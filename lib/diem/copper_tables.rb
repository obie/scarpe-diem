# frozen_string_literal: true

module Diem
  # Precomputed data for the Copper scene: the scroller text as column bitmasks, the paths for
  # every column pattern, a rainbow table and the lead melody's pitch curve.
  module CopperTables
    # The text ends on HELLO OBIE, and the five extra spaces before it hold the phrase back so it
    # sits whole and centred on screen from about 14.7 s until the scroller shatters at 15.5 s.
    TEXT = "GREETINGS TO NICK AND THE SCARPE TEAM ... _WHY THE LUCKY STIFF, WHO GAVE US SHOES ...      " \
           "HELLO OBIE   "

    # Words that shine gold instead of rainbow.
    GOLDEN = ["NICK", "_WHY THE LUCKY STIFF", "SHOES", "OBIE"].freeze

    HUES = 512

    module_function

    # One Integer per font column: bit r is lit when row r of that column is. The text is set
    # proportionally: each glyph keeps only its lit columns, then one blank; a space is three.
    def columns
      layout unless @columns
      @columns
    end

    # The first column of each character of TEXT, plus one past the end.
    def starts
      layout unless @starts
      @starts
    end

    def layout
      cols = []
      starts = []
      TEXT.each_char do |ch|
        starts << cols.size
        if ch == " "
          cols.push(0, 0, 0)
          next
        end
        rows = Bitfont.glyph(ch)
        masks = Array.new(Bitfont::GLYPH_WIDTH) do |x|
          (0...Bitfont::GLYPH_HEIGHT).sum { |r| rows[r][x] == "#" ? 1 << r : 0 }
        end
        lit = masks.each_index.select { |x| masks[x].positive? }
        cols.concat(masks[lit.first..lit.last]) unless lit.empty?
        cols << 0
      end
      starts << cols.size
      @columns = cols.freeze
      @starts = starts.freeze
    end

    # True for each text column inside a golden word.
    def golden
      @golden ||= begin
        flags = Array.new(columns.size, false)
        GOLDEN.each do |word|
          from = 0
          while (i = TEXT.index(word, from))
            (starts[i]...(starts[i + word.size] - 1)).each { |c| flags[c] = true }
            from = i + word.size
          end
        end
        flags.freeze
      end
    end

    # The column where a phrase of TEXT starts and ends, for timing the choreography.
    def span_of(phrase)
      i = TEXT.index(phrase)
      [starts[i], starts[i + phrase.size] - 1]
    end

    # 1.0 inside a golden word, ramping to 0 over the six columns either side, so the scroller
    # can flatten its wave there without a step at the word's edges.
    def flat
      @flat ||= begin
        g = golden
        reach = 6
        Array.new(g.size) do |c|
          lo = [c - reach, 0].max
          hi = [c + reach, g.size - 1].min
          [(lo..hi).count { |k| g[k] }.fdiv(reach + 1), 1.0].min
        end.freeze
      end
    end

    # The squares of one column as path commands. dir < 0 mirrors and squashes it (the floor
    # reflection). spread > 1 pulls the rows apart and knocks them sideways (the closing burst). Two zero-area slivers
    # pin the path's box to the full seven rows, so a gradient fill always spans the letter.
    def column_path(mask, size, pitch, dir, spread = 1.0)
      @paths ||= {}
      key = [mask, size.round(2), pitch.round(3), dir, spread]
      @paths[key] ||= begin
        sy = dir.abs
        inset = (pitch - size) * 0.5
        row_pitch = pitch * spread
        cmds = []
        span = (7 * row_pitch * sy).round(2)
        cmds << ["move_to", 0, 0] << ["line_to", 0.01, 0] << ["line_to", 0, 0]
        7.times do |r|
          next if mask[r].zero?

          row = dir.positive? ? r : 6 - r
          y0 = ((row * row_pitch + inset) * sy).round(2)
          y1 = ((row * row_pitch + inset + size) * sy).round(2)
          drift = (noise(r * 7 + 3) - 0.5) * pitch * (spread - 1.0) * 2.2
          x0 = (inset + drift).round(2)
          x1 = (inset + drift + size).round(2)
          cmds << ["move_to", x0, y0] << ["line_to", x1, y0] << ["line_to", x1, y1] << ["line_to", x0, y1]
        end
        cmds << ["move_to", 0, span] << ["line_to", 0.01, span] << ["line_to", 0, span]
        cmds.freeze
      end
    end

    # Saturated rainbow, h in 0...1, as [r, g, b] Integers.
    def hue(h)
      table[(h * HUES).to_i % HUES]
    end

    # The same wheel at full saturation, for the copper bars.
    def vivid(h)
      vivid_table[(h * HUES).to_i % HUES]
    end

    def vivid_table
      @vivid_table ||= wheel(0, 255)
    end

    def table
      @table ||= wheel(40, 215)
    end

    def wheel(floor, span)
      Array.new(HUES) do |i|
        x = i.fdiv(HUES) * 6
        k = x.floor
        f = x - k
        rgb = case k
              when 0 then [1, f, 0]
              when 1 then [1 - f, 1, 0]
              when 2 then [0, 1, f]
              when 3 then [0, 1 - f, 1]
              when 4 then [f, 0, 1]
              else [1, 0, 1 - f]
              end
        rgb.map { |v| (floor + span * v).round }.freeze
      end.freeze
    end

    GOLD = [255, 196, 64].freeze

    def golden?(c)
      c >= 0 && c < golden.size && golden[c]
    end

    # Rainbow for ordinary words, but never through the orange-yellow band the gold lives in.
    def column_colour(c, h)
      golden?(c) ? gold(h) : hue((0.2 + h * 0.85) % 1.0)
    end

    def gold(h)
      s = 0.5 + 0.5 * Math.sin(h * Math::PI * 6)
      [255, (150 + 70 * s).round, (20 + 70 * s).round]
    end

    # A repeatable 0...1 value for an Integer.
    def noise(n)
      ((n * 2_654_435_761) % 4_294_967_296) / 4_294_967_296.0
    end

    def lerp(a, b, k)
      [(a[0] + (b[0] - a[0]) * k).round, (a[1] + (b[1] - a[1]) * k).round, (a[2] + (b[2] - a[2]) * k).round]
    end

    def shade(c, k)
      [(c[0] * k).round.clamp(0, 255), (c[1] * k).round.clamp(0, 255), (c[2] * k).round.clamp(0, 255)]
    end

    def mix_white(c, k)
      k = k.clamp(0.0, 1.0)
      [(c[0] + (255 - c[0]) * k).round, (c[1] + (255 - c[1]) * k).round, (c[2] + (255 - c[2]) * k).round]
    end

    # The lead line's pitch at song time t, gliding 0.1 s between notes (MIDI, fractional).
    def lead_pitch(t)
      times, notes = lead
      return 74.0 if times.empty?

      i = (times.bsearch_index { |x| x > t } || times.size) - 1
      return notes.first.to_f if i.negative?

      prev = i.zero? ? notes[0] : notes[i - 1]
      g = ((t - times[i]) / 0.1).clamp(0.0, 1.0)
      g = g * g * (3 - 2 * g)
      prev + (notes[i] - prev) * g
    end

    def lead
      @lead ||= begin
        evs = Music.score[:lead] || []
        [evs.map { |e| e[0] * Music::STEP }.freeze, evs.map { |e| e[2] }.freeze]
      end
    end
  end
end
