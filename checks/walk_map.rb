# frozen_string_literal: true

# Plain-Ruby check of the walk: every lost shoe stands on reachable floor, a body driven by
# keys alone (through the real WalkPlayer, collisions, door and all) can fetch all seven, a
# long random walk never ends up inside a wall, and key presses add up the way they should.
#   ruby checks/walk_map.rb
require_relative "../lib/diem/raycaster"
require_relative "../lib/diem/maze_map"
require_relative "../lib/diem/walk_player"

M = Diem::MazeMap
H = Diem::WalkHunt
SHOES = H::SHOES
START = H::START
TAKE = H::TAKE
DT = 1.0 / 120
rc = Diem::Raycaster.new(M::ROWS, legend: M::LEGEND, open: M::OPEN, round: M::ROUND, doors: [M::DOOR])
gem = [*M::HALL_CENTRE, H::GEM_R]
fails = []

walkable = lambda do |x, y|
  rc.inside?(x, y) && [0, M::PILLAR, M::DOOR].include?(rc.cells[y * rc.cols + x])
end
# the driver plans round the columns (it could squeeze past them, but it steers like a brick)
plannable = lambda do |x, y|
  rc.inside?(x, y) && [0, M::DOOR].include?(rc.cells[y * rc.cols + x])
end

def bfs(rc, walkable, from, to)
  prev = { from => nil }
  q = [from]
  until q.empty?
    c = q.shift
    break if c == to

    [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
      n = [c[0] + dx, c[1] + dy]
      next if prev.key?(n) || !walkable.call(*n)

      prev[n] = c
      q << n
    end
  end
  return nil unless prev.key?(to)

  path = [to]
  path << prev[path.last] while prev[path.last]
  path.reverse
end

# 1. every shoe on floor a body fits on, connected to the start
probe = Diem::WalkPlayer.new(rc, blockers: [gem])
SHOES.each do |x, y|
  fails << "shoe #{[x, y]} is not on floor" unless walkable.call(x.floor, y.floor)
  fails << "shoe #{[x, y]}: a body cannot stand on it" if probe.blocked?(x, y)
  fails << "shoe #{[x, y]} is not connected to the start" unless bfs(rc, walkable, [2, 10], [x.floor, y.floor])
end

# 2. drive there by keys alone: aim down the BFS path, turn with left/right, walk with up
pl = Diem::WalkPlayer.new(rc, blockers: [gem])
pl.reset(*START)
t = 0.0
got = []
order = SHOES.dup
until order.empty? || t > 600
  target = order.min_by { |x, y| (bfs(rc, plannable, [pl.x.floor, pl.y.floor], [x.floor, y.floor]) || []).size }
  path = bfs(rc, plannable, [pl.x.floor, pl.y.floor], [target[0].floor, target[1].floor])
  stuck_at = t
  last = [pl.x, pl.y]
  while t < 600
    cell = [pl.x.floor, pl.y.floor]
    i = path.index(cell)
    path = bfs(rc, plannable, cell, [target[0].floor, target[1].floor]) if i.nil?
    i ||= 0
    wx, wy = i + 1 < path.size ? [path[i + 1][0] + 0.5, path[i + 1][1] + 0.5] : target
    # step round the great gem rather than into it
    if Math.hypot(wx - gem[0], wy - gem[1]) < 1.0
      wx += 1.2
    end
    err = Math.atan2(wy - pl.y, wx - pl.x) - pl.ang
    err = (err + Math::PI) % (2 * Math::PI) - Math::PI
    pl.press(err.positive? ? :right : :left, t) if err.abs > 0.08
    pl.press(:fwd, t) if err.abs < 0.6
    pl.step(t, DT)
    t += DT
    if Math.hypot(pl.x - target[0], pl.y - target[1]) < TAKE
      got << [target, t.round(1)]
      order.delete(target)
      break
    end
    if t - stuck_at > 3.0
      fails << "stuck near #{[pl.x.round(2), pl.y.round(2)]} heading for #{target}" if Math.hypot(pl.x - last[0], pl.y - last[1]) < 0.2
      stuck_at = t
      last = [pl.x, pl.y]
      break if fails.size > 5
    end
  end
  break if fails.size > 5
end
fails << "fetched only #{got.size} of #{SHOES.size}" if got.size < SHOES.size
puts "fetched #{got.size}/#{SHOES.size} by keys in #{t.round(1)} s: #{got.map { |(x, y), s| "#{[x, y]}@#{s}" }.join(' ')}"

# 3. a long random walk with mashed keys never puts the body inside anything
rnd = Random.new(7)
pl.reset(*START)
t = 0.0
acts = %i[fwd fwd fwd back left right sleft sright]
worst = 1.0
120_000.times do |n|
  pl.press(acts[rnd.rand(acts.size)], t) if (n % 9).zero?
  pl.step(t, DT, rnd.rand < 0.01 ? rnd.rand * 2 - 1 : nil)
  t += DT
  x = pl.x
  y = pl.y
  k = rc.cells[y.floor * rc.cols + x.floor]
  if ![0, M::PILLAR, M::DOOR].include?(k)
    fails << "inside a wall at #{[x, y]}"
    break
  end
  if k == M::DOOR && pl.door_open < Diem::WalkPlayer::DOOR_PASS - 0.2
    fails << "inside a shut door at #{[x, y]}"
    break
  end
  # clearance to every solid box around
  (-1..1).each do |oy|
    (-1..1).each do |ox|
      cx = x.floor + ox
      cy = y.floor + oy
      kk = rc.inside?(cx, cy) ? rc.cells[cy * rc.cols + cx] : 1
      next if [0, M::PILLAR, M::DOOR].include?(kk)

      d = Math.hypot(x - x.clamp(cx, cx + 1.0), y - y.clamp(cy, cy + 1.0))
      worst = d if d < worst
    end
  end
end
fails << "a body got #{worst.round(3)} from a wall (radius #{Diem::WalkPlayer::RADIUS})" if worst < Diem::WalkPlayer::RADIUS - 1e-6
puts "random walk: #{(t / 60).round(1)} min, closest approach to a wall #{worst.round(3)}"

# 4. presses: more taps never move less than one, and a held key (a press, the OS delay,
# then repeats) keeps its speed once the delay has been seen, whatever the delay
drive = lambda do |pl, presses, act, secs|
  pl.reset(48.5, 14.5, 0.0) # the hall's open floor
  x0 = pl.x
  a0 = pl.ang
  q = presses.sort
  t = 0.0
  low = 9.0
  up = false
  while t < secs
    pl.press(act, q.shift) while q.first && q.first <= t
    pl.step(t, DT)
    t += DT
    up ||= pl.speed > 0.9 * Diem::WalkPlayer::WALK
    low = pl.speed if up && t < presses.max && pl.speed < low
  end
  [pl.x - x0, (pl.ang - a0).abs, low]
end
taps = Diem::WalkPlayer.new(rc)
one = drive.call(taps, [0.0], :fwd, 3)
[[0.0, 0.0, 0.0], [0.0, 0.05, 0.1], [0.0, 0.2]].each do |ts|
  more = drive.call(taps, ts, :fwd, 3)
  fails << "taps at #{ts} walk #{more[0].round(2)}, less than one tap's #{one[0].round(2)}" if more[0] < one[0] - 1e-6
end
turn_one = drive.call(taps, [0.0], :left, 3)
turn_two = drive.call(taps, [0.0, 0.1], :left, 3)
fails << "a double tap of left turns less than one" if turn_two[1] < turn_one[1] - 1e-6
# and a tap stays small enough to aim with in a one-cell corridor, before and after the
# OS delay has been learned
fails << "one tap of left turns #{turn_one[1].round(2)} rad, over 0.7" if turn_one[1] > 0.7
fails << "one tap of up walks #{one[0].round(2)} cells, over 1.5" if one[0] > 1.5
learned = Diem::WalkPlayer.new(rc)
drive.call(learned, [0.0, 0.375] + Array.new(30) { |k| 0.408 + k * 0.033 }, :left, 3)
turn_learned = drive.call(learned, [0.0], :left, 3)
fails << "after learning a 0.375 s delay, one tap turns #{turn_learned[1].round(2)} rad, over 0.7" if turn_learned[1] > 0.7
[0.25, 0.375, 0.5, 0.75, 1.0].each do |delay|
  held = Diem::WalkPlayer.new(rc)
  keys = [0.0] + Array.new(60) { |k| delay + k * 0.033 }
  drive.call(held, keys, :fwd, 4) # the first hold teaches it the delay
  low = drive.call(held, keys, :fwd, 4)[2]
  fails << "held with a #{delay} s delay, speed dips to #{low.round(2)}" if low < 0.8 * Diem::WalkPlayer::WALK
end
puts "presses: one tap #{one[0].round(2)} cells, #{turn_one[1].round(2)} rad (#{turn_learned[1].round(2)} once the delay is learned); held speed kept for delays 0.25 to 1.0 s"

if fails.empty?
  puts "walk map: ok"
else
  puts fails.first(10)
  exit 1
end
