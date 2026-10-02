# frozen_string_literal: true

# What the music is doing at time t, read from the same score the synthesizer plays, so a
# scene can flash on the kick or lean on the bass note without guessing.
module Diem
  class Sync
    Hit = Struct.new(:time, :step, :len, :note, :vel, :opts)

    attr_reader :t

    def initialize(score)
      @hits = {}
      @times = {}
      score.each do |track, events|
        hits = events.map { |s, len, note, vel, opts| Hit.new(s * Music::STEP, s, len, note, vel || 1.0, opts) }
        hits.sort_by!(&:time)
        @hits[track] = hits
        @times[track] = hits.map(&:time)
      end
      @t = 0.0
      @memo = {}
    end

    # Moves the cursor; every question below is about this moment.
    def at(t)
      @t = t
      @memo.clear
      self
    end

    def bar = @t / Music::BAR
    def beat = @t / Music::BEAT
    def step = @t / Music::STEP
    def beat_phase = beat % 1.0
    def bar_phase = bar % 1.0

    # The latest hit on a track at or before now, or nil.
    def last(track)
      @memo.fetch(track) do
        times = @times[track]
        if times.nil? || times.empty?
          @memo[track] = nil
        else
          i = times.bsearch_index { |x| x > @t + 1e-9 } || times.size
          @memo[track] = i.zero? ? nil : @hits[track][i - 1]
        end
      end
    end

    # 1.0 the instant a hit lands (scaled by its velocity), falling away with time constant tau.
    def hit(track, tau = 0.15)
      h = last(track)
      return 0.0 unless h

      h.vel * Math.exp(-(@t - h.time) / tau)
    end

    # Seconds since the latest hit, or a large number before the first one.
    def since(track)
      h = last(track)
      h ? @t - h.time : 1e9
    end

    # How many hits have landed so far (handy for alternating colours per kick).
    def count(track)
      times = @times[track]
      return 0 unless times

      times.bsearch_index { |x| x > @t + 1e-9 } || times.size
    end

    # The MIDI note of the latest event on a track, or nil.
    def note(track)
      last(track)&.note
    end

    # True while the latest event on the track is still held.
    def sounding?(track)
      h = last(track)
      h ? @t < h.time + h.len * Music::STEP : false
    end

    # Every hit on a track between two times, for scenes that pre-plan choreography.
    def hits_between(track, from, to)
      (@hits[track] || []).select { |h| h.time >= from && h.time < to }
    end

    def hits(track) = @hits[track] || []
  end
end
