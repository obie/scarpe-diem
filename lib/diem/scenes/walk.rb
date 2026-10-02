# frozen_string_literal: true

require_relative "maze"
require_relative "../walk_player"
require_relative "../walk_text"
require_relative "../walk_fireworks"

module Diem
  module Scenes
    # The after-party: WOLFENSHOES 3D with you at the controls. It is the Maze scene's own
    # renderer (every strip, trim, roof, sky, gem and radar of it), fed a camera you drive
    # instead of the autopilot. Seven lost shoes glow in the dead ends, the hall and the
    # white room at the end of the last corridor; walk into one to take it. Find all seven and
    # the sky fills with fireworks while the maze section of the song loops on.
    #
    # The engine drives it (start_walk, walk_step): update(t, sync) every frame with t the
    # seconds since the walk began and sync looping bars 56-72, key(k) for every key press
    # but Escape. The mouse is polled every frame: hold button 1 to walk, and steer by how far
    # the pointer stands from the middle of the window.
    class Walk < Maze
      SHOES = WalkHunt::SHOES
      START = WalkHunt::START
      TAKE = WalkHunt::TAKE
      GEM_R = WalkHunt::GEM_R
      DT = 1.0 / 120
      MAX_STEPS = 40   # after a stall the clock catches up instead of replaying it
      HINT_FROM = 2.6  # the hint waits for the title to go
      HINT_TO = 8.6
      POP_FOR = 1.12   # "3 OF 7" slams in, holds, then its number flies into the counter
      FLY = 0.24       # the flight's length, ending at POP_FOR
      SETTLE = 0.3     # the new digit lands big and white, then settles into the counter's gold
      LAND_SCALE = 1.45
      WHITE = [[255, 255, 255]] * 5 + [[255, 246, 214]] * 2
      # the chrome without its dark band, for the banner's small letters
      BANNER_CHROME = [[255, 255, 255], [214, 242, 255], [160, 214, 255], [255, 200, 236], [255, 150, 214],
                       [255, 96, 172], [226, 54, 134]].freeze
      BANNER_AT = 7.0  # the finale's words make way for the walk: a banner at the top
      BANNER_FOR = 0.9
      GLOW_N = 32
      # the last shoe glows deep magenta, not gold, against the white room's haze
      GLOWS = [[255, 196, 90]] * 6 + [[214, 20, 150]]
      HINT = "arrows or WASD to move  ·  hold the mouse to walk and steer  ·  esc to leave"
      MOVE = "move_to"
      LINE = "line_to"
      KEYS = {
        "up" => :fwd, "w" => :fwd, "down" => :back, "s" => :back, "left" => :left, "right" => :right,
        "a" => :sleft, "d" => :sright,
      }.freeze

      def build
        super
        @player = WalkPlayer.new(@rc, blockers: [[*M::HALL_CENTRE, GEM_R]])
        @rcx = @radar.cx
        @rcy = @radar.cy
        @rr = @radar.r
        total = SHOES.size
        # where the counter's digit stands, for the pop to fly into
        cpx = 3.0 * u
        @digit_x = 16 * u + (Bitfont.width("SHOES") + 3 + 2.5) * cpx
        @digit_y = 16 * u + 3.5 * cpx
        @digit_p = cpx
        @pop_num = WalkText.new(self)
        @pop_rest = WalkText.new(self)
        @line1 = WalkText.new(self, layers: %i[shadow outline cyan magenta face])
        @line2 = WalkText.new(self, layers: %i[outline cyan magenta face])
        @line3 = WalkText.new(self, layers: %i[outline face])
        @fireworks = WalkFireworks.new(self, sky: method(:sky_at?))
        @spray = WalkSpray.new(self)
        draw do
          nostroke
          @got_dots = Array.new(total) { rect(0, 0, (4 * u).round, (4 * u).round, fill: Palette.rgb(Palette::GOLD), strokewidth: 0, hidden: true) }
          # far shoes: one shape of little chevrons on the radar's rim, pointing the way out
          @pip_shape = shape(0, 0, fill: Palette.rgb(Palette::MAGENTA, 0.85), strokewidth: 0)
          pad = 2.5 * cpx
          wide = (Bitfont.width("SHOES") + 3 + 6 + Bitfont.width("/#{total}")) * cpx
          # the counter's box, for the ring that flashes round it as a find lands
          @box = [(16 * u - pad).round, (16 * u - pad).round, (wide + 2 * pad).round, (7 * cpx + 2 * pad).round]
          @land = rect(*@box, fill: Palette.rgb(Palette::NIGHT, 0.0), stroke: Palette.rgb(Palette::GOLD, 0.0),
            strokewidth: (2 * u).round, hidden: true)
          @spray.build
          @fireworks.build
          [@pop_rest, @pop_num, @line1, @line2, @line3].each(&:build)
          bw = (680 * u).round
          @hint_bg = rect(((w - bw) / 2.0).round, (h - 54 * u).round, bw, (30 * u).round, curve: (15 * u).round,
            fill: Palette.rgb(Palette::NIGHT, 0.6), strokewidth: 0)
          @hint = para(HINT, left: 0, top: (h - 46 * u).round, width: w.round, align: "center", size: (13 * u).round,
            stroke: Palette.rgb(Palette::INK, 0.9), font: "Menlo, monospace", margin: 0)
        end
        @prev = Array.new(7, 0.0)
        @gx = Array.new(GLOW_N, 0.0)
        @gy = Array.new(GLOW_N, 0.0)
        @gox = Array.new(GLOW_N + 8, 0.0)
        @goy = Array.new(GLOW_N + 8, 0.0)
        @gtx = Array.new(GLOW_N + 8, 0.0)
        @gty = Array.new(GLOW_N + 8, 0.0)
        @marks_left = []
        @pip_cmds = []
        @pip_key = nil
      end

      def enter
        super
        @player.reset(*START)
        @sim_t = 0.0
        @alpha = 1.0
        @t_now = 0.0
        @got = 0
        @got_at = Array.new(SHOES.size)
        @shoe_t.fill(1e9)
        @last_got = nil
        @done_at = nil
        @door_seen = false
        @bloom_vis = 0.0
        SHOES.each_with_index do |(x, y), k|
          sp = @sprites[@first_shoe + k]
          sp[1] = x
          sp[2] = y
        end
        @light_src -= @shoe_lights
        @light_src.concat(@shoe_lights)
        [@pop_rest, @pop_num, @line1, @line2, @line3].each(&:enter)
        @fireworks.enter
        @spray.enter
        @got_dots.each { |d| set(d, { hidden: true }) }
        set(@pip_shape, { shape_commands: [] })
        @pip_key = nil
        @dot_on = Array.new(SHOES.size, false)
        @pop_white = false
        @hint_alpha = nil
        @land_a = nil
        @dusk_k = nil
        @night = 1.0
        @dusk = 0.0
        @burst_x = w / 2.0
        @burst_y = h * 0.62
        lab_start
        snap(@prev)
      end

      def key(k)
        action = KEYS[k.to_s.downcase]
        @player.press(action, @t_now) if action
      end

      def update(t, sync)
        simulate(t)
        pose(t, sync)
        environment(t, sync)
        @door_open = @player.door_open
        @door_seen ||= @door_open > 0.3 || @py > 11.6
        @rc.open_door(*M::DOOR_CELL, @door_open)
        @rc.cast(@px, @py, @dx, @dy, @plx, @ply, @n)
        draw_columns(0.0, sync)
        along = @s
        @s = @odo # the sun's ripples on the floor stream past as you walk
        draw_sky(t, sync)
        @s = along
        draw_grid
        draw_sprites(t, sync)
        draw_bloom
        @radar.update(@px, @py, @dx, @dy, @tan_half, marks_left, sky: @door_seen)
        radar_marks
        @counter.update(landed(t))
        @title.update(t, sync)
        draw_overlays(t, sync)
        draw_pop(t)
        draw_finale(t, sync)
        draw_hint(t)
        @t_now = t
      end

      private

      # ---- the body and the hunt ----------------------------------------------------------

      # Maze's world without its route's shoes: the seven lost ones take their place.
      def setup_world
        super
        @shoe_s = []
        @shoe_t = Array.new(SHOES.size, 1e9)
      end

      def shoe_total = SHOES.size

      # Maze's sprites, then the seven lost shoes, each a warm light on the walls around it
      # until it is found.
      def build_sprites
        super
        SHOES.each_with_index { |(x, y), k| @sprites << [SHOE, x, y, 0.36, 0.34, Palette::MAGENTA, 0.0, k * 1.3, -1] }
        @shoe_lights = SHOES.map { |x, y| [x, y, Palette::GOLD, 1.5] }
        @light_src.concat(@shoe_lights)
      end

      def collected(_t) = 0 # found shoes leave the world instead (see pick_up)

      # Fixed 1/120 s steps run until the body is at or just past t; the camera then shows the
      # blend of the last two steps that stands at t exactly, so motion is as smooth as the
      # frames are, whatever whole number of steps each one takes.
      def simulate(t)
        mouse = mouse_offset
        steps = 0
        while @sim_t < t && steps < MAX_STEPS
          snap(@prev)
          @player.step(@sim_t, DT, mouse)
          @sim_t += DT
          steps += 1
          pick_up(@sim_t)
        end
        if @sim_t < t # after a stall the clock catches up instead of replaying it
          @sim_t = t
          snap(@prev)
        end
        @alpha = ((t - (@sim_t - DT)) / DT).clamp(0.0, 1.0)
      end

      # The body's pose as it stands: x, y, heading, stride phase, gait, turn, distance walked.
      def snap(a)
        pl = @player
        a[0] = pl.x
        a[1] = pl.y
        a[2] = pl.ang
        a[3] = pl.bob
        a[4] = pl.gait
        a[5] = pl.turn
        a[6] = pl.odo
        a
      end

      def blend(i, now)
        p = @prev[i]
        p + (now - p) * @alpha
      end

      # The pointer's offset from the middle of the window (-1..1) while button 1 is held.
      def mouse_offset
        button, x, = @app.mouse
        return nil unless button == 1

        (x - w / 2.0) / (w / 2.0)
      rescue StandardError
        nil
      end

      def pick_up(at)
        SHOES.each_with_index do |(x, y), k|
          next if @got_at[k]
          next if (@player.x - x)**2 + (@player.y - y)**2 > TAKE * TAKE

          found(k, at)
        end
      end

      def found(k, at)
        @got_at[k] = at
        @shoe_t[k] = at
        @got += 1
        @last_got = at
        burst_from(@first_shoe + k)
        sp = @sprites[@first_shoe + k]
        sp[1] = sp[2] = -1000.0
        @light_src.delete(@shoe_lights[k])
        @done_at = at if @got == SHOES.size
      end

      # For the lab only: DIEM_WALK_POSE="x,y,degrees" starts somewhere else, and
      # DIEM_WALK_FOUND=n starts with the first n shoes already found (or a list of which:
      # DIEM_WALK_FOUND=0,1,2,3,4,6 leaves the one in the hall's corner for last).
      def lab_start
        if (spot = ENV["DIEM_WALK_POSE"]) && !spot.empty?
          x, y, deg = spot.split(",").map(&:to_f)
          @player.reset(x, y, deg * Math::PI / 180)
        end
        which = ENV["DIEM_WALK_FOUND"].to_s
        ks = which.include?(",") ? which.split(",").map(&:to_i) : (0...which.to_i.clamp(0, SHOES.size)).to_a
        ks.uniq.select { |k| k.between?(0, SHOES.size - 1) }.each { |k| found(k, -10.0) }
      end

      # The burst of a find goes off where the shoe stood on screen last frame (low and
      # centred when it was out of sight, as when you back into one).
      def burst_from(sprite)
        @burst_x = w / 2.0
        @burst_y = @hor ? @hor + 0.16 * @f : h * 0.62
        list = @shoe_list
        return unless list

        i = 0
        while i < list.size
          if list[i + 4] == sprite
            @burst_x = list[i + 1].clamp(w * 0.12, w * 0.88)
            @burst_y = list[i + 2].clamp(h * 0.3, h * 0.85)
            return
          end
          i += 5
        end
      end

      # Shoes the counter shows: a find counts once its "N OF 7" has flown into it.
      def landed(t)
        n = 0
        @got_at.each { |a| n += 1 if a && t >= a + POP_FOR }
        n
      end

      def marks_left
        m = @marks_left.clear
        SHOES.each_with_index { |(x, y), k| m << x << y unless @got_at[k] }
        m
      end

      # ---- camera -------------------------------------------------------------------------

      def pose(_t, sync)
        pl = @player
        @px = blend(0, pl.x)
        @py = blend(1, pl.y)
        @s = along_run
        kick = sync.hit(:kick, 0.12)
        gait = blend(4, pl.gait)
        bob = pl.bob
        bob += WalkPlayer::TAU * 64 if bob < @prev[3] - WalkPlayer::TAU * 32 # it wrapped
        ph = blend(3, bob)
        @ang = blend(2, pl.ang)
        @odo = blend(6, pl.odo)
        turn = blend(5, pl.turn)
        @dx = Math.cos(@ang)
        @dy = Math.sin(@ang)
        # the kick touches the camera only while you walk, and barely: the colours carry it
        beat = kick * gait
        half = Math.tan((74.0 + 0.5 * beat) * Math::PI / 360.0)
        @plx = -@dy * half
        @ply = @dx * half
        @f = (w / 2.0) / half
        @tan_half = half
        # lean into turns, sway with the stride, and bob twice a stride (once per footfall)
        @tilt = (-0.02 * turn).clamp(-0.05, 0.05) + 0.006 * gait * Math.sin(ph)
        @camh = 0.5 + gait * 0.03 * (Math.sin(ph).abs - 0.64) - 0.003 * beat
        @hor = h / 2.0 + 0.8 * u * beat + 2.0 * u * gait * Math.cos(ph * 2.0)
      end

      # Where the Maze's distance-driven looks (the white haze and the doorway's light down the
      # last corridor) should stand: the route distance with the same gap to the doorway.
      def along_run
        if @py > 11.5 && @px > 56.5
          @s_end - (@door_x - 0.3 - @px).clamp(0.0, 60.0)
        else
          @s_end - 60.0
        end
      end

      # Maze's environment blended by where you stand instead of by the clock: corridor fog
      # in the maze, the hall's past its door, the rush's down the last corridor. Trims flash
      # white-hot as a shoe is taken, and once all seven are home they flash on every kick.
      def environment(t, sync)
        into_hall = smooth(10.9, 12.4, @py)
        into_rush = @py > 11.5 ? smooth(56.5, 62.5, @px) : 0.0
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
        # once all seven are home the lights go down a little (the white room's haze thins,
        # the sky and the fog darken) so the fireworks have a night to burst in
        dusk = @done_at ? smooth(0.25, 1.4, t - @done_at) : 0.0
        night = 1.0 - 0.85 * dusk
        @night = night # the haze thins; the doorway's lights, bloom and glare go out (dusk)
        @dusk = dusk
        # and the doorway of light itself goes down to a violet glow behind the fireworks
        @light_wall = dusk.positive? ? lerp3(LIGHT_WALL, [54, 18, 100], dusk) : nil
        white = 0.6 * smooth(@s_end - 26.0, @s_end, @s)**2 * night
        @fog = lerp3(@fog, [255, 236, 250], white)
        @fog_len += 20.0 * white
        spill = 0.7 * smooth(@s_end - 9.0, @s_end, @s)**1.4 * night
        @fog = lerp3(@fog, [34, 6, 62], 0.5 * dusk)
        dusk_sky(dusk)
        @near_floor = lerp3(@near_floor, [255, 214, 240], spill)
        @roof_col = lerp3(@roof_col, [255, 228, 246], spill)
        @kick = sync.hit(:kick, 0.16)
        @snare = sync.hit(:snare, 0.1)
        found = @last_got ? Math.exp(-[t - @last_got, 0.0].max / 0.3) : 0.0
        party = @done_at ? 0.3 * @kick + 0.5 * @fireworks.light_k : 0.0
        @pulse = 0.75 + 0.5 * @kick + 0.5 * found
        @streak = found > party ? found : party
        sixteenth = (sync.t % Music::STEP) / Music::STEP
        @tube = 0.35 + 0.85 * into_rush * (1.0 - sixteenth)**2
        eighth = Music::STEP * 2
        ph = (sync.t % eighth) / eighth
        @chase_d = 0.5 + ph * (7.0 + 9.0 * into_rush)
        @chase_a = (1.0 - into_hall + into_rush).clamp(0.0, 1.0) * (1.0 - ph)**0.6 * (0.8 + 0.4 * @kick)
        lights
        bang
      end

      # Maze's lights, with the doorway's three nearly out once night falls on the white room.
      def lights
        super
        return if @dusk < 0.001 || @s_end - @s >= 45

        n = @lights.size
        dim = 1.0 - 0.96 * @dusk
        [n - 18, n - 12, n - 6].each { |i| @lights[i + 5] *= dim }
      end

      # True when the screen point (x, y) shows open sky: below the edge of any roof over
      # you, above the wall's top (or the roof that runs up to it). The doorway of light, gone
      # dark at dusk, counts as sky too: a window on the night.
      def sky_at?(x, y)
        i = (x / @colw).floor
        return false if i.negative? || i >= @n || y.negative?

        return true if @rc.kind[i] == M::LIGHT && @night < 0.5
        return false if @roofed_view

        ra = @rc.roof_a[i]
        rb = @rc.roof_b[i]
        return false if ra >= @zbuf[i] - 1e-6 && rb <= 0.0

        low = rb > 0.0 ? @hor_at[i] - (1.0 - @camh) * @f / rb : @wtop[i]
        high = ra > 0.0 ? @roof_y[i] : 0.0
        y > high && y < low
      end

      # The hall's sky going over to night: a recolour of the sky and the sun's cuts, which
      # costs nothing to paint, where a veil over the screen would cost a full-screen blend.
      def dusk_sky(k)
        k = (k * 24).round / 24.0
        return if k == @dusk_k

        @dusk_k = k
        top = lerp3(SKY_TOP, [0, 0, 4], 0.6 * k)
        low = lerp3(SKY_HORIZON, [70, 14, 60], 0.55 * k)
        set(@sky, { fill: { gradient: [col(*top), col(*low)], angle: 0 } })
        @bands.each { |b| set(b, { fill: col(*low) }) }
      end

      # Each firework lights the world in its own colour for a moment: a light just ahead of
      # you, toward the side of the sky it burst in.
      def bang
        k = @done_at ? @fireworks.light_k : 0.0
        return if k < 0.02

        c = @fireworks.light
        side = (@fireworks.light_x - 0.5) * 2.4
        x = @px + @dx * 1.6 - @dy * side
        y = @py + @dy * 1.6 + @dx * side
        @lights.push(x, y, c[0].to_f, c[1].to_f, c[2].to_f, 5.0 * k)
      end

      # ---- the shoes: glowing, bobbing, cut against the depth buffer ------------------------

      def draw_shoes(t)
        pool = @shoe_shapes
        pool.begin_frame
        list = @shoe_list
        i = list.size - 5
        while i >= 0
          depth, sx, zc, half, k = list[i, 5]
          sp = @sprites[k]
          take = 0.55 + 0.45 * smooth(0.3, 1.1, depth)
          half *= take
          hgt = sp[4] * 0.62 * @f / depth * take
          zc -= (1.0 - take) * hgt * 0.8
          spin = t * 2.2 + sp[7]
          fogk = (1.0 - Math.exp(-depth / @fog_len)) * 0.7
          near = smooth(0.45, 1.2, depth) # up close the shoe takes over from its glow
          glow_runs = gem_runs(sx, half * 1.45, depth, 0.1)
          if glow_runs.nil? || !glow_runs.empty?
            shoe_glow(sx, zc, half, hgt, fogk, glow_runs, t, sp[7], near, k - @first_shoe) if near > 0.02
            runs = gem_runs(sx, half, depth, 0.1)
            if runs.nil? || !runs.empty?
              @shoes.draw(sx, zc, half, hgt, spin, sp[5], @fog, fogk, runs)
              face = Math.cos(spin).abs**12
              @shoes.glint(sx + half * 0.5 * Math.cos(spin), zc - hgt * 0.1, half * 0.9 * face, 220 * face) if face > 0.05
            end
          end
          i -= 5
        end
        since = @last_got && t - @last_got
        if since && since >= 0.0 && since < 0.5
          k = since / 0.5
          x = @burst_x
          y = @burst_y
          r = h * (0.12 + 0.5 * Math.sqrt(k))
          @shoes.ring(x, y, r, (10.0 - 8.0 * k) * u, [255, 214, 110, (230 * (1.0 - k)**1.5).round])
          @shoes.ring(x, y, r * 0.62, (5.0 - 4.0 * k) * u, [255, 255, 255, (200 * (1.0 - k)**2).round]) if k < 0.7
          @shoes.burst(x, y, r * 1.1, k, 12)
        end
        pool.end_frame
      end

      # Two soft discs behind a shoe, breathing with the kick: gold, or deep magenta for the
      # one in the white room. near (0..1) fades them as you close on it.
      def shoe_glow(sx, zc, half, hgt, fogk, runs, t, phase, near, which)
        beat = (0.8 + 0.4 * @kick) * (0.8 + 0.2 * Math.sin(t * 5.0 + phase)) * (1.0 - fogk) * near
        gc = GLOWS[which] || GLOWS[0]
        strong = which == GLOWS.size - 1 ? 2.2 : 1.0
        [[1.9, 0.11 * strong], [1.2, 0.17 * strong]].each do |k, a|
          rx = half * k
          ry = hgt * k * 0.95
          GLOW_N.times do |j|
            ang = j * TAU / GLOW_N
            @gx[j] = sx + Math.cos(ang) * rx
            @gy[j] = zc + Math.sin(ang) * ry
          end
          fill = [gc[0], gc[1], gc[2], (255 * a * beat).round.clamp(0, 255)]
          if runs.nil?
            @shoe_shapes.poly(@gx, @gy, GLOW_N, fill)
          else
            j = 0
            while j < runs.size
              m = MazeClip.x_band(@gx, @gy, GLOW_N, runs[j], runs[j + 1], @gox, @goy, @gtx, @gty)
              @shoe_shapes.poly(@gox, @goy, m, fill)
              j += 2
            end
          end
        end
      end

      # ---- the doorway of light: Maze's bloom, dimmed when a wall stands in front of it ----

      def draw_bloom
        d = (@door_x - @px) * @dx + (15.5 - @py) * @dy
        lat = (@door_x - @px) * -@dy + (15.5 - @py) * @dx
        # the columns where the doorway itself shows
        c0 = c1 = nil
        if @s > @s_exit + 2.0 && d > 0.3
          kinds = @rc.kind
          i = 0
          while i < @n
            if kinds[i] == M::LIGHT
              c0 ||= i
              c1 = i
            end
            i += 1
          end
        end
        @bloom_vis += ((c0 ? 1.0 : 0.0) - @bloom_vis) * 0.25
        if @bloom_vis < 0.02
          @bloom.each { |b| set(b, { hidden: true }) } if @bloom_on
          @bloom_on = false
          return
        end
        sx = w / 2.0 + lat / d * @f
        sy = @hor + (sx - w / 2.0) * @tilt
        dh = 0.5 * @f / d
        heat = smooth(@s_end - 44.0, @s_end - 4.0, @s) * @bloom_vis * (1.0 - @dusk)
        if heat < 0.01
          @bloom.each { |b| set(b, { hidden: true }) } if @bloom_on
          @bloom_on = false
          return
        end
        cap = w * 0.75
        [[5.2, 0.05], [3.4, 0.08], [2.2, 0.13], [1.4, 0.2]].each_with_index do |(k, a), j|
          r = dh * k
          r = cap if r > cap
          set(@bloom[j], { hidden: false, left: (sx - r).round(1), top: (sy - r * 0.8).round(1), width: (2 * r).round(1), height: (1.6 * r).round(1),
                           fill: [255, 236, 250, (255 * a * heat).round] })
        end
        # the flare across the doorway, held to the doorway's own columns
        bar = [dh * 9.0, w.to_f].min
        left = sx - bar
        right = sx + bar
        if c0
          pad = 6.0 * u
          left = [left, @x0[c0] - pad].max
          right = [right, @x0[c1] + @xw[c1] + pad].min
        end
        left = left.clamp(0.0, w.to_f)
        right = right.clamp(left, w.to_f)
        set(@bloom[4], { hidden: false, left: left.round(1), top: (sy - dh * 0.12).round(1), width: (right - left).round(1),
                         height: (dh * 0.24).round(1), fill: [255, 255, 255, (110 * heat).round] })
        @bloom_on = true
      end

      # ---- screen: floor, flashes, radar marks, words ---------------------------------------

      def draw_overlays(t, _sync)
        lean = (@tilt.abs * w / 2.0).round
        hor = (@hor - lean).round
        set(@floor, { top: hor, height: h.round - hor, fill: { gradient: [col(*@fog), col(*@near_floor)], angle: 0 } })
        gold = @last_got ? 0.2 * Math.exp(-[t - @last_got, 0.0].max / 0.12) : 0.0
        tau = @done_at ? [t - @done_at, 0.0].max : nil
        done = tau ? 0.7 * Math.exp(-tau / 0.22) : 0.0
        fill = done > gold ? [255, 236, 200, (done * 255).round] : [255, 201, 77, (gold * 255).round]
        veil(@flash, :flash, fill)
        glare = @py > 11.5 && @px > 56.5 ? 0.3 * smooth(@door_x - 8.0, @door_x - 0.6, @px) * (1.0 - @dusk) : 0.0
        veil(@glare, :glare, [255, 250, 252, (glare * 255).round])
      end

      # On the radar: shoes found, as gold; shoes still lost beyond its reach, as little
      # chevrons on the rim pointing their way.
      def radar_marks
        sc = @rr / MazeRadar::REACH
        lim = MazeRadar::REACH - 0.6
        cmds = []
        SHOES.each_with_index do |(x, y), k|
          rx = x - @px
          ry = y - @py
          dist = Math.sqrt(rx * rx + ry * ry)
          fwd = rx * @dx + ry * @dy
          lat = -rx * @dy + ry * @dx
          if @got_at[k] && dist < lim
            mark(@got_dots, @dot_on, k, @rcx + lat * sc - 2 * u, @rcy - fwd * sc - 2 * u)
          else
            mark(@got_dots, @dot_on, k, nil, nil)
          end
          chevron(cmds, lat / dist, -fwd / dist) if !@got_at[k] && dist >= lim
        end
        return if cmds == @pip_key

        @pip_key = cmds
        set(@pip_shape, { shape_commands: cmds })
      end

      # A small arrowhead astride the rim, pointing out along (ux, uy).
      def chevron(cmds, ux, uy)
        r = @rr
        nx = -uy
        ny = ux
        pt = lambda do |along, side|
          [(@rcx + ux * along + nx * side).round, (@rcy + uy * along + ny * side).round]
        end
        cmds << [MOVE, *pt.call(r + 2.5 * u, 0.0)]
        cmds << [LINE, *pt.call(r - 2.5 * u, 3.2 * u)]
        cmds << [LINE, *pt.call(r - 0.8 * u, 0.0)]
        cmds << [LINE, *pt.call(r - 2.5 * u, -3.2 * u)]
      end

      def mark(pool, on, k, x, y)
        if x.nil?
          set(pool[k], { hidden: true }) if on[k]
          on[k] = false
          return
        end
        props = { left: x.round, top: y.round }
        props[:hidden] = false unless on[k]
        on[k] = true
        set(pool[k], props)
      end

      # "3 OF 7", slammed in over the burst and held. Then its number flies into the SHOES
      # counter while "OF 7" fades where it stood; the number lands big and white as the
      # counter takes the find, settles to the counter's size and fades into its gold, and a
      # ring flashes out round the counter's box.
      def draw_pop(t)
        k = @last_got && t - @last_got
        @spray.update(k, @burst_x, @burst_y)
        land(k)
        if k.nil? || k.negative? || k > POP_FOR + SETTLE
          @pop_num.hide
          @pop_rest.hide
          return
        end
        num = @got.to_s
        if k > POP_FOR
          q = (k - POP_FOR) / SETTLE
          @pop_rest.hide
          @pop_num.text(num, WHITE)
          e = 1.0 - (1.0 - q)**2
          @pop_num.fade(1.0 - q**1.6)
          @pop_num.place(@digit_x, @digit_y, @digit_p * (LAND_SCALE + (1.0 - LAND_SCALE) * e), 0.0, shadow: false)
          return
        end
        rest = "OF #{SHOES.size}"
        wide = Bitfont.width("#{num} #{rest}")
        num_off = Bitfont.width(num) / 2.0 - wide / 2.0
        rest_off = (num.length + 1) * 6 + Bitfont.width(rest) / 2.0 - wide / 2.0
        @pop_num.text(num, MazeTitle::GOLD)
        @pop_rest.text(rest, MazeTitle::GOLD)
        @pop_num.fade(1.0)
        scale = k < 0.12 ? 1.0 + 2.4 * (1.0 - k / 0.12)**2 : 1.0
        shake = 7.0 * u * Math.exp(-[k - 0.12, 0.0].max / 0.14)
        ghost = 13.0 * u * Math.exp(-k / 0.2)
        x = w / 2.0 + shake * Math.sin(t * 97.0)
        y = h * 0.28 + shake * Math.cos(t * 71.0)
        p = 11.0 * u * scale
        q = (k - (POP_FOR - FLY)) / FLY
        if q.positive?
          e = q * q * (3.0 - 2.0 * q)
          nx = x + num_off * p
          nx += (@digit_x - nx) * e
          ny = y + (@digit_y - y) * e - h * 0.06 * Math.sin(Math::PI * q) # a little hop on the way
          np = p + (@digit_p * LAND_SCALE - p) * e
          @pop_num.place(nx, ny, np, 0.0, shadow: q < 0.5)
          if q < 0.4
            @pop_rest.fade(1.0 - q / 0.4)
            @pop_rest.place(x + rest_off * p, y, p, 0.0, shadow: false)
          else
            @pop_rest.hide
          end
        else
          @pop_rest.fade(1.0)
          @pop_num.place(x + num_off * p, y, p, ghost)
          @pop_rest.place(x + rest_off * p, y, p, ghost)
        end
      end

      # The ring round the counter's box as a find lands: gold, opening out and fading.
      def land(k)
        a = k ? k - POP_FOR : -1.0
        if a.negative? || a > 0.75
          set(@land, { hidden: true }) if @land_a
          @land_a = nil
          return
        end
        alpha = (235 * Math.exp(-a / 0.2)).round
        g = (u * (1.0 + 7.0 * (1.0 - Math.exp(-a / 0.12)))).round
        key = [alpha, g]
        return if key == @land_a

        bx, by, bw, bh = @box
        props = { left: bx - g, top: by - g, width: bw + 2 * g, height: bh + 2 * g, stroke: [255, 226, 130, alpha] }
        props[:hidden] = false unless @land_a
        set(@land, props)
        @land_a = key
      end

      # Fireworks from the last shoe on, then the time it took, and the way out. Every word
      # wears a dark outline, so it reads on the white room's haze as on the night. After
      # BANNER_AT seconds the words shrink to a banner at the top and "esc to leave" drops low,
      # and the walk goes on.
      def draw_finale(t, sync)
        tau = @done_at && t - @done_at
        tau = nil if tau&.negative?
        @fireworks.update(tau, sync.hit(:kick, 0.15))
        unless tau && tau > 1.25
          [@line1, @line2, @line3].each(&:hide)
          return
        end
        secs = [@done_at, 0.0].max.floor
        e = smooth(BANNER_AT, BANNER_AT + BANNER_FOR, tau)
        e = e * e * (3.0 - 2.0 * e)
        @line1.text("ALL SEVEN SHOES", e < 0.5 ? MazeTitle::CHROME : BANNER_CHROME)
        @line2.text(format("FOUND IN %d:%02d", secs / 60, secs % 60), MazeTitle::GOLD)
        @line3.text("ESC TO LEAVE")
        kick = sync.hit(:kick, 0.12)
        top1 = 24.0 * u
        top2 = top1 + (3.5 * 2.6 + 5.0 + 3.5 * 2.2) * u
        [[@line1, 1.3, 7.0, 0.34, 2.6, top1], [@line2, 1.65, 4.6, 0.52, 2.2, top2]].each do |line, at, px, cy, bpx, by|
          k = tau - at
          if k.negative?
            line.hide
            next
          end
          scale = k < 0.18 ? 1.0 + 3.0 * (1.0 - k / 0.18)**2 : 1.0 + 0.035 * kick * (1.0 - e)
          shake = 8.0 * u * Math.exp(-k / 0.15)
          ghost = 14.0 * u * Math.exp(-k / 0.22)
          y = h * cy + shake * Math.cos(t * 71.0)
          p = px * u * scale
          line.place(w / 2.0 + shake * Math.sin(t * 97.0), y + (by - y) * e, p + (bpx * u - p) * e, ghost,
            shadow: k < 0.7)
        end
        if tau > 2.4 && ((tau - 2.4) * 0.8) % 1.0 < 0.78
          y = h * 0.66
          @line3.place(w / 2.0, y + (h - 34.0 * u - y) * e, (2.8 - 0.6 * e) * u)
        else
          @line3.hide
        end
      end

      # The hint waits for the title to clear, then stays six seconds.
      def draw_hint(t)
        a = [((t - HINT_FROM) / 0.4), ((HINT_TO - t) / 0.6), 1.0].min.clamp(0.0, 1.0)
        a = (a * 20).round / 20.0
        return if a == @hint_alpha

        if a.zero?
          @hint.hide
          set(@hint_bg, { hidden: true })
        else
          @hint.show if @hint_alpha.nil? || @hint_alpha.zero?
          @hint.style(stroke: Palette.rgb(Palette::INK, 0.9 * a))
          set(@hint_bg, { hidden: false, fill: [*Palette::NIGHT, (150 * a).round] })
        end
        @hint_alpha = a
      end
    end
  end
end
