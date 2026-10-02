# frozen_string_literal: true

# Window size, frame rates and the palette every scene shares.
module Diem
  ROOT = File.expand_path("../..", __dir__)

  # DIEM_SIZE=1280x720 makes a bigger window; every scene draws in units of U.
  W, H = (ENV["DIEM_SIZE"] || "960x540").split("x").map(&:to_i)
  U = H / 540.0

  FPS = 60

  # Filled by the engine as the show runs (and read by the credits).
  def self.stats = (@stats ||= {})
  RECORD = !ENV["DIEM_RECORD"].to_s.empty?
  RECORD_FPS = (ENV["DIEM_RECORD_FPS"] || 60).to_i

  # Seconds between spawning afplay and hearing the first sample.
  AUDIO_LATENCY = (ENV["DIEM_AUDIO_LATENCY"] || 0.06).to_f

  DATA_DIR = if RUBY_PLATFORM.include?("darwin")
    File.join(Dir.home, "Library", "Application Support", "Scarpe Diem")
  else
    File.join(ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share")), "scarpe_diem")
  end

  # Colours as [r, g, b] so scenes can mix them; Palette.rgb turns one into a Shoes colour.
  module Palette
    NIGHT   = [6, 5, 13]
    INK     = [244, 241, 255]
    MUTED   = [140, 134, 178]
    MAGENTA = [255, 46, 136]
    CYAN    = [0, 229, 255]
    GOLD    = [255, 201, 77]
    VIOLET  = [123, 92, 255]
    RUBY    = [224, 17, 95]
    EMBER   = [255, 106, 61]
    MINT    = [61, 255, 176]

    module_function

    def mix(a, b, t)
      [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
    end

    def scale(c, k)
      [c[0] * k, c[1] * k, c[2] * k]
    end

    # A Shoes colour; channels are clamped and rounded so a Float never reads as a fraction.
    def rgb(c, alpha = nil)
      r = c[0].round.clamp(0, 255)
      g = c[1].round.clamp(0, 255)
      b = c[2].round.clamp(0, 255)
      Shoes::Color[r, g, b, alpha ? (alpha.clamp(0.0, 1.0) * 255).round : 255]
    end

    def hex(c)
      format("#%02x%02x%02x", *c.map { |v| v.round.clamp(0, 255) })
    end

    # n colours along a ramp of stops, ready to hand to style(fill:) every frame.
    def ramp(stops, n, alpha: nil)
      Array.new(n) do |i|
        x = i.fdiv(n - 1) * (stops.size - 1)
        k = [x.floor, stops.size - 2].min
        rgb(mix(stops[k], stops[k + 1], x - k), alpha)
      end
    end
  end
end
