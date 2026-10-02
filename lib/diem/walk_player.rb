# frozen_string_literal: true

require_relative "maze_map"

# The body you walk the WOLFENSHOES maze in: position, heading and the speeds that carry them,
# stepped at a fixed 1/120 s. Keys arrive as separate presses (a held key is the OS repeating
# it after a delay), so every press is an impulse: it holds its action at full strength for a
# moment, then lets it fall away over DECAY seconds unless another press refreshes it, and the
# speeds chase those targets. Held, a key gives smooth continuous motion; tapped, a short step.
# A first press runs at reduced strength until a repeat inside its hold shows the key is held
# (Doom's slow turn for the first tics), so a tap is a small correction you can aim with and
# a hold ramps up naturally to full speed.
# The hall door slides open as you come near it and shut once you are well away. Plain Ruby
# with no drawing, so a check can drive it.
module Diem
  # Where the seven lost shoes hide (cell centres: four dead ends and a brick room's back door
  # in the maze, a far corner of the hall, the white room at the end of the last corridor),
  # where you start (the autopilot's own first spot, facing north) and how close is a find.
  module WalkHunt
    SHOES = [[7.5, 4.5], [13.5, 1.5], [14.5, 10.5], [37.5, 9.5], [56.5, 8.5], [41.5, 27.5], [91.5, 17.5]].freeze
    START = [2.5, 10.35, -Math::PI / 2].freeze
    TAKE = 0.48
    GEM_R = 0.55 # the great gem in the hall stands in the way
  end

  class WalkPlayer
    M = MazeMap
    TAU = Math::PI * 2

    RADIUS = 0.22     # the body, in cells
    WALK = 3.1        # cells per second, forward
    BACK = 2.2
    SIDE = 2.4        # strafing
    MOUSE = 3.3       # walking with the button held
    TURN = 2.5        # radians per second at full turn
    MOUSE_TURN = 2.9
    DECAY = 0.35      # an impulse fades over this long
    FIRST_HOLD = 0.5  # a first press holds this long, bridging the OS delay before it repeats
    REPEAT_HOLD = 0.08
    RUN_GAP = 1.3     # a press this long after the last starts a new run
    DELAY_RANGE = (0.2..1.25) # what an OS key-repeat delay can be
    FAST = 0.16       # repeats come at least this quickly once they start
    DELAY_PAD = 0.06  # the first hold outlasts the learned delay by this much
    SPEED_TAU = 0.09  # how quickly speed follows its target
    TURN_TAU = 0.07
    STRIDE = 2.0      # cells per head-bob cycle (two footfalls)
    DOOR_NEAR = 2.6   # the hall door opens inside this distance
    DOOR_FAR = 3.4    # and closes beyond this one
    DOOR_TIME = 0.38
    DOOR_PASS = 0.85  # how open it must be to walk through

    TAP_TURN = 0.35   # strength of a first press, until a repeat confirms a hold
    TAP_MOVE = 0.6
    TURNS = %i[left right].freeze

    OPPOSITE = { fwd: :back, back: :fwd, left: :right, right: :left, sleft: :sright, sright: :sleft }.freeze

    attr_reader :x, :y, :ang, :speed, :side, :turn, :odo, :bob, :gait, :door_open

    # rc: the Raycaster of the level. blockers: [[x, y, radius], ...] round things that are
    # not walls (the great gem).
    def initialize(rc, blockers: [])
      @rc = rc
      @blockers = blockers
      @door_x = M::DOOR_CELL[0] + 0.5
      @door_y = M::DOOR_CELL[1] + 0.5
      reset(2.5, 10.4, -Math::PI / 2)
    end

    def reset(x, y, ang)
      @x = x
      @y = y
      @ang = ang
      @speed = @side = @turn = 0.0
      @odo = @bob = @gait = 0.0
      @door_k = 0.0
      @door_open = 0.0
      @press = {}
      @until = {}
      @run = {}
      @tap = {}
    end

    # How long a first press holds: FIRST_HOLD until the OS's key-repeat delay has been seen,
    # then that delay and a little more. Learned across resets, as the OS setting does not move.
    def first_hold = @first_hold || FIRST_HOLD

    # One press of an action (:fwd :back :left :right :sleft :sright) at time t. A press can
    # only lengthen the full-strength hold an action already has, never cut it short, so
    # quick taps add up and a held key's repeats carry on its first press. A run is a first
    # press and its repeats: when its second press comes after a pause (the OS delay) and its
    # third straight after (the repeats), that pause is the delay, and later first presses
    # hold just past it.
    def press(action, t)
      last = @press[action]
      gap = last && t - last
      run = @run[action]
      if gap.nil? || gap > RUN_GAP
        run = @run[action] = [1, nil]
        hold = first_hold
        @tap[action] = true unless (@until[action] || -1.0e9) > t
      else
        @tap.delete(action) if gap < first_hold + 0.05 # a repeat inside the hold: held
        run[0] += 1
        run[1] = gap if run[0] == 2
        @first_hold = run[1] + DELAY_PAD if run[0] == 3 && gap < FAST && DELAY_RANGE.cover?(run[1])
        hold = REPEAT_HOLD
        hold = gap * 1.6 if run[0] > 2 && gap * 1.6 > hold && gap < 0.3 # slow repeats bridge themselves
      end
      @press[action] = t
      ends = t + hold
      @until[action] = ends if (@until[action] || -1.0e9) < ends
      opp = OPPOSITE[action]
      @press.delete(opp)
      @until.delete(opp)
      @run.delete(opp)
      @tap.delete(opp)
    end

    # Strength 0..1 of an action at time t.
    def drive(action, t)
      ends = @until[action]
      return 0.0 unless ends

      full = @tap[action] ? (TURNS.include?(action) ? TAP_TURN : TAP_MOVE) : 1.0
      return full if t < ends

      k = 1.0 - (t - ends) / DECAY
      k <= 0.0 ? 0.0 : full * k * k * (3.0 - 2.0 * k)
    end

    # Advances by dt from time t. mouse: nil, or the pointer's horizontal offset from the
    # window centre (-1..1) while button 1 is held.
    def step(t, dt, mouse = nil)
      fwd = WALK * drive(:fwd, t) - BACK * drive(:back, t)
      yaw = TURN * (drive(:right, t) - drive(:left, t))
      sv = SIDE * (drive(:sright, t) - drive(:sleft, t))
      if mouse
        fwd = MOUSE if fwd < MOUSE
        off = mouse.clamp(-1.0, 1.0)
        yaw += MOUSE_TURN * off * (0.3 + 0.7 * off.abs)
      end
      k = 1.0 - Math.exp(-dt / SPEED_TAU)
      @speed += (fwd - @speed) * k
      @side += (sv - @side) * k
      @turn += (yaw - @turn) * (1.0 - Math.exp(-dt / TURN_TAU))
      @ang += @turn * dt

      dx = Math.cos(@ang)
      dy = Math.sin(@ang)
      mx = (dx * @speed - dy * @side) * dt
      my = (dy * @speed + dx * @side) * dt
      ox = @x
      oy = @y
      nx = @x + mx
      @x = nx unless blocked?(nx, @y)
      ny = @y + my
      @y = ny unless blocked?(@x, ny)
      moved = Math.sqrt((@x - ox)**2 + (@y - oy)**2)
      @odo += moved
      @bob = (@bob + moved * TAU / STRIDE) % (TAU * 64)
      g = (moved / dt / WALK).clamp(0.0, 1.0)
      @gait += (g - @gait) * (1.0 - Math.exp(-dt / 0.15))
      step_door(dt)
    end

    # True when a body at (x, y) would overlap a wall, a column, a shut door or a blocker.
    def blocked?(x, y)
      r = RADIUS
      rc = @rc
      cols = rc.cols
      cells = rc.cells
      ((y - r).floor..(y + r).floor).each do |cy|
        ((x - r).floor..(x + r).floor).each do |cx|
          return true unless rc.inside?(cx, cy)

          k = cells[cy * cols + cx]
          next if k.zero?

          if k == M::PILLAR
            ex = x - (cx + 0.5)
            ey = y - (cy + 0.5)
            rr = M::ROUND[M::PILLAR] + r
            return true if ex * ex + ey * ey < rr * rr
            next
          end
          next if k == M::DOOR && @door_open >= DOOR_PASS

          qx = x.clamp(cx.to_f, cx + 1.0)
          qy = y.clamp(cy.to_f, cy + 1.0)
          return true if (x - qx)**2 + (y - qy)**2 < r * r
        end
      end
      @blockers.any? { |bx, by, br| (x - bx)**2 + (y - by)**2 < (br + r)**2 }
    end

    private

    def step_door(dt)
      d = Math.sqrt((@x - @door_x)**2 + (@y - @door_y)**2)
      if d < DOOR_NEAR
        @door_k += dt / DOOR_TIME
      elsif d > DOOR_FAR
        @door_k -= dt / DOOR_TIME
      end
      @door_k = @door_k.clamp(0.0, 1.0)
      @door_open = 1.0 - (1.0 - @door_k)**2.2
    end
  end
end
