# frozen_string_literal: true

module Diem
  # How fast the camera flies through Ignition, second by second. Speed is a formula of t and the
  # kick drum; distance and roll are its integrals, tabulated once at 240 Hz, so any frame can be
  # drawn from t alone (the recorder and a seek get the same picture as the live run).
  class IgnitionFlight
    HZ = 240
    LENGTH = 34.0
    RISER = 12.0
    BREATH = 15.5
    DROP = 16.0
    BOOM = 31.0
    TAIL_TIME = 0.085 # a streak is where the star was this long ago
    INTRO_FROM = 3.5 # the cruise starts picking up
    CRUISE = 0.16 # depth per second as the riser takes over

    def initialize(origin)
      kicks = Music.score.fetch(:kick, []).map { |s, *| s * Music::STEP - origin }
      @kicks = kicks.select { |k| k >= DROP - 1e-6 && k < LENGTH }
      hats = Music.score.fetch(:hat, []).map { |s, *| s * Music::STEP - origin }
      @hats = hats.select { |k| k >= 0 && k < BREATH }
      tabulate
    end

    # Depth fraction travelled per second.
    def speed(t) = cruise(t) + surges(t)

    def distance(t) = lookup(@dist, t)
    def roll(t) = lookup(@roll, t)

    # Depth a streak's tail lags its head; frozen through the breath at its last warp length.
    def stretch(t)
      s = speed(t < BREATH || t >= DROP ? t : BREATH - 1e-4)
      (s * TAIL_TIME).clamp(0.0015, 0.3)
    end

    # Radians the tail trails the head around the axis: the vortex twist of hyperspace.
    def twist(t)
      roll_rate(t < BREATH || t >= DROP ? t : BREATH - 1e-4) * 0.16
    end

    # 0 cruising, 1 deep in hyperspace: drives the cyan to magenta shift.
    def warp(t)
      s = speed(t < BREATH || t >= DROP ? t : BREATH - 1e-4)
      ((s - 0.13) / 1.9).clamp(0.0, 1.0)
    end

    private

    # The flight without the drum surges. The intro picks up from 4 s, so the first bars visibly
    # go somewhere, and hands the riser a little more speed than it starts from.
    def cruise(t)
      if t < RISER then 0.035 + (CRUISE - 0.035) * smooth(INTRO_FROM, RISER, t)
      elsif t < BREATH then CRUISE + (3.01 - CRUISE) * ((t - RISER) / (BREATH - RISER))**3
      elsif t < DROP then 0.0
      elsif t < BOOM then 0.14
      else 0.14 + 2.6 * (t - BOOM)**2
      end
    end

    # The intro as it was first flown. Everything after the drop is pinned to where this put it,
    # so the retimed intro leaves the rest of the scene exactly as it was.
    def first_cruise(t)
      if t < RISER then 0.035 + 0.075 * (t / RISER)**2
      elsif t < BREATH then 0.11 + 2.9 * ((t - RISER) / (BREATH - RISER))**3
      else 0.0
      end
    end

    def smooth(a, b, t)
      x = ((t - a) / (b - a)).clamp(0.0, 1.0)
      x * x * (3.0 - 2.0 * x)
    end

    def surges(t)
      s = 0.0
      if t >= DROP
        s += 3.4 * Math.exp(-(t - DROP) / 0.28)
        k = last_index(@kicks, t)
        s += 0.42 * Math.exp(-(t - @kicks[k]) / 0.13) if k && @kicks[k] < BOOM + 0.6
      elsif t >= 8.0
        k = last_index(@hats, t)
        s += 0.035 * Math.exp(-(t - @hats[k]) / 0.07) if k
      end
      s
    end

    def roll_rate(t)
      if t < RISER then 0.035
      elsif t < BREATH then 0.035 + 1.5 * ((t - RISER) / (BREATH - RISER))**2
      elsif t < DROP then 0.0
      elsif t < BOOM then 0.03 + 0.5 * Math.exp(-(t - DROP) / 0.5)
      else 0.03 + 1.2 * (t - BOOM)
      end
    end

    def last_index(times, t)
      i = times.bsearch_index { |x| x > t } || times.size
      i.zero? ? nil : i - 1
    end

    def tabulate
      n = (LENGTH * HZ).ceil + 2
      dt = 1.0 / HZ
      @dist = Array.new(n, 0.0)
      @roll = Array.new(n, 0.0)
      pin = 0.0
      drop = (DROP * HZ).round
      (1...n).each do |i|
        tm = (i - 0.5) * dt
        pin += (first_cruise(tm) - cruise(tm)) * dt if i <= drop
        @dist[i] = @dist[i - 1] + speed(tm) * dt
        @roll[i] = @roll[i - 1] + roll_rate(tm) * dt
      end
      # The jump lands on the drop's white frame, where no star shows.
      (drop...n).each { |i| @dist[i] += pin }
    end

    def lookup(table, t)
      x = t.clamp(0.0, LENGTH) * HZ
      i = x.floor
      return table[-1] if i >= table.size - 1

      f = x - i
      table[i] + (table[i + 1] - table[i]) * f
    end
  end
end
