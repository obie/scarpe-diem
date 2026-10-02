# frozen_string_literal: true

# The light around the Dots formation: the chord-tinted haze, the centre glow (a faint anchor at
# the start, the blinding point at the end) and the anamorphic band, streak and whiteout.
# Mixed into Diem::Scenes::Dots; it reads @roll and the scene's w, h, u.
module Diem
  module DotsLight
    # The renderer has no radial gradients, so the glow is a stack of ovals of one small alpha
    # step each: 3 of 255 at the rim, 16 at the heart. Their radii are solved so the stack
    # follows a soft 1/(1+r^2)^2.5 falloff, which keeps every step near the limit of 8-bit colour.
    RINGS = 40
    RING_ALPHA = Array.new(RINGS) { |j| (3 + 13 * j.fdiv(RINGS - 1)**2).round }.freeze
    RING_RADII = begin
      keep = 1.0
      lift = RING_ALPHA.map { |a| 1.0 - (keep *= 1.0 - a / 255.0) }
      raw = lift.map { |l| Math.sqrt((l / lift.last)**(-1 / 2.5) - 1.0) }
      raw.map { |r| [r / raw.first, 0.025].max }.freeze
    end
    RIM = [104, 64, 214].freeze
    HEART = [255, 236, 204].freeze

    # Haze tint per pad chord of the breakdown (F G Em Am).
    CHORD_TINT = { f: [128, 60, 206], g: [72, 82, 226], em: [36, 118, 210], am: [176, 50, 150] }.freeze
    DREAM_ORDER = %i[f g em am].freeze

    def build_light
      clear = Palette.rgb([255, 255, 255], 0.0)
      draw do
        nostroke
        @band = Array.new(4) { rect(-50, -50, 2, 2, fill: clear, strokewidth: 0) }
        @rings = Array.new(RINGS) { oval(-50, -50, 2, 2, fill: clear, strokewidth: 0) }
        @streak_l = rect(-50, -50, 2, 2, fill: clear, strokewidth: 0)
        @streak_r = rect(-50, -50, 2, 2, fill: clear, strokewidth: 0)
        @core = oval(-50, -50, 2, 2, fill: clear, strokewidth: 0)
      end
      @ring_colours = Array.new(RINGS) { |j| Palette.mix(RIM, HEART, j.fdiv(RINGS - 1)**1.4) }
    end

    # The overexposed last 16th: white at the heart, gold, then rose at the rim of the frame.
    FLARE = [[0.0, [255, 252, 242]], [0.16, [255, 244, 214]], [0.38, [255, 196, 128]],
             [0.62, [250, 128, 150]], [1.0, [214, 86, 176]]].freeze

    def flare_colour(r)
      k = FLARE.each_cons(2).find { |(a, _), (b, _)| r <= b } || FLARE.last(2)
      (a, ca), (b, cb) = k
      Palette.mix(ca, cb, ((r - a) / (b - a)).clamp(0.0, 1.0))
    end

    def reset_light
      @light_state = nil
      @haze_state = nil
      @finale_parked = nil
      @parked_light = {}
    end

    # ---- haze -----------------------------------------------------------------------------------

    SKY_TOP = [16, 10, 38].freeze
    SKY_BOTTOM = [3, 2, 8].freeze
    HAZE = 0.12

    # The sky at mid height: what the base gradient and a 12% haze of this colour make there.
    def self.sky_mid(tint) = Palette.mix(Palette.mix(SKY_TOP, SKY_BOTTOM, 0.5), tint, HAZE)

    HAZE_TOP_MID = sky_mid([92, 58, 196]).freeze

    # The sky in the flare: a horizon of gold light under rose and magenta.
    FLARE_TOP = [214, 86, 168].freeze
    FLARE_MID = [255, 224, 178].freeze
    FLARE_BOTTOM = [188, 64, 156].freeze
    FLARE_FROM = 15.875

    # 0 until the last snare, then up to 1 at the downbeat, easing in over the first frames.
    def flare_at(t)
      f = ((t - FLARE_FROM) / (16.0 - FLARE_FROM)).clamp(0.0, 1.0)
      f * f * (3 - 2 * f)
    end

    # Each bar the haze leans towards the colour of the new chord, over about a beat. In the
    # flare the same two rects light up into a band of light across the frame.
    def haze(t)
      bar = (t / Music::BAR).floor.clamp(0, 7)
      into = ((t - bar * Music::BAR) / 0.9).clamp(0.0, 1.0)
      into = into * into * (3 - 2 * into)
      flare = (flare_at(t) * 40).round
      state = bar * 32 + (into * 10).round + flare * 1000
      return if state == @haze_state

      @haze_state = state
      now = CHORD_TINT[DREAM_ORDER[bar % 4]]
      before = bar.zero? ? [92, 58, 196] : CHORD_TINT[DREAM_ORDER[(bar - 1) % 4]]
      mid = DotsLight.sky_mid(Palette.mix(before, now, (state % 32) / 10.0))
      f = flare / 40.0
      top = wc(Palette.mix(SKY_TOP, FLARE_TOP, f))
      mid = wc(Palette.mix(mid, Palette.mix(FLARE_TOP, FLARE_MID, f), f**0.8))
      bottom = wc(Palette.mix(SKY_BOTTOM, FLARE_BOTTOM, f))
      set(@haze_top, { fill: { gradient: [top, mid], angle: 0 } })
      set(@haze_bottom, { fill: { gradient: [mid, bottom], angle: 0 } })
    end

    # ---- the point ------------------------------------------------------------------------------

    # anchor: 0..1, the opening glow. p: collapse progress (ratcheted). kick: the snare pulse.
    def light(t, anchor, p, kick)
      if anchor <= 0.004 && p <= 0.0
        park_light
        return
      end

      @light_state = :on
      cx = w * 0.5
      cy = h * 0.5
      final = flare_at(t)
      if p.positive?
        level = (0.25 + 0.75 * p**1.5) * (1.0 + 0.55 * kick) + 0.6 * final
        reach = (30 + 115 * p**2.2 + 30 * kick * p + 240 * final**1.2) * u
      else
        level = anchor
        reach = (100 - 30 * (1.0 - anchor)) * u
      end
      rings(cx, cy, reach, level.clamp(0.0, 1.0), final)
      return park_finale if p <= 0.0

      @finale_parked = false
      bands(cx, cy, p, kick)
      core = (3 + 13 * p**5 + 6 * kick * p + 14 * final) * u
      centered(@core, cx, cy, core, wc([255, 252, 244], [p * 1.6 + kick, 1.0].min))
      streak(cx, cy, p, kick, final)
    end

    # Before the flare the stack is the plain falloff: one small alpha step per ring, tinted by
    # level. In the last 16th it is solved instead (see flare_rings).
    def rings(cx, cy, reach, level, flare)
      return flare_rings(cx, cy, reach, level, flare) if flare.positive?

      bg = [12, 8, 28]
      @rings.each_with_index do |ring, j|
        c = Palette.mix(bg, @ring_colours[j], level)
        centered(ring, cx, cy, 2 * reach * RING_RADII[j], [c[0].round, c[1].round, c[2].round, RING_ALPHA[j]])
      end
    end

    # The overexposed last 16th. Each ring paints one flat colour, so a stack of strong rings
    # shows its edges as contours. Here the stack is solved from the rim in. Whatever the sky
    # is, a stack of rings leaves sky * T + S under band j (T what still shows through, S the
    # light the rings put there), so the glow is written as those two curves: a cover that rises
    # smoothly to opaque at the heart and a light that runs white, gold, rose. Each ring takes the
    # alpha that steps T to its curve and the colour that steps S to its, and every edge in the
    # stack is one small notch of a smooth glow, over the sky's own gradient, not a guess of it.
    def flare_rings(cx, cy, reach, level, flare)
      plain_t = 1.0
      plain_s = [0.0, 0.0, 0.0]
      have_t = 1.0
      have_s = [0.0, 0.0, 0.0]
      last = RINGS - 1
      @rings.each_with_index do |ring, j|
        base = Palette.mix([12, 8, 28], @ring_colours[j], level)
        a0 = RING_ALPHA[j] / 255.0
        plain_t *= 1.0 - a0
        plain_s = Array.new(3) { |c| plain_s[c] * (1.0 - a0) + base[c] * a0 }
        rho = 0.5 * (RING_RADII[j] + (j < last ? RING_RADII[j + 1] : 0.0))
        cover = flare_cover(rho / FLARE_EDGE)
        lit = flare_colour([rho / FLARE_EDGE, 1.0].min)
        want_t = plain_t + (1.0 - cover - plain_t) * flare
        want_s = Array.new(3) { |c| plain_s[c] + (lit[c] * cover - plain_s[c]) * flare }
        alpha = ((1.0 - want_t / have_t) * 255).round.clamp(0, 255)
        a = alpha / 255.0
        # Outside the flare the rings only fade the plain glow out. One that would add under 3
        # of 255 is parked and the next ring in takes up its share, which saves wide paint.
        if alpha.zero? || (alpha < 3 && rho > FLARE_EDGE)
          park(ring)
          next
        end

        col = Array.new(3) { |c| ((want_s[c] - have_s[c] * (1.0 - a)) / a).round.clamp(0, 255) }
        have_t *= 1.0 - a
        have_s = Array.new(3) { |c| have_s[c] * (1.0 - a) + col[c] * a }
        centered(ring, cx, cy, 2 * reach * RING_RADII[j], [col[0], col[1], col[2], alpha])
      end
    end

    # The flare glow ends at this share of the stack's reach. The rings outside it fade out as
    # the flare comes in and are parked at its peak, which keeps the paint of the widest frame
    # where the plain stack had it.
    FLARE_EDGE = 0.62

    # How much of the flare light covers the sky at r (0 heart, 1 the flare's edge): full at the
    # heart, flat at the edge so the glow has no rim.
    def flare_cover(r) = r >= 1.0 ? 0.0 : (1.0 - r**2.5)**2

    # A thin, hot horizontal band through the point, flaring on every snare, and a fainter beam.
    # They span the frame, so they wait until they would show: the renderer repaints only the
    # box that changed, and the formation alone is much smaller than the frame.
    def bands(cx, cy, p, kick)
      top, bottom, left, right = @band
      if p < 0.2
        park_once(top, bottom, left, right)
        return
      end
      glow = wc(Palette.mix([170, 96, 250], [255, 214, 236], p), (0.05 + 0.32 * p**2.5) * (1.0 + 0.9 * kick))
      clear = [glow[0], glow[1], glow[2], 0]
      hb = ((3 + 14 * p**2 + 5 * kick * p) * u).round(1)
      bw = ((2 + 12 * p**4) * u).round(1)
      @parked_light&.delete(top)
      @parked_light&.delete(bottom)
      set(top, { left: 0, top: (cy - hb).round(1), width: w, height: hb, fill: { gradient: [clear, glow], angle: 0 } })
      set(bottom, { left: 0, top: cy.round(1), width: w, height: hb, fill: { gradient: [glow, clear], angle: 0 } })
      return park_once(left, right) if p < 0.5

      beam = [glow[0], glow[1], glow[2], (glow[3] * 0.45 * p * p).round]
      @parked_light&.delete(left)
      @parked_light&.delete(right)
      set(left, { left: (cx - bw).round(1), top: 0, width: bw, height: h, fill: { gradient: [clear, beam], angle: 90 } })
      set(right, { left: cx.round(1), top: 0, width: bw, height: h, fill: { gradient: [beam, clear], angle: 90 } })
    end

    def streak(cx, cy, p, kick, final)
      half = (30 * u + w * (0.55 * p**4 + 0.08 * kick * p + 0.5 * final)).round(1)
      th = ((1.0 + 2.5 * p**4 + 1.5 * kick * p + 5 * final) * u).round(1)
      hot = wc([255, 244, 226], [p**3 + 0.5 * kick * p, 1.0].min)
      cold = [255, 220, 200, 0]
      set(@streak_l, { left: (cx - half).round(1), top: (cy - th / 2).round(1), width: half, height: th,
                       fill: { gradient: [cold, hot], angle: 90 } })
      set(@streak_r, { left: cx.round(1), top: (cy - th / 2).round(1), width: half, height: th,
                       fill: { gradient: [hot, cold], angle: 90 } })
    end

    def centered(d, cx, cy, size, fill)
      s = size.round(1)
      set(d, { left: (cx - s / 2).round(1), top: (cy - s / 2).round(1), width: s, height: s, fill: fill })
    end

    def park_light
      return if @light_state == :parked

      @light_state = :parked
      @rings.each { |d| park(d) }
      park_finale
    end

    def park_finale
      return if @finale_parked

      @finale_parked = true
      (@band + [@core, @streak_l, @streak_r]).each { |d| park(d) }
      @band.each { |d| @parked_light[d] = true }
    end

    def park(d) = set(d, { left: -50, top: -50, width: 2, height: 2 })

    def park_once(*ds)
      @parked_light ||= {}
      ds.each do |d|
        next if @parked_light[d]

        @parked_light[d] = true
        park(d)
      end
    end
  end
end
