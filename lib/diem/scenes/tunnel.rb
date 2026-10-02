# frozen_string_literal: true

require_relative "../tunnel_textures"
require_relative "../tunnel_sign"

module Diem
  module Scenes
    # The climax, bars 72-80, in B minor: a texture-mapped tunnel drawn per pixel by Ruby into a
    # framebuffer, flown at full tilt. Per pixel it is five table reads: depth and angle from
    # tables built once, a mip offset that picks a box-filtered copy of the wall for far pixels
    # (and, on a surge, a copy smeared along the depth), the wall texel at (depth + travel,
    # angle + spin + twist * depth), and a per-frame fog/light table by depth that makes light
    # pulses race down the walls for free. Palette copies answer the music at no cost: the seams
    # throb on the galloping bass, lit cells glint on the bell, flashes wash toward the light.
    # Over it, a thin vector layer: rings on the hats, sparks on the lead, and a 3D block sign
    # that flies in, lands on the beat and blows apart on the snare.
    class Tunnel < Scene
      FROM = 72 * Music::BAR
      LENGTH = 16.5
      STEP = 1.0 / 240           # resolution of the travel/spin tables
      KD = 20.0                  # depth = KD / (radius / frame height), in texels
      DEPTHS = 2048              # depth texels covered by the fog table
      FOG_END = 480              # past this depth the fog table is always black
      SWAP = 8.0                 # the second texture and palette arrive with the crash
      SIGN_IN = 5.5              # on a snare
      SIGN_HOLD = 7.0            # lands on a kick
      SIGN_BURST = 9.5           # breaks on a snare
      ASPECT = 2.35
      SPARK_LIFE = 0.6
      RING_COLOURS = [[150, 250, 255], [210, 255, 230]].freeze
      KALEIDO = 12.0             # bar 78: the walls fold into an eight-way mirror
      PUNCHES = [SIGN_HOLD, SIGN_BURST].freeze
      # travel per frame (texels) at which the walls switch to a copy smeared 4, 8, 16 deep
      BLUR_AT = [3.2, 5.0, 6.4].freeze
      TOP_SPEED = 540.0
      NEAR_SOFT = 30.0           # walls nearer than this read a softened copy

      def build
        plan_frame
        build_tables
        breathe
        bases = [TunnelTextures.hex, TunnelTextures.circuit]
        breathe
        plan_mips
        @tex = TunnelTextures::THEMES.each_with_index.map do |theme, n|
          @mips.flat_map { |bd, ba| TunnelTextures.filtered(bases[n], theme, bd, ba).tap { breathe } }
        end
        @palettes = TunnelTextures::THEMES.map { |th| TunnelTextures.palettes(th).tap { breathe } }
        read_score
        integrate_flight
        @sign = TunnelSign.new
        @faces = [[], [], []]
        draw_all
      end

      # Everything the vector layer may have left on screen goes, so a replay or a seek starts
      # from a clean frame.
      def enter
        @shown = {}
        @ring_ovals.each { |o| set(o, { hidden: true }) }
        @spark_shapes.each { |s| set(s, { shape_commands: [] }) }
        @sign_shapes.each { |s| set(s, { shape_commands: [] }) }
      end

      def update(t, sync)
        @shown ||= {}
        theme = t < SWAP ? 0 : 1
        vpx, vpy = vanishing_point(t)
        travel, spin, twist = flight(t)
        frame(theme, vpx, vpy, travel, spin, twist, lift_at(t), t)
        rings(t, vpx, vpy, theme)
        sparks(t, vpx, vpy, spin, twist)
        sign(t, vpx, vpy, theme)
        captions(t)
      end

      private

      # ---- setup ----------------------------------------------------------------------------

      # Cinemascope: the tunnel fills a 2.35:1 band (320 x 136 pixels, 3 screen px each, fewer
      # in a tile), which keeps the bicubic upscale inside the paint budget and lets the sign
      # break out over the black bars. The framebuffer is a few pixels bigger than the band so
      # the picture can slide by whole screen pixels while the tunnel's centre wanders.
      def plan_frame
        @px = density >= 1.0 ? w / 320.0 : 4.0
        @fw = ((w / @px) / 4).round * 4
        @px = w.fdiv(@fw)
        @fh = (w / ASPECT / @px).round
        @lh = (@fh * @px).round
        @bt = ((h - @lh) / 2.0).round
        @fbw = @fw + 4
        @fbh = @fh + 2
        @ax = (0.2 * @fw).ceil
        @ay = (0.2 * @fh).ceil
        @bw = @fbw + 2 * @ax + 4
        @bh = @fbh + 2 * @ay + 4
        @out = Array.new(@fbw * @fbh)
      end

      # Per pixel of a field bigger than the view: depth and angle in sixteenths of a texel
      # (4096 a turn: 256 texels around) and a dithered depth for the fog lookup.
      def build_tables
        n = @bw * @bh
        @dep = Array.new(n)
        @ang = Array.new(n)
        @fogi = Array.new(n)
        @kal = Array.new(n)
        cx = @bw / 2.0
        cy = @bh / 2.0
        bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        @bh.times do |y|
          dy = y + 0.5 - cy
          @bw.times do |x|
            dx = x + 0.5 - cx
            r = Math.sqrt(dx * dx + dy * dy) / @fh
            d = KD / [r, 1e-3].max
            i = y * @bw + x
            @dep[i] = (d.clamp(0.0, DEPTHS - 1.0) * 16).to_i
            @ang[i] = ((Math.atan2(dy, dx) / (2 * Math::PI)) % 1.0 * 4096).to_i & 4095
            dither = (bayer[(y & 3) * 4 + (x & 3)] - 7.5) / 16.0
            @fogi[i] = (d * (1.0 + dither * 0.04)).round.clamp(0, DEPTHS - 1)
            fold = @ang[i] & 1023
            @kal[i] = (fold < 512 ? fold : 1024 - fold) * 2
          end
        end
        @shade = Array.new(DEPTHS, 0)
      end

      # Which box-filtered copy of the wall each pixel reads. A pixel's footprint on the wall
      # is fixed by its depth: d^2 / (KD * fh) texels along, 256 d / (2 pi KD fh) around. The
      # copy must be at least that wide or far walls alias into static. Motion level m adds a
      # smear along the depth of 1, 4, 8 or 16 texels for the surges, so a wall never moves
      # more than about a third of its pattern between frames without being blurred by it.
      # The nearest walls, where one texel spans several pixels, read a softened copy too, so
      # their stair-steps blur into glow instead of jaggies.
      def plan_mips
        boxes_d = TunnelTextures::DEPTH_BOXES
        boxes_a = TunnelTextures::ANGLE_BOXES
        static = @dep.map do |dq|
          d = dq / 16.0
          fd = d * d / (KD * @fh)
          fa = 256.0 * d / (2 * Math::PI * KD * @fh)
          sd = boxes_d.index { |b| b >= fd * 0.75 } || boxes_d.size - 1
          sa = boxes_a.index { |b| b >= fa * 0.75 } || boxes_a.size - 1
          d < NEAR_SOFT ? [[sd, 1].max, [sa, 1].max] : [sd, sa]
        end
        keys = Array.new(4) { |m| static.map { |sd, sa| [[sd, m].max, sa] } }
        @mips = keys.flatten(1).uniq.sort.map { |di, ai| [boxes_d[di], boxes_a[ai]] }
        slot = @mips.each_with_index.to_h { |(bd, ba), k| [[boxes_d.index(bd), boxes_a.index(ba)], k * TunnelTextures::TEXELS] }
        @moff = keys.map { |ks| ks.map { |key| slot[key] } }
      end

      # Everything the visuals dance to, in scene seconds.
      def read_score
        s = Sync.new(Music.score)
        local = ->(track) { s.hits_between(track, FROM - 0.01, FROM + LENGTH).map { |hit| [hit.time - FROM, hit] } }
        @kicks = local[:kick].map(&:first)
        @snares = local[:snare].map(&:first).uniq
        @backbeats = @snares.select { |tm| ((tm % 1.0) - 0.5).abs < 1e-6 }
        @crashes = local[:crash].map(&:first)
        @bass = local[:bass].map(&:first)
        @bass_vel = local[:bass].map { |_, hit| hit.vel }
        @bells = local[:bell].map(&:first)
        @rings = (local[:ohat].map { |tm, _| [tm, 0] } + local[:hat].select { |tm, _| tm >= KALEIDO }.map { |tm, _| [tm, 1] } +
          PUNCHES.flat_map { |p| [0.0, 0.05, 0.1].map { |dt| [p + dt, 2] } }).sort_by(&:first)
        @leads = local[:lead].map { |tm, hit| [tm, hit.note, hit.vel] }
      end

      # Travel, spin and twist as tables over the scene, integrated at 240 Hz, so any frame is a
      # pure lookup of t. Speed surges on every kick; spin turns lazily in the first half and
      # whips round on every snare in the second; twist coils the far end behind the spin.
      def integrate_flight
        n = (LENGTH / STEP).ceil + 2
        @travel = Array.new(n, 0.0)
        @spin = Array.new(n, 0.0)
        @twist = Array.new(n, 0.0)
        pos = 0.0
        ang = 0.0
        omega = 520.0
        lag = 0.0
        n.times do |i|
          t = i * STEP
          @travel[i] = pos
          @spin[i] = ang
          @twist[i] = twist_at(t, lag)
          pos += speed_at(t) * STEP
          target = t < SWAP ? 520.0 + 280.0 * Math.sin(2 * Math::PI * t / 4) : direction_at(t) * 1640.0
          omega += (target - omega) * [STEP / 0.07, 1.0].min
          lag += (omega - lag) * (STEP / 0.3)
          ang += omega * STEP
        end
      end

      # Texels per second, softly capped so peaks stay under 8 texels a frame (a quarter of the
      # hex pattern's 32-texel period); the smear (BLUR_AT) hides the 16-texel rows whenever
      # they would strobe.
      def speed_at(t)
        v = 160.0 * (1.0 + 0.6 * smooth(10.0, 16.0, t))
        a = since(@kicks, t)
        v += 180.0 * Math.exp(-a / 0.1) if a < 1.0
        a = since(@crashes, t)
        v += 300.0 * Math.exp(-a / 0.25) if a < 3.0
        TOP_SPEED * Math.tanh(v / TOP_SPEED)
      end

      def motion_level(t)
        tpf = speed_at(t) / 60.0
        BLUR_AT.index { |x| tpf < x } || BLUR_AT.size
      end

      # +1 or -1: flips on each backbeat snare after the swap. The 16th roll into the finale
      # does not count, so the scene leaves in one spin.
      def direction_at(t)
        flips = @backbeats.count { |s| s >= SWAP && s <= t }
        flips.even? ? 1.0 : -1.0
      end

      def twist_at(t, lag)
        return 34.0 * smooth(3.0, 6.0, t) * Math.sin(2 * Math::PI * (t - 3.0) / 4) if t < SWAP

        lag * 0.035
      end

      # ---- drawables --------------------------------------------------------------------------

      def draw_all
        ring_count = [(10 * density).ceil, 4].max
        @spark_per_note = [(20 * density).round, 6].max
        draw do
          background rgb(0, 0, 0)
          nofill
          @band = stack(left: 0, top: @bt, width: w, height: @lh) do
            @fb = Framebuffer.new(@app, @fbw, @fbh, left: 0, top: 0,
              width: (@fbw * @px).round, height: (@fbh * @px).round)
            @ring_ovals = Array.new(ring_count) do
              oval(0, 0, 10, stroke: Palette.rgb(Palette::CYAN, 0.0), strokewidth: 2, fill: rgb(0, 0, 0, 0), hidden: true)
            end
            # each streak is a pitch-coloured needle with a white-hot core
            @spark_glows = Array.new(3) { shape(0, 0, fill: Palette.rgb(Palette::CYAN, 0.0), strokewidth: 0) }
            @spark_cores = Array.new(3) { shape(0, 0, fill: Palette.rgb(Palette::CYAN), strokewidth: 0) }
            @spark_shapes = @spark_glows + @spark_cores
          end
          # drawn back to front: extrusion (or edges), then the two front faces
          back = shape(0, 0, fill: Palette.rgb([16, 4, 34]), strokewidth: 0)
          @sign_shapes = [shape(0, 0, fill: Palette.rgb(Palette::GOLD), strokewidth: 0),
                          shape(0, 0, fill: Palette.rgb(Palette::INK), strokewidth: 0), back]
          # the letterbox captions come last, so debris flying out over the bars passes under
          # them, each on a black halo of its own glyphs that keeps the letters clean
          if density >= 1.0
            names = [[:bar, Palette::INK], [:key, Palette::GOLD], [:pixels, Palette::MUTED]]
            @caption_halos = names.to_h { |name, _| [name, shape(0, 0, fill: rgb(0, 0, 0), strokewidth: 0)] }
            @captions = names.to_h { |name, c| [name, shape(0, 0, fill: Palette.rgb(c, 0.85), strokewidth: 0)] }
          end
        end
      end

      # ---- the framebuffer --------------------------------------------------------------------

      def frame(theme, vpx, vpy, travel, spin, twist, lift, t)
        # which part of the big table to show, and where to slide the picture to
        fx = vpx / @px
        fy = vpy / @px
        cxf = @bw / 2.0
        cyf = @bh / 2.0
        ox = (cxf - fx).floor.clamp(0, @bw - @fbw)
        oy = (cyf - fy).floor.clamp(0, @bh - @fbh)
        left = (vpx - (cxf - ox) * @px).round
        top = (vpy - (cyf - oy) * @px).round
        fog_table(t)
        angles = t >= KALEIDO ? @kal : @ang
        pal = @palettes[theme][lift][pulse_at(t) * TunnelTextures::GLINTS + glint_at(t)]
        pixels(@tex[theme], pal, angles, @moff[motion_level(t)], (travel * 16).to_i, spin.to_i, twist.to_i, ox, oy)
        @fb.present(@out)
        pos = [left, top]
        return if @shown[:fb] == pos

        set(@fb.image, { left: left, top: top })
        @shown[:fb] = pos
      end

      # The hot loop: one wall texel per pixel, from the right copy, shaded by the fog table.
      def pixels(tex, pal, ang, moff, du, dv, tw, ox, oy)
        dep = @dep
        fogi = @fogi
        shade = @shade
        out = @out
        bw = @bw
        fbw = @fbw
        k = 0
        y = 0
        rows = @fbh
        while y < rows
          i = (oy + y) * bw + ox
          e = i + fbw
          while i < e
            d = dep[i]
            out[k] = pal[tex[(((((d + du) >> 4) & 255) << 8) | (((ang[i] + dv + ((d * tw) >> 8)) >> 4) & 255)) + moff[i]] | shade[fogi[i]]]
            i += 1
            k += 1
          end
          y += 1
        end
      end

      # Shade 0..15 for every depth: fog that reaches black by about d = 280, where a wall row
      # shrinks to a pixel, so the far end is a clean dark throat; a light band shooting away
      # down the tunnel on each kick, another rushing in at the viewer on each snare. The kick
      # light lives in its band, never in the fog's reach, and the walls dim while the sign holds.
      def fog_table(t)
        reach = 255.0 + 25.0 * smooth(10.0, 16.0, t)
        hold = hold_env(t)
        dim = 1.0 - 0.5 * hold - 0.2 * decay([SIGN_BURST], t, 0.06)
        bands = 1.0 - 0.75 * hold
        top = 11.0 * dim
        ka = since(@kicks, t)
        kc = 55.0 + 1500.0 * ka
        kg = ka < 0.6 ? 5.0 * Math.exp(-ka / 0.25) * bands : 0.0
        sa = since(@snares, t)
        sc = 440.0 - 1250.0 * sa
        sg = sa < 0.34 ? 4.5 * (1.0 - sa / 0.34) * bands : 0.0
        shade = @shade
        d = 0
        while d < FOG_END
          x = d < 20 ? 1.0 : 1.0 - (d - 20) / reach
          s = x > 0.0 ? top * x**1.8 : 0.0
          far = d < 380 ? 1.0 - d / 380.0 : 0.0
          if kg > 0.0
            dist = (d - kc).abs / (0.25 * kc + 6.0)
            s += kg * far * band(dist) if dist < 1.0
          end
          if sg > 0.0 && sc > 0.0
            dist = (d - sc).abs / (0.25 * sc + 8.0)
            s += sg * far * band(dist) if dist < 1.0
          end
          v = s.round
          cap = d < 40 ? 12 : 15
          shade[d] = v > cap ? cap : v
          d += 1
        end
      end

      # A light band's profile: a smooth bump, so its edges fade instead of stepping.
      def band(dist)
        x = 1.0 - dist
        x * x * (3.0 - 2.0 * x)
      end

      # 0..2: the seams throb on every 16th of the galloping bass, accents brighter.
      def pulse_at(t)
        i = (@bass.bsearch_index { |x| x > t + 1e-9 } || @bass.size) - 1
        return 0 if i.negative?

        (@bass_vel[i] * Math.exp(-(t - @bass[i]) / 0.045) * 2.9).floor.clamp(0, 2)
      end

      # 0..2: lit cells glint with the bell, an octave above the lead.
      def glint_at(t)
        a = since(@bells, t)
        a > 1.0 ? 0 : (Math.exp(-a / 0.18) * 2.7).floor.clamp(0, 2)
      end

      # ---- the vector layer -------------------------------------------------------------------

      # Rings that rush out at the viewer: open hats, the closed hats in the last two bars, and
      # a burst where the sign lands and where it breaks. Depth eases exponentially, so a ring
      # grows at a steady rate on screen instead of idling at the centre and then zipping off.
      def rings(t, vpx, vpy, theme)
        pool = @ring_ovals
        used = Array.new(pool.size, false)
        light = TunnelTextures::THEMES[theme][:light]
        @rings.each_with_index do |(tm, kind), j|
          next if tm > t

          life, from = case kind
                       when 0 then [0.6, 300.0]
                       when 1 then [0.4, 300.0]
                       else [0.45, 110.0]
                       end
          a = t - tm
          next if a >= life

          depth = from * (6.0 / from)**(a / life)
          r = KD / depth * @lh
          next if r > w

          slot = j % pool.size
          used[slot] = true
          fade = [a / (life * 0.15), 1.0].min * (1.0 - a / life)**0.5
          col, width, alpha = case kind
                              when 0 then [RING_COLOURS[theme], r * 0.075 * (1.0 - 0.4 * a / life), 1.0]
                              when 1 then [light, r * 0.016, 0.85]
                              else [Palette.mix(light, [255, 255, 255], 0.5), r * 0.05, 1.0]
                              end
          ring_to(pool[slot], slot, vpx, vpy, r, width.clamp(1.5 * u, 30.0 * u), wc(col, fade * alpha))
        end
        used.each_with_index { |on, i| hide_ring(pool[i], i) unless on }
      end

      def ring_to(o, i, x, y, r, width, colour)
        set(o, { left: (x - r).round(1), top: (y - r).round(1), width: (2 * r).round(1), height: (2 * r).round(1),
                 strokewidth: width.round(1), stroke: colour, hidden: false })
        @shown[[:ring, i]] = true
      end

      def hide_ring(o, i)
        return unless @shown[[:ring, i]]

        set(o, { hidden: true })
        @shown[[:ring, i]] = false
      end

      # Each lead note throws a fan of streaks that ride the spinning, twisting walls toward the
      # viewer, coloured by pitch. They are born mid-tunnel and ease out exponentially, so they
      # live on the walls rather than in a knot at the centre.
      def sparks(t, vpx, vpy, spin, twist)
        live = @leads.each_index.select { |j| @leads[j][0] <= t && t - @leads[j][0] < SPARK_LIFE }
        @spark_cores.each_with_index do |core, slot|
          glow = @spark_glows[slot]
          j = live.reverse.find { |n| n % 3 == slot }
          if j.nil?
            next unless @shown[[:spark, slot]]

            set(core, { shape_commands: [] })
            set(glow, { shape_commands: [] })
            @shown[[:spark, slot]] = nil
            next
          end
          tm, note, vel = @leads[j]
          a = t - tm
          cmds, halo = spark_cmds(j, a, vpx, vpy, spin, twist, vel)
          fade = [(1.0 - a / SPARK_LIFE) * 1.6, 1.0].min
          hue = pitch_colour(note)
          set(core, { shape_commands: cmds, fill: wc(Palette.mix(hue, [255, 255, 255], 0.8), fade) })
          set(glow, { shape_commands: halo, fill: wc(Palette.mix(hue, [255, 255, 255], 0.1), fade * 0.8) })
          @shown[[:spark, slot]] = true
        end
      end

      # Two paths per fan: the white cores (a sharp tip just ahead of the head, tapering to the
      # tail) and the coloured bodies around them.
      def spark_cmds(j, a, vpx, vpy, spin, twist, vel)
        rng = Random.new(9000 + j)
        cmds = []
        halo = []
        to_rad = 2 * Math::PI / 4096
        @spark_per_note.times do
          theta = rng.rand * 4096
          speed = 0.75 + rng.rand * 0.5
          born = 95.0 + rng.rand * 30.0
          d = born * (5.0 / born)**[a * speed / SPARK_LIFE, 1.0].min
          tail = d * (1.5 + rng.rand * 0.7)
          phi_h = (theta - spin - d * 16 * twist / 256.0) * to_rad
          phi_t = (theta - spin - tail * 16 * twist / 256.0) * to_rad
          rh = KD / d * @lh
          rt = KD / tail * @lh
          next if rt > w

          half = (rh * 0.011 + 0.9 * u) * vel
          c = Math.cos(phi_h)
          sn = Math.sin(phi_h)
          hx = vpx + rh * c
          hy = vpy + rh * sn
          tip = rh * 0.035 + 3.0 * u
          tx = (vpx + rt * Math.cos(phi_t)).round(1)
          ty = (vpy + rt * Math.sin(phi_t)).round(1)
          needle(cmds, hx, hy, c, sn, half * 0.7, tip * 0.8, tx, ty)
          needle(halo, hx, hy, c, sn, half * 2.2, tip * 1.3, tx, ty)
        end
        [cmds, halo]
      end

      # A kite from the tip, through the two shoulders at the head, to the tail point.
      def needle(out, hx, hy, c, sn, half, tip, tx, ty)
        px = -sn * half
        py = c * half
        out << ["move_to", (hx + c * tip).round(1), (hy + sn * tip).round(1)]
        out << ["line_to", (hx + px).round(1), (hy + py).round(1)]
        out << ["line_to", tx, ty]
        out << ["line_to", (hx - px).round(1), (hy - py).round(1)]
      end

      def pitch_colour(note)
        x = ((note - 68) / 16.0).clamp(0.0, 1.0) * 3
        stops = [Palette::CYAN, Palette::MINT, Palette::GOLD, Palette::MAGENTA]
        k = [x.floor, 2].min
        Palette.mix(stops[k], stops[k + 1], x - k)
      end

      # B MINOR. BECAUSE WE CAN.: emerges from the throat, lands on the 7.0 kick with a punch,
      # hangs over the dimmed tunnel, then breaks over the camera on the 9.5 snare.
      def sign(t, vpx, vpy, theme)
        if t < SIGN_IN || t > SIGN_BURST + 1.6
          return unless @shown[:sign]

          @sign_shapes.each { |s| set(s, { shape_commands: [] }) }
          @shown[:sign] = false
          return
        end
        pose = {
          z: sign_z(t), f: 780.0 * u, vp: [vpx, vpy + @bt], centre: [w / 2.0, h / 2.0],
          yaw: 0.2 * Math.sin(2 * Math::PI * (t - SIGN_IN) / 3.6) * smooth(SIGN_IN, SIGN_HOLD, t),
          roll: 0.07 * Math.sin(2 * Math::PI * t / 2.9),
          burst: t >= SIGN_BURST ? t - SIGN_BURST : nil,
          pull: smooth(SIGN_HOLD - 0.6, SIGN_HOLD, t),
        }
        @sign.project(pose, @faces)
        @sign_shapes.each_with_index { |s, n| set(s, { shape_commands: @faces[n] }) }
        @shown[:sign] = true
        paint_sign(t, theme)
      end

      # Far, it rises out of the throat slowly enough to read; then it accelerates into the
      # 7.0 kick, overshoots toward the camera and springs back.
      def sign_z(t)
        kick = 3.0 * decay(@kicks, t, 0.12)
        if t < SIGN_HOLD
          e = (t - SIGN_IN) / (SIGN_HOLD - SIGN_IN)
          100.0 + 554.0 * (1.0 - e**1.6)
        else
          # rest and overshoot sized so the wide line keeps a margin at the nearest point
          a = t - SIGN_HOLD
          100.0 - 4.0 * a - kick - 22.0 * Math.sin(a * 2 * Math::PI / 0.36) * Math.exp(-a / 0.12)
        end
      end

      def paint_sign(t, theme)
        th = TunnelTextures::THEMES[theme]
        fills = if t >= SIGN_BURST
          debris_fills(t - SIGN_BURST, th)
        else
          sign_fills(theme, th, smooth(SIGN_IN, SIGN_IN + 0.7, t))
        end
        flash = [SIGN_HOLD, SWAP, SIGN_BURST].map { |p| t >= p ? Math.exp(-(t - p) / 0.03) : 0.0 }.max
        flash = 0.0 if flash < 0.05
        key = [theme, t >= SIGN_BURST, fills.flatten.map(&:round), (flash * 10).round]
        return if @shown[:sign_paint] == key

        white = [255, 255, 255]
        fills.each_with_index do |f, n|
          ink = f.map { |c| wc(Palette.mix(c, white, flash * 0.85)) }
          set(@sign_shapes[n], { fill: ink.size == 1 ? ink[0] : { gradient: ink, angle: 0 } })
        end
        @shown[:sign_paint] = key
      end

      # Line one in a gradient, line two in solid bright ink, the extrusion deep; all rise
      # out of the fog colour as the sign emerges.
      def sign_fills(theme, th, fade)
        one, two, back = if theme.zero?
          [[Palette::GOLD, Palette::EMBER], [Palette::INK], [[44, 18, 84]]]
        else
          [[Palette::INK, Palette::CYAN], [Palette::INK], [[64, 14, 28]]]
        end
        haze = Palette.scale(th[:fog], 0.45)
        [one, two, back].map { |cs| cs.map { |c| Palette.mix(haze, c, fade) } }
      end

      # Debris, in the order the shapes take it (edges, lit faces, faces turned away): lit faces
      # warm toward the theme light as they pass the camera, the far sides rim-lit mid-tones,
      # so a tumbling block flickers between bright and dim and is never a hole in the picture.
      def debris_fills(a, th)
        light = th[:light]
        k = (a / 0.7).clamp(0.0, 1.0)
        top = Palette.mix(Palette::INK, light, 0.15 + 0.4 * k)
        bottom = Palette.mix(light, Palette::EMBER, 0.3 + 0.3 * k)
        shadow = Palette.mix(Palette.scale(light, 0.6), Palette::VIOLET, 0.5)
        [[Palette.mix(light, Palette::INK, 0.35)], [top, bottom], [shadow, Palette.scale(shadow, 0.85)]]
      end

      # ---- the black bars --------------------------------------------------------------------

      # Small pixel-font captions in the letterbox: the bar we are in, the key, and the claim.
      def captions(t)
        return unless @captions

        bar = 72 + (t / Music::BAR).floor.clamp(0, 7)
        ps = (2 * u).round(1)
        mid_top = @bt / 2.0 - 3.5 * ps
        mid_bottom = @bt + @lh + (h - @bt - @lh) / 2.0 - 3.5 * ps
        unless @shown[:bar] == bar
          caption(:bar, format("BAR %02d / 96", bar), 18 * u, mid_top, ps)
          @shown[:bar] = bar
        end
        return if @shown[:captions]

        key = "B MINOR   120 BPM"
        caption(:key, key, w - 18 * u - Bitfont.width(key) * ps, mid_top, ps)
        count = @fbw * @fbh
        claim = "#{count} PIXELS A FRAME, EVERY ONE COMPUTED IN RUBY"
        caption(:pixels, claim, (w - Bitfont.width(claim) * ps) / 2.0, mid_bottom, ps)
        @shown[:captions] = true
      end

      def caption(name, text, x, y, ps)
        points = Bitfont.points(text)
        set(@captions[name], { shape_commands: text_cmds(points, x, y, ps) })
        set(@caption_halos[name], { shape_commands: halo_cmds(points, x, y, ps) })
      end

      def text_cmds(points, x, y, ps)
        points.flat_map { |px, py| cell(x + px * ps, y + py * ps, ps, ps) }
      end

      # Every glyph pixel grown by one pixel all round, merged into runs along each row.
      def halo_cmds(points, x, y, ps)
        lit = {}
        points.each { |px, py| (-1..1).each { |dy| (-1..1).each { |dx| lit[[px + dx, py + dy]] = true } } }
        lit.keys.group_by(&:last).flat_map do |py, row|
          xs = row.map(&:first).sort
          runs = xs.slice_when { |a, b| b != a + 1 }
          runs.flat_map { |run| cell(x + run.first * ps, y + py * ps, run.size * ps, ps) }
        end
      end

      def cell(l, tp, cw, ch)
        l = l.round(1)
        tp = tp.round(1)
        r = (l + cw).round(1)
        b = (tp + ch).round(1)
        [["move_to", l, tp], ["line_to", r, tp], ["line_to", r, b], ["line_to", l, b]]
      end

      # ---- time -------------------------------------------------------------------------------

      def flight(t)
        x = (t / STEP).clamp(0.0, @travel.size - 2.0)
        i = x.floor
        f = x - i
        [lerp(@travel, i, f), lerp(@spin, i, f), lerp(@twist, i, f)]
      end

      def lerp(tab, i, f) = tab[i] + (tab[i + 1] - tab[i]) * f

      # The tunnel's far end wanders on a Lissajous path that widens as the climax builds.
      def vanishing_point(t)
        grow = 0.1 + 0.08 * smooth(4.0, 12.0, t)
        [w / 2.0 + w * grow * Math.sin(2 * Math::PI * 0.29 * t + 0.6),
         @lh / 2.0 + @lh * grow * Math.sin(2 * Math::PI * 0.43 * t)]
      end

      # 0..1 while the sign holds the screen: the tunnel dims behind it, stays dim through the
      # break so the flashed blocks pop off a dark wall, and the lights come up mid-flight.
      def hold_env(t)
        t < SIGN_BURST + 0.08 ? smooth(6.6, 7.0, t) : 1.0 - smooth(SIGN_BURST + 0.08, SIGN_BURST + 0.3, t)
      end

      # Palette wash 0..7: a frame or two near white and a hard drop, so a flash reads as an
      # impact rather than a filter. The crashes, a nudge on each kick (not while the sign
      # holds the dimmed screen), a step where the sign lands, the fold into the kaleidoscope,
      # and a white-out into the finale. The break gets none: its light is in the blocks.
      def lift_at(t)
        l = 7.0 * decay(@crashes, t, 0.05)
        l = [l, 1.4 * decay(@kicks, t, 0.08)].max if hold_env(t) < 0.3
        l = [l, 2.4 * decay([SIGN_HOLD], t, 0.07)].max
        l = [l, 7.0 * Math.exp(-(t - KALEIDO) / 0.05)].max if t >= KALEIDO
        l = [l, 7.0 * ((t - 15.4) / 0.6)**2].max if t > 15.4
        l.round.clamp(0, 7)
      end

      def since(times, t)
        last = times.bsearch_index { |x| x > t + 1e-9 }
        i = (last || times.size) - 1
        i.negative? ? 1e9 : t - times[i]
      end

      def decay(times, t, tau)
        a = since(times, t)
        a > tau * 12 ? 0.0 : Math.exp(-a / tau)
      end

      def smooth(a, b, t)
        x = ((t - a) / (b - a)).clamp(0.0, 1.0)
        x * x * (3 - 2 * x)
      end
    end
  end
end
