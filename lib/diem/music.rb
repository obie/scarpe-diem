# frozen_string_literal: true

# The score of SCARPE DIEM: synthwave in A minor at 120 bpm, 96 bars (3:12), lifting to B minor
# for the climax. It is plain data, built by the code below, and both the synthesizer (which
# plays it) and the scenes (which dance to it, through Diem::Sync) read the same events.
#
# An event is [step, len_steps, midi_note_or_nil, velocity, opts_or_nil]; a step is a 16th note.
module Diem
  module Music
    BPM = 120.0
    BEAT = 60.0 / BPM
    STEP = BEAT / 4
    BAR = BEAT * 4
    BARS = 96
    LENGTH = BARS * BAR

    PITCH = { "C" => 0, "C#" => 1, "Db" => 1, "D" => 2, "D#" => 3, "Eb" => 3, "E" => 4, "F" => 5,
              "F#" => 6, "Gb" => 6, "G" => 7, "G#" => 8, "Ab" => 8, "A" => 9, "A#" => 10, "Bb" => 10, "B" => 11 }.freeze

    # Pad voicings, voice-led so each chord moves as little as it can into the next.
    CHORDS = {
      am: [57, 60, 64], f: [57, 60, 65], c: [55, 60, 64], g: [55, 59, 62],
      dm: [57, 62, 65], e: [56, 59, 64], em: [55, 59, 64],
    }.freeze
    ROOTS = { am: 45, f: 41, c: 36, g: 43, dm: 38, e: 40, em: 40 }.freeze

    MAIN = %i[am f c g].freeze       # i  VI  III VII
    GROOVE = %i[dm am f e].freeze    # iv i   VI  V
    DREAM = %i[f g em am].freeze     # VI VII v   i

    # [first bar, last bar + 1, progression, semitones up, name]
    SECTIONS = [
      [0, 8, MAIN, 0, :intro],
      [8, 16, MAIN, 0, :drop],
      [16, 24, MAIN, 0, :theme_a],
      [24, 32, GROOVE, 0, :groove],
      [32, 40, MAIN, 0, :theme_b],
      [40, 48, MAIN, 0, :theme_a2],
      [48, 56, DREAM, 0, :breakdown],
      [56, 64, MAIN, 0, :drop2],
      [64, 72, MAIN, 0, :theme_b2],
      [72, 80, MAIN, 2, :climax_a],
      [80, 88, MAIN, 2, :climax_b],
      [88, 96, DREAM, 2, :outro],
    ].freeze

    THEME_A = "E5:8 D5:4 C5:4 | C5:6 D5:2 C5:4 A4:4 | G4:8 C5:4 E5:4 | D5:12 B4:2 D5:2 | " \
              "E5:8 G5:4 A5:4 | A5:6 G5:2 F5:4 E5:4 | E5:4 D5:4 C5:4 E5:4 | D5:16"
    THEME_B = "A4:2 C5:2 E5:2 A5:4 G5:2 E5:4 | F5:6 E5:2 C5:4 A4:4 | G4:2 C5:2 E5:2 G5:4 E5:2 C5:4 | B4:6 D5:2 G5:8 | " \
              "A5:2 B5:2 C6:4 B5:2 A5:2 E5:4 | F5:4 A5:4 C6:6 A5:2 | G5:4 E5:4 C5:4 E5:4 | D5:4 B4:4 D5:4 G5:4"
    GROOVE_BELL = "A5:3 F5:3 D5:2 r:8 | E5:3 C5:3 A4:2 r:8 | C6:3 A5:3 F5:2 r:8 | B5:3 G#5:3 E5:2 r:8"
    DREAM_BELL = "C6:8 A5:8 | B5:8 D6:8 | G5:16 | A5:12 r:4 | C6:8 A5:8 | D6:8 B5:8 | E6:8 B5:8 | A5:16"

    A_MINOR = [9, 11, 0, 2, 4, 5, 7].freeze # pitch classes A B C D E F G

    class << self
      def score
        @score ||= Composer.new.compose.freeze
      end

      def midi(name)
        m = name.match(/\A([A-G][#b]?)(-?\d)\z/) || raise(ArgumentError, "bad note #{name}")
        PITCH.fetch(m[1]) + (m[2].to_i + 1) * 12
      end

      # [first bar, last bar + 1, progression, transpose, name] of the section holding bar.
      def section(bar)
        SECTIONS.find { |from, to, *| bar >= from && bar < to } || SECTIONS.last
      end

      def section_at(t) = section((t / BAR).floor)[4]

      # The chord under song time t: [symbol, pad notes, bass root], transposed.
      def chord_at(t)
        bar = (t / BAR).floor.clamp(0, BARS - 1)
        from, _, prog, up, = section(bar)
        sym = prog[(bar - from) % prog.size]
        [sym, CHORDS[sym].map { |n| n + up }, ROOTS[sym] + up]
      end

      # A note moved along the A minor scale by `degrees` (a third below is -2).
      def diatonic(note, degrees)
        n = note
        degrees.abs.times do
          loop do
            n += degrees.positive? ? 1 : -1
            break if A_MINOR.include?(n % 12)
          end
        end
        n
      end
    end

    # Writes the events, section by section.
    class Composer
      def initialize
        @tracks = Hash.new { |h, k| h[k] = [] }
        @rand = Random.new(1609) # the same humanising every time
      end

      def compose
        SECTIONS.each { |from, to, prog, up, name| section(from, to, prog, up, name) }
        accents
        @tracks.transform_values { |evs| evs.sort_by(&:first).map(&:freeze).freeze }
      end

      private

      def add(track, step, len, note, vel, opts = nil)
        @tracks[track] << [step, len, note, vel.round(3), opts]
      end

      def human(vel, amount = 0.06) = (vel + @rand.rand(-amount..amount)).clamp(0.05, 1.0)

      def bar_step(bar) = bar * 16

      def section(from, to, prog, up, name)
        (from...to).each do |bar|
          sym = prog[(bar - from) % prog.size]
          last_of_section = bar == to - 1
          pads(bar, sym, up, name, last_of_section)
          bass(bar, sym, up, name)
          arp(bar, sym, up, name, from, last_of_section)
          drums(bar, name, last_of_section)
        end
        melodies(from, up, name)
      end

      # ---- harmony ----------------------------------------------------------------------

      def pads(bar, sym, up, name, last)
        vel = { intro: 0.42, breakdown: 0.5, outro: 0.5 }.fetch(name, 0.36)
        len = 16
        len = 12 if last && %i[intro breakdown].include?(name) # the breath before a drop
        len = 32 if name == :outro && bar == 94
        return if name == :outro && bar == 95

        CHORDS[sym].each { |n| add(:pad, bar_step(bar), len, n + up, vel) }
        add(:pad, bar_step(bar), len, CHORDS[sym].first + up - 12, vel * 0.6) if %i[breakdown outro].include?(name)
      end

      def bass(bar, sym, up, name)
        root = ROOTS[sym] + up
        s = bar_step(bar)
        case name
        when :intro, :outro
          nil
        when :breakdown
          add(:sub, s, 16, root, 0.55)
        when :groove
          [[0, 3, 0], [3, 1, 0], [6, 2, 12], [8, 2, 0], [11, 1, 0], [12, 2, 0], [14, 2, 12]].each do |at, len, oct|
            add(:bass, s + at, len, root + oct, human(oct.zero? ? 0.9 : 0.75), { cut: 0.5 })
          end
        when :climax_a, :climax_b
          16.times do |i|
            oct = i % 4 == 2 ? 12 : 0
            add(:bass, s + i, 0.9, root + oct, human(i.even? ? 0.85 : 0.65), { cut: 0.62 })
          end
          add(:sub, s, 16, root, 0.4)
        else
          8.times do |i|
            add(:bass, s + i * 2, 1.7, root + (i.odd? ? 12 : 0), human(i.even? ? 0.9 : 0.72), { cut: name == :drop2 ? 0.6 : 0.5 })
          end
          add(:sub, s, 16, root, 0.35) if %i[drop2 theme_b2].include?(name)
        end
      end

      # 16ths over the chord, rising and falling over six steps so it rolls against the bar.
      def arp(bar, sym, up, name, from, last)
        tones = CHORDS[sym].map { |n| n + 12 + up } + [CHORDS[sym].first + 24 + up]
        shape = [0, 1, 2, 3, 2, 1]
        cut = case name
              when :intro then 0.12 + 0.78 * ((bar - from) / 8.0)
              when :breakdown, :outro then 0.32
              when :groove then 0.55
              else 0.78
              end
        vel = %i[breakdown outro].include?(name) ? 0.42 : 0.55
        16.times do |i|
          next if last && name == :intro && i >= 12

          k = bar_step(bar) + i
          add(:arp, k, 1.5, tones[shape[k % 6]], human((i % 4).zero? ? vel + 0.18 : vel, 0.04), { cut: cut.round(3) })
        end
      end

      # ---- drums ------------------------------------------------------------------------

      def drums(bar, name, last)
        s = bar_step(bar)
        case name
        when :intro
          4.times { |b| add(:hat, s + b * 4 + 2, 1, nil, 0.12 + 0.02 * (bar - 4)) } if bar >= 4
        when :breakdown, :outro
          nil
        when :groove
          [0, 10].each { |at| add(:kick, s + at, 2, nil, 1.0) }
          add(:snare, s + 8, 2, nil, 0.95)
          add(:clap, s + 8, 2, nil, 0.55)
          16.times { |i| add(:hat, s + i, 1, nil, human(i.even? ? 0.42 : 0.22)) }
          add(:ohat, s + 14, 2, nil, 0.35) if bar.odd?
        else
          4.times { |b| add(:kick, s + b * 4, 2, nil, 1.0) }
          [4, 12].each do |at|
            add(:snare, s + at, 2, nil, human(0.92, 0.03))
            add(:clap, s + at, 2, nil, 0.5)
          end
          open = %i[theme_a theme_a2 drop2 theme_b2 climax_a climax_b].include?(name)
          16.times do |i|
            if open && i % 4 == 2
              add(:ohat, s + i, 2, nil, human(0.38, 0.03))
            else
              add(:hat, s + i, 1, nil, human(i % 4 == 2 ? 0.55 : 0.26))
            end
          end
        end
        fill(s) if last && !%i[intro groove breakdown outro theme_b2].include?(name)
        roll(s) if last && name == :breakdown
      end

      def fill(s)
        [12, 13, 14, 15].each_with_index { |at, i| add(:snare, s + at, 1, nil, 0.55 + i * 0.12) }
      end

      # Two bars of snare climbing from 8ths to 16ths into the second drop.
      def roll(s)
        prev = s - 16
        8.times { |i| add(:snare, prev + i * 2, 1, nil, 0.2 + i * 0.03) }
        16.times { |i| add(:snare, s + i, 1, nil, 0.42 + i * 0.035) }
      end

      # Crashes, impacts and risers at the seams.
      def accents
        [8, 16, 24, 32, 40, 56, 64, 72, 80, 88].each { |bar| add(:crash, bar_step(bar), 16, nil, 0.7) }
        [76, 84].each { |bar| add(:crash, bar_step(bar), 16, nil, 0.45) }
        [8, 56, 72, 88].each { |bar| add(:impact, bar_step(bar), 32, nil, 0.9) }
        [[6, 2], [30, 2], [54, 2], [70, 2], [86, 2]].each { |bar, bars| add(:riser, bar_step(bar), bars * 16, nil, 0.6) }
      end

      # ---- melodies ---------------------------------------------------------------------

      def melodies(from, up, name)
        s = bar_step(from)
        case name
        when :theme_a then line(:lead, THEME_A, s, up, 0.8)
        when :theme_b then line(:lead, THEME_B, s, up, 0.8)
        when :theme_a2
          line(:lead, THEME_A, s, up, 0.8)
          line(:lead2, THEME_A, s, up, 0.5, third: -2)
        when :theme_b2
          line(:lead, THEME_B, s, up, 0.8)
          line(:lead2, THEME_B, s, up, 0.5, third: -2)
        when :climax_a
          line(:lead, THEME_A, s, up, 0.85)
          line(:bell, THEME_A, s, up + 12, 0.35)
        when :climax_b
          line(:lead, THEME_B, s, up, 0.85)
          line(:lead2, THEME_B, s, up, 0.5, third: -2)
          line(:bell, THEME_B, s, up + 12, 0.3)
        when :groove
          2.times { |k| line(:bell, GROOVE_BELL, s + k * 64, up, 0.55) }
        when :breakdown, :outro
          line(:bell, DREAM_BELL, s, up, 0.6)
        end
      end

      # Writes a melody string ("E5:8 r:4 | ...") from step s; third shifts it along the scale.
      def line(track, text, s, up, vel, third: nil)
        check_bars(text)
        at = s
        text.split.each do |tok|
          next if tok == "|"

          name, len = tok.split(":")
          len = len.to_i
          unless name == "r"
            n = Music.midi(name)
            n = Music.diatonic(n, third) if third
            add(track, at, len, n + up, human(vel, 0.04), track == :lead && len <= 2 ? { glide: true } : nil)
          end
          at += len
        end
      end

      def check_bars(text)
        text.split("|").each_with_index do |bar, i|
          sum = bar.split.sum { |tok| tok.split(":").last.to_i }
          raise ArgumentError, "melody bar #{i + 1} has #{sum} steps, not 16: #{bar.strip}" unless sum == 16
        end
      end
    end
  end
end
