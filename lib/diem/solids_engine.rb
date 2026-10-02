# frozen_string_literal: true

# A small flat-shaded 3D engine for the Solids scene. Meshes are flat Float arrays of object-space
# vertices plus faces as Arrays of vertex indices. Each frame a Renderer transforms, culls, lights
# and depth-sorts the faces of every mesh drawn into it, then writes the k-th farthest face into
# the k-th shape of a fixed pool, so nothing is ever created, removed or reordered.
#
# Space: right-handed, y up. The camera sits at the origin of view space looking down -z.
module Diem
  module Solids
    TAU = Math::PI * 2

    # 3x3 matrices as flat row-major Arrays of 9 Floats.
    module M3
      module_function

      # Ry(yaw) * Rx(pitch) * Rz(roll).
      def rot(yaw, pitch, roll = 0.0)
        cy = Math.cos(yaw)
        sy = Math.sin(yaw)
        cp = Math.cos(pitch)
        sp = Math.sin(pitch)
        cr = Math.cos(roll)
        sr = Math.sin(roll)
        mul([cy, 0.0, sy, 0.0, 1.0, 0.0, -sy, 0.0, cy],
          mul([1.0, 0.0, 0.0, 0.0, cp, -sp, 0.0, sp, cp], [cr, -sr, 0.0, sr, cr, 0.0, 0.0, 0.0, 1.0]))
      end

      # Spin about the object's own vertical, then lean the spinning thing towards the viewer.
      def turn(yaw, lean, roll = 0.0)
        mul(rot(0.0, lean, roll), rot(yaw, 0.0))
      end

      def mul(a, b)
        [
          a[0] * b[0] + a[1] * b[3] + a[2] * b[6], a[0] * b[1] + a[1] * b[4] + a[2] * b[7], a[0] * b[2] + a[1] * b[5] + a[2] * b[8],
          a[3] * b[0] + a[4] * b[3] + a[5] * b[6], a[3] * b[1] + a[4] * b[4] + a[5] * b[7], a[3] * b[2] + a[4] * b[5] + a[5] * b[8],
          a[6] * b[0] + a[7] * b[3] + a[8] * b[6], a[6] * b[1] + a[7] * b[4] + a[8] * b[7], a[6] * b[2] + a[7] * b[5] + a[8] * b[8],
        ]
      end

      def scale(m, s) = m.map { |v| v * s }

      def apply(m, x, y, z)
        [m[0] * x + m[1] * y + m[2] * z, m[3] * x + m[4] * y + m[5] * z, m[6] * x + m[7] * y + m[8] * z]
      end

      def normalize(v)
        l = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
        l = 1.0 if l < 1e-12
        [v[0] / l, v[1] / l, v[2] / l]
      end
    end

    # Object-space geometry. pos is the current shape (deforming meshes rewrite it in place);
    # rest is the shape it was built in. tone is a 0..1 Float per face, the place on a colour ramp.
    class Mesh
      attr_reader :faces, :tone, :rest, :refs
      attr_accessor :pos

      def initialize(verts, faces, tone, refs = nil, orient: true)
        @rest = verts.map(&:to_f).freeze
        @pos = @rest.dup
        @faces = faces
        @tone = tone
        @refs = refs
        orient! if orient
        @faces.each(&:freeze)
        @faces.freeze
      end

      def vertex_count = @rest.size / 3
      def face_count = @faces.size

      # Centroid and unit normal of every face of the rest shape, as flat Arrays.
      def face_frames(pos = @rest)
        cen = []
        nor = []
        @faces.each do |f|
          c = centroid(pos, f)
          n = M3.normalize(newell(pos, f))
          cen.concat(c)
          nor.concat(n)
        end
        [cen, nor]
      end

      private

      # Every face wound counter-clockwise seen from outside: its normal must point away from
      # its reference point (the origin, or a tube centre for a knot).
      def orient!
        @faces = @faces.each_with_index.map do |f, i|
          c = centroid(@rest, f)
          n = newell(@rest, f)
          rx, ry, rz = @refs ? @refs[i] : [0.0, 0.0, 0.0]
          d = n[0] * (c[0] - rx) + n[1] * (c[1] - ry) + n[2] * (c[2] - rz)
          d.negative? ? f.reverse : f
        end
      end

      def centroid(pos, f)
        x = y = z = 0.0
        f.each do |v|
          x += pos[v * 3]
          y += pos[v * 3 + 1]
          z += pos[v * 3 + 2]
        end
        k = f.size.to_f
        [x / k, y / k, z / k]
      end

      def newell(pos, f)
        nx = ny = nz = 0.0
        m = f.size
        m.times do |i|
          a = f[i] * 3
          b = f[(i + 1) % m] * 3
          nx += (pos[a + 1] - pos[b + 1]) * (pos[a + 2] + pos[b + 2])
          ny += (pos[a + 2] - pos[b + 2]) * (pos[a] + pos[b])
          nz += (pos[a] - pos[b]) * (pos[a + 1] + pos[b + 1])
        end
        [nx, ny, nz]
      end
    end

    # Every face of a mesh as its own loose polygon, so it can fly off along its normal, tumble
    # and fade (out), or arrive from far away and lock into place (in). Pure function of s.
    class Shards
      attr_reader :mesh, :alpha, :cen

      # delay: optional Array of 0..1 per face (when each face moves), in place of random.
      def initialize(source, pos = source.rest, seed: 1, spread: 1.0, delay: nil)
        rnd = Random.new(seed)
        verts = []
        faces = []
        @cen, @nor = source.face_frames(pos)
        @axis = []
        @spin = []
        @delay = []
        @speed = []
        @local = []
        source.faces.each_with_index do |f, i|
          cx, cy, cz = @cen[i * 3], @cen[i * 3 + 1], @cen[i * 3 + 2]
          face = []
          f.each do |v|
            face << verts.size / 3
            @local.push(pos[v * 3] - cx, pos[v * 3 + 1] - cy, pos[v * 3 + 2] - cz)
            verts.push(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2])
          end
          faces << face
          @axis.concat(M3.normalize([rnd.rand - 0.5, rnd.rand - 0.5, rnd.rand - 0.5]))
          @spin << (2.0 + rnd.rand * 5.0) * (rnd.rand < 0.5 ? -1 : 1)
          r = rnd.rand
          @delay << (delay ? delay[i] : r)
          @speed << (0.6 + rnd.rand * 0.9) * spread
        end
        @mesh = Mesh.new(verts, faces, source.tone, orient: false)
        @alpha = Array.new(faces.size, 1.0)
        @reach = faces.map { |face| face.map { |v| Math.sqrt(@local[v * 3]**2 + @local[v * 3 + 1]**2 + @local[v * 3 + 2]**2) }.max }
      end

      # s: seconds since the shatter began. Faces leave over `dur` after a staggered delay.
      def out(s, dur: 0.9, stagger: 0.25, dist: 4.0)
        place(s, dur, stagger, dist, true)
      end

      # s: seconds since assembly began; every face is home by stagger + dur.
      def in(s, dur: 0.7, stagger: 0.35, dist: 6.0)
        place(s, dur, stagger, dist, false)
      end

      # An exploded view: every face pushed out by about d (a little less for the slow ones) and
      # turned about its own axis by turn * its spin. Every face opaque. The push leans upwards,
      # and with ground: [m, ty, floor] (m: the object's world matrix, ty: its world height) a
      # facet that would pass below the floor bounces back up off it.
      def burst(d, turn, ground = nil)
        nor = (@lifted ||= lifted_normals)
        n = @mesh.faces.size
        alpha = @alpha
        vi = 0
        fi = 0
        while fi < n
          vi = put(fi, vi, d * (0.4 + 0.4 * @speed[fi]), turn * @spin[fi], 1.0, ground, nor)
          alpha[fi] = 1.0
          fi += 1
        end
      end

      private

      def lifted_normals
        out = []
        (@nor.size / 3).times do |i|
          out.concat(M3.normalize([@nor[i * 3], @nor[i * 3 + 1] + 0.7, @nor[i * 3 + 2]]))
        end
        out
      end

      def place(s, dur, stagger, dist, leaving)
        alpha = @alpha
        n = @mesh.faces.size
        vi = 0
        fi = 0
        while fi < n
          e = (s - @delay[fi] * stagger) / dur
          e = e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e)
          if leaving
            push = (e * 0.8 + e * e * 1.4) * dist * @speed[fi]
            shrink = 1.0 - 0.55 * e
            ang = e * @spin[fi]
            alpha[fi] = 1.0 - e * e
          else
            k = 1.0 - e
            k3 = k * k * k
            push = k3 * dist * @speed[fi]
            shrink = 1.0 - 0.7 * k3
            ang = k3 * @spin[fi]
            alpha[fi] = e < 0.6 ? e / 0.6 : 1.0
          end
          vi = put(fi, vi, push, ang, shrink)
          fi += 1
        end
      end

      # Face fi, whose first corner is vertex vi: moved along its normal by push, turned by ang
      # about its axis and scaled about its centroid. Returns the next face's first vertex.
      def put(fi, vi, push, ang, shrink, ground = nil, nor = @nor)
        pos = @mesh.pos
        loc = @local
        f3 = fi * 3
        ox = @cen[f3] + nor[f3] * push
        oy = @cen[f3 + 1] + nor[f3 + 1] * push
        oz = @cen[f3 + 2] + nor[f3 + 2] * push
        if ground
          m, ty, floor = ground
          ss = m[3] * m[3] + m[4] * m[4] + m[5] * m[5]
          # the centroid keeps most of the facet's reach above the floor (or stays as high as
          # it was at rest, for the low facets)
          lim = floor + @reach[fi] * 0.6 * Math.sqrt(ss)
          rest = m[3] * @cen[f3] + m[4] * @cen[f3 + 1] + m[5] * @cen[f3 + 2] + ty
          lim = rest if rest < lim
          below = lim - (m[3] * ox + m[4] * oy + m[5] * oz + ty)
          if below > 0.0
            # back up through the floor and a third of the way again: a bounce off the neon
            k = below * 1.35 / ss
            ox += m[3] * k
            oy += m[4] * k
            oz += m[5] * k
          end
        end
        ax = @axis[f3]
        ay = @axis[f3 + 1]
        az = @axis[f3 + 2]
        ca = Math.cos(ang)
        sa = Math.sin(ang)
        oc = 1.0 - ca
        m = @mesh.faces[fi].size
        j = 0
        while j < m
          l = vi * 3
          x = loc[l]
          y = loc[l + 1]
          z = loc[l + 2]
          d = (ax * x + ay * y + az * z) * oc
          pos[l] = ox + (x * ca + (ay * z - az * y) * sa + ax * d) * shrink
          pos[l + 1] = oy + (y * ca + (az * x - ax * z) * sa + ay * d) * shrink
          pos[l + 2] = oz + (z * ca + (ax * y - ay * x) * sa + az * d) * shrink
          vi += 1
          j += 1
        end
        vi
      end
    end

    # How a mesh takes light. Colours are [r, g, b] Floats 0..255; ramp is an Array of them.
    class Shade
      attr_accessor :ramp, :amb, :key, :key_col, :spec_pow, :spec, :spec_col, :rim_col, :rim_pow,
        :fill_dir, :fill_col, :fog, :fog_col, :env_up, :env_down, :env, :alpha, :gradient, :tone_shift

      def initialize(**opts)
        @amb = 0.18
        @key = M3.normalize([-0.5, 0.7, 0.6])
        @key_col = [1.0, 1.0, 1.0]
        @spec_pow = 40.0
        @spec = 1.0
        @spec_col = [255.0, 255.0, 255.0]
        @rim_col = [0.0, 0.0, 0.0]
        @rim_pow = 3.0
        @fill_dir = M3.normalize([0.6, -0.2, 0.4])
        @fill_col = [0.0, 0.0, 0.0]
        @fog = 0.0
        @fog_col = Palette::NIGHT.map(&:to_f)
        @env = 0.0
        @env_up = [0.0, 0.0, 0.0]
        @env_down = [0.0, 0.0, 0.0]
        @alpha = 1.0
        @gradient = false
        @tone_shift = 0.0
        opts.each { |k, v| public_send("#{k}=", v) }
      end
    end

    # Collects lit, culled faces from any number of draw calls, then sorts them far to near and
    # writes them into a pool of shapes. One Renderer per pool (the mirror pool, the main pool).
    class Renderer
      MAXP = 24 # points per polygon
      IDX = 4095

      attr_reader :count, :it_spec, :it_tag, :it_cx, :it_cy, :it_depth
      attr_accessor :f, :cx, :cy, :wire_alpha, :wire_col, :bounds
      # dry: do all the work but post nothing (for warming YJIT up at build time)
      attr_accessor :dry
      # grow: px every opaque polygon is pushed out on screen, so the antialiased edges of
      # neighbouring faces overlap instead of letting the background show through as a seam
      attr_accessor :grow

      def initialize(pool_ids, f:, cx:, cy:)
        @ids = pool_ids
        @cap = pool_ids.size
        @f = f
        @cx = cx
        @cy = cy
        @vx = []
        @vy = []
        @vz = []
        @sx = []
        @sy = []
        @it_m = Array.new(@cap, 0)
        @it_xy = Array.new(@cap * MAXP * 2, 0.0)
        @it_col = Array.new(@cap * 8, 0)
        @it_grad = Array.new(@cap, false)
        @it_spec = Array.new(@cap, 0.0)
        @it_tag = Array.new(@cap, 0)
        @it_cx = Array.new(@cap, 0.0)
        @it_cy = Array.new(@cap, 0.0)
        @it_depth = Array.new(@cap, 0.0)
        @keys = []
        @count = 0
        @shown = 0
        @stroked = Array.new(@cap, false)
        @cmds = Array.new(@cap) { {} }
        @fills = Array.new(@cap) { [0, 0, 0, 0] }
        @grads = Array.new(@cap) { { gradient: [[0, 0, 0, 0], [0, 0, 0, 0]], angle: 0 } }
        @props = Array.new(@cap) { {} }
        @wire_alpha = 0.0
        @wire_col = [120, 255, 255]
        @flat = { shape_commands: [] }.freeze
        @bounds = [cx * 2.0, cy * 2.0]
        @grow = 0.0
        @gnx = Array.new(MAXP, 0.0)
        @gny = Array.new(MAXP, 0.0)
        camera([0.0, 0.0, 8.0], 0.0)
      end

      # Eye position (world) and pitch (radians, positive looks down).
      def camera(eye, pitch)
        @eye = eye
        c = Math.cos(pitch)
        s = Math.sin(pitch)
        @vr = [1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c]
      end

      attr_reader :vr, :eye

      # World point to screen [x, y, depth]; nil behind the camera.
      def project(x, y, z)
        vx, vy, vz = view_point(x, y, z)
        return nil if vz > -0.05

        iz = @f / -vz
        [@cx + vx * iz, @cy - vy * iz, -vz]
      end

      def view_point(x, y, z)
        M3.apply(@vr, x - @eye[0], y - @eye[1], z - @eye[2])
      end

      # Forget what the pool shows (after a dry run, when nothing was posted).
      def forget
        @shown = 0
        @stroked.fill(false)
      end

      def begin_frame
        @count = 0
        @keys.clear
      end

      # Draws a mesh: world = rot * pos + at. mirror_y reflects it in the plane y = mirror_y.
      # alpha: per-face Array (or nil). tag marks the items for later queries (glints).
      # back: 0 culls back faces; above 0 draws them lit from behind and darkened by that factor.
      # min_area: faces smaller than this on screen (px^2) are dropped. fade: per world unit
      # below the mirror plane, the share of alpha a mirrored face loses.
      def draw(mesh, rot, at, shade, alpha: nil, mirror_y: nil, tag: 0, back: 0.0, min_area: 0.0, fade: 0.0)
        @back = back
        @min_area = min_area * 2.0
        @fade = mirror_y ? fade : 0.0
        @plane = mirror_y || 0.0
        w = rot
        tx, ty, tz = at
        if mirror_y
          w = [rot[0], rot[1], rot[2], -rot[3], -rot[4], -rot[5], rot[6], rot[7], rot[8]]
          ty = 2.0 * mirror_y - ty
        end
        m = M3.mul(@vr, w)
        t = M3.apply(@vr, tx - @eye[0], ty - @eye[1], tz - @eye[2])
        transform(mesh.pos, m, t)
        kx, ky, kz = light(shade.key, mirror_y)
        fx, fy, fz = light(shade.fill_dir, mirror_y)
        upx, upy, upz = M3.apply(@vr, 0.0, mirror_y ? -1.0 : 1.0, 0.0)
        faces(mesh, shade, alpha, !mirror_y.nil?, tag, kx, ky, kz, fx, fy, fz, upx, upy, upz)
      end

      # Sorts far to near and writes into the pool. Unused slots get empty paths.
      def flush
        @keys.sort!
        wire = @wire_alpha > 0.01
        wcol = wire ? [@wire_col[0], @wire_col[1], @wire_col[2], (@wire_alpha * 255).round.clamp(0, 255)] : nil
        k = 0
        n = @keys.size
        while k < n
          write(k, @keys[k] & IDX, wcol)
          k += 1
        end
        while k < @shown
          Wire.set_id(@ids[k], @flat) unless @dry
          @stroked[k] = false
          k += 1
        end
        @shown = n
      end

      private

      def light(dir, mirror)
        M3.normalize(M3.apply(@vr, dir[0], mirror ? -dir[1] : dir[1], dir[2]))
      end

      def transform(pos, m, t)
        vx = @vx
        vy = @vy
        vz = @vz
        sx = @sx
        sy = @sy
        f = @f
        cx = @cx
        cy = @cy
        m0, m1, m2, m3, m4, m5, m6, m7, m8 = m
        t0, t1, t2 = t
        n = pos.size / 3
        i = 0
        while i < n
          j = i * 3
          x = pos[j]
          y = pos[j + 1]
          z = pos[j + 2]
          a = m0 * x + m1 * y + m2 * z + t0
          b = m3 * x + m4 * y + m5 * z + t1
          c = m6 * x + m7 * y + m8 * z + t2
          vx[i] = a
          vy[i] = b
          vz[i] = c
          iz = c < -0.05 ? f / -c : f / 0.05
          sx[i] = cx + a * iz
          sy[i] = cy - b * iz
          i += 1
        end
      end

      def faces(mesh, sh, alpha, flip, tag, kx, ky, kz, fx, fy, fz, upx, upy, upz)
        vx = @vx
        vy = @vy
        vz = @vz
        sx = @sx
        sy = @sy
        ramp = sh.ramp
        rn = ramp.size
        tones = mesh.tone
        shift = sh.tone_shift
        amb = sh.amb
        kcr, kcg, kcb = sh.key_col
        fcr, fcg, fcb = sh.fill_col
        spow = sh.spec_pow
        sk = sh.spec
        scr, scg, scb = sh.spec_col
        rcr, rcg, rcb = sh.rim_col
        rpow = sh.rim_pow
        fog = sh.fog
        fogr, fogg, fogb = sh.fog_col
        env = sh.env
        eur, eug, eub = sh.env_up
        edr, edg, edb = sh.env_down
        base_alpha = sh.alpha
        grad = sh.gradient
        back = @back
        min_area = @min_area
        fade = @fade
        plane = @plane
        vr1 = @vr[1]
        vr4 = @vr[4]
        vr7 = @vr[7]
        eye_y = @eye[1]
        cap = @cap
        list = mesh.faces
        nf = list.size
        fi = 0
        while fi < nf
          if @count >= cap
            fi = nf
            next
          end
          fa = alpha ? alpha[fi] * base_alpha : base_alpha
          if fa < 0.02
            fi += 1
            next
          end
          face = list[fi]
          m = face.size
          a = face[0]
          b = face[1]
          c = face[2]
          if m == 3
            ux = vx[b] - vx[a]
            uy = vy[b] - vy[a]
            uz = vz[b] - vz[a]
            wx = vx[c] - vx[a]
            wy = vy[c] - vy[a]
            wz = vz[c] - vz[a]
            px = (vx[a] + vx[b] + vx[c]) / 3.0
            py = (vy[a] + vy[b] + vy[c]) / 3.0
            pz = (vz[a] + vz[b] + vz[c]) / 3.0
          elsif m == 4
            d = face[3]
            ux = vx[c] - vx[a]
            uy = vy[c] - vy[a]
            uz = vz[c] - vz[a]
            wx = vx[d] - vx[b]
            wy = vy[d] - vy[b]
            wz = vz[d] - vz[b]
            px = (vx[a] + vx[b] + vx[c] + vx[d]) * 0.25
            py = (vy[a] + vy[b] + vy[c] + vy[d]) * 0.25
            pz = (vz[a] + vz[b] + vz[c] + vz[d]) * 0.25
          else
            q = face[m / 3]
            r = face[(2 * m) / 3]
            ux = vx[q] - vx[a]
            uy = vy[q] - vy[a]
            uz = vz[q] - vz[a]
            wx = vx[r] - vx[a]
            wy = vy[r] - vy[a]
            wz = vz[r] - vz[a]
            px = py = pz = 0.0
            j = 0
            while j < m
              v = face[j]
              px += vx[v]
              py += vy[v]
              pz += vz[v]
              j += 1
            end
            px /= m
            py /= m
            pz /= m
          end
          nx = uy * wz - uz * wy
          ny = uz * wx - ux * wz
          nz = ux * wy - uy * wx
          if flip
            nx = -nx
            ny = -ny
            nz = -nz
          end
          dim = 1.0
          if pz > -0.1
            fi += 1
            next
          end
          if nx * px + ny * py + nz * pz >= 0.0
            if back <= 0.0
              fi += 1
              next
            end
            nx = -nx
            ny = -ny
            nz = -nz
            dim = back
          end
          j = 0
          off = 15
          bw = @bounds[0]
          bh = @bounds[1]
          area = 0.0
          while j < m
            v = face[j]
            x = sx[v]
            y = sy[v]
            off &= (x < 0.0 ? 1 : 0) | (x > bw ? 2 : 0) | (y < 0.0 ? 4 : 0) | (y > bh ? 8 : 0)
            if min_area > 0.0
              u = face[(j + 1) % m]
              area += x * sy[u] - sx[u] * y
            end
            j += 1
          end
          # every corner beyond the same edge: off screen
          if !off.zero? || (min_area > 0.0 && area.abs < min_area)
            fi += 1
            next
          end
          if fade > 0.0
            below = plane - (vr1 * px + vr4 * py + vr7 * pz + eye_y)
            fa *= 1.0 - below * fade if below > 0.0
            if fa < 0.02
              fi += 1
              next
            end
          end
          nl = Math.sqrt(nx * nx + ny * ny + nz * nz)
          if nl < 1e-12
            fi += 1
            next
          end
          nx /= nl
          ny /= nl
          nz /= nl
          dist = Math.sqrt(px * px + py * py + pz * pz)
          ex = -px / dist
          ey = -py / dist
          ez = -pz / dist
          ndv = nx * ex + ny * ey + nz * ez
          ndv = 0.0 if ndv < 0.0
          lam = nx * kx + ny * ky + nz * kz
          lam = 0.0 if lam < 0.0
          fl = nx * fx + ny * fy + nz * fz
          fl = 0.0 if fl < 0.0
          hx = kx + ex
          hy = ky + ey
          hz = kz + ez
          hl = Math.sqrt(hx * hx + hy * hy + hz * hz)
          nh = (nx * hx + ny * hy + nz * hz) / hl
          sp = nh > 0.0 ? (nh**spow) * sk : 0.0
          rim = (1.0 - ndv)**rpow
          ti = ((tones[fi] + shift) % 1.0 * rn).to_i
          ti = rn - 1 if ti >= rn
          base = ramp[ti]
          lr = amb + lam * kcr + fl * fcr
          lg = amb + lam * kcg + fl * fcg
          lb = amb + lam * kcb + fl * fcb
          cr = base[0] * lr + sp * scr + rim * rcr
          cg = base[1] * lg + sp * scg + rim * rcg
          cb = base[2] * lb + sp * scb + rim * rcb
          if dim < 1.0
            cr *= dim
            cg *= dim
            cb *= dim
          end
          if env > 0.0
            # mirror direction's height picks sky or floor
            rdy = 2.0 * ndv * (nx * upx + ny * upy + nz * upz) - (ex * upx + ey * upy + ez * upz)
            if rdy > 0.0
              cr += eur * rdy * env
              cg += eug * rdy * env
              cb += eub * rdy * env
            else
              cr -= edr * rdy * env
              cg -= edg * rdy * env
              cb -= edb * rdy * env
            end
          end
          if fog > 0.0
            fk = (dist - 6.0) * fog
            fk = fk < 0.0 ? 0.0 : (fk > 0.85 ? 0.85 : fk)
            cr += (fogr - cr) * fk
            cg += (fogg - cg) * fk
            cb += (fogb - cb) * fk
          end
          k = @count
          o = k * MAXP * 2
          xy = @it_xy
          j = 0
          top = 0
          bot = 0
          while j < m
            v = face[j]
            xy[o] = sx[v]
            xy[o + 1] = sy[v]
            top = j if sy[v] < sy[face[top]]
            bot = j if sy[v] > sy[face[bot]]
            o += 2
            j += 1
          end
          col = @it_col
          al = (fa * 255).round
          al = 255 if al > 255
          grow!(k * MAXP * 2, m, @grow) if al == 255 && @grow > 0.0
          o = k * 8
          col[o] = clamp8(cr)
          col[o + 1] = clamp8(cg)
          col[o + 2] = clamp8(cb)
          col[o + 3] = al
          if grad
            # the same facet seen from its top and bottom corners: a glint slides across it
            g1 = glint(face[top], nx, ny, nz, kx, ky, kz, spow, sk)
            g2 = glint(face[bot], nx, ny, nz, kx, ky, kz, spow, sk)
            col[o] = clamp8(cr + (g1 - sp) * scr)
            col[o + 1] = clamp8(cg + (g1 - sp) * scg)
            col[o + 2] = clamp8(cb + (g1 - sp) * scb)
            col[o + 4] = clamp8(cr * 0.55 + (g2 - sp) * scr)
            col[o + 5] = clamp8(cg * 0.55 + (g2 - sp) * scg)
            col[o + 6] = clamp8(cb * 0.55 + (g2 - sp) * scb)
            col[o + 7] = al
            sp = g1 if g1 > sp
          end
          @it_grad[k] = grad
          @it_m[k] = m
          @it_spec[k] = sp
          @it_tag[k] = tag
          @it_cx[k] = @cx + px * (@f / -pz)
          @it_cy[k] = @cy - py * (@f / -pz)
          @it_depth[k] = dist
          @keys << ((-dist * 2000.0).to_i << 12) + k
          @count += 1
          fi += 1
        end
      end

      # Pushes each edge of the screen polygon at xy[o..] out by g px (mitred corners, the
      # miter capped at 2g), whichever way it is wound.
      def grow!(o, m, g)
        xy = @it_xy
        area = 0.0
        j = 0
        while j < m
          a = o + j * 2
          b = o + (j + 1 == m ? 0 : (j + 1) * 2)
          area += xy[a] * xy[b + 1] - xy[b] * xy[a + 1]
          j += 1
        end
        return if area.abs < 1.0

        sg = area.positive? ? 1.0 : -1.0
        gnx = @gnx
        gny = @gny
        j = 0
        while j < m
          a = o + j * 2
          b = o + (j + 1 == m ? 0 : (j + 1) * 2)
          dx = xy[b] - xy[a]
          dy = xy[b + 1] - xy[a + 1]
          l = Math.sqrt(dx * dx + dy * dy)
          if l < 1e-6
            gnx[j] = 0.0
            gny[j] = 0.0
          else
            gnx[j] = dy * sg / l
            gny[j] = -dx * sg / l
          end
          j += 1
        end
        j = 0
        while j < m
          i = j.zero? ? m - 1 : j - 1
          ax = gnx[i]
          ay = gny[i]
          bx = gnx[j]
          by = gny[j]
          d = 1.0 + ax * bx + ay * by
          d = 0.5 if d < 0.5
          k = g / d
          a = o + j * 2
          xy[a] += (ax + bx) * k
          xy[a + 1] += (ay + by) * k
          j += 1
        end
      end

      def glint(v, nx, ny, nz, kx, ky, kz, spow, sk)
        x = @vx[v]
        y = @vy[v]
        z = @vz[v]
        l = Math.sqrt(x * x + y * y + z * z)
        hx = kx - x / l
        hy = ky - y / l
        hz = kz - z / l
        hl = Math.sqrt(hx * hx + hy * hy + hz * hz)
        nh = (nx * hx + ny * hy + nz * hz) / hl
        nh > 0.0 ? (nh**spow) * sk : 0.0
      end

      def clamp8(v)
        v = v.round
        v.negative? ? 0 : (v > 255 ? 255 : v)
      end

      def write(k, i, wcol)
        m = @it_m[i]
        cache = @cmds[k]
        closed = !wcol.nil?
        key = closed ? m + 100 : m
        cmds = cache[key] ||= Array.new(closed ? m + 1 : m) { |j| [j.zero? ? "move_to" : "line_to", 0.0, 0.0] }
        xy = @it_xy
        o = i * MAXP * 2
        j = 0
        while j < m
          c = cmds[j]
          c[1] = xy[o].round(1)
          c[2] = xy[o + 1].round(1)
          o += 2
          j += 1
        end
        if closed
          c = cmds[m]
          c[1] = cmds[0][1]
          c[2] = cmds[0][2]
        end
        col = @it_col
        o = i * 8
        props = @props[k]
        props.clear
        props[:shape_commands] = cmds
        if @it_grad[i]
          g = @grads[k]
          a = g[:gradient][0]
          b = g[:gradient][1]
          a[0] = col[o]
          a[1] = col[o + 1]
          a[2] = col[o + 2]
          a[3] = col[o + 3]
          b[0] = col[o + 4]
          b[1] = col[o + 5]
          b[2] = col[o + 6]
          b[3] = col[o + 7]
          props[:fill] = g
        else
          fill = @fills[k]
          fill[0] = col[o]
          fill[1] = col[o + 1]
          fill[2] = col[o + 2]
          fill[3] = col[o + 3]
          props[:fill] = fill
        end
        if wcol
          props[:stroke] = wcol
          props[:strokewidth] = 1
          @stroked[k] = true
        elsif @stroked[k]
          props[:strokewidth] = 0
          @stroked[k] = false
        end
        Wire.set_id(@ids[k], props) unless @dry
      end
    end
  end
end
