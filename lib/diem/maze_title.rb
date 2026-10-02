# frozen_string_literal: true

# The WOLFENSHOES 3D title card and the pickup counter, both in the 5x7 Bitfont. Glyph rows are
# merged into runs, so a letter costs a few rects instead of a dozen.
module Diem
  class MazeTitle
    CHROME = [[255, 255, 255], [196, 236, 255], [120, 196, 255], [36, 28, 92],
              [255, 140, 210], [255, 70, 150], [190, 24, 104]].freeze
    GOLD = [[255, 246, 200], [255, 226, 130], [255, 201, 77], [70, 22, 96],
            [255, 150, 60], [255, 106, 61], [200, 50, 40]].freeze

    # [text, pixel size in u, centre y as a share of h, row colours (nil = flat ink)]
    LINES = [["WOLFENSHOES", 11.5, 0.30, CHROME], ["3D", 21.0, 0.62, GOLD], ["GET PSYCHED!", 4.0, 0.86, nil]].freeze

    # Runs of lit pixels: [[x, y, len], ...] in font pixels, x centred on the line.
    def self.runs(text)
      w = Bitfont.width(text)
      out = []
      text.each_char.with_index do |ch, n|
        rows = Hash.new { |hh, k| hh[k] = [] }
        Bitfont.glyph_points(ch).each { |x, y| rows[y] << x }
        rows.each do |y, xs|
          xs.sort.slice_when { |a, b| b != a + 1 }.each { |run| out << [n * 6 + run.first - w / 2.0, y - 3.5, run.size] }
        end
      end
      out
    end

    def initialize(scene)
      @s = scene
      @lines = LINES.map { |text, px, cy, rows| { runs: MazeTitle.runs(text), px: px * scene.u, cy: cy * scene.h, rows: rows } }
      @shown = nil
      @alpha_sent = Array.new(@lines.size, 1.0)
    end

    # Inside a draw block. Layers: shadow, two chromatic ghosts, then the face.
    def build
      s = @s
      @inks = %i[shadow cyan magenta face].map do |layer|
        @lines.map do |line|
          next [] if line[:rows].nil? && layer != :face

          line[:runs].map do |_x, y, _len|
            case layer
            when :shadow then [0, 0, 0, 0.6]
            when :cyan then [*Palette::CYAN, 0.75]
            when :magenta then [*Palette::MAGENTA, 0.75]
            else [*(line[:rows] ? line[:rows][(y + 3.5).round] : Palette::INK), 1.0]
            end
          end
        end
      end
      @layers = %i[shadow cyan magenta face].map do |layer|
        @lines.map do |line|
          next [] if line[:rows].nil? && layer != :face

          line[:runs].map do |_x, y, _len|
            fill = case layer
                   when :shadow then Palette.rgb([0, 0, 0], 0.6)
                   when :cyan then Palette.rgb(Palette::CYAN, 0.75)
                   when :magenta then Palette.rgb(Palette::MAGENTA, 0.75)
                   else line[:rows] ? Palette.rgb(line[:rows][(y + 3.5).round]) : Palette.rgb(Palette::INK)
                   end
            s.rect(0, 0, 1, 1, fill: fill, strokewidth: 0, hidden: true)
          end
        end
      end
      @on = @layers.map { |layer| layer.map { |rects| Array.new(rects.size, false) } }
    end

    def update(t, sync)
      show = t > 0.28 && t < 2.5
      toggle(show)
      return unless show

      w = @s.w
      @lines.each_with_index do |line, li|
        scale, alpha, shake = line_motion(li, t)
        if scale.nil?
          hide_line(li)
          next
        end
        p = line[:px] * scale
        cx = w / 2.0 + shake * Math.sin(t * 97.0) * @s.u
        cy = @s.h * 0.5 + (line[:cy] - @s.h * 0.5) * [scale, 1.0].max**0.6 + shake * Math.cos(t * 71.0) * @s.u
        ghost = 14.0 * @s.u * Math.exp(-[t - hit_time(li), 0.0].max / 0.18)
        # as the letters reach the lens they fade out over a few frames rather than blink off
        fade = (alpha * 32).round / 32.0
        if fade != @alpha_sent[li]
          @alpha_sent[li] = fade
          tint(li, fade)
        end
        @layers.each_with_index do |layer, k|
          rects = layer[li]
          next if rects.empty?

          dx, dy = case k
                   when 0 then [p * 0.45, p * 0.45]
                   when 1 then [-ghost, 0.0]
                   when 2 then [ghost, 0.0]
                   else [0.0, 0.0]
                   end
          on = k.zero? || k == 3 || ghost > 0.6
          state = @on[k][li]
          line[:runs].each_with_index do |(x, y, len), j|
            if on && alpha > 0.02
              props = { left: (cx + x * p + dx).round(1), top: (cy + y * p + dy).round(1),
                        width: (len * p + 0.6).round(1), height: (p + 0.6).round(1) }
              props[:hidden] = false unless state[j]
              state[j] = true
              @s.set(rects[j], props)
            elsif state[j]
              @s.set(rects[j], { hidden: true })
              state[j] = false
            end
          end
        end
      end
    end

    private

    def hit_time(li) = [0.5, 1.0, 1.25][li]

    FADE_FROM = 0.84 # share of the fly-out after which the letters fade, about four frames

    # scale (nil = hidden), alpha, shake in u for one line at time t.
    def line_motion(li, t)
      hit = hit_time(li)
      fall = 0.2
      return nil if t < hit - fall
      return nil if li == 2 && (t > 2.0 || ((t - hit) * 8).floor.odd?)

      if t < hit
        k = (t - (hit - fall)) / fall
        return [1.0 + 3.5 * (1.0 - k * k), 1.0, 0.0]
      end
      shake = 9.0 * Math.exp(-(t - hit) / 0.16)
      if t > 2.05
        k = (t - 2.05) / 0.4
        return k > 1.0 ? nil : [1.0 + 7.0 * k * k, k < FADE_FROM ? 1.0 : (1.0 - k) / (1.0 - FADE_FROM), 0.0]
      end
      [1.0, 1.0, shake]
    end

    # Every rect of one line, shown or not, to its ink at this share of its alpha.
    def tint(li, share)
      @layers.each_with_index do |layer, k|
        inks = @inks[k][li]
        layer[li].each_with_index do |r, j|
          c = inks[j]
          @s.set(r, { fill: [c[0], c[1], c[2], (c[3] * share * 255).round] })
        end
      end
    end

    def hide_line(li)
      @layers.each_index { |k| hide(k, li) }
    end

    def hide(k, li)
      state = @on[k][li]
      @layers[k][li].each_with_index do |r, j|
        next unless state[j]

        @s.set(r, { hidden: true })
        state[j] = false
      end
    end

    def toggle(show)
      return if show == @shown

      @shown = show
      return if show

      @layers.each_index { |k| @lines.each_index { |li| hide(k, li) } }
    end
  end

  # SHOES n/9, top left: a dot-matrix digit whose 35 pixels are shown or hidden.
  class MazeCounter
    def initialize(scene, total)
      @s = scene
      @total = total
      @shown = -1
    end

    def build(left, top, px)
      s = @s
      @px = px
      label = "SHOES"
      ink = Palette.rgb(Palette::GOLD)
      tail = "/#{@total}"
      wide = (Bitfont.width(label) + 3 + 6 + Bitfont.width(tail)) * px
      pad = 2.5 * px
      @static = []
      @static << s.rect(left - pad, top - pad, wide + 2 * pad, 7 * px + 2 * pad, fill: Palette.rgb(Palette::NIGHT, 0.62),
        stroke: Palette.rgb(Palette::GOLD, 0.35), strokewidth: 1)
      MazeTitle.runs(label).each do |x, y, len|
        @static << s.rect(left + (x + Bitfont.width(label) / 2.0) * px, top + (y + 3.5) * px, len * px, px, fill: ink, strokewidth: 0)
      end
      dx = left + (Bitfont.width(label) + 3) * px
      @cells = Array.new(35) do |k|
        s.rect(dx + (k % 5) * px, top + (k / 5) * px, px * 0.86, px * 0.86, fill: ink, strokewidth: 0, hidden: true)
      end
      MazeTitle.runs(tail).each do |x, y, len|
        @static << s.rect(dx + (6 + x + Bitfont.width(tail) / 2.0) * px, top + (y + 3.5) * px, len * px, px,
          fill: Palette.rgb(Palette::MUTED), strokewidth: 0)
      end
    end

    # Hold the whole counter back (false) or bring it in (true). A scene that never calls this
    # keeps it on screen throughout.
    def visible(on)
      return if on == @visible

      @visible = on
      @static.each { |d| @s.set(d, { hidden: !on }) }
      @cells.each { |r| @s.set(r, { hidden: true }) } unless on
      @shown = -1
    end

    def update(count)
      return if @visible == false || count == @shown

      @shown = count
      lit = Bitfont.glyph_points(count.to_s).map { |x, y| y * 5 + x }
      @cells.each_with_index { |r, k| @s.set(r, { hidden: !lit.include?(k) }) }
    end
  end
end
