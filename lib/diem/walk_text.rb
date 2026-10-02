# frozen_string_literal: true

require_relative "maze_title"

# Big Bitfont words for the walk, any text: layers of a drop shadow, a dark outline (every
# lit run grown by a fraction of a pixel on each side, so the words hold up on the white
# room's haze as well as on the night), two chromatic ghosts and the face. Each layer is one shape per colour (the face, one per glyph row when its rows are
# coloured), every run of lit pixels one rect inside it, snapped to whole pixels edge to edge.
# A line of fifteen letters is a handful of fills instead of a few hundred rects.
module Diem
  class WalkText
    LAYERS = %i[shadow cyan magenta face].freeze
    OUTLINE = [14, 4, 32, 215].freeze
    MOVE = "move_to"
    LINE = "line_to"

    def initialize(scene, layers: LAYERS)
      @s = scene
      @layers = layers
      @runs = []
      @groups = [[]]
      @text = nil
      @fade = 1.0
      @base = nil
    end

    # Inside a draw block.
    def build
      @shapes = @layers.map do |layer|
        Array.new(layer == :face ? 7 : 1) { @s.shape(0, 0, fill: Palette.rgb(Palette::INK), strokewidth: 0) }
      end
      @cmds = @shapes.map { |a| Array.new(a.size) { [] } }
      @on = @shapes.map { |a| Array.new(a.size, false) }
      @placed = nil
    end

    def enter
      @shapes.each { |a| a.each { |sh| @s.set(sh, { shape_commands: [] }) } }
      @on.each { |a| a.fill(false) }
      @text = nil
      @rows = nil
      @placed = nil
      @fade = 1.0
    end

    # Sets the words and the colour of each glyph row (7 [r, g, b], or nil for ink).
    def text(str, rows = nil)
      return if str == @text && rows.equal?(@rows)

      hide
      @text = str
      @rows = rows
      @runs = MazeTitle.runs(str)
      @groups = if rows
                  Array.new(7) { |r| @runs.select { |_x, y, _len| (y + 3.5).round == r } }
                else
                  [@runs]
                end
      @base = @layers.map do |layer|
        Array.new(@shapes[@layers.index(layer)].size) do |g|
          case layer
          when :shadow then [0, 0, 0, 150]
          when :outline then OUTLINE
          when :cyan then [*Palette::CYAN, 190]
          when :magenta then [*Palette::MAGENTA, 190]
          else rows ? [*rows[g], 255] : [*Palette::INK, 255]
          end
        end
      end
      paint
    end

    # Fades every layer to a share (0..1) of its own alpha: a fill change, which keeps the layout.
    def fade(a)
      a = (a.clamp(0.0, 1.0) * 32).round / 32.0
      return if a == @fade

      @fade = a
      paint if @base
    end

    # Centre (cx, cy), pixel size p, how far the chromatic ghosts stand apart, and whether the
    # drop shadow shows (a settled word drops it, a layer less to paint).
    def place(cx, cy, p, ghost = 0.0, shadow: true)
      key = [cx.round, cy.round, p.round(2), ghost.round, shadow]
      return if key == @placed

      @placed = key
      @layers.each_with_index do |layer, li|
        dx, dy = case layer
                 when :shadow then [p * 0.45, p * 0.45]
                 when :outline then [0.0, 0.0]
                 when :cyan then [-ghost, 0.0]
                 when :magenta then [ghost, 0.0]
                 else [0.0, 0.0]
                 end
        on = case layer
             when :shadow then shadow
             when :face, :outline then true
             else ghost > 0.6
             end
        groups = layer == :face ? @groups : [@runs]
        groups.each_with_index do |runs, g|
          sh = @shapes[li][g]
          if on && !runs.empty?
            draw_runs(@cmds[li][g], runs, cx + dx, cy + dy, p, layer == :outline ? grow(p) : 0)
            @s.set(sh, { shape_commands: @cmds[li][g] })
            @on[li][g] = true
          elsif @on[li][g]
            @s.set(sh, { shape_commands: [] })
            @on[li][g] = false
          end
        end
      end
    end

    def hide
      @on.each_with_index do |a, li|
        a.each_with_index do |shown, g|
          next unless shown

          @s.set(@shapes[li][g], { shape_commands: [] })
          a[g] = false
        end
      end
      @placed = nil
    end

    private

    def paint
      @layers.each_index do |li|
        @shapes[li].each_with_index do |sh, g|
          c = @base[li][g]
          @s.set(sh, { fill: [c[0], c[1], c[2], (c[3] * @fade).round] })
        end
      end
    end

    # How far the outline stands out from the face: three tenths of a pixel, at least one.
    def grow(p) = [(p * 0.3).round, 1].max

    def draw_runs(c, runs, cx, cy, p, out = 0)
      k = 0
      runs.each do |x, y, len|
        l = (cx + x * p).round
        r = (cx + (x + len) * p).round
        t = (cy + y * p).round
        b = (cy + (y + 1) * p).round
        r = l + 1 if r <= l
        b = t + 1 if b <= t
        l -= out
        r += out
        t -= out
        b += out
        put(c, k, MOVE, l, t)
        put(c, k + 1, LINE, r, t)
        put(c, k + 2, LINE, r, b)
        put(c, k + 3, LINE, l, b)
        k += 4
      end
      c.pop while c.size > k
    end

    def put(c, k, op, x, y)
      q = c[k]
      if q
        q[0] = op
        q[1] = x
        q[2] = y
      else
        c << [op, x, y]
      end
    end
  end
end
