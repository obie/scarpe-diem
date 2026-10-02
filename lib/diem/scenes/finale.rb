# frozen_string_literal: true

# The finale runs every earlier scene at once, so it loads them itself (the lab loads only the
# scene it shows). A scene that fails to load just leaves its tile out.
%w[ignition copper plasma solids dots maze tunnel].each do |f|
  begin
    require_relative f
  rescue ScriptError, StandardError => e
    warn "scarpe diem: finale tile #{f} did not load (#{e.class}: #{e.message.lines.first&.strip})"
  end
end

module Diem
  module Scenes
    # Bars 80-88. EVERYTHING AT ONCE: a 3x3 video wall whose eight outer tiles are live
    # miniatures of the earlier scenes, every one of them running its own update at the same
    # time, round a centre panel that counts the shapes and the changes as they happen. The
    # tiles fly in two a beat and land on it, pulse their frames on the kick and trade places
    # on the snare, then orbit the centre on the riser, faster and faster, pour into the panel
    # on the last beat of the bar, and the panel turns into the light the credits flash in from.
    #
    # Each tile and its neon frame are one group (a mover stack), so when two tiles cross, the
    # one on top is on top whole, frame and picture.
    #
    # The wall is paced for the renderer's damage tracking (paint/damage.rs): past 64 damaged
    # nodes it joins them blindly into one box, and a box over half the window repaints all of
    # it, which for the whole wall costs about 17 ms of paint (measured; 30 fps). So the live
    # wall changes one column a frame (a third of the window), a swap keeps to the one row or
    # column it happens in, and the kick rides that column sweep instead of lighting every
    # frame at once.
    class Finale < Scene
      P = Palette
      SKY = [90, 170, 255].freeze

      # [scene, seconds into that scene at the finale's start, frame colour, density], in ring order
      # (clockwise from the top left cell). Offsets are whole beats, so every tile's own
      # choreography lands on the finale's beats, and they spread the tiles' white hits out to
      # one a bar, a flash that moves round the wall: the knot shatters into its sphere at 6 s,
      # the tunnel swaps its walls on the crash at 8 s, the maze flies through its door at
      # 10 s, the tunnel folds into its mirror as the riser starts at 12 s and the gem is born
      # at 14 s. Meanwhile the logo turns on the crash and blows apart on the riser, the second
      # gem bursts on every bar from 8 s, the plasma rains and bleaches from 11 s, and the dots
      # ratchet shut into one point at 15 s, the beat the wall pours into the panel.
      TILES = [
        [:Ignition, 16.0, P::VIOLET],
        [:Copper, 0.0, P::GOLD],
        [:Solids, 2.0, P::CYAN],
        [:Maze, 6.0, P::MAGENTA],
        [:Tunnel, 0.0, P::MINT],
        [:Dots, 1.0, SKY, 0.45],
        [:Solids, 16.0, P::RUBY],
        [:Plasma, 1.0, P::EMBER],
      ].freeze
      DENSITY = 0.3

      RING = [[0, 0], [1, 0], [2, 0], [2, 1], [2, 2], [1, 2], [0, 2], [0, 1]].freeze
      TILE_W = 296 # in u
      TILE_H = 166

      # A tile's flight in, settle included. Its ease-out-back (BACK) first reaches the cell
      # CROSS of the way through, and that moment is the beat it lands on; it then overshoots
      # by about 2 % of the flight and settles.
      FLY = 0.8
      BACK = 0.8
      CROSS = 1.0 - BACK / (BACK + 1.0)
      # Two tiles a beat: the first is already in its cell on the downbeat, the last lands on
      # the eighth before 2 s, so the wall is full by then.
      LAND_EVERY = Music::BEAT / 2
      LIVE = 4.0
      SWAP = 0.3     # seconds a swap slides
      # The cells (ring indices) whose tiles trade places, one pair per backbeat snare 4-12 s.
      # Every pair is next to each other on the ring, so a swap stays inside one outer row or
      # column (LINES) and never crosses the panel; the tile drawn on top hops outward over the
      # other, partly off the window, and the other slides straight.
      SWAPS = [[0, 1], [4, 5], [2, 3], [6, 7], [1, 2], [5, 6], [3, 4], [7, 0]].freeze
      LINES = { top: [[0, 1, 2], [0, -1]], right: [[2, 3, 4], [1, 0]], bottom: [[4, 5, 6], [0, 1]], left: [[6, 7, 0], [-1, 0]] }.freeze
      HOP = 0.3 # how far the hopping tile arcs out, in tile sizes
      ORBIT = 12.0
      # On the riser the ring turns one cell a hop, a quick slide off each hop, on the beats,
      # then the eighths, then the sixteenths, and from POUR it spins without a stop as it
      # pours into the panel. A slide moves every tile, so the whole window repaints, and the
      # tiles draw one a frame (TURNS) while it slides, so the sixteenths, which are nearly all
      # slide, never freeze the pictures; between hops the wall lives one column a frame again.
      HOPS = [12.0, 12.5, 13.0, 13.25, 13.5, 13.75, 14.0, 14.125, 14.25, 14.375].freeze
      HOP_SLIDE = 0.1
      # After the whole window has repainted for a while, nothing changes for one frame, so the
      # renderer catches up instead of merging the next column into the last (two columns at
      # once are over half the window, a whole repaint, and so on).
      QUIET = 0.017
      SPIN = 8.0 # cells a second while it pours, the sixteenths' pace
      # Wherever every tile moves (the flight in, a hop's slide, the pour) the whole window
      # repaints every frame, about 14 ms of paint for the wall alone, so the tiles take turns
      # to draw: TURNS[mode] groups of them, one group a frame, and the framebuffer tiles (whose
      # every new picture is a decode and a resample too) half as often in the flight. Measured
      # in the flight in: every other frame 44-48 fps, these turns 54-58.
      TURNS = { fly: 4, slide: 8, pour: 8 }.freeze
      HEAVY = %i[Plasma Tunnel].freeze
      # The wall pours into the panel over the last beat before 15 s, ending on that beat.
      CONVERGE = [14.5, 15.0].freeze
      POUR = CONVERGE[0]
      BURY = 15.0 # from here the tiles are hidden and the panel is the light
      # The light: a small framebuffer, scaled up smooth by the renderer, glows out of the panel
      # and fills the window. It burns no hotter than LIGHT_CAP of its ramp, a warm gold, and
      # each snare of the fill from FILL lifts it a step towards that; from WHITE, the last
      # frame before the credits flash in, it is one opaque white rect.
      LIGHT_FB = [160, 90].freeze
      FILL = 15.5
      WHITE = 15.98
      LIGHT_FROM = 0.6  # the light's level on the beat it is born
      LIGHT_PRE = 0.68  # and as the fill begins
      LIGHT_CAP = 0.84
      LIGHT_BUMP = 0.035 # each fill snare overshoots its step by this, for a few frames
      # how much of the whole window the light has washed over, after each fill snare
      WASH = [0.0, 0.3, 0.55, 0.75, 0.9].freeze
      LIGHT_STOPS = [
        [0.0, P::NIGHT], [0.1, [34, 10, 30]], [0.28, [136, 36, 44]], [0.48, [255, 106, 61]],
        [0.66, [255, 168, 84]], [0.82, [255, 222, 160]], [0.93, [255, 244, 222]], [1.0, [255, 255, 255]],
      ].freeze
      WARM = [0.0, 2.0, 4.0, 6.0, 7.0, 8.0, 10.0, 12.0, 13.0, 14.0, 14.6].freeze
      WARM_FRAMES = 6
      # Plasma has one big inner loop per number of ripple terms, and YJIT compiling one costs
      # 20-30 ms on whichever frame first calls it often enough. These tiles warm through their
      # whole finale at 30 fps, so every one of those compiles happens on the loader.
      WARM_ALL = %i[Plasma].freeze
      JUMP = 0.05 # a step in t bigger than this is a seek or a still: every tile draws at once

      # The wall is already lit when the climax lands, so the white flash only has to punch, not
      # hide anything: three frames instead of the engine's usual 0.6 s.
      def self.flash_length = 3.0 / 60

      def build
        @tw = (TILE_W * u).round
        @th = (TILE_H * u).round
        gx = @gx = (w - 3 * @tw) / 4.0
        gy = @gy = (h - 3 * @th) / 4.0
        @cells = RING.map { |c, r| [gx + c * (@tw + gx), gy + r * (@th + gy)] }
        @centre = [gx * 2 + @tw, gy * 2 + @th]
        @start = PLAN.find { |name, *| name == "Finale" }[1] * Music::BAR
        @tiles_spec = TILES.select { |name, *| Scenes.const_defined?(name, false) }
        @offsets = @tiles_spec.map { |_, off, _| off }
        @colours = @tiles_spec.map { |_, _, c| c }
        @densities = @tiles_spec.map { |spec| spec[3] || DENSITY }
        @heavy = @tiles_spec.map { |name, *| HEAVY.include?(name) }
        @n = @tiles_spec.size
        @land = Array.new(@n) { |k| LAND_EVERY * k }
        @launch = @land.map { |l| l - CROSS * FLY }
        @launch[0] = -FLY # the first tile is settled in its cell on the downbeat
        @settled = @launch.map { |l| l + FLY }
        # the wall goes live one column a frame once the last tile has settled in its cell
        @wall_at = @settled.max
        @from = Array.new(@n) { |k| launch_point(k) }
        plan_swaps
        build_light_tables

        # no background of its own: the window's night shows in the gaps, one full-window fill
        # fewer for every repaint
        draw do
          nostroke
          @tiles = []
          # Each tile sits in a cell-sized stack of its own, which moves it and clips it; the
          # tunnel letterboxes a 2.35:1 band, so its scene is made wider and cropped to the cell
          # to fill it instead of leaving black bars in the wall.
          @inner_left = []
          @clips = []
          @hazes = []
          @glows = []
          @edges = []
          # The neon round each tile, in the tile's own group above its picture: a wide faint
          # haze, a glow, and a thin bright edge, out from the tile by these many pixels.
          g = (3 * u).round
          @ring_out = { hazes: (g * 1.9).round, glows: g, edges: g / 2 }
          m = @margin = (12 * u).round
          clear = rgb(0, 0, 0, 0)
          @movers = @tiles_spec.each_with_index.map do |(name, *), k|
            klass = Scenes.const_get(name, false)
            bw = name == :Tunnel ? (@th * klass::ASPECT).ceil : @tw
            @inner_left << -((bw - @tw) / 2)
            stack(left: w + 50, top: 0, width: @tw + 2 * m, height: @th + 2 * m) do
              @clips << stack(left: m, top: m, width: @tw, height: @th) do
                @tiles << klass.new(@app, w: bw, h: @th, left: @inner_left[k], top: 0, density: @densities[k])
              end
              [[@hazes, :hazes, 8.0], [@glows, :glows, 3.5], [@edges, :edges, 1.6]].each do |list, ring, sw|
                out = @ring_out[ring]
                list << rect(m - out, m - out, @tw + 2 * out, @th + 2 * out, fill: clear, stroke: clear, strokewidth: (sw * u).round(1))
              end
            end
          end
          @fb = Framebuffer.new(@app, LIGHT_FB[0], LIGHT_FB[1], left: 0, top: 0, width: w, height: h)
          # the panel goes on top of everything the tiles do, so the wall pours into it
          build_panel
          @light = rect(0, 0, w, h, fill: rgb(255, 255, 255, 0), stroke: rgb(255, 255, 255, 0), strokewidth: 0, hidden: true)
        end
        set(@fb.image, { hidden: true })
        @tiles.each do |tile|
          breathe
          tile.build
          # the scene slots start hidden; Wire owns their hidden, left and top from here on
          set(tile.slot, { hidden: false })
        end
        @tile_shapes = @tiles.map(&:drawable_count)
        # Counted now, from the tiles' own counts: the engine asks on the finale's first frame,
        # and walking all 4,500 drawables then costs about 90 ms on the climax downbeat.
        @drawable_count = @slot.contents.size + @n * 5 + @tile_shapes.sum
        warm_up
        lay_out_under_loader
      end

      def drawable_count = @drawable_count || super

      # Runs every tile through a few frames at the moments the finale will show, while the
      # finale is still hidden, so first-frame costs (lazy tables, YJIT compiling a scene's later
      # code paths) are paid on the loader and not mid-flight. Then it leaves each tile entered
      # and stepped to its launch, so the finale's first entry starts every tile from there and
      # no tile has to catch up on a live frame.
      def warm_up
        @prime_sync = Sync.new(Music.score)
        @tiles.each_with_index do |tile, k|
          tile.enter
          warm = WARM_ALL.include?(@tiles_spec[k][0]) ? (0...(BURY * 5).ceil).map { |i| i * 0.2 } : WARM
          warm.each do |t0|
            next if t0 < @launch[k]

            WARM_FRAMES.times do |i|
              t = t0 + i / 30.0
              tile.update(@offsets[k] + t, @prime_sync.at(@start + t))
              breathe
            end
            breathe
          end
          tile.enter
          prime(k)
          breathe
        end
        @primed = Array.new(@n, true)
        light_frame(BURY + 0.4) # compiles the light's loops too
      end

      # The renderer's first layout of this tree (every tile's text shaped, 4,500 nodes placed)
      # takes 25-60 ms. Under the loader, which covers the whole window, the finale is shown for
      # a few frames to pay that there, and hidden again before the show.
      def lay_out_under_loader
        return unless Engine.building_in_fiber?

        show
        3.times { Fiber.yield }
        hide
      end

      # Steps tile k to its launch with the song as it is then.
      def prime(k)
        at = [@launch[k], 0.0].max
        @tiles[k].update(@offsets[k] + at, @prime_sync.at(@start + at))
      end

      def enter
        # a tile still as warm_up left it is already entered and at its launch; any other
        # (a second entry, a seek) is reset now and primed over the first frames
        @unprimed = (0...@n).reject { |k| @primed[k] }
        @unprimed.each { |k| @tiles[k].enter }
        @primed.fill(false)
        @shown_xy = Array.new(@n)
        @shown_frame = Array.new(@n)
        @moving = Array.new(@n, false)
        @shown_letters = nil
        @buried = false
        # a tile is shown when it launches, so the renderer lays out one tile a beat instead of
        # the whole wall on the climax downbeat
        @movers.each { |m| set(m, { hidden: true }) }
        @mover_on = Array.new(@n, false)
        @counter_tick = nil
        @counter_text = [nil, nil, nil]
        @posts_seen = [Wire.posts]
        @changes = 0
        @tick = 0
        @last_t = nil
        @tiles_run = Array.new(@n, false)
        @light_state = nil
        set(@fb.image, { hidden: true })
        set(@light, { hidden: true })
        panel_glow(0.0)
        @counters_hidden = nil
        counters_hidden(false)
      end

      def update(t, sync)
        posts = Wire.posts
        # props per frame, averaged over the last three frames
        @posts_now = posts
        @posts_seen << posts
        @posts_seen.shift while @posts_seen.size > 4
        @changes = @posts_seen.size > 1 ? ((posts - @posts_seen.first) / (@posts_seen.size - 1.0)).round : 0
        @tick += 1
        @jump = @last_t.nil? || (t - @last_t).abs > JUMP
        @last_t = t
        prime_next(t)
        kick = sync.hit(:kick, 0.12)
        snare = sync.hit(:snare, 0.08)
        rise = smooth(ORBIT, POUR, t)
        hop = t >= ORBIT && t < POUR ? HOPS.rindex { |h| h <= t } : nil
        @hop_flash = hop ? 0.7 * Math.exp(-(t - HOPS[hop]) / 0.12) : 0.0
        @mode = mode(t)
        @by_column = @mode == :column
        @line = @by_column && t < ORBIT ? swap_line(t) : nil
        place_tiles(t, kick, snare, rise) unless t >= BURY && @buried
        run_tiles(t, sync)
        update_panel(t, kick, rise) if panel_due?
        update_light(t)
      end

      def leave
        @tiles.each(&:leave)
      end

      private

      # One unprimed tile a frame, under the white flash the finale arrives in, so a seek never
      # makes a tile step through seconds of its scene on the frame it launches.
      def prime_next(t)
        k = @unprimed.shift
        prime(k) if k && t < @launch[k]
      end

      # ---- choreography: positions are pure functions of t ------------------------------------

      # Where tile k flies in from: off screen, straight out from the centre through its cell.
      def launch_point(k)
        x, y = @cells[k]
        [x + (x - @centre[0]) * 3.2, y + (y - @centre[1]) * 3.2]
      end

      # The snares that trigger swaps (the backbeats in the live window), and who sits where
      # after each one. order[n][cell] is the tile in that cell after n swaps.
      def plan_swaps
        song = Sync.new(Music.score)
        times = song.hits_between(:snare, @start + LIVE, @start + ORBIT - SWAP).map { |h| (h.time - @start).round(4) }
        times = times.select { |tm| ((tm % 1.0) - 0.5).abs < 1e-6 }.uniq
        @swap_at = times.first(SWAPS.size)
        @swap_line = @swap_at.each_index.map do |i|
          a, b = SWAPS[i]
          LINES.values.find { |cells, _| cells.include?(a) && cells.include?(b) }
        end
        order = (0...@n).to_a
        @order = [order.dup]
        @swap_at.each_index do |i|
          a, b = SWAPS[i]
          next @order << order.dup if a >= @n || b >= @n

          order[a], order[b] = order[b], order[a]
          @order << order.dup
        end
        @cell_of = @order.map { |o| inverse(o) }
      end

      def inverse(order)
        cell = Array.new(order.size)
        order.each_with_index { |tile, c| cell[tile] = c }
        cell
      end

      # The swap sliding now, as [index, ring cells of its row or column], or nil.
      def swap_line(t)
        i = @swap_at.index { |s| t >= s && t < s + SWAP }
        i && [i, @swap_line[i][0]]
      end

      # How the tiles take turns to draw at t (see due?). Wherever the whole window has been
      # repainting every frame (the flight in, a hop's slide) a quiet frame follows.
      def mode(t)
        return :fly if t < @wall_at
        return :quiet if t < @wall_at + QUIET
        return :column if t < ORBIT
        return :pour if t >= POUR

        hop = HOPS.rindex { |s| s <= t }
        return :column unless hop

        since = t - HOPS[hop]
        since < HOP_SLIDE ? :slide : (since < HOP_SLIDE + QUIET ? :quiet : :column)
      end

      def tile_xy(k, t)
        return fly_in(k, t) if t < @settled[k]
        return orbit(k, t) if t >= ORBIT

        n = @swap_at.count { |s| s + SWAP <= t }
        here = @cells[@cell_of[n][k]]
        active = @swap_at[n]
        return here unless active && t >= active

        there = @cells[@cell_of[n + 1][k]]
        return here if there.equal?(here)

        # off the snare at speed; the tile drawn on top hops outward over the other
        e = ease_out_cubic((t - active) / SWAP)
        x = here[0] + (there[0] - here[0]) * e
        y = here[1] + (there[1] - here[1]) * e
        a, b = SWAPS[n]
        return [x, y] unless k == [@order[n][a], @order[n][b]].max

        nx, ny = @swap_line[n][1]
        hop = HOP * (nx.abs * @tw + ny.abs * @th) * Math.sin(Math::PI * e)
        [x + nx * hop, y + ny * hop]
      end

      def fly_in(k, t)
        p = ((t - @launch[k]) / FLY).clamp(0.0, 1.0)
        e = ease_out_back(p)
        fx, fy = @from[k]
        x, y = @cells[k]
        [fx + (x - fx) * e, fy + (y - fy) * e]
      end

      # Round the ring of cells, a hop at a time and then spinning, and from POUR pulled into the
      # panel, landing on 15 s. Along the cells themselves the tiles keep a cell apart, so they
      # only brush each other at the corners.
      def orbit(k, t)
        s = @cell_of.last[k] + ring_turn(t)
        i = s.floor
        f = s - i
        a = @cells[i % 8]
        b = @cells[(i + 1) % 8]
        x = a[0] + (b[0] - a[0]) * f
        y = a[1] + (b[1] - a[1]) * f
        pull = 1.0 - pour(t)
        [@centre[0] + (x - @centre[0]) * pull, @centre[1] + (y - @centre[1]) * pull]
      end

      # Cells the ring has turned by t.
      def ring_turn(t)
        return HOPS.size + SPIN * (t - POUR) if t >= POUR

        hop = HOPS.rindex { |s| s <= t }
        return 0.0 unless hop

        hop + ease_out_cubic((t - HOPS[hop]) / HOP_SLIDE)
      end

      # 0 to 1 over CONVERGE, accelerating into the panel.
      def pour(t)
        x = ((t - CONVERGE[0]) / (CONVERGE[1] - CONVERGE[0])).clamp(0.0, 1.0)
        x * x * x
      end

      def landed?(k, t) = t >= @land[k]

      # The panel sits in the middle column, so it changes with that column, or at once after a
      # jump in time.
      def panel_due?
        return false if @mode == :quiet && !@jump

        !@by_column || @jump || (@line.nil? && @tick % 3 == 1)
      end

      # ---- per frame --------------------------------------------------------------------------

      def place_tiles(t, kick, snare, rise)
        fade = 1.0 - pour(t)
        # as it pours in, every tile switches off like an old screen, to its middle line
        squash = ((t - CONVERGE[0]) / (CONVERGE[1] - CONVERGE[0])).clamp(0.0, 1.0)**2
        band = (@th * (1.0 - squash)).round
        off = (@th - band) / 2
        m = @margin
        @n.times do |k|
          x, y = tile_xy(k, t)
          xi = x.round
          yi = y.round + off
          xy = @shown_xy[k]
          @moving[k] = xy.nil? || xy[0] != xi || xy[1] != yi || xy[2] != band
          unless @mover_on[k] == (t >= @launch[k])
            @mover_on[k] = !@mover_on[k]
            set(@movers[k], { hidden: !@mover_on[k] })
          end
          if @moving[k]
            props = { left: xi - m, top: yi - m }
            resized = xy.nil? || xy[2] != band
            if resized
              props[:height] = band + 2 * m
              set(@clips[k], { height: band })
              set(@tiles[k].slot, { top: -off })
            end
            set(@movers[k], props)
            @shown_xy[k] = [xi, yi, band]
          end
          frame(k, t, band, kick, snare, rise, fade)
        end
      end

      # The neon frame round tile k, in the tile's own colour: it flashes as the tile lands and
      # on every hop of the ring, the thin edge kicks on the kick, the glow flares on the snare
      # for the two that swap, and both brighten on the riser and fade as the wall pours in.
      def frame(k, t, band, kick, snare, rise, fade)
        return if t < @launch[k] # its group is hidden

        since_land = t - @land[k]
        land = since_land >= 0.0 ? Math.exp(-since_land / 0.18) : 0.0
        land = [land, @hop_flash].max
        swapping = @by_column && swapping?(k, t)
        flare = swapping ? snare : 0.0
        edge_a = ((0.5 + 0.5 * kick + 0.6 * land + 0.3 * rise) * fade).clamp(0.0, 1.0)
        glow_a = ((0.2 + 0.18 * kick + 0.5 * land + 0.5 * flare + 0.25 * rise) * fade).clamp(0.0, 1.0)
        base = @colours[k]
        edge_c = P.mix(base, P::INK, (0.55 * land + 0.4 * kick + 0.4 * flare).clamp(0.0, 1.0))
        glow_c = P.mix(base, P::INK, 0.3 * land)
        key = [band, (edge_a * 64).round, (glow_a * 64).round, ((land + kick + flare) * 16).round]
        shown = @shown_frame[k]
        return if shown == key
        # A still tile repaints only on its own frames, so its frame waits for them too.
        return if shown && shown[0] == band && !@moving[k] && !due?(k)

        @shown_frame[k] = key
        rings = [[@edges, :edges, wc(edge_c, edge_a)], [@glows, :glows, wc(glow_c, glow_a)], [@hazes, :hazes, wc(glow_c, glow_a * 0.35)]]
        rings.each do |list, ring, colour|
          props = { stroke: colour }
          if shown.nil? || shown[0] != band
            out = @ring_out[ring]
            props[:top] = @margin - out
            props[:height] = band + 2 * out
          end
          set(list[k], props)
        end
      end

      # Whether tile k draws this frame. Everything after a jump in time (a seek, a still).
      # While every tile moves (flight, slide, pour) they take turns (TURNS), none on a quiet
      # frame. Otherwise one column a frame, since then only that third of the window changes
      # and the renderer repaints just that (20 Hz a tile: the panel and two columns at once
      # are over half the window, a whole repaint); while a swap slides, every tile in its row
      # or column, every frame (the slide repaints that strip anyway), and nothing else, so the
      # damage stays one strip.
      def due?(k)
        return true if @jump

        case @mode
        when :fly then ((@tick + k) % (@heavy[k] ? 2 * TURNS[:fly] : TURNS[:fly])).zero?
        when :slide, :pour then ((@tick + k) % TURNS[@mode]).zero?
        when :quiet then false
        else
          return @line[1].include?(@cell_of[@line[0]][k]) if @line

          x = @shown_xy[k][0] + @tw / 2.0
          ((x - @gx / 2) / (@tw + @gx)).floor.clamp(0, 2) == @tick % 3
        end
      end

      def swapping?(k, t)
        @swap_at.each_with_index do |s, i|
          next unless t >= s && t < s + SWAP + 0.15

          return @cell_of[i][k] != @cell_of[i + 1][k]
        end
        false
      end

      # Each tile runs from its launch, at its own offset into its scene, with the song as it is
      # now, on the frames due? gives it, until the wall has poured into the panel.
      def run_tiles(t, sync)
        return if t >= BURY

        @n.times do |k|
          next if t < @launch[k]
          next if @tiles_run[k] && !due?(k)

          @tiles_run[k] = true
          @tiles[k].update(@offsets[k] + t, sync)
        end
      end

      # ---- the centre panel -------------------------------------------------------------------

      PANEL_FILL = [10, 8, 26].freeze
      PANEL_EDGE = [62, 58, 86].freeze

      def build_panel
        px, py = @centre
        px = px.round
        py = py.round
        # opaque, so the tiles vanish into it as they pour in
        @panel = rect(px, py, @tw, @th, curve: (6 * u).round, fill: P.rgb(PANEL_FILL),
          stroke: P.rgb(PANEL_EDGE), strokewidth: (1.2 * u).round(1))
        cell = 3.9 * u
        sq = 3.3 * u
        text = "EVERYTHING\nAT ONCE"
        y0 = py + 14 * u
        glyphs = []
        text.split("\n").each_with_index do |line, row|
          lw = Bitfont.width(line) * cell
          lx = px + (@tw - lw) / 2.0
          line.each_char.with_index do |ch, j|
            next if ch == " "

            pts = Bitfont.points(ch).map { |gx, gy| [lx + (j * 6 + gx) * cell, y0 + (row * 9 + gy) * cell] }
            glyphs << pts
          end
        end
        @letters = glyphs.map do |pts|
          shape(0, 0, fill: P.rgb(P::INK, 0.0), strokewidth: 0) do
            pts.each do |x, y|
              @app.move_to(x.round(1), y.round(1))
              @app.line_to((x + sq).round(1), y.round(1))
              @app.line_to((x + sq).round(1), (y + sq).round(1))
              @app.line_to(x.round(1), (y + sq).round(1))
            end
          end
        end
        rule_y = (y0 + 16 * cell + 9 * u).round
        @rule = rect(px + (24 * u).round, rule_y, @tw - (48 * u).round, [(1 * u).round, 1].max, fill: P.rgb(P::GOLD, 0.35), strokewidth: 0)
        size = (15 * u).round
        num_x = px + (22 * u).round
        label_x = num_x + (6 * 0.602 * size + 10 * u).round
        mono = "Menlo, monospace"
        @nums = []
        @labels = []
        # built with text in them, so the fonts are loaded and the lines shaped while the loader
        # still covers the window, not on the finale's first frame (30-45 ms of layout)
        %w[scenes shapes changes].each_with_index do |label, i|
          top = rule_y + (7 * u).round + (i * 22 * u).round
          @nums << para("0,000".rjust(6), left: num_x, top: top, size: size, font: mono, weight: "bold", stroke: P.rgb(P::GOLD), margin: 0)
          @labels << para(label, left: label_x, top: top, size: size, font: mono, stroke: P.rgb(P::INK, 0.62), margin: 0)
        end
      end

      # The letters are lit from the downbeat and shimmer: a hue wave runs across them and the
      # kick lights them; on the riser they burn white.
      def update_panel(t, kick, rise)
        n = @letters.size
        hue_shift = t * 0.35
        @shown_letters ||= []
        @letters.each_with_index do |shape, j|
          a = 1.0
          x = (j.fdiv(n) + hue_shift) % 1.0
          c = wave(x)
          lift = (0.5 * kick * (1.0 - (j.fdiv(n) - (t % 1.0)).abs)).clamp(0.0, 1.0)
          c = P.mix(c, P::INK, (lift + rise).clamp(0.0, 1.0))
          col = wc(c, a)
          next if @shown_letters[j] == col

          set(shape, { fill: col })
          @shown_letters[j] = col
        end
        counters(t)
      end

      def wave(x)
        stops = [P::CYAN, P::VIOLET, P::MAGENTA, P::GOLD, P::CYAN]
        f = x * (stops.size - 1)
        i = f.floor.clamp(0, stops.size - 2)
        P.mix(stops[i], stops[i + 1], f - i)
      end

      # Ten times a second: how many scenes are live, how many shapes they hold, and how many
      # props a frame went over the wire, averaged over the last three frames.
      def counters(t)
        tick = (t * 10).floor
        return if tick == @counter_tick

        @counter_tick = tick
        live = (0...@n).select { |k| landed?(k, t) }
        shapes = live.sum { |k| @tile_shapes[k] }
        # on the first frame there is no frame before to average: this one so far
        changes = @tick > 1 ? @changes : Wire.posts - @posts_now
        texts = [
          [live.size.to_s, live.size == 1 ? "scene" : "scenes"],
          [group(shapes), "shapes"],
          [group(changes), "changes a frame"],
        ]
        texts.each_with_index do |(num, label), i|
          next if @counter_text[i] == [num, label]

          @nums[i].text = num.rjust(6)
          @labels[i].text = label
          @counter_text[i] = [num, label]
        end
      end

      def group(n) = n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

      # The panel's own glow: k = 0 is the panel as built, 1 is the light at `level` of its ramp;
      # in between it heats up the light's own ramp, red hot to gold.
      def panel_glow(k, level = 1.0)
        c = k <= 0.0 ? PANEL_FILL : P.mix(PANEL_FILL, light_colour((0.35 + 0.65 * k) * level), (k / 0.3).clamp(0.0, 1.0))
        set(@panel, { fill: wc(c), stroke: wc(k <= 0.0 ? PANEL_EDGE : light_colour((0.5 + 0.5 * k) * level)) })
        set(@rule, { fill: wc(P.mix(P::GOLD, light_colour(level), k), 0.35 + 0.65 * k) })
      end

      def light_colour(x)
        k = LIGHT_STOPS.index { |s, _| s >= x } || LIGHT_STOPS.size - 1
        k = 1 if k.zero?
        (s0, c0), (s1, c1) = LIGHT_STOPS[k - 1], LIGHT_STOPS[k]
        P.mix(c0, c1, ((x - s0) / (s1 - s0)).clamp(0.0, 1.0))
      end

      def counters_hidden(hidden)
        return if @counters_hidden == hidden

        (@nums + @labels).each { |pr| set(pr, { hidden: hidden }) }
        @counters_hidden = hidden
      end

      # ---- the light the credits arrive in ----------------------------------------------------

      # Distances from the panel's edge (in u, 0 inside it) for every framebuffer pixel, and the
      # ramp the light runs down: white, pale gold, amber, ember, night.
      def build_light_tables
        fw, fh = LIGHT_FB
        cx = @centre[0] + @tw / 2.0
        cy = @centre[1] + @th / 2.0
        a = @tw / 2.0
        b = @th / 2.0
        @light_q = Array.new(fh) do |j|
          y = (j + 0.5) * h / fh
          Array.new(fw) do |i|
            x = (i + 0.5) * w / fw
            dx = [(x - cx).abs - a, 0.0].max
            dy = [(y - cy).abs - b, 0.0].max
            (Math.hypot(dx, dy) / u).round
          end
        end
        @light_qmax = @light_q.map(&:max).max
        @light_pal = Array.new(256) { |i| Framebuffer.pixel(light_colour(i / 255.0)) }
        song = Sync.new(Music.score)
        @fill_snares = song.hits_between(:snare, @start + FILL - 1e-6, @start + Music::BAR * 8)
          .map { |hit| (hit.time - @start).round(4) }.uniq.first(WASH.size - 1)
      end

      # The light's level (how far up its ramp the core burns) and its wash over the window at t.
      def light_level(t)
        n = @fill_snares.count { |s| s <= t }
        if n.zero?
          [LIGHT_FROM + (LIGHT_PRE - LIGHT_FROM) * smooth(BURY, FILL, t), 0.0]
        else
          since = t - @fill_snares[n - 1]
          step = LIGHT_PRE + (LIGHT_CAP - LIGHT_PRE) * n / (WASH.size - 1.0)
          wash = WASH[n - 1] + (WASH[n] - WASH[n - 1]) * ease_out_cubic(since / 0.05)
          [step + LIGHT_BUMP * Math.exp(-since / 0.04), wash]
        end
      end

      # The light at t: a core that grows out of the panel's edge, a glow round it that reaches
      # further as it grows, and a wash that the fill's snares spread over the whole window.
      def light_frame(t)
        x = ((t - BURY) / (WHITE - BURY)).clamp(0.0, 1.0)
        r = 430.0 * x * x
        fall = 24.0 + 150.0 * x
        level, wash = light_level(t)
        top = level * 255
        pal = @light_pal
        tab = Array.new(@light_qmax + 1) do |q|
          d = q - r
          i = d <= 0.0 ? 1.0 : Math.exp(-d / fall)
          pal[((i + (1.0 - i) * wash) * top).round.clamp(0, 255)]
        end
        @fb.present(@light_q.map { |row| row.map { |q| tab[q] }.join })
      end

      # From BURY the tiles and their frames are hidden, the panel turns to light and the light
      # framebuffer grows round it; from WHITE one white rect is all there is.
      def update_light(t)
        buried = t >= BURY
        unless buried == @buried
          if buried
            @movers.each { |m| set(m, { hidden: true }) }
            @mover_on.fill(false)
            @shown_frame.fill(nil)
          end
          @buried = buried
        end
        state = t < BURY ? :off : (t >= WHITE ? :white : (t * 120).round)
        return if state == @light_state

        @light_state = state
        case state
        when :off
          set(@fb.image, { hidden: true })
          set(@light, { hidden: true })
          panel_glow(0.0)
          counters_hidden(false)
          @fb_on = false
          @flash_on = false
        when :white
          set(@fb.image, { hidden: true })
          set(@light, { hidden: false, fill: [255, 255, 255, 255] })
          @fb_on = false
          @flash_on = nil
        else
          set(@fb.image, { hidden: false }) unless @fb_on
          @fb_on = true
          # one frame of gold light on the beat the wall lands in the panel
          flash = t - BURY < 1.0 / 60
          set(@light, flash ? { hidden: false, fill: wc(light_colour(LIGHT_CAP), 0.85) } : { hidden: true }) unless flash == @flash_on
          @flash_on = flash
          light_frame(t)
          panel_glow(smooth(BURY + 0.02, BURY + 0.32, t), light_level(t)[0])
          counters_hidden(t >= BURY + 0.2)
        end
      end

      # ---- easing -----------------------------------------------------------------------------

      def smooth(a, b, t)
        x = ((t - a) / (b - a)).clamp(0.0, 1.0)
        x * x * (3.0 - 2.0 * x)
      end

      def ease_out_cubic(x)
        1.0 - (1.0 - x.clamp(0.0, 1.0))**3
      end

      def ease_out_back(x)
        c3 = BACK + 1
        1 + c3 * (x - 1)**3 + BACK * (x - 1)**2
      end
    end
  end
end
