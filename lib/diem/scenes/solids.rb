# frozen_string_literal: true

require_relative "../solids_meshes"

module Diem
  module Scenes
    # Real-time flat-shaded 3D: a twisting torus knot, a geodesic sphere that spikes on the kick,
    # then the Ruby gem itself, mirrored in a neon floor, with small gems in orbit.
    class Solids < Scene
      include Diem::Solids

      KNOT_END = 8.0
      GEO_END = 16.0
      BOOM = 24.0 # from here the gem explodes on the first kick of every bar
      FILL = 31.5 # the snare fill: the gem flies apart into the next scene
      GEO_FILL = 15.5 # bar 39's snare fill: one ripple spreads and every snare spikes the sphere
      FLOOR = -0.62
      LIFT = 1.25
      GEM_LIFT = 1.75
      GEM_SIZE = 1.85
      CROWN = 24.0 # bar 44, theme A's second half: the orbiting gems rise into a crown
      CROWN_RISE = 1.6
      CROWN_Y = GEM_LIFT + 1.3
      CROWN_R = 1.95
      EYE = [0.0, 1.45, 10.0].freeze
      PITCH = 0.06
      WIRE = [120, 255, 255].freeze
      TIES = 24
      MIRROR_FADE = 0.3 # share of a reflection's alpha lost per unit below the floor
      HERO_MIRROR = 0.42
      HERO_MIRROR_FADE = 0.1
      HERO_RIM = [190.0, 16.0, 70.0].freeze # the chords only tint this, so the gem stays ruby
      CELL = 2.0 # floor grid spacing; the cross lines move one cell per beat

      # For each chord: key brightness (the body keeps the ruby's own hue), specular colour,
      # the light's colour (shafts, horizon) and the rim colour.
      CHORD_LIGHT = {
        am: [1.0, [255, 238, 244], [255, 60, 150], [180.0, 20.0, 60.0]],
        f: [1.06, [255, 222, 160], [255, 176, 60], [170.0, 90.0, 20.0]],
        c: [0.96, [200, 246, 255], [40, 220, 255], [30.0, 130.0, 190.0]],
        g: [1.0, [222, 200, 255], [140, 100, 255], [100.0, 60.0, 190.0]],
      }.freeze

      def build
        setup_geometry
        draw { backdrop }
        breathe
        draw { @refl_pool = pool(@refl_cap) }
        breathe
        draw { floor_layers }
        breathe
        draw { @main_pool = pool(@main_cap) }
        breathe
        draw { overlays }
        @refl = Renderer.new(@refl_pool.map(&:linkable_id), f: @focal, cx: w / 2.0, cy: h / 2.0)
        @main = Renderer.new(@main_pool.map(&:linkable_id), f: @focal, cx: w / 2.0, cy: h / 2.0)
        [@refl, @main].each { |r| r.camera(EYE, PITCH) }
        # opaque faces overlap by half a pixel: no hairline of sky between neighbours (the
        # translucent mirror pool stays exact, or its overlaps would draw a lattice)
        @main.grow = 0.5
        @horizon = @main.project(0.0, FLOOR, -1e4)[1]
        @rays_on = false
        place_static
        warm_up
      end

      # Runs the whole scene dry (nothing posted) a few dozen frames per phase, so YJIT has
      # compiled every hot path before the scene goes on air: no compile hitch at the crash.
      def warm_up
        return unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

        start = Diem::PLAN.find { |name, *| name == "Solids" }[1] * Music::BAR
        sync = Sync.new(Music.score)
        enter
        @dry = true
        [@main, @refl].each { |r| r.dry = true }
        [2.0, 8.05, 11.0, 15.5, 16.05, 18.0, 24.05, 31.7].each do |t0|
          36.times do |k|
            update(t0 + k / 60.0, sync.at(start + t0 + k / 60.0))
            breathe
          end
        end
      ensure
        @dry = false
        [@main, @refl].each { |r| r.dry = false; r.forget }
        forget_shown
      end

      def set(drawable, props)
        super unless @dry
      end

      # Every cache of what is on screen, back to "nothing posted yet".
      def forget_shown
        @rails_shown = nil
        @grid_shown = nil
        @rays_on = false
        @ties_on.fill(false)
        @glint_on&.fill(false)
        enter
      end

      def enter
        @chord = nil
        @light_rgb = nil
        @boom_e = 0.0
        @shown_flash = nil
        @glow_shown = nil
        @stat_shown = nil
        @stat_hidden = nil
        @grid_shown = nil
      end

      def update(t, sync)
        @main.begin_frame
        @refl.begin_frame
        @main.wire_alpha = 0.0
        eye = camera_at(t)
        @main.camera(eye, PITCH)
        @refl.camera(eye, PITCH)
        if t < KNOT_END
          knot_phase(t, sync)
        elsif t < GEO_END
          geo_phase(t, sync)
        else
          gem_phase(t, sync)
        end
        @refl.flush
        @main.flush
        floor(t, sync)
        rails
        rays(t, sync)
        flash(t, sync)
        glints(t, sync)
        horizon_glow(t, sync)
        stats(t)
      end

      private

      # ---- geometry -----------------------------------------------------------------------

      def setup_geometry
        @focal = 1.25 * h
        dens = density.clamp(0.2, 1.0)
        @knot = Knot.new([(92 * dens).round, 30].max, 6, 0.42)
        @geo = Geo.new(dens > 0.6 ? 5 : 3)
        @hero = Diem::Solids.gem(8, seed: 3, crown: 1.5, pavilion: 1.3)
        @small_count = [(6 * dens).round, 3].max
        @smalls = Array.new(@small_count) { |i| Diem::Solids.gem(6, seed: 20 + i, crown: 1.2) }
        @disp = Array.new(@geo.count, 0.0)
        ripple_tables
        spike_tables
        fill_tables
        @knot_out = Shards.new(@knot.mesh, knot_at(KNOT_END), seed: 11, spread: 1.0)
        @knot_in = Shards.new(@knot.mesh, knot_at(1.3), seed: 12)
        @geo_in = Shards.new(@geo.mesh, @geo.mesh.rest, seed: 13, delay: pole_to_pole)
        @geo_out = Shards.new(@geo.mesh, geo_at(GEO_END - 1.0 / 60), seed: 14, spread: 1.3)
        @hero_in = Shards.new(@hero, @hero.rest, seed: 15)
        shades
        k = @knot.mesh.face_count
        g = @geo.mesh.face_count
        @main_cap = ((k + g) * 0.6).round + 40
        @refl_cap = @main_cap
      end

      def knot_at(t)
        knot_deform(t, 0.0)
        @knot.mesh.pos.dup
      end

      # The sphere exactly as the music shapes it at local time t, read from a private Sync.
      def geo_at(t)
        start = Diem::PLAN.find { |name, *| name == "Solids" }[1] * Music::BAR
        geo_live(t, Sync.new(Music.score).at(start + t))
        @geo.mesh.pos.dup
      end

      # Assembly order for the sphere: the north pole locks in first, the south pole last.
      def pole_to_pole
        cen, = @geo.mesh.face_frames
        rnd = Random.new(17)
        Array.new(@geo.mesh.face_count) { |i| ((1.0 - cen[i * 3 + 1]) * 0.42 + rnd.rand * 0.16).clamp(0.0, 1.0) }
      end

      # Angle of every vertex from four ripple origins.
      def ripple_tables
        origins = [[0, 1, 0], [0.8, -0.3, 0.5], [-0.7, 0.2, 0.7], [0.1, -0.9, -0.4]].map { |o| M3.normalize(o.map(&:to_f)) }
        d = @geo.dirs
        @ripple = origins.map do |o|
          Array.new(@geo.count) { |i| Math.acos((d[i * 3] * o[0] + d[i * 3 + 1] * o[1] + d[i * 3 + 2] * o[2]).clamp(-1.0, 1.0)) }
        end
        @wobble = Array.new(@geo.count) { |i| d[i * 3] * 2.1 + d[i * 3 + 1] * 1.3 - d[i * 3 + 2] * 1.7 }
      end

      # Four spike patterns, one per kick of the bar: the twelve icosahedron points, then
      # seeded scatters of the rest.
      def spike_tables
        rnd = Random.new(99)
        n = @geo.count
        icosa = Array.new(n, 0.0)
        @geo.icosa.each { |i| icosa[i] = 1.0 }
        scatter = ->(share, lo) { Array.new(n) { rnd.rand < share ? lo + rnd.rand * (1.0 - lo) : 0.0 } }
        @spikes = [icosa, scatter.(0.18, 0.4), scatter.(0.32, 0.2), scatter.(0.1, 0.7)]
      end

      # Bar 39's fill: its snares (local time, velocity), the spike set each one fires, and a
      # ripple centred on the side of the sphere that faces the camera mid-fill, so the ring
      # spreads towards the silhouette rather than bulging out of it.
      def fill_tables
        start = Diem::PLAN.find { |name, *| name == "Solids" }[1] * Music::BAR
        hits = Sync.new(Music.score).hits_between(:snare, start + GEO_FILL - 1e-6, start + GEO_END)
        # the backbeat doubles the fill's first note: keep the fill's own (softer) velocity
        @fill_hits = hits.group_by { |hh| (hh.time - start).round(4) }.map { |tt, hs| [tt, hs.map(&:vel).min] }.sort
        # many short spikes to few long ones, ending on the twelve points of the star
        @fill_spikes = [@spikes[2], @spikes[1], @spikes[3], @spikes[0]]
        mid = GEO_FILL + 0.2
        r = geo_rot(mid, 0.0)
        eye = camera_at(mid)
        v = [eye[0], eye[1] - LIFT, eye[2]]
        # into object space: the transpose of the rotation (its scale goes with the normalize)
        o = M3.normalize([r[0] * v[0] + r[3] * v[1] + r[6] * v[2], r[1] * v[0] + r[4] * v[1] + r[7] * v[2],
                          r[2] * v[0] + r[5] * v[1] + r[8] * v[2]])
        d = @geo.dirs
        @fill_ripple = Array.new(@geo.count) { |i| Math.acos((d[i * 3] * o[0] + d[i * 3 + 1] * o[1] + d[i * 3 + 2] * o[2]).clamp(-1.0, 1.0)) }
      end

      def shades
        night = Palette::NIGHT.map(&:to_f)
        knot_ramp = ramp([Palette::MAGENTA, Palette::VIOLET, Palette::CYAN, [60, 120, 255], Palette::MAGENTA], 64)
        @knot_shade = Shade.new(ramp: knot_ramp, amb: 0.16, key: M3.normalize([-0.4, 0.8, 0.6]), key_col: [1.05, 1.0, 1.0],
          spec_pow: 28.0, spec: 0.9, rim_col: [40.0, 200.0, 255.0], rim_pow: 2.5, fill_dir: M3.normalize([0.8, -0.4, 0.3]),
          fill_col: [0.35, 0.1, 0.45], fog: 0.09, fog_col: night)
        geo_ramp = ramp([Palette::VIOLET, [170, 90, 255], Palette::MAGENTA, Palette::EMBER, Palette::GOLD], 64)
        @geo_shade = Shade.new(ramp: geo_ramp, amb: 0.22, key: M3.normalize([-0.5, 0.7, 0.55]), key_col: [0.85, 0.82, 0.9], spec_pow: 60.0, spec: 0.7,
          rim_col: [0.0, 210.0, 255.0], rim_pow: 2.2, fill_dir: M3.normalize([0.7, -0.5, 0.2]), fill_col: [0.2, 0.05, 0.4],
          fog: 0.06, fog_col: night)
        @knot_mirror = Shade.new(**shade_opts(@knot_shade).merge(alpha: 0.2, fog: 0.05, fog_col: night))
        @geo_mirror = Shade.new(**shade_opts(@geo_shade).merge(alpha: 0.2, fog: 0.05, fog_col: night))
        ruby = ramp([[34, 0, 8], [96, 0, 22], [176, 6, 44], Palette::RUBY, [250, 60, 96], [255, 112, 124]], 64)
        @hero_shade = Shade.new(ramp: ruby, amb: 0.16, key: M3.normalize([-0.45, 0.75, 0.55]), spec_pow: 70.0, spec: 1.25,
          rim_col: [180.0, 20.0, 60.0], rim_pow: 3.5, fill_dir: M3.normalize([0.75, -0.25, 0.35]),
          fill_col: [0.62, 0.1, 0.16], env: 0.5, env_up: [80.0, 14.0, 40.0], env_down: [120.0, 10.0, 60.0], gradient: true)
        @hero_mirror = Shade.new(**shade_opts(@hero_shade).merge(alpha: 0.3, gradient: false, fog: 0.05, fog_col: night))
        jewels = [Palette::CYAN, Palette::GOLD, Palette::MINT, Palette::VIOLET, Palette::EMBER, Palette::MAGENTA]
        @small_shades = Array.new(@small_count) do |i|
          c = jewels[i % jewels.size]
          Shade.new(ramp: ramp([Palette.scale(c, 0.15), Palette.scale(c, 0.55), c, Palette.mix(c, [255, 255, 255], 0.6)], 32),
            amb: 0.3, spec_pow: 50.0, spec: 1.2, rim_col: Palette.scale(c, 0.6), rim_pow: 2.5, env: 0.4,
            env_up: [60.0, 40.0, 100.0], env_down: [0.0, 0.0, 0.0])
        end
        @small_mirrors = @small_shades.map { |s| Shade.new(**shade_opts(s).merge(alpha: 0.2, fog: 0.05, fog_col: night)) }
      end

      def shade_opts(s)
        %i[ramp amb key key_col spec_pow spec spec_col rim_col rim_pow fill_dir fill_col env env_up env_down]
          .to_h { |k| [k, s.public_send(k)] }
      end

      def ramp(stops, n)
        Array.new(n) do |i|
          x = i.fdiv(n - 1) * (stops.size - 1)
          k = [x.floor, stops.size - 2].min
          Palette.mix(stops[k], stops[k + 1], x - k).map(&:to_f)
        end
      end

      # ---- drawables ----------------------------------------------------------------------

      def pool(n)
        Array.new(n) { shape(left: 0, top: 0, strokewidth: 0, stroke: rgb(0, 0, 0, 0), fill: rgb(0, 0, 0, 0)) }
      end

      def backdrop
        nostroke
        @sky = rect(0, 0, w, h, fill: gradient(Palette.rgb([4, 3, 12]), Palette.rgb([44, 12, 66]), angle: 0), strokewidth: 0)
        @ground = rect(0, h / 2, w, h / 2, fill: gradient(Palette.rgb([22, 7, 40]), Palette.rgb([3, 2, 8]), angle: 0), strokewidth: 0)
        rnd = Random.new(5)
        @stars = Array.new((80 * density).round) do
          s = (rnd.rand < 0.15 ? 2.0 : 1.2) * u
          rect(rnd.rand * w, rnd.rand * h * 0.4, s, s, fill: Palette.rgb(Palette::INK, 0.25 + rnd.rand * 0.6), strokewidth: 0)
        end
        @glow = rect(0, 0, w, 10, fill: gradient(rgb(0, 0, 0, 0), Palette.rgb(Palette::MAGENTA, 0.32), angle: 0), strokewidth: 0)
        @rays = Array.new((8 * density.clamp(0.5, 1.0)).round & ~1) { shape(left: 0, top: 0, strokewidth: 0, fill: rgb(0, 0, 0, 0)) }
        @ray_fills = @rays.map { { gradient: [[0, 0, 0, 0], [0, 0, 0, 0]], angle: 0 } }
        @ray_cmds = @rays.map { |_| [3, 4].to_h { |m| [m, Array.new(m) { |j| [j.zero? ? "move_to" : "line_to", 0.0, 0.0] }] } }
        @ray_xy = Array.new(16, 0.0)
      end

      def floor_layers
        # Filled slivers and plain rects: a stroked path costs the renderer several times more.
        line_paint = gradient(Palette.rgb(Palette::VIOLET, 0.12), Palette.rgb(Palette::MAGENTA, 0.75), angle: 0)
        @rails = shape(left: 0, top: 0, strokewidth: 0, fill: line_paint)
        @ties = Array.new(TIES) { rect(0, 0, w, 1, strokewidth: 0, fill: rgb(0, 0, 0, 0)) }
        @ties_on = Array.new(TIES, false)
        @horizon_line = rect(0, 0, w, [1.5 * u, 1].max, fill: Palette.rgb([255, 120, 200], 0.9), strokewidth: 0)
      end

      def overlays
        @glint_pool = Array.new(5) do
          [star(-50, -50, 4, 10, 2, fill: rgb(255, 255, 255, 0), strokewidth: 0),
           star(-50, -50, 4, 6, 1.5, fill: rgb(255, 255, 255, 0), strokewidth: 0)]
        end
        caption_shade if density >= 0.6
        @stat_num = shape(left: 0, top: 0, strokewidth: 0, fill: Palette.rgb(Palette::CYAN, 0.75))
        @stat_text = shape(left: 0, top: 0, strokewidth: 0, fill: Palette.rgb(Palette::INK, 0.5))
        @flash_rect = rect(0, 0, w, h, fill: rgb(255, 255, 255, 0), strokewidth: 0)
      end

      # A soft dark pad under the polygon counter, so no floor line runs through the letters.
      def caption_shade
        dark = Palette.rgb([4, 2, 10], 0.86)
        clear = Palette.rgb([4, 2, 10], 0.0)
        x1 = (560 * u).round
        top = (h - 52 * u).round
        fade = (26 * u).round
        @caption = [
          rect(0, top, x1, h - top, fill: dark, strokewidth: 0),
          rect(x1, top, (110 * u).round, h - top, fill: gradient(dark, clear, angle: 90), strokewidth: 0),
          rect(0, top - fade, x1, fade, fill: gradient(clear, dark, angle: 0), strokewidth: 0),
        ]
      end

      # Things that only depend on the camera: the horizon, the glow above it, the rails.
      def place_static
        @px = (1.6 * u).round(2)
        @stat_x = 22 * u
        @stat_y = h - 22 * u - 7 * @px
        label = " POLYGONS LIT AND DEPTH-SORTED IN RUBY, THIS FRAME"
        set(@stat_text, { shape_commands: pixel_text(label, @stat_x + 18 * @px, @stat_y) }) if density >= 0.6
        hz = @horizon.round(1)
        @glint_pool.each { |_, small| set(small, { rotate: 45 }) }
        set(@sky, { height: (hz + 1).round(1) })
        set(@ground, { top: hz, height: (h - hz).round(1) })
        set(@glow, { top: (hz - 70 * u).round(1), height: (70 * u).round(1) })
        set(@horizon_line, { top: (hz - 0.75 * u).round(1) })
      end

      # The camera drifts sideways the whole scene and dollies in on the gem.
      def camera_at(t)
        dolly = t > GEO_END ? 1.6 * smooth(((t - GEO_END) / 14.0).clamp(0.0, 1.0)) : 0.0
        [1.1 * Math.sin(t * 0.21), EYE[1] + 0.15 * Math.sin(t * 0.37), EYE[2] - dolly]
      end

      def smooth(e) = e * e * (3.0 - 2.0 * e)

      # Lines along the floor, towards the horizon.
      def rails
        eye = @main.eye
        key = ((eye[0] * 200).round * 4096 + (eye[2] * 200).round) * 4096 + (eye[1] * 200).round
        return if key == @rails_shown

        @rails_shown = key
        cmds = []
        lines = (9 * density.clamp(0.4, 1.0)).round
        base = (eye[0] / CELL).round
        (-lines..lines).each do |i|
          x = (base + i) * CELL
          seg = floor_segment(x, -60.0, x, 12.0)
          sliver(cmds, seg) if seg
        end
        set(@rails, { shape_commands: cmds })
      end

      # Light shafts fanning up from behind the solid, in the colour of the light. They live in
      # the sky only: each wedge is cut at the horizon, and they drift across the upper half,
      # fading out as they reach the horizon at either end. Wide and narrow swap on each chord.
      def rays(t, sync)
        strength, col = ray_light(t, sync)
        if strength < 0.01
          @rays.each { |r| set(r, { shape_commands: [] }) } if @rays_on
          @rays_on = false
          return
        end
        @rays_on = true
        c = @main.project(0.0, t >= GEO_END ? GEM_LIFT : LIFT, 0.0)
        cx = c[0]
        cy = c[1]
        n = @rays.size
        len = 900.0 * u
        swap = t >= GEO_END && %i[f g].include?(@chord) ? 1 : 0
        drift = t * 0.018
        n.times do |i|
          f = ((i + 0.5) / n + drift) % 1.0
          a = Math::PI * (1.0 + f)
          edge = Math.sin(f * Math::PI)
          wide = (i + swap).even?
          half = (wide ? 0.085 : 0.03) * (1.0 + 0.25 * Math.sin(t * 0.9 + i * 2.3))
          al = (strength * edge * (wide ? 78 : 96) * (0.8 + 0.2 * Math.sin(t * 2.0 + i))).round.clamp(0, 255)
          ray(i, cx, cy, a, half, len, al, col)
        end
      end

      # One wedge from (cx, cy), cut to y <= horizon, with its gradient along the ray.
      def ray(i, cx, cy, a, half, len, al, col)
        xy = @ray_xy
        m = clip_sky(cx, cy, cx + Math.cos(a - half) * len, cy + Math.sin(a - half) * len,
          cx + Math.cos(a + half) * len, cy + Math.sin(a + half) * len)
        if m < 3 || al.zero?
          set(@rays[i], { shape_commands: [] })
          return
        end
        cmd = @ray_cmds[i][m]
        x0 = x1 = xy[0]
        y0 = y1 = xy[1]
        m.times do |j|
          x = xy[j * 2]
          y = xy[j * 2 + 1]
          cmd[j][1] = x.round(1)
          cmd[j][2] = y.round(1)
          x0 = x if x < x0
          x1 = x if x > x1
          y0 = y if y < y0
          y1 = y if y > y1
        end
        bw = [x1 - x0, 1.0].max
        bh = [y1 - y0, 1.0].max
        g = @ray_fills[i]
        g[:angle] = (Math.atan2(Math.cos(a) / bw, Math.sin(a) / bh) * 180.0 / Math::PI).round(1)
        from = g[:gradient][0]
        to = g[:gradient][1]
        from[0] = to[0] = col[0].round.clamp(0, 255)
        from[1] = to[1] = col[1].round.clamp(0, 255)
        from[2] = to[2] = col[2].round.clamp(0, 255)
        from[3] = al
        to[3] = 0
        set(@rays[i], { shape_commands: cmd, fill: g })
      end

      # The triangle (ax, ay) (bx, by) (cx, cy) cut to the sky, into @ray_xy. Returns its corners.
      def clip_sky(ax, ay, bx, by, cx, cy)
        hz = @horizon
        xy = @ray_xy
        m = 0
        pts = [ax, ay, bx, by, cx, cy]
        3.times do |j|
          px = pts[j * 2]
          py = pts[j * 2 + 1]
          qx = pts[(j * 2 + 2) % 6]
          qy = pts[(j * 2 + 3) % 6]
          if py <= hz
            xy[m * 2] = px
            xy[m * 2 + 1] = py
            m += 1
          end
          next if (py <= hz) == (qy <= hz)

          k = (hz - py) / (qy - py)
          xy[m * 2] = px + (qx - px) * k
          xy[m * 2 + 1] = hz
          m += 1
        end
        m
      end

      def ray_light(t, sync)
        kick = sync.hit(:kick, 0.25)
        if t < KNOT_END
          # the shafts are the arrival flash clearing, then fall back and build again
          [(0.3 + 0.5 * kick) * (t / 2.0).clamp(0.0, 1.0) + 0.9 * Math.exp(-t / 0.35), [90.0, 120.0, 255.0]]
        elsif t < GEO_END
          # dark while the knot shatters, back as the sphere locks together
          back = ((t - KNOT_END - 0.8) / 0.5).clamp(0.0, 1.0)
          [(0.25 + 0.65 * kick) * back, Palette.mix(Palette::MAGENTA, Palette::GOLD, 0.35)]
        else
          e = ((t - GEO_END) / 0.6).clamp(0.0, 1.0)
          [(0.45 + 0.55 * kick) * e, @light_rgb || [255.0, 230.0, 240.0]]
        end
      end

      # A floor line from (x1, z1) to (x2, z2), cut at the near plane, as two screen points.
      def floor_segment(x1, z1, x2, z2)
        near = 0.35
        a = @main.view_point(x1, FLOOR, z1)
        b = @main.view_point(x2, FLOOR, z2)
        return nil if a[2] > -near && b[2] > -near

        if a[2] > -near || b[2] > -near
          k = (-near - a[2]) / (b[2] - a[2])
          c = [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, -near]
          a[2] > -near ? a = c : b = c
        end
        [screen(a), screen(b)]
      end

      def screen(v)
        iz = @focal / -v[2]
        [(w / 2.0 + v[0] * iz).round(1), (h / 2.0 - v[1] * iz).round(1)]
      end

      # ---- the knot -----------------------------------------------------------------------

      def knot_deform(t, kick)
        @knot.deform(t * 1.3, 0.7 * Math.sin(t * 0.8), 0.12 * Math.sin(t * Math::PI), 0.85 * kick, t * 5.0)
      end

      def knot_rot(t, kick)
        s = 0.7 * (1.0 + 0.045 * kick)
        M3.scale(M3.rot(t * 0.42 + 0.3, 0.35 + 0.45 * Math.sin(t * 0.35), t * 0.22), s)
      end

      def knot_phase(t, sync)
        kick = sync.hit(:kick, 0.18)
        @knot_shade.tone_shift = t * 0.06
        @knot_mirror.tone_shift = t * 0.06
        # out of the arrival flash the shards come in white hot and cool as they lock together
        hot = Math.exp(-t / 0.4)
        @knot_shade.spec = 0.9 + 2.0 * hot
        @knot_shade.amb = 0.16 + 0.55 * hot
        @knot_mirror.alpha = 0.2
        at = [0.0, LIFT, 0.0]
        if t < 1.3
          @knot_in.in(t, dur: 0.85, stagger: 0.45, dist: 7.0)
          draw_shards(@knot_in, knot_rot(t, 0.0), at, @knot_shade, @knot_mirror)
        else
          knot_deform(t, kick)
          rot = knot_rot(t, kick)
          @main.draw(@knot.mesh, rot, at, @knot_shade)
          @refl.draw(@knot.mesh, rot, at, @knot_mirror, mirror_y: FLOOR, fade: MIRROR_FADE)
        end
        @main.wire_alpha = 0.55 * sync.hit(:snare, 0.09)
        @main.wire_col = WIRE
      end

      # ---- the geodesic sphere --------------------------------------------------------------

      # rip: a ripple table, front: the ring's angle from its centre, renv: its height.
      # extra/extra_amp: a second spike set (the fill's snares).
      def geo_deform(t, kick, kicks, front, renv, rip, star = 0.0, extra = nil, extra_amp = 0.0)
        spikes = @spikes[kicks % 4]
        icosa = @spikes[0]
        wob = @wobble
        disp = @disp
        amp = 0.72 * kick
        extra = nil if extra_amp < 0.002
        n = @geo.count
        i = 0
        while i < n
          d = spikes[i] * amp + icosa[i] * star + 0.045 * Math.sin(wob[i] * 2.0 + t * 2.4)
          d += extra[i] * extra_amp if extra
          if renv > 0.002
            x = rip[i] - front
            d += renv * Math.sin(x * 9.0) * Math.exp(-x * x * 3.0)
          end
          disp[i] = d
          i += 1
        end
        @geo.deform(disp, 1.05, t * 0.08)
      end

      def geo_rot(t, kick)
        M3.scale(M3.rot(t * 0.55, 0.4 + 0.2 * Math.sin(t * 0.5), t * 0.17), 1.65 * (1.0 + 0.03 * kick))
      end

      # The sphere as the drums shape it: spikes on the kick, a ripple ring on the snare. On
      # bar 39's fill one low ring spreads from the face turned to the camera, each snare tops
      # it up and fires a spike set as hard as it is hit, the last set being the twelve
      # points; in the last moments the ripple settles and those points thrust out, so the
      # sphere shatters from a star.
      def geo_live(t, sync)
        kick = sync.hit(:kick, 0.16)
        e = smooth(((t - (GEO_END - 0.16)) / 0.15).clamp(0.0, 1.0))
        kicks = sync.count(:kick)
        if t >= GEO_FILL && @fill_hits.any?
          k = 0
          k += 1 while k + 1 < @fill_hits.size && @fill_hits[k + 1][0] <= t + 1e-9
          ht, vel = @fill_hits[k]
          ago = t - ht
          ring = 0.045 + 0.07 * vel * Math.exp(-ago / 0.18)
          spike = 0.85 * vel * Math.exp(-ago / 0.09)
          geo_deform(t, kick, kicks, (t - GEO_FILL) * 3.4, ring * (1.0 - e), @fill_ripple, 0.8 * e, @fill_spikes[k % 4], spike)
        else
          snare = sync.since(:snare)
          env = 0.22 * Math.exp(-snare / 0.45)
          geo_deform(t, kick, kicks, snare * 4.2, env * (1.0 - e), @ripple[sync.count(:snare) % 4], 0.8 * e)
        end
        kick
      end

      # Shards of a mesh in both pools: the reflection shatters and assembles with the solid.
      def draw_shards(shards, rot, at, shade, mirror)
        @main.draw(shards.mesh, rot, at, shade, alpha: shards.alpha)
        return if mirror.alpha < 0.02

        @refl.draw(shards.mesh, rot, at, mirror, alpha: shards.alpha, mirror_y: FLOOR, fade: MIRROR_FADE)
      end

      def geo_phase(t, sync)
        at = [0.0, LIFT, 0.0]
        @geo_shade.spec = 0.7
        @geo_shade.amb = 0.22
        s = t - KNOT_END
        shatter = Math.exp(-s / 0.12)
        @knot_shade.spec = 0.9 + 2.5 * shatter
        @knot_shade.amb = 0.16 + 0.5 * shatter
        # the reflections cross-fade so the two swarms are never both mirrored in full
        if s < 1.25
          @knot_out.out(s, dur: 0.9, stagger: 0.25, dist: 4.5)
          @knot_mirror.alpha = 0.2 * (1.0 - s / 0.7).clamp(0.0, 1.0)
          draw_shards(@knot_out, knot_rot(t, 0.0), at, @knot_shade, @knot_mirror)
        end
        @geo_mirror.alpha = 0.2 * ((s - 0.25) / 0.6).clamp(0.0, 1.0)
        if s < 1.0
          @geo_in.in(s, dur: 0.6, stagger: 0.4, dist: 7.0)
          draw_shards(@geo_in, geo_rot(t, 0.0), at, @geo_shade, @geo_mirror)
        else
          kick = geo_live(t, sync)
          rot = geo_rot(t, kick)
          @main.draw(@geo.mesh, rot, at, @geo_shade)
          @refl.draw(@geo.mesh, rot, at, @geo_mirror, mirror_y: FLOOR, fade: MIRROR_FADE)
        end
        @main.wire_alpha = [0.5 * sync.hit(:snare, 0.09), 0.9 * shatter].max
        @main.wire_col = s < 0.4 ? [255, 236, 250] : WIRE
      end

      # ---- the gem ------------------------------------------------------------------------

      def gem_phase(t, sync)
        s = t - GEO_END
        at = [0.0, LIFT, 0.0]
        gat = [0.0, GEM_LIFT, 0.0]
        if s < 1.3
          # the sphere goes white hot as it breaks: the flash lives in the geometry too
          hot = Math.exp(-s / 0.1)
          @geo_shade.spec = 0.7 + 2.6 * hot
          @geo_shade.amb = 0.22 + 0.7 * hot
          @main.wire_alpha = 0.85 * hot
          @main.wire_col = [255, 240, 250]
          @geo_out.out(s, dur: 1.15, stagger: 0.15, dist: 5.0)
          @geo_mirror.alpha = 0.2 * (1.0 - s / 0.8).clamp(0.0, 1.0)
          draw_shards(@geo_out, geo_rot(t, 0.0), at, @geo_shade, @geo_mirror)
        end
        light(t, sync)
        rot = hero_rot(t, s, sync.hit(:kick, 0.2))
        @hero_mirror.alpha = HERO_MIRROR * ((s - 0.4) / 0.9).clamp(0.0, 1.0)
        if s < 1.35
          @hero_in.in(s + 0.15, dur: 0.85, stagger: 0.5, dist: 5.5)
          @main.draw(@hero_in.mesh, rot, gat, @hero_shade, alpha: @hero_in.alpha, tag: 1)
          refl_hero(@hero_in.mesh, rot, gat, @hero_in.alpha, 0.0)
        else
          mesh, back = hero_pop(t, sync, rot)
          @main.draw(mesh, rot, gat, @hero_shade, tag: 1, back: back, min_area: 5.0)
          refl_hero(mesh, rot, gat, nil, back)
        end
        orbiters(t, s, sync)
      end

      def refl_hero(mesh, rot, at, alpha, back)
        return if @hero_mirror.alpha < 0.02

        @refl.draw(mesh, rot, at, @hero_mirror, alpha: alpha, mirror_y: FLOOR, back: back * 0.6, min_area: 5.0, fade: HERO_MIRROR_FADE)
      end

      # From bar 44 the gem explodes on the first kick of every bar, its facets tumbling, and
      # snaps back with a little overshoot; the other kicks only pop it, closed. Facets bounce
      # off the floor. Returns the mesh and how dark the inner sides of flying facets are drawn
      # (0: solid, back faces culled).
      def hero_pop(t, sync, rot)
        @boom_e = 0.0
        return [@hero, 0.0] if t < BOOM

        d, turn, open = t < FILL ? kick_burst(sync) : fill_burst(t, sync)
        return [@hero, 0.0] if d.abs < 0.004

        @bounce ||= [nil, GEM_LIFT, FLOOR + 0.06]
        @bounce[0] = rot
        @hero_in.burst(d, turn, @bounce)
        [@hero_in.mesh, open && d > 0.02 ? 0.42 : 0.0]
      end

      def kick_burst(sync)
        kick = sync.last(:kick)
        return [0.0, 0.0, false] unless kick

        s = sync.t - kick.time
        if (kick.time % Music::BAR) < 0.01
          e = boom(s)
          @boom_e = e
          [0.7 * e, 0.24 * e, true]
        else
          e = Math.exp(-s / 0.1)
          [0.09 * e, 0.015 * e, false]
        end
      end

      # Out in 60 ms, hang, fall back, overshoot inwards, settle: 0.5 s, one beat.
      def boom(s)
        if s < 0.06
          1.0 - (1.0 - s / 0.06)**3
        elsif s < 0.16
          1.0 + 0.6 * (s - 0.06)
        elsif s < 0.38
          x = (s - 0.16) / 0.22
          1.06 * (1.0 - x * x)
        elsif s < 0.5
          -0.06 * Math.sin((s - 0.38) / 0.12 * Math::PI)
        else
          0.0
        end
      end

      # The last half bar: every snare blows the facets further out, and they never come back.
      def fill_burst(t, sync)
        x = (t - FILL) / (32.0 - FILL)
        pop = 0.25 * sync.hit(:snare, 0.06)
        @boom_e = 1.5 * x
        [0.15 + 1.6 * x * x + pop, 0.1 + 0.9 * x + 0.1 * pop, true]
      end

      def hero_rot(t, s, kick)
        spin = s < 2.0 ? 2.6 * (1.0 - s / 2.0)**3 : 0.0
        whirl = t > 31.0 ? (t - 31.0)**2 * 1.8 : 0.0
        yaw = t * 0.42 + spin * 2.0 + whirl
        # halfway through the dolly the gem bows to the camera: the octagonal table, face on
        bow = smooth(((t - 19.0) / 1.2).clamp(0.0, 1.0)) * smooth(((23.6 - t) / 1.2).clamp(0.0, 1.0))
        lean = 0.36 + 0.06 * Math.sin(t * 0.6) + 0.22 * bow
        M3.scale(M3.turn(yaw, lean, 0.05 * Math.sin(t * 0.43)), GEM_SIZE * (1.0 + 0.022 * kick))
      end

      # The chord colours the specular, the rim, the shafts and the horizon, easing over 0.3 s;
      # the body only gets brighter or darker, so it stays ruby red.
      def light(t, sync)
        song = sync.t
        sym = Music.chord_at(song)[0]
        prev = Music.chord_at(song - Music::BAR)[0]
        e = ((song % Music::BAR) / 0.3).clamp(0.0, 1.0)
        e = e * e * (3 - 2 * e)
        a = CHORD_LIGHT.fetch(prev, CHORD_LIGHT[:am])
        b = CHORD_LIGHT.fetch(sym, CHORD_LIGHT[:am])
        k = a[0] + (b[0] - a[0]) * e
        key = [k, k * 0.96, k * 0.96]
        spec = Palette.mix(a[1], b[1], e)
        rim = Palette.mix(HERO_RIM, Palette.mix(a[3], b[3], e), 0.3)
        snare = sync.hit(:snare, 0.12)
        [@hero_shade, @hero_mirror].each do |sh|
          sh.key_col = key
          sh.spec_col = spec
          sh.rim_col = rim
        end
        @hero_shade.spec = 1.25 + 0.9 * snare + 0.45 * sync.hit(:lead, 0.2)
        @light_rgb = Palette.mix(a[2], b[2], e)
        @chord = sym
      end

      # The orbit turns one gap between gems per bar (or half a gap), phased so that on every
      # downbeat the front of the orbit falls between two gems: none hides the explosion.
      def orbit_phase
        n = @small_count
        gap = TAU / n
        @orbit_w = gap / Music::BAR / [((gap / Music::BAR) / 0.55).round, 1].max
        @orbit_off = Math::PI / 2 - gap / 2 - BOOM * @orbit_w
      end

      def orbiters(t, s, sync)
        arrive = ((s - 0.6) / 2.2).clamp(0.0, 1.0)
        return if arrive <= 0.0

        orbit_phase unless @orbit_w
        k = 1.0 - arrive
        # from bar 44 the ring climbs and closes into a crown over the gem, its stones set
        # alternately high and low; every bar's explosion still throws it wide
        c = smooth(((t - CROWN) / CROWN_RISE).clamp(0.0, 1.0))
        radius = 3.5 + 0.25 * Math.sin(t * 0.9) + 14.0 * k * k * k
        radius += (CROWN_R - radius) * c + 1.6 * @boom_e
        tilt = 0.32 * (1.0 - c) + 0.08 * c
        kick = sync.hit(:kick, 0.2)
        mirror_a = 0.3 * ((s - 1.6) / 1.0).clamp(0.0, 1.0)
        # each note of the harmony lights the next gem round the ring
        sung = sync.count(:lead2) % @small_count
        ring = sync.hit(:lead2, 0.22)
        @small_count.times do |i|
          glow = i == sung ? ring : 0.0
          @small_shades[i].amb = 0.3 + 0.75 * glow
          a = t * @orbit_w + @orbit_off + i * TAU / @small_count + k * 3.0
          x = Math.cos(a) * radius
          z = Math.sin(a) * radius
          y = LIFT + Math.sin(a) * radius * Math.sin(tilt) * 0.45 + 0.15 * Math.sin(t * 1.7 + i)
          y += (CROWN_Y + (i.even? ? 0.2 : -0.12) - y) * c if c.positive?
          rot = M3.scale(M3.turn(t * 1.6 + i, 0.45 + 0.25 * Math.sin(t + i), 0.15 * Math.sin(t * 0.7 + i)), 0.32 * (1.0 + 0.08 * kick + 0.35 * glow))
          @main.draw(@smalls[i], rot, [x, y, z], @small_shades[i], tag: 2)
          @small_mirrors[i].alpha = mirror_a
          @refl.draw(@smalls[i], rot, [x, y, z], @small_mirrors[i], mirror_y: FLOOR) if mirror_a > 0.02
        end
      end

      # ---- floor, flashes, glints -----------------------------------------------------------

      # Cross lines of the floor, one cell per beat towards the viewer: thin rects, brighter and
      # pinker near the viewer, as the stroke gradient they replace.
      def floor(t, _sync)
        phase = (t / Music::BEAT) % 1.0
        cell = CELL
        key = (phase * 120).round
        return if key == @grid_shown

        @grid_shown = key
        hz = @horizon
        thick = [1.2 * u, 1.0].max.round(1)
        TIES.times do |i|
          z = 9.0 - (i - phase) * cell
          seg = floor_segment(-30.0, z, 30.0, z)
          tie = @ties[i]
          if seg.nil? || seg[0][1] > h + 2
            set(tie, { hidden: true }) if @ties_on[i]
            @ties_on[i] = false
            next
          end
          y = seg[0][1]
          x0 = [seg[0][0], 0.0].max
          x1 = [seg[1][0], w.to_f].min
          k = ((y - hz) / (h - hz)).clamp(0.0, 1.0)
          c = Palette.mix(Palette::VIOLET, Palette::MAGENTA, k)
          props = { left: x0.round(1), top: (y - thick / 2).round(1), width: (x1 - x0).round(1), height: thick,
                    fill: wc(c, 0.12 + 0.63 * k) }
          props[:hidden] = false unless @ties_on[i]
          @ties_on[i] = true
          set(tie, props)
        end
      end

      # A floor line as a filled sliver about 1.2 px wide, cut to the slot.
      def sliver(cmds, seg)
        (ax, ay), (bx, by) = seg
        t0 = 0.0
        t1 = 1.0
        dx = bx - ax
        dy = by - ay
        [[-dx, ax + 2.0], [dx, w + 2.0 - ax], [-dy, ay + 2.0], [dy, h + 2.0 - ay]].each do |p, q|
          if p.abs < 1e-9
            return if q.negative?
          else
            r = q / p
            p.negative? ? (t0 = r if r > t0) : (t1 = r if r < t1)
          end
        end
        return if t0 >= t1

        bx = ax + dx * t1
        by = ay + dy * t1
        ax += dx * t0
        ay += dy * t0
        dx = bx - ax
        dy = by - ay
        l = Math.sqrt(dx * dx + dy * dy)
        return if l < 0.5

        o = [0.6 * u, 0.5].max / l
        nx = (-dy * o).round(2)
        ny = (dx * o).round(2)
        cmds.push(["move_to", (ax + nx).round(1), (ay + ny).round(1)], ["line_to", (bx + nx).round(1), (by + ny).round(1)],
          ["line_to", (bx - nx).round(1), (by - ny).round(1)], ["line_to", (ax - nx).round(1), (ay - ny).round(1)])
      end

      # A strobe on the bar line: one frame of near white in the colour of the light, then gone
      # within three frames, so it reads as a flash and never as fog.
      def flash(t, _sync)
        if t >= GEO_END && t < GEO_END + 0.25
          a = strobe(t - GEO_END, 0.95)
          col = Palette.mix([255, 255, 255], @light_rgb || Palette::MAGENTA, 0.12)
        elsif t >= KNOT_END && t < KNOT_END + 0.25
          a = strobe(t - KNOT_END, 0.88)
          col = [225, 245, 255]
        else
          a = 0.0
          col = [255, 255, 255]
        end
        c = wc(col, a)
        return if c == @shown_flash

        @shown_flash = c
        set(@flash_rect, { fill: c })
      end

      def strobe(s, peak)
        frame = 1.0 / 60
        s < frame ? peak : 0.22 * Math.exp(-(s - frame) / 0.02)
      end

      # A live count of the polygons on screen, in the 5x7 font, bottom left.
      def stats(t)
        return if density < 0.6 # unreadable in a tile

        n = t < 0.6 ? 0 : @main.count + @refl.count
        return if n == @stat_shown

        @stat_shown = n
        set(@stat_num, { shape_commands: t < 0.6 ? [] : pixel_text(format("%3d", n), @stat_x, @stat_y) })
        if (t < 0.6) != @stat_hidden
          set(@stat_text, { hidden: t < 0.6 })
          @caption&.each { |r| set(r, { hidden: t < 0.6 }) }
        end
        @stat_hidden = t < 0.6
      end

      # Pixel text as rectangles, one per horizontal run of lit pixels.
      def pixel_text(text, x0, y0)
        px = @px
        rows = Hash.new { |hh, k| hh[k] = [] }
        Bitfont.points(text).each { |x, y| rows[y] << x }
        cmds = []
        rows.each do |y, xs|
          xs.sort!
          start = prev = xs.first
          (xs[1..] + [nil]).each do |x|
            next prev = x if x && x == prev + 1

            l = (x0 + start * px).round(1)
            r = (x0 + (prev + 1) * px).round(1)
            t = (y0 + y * px).round(1)
            b = (y0 + (y + 1) * px).round(1)
            cmds.push(["move_to", l, t], ["line_to", r, t], ["line_to", r, b], ["line_to", l, b])
            start = prev = x
          end
        end
        cmds
      end

      # The glow above the horizon takes the colour of the light.
      def horizon_glow(t, sync)
        col = t >= GEO_END && @light_rgb ? @light_rgb : Palette::MAGENTA
        boost = 1.0 + 0.5 * sync.hit(:kick, 0.2)
        boost += 1.8 * Math.exp(-(t - KNOT_END) / 0.2) if t >= KNOT_END && t < KNOT_END + 1.5
        boost += 1.5 * Math.exp(-t / 0.35) if t < 1.5
        c = [col[0].round, col[1].round, col[2].round, (82 * boost).round.clamp(0, 255)]
        return if c == @glow_shown

        @glow_shown = c
        set(@glow, { fill: { gradient: [[c[0], c[1], c[2], 0], c], angle: 0 } })
      end

      # Four-point sparkles on the four facets that catch the most light, and a fifth, bigger
      # one that flares on each note of the lead, stepping to another facet with every note.
      def glints(t, sync)
        n = t >= GEO_END + 0.9 ? top_facets : 0
        lead = t >= GEO_END + 0.9 ? sync.hit(:lead, 0.2) : 0.0
        @glint_pool.each_with_index do |(big, small), gi|
          if gi < 4
            j = gi < n && @top_spec[gi] > 0.55 ? @top[gi] : nil
            g = j ? (@top_spec[gi] - 0.5).clamp(0.0, 1.0) : 0.0
            size = (22.0 + 40.0 * g) * u * (0.75 + 0.25 * Math.sin(t * 23.0 + gi * 1.7))
            al = 0.35 + 0.65 * g
          else
            j = n.positive? && lead > 0.04 ? @top[sync.count(:lead) % [n, 6].min] : nil
            size = (40.0 + 70.0 * lead) * u
            al = lead.clamp(0.0, 1.0)
          end
          glint(big, small, gi, j, size, al)
        end
      end

      def glint(big, small, gi, j, size, al)
        @glint_on ||= Array.new(@glint_pool.size, false)
        unless j
          return unless @glint_on[gi]

          set(big, { fill: [255, 255, 255, 0] })
          set(small, { fill: [255, 255, 255, 0] })
          @glint_on[gi] = false
          return
        end
        x = @main.it_cx[j].round(1)
        y = @main.it_cy[j].round(1)
        a = (255 * al).round.clamp(0, 255)
        set(big, { left: x, top: y, outer: size.round(1), inner: (size * 0.09).round(1), fill: [255, 255, 255, a] })
        set(small, { left: x, top: y, outer: (size * 0.45).round(1), inner: (size * 0.07).round(1), fill: [255, 255, 255, (a * 0.8).round] })
        @glint_on[gi] = true
      end

      # The six brightest hero facets this frame, brightest first, into @top / @top_spec
      # (preallocated: an insertion pass, no sorting or new arrays). Returns how many.
      def top_facets
        @top ||= Array.new(6, 0)
        @top_spec ||= Array.new(6, 0.0)
        top = @top
        best = @top_spec
        r = @main
        spec = r.it_spec
        tag = r.it_tag
        m = 0
        i = 0
        n = r.count
        while i < n
          sp = spec[i]
          if tag[i] == 1 && sp > 0.3 && (m < 6 || sp > best[5])
            k = m < 6 ? m : 5
            while k.positive? && best[k - 1] < sp
              best[k] = best[k - 1]
              top[k] = top[k - 1]
              k -= 1
            end
            best[k] = sp
            top[k] = i
            m += 1 if m < 6
          end
          i += 1
        end
        m
      end
    end
  end
end
