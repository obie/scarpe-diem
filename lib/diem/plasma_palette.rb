# frozen_string_literal: true

# The Plasma scene's palette: HUES colours (a closed loop, so a cycling index never seams) times
# NL light levels, as ready-made BGR pixel strings indexed by level * HUES + hue.
# One loop per chord; the palette cross-fades between two loops, heats through the riser with
# its colour kept, and lands on a white tinted by the chord just before the engine's flash.
# A rebuild costs about a millisecond and a half and only happens when the inputs change.
module Diem
  class PlasmaPalette
    P = Palette
    NL = PlasmaField::NL
    HUES = PlasmaField::HUES
    SPAN = HUES * 3

    LOOPS = {
      dm: [[16, 12, 62], [40, 76, 205], P::VIOLET, [196, 182, 255], [70, 168, 255], [72, 44, 176]],
      am: [[44, 6, 40], [168, 18, 86], P::MAGENTA, [255, 172, 204], P::RUBY, [110, 14, 80]],
      f: [[70, 18, 10], [150, 40, 16], P::EMBER, [255, 232, 160], P::GOLD, [176, 58, 22]],
      e: [[6, 34, 52], [0, 128, 160], P::CYAN, [206, 255, 240], P::MINT, [14, 96, 118]],
    }.freeze

    # Chords from outside the groove (the finale runs this scene as a tile over Am F C G) borrow
    # the loop that sounds closest.
    ALIASES = { c: :f, g: :e, em: :e }.freeze

    # Each loop as SPAN Floats in pixel (B, G, R) order.
    BASES = LOOPS.transform_values do |stops|
      ring = stops + [stops.first]
      Array.new(SPAN) do |k|
        i = k / 3
        x = i / HUES.to_f * (ring.size - 1)
        j = x.floor
        c = P.mix(ring[j], ring[j + 1], x - j)
        c[2 - k % 3].to_f
      end.freeze
    end.freeze

    # Shadow tint per loop, as [B, G, R] multipliers at the darkest light level: gold in shade
    # turns olive, so F leans to ember and oxblood as the light falls.
    TINTS = Hash.new([1.0, 1.0, 1.0].freeze).merge(f: [0.42, 0.58, 1.12].freeze).freeze

    # How much of the hue each light level keeps, and how much white sheen it adds.
    DIFFUSE = Array.new(NL) { |l| 0.22 + 0.9 * (l / (NL - 1.0))**1.3 }.freeze
    SHEEN = Array.new(NL) do |l|
      s = (l / (NL - 1.0) - 0.62) / 0.38
      s.positive? ? 200.0 * s**1.6 : 0.0
    end.freeze
    DARK = Array.new(NL) { |l| (1.0 - l / (NL - 1.0))**1.6 }.freeze

    # DIFFUSE * colour + SHEEN can reach past 500. A film shoulder above KNEE rolls that into
    # 255 with its slope intact, so a crest keeps a gradient instead of a flat white plateau.
    KNEE = 168.0
    TOP = 640
    ROLL = 254.6 - KNEE
    SHOULDER = Array.new(TOP + 1) do |c|
      c < KNEE ? c.to_f : KNEE + ROLL * (1.0 - Math.exp(-(c - KNEE) / ROLL))
    end.freeze

    # The palest stop of each loop, as [B, G, R]: the colour the white-out leans to.
    PALEST = LOOPS.transform_values { |stops| stops.max_by(&:sum).reverse.map(&:to_f).freeze }.freeze
    WARM = [242.0, 250.0, 255.0].freeze # B, G, R

    def self.loop_for(sym) = LOOPS.key?(sym) ? sym : ALIASES.fetch(sym, :dm)

    SLICES = ("a3" * (HUES * NL)).freeze

    def initialize
      @bytes = ("\0" * (SPAN * NL)).b
      @mixed = Array.new(SPAN, 0.0)
      @pal = nil
      @key = nil
    end

    # from, to: chord symbols; m: 0..1 across; heat: 0..1, the riser's exposure push;
    # white: 0..1, the share mixed toward a white tinted by the chord.
    def at(from, to, m, heat, white = 0.0)
      from = PlasmaPalette.loop_for(from)
      to = PlasmaPalette.loop_for(to)
      key = [from, to, (m * 24).round, (heat * 24).round, (white * 40).round]
      return @pal if key == @key

      @key = key
      m = key[2] / 24.0
      tint = Array.new(3) { |j| TINTS[from][j] + (TINTS[to][j] - TINTS[from][j]) * m }
      heat = key[3] / 24.0
      white = key[4] / 40.0
      @pal = build(BASES.fetch(from), BASES.fetch(to), m, heat, white, tint, pale(from, to, m, white), glow(from, to, m, heat))
    end

    private

    # The white the push lands on: the chord's palest stop folded into a warm white, going
    # pure as it arrives, so the field meets the engine's flash without a seam.
    def pale(from, to, m, white)
      a = PALEST[from]
      b = PALEST[to]
      pure = white**4
      Array.new(3) do |j|
        c = (a[j] + (b[j] - a[j]) * m) * 0.45 + WARM[j] * 0.55
        c + (255.0 - c) * pure
      end
    end

    # The riser's sheen takes the chord's palest colour, so a hot crest glows mint or rose
    # or gold instead of grey: [B, G, R] multipliers on the sheen.
    def glow(from, to, m, heat)
      a = PALEST[from]
      b = PALEST[to]
      c = Array.new(3) { |j| a[j] + (b[j] - a[j]) * m }
      top = c.max
      Array.new(3) { |j| 1.0 - 0.75 * heat * (1.0 - c[j] / top) }
    end

    def build(a, b, m, heat, white, tint, pale, glow)
      bytes = @bytes
      mx = @mixed
      i = 0
      while i < SPAN
        mx[i] = a[i] + (b[i] - a[i]) * m
        i += 1
      end
      lift = [white * 1.7, 1.0].min
      lift = lift * lift * (3 - 2 * lift)
      # As the white-out begins, the loop's dark stops rise to their own full-strength hue
      # (deep teal to bright cyan), so nothing on the way to white passes through grey.
      if lift > 0.0
        i = 0
        while i < SPAN
          top = mx[i] > mx[i + 1] ? mx[i] : mx[i + 1]
          top = mx[i + 2] if mx[i + 2] > top
          g = 1.0 + lift * (240.0 / (top < 24.0 ? 24.0 : top) - 1.0)
          g = 1.0 if g < 1.0
          mx[i] *= g
          mx[i + 1] *= g
          mx[i + 2] *= g
          i += 3
        end
      end
      # The riser heats the colour, it does not wash it out: an exposure push whose shoulder
      # widens with it, so crests stay graded and tinted instead of clipping to flat white.
      # Then the white-out: the shade first rises to its own bright hue (the light levels all
      # take the full diffuse), and only then mixes toward the pale white, lit facets first, so
      # the field passes through bright colour and pastel on its way to white, never grey.
      tone = tone_curve(heat)
      hot = 1.0 + 0.55 * heat
      fade = hot * (1.0 - 0.85 * white**1.5) # the sheen melts into the white as it lands
      floor = 0.3 + 0.7 * white**1.5 # the troughs catch up as it lands
      pb, pg, pr = pale
      top = TOP
      hue = [heat * 3.0, 1.0].min
      # tone[c] / c, so the hue-keeping shoulder is one lookup and a multiply.
      per = hue > 0.0 ? Array.new(top + 1) { |c| c < 1 ? 1.0 : tone[c] / c } : nil
      full = DIFFUSE[NL - 1]
      l = 0
      while l < NL
        d = DIFFUSE[l]
        d += (full - d) * lift
        s = SHEEN[l] * fade
        sb = s * glow[0]
        sg = s * glow[1]
        sr = s * glow[2]
        dk = DARK[l] * (1.0 - lift)
        db = d * (1.0 + (tint[0] - 1.0) * dk)
        dg = d * (1.0 + (tint[1] - 1.0) * dk)
        dr = d * (1.0 + (tint[2] - 1.0) * dk)
        mix = white * (floor + (1.0 - floor) * l / (NL - 1.0))
        mix = 1.0 if mix > 1.0
        keep = 1.0 - mix
        ab = pb * mix + 0.5
        ag = pg * mix + 0.5
        ar = pr * mix + 0.5
        o = l * SPAN
        if hue >= 1.0
          row_hot(bytes, mx, o, db, dg, dr, sb, sg, sr, keep, ab, ag, ar, per)
        elsif hue > 0.0
          row_blend(bytes, mx, o, db, dg, dr, sb, sg, sr, keep, ab, ag, ar, per, tone, hue)
        else
          row_rest(bytes, mx, o, db, dg, dr, sb, sg, sr, keep, ab, ag, ar, tone)
        end
        l += 1
      end
      bytes.unpack(SLICES)
    end

    # One light level of the palette, three ways. At rest the shoulder works per channel.
    def row_rest(bytes, mx, o, db, dg, dr, sb, sg, sr, keep, ab, ag, ar, tone)
      top = TOP
      i = 0
      while i < SPAN
        c = (mx[i] * db + sb).to_i
        c = top if c > top
        bytes.setbyte(o + i, (tone[c] * keep + ab).to_i)
        c = (mx[i + 1] * dg + sg).to_i
        c = top if c > top
        bytes.setbyte(o + i + 1, (tone[c] * keep + ag).to_i)
        c = (mx[i + 2] * dr + sr).to_i
        c = top if c > top
        bytes.setbyte(o + i + 2, (tone[c] * keep + ar).to_i)
        i += 3
      end
    end

    # Hot, the shoulder is taken on the brightest channel and applied to all three, which
    # keeps a crest tinted; per channel, the channels would converge on grey.
    def row_hot(bytes, mx, o, db, dg, dr, sb, sg, sr, keep, ab, ag, ar, per)
      top = TOP
      i = 0
      while i < SPAN
        cb = mx[i] * db + sb
        cg = mx[i + 1] * dg + sg
        cr = mx[i + 2] * dr + sr
        c = cb > cg ? cb : cg
        c = cr if cr > c
        c = c.to_i
        c = top if c > top
        f = per[c] * keep
        bytes.setbyte(o + i, (cb * f + ab).to_i)
        bytes.setbyte(o + i + 1, (cg * f + ag).to_i)
        bytes.setbyte(o + i + 2, (cr * f + ar).to_i)
        i += 3
      end
    end

    # In between, at the riser's first moments, a blend of the two.
    def row_blend(bytes, mx, o, db, dg, dr, sb, sg, sr, keep, ab, ag, ar, per, tone, hue)
      top = TOP
      sh = (1.0 - hue) * keep
      hk = hue * keep
      i = 0
      while i < SPAN
        cb = mx[i] * db + sb
        cg = mx[i + 1] * dg + sg
        cr = mx[i + 2] * dr + sr
        c = cb > cg ? cb : cg
        c = cr if cr > c
        c = c.to_i
        c = top if c > top
        f = per[c] * hk
        x = cb.to_i
        x = top if x > top
        bytes.setbyte(o + i, (tone[x] * sh + cb * f + ab).to_i)
        x = cg.to_i
        x = top if x > top
        bytes.setbyte(o + i + 1, (tone[x] * sh + cg * f + ag).to_i)
        x = cr.to_i
        x = top if x > top
        bytes.setbyte(o + i + 2, (tone[x] * sh + cr * f + ar).to_i)
        i += 3
      end
    end

    # 0..TOP -> 0..254.6 Floats: the shoulder alone at heat 0. Heat scales the input up (an
    # exposure push), lowers the knee and swaps the shoulder's exponential for a rational roll
    # (slope 1 at the knee, like it, but a far slower approach to the ceiling), so even the
    # hottest sheen lands well under 255 and a crest stays a gradient, never a flat plateau.
    def tone_curve(heat)
      return SHOULDER if heat <= 0.0

      gain = 1.0 + 0.9 * heat
      knee = KNEE - 48.0 * heat
      roll = 254.6 - knee
      far = 275.0 - knee # the rational roll aims past 255, so its top still climbs
      b = [heat * 4.0, 1.0].min
      Array.new(TOP + 1) do |c|
        x = c * gain
        next x if x < knee

        q = (x - knee) / far
        y = knee + roll * (1.0 - Math.exp(-(x - knee) / roll)) * (1.0 - b) + far * q / (1.0 + q) * b
        y > 254.6 ? 254.6 : y
      end
    end
  end
end
