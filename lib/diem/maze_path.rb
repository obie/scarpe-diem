# frozen_string_literal: true

# The autopilot's road: a centripetal Catmull-Rom spline through route points, flattened into
# a polyline with its running length so a position is a binary search and a lerp. Corners in a
# corridor route are cut a little first, so the spline rounds them instead of overshooting
# into the walls.
module Diem
  class MazePath
    attr_reader :length

    # points: [[x, y], ...]. cut: how far before and after each interior corner the curve
    # starts and ends its turn (0 keeps the corner points).
    def self.corridor(points, cut: 0.45)
      return points if cut.zero? || points.size < 3

      out = [points.first]
      points.each_cons(3) do |a, b, c|
        d1 = unit(b[0] - a[0], b[1] - a[1])
        d2 = unit(c[0] - b[0], c[1] - b[1])
        if (d1[0] * d2[0] + d1[1] * d2[1]) > 0.999
          out << b
        else
          out << [b[0] - d1[0] * cut, b[1] - d1[1] * cut]
          out << [b[0] + d2[0] * cut, b[1] + d2[1] * cut]
        end
      end
      out << points.last
      straighten(out)
    end

    # Long straight runs get extra points, or the spline bows between far-apart knots.
    def self.straighten(points, step: 1.5)
      out = [points.first]
      points.each_cons(2) do |a, b|
        n = (Math.hypot(b[0] - a[0], b[1] - a[1]) / step).floor
        (1...n).each { |j| out << [a[0] + (b[0] - a[0]) * j / n, a[1] + (b[1] - a[1]) * j / n] }
        out << b
      end
      out
    end

    def self.unit(x, y)
      l = Math.hypot(x, y)
      [x / l, y / l]
    end

    def initialize(points, per_cell: 10)
      @xs = []
      @ys = []
      pts = [extend_end(points[1], points[0])] + points + [extend_end(points[-2], points[-1])]
      (1...(pts.size - 2)).each do |k|
        seg = segment(pts[k - 1], pts[k], pts[k + 1], pts[k + 2])
        n = [(Math.hypot(pts[k + 1][0] - pts[k][0], pts[k + 1][1] - pts[k][1]) * per_cell).ceil, 4].max
        start = k == 1 ? 0 : 1
        (start..n).each do |j|
          x, y = seg.call(j.fdiv(n))
          @xs << x
          @ys << y
        end
      end
      @ss = [0.0]
      (1...@xs.size).each { |i| @ss << @ss[-1] + Math.hypot(@xs[i] - @xs[i - 1], @ys[i] - @ys[i - 1]) }
      @length = @ss[-1]
      @last = @xs.size - 1
    end

    def x_at(s)
      i, f = locate(s)
      @xs[i] + (@xs[i + 1] - @xs[i]) * f
    end

    def y_at(s)
      i, f = locate(s)
      @ys[i] + (@ys[i + 1] - @ys[i]) * f
    end

    # Heading (radians) of the chord from s - back to s + ahead.
    def heading(s, ahead = 0.6, back = 0.1)
      a = s - back
      b = s + ahead
      Math.atan2(y_at(b) - y_at(a), x_at(b) - x_at(a))
    end

    # The distance along the path nearest to (x, y), to within a sample, at or after `from`.
    def nearest_s(x, y, from: 0.0)
      best = 0
      bd = Float::INFINITY
      @xs.each_index do |i|
        next if @ss[i] < from

        d = (@xs[i] - x)**2 + (@ys[i] - y)**2
        if d < bd
          bd = d
          best = i
        end
      end
      @ss[best]
    end

    private

    def locate(s)
      return [0, 0.0] if s <= 0.0
      return [@last - 1, 1.0] if s >= @length

      i = (@ss.bsearch_index { |v| v > s } || @last) - 1
      span = @ss[i + 1] - @ss[i]
      [i, span.zero? ? 0.0 : (s - @ss[i]) / span]
    end

    def extend_end(inner, tip)
      [tip[0] * 2 - inner[0], tip[1] * 2 - inner[1]]
    end

    # Barry and Goldman's pyramid for the centripetal Catmull-Rom segment p1 -> p2.
    def segment(p0, p1, p2, p3)
      t0 = 0.0
      t1 = t0 + knot(p0, p1)
      t2 = t1 + knot(p1, p2)
      t3 = t2 + knot(p2, p3)
      lambda do |f|
        t = t1 + (t2 - t1) * f
        a1 = lerp2(p0, p1, (t - t0) / (t1 - t0))
        a2 = lerp2(p1, p2, (t - t1) / (t2 - t1))
        a3 = lerp2(p2, p3, (t - t2) / (t3 - t2))
        b1 = lerp2(a1, a2, (t - t0) / (t2 - t0))
        b2 = lerp2(a2, a3, (t - t1) / (t3 - t1))
        lerp2(b1, b2, (t - t1) / (t2 - t1))
      end
    end

    def knot(a, b) = [Math.hypot(b[0] - a[0], b[1] - a[1])**0.5, 1e-4].max

    def lerp2(a, b, f) = [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f]
  end
end
