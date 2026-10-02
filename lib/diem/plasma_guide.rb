# frozen_string_literal: true

# Where the Plasma scene's loupe looks. A new bell note or snare always pulls it to the fresh
# ring; otherwise it rides whatever ring (a note's, or a crest of the two ripples that always
# fill the picture) shows the most light-to-shadow change inside its nine pixels, reading the
# real height field back from the scene, and it keeps its box out of the formula panel and
# the loupe's own column.
#
# It is stepped at a fixed 1/120 s from the scene's first tick (what it rides, and a spring
# that eases the box across when that changes), and every step is kept, so any t, a seek or a
# recording frame, lands on exactly the same picture.
module Diem
  class PlasmaGuide
    TICKS = 120.0    # steps per second
    OMEGA = 17.0     # spring rate: the box settles on a new ring in about 0.3 s
    FRESH = 0.1      # seconds: a note this new always wins
    KEEP = 9         # light levels of contrast that are worth staying on
    BETTER = 4       # a rival must beat the current contrast by this much to take over
    SEARCH = 6       # ticks between searches while the current spot is dull
    ANGLES = 72      # coarse steps tried around a ring
    HOME = 50.0      # framebuffer pixels: the background crest nearest this radius is tried
    GOLD = (Math.sqrt(5) - 1) / 2
    PROBE = [[0, 0], [-4, -4], [4, -4], [-4, 4], [4, 4], [0, -4], [0, 4], [-4, 0], [4, 0]].freeze

    Ring = Struct.new(:time, :cx, :cy, :r0, :speed, :life, :theta, :peak, :bell)
    Step = Struct.new(:cur, :ox, :oy, :vx, :vy, :raw, :searched)

    # fw, fh: framebuffer pixels; sc: screen pixels per framebuffer pixel; k: field units per
    # framebuffer pixel; blocked: screen rects [x, y, w, h] the box must stay clear of;
    # field: answers snapshot(t) and light(snapshot, x, y) (see the Plasma scene).
    def initialize(fw, fh, sc, k, blocked, margin, half, field)
      @fw = fw
      @fh = fh
      @sc = sc
      @k = k
      @blocked = blocked.map { |x, y, w, h| [x - margin, y - margin, x + w + margin, y + h + margin] }
      @edge = margin * 0.6
      @half = half
      @field = field
      @goal = [0.42 * fw, 0.4 * fh]
      @rings = []
      @steps = []
    end

    # drops: bell Drops, shocks: snare Drops (time, x, y as shares).
    def plan(drops, shocks, bell_life, shock_life)
      @rings = drops.map { |d| ring(d, 3.0, 62.0, bell_life, 0.45, true) } +
        shocks.map { |s| ring(s, 4.0, 150.0, shock_life, 0.3, false) }
      @rings.sort_by!(&:time)
      @steps = []
    end

    # Steps ahead to time t now (at build), so a seek or a mid-scene start never stalls.
    # Yields every few dozen steps, for the loader to breathe.
    def prepare(t)
      (0..(t * TICKS).ceil).step(32) do |tick|
        step(tick)
        yield if block_given?
      end
    end

    # The pixel (framebuffer coordinates, Floats) the loupe should centre on at time t.
    def target(t)
      st = step([(t * TICKS).floor, 0].max)
      here = (st.cur && spot(st.cur, t)) || st.raw
      [here[0] + st.ox, here[1] + st.oy]
    end

    private

    # freq: the packet's wavenumber. The box sits on its outer peak, where the slope turns
    # over, so the nine pixels run from lit to shadow.
    def ring(d, r0, speed, life, freq, bell)
      cx = d.x * @fw
      cy = d.y * @fh
      Ring.new(d.time, cx, cy, r0, speed, life, Math.atan2(@goal[1] - cy, @goal[0] - cx), Math::PI / (2 * freq), bell)
    end

    def step(tick)
      n = @steps.size
      while n <= tick
        @steps << advance(n, n.zero? ? nil : @steps[n - 1])
        n += 1
      end
      @steps[tick]
    end

    # One tick on: choose what to ride, then spring the offset that carries the box across.
    def advance(tick, prev)
      t = tick / TICKS
      sn = @field.snapshot(t)
      cur, searched = choose(tick, t, sn, prev)
      raw = (cur && spot(cur, t, sn)) || (prev ? prev.raw : @goal)
      raw = raw.first(2)
      return Step.new(cur, 0.0, 0.0, 0.0, 0.0, raw, searched) unless prev

      ox = prev.ox
      oy = prev.oy
      if cur != prev.cur
        old = (prev.cur && spot(prev.cur, t, sn)) || prev.raw
        ox += old[0] - raw[0]
        oy += old[1] - raw[1]
      end
      dt = 1.0 / TICKS
      vx = prev.vx + (-OMEGA * OMEGA * ox - 2 * OMEGA * prev.vx) * dt
      vy = prev.vy + (-OMEGA * OMEGA * oy - 2 * OMEGA * prev.vy) * dt
      Step.new(cur, ox + vx * dt, oy + vy * dt, vx, vy, raw, searched)
    end

    # Returns [choice, tick of the last search]. A choice is [:ring, index, lobe] or
    # [:base, which, crest, lobe]; lobe +1 is the down-right side of the circle, -1 up-left.
    def choose(tick, t, sn, prev)
      last = prev ? prev.searched : -SEARCH
      cur = prev&.cur
      fresh = fresh_ring(t, sn)
      return [fresh, last] if fresh && (cur.nil? || cur[0] != :ring || cur[1] != fresh[1])

      pt = cur && alive?(cur, t) && spot(cur, t, sn)
      have = pt ? contrast(sn, pt) : -1
      return [cur, last] if have >= KEEP || (pt && tick - last < SEARCH)

      best = nil
      best_c = have + BETTER
      candidates(t, sn).each do |c|
        q = spot(c, t, sn)
        next unless q

        v = contrast(sn, q)
        next if v < best_c

        best = c
        best_c = v
      end
      [best || (pt ? cur : nil), tick]
    end

    # The newest bell ring under FRESH seconds old, on its better side.
    def fresh_ring(t, sn)
      i = @rings.rindex { |rg| rg.bell && rg.time <= t && t - rg.time < FRESH }
      return nil unless i

      [-1, 1].map { |lobe| [:ring, i, lobe] }.select { |c| spot(c, t, sn) }
        .max_by { |c| spot(c, t, sn)[3] }
    end

    def candidates(t, sn)
      out = []
      @rings.each_index do |i|
        rg = @rings[i]
        next if t < rg.time || t - rg.time >= rg.life

        out << [:ring, i, 1] << [:ring, i, -1]
      end
      sn.base.each_with_index do |(_, _, kf, ph), j|
        n = ((HOME * kf - Math::PI / 2 - ph) / (2 * Math::PI)).round
        n += 1 if (Math::PI / 2 + 2 * Math::PI * n + ph) / kf < 12.0
        out << [:base, j, n, 1] << [:base, j, n, -1]
      end
      out
    end

    def alive?(cur, t)
      return true unless cur[0] == :ring

      rg = @rings[cur[1]]
      t >= rg.time && t - rg.time < rg.life
    end

    # How many light levels the box's nine-pixel square spans, read from the real field.
    def contrast(sn, pt)
      px = pt[0].round.clamp(5, @fw - 5)
      py = pt[1].round.clamp(5, @fh - 5)
      lo = 99
      hi = -1
      PROBE.each do |dx, dy|
        l = @field.light(sn, px + dx, py + dy)
        lo = l if l < lo
        hi = l if l > hi
      end
      hi - lo
    end

    def spot(cur, t, sn = nil)
      if cur[0] == :ring
        rg = @rings[cur[1]]
        age = [t - rg.time, 0.0].max
        point(rg.cx, rg.cy, (rg.r0 + rg.speed * age + rg.peak) / @k, rg.theta, cur[2])
      else
        cx, cy, kf, ph = (sn || @field.snapshot(t)).base[cur[1]]
        r = (Math::PI / 2 + 2 * Math::PI * cur[2] + ph) / kf
        return nil if r < 6.0

        point(cx, cy, r, Math.atan2(@goal[1] - cy, @goal[0] - cx), cur[3])
      end
    end

    # The best legal point on a circle, as [x, y, lobe, score]: on the light's diagonal, away
    # from the dark edges, leaning toward theta, on the given side. A coarse scan finds the
    # best step, then a golden-section search inside the legal part of its neighbourhood
    # finds the exact angle, so the point slides instead of stepping.
    def point(cx, cy, r, theta, lobe)
      step = 2 * Math::PI / ANGLES
      jb = nil
      best_s = -9.0
      ANGLES.times do |j|
        s = score(cx, cy, r, theta, j * step, lobe)
        next unless s && s > best_s

        best_s = s
        jb = j
      end
      return nil unless jb

      a = jb * step
      lo = edge_of(cx, cy, r, theta, a, a - step, lobe)
      hi = edge_of(cx, cy, r, theta, a, a + step, lobe)
      a = golden(cx, cy, r, theta, lo, hi, lobe)
      s = score(cx, cy, r, theta, a, lobe) || best_s
      [cx + r * Math.cos(a), cy + r * Math.sin(a), lobe, s]
    end

    def lobe_of(a) = Math.cos(a - Math::PI / 4) >= 0 ? 1 : -1

    # Larger is a better place for the box at angle a, or nil where it may not go.
    def score(cx, cy, r, theta, a, lobe)
      return nil if lobe_of(a) != lobe

      x = cx + r * Math.cos(a)
      y = cy + r * Math.sin(a)
      return nil unless legal?(x, y)

      ex = (2.0 * x / @fw - 1.0).abs
      ey = (2.0 * y / @fh - 1.0).abs
      e = ex > ey ? ex : ey
      al = Math.cos(a - Math::PI / 4)
      al * al * (1.0 - 0.85 * e * e * e) + 0.25 * Math.cos(a - theta)
    end

    # From a legal angle toward another, the last legal angle (bisection).
    def edge_of(cx, cy, r, theta, ok, toward, lobe)
      return toward if score(cx, cy, r, theta, toward, lobe)

      8.times do
        mid = (ok + toward) / 2
        if score(cx, cy, r, theta, mid, lobe)
          ok = mid
        else
          toward = mid
        end
      end
      ok
    end

    def golden(cx, cy, r, theta, lo, hi, lobe)
      a = hi - GOLD * (hi - lo)
      b = lo + GOLD * (hi - lo)
      fa = score(cx, cy, r, theta, a, lobe) || -9.0
      fb = score(cx, cy, r, theta, b, lobe) || -9.0
      12.times do
        if fa > fb
          hi = b
          b = a
          fb = fa
          a = hi - GOLD * (hi - lo)
          fa = score(cx, cy, r, theta, a, lobe) || -9.0
        else
          lo = a
          a = b
          fa = fb
          b = lo + GOLD * (hi - lo)
          fb = score(cx, cy, r, theta, b, lobe) || -9.0
        end
      end
      (lo + hi) / 2
    end

    def legal?(px, py)
      x0 = (px - @half) * @sc
      x1 = (px + @half + 1) * @sc
      y0 = (py - @half) * @sc
      y1 = (py + @half + 1) * @sc
      return false if x0 < @edge || y0 < @edge || x1 > @fw * @sc - @edge || y1 > @fh * @sc - @edge

      @blocked.none? { |bx0, by0, bx1, by1| x0 < bx1 && x1 > bx0 && y0 < by1 && y1 > by0 }
    end
  end
end
