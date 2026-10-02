# frozen_string_literal: true

require_relative "../lib/diem/bitfont"

F = Diem::Bitfont
def check(cond, msg) = (cond or abort("FAIL: #{msg}"))

F::GLYPHS.each do |ch, rows|
  check(rows.size == 7, "#{ch.inspect} has #{rows.size} rows")
  rows.each { |r| check(r.match?(/\A[#.]{5}\z/), "#{ch.inspect} bad row #{r.inspect}") }
end

required = [*"A".."Z", *"0".."9", " ", *%w[. , ! ? ' " - + : ; / ( ) _ & * = # @ < > % $ ♥]]
required.each { |ch| check(F::GLYPHS.key?(ch), "missing #{ch.inspect}") }
check(F.glyph("a") == F.glyph("A"), "lowercase maps to uppercase")
check(F.glyph("~") == F::UNKNOWN, "unknown renders as box")
check(F.glyph("0") != F.glyph("O") && F.glyph("I") != F.glyph("1"), "O/0 and I/1 distinct")

check(F.width("") == 0 && F.width("A") == 5 && F.width("AB") == 11, "width basics")
check(F.width("AB", spacing: 2) == 12, "width spacing")
check(F.width("AB\nABC") == 17, "width uses widest line")

["SCARPE DIEM", "hi!\n0O1I", "A", " "].each do |t|
  pts = F.points(t)
  lit = t.delete("\n").each_char.sum { |c| F.glyph(c).sum { |r| r.count("#") } }
  check(pts.size == lit, "point count for #{t.inspect}")
  check(pts.all? { |x, y| x.between?(0, F.width(t) - 1) && y >= 0 }, "bounds for #{t.inspect}")
  check(pts.uniq.size == pts.size, "duplicates for #{t.inspect}")
  c = F.points_centered(t)
  check(c.size == pts.size, "centered count")
end
check(F.points("A\nA").map(&:last).max == 9 + 6, "line_height")

c = F.points_centered("HELLO")
xs = c.map(&:first)
check((xs.min + xs.max + 1).abs < 5, "centered x roughly symmetric")

text = "GREETINGS TO NICK AND THE SCARPE TEAM!" * 5
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100.times { F.points(text) }
per_char = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) / (100 * text.size)
check(per_char < 0.0001, "too slow: #{per_char * 1e6}us/char")
puts "font selftest ok (#{F::GLYPHS.size} glyphs, #{(per_char * 1e6).round(2)}us/char)"
