# frozen_string_literal: true

require_relative "../dots_shapes"
require_relative "../dots_roll"
require_relative "../dots_light"

# The breakdown: a cloud of glowing dots condenses into a sphere around a faint glow, streams
# into a torus, winds into a double helix that tips over and unwinds into a flat ladder, which
# writes SHOES letter by letter in extruded voxels. Over the riser the word spins into a galaxy
# that the snare roll ratchets shut, hit by hit, into one blinding point on the downbeat.
#
# Every frame the dots are depth sorted and handed to the ovals in paint order, so drawable k
# always shows the k-th farthest dot; the brightest dots (the bell sweep, the core) get halos.
module Diem
  module Scenes
    class Dots < Scene
      include DotsLight

      COUNT = 1400
      HALOS = 110
      FINISH = 16.0
      COLLAPSE = 13.5
      # The word whips round once, rigid, and lands face on as the roll doubles to 16ths; then
      # it peels from the middle out into the arms of the galaxy.
      PEEL = 14.0
      SHRINK = 0.62

      # [start, end, from, to, stagger, arc, move, swing]. Each dot travels in `move` of the
      # window, starting at its stagger key (0..1) times the rest; arc is how far it swings out,
      # in 3D about the vertical (:lift) or in the screen plane about the centre (:swirl).
      # Every morph starts on a bell note: 4.0 and 8.0 on bar lines, 11.0 on the B5.
      MORPHS = [
        [0.0, 2.6, :cloud, :sphere, :order, 1.0, 0.55, :lift],
        [4.0, 5.8, :sphere, :torus, :order, 1.0, 0.55, :lift],
        [8.0, 9.6, :torus, :helix, :order, 1.0, 0.55, :lift],
        [11.0, 12.8, :helix, :word, :across, 0.12, 0.4, :lift],
        [PEEL, 14.85, :word, :vortex, :centre, 1.15, 0.6, :swirl],
      ].freeze

      # The helix tips over and unwinds between these times.
      UNWIND = 8.9
      UNWIND_FOR = 1.7
      HELIX_SPIN = 1.25

      DEPTH_LEVELS = 32
      GLOW_LEVELS = 8
      BOKEH_LEVELS = 8
      HALO_BINS = 32
      # Halos are spread over a coarse screen grid so a bright band shows separate twinkles.
      CELLS_X = 16
      CELLS_Y = 9
      PER_CELL = 2

      # One far-to-near ramp per shape; a dot's colour travels from one to the next with it.
      RAMPS = [
        [[44, 22, 104], [104, 74, 236], [206, 112, 226], [255, 196, 92], [255, 242, 214]],   # sphere: violet to gold
        [[14, 26, 92], [36, 92, 226], [0, 204, 255], [120, 255, 214], [236, 255, 250]],     # torus: ice
        [[64, 10, 58], [178, 20, 104], [255, 62, 150], [255, 146, 92], [255, 234, 204]],    # helix: ruby to ember
        [[44, 22, 104], [118, 80, 240], [214, 120, 224], [255, 201, 77], [255, 246, 222]],  # word: violet to gold
      ].freeze
      HUE = { cloud: 0, sphere: 0, torus: 1, helix: 2, word: 3 }.freeze
      HUE_STEPS = 5
      HUES = (RAMPS.size - 1) * HUE_STEPS + 1

      SWEEPS = [[0.0, -1.0, 0.0], [0.8, -0.6, 0.0], [-0.7, -0.7, 0.2], [1.0, 0.1, 0.3],
                [-1.0, 0.2, 0.0], [0.4, -0.7, 0.6], [0.0, -0.8, -0.6], [-0.6, -0.5, -0.6]].map do |v|
        l = Math.sqrt(v.sum { |c| c * c })
        v.map { |c| c / l }
      end.freeze

      def build
        @n = [(COUNT * density).round, 60].max
        @nh = [[(HALOS * density).round, 8].max, @n].min
        @roll = DotsRoll.new(11.9, FINISH)
        @kicks_before = @roll.kicks(COLLAPSE - 1e-3)
        @p = collapse(PEEL)
        @turn_at_peel = vortex_turn(PEEL)
        build_shapes
        build_tables
        build_drawables
        reset_caches
      end

      def enter
        reset_caches
        @order = (0...@n).to_a
      end

      def update(t, sync)
        t = t.clamp(0.0, FINISH)
        @kick = @roll.pulse(t)
        # The ratchet: every hit clamps the formation in, jolts it round and flashes it, a few
        # frames long so each hit reads as a notch.
        @snap = @roll.pulse(t, 0.07, 0.6)
        @p = collapse(t)
        haze(t)
        place(t)
        glow(t, sync)
        paint(t)
        halos
        light(t, anchor(t), @p, @kick)
      end

      private

      # Collapse progress: mostly a staircase that steps on each snare hit, a little smooth.
      def collapse(t)
        return 0.0 if t <= COLLAPSE

        0.3 * smooth_collapse(t) + 0.7 * @roll.ratchet(t) { |x| smooth_collapse(x) }
      end

      def smooth_collapse(t) = ((t - COLLAPSE) / (FINISH - COLLAPSE)).clamp(0.0, 1.0)

      # The faint glow the sphere condenses around, lit by the first bell.
      def anchor(t)
        return 0.0 if t >= 3.6

        (1.0 - Math.exp(-t / 0.12)) * (0.6 * Math.exp(-t / 1.3) + 0.16) * ((3.6 - t) / 1.4).clamp(0.0, 1.0)
      end

      def reset_caches
        @shown_key = Array.new(@n, -1)
        @shown_size = Array.new(@n, -1.0)
        @shown_halo_key = Array.new(@nh, -1)
        @shown_halo_size = Array.new(@nh, -1)
        @shown_bloom_size = Array.new(@nh, -1)
        @shown_rim = Array.new(@n, -2) # -2 unknown, -1 no rim, else the key it shows
        @halo_parked = Array.new(@nh, false)
        @gone = Array.new(@n, false)
        reset_light
      end

      # ---- setup ------------------------------------------------------------------------------

      def build_shapes
        n = @n
        rng = Random.new(5648)
        @cloud = DotsShapes.cloud(n, rng)
        @sphere = DotsShapes.sphere(n)
        @torus = DotsShapes.torus(n, 0.92, 0.4, [(31 * Math.sqrt(n / 1400.0)).round, 10].max)
        @helix = DotsShapes.helix(n, rng, 1.32, [(22 * [density, 0.5].max).round, 8].max)
        @word = word_from_ladder
        @vortex = DotsShapes.align(DotsShapes.vortex(n, rng), (0...n).to_a,
                                   DotsShapes.reading_order(*@word, side: :across))
        @heat = @vortex[0].map { |r| 0.6 * Math.exp(-r / 0.28) }
        @hues = HUE.transform_values { |k| Array.new(n, k * HUE_STEPS) }
        # The whirlpool runs ice blue at the rim through ruby to a gold core.
        @hues[:vortex] = @vortex[0].map do |r|
          q = (r / 1.3).clamp(0.0, 1.0)
          HUE[:torus] * HUE_STEPS + ((1.0 - q * q * (3 - 2 * q)) * 2 * HUE_STEPS).round
        end
        @hash = Array.new(n) { rng.rand }
        @phase = Array.new(n) { rng.rand * DotsShapes::TAU }
        @rate = Array.new(n) { 0.6 + 1.6 * rng.rand }
        build_delays
        @ax, @ay, @az, @bx, @by, @bz, @x, @y, @z, @glow = Array.new(10) { Array.new(n, 0.0) }
        @sx, @sy, @sd = Array.new(3) { Array.new(n, 0.0) }
        @skey = Array.new(n, 0)
        @hue = Array.new(n, 0)
        @order = (0...n).to_a
        @bins = Array.new(HALO_BINS) { [] }
        @cells = Array.new(CELLS_X * CELLS_Y, 0)
        @picked = []
      end

      # The unwound helix lies along x with its rails above and below, so slot by slot it lines
      # up with the word column by column: each dot only drops or rises into its pixel.
      def word_from_ladder
        word = DotsShapes.word(@n, "SHOES", 0.12, 0.32)
        _kinds, hs, fs, = @helix
        cols = word[0].map { |x| x.round(4) }.uniq.size
        ladder = DotsShapes.columns(hs.map(&:-@), fs, cols)
        letters = DotsShapes.columns(word[0], word[1], cols)
        DotsShapes.align(word, letters, ladder)
      end

      def build_delays
        n = @n
        hash = @hash
        wx = @word[0]
        lo, hi = wx.minmax
        span = hi - lo
        edge = wx.map(&:abs).max
        @delays = {
          order: Array.new(n) { |i| 0.85 * i / n + 0.15 * hash[i] },
          across: Array.new(n) { |i| 0.9 * (wx[i] - lo) / span + 0.1 * hash[i] },
          centre: Array.new(n) { |i| 0.8 * wx[i].abs / edge + 0.2 * hash[i] },
        }
      end

      # Fills by [hue][depth level][glow level]. Levels past DEPTH_LEVELS are dots nearer than
      # the formation (the opening nebula, the arcs of a morph): out of focus, so wide and faint.
      # Halos keep the dot's own saturated hue, so glow reads as coloured light, never as grey.
      # Bokeh discs stay saturated too (violet, magenta, teal from the middle of the ramp), with
      # a faint body and a brighter rim, the way an out-of-focus highlight looks through a lens.
      def build_tables
        @fills = []
        @rims = []
        @halo_fills = []
        @bloom_fills = []
        HUES.times do |hq|
          hue = hq.fdiv(HUE_STEPS)
          (DEPTH_LEVELS + BOKEH_LEVELS).times do |d|
            depth = [d.fdiv(DEPTH_LEVELS - 1), 1.0].min
            blur = d < DEPTH_LEVELS ? 0.0 : (d - DEPTH_LEVELS + 1).fdiv(BOKEH_LEVELS)
            base = blur.positive? ? ramp(hue, 0.5 - 0.15 * blur) : ramp(hue, depth)
            halo = ramp(hue, 0.42 + 0.4 * depth)
            GLOW_LEVELS.times do |g|
              k = g.fdiv(GLOW_LEVELS - 1)
              if blur.positive?
                @fills << wc(Palette.mix(base, [255, 255, 255], k * 0.25), (0.17 + 0.12 * k) * (1.0 - 0.4 * blur)).freeze
                rim = Palette.mix(ramp(hue, 0.62 - 0.1 * blur), [255, 255, 255], k * 0.35)
                @rims << wc(rim, (0.28 + 0.3 * k) * (1.0 - 0.45 * blur)).freeze
              else
                c = Palette.mix(base, [255, 255, 255], k * 0.7)
                @fills << wc(c, (0.3 + 0.62 * depth**1.3 + 0.35 * k).clamp(0.0, 1.0)).freeze
                @rims << nil
              end
              soft = (0.55 + 0.45 * depth) * (1.0 - blur)**2
              @halo_fills << wc(halo, (0.015 + 0.07 * k) * soft).freeze
              @bloom_fills << wc(Palette.mix(halo, base, 0.4), (0.015 + 0.1 * k) * soft).freeze
            end
          end
        end
      end

      # The colour at depth x (0 far, 1 near) for a hue between two shapes' ramps.
      def ramp(hue, x)
        a = [hue.floor, RAMPS.size - 2].min
        Palette.mix(ramp_of(RAMPS[a], x), ramp_of(RAMPS[a + 1], x), hue - a)
      end

      def ramp_of(stops, x)
        f = x * (stops.size - 1)
        k = [f.floor, stops.size - 2].min
        Palette.mix(stops[k], stops[k + 1], f - k)
      end

      def build_drawables
        @dots = []
        @halos = []
        @blooms = []
        draw do
          nostroke
          # Two opaque halves meeting in a soft haze across the middle (tinted by the pad chord,
          # see DotsLight#haze).
          mid = Palette.rgb(HAZE_TOP_MID)
          @haze_top = rect(0, 0, w, h / 2, fill: gradient(Palette.rgb(SKY_TOP), mid, angle: 0), strokewidth: 0)
          @haze_bottom = rect(0, h / 2, w, h - h / 2, fill: gradient(mid, Palette.rgb(SKY_BOTTOM), angle: 0), strokewidth: 0)
        end
        @n.times.each_slice(250) do |slice|
          draw do
            nostroke
            slice.each { @dots << oval(-50, -50, 2, 2, fill: Palette.rgb(Palette::VIOLET, 0.0), strokewidth: 0) }
          end
          breathe
        end
        draw do
          nostroke
          @nh.times { @halos << oval(-50, -50, 4, 4, fill: Palette.rgb(Palette::GOLD, 0.0), strokewidth: 0) }
          @nh.times { @blooms << oval(-50, -50, 4, 4, fill: Palette.rgb(Palette::GOLD, 0.0), strokewidth: 0) }
        end
        build_light
      end

      # ---- motion -----------------------------------------------------------------------------

      def place(t)
        morph = MORPHS.find { |t0, t1, *| t >= t0 && t < t1 }
        if morph
          t0, t1, from, to, stagger, arc, move, swing = morph
          pose(from, t, @ax, @ay, @az)
          pose(to, t, @bx, @by, @bz)
          local = (t - t0) / (t1 - t0)
          if swing == :swirl
            swirl(local, @hues[from], @hues[to], @delays[stagger], arc, move)
          else
            blend(local, @hues[from], @hues[to], @delays[stagger], arc, move)
          end
        else
          last = MORPHS.reverse.find { |t0, *| t >= t0 }
          shape = last ? last[3] : :cloud
          pose(shape, t, @x, @y, @z)
          @hue.replace(@hues[shape])
        end
      end

      # Each dot eases from A to B in its own slice of the window, swinging out on an arc.
      def blend(local, hue_a, hue_b, delay, arc, move)
        n = @n
        hue = @hue
        ax = @ax
        ay = @ay
        az = @az
        bx = @bx
        by = @by
        bz = @bz
        x = @x
        y = @y
        z = @z
        hash = @hash
        wait = 1.0 - move
        i = 0
        while i < n
          e = (local - wait * delay[i]) / move
          e = e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e)
          e = e * e * e * (e * (e * 6.0 - 15.0) + 10.0)
          ha = hue_a[i]
          hue[i] = ha + ((hue_b[i] - ha) * e).round
          px = ax[i] + (bx[i] - ax[i]) * e
          py = ay[i] + (by[i] - ay[i]) * e
          pz = az[i] + (bz[i] - az[i]) * e
          lift = Math.sin(Math::PI * e) * arc
          a = lift * (0.5 + 1.1 * hash[i])
          c = Math.cos(a)
          s = Math.sin(a)
          k = 1.0 + 0.22 * lift
          x[i] = (c * px + s * pz) * k
          y[i] = py * k
          z[i] = (c * pz - s * px) * k
          i += 1
        end
      end

      # The same easing, but each dot in flight is wound clockwise about the view axis, the way
      # the galaxy turns, so the frames between the word and the arms show spiral streams.
      def swirl(local, hue_a, hue_b, delay, arc, move)
        n = @n
        hue = @hue
        ax = @ax
        ay = @ay
        az = @az
        bx = @bx
        by = @by
        bz = @bz
        x = @x
        y = @y
        z = @z
        hash = @hash
        wait = 1.0 - move
        i = 0
        while i < n
          e = (local - wait * delay[i]) / move
          e = e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e)
          e = e * e * e * (e * (e * 6.0 - 15.0) + 10.0)
          ha = hue_a[i]
          hue[i] = ha + ((hue_b[i] - ha) * e).round
          px = ax[i] + (bx[i] - ax[i]) * e
          py = ay[i] + (by[i] - ay[i]) * e
          lift = Math.sin(Math::PI * e) * arc
          a = -lift * (0.6 + 0.8 * hash[i])
          c = Math.cos(a)
          s = Math.sin(a)
          k = 1.0 + 0.12 * lift
          x[i] = (c * px - s * py) * k
          y[i] = (s * px + c * py) * k
          z[i] = az[i] + (bz[i] - az[i]) * e
          i += 1
        end
      end

      def pose(shape, t, x, y, z)
        case shape
        when :cloud then pose_cloud(t, x, y, z)
        when :sphere then pose_sphere(t, x, y, z)
        when :torus then pose_torus(t, x, y, z)
        when :helix then pose_helix(t, x, y, z)
        when :word then pose_word(t, x, y, z)
        when :vortex then pose_vortex(t, x, y, z)
        end
      end

      def pose_cloud(t, x, y, z)
        cx, cy, cz = @cloud
        m = matrix(0.12 * t, 0.2, 0.0)
        i = 0
        while i < @n
          rotate_into(m, cx[i], cy[i], cz[i], x, y, z, i)
          i += 1
        end
      end

      def pose_sphere(t, x, y, z)
        sx, sy, sz = @sphere
        m = matrix(0.55 * t, 0.42 + 0.1 * Math.sin(0.6 * t), 0.18)
        i = 0
        while i < @n
          py = sy[i]
          r = 1.0 + 0.015 * Math.sin(6.0 * py - 2.2 * t)
          rotate_into(m, sx[i] * r, py * r, sz[i] * r, x, y, z, i)
          i += 1
        end
      end

      def pose_torus(t, x, y, z)
        us, vs = @torus
        m = matrix(0.32 * t + 0.6, 1.05 + 0.16 * Math.sin(0.5 * t), 0.28)
        flow = 1.15 * t
        spin = 0.12 * t
        i = 0
        while i < @n
          u = us[i] + spin
          v = vs[i] + flow
          rr = 0.92 + 0.4 * Math.cos(v)
          rotate_into(m, rr * Math.cos(u), 0.4 * Math.sin(v), rr * Math.sin(u), x, y, z, i)
          i += 1
        end
      end

      # The helix spins and twists, then tips over onto its side while most of the twist runs
      # out, so by 10.6 s it is a ladder lying across the screen, rails top and bottom. A little
      # twist and a slow wave stay in it, and it leans back in depth, so it still reads as DNA.
      def pose_helix(t, x, y, z)
        _kinds, hs, fs, ja, jr = @helix
        q = ((t - UNWIND) / UNWIND_FOR).clamp(0.0, 1.0)
        q = q * q * (3 - 2 * q)
        twist = 4.2 * (1.0 - q) + 0.28 * q
        radius = 0.44 - 0.02 * q
        stretch = 1.0 + 0.36 * q
        spin = helix_spin(t)
        wave = 0.42 * q
        lean = 0.3 * q * (1.0 - 0.6 * ((t - 11.0) / 1.6).clamp(0.0, 1.0))
        m = matrix(0.0, 0.18 - 0.12 * q + lean, 0.42 + (Math::PI / 2 - 0.42) * q)
        i = 0
        while i < @n
          hh = hs[i]
          th = twist * hh + spin + wave * Math.sin(1.5 * hh - 2.2 * t)
          r = fs[i] * radius
          j = jr[i]
          rotate_into(m, r * Math.cos(th) + j * Math.cos(ja[i]), hh * stretch + j * Math.sin(ja[i]), r * Math.sin(th), x, y, z, i)
          i += 1
        end
      end

      # The spin slows to a stop as the helix unwinds, landing face on (a multiple of a turn).
      def helix_spin(t)
        done = HELIX_SPIN * (UNWIND + UNWIND_FOR / 2)
        return HELIX_SPIN * t - done if t < UNWIND

        s = ((t - UNWIND) / UNWIND_FOR).clamp(0.0, 1.0)
        HELIX_SPIN * (UNWIND + UNWIND_FOR * (s - s**3 + s**4 / 2)) - done
      end

      # The word sways while it forms, its pixels rippling a little, then settles into hard
      # pixels. Over the riser it whips round once as one rigid piece, shrinking so its ends never
      # swing out of focus, and lands face on at PEEL; from there it turns with the galaxy.
      def pose_word(t, x, y, z)
        wx, wy, wz = @word
        settle = ((t - 12.6) / 0.5).clamp(0.0, 1.0)
        ripple = 0.045 - 0.032 * settle * settle * (3 - 2 * settle)
        yaw = 0.2 * Math.sin(0.85 * (t - 12.0))
        pitch = 0.1 * Math.sin(0.6 * t)
        roll = 0.03 * Math.sin(0.7 * t) - 0.07 * @snap
        scale = 1.0 - 0.07 * @snap
        push = 0.3
        if t >= PEEL
          yaw = pitch = 0.0
          push = 0.15
          roll = -(vortex_turn(t) - @turn_at_peel) / 1.4
          scale = SHRINK
        elsif t > COLLAPSE
          q = (t - COLLAPSE) / (PEEL - COLLAPSE)
          e = q * q * (3 - 2 * q)
          yaw = yaw * (1.0 - e) + DotsShapes::TAU * q * q * q * (4.0 - 3.0 * q)
          pitch *= 1.0 - e
          roll *= 1.0 - e
          push *= 1.0 - 0.5 * e
          scale *= 1.0 - (1.0 - SHRINK) * e
        end
        m = matrix(yaw, pitch, roll)
        i = 0
        while i < @n
          px = wx[i]
          rotate_into(m, px * scale, (wy[i] + ripple * Math.sin(2.3 * px - 2.6 * t)) * scale, wz[i] * scale, x, y, z, i)
          z[i] += push
          i += 1
        end
      end

      # How far the galaxy has turned: a steady spin, a surge as the collapse closes, and a
      # shove on every snare hit.
      def vortex_turn(t)
        return 0.0 if t <= COLLAPSE

        0.9 * (t - COLLAPSE) + 11.0 * @p**3 + 0.4 * (@roll.kicks(t, 0.05) - @kicks_before)
      end

      # A three-armed whirlpool. It opens nearly face on, so the word peels straight into its
      # arms, then tips back to show its depth. Inner dots orbit a little faster, so the arms
      # wind as it spins up without closing into rings. Every snare hit kicks it inward and
      # shoves the spin, and the radius steps down hit by hit to nothing on the downbeat.
      def pose_vortex(t, x, y, z)
        r0s, th0s, ys = @vortex
        p = @p
        s = (1.0 - p**2.8) * (1.0 - 0.14 * @snap) * 1.05
        turn = vortex_turn(t)
        tip = ((t - 14.3) / 0.9).clamp(0.0, 1.0)
        tip = tip * tip * (3 - 2 * tip)
        m = matrix(0.0, 1.28 - 0.38 * tip + 0.25 * p * p, 0.25 + 0.5 * p)
        i = 0
        while i < @n
          r0 = r0s[i]
          r = r0 * s
          th = th0s[i] + turn / (1.0 + 0.35 * r0)
          rotate_into(m, r * Math.cos(th), ys[i] * s, r * Math.sin(th), x, y, z, i)
          i += 1
        end
      end

      # yaw about y, then pitch about x, then roll about the view axis, as nine numbers.
      def matrix(yaw, pitch, roll)
        cy = Math.cos(yaw)
        sy = Math.sin(yaw)
        cp = Math.cos(pitch)
        sp = Math.sin(pitch)
        cr = Math.cos(roll)
        sr = Math.sin(roll)
        [cr * cy - sr * sp * sy, -sr * cp, cr * sy + sr * sp * cy,
         sr * cy + cr * sp * sy, cr * cp, sr * sy - cr * sp * cy,
         -cp * sy, sp, cp * cy]
      end

      def rotate_into(m, px, py, pz, x, y, z, i)
        x[i] = m[0] * px + m[1] * py + m[2] * pz
        y[i] = m[3] * px + m[4] * py + m[5] * pz
        z[i] = m[6] * px + m[7] * py + m[8] * pz
      end

      # ---- light ------------------------------------------------------------------------------

      # A band of light sweeps through the cloud on every bell note; a few dots always sparkle;
      # light bands roll down the sphere; the snare roll flashes the whole formation.
      def glow(t, sync)
        age = sync.since(:bell)
        bell = sync.last(:bell)
        sweeping = bell && age < 1.6
        if sweeping
          dx, dy, dz = sweep_direction(bell.time - 48 * Music::BAR, sync.count(:bell))
          # The front enters at the formation's near edge along the sweep, so the first dots
          # light on the note frame, and the whole formation flashes for a tenth of a second.
          front = near_edge(dx, dy, dz) - 0.04 + 3.27 * age
          fade = bell.vel / 0.6 * (1.0 - age / 1.6)
          flash = age < 0.1 ? 0.3 * bell.vel / 0.6 * (1.0 - age / 0.1)**2 : 0.0
        end
        p = @p
        hot = 0.6 * p * p + (t > 11.9 ? 0.18 * @kick + 0.42 * @snap : 0.0)
        hot += flash if sweeping
        hot += 0.5 * Math.exp(-(t - PEEL) / 0.2) if t >= PEEL
        core = (p * 2.5).clamp(0.0, 1.0)
        ripple = t < 5.0 ? 0.22 * (1.0 - ((t - 3.6) / 1.4).clamp(0.0, 1.0)) * (t / 1.5).clamp(0.0, 1.0) : 0.0
        heat = @heat
        x = @x
        y = @y
        z = @z
        g = @glow
        hash = @hash
        phase = @phase
        rate = @rate
        i = 0
        while i < @n
          s = Math.sin(rate[i] * t + phase[i])
          s *= s
          s *= s
          v = 0.35 * s * s * hash[i] + hot + core * heat[i]
          if ripple > 0.0
            r = Math.sin(5.0 * y[i] - 2.2 * t)
            v += ripple * r * r * r * r if r > 0.0
          end
          if sweeping
            d = front - (x[i] * dx + y[i] * dy + z[i] * dz)
            band = d >= 0.0 ? Math.exp(-4.0 * d) : Math.exp(-(d * 12.0)**2)
            v += band * fade * (0.7 + 0.9 * hash[i])
          end
          g[i] = v > 1.0 ? 1.0 : v
          i += 1
        end
      end

      # The least projection of any dot on the sweep direction: where the band comes in.
      def near_edge(dx, dy, dz)
        x = @x
        y = @y
        z = @z
        lo = 9.0
        i = 0
        while i < @n
          d = x[i] * dx + y[i] * dy + z[i] * dz
          lo = d if d < lo
          i += 1
        end
        lo
      end

      # On the ladder the bells run a pulse along it from left to right, rung by rung.
      def sweep_direction(at, count)
        return [1.0, 0.0, 0.0] if at > 9.9 && at < 11.1

        SWEEPS[count % SWEEPS.size]
      end

      # ---- paint ------------------------------------------------------------------------------

      def paint(t)
        n = @n
        x = @x
        y = @y
        z = @z
        g = @glow
        order = @order
        order.sort_by! { |i| z[i] + i * 1.0e-9 }
        breath = 1.0 + 0.03 * Math.sin(Math::PI * t)
        k_screen = 168.0 * u * breath
        cx = w * 0.5
        cy = h * 0.5
        dots = @dots
        fills = @fills
        shown_key = @shown_key
        shown_size = @shown_size
        ssx = @sx
        ssy = @sy
        ssd = @sd
        skey = @skey
        uu = u / Math.sqrt([density, 1.0].min) # a sparse tile gets bigger dots, so the same light
        hue = @hue
        per_hue = (DEPTH_LEVELS + BOKEH_LEVELS) * GLOW_LEVELS
        rims = @rims
        shown_rim = @shown_rim
        rim_w = [(0.9 * uu).round(1), 0.5].max
        hash = @hash
        cull = vanished
        gone = @gone
        k = 0
        while k < n
          i = order[k]
          if hash[i] < cull
            set(dots[k], PARKED) unless gone[k]
            gone[k] = true
            ssd[i] = -1.0
            k += 1
            next
          end
          gone[k] = false
          pz = z[i]
          pz = 2.6 if pz > 2.6
          persp = 4.2 / (4.2 - pz)
          depth = (pz + 1.25) / 2.5
          gi = g[i]
          if depth > 1.0
            blur = (depth - 1.0) * 1.6
            level = DEPTH_LEVELS - 1 + (blur > 1.0 ? BOKEH_LEVELS : (blur * BOKEH_LEVELS).ceil)
            d = (5.2 + 9.0 * (blur > 1.0 ? 1.0 : blur)) * persp * uu
          else
            depth = 0.0 if depth < 0.0
            level = (depth * (DEPTH_LEVELS - 1)).round
            d = (1.6 + 3.6 * depth) * persp * uu * (1.0 + 0.6 * gi)
          end
          d = 1.25 if d < 1.25
          d = (d * 4.0).round * 0.25
          sx = cx + x[i] * persp * k_screen
          sy = cy - y[i] * persp * k_screen
          key = hue[i] * per_hue + level * GLOW_LEVELS + (gi * (GLOW_LEVELS - 1)).round
          ssx[i] = sx
          ssy[i] = sy
          ssd[i] = d
          skey[i] = key
          props = { left: (sx - d * 0.5).round(1), top: (sy - d * 0.5).round(1) }
          if shown_size[k] != d
            props[:width] = d
            props[:height] = d
            shown_size[k] = d
          end
          if shown_key[k] != key
            props[:fill] = fills[key]
            shown_key[k] = key
            rim = rims[key]
            if rim
              props[:stroke] = rim
              props[:strokewidth] = rim_w if shown_rim[k] < 0
              shown_rim[k] = key
            elsif shown_rim[k] != -1
              props[:strokewidth] = 0
              shown_rim[k] = -1
            end
          end
          set(dots[k], props)
          k += 1
        end
      end

      PARKED = { left: -50, top: -50 }.freeze

      # The share of dots already swallowed by the light in the last third of the collapse.
      def vanished
        q = (@p - 0.7) / 0.3
        return 0.0 if q <= 0.0

        q = 1.0 if q > 1.0
        0.75 * q * q * (3 - 2 * q)
      end

      # Halos go to the brightest dots (the bell band, the core, the strongest sparkles), found
      # by binning glow rather than sorting, at most PER_CELL to a cell of a coarse screen grid.
      def halos
        bins = @bins
        bins.each(&:clear)
        g = @glow
        hash = @hash
        sd = @sd
        sx = @sx
        sy = @sy
        cells = @cells.fill(0)
        fx = CELLS_X / w.to_f
        fy = CELLS_Y / h.to_f
        top = HALO_BINS - 1
        i = 0
        while i < @n
          v = g[i]
          if v > 0.3 && sd[i] >= 0.0
            b = ((v + 0.06 * hash[i]) * top).to_i
            bins[b > top ? top : b] << i
          end
          i += 1
        end
        picked = @picked.clear
        # Over the collapse every dot is hot and the rings carry the glow, so fewer halos.
        want = @p.positive? ? (@nh * (0.6 - 0.45 * @p)).round : @nh
        top.downto(0) do |b|
          break if picked.size >= want

          bins[b].each do |i|
            cx = (sx[i] * fx).to_i.clamp(0, CELLS_X - 1)
            c = cx + CELLS_X * (sy[i] * fy).to_i.clamp(0, CELLS_Y - 1)
            next if cells[c] >= PER_CELL

            cells[c] += 1
            picked << i
            break if picked.size >= want
          end
        end
        @nh.times { |j| j < picked.size ? halo(j, picked[j]) : park_halo(j) }
      end

      # Two soft discs per glowing dot: a wide faint halo and a tighter bloom in the dot's hue.
      def halo(j, i)
        d = @sd[i]
        sx = @sx[i]
        sy = @sy[i]
        key = @skey[i]
        fresh = @shown_halo_key[j] != key
        @shown_halo_key[j] = key
        @halo_parked[j] = false
        hd = [(d * 5.0 + 7.0 * u).round, (34 * u).round].min
        props = { left: (sx - hd * 0.5).round(1), top: (sy - hd * 0.5).round(1) }
        if @shown_halo_size[j] != hd
          props[:width] = props[:height] = hd
          @shown_halo_size[j] = hd
        end
        props[:fill] = @halo_fills[key] if fresh
        set(@halos[j], props)
        bd = [(d * 2.4 + 2.5 * u).round, (16 * u).round].min
        props = { left: (sx - bd * 0.5).round(1), top: (sy - bd * 0.5).round(1) }
        if @shown_bloom_size[j] != bd
          props[:width] = props[:height] = bd
          @shown_bloom_size[j] = bd
        end
        props[:fill] = @bloom_fills[key] if fresh
        set(@blooms[j], props)
      end

      def park_halo(j)
        return if @halo_parked[j]

        @halo_parked[j] = true
        set(@halos[j], { left: -50, top: -50 })
        set(@blooms[j], { left: -50, top: -50 })
      end
    end
  end
end
