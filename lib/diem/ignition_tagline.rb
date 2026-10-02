# frozen_string_literal: true

module Diem
  # The tagline under the logo: one small square per lit font pixel. Letters fly up out of the
  # depths one after another, settle with a little overshoot, catch a gold glint each bar, then
  # fall away when the logo explodes. Squares are only written when their pixel or colour moves.
  class IgnitionTagline
    TEXT = "A REAL-TIME DEMO IN RUBY + SHOES"
    ARRIVE = 20.0
    STAGGER = 0.05
    FLIGHT = 0.8
    GLINTS = 8
    LEVELS = 24
    LAND = 0.85 # where in its flight (0..1) a pixel visibly settles into its slot

    def initialize(scene, cell, cy)
      @scene = scene
      @u = scene.u
      @q = cell * 0.19
      @cx = scene.w / 2.0
      @cy = cy
      @cam = 1000.0 * @u
      place
      build_colours
    end

    def build
      night = Palette.rgb(Palette::NIGHT)
      @rects = Array.new(@n) { @scene.rect(-50, -50, 0, 0, fill: night, strokewidth: 0, center: true) }
    end

    def reset
      @lx.fill(-1e9)
      @lc.fill(-1)
    end

    def update(t, kick)
      return park_all if t < ARRIVE
      return fall(t) if t >= IgnitionFlight::BOOM

      cam = @cam
      size = @q * 0.84
      sweep = ((t - ARRIVE) % 2.0) / 1.4
      # While the logo turns, the line steps down and back out of its way.
      duck = smooth(23.5, 24.3, t) * (1.0 - smooth(27.7, 28.5, t))
      cy = @cy + 40.0 * @u * duck
      dim = 1.0 - 0.6 * duck
      i = 0
      while i < @n
        p = (t - @ta[i]) / FLIGHT
        if p <= 0.0
          park(i)
          i += 1
          next
        end
        if p >= 1.0
          x = @hx[i]
          y = @hy[i]
          sc = 1.0
          fade = 1.0
        else
          e = back_out(p)
          g = 1.0 - e
          x = @hx[i] + @fx[i] * g
          y = @hy[i] + @fy[i] * g
          z = @fz[i] * (1.0 - p) * (1.0 - p)
          sc = cam / (cam + z)
          fade = 0.45 + p * 1.6
          fade = 1.0 if fade > 1.0
        end
        d = @nx[i] - sweep
        gl = d.abs < 0.08 ? ((1.0 - d.abs / 0.08) * (GLINTS - 1)).round : 0
        # Each pixel lands with a gold spark that cools over a third of a second.
        land = p - LAND
        if land > -0.12 && land < 0.42
          k = land < 0.0 ? 1.0 + land / 0.12 : 1.0 - land / 0.42
          fl = (k * (GLINTS - 1)).round
          gl = fl if fl > gl
          fade = 1.0 if k > 0.3
        end
        lev = ((0.82 + 0.18 * kick + 0.18 * (gl.fdiv(GLINTS - 1))) * fade * dim * (LEVELS - 1)).round
        lev = LEVELS - 1 if lev >= LEVELS
        write(i, @cx + x * sc, cy + y * sc, size * sc, gl * LEVELS + lev)
        i += 1
      end
    end

    private

    def fall(t)
      tau = t - IgnitionFlight::BOOM
      fade = (1.0 - ((t - 31.02) / 0.26).clamp(0.0, 1.0))**2
      return park_all if fade <= 0.0

      size = @q * 0.84
      i = 0
      while i < @n
        tt = tau - @drop[i]
        tt = 0.0 if tt.negative?
        y = @hy[i] - @fy[i] * 1.4 * tt + 0.5 * 1300.0 * @u * tt * tt
        x = @hx[i] + @fx[i] * 1.6 * tt
        write(i, @cx + x, @cy + y, size, (fade * 0.82 * (LEVELS - 1)).round)
        i += 1
      end
    end

    def write(i, x, y, size, ci)
      x = x.round(1)
      y = y.round(1)
      if x != @lx[i] || y != @ly[i]
        @lx[i] = x
        @ly[i] = y
        @lc[i] = ci
        size = size.round(1)
        @scene.set(@rects[i], { left: x, top: y, width: size, height: size, fill: @cols[ci] })
      elsif ci != @lc[i]
        @lc[i] = ci
        @scene.set(@rects[i], { fill: @cols[ci] })
      end
    end

    def park(i)
      return if @lx[i] == -50.0

      @lx[i] = -50.0
      @scene.set(@rects[i], { left: -50, top: -50, width: 0, height: 0 })
    end

    def park_all
      @n.times { |i| park(i) }
    end

    def smooth(a, b, t)
      x = ((t - a) / (b - a)).clamp(0.0, 1.0)
      x * x * (3.0 - 2.0 * x)
    end

    def back_out(p)
      s = 1.9
      p -= 1.0
      p * p * ((s + 1.0) * p + s) + 1.0
    end

    def place
      rnd = Random.new(2020)
      pts = Bitfont.points_centered(TEXT)
      bw = Bitfont.width(TEXT)
      @n = pts.size
      @hx = pts.map { |x, _| (x + 0.5) * @q }
      @hy = pts.map { |_, y| (y + 0.5) * @q }
      @nx = pts.map { |x, _| (x + bw / 2.0) / bw }
      chars = pts.map { |x, _| ((x + bw / 2.0) / 6.0).floor }
      @ta = chars.map { |c| ARRIVE + c * STAGGER + rnd.rand * 0.08 }
      @fx = Array.new(@n) { (rnd.rand - 0.5) * 520.0 * @u }
      @fy = Array.new(@n) { (140.0 + rnd.rand * 220.0) * @u }
      @fz = Array.new(@n) { (900.0 + rnd.rand * 1400.0) * @u }
      @drop = chars.map { |c| (c - 16).abs * 0.012 + rnd.rand * 0.05 }
      @lx = Array.new(@n, -1e9)
      @ly = Array.new(@n, 0.0)
      @lc = Array.new(@n, -1)
    end

    def build_colours
      base = Palette.mix(Palette::INK, Palette::CYAN, 0.3)
      @cols = []
      GLINTS.times do |g|
        c = Palette.mix(base, Palette::GOLD, g.fdiv(GLINTS - 1))
        LEVELS.times do |b|
          m = Palette.mix(Palette::NIGHT, c, b.fdiv(LEVELS - 1))
          @cols << [m[0].round, m[1].round, m[2].round, 255].freeze
        end
      end
    end
  end
end
