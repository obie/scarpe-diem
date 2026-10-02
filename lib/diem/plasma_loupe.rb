# frozen_string_literal: true

# A magnifier over the Plasma scene's framebuffer: a box on the picture, and beside it the
# N x N real pixels under that box, drawn as crisp squares in exactly the colours Ruby wrote.
# It rides the rings the music drops (see PlasmaGuide) and fades out before the riser.
module Diem
  class PlasmaLoupe
    N = 9
    FRAME = [6, 5, 13, 170].freeze
    EDGE = [244, 241, 255, 34].freeze
    MARK = [255, 255, 255, 230].freeze
    BOX = [255, 255, 255, 200].freeze
    LEAD = [255, 255, 255, 70].freeze

    attr_reader :rect

    # Screen segments a label must keep clear of: the box on the picture and the lead line
    # from it, as [x0, y0, x1, y1] boxes (the line as a few short boxes along it).
    def keep_clear
      return [] if @hidden || @box_left.nil?

      side = N * @sc
      out = [[@box_left, @box_top, @box_left + side, @box_top + side]]
      bx = @box_left + side
      tx = @x0 - 10 * @s.u
      8.times do |i|
        f = (i + 0.5) / 8
        x = bx + (tx - bx) * f
        y = @box_top + (@y0 - @box_top) * f
        out << [x - 3, y - 3, x + 3, y + 3]
      end
      out
    end

    # scene: the Plasma scene (its DSL draws, inside its draw block). fw, fh: framebuffer size;
    # sc: screen pixels per framebuffer pixel.
    def initialize(scene, fw, fh, sc)
      @s = scene
      @fw = fw
      @fh = fh
      @sc = sc
      u = scene.u
      @cell = (13 * u).round
      pad = (10 * u).round
      side = N * @cell
      @x0 = (scene.w - 24 * u - side - pad).round
      @y0 = (24 * u + pad).round
      @rect = [@x0 - pad, @y0 - pad, side + 2 * pad, side + 2 * pad + (26 * u).round]
      build(u, side, pad)
      @last = nil
      @alpha = 1.0
      @hidden = false
    end

    # rows: the frame's BGR row strings; px, py: the framebuffer pixel to centre on;
    # tick: the readout only changes when this does (15 Hz is all an eye can read).
    def update(rows, px, py, tick)
      return if @hidden

      px = px.round.clamp(N / 2, @fw - N / 2 - 1)
      py = py.round.clamp(N / 2, @fh - N / 2 - 1)
      paint_cells(rows, px, py, (@alpha * 255).round)
      place_box(px, py)
      return if tick == @tick

      @tick = tick
      centre = rows[py]
      hex = format("#%02x%02x%02x", centre.getbyte(px * 3 + 2), centre.getbyte(px * 3 + 1), centre.getbyte(px * 3))
      text = format("%3d,%-3d %s", px, py, hex)
      return if text == @last

      @readout.text = text
      @last = text
    end

    # Forget what was last sent, so a seek repaints everything.
    def reset
      @last = @tick = @box_left = @box_top = nil
    end

    # 0..1: how much of the loupe shows. At 0 every part is hidden, so it costs no paint.
    def fade(a)
      return if a == @alpha

      @alpha = a
      if a <= 0.0
        parts.each { |d| Wire.set(d, { hidden: true }) }
        @hidden = true
        return
      end
      parts.each { |d| Wire.set(d, { hidden: false }) } if @hidden
      @hidden = false
      Wire.set(@frame, { fill: dim(FRAME, a), stroke: dim(EDGE, a) })
      Wire.set(@mark, { stroke: dim(MARK, a) })
      Wire.set(@box, { stroke: dim(BOX, a) })
      Wire.set(@lead, { stroke: dim(LEAD, a) })
      Wire.set(@readout, { stroke: dim([*Palette::MUTED, 255], a) })
    end

    private

    def dim(c, a) = [c[0], c[1], c[2], (c[3] * a).round]

    def parts = @parts ||= [@frame, *@cells, @mark, @readout, @box, @lead]

    def build(u, side, pad)
      s = @s
      @frame = s.rect(*@rect, (10 * u).round, fill: s.rgb(*FRAME), stroke: s.rgb(*EDGE), strokewidth: 1)
      gap = [1, (1 * u).round].max
      @cells = Array.new(N * N) do |i|
        s.rect(@x0 + (i % N) * @cell, @y0 + (i / N) * @cell, @cell - gap, @cell - gap, fill: s.rgb(0, 0, 0), strokewidth: 0)
      end
      mid = N / 2 * @cell
      @mark = s.rect(@x0 + mid - gap, @y0 + mid - gap, @cell + gap, @cell + gap, fill: s.rgb(0, 0, 0, 0),
        stroke: s.rgb(*MARK), strokewidth: [1, (1.5 * u).round].max)
      @readout = s.para "", left: @x0, top: @y0 + side + (7 * u).round, size: (11 * u).round,
        font: "Menlo, monospace", margin: 0, stroke: Palette.rgb(Palette::MUTED)
      box = N * @sc
      @box = s.rect(0, 0, box, box, fill: s.rgb(0, 0, 0, 0), stroke: s.rgb(*BOX), strokewidth: 1)
      @lead = s.line(0, 0, 1, 1, stroke: s.rgb(*LEAD), strokewidth: 1)
    end

    def paint_cells(rows, px, py, alpha)
      cells = @cells
      i = 0
      dy = 0
      while dy < N
        row = rows[py - N / 2 + dy]
        o = (px - N / 2) * 3
        dx = 0
        while dx < N
          Wire.set(cells[i], { fill: [row.getbyte(o + 2), row.getbyte(o + 1), row.getbyte(o), alpha] })
          o += 3
          i += 1
          dx += 1
        end
        dy += 1
      end
    end

    def place_box(px, py)
      left = ((px - N / 2) * @sc).round(1)
      top = ((py - N / 2) * @sc).round(1)
      return if left == @box_left && top == @box_top

      @box_left = left
      @box_top = top
      Wire.set(@box, { left: left, top: top })
      bx = left + N * @sc
      Wire.set(@lead, { left: bx.round(1), top: top, x2: (@x0 - 10 * @s.u).round(1), y2: @y0.to_f })
    end
  end
end
