# frozen_string_literal: true

require "digest"
require "fileutils"

# The two wall textures of the Tunnel and the palettes that light them. A texture is 256 x 256
# indexed-colour texels, stored pre-shifted (level << 4) so the per-pixel loop can OR the fog
# shade (0..15) straight in: palette index = level << 4 | shade. Row = depth, column = angle.
#
# Each texture also comes box-filtered at a few sizes (a hand-made mip chain): far walls read a
# copy averaged over their footprint, so they stay smooth instead of twinkling, and on a surge
# every wall reads a copy smeared along the depth, which is motion blur for free.
module Diem
  module TunnelTextures
    SIZE = 256
    TEXELS = SIZE * SIZE
    BITS = 8
    SHADES = 16
    LIFTS = 8   # palette copies washed toward the theme light, for flashes that cost no paint
    PULSES = 3  # seam brightness steps (the galloping bass)
    GLINTS = 3  # lit-cell brightness steps (the bell)
    FX = PULSES * GLINTS
    DEPTH_BOXES = [1, 4, 8, 16, 32].freeze
    ANGLE_BOXES = [1, 2, 4].freeze

    SQ3 = Math.sqrt(3.0)

    # Each theme is three colour ramps over the 64 levels, the haze far walls fade through, the
    # light pulses glow in, and which levels are seams and which are lit cells.
    THEMES = [
      {
        ramps: [
          [0, 15, [[5, 3, 16], [26, 10, 66], [70, 26, 140]]],
          [16, 43, [[50, 24, 130], Palette::VIOLET, Palette::MAGENTA, [255, 170, 215], [255, 250, 255]]],
          [44, 63, [[0, 40, 70], [0, 150, 190], Palette::CYAN, [215, 255, 255]]],
        ],
        seams: 16..43,
        cells: 44..63,
        fog: [70, 12, 140],
        light: [255, 90, 200],
      },
      {
        ramps: [
          [0, 15, [[4, 1, 3], [30, 5, 16], [80, 12, 34]]],
          [16, 39, [[50, 8, 6], Palette::RUBY, Palette::EMBER, Palette::GOLD, [255, 228, 160]]],
          [40, 63, [[0, 40, 36], [10, 140, 100], Palette::MINT, [210, 255, 235]]],
        ],
        seams: 16..39,
        cells: 40..63,
        fog: [140, 24, 30],
        light: [255, 170, 60],
      },
    ].freeze

    module_function

    # ---- textures ---------------------------------------------------------------------------

    # A neon hex grid: magenta glowing seams, dark violet cells, a scatter of cyan-lit cells.
    # 16 hexes around and 16 rows along each repeat, so it tiles both ways.
    def hex
      rng = Random.new(7272)
      lit = Array.new(256) { rng.rand < 0.26 ? 0.55 + rng.rand * 0.45 : 0.0 }
      Array.new(TEXELS) do |idx|
        x = ((idx & 255) + 0.5) / SIZE * SQ3 * 16
        y = ((idx >> 8) + 0.5) / SIZE * 24
        cq, cr, px, py = hex_cell(x, y)
        e = 1.0 - [px.abs, px.abs * 0.5 + py.abs * SQ3 / 2].max / (SQ3 / 2) # 0 on the seam
        glow = e < 0.04 ? 1.0 : Math.exp(-(e - 0.04) / 0.07)
        k = lit[cell_key(cq, cr)]
        level = if k.positive?
          44 + ([glow, k * (0.25 + 0.5 * (1.0 - e)**2)].max * 19).round
        elsif glow > 0.05
          16 + (glow * 27).round
        else
          (15 * (1.0 - e)**2.2).round.clamp(0, 15)
        end
        level << 4
      end
    end

    # Axial cube-rounding to the nearest pointy hex (circumradius 1). Returns its axial coords
    # and the offset of (x, y) from its centre.
    def hex_cell(x, y)
      q = SQ3 / 3 * x - y / 3.0
      r = 2.0 / 3 * y
      s = -q - r
      rq = q.round
      rr = r.round
      rs = s.round
      dq = (rq - q).abs
      dr = (rr - r).abs
      ds = (rs - s).abs
      if dq > dr && dq > ds
        rq = -rr - rs
      elsif dr > ds
        rr = -rq - rs
      end
      [rq, rr, x - SQ3 * (rq + rr / 2.0), y - 1.5 * rr]
    end

    # The lattice repeats every 16 cells in q and every (q - 8, r + 16): one key per cell.
    def cell_key(q, r)
      rm = r % 16
      k = (r - rm) / 16
      ((q + 8 * k) % 16) * 16 + rm
    end

    # A circuit board: ember-gold traces between grid nodes, mint pads, a dim ruby checker.
    def circuit
      rng = Random.new(1609)
      trace = Array.new(TEXELS, 0.0)
      pad = Array.new(TEXELS, 0.0)
      nodes = 16
      cell = SIZE / nodes
      nodes.times do |j|
        nodes.times do |i|
          x = i * cell + cell / 2
          y = j * cell + cell / 2
          ends = 0
          if rng.rand < 0.55
            stamp_segment(trace, x, y, x + cell, y, 0.8)
            ends += 1
          end
          if rng.rand < 0.5
            stamp_segment(trace, x, y, x, y + cell, 0.8)
            ends += 1
          end
          if rng.rand < 0.22
            stamp_segment(trace, x, y, x + cell / 2, y + cell / 2, 0.9)
            stamp_segment(trace, x + cell / 2, y + cell / 2, x + cell, y + cell / 2, 0.9)
          end
          stamp_pad(pad, x, y, ends.zero? ? 2.2 : 3.2) if ends != 1 || rng.rand < 0.35
        end
      end
      Array.new(TEXELS) do |idx|
        u = idx >> 8
        v = idx & 255
        tr = trace[idx]
        pd = pad[idx]
        level = if pd > 0.08 && pd >= tr
          40 + (pd * 23).round
        elsif tr > 0.06
          16 + (tr * 23).round
        else
          checker = ((u >> 4) + (v >> 4)).even? ? 8 : 3
          fine = (u % 4).zero? || (v % 4).zero? ? 3 : 0
          checker + fine
        end
        level.clamp(0, 63) << 4
      end
    end

    # Glow around a segment, wrapped onto the torus of the texture: 1 on the core.
    def stamp_segment(buf, x0, y0, x1, y1, core)
      reach = 6
      dx = x1 - x0
      dy = y1 - y0
      len2 = (dx * dx + dy * dy).to_f
      ([x0, x1].min - reach..[x0, x1].max + reach).each do |x|
        ([y0, y1].min - reach..[y0, y1].max + reach).each do |y|
          t = (((x - x0) * dx + (y - y0) * dy) / len2).clamp(0.0, 1.0)
          ex = x - (x0 + dx * t)
          ey = y - (y0 + dy * t)
          d = Math.sqrt(ex * ex + ey * ey)
          g = d < core ? 1.0 : Math.exp(-(d - core) / 1.0) * 0.8
          i = ((y % SIZE) << BITS) | (x % SIZE)
          buf[i] = g if g > buf[i]
        end
      end
    end

    # A ring pad with a bright rim and a hole.
    def stamp_pad(buf, x0, y0, radius)
      reach = (radius + 5).ceil
      (-reach..reach).each do |oy|
        (-reach..reach).each do |ox|
          d = (Math.sqrt(ox * ox + oy * oy) - radius).abs
          g = d < 0.9 ? 1.0 : Math.exp(-(d - 0.9) / 0.9) * 0.85
          i = (((y0 + oy) % SIZE) << BITS) | ((x0 + ox) % SIZE)
          buf[i] = g if g > buf[i]
        end
      end
    end

    # ---- the mip chain ----------------------------------------------------------------------

    # The texture averaged over a box of bd texels along the depth and ba around, in colour,
    # then snapped back to the nearest of the theme's 64 levels.
    def filtered(tex, theme, bd, ba)
      return tex if bd == 1 && ba == 1

      colours = levels(theme[:ramps])
      # a root-mean-square average, so glowing seams and lit cells keep their colour when
      # smeared into the dark cells instead of greying out
      chans = Array.new(3) { |c| tex.map { |v| colours[v >> 4][c].to_f**2 } }
      chans.map! { |ch| box_cols(box_rows(ch, bd), ba).map! { |x| x > 0.0 ? Math.sqrt(x) : 0.0 } }
      nearest = {}
      Array.new(TEXELS) do |i|
        r = chans[0][i]
        g = chans[1][i]
        b = chans[2][i]
        key = (r.to_i >> 2) << 12 | (g.to_i >> 2) << 6 | (b.to_i >> 2)
        nearest[key] ||= closest_level(colours, r, g, b) << 4
      end
    end

    # A wrapping box filter down each column (along the depth).
    def box_rows(ch, n)
      return ch if n == 1

      out = Array.new(TEXELS, 0.0)
      lo = n / 2
      SIZE.times do |col|
        sum = 0.0
        n.times { |k| sum += ch[(((k - lo) & 255) << 8) | col] }
        SIZE.times do |row|
          out[(row << 8) | col] = sum / n
          sum += ch[(((row - lo + n) & 255) << 8) | col] - ch[(((row - lo) & 255) << 8) | col]
        end
      end
      out
    end

    # The same along each row (around the tunnel).
    def box_cols(ch, n)
      return ch if n == 1

      out = Array.new(TEXELS, 0.0)
      lo = n / 2
      SIZE.times do |row|
        base = row << 8
        sum = 0.0
        n.times { |k| sum += ch[base | ((k - lo) & 255)] }
        SIZE.times do |col|
          out[base | col] = sum / n
          sum += ch[base | ((col - lo + n) & 255)] - ch[base | ((col - lo) & 255)]
        end
      end
      out
    end

    def closest_level(colours, r, g, b)
      best = 0
      best_d = Float::INFINITY
      colours.each_with_index do |c, l|
        dr = c[0] - r
        dg = c[1] - g
        db = c[2] - b
        d = dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11
        if d < best_d
          best_d = d
          best = l
        end
      end
      best
    end

    # ---- palettes ---------------------------------------------------------------------------

    # palettes[lift][fx] = 1024 BGR pixel Strings, indexed level << 4 | shade. Shade 0 is black,
    # 11 is the texture as drawn, 12..15 burn toward the theme light (pulses racing down the
    # walls). fx = pulse * GLINTS + glint: the seams brighten on the bass, lit cells on the bell.
    def palettes(theme)
      base = levels(theme[:ramps])
      fog = theme[:fog]
      light = theme[:light]
      hot = Palette.mix(light, [255, 255, 255], 0.35)
      Array.new(LIFTS) do |lift|
        # small washes tint toward the saturated light, the biggest is all but white
        wash = lift.fdiv(LIFTS - 1)
        target = Palette.mix(light, [255, 255, 255], wash**1.5)
        wash *= 0.6 + 0.32 * wash
        Array.new(FX) do |fx|
          lit = lit_levels(base, theme, fx / GLINTS, fx % GLINTS, hot)
          Array.new(64 * SHADES) do |i|
            c = shaded(lit[i >> 4], i & 15, fog, light)
            Framebuffer.pixel(Palette.mix(c, target, wash))
          end
        end
      end
    end

    def lit_levels(base, theme, pulse, glint, hot)
      base.each_with_index.map do |c, l|
        if theme[:seams].cover?(l)
          Palette.mix(c, hot, 0.2 * pulse)
        elsif theme[:cells].cover?(l)
          Palette.mix(c, [255, 255, 255], 0.3 * glint)
        else
          c
        end
      end
    end

    def levels(ramps)
      out = Array.new(64) { [0, 0, 0] }
      ramps.each do |from, to, stops|
        (from..to).each do |l|
          x = (l - from).fdiv(to - from) * (stops.size - 1)
          k = [x.floor, stops.size - 2].min
          out[l] = Palette.mix(stops[k], stops[k + 1], x - k)
        end
      end
      out
    end

    # Past 11 the light is tinted, so a pulse glows in the theme's colour instead of greying.
    def shaded(c, s, fog, light)
      if s > 11
        k = (s - 11) / 4.0
        return [c[0] * (1 + 0.6 * k) + light[0] * k * 0.6, c[1] * (1 + 0.6 * k) + light[1] * k * 0.6,
                c[2] * (1 + 0.6 * k) + light[2] * k * 0.6]
      end

      b = s / 11.0
      haze = b * (1.0 - b) * 1.1
      [c[0] * b**1.25 + fog[0] * haze, c[1] * b**1.25 + fog[1] * haze, c[2] * b**1.25 + fog[2] * haze]
    end

    # ---- precalc: every texture is worked out once, shared, and kept on disk ------------------
    #
    # The Tunnel and the finale's tunnel tile ask for the same box-filtered textures, which take
    # about two seconds of Ruby to make. They are made once (behind the loader), shared by both,
    # and written to Application Support so the next launch reads them in a few milliseconds.
    @memo = nil
    @dirty = false

    class << self
      def cached(key)
        load_memo
        @memo.fetch(key) do
          @dirty = true
          @memo[key] = yield
        end
      end

      def persist
        return unless @dirty

        FileUtils.mkdir_p(File.dirname(cache_path))
        File.binwrite("#{cache_path}.tmp", Marshal.dump(@memo))
        File.rename("#{cache_path}.tmp", cache_path)
        @dirty = false
      rescue SystemCallError
        nil
      end

      private

      def cache_path
        @cache_path ||= File.join(DATA_DIR, "tunnel-#{Digest::SHA256.hexdigest(File.read(__FILE__))[0, 12]}.bin")
      end

      def load_memo
        return if @memo

        @memo = File.exist?(cache_path) ? Marshal.load(File.binread(cache_path)) : {}
      rescue StandardError
        @memo = {}
      end
    end

    module Memo
      def hex = TunnelTextures.cached([:hex]) { super }
      def circuit = TunnelTextures.cached([:circuit]) { super }
      def palettes(theme) = TunnelTextures.cached([:palettes, THEMES.index(theme)]) { super }

      def filtered(tex, theme, bd, ba)
        base = tex.equal?(hex) ? :hex : tex.equal?(circuit) ? :circuit : nil
        return super unless base

        TunnelTextures.cached([:filtered, base, THEMES.index(theme), bd, ba]) { super }
      end
    end
    singleton_class.prepend(Memo)
  end
end
