# frozen_string_literal: true

# Antialiased polygons for WOLFENSHOES 3D: a pool of shapes written in paint order each frame
# (the first polygon written paints first), with the clipping and hull helpers the gems, the
# shoes and the door's chevrons share. Points go in as flat Float Arrays so nothing is
# allocated per point; each slot keeps its command Arrays from frame to frame.
module Diem
  class MazeShapes
    MOVE = "move_to"
    LINE = "line_to"

    attr_reader :size

    # Inside a draw block.
    def initialize(scene, size)
      @s = scene
      @size = size
      @shapes = Array.new(size) { scene.shape(0, 0, fill: Palette.rgb(Palette::RUBY), strokewidth: 0) }
      @cmds = Array.new(size) { [] }
      @q = 0
      @used = 0
    end

    def enter
      @shapes.each { |sh| @s.set(sh, { shape_commands: [] }) }
      @q = 0
      @used = 0
    end

    def begin_frame
      @q = 0
    end

    def full? = @q >= @size

    # One closed polygon from the first n points of xs, ys.
    def poly(xs, ys, n, fill)
      return if @q >= @size || n < 3

      c = @cmds[@q]
      k = 0
      while k < n
        put(c, k, k.zero? ? MOVE : LINE, xs[k], ys[k])
        k += 1
      end
      c.pop while c.size > n
      @s.set(@shapes[@q], { shape_commands: c, fill: fill })
      @q += 1
    end

    # Several polygons in one shape (one fill): rings is [[xs, ys, n], ...].
    def multi(rings, fill)
      return if @q >= @size

      c = @cmds[@q]
      k = 0
      rings.each do |xs, ys, n|
        next if n < 3

        j = 0
        while j < n
          put(c, k, j.zero? ? MOVE : LINE, xs[j], ys[j])
          j += 1
          k += 1
        end
      end
      return if k.zero?

      c.pop while c.size > k
      @s.set(@shapes[@q], { shape_commands: c, fill: fill })
      @q += 1
    end

    def end_frame
      (@q...@used).each { |i| @s.set(@shapes[i], { shape_commands: [] }) }
      @used = @q
    end

    private

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
  end

  # Polygon helpers on flat Float Arrays.
  module MazeClip
    module_function

    # Clips the convex polygon (xs, ys, n) to xa <= x <= xb into (ox, oy); returns the count.
    # tx, ty are scratch Arrays.
    def x_band(xs, ys, n, xa, xb, ox, oy, tx, ty)
      m = edge(xs, ys, n, xa, 1.0, tx, ty)
      edge(tx, ty, m, xb, -1.0, ox, oy)
    end

    # Keeps the side where (x - at) * sign >= 0.
    def edge(xs, ys, n, at, sign, ox, oy)
      m = 0
      return 0 if n.zero?

      px = xs[n - 1]
      py = ys[n - 1]
      pin = (px - at) * sign >= 0.0
      k = 0
      while k < n
        cx = xs[k]
        cy = ys[k]
        cin = (cx - at) * sign >= 0.0
        if cin != pin
          f = (at - px) / (cx - px)
          ox[m] = at
          oy[m] = py + (cy - py) * f
          m += 1
        end
        if cin
          ox[m] = cx
          oy[m] = cy
          m += 1
        end
        px = cx
        py = cy
        pin = cin
        k += 1
      end
      m
    end

    # Convex hull (Andrew's monotone chain) of n points into (ox, oy), counter-clockwise on
    # screen; returns the count. order is a scratch Array of indices.
    def hull(xs, ys, n, ox, oy, order)
      order.clear
      n.times { |i| order << i }
      order.sort! { |a, b| (xs[a] <=> xs[b]).nonzero? || (ys[a] <=> ys[b]) }
      m = 0
      order.each do |i|
        m -= 1 while m >= 2 && cross(ox[m - 2], oy[m - 2], ox[m - 1], oy[m - 1], xs[i], ys[i]) <= 0.0
        ox[m] = xs[i]
        oy[m] = ys[i]
        m += 1
      end
      lo = m + 1
      (n - 2).downto(0) do |j|
        i = order[j]
        m -= 1 while m >= lo && cross(ox[m - 2], oy[m - 2], ox[m - 1], oy[m - 1], xs[i], ys[i]) <= 0.0
        ox[m] = xs[i]
        oy[m] = ys[i]
        m += 1
      end
      m - 1
    end

    def cross(ax, ay, bx, by, cx, cy)
      (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    end

    # Pushes every point of a convex polygon e pixels away from its centre.
    def grow(xs, ys, n, e)
      cx = 0.0
      cy = 0.0
      n.times do |k|
        cx += xs[k]
        cy += ys[k]
      end
      cx /= n
      cy /= n
      n.times do |k|
        dx = xs[k] - cx
        dy = ys[k] - cy
        l = Math.sqrt(dx * dx + dy * dy) + 1e-6
        xs[k] += dx / l * e
        ys[k] += dy / l * e
      end
    end
  end
end
