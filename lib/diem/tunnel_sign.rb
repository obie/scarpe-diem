# frozen_string_literal: true

# "B MINOR. BECAUSE WE CAN." as a solid 3D sign of bitfont blocks: every block is a quad
# projected from world space each frame, so the sign can swing, sit in perspective with an
# extruded back face, and then blow apart into hundreds of tumbling blocks that fly past the
# camera. Blocks share three Shapes (one path and one fill each), so the paint stays at three
# fills however many blocks there are. The scene draws faces[2] first, then faces[0], then
# faces[1]: before the burst they are the extrusion (back face and the visible sides), line
# one and line two; after it, the faces in shadow, the edges and the lit faces on top.
module Diem
  class TunnelSign
    LINES = [["B MINOR.", 1.6], ["BECAUSE WE CAN.", 1.0]].freeze
    GAP = 2.4          # font pixels between the lines
    BLOCK = 0.46       # half a block, in font pixels (the rest is the gap between blocks)
    DEPTH = 2.2        # how far the back face sits behind the front
    NEAREST = 10.0     # a block closer than this has flown past the camera
    EDGE = 0.3         # |cos tumble| under this shows a block edge-on

    MOVE = "move_to"
    LINE = "line_to"

    attr_reader :count

    def initialize(seed: 76)
      @bx = []
      @by = []
      @hs = []
      @line = []
      layout
      @count = @bx.size
      shatter_params(Random.new(seed))
    end

    # Fills faces (three Arrays) with Shape commands for this pose. pose: z (distance of the
    # sign's centre), yaw, roll, f (focal length, px), vp and centre (screen points [x, y]), and
    # burst (seconds since it began to blow apart, or nil), pull (0..1: how far near blocks are
    # drawn round the screen centre rather than the vanishing point). Returns blocks drawn.
    def project(pose, faces)
      faces.each(&:clear)
      z0 = pose[:z]
      f = pose[:f]
      cy = Math.cos(pose[:yaw])
      sy = Math.sin(pose[:yaw])
      cr = Math.cos(pose[:roll])
      sr = Math.sin(pose[:roll])
      burst = pose[:burst]
      vpx, vpy = pose[:vp]
      scx, scy = pose[:centre]
      @pull = pose[:pull] || 0.0
      drawn = 0
      @count.times do |k|
        x = @bx[k] * cr - @by[k] * sr
        y = @bx[k] * sr + @by[k] * cr
        # into world space: yaw about the vertical axis, then out to the sign's distance
        wx = x * cy
        wz = z0 + x * sy
        wy = y
        if burst
          a = burst - @delay[k]
          a = 0.0 if a.negative?
          kick = a + 0.16 * (1.0 - Math.exp(-a / 0.05))
          wx += @vx[k] * kick
          wy += @vy[k] * kick
          wz -= @vz[k] * kick + 40.0 * a * a
          next if wz < NEAREST

          drawn += 1
          tumble = Math.cos(@tumble[k] * a)
          face = if tumble > EDGE then faces[1] elsif tumble < -EDGE then faces[2] else faces[0] end
          quad(face, wx, wy, wz, @hs[k], @spin[k] * a, tumble.abs.clamp(0.12, 1.0), f, vpx, vpy, scx, scy)
          next
        end
        next if wz < NEAREST

        drawn += 1
        quad(faces[@line[k]], wx, wy, wz, @hs[k], 0.0, 1.0, f, vpx, vpy, scx, scy)
        # the extrusion thins as a block nears, or its back would outlive its front on screen
        depth = DEPTH * ((wz - 25.0) / 50.0).clamp(0.0, 1.0)
        next unless depth > 0.3

        fx, fy, fh = square(wx, wy, wz, @hs[k], f, vpx, vpy, scx, scy)
        bx, by, bh = square(wx, wy, wz + depth, @hs[k], f, vpx, vpy, scx, scy)
        extrude(faces[2], fx - fh, fy - fh, fx + fh, fy + fh, bx - bh, by - bh, bx + bh, by + bh)
      end
      drawn
    end

    private

    # Lines centred on the origin, in font pixels, y down.
    def layout
      height = LINES.sum { |_, s| 7 * s } + GAP
      top = -height / 2.0
      LINES.each_with_index do |(text, s), n|
        width = Bitfont.width(text) * s
        Bitfont.points(text).each do |px, py|
          @bx << px * s + s / 2.0 - width / 2.0
          @by << top + py * s + s / 2.0
          @hs << BLOCK * s
          @line << n
        end
        top += 7 * s + GAP
      end
    end

    # Each block's flight when the sign breaks: an impulse on the hit itself that throws it
    # outward from the centre and hard at the camera, then a tumble about its own axis.
    def shatter_params(rng)
      @vx = []
      @vy = []
      @vz = []
      @spin = []
      @tumble = []
      @delay = []
      @count.times do |k|
        x = @bx[k]
        y = @by[k]
        @vx << x * (0.15 + rng.rand * 0.5) + (rng.rand - 0.5) * 16
        @vy << y * (0.25 + rng.rand * 0.7) + (rng.rand - 0.5) * 16
        @vz << 25 + rng.rand * 105
        @spin << (rng.rand - 0.5) * 9
        @tumble << (rng.rand < 0.5 ? -1 : 1) * (3.0 + rng.rand * 22.0)
        @delay << Math.sqrt(x * x + y * y * 4) / 45.0 * 0.045 + rng.rand * 0.015
      end
    end

    # A square of half-size hs centred on (wx, wy, wz), turned by spin and squashed by squash
    # (a block tumbling about its own axis), projected. Near things sit around the screen
    # centre and far things around the vanishing point.
    def quad(out, wx, wy, wz, hs, spin, squash, f, vpx, vpy, scx, scy)
      g = centring(wz)
      ox = vpx + (scx - vpx) * g
      oy = vpy + (scy - vpy) * g
      k = f / wz
      cs = Math.cos(spin) * hs * k
      sn = Math.sin(spin) * hs * k
      x = ox + wx * k
      y = oy + wy * k
      # the corners: (+-1, +-squash) turned by spin
      ux = cs
      uy = sn
      vx = -sn * squash
      vy = cs * squash
      out << [MOVE, (x - ux - vx).round(1), (y - uy - vy).round(1)]
      out << [LINE, (x + ux - vx).round(1), (y + uy - vy).round(1)]
      out << [LINE, (x + ux + vx).round(1), (y + uy + vy).round(1)]
      out << [LINE, (x - ux + vx).round(1), (y - uy + vy).round(1)]
    end

    def centring(wz)
      g = (1.0 - (wz - 60.0) / 1500.0).clamp(0.0, 1.0) * 0.9
      g + (1.0 - g) * @pull
    end

    # An unturned block projected: its screen centre and half-size.
    def square(wx, wy, wz, hs, f, vpx, vpy, scx, scy)
      g = centring(wz)
      k = f / wz
      [vpx + (scx - vpx) * g + wx * k, vpy + (scy - vpy) * g + wy * k, hs * k]
    end

    # The block's back face and every side that shows past its front (front: l t r b, back:
    # bl bt br bb), so the extrusion reads as one solid with the face drawn over it. All
    # clockwise on screen, as nonzero winding needs.
    def extrude(out, l, t, r, b, bl, bt, br, bb)
      poly(out, bl, bt, br, bt, br, bb, bl, bb)
      poly(out, bl, bt, l, t, l, b, bl, bb) if bl < l
      poly(out, r, t, br, bt, br, bb, r, b) if br > r
      poly(out, bl, bt, br, bt, r, t, l, t) if bt < t
      poly(out, l, b, r, b, br, bb, bl, bb) if bb > b
    end

    def poly(out, x0, y0, x1, y1, x2, y2, x3, y3)
      out << [MOVE, x0.round(1), y0.round(1)]
      out << [LINE, x1.round(1), y1.round(1)]
      out << [LINE, x2.round(1), y2.round(1)]
      out << [LINE, x3.round(1), y3.round(1)]
    end
  end
end
