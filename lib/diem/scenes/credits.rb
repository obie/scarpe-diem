# frozen_string_literal: true

module Diem
  module Scenes
    # Bars 88-96, the last scene. Calm after the storm: a slow starfield drifting at the viewer,
    # a warm glow low on the horizon, the SCARPE DIEM logo gathered out of the stars in small
    # squares that ring like the bell, and the credits rolling up through the middle until
    # "thank you for watching" settles in the centre and the engine fades the night out.
    class Credits < Scene
      P = Palette
      TAU = Math::PI * 2

      STARS = 420
      BUCKETS = 7          # star brightness levels, one shape each
      Z_NEAR = 0.16
      Z_FAR = 1.0
      DRIFT = 0.045        # depth units per second toward the viewer

      CELL = 5.0           # logo cell, in u
      LOGO_TOP = 30.0      # in u
      GATHER = 2.6         # seconds for the stars to become the logo

      ARRIVE = 13.0        # when "thank you for watching" reaches the centre
      HOLD = 0.35          # seconds the roll waits under the flash
      ACCEL = 1.6
      SPEED = 120.0        # cruise, in u a second: 2 px every 60 fps frame, 4 at 30

      HEADING = [196, 170, 150]
      SKY_TOP = [5, 4, 14]
      SKY_BOTTOM = [30, 11, 38]
      SKY_TILE = 64        # px: the period of the sky's grain across the slot
      DETAIL = [226, 222, 246]

      # [kind, text or key]; :gap marks a gold rule between blocks.
      ROLL = [
        [:detail, "a real-time demo for the Scarpe native renderer"],
        [:gap],
        [:heading, "code, music and pixels"],
        [:name, "Claude, for Obie Fernandez"],
        [:gap],
        [:heading, "the renderer"],
        [:name, "Nick and the Scarpe team"],
        [:gap],
        [:heading, "Shoes"],
        [:name, "_why the lucky stiff, 2007"],
        [:gap],
        [:heading, "the soundtrack"],
        [:name, "synthesized by Ruby when you pressed play"],
        [:detail, :samples],
        [:detail, :synth],
        [:gap],
        [:heading, "this run"],
        [:stat, :frames],
        [:stat, :shapes],
        [:stat, :changes],
        [:detail, "Ruby to JSON to Rust to tiny-skia, every frame"],
        [:detail, "no GPU, no shaders, no video"],
        [:end],
        [:thanks, "thank you for watching"],
      ].freeze

      # kind => [size, line advance, kerning, weight, colour]
      STYLE = {
        heading: [13, 26, 4, 500, HEADING],
        name: [25, 44, 0, 300, P::INK],
        detail: [17, 27, 0, 400, DETAIL],
        stat: [19, 30, 0, 400, P::INK],
        thanks: [28, 40, 1, 300, [255, 226, 180]],
      }.freeze

      # The low warm glow: ovals sunk below the bottom edge, each a gradient that is clear at
      # its top, so no edge shows. [dy, width, height, colour, alpha], sizes in u.
      HORIZON = [
        [250, 2600, 760, [120, 34, 130], 0.26],
        [200, 2000, 560, [210, 60, 120], 0.19],
        [150, 1000, 380, [255, 120, 90], 0.24],
        [110, 560, 230, [255, 200, 140], 0.22],
      ].freeze
      BAKED = 2            # the broad outer ovals are painted into the sky picture, at BAKED_K;
      BAKED_K = 1.15       # the warm inner two stay ovals and keep breathing

      BLOOM = 2.2          # a logo square's glow, as a multiple of its size
      BLOOM_COL = [255, 168, 96]

      DISSOLVE = 13.3      # the logo goes back to the stars
      DEPART = 1.05        # seconds each square takes to leave

      GAP = 76             # block gap in u, the rule sits in its middle
      END_GAP = 200        # from the last block to the thanks

      # Lines fade between these two heights (u, at a line's middle) on the way up, so they are
      # gone before they reach the logo's band.
      FADE_GONE = 104
      FADE_FULL = 164

      def build
        @rng = Random.new(8896)
        @cx = w / 2.0
        @cy = h * 0.47
        build_stars_data
        build_logo_data
        sky = build_sky
        breathe
        draw do
          nostroke
          if sky
            image(sky, left: 0, top: 0, width: w.round, height: h.round)
          else
            rect(0, 0, w, h, fill: P.rgb(SKY_TOP)..P.rgb(SKY_BOTTOM), strokewidth: 0)
          end
          @glow_from = sky ? BAKED : 0
          @horizon = HORIZON.drop(@glow_from).map do |dy, ww, hh, _col, _a|
            oval(@cx, h + dy * u, ww * u, hh * u, center: true, fill: P.rgb(P::NIGHT, 0.0), strokewidth: 0)
          end
          @star_shapes = Array.new(BUCKETS) { shape(0, 0, fill: P.rgb(P::INK, 0.0), strokewidth: 0) }
          @blooms = @logo_pts.map { oval(-20, -20, @sq, @sq, fill: P.rgb(P::GOLD, 0.0), strokewidth: 0) }
          @squares = @logo_pts.map { rect(-20, -20, @sq, @sq, fill: P.rgb(P::GOLD, 0.0), strokewidth: 0) }
          build_roll
        end
        @sq_shown = Array.new(@squares.size)
        @sq_pos = Array.new(@squares.size)
        @bloom_shown = Array.new(@squares.size)
      end

      def enter
        @refreshed = false
        @line_shown = {}
        @line_top = {}
        @line_alpha = {}
        @glow_shown = nil
        @rule_top = []
        @rule_alpha = []
        @star_shown = Array.new(BUCKETS)
        @sq_shown.fill(nil)
        @sq_pos.fill(nil)
        @bloom_shown.fill(nil)
        fill_numbers
        layout_roll
      end

      def update(t, sync)
        if !@refreshed && t >= 2.0
          @refreshed = true
          fill_numbers(refresh: true)
        end
        update_stars(t)
        update_glow(t, sync)
        update_logo(t, sync)
        update_roll(t)
      end

      private

      # ---- sky -----------------------------------------------------------------------------

      # The night gradient climbs only 25 levels over the whole height, so drawn smooth it bands
      # in 20 px steps. Instead the sky is one picture, made here at the slot's size: the same
      # gradient with the two broad horizon ovals laid over it, dithered with seeded noise (each
      # channel rounds up or down by chance in proportion to how near it is), which averages to
      # the true colour with no edges. Shown at its own size the renderer copies it pixel for
      # pixel. Rows clear of the glow are one colour across, so their grain is a short seeded
      # tile repeated (shifted row by row); the glow rows are worked out pixel by pixel.
      # Returns nil, and the scene falls back to the plain gradient and four ovals, if the file
      # cannot be written.
      def build_sky
        ww = w.round
        hh = h.round
        return nil if ww < SKY_TILE || hh < 2

        rng = Random.new(5413)
        ovals = HORIZON.first(BAKED).map do |dy, ow, oh, col, a|
          [h + dy * u, ow * u / 2.0, oh * u / 2.0, col, a * BAKED_K]
        end
        glow_top = ovals.map { |cy, _, b, *| cy - b }.min.floor.clamp(0, hh)
        reps = ww / SKY_TILE + 2
        rows = Array.new(hh) do |y|
          c = P.mix(SKY_TOP, SKY_BOTTOM, (y + 0.5) / hh)
          noise = Array.new(SKY_TILE * 3) { rng.rand }
          if y < glow_top
            breathe if (y % 16).zero?
            tile = Array.new(SKY_TILE * 3) { |i| (c[2 - i % 3] + noise[i]).floor }.pack("C*")
            shift = (y * 37 % SKY_TILE) * 3
            ((tile[shift..] + tile[0, shift]) * reps)[0, ww * 3]
          else
            breathe
            glow_row(y + 0.5, c, ovals, ww, noise)
          end
        end
        pad = "\0" * ((4 - ww * 3 % 4) % 4)
        body = pad.empty? ? rows.join : rows.map { |r| r + pad }.join
        header = ["BM", 54 + body.bytesize, 0, 0, 54, 40, ww, -hh, 1, 24, 0, body.bytesize, 2835, 2835, 0, 0]
          .pack("a2Vv2VVl<l<vvVVl<l<VV")
        path = File.join(Framebuffer::DIR, "credits-sky-#{ww}x#{hh}.bmp")
        File.binwrite(path, header + body)
        path
      rescue SystemCallError
        nil
      end

      # One row of sky with the baked ovals over it, as BGR bytes. Each oval is a vertical
      # gradient from clear at its top to its alpha at its bottom, as the renderer draws it, with
      # a pixel of soft edge at the sides.
      def glow_row(py, sky, ovals, ww, noise)
        spans = ovals.filter_map do |cy, ax, by, col, alpha|
          d = (py - cy) / by
          next if d.abs >= 1.0

          [ax * Math.sqrt(1.0 - d * d), alpha * (py - cy + by) / (2.0 * by), col]
        end
        out = Array.new(ww * 3)
        ww.times do |x|
          dx = (x + 0.5 - @cx).abs
          r, g, b = sky
          spans.each do |half, alpha, col|
            k = alpha * (half - dx + 0.5).clamp(0.0, 1.0)
            next unless k.positive?

            r += (col[0] - r) * k
            g += (col[1] - g) * k
            b += (col[2] - b) * k
          end
          n = (x % SKY_TILE) * 3
          i = x * 3
          out[i] = (b + noise[n]).floor.clamp(0, 255)
          out[i + 1] = (g + noise[n + 1]).floor.clamp(0, 255)
          out[i + 2] = (r + noise[n + 2]).floor.clamp(0, 255)
        end
        out.pack("C*")
      end

      # ---- stars ---------------------------------------------------------------------------

      def build_stars_data
        n = (STARS * density).round.clamp(40, STARS)
        @stars = Array.new(n) do
          r = Math.sqrt(@rng.rand) * 1.25 + 0.04
          a = @rng.rand * TAU
          [r * Math.cos(a) * 1.7, r * Math.sin(a), @rng.rand, 0.7 + 0.6 * @rng.rand]
        end
        @focal = h * 0.36
        @star_cols = Array.new(BUCKETS) do |b|
          k = (b + 1).fdiv(BUCKETS)
          tint = P.mix([170, 170, 255], [255, 236, 214], k)
          wc(tint, 0.18 + 0.82 * k**1.3)
        end
      end

      # Each star sits at depth z, falling slowly toward the viewer and wrapping round to the
      # back. A star's brightness level picks its shape, so the whole field is seven paths.
      def update_stars(t)
        span = Z_FAR - Z_NEAR
        ease = t < 12.0 ? 1.0 : 1.0 - 0.5 * smooth((t - 12.0) / 3.0)
        travel = DRIFT * (t < 12.0 ? t : 12.0 + (t - 12.0) * ease)
        turn = 0.018 * t
        ct = Math.cos(turn)
        st = Math.sin(turn)
        cmds = Array.new(BUCKETS) { [] }
        f = @focal
        cx = @cx
        cy = @cy
        ww = w + 4
        hh = h + 4
        quiet_x = 300 * u
        quiet_y = 90 * u
        quiet_r = 0.6 * u
        lhalf, ltop, lbot = @logo_box
        @stars.each do |x0, y0, z0, s0|
          z = Z_NEAR + (z0 * span - travel) % span
          x = x0 * ct - y0 * st
          y = x0 * st + y0 * ct
          sx = cx + x / z * f
          sy = cy + y / z * f
          next if sx < -4 || sy < -4 || sx > ww || sy > hh

          near = (Z_FAR - z) / span
          fade = z < Z_NEAR + 0.08 ? (z - Z_NEAR) / 0.08 : 1.0
          fade *= z > Z_FAR - 0.12 ? (Z_FAR - z) / 0.12 : 1.0
          b = ((near**1.4 * fade * s0) * BUCKETS).floor.clamp(0, BUCKETS - 1)
          next if fade < 0.15

          r = (0.45 + 1.9 * near**2 * s0) * u
          dx = (sx - cx).abs
          # behind the credits and around the logo: no stray punctuation
          if (dx < quiet_x && sy > quiet_y) || (dx < lhalf && sy > ltop && sy < lbot)
            b = (b - 2).clamp(0, BUCKETS - 1)
            r = quiet_r if r > quiet_r
          end
          l = (sx - r).round(1)
          tp = (sy - r).round(1)
          rr = (sx + r).round(1)
          bt = (sy + r).round(1)
          cmds[b] << ["move_to", l, tp] << ["line_to", rr, tp] << ["line_to", rr, bt] << ["line_to", l, bt]
        end
        BUCKETS.times do |b|
          props = { shape_commands: cmds[b] }
          props[:fill] = @star_cols[b] unless @star_shown[b]
          @star_shown[b] = true
          set(@star_shapes[b], props)
        end
      end

      # ---- glow ----------------------------------------------------------------------------

      def update_glow(t, sync)
        swell = 0.5 + 0.5 * Math.sin(t * 0.8)
        held = smooth((t - 12.0) / 1.5)
        k = (0.85 + 0.25 * swell + 0.35 * held).round(2)
        return if k == @glow_shown

        @glow_shown = k
        HORIZON.drop(@glow_from).each_with_index do |(_, _, _, col, a), i|
          set(@horizon[i], { fill: { gradient: [wc(col, 0.0), wc(col, a * k)], angle: 0 } })
        end
      end

      # ---- logo ----------------------------------------------------------------------------

      def build_logo_data
        text = "SCARPE DIEM"
        cols = Bitfont.width(text)
        cell = CELL * u
        @sq = (cell * 0.78).round(1)
        x0 = @cx - cols * cell / 2.0
        y0 = LOGO_TOP * u
        @logo_cols = cols
        @logo_pts = Bitfont.points(text).map do |gx, gy|
          home = [x0 + gx * cell, y0 + gy * cell]
          # where it starts: a point in the starfield, far back
          a = @rng.rand * TAU
          r = 0.25 + @rng.rand * 1.1
          start = [@cx + Math.cos(a) * r * w * 0.5, @cy + Math.sin(a) * r * h * 0.45]
          [gx, gy, home, start, @rng.rand * TAU, 0.15 + @rng.rand * 0.55]
        end
        rows = @logo_pts.map { |pt| pt[1] }.max.to_i + 1
        # the logo's box plus a margin, reaching down to the roll's quiet zone: stars in it are dimmed
        @logo_box = [cols * cell / 2.0 + 10 * u, y0 - 10 * u, y0 + rows * cell + 28 * u]
        origin = (PLAN.find { |name, *| name == "Credits" }&.[](1) || 88) * Music::BAR
        @bells = Sync.new(Music.score).hits(:bell).select { |hb| hb.time >= origin - 0.01 }
          .map { |hb| [hb.time - origin, hb.note] }
      end

      # The squares come out of the starfield and settle into the logo; after that every bell
      # note rings it, a ripple spreading out from the column its pitch points at.
      def update_logo(t, sync)
        rings = @bells.select { |bt, _| bt <= t && t - bt < 2.2 }
        cols = @logo_cols.to_f
        @logo_pts.each_with_index do |(gx, gy, home, start, phase, delay), i|
          g = smooth((t - delay) / GATHER)
          g = 1.0 - (1.0 - g)**3
          boost = 0.0
          rings.each do |bt, note|
            age = t - bt
            c0 = ((note - 79) / 12.0).clamp(0.0, 1.0) * (cols - 1)
            dist = Math.sqrt((gx - c0)**2 + ((gy - 3) * 1.6)**2)
            front = age * 34.0
            boost += Math.exp(-((dist - front)**2) / 10.0) * Math.exp(-age / 0.9)
          end
          boost = boost.clamp(0.0, 1.0)
          # Leaving: each square lets go in turn and is flung up and outward, shrinking to a
          # star's size and fading as it goes, so the logo area is clear well before the fade.
          p = t > DISSOLVE ? ((t - DISSOLVE - delay * 0.9) / DEPART).clamp(0.0, 1.0) : 0.0
          gone = p * p * (3 - 2 * p)
          if p.positive?
            fling = p * p
            x = home[0] + (home[0] - @cx) * 0.55 * fling + Math.sin(phase) * 18 * u * fling
            y = home[1] - fling * (70 + 60 * (1.0 - delay)) * u
            s = (@sq * (1.0 - 0.72 * gone)).round(1)
          elsif g < 1.0
            x = start[0] + (home[0] - start[0]) * g
            y = start[1] + (home[1] - start[1]) * g
            s = (@sq * (0.35 + 0.65 * g)).round(1)
          else
            x = home[0]
            y = home[1] - boost * 1.6 * u
            s = @sq
          end
          pos = [x.round(1), y.round(1), s]
          tw = 0.06 * Math.sin(t * 1.9 + phase)
          warm = P.mix(P::GOLD, [255, 150, 130], gx / cols)
          base = P.mix(warm, [255, 246, 228], 0.35 + tw)
          col = P.mix(base, [255, 255, 255], boost)
          alpha = (0.5 + 0.5 * g) * (0.86 + 0.14 * boost) * (1.0 - gone)
          c = wc(P.scale(col, 0.88 + 0.12 * boost), alpha)
          c[3] = (c[3] / 4) * 4
          glow = wc(P.mix(warm, BLOOM_COL, 0.5), (0.018 + 0.055 * boost) * alpha * g)
          glow[3] = (glow[3] / 2) * 2
          props = {}
          bloom = {}
          if pos != @sq_pos[i]
            props[:left] = pos[0]
            props[:top] = pos[1]
            b = s * BLOOM
            bloom[:left] = (pos[0] + (s - b) / 2).round(1)
            bloom[:top] = (pos[1] + (s - b) / 2).round(1)
            if @sq_pos[i].nil? || @sq_pos[i][2] != s
              props[:width] = s
              props[:height] = s
              bloom[:width] = b.round(1)
              bloom[:height] = b.round(1)
            end
            @sq_pos[i] = pos
          end
          if c != @sq_shown[i]
            props[:fill] = c
            @sq_shown[i] = c
          end
          if glow != @bloom_shown[i]
            bloom[:fill] = glow
            @bloom_shown[i] = glow
          end
          set(@squares[i], props) unless props.empty?
          set(@blooms[i], bloom) unless bloom.empty?
        end
      end

      # ---- the roll ------------------------------------------------------------------------

      def build_roll
        @lines = []
        @rules = []
        ROLL.each do |kind, text|
          case kind
          when :gap
            @rules << rect((@cx - 18 * u).round, -10, (36 * u).round, 1, fill: P.rgb(P::GOLD, 0.0), strokewidth: 0)
          when :end
            nil
          else
            size, _adv, kern, weight, colour = STYLE.fetch(kind)
            label = text.is_a?(String) ? text : " "
            label = label.downcase if kind == :heading # uniform small caps, "Shoes" included
            opts = { left: 0, top: h + 40, width: w, size: (size * u).round(1), stroke: P.rgb(colour, 0.0),
                     align: "center", margin: 0, weight: weight }
            if kern.positive?
              opts[:kerning] = (kern * u).round(1)
              opts[:left] = (kern * u / 2).round # the spacing after the last letter, centred out
            end
            opts[:variant] = "smallcaps" if kind == :heading
            para = para(label, **opts)
            @lines << { kind: kind, key: text, para: para, colour: colour }
          end
        end
      end

      def samples_text
        n = (Music::LENGTH * 44_100).round
        notes = Music.score.values.sum(&:size)
        "#{group(n)} stereo samples · #{group(notes)} notes · #{Music.score.size} instruments"
      end

      def number_text(key)
        st = Diem.stats
        case key
        when :samples then samples_text
        when :synth
          s = st["synth_seconds"]
          s ? "rendered in #{format('%.1f', s.to_f)} s" : nil
        when :frames then st["frames"] ? "#{group(st['frames'])} frames drawn" : nil
        when :shapes then st["peak_shapes"] ? "peak #{group(st['peak_shapes'])} shapes on screen" : nil
        when :changes then st["peak_changes"] ? "peak #{group(st['peak_changes'])} changes in a single frame" : nil
        end
      end

      # Sets the text of every line whose words come from the run. Which lines exist is fixed at
      # enter; the refresh only brings the numbers up to date.
      def fill_numbers(refresh: false)
        @lines.each do |ln|
          next if ln[:key].is_a?(String)

          text = number_text(ln[:key])
          ln[:on] = !text.nil? unless refresh
          next unless ln[:on] && text && text != ln[:text]

          ln[:para].text = text
          ln[:text] = text
        end
        @lines.each { |ln| ln[:on] = true if ln[:key].is_a?(String) }
      end

      # Content offsets in u from the first line's top. The cruise runs at SPEED, a whole number
      # of pixels a frame so the type steps evenly; the landing takes whatever time is left for
      # the thanks to reach the centre at ARRIVE. Only if that falls outside a sane landing
      # (lines missing from the stats) does the speed give way instead.
      def layout_roll
        y = 0.0
        li = 0
        ri = 0
        @rule_y = []
        ROLL.each do |kind, _|
          case kind
          when :gap
            @rule_y[ri] = y + GAP / 2.0
            ri += 1
            y += GAP
          when :end
            y += END_GAP
          else
            ln = @lines[li]
            li += 1
            next unless ln[:on]

            ln[:y] = y
            y += STYLE.fetch(kind)[1]
          end
        end
        thanks = @lines.last
        size = STYLE[:thanks][0]
        @start = h - 170 * u               # where the first line sits at t = 0
        target = h / 2.0 - size * 0.62 * u # top of the thanks when its middle is centred
        @distance = @start + thanks[:y] * u - target
        @speed = SPEED * u
        @decel = 2.0 * (ARRIVE - HOLD - ACCEL / 2.0 - @distance / @speed)
        return if @decel.between?(1.6, 5.6)

        @decel = @decel.clamp(1.6, 5.6)
        @speed = @distance / (ARRIVE - HOLD - ACCEL / 2.0 - @decel / 2.0)
      end

      def scrolled(t)
        v = @speed
        t1 = HOLD
        t2 = HOLD + ACCEL
        t3 = ARRIVE - @decel
        if t <= t1 then 0.0
        elsif t <= t2 then v * (t - t1)**2 / (2 * ACCEL)
        elsif t <= t3 then v * (ACCEL / 2.0 + (t - t2))
        elsif t <= ARRIVE
          r = ARRIVE - t
          @distance - v * r * r / (2 * @decel)
        else @distance
        end
      end

      def update_roll(t)
        s = scrolled(t).round
        base = @start.round - s
        top_a = FADE_GONE * u
        top_b = FADE_FULL * u
        bot_a = h - 18 * u
        bot_b = h - 80 * u
        @lines.each do |ln|
          para = ln[:para]
          unless ln[:on]
            hide_line(ln)
            next
          end
          top = base + (ln[:y] * u).round
          size = STYLE.fetch(ln[:kind])[0] * u
          mid = top + size * 0.6
          if mid < top_a - 10 || top > h + 4
            hide_line(ln)
            next
          end
          a = ramp(mid, top_a, top_b) * (1.0 - ramp(mid, bot_b, bot_a))
          a = (a * 32).round / 32.0
          props = {}
          props[:hidden] = false if @line_shown[para] != true
          @line_shown[para] = true
          props[:top] = top if @line_top[para] != top
          @line_top[para] = top
          if @line_alpha[para] != a
            props[:stroke] = wc(ln[:colour], a)
            @line_alpha[para] = a
          end
          set(para, props) unless props.empty?
        end
        @rules.each_with_index do |rule, i|
          y = base + (@rule_y[i] * u).round
          a = ramp(y, top_a, top_b) * (1.0 - ramp(y, bot_b, bot_a))
          a = (a * 32).round / 32.0
          top = y.clamp(-10, h + 10)
          props = {}
          props[:top] = top if @rule_top[i] != top
          props[:fill] = wc(P::GOLD, 0.5 * a) if @rule_alpha[i] != a
          @rule_top[i] = top
          @rule_alpha[i] = a
          set(rule, props) unless props.empty?
        end
      end

      def hide_line(ln)
        para = ln[:para]
        return if @line_shown[para] == false

        set(para, { hidden: true })
        @line_shown[para] = false
      end

      def ramp(x, a, b) = ((x - a) / (b - a)).clamp(0.0, 1.0)

      def group(n) = n.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

      def smooth(x)
        x = x.clamp(0.0, 1.0)
        x * x * (3 - 2 * x)
      end
    end
  end
end
