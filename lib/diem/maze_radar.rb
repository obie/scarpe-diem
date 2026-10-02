# frozen_string_literal: true

# The WOLFENSHOES minimap as a heading-up radar: the cells around the camera, turned so the
# view always points up, clipped to a disc. Each world row of floor inside the disc is one
# rotated quad, and every quad of a colour goes out in one shape, so the whole map is a
# handful of drawables however much of the level shows.
module Diem
  class MazeRadar
    REACH = 10.5 # cells from the camera to the rim

    attr_reader :cx, :cy, :r

    def initialize(scene, rc, cx:, cy:, radius:, roofed:, open:, door:, cells: [])
      @s = scene
      @rc = rc
      @cx = cx
      @cy = cy
      @r = radius
      @scale = radius / REACH
      @colours = [roofed, open, door]
      @kinds = cells # wall kinds that show as the door colour
    end

    # Inside a draw block.
    def build
      s = @s
      u = s.u
      @static = []
      @static << s.oval(@cx - @r - 3 * u, @cy - @r - 3 * u, 2 * @r + 6 * u, 2 * @r + 6 * u, fill: Palette.rgb(Palette::NIGHT, 0.7),
        stroke: Palette.rgb(Palette::CYAN, 0.55), strokewidth: 1.2 * u)
      @layers = @colours.map { |c| s.shape(0, 0, fill: c, strokewidth: 0) }
      @cmds = Array.new(@layers.size) { [] }
      @cone = s.shape(0, 0, fill: Palette.rgb(Palette::CYAN, 0.28), strokewidth: 0)
      @dots = Array.new(12) { s.rect(0, 0, 3 * u, 3 * u, fill: Palette.rgb(Palette::MAGENTA), strokewidth: 0, hidden: true) }
      @dots_on = 12
      @static << s.rect(@cx - 2 * u, @cy - 2 * u, 4 * u, 4 * u, fill: Palette.rgb(Palette::INK), strokewidth: 0)
      @static.concat(@layers) << @cone
      @tan_sent = nil
    end

    def enter
      @dots_on = @dots.size
      @tan_sent = nil
    end

    # Hold the radar back (false) or bring it in (true). A scene that never calls this keeps it
    # on screen throughout.
    def visible(on)
      return if on == @visible

      @visible = on
      @static.each { |d| @s.set(d, { hidden: !on }) }
      return if on

      @dots.each { |d| @s.set(d, { hidden: true }) }
      @dots_on = 0
    end

    # px, py: camera; dx, dy: unit heading; tan_half: tan of half the FOV;
    # marks: flat [x, y, x, y, ...] of pickups still to collect. sky: false keeps the open-sky
    # cells off the map (the hall stays a secret until its door opens).
    def update(px, py, dx, dy, tan_half, marks, sky: true)
      return if @visible == false

      rc = @rc
      cols = rc.cols
      cells = rc.cells
      roofs = rc.roofs
      reach = REACH
      cmds = @cmds
      cmds.each(&:clear)
      y0 = (py - reach).floor
      y1 = (py + reach).floor
      y0 = 0 if y0 < 0
      y1 = rc.rows - 1 if y1 >= rc.rows
      r2 = reach * reach
      y = y0
      while y <= y1
        # the widest chord of the disc across this row
        oy = py < y ? y - py : (py > y + 1 ? py - y - 1 : 0.0)
        half = r2 - oy * oy
        if half > 0.0
          half = Math.sqrt(half)
          xa = (px - half).floor
          xb = (px + half).floor
          xa = 0 if xa < 0
          xb = cols - 1 if xb >= cols
          x = xa
          while x <= xb
            layer = layer_of(cells[y * cols + x], roofs[y * cols + x])
            if layer.nil? || (layer == 1 && !sky)
              x += 1
              next
            end
            run = x
            x += 1 while x + 1 <= xb && layer_of(cells[y * cols + x + 1], roofs[y * cols + x + 1]) == layer
            cut(cmds[layer], run.to_f, y.to_f, x + 1.0, y + 1.0, px, py, dx, dy)
            x += 1
          end
        end
        y += 1
      end
      @layers.each_with_index { |sh, k| @s.set(sh, { shape_commands: cmds[k] }) }
      cone(tan_half)
      dots(px, py, dx, dy, marks)
    end

    private

    # 0 roofed floor, 1 open sky, 2 doors and lights, nil wall.
    def layer_of(k, roof)
      if k.zero? || k == MazeMap::PILLAR
        roof ? 0 : 1
      elsif @kinds.include?(k)
        2
      end
    end

    ARC = 4 # pieces of arc per cell where a run meets the rim

    # A world rectangle cut to the disc, then turned: whole cells go out as quads, and a run
    # that crosses the rim is traced down its left edge and back up its right, sampled across
    # its height, so the map ends on a smooth circle inside the rim.
    def cut(out, x0, y0, x1, y1, px, py, dx, dy)
      r2 = REACH * REACH
      ax = x0 - px
      bx = x1 - px
      ay = y0 - py
      by = y1 - py
      fx = ax * ax > bx * bx ? ax * ax : bx * bx
      fy = ay * ay > by * by ? ay * ay : by * by
      if fx + fy <= r2
        point(out, true, x0, y0, px, py, dx, dy)
        point(out, false, x1, y0, px, py, dx, dy)
        point(out, false, x1, y1, px, py, dx, dy)
        point(out, false, x0, y1, px, py, dx, dy)
        point(out, false, x0, y0, px, py, dx, dy)
        return
      end

      # the rows of the run that the disc reaches at all
      gx = ax > 0.0 ? ax : (bx < 0.0 ? -bx : 0.0)
      reach = r2 - gx * gx
      return if reach <= 0.0

      reach = Math.sqrt(reach)
      ya = y0 > py - reach ? y0 : py - reach
      yb = y1 < py + reach ? y1 : py + reach
      return if yb - ya < 1e-3

      n = ((yb - ya) * ARC).ceil
      n = 1 if n < 1
      ys = @ys ||= []
      ls = @ls ||= []
      rs = @rs ||= []
      k = 0
      while k <= n
        yk = ya + (yb - ya) * k / n
        oy = yk - py
        half = r2 - oy * oy
        half = half > 0.0 ? Math.sqrt(half) : 0.0
        l = px - half
        r = px + half
        l = x0 if l < x0
        r = x1 if r > x1
        if l > r
          m = gx.zero? ? px : (ax > 0.0 ? x0 : x1)
          l = r = m
        end
        ys[k] = yk
        ls[k] = l
        rs[k] = r
        k += 1
      end
      k = 0
      while k <= n
        point(out, k.zero?, ls[k], ys[k], px, py, dx, dy)
        k += 1
      end
      k = n
      while k >= 0
        point(out, false, rs[k], ys[k], px, py, dx, dy)
        k -= 1
      end
      point(out, false, ls[0], ys[0], px, py, dx, dy)
    end

    # One world point, turned so lateral offset goes right and forward goes up.
    def point(out, first, wx, wy, px, py, dx, dy)
      rx = wx - px
      ry = wy - py
      fwd = rx * dx + ry * dy
      lat = -rx * dy + ry * dx
      out << [first ? "move_to" : "line_to", (@cx + lat * @scale).round(1), (@cy - fwd * @scale).round(1)]
    end

    def cone(tan_half)
      t = tan_half.round(3)
      return if t == @tan_sent

      @tan_sent = t
      reach = @r * 0.82
      a = Math.atan(tan_half)
      lx = @cx - Math.sin(a) * reach
      rx = @cx + Math.sin(a) * reach
      ty = @cy - Math.cos(a) * reach
      @s.set(@cone, { shape_commands: [["move_to", @cx.round(1), @cy.round(1)], ["line_to", lx.round(1), ty.round(1)],
                                       ["line_to", rx.round(1), ty.round(1)], ["line_to", @cx.round(1), @cy.round(1)]] })
    end

    def dots(px, py, dx, dy, marks)
      sc = @scale
      lim = REACH - 0.6
      n = 0
      i = 0
      while i < marks.size && n < @dots.size
        rx = marks[i] - px
        ry = marks[i + 1] - py
        i += 2
        next if rx * rx + ry * ry > lim * lim

        fwd = rx * dx + ry * dy
        lat = -rx * dy + ry * dx
        u = @s.u
        @s.set(@dots[n], { hidden: false, left: (@cx + lat * sc - 1.5 * u).round(1), top: (@cy - fwd * sc - 1.5 * u).round(1) })
        n += 1
      end
      (n...@dots_on).each { |k| @s.set(@dots[k], { hidden: true }) }
      @dots_on = n
    end
  end
end
