# frozen_string_literal: true

require_relative "../copper_tables"

module Diem
  module Scenes
    # Bars 16-24. An Amiga homage done better than the Amiga could: chrome copper bars rolling
    # round a cylinder, a checkerboard floor rushing at the viewer, and a giant sine scroller of
    # greetings that rides the lead melody, weaves between the bars and shines on the floor.
    class Copper < Scene
      T = CopperTables
      TAU = Math::PI * 2

      PITCH = 11.0         # font pixel cell, in u
      SQUARE = 8.6         # a lit font pixel's square, in u (golden words get GOLD_SQUARE)
      GOLD_SQUARE = 9.4
      SEAM = 1.19          # a gap thinner than this, in u, reads as a hairline seam (golden squares on a kick)...
      FUSE = 0.5           # ... so the squares fuse instead, overlapping by this much
      SPEED = 345.0        # scroller speed, u per second: HELLO OBIE arrives before the fold
      LEAD_IN = 1.3        # seconds of text already on screen when the scene opens
      BAR_COUNT = 12
      FLOOR_DEPTH = 13.0   # how far the floor runs before the fog takes it
      SQUASH = 0.42        # the floor reflection's vertical squash
      FRONT = 0.8          # bars nearer than this cos(phase) pass in front of the scroller
      VEIL = 0.55          # a front bar's alpha, so the text reads through the chrome
      ARC = Math.acos(FRONT)
      WEAVE = [5.35, 6.8]   # bars may only enter the front layer between these seconds
      BURST = 15.5         # the snare fill: the scroller explodes
      FOLD = 15.25         # the bars fold into one white beam
      DROP = 8.0           # bar 20: the floor turns to ice and every bar flares
      TILE = 0.8           # floor tile size, in half camera heights
      BEAM_HALF = 4.5      # the closing beam's half thickness, in u
      SPIN0 = 1.17         # spin offset that puts the snake's middle facing us at 7.5 s
      FILL_LIFT = 20.0     # u the shattered scroller jumps on the loudest snare fill hit

      def build
        @hy = (h * 0.6).round(1)
        @fk = h - @hy
        @cols = T.columns
        @pool = (w / (PITCH * u)).ceil + 2
        @bar_n = density < 0.6 ? [(BAR_COUNT * density * 1.4).round, 5].max : BAR_COUNT
        @rich = density >= 0.6

        draw do
          nostroke
          sky
          @back = Array.new(@bar_n) { bar_pair }
          floor
          @mirror = @rich ? Array.new(@bar_n) { bar_pair(2) } : []
          @reflect = @rich ? Array.new(@pool) { column_shape } : []
          horizon
          @hflash = [glow_rect, glow_rect]
          @beam = [glow_rect, glow_rect]
          @extrude = @rich ? Array.new(@pool) { column_shape } : []
          @face = Array.new(@pool) { column_shape }
          @front = Array.new(@bar_n) { bar_pair }
        end
        @slots = Array.new(@pool) { [-1, -1] } # [text column, size level] each pool slot shows
        @order = (0...@bar_n).to_a
        @bar_y = Array.new(@bar_n, 0.0)
        @bar_z = Array.new(@bar_n, 0.0)
        @shown = {}
        @flat = T.flat
        @p_from = Array.new(@bar_n) { |i| phase(WEAVE[0], i) }
        @p_to = Array.new(@bar_n) { |i| phase(WEAVE[1], i) }
        @glow_a = {}
        @reflect_gone = Array.new(@pool, false)
      end

      def enter
        @slots.each { |s| s[0] = -1 }
        @floor_step = nil
        (@back + @front + @waves).each { |pair| @shown[pair[0]] = true }
        (@beam + @hflash).each { |r| set(r, { height: 0 }) }
        @glow_a.clear
        (@face + @extrude).each { |d| set(d, { rotate: 0, scale: [1.0, 1.0] }) } if @rotated
        @rotated = false
        @reflect_gone.fill(false)
      end

      def update(t, sync)
        kick = sync.hit(:kick, 0.13)
        snare = sync.hit(:snare, 0.09)
        @jolt = sync.hit(:snare, 0.05)
        @snares = sync.count(:snare)
        @flare = t >= DROP ? Math.exp(-(t - DROP) / 0.15) : 0.0
        fill_response(sync, t - BURST)
        update_bars(t, sync, kick)
        update_floor(t, sync, kick)
        update_glows(t)
        update_scroller(t, sync, kick, snare)
      end

      private

      # ---- build -------------------------------------------------------------------------

      def sky
        rect(0, 0, w, @hy, fill: rgb(6, 4, 22)..rgb(58, 12, 78), strokewidth: 0)
        rect(0, @hy - 90 * u, w, 90 * u, fill: rgb(255, 40, 140, 0)..rgb(255, 60, 150, 110), strokewidth: 0)
      end

      def bar_pair(n = 3)
        clear = rgb(0, 0, 0, 0)
        Array.new(n) { rect(0, -50, w, 0, fill: clear, strokewidth: 0) }
      end

      def glow_rect
        rect(0, -50, w, 0, fill: rgb(255, 255, 255, 0), strokewidth: 0)
      end

      def column_shape
        shape(-100, 0, fill: rgb(0, 0, 0, 0), strokewidth: 0, stroke: rgb(0, 0, 0, 0))
      end

      def floor
        rect(0, @hy, w, h - @hy, fill: rgb(10, 4, 30)..rgb(28, 8, 60), strokewidth: 0)
        @checker = shape(0, 0, fill: rgb(80, 16, 104)..rgb(214, 44, 150), strokewidth: 0, stroke: rgb(0, 0, 0, 0))
        @waves = Array.new(2) do
          [rect(0, -50, w, 0, fill: rgb(0, 0, 0, 0), strokewidth: 0), rect(0, -50, w, 0, fill: rgb(0, 0, 0, 0), strokewidth: 0)]
        end
        @fog = [rect(0, @hy, w, 100 * u, fill: rgb(70, 16, 96, 255)..rgb(70, 16, 96, 0), strokewidth: 0),
                rect(0, @hy, w, 42 * u, fill: rgb(70, 16, 96, 255)..rgb(70, 16, 96, 0), strokewidth: 0)]
      end

      def horizon
        rect(0, @hy - 3 * u, w, 3 * u, fill: rgb(255, 80, 180, 0)..rgb(255, 210, 240, 255), strokewidth: 0)
        rect(0, @hy, w, 2 * u, fill: rgb(255, 230, 250)..rgb(255, 80, 180, 0), strokewidth: 0)
      end

      # ---- copper bars -----------------------------------------------------------------------

      # Bars roll round a cylinder: sin(phase) is height, cos(phase) is nearness. Near bars draw
      # in front of the scroller, far ones behind it; each frame the bars are dealt to the pool
      # slots in depth order, so the creation order of the rects does the painter's sort.
      def update_bars(t, sync, kick)
        @fin = smooth((t - FOLD) / 0.65)
        layout_bars(t)
        @order.sort_by! { |i| @bar_z[i] }
        hue0 = t * 0.045 + sync.count(:snare) * 0.07
        spark_bar = (sync.count(:lead) - 1) % @bar_n
        spark = sync.count(:lead).positive? ? Math.exp(-sync.since(:lead) / 0.35) : 0.0
        back = 0
        front = 0
        @order.each_with_index do |i, n|
          glow = i == spark_bar ? spark : 0.0
          colours = bar_colours(i, hue0, kick, glow)
          if front?(t, i)
            paint_bar(@front[front], i, colours, veil(t, i))
            front += 1
          else
            paint_bar(@back[back], i, colours, veil(t, i))
            back += 1
          end
          reflect_bar(@mirror[n], i, colours) if @rich
        end
        (back...@bar_n).each { |k| park(@back[k]) }
        (front...@bar_n).each { |k| park(@front[k]) }
      end

      # Where each bar is: a snake of bars that opens into a full rolling cylinder mid-scene,
      # tightens again, then folds to one line on the closing snare fill.
      def layout_bars(t)
        open = smooth((t - 0.05) / 1.1)
        close = t > FOLD ? 1.0 - smooth((t - FOLD) / 0.7) : 1.0
        radius = 128 * u * open * close
        centre = h * 0.28
        wobble = 12 * u * open * close * (1.0 - ring(t) * 0.7)
        spin = spin(t)
        spread = spread(t)
        @bar_n.times do |i|
          p = spin + i * spread
          @bar_z[i] = Math.cos(p)
          @bar_y[i] = centre + radius * Math.sin(p) + wobble * Math.sin(t * 1.3 + i * 1.9)
        end
      end

      def ring(t) = smooth((t - 7.5) / 1.5) * (1.0 - smooth((t - 11.5) / 1.5))

      def spread(t)
        snake = 0.4 + 0.06 * Math.sin(t * 0.55)
        snake + (TAU / @bar_n - snake) * ring(t)
      end

      def spin(t) = SPIN0 + t * 2.1 + smooth((t - 11.5) / 4.0) * (t - 11.5) * 1.6

      def phase(t, i) = spin(t) + i * spread(t)

      # A bar joins the front layer only by rolling forward through cos(phase) = FRONT inside
      # the weave window, and leaves it only by rolling back out, so the layer swap always
      # happens as the bar crosses the scroller's depth and never as a pop.
      def front?(t, i)
        return false if t < WEAVE[0]

        p = phase(t, i)
        a = (p + ARC) % TAU
        return false if a >= 2 * ARC

        entry = p - a
        entry >= @p_from[i] && entry <= @p_to[i]
      end

      # Near bars thin to VEIL as they roll up to the scroller's depth, during the weave only, so
      # a bar already reads as glass when it crosses in front of the text and never pops.
      def veil(t, i)
        weave = smooth((t - WEAVE[0] + 0.6) / 0.5) * (1.0 - smooth((t - WEAVE[1] - 0.7) / 0.5))
        return 1.0 if weave <= 0.0

        1.0 - (1.0 - VEIL) * weave * smooth((@bar_z[i] - 0.55) / 0.25)
      end

      # [edge, core, half height]: dark edge to a bright core and back fakes a chrome tube.
      def bar_colours(i, hue0, kick, glow)
        z = (@bar_z[i] + 1) * 0.5
        col = T.vivid((hue0 + i.fdiv(@bar_n)) % 1.0)
        fin = @fin
        flare = @flare
        lit = 0.18 + 0.82 * z * z
        lit += (1.0 - lit) * [fin, flare].max
        core = T.mix_white(T.shade(col, lit), (0.5 * kick + 0.9 * glow) * (0.3 + 0.7 * z) + 0.8 * fin + flare)
        edge = T.mix_white(T.shade(col, 0.07 + 0.08 * z + 0.5 * fin), 0.9 * fin + 0.6 * flare)
        half = (5.5 + 7.5 * z) * u * (1 + 0.3 * kick + 0.6 * glow + 0.35 * flare)
        half += (BEAM_HALF * u - half) * fin
        half += @punch * 3.5 * u * fin
        [edge, core, half]
      end

      def paint_bar(pair, i, colours, alpha)
        edge, core, half = colours
        a = (alpha * 255).round
        top = (@bar_y[i] - half).round(1)
        hh = half.round(1)
        set(pair[0], { top: top, height: hh, fill: { gradient: [edge + [a], core + [a]], angle: 0 } })
        set(pair[1], { top: (top + hh).round(1), height: hh, fill: { gradient: [core + [a], edge + [a]], angle: 0 } })
        z = (@bar_z[i] + 1) * 0.5
        gh = (half * 0.16).round(1)
        set(pair[2], { top: (top + hh - gh * 0.5).round(1), height: gh, fill: [255, 255, 255, (a * (0.15 + 0.55 * z * z)).round] })
        @shown[pair[0]] = true
      end

      # The same bar, mirrored and squashed on the glossy floor.
      def reflect_bar(pair, i, colours)
        edge, core, half = colours
        z = (@bar_z[i] + 1) * 0.5
        a = (40 + 50 * z).round
        hh = (half * SQUASH).round(1)
        y = @hy + (@hy - @bar_y[i]) * SQUASH + 3 * u
        top = (y - hh).round(1)
        set(pair[0], { top: top, height: hh, fill: { gradient: [edge + [0], core + [a]], angle: 0 } })
        set(pair[1], { top: (top + hh).round(1), height: hh, fill: { gradient: [core + [a], edge + [0]], angle: 0 } })
      end

      def park(pair)
        return unless @shown.delete(pair[0])

        pair.each { |r| set(r, { height: 0 }) }
      end

      # Two soft white glows: a horizon flash on the bar-20 drop, and a halo round the closing
      # beam that grows until it hands over to the next scene's flash.
      def update_glows(t)
        flash = @flare
        flash = flash * (t < DROP + 1 ? 1 : 0)
        flash = [flash, 0.75 * @punch].max
        glow_pair(@hflash, @hy, 80 * u, 46 * u, flash)
        beam_y = @fin.positive? ? @bar_y.sum / @bar_n : 0
        halo = (24 + 50 * @fin + 46 * @punch * @fin) * u
        glow_pair(@beam, beam_y, halo, halo, @fin * 0.95)
      end

      def glow_pair(pair, y, up, down, k)
        a = (k * 255).round.clamp(0, 255)
        if a < 3
          return unless @glow_a.delete(pair[0])

          pair.each { |r| set(r, { height: 0 }) }
          return
        end
        @glow_a[pair[0]] = a
        white = [255, 250, 255]
        set(pair[0], { top: (y - up).round(1), height: up.round(1), fill: { gradient: [white + [0], white + [a]], angle: 0 } })
        set(pair[1], { top: y.round(1), height: down.round(1), fill: { gradient: [white + [a], white + [0]], angle: 0 } })
      end

      # ---- floor -------------------------------------------------------------------------

      # One shape draws the whole checkerboard: column wedges wound one way and row bands wound
      # the other, so where they cross the windings cancel (nonzero fill gives XOR for free).
      def update_floor(t, sync, kick)
        beats = t / Music::BEAT
        whole = beats.floor
        f = beats - whole
        scroll = 2.0 * (whole + 1.0 - (1.0 - f)**3)
        scroll += 6.0 * smooth((t - 15.5) / 0.5)**2 if t > 15.5
        cam = 0.9 * Math.sin(t * 0.37)
        set(@checker, { shape_commands: checker_path(scroll, cam) })
        tint_floor(t)
        update_waves(t, sync)
      end

      # The floor snaps to ice blue on the bar-20 drop, the same frame the bars flare, and melts
      # back to magenta as the cylinder closes.
      def tint_floor(t)
        hit = t >= DROP ? 0.6 + 0.4 * smooth((t - DROP) / 0.12) : 0.0
        act = hit * (1.0 - smooth((t - 11.75) / 0.5))
        step = (act * 32).round
        return if step == @floor_step

        @floor_step = step
        k = step / 32.0
        far = T.lerp([80, 16, 104], [12, 52, 110], k)
        near = T.lerp([214, 44, 150], [30, 196, 230], k)
        set(@checker, { fill: { gradient: [far + [255], near + [255]], angle: 0 } })
        fog = T.lerp([70, 16, 96], [22, 44, 104], k)
        @fog.each { |r| set(r, { fill: { gradient: [fog + [255], fog + [0]], angle: 0 } }) }
      end

      def checker_path(scroll, cam)
        cmds = []
        fk = @fk
        hy = @hy
        bottom = h.to_f
        tile = TILE
        frac = scroll % 1.0
        base = scroll.floor
        rows = ((FLOOR_DEPTH - 1.0) / tile).ceil + 1
        rows.times do |k|
          next unless (k + base).odd?

          z0 = 1.0 + (k - frac) * tile
          y0 = z0 <= 1.0 ? bottom : (hy + fk / z0).round(1)
          y1 = (hy + fk / (z0 + tile)).round(1)
          cmds << ["move_to", -1, y1] << ["line_to", -1, y0] << ["line_to", w + 1, y0] << ["line_to", w + 1, y1]
        end
        ytop = hy + fk / FLOOR_DEPTH
        top_scale = fk * 0.5 / FLOOR_DEPTH
        bot_scale = fk * 0.5
        cx = w * 0.5
        reach = (cx / top_scale / tile).ceil + 2
        shift = (cam / tile).floor
        j = shift - reach
        j += 1 if j.odd?
        while j < shift + reach
          a = j * tile - cam
          b = a + tile
          wedge(cmds, cx + a * top_scale, cx + b * top_scale, cx + b * bot_scale, cx + a * bot_scale, ytop, bottom)
          j += 2
        end
        cmds
      end

      # One column wedge (clockwise), clipped to the slot's width so the path stays small.
      def wedge(cmds, tl, tr, br, bl, ytop, bottom)
        lo = -2.0
        hi = w + 2.0
        return if tr < lo && br < lo
        return if tl > hi && bl > hi

        poly = clip_x([tl, ytop, tr, ytop, br, bottom, bl, bottom], lo, 1.0)
        poly = clip_x(poly, -hi, -1.0)
        return if poly.size < 6

        cmds << ["move_to", poly[0].round(1), poly[1].round(1)]
        i = 2
        while i < poly.size
          cmds << ["line_to", poly[i].round(1), poly[i + 1].round(1)]
          i += 2
        end
      end

      # Sutherland-Hodgman against one vertical edge: keeps sign * x >= edge.
      def clip_x(poly, edge, sign)
        out = []
        n = poly.size / 2
        n.times do |i|
          ax = poly[i * 2]
          ay = poly[i * 2 + 1]
          bx = poly[((i + 1) % n) * 2]
          by = poly[((i + 1) % n) * 2 + 1]
          a_in = sign * ax >= edge
          b_in = sign * bx >= edge
          out << ax << ay if a_in
          if a_in != b_in
            k = (edge * sign - ax) / (bx - ax)
            out << ax + (bx - ax) * k << ay + (by - ay) * k
          end
        end
        out
      end

      # A ring of light runs down the floor from the horizon after every kick.
      def update_waves(t, sync)
        last = sync.count(:kick)
        kicks = sync.hits(:kick)
        @waves.each_with_index do |pair, n|
          idx = last - 1 - n
          age = idx >= 0 ? sync.t - kicks[idx].time : 9.0
          if age > 0.7
            next unless @shown.delete(pair[0])

            set(pair[0], { height: 0 })
            set(pair[1], { height: 0 })
            next
          end
          z = FLOOR_DEPTH * (1.0 - age / 0.7)**1.6 + 0.6
          y = @hy + @fk / z
          band = [@fk / z - @fk / (z + 0.9), 1.0].max
          a = (150 * (1.0 - age / 0.7)).round.clamp(0, 255)
          glow = [140, 240, 255]
          set(pair[0], { top: (y - band).round(1), height: band.round(1), fill: { gradient: [glow + [0], glow + [a]], angle: 0 } })
          set(pair[1], { top: y.round(1), height: (band * 0.6).round(1), fill: { gradient: [glow + [a], glow + [0]], angle: 0 } })
          @shown[pair[0]] = true
        end
      end

      # ---- the sine scroller ---------------------------------------------------------------

      # Pool slot k always shows text columns k, k + pool, k + 2 pool..., so as the text moves
      # only the slot that wraps round gets a new path; the rest just move.
      def update_scroller(t, sync, kick, snare)
        pu = PITCH * u
        travel = (t + LEAD_IN) * SPEED * u
        first = ((travel - w) / pu).floor
        level = (kick * 4).round
        burst = t - BURST
        split = burst.positive? ? [(burst * 8).floor + 1, 4].min : 0
        key = level * 8 + split
        ride = T.lead_pitch(sync.t)
        centre = h * 0.335 - (ride - 74.0) * 2.6 * u
        amp = (40 + 10 * Math.sin(t * 0.9)) * u
        omega = t * 3.1
        hue_t = t * 0.21
        white = snare * 0.85
        lift = 3.5 * pu
        jolt = @jolt * 7 * u
        ncols = @cols.size
        flat = @flat
        @pool.times do |k|
          c = first + ((k - first) % @pool)
          x = w + c * pu - travel
          inside = c >= 0 && c < ncols
          mask = inside ? @cols[c] : 0
          slot = @slots[k]
          if slot[0] != c || slot[1] != key
            change_paths(k, c, mask, level, split, pu, slot[0] != c)
            slot[0] = c
            slot[1] = key
          end
          next if mask.zero?

          calm = inside ? 1.0 - 0.7 * flat[c] : 1.0
          y = centre + amp * calm * Math.sin(x * 0.0082 / u + omega) - lift
          if burst.positive?
            paint_burst(k, c, x, y, burst, hue_t, white, kick, t)
          else
            x += jolt * (T.noise(c * 3 + @snares * 131) * 2 - 1) if jolt > 0.05
            paint_column(k, c, x, y, hue_t, white, kick, t)
          end
        end
      end

      # The closing snare fill blows the scroller apart toward the viewer: each column flies
      # out from the middle of the screen as it grows (a perspective push), tumbles, spreads
      # its rows, punches bigger on every fill hit and hangs in the white beam before it fades.
      def paint_burst(k, c, x, y, tau, hue_t, white, kick, t)
        r1 = T.noise(c)
        r2 = T.noise(c + 7919)
        r3 = T.noise(c + 104_729)
        grow = smooth((tau - 0.1 * r1) / 0.42)
        s = 1.0 + (1.0 + 1.5 * r3) * grow + 0.6 * @punch
        cx = w * 0.5
        cy = h * 0.32
        bx = cx + (x - cx) * s + (r1 - 0.5) * 200 * u * tau
        by = cy + (y - cy) * s - (90 + 230 * r2) * u * tau + 560 * u * tau * tau
        by -= @lift * (0.6 + 0.8 * r1) * u
        turn = ((r2 - 0.5) * 700 * tau).round(1)
        fade = 1.0 - smooth((tau - 0.3) / 0.2)
        paint_column(k, c, bx, by, hue_t, white, kick, t, turn, s.round(3), fade)
      end

      # Golden words sit one size up; every square grows a little on the kick, so the text stays
      # a dot matrix. When a kick would shrink the gap to a hairline, the squares fuse for those
      # frames instead, so a bright chrome bar never shows through as a seam inside a letter.
      def change_paths(k, c, mask, level, split, pu, new_column)
        size = T.golden?(c) ? GOLD_SQUARE + 0.14 * level : SQUARE + 0.3 * level
        size = PITCH + FUSE if PITCH - size < SEAM
        path = T.column_path(mask, size * u, pu, 1.0, 1.0 + 0.3 * split)
        set(@face[k], { shape_commands: path })
        return unless @rich

        set(@extrude[k], { shape_commands: path })
        set(@reflect[k], { shape_commands: T.column_path(mask, (SQUARE + 0.2) * u, pu, -SQUASH) }) if new_column
      end

      def paint_column(k, c, x, y, hue_t, white, kick, t, turn = nil, scale = 1.0, fade = 1.0)
        col = T.column_colour(c, (x / w * 0.85 - hue_t) % 1.0)
        if T.golden?(c)
          spec = (0.5 + 0.5 * Math.cos(c * 0.26 - t * 14.0))**8
          light = T.mix_white(col, 0.3 + 0.7 * spec + white)
          deep = T.mix_white(T.shade(col, 0.88 + 0.12 * spec), 0.15 * spec + white)
          dark = T.shade(col, 0.28 + 0.5 * white)
        else
          light = T.mix_white(col, 0.3 + 0.25 * kick + 0.65 * white)
          deep = T.mix_white(T.shade(col, 0.78), white)
          dark = T.shade(col, 0.2 + 0.5 * white)
        end
        a = (255 * fade).round
        xr = x.round(1)
        face = { left: xr, top: y.round(1), fill: { gradient: [light + [a], deep + [a]], angle: 0 } }
        if turn
          face[:rotate] = turn
          face[:scale] = [scale, scale]
          @rotated = true
        end
        set(@face[k], face)
        return unless @rich

        depth = (3 + 2.5 * kick) * u * scale
        ext = { left: (x + depth).round(1), top: (y + depth * 1.15).round(1), fill: dark + [a] }
        if turn
          ext[:rotate] = turn
          ext[:scale] = [scale, scale]
        end
        set(@extrude[k], ext)
        paint_reflection(k, col, xr, y, t, turn)
      end

      # The scroller upside down on the floor. It vanishes the instant the scroller bursts,
      # since an upright reflection under tumbling cubes would read as a barcode.
      def paint_reflection(k, col, xr, y, t, turn)
        fade = turn ? (1.0 - (t - BURST) * 12).clamp(0.0, 1.0) : 1.0
        return if fade.zero? && @reflect_gone[k]

        @reflect_gone[k] = fade.zero?
        ry = @hy + (@hy - y - 7 * PITCH * u) * SQUASH + 4 * u
        set(@reflect[k], { left: xr, top: ry.round(1), fill: { gradient: [col + [(90 * fade).round], col + [(18 * fade).round]], angle: 0 } })
      end

      # The closing snare fill, hit by hit. Each hit's response is scaled by its velocity, mapped
      # so the four fill hits (0.55 to 0.91) climb from a tap to a full blow: @punch is the latest
      # hit's decaying swell, @lift the steps the shattered scroller has jumped so far. Where the
      # backbeat lands on the fill's first hit, the fill's own (softer) voice counts.
      def fill_response(sync, since)
        @punch = 0.0
        @lift = 0.0
        return unless since >= 0.0

        now = sync.t
        vels = {}
        sync.hits_between(:snare, now - since - 1e-6, now + 1e-9).each do |h|
          vels[h.time] = vels[h.time] ? [vels[h.time], h.vel].min : h.vel
        end
        vels.each do |time, vel|
          k = ((vel - 0.43) / 0.48).clamp(0.0, 1.0)**1.3
          dt = now - time
          @punch = [@punch, k * Math.exp(-dt / 0.07)].max
          @lift += k * FILL_LIFT * smooth(dt / 0.06)
        end
      end

      def smooth(x)
        x = x.clamp(0.0, 1.0)
        x * x * (3 - 2 * x)
      end
    end
  end
end
