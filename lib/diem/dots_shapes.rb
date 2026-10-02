# frozen_string_literal: true

# The point sets the Dots scene morphs between, built once. Every set holds exactly n points and
# is put in the same "reading order" (horizontal bands from the top, each band sorted around the
# vertical axis), so slot i of one shape sits near slot i of the next and a morph flows instead
# of scrambling. Shapes whose points move (the torus streams, the helix twists) keep parameters
# rather than positions.
module Diem
  module DotsShapes
    GOLDEN = Math::PI * (3.0 - Math.sqrt(5.0))
    TAU = Math::PI * 2

    module_function

    # Indices of the points in reading order. side: :around sorts a band by azimuth, :across by x.
    def reading_order(xs, ys, zs, side: :around)
      n = xs.size
      by_height = (0...n).sort_by { |i| -ys[i] }
      band = (n / [(Math.sqrt(n) / 2).round, 1].max.to_f).ceil
      by_height.each_slice(band).flat_map do |slice|
        side == :across ? slice.sort_by { |i| xs[i] } : slice.sort_by { |i| Math.atan2(zs[i], xs[i]) }
      end
    end

    def permute(arrays, order) = arrays.map { |a| order.map { |i| a[i] } }

    # A loose spherical nebula the dots condense out of.
    def cloud(n, rng)
      xs = []
      ys = []
      zs = []
      n.times do
        r = 1.9 + 1.6 * rng.rand**0.5
        y = rng.rand * 2 - 1
        th = rng.rand * TAU
        s = Math.sqrt(1 - y * y)
        xs << r * s * Math.cos(th) * 1.5
        ys << r * y * 0.8
        zs << r * s * Math.sin(th)
      end
      permute([xs, ys, zs], reading_order(xs, ys, zs))
    end

    # Fibonacci sphere, unit radius.
    def sphere(n)
      xs = []
      ys = []
      zs = []
      n.times do |i|
        y = 1 - 2 * (i + 0.5) / n
        r = Math.sqrt(1 - y * y)
        xs << r * Math.cos(i * GOLDEN)
        ys << y
        zs << r * Math.sin(i * GOLDEN)
      end
      permute([xs, ys, zs], reading_order(xs, ys, zs))
    end

    # Torus parameters [u around the ring, v around the tube] as one continuous coil, like a
    # slinky: `loops` turns of the tube, so it closes at any density.
    def torus(n, big, small, loops)
      us = []
      vs = []
      xs = []
      ys = []
      zs = []
      n.times do |i|
        u = TAU * (i + 0.5) / n
        v = -TAU * ((i * loops).fdiv(n) % 1.0)
        us << u
        vs << v
        rr = big + small * Math.cos(v)
        xs << rr * Math.cos(u)
        ys << small * Math.sin(v)
        zs << rr * Math.sin(u)
      end
      permute([us, vs], reading_order(xs, ys, zs))
    end

    # Double helix parameters: [kind (0, 1 strand; 2 rung), height, across (-1..1 on a rung),
    # tube jitter angle, tube jitter radius].
    def helix(n, rng, half_height, rungs)
      strand = (n * 0.62).round
      kinds = []
      hs = []
      fs = []
      ja = []
      jr = []
      strand.times do |j|
        kinds << j % 2
        hs << -half_height + 2 * half_height * ((j / 2) + 0.5) / ((strand + 1) / 2)
        fs << (j.even? ? 1.0 : -1.0)
        ja << rng.rand * TAU
        jr << 0.035 * rng.rand
      end
      rest = n - strand
      rest.times do |k|
        r = k % rungs
        m = k / rungs
        per = (rest + rungs - 1 - r) / rungs
        kinds << 2
        hs << -half_height + 2 * half_height * (r + 0.5) / rungs
        fs << -0.82 + 1.64 * (m + 0.5) / [per, 1].max
        ja << rng.rand * TAU
        jr << 0.012 * rng.rand
      end
      xs = []
      ys = []
      zs = []
      n.times do |i|
        th = 3.6 * hs[i]
        xs << fs[i] * Math.cos(th)
        ys << hs[i]
        zs << fs[i] * Math.sin(th)
      end
      permute([kinds, hs, fs, ja, jr], reading_order(xs, ys, zs))
    end

    # A three-armed spiral disc in the xz plane: [radius, angle, thickness offset].
    def vortex(n, rng)
      rs = []
      ths = []
      ys = []
      n.times do |i|
        if i % 7 == 0
          r = 0.05 + 0.3 * rng.rand
          th = rng.rand * TAU
        else
          r = 0.1 + 1.55 * rng.rand**0.9
          th = (i % 3) * TAU / 3 - 2.0 * Math.log(r + 0.2) + gauss(rng) * (0.09 + 0.15 * r)
        end
        rs << r
        ths << th
        ys << gauss(rng) * 0.035 * (1.4 - r * 0.6)
      end
      xs = rs.each_index.map { |i| rs[i] * Math.cos(ths[i]) }
      zs = rs.each_index.map { |i| rs[i] * Math.sin(ths[i]) }
      permute([rs, ths, ys], reading_order(xs, zs.map(&:-@), ys, side: :across))
    end

    def gauss(rng)
      Math.sqrt(-2 * Math.log(1 - rng.rand)) * Math.cos(TAU * rng.rand)
    end

    # "SHOES" as extruded voxel text. Each font pixel is a g x g block of dots on one even
    # lattice, so neighbouring pixels join into hard square strokes; the front face gets every
    # dot, then the outline is repeated at depth layers to make solid walls. g shrinks with n.
    def word(n, text, pitch, depth)
      pixels = Bitfont.points_centered(text)
      lit = pixels.to_h { |px, py| [[px.round(1), py.round(1)], true] }
      g = [3, 2, 1].find { |k| pixels.size * k * k <= n * 0.7 } || 1
      front = []
      rim = []
      pixels.each do |px, py|
        g.times do |a|
          g.times do |b|
            spot = [px + (a + 0.5) / g, py + (b + 0.5) / g]
            front << spot
            edge = (a.zero? && !lit[[(px - 1).round(1), py.round(1)]]) ||
                   (a == g - 1 && !lit[[(px + 1).round(1), py.round(1)]]) ||
                   (b.zero? && !lit[[px.round(1), (py - 1).round(1)]]) ||
                   (b == g - 1 && !lit[[px.round(1), (py + 1).round(1)]])
            rim << spot if edge
          end
        end
      end
      spots = front.map { |x, y| [x, y, 0.0] }
      [1.0, 0.5, 0.75, 0.25].cycle.each_with_index do |f, lap|
        break if spots.size >= n

        z = -depth * f * (1 + 0.15 * (lap / 4))
        room = n - spots.size
        layer = rim.size <= room ? rim : evenly(rim, room)
        layer.each { |x, y| spots << [x, y, z] }
      end
      xs = spots.map { |x, _, _| x * pitch }
      ys = spots.map { |_, y, _| -y * pitch }
      zs = spots.map(&:last)
      [xs, ys, zs]
    end

    def evenly(list, count)
      Array.new(count) { |k| list[(k * list.size) / count] }
    end

    # Reorders `arrays` (a shape whose points are listed in `order`) so that the k-th point of
    # that order lands in slot ref[k]: dot ref[k] of the previous shape flies to it.
    def align(arrays, order, ref)
      n = ref.size
      out = arrays.map { Array.new(n) }
      n.times do |k|
        src = order[k]
        dst = ref[k]
        arrays.each_with_index { |a, j| out[j][dst] = a[src] }
      end
      out
    end

    # Slot order for a morph from a horizontal ladder into the word: columns left to right, and
    # inside each column from the bottom up, so every dot rises or falls a little into its pixel.
    def columns(keys_x, keys_y, count)
      n = keys_x.size
      by_x = (0...n).sort_by { |i| keys_x[i] }
      size = (n / count.to_f).ceil
      by_x.each_slice(size).flat_map { |col| col.sort_by { |i| keys_y[i] } }
    end
  end
end
