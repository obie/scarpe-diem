# frozen_string_literal: true

# The snare roll under the Dots collapse, read straight from the score so the scene keeps its
# choreography wherever it runs (a tile in the finale included). Times are scene-local seconds.
module Diem
  class DotsRoll
    def initialize(from, to, start: 48 * Music::BAR)
      hits = Music.score[:snare].filter_map do |step, _len, _note, vel, _opts|
        at = step * Music::STEP - start
        [at, vel] if at >= from && at < to
      end
      @times = hits.map(&:first)
      top = hits.map(&:last).max || 1.0
      @vels = hits.map { |_, v| v / top }
      @sums = @vels.each_with_object([0.0]) { |v, acc| acc << acc.last + v }
      @end = to
    end

    def first = @times.first || @end

    # 1.0 (times velocity) the instant a hit lands, gone in about three tau. A power under 1
    # lifts the quiet early hits of the roll so each one still reads.
    def pulse(t, tau = 0.035, power = 1.0)
      k = index(t)
      k.negative? ? 0.0 : @vels[k]**power * Math.exp(-(t - @times[k]) / tau)
    end

    # Velocity-weighted hit count, each hit easing in over `snap` seconds: a staircase that rises
    # a notch on every hit.
    def kicks(t, snap = 0.08)
      k = index(t)
      return 0.0 if k.negative?

      @sums[k] + @vels[k] * ease((t - @times[k]) / snap)
    end

    # f (a smooth progress curve) sampled only on the hits: it snaps to the next hit's value in
    # `snap` seconds and holds, so the motion ratchets on the grid.
    def ratchet(t, snap = 0.05)
      k = index(t)
      return yield(t) if k.negative?

      a = @times[k]
      b = @times[k + 1] || @end
      fa = yield(a)
      fa + (yield(b) - fa) * ease((t - a) / snap)
    end

    private

    def index(t)
      (@times.bsearch_index { |x| x > t + 1e-9 } || @times.size) - 1
    end

    def ease(x)
      return 0.0 if x <= 0.0
      return 1.0 if x >= 1.0

      1.0 - (1.0 - x)**3
    end
  end
end
