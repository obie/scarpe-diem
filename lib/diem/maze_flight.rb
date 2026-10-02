# frozen_string_literal: true

require_relative "maze_map"
require_relative "maze_path"

# The autopilot of WOLFENSHOES 3D: where the camera is along the route at scene time t, and
# where it looks. Pure functions of t, so the recorder and the live run agree. Heading goes
# through a critically damped, slew-limited filter stepped at 1/120 s once at build time and
# kept as a table; corners are swung through, never whipped.
module Diem
  class MazeFlight
    M = MazeMap
    TAU = Math::PI * 2

    HALL_AT = 16.0
    RUSH_AT = 28.0
    END_AT = 32.0
    BRAKE_AT = 15.5 # the fill: brakes on, short of the door
    HOLD_AT = 15.95 # standing 1.8 cells off the door while it slides open
    PUSH_AT = 16.5  # through it on the beat after the crash
    GLIDE_AT = 17.3 # up to hall speed
    HOLD_Y = 9.7
    CREEP = 0.12
    V_START = 5.8   # cells per second at the start
    V_DOOR = 2.6    # where the drive would arrive at the door
    V_HALL = 3.0    # through the door and into the hall
    V_EXIT = 3.4    # leaving the orbit
    LUNGE = 0.9     # how hard each beat surges, as a share of a beat's travel
    DT = 1.0 / 120
    YAW_MAX = 3.3 * 60 * Math::PI / 180 # radians per second: 3.3 degrees a frame at 60 fps
    YAW_W = 9.0     # filter stiffness
    LOOK_AHEAD = 1.6
    RUSH_RISE = 1.5  # seconds to reach full speed down the last corridor
    RUSH_CLIMB = 0.1 # and how much it keeps climbing after that

    attr_reader :path, :s_door, :s_exit, :s_end, :shoe_s, :shoe_t

    def initialize
      @path = MazePath.new(MazePath.corridor(M::MAZE_ROUTE, cut: 0.75) + MazePath.straighten(M.hall_route))
      @s_door = @path.nearest_s(48.5, 10.4)
      @s_hold = @path.nearest_s(48.5, HOLD_Y)
      @s_exit = @path.nearest_s(M::HALL_CENTRE[0], M::HALL_CENTRE[1] - M::ORBIT, from: @s_door + 10.0)
      @s_end = @path.length
      @lunge_k = 6.0
      @lunge_m = (1.0 - Math.exp(-@lunge_k)) / @lunge_k
      build_brake
      build_rush
      @shoe_s = M::SHOE_AT
      @shoe_t = @shoe_s.map { |s| time_of(s - 0.3) }
      build_yaw
    end

    def hermite(u, p0, p1, m0, m1)
      u2 = u * u
      u3 = u2 * u
      (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1
    end

    # Distance along the route at scene time t: surging on every beat for fifteen seconds, a
    # hard stop short of the hall door through the fill, a push through it once it has slid
    # open, a glide round the hall, then a run at the light that keeps accelerating.
    def distance_at(t)
      t = t.clamp(0.0, END_AT)
      if t < BRAKE_AT
        drive(t)
      elsif t < HOLD_AT
        span = HOLD_AT - BRAKE_AT
        hermite((t - BRAKE_AT) / span, @brake_s, @s_hold, @brake_v * span, 0.0)
      elsif t < PUSH_AT
        hermite((t - HOLD_AT) / (PUSH_AT - HOLD_AT), @s_hold, @s_hold + CREEP, 0.0, 0.0)
      elsif t < GLIDE_AT
        span = GLIDE_AT - PUSH_AT
        hermite((t - PUSH_AT) / span, @s_hold + CREEP, @s_glide, 0.0, V_HALL * span)
      elsif t < RUSH_AT
        span = RUSH_AT - GLIDE_AT
        hermite((t - GLIDE_AT) / span, @s_glide, @s_exit, V_HALL * span, V_EXIT * span)
      else
        rush_at(t - RUSH_AT)
      end
    end

    def time_of(s)
      lo = 0.0
      hi = END_AT
      30.times do
        mid = (lo + hi) / 2
        distance_at(mid) < s ? lo = mid : hi = mid
      end
      hi
    end

    # Filtered heading (radians, unwrapped) and its rate (radians per second) at t.
    def yaw(t)
      x = t.clamp(0.0, END_AT) / DT
      i = x.floor
      i = @yaw.size - 2 if i > @yaw.size - 2
      f = x - i
      @yaw[i] + (@yaw[i + 1] - @yaw[i]) * f
    end

    def yaw_rate(t)
      x = t.clamp(0.0, END_AT) / DT
      i = x.floor
      i = @rate.size - 1 if i > @rate.size - 1
      @rate[i]
    end

    private

    # The beat-surging drive of the first sixteen seconds, as first planned all the way to
    # the door; the brake takes over from it at BRAKE_AT.
    def drive(t)
      beat = Music::BEAT
      ph = (t % beat) / beat
      k = t / HALL_AT
      v = V_START + (V_DOOR - V_START) * k
      lunge = t < 0.5 ? 0.0 : LUNGE * v * beat * ((1.0 - Math.exp(-@lunge_k * ph)) / @lunge_k - @lunge_m * ph)
      hermite(k, 0.0, @s_door, V_START * HALL_AT, V_DOOR * HALL_AT) + lunge
    end

    def build_brake
      e = 1e-3
      @brake_s = drive(BRAKE_AT)
      @brake_v = (@brake_s - drive(BRAKE_AT - e)) / e
      @s_glide = @s_hold + CREEP + 0.6 * V_HALL * (GLIDE_AT - PUSH_AT)
    end

    # 28 to 32 s: from V_EXIT the speed climbs for RUSH_RISE seconds and keeps creeping up,
    # scaled so the run ends at the doorway on the last frame.
    def build_rush
      span = END_AT - RUSH_AT
      n = (span * 240).round
      dt = span / n
      shape = Array.new(n + 1) { |j| ease((j * dt) / RUSH_RISE) + RUSH_CLIMB * j * dt }
      base = 0.0
      extra = 0.0
      tab_b = [0.0]
      tab_e = [0.0]
      n.times do |j|
        base += V_EXIT * dt
        extra += (shape[j] + shape[j + 1]) * 0.5 * dt
        tab_b << base
        tab_e << extra
      end
      gain = (@s_end - @s_exit - base) / extra
      @rush_peak = V_EXIT + gain
      @rush_tab = tab_b.each_index.map { |j| @s_exit + tab_b[j] + gain * tab_e[j] }
      @rush_dt = dt
    end

    def ease(x)
      x = x.clamp(0.0, 1.0)
      (x * x * (3 - 2 * x))**1.4
    end

    def rush_at(tau)
      x = tau / @rush_dt
      i = x.floor
      return @rush_tab[-1] if i >= @rush_tab.size - 1

      @rush_tab[i] + (@rush_tab[i + 1] - @rush_tab[i]) * (x - i)
    end

    def build_yaw
      n = (END_AT / DT).round + 2
      target = Array.new(n) { |i| raw_heading(i * DT) }
      (1...n).each do |i|
        d = target[i] - target[i - 1]
        target[i] -= TAU * ((d + Math::PI) / TAU).floor
      end
      a = target[0]
      v = 0.0
      @yaw = Array.new(n)
      @rate = Array.new(n)
      w2 = YAW_W * YAW_W
      n.times do |i|
        @yaw[i] = a
        @rate[i] = v
        acc = w2 * (target[i] - a) - 2.0 * YAW_W * v
        v += acc * DT
        v = YAW_MAX if v > YAW_MAX
        v = -YAW_MAX if v < -YAW_MAX
        a += v * DT
      end
    end

    def raw_heading(t)
      @path.heading(distance_at(t), LOOK_AHEAD, 0.05)
    end
  end
end
