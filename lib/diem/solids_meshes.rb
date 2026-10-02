# frozen_string_literal: true

require_relative "solids_engine"

# The three solids: a (2,3) torus knot tube, a geodesic sphere, and a brilliant-cut gem.
module Diem
  module Solids
    # A hexagonal tube along the (2,3) torus knot. The tube's frame comes from the torus it
    # lies on (the surface normal is always square to the curve), so it closes with no seam.
    class Knot
      attr_reader :mesh, :segments, :sides

      def initialize(segments, sides, tube)
        @segments = segments
        @sides = sides
        @tube = tube
        @c = []
        @d = []
        @b = []
        segments.times { |i| frame(i * TAU / segments) }
        @cos = Array.new(sides) { |j| Math.cos(j * TAU / sides) }
        @sin = Array.new(sides) { |j| Math.sin(j * TAU / sides) }
        @rad = Array.new(segments, tube)
        @tw = Array.new(segments, 0.0)
        @phi = Array.new(segments) { |i| i * TAU / segments }
        verts = Array.new(segments * sides * 3, 0.0)
        fill(verts)
        faces = []
        tone = []
        refs = []
        segments.times do |i|
          i2 = (i + 1) % segments
          sides.times do |j|
            j2 = (j + 1) % sides
            faces << [i * sides + j, i2 * sides + j, i2 * sides + j2, i * sides + j2]
            tone << i.fdiv(segments)
            refs << [@c[i * 3], @c[i * 3 + 1], @c[i * 3 + 2]]
          end
        end
        @mesh = Mesh.new(verts, faces, tone, refs)
      end

      # twist: radians the cross-section turns, plus a wave of extra turn along the knot.
      # swell: Array-free bulges: amp travelling along the curve at phase `at`, `lobes` of them.
      def deform(twist, wave, breath, amp, at, lobes = 3)
        segments = @segments
        phi = @phi
        tube = @tube
        i = 0
        while i < segments
          p = phi[i]
          @tw[i] = twist + wave * Math.sin(p * 2.0 + twist * 0.5)
          bump = Math.cos(p * lobes - at)
          bump = bump > 0.0 ? bump**10 : 0.0
          @rad[i] = tube * (1.0 + breath * Math.sin(p * 3.0 + at * 0.3) + amp * bump)
          i += 1
        end
        fill(@mesh.pos)
      end

      private

      def frame(t)
        c3 = Math.cos(3 * t)
        s3 = Math.sin(3 * t)
        c2 = Math.cos(2 * t)
        s2 = Math.sin(2 * t)
        r = 2.0 + c3
        @c.push(r * c2, r * s2, s3)
        # tangent: derivative of the curve
        tx = -3 * s3 * c2 - 2 * r * s2
        ty = -3 * s3 * s2 + 2 * r * c2
        tz = 3 * c3
        tl = Math.sqrt(tx * tx + ty * ty + tz * tz)
        tx /= tl
        ty /= tl
        tz /= tl
        dx = c3 * c2
        dy = c3 * s2
        dz = s3
        @d.push(dx, dy, dz)
        @b.push(ty * dz - tz * dy, tz * dx - tx * dz, tx * dy - ty * dx)
      end

      def fill(pos)
        sides = @sides
        cs = @cos
        sn = @sin
        o = 0
        @segments.times do |i|
          i3 = i * 3
          cx = @c[i3]
          cy = @c[i3 + 1]
          cz = @c[i3 + 2]
          dx = @d[i3]
          dy = @d[i3 + 1]
          dz = @d[i3 + 2]
          bx = @b[i3]
          by = @b[i3 + 1]
          bz = @b[i3 + 2]
          r = @rad[i]
          ca = Math.cos(@tw[i])
          sa = Math.sin(@tw[i])
          j = 0
          while j < sides
            c = (cs[j] * ca - sn[j] * sa) * r
            s = (sn[j] * ca + cs[j] * sa) * r
            pos[o] = cx + dx * c + bx * s
            pos[o + 1] = cy + dy * c + by * s
            pos[o + 2] = cz + dz * c + bz * s
            o += 3
            j += 1
          end
        end
      end
    end

    # A geodesic sphere: every icosahedron face cut into freq^2 triangles, pushed out to the
    # unit sphere. deform moves each vertex along its own direction by disp[v].
    class Geo
      attr_reader :mesh, :dirs, :count, :icosa

      PHI = (1 + Math.sqrt(5)) / 2

      def initialize(freq)
        base = [[-1, PHI, 0], [1, PHI, 0], [-1, -PHI, 0], [1, -PHI, 0], [0, -1, PHI], [0, 1, PHI],
                [0, -1, -PHI], [0, 1, -PHI], [PHI, 0, -1], [PHI, 0, 1], [-PHI, 0, -1], [-PHI, 0, 1]].map { |v| M3.normalize(v.map(&:to_f)) }
        tris = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6],
                [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
        index = {}
        verts = []
        faces = []
        at = lambda do |a, b, c, i, j|
          v = (0..2).map { |k| a[k] + (b[k] - a[k]) * i / freq + (c[k] - a[k]) * j / freq }
          v = M3.normalize(v)
          key = v.map { |x| (x * 1e5).round }
          index[key] ||= begin
            verts.concat(v)
            verts.size / 3 - 1
          end
        end
        tris.each do |ia, ib, ic|
          a = base[ia]
          b = base[ib]
          c = base[ic]
          (0..freq).each do |i|
            (0..(freq - i)).each do |j|
              next if i + j >= freq

              faces << [at.(a, b, c, i, j), at.(a, b, c, i + 1, j), at.(a, b, c, i, j + 1)]
              faces << [at.(a, b, c, i + 1, j), at.(a, b, c, i + 1, j + 1), at.(a, b, c, i, j + 1)] if i + j < freq - 1
            end
          end
        end
        @count = verts.size / 3
        @dirs = verts.dup.freeze
        @icosa = base.map { |v| index[v.map { |x| (x * 1e5).round }] }
        @mesh = Mesh.new(verts, faces, Array.new(faces.size, 0.0))
        @tone = @mesh.tone
        rnd = Random.new(31)
        @base = Array.new(faces.size) { rnd.rand }
      end

      # radius of vertex v = 1 + disp[v]; tones follow the mean push of each face.
      # sheen: drifts a glitter of tone over the facets while the sphere is at rest.
      def deform(disp, tone_k, sheen = 0.0)
        pos = @mesh.pos
        dirs = @dirs
        n = @count
        i = 0
        while i < n
          r = 1.0 + disp[i]
          j = i * 3
          pos[j] = dirs[j] * r
          pos[j + 1] = dirs[j + 1] * r
          pos[j + 2] = dirs[j + 2] * r
          i += 1
        end
        tone = @tone
        faces = @mesh.faces
        base = @base
        k = 0
        nf = faces.size
        while k < nf
          f = faces[k]
          g = (base[k] + sheen) % 1.0
          d = (disp[f[0]] + disp[f[1]] + disp[f[2]]) * tone_k + 0.08 + (g < 0.5 ? g : 1.0 - g) * 0.5
          tone[k] = d < 0.0 ? 0.0 : (d > 0.999 ? 0.999 : d)
          k += 1
        end
      end
    end

    module_function

    # A round brilliant: n-sided table, star and bezel facets, upper girdle facets, a girdle band,
    # lower girdle facets and pavilion mains down to the culet. 9n + 1 faces. Radius 1.
    # crown and pavilion stretch the top and bottom halves.
    def gem(n, seed: 7, crown: 1.0, pavilion: 1.0)
      rnd = Random.new(seed)
      verts = []
      add = lambda do |r, a, y|
        verts.push(r * Math.cos(a), y, r * Math.sin(a))
        verts.size / 3 - 1
      end
      step = TAU / n
      top = 0.36 * crown
      table = Array.new(n) { |k| add.(0.56, k * step, top) }
      star = Array.new(n) { |k| add.(0.82, (k + 0.5) * step, 0.21 * crown) }
      gt = Array.new(2 * n) { |j| add.(1.0, j * step / 2, 0.025) }
      gb = Array.new(2 * n) { |j| add.(1.0, j * step / 2, -0.025) }
      pav = Array.new(n) { |k| add.(0.42, k * step, -0.56 * pavilion) }
      culet = add.(0.0, 0.0, -0.98 * pavilion)
      faces = []
      tone = []
      put = ->(f, t) { faces << f; tone << (t + (rnd.rand - 0.5) * 0.2).clamp(0.0, 0.999) }
      put.(table.reverse, 0.9)
      n.times do |k|
        k1 = (k + 1) % n
        put.([table[k], table[k1], star[k]], 0.82)
        put.([table[k], star[(k - 1) % n], gt[2 * k], star[k]], k.even? ? 0.7 : 0.5)
        put.([star[k], gt[2 * k], gt[2 * k + 1]], 0.62)
        put.([star[k], gt[2 * k + 1], gt[(2 * k + 2) % (2 * n)]], 0.38)
      end
      (2 * n).times do |j|
        j1 = (j + 1) % (2 * n)
        put.([gt[j], gt[j1], gb[j1], gb[j]], 0.4)
      end
      n.times do |k|
        k1 = (k + 1) % n
        put.([gb[2 * k], gb[2 * k + 1], pav[k]], 0.48)
        put.([gb[2 * k + 1], gb[(2 * k + 2) % (2 * n)], pav[k1]], 0.3)
        put.([pav[k], gb[2 * k + 1], pav[k1], culet], k.even? ? 0.18 : 0.4)
      end
      Mesh.new(verts, faces, tone)
    end
  end
end
