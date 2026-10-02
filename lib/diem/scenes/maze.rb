# frozen_string_literal: true

require_relative "../raycaster"
require_relative "../maze_map"
require_relative "../maze_flight"
require_relative "../maze_title"
require_relative "../maze_radar"
require_relative "../maze_gems"
require_relative "../maze_shoes"

module Diem
  module Scenes
    # Bars 56-72. WOLFENSHOES 3D: a real raycaster in Shoes. 240 rays a frame through a hand-drawn
    # maze; every wall strip is a gradient rect, every planar wall's neon trim one quad, with a
    # glossy reflection and a roof that knows where the sky begins. A sliding door that opens on
    # the crash, round gold columns, billboard orbs, spinning shoes and rubies clipped against a
    # depth buffer, a Tron floor that is real projected geometry, a heading-up radar. Sixteen
    # seconds of banking corridor runs, a pillared hall under a synthwave sun, then a corridor at
    # twenty cells a second into a doorway of white light.
    class Maze < Scene
      M = MazeMap
      F = MazeFlight
      TAU = Math::PI * 2

      HALL_AT = F::HALL_AT
      RUSH_AT = F::RUSH_AT
      END_AT = F::END_AT
      NEAR = 0.06
      HUD_AT = 2.5    # the counter and the radar wait for the title to fly clear
      GRID_R = 9      # floor grid reach, in cells

      # Sprite kinds.
      ORB = 0
      GEM = 1
      SHOE = 2

      COLOURS = {
        cyan: Palette::CYAN, magenta: Palette::MAGENTA, mint: Palette::MINT, gold: Palette::GOLD,
        violet: Palette::VIOLET, ruby: Palette::RUBY, ink: Palette::INK,
      }.freeze

      # Environments the camera passes through: fog colour, fog length, near floor, roof,
      # floor grid colour, ceiling grid colour, gloss.
      ENVS = {
        maze: [[13, 4, 26], 6.0, [5, 3, 14], [9, 6, 22], Palette::CYAN, Palette::MAGENTA, 0.46],
        hall: [[150, 52, 120], 15.0, [14, 7, 28], [20, 12, 36], Palette::MAGENTA, Palette::GOLD, 0.55],
        rush: [[34, 6, 44], 9.0, [8, 3, 16], [16, 5, 24], Palette::MAGENTA, Palette::CYAN, 0.5],
      }.freeze

      # The hall's arched windows, in world units: sill, where the arch springs, its rise,
      # and its half width as a share of a cell.
      ARCH_SILL = 0.3
      ARCH_SPRING = 0.82
      ARCH_RISE = 0.3
      ARCH_HALF = 0.3

      # Trims on planar walls, by kind: [fraction of the wall's height, thickness, colour].
      TRIMS = {
        MazeMap::NEON => [[0.07, 0.034, Palette::CYAN], [0.86, 0.02, Palette::MAGENTA]],
        MazeMap::CHROME => [[ARCH_SILL / 1.3, 0.022, Palette::MAGENTA], [0.97, 0.02, Palette::GOLD]],
        MazeMap::TECH => [[0.8, 0.034, Palette::MAGENTA], [0.2, 0.034, Palette::CYAN]],
        MazeMap::BRICK => [[1.0 / 3, 0.03, :mortar], [2.0 / 3, 0.03, :mortar]],
      }.freeze
      CHASED = [MazeMap::NEON, MazeMap::TECH].freeze

      # Under the open sky some walls stand taller than the roofed corridors allow: the hall's
      # walls, and its columns most of all.
      PILLAR_H = 2.4
      TALL = Array.new(8, 1.0).tap do |a|
        a[MazeMap::PILLAR] = PILLAR_H
        a[MazeMap::CHROME] = 1.3
      end.freeze

      AMETHYST = [150, 70, 255].freeze
      SKY_TOP = [6, 4, 30].freeze
      SKY_HORIZON = [255, 82, 124].freeze
      SUN_AZ = Math::PI / 2            # due south: dead ahead, behind the gem, as the door opens
      KEY_AZ = SUN_AZ + Math::PI + 0.7 # the pillars' key light, over the camera's shoulder
      LIGHT_WALL = [255.0, 250.0, 242.0].freeze # the doorway of light (a subclass may set @light_wall)

      def build
        @flight = MazeFlight.new
        @path = @flight.path
        setup_world
        @n = [(240 * density).round, 48].max
        @colw = w.to_f / @n
        @x0 = Array.new(@n) { |i| (i * @colw).round }
        @xw = Array.new(@n) { |i| ((i + 1) * @colw).round - @x0[i] }
        @xc = Array.new(@n) { |i| @x0[i] + @xw[i] * 0.5 - w / 2.0 }
        @slice_n = [(200 * density).round, 60].max
        @floor_n = [(240 * density).round, 60].max
        @ceil_n = [(150 * density).round, 40].max
        @star_n = [(70 * density).round, 20].max
        @halo_n = density < 0.6 ? 6 : 12
        @pool_n = density < 0.6 ? 4 : 8
        @orb_n = density < 0.6 ? 12 : 28
        @tq_n = density < 0.6 ? 24 : 64
        @cq_n = density < 0.6 ? 6 : 16
        @title = MazeTitle.new(self)
        @counter = MazeCounter.new(self, shoe_total)

        draw do
          nostroke
          build_sky
        end
        breathe
        draw do
          @ceiling = rect(0, 0, w, (h / 2.0).round, fill: Palette.rgb(Palette::NIGHT), strokewidth: 0, hidden: true)
          @roof_a = strips
          @roof_b = strips
          @ceil = lines(@ceil_n)
        end
        breathe
        draw do
          @floor = rect(0, (h / 2.0).round, w, (h / 2.0).round, fill: Palette.rgb(Palette::NIGHT), strokewidth: 0)
          @refl = strips
          @grid = lines(@floor_n)
          @glitter = Array.new(GLITTER_BANDS + 1) { rect(0, 0, 1, 1, fill: Palette.rgb(Palette::GOLD, 0.0), strokewidth: 0, hidden: true) }
          @pools = ovals(@pool_n * 3)
        end
        breathe
        draw do
          @walls = strips
          @trim_a = strips
          @trim_b = strips
          @tq = quads(@tq_n)
          @cq = quads(@cq_n)
          @door_shapes = MazeShapes.new(self, 4)
        end
        breathe
        draw do
          @halos = ovals(@halo_n * 3)
          @orb_body = ovals(@orb_n)
          @orb_core = ovals(@orb_n)
          @slice_a = Array.new(@slice_n) { rect(0, 0, 1, 1, strokewidth: 0, hidden: true) }
          @shoe_shapes = MazeShapes.new(self, density < 0.6 ? 30 : 60)
          @gem_shapes = MazeShapes.new(self, density < 0.6 ? 70 : 150)
        end
        @gems = MazeGems.new(self, @gem_shapes)
        @shoes = MazeShoes.new(self, @shoe_shapes)
        breathe
        draw do
          @bloom = ovals(4) + [rect(0, 0, 1, 1, fill: Palette.rgb(Palette::INK, 0.0), strokewidth: 0, hidden: true)]
          @flash = rect(0, 0, w, h, fill: Palette.rgb(Palette::GOLD, 0.0), strokewidth: 0)
          build_radar
          @counter.build(16 * u, 16 * u, 3.0 * u)
          @title.build
          @glare = rect(0, 0, w, h, fill: Palette.rgb(Palette::INK, 0.0), strokewidth: 0)
        end
        setup_buffers
      end

      # Each time the scene shows, after a seek too: everything pooled starts hidden, so nothing
      # from before the seek stays frozen on screen.
      def enter
        [@orb_body, @orb_core, @halos, @pools, @grid, @ceil, @bloom].each do |pool|
          pool.each { |d| set(d, { hidden: true }) }
        end
        (@tq + @cq).each { |d| set(d, { shape_commands: [] }) }
        @gem_shapes.enter
        @shoe_shapes.enter
        @door_shapes.enter
        @orbs_on = @halos_on = @pools_on = 0
        @tq_on = @cq_on = 0
        @lines_on = [0, 0]
        @slices_on = 0
        @bloom_on = false
        @veils = {}
        @sky_on = nil
        @ceiling_on = nil
        @glitter.each { |g| set(g, { hidden: true }) }
        @glitter_shown&.fill(false)
        @glitter_on = false
        @radar.enter
      end

      def update(t, sync)
        pose(t, sync)
        environment(t, sync)
        @door_open = door_share(t)
        @rc.open_door(*M::DOOR_CELL, @door_open)
        @rc.cast(@px, @py, @dx, @dy, @plx, @ply, @n)
        draw_columns(t, sync)
        draw_sky(t, sync)
        draw_grid
        draw_sprites(t, sync)
        draw_bloom
        hud = t >= HUD_AT
        @radar.visible(hud)
        @counter.visible(hud)
        @radar.update(@px, @py, @dx, @dy, @tan_half, @marks[collected(t)], sky: t >= HALL_AT)
        @counter.update(collected(t))
        @title.update(t, sync)
        draw_overlays(t, sync)
      end

      private

      # ---- world and flight ---------------------------------------------------------------

      def setup_world
        @rc = Raycaster.new(M::ROWS, legend: M::LEGEND, open: M::OPEN, round: M::ROUND, doors: [M::DOOR])
        @s_door = @flight.s_door
        @s_exit = @flight.s_exit
        @s_end = @flight.s_end
        @shoe_s = @flight.shoe_s
        @shoe_t = @flight.shoe_t
        spots = @shoe_s.flat_map { |s| [@path.x_at(s), @path.y_at(s)] }
        @marks = Array.new(@shoe_s.size + 1) { |k| spots.drop(k * 2) }
        grid_edges
      end

      def collected(t) = @shoe_t.count { |ct| t >= ct }

      # How many shoes the counter counts to.
      def shoe_total = @shoe_s.size

      # The hall door slides open just after the crash, while the camera holds off it.
      DOOR_OPENS = [HALL_AT + 0.03, HALL_AT + 0.4].freeze

      def door_share(t)
        k = ((t - DOOR_OPENS[0]) / (DOOR_OPENS[1] - DOOR_OPENS[0])).clamp(0.0, 1.0)
        1.0 - (1.0 - k)**2.2
      end

      def smooth(a, b, x)
        k = ((x - a) / (b - a)).clamp(0.0, 1.0)
        k * k * (3 - 2 * k)
      end

      def wrap(a) = (a + Math::PI) % TAU - Math::PI

      # How hard the camera turns to face the great gem: it walks in looking straight at it,
      # keeps it in frame round the orbit, and stares it down from 21.6 to 24.2 s.
      def look_at(t)
        base = 0.6 * smooth(HALL_AT + 0.8, HALL_AT + 2.6, t)
        hero = 0.32 * smooth(20.2, 21.6, t) * (1.0 - smooth(24.2, 25.8, t))
        (base + hero) * (1.0 - smooth(RUSH_AT - 1.6, RUSH_AT - 0.1, t))
      end

      def pose(t, sync)
        s = @flight.distance_at(t)
        @s = s
        @px = @path.x_at(s)
        @py = @path.y_at(s)
        ang = @flight.yaw(t)
        rate = @flight.yaw_rate(t)
        look = look_at(t)
        if look > 0.0
          gem = Math.atan2(M::HALL_CENTRE[1] - @py, M::HALL_CENTRE[0] - @px)
          ang += look * wrap(gem - ang)
        end
        kick = sync.hit(:kick, 0.12)
        snare = sync.hit(:snare, 0.08)
        shake = 0.05 * Math.exp(-t / 0.3) + (t > 15.5 && t < HALL_AT ? 0.025 * snare : 0.0)
        shake += 0.03 * Math.exp(-(t - HALL_AT) / 0.25) if t >= HALL_AT
        shake += 0.012 * smooth(RUSH_AT, END_AT, t)
        ang += shake * Math.sin(t * 83.0)
        @ang = ang
        @dx = Math.cos(ang)
        @dy = Math.sin(ang)
        punch = t < HALL_AT ? 9.0 * kick : 0.0
        # wider and wider down the last corridor, then a dolly zoom into the doorway
        fov = 74.0 + punch + 15.0 * smooth(RUSH_AT, END_AT - 0.7, t)**1.3 - 30.0 * smooth(END_AT - 0.8, END_AT, t)**1.5
        half = Math.tan(fov * Math::PI / 360.0)
        @plx = -@dy * half
        @ply = @dx * half
        @f = (w / 2.0) / half
        @tan_half = half
        @tilt = banking(t, sync, rate, kick)
        if t < HALL_AT
          @camh = 0.5 - 0.04 * kick
          @hor = h / 2.0 + 8.0 * u * kick + shake * 120.0 * u * Math.cos(t * 61.0)
        else
          bob = Math.sin(TAU * t / (Music::BEAT * 2))
          @camh = 0.5 + 0.018 * bob
          @hor = h / 2.0 + 3.0 * u * bob + shake * 140.0 * u * Math.cos(t * 61.0)
        end
      end

      # Roll, faked as a shear: each column's horizon moves by its distance from the centre
      # times this. The camera banks into every turn and snaps a little each kick, left then
      # right, for the first sixteen seconds; the hall only leans.
      def banking(t, sync, rate, kick)
        if t < HALL_AT
          side = sync.count(:kick).even? ? 1.0 : -1.0
          bank = -0.03 * rate + 0.035 * kick * side
          bank.clamp(-0.12, 0.12)
        else
          (-0.015 * rate).clamp(-0.04, 0.04) + 0.008 * Math.sin(t * 1.3) * (1.0 - smooth(RUSH_AT, END_AT, t))
        end
      end

      # Fog, floor, roof and grid colours, blended by where the camera is along the route.
      def environment(t, sync)
        into_hall = smooth(HALL_AT, HALL_AT + 0.14, t)
        into_rush = smooth(@s_exit + 3.0, @s_exit + 9.0, @s)
        a = ENVS[:maze]
        b = ENVS[:hall]
        c = ENVS[:rush]
        mixv = ->(i) { lerp3(lerp3(a[i], b[i], into_hall), c[i], into_rush) }
        @fog = mixv.call(0)
        @fog_len = a[1] + (b[1] - a[1]) * into_hall + (c[1] - b[1]) * into_rush
        @near_floor = mixv.call(2)
        @roof_col = mixv.call(3)
        @grid_col = mixv.call(4)
        @ceil_col = mixv.call(5)
        @gloss = a[6] + (b[6] - a[6]) * into_hall + (c[6] - b[6]) * into_rush
        white = smooth(@s_end - 26.0, @s_end, @s)**2
        @fog = lerp3(@fog, [255, 236, 250], white)
        @fog_len += 20.0 * white
        # the last room fills with the doorway's light: floor and roof go white near it
        spill = smooth(@s_end - 9.0, @s_end, @s)**1.4
        @near_floor = lerp3(@near_floor, [255, 214, 240], spill)
        @roof_col = lerp3(@roof_col, [255, 228, 246], spill)
        @kick = sync.hit(:kick, 0.16)
        @snare = sync.hit(:snare, 0.1)
        @pulse = 0.75 + 0.5 * @kick
        @pulse = 1.7 if t > 15.5 && t < HALL_AT && sync.since(:snare) < 0.06
        @streak = smooth(RUSH_AT + 0.6, END_AT - 0.3, t)
        # the drop itself: every trim white-hot on the downbeat
        drop = t < 0.8 ? Math.exp(-t / 0.16) : 0.0
        @streak = drop if drop > @streak
        @pulse += 0.6 * drop
        sixteenth = (sync.t % Music::STEP) / Music::STEP
        @tube = 0.35 + 0.85 * smooth(RUSH_AT, RUSH_AT + 1.5, t) * (1.0 - sixteenth)**2
        # every 8th a light runs along the neon trims, away from the camera
        eighth = Music::STEP * 2
        ph = (sync.t % eighth) / eighth
        rush = smooth(RUSH_AT, RUSH_AT + 1.0, t)
        @chase_d = 0.5 + ph * (7.0 + 9.0 * rush)
        @chase_a = t < HALL_AT || t > RUSH_AT ? (1.0 - ph)**0.6 * (0.8 + 0.4 * @kick) : 0.0
        lights
      end

      def lerp3(p, q, k)
        [p[0] + (q[0] - p[0]) * k, p[1] + (q[1] - p[1]) * k, p[2] + (q[2] - p[2]) * k]
      end

      # Up to four point lights near the camera, as a flat Array [x, y, r, g, b, power, ...].
      def lights
        best = @light_src.select { |x, y, *| (x - @px).abs < 7 && (y - @py).abs < 7 }
          .min_by(4) { |x, y, *| (x - @px)**2 + (y - @py)**2 }
        out = @lights
        out.clear
        best.each do |x, y, c, power|
          out.push(x, y, c[0], c[1], c[2], power * (0.75 + 0.5 * @kick))
        end
        d = @s_end - @s
        return unless d < 45

        power = 2.0 + 26.0 / (1.0 + d * 0.15)
        [13.6, 15.5, 17.4].each { |y| out.push(@door_x - 0.4, y, 255.0, 240.0, 250.0, power) }
      end

      # ---- drawables ------------------------------------------------------------------------

      def strips
        Array.new(@n) { |i| rect(@x0[i], 0, @xw[i], 0, strokewidth: 0) }
      end

      def lines(n)
        Array.new(n) { line(0, 0, 0, 0, stroke: Palette.rgb(Palette::CYAN, 0.0), strokewidth: 1.3 * u, hidden: true) }
      end

      def ovals(n)
        Array.new(n) { oval(0, 0, 1, 1, fill: Palette.rgb(Palette::GOLD, 0.0), strokewidth: 0, hidden: true) }
      end

      def quads(n)
        Array.new(n) { shape(0, 0, fill: Palette.rgb(Palette::CYAN), strokewidth: 0) }
      end

      def setup_buffers
        n = @n
        @zbuf = Array.new(n, 1.0)
        @w_top = Array.new(n, 0)
        @w_h = Array.new(n, 0)
        @w_c1 = Array.new(n)
        @w_c2 = Array.new(n)
        @w_sent = Array.new(n, -1)
        @wtop = Array.new(n, 0.0)
        @sky_at = Array.new(n, false)
        @roof_y = Array.new(n, -1.0)
        @roof_d = Array.new(n, -1.0)
        @hor_at = Array.new(n, 0.0)
        # planar trims, per column: plane key, top, thickness, colour (nil: none)
        @qkey = Array.new(n, -1)
        @qkind = Array.new(n, 0)
        @qa_y = Array.new(n, 0.0)
        @qa_h = Array.new(n, 0.0)
        @qa_c = Array.new(n)
        @qb_y = Array.new(n, 0.0)
        @qb_h = Array.new(n, 0.0)
        @qb_c = Array.new(n)
        @tq_cmds = Array.new(@tq_n) { Array.new(5) { |j| [j.zero? ? "move_to" : "line_to", 0.0, 0.0] } }
        @cq_cmds = Array.new(@cq_n) { Array.new(5) { |j| [j.zero? ? "move_to" : "line_to", 0.0, 0.0] } }
        @lights = []
        @door_x = M::ROWS[15].index("D") + 0.0
        @zero = { a: Array.new(n, false), b: Array.new(n, false), r: Array.new(n, false), ta: Array.new(n, false), tb: Array.new(n, false) }
        @slice_shown = Array.new(@slice_n, false)
        build_sprites
        @orbs_on = @halos_on = @pools_on = @tq_on = @cq_on = @slices_on = 0
        @lines_on = [0, 0]
      end

      # ---- the walls: one strip per ray ---------------------------------------------------

      def draw_columns(t, sync)
        rc = @rc
        n = @n
        f = @f
        hor0 = @hor
        tilt = @tilt
        xc = @xc
        camh = @camh
        hh = h.to_f
        fr, fg, fb = @fog
        inv_fog = 1.0 / @fog_len
        lights = @lights
        nl = lights.size
        pulse = @pulse
        gloss = @gloss
        roof = @roof_col
        lead = sync.hit(:lead, 0.3)
        key_x = Math.cos(KEY_AZ)
        key_y = Math.sin(KEY_AZ)
        sun_x = Math.cos(SUN_AZ)
        sun_y = Math.sin(SUN_AZ)
        door_glow = pulse * (t > 15.5 && t < HALL_AT ? 1.0 + 0.8 * @snare : 1.0)
        light_wall = @light_wall || LIGHT_WALL
        ceiling(n, fr, fg, fb, inv_fog)
        i = 0
        while i < n
          d = rc.dist[i]
          d = NEAR if d < NEAR
          @zbuf[i] = d
          k = rc.kind[i]
          hor = hor0 + xc[i] * tilt
          @hor_at[i] = hor
          sc = f / d
          open_sky = rc.roof_a[i] < d - 1e-6 && rc.roof_b[i] < 0.0
          top = hor - ((open_sky ? TALL[k] : 1.0) - camh) * sc
          bot = hor + camh * sc
          wh = bot - top
          @wtop[i] = top
          side = rc.side[i]
          tex = rc.tex[i]
          cell = rc.cell[i]
          shade = side == 1 ? 0.72 : 1.0
          emissive = false
          efog = 1.0
          col_a = col_b = nil # per-column trim rects: [top, height, colour]
          arch_z = nil
          case k
          when M::NEON
            shade *= 0.8 + 0.4 * ((cell * 37 + side * 11) % 7) / 6.0
            shade *= 0.42 if tex < 0.035 || tex > 0.965
            # bevelled seams split each panel in four, so a wall close up is never blank
            q4 = (tex * 4.0) % 1.0
            if q4 < 0.035
              shade *= 0.5
            elsif q4 < 0.07
              shade *= 1.45
            end
            br = 46.0 * shade
            bg = 30.0 * shade
            bb = 112.0 * shade
            top_k = 0.36
            off = (tex - 0.5).abs
            if off < 0.04
              # a neon tube from floor to ceiling on every panel, cyan or violet, with a
              # white-hot core
              glow = pulse * (side == 1 ? 0.85 : 1.0)
              if off < 0.013
                br = 235.0 * glow
                bg = 245.0 * glow
                bb = 255.0 * glow
              elsif (cell + side).even?
                br = 120.0 * glow
                bg = 230.0 * glow
                bb = 255.0 * glow
              else
                br = 190.0 * glow
                bg = 120.0 * glow
                bb = 255.0 * glow
              end
              top_k = 1.0
              emissive = true
              efog = 0.4
            end
          when M::BRICK
            bx = tex * 4.0
            brick = bx.floor
            hsh = ((cell * 7 + brick * 13) % 11) / 11.0
            shade *= 0.7 + 0.45 * hsh
            br = 200.0 * shade
            bg = 70.0 * shade
            bb = 40.0 * shade
            top_k = 0.5
          when M::CHROME
            # the hall's arcade: dark stone with a round-arched window in every bay, so the
            # glowing horizon shows through the wall
            rib = Math.cos(tex * TAU * 2.0)
            shade *= 0.8 + 0.2 * rib * rib
            br = 58.0 * shade
            bg = 40.0 * shade
            bb = 104.0 * shade
            top_k = 1.5
            if open_sky
              a = (tex - 0.5).abs / ARCH_HALF
              arch_z = a < 1.0 ? ARCH_SPRING + ARCH_RISE * Math.sqrt(1.0 - a * a) : nil
            end
          when M::PILLAR
            nx = rc.norm_x[i]
            ny = rc.norm_y[i]
            vx = @px - rc.hit_x[i]
            vy = @py - rc.hit_y[i]
            vl = Math.sqrt(vx * vx + vy * vy) + 1e-6
            vx /= vl
            vy /= vl
            lam = nx * key_x + ny * key_y
            lam = 0.0 if lam < 0.0
            hx = key_x + vx
            hy = key_y + vy
            hl = Math.sqrt(hx * hx + hy * hy) + 1e-6
            spec = (nx * hx + ny * hy) / hl
            spec = spec > 0.0 ? spec**28 : 0.0
            facing = nx * vx + ny * vy
            rim = 1.0 - facing
            back = nx * sun_x + ny * sun_y
            back = back > 0.0 ? back * rim * rim : 0.0
            # and a polished-metal streak down the face turned to the camera
            sheen = facing > 0.0 ? facing**36 : 0.0
            l = 0.2 + 0.75 * lam + 0.4 * facing + 1.1 * back
            hot = spec + 0.75 * sheen
            br = 255.0 * l + 255.0 * hot
            bg = 168.0 * l + 236.0 * hot
            bb = 50.0 * l + 200.0 * hot + 30.0 * (1.0 - lam)
            top_k = 1.1
            th = pillar_trim(wh)
            col_a = [bot - 0.04 * wh - th / 2, th, :bright]
            col_b = [bot - 0.91 * wh - th / 2, th * 1.2, :bright]
          when M::LIGHT
            br, bg, bb = light_wall
            top_k = 1.0
            emissive = true
            efog = 0.12
          when M::DOOR
            rail = tex < DOOR_RAIL || tex > 1.0 - DOOR_RAIL
            rib = (tex * 10.0) % 1.0 < 0.1 ? 0.62 : 1.0
            br = (rail ? 230.0 : 62.0 * rib) * shade
            bg = (rail ? 170.0 : 54.0 * rib) * shade
            bb = (rail ? 70.0 : 118.0 * rib) * shade
            top_k = 0.62
          else # TECH
            shade *= 0.5 if (tex * 2.0) % 1.0 < 0.05
            br = 34.0 * shade
            bg = 14.0 * shade
            bb = 56.0 * shade
            top_k = 0.5
            off = (tex - 0.5).abs
            if off > 0.025 && off < 0.085
              # a pair of tubes on every panel, strobing on the riser's sixteenths
              glow = @tube * (side == 1 ? 0.8 : 1.0)
              hot = off > 0.045 && off < 0.065 ? 1.0 : 0.55
              if cell.even?
                br = (60.0 + 140.0 * hot) * glow
                bg = (200.0 + 50.0 * hot) * glow
                bb = 255.0 * glow
              else
                br = 255.0 * glow
                bg = (40.0 + 150.0 * hot) * glow
                bb = (140.0 + 90.0 * hot) * glow
              end
              top_k = 1.0
              emissive = true
              efog = 0.45
            end
          end

          unless emissive
            hx = rc.hit_x[i]
            hy = rc.hit_y[i]
            j = 0
            while j < nl
              ex = lights[j] - hx
              ey = lights[j + 1] - hy
              att = lights[j + 5] / (1.0 + (ex * ex + ey * ey) * 2.2)
              br += lights[j + 2] * att * 0.35
              bg += lights[j + 3] * att * 0.35
              bb += lights[j + 4] * att * 0.35
              j += 6
            end
          end

          fogk = 1.0 - Math.exp(-d * inv_fog)
          fogk *= efog if emissive
          keep = 1.0 - fogk
          lr = br * keep + fr * fogk
          lg = bg * keep + fg * fogk
          lb = bb * keep + fb * fogk
          ur = br * top_k * keep + fr * fogk
          ug = bg * top_k * keep + fg * fogk
          ub = bb * top_k * keep + fb * fogk

          # Strips stay inside the slot (a shape crossing the clip is painted through a mask,
          # several times slower), so the gradient is cut to the part that shows.
          vt = top < 0.0 ? 0.0 : top
          if arch_z
            # the strip stops at the sill; the wall over the arch is a column rect
            lin = bot - arch_z * sc
            ka = (lin - top) / wh
            col_a = [top, lin - top, [ur, ug, ub], [ur + (lr - ur) * ka, ug + (lg - ug) * ka, ub + (lb - ub) * ka]]
            vt = bot - ARCH_SILL * sc
          end
          vb = bot > hh ? hh : bot
          ka = (vt - top) / wh
          kb = (vb - top) / wh
          @w_top[i] = vt.round
          @w_h[i] = vb - vt >= 1.0 ? vb.round - vt.round : 0
          @w_c1[i] = col(ur + (lr - ur) * ka, ug + (lg - ug) * ka, ub + (lb - ub) * ka)
          @w_c2[i] = col(ur + (lr - ur) * kb, ug + (lg - ug) * kb, ub + (lb - ub) * kb)

          planar_trims(i, k, side, rc, bot, wh, lr, lg, lb, fogk, pulse, lead)
          col_a, col_b = brick_joints(tex, bot, wh) if k == M::BRICK
          column_rect(@trim_a, :ta, i, col_a, lr, lg, lb, fogk, door_glow)
          column_rect(@trim_b, :tb, i, col_b, lr, lg, lb, fogk, door_glow)

          # the glossy floor under it
          rh = sc * (k == M::PILLAR ? 0.8 : 0.42)
          rk = bot + rh > hh ? (hh - bot) / rh : 1.0
          if rk * rh > 1.0 && bot < hh
            ga = 255 * gloss
            set(@refl[i], { top: bot.round, height: (bot + rh * rk).round - bot.round,
                            fill: { gradient: [col(lr, lg, lb, ga), col(lr, lg, lb, ga * (1.0 - rk))], angle: 0 } })
            @zero[:r][i] = false
          else
            zero(@refl, :r, i)
          end

          roofs(i, d, top, hor, camh, f, roof, fr, fg, fb, inv_fog)
          i += 1
        end
        emit_walls(n)
        emit_trims(n)
        door_chevrons(door_glow)
      end

      # The sliding door's two zigzags, as real polygons on the door's plane (so the diagonals
      # are clean), riding with the panel and cut to the columns where the door shows.
      CHEVRONS = [[0.64, -0.16, Palette::MAGENTA], [0.36, 0.16, Palette::CYAN]].freeze
      DOOR_RAIL = 0.07 # the gold rails at the panel's two edges, as a share of its width

      def door_chevrons(glow)
        pool = @door_shapes
        pool.begin_frame
        kinds = @rc.kind
        texs = @rc.tex
        # only the columns that show the panel between its rails, so the gold leading edge
        # stays clean and nothing spills past it into the doorway
        c0 = c1 = nil
        @n.times do |i|
          next unless kinds[i] == M::DOOR && texs[i] >= DOOR_RAIL && texs[i] <= 1.0 - DOOR_RAIL

          c0 ||= i
          c1 = i
        end
        span = 1.0 - @door_open
        if c0 && span > DOOR_RAIL
          dx0, dy0 = M::DOOR_CELL
          left = dx0 + @door_open
          yy = dy0 + 0.5
          d = yy - @py
          fogk = 1.0 - Math.exp(-(d.abs + 0.1) / @fog_len)
          xs = @chev_x ||= Array.new(40, 0.0)
          ys = @chev_y ||= Array.new(40, 0.0)
          ox = @chev_ox ||= Array.new(48, 0.0)
          oy = @chev_oy ||= Array.new(48, 0.0)
          tx = @chev_tx ||= Array.new(48, 0.0)
          ty = @chev_ty ||= Array.new(48, 0.0)
          th = 0.024
          last = span < 1.0 - DOOR_RAIL ? span : 1.0 - DOOR_RAIL
          CHEVRONS.each do |base, amp, colour|
            us = chevron_knots(DOOR_RAIL, last)
            m = us.size
            us.each_with_index do |u, k|
              z = base + amp * chevron_tri(u)
              xs[k], ys[k] = project(left + u, yy, z + th)
              xs[2 * m - 1 - k], ys[2 * m - 1 - k] = project(left + u, yy, z - th)
            end
            n = MazeClip.x_band(xs, ys, 2 * m, @x0[c0].to_f, (@x0[c1] + @xw[c1]).to_f, ox, oy, tx, ty)
            pool.poly(ox, oy, n, door_colour(colour, fogk, glow))
          end
        end
        pool.end_frame
      end

      # Knots along the panel from a to b: both ends and every corner of the zigzag between.
      def chevron_knots(a, b)
        us = (@chev_knots ||= []).clear
        us << a
        k = (a * 6.0).floor + 1
        while k / 6.0 < b
          us << k / 6.0
          k += 1
        end
        us << b
      end

      def chevron_tri(u)
        z = (u * 3.0) % 1.0
        z < 0.5 ? z * 2.0 : 2.0 - z * 2.0
      end

      def project(x, y, z)
        rx = x - @px
        ry = y - @py
        depth = rx * @dx + ry * @dy
        depth = NEAR if depth < NEAR
        sx = w / 2.0 + (ry * @dx - rx * @dy) / depth * @f
        [sx, @hor + (sx - w / 2.0) * @tilt - (z - @camh) * @f / depth]
      end

      def pillar_trim(wh)
        th = 0.05 * wh
        th < 1.2 * u ? 1.2 * u : (th > 9.0 * u ? 9.0 * u : th)
      end

      # The vertical joints between bricks, course by course: the middle course is shifted half
      # a brick against the ones above and below it, so the wall reads as a running bond. Only
      # the few columns that land on a joint draw anything.
      def brick_joints(tex, bot, wh)
        third = wh / 3.0
        bx = tex * 4.0
        if bx - bx.floor < 0.07
          [[bot - wh, third, :joint], [bot - third, third, :joint]]
        elsif (bx + 0.5) - (bx + 0.5).floor < 0.07
          [[bot - 2.0 * third, third, :joint], nil]
        else
          [nil, nil]
        end
      end

      # Trims that run along a flat wall: recorded per column here, and sent as one quad per
      # wall plane by emit_trims, so a trim on a wall seen at a slant is one clean line.
      def planar_trims(i, k, side, rc, bot, wh, lr, lg, lb, fogk, pulse, lead)
        spec = TRIMS[k]
        if spec.nil? || side == 2
          @qa_c[i] = nil
          @qb_c[i] = nil
          @qkey[i] = -1
          return
        end
        plane = side.zero? ? rc.hit_x[i] : rc.hit_y[i]
        @qkey[i] = (k * 2 + side) * 1000 + plane.round
        @qkind[i] = k
        a, b = spec
        @qa_y[i], @qa_h[i], @qa_c[i] = trim_band(a, bot, wh, lr, lg, lb, fogk, pulse, lead)
        @qb_y[i], @qb_h[i], @qb_c[i] = trim_band(b, bot, wh, lr, lg, lb, fogk, pulse, lead)
      end

      def trim_band(spec, bot, wh, lr, lg, lb, fogk, pulse, lead)
        frac, thick, c = spec
        th = thick * wh
        th = 1.2 * u if th < 1.2 * u
        th = 8.0 * u if th > 8.0 * u
        y = bot - frac * wh - th / 2
        colour = if c == :mortar
                   col(lr * 0.3, lg * 0.3, lb * 0.3)
                 else
                   glow = (1.0 - fogk * 0.5) * pulse
                   glow *= 0.8 + 0.4 * lead if c.equal?(Palette::GOLD)
                   fo = @fog
                   kf = fogk * 0.55
                   r = c[0] * glow + fo[0] * kf
                   g = c[1] * glow + fo[1] * kf
                   b = c[2] * glow + fo[2] * kf
                   s = @streak * (1.0 - fogk * 0.6)
                   col(r + (255 - r) * s, g + (255 - g) * s, b + (255 - b) * s)
                 end
        [y, th, colour]
      end

      # Per-column trims (columns, the door's chevrons, the brick's middle course).
      def column_rect(rects, key, i, spec, lr, lg, lb, fogk, door_glow)
        if spec.nil?
          zero(rects, key, i)
          return
        end
        y, th, c, c2 = spec
        y1 = y + th
        y = 0.0 if y < 0.0
        y1 = h.to_f if y1 > h
        if y1 - y < 0.6
          zero(rects, key, i)
          return
        end
        fill = case c
               when :bright then col(lr * 1.3 + 30, lg * 1.25 + 20, lb * 1.1 + 10)
               when :joint then col(lr * 0.3, lg * 0.3, lb * 0.3)
               when :door_m then door_colour(Palette::MAGENTA, fogk, door_glow)
               when :door_c then door_colour(Palette::CYAN, fogk, door_glow)
               else { gradient: [col(*c), col(*c2)], angle: 0 }
               end
        set(rects[i], { top: y.round, height: [y1.round - y.round, 1].max, fill: fill })
        @zero[key][i] = false
      end

      def door_colour(c, fogk, glow)
        k = (1.0 - fogk * 0.5) * glow
        col(c[0] * k + 40, c[1] * k + 30, c[2] * k + 40)
      end

      def zero(rects, key, i)
        return if @zero[key][i]

        set(rects[i], { height: 0 })
        @zero[key][i] = true
      end

      # Neighbouring strips that match (same span, near-identical colours) go out as one wider
      # rect: a near wall filling the screen is a handful of rects instead of a hundred, which
      # matters because the renderer's cost is per strip per scanline.
      def emit_walls(n)
        tops = @w_top
        hs = @w_h
        c1s = @w_c1
        c2s = @w_c2
        i = 0
        while i < n
          t = tops[i]
          hh = hs[i]
          a = c1s[i]
          b = c2s[i]
          j = i + 1
          while j < n && tops[j] == t && hs[j] == hh && close(a, c1s[j]) && close(b, c2s[j])
            j += 1
          end
          if hh.zero?
            wall_off(i)
          else
            width = @x0[j - 1] + @xw[j - 1] - @x0[i]
            props = { top: t, height: hh, fill: { gradient: [a, b], angle: 0 } }
            props[:width] = width if width != @w_sent[i]
            @w_sent[i] = width
            set(@walls[i], props)
          end
          k = i + 1
          while k < j
            wall_off(k)
            k += 1
          end
          i = j
        end
      end

      def close(a, b)
        (a[0] - b[0]).abs + (a[1] - b[1]).abs + (a[2] - b[2]).abs <= 7
      end

      def wall_off(k)
        return if @w_sent[k].zero?

        set(@walls[k], { height: 0 })
        @w_sent[k] = 0
      end

      # One quad per trim per wall plane in view, then the chase lights riding on them.
      def emit_trims(n)
        q = 0
        cq = 0
        keys = @qkey
        i = 0
        while i < n
          key = keys[i]
          if key.negative?
            i += 1
            next
          end
          j = i
          j += 1 while j + 1 < n && keys[j + 1] == key
          q = trim_run(q, i, j, @qa_y, @qa_h, @qa_c)
          q = trim_run(q, i, j, @qb_y, @qb_h, @qb_c)
          cq = chase(cq, i, j) if @chase_a > 0.02 && CHASED.include?(@qkind[i])
          i = j + 1
        end
        (q...@tq_on).each { |k| set(@tq[k], { shape_commands: [] }) }
        @tq_on = q
        (cq...@cq_on).each { |k| set(@cq[k], { shape_commands: [] }) }
        @cq_on = cq
      end

      # A trim leaving the top or bottom of the screen is cut back to the columns where it
      # shows, so the quad never folds along the edge.
      def trim_run(q, i, j, ys, hs, cs)
        hh = h.to_f
        i += 1 while i < j && (ys[i] < 0.0 || ys[i] + hs[i] > hh)
        j -= 1 while j > i && (ys[j] < 0.0 || ys[j] + hs[j] > hh)
        trim_quad(@tq, @tq_cmds, q, @tq_n, i, j, ys, hs, cs[i], cs[j])
      end

      def trim_quad(pool, cmds_pool, q, cap, i, j, ys, hs, ca, cb, fill = nil)
        return q if q >= cap

        span = j - i
        st = span.positive? ? (ys[j] - ys[i]) / span : 0.0
        sh = span.positive? ? (hs[j] - hs[i]) / span : 0.0
        yl = ys[i] - st * 0.5
        yr = ys[j] + st * 0.5
        hl = hs[i] - sh * 0.5
        hr = hs[j] + sh * 0.5
        hl = 1.0 if hl < 1.0
        hr = 1.0 if hr < 1.0
        hh = h.to_f
        return q if (yl > hh && yr > hh) || (yl + hl < 0 && yr + hr < 0)

        xl = @x0[i].to_f
        xr = (@x0[j] + @xw[j]).to_f
        c = cmds_pool[q]
        quad_point(c[0], xl, yl, hh)
        quad_point(c[1], xr, yr, hh)
        quad_point(c[2], xr, yr + hr, hh)
        quad_point(c[3], xl, yl + hl, hh)
        c[4][1] = c[0][1]
        c[4][2] = c[0][2]
        set(pool[q], { shape_commands: c, fill: fill || (ca == cb ? ca : { gradient: [ca, cb], angle: 90 }) })
        q + 1
      end

      def quad_point(p, x, y, hh)
        y = 0.0 if y < 0.0
        y = hh if y > hh
        p[1] = x.round(1)
        p[2] = y.round(1)
      end

      # A short bright run on both trims of a wall, at the column whose depth matches the
      # chase distance.
      def chase(cq, i, j)
        dc = @chase_d
        return cq if dc < 1.2

        dist = @zbuf
        best = -1
        bd = 0.7
        c = i
        while c <= j
          e = (dist[c] - dc).abs
          if e < bd
            bd = e
            best = c
          end
          c += 1
        end
        return cq if best.negative?

        reach = (4.0 + 10.0 * @streak + 6.0 / (bd + dc)).round
        a = best - reach < i ? i : best - reach
        b = best + reach > j ? j : best + reach
        alpha = 255 * @chase_a * (1.0 - bd / 0.7)
        fill = [255, 255, 255, alpha.round.clamp(0, 255)]
        cq = trim_quad(@cq, @cq_cmds, cq, @cq_n, a, b, @qa_y, @qa_h, nil, nil, fill)
        trim_quad(@cq, @cq_cmds, cq, @cq_n, a, b, @qb_y, @qb_h, nil, nil, fill)
      end

      # When every ray stays under a roof all the way to its wall, one gradient rect behind the
      # walls is the whole ceiling, and the 240 roof strips rest.
      def ceiling(n, fr, fg, fb, inv_fog)
        ra = @rc.roof_a
        dist = @rc.dist
        rb = @rc.roof_b
        all = true
        i = 0
        while i < n
          if ra[i] < dist[i] - 1e-6 || rb[i] > 0.0
            all = false
            break
          end
          i += 1
        end
        @roofed_view = all
        if all
          up = (1.0 - @camh) * @f
          near = fog_mix(@roof_col, up / @hor, fr, fg, fb, inv_fog)
          far = fog_mix(@roof_col, up / 6.0, fr, fg, fb, inv_fog)
          lean = (@tilt.abs * w / 2.0).round
          set(@ceiling, { hidden: false, top: 0, height: (@hor + lean).round.clamp(1, h), fill: { gradient: [near, far], angle: 0 } })
        elsif @ceiling_on != false
          set(@ceiling, { hidden: true })
        end
        @ceiling_on = all
      end

      # The roof over the camera (a) and the roof that runs up to the wall (b). Between them,
      # or above the wall when neither reaches it, the sky shows.
      def roofs(i, d, top, hor, camh, f, roof, fr, fg, fb, inv_fog)
        ra = @rc.roof_a[i]
        rb = @rc.roof_b[i]
        up = (1.0 - camh) * f
        @sky_at[i] = ra < d - 1e-6 && rb < 0.0
        if ra > 0.0 && @roofed_view
          zero(@roof_a, :a, i)
          @roof_y[i] = top
          @roof_d[i] = ra
        elsif ra > 0.0
          y = ra >= d - 1e-6 ? top + 1.0 : hor - up / ra
          y = 0.0 if y < 0.0
          y = h if y > h
          near = fog_mix(roof, up / (hor > 1.0 ? hor : 1.0), fr, fg, fb, inv_fog)
          far = fog_mix(roof, ra, fr, fg, fb, inv_fog)
          set(@roof_a[i], { top: 0, height: y.round, fill: { gradient: [near, far], angle: 0 } })
          @roof_y[i] = y
          @roof_d[i] = ra
          @zero[:a][i] = false
        else
          zero(@roof_a, :a, i)
          @roof_y[i] = -1.0
          @roof_d[i] = -1.0
        end
        if rb > 0.0
          y = hor - up / rb
          y = 0.0 if y < 0.0
          yb = top + 1.0
          yb = 0.0 if yb < 0.0
          set(@roof_b[i], { top: y.round, height: yb.round - y.round,
                            fill: { gradient: [fog_mix(roof, rb, fr, fg, fb, inv_fog), fog_mix(roof, d, fr, fg, fb, inv_fog)], angle: 0 } })
          @zero[:b][i] = false
        else
          zero(@roof_b, :b, i)
        end
      end

      def fog_mix(c, d, fr, fg, fb, inv_fog)
        k = 1.0 - Math.exp(-d * inv_fog)
        col(c[0] + (fr - c[0]) * k, c[1] + (fg - c[1]) * k, c[2] + (fb - c[2]) * k)
      end

      def col(r, g, b, a = 255)
        [r < 0 ? 0 : (r > 255 ? 255 : r.to_i), g < 0 ? 0 : (g > 255 ? 255 : g.to_i),
         b < 0 ? 0 : (b > 255 ? 255 : b.to_i), a < 0 ? 0 : (a > 255 ? 255 : a.to_i)]
      end

      # ---- sky, sun and floor ---------------------------------------------------------------

      SUN_BANDS = 7

      def build_sky
        @sky = rect(0, 0, w, (h * 0.62).round, fill: gradient(Palette.rgb(SKY_TOP), Palette.rgb(SKY_HORIZON), angle: 0), strokewidth: 0)
        rnd = Random.new(5672)
        @stars = Array.new(@star_n) do
          [rnd.rand * TAU, 0.06 + rnd.rand**1.6 * 0.55, 0.6 + rnd.rand * 1.4,
           rect(-10, -10, 2 * u, 2 * u, fill: Palette.rgb(Palette::INK, 0.4 + rnd.rand * 0.6), strokewidth: 0)]
        end
        @sun_glow = [[Palette::MAGENTA, 0.1], [[255, 110, 150], 0.16]].map do |c, a|
          oval(0, 0, 1, 1, fill: Palette.rgb(c, a), strokewidth: 0)
        end
        @sun = oval(0, 0, 1, 1, fill: gradient(Palette.rgb([255, 240, 130]), Palette.rgb([255, 60, 140]), angle: 0), strokewidth: 0)
        @bands = Array.new(SUN_BANDS) { rect(0, 0, 1, 1, fill: Palette.rgb(SKY_HORIZON), strokewidth: 0) }
      end

      def sky_colour(y)
        k = (y / (h * 0.62)).clamp(0.0, 1.0)
        lerp3(SKY_TOP, SKY_HORIZON, k)
      end

      def draw_sky(t, sync)
        open = 0
        i = 0
        while i < @n
          open += 1 if @sky_at[i] || @roof_d[i].negative?
          i += 2
        end
        sky_layer(open.positive?)
        return if open.zero?

        f = @f
        hor = @hor
        tilt = @tilt
        half_w = w / 2.0
        @stars.each do |az, el, _tw, r|
          rel = wrap(az - @ang)
          if rel.abs > 1.1
            set(r, { left: -10 })
            next
          end
          x = half_w + Math.tan(rel) * f
          y = hor + (x - half_w) * tilt - Math.tan(el) * f
          set(r, { left: x.round(1), top: y.round(1) })
        end
        rel = wrap(SUN_AZ - @ang)
        if rel.abs > 1.2
          set(@sun, { left: -900 })
          @sun_glow.each { |g| set(g, { left: -900 }) }
          @bands.each { |b| set(b, { left: -900 }) }
          glitter(nil, 0, 0, t)
          return
        end
        sx = half_w + Math.tan(rel) * f
        r = 0.17 * f
        sy = hor + (sx - half_w) * tilt - 0.235 * f
        set(@sun, { left: (sx - r).round(1), top: (sy - r).round(1), width: (2 * r).round(1), height: (2 * r).round(1) })
        [2.2, 1.45].each_with_index do |k, j|
          g = r * k * (1.0 + 0.04 * @kick)
          set(@sun_glow[j], { left: (sx - g).round(1), top: (sy - g * 0.8).round(1), width: (2 * g).round(1), height: (1.6 * g).round(1) })
        end
        sun_bands(sx, sy, r, sync)
        c = ((sx / @colw).floor).clamp(0, @n - 1)
        glitter(@sky_at[c] || @roof_d[c].negative? ? sx : nil, r, @hor_at[c] + @camh * @f / @zbuf[c], t)
      end

      # Synthwave cuts across the sun's lower half, thickening toward the bottom, stepping down
      # half a band on every kick.
      def sun_bands(sx, sy, r, sync)
        since = sync.since(:kick)
        step = sync.count(:kick) + (1.0 - Math.exp(-since / 0.07))
        scroll = (step * 0.5) % 1.0
        nb = SUN_BANDS
        @bands.each_with_index do |b, k|
          fy = (k + scroll) / nb
          y = sy + r * (0.08 + 0.9 * fy)
          th = r * (0.018 + 0.11 * fy)
          dy = y + th / 2 - sy
          chord = r * r - dy * dy
          if chord <= 0.0
            set(b, { left: -900 })
            next
          end
          half = Math.sqrt(chord) + 1.0
          c = lerp3(sky_colour(y), [200, 40, 120], 0.35)
          set(b, { left: (sx - half).round(1), top: y.round(1), width: (2 * half).round(1), height: th.round(1), fill: col(*c) })
        end
      end

      GLITTER_BANDS = 14
      GLITTER_GAP = 0.9 # world spacing of the ripples the sun's streak breaks into

      # The sun's reflection on the glossy floor: a soft gold streak straight down from the
      # horizon, broken into ripples that shimmer and stream toward the camera as it moves.
      def glitter(sx, r, base, t)
        on = !sx.nil?
        shown = @glitter_shown ||= Array.new(@glitter.size, false)
        unless on
          @glitter.each_with_index { |g, k| set(g, { hidden: true }) if shown[k] } if @glitter_on
          shown.fill(false)
          @glitter_on = false
          return
        end
        show = !shown[0]
        shown[0] = true
        f = @f
        hor = @hor
        ground = @camh * f
        bottom = h.to_f
        streak = { left: (sx - r * 0.22).round(1), top: base.round(1), width: (r * 0.44).round(1), height: (bottom - base).round(1),
                   fill: { gradient: [[255, 222, 140, 120], [255, 60, 140, 0]], angle: 0 } }
        streak[:hidden] = false if show
        set(@glitter[0], streak)
        scroll = @s % GLITTER_GAP
        GLITTER_BANDS.times do |k|
          z = 1.2 + k * GLITTER_GAP - scroll
          z += GLITTER_GAP * GLITTER_BANDS if z < 1.2
          y = hor + ground / z
          if y < base
            set(@glitter[k + 1], { hidden: true }) if shown[k + 1]
            shown[k + 1] = false
            next
          end

          gap = ground / z - ground / (z + GLITTER_GAP)
          q = ((y - hor) / (bottom - hor)).clamp(0.0, 1.0)
          wob = 0.75 + 0.25 * Math.sin(t * 7.0 + k * 2.3)
          wide = r * (0.7 + 0.5 * q) * wob
          c = lerp3([255, 236, 160], Palette::MAGENTA, q**0.7)
          a = 200 * (1.0 - q)**1.2 * (0.7 + 0.3 * @kick)
          props = { left: (sx - wide / 2 + r * 0.08 * Math.sin(t * 3.1 + k)).round(1), top: y.round(1), width: wide.round(1),
                    height: [gap * 0.38, 1.0].max.round(1), fill: col(c[0], c[1], c[2], a) }
          props[:hidden] = false unless shown[k + 1]
          shown[k + 1] = true
          set(@glitter[k + 1], props)
        end
        @glitter_on = true
      end

      # Under a roof the whole way the sky is never seen: hide it rather than paint it.
      def sky_layer(on)
        return if on == @sky_on

        @sky_on = on
        ([@sky, @sun] + @sun_glow + @bands + @stars.map(&:last)).each { |d| set(d, { hidden: !on }) }
        glitter(nil, 0, 0, 0.0) unless on
      end

      def draw_overlays(t, sync)
        lean = (@tilt.abs * w / 2.0).round
        hor = (@hor - lean).round
        set(@floor, { top: hor, height: h.round - hor, fill: { gradient: [col(*@fog), col(*@near_floor)], angle: 0 } })
        since = @shoe_t.map { |ct| t - ct }.select { |x| x >= 0 }.min
        gold = since ? 0.18 * Math.exp(-since / 0.12) : 0.0
        crash = t >= HALL_AT ? 0.9 * Math.exp(-((t - HALL_AT) / 0.075)**1.3) : 0.0
        fill = crash > gold ? [255, 248, 252, (crash * 255).round] : [255, 201, 77, (gold * 255).round]
        veil(@flash, :flash, fill)
        white = smooth(END_AT - 0.25, END_AT, t)**1.5
        veil(@glare, :glare, [255, 250, 252, (white * 255).round])
      end

      # A full-screen rect costs a full-screen blend even when clear, so a clear one hides.
      def veil(rect, key, fill)
        @veils ||= {}
        on = fill[3].positive?
        if on
          props = { fill: fill }
          props[:hidden] = false unless @veils[key]
          set(rect, props)
        elsif @veils[key] != false
          set(rect, { hidden: true })
        end
        @veils[key] = on
      end

      # The doorway at the end of the last corridor blooms as the camera closes on it: stacked
      # translucent ovals and a soft bar, sized by its distance.
      def draw_bloom
        d = (@door_x - @px) * @dx + (15.5 - @py) * @dy
        lat = (@door_x - @px) * -@dy + (15.5 - @py) * @dx
        on = @s > @s_exit + 2.0 && d > 0.3
        unless on
          @bloom.each { |b| set(b, { hidden: true }) } if @bloom_on
          @bloom_on = false
          return
        end
        sx = w / 2.0 + lat / d * @f
        sy = @hor + (sx - w / 2.0) * @tilt
        dh = 0.5 * @f / d
        heat = smooth(@s_end - 44.0, @s_end - 4.0, @s)
        cap = w * 0.75
        [[5.2, 0.05], [3.4, 0.08], [2.2, 0.13], [1.4, 0.2]].each_with_index do |(k, a), j|
          r = dh * k
          r = cap if r > cap
          set(@bloom[j], { hidden: false, left: (sx - r).round(1), top: (sy - r * 0.8).round(1), width: (2 * r).round(1), height: (1.6 * r).round(1),
                           fill: [255, 236, 250, (255 * a * heat).round] })
        end
        bar = [dh * 9.0, w.to_f].min
        set(@bloom[4], { hidden: false, left: (sx - bar).round(1).clamp(0.0, w.to_f), top: (sy - dh * 0.12).round(1), width: (2 * bar).round(1).clamp(0.0, w.to_f),
                         height: (dh * 0.24).round(1), fill: [255, 255, 255, (110 * heat).round] })
        @bloom_on = true
      end

      # ---- floor and ceiling grid: real projected lines ---------------------------------------

      # Cell edges worth drawing, by cell: bit 1 west floor, 2 north floor, 4 west roof, 8 north roof.
      def grid_edges
        rc = @rc
        cols = rc.cols
        floorish = lambda do |x, y|
          rc.inside?(x, y) && [0, M::PILLAR, M::DOOR].include?(rc.cells[y * cols + x])
        end
        roofed = ->(x, y) { rc.inside?(x, y) && rc.cells[y * cols + x].zero? && rc.roofs[y * cols + x] }
        @edges = Array.new(rc.rows * cols, 0)
        rc.rows.times do |y|
          cols.times do |x|
            e = 0
            e |= 1 if floorish.call(x - 1, y) || floorish.call(x, y)
            e |= 2 if floorish.call(x, y - 1) || floorish.call(x, y)
            e |= 4 if roofed.call(x - 1, y) || roofed.call(x, y)
            e |= 8 if roofed.call(x, y - 1) || roofed.call(x, y)
            @edges[y * cols + x] = e
          end
        end
        r = GRID_R
        @spiral = (-r..r).to_a.product((-r..r).to_a).select { |a, b| a * a + b * b <= r * r + r }.sort_by { |a, b| a * a + b * b }
      end

      def draw_grid
        cols = @rc.cols
        rows = @rc.rows
        cx = @px.floor
        cy = @py.floor
        nf = 0
        nc = 0
        fmax = @floor_n
        cmax = @ceil_n
        alpha_f = 0.62 * @pulse
        alpha_c = 0.34 * @pulse
        @spiral.each do |ox, oy|
          x = cx + ox
          y = cy + oy
          next if x < 0 || y < 0 || x >= cols || y >= rows

          e = @edges[y * cols + x]
          next if e.zero?

          if e & 5 != 0
            nf, nc = edge(x, y, x, y + 1, e & 1 != 0, e & 4 != 0, nf, nc, fmax, cmax, alpha_f, alpha_c)
          end
          if e & 10 != 0
            nf, nc = edge(x, y, x + 1, y, e & 2 != 0, e & 8 != 0, nf, nc, fmax, cmax, alpha_f, alpha_c)
          end
          break if nf >= fmax && nc >= cmax
        end
        hide_unused(@grid, nf, 0)
        hide_unused(@ceil, nc, 1)
      end

      def edge(ax, ay, bx, by, flo, cei, nf, nc, fmax, cmax, alpha_f, alpha_c)
        dx = @dx
        dy = @dy
        rx = -dy
        ry = dx
        az = (ax - @px) * dx + (ay - @py) * dy
        bz = (bx - @px) * dx + (by - @py) * dy
        return [nf, nc] if az < NEAR && bz < NEAR

        al = (ax - @px) * rx + (ay - @py) * ry
        bl = (bx - @px) * rx + (by - @py) * ry
        if az < NEAR
          k = (NEAR - az) / (bz - az)
          al += (bl - al) * k
          az = NEAR
        elsif bz < NEAR
          k = (NEAR - bz) / (az - bz)
          bl += (al - bl) * k
          bz = NEAR
        end
        f = @f
        half_w = w / 2.0
        sxa = half_w + al / az * f
        sxb = half_w + bl / bz * f
        return [nf, nc] if (sxa < 0 && sxb < 0) || (sxa > w && sxb > w)

        mz = (az + bz) / 2
        mx = (sxa + sxb) / 2
        c = (mx / @colw).floor
        if c >= 0 && c < @n
          return [nf, nc] if @zbuf[c] < mz - 0.02 && (sxa - sxb).abs < 3 * @colw
        end
        fade = 1.0 - mz / (GRID_R + 0.5)
        return [nf, nc] if fade <= 0.0

        fade *= fade
        ha = @hor + (sxa - half_w) * @tilt
        hb = @hor + (sxb - half_w) * @tilt
        if flo && nf < @floor_n
          line_to(@grid, nf, 0, sxa, ha + @camh * f / az, sxb, hb + @camh * f / bz, @grid_col, alpha_f * fade)
          nf += 1
        end
        if cei && nc < @ceil_n
          up = (1.0 - @camh) * f
          line_to(@ceil, nc, 1, sxa, ha - up / az, sxb, hb - up / bz, @ceil_col, alpha_c * fade)
          nc += 1
        end
        [nf, nc]
      end

      def line_to(pool, i, which, x1, y1, x2, y2, c, a)
        props = { left: x1.round(1), top: y1.round(1), x2: x2.round(1), y2: y2.round(1), stroke: col(c[0], c[1], c[2], a * 255) }
        props[:hidden] = false if i >= @lines_on[which]
        set(pool[i], props)
      end

      def hide_unused(pool, used, which)
        (used...@lines_on[which]).each { |i| set(pool[i], { hidden: true }) }
        @lines_on[which] = used
      end

      # ---- sprites: billboards cut into column slices against the depth buffer ----------

      # [kind, x, y, z, size, colour, light, phase, own cell (or -1)]
      def build_sprites
        sp = []
        M::ROOM_ORBS.each { |x, y, z, c| sp << [ORB, x, y, z, 0.13, COLOURS[c], 1.6, 0.0, -1] }
        M::CORRIDOR_LAMPS.each { |x, y, z, c| sp << [ORB, x, y, z, 0.1, COLOURS[c], 1.4, 0.0, -1] }
        cx, cy = M::HALL_CENTRE
        M::PILLARS.each do |i, j|
          ring = (i + j).even? ? Palette::GOLD : Palette::MAGENTA
          x = cx + i
          y = cy + j
          sp << [ORB, x, y, PILLAR_H + 0.34, 0.2, ring, 0.0, (i + j) * 0.37, @rc.index(x, y)]
        end
        @high_orbs = sp.size
        6.times { |k| sp << [ORB, cx, cy, 1.75, 0.14, k.even? ? Palette::CYAN : Palette::GOLD, 0.0, k * TAU / 6, -1] }
        @big_gem = sp.size
        sp << [GEM, cx, cy, 0.9, 0.95, Palette::RUBY, 2.0, 0.0, -1]
        @small_gems = sp.size
        6.times { |k| sp << [GEM, cx, cy, 0.9, 0.3, k.even? ? Palette::RUBY : AMETHYST, 0.0, k * TAU / 6, -1] }
        @first_shoe = sp.size
        @shoe_s.each_with_index { |s, k| sp << [SHOE, @path.x_at(s), @path.y_at(s), 0.36, 0.32, Palette::MAGENTA, 0.0, k * 1.3, -1] }
        @sprites = sp
        @light_src = M::ROOM_ORBS.map { |x, y, _z, c| [x, y, COLOURS[c], 1.6] } +
                     M::CORRIDOR_LAMPS.map { |x, y, _z, c| [x, y, COLOURS[c], 1.3] } +
                     [[cx, cy, Palette::RUBY, 2.5]]
        @vis = []
        @gem_list = []
        @shoe_list = []
        @gem_runs = []
      end

      # ---- gems: faceted solids, painted far to near --------------------------------------

      # The share of a gem's columns not hidden behind a nearer wall (0.0 when none show).
      def gem_seen(sx, half, depth)
        c0 = ((sx - half) / @colw).floor.clamp(0, @n - 1)
        c1 = ((sx + half) / @colw).floor.clamp(0, @n - 1)
        open = 0
        (c0..c1).each { |c| open += 1 if @zbuf[c] > depth - half / @f * depth }
        open.fdiv(c1 - c0 + 1)
      end

      # The screen bands a gem shows through, or nil when nothing stands in front of it.
      def gem_runs(sx, half, depth, r)
        c0 = ((sx - half * 1.4) / @colw).floor
        c1 = ((sx + half * 1.4) / @colw).floor
        c0 = 0 if c0 < 0
        c1 = @n - 1 if c1 >= @n
        runs = @gem_runs.clear
        all = true
        start = nil
        (c0..c1).each do |c|
          if @zbuf[c] > depth - r
            start ||= c
          else
            all = false
            if start
              runs << @x0[start].to_f << (@x0[c - 1] + @xw[c - 1]).to_f
              start = nil
            end
          end
        end
        return nil if all

        runs << @x0[start].to_f << (@x0[c1] + @xw[c1]).to_f if start
        runs
      end

      # Pickups far to near, shrinking as the camera takes them, then the burst of the latest.
      def draw_shoes(t)
        pool = @shoe_shapes
        pool.begin_frame
        list = @shoe_list
        i = list.size - 5
        while i >= 0
          depth, sx, zc, half, k = list[i, 5]
          sp = @sprites[k]
          take = 0.3 + 0.7 * smooth(0.3, 1.5, depth)
          half *= take
          hgt = sp[4] * 0.62 * @f / depth * take
          zc -= (1.0 - take) * hgt * 0.8
          spin = t * 2.2 + sp[7]
          fogk = (1.0 - Math.exp(-depth / @fog_len)) * 0.7
          runs = gem_runs(sx, half, depth, 0.1)
          if runs.nil? || !runs.empty?
            @shoes.draw(sx, zc, half, hgt, spin, sp[5], @fog, fogk, runs)
            face = Math.cos(spin).abs**12
            @shoes.glint(sx + half * 0.5 * Math.cos(spin), zc - hgt * 0.1, half * 0.9 * face, 220 * face) if face > 0.05
          end
          i -= 5
        end
        since = @shoe_t.map { |ct| t - ct }.select { |x| x >= 0 }.min
        if since && since < 0.5
          k = since / 0.5
          x = w / 2.0
          y = @hor + 0.16 * @f
          r = h * (0.12 + 0.5 * Math.sqrt(k))
          @shoes.ring(x, y, r, (10.0 - 8.0 * k) * u, [255, 214, 110, (230 * (1.0 - k)**1.5).round])
          @shoes.ring(x, y, r * 0.62, (5.0 - 4.0 * k) * u, [255, 255, 255, (200 * (1.0 - k)**2).round]) if k < 0.7
          @shoes.burst(x, y, r * 1.1, k, density < 0.6 ? 6 : 12)
        end
        pool.end_frame
      end

      def draw_gems(gems, t)
        pool = @gem_shapes
        pool.begin_frame
        cam = @gem_cam ||= Array.new(9, 0.0)
        cam[0] = @px
        cam[1] = @py
        cam[2] = @camh
        cam[3] = @dx
        cam[4] = @dy
        cam[5] = @f
        cam[6] = @hor
        cam[7] = @tilt
        cam[8] = w / 2.0
        lead = @lead
        glint = nil
        i = gems.size - 7
        while i >= 0
          k = gems[i]
          sp = @sprites[k]
          depth = gems[i + 4]
          big = k == @big_gem
          r = sp[4] * 0.5
          runs = gem_runs(gems[i + 5], gems[i + 6], depth, r)
          if runs.nil? || !runs.empty?
            spin = big ? t * 0.9 : t * 1.7 + sp[7]
            fogk = (1.0 - Math.exp(-depth / @fog_len)) * (big ? 0.45 : 0.6)
            hit = @gems.draw(cam, gems[i + 1], gems[i + 2], gems[i + 3], r, spin, sp[5], big, runs, @fog, fogk, lead)
            glint = [hit[0], hit[1], hit[2], gems[i + 6]] if big && hit
          end
          i -= 7
        end
        if glint
          bx, by, strength, half = glint
          size = half * (0.35 + 0.9 * lead) * [strength, 1.6].min
          @gems.star(bx, by, size, 235 * [strength, 1.0].min) if size > 2.0 * u
        end
        pool.end_frame
      end

      def sprite_xy(k, t, sync)
        sp = @sprites[k]
        if k >= @small_gems && k < @first_shoe
          a = sp[7] + t * 0.7
          r = 1.55 + 0.4 * sync.hit(:lead2, 0.35)
          [sp[1] + Math.cos(a) * r, sp[2] + Math.sin(a) * r, 0.95 + 0.22 * Math.sin(a * 2 + t)]
        elsif k >= @high_orbs && k < @big_gem
          a = sp[7] - t * 0.45
          [sp[1] + Math.cos(a) * 2.7, sp[2] + Math.sin(a) * 2.7, sp[3] + 0.12 * Math.sin(t * 1.1 + sp[7])]
        elsif k == @big_gem
          [sp[1], sp[2], sp[3] + 0.06 * Math.sin(t * 1.7)]
        elsif sp[0] == SHOE
          [sp[1], sp[2], sp[3] + 0.05 * Math.sin(t * 4 + sp[7])]
        elsif sp[6].zero?
          [sp[1], sp[2], sp[3] + 0.04 * Math.sin(t * 2.3 + sp[7])]
        else
          [sp[1], sp[2], sp[3]]
        end
      end

      def draw_sprites(t, sync)
        vis = @vis
        vis.clear
        f = @f
        dx = @dx
        dy = @dy
        got = collected(t)
        @lead = sync.hit(:lead, 0.25)
        @sprites.each_index do |k|
          next if k >= @first_shoe && k - @first_shoe < got

          x, y, z = sprite_xy(k, t, sync)
          rx = x - @px
          ry = y - @py
          next if rx.abs > 24 || ry.abs > 24

          depth = rx * dx + ry * dy
          next if depth < 0.25

          lat = rx * -dy + ry * dx
          sx = w / 2.0 + lat / depth * f
          size = @sprites[k][4]
          half = size * 0.5 * f / depth
          next if sx + half * 2.6 < 0 || sx - half * 2.6 > w

          vis << [depth, k, sx, z, half, x, y]
        end
        vis.sort_by!(&:first)
        gems = @gem_list.clear
        @shoe_list.clear

        slot = @slice_n
        halos = 0
        pools = 0
        orbs = 0
        vis.each do |depth, k, sx, z, half, x, y|
          sp = @sprites[k]
          zc = @hor + (sx - w / 2.0) * @tilt - (z - @camh) * f / depth
          if sp[0] == GEM
            seen = gem_seen(sx, half, depth)
            next if seen.zero?

            gems << k << x << y << z << depth << sx << half
            total = 1
          elsif sp[0] == SHOE
            seen = gem_seen(sx, half, depth)
            next if seen.zero?

            @shoe_list << depth << sx << zc << half << k
            if pools < @pool_n && depth > 0.6
              pool(pools, sp, depth, sx, half, pools >= @pools_on)
              pools += 1
            end
            next
          elsif sp[0] == ORB && orbs < @orb_n && in_clear(depth, sx, zc, half, sp[8])
            orb_oval(orbs, sp, depth, sx, zc, half)
            orbs += 1
            seen = total = 1
          else
            slot, seen, total = slices(sp, depth, sx, zc, half, slot)
            next if total.zero?
          end

          if halos < @halo_n && seen > 0 && sp[0] != SHOE
            halo(halos, sp, depth, sx, zc, half, seen.fdiv(total), halos >= @halos_on)
            halos += 1
          end
          if pools < @pool_n && depth > 0.6 && sp[8].negative? && (k <= @big_gem || k >= @first_shoe)
            pool(pools, sp, depth, sx, half, pools >= @pools_on)
            pools += 1
          end
        end
        draw_gems(gems, t)
        draw_shoes(t)
        (orbs...@orbs_on).each do |i|
          set(@orb_body[i], { hidden: true })
          set(@orb_core[i], { hidden: true })
        end
        @orbs_on = orbs
        ((halos * 3)...(@halos_on * 3)).each { |i| set(@halos[i], { hidden: true }) }
        @halos_on = halos
        ((pools * 3)...(@pools_on * 3)).each { |i| set(@pools[i], { hidden: true }) }
        @pools_on = pools
        (@slices_on...slot).each do |i|
          if @slice_shown[i]
            set(@slice_a[i], { hidden: true })
            @slice_shown[i] = false
          end
        end
        @slices_on = slot
      end

      # Cuts an orb that something stands in front of into column slices, taking pool slots
      # downward from `slot` so nearer orbs (handled first) sit later in paint order. Returns
      # [slot, columns seen, columns].
      def slices(sp, depth, sx, zc0, half, slot)
        colw = @colw
        tilt = @tilt
        own = sp[8]
        cells = @rc.cell
        c0 = ((sx - half) / colw).floor
        c1 = ((sx + half) / colw).floor
        c0 = 0 if c0 < 0
        c1 = @n - 1 if c1 >= @n
        return [slot, 0, 0] if c1 < c0

        hgt = sp[4] * @f / depth
        base = sp[5]
        fogk = (1.0 - Math.exp(-depth / @fog_len)) * 0.35
        fr, fg, fb = @fog
        glow = 0.85 + 0.3 * @kick
        seen = 0
        total = c1 - c0 + 1
        (c0..c1).each do |c|
          left = @x0[c]
          width = @xw[c]
          mid = left + width * 0.5
          s = (mid - sx) / half
          next if s <= -1.0 || s >= 1.0

          zc = zc0 + (mid - sx) * tilt
          r = Math.sqrt(1.0 - s * s)
          ta = zc - hgt * 0.5 * r
          tb = zc + hgt * 0.5 * r
          if @zbuf[c] < depth && !(own >= 0 && cells[c] == own)
            next unless @sky_at[c]

            tb = @wtop[c] if tb > @wtop[c]
          end
          ta = @roof_y[c] if @roof_d[c] > 0.0 && depth > @roof_d[c] && ta < @roof_y[c]
          next if tb - ta < 0.5
          break if slot.zero?

          slot -= 1
          seen += 1
          hot = r * r * 127.5
          lit = (0.55 + 0.45 * r) * 0.7
          ca = fogged([base[0] * 0.5 + hot, base[1] * 0.5 + hot, base[2] * 0.5 + hot], fogk, fr, fg, fb, glow)
          cb = fogged([base[0] * lit, base[1] * lit, base[2] * lit], fogk, fr, fg, fb, glow)
          slice_set(@slice_a, @slice_shown, slot, left, width, ta, tb - ta, { gradient: [ca, cb], angle: 0 })
        end
        [slot, seen, total]
      end

      # True when nothing stands between the camera and this orb in any column it covers, so
      # it can be a round oval instead of strips. An orb on a column's top ignores its column.
      def in_clear(depth, sx, zc, half, own)
        c0 = ((sx - half) / @colw).floor
        c1 = ((sx + half) / @colw).floor
        return false if c0 < 0 || c1 >= @n

        top = zc - half
        bot = zc + half
        cells = @rc.cell
        c = c0
        while c <= c1
          if @zbuf[c] < depth && !(own >= 0 && cells[c] == own)
            return false unless @sky_at[c] && bot <= @wtop[c]
          end
          return false if @roof_d[c] > 0.0 && depth > @roof_d[c] && top < @roof_y[c]

          c += 1
        end
        true
      end

      def orb_oval(i, sp, depth, sx, zc, half)
        r = half
        fogk = (1.0 - Math.exp(-depth / @fog_len)) * 0.35
        fr, fg, fb = @fog
        glow = 0.85 + 0.3 * @kick
        c = sp[5]
        top = fogged([c[0] * 0.45 + 150, c[1] * 0.45 + 150, c[2] * 0.45 + 150], fogk, fr, fg, fb, glow)
        low = fogged([c[0] * 0.95, c[1] * 0.95, c[2] * 0.95], fogk, fr, fg, fb, glow)
        show = i >= @orbs_on
        body = { left: (sx - r).round(1), top: (zc - r).round(1), width: (2 * r).round(1), height: (2 * r).round(1),
                 fill: { gradient: [top, low], angle: 0 } }
        body[:hidden] = false if show
        set(@orb_body[i], body)
        k = r * 0.42
        core = { left: (sx - k - r * 0.18).round(1), top: (zc - k - r * 0.22).round(1), width: (2 * k).round(1), height: (2 * k).round(1),
                 fill: col(255, 250, 255, 220 * (1.0 - fogk)) }
        core[:hidden] = false if show
        set(@orb_core[i], core)
      end

      def fogged(c, fogk, fr, fg, fb, glow)
        keep = 1.0 - fogk
        col(c[0] * glow * keep + fr * fogk, c[1] * glow * keep + fg * fogk, c[2] * glow * keep + fb * fogk)
      end

      def slice_set(pool, shown, i, left, width, top, height, fill)
        y0 = top < 0 ? 0 : top.round
        y1 = top + height > h ? h.round : (top + height).round
        props = { left: left, width: width, top: y0, height: y1 > y0 ? y1 - y0 : 0, fill: fill }
        unless shown[i]
          props[:hidden] = false
          shown[i] = true
        end
        set(pool[i], props)
      end

      HALO_RINGS = [[3.0, 0.07], [2.1, 0.14], [1.4, 0.26]].freeze

      # Three nested discs per light, outermost first, so the glow falls away instead of
      # ending at a hard rim. Near the camera the rings are held to a third of the height.
      def halo(slot, sp, depth, sx, y, half, frac, show)
        gem = sp[0] == GEM
        base = half * (gem ? 0.8 : 1.0)
        scale = base * 3.0 > h * 0.34 ? h * 0.34 / (base * 3.0) : 1.0
        strength = (gem ? 0.55 : 1.0) * frac * (0.8 + 0.4 * @kick)
        c = sp[5]
        HALO_RINGS.each_with_index do |(k, a), j|
          r = base * k * scale
          props = { left: (sx - r).round(1), top: (y - r).round(1), width: (2 * r).round(1), height: (2 * r).round(1),
                    fill: col(c[0], c[1], c[2], a * strength * 255) }
          props[:hidden] = false if show
          set(@halos[slot * 3 + j], props)
        end
      end

      POOL_RINGS = [[1.0, 0.05], [0.72, 0.08], [0.46, 0.12]].freeze

      # The light an orb throws on the floor, as three soft nested ovals that fade out before
      # they reach the camera.
      def pool(slot, sp, depth, sx, half, show)
        f = @f
        rr = sp[0] == GEM ? sp[4] * 1.2 : sp[4] * 3.0
        near_fade = smooth(0.7, 1.6, depth)
        strength = (sp[0] == SHOE ? 0.6 : 1.0) * (0.8 + 0.4 * @kick) * Math.exp(-depth / (@fog_len * 1.4)) * near_fade
        c = sp[5]
        cap = w * 0.25
        POOL_RINGS.each_with_index do |(k, a), j|
          r = rr * k
          near = depth - r
          near = 0.4 if near < 0.4
          y0 = @hor + @camh * f / (depth + r)
          y1 = @hor + @camh * f / near
          y0 += (sx - w / 2.0) * @tilt
          y1 += (sx - w / 2.0) * @tilt
          y1 = h + 2.0 if y1 > h + 2.0
          rw = r * f / depth
          rw = cap * k if rw > cap * k
          props = { left: (sx - rw).round(1), top: y0.round(1), width: (2 * rw).round(1), height: (y1 - y0).round(1).clamp(0.0, h.to_f),
                    fill: col(c[0], c[1], c[2], a * strength * 255) }
          props[:hidden] = false if show
          set(@pools[slot * 3 + j], props)
        end
      end

      # ---- radar ----------------------------------------------------------------------------

      def build_radar
        r = 50 * u
        @radar = MazeRadar.new(self, @rc, cx: w - r - 18 * u, cy: r + 18 * u, radius: r,
          roofed: Palette.rgb(Palette::VIOLET, 0.8), open: Palette.rgb(Palette::GOLD, 0.45), door: Palette.rgb(Palette::INK),
          cells: [M::LIGHT, M::DOOR])
        @radar.build
      end
    end
  end
end
