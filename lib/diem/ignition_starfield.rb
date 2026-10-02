# frozen_string_literal: true

module Diem
  # A true perspective starfield. Each star is one line from where it is to where it was a moment
  # ago, so a star at rest is a dot and a star at warp is a streak. Depth is the star's seed plus
  # the distance flown, wrapped, so the field is a pure function of t.
  class IgnitionStarfield
    NEAR = 0.03
    HUES = 16
    LEVELS = 32
    PARK = { left: -40, top: -40, x2: -40, y2: -40 }.freeze

    def initialize(scene, count, flight)
      @scene = scene
      @n = count
      @flight = flight
      @u = scene.u
      @f = scene.h * 0.5
      seed
      build_colours
    end

    def build
      s = @scene
      build_band
      ice = Palette.rgb(Palette::NIGHT)
      @lines = Array.new(@n) do
        s.line(-40, -40, -40, -40, stroke: ice, strokewidth: 1, cap: "round")
      end
    end

    # A band of violet haze across the sky, the galaxy we are flying through: two rects with
    # gradients fading out from the middle, turned with the camera's roll and slid by its yaw.
    def build_band
      s = @scene
      bw = s.w * 2.4
      bh = s.h * 0.3
      clear = s.rgb(0, 0, 0, 0)
      @band = [0, 1].map do |k|
        s.rect(0, 0, bw, bh, fill: clear, strokewidth: 0, center: true)
      end
      @band_h = bh
      @band_key = nil
    end

    # Two big gradient rects cost about 2 ms of paint, so the band is hidden whenever it would
    # be too faint to see, and for good once the logo owns the frame.
    def band(cx, cy, roll, yaw, pitch, level)
      lv = (level * 40).round
      if lv < 2
        return if @band_key == :off

        @band.each { |r| @scene.set(r, { hidden: true }) }
        @band_key = :off
        return
      end
      if @band_key == :off || @band_key.nil?
        @band.each { |r| @scene.set(r, { hidden: false }) }
      end
      ang = (-13.0 - roll * 57.2958).round(1)
      bx = (cx - Math.tan(yaw) * @f * 1.1).round(1)
      by = (cy - Math.tan(pitch) * @f * 1.1).round(1)
      key = [lv, ang, bx, by]
      return if key == @band_key

      @band_key = key
      a = (lv / 40.0 * 0.11 * 255).round
      c = Palette.mix(Palette::VIOLET, Palette::MAGENTA, 0.25)
      core = [c[0].round, c[1].round, c[2].round, a]
      clear = [c[0].round, c[1].round, c[2].round, 0]
      rad = ang * Math::PI / 180.0
      off = @band_h * 0.5
      @band.each_with_index do |r, k|
        sgn = k.zero? ? -1.0 : 1.0
        fill = { gradient: k.zero? ? [clear, core] : [core, clear], angle: 0 }
        @scene.set(r, { left: (bx + Math.sin(rad) * off * sgn).round(1), top: (by + Math.cos(rad) * off * sgn).round(1),
          rotate: ang, fill: fill })
      end
    end

    # Forget what was sent, so the next update writes every star.
    def reset
      @band_key = nil
      @sx.fill(-1e9)
      @sc.fill(-1)
      @sw.fill(-1.0)
      @on.fill(true)
    end

    # cx, cy: the vanishing point. glow: overall brightness 0..1. yaw, pitch: where the camera
    # looks (radians). sparkle: an extra brightness for every eighth star, group picks which.
    # floor: the dimmest level worth painting (the breath raises it, to spare the frozen streaks).
    # haze: the galaxy band's gain (0 hides it).
    def update(t, cx, cy, glow, yaw, pitch, sparkle, group, solid: false, haze: 1.0, floor: 1)
      fl = @flight
      d = fl.distance(t)
      roll = fl.roll(t)
      st = fl.stretch(t)
      tw = fl.twist(t)
      warp = fl.warp(t)
      cr = Math.cos(roll)
      sr = Math.sin(roll)
      ct = Math.cos(roll - tw)
      stt = Math.sin(roll - tw)
      band(cx, cy, roll, yaw, pitch, glow * (1.0 - warp) * haze)
      cyw = Math.cos(yaw)
      syw = Math.sin(yaw)
      cpi = Math.cos(pitch)
      spi = Math.sin(pitch)
      f = @f
      u4 = @u * 4.0 / (1.0 + 2.5 * st)
      w = @scene.w + 30.0
      h = @scene.h + 30.0
      gl = glow * (1.0 + 0.7 * warp) * (LEVELS - 1)
      hue_k = warp * (HUES - 1)
      xs = @x
      ys = @y
      z0 = @z0
      lines = @lines
      cols = @cols
      lx = @sx
      ly = @sy
      lx2 = @sx2
      ly2 = @sy2
      lc = @sc
      lw = @sw
      on = @on
      mags = @mag
      cls = @cls
      long2 = solid ? 1e18 : (14.0 * @u)**2
      spark_w = sparkle * 2.4 * @u
      cuts = solid ? @cut_boom : @cut
      span = 1.0 - NEAR
      i = 0
      n = @n
      while i < n
        zf = (z0[i] + d) % 1.0
        z = 1.0 - zf * span
        zt = z + st
        zt = 1.0 if zt > 1.0
        x = xs[i]
        y = ys[i]
        rx = x * cr - y * sr
        ry = x * sr + y * cr
        zz = z * cyw - rx * syw
        ry, zz = ry * cpi - zz * spi, zz * cpi + ry * spi
        zz = 0.01 if zz < 0.01
        k = f / zz
        hx = cx + (rx * cyw + z * syw) * k
        hy = cy + ry * k
        rx = x * ct - y * stt
        ry = x * stt + y * ct
        zz = zt * cyw - rx * syw
        ry, zz = ry * cpi - zz * spi, zz * cpi + ry * spi
        zz = 0.01 if zz < 0.01
        k = f / zz
        tx = cx + (rx * cyw + zt * syw) * k
        ty = cy + ry * k
        thin = (cuts[i] - warp) * 8.0
        near = 1.0 - z
        b = (0.58 + 0.62 * Math.sqrt(near)) * mags[i]
        b *= near / 0.1 if near < 0.1
        lit = (i & 7) == group
        b += sparkle if lit
        b *= thin if thin < 1.0
        bi = (b * gl).round
        # A star below the floor is night on night: park it rather than paint it.
        if thin <= 0.0 || bi < floor || ((hx < -30.0 || hx > w || hy < -30.0 || hy > h) && (tx < -30.0 || tx > w || ty < -30.0 || ty > h))
          if on[i]
            @scene.set(lines[i], PARK)
            on[i] = false
            lx[i] = -1e9
          end
          i += 1
          next
        end
        on[i] = true
        bi = LEVELS - 1 if bi >= LEVELS
        ci = (cls[i] + (hue_k * (0.35 + 0.65 * near)).round) * LEVELS + bi
        wd = ((1.1 + 3.0 * near * near) * mags[i] * u4).round / 4.0
        wd += (spark_w * 4.0).round / 4.0 if lit
        hx = hx.round(1)
        hy = hy.round(1)
        tx = tx.round(1)
        ty = ty.round(1)
        ddx = hx - tx
        ddy = hy - ty
        if ddx * ddx + ddy * ddy > long2
          ci = ci * 5 + (ddx >= 0.0 ? (ddy >= 0.0 ? 1 : 2) : (ddy >= 0.0 ? 4 : 3))
        else
          ci *= 5
        end
        moved = hx != lx[i] || hy != ly[i] || tx != lx2[i] || ty != ly2[i]
        if moved
          lx[i] = hx
          ly[i] = hy
          lx2[i] = tx
          ly2[i] = ty
          if wd != lw[i]
            lw[i] = wd
            lc[i] = ci
            @scene.set(lines[i], { left: hx, top: hy, x2: tx, y2: ty, stroke: cols[ci], strokewidth: wd })
          elsif ci != lc[i]
            lc[i] = ci
            @scene.set(lines[i], { left: hx, top: hy, x2: tx, y2: ty, stroke: cols[ci] })
          else
            @scene.set(lines[i], { left: hx, top: hy, x2: tx, y2: ty })
          end
        elsif ci != lc[i]
          lc[i] = ci
          @scene.set(lines[i], { stroke: cols[ci] })
        end
        i += 1
      end
    end

    private

    def seed
      rnd = Random.new(4207)
      @x = Array.new(@n, 0.0)
      @y = Array.new(@n, 0.0)
      @z0 = Array.new(@n, 0.0)
      aspect = @scene.w.fdiv(@scene.h)
      @n.times do |i|
        r = 0.05 + 0.95 * rnd.rand**0.85
        a = rnd.rand * Math::PI * 2
        @x[i] = r * Math.cos(a) * aspect * 1.08
        @y[i] = r * Math.sin(a) * 1.08
        @z0[i] = rnd.rand
      end
      # Long streaks fill the sky, so as warp rises 35% of the stars bow out, each at its own point.
      @cut = Array.new(@n) { |i| i >= @n * 0.65 ? 0.25 + 0.6 * rnd.rand : 9.0 }
      # Behind the exploding logo the debris fills the frame, so on the fill's warp another 30%
      # bow out too (streaks at full warp are the costliest thing to paint).
      more = Random.new(4208)
      @cut_boom = Array.new(@n) { |i| i >= @n * 0.35 && i < @n * 0.65 ? 0.3 + 0.55 * more.rand : @cut[i] }
      @mag = Array.new(@n) { 0.5 + 0.5 * rnd.rand**0.6 }
      @cls = Array.new(@n) do
        c = rnd.rand
        (c < 0.74 ? 0 : (c < 0.88 ? 1 : 2)) * HUES
      end
      @sx = Array.new(@n, -1e9)
      @sy = Array.new(@n, 0.0)
      @sx2 = Array.new(@n, 0.0)
      @sy2 = Array.new(@n, 0.0)
      @sc = Array.new(@n, -1)
      @sw = Array.new(@n, -1.0)
      @on = Array.new(@n, true)
    end

    # 3 star classes (ice, gold, rose) x HUES x LEVELS opaque colours. Warp pulls every class
    # along cyan to magenta; each colour is faded toward the night by level.
    def build_colours
      ice = Palette.mix(Palette::INK, Palette::CYAN, 0.22)
      bases = [ice, Palette.mix(Palette::INK, Palette::GOLD, 0.55), Palette.mix(Palette::INK, Palette::MAGENTA, 0.45)]
      stops = [Palette::CYAN, Palette.mix(Palette::CYAN, Palette::VIOLET, 0.6), Palette::MAGENTA]
      solid = []
      bases.each do |base|
        HUES.times do |hi|
          h = hi.fdiv(HUES - 1)
          x = h * (stops.size - 1)
          k = [x.floor, stops.size - 2].min
          c = Palette.mix(base, Palette.mix(stops[k], stops[k + 1], x - k), [h * 2.5, 1.0].min)
          LEVELS.times do |bi|
            m = Palette.mix(Palette::NIGHT, c, bi.fdiv(LEVELS - 1))
            solid << [m[0].round, m[1].round, m[2].round, 255].freeze
          end
        end
      end
      @cols = gradients(solid)
    end

    # Five strokes per colour: solid, then a gradient from a clear tail to the head for each
    # quadrant a streak can point into (a line's gradient box is the line's own diagonal, so
    # 45, 135, 225 and 315 degrees run exactly tail to head).
    def gradients(solid)
      solid.flat_map do |c|
        tail = [c[0], c[1], c[2], 0].freeze
        [c] + [45, 135, 225, 315].map { |a| { gradient: [tail, c].freeze, angle: a }.freeze }
      end
    end
  end
end
