# frozen_string_literal: true

# The celebration once every shoe is found: rockets climb from the bottom of the screen and
# burst into comets that drag, fall, twinkle and fade. Each burst is three shapes (the streaks
# in its two colours and their white-hot heads), every spark one tapered polygon in them, so a
# burst of 22 sparks costs three fills. Each burst is seeded by its number, so a frame is a
# function of the time since the last shoe and of the view when its rocket goes up: each
# burst picks a spot where the sky shows (sky: a callable, true when the screen point (x, y)
# is open sky beyond the walls and roofs), so it never goes off over a wall up close. With no
# sky in view the burst goes off unseen behind the walls, and only its light reaches you.
module Diem
  class WalkFireworks
    TAU = Math::PI * 2
    COLOURS = [Palette::GOLD, Palette::MAGENTA, Palette::CYAN, Palette::MINT, Palette::VIOLET, Palette::EMBER].freeze
    CLIMB = 0.55   # seconds a rocket rises before it bursts
    LIFE = 1.8     # seconds a burst lasts
    DRAG = 0.42    # time constant of the sparks' slowing
    TRAIL = 0.2    # seconds of path each streak shows
    MOVE = "move_to"
    LINE = "line_to"

    # The colour and strength (0..1) of the brightest burst going off now, for lighting the
    # world with it.
    attr_reader :light, :light_k, :light_x

    def initialize(scene, bursts: 6, sparks: 22, sky: nil)
      @s = scene
      @sky = sky
      @nb = bursts
      @ns = sparks
      @memo = {}
      @light = [255, 255, 255]
      @light_k = 0.0
      @light_x = 0.5
    end

    # Inside a draw block.
    def build
      s = @s
      u = s.u
      @glows = Array.new(@nb) { s.oval(0, 0, 1, 1, fill: Palette.rgb(Palette::INK, 0.0), strokewidth: 0, hidden: true) }
      @rockets = Array.new(@nb) { s.line(0, 0, 0, 0, stroke: Palette.rgb(Palette::INK, 0.0), strokewidth: 3.0 * u, hidden: true) }
      # per burst: streaks in its first colour, in its second, then the heads over both
      @shapes = Array.new(@nb * 3) { s.shape(0, 0, fill: Palette.rgb(Palette::INK, 0.0), strokewidth: 0) }
      @cmds = Array.new(@shapes.size) { [] }
      @drawables = @glows + @rockets
      @shown = Array.new(@drawables.size, false)
      @shape_on = Array.new(@shapes.size, false)
    end

    def enter
      @drawables.each { |d| @s.set(d, { hidden: true }) }
      @shapes.each { |d| @s.set(d, { shape_commands: [] }) }
      @shown.fill(false)
      @shape_on.fill(false)
      @light_k = 0.0
      @memo.clear
    end

    # When burst j goes off, after the last shoe: a quick volley, then one every second or so.
    def burst_time(j) = j < 10 ? 0.3 + j * 0.42 : 0.3 + 10 * 0.42 + (j - 10) * 1.05

    # tau: seconds since the last shoe was found (nil: nothing to celebrate yet).
    def update(tau, kick)
      used = Array.new(@shown.size, false)
      shaped = Array.new(@shapes.size, false)
      @light_k = 0.0
      if tau
        slot = 0
        j = first_live(tau)
        @memo.delete(j - 12)
        while slot < @nb && burst_time(j) - CLIMB <= tau
          age = tau - burst_time(j)
          draw_burst(slot, burst(j), age, kick, used, shaped, j.even?) if age < LIFE
          slot += 1
          j += 1
        end
      end
      @shown.each_index do |i|
        next if used[i] || !@shown[i]

        @s.set(@drawables[i], { hidden: true })
        @shown[i] = false
      end
      @shape_on.each_index do |i|
        next if shaped[i] || !@shape_on[i]

        @s.set(@shapes[i], { shape_commands: [] })
        @shape_on[i] = false
      end
    end

    private

    def first_live(tau)
      j = 0
      j += 1 while burst_time(j) + LIFE < tau
      j
    end

    # Where, what colour and how hard burst j goes off. Sparks leave at 0.3 to 1.0 of the
    # burst's speed, so it fills in as a ball instead of a ring.
    def burst(j)
      @memo[j] ||= begin
        rnd = Random.new(9100 + j * 31)
        w = @s.w
        h = @s.h
        x = w * (0.12 + 0.76 * rnd.rand)
        x = w * (0.2 + 0.6 * rnd.rand) if j.zero?
        y = h * (0.14 + 0.3 * rnd.rand)
        unseen = false
        x, y, unseen = open_sky(rnd, x, y) if @sky
        c = COLOURS[(j * 5 + rnd.rand(3)) % COLOURS.size]
        c2 = COLOURS[(j * 5 + 2 + rnd.rand(3)) % COLOURS.size]
        speed = h * (0.75 + 0.35 * rnd.rand)
        sparks = Array.new(@ns) do |k|
          a = TAU * (k + 0.6 * rnd.rand) / @ns
          v = 0.3 + 0.7 * Math.sqrt(rnd.rand)
          [Math.cos(a), Math.sin(a), speed * v, k.even? ? 0 : 1, rnd.rand]
        end
        [x, y, sparks, rnd.rand * 0.4 - 0.2, [c, c2], unseen]
      end
    end

    # A spot with sky all round the burst's heart, tried a dozen times; [x, y, unseen].
    def open_sky(rnd, x, y)
      w = @s.w
      h = @s.h
      m = h * 0.07
      12.times do |n|
        unless n.zero?
          x = w * (0.1 + 0.8 * rnd.rand)
          y = h * (0.1 + 0.36 * rnd.rand)
        end
        return [x, y, false] if @sky.call(x, y - m) && @sky.call(x, y + m) && @sky.call(x - m, y) && @sky.call(x + m, y)
      end
      [x, y, true]
    end

    def draw_burst(slot, b, age, kick, used, shaped, glow = true)
      x, y, sparks, lean, cols, unseen = b
      s = @s
      u = s.u
      if unseen # behind the walls: no rocket, no sparks, only its light on the world
        hot = age.negative? ? 0.0 : Math.exp(-age / 0.12)
        if hot > @light_k
          @light_k = hot
          @light = cols[0]
          @light_x = x / s.w
        end
        return
      end
      gi = slot
      ri = @nb + slot
      if age < 0.0
        # the rocket: climbing from the bottom edge, slowing as it nears the top of its arc
        k = 1.0 + age / CLIMB
        ease = 1.0 - (1.0 - k)**2
        y0 = s.h + 10.0
        cx = x + lean * s.h * (1.0 - ease)
        cy = y0 + (y - y0) * ease
        tail = 26.0 * u * (1.0 - k * 0.6)
        show(ri, used, { left: cx.round(1), top: cy.round(1), x2: (cx + lean * tail).round(1), y2: (cy + tail).round(1),
                         stroke: [255, 236, 200, (230 * (0.5 + 0.5 * k)).round] })
        return
      end

      fade = 1.0 - age / LIFE
      a = fade**1.3
      hot = Math.exp(-age / 0.12)
      boost = 1.0 + 0.3 * kick
      # the light of the bang, in the burst's own colour, on the sky and on the world
      if glow && age < 0.24 # every other burst, and not once it is too faint to see: it is big
        r = (24.0 + 330.0 * age) * u
        ga = 0.55 * Math.exp(-age / 0.09)
        c = cols[0]
        show(gi, used, { left: (x - r).round(1), top: (y - r).round(1), width: (2 * r).round(1), height: (2 * r).round(1),
                         fill: [(c[0] + 255) / 2, (c[1] + 255) / 2, (c[2] + 255) / 2, (255 * ga).round.clamp(0, 255)] })
      end
      if hot > @light_k
        @light_k = hot
        @light = cols[0]
        @light_x = x / s.w
      end

      base = slot * 3
      wide = 1.9 * u * (0.55 + 0.45 * fade)
      head = 2.6 * u * (0.5 + 0.5 * fade)
      dying = age > LIFE * 0.55
      cs = [@cmds[base], @cmds[base + 1], @cmds[base + 2]]
      ns = [0, 0, 0]
      sparks.each do |ux, uy, sp, ci, ph|
        hx, hy = spark_at(x, y, ux, uy, sp, age)
        tx, ty = spark_at(x, y, ux, uy, sp, age > TRAIL ? age - TRAIL : 0.0)
        ddx = hx - tx
        ddy = hy - ty
        len = Math.sqrt(ddx * ddx + ddy * ddy)
        next if len < 0.5

        nx = -ddy / len
        ny = ddx / len
        # a comet: a needle from the tail, widest just behind the head
        mx = tx + ddx * 0.8
        my = ty + ddy * 0.8
        ns[ci] = quad(cs[ci], ns[ci], tx, ty, mx + nx * wide, my + ny * wide, hx, hy, mx - nx * wide, my - ny * wide)
        # and a white-hot head that twinkles out as the burst dies
        next if dying && ((age * 14.0 + ph * 7.0) % 1.0) > 0.5 + 0.5 * fade

        hs = head * (dying ? 0.7 + 0.6 * ph : 1.0)
        ns[2] = quad(cs[2], ns[2], hx - ux * hs * 1.6, hy - uy * hs * 1.6, hx - uy * hs, hy + ux * hs, hx + ux * hs * 1.2, hy + uy * hs * 1.2,
                     hx + uy * hs, hy - ux * hs)
      end
      3.times do |q|
        i = base + q
        c = q < 2 ? cols[q] : [255, 250, 235]
        heat = q < 2 ? 0.25 + 0.75 * hot : 1.0
        r = c[0] + (255 - c[0]) * heat
        g = c[1] + (255 - c[1]) * heat
        bl = c[2] + (255 - c[2]) * heat
        if q < 2
          r = (r * boost).clamp(0, 255)
          g = (g * boost).clamp(0, 255)
          bl = (bl * boost).clamp(0, 255)
        end
        cmds = cs[q]
        cmds.pop while cmds.size > ns[q]
        next if ns[q].zero?

        alpha = q < 2 ? a : a**0.7
        @s.set(@shapes[i], { shape_commands: cmds, fill: [r.round, g.round, bl.round, (255 * alpha).round.clamp(0, 255)] })
        shaped[i] = true
        @shape_on[i] = true
      end
    end

    # Appends one four-point polygon at command k; returns the next k.
    def quad(c, k, x0, y0, x1, y1, x2, y2, x3, y3)
      put(c, k, MOVE, x0, y0)
      put(c, k + 1, LINE, x1, y1)
      put(c, k + 2, LINE, x2, y2)
      put(c, k + 3, LINE, x3, y3)
      k + 4
    end

    def put(c, k, op, x, y)
      p = c[k]
      if p
        p[0] = op
        p[1] = x.round(1)
        p[2] = y.round(1)
      else
        c << [op, x.round(1), y.round(1)]
      end
    end

    def spark_at(x, y, ux, uy, sp, age)
      travel = sp * DRAG * (1.0 - Math.exp(-age / DRAG))
      fall = 0.5 * 0.34 * @s.h * age * age
      [x + ux * travel, y + uy * travel + fall]
    end

    def show(i, used, props)
      used[i] = true
      unless @shown[i]
        props[:hidden] = false
        @shown[i] = true
      end
      @s.set(@drawables[i], props)
    end
  end

  # The spray a shoe leaves as you take it: streaks of gold and white flung out from where it
  # stood, slowing and fading inside half a second. A pure function of the time since.
  class WalkSpray
    TAU = Math::PI * 2
    LIFE = 0.55

    def initialize(scene, count: 28)
      @s = scene
      rnd = Random.new(4242)
      @dirs = Array.new(count) do |k|
        a = TAU * (k + 0.4 * rnd.rand) / count
        [Math.cos(a), Math.sin(a) * 0.85, 0.6 + 0.4 * rnd.rand, k % 3 == 0 ? [255, 255, 255] : [255, 214, 110]]
      end
    end

    # Inside a draw block.
    def build
      @lines = Array.new(@dirs.size) { @s.line(0, 0, 0, 0, stroke: Palette.rgb(Palette::GOLD, 0.0), strokewidth: 3.0 * @s.u, hidden: true) }
      @on = false
    end

    def enter
      @lines.each { |l| @s.set(l, { hidden: true }) }
      @on = false
    end

    # tau: seconds since a shoe was taken (nil: none); (x, y) where it stood on screen.
    def update(tau, x, y)
      unless tau && tau >= 0.0 && tau < LIFE
        @lines.each { |l| @s.set(l, { hidden: true }) } if @on
        @on = false
        return
      end
      reach = @s.h * 0.62
      k = tau / LIFE
      a = (1.0 - k)**1.3
      @dirs.each_with_index do |(ux, uy, sp, c), j|
        d1 = reach * sp * (1.0 - Math.exp(-tau / 0.16))
        d0 = reach * sp * (1.0 - Math.exp(-[tau - 0.07, 0.0].max / 0.16)) * 0.55
        props = { left: (x + ux * d0).round(1), top: (y + uy * d0).round(1), x2: (x + ux * d1).round(1), y2: (y + uy * d1).round(1),
                  stroke: [c[0], c[1], c[2], (255 * a).round.clamp(0, 255)] }
        props[:hidden] = false unless @on
        @s.set(@lines[j], props)
      end
      @on = true
    end
  end
end
