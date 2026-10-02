# frozen_string_literal: true

module Diem
  # Classic 5x7 pixel font for demo text. Pure stdlib.
  module Bitfont
    GLYPH_WIDTH = 5
    GLYPH_HEIGHT = 7

    RAW = {
      "A" => %w[.###. #...# #...# ##### #...# #...# #...#],
      "B" => %w[####. #...# #...# ####. #...# #...# ####.],
      "C" => %w[.###. #...# #.... #.... #.... #...# .###.],
      "D" => %w[####. #...# #...# #...# #...# #...# ####.],
      "E" => %w[##### #.... #.... ####. #.... #.... #####],
      "F" => %w[##### #.... #.... ####. #.... #.... #....],
      "G" => %w[.###. #...# #.... #.### #...# #...# .####],
      "H" => %w[#...# #...# #...# ##### #...# #...# #...#],
      "I" => %w[.###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.],
      "J" => %w[..### ...#. ...#. ...#. ...#. #..#. .##..],
      "K" => %w[#...# #..#. #.#.. ##... #.#.. #..#. #...#],
      "L" => %w[#.... #.... #.... #.... #.... #.... #####],
      "M" => %w[#...# ##.## #.#.# #.#.# #...# #...# #...#],
      "N" => %w[#...# ##..# #.#.# #.#.# #..## #...# #...#],
      "O" => %w[.###. #...# #...# #...# #...# #...# .###.],
      "P" => %w[####. #...# #...# ####. #.... #.... #....],
      "Q" => %w[.###. #...# #...# #...# #.#.# #..#. .##.#],
      "R" => %w[####. #...# #...# ####. #.#.. #..#. #...#],
      "S" => %w[.###. #...# #.... .###. ....# #...# .###.],
      "T" => %w[##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..],
      "U" => %w[#...# #...# #...# #...# #...# #...# .###.],
      "V" => %w[#...# #...# #...# #...# #...# .#.#. ..#..],
      "W" => %w[#...# #...# #...# #.#.# #.#.# ##.## #...#],
      "X" => %w[#...# #...# .#.#. ..#.. .#.#. #...# #...#],
      "Y" => %w[#...# #...# .#.#. ..#.. ..#.. ..#.. ..#..],
      "Z" => %w[##### ....# ...#. ..#.. .#... #.... #####],
      "0" => %w[.###. #...# #..## #.#.# ##..# #...# .###.],
      "1" => %w[..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.],
      "2" => %w[.###. #...# ....# ...#. ..#.. .#... #####],
      "3" => %w[.###. #...# ....# ..##. ....# #...# .###.],
      "4" => %w[...#. ..##. .#.#. #..#. ##### ...#. ...#.],
      "5" => %w[##### #.... ####. ....# ....# #...# .###.],
      "6" => %w[.###. #.... #.... ####. #...# #...# .###.],
      "7" => %w[##### ....# ...#. ..#.. ..#.. ..#.. ..#..],
      "8" => %w[.###. #...# #...# .###. #...# #...# .###.],
      "9" => %w[.###. #...# #...# .#### ....# ....# .###.],
      " " => %w[..... ..... ..... ..... ..... ..... .....],
      "." => %w[..... ..... ..... ..... ..... ..... ..#..],
      "," => %w[..... ..... ..... ..... ..... ..#.. .#...],
      "!" => %w[..#.. ..#.. ..#.. ..#.. ..#.. ..... ..#..],
      "?" => %w[.###. #...# ....# ...#. ..#.. ..... ..#..],
      "'" => %w[..#.. ..#.. .#... ..... ..... ..... .....],
      "\"" => %w[.#.#. .#.#. .#.#. ..... ..... ..... .....],
      "-" => %w[..... ..... ..... .###. ..... ..... .....],
      "+" => %w[..... ..#.. ..#.. ##### ..#.. ..#.. .....],
      ":" => %w[..... ..... ..... ..#.. ..... ..... ..#..],
      ";" => %w[..... ..... ..... ..#.. ..... ..#.. .#...],
      "/" => %w[....# ....# ...#. ..#.. .#... #.... #....],
      "(" => %w[...#. ..#.. .#... .#... .#... ..#.. ...#.],
      ")" => %w[.#... ..#.. ...#. ...#. ...#. ..#.. .#...],
      "_" => %w[..... ..... ..... ..... ..... ..... #####],
      "&" => %w[.##.. #..#. #.#.. .#... #.#.# #..#. .##.#],
      "*" => %w[..... ..#.. #.#.# .###. #.#.# ..#.. .....],
      "=" => %w[..... ..... ##### ..... ##### ..... .....],
      "#" => %w[.#.#. .#.#. ##### .#.#. ##### .#.#. .#.#.],
      "@" => %w[.###. #...# #.### #.#.# #.### #.... .###.],
      "<" => %w[...#. ..#.. .#... #.... .#... ..#.. ...#.],
      ">" => %w[.#... ..#.. ...#. ....# ...#. ..#.. .#...],
      "%" => %w[##..# ##..# ...#. ..#.. .#... #..## #..##],
      "$" => %w[..#.. .###. #.#.. .###. ..#.# .###. ..#..],
      "♥" => %w[..... ##.## ##### ##### .###. ..#.. .....]
    }.freeze

    UNKNOWN = %w[..... .###. .#.#. .#.#. .#.#. .###. .....].freeze

    GLYPHS = RAW.transform_values { |rows| rows.map(&:freeze).freeze }.freeze

    # Lit pixels per glyph as [x, y] pairs, built once at load time.
    GLYPH_POINTS = GLYPHS.transform_values do |rows|
      rows.each_with_index.flat_map do |row, y|
        (0...GLYPH_WIDTH).select { |x| row[x] == "#" }.map { |x| [x, y].freeze }
      end.freeze
    end.freeze

    UNKNOWN_POINTS = UNKNOWN.each_with_index.flat_map do |row, y|
      (0...GLYPH_WIDTH).select { |x| row[x] == "#" }.map { |x| [x, y].freeze }
    end.freeze

    def self.key_for(ch)
      GLYPHS.key?(ch) ? ch : ch.upcase
    end

    def self.glyph(ch)
      GLYPHS.fetch(key_for(ch), UNKNOWN)
    end

    def self.glyph_points(ch)
      GLYPH_POINTS.fetch(key_for(ch), UNKNOWN_POINTS)
    end

    # Width of the widest line, in font pixels.
    def self.width(text, spacing: 1)
      text.to_s.split("\n", -1).map { |line| line_width(line, spacing) }.max || 0
    end

    def self.line_width(line, spacing)
      n = line.length
      n.zero? ? 0 : n * GLYPH_WIDTH + (n - 1) * spacing
    end

    def self.height(text, line_height: 9)
      lines = text.to_s.split("\n", -1).length
      (lines - 1) * line_height + GLYPH_HEIGHT
    end

    def self.points(text, spacing: 1, line_height: 9)
      layout(text, spacing, line_height) { |_line_w| 0 }
    end

    def self.points_centered(text, spacing: 1, line_height: 9)
      block_w = width(text, spacing: spacing)
      dy = height(text, line_height: line_height) / 2.0
      layout(text, spacing, line_height) { |line_w| (block_w - line_w) / 2.0 - block_w / 2.0 }
        .map { |x, y| [x, y - dy] }
    end

    def self.layout(text, spacing, line_height)
      out = []
      text.to_s.split("\n", -1).each_with_index do |line, row|
        x0 = yield(line_width(line, spacing))
        emit_line(out, line, x0, row * line_height, spacing)
      end
      out
    end

    def self.emit_line(out, line, x0, y0, spacing)
      pen = x0
      line.each_char do |ch|
        glyph_points(ch).each { |gx, gy| out << [pen + gx, y0 + gy] }
        pen += GLYPH_WIDTH + spacing
      end
    end

    private_class_method :key_for, :line_width, :layout, :emit_line
  end
end
