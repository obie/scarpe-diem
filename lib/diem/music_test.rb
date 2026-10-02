# frozen_string_literal: true

# A 16-bar A-minor test groove (Am F C G) that exercises every synth track.
#
# Score format, shared with lib/diem/music.rb:
#   Diem::Music.score  # => frozen Hash, track Symbol => Array of events
#   event = [step, len_steps, midi_or_nil, velocity_0_to_1, opts_or_nil]
#     step       Integer 16th-note index from the start of the song
#     len_steps  duration in 16ths (Integer or Float)
#     opts       optional :cut (0..1 filter openness), :pan (-1..1),
#                :glide (lead only: portamento from the previous note),
#                :dec (decay multiplier)
module Diem
  module MusicTest
    BPM = 120.0
    BEAT = 60.0 / BPM
    STEP = BEAT / 4
    BAR = BEAT * 4
    BARS = 16
    LENGTH = BARS * BAR

    CHORDS = [
      { root: 33, pad: [57, 60, 64], arp: [69, 72, 76, 81] }, # Am
      { root: 29, pad: [53, 57, 60], arp: [65, 69, 72, 77] }, # F
      { root: 36, pad: [55, 60, 64], arp: [67, 72, 76, 79] }, # C
      { root: 31, pad: [55, 59, 62], arp: [67, 71, 74, 79] }  # G
    ].freeze

    # One bar of lead per chord: [step_in_bar, len, midi, glide]
    MELODY = [
      [[0, 6, 76, false], [6, 2, 74, false], [8, 4, 72, false], [12, 4, 74, true]],
      [[0, 8, 72, false], [8, 4, 69, false], [12, 4, 72, true]],
      [[0, 6, 76, false], [6, 2, 79, true], [8, 8, 76, false]],
      [[0, 4, 74, false], [4, 4, 71, false], [8, 8, 74, true]]
    ].freeze

    def self.score
      @score ||= build.transform_values { |events| events.map(&:freeze).freeze }.freeze
    end

    def self.build
      tracks = Hash.new { |h, k| h[k] = [] }
      BARS.times do |bar|
        at = bar * 16
        chord = CHORDS[bar % 4]
        drums(tracks, bar, at)
        harmony(tracks, bar, at, chord)
        lead(tracks, bar, at) if bar >= 4
      end
      fx(tracks)
      tracks.to_h
    end

    def self.drums(tracks, bar, at)
      4.times { |beat| tracks[:kick] << [at + (beat * 4), 2, nil, 1.0, nil] }
      [4, 12].each { |s| tracks[:snare] << [at + s, 2, nil, 0.9, nil] }
      tracks[:clap] << [at + 12, 2, nil, 0.8, nil] if bar >= 8
      16.times do |s|
        next if bar >= 8 && s % 4 == 2 # open hats take these

        tracks[:hat] << [at + s, 1, nil, s.even? ? 0.8 : 0.45, nil]
      end
      [2, 6, 10, 14].each { |s| tracks[:ohat] << [at + s, 2, nil, 0.7, nil] } if bar >= 8
    end

    def self.harmony(tracks, bar, at, chord)
      root = chord[:root]
      8.times do |e|
        note = e.odd? ? root + 12 : root
        tracks[:bass] << [at + (e * 2), 2, note, e.odd? ? 0.75 : 0.95, { cut: 0.25 + (0.04 * (bar % 8)) }]
      end
      tracks[:sub] << [at, 16, root, 0.8, nil]
      chord[:pad].each { |m| tracks[:pad] << [at, 16, m, 0.7, { cut: 0.4 }] }
      16.times do |s|
        tracks[:arp] << [at + s, 1, chord[:arp][s % 4], s % 4 == 0 ? 0.9 : 0.65, { cut: 0.3 + (0.04 * bar) }]
      end
      tracks[:bell] << [at, 8, chord[:arp][2], 0.7, nil] if bar.even?
    end

    def self.lead(tracks, bar, at)
      MELODY[bar % 4].each do |step, len, midi, glide|
        tracks[:lead] << [at + step, len, midi, 0.85, glide ? { glide: true } : nil]
      end
    end

    def self.fx(tracks)
      [0, 8].each do |bar|
        tracks[:crash] << [bar * 16, 16, nil, 0.8, nil]
        tracks[:impact] << [bar * 16, 16, nil, 0.9, nil]
      end
      [6, 14].each { |bar| tracks[:riser] << [bar * 16, 32, nil, 0.8, nil] }
    end
  end
end
