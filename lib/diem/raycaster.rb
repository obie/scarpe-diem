# frozen_string_literal: true

# A grid raycaster in the Wolfenstein 3D tradition (Lode Vandevenne's DDA), with two additions:
# walls whose kind is listed in `round` are columns of that radius standing in the middle of
# their cell, and floor cells know whether they have a roof, so a ray reports where the sky
# shows. Kinds listed in `doors` are Wolfenstein sliding doors: a panel across the middle of
# the cell that slides sideways into the wall as `open_door` raises its share from 0 to 1. It knows nothing about drawing: cast fills flat per-column Arrays that a scene (or a
# walk-around mode) turns into strips.
#
#   rc = Raycaster.new(rows, legend: { "#" => 1, "O" => 4 }, open: [","], round: { 4 => 0.32 })
#   rc.cast(x, y, dir_x, dir_y, plane_x, plane_y, 320)
#   rc.dist[i], rc.kind[i], rc.tex[i] ...
#
# Distances are perpendicular to the camera plane (no fisheye), because the ray direction is
# dir + plane * camera_x with |dir| = 1 and plane at right angles to it.
module Diem
  class Raycaster
    MAX_STEPS = 220
    NO_ROOF = -1.0
    RUNNING = -2.0 # the camera's own roof has not ended yet

    attr_reader :cols, :rows, :cells, :roofs, :max_dist
    # Per column, after cast: perpendicular distance, wall kind, side (0 = x face, 1 = y face,
    # 2 = round), texture u in 0...1, world hit point, face normal, map cell index, where the
    # camera's own roof ends (NO_ROOF if it stands in the open), where the roof over the wall
    # begins (NO_ROOF if the wall stands in the open).
    attr_reader :dist, :kind, :side, :tex, :hit_x, :hit_y, :norm_x, :norm_y, :cell, :roof_a, :roof_b

    # rows: Strings, one character per cell. legend: character => wall kind (Integer > 0);
    # characters not in it are floor. open: floor characters with no roof above them (round
    # walls count as open floor around their column). round: wall kind => column radius.
    def initialize(rows, legend:, open: [], round: {}, doors: [], max_dist: 64.0)
      @rows = rows.size
      @cols = rows.map(&:size).max
      @cells = Array.new(@rows * @cols, 0)
      @roofs = Array.new(@rows * @cols, true)
      @round = Array.new((legend.values.max || 0) + 1, 0.0)
      round.each { |k, r| @round[k] = r.to_f }
      @door = Array.new(@round.size, false)
      doors.each { |k| @door[k] = true }
      @open = Array.new(@rows * @cols, 0.0)
      rows.each_with_index do |line, y|
        @cols.times do |x|
          ch = line[x] || " "
          i = y * @cols + x
          @cells[i] = legend.fetch(ch, 0)
          @roofs[i] = !(open.include?(ch) || @round[@cells[i]] > 0.0)
        end
      end
      # a door panel runs along x when its cell has walls east and west of it
      @door_along_x = Array.new(@rows * @cols) { |i| (@cells[i - 1] || 0) != 0 && (@cells[i + 1] || 0) != 0 }
      @max_dist = max_dist
      @n = 0
      %i[@dist @kind @side @tex @hit_x @hit_y @norm_x @norm_y @cell @roof_a @roof_b].each { |v| instance_variable_set(v, []) }
    end

    def index(x, y) = y.floor * @cols + x.floor

    def inside?(x, y) = x >= 0 && y >= 0 && x < @cols && y < @rows

    # The wall kind at a world point (0 for floor), with the round columns' real shape.
    def solid_at(x, y)
      return 1 unless inside?(x, y)

      k = @cells[index(x, y)]
      r = @round[k]
      return k if k.zero? || r.zero?

      dx = x - (x.floor + 0.5)
      dy = y - (y.floor + 0.5)
      dx * dx + dy * dy < r * r ? k : 0
    end

    def roofed_at?(x, y) = inside?(x, y) && @roofs[index(x, y)]

    # How far the door in cell (x, y) has slid open, 0.0 (shut) to 1.0 (gone).
    def open_door(x, y, share)
      @open[index(x, y)] = share.clamp(0.0, 1.0)
    end

    # Casts n rays across the view and fills the per-column Arrays.
    def cast(px, py, dir_x, dir_y, plane_x, plane_y, n)
      grow(n) if n > @n
      i = 0
      while i < n
        cam = 2.0 * (i + 0.5) / n - 1.0
        cast_one(i, px, py, dir_x + plane_x * cam, dir_y + plane_y * cam)
        i += 1
      end
      n
    end

    private

    def grow(n)
      [@dist, @tex, @hit_x, @hit_y, @norm_x, @norm_y, @roof_a, @roof_b].each { |a| a.fill(0.0, a.size...n) }
      [@kind, @side, @cell].each { |a| a.fill(0, a.size...n) }
      @n = n
    end

    def cast_one(i, px, py, rdx, rdy)
      cols = @cols
      cells = @cells
      roofs = @roofs
      mx = px.floor
      my = py.floor
      ddx = rdx.zero? ? 1e30 : (1.0 / rdx).abs
      ddy = rdy.zero? ? 1e30 : (1.0 / rdy).abs
      if rdx < 0
        sx = -1
        sdx = (px - mx) * ddx
      else
        sx = 1
        sdx = (mx + 1.0 - px) * ddx
      end
      if rdy < 0
        sy = -1
        sdy = (py - my) * ddy
      else
        sy = 1
        sdy = (my + 1.0 - py) * ddy
      end

      in_roof = roofs[my * cols + mx]
      a_end = in_roof ? RUNNING : NO_ROOF
      b_start = NO_ROOF
      steps = 0
      while steps < MAX_STEPS
        steps += 1
        if sdx < sdy
          enter = sdx
          sdx += ddx
          mx += sx
          side = 0
        else
          enter = sdy
          sdy += ddy
          my += sy
          side = 1
        end
        if mx < 0 || my < 0 || mx >= cols || my >= @rows || enter > @max_dist
          finish(i, enter, 1, side, 0.0, px + rdx * enter, py + rdy * enter, 0.0, 0.0, 0, a_end, b_start, in_roof)
          return
        end
        idx = my * cols + mx
        k = cells[idx]
        if k != 0 && @door[k]
          open = @open[idx]
          if @door_along_x[idx]
            t = rdy.zero? ? -1.0 : (my + 0.5 - py) / rdy
            hx = px + rdx * t
            fu = hx - mx
            if t > 0.0 && fu >= open && fu < 1.0 && fu >= 0.0
              finish(i, t, k, 1, fu - open, hx, my + 0.5, 0.0, -sy.to_f, idx, a_end, b_start, in_roof)
              return
            end
          else
            t = rdx.zero? ? -1.0 : (mx + 0.5 - px) / rdx
            hy = py + rdy * t
            fu = hy - my
            if t > 0.0 && fu >= open && fu < 1.0 && fu >= 0.0
              finish(i, t, k, 0, fu - open, mx + 0.5, hy, -sx.to_f, 0.0, idx, a_end, b_start, in_roof)
              return
            end
          end
          k = 0 # through the gap: roofed floor
        end
        if k.zero?
          rf = roofs[idx]
          next if rf == in_roof

          if in_roof
            a_end = enter if a_end == RUNNING
            b_start = NO_ROOF
          else
            b_start = enter
          end
          in_roof = rf
          next
        end

        r = @round[k]
        if r > 0.0
          cx = mx + 0.5
          cy = my + 0.5
          ox = px - cx
          oy = py - cy
          qa = rdx * rdx + rdy * rdy
          qb = 2.0 * (ox * rdx + oy * rdy)
          qc = ox * ox + oy * oy - r * r
          disc = qb * qb - 4.0 * qa * qc
          next if disc < 0.0

          t = (-qb - Math.sqrt(disc)) / (2.0 * qa)
          next if t <= 0.0

          hx = px + rdx * t
          hy = py + rdy * t
          nx = (hx - cx) / r
          ny = (hy - cy) / r
          u = Math.atan2(ny, nx) / (2.0 * Math::PI) + 0.5
          finish(i, t, k, 2, u, hx, hy, nx, ny, idx, a_end, b_start, in_roof)
          return
        end

        hx = px + rdx * enter
        hy = py + rdy * enter
        if side.zero?
          u = hy - hy.floor
          u = 1.0 - u if rdx > 0
          finish(i, enter, k, 0, u, hx, hy, -sx.to_f, 0.0, idx, a_end, b_start, in_roof)
        else
          u = hx - hx.floor
          u = 1.0 - u if rdy < 0
          finish(i, enter, k, 1, u, hx, hy, 0.0, -sy.to_f, idx, a_end, b_start, in_roof)
        end
        return
      end
      finish(i, @max_dist, 1, 0, 0.0, px, py, 0.0, 0.0, 0, a_end, b_start, in_roof)
    end

    def finish(i, d, k, side, u, hx, hy, nx, ny, idx, a_end, b_start, in_roof)
      @dist[i] = d
      @kind[i] = k
      @side[i] = side
      @tex[i] = u
      @hit_x[i] = hx
      @hit_y[i] = hy
      @norm_x[i] = nx
      @norm_y[i] = ny
      @cell[i] = idx
      if a_end == RUNNING
        @roof_a[i] = d
        @roof_b[i] = NO_ROOF
      else
        @roof_a[i] = a_end
        @roof_b[i] = in_roof ? b_start : NO_ROOF
      end
    end
  end
end
