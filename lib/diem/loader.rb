# frozen_string_literal: true

# The loading screen, in the old tape-loader tradition: raster stripes racing through the
# border while, in the middle, the soundtrack is synthesized track by track in a Ruby child
# process and every scene is built behind the screen.
module Diem
  class Loader
    TRACKS = %w[kick snare clap hat ohat crash bass sub arp pad lead lead2 bell riser impact mix].freeze
    C64 = [[0, 0, 0], [255, 255, 255], [136, 57, 50], [103, 182, 189], [139, 63, 150], [85, 160, 73],
      [64, 49, 141], [191, 206, 114], [139, 84, 41], [87, 66, 0], [184, 105, 98], [80, 80, 80],
      [120, 120, 120], [148, 224, 137], [120, 105, 196], [159, 159, 159]].freeze
    STRIPES = 135

    def initialize(app, engine)
      @app = app
      @engine = engine
      @pw = (560 * U).round
      @ph = (362 * U).round
      @px = ((W - @pw) / 2.0).round
      @py = ((H - @ph) / 2.0).round
      build
    end

    # Seconds to wait once everything is ready, so the last bar can be seen to fill.
    def linger = 0.9

    def update(elapsed, progress, built)
      stripes(elapsed, progress[:done])
      tracks(progress)
      @built_bar.style(width: [(@bar_w * built).round, 1].max)
      status(elapsed, progress, built)
    end

    def finish
      @slot.remove
    end

    private

    def build
      app = @app
      ink = Palette.rgb(Palette::INK)
      muted = Palette.rgb(Palette::MUTED)
      @slot = app.stack(left: 0, top: 0, width: W, height: H) do
        app.nostroke
        h = H.fdiv(STRIPES)
        @stripes = Array.new(STRIPES) { |i| app.rect(0, (i * h).floor, W, h.ceil + 1, fill: app.rgb(0, 0, 0), strokewidth: 0) }
        app.rect(@px, @py, @pw, @ph, 6 * U, fill: Palette.rgb(Palette::NIGHT), strokewidth: 0)
        app.para("SCARPE DIEM", left: @px + (28 * U).round, top: @py + (22 * U).round, size: (30 * U).round,
          stroke: ink, weight: "heavy", kerning: (6 * U).round, margin: 0)
        app.para("a real-time demo in Ruby and Shoes, for the Scarpe native renderer", left: @px + (30 * U).round,
          top: @py + (66 * U).round, size: (11 * U).round, stroke: muted, margin: 0)
        @headline = app.para("synthesizing the soundtrack in pure Ruby", left: @px + (30 * U).round,
          top: @py + (100 * U).round, size: (12 * U).round, stroke: ink, margin: 0)
        build_track_bars(app, muted)
        top = @py + (290 * U).round
        app.para("building scenes", left: @px + (30 * U).round, top: top - (2 * U).round, size: (10 * U).round, stroke: muted, margin: 0)
        @bar_w = @pw - (170 * U).round
        app.rect(@px + (140 * U).round, top, @bar_w, (8 * U).round, 3 * U, fill: app.rgb(255, 255, 255, 0.08), strokewidth: 0)
        @built_bar = app.rect(@px + (140 * U).round, top, 1, (8 * U).round, 3 * U, fill: Palette.rgb(Palette::MAGENTA), strokewidth: 0)
        @status = app.para("", left: @px + (30 * U).round, top: @py + @ph - (30 * U).round, size: (10 * U).round,
          stroke: muted, font: "Menlo, monospace", margin: 0)
      end
    end

    def build_track_bars(app, muted)
      cols = 2
      col_w = (@pw - (60 * U)) / cols
      @track_bars = {}
      @track_w = (col_w - 70 * U).round
      TRACKS.each_with_index do |name, i|
        x = @px + (30 * U + (i % cols) * col_w).round
        y = @py + (132 * U + (i / cols) * 17 * U).round
        app.para(name, left: x, top: y - (3 * U).round, size: (10 * U).round, stroke: muted, font: "Menlo, monospace", margin: 0)
        app.rect(x + (52 * U).round, y, @track_w, (6 * U).round, 3 * U, fill: app.rgb(255, 255, 255, 0.07), strokewidth: 0)
        @track_bars[name] = app.rect(x + (52 * U).round, y, 1, (6 * U).round, 3 * U, fill: Palette.rgb(Palette::CYAN), strokewidth: 0)
      end
    end

    # The border stripes: chaotic runs of tape-loader colour while loading, a calm rolling
    # rainbow once everything is ready.
    def stripes(elapsed, ready)
      frame = (elapsed * 60).floor
      run_left = 0
      colour = C64[0]
      @stripes.each_with_index do |s, i|
        c = if ready
          k = ((i + frame * 0.5) % STRIPES) / STRIPES.to_f
          Palette.mix(Palette::VIOLET, Palette::MAGENTA, 0.5 + 0.5 * Math.sin(k * Math::PI * 2))
        else
          if run_left.zero?
            h = (i * 7919 + frame * 104_729 + (frame / 3) * 31) & 0xffff
            run_left = 1 + h % 4
            colour = C64[(h >> 4) % 16]
          end
          run_left -= 1
          colour
        end
        Wire.set(s, { fill: [c[0].round, c[1].round, c[2].round, 255] })
      end
    end

    def tracks(progress)
      done = progress[:done]
      @track_bars.each do |name, bar|
        f = done ? 1.0 : (progress[:tracks] || {}).fetch(name, 0.0)
        width = [(@track_w * f).round, 1].max
        next if width == bar.instance_variable_get(:@shown_w)

        bar.instance_variable_set(:@shown_w, width)
        bar.style(width: width)
      end
    end

    def status(elapsed, progress, built)
      text = if progress[:done] && built >= 1.0
        @headline.text = progress[:seconds] ? format("soundtrack synthesized in %.1f s", progress[:seconds]) : "soundtrack ready"
        "ready. space pause · arrows skip · m mute · f stats · esc quit"
      else
        format("%.1f s  ·  %d of %d tracks", elapsed, (progress[:tracks] || {}).count { |_, v| v >= 1.0 }, TRACKS.size)
      end
      @status.text = text unless text == @shown_status
      @shown_status = text
    end
  end
end
