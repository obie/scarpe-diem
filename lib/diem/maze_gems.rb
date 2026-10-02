# frozen_string_literal: true

require_relative "maze_shapes"

# The rubies of WOLFENSHOES 3D as real faceted solids: a cut stone (table, a crown of star and
# bezel facets, a girdle, a pavilion of three tiers) projected through the raycaster's camera
# every frame, back faces culled, each facet lit on its own by a key light, the low sun behind
# the hall and a specular highlight, with a dark rim behind it so stones in front of stones
# separate. Facets are antialiased polygons in a MazeShapes pool.
module Diem
  class MazeGems
    TAU = Math::PI * 2
    CROWN = 0
    GIRDLE = 1
    PAVILION = 2
    TABLE = 3

    # Local mesh in units of the girdle radius, z up, centre at 0. Returns
    # [verts (flat x, y, z), faces [[indices, kind, nx, ny, nz, cx, cy, cz, seed], ...]].
    def self.mesh(n, fancy)
      step = TAU / n
      v = []
      ring = lambda do |r, z, off|
        first = v.size / 3
        n.times do |i|
          a = (i + off) * step
          v.push(r * Math.cos(a), r * Math.sin(a), z)
        end
        first
      end
      zt = 0.92
      t0 = ring.call(0.56, zt, 0.5)
      g0 = ring.call(1.0, 0.3, 0.0)
      b0 = ring.call(1.0, 0.18, 0.0)
      m0 = fancy ? ring.call(0.55, -0.52, 0.5) : nil
      culet = v.size / 3
      v.push(0.0, 0.0, -1.25)
      faces = []
      n.times do |i|
        j = (i + 1) % n
        if fancy
          faces << [[g0 + i, g0 + j, t0 + i], CROWN]
          faces << [[t0 + i, t0 + j, g0 + j], CROWN]
          faces << [[b0 + i, b0 + j, m0 + i], PAVILION]
          faces << [[b0 + j, m0 + j, m0 + i], PAVILION]
          faces << [[m0 + i, m0 + j, culet], PAVILION]
        else
          faces << [[t0 + (i - 1) % n, t0 + i, g0 + i], CROWN]
          faces << [[t0 + i, g0 + j, g0 + i], CROWN]
          faces << [[b0 + i, b0 + j, culet], PAVILION]
        end
        faces << [[g0 + i, g0 + j, b0 + j, b0 + i], GIRDLE]
      end
      faces << [Array.new(n) { |i| t0 + i }, TABLE]
      faces.each_with_index.map do |(idx, kind), k|
        cx = cy = cz = 0.0
        idx.each do |q|
          cx += v[q * 3]
          cy += v[q * 3 + 1]
          cz += v[q * 3 + 2]
        end
        cx /= idx.size
        cy /= idx.size
        cz /= idx.size
        a = idx[0] * 3
        b = idx[1] * 3
        c = idx[2] * 3
        ux = v[b] - v[a]
        uy = v[b + 1] - v[a + 1]
        uz = v[b + 2] - v[a + 2]
        wx = v[c] - v[a]
        wy = v[c + 1] - v[a + 1]
        wz = v[c + 2] - v[a + 2]
        nx = uy * wz - uz * wy
        ny = uz * wx - ux * wz
        nz = ux * wy - uy * wx
        l = Math.sqrt(nx * nx + ny * ny + nz * nz)
        nx /= l
        ny /= l
        nz /= l
        if nx * cx + ny * cy + nz * (cz - 0.0) < 0.0
          nx = -nx
          ny = -ny
          nz = -nz
        end
        [idx, kind, nx, ny, nz, cx, cy, cz, (k * 0.618034) % 1.0]
      end.then { |fs| [v, fs] }
    end

    def initialize(scene, pool)
      @s = scene
      @pool = pool
      @meshes = { true => MazeGems.mesh(8, true), false => MazeGems.mesh(6, false) }
      most = @meshes.values.map { |v, _| v.size / 3 }.max
      @vx = Array.new(most, 0.0)
      @vy = Array.new(most, 0.0)
      @px_ = Array.new(64, 0.0)
      @py_ = Array.new(64, 0.0)
      @ox = Array.new(64, 0.0)
      @oy = Array.new(64, 0.0)
      @tx = Array.new(64, 0.0)
      @ty = Array.new(64, 0.0)
      @order = []
      key = Math::PI / 2 + Math::PI + 0.7
      @light = unit(Math.cos(key), Math.sin(key), 0.9)
      @sun = unit(0.0, 1.0, 0.3)
      @star_x = Array.new(16, 0.0)
      @star_y = Array.new(16, 0.0)
    end

    # cam: [px, py, camh, dx, dy, f, hor, tilt, half_w]. One gem at world (x, y, z) with
    # girdle radius r, turned by spin; runs: nil (all in view) or flat [xa, xb, ...] screen
    # bands it shows through. fog: [r, g, b], fogk 0..1. lead: the lead note's hit, 0..1.
    # Returns the strongest highlight as [x, y, strength] (nil when none).
    def draw(cam, x, y, z, r, spin, base, fancy, runs, fog, fogk, lead)
      verts, faces = @meshes[fancy]
      px, py, camh, dx, dy, f, hor, tilt, half_w = cam
      c = Math.cos(spin)
      s = Math.sin(spin)
      nv = verts.size / 3
      vx = @vx
      vy = @vy
      k = 0
      while k < nv
        lx = verts[k * 3]
        ly = verts[k * 3 + 1]
        wx = x + (lx * c - ly * s) * r - px
        wy = y + (lx * s + ly * c) * r - py
        depth = wx * dx + wy * dy
        return nil if depth < 0.2

        sx = half_w + (wy * dx - wx * dy) / depth * f
        vx[k] = sx
        vy[k] = hor + (sx - half_w) * tilt - (z + verts[k * 3 + 2] * r - camh) * f / depth
        k += 1
      end

      # the dark rim: the silhouette, a little larger, behind the facets
      m = MazeClip.hull(vx, vy, nv, @ox, @oy, @order)
      MazeClip.grow(@ox, @oy, m, 1.6 * @s.u)
      emit(@ox, @oy, m, [(fog[0] * 0.12 + 16).to_i, 2, (fog[2] * 0.12 + 12).to_i, 240], runs)

      lx, ly, lz = @light
      sx_, sy_, sz_ = @sun
      keep = 1.0 - fogk
      best = 0.0
      bx = by = 0.0
      faces.each do |idx, kind, nx0, ny0, nz, cx0, cy0, cz0, seed|
        nx = nx0 * c - ny0 * s
        ny = nx0 * s + ny0 * c
        ux = px - (x + (cx0 * c - cy0 * s) * r)
        uy = py - (y + (cx0 * s + cy0 * c) * r)
        uz = camh - (z + cz0 * r)
        ul = Math.sqrt(ux * ux + uy * uy + uz * uz)
        facing = (nx * ux + ny * uy + nz * uz) / ul
        next if facing <= 0.02

        ux /= ul
        uy /= ul
        uz /= ul
        diff = nx * lx + ny * ly + nz * lz
        diff = 0.0 if diff < 0.0
        hx = lx + ux
        hy = ly + uy
        hz = lz + uz
        hl = Math.sqrt(hx * hx + hy * hy + hz * hz)
        spec = (nx * hx + ny * hy + nz * hz) / hl
        spec = spec > 0.0 ? spec**22 : 0.0
        back = nx * sx_ + ny * sy_ + nz * sz_
        back = back > 0.0 ? back * back : 0.0
        tw = Math.cos(seed * 40.0 + spin * 2.0)
        fire = tw > 0.0 ? tw**10 * (0.25 + 0.9 * lead) : 0.0
        lit = case kind
              when CROWN then 0.2 + 0.6 * diff + 0.3 * facing**4
              when PAVILION then 0.1 + 0.28 * diff + 0.7 * facing**8
              when TABLE then 0.4 + 0.5 * diff
              else 0.3 + 0.4 * diff
              end
        lit *= 0.85 + 0.3 * seed
        hot = spec * 1.15 + fire
        cr = base[0] * lit + 255.0 * hot + 120.0 * back
        cg = base[1] * lit + 225.0 * hot + 40.0 * back
        cb = base[2] * lit + 235.0 * hot + 80.0 * back
        colour = [mix(cr, fog[0], keep, fogk), mix(cg, fog[1], keep, fogk), mix(cb, fog[2], keep, fogk), 255]
        n = idx.size
        j = 0
        while j < n
          q = idx[j]
          @px_[j] = vx[q]
          @py_[j] = vy[q]
          j += 1
        end
        emit(@px_, @py_, n, colour, runs)
        next unless hot > best

        best = hot
        bx = 0.0
        by = 0.0
        n.times do |jj|
          bx += @px_[jj]
          by += @py_[jj]
        end
        bx /= n
        by /= n
      end
      best > 0.25 ? [bx, by, best] : nil
    end

    # A four-pointed glint with short diagonals, centred on (x, y), radius rr.
    def star(x, y, rr, alpha)
      16.times do |k|
        a = k * TAU / 16
        rad = if k % 4 == 0 then rr
              elsif k % 2 == 0 then rr * 0.32
              else rr * 0.07
              end
        @star_x[k] = x + Math.cos(a) * rad
        @star_y[k] = y + Math.sin(a) * rad
      end
      @pool.poly(@star_x, @star_y, 16, [255, 252, 255, alpha.round.clamp(0, 255)])
    end

    private

    def mix(v, fogc, keep, fogk)
      out = v * keep + fogc * fogk
      out < 0 ? 0 : (out > 255 ? 255 : out.to_i)
    end

    def emit(xs, ys, n, fill, runs)
      if runs.nil?
        @pool.poly(xs, ys, n, fill)
        return
      end
      k = 0
      while k < runs.size
        m = MazeClip.x_band(xs, ys, n, runs[k], runs[k + 1], @ox2 ||= Array.new(64, 0.0), @oy2 ||= Array.new(64, 0.0), @tx, @ty)
        @pool.poly(@ox2, @oy2, m, fill)
        k += 2
      end
    end

    def unit(x, y, z)
      l = Math.sqrt(x * x + y * y + z * z)
      [x / l, y / l, z / l]
    end
  end
end
