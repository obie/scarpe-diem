# frozen_string_literal: true

require "fileutils"

# Plays the soundtrack through afplay and can start it anywhere: afplay has no seek, so a seek
# writes the rest of the song to a new WAV and plays that. Silent where afplay is missing.
module Diem
  class Audio
    attr_reader :path

    def initialize(path)
      @path = path
      @pid = nil
      @flip = 0
      at_exit { stop }
    end

    # Starts the song at `from` seconds. Returns the monotonic time sound should begin.
    def play(from = 0.0)
      stop
      file = from <= 0.005 ? @path : slice(from)
      @pid = spawn("afplay", file, out: File::NULL, err: File::NULL)
      Process.detach(@pid)
      now + AUDIO_LATENCY
    rescue SystemCallError
      @pid = nil
      now
    end

    def stop
      return unless @pid

      Process.kill("TERM", @pid)
    rescue SystemCallError
      nil
    ensure
      @pid = nil
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The song from `from` seconds on, as its own WAV.
    def slice(from)
      read_song
      offset = (from * @rate).floor * @frame_bytes
      data = @data.byteslice(offset..) || "".b
      @flip ^= 1
      out = File.join(File.dirname(@path), "from-here-#{@flip}.wav")
      File.binwrite(out, header(data.bytesize) + data)
      out
    end

    def read_song
      return if @data

      bytes = File.binread(@path)
      @channels, @rate = bytes.byteslice(22, 6).unpack("vV")
      bits = bytes.byteslice(34, 2).unpack1("v")
      @frame_bytes = @channels * bits / 8
      at = bytes.index("data", 12)
      size = bytes.byteslice(at + 4, 4).unpack1("V")
      @data = bytes.byteslice(at + 8, size)
    end

    def header(size)
      ["RIFF", 36 + size, "WAVE", "fmt ", 16, 1, @channels, @rate, @rate * @frame_bytes, @frame_bytes, 16, "data", size]
        .pack("a4Va4a4VvvVVvva4V")
    end
  end
end
