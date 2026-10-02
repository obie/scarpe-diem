# frozen_string_literal: true

require_relative "../plasma_field"
require_relative "../plasma_palette"
require_relative "../plasma_loupe"
require_relative "../plasma_guide"

module Diem
  module Scenes
    # Bars 24-32. A full-screen plasma computed pixel by pixel in Ruby, lit like a liquid
    # surface. The kick swells it, the snare sends a shockwave through it, and every bell note
    # drops a ripple from a point set by its pitch, so the melody is written across the screen.
    # The riser rains on it, races its clock and heats it, then carries it into white.
    class Plasma < Scene
      LIFE = 1.7          # seconds a bell ripple lives
      SHOCK_LIFE = 1.2    # seconds a snare shockwave lives
      BELLS = 5           # bell ripples that can live at once
      RISER = 12.0        # local second the riser starts
      RAIN_SLOTS = 6      # riser raindrops alive at once, at most
      RAIN_LIFE = 0.7     # longest a raindrop lives
      LOUPE_OUT = 11.5    # the loupe, note labels and melody line fade from here to RISER
      TEXT_OUT = 14.55    # the panel's text fades from here...
      TEXT_GONE = 14.8
      HUD_OUT = 14.65     # ...and then the panel and rings, to here, leaving the white-out clean
      HUD_GONE = 14.95
      LENGTH = 16.0       # the scene's 8 bars; a clock run past it (a tile) wraps onto them
      KICK_ZOOM = 0.2     # how far the kick pushes the field out
      SQUEEZE = 8         # contrast tables for the kick's squeeze
      NOTE_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze
      FORMULA = "v = SIN[.052x+.9t] + SIN[.019x-.41t] + SIN[.064y-1.1t]"
      FORMULA2 = "  + SIN[.027y+.6t] + SIN[.034(x+y)+.7t] + 2 RIP + %d RING"
      PANEL = [6, 5, 13, 170].freeze
      PANEL_EDGE = [244, 241, 255, 34].freeze

      Drop = Struct.new(:time, :x, :y, :note, :label, :strength, :life)

      def build
        @fw = [((w / 4.0) / 4).round * 4, 16].max
        @fh = (@fw * h / w.to_f).round
        @field = PlasmaField.new(@fw, @fh)
        @palette = PlasmaPalette.new
        @sc = w / @fw.to_f
        @k = 240.0 / @fw # field units per framebuffer pixel, so a tile looks the same
        build_tables
        draw do
          @fb = Framebuffer.new(@app, @fw, @fh, left: 0, top: 0, width: w, height: h)
          nofill
          @rings = Array.new(BELLS + 1) { oval(0, 0, 10, hidden: true, stroke: rgb(255, 255, 255, 0), strokewidth: 1.4 * u) }
          @melody = shape(0, 0, stroke: rgb(255, 255, 255, 0), strokewidth: 1.0 * u) { @app.move_to(0, 0) }
          @dots = Array.new(BELLS) { oval(0, 0, 10, hidden: true, fill: rgb(255, 255, 255, 0), strokewidth: 0) }
          label = { left: 0, top: 0, size: (12 * u).round, font: "Menlo, monospace", margin: 0, hidden: true }
          @shadows = Array.new(BELLS) { para "", stroke: rgb(6, 5, 13, 0), **label }
          @labels = Array.new(BELLS) { para "", stroke: rgb(255, 255, 255, 0), **label }
          build_panel
          @loupe = PlasmaLoupe.new(self, @fw, @fh, @sc) if @panel_on
        end
        return unless @panel_on

        build_guide
        warm_guide
      end

      def enter
        @shown_rings = Array.new(BELLS + 1)
        @shown_labels = Array.new(BELLS)
        @label_at = Array.new(BELLS)
        @shown_dots = Array.new(BELLS)
        @melody_off = nil
        @live_text = nil
        @live_tick = nil
        @formula_text = nil
        @hud = nil
        @loupe&.reset
      end

      def update(t, sync)
        t %= LENGTH if t >= LENGTH + 0.5
        plan((sync.t - t).round(6))
        tau = warp(t)
        kick = kick_at(t)
        snare = snare_at(t)
        zoom = 1.0 + KICK_ZOOM * kick
        fill_sines(tau, zoom, *kick_centre(t))
        terms = gather_ripples(t, tau, zoom)
        fill_light(kick, snare, t)
        pal = palette_at(sync.t, t)
        frame = (t * 60).round
        rows = @field.render(@in_tabs, @in_cx, @in_cy, @rings_small, @tabs,
          @colv, @diag, @rowv, @rowlev, dither_at(t)[frame & 3], pal, @levs[squeeze(kick)], (tau * 12).to_i)
        @fb.present(rows)
        hud = ramp_out(t, HUD_OUT, HUD_GONE)
        crisp = ramp_out(t, LOUPE_OUT, RISER)
        if @panel_on
          fade_panel(ramp_out(t, TEXT_OUT, TEXT_GONE), hud)
          @loupe.fade(crisp)
          @loupe.update(rows, *@guide.target(t), (t * 15).floor) if crisp > 0.0
          update_panel(t, tau, zoom, terms) if hud > 0.0
        end
        update_rings(t, hud, crisp)
      end

      private

      # ---- precomputed tables ---------------------------------------------------------------

      def build_tables
        @colv = Array.new(@fw, 0)
        @rowv = Array.new(@fh, 0)
        @diag = Array.new(@fw + @fh, 0)
        @rowlev = Array.new(@fh, 128)
        n = @field.dist_len
        @tabs = Array.new(PlasmaField::MAX_TERMS) { Array.new(n, 0) }
        @bands = Array.new(PlasmaField::MAX_TERMS) { [0, 0] }
        @cxs = Array.new(PlasmaField::MAX_TERMS, 0)
        @cys = Array.new(PlasmaField::MAX_TERMS, 2)
        @in_tabs = []
        @in_cx = []
        @in_cy = []
        @rings_small = []
        # Vignette plus a 4x4 ordered dither, so light levels melt into each other once scaled.
        # The dither matrix shifts every frame, so its grain averages out instead of quilting.
        # The white-out gets a fainter grain: on near-white the pattern would read as texture.
        @vigx = vignette(0.05)
        @vigx_soft = vignette(0.02)
        @vigx_bare = vignette(0.0)
        @vigy = Array.new(@fh) { |y| -40 * ((y + 0.5) / @fh * 2 - 1).abs**2.4 }
        # Slope bucket -> light level * HUES: a soft S so flat reads mid and steep reads lit.
        # The kick squeezes it steeper for a moment, so the whole surface hardens on the hit.
        @levs = Array.new(SQUEEZE) { |j| lev_table(1.0 + 0.6 * j / (SQUEEZE - 1)) }.freeze
      end

      BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].freeze

      def vignette(grain)
        [[0, 0], [2, 2], [2, 0], [0, 2]].map do |ox, oy|
          Array.new(4) do |r|
            Array.new(@fw) do |x|
              (-46 * ((x + 0.5) / @fw * 2 - 1).abs**2.4 + (BAYER[((r + oy) & 3) * 4 + ((x + ox) & 3)] - 7.5) * grain).round
            end
          end
        end
      end

      def lev_table(contrast)
        Array.new(PlasmaField::LIGHT) do |i|
          l = 0.5 + 0.5 * Math.tanh((i - 128) * contrast / (30.0 * @k)) # a coarser buffer has steeper slopes
          (l * (PlasmaField::NL - 1)).round.clamp(0, PlasmaField::NL - 1) * PlasmaField::HUES
        end.freeze
      end

      def squeeze(kick) = (kick * (SQUEEZE - 1)).round.clamp(0, SQUEEZE - 1)

      def dither_at(t)
        return @vigx if t < RISER + 2.8

        t < WHITE_FROM + 0.65 ? @vigx_soft : @vigx_bare
      end

      # Every bell note and snare of the scene, with the point it falls on. Pure data from the
      # score, so any frame can be drawn on its own.
      def plan(base)
        return if @base == base

        @base = base
        sync = Plasma.song
        bells = sync.hits(:bell).select { |h| h.time >= base - LIFE && h.time < base + 16.5 }
        @drops = bells.map { |h| bell_drop(h, base) }
        snares = sync.hits(:snare).select { |h| h.time >= base - SHOCK_LIFE && h.time < base + 16.5 }
        @shocks = [Drop.new(0.0, 0.5, 0.5, nil, nil, 1.3, SHOCK_LIFE)] +
          snares.map.with_index { |h, i| Drop.new(h.time - base, i.even? ? 0.2 : 0.8, 0.44, nil, nil, h.vel, SHOCK_LIFE) }
        @snare_t = snares.map { |h| h.time - base }
        @snare_v = snares.map(&:vel)
        kicks = sync.hits(:kick).select { |h| h.time >= base - 1.0 && h.time < base + 16.5 }
        @kick_t = kicks.map { |h| h.time - base }
        @kick_v = kicks.map(&:vel)
        @kick_c = @kick_t.map { |kt| centre_before(kt) }
        @rain = rain
        @guide&.plan(@drops, @shocks, LIFE, SHOCK_LIFE)
      end

      # The whole song's hits, read once: only the cursor of a Sync changes.
      def self.song = @song ||= Sync.new(Music.score)

      # Where the kick at time kt pushes from: the bell note sounding then (they share the
      # downbeat), else the screen centre. Fixed for the kick's whole swell, so it never jumps.
      def centre_before(kt)
        d = @drops.reverse_each.find { |b| b.time <= kt + 1e-6 && kt - b.time < LIFE }
        d ? [d.x * @fw, d.y * @fh] : [@fw / 2.0, @fh / 2.0]
      end

      def kick_centre(t)
        i = @kick_t.bsearch_index { |x| x > t + 1e-9 } || @kick_t.size
        i.zero? ? [@fw / 2.0, @fh / 2.0] : @kick_c[i - 1]
      end

      # The riser's rain: drops on a golden-angle spiral, every 8th, then 16th, then 32nd note.
      # Drop k dies by the time drop k + RAIN_SLOTS lands, so at most RAIN_SLOTS are ever alive
      # and no ring is cut off mid-life. Quicker rain means shorter, faster rings.
      def rain
        times = []
        at = RISER
        while at < 16.0
          times << at
          at += at < 13.0 ? 0.25 : (at < 14.5 ? 0.125 : 0.0625)
        end
        times.each_with_index.map do |at0, k|
          a = k * 2.39996
          r = 0.06 + 0.34 * Math.sqrt(k / 52.0)
          next_free = times[k + RAIN_SLOTS] || (at0 + 0.0625 * RAIN_SLOTS)
          life = [RAIN_LIFE, next_free - at0].min
          hard = 1.0 + 1.1 * ((at0 - RISER) / (16.0 - RISER))**1.5 # the 32nds hit hardest
          Drop.new(at0, 0.5 + r * Math.cos(a) * 0.62, 0.5 + r * Math.sin(a), nil, nil, hard, life)
        end
      end

      # Pitch sets the height, place in the four-bar phrase sets x (mirrored the second time).
      def bell_drop(hit, base)
        local = hit.time - base
        phrase = ((local / Music::BAR).floor / 4) % 2
        p = (local % (Music::BAR * 4)) / (Music::BAR * 4)
        # Kept clear of the formula panel (bottom left) and the loupe (top right).
        x = phrase.zero? ? 0.08 + 0.74 * p : 0.82 - 0.74 * p
        y = 0.72 - (hit.note - 69) / 15.0 * 0.54
        Drop.new(local, x, y, hit.note, "#{NOTE_NAMES[hit.note % 12]}#{hit.note / 12 - 1}", hit.vel, LIFE)
      end

      # The plasma's own clock: steady, then racing through the riser.
      def warp(t)
        r = t - RISER
        r.positive? ? t + 1.7 * r * r : t
      end

      # The kick's swell: most of it lands on the hit frame itself, the last of it a frame on,
      # so a liquid surface pulses instead of cutting.
      # Read from the planned kicks, so the loupe's guide can ask about any moment.
      def kick_at(t)
        i = @kick_t.bsearch_index { |x| x > t + 1e-9 } || @kick_t.size
        return 0.0 if i.zero?

        age = t - @kick_t[i - 1]
        a = (age / 0.017).clamp(0.0, 1.0)
        @kick_v[i - 1] * (0.8 + 0.2 * a * a * (3 - 2 * a)) * Math.exp(-age / 0.22)
      end

      def snare_at(t)
        i = @snare_t.bsearch_index { |x| x > t + 1e-9 } || @snare_t.size
        i.zero? ? 0.0 : @snare_v[i - 1] * Math.exp(-(t - @snare_t[i - 1]) / 0.3)
      end

      # The two ripples that always fill the screen: [centre x, centre y (shares), freq, speed].
      def base_ripples(tau)
        [[0.5 + 0.3 * Math.sin(tau * 0.31), 0.5 + 0.28 * Math.sin(tau * 0.47 + 0.6), 0.09, 2.3],
          [0.5 + 0.33 * Math.sin(tau * 0.23 + 2.1), 0.5 + 0.3 * Math.cos(tau * 0.39), 0.07, -1.7]]
      end

      # 1 before from, 0 after to, eased between (quantised so faded props only change 64 times).
      def ramp_out(t, from, to)
        m = ((t - from) / (to - from)).clamp(0.0, 1.0)
        a = 1.0 - m * m * (3 - 2 * m)
        (a * 64).round / 64.0
      end

      # ---- the separable fields ------------------------------------------------------------

      # The kick zooms about (zx, zy), framebuffer pixels: coordinates are measured from the
      # screen centre at rest, plus a stretch about the zoom centre, so a zoom of 1 never moves.
      def fill_sines(tau, zoom, zx, zy)
        k = @k
        kz = @k * (1.0 / zoom - 1.0)
        colv = @colv
        half = @fw / 2.0
        @fw.times do |x|
          xc = (x - half) * k + (x - zx) * kz
          colv[x] = (2600 * Math.sin(xc * 0.052 + tau * 0.9) + 1500 * Math.sin(xc * 0.019 - tau * 0.41 + 1.3)).to_i
        end
        rowv = @rowv
        half = @fh / 2.0
        @fh.times do |y|
          yc = (y - half) * k + (y - zy) * kz
          rowv[y] = (2600 * Math.sin(yc * 0.064 - tau * 1.1) + 1200 * Math.sin(yc * 0.027 + tau * 0.6)).to_i
        end
        diag = @diag
        half = (@fw + @fh) / 2.0
        zd = zx + zy
        diag.size.times do |i|
          diag[i] = (1700 * Math.sin(((i - half) * k + (i - zd) * kz) * 0.034 + tau * 0.7)).to_i
        end
      end

      # ---- the radial terms ----------------------------------------------------------------

      # A ring whose annulus covers less than this share of the picture is added only across
      # the spans it covers; a bigger one is cheaper read for every pixel.
      SMALL = 0.4

      # Fills one ripple table per live term, sorts the terms into those read at every pixel and
      # the small rings, and returns how many there are.
      def gather_ripples(t, tau, zoom)
        @in_tabs.clear
        @in_cx.clear
        @in_cy.clear
        @rings_small.clear
        n = 0
        base_ripples(tau).each do |fx, fy, freq, speed|
          n = base_ripple(n, tau, zoom, fx, fy, freq, speed)
          read_everywhere(n - 1)
        end
        area = SMALL * @fw * @fh
        waves_at(t).each do |fx, fy, r, wd, freq, amp|
          n = wave(n, fx, fy, r, wd, freq, amp)
          ro = (r + 3 * wd) / @k + 1.5
          ri = [(r - 3 * wd) / @k - 1.5, 0.0].max
          if Math::PI * (ro * ro - ri * ri) < area
            @rings_small.push(n - 1, @cxs[n - 1], @cys[n - 1], ro, ri)
          else
            read_everywhere(n - 1)
          end
        end
        n
      end

      def read_everywhere(i)
        @in_tabs << @tabs[i]
        @in_cx << @cxs[i]
        @in_cy << @cys[i]
      end

      # Every ring-shaped wave alive at t as [x, y (shares), radius, width, freq, amplitude] in
      # field units. The budget is 1 shock + 3 bells + RAIN_SLOTS rain in the riser, which with
      # the 2 base ripples is MAX_TERMS, so nothing is ever cut off.
      def waves_at(t)
        out = []
        max = PlasmaField::MAX_TERMS - 2
        @shocks.each do |s|
          age = t - s.time
          next if age.negative? || age >= SHOCK_LIFE || out.size >= max

          out << [s.x, s.y, 4 + 150 * age, 7 + 9 * age, 0.3, 3000 * s.strength * fade(age, SHOCK_LIFE)]
        end
        @drops.each do |d|
          age = t - d.time
          next if age.negative? || age >= LIFE || out.size >= max

          out << [d.x, d.y, 3 + 62 * age, 4.5 + 5 * age, 0.45, 2000 * bell_fade(age)]
        end
        return out if t < RISER

        @rain.each do |d|
          age = t - d.time
          break if age.negative?
          next if age >= d.life || out.size >= max

          speed = [85.0, 50.0 / d.life].max
          out << [d.x, d.y, 2 + speed * age, 3.5 + 4 * age * speed / 85.0, 0.55, 1500 * d.strength * fade(age, d.life)]
        end
        out
      end

      def fade(age, life)
        a = 1.0 - age / life
        a * a * [age / 0.05, 1.0].min
      end

      # A bell lands already ringing: its ripple starts at a third of full strength, so the
      # note's own frame shows it.
      def bell_fade(age)
        a = 1.0 - age / LIFE
        a * a * [0.35 + age / 0.04, 1.0].min
      end

      # A ripple that fills the screen: sin(distance - time) over the whole table.
      def base_ripple(n, tau, zoom, fx, fy, freq, speed)
        place(n, fx, fy)
        tab = @tabs[n]
        k = @k * freq / zoom / PlasmaField::SUB
        # 1800 * sin(i * k - phase), stepped by rotation instead of a sine per entry.
        sn = 1800 * Math.sin(-tau * speed)
        cs = 1800 * Math.cos(-tau * speed)
        ck = Math.cos(k)
        sk = Math.sin(k)
        # Only as far out as the farthest corner: nothing reads past it.
        cx = @cxs[n] * 0.5
        cy = @cys[n] * 0.5
        far = Math.hypot([cx, @fw - cx].max, [cy, @fh - cy].max)
        len = [((far + 2) * PlasmaField::SUB).ceil, tab.size].min
        i = 0
        while i < len
          tab[i] = sn.to_i
          sn, cs = sn * ck + cs * sk, cs * ck - sn * sk
          i += 1
        end
        @bands[n][0] = 0
        @bands[n][1] = len
        n + 1
      end

      # A ring-shaped wave packet of radius r (field units), width wd: only its band is written.
      def wave(n, fx, fy, r, wd, freq, amp)
        place(n, fx, fy)
        tab = @tabs[n]
        band = @bands[n]
        tab.fill(0, band[0], band[1] - band[0])
        per = @k / PlasmaField::SUB # field units per table step
        lo = [((r - 3 * wd) / per).floor, 0].max
        hi = [((r + 3 * wd) / per).ceil, tab.size].min
        # amp * sin(dd * freq) * exp(-dd^2 / wd^2), stepped: the sine by rotation, the gaussian
        # by a ratio that itself shrinks by a constant factor each step.
        dd = lo * per - r
        w2 = wd * wd
        sn = amp * Math.sin(dd * freq)
        cs = amp * Math.cos(dd * freq)
        ck = Math.cos(per * freq)
        sk = Math.sin(per * freq)
        g = Math.exp(-(dd * dd) / w2)
        ratio = Math.exp(-(2 * dd * per + per * per) / w2)
        q = Math.exp(-2 * per * per / w2)
        i = lo
        while i < hi
          tab[i] = (sn * g).to_i
          sn, cs = sn * ck + cs * sk, cs * ck - sn * sk
          g *= ratio
          ratio *= q
          i += 1
        end
        band[0] = lo
        band[1] = [hi, lo].max
        n + 1
      end

      def place(n, fx, fy)
        @cxs[n] = (fx * @fw * 2).round.clamp(0, 2 * @fw)
        @cys[n] = (fy * @fh * 2).round.clamp(2, 2 * @fh)
      end

      # ---- light and colour ----------------------------------------------------------------

      def light_lift(kick, snare, t)
        lift = 18 * kick + 22 * snare
        lift += 22 * ((t - RISER) / 4.0).clamp(0.0, 1.0)**2 if t > RISER
        lift
      end

      def fill_light(kick, snare, t)
        lift = light_lift(kick, snare, t)
        rowlev = @rowlev
        vigy = @vigy
        @fh.times { |y| rowlev[y] = (128 + lift + vigy[y]).round }
      end

      WHITE_FROM = 15.1   # the push toward white starts here...
      WHITE_AT = 15.97    # ...and lands here, two frames before the engine's flash takes over

      # The riser's heat: exposure and sheen, colour kept.
      def heat_at(t)
        return 0.0 if t <= RISER

        p = ((t - RISER) / (LENGTH - RISER)).clamp(0.0, 1.0)
        p * p * (3 - 2 * p)
      end

      # The white-out, eased in so it builds with the riser's last beats.
      def white_at(t)
        return 0.0 if t <= WHITE_FROM

        ((t - WHITE_FROM) / (WHITE_AT - WHITE_FROM)).clamp(0.0, 1.0)**1.6
      end

      def palette_at(song_t, t)
        sym = Music.chord_at(song_t).first
        into = song_t % Music::BAR
        m = (into / Music::BEAT).clamp(0.0, 1.0)
        m = m * m * (3 - 2 * m)
        prev = Music.chord_at(song_t - into - 0.01).first
        prev = sym if t < into # the first chord arrives under the flash
        @chord = sym
        @palette.at(prev, sym, m, heat_at(t), white_at(t))
      end

      # ---- the crisp layer -----------------------------------------------------------------

      # How visible a bell ring still is in the pixels: its amplitude, and how sharp the packet
      # still is as it widens. The crisp line follows this, so it never outlives the liquid.
      def bell_vis(age) = bell_fade(age) * 4.5 / (4.5 + 5 * age)

      # hud: the rings and dots; crisp: the note labels and the melody line, which leave first.
      def update_rings(t, hud, crisp)
        return hide_crisp if hud <= 0.0

        slot = 0
        path = []
        newest = 0.0
        clear = @loupe ? @loupe.keep_clear : []
        @drops.each do |d|
          age = t - d.time
          next if age.negative? || age >= LIFE || slot >= BELLS

          r = (3 + 62 * age) / @k
          alpha = 0.85 * bell_vis(age) * hud
          show_ring(slot, d.x, d.y, r, alpha)
          if @panel_on && crisp > 0.0
            show_label(slot, d, [0.95 * crisp, 2.4 * alpha].min, clear)
          else
            hide_label(slot)
          end
          show_dot(slot, d, [hud, 2.8 * alpha].min)
          path << [path.empty? ? "move_to" : "line_to", *screen(d.x, d.y)]
          newest = alpha
          slot += 1
        end
        (slot...BELLS).each do |i|
          hide_ring(i)
          hide_label(i)
          hide_dot(i)
        end
        draw_melody(crisp > 0.0 ? path : [], newest * crisp)
        shock = @shocks.reverse_each.find { |s| t >= s.time && t - s.time < SHOCK_LIFE }
        if shock
          age = t - shock.time
          show_ring(BELLS, shock.x, shock.y, (4 + 150 * age) / @k, 0.5 * fade(age, SHOCK_LIFE) * 7 / (7 + 9 * age) * hud)
        else
          hide_ring(BELLS)
        end
      end

      def hide_crisp
        (BELLS + 1).times { |i| hide_ring(i) }
        BELLS.times do |i|
          hide_label(i)
          hide_dot(i)
        end
        draw_melody([], 0.0)
      end

      # The notes still ringing, joined in the order they were played.
      def draw_melody(path, alpha)
        if path.size < 2
          return if @melody_off

          set(@melody, { stroke: [255, 255, 255, 0] })
          @melody_off = true
          return
        end
        @melody_off = false
        set(@melody, { shape_commands: path, stroke: [255, 255, 255, (90 * [1.0, 2 * alpha].min).round] })
      end

      def screen(fx, fy)
        hx = (fx * @fw * 2).round.clamp(0, 2 * @fw)
        hy = (fy * @fh * 2).round.clamp(2, 2 * @fh)
        [((hx / 2.0 + 0.5) * @sc).round(1), ((hy / 2.0 + 0.5) * @sc).round(1)]
      end

      def show_dot(i, drop, alpha)
        dot = @dots[i]
        if @shown_dots[i] != drop
          x, y = screen(drop.x, drop.y)
          r = 3.0 * u
          set(dot, { left: (x - r).round(1), top: (y - r).round(1), width: (2 * r).round(1), height: (2 * r).round(1), hidden: false })
          @shown_dots[i] = drop
        end
        set(dot, { fill: [255, 255, 255, (alpha * 255).round] })
      end

      def hide_dot(i)
        return if @shown_dots[i] == :off

        set(@dots[i], { hidden: true })
        @shown_dots[i] = :off
      end

      def show_ring(i, fx, fy, r, alpha)
        cx, cy = screen(fx, fy)
        d = (2 * r * @sc).round(1)
        props = { left: (cx - d / 2).round(1), top: (cy - d / 2).round(1), width: d, height: d,
                  stroke: [255, 255, 255, (alpha * 255).round] }
        props[:hidden] = false if @shown_rings[i] != :on
        set(@rings[i], props)
        @shown_rings[i] = :on
      end

      def hide_ring(i)
        return if @shown_rings[i] == :off

        set(@rings[i], { hidden: true })
        @shown_rings[i] = :off
      end

      # A label sits at one corner of its dot, the first of LABEL_SIDES that keeps clear of the
      # loupe's box and lead line, over a one-pixel dark shadow so a white crest cannot swallow it.
      LABEL_SIDES = [[-1, 1], [1, -1], [1, 1], [-1, -1]].freeze

      def show_label(i, drop, alpha, clear)
        label = @labels[i]
        shadow = @shadows[i]
        if @shown_labels[i] != drop
          label.text = drop.label
          shadow.text = drop.label
          @shown_labels[i] = drop
          @label_at[i] = nil
        end
        x, y = label_spot(drop, clear)
        if @label_at[i] != [x, y]
          off = [1, u.round].max
          set(shadow, { left: x + off, top: y + off, hidden: false })
          set(label, { left: x, top: y, hidden: false })
          @label_at[i] = [x, y]
        end
        a = (alpha * 255).round
        set(shadow, { stroke: [6, 5, 13, (a * 0.8).round] })
        set(label, { stroke: [255, 255, 255, a] })
      end

      def label_spot(drop, clear)
        cx, cy = screen(drop.x, drop.y)
        lw = drop.label.size * 7.2 * u
        lh = 15 * u
        spots = LABEL_SIDES.map do |sx, sy|
          x = sx.negative? ? cx - 6 * u - lw : cx + 6 * u
          y = sy.negative? ? cy - 4 * u - lh : cy + 2 * u
          [x, y]
        end
        best = spots.find do |x, y|
          clear.none? { |x0, y0, x1, y1| x < x1 + 3 && x + lw > x0 - 3 && y < y1 + 3 && y + lh > y0 - 3 }
        end
        x, y = best || spots.first
        [x.round, y.round]
      end

      def hide_label(i)
        return if @shown_labels[i] == :off

        set(@labels[i], { hidden: true })
        set(@shadows[i], { hidden: true })
        @shown_labels[i] = :off
      end

      # ---- the panel: what is being computed, live ------------------------------------------

      def build_panel
        @panel_on = u >= 0.5 && ENV["DIEM_PLASMA_BARE"].to_s.empty?
        return unless @panel_on

        size = (13 * u).round
        pixels = (@fw * @fh).to_s.reverse.scan(/\d{1,3}/).join(",").reverse
        gold = "#{pixels} pixels a frame, every one computed in Ruby"
        widest = [FORMULA, format(FORMULA2, 10), gold, live_line(99.0, 99.0, 1.16, :dm)].map(&:size).max
        x = (24 * u).round
        pw = (widest * 0.6 * size + 32 * u).round # Menlo advances 0.6 em
        ph = (106 * u).round
        y = (h - ph - 24 * u).round
        @panel_box = [x, y, pw, ph]
        @panel = rect(x, y, pw, ph, (10 * u).round, fill: rgb(*PANEL), stroke: rgb(*PANEL_EDGE), strokewidth: 1)
        mono = { font: "Menlo, monospace", margin: 0, size: size }
        tx = x + (16 * u).round
        ink = [*Palette::INK, 255]
        f1 = para FORMULA, left: tx, top: y + (14 * u).round, stroke: rgb(*ink), **mono
        @formula2 = para "", left: tx, top: y + (33 * u).round, stroke: rgb(*ink), **mono
        g = para gold, left: tx, top: y + (58 * u).round, stroke: Palette.rgb(Palette::GOLD), **mono
        @live = para "", left: tx, top: y + (77 * u).round, stroke: Palette.rgb(Palette::MUTED), **mono
        @panel_text = [[f1, ink], [@formula2, ink], [g, [*Palette::GOLD, 255]], [@live, [*Palette::MUTED, 255]]]
      end

      def build_guide
        lx = @loupe.rect[0]
        blocked = [@panel_box, [lx, 0, w - lx, h]]
        @guide = PlasmaGuide.new(@fw, @fh, @sc, @k, blocked, 10 * u, PlasmaLoupe::N / 2, self)
      end

      # The guide's path through the scene, worked out while the show loads. Only the show's own
      # start is known here; anywhere else (a lab seek past the start) it is stepped on demand.
      def warm_guide
        start = PLAN.find { |name, *| name == "Plasma" }&.[](1)
        return unless start

        plan(start * Music::BAR)
        @guide.prepare(RISER) { breathe }
      end

      public

      # ---- the field, read back analytically (for the loupe's guide) ------------------------

      Snap = Struct.new(:tau, :zoom, :lift, :base, :waves, :zx, :zy, :lev)

      # Everything that shapes the height field at t, in framebuffer pixels.
      def snapshot(t)
        tau = warp(t)
        kick = kick_at(t)
        zoom = 1.0 + KICK_ZOOM * kick
        base = base_ripples(tau).map { |fx, fy, freq, speed| [fx * @fw, fy * @fh, @k * freq / zoom, tau * speed] }
        waves = waves_at(t).map { |fx, fy, r, wd, freq, amp| [fx * @fw, fy * @fh, r / @k, wd / @k, freq * @k, amp] }
        Snap.new(tau, zoom, light_lift(kick, snare_at(t), t), base, waves, *kick_centre(t), @levs[squeeze(kick)])
      end

      # The light level (0...NL) the kernel gives pixel x, y, without the dither.
      def light(sn, x, y)
        v = height(sn, x, y)
        li = ((2 * v - height(sn, x - 1, y) - height(sn, x, y - 1)).to_i >> 4) + 128 + sn.lift + @vigy[y] + @vigx[0][0][x]
        sn.lev[li.round.clamp(0, PlasmaField::LIGHT - 1)] / PlasmaField::HUES
      end

      private

      def height(sn, x, y)
        k = @k
        kz = @k * (1.0 / sn.zoom - 1.0)
        tau = sn.tau
        xc = (x - @fw / 2.0) * k + (x - sn.zx) * kz
        yc = (y - @fh / 2.0) * k + (y - sn.zy) * kz
        dc = (x + y - (@fw + @fh) / 2.0) * k + (x + y - sn.zx - sn.zy) * kz
        v = 2600 * Math.sin(xc * 0.052 + tau * 0.9) + 1500 * Math.sin(xc * 0.019 - tau * 0.41 + 1.3) +
          2600 * Math.sin(yc * 0.064 - tau * 1.1) + 1200 * Math.sin(yc * 0.027 + tau * 0.6) +
          1700 * Math.sin(dc * 0.034 + tau * 0.7)
        sn.base.each { |cx, cy, kf, ph| v += 1800 * Math.sin(Math.hypot(x - cx, y - cy) * kf - ph) }
        sn.waves.each do |cx, cy, r, wd, freq, amp|
          dd = Math.hypot(x - cx, y - cy) - r
          v += amp * Math.sin(dd * freq) * Math.exp(-(dd * dd) / (wd * wd)) if dd.abs < 3 * wd
        end
        v
      end

      def live_line(tau, t, zoom, chord)
        format("t %05.2f  at %05.2f s  zoom %.2f  chord %s", tau, t, zoom, chord.to_s.capitalize)
      end

      # The text leaves first (alpha only), then the panel itself: a dark panel at falling alpha
      # over a field going white just thins away, with no grey ghost lettering left on it.
      def fade_panel(text, panel)
        return if [text, panel] == @hud

        @hud = [text, panel]
        show_part(@panel, panel) { set(@panel, { fill: dim(PANEL, panel), stroke: dim(PANEL_EDGE, panel) }) }
        @panel_text.each { |para, c| show_part(para, text) { set(para, { stroke: dim(c, text) }) } }
      end

      def show_part(d, a)
        @parts_off ||= {}.compare_by_identity
        if a <= 0.0
          set(d, { hidden: true }) unless @parts_off[d]
          @parts_off[d] = true
          return
        end
        set(d, { hidden: false }) if @parts_off[d]
        @parts_off[d] = false
        yield
      end

      def dim(c, a) = [c[0], c[1], c[2], (c[3] * a).round]

      # The ring count changes a few times a second; the live line is held to 15 Hz.
      def update_panel(t, tau, zoom, terms)
        text2 = format(FORMULA2, terms - 2)
        if text2 != @formula_text
          @formula2.text = text2
          @formula_text = text2
        end
        tick = (t * 15).floor
        return if tick == @live_tick

        @live_tick = tick
        live = live_line(tau, t, zoom, @chord)
        return if live == @live_text

        @live.text = live
        @live_text = live
      end
    end
  end
end
