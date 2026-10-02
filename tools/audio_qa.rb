# frozen_string_literal: true

# Measures a 16-bit PCM WAV and draws pictures of it, for judging a mix you
# cannot hear.
#
#   ruby tools/audio_qa.rb WAV [--window START:SECONDS]
#
# Prints duration, format, peak, RMS (overall, per 8-bar section at 120 BPM
# and per band), clipped samples, DC offset per channel and the longest run of
# near-silence. Writes a spectrogram (linear and log frequency) and a waveform
# PNG into shots/audio/. --window also draws a zoomed spectrogram and waveform
# of that stretch, where clicks show up as vertical lines.

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable) && !RubyVM::YJIT.enabled?

module AudioQA
  FFMPEG = File.exist?("/opt/homebrew/bin/ffmpeg") ? "/opt/homebrew/bin/ffmpeg" : "ffmpeg"
  OUT_DIR = File.expand_path("../shots/audio", __dir__)
  SECTION = 16.0      # 8 bars at 120 BPM
  SILENCE = 1e-3      # |sample| below this fraction of full scale counts as silent
  CLIP = 32_767

  Wav = Struct.new(:rate, :channels, :bits, :data)

  module_function

  def read_wav(path)
    bytes = File.binread(path)
    raise "#{path}: not a RIFF/WAVE file" unless bytes[0, 4] == "RIFF" && bytes[8, 4] == "WAVE"

    wav = Wav.new
    pos = 12
    while pos + 8 <= bytes.bytesize
      id, size = bytes[pos, 8].unpack("a4V")
      body = pos + 8
      if id == "fmt "
        _format, wav.channels, wav.rate, _rate, _align, wav.bits = bytes[body, 16].unpack("vvVVvv")
      elsif id == "data"
        wav.data = bytes[body, size]
      end
      pos = body + size + (size & 1)
    end
    raise "#{path}: only 16-bit PCM is supported" unless wav.bits == 16

    wav
  end

  def channels(wav)
    samples = wav.data.unpack("s<*")
    count = wav.channels
    Array.new(count) { |c| (c...samples.size).step(count).map { |i| samples[i] } }
  end

  def report(path, window)
    wav = read_wav(path)
    chans = channels(wav)
    frames = chans.first.size
    puts "file        #{path}"
    puts format("duration    %.3f s (%d frames)", frames.fdiv(wav.rate), frames)
    puts "format      #{wav.rate} Hz, #{wav.channels} ch, #{wav.bits}-bit"
    levels(chans, wav.rate)
    sections(chans, wav.rate)
    bands(chans, wav.rate)
    silence(chans, wav.rate)
    pictures(path, window)
  end

  def levels(chans, _rate)
    peak = chans.map { |c| c.max_by(&:abs).abs }.max
    clipped = chans.sum { |c| c.count { |v| v.abs >= CLIP } }
    puts format("peak        %.4f FS (%.2f dBFS)", peak / 32_768.0, db(peak / 32_768.0))
    puts format("rms         %.4f FS (%.2f dBFS)", rms(chans), db(rms(chans)))
    puts format("crest       %.2f dB", db(peak / 32_768.0) - db(rms(chans)))
    puts "clipped     #{clipped} samples"
    chans.each_with_index { |c, i| puts format("dc ch%-6d %.6f FS", i, c.sum.fdiv(c.size) / 32_768.0) }
  end

  def sections(chans, rate)
    size = (SECTION * rate).round
    count = (chans.first.size.to_f / size).ceil
    count.times do |k|
      slice = chans.map { |c| c[k * size, size] }
      puts format("section %2d  bars %3d-%3d  rms %.4f (%.1f dBFS)", k + 1, (k * 8) + 1, (k + 1) * 8, rms(slice), db(rms(slice)))
    end
  end

  # One-pole band split: below 200 Hz, 200 Hz to 4 kHz, above 4 kHz (of the mono sum).
  def bands(chans, rate)
    mono = chans.transpose.map { |frame| frame.sum.fdiv(frame.size) }
    low = one_pole(mono, 200.0, rate)
    lowmid = one_pole(mono, 4000.0, rate)
    high = mono.each_index.map { |i| mono[i] - lowmid[i] }
    mid = lowmid.each_index.map { |i| lowmid[i] - low[i] }
    { "low <200" => low, "mid" => mid, "high >4k" => high }.each do |name, band|
      puts format("band %-9s rms %.4f (%.1f dBFS)", name, rms([band]), db(rms([band])))
    end
  end

  def one_pole(signal, cutoff, rate)
    a = Math.exp(-2.0 * Math::PI * cutoff / rate)
    y = 0.0
    signal.map { |x| y = ((1.0 - a) * x) + (a * y) }
  end

  def silence(chans, rate)
    limit = SILENCE * 32_768.0
    best = run = 0
    best_end = 0
    chans.first.each_index do |i|
      if chans.all? { |c| c[i].abs < limit }
        run += 1
        if run > best
          best = run
          best_end = i
        end
      else
        run = 0
      end
    end
    start = (best_end - best + 1).fdiv(rate)
    puts format("silence     longest %.3f s below %.0e FS (from %.3f s)", best.fdiv(rate), SILENCE, best.zero? ? 0.0 : start)
  end

  def rms(chans)
    sum = 0.0
    count = 0
    chans.each do |c|
      c.each { |v| sum += v * v }
      count += c.size
    end
    count.zero? ? 0.0 : Math.sqrt(sum / count) / 32_768.0
  end

  def db(value) = value.positive? ? 20.0 * Math.log10(value) : -Float::INFINITY

  def pictures(path, window)
    Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)
    base = File.join(OUT_DIR, File.basename(path, ".*"))
    draw(path, "#{base}_spectrum.png", "showspectrumpic=s=1600x800:legend=1")
    draw(path, "#{base}_spectrum_log.png", "showspectrumpic=s=1600x800:legend=1:fscale=log")
    draw(path, "#{base}_wave.png", "showwavespic=s=1600x400")
    return unless window

    start, seconds = window.split(":").map(&:to_f)
    trim = ["-ss", start.to_s, "-t", seconds.to_s]
    tag = format("%s_at%.1f", base, start)
    draw(path, "#{tag}_spectrum.png", "showspectrumpic=s=1600x800:legend=1", trim)
    draw(path, "#{tag}_wave.png", "showwavespic=s=1600x400:split_channels=1", trim)
  end

  def draw(path, png, filter, trim = [])
    ok = system(FFMPEG, "-y", "-v", "error", *trim, "-i", path, "-lavfi", filter, "-frames:v", "1", png)
    puts ok ? "wrote       #{png}" : "ffmpeg failed for #{png}"
  end

  def main(argv)
    args = argv.dup
    window = (i = args.index("--window")) ? args.slice!(i, 2).last : nil
    path = args.first
    abort "usage: ruby tools/audio_qa.rb WAV [--window START:SECONDS]" unless path && File.exist?(path)

    report(File.expand_path(path), window)
  end
end

AudioQA.main(ARGV) if $PROGRAM_NAME == __FILE__
