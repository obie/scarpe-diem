# frozen_string_literal: true

require_relative "maze_shapes"

# The pickups of WOLFENSHOES 3D: a spinning sneaker drawn as antialiased polygons (a dark rim,
# the upper, a white toe cap, a heel stripe, laces and the sole), squeezed by the cosine of
# its spin and mirrored as it turns, and the burst of sparks it leaves when it is collected.
module Diem
  class MazeShoes
    TAU = Math::PI * 2
    SAMPLES = 14

    def initialize(scene, pool)
      @s = scene
      @pool = pool
      @qs = Array.new(SAMPLES + 1) { |k| -1.0 + 2.0 * k / SAMPLES }
      @top = @qs.map { |q| top(q) }
      @sole = @qs.map { |q| sole(q) }
      big = SAMPLES * 2 + 8
      @xs = Array.new(big, 0.0)
      @ys = Array.new(big, 0.0)
      @ox = Array.new(big + 8, 0.0)
      @oy = Array.new(big + 8, 0.0)
      @tx = Array.new(big + 8, 0.0)
      @ty = Array.new(big + 8, 0.0)
      @lx = Array.new(12, 0.0)
      @ly = Array.new(12, 0.0)
    end

    # One shoe: centre (sx, zc), half its length in pixels before the spin, height in pixels,
    # spin angle, base colour, fog mix and the bands it shows through (nil: all).
    def draw(sx, zc, half, hgt, spin, base, fog, fogk, runs)
      c = Math.cos(spin)
      sgn = c < 0 ? -1.0 : 1.0
      hw = half * (c.abs < 0.12 ? 0.12 : c.abs) * sgn
      lit = 0.65 + 0.35 * c * c
      line = 0.28 # top of the sole, as a share of the height

      # rim: the whole silhouette, grown, in dark plum
      m = outline(sx, zc, hw, hgt, -1.0, 1.0, nil)
      MazeClip.grow(@xs, @ys, m, 1.4 * @s.u)
      emit(m, colour(70, 10, 50, fog, fogk), runs)

      m = outline(sx, zc, hw, hgt, -1.0, 1.0, line)
      emit(m, { gradient: [colour(base[0] * lit, base[1] * lit + 10, base[2] * lit, fog, fogk), colour(170, 18, 96, fog, fogk)], angle: 0 }, runs)
      m = outline(sx, zc, hw, hgt, 0.52, 1.0, line)
      emit(m, { gradient: [colour(255 * lit, 248 * lit, 252 * lit, fog, fogk), colour(215, 200, 225, fog, fogk)], angle: 0 }, runs)
      m = outline(sx, zc, hw, hgt, -0.74, -0.62, line)
      emit(m, colour(255, 240, 250, fog, fogk), runs)
      laces(sx, zc, hw, hgt, colour(255 * lit, 236 * lit, 246 * lit, fog, fogk), runs)
      m = sole_band(sx, zc, hw, hgt, line)
      emit(m, { gradient: [colour(250, 250, 255, fog, fogk), colour(120, 110, 150, fog, fogk)], angle: 0 }, runs)
    end

    # Sparks from a collected shoe, k (0..1) through the burst, centred on (x, y), reach r px.
    def burst(x, y, r, k, count)
      a = 1.0 - k
      count.times do |j|
        ang = j * TAU / count + 0.4
        d = r * (0.25 + 0.75 * Math.sqrt(k)) * (0.75 + 0.25 * ((j * 7) % 3))
        cx = x + Math.cos(ang) * d
        cy = y + Math.sin(ang) * d * 0.8
        sz = r * 0.07 * (1.0 - 0.6 * k)
        ux = Math.cos(ang)
        uy = Math.sin(ang) * 0.8
        @lx[0] = cx + ux * sz * 2.4
        @ly[0] = cy + uy * sz * 2.4
        @lx[1] = cx - uy * sz * 0.45
        @ly[1] = cy + ux * sz * 0.45
        @lx[2] = cx - ux * sz * 2.4
        @ly[2] = cy - uy * sz * 2.4
        @lx[3] = cx + uy * sz * 0.45
        @ly[3] = cy - ux * sz * 0.45
        c = j.even? ? [255, 226, 120] : [255, 255, 255]
        @pool.poly(@lx, @ly, 4, [c[0], c[1], c[2], (255 * a).round.clamp(0, 255)])
      end
    end

    # A ring of light round (x, y): an annulus of radius r and thickness th.
    def ring(x, y, r, th, fill)
      outer = @ring_o ||= [Array.new(28, 0.0), Array.new(28, 0.0), 28]
      inner = @ring_i ||= [Array.new(28, 0.0), Array.new(28, 0.0), 28]
      28.times do |k|
        a = k * TAU / 28
        outer[0][k] = x + Math.cos(a) * r
        outer[1][k] = y + Math.sin(a) * r * 0.8
        inner[0][27 - k] = x + Math.cos(a) * (r - th)
        inner[1][27 - k] = y + Math.sin(a) * (r - th) * 0.8
      end
      @pool.multi(@rings ||= [outer, inner], fill)
    end

    # The glint that runs across a shoe as it turns face-on: two thin crossed diamonds.
    def glint(x, y, len, alpha)
      th = len * 0.09
      fill = [255, 255, 255, alpha.round.clamp(0, 255)]
      [[len, th], [th, len]].each do |ax, ay|
        @lx[0] = x - ax
        @ly[0] = y
        @lx[1] = x
        @ly[1] = y - ay
        @lx[2] = x + ax
        @ly[2] = y
        @lx[3] = x
        @ly[3] = y + ay
        @pool.poly(@lx, @ly, 4, fill)
      end
    end

    private

    # Points along the top from q0 to q1, then back along the line `line` (or the bottom of
    # the sole when nil). Returns the count in @xs/@ys.
    def outline(sx, zc, hw, hgt, q0, q1, line)
      m = put(0, sx + q0 * hw, zc + hgt * (0.5 - top(q0)))
      @qs.each_with_index do |q, k|
        m = put(m, sx + q * hw, zc + hgt * (0.5 - @top[k])) if q > q0 + 1e-6 && q < q1 - 1e-6
      end
      m = put(m, sx + q1 * hw, zc + hgt * (0.5 - top(q1)))
      if line
        m = put(m, sx + q1 * hw, zc + hgt * (0.5 - line))
        put(m, sx + q0 * hw, zc + hgt * (0.5 - line))
      else
        (@qs.size - 1).downto(0) { |k| m = put(m, sx + @qs[k] * hw, zc + hgt * (0.5 - @sole[k])) }
        m
      end
    end

    def sole_band(sx, zc, hw, hgt, line)
      m = 0
      @qs.each { |q| m = put(m, sx + q * hw, zc + hgt * (0.5 - line)) }
      (@qs.size - 1).downto(0) { |k| m = put(m, sx + @qs[k] * hw, zc + hgt * (0.5 - @sole[k])) }
      m
    end

    def laces(sx, zc, hw, hgt, fill, runs)
      [-0.16, 0.04, 0.24].each do |q|
        y0 = zc + hgt * (0.5 - top(q))
        w = 0.07
        @lx[0] = sx + q * hw
        @ly[0] = y0
        @lx[1] = sx + (q + w) * hw
        @ly[1] = zc + hgt * (0.5 - top(q + w))
        @lx[2] = sx + (q + w - 0.1) * hw
        @ly[2] = @ly[1] + hgt * 0.16
        @lx[3] = sx + (q - 0.1) * hw
        @ly[3] = y0 + hgt * 0.16
        4.times do |k|
          @xs[k] = @lx[k]
          @ys[k] = @ly[k]
        end
        emit(4, fill, runs)
      end
    end

    def put(m, x, y)
      @xs[m] = x
      @ys[m] = y
      m + 1
    end

    def emit(m, fill, runs)
      if runs.nil?
        @pool.poly(@xs, @ys, m, fill)
        return
      end
      k = 0
      while k < runs.size
        n = MazeClip.x_band(@xs, @ys, m, runs[k], runs[k + 1], @ox, @oy, @tx, @ty)
        @pool.poly(@ox, @oy, n, fill)
        k += 2
      end
    end

    def colour(r, g, b, fog, fogk)
      keep = 1.0 - fogk
      [(r * keep + fog[0] * fogk).round.clamp(0, 255), (g * keep + fog[1] * fogk).round.clamp(0, 255),
       (b * keep + fog[2] * fogk).round.clamp(0, 255), 255]
    end

    # Height of the upper (share of the sprite) along the shoe, heel (-1) to toe (+1): a
    # rounded heel counter, the dip of the collar, the tongue, then the laces running down to
    # a round toe.
    def top(q)
      if q < -0.78 then 0.62 + 0.24 * Math.sqrt([1.0 - ((q + 0.78) / 0.22)**2, 0.0].max)
      elsif q < -0.42 then 0.86 - 0.05 * Math.sin((q + 0.78) / 0.36 * Math::PI)
      elsif q < -0.28 then 0.86 + 0.08 * (q + 0.42) / 0.14
      elsif q < 0.38 then 0.94 - 0.39 * (q + 0.28) / 0.66
      else 0.27 + 0.28 * Math.sqrt([1.0 - ((q - 0.38) / 0.62)**2, 0.0].max)
      end
    end

    def sole(q)
      if q > 0.8 then (q - 0.8) * 0.9
      elsif q < -0.88 then (-0.88 - q) * 1.2
      else 0.0
      end
    end
  end
end
