# frozen_string_literal: true

# Records SCARPE DIEM to video, frame-exact: each frame is drawn by the real renderer, headless,
# at 2x (1920x1080 from the 960x540 window) and saved as a PNG; chunks of frames render in
# parallel processes, each chunk is encoded as soon as it is done (and its PNGs deleted), then the
# segments are joined and the synthesized soundtrack is laid under them.
#
#   ruby tools/record.rb                      the whole demo
#   ruby tools/record.rb --from 32 --to 48    seconds 32-48 only (a test)
#   ruby tools/record.rb --jobs 10 --chunk 480 --fps 60
require "optparse"
require "fileutils"
require "rbconfig"
require "open3"

ROOT = File.expand_path("..", __dir__)
SCARPE = ENV.fetch("SCARPE", File.join(Dir.home, "scarpe"))
OUT = File.join(ROOT, "record")

opts = { from: 0.0, to: nil, jobs: 10, chunk: 480, fps: 60, scale: 2, crf: 16 }
OptionParser.new do |o|
  o.on("--from SECS", Float) { |v| opts[:from] = v }
  o.on("--to SECS", Float) { |v| opts[:to] = v }
  o.on("--jobs N", Integer) { |v| opts[:jobs] = v }
  o.on("--chunk FRAMES", Integer) { |v| opts[:chunk] = v }
  o.on("--fps N", Integer) { |v| opts[:fps] = v }
  o.on("--scale N", Float) { |v| opts[:scale] = v }
  o.on("--crf N", Integer) { |v| opts[:crf] = v }
  o.on("--name NAME") { |v| opts[:name] = v }
end.parse!

require File.join(ROOT, "lib/diem/config")
require File.join(ROOT, "lib/diem/music")
length = Diem::Music::LENGTH
TAIL = 2.0 # black after the last frame of the show, so the final chord rings out instead of clicking off
opts[:to] ||= length + TAIL
first = (opts[:from] * opts[:fps]).round
last = (opts[:to] * opts[:fps]).round - 1
name = opts[:name] || (opts[:from].zero? && opts[:to] >= length ? "scarpe_diem" : format("scarpe_diem_%03d-%03d", opts[:from], opts[:to]))

frames_dir = File.join(OUT, "frames", name)
seg_dir = File.join(OUT, "segments", name)
box = File.join(OUT, "home")
[frames_dir, seg_dir, box].each { |d| FileUtils.mkdir_p(d) }

ruby = Dir.chdir(SCARPE) { `ruby -e 'print RbConfig.ruby'` }

def log(msg) = $stdout.puts("[#{Time.now.strftime("%H:%M:%S")}] #{msg}")

# ---- the soundtrack -------------------------------------------------------------------------
wav = File.join(OUT, "soundtrack.wav")
synth = File.join(ROOT, "lib/diem/synth.rb")
stamp = [File.mtime(synth), File.mtime(File.join(ROOT, "lib/diem/music.rb"))].max
unless File.exist?(wav) && File.mtime(wav) > stamp
  log "synthesizing the soundtrack"
  system(ruby, synth, wav, File.join(OUT, "synth.progress"), exception: true)
end

# ---- frames, in parallel chunks -------------------------------------------------------------
chunks = (first..last).each_slice(opts[:chunk]).map { |s| [s.first, s.last] }
env = {
  "PATH" => "#{SCARPE}/spec/support/fakebin:#{ENV["PATH"]}", "HOME" => box,
  "SPEC_TRAP_FILE" => File.join(box, "trapped.txt"), "SPEC_CLIPBOARD_FILE" => File.join(box, "clipboard.txt"),
  "RUSTUP_HOME" => ENV.fetch("RUSTUP_HOME", File.join(Dir.home, ".rustup")),
  "CARGO_HOME" => ENV.fetch("CARGO_HOME", File.join(Dir.home, ".cargo")),
  "SCARPE_DISPLAY_SERVICE" => "native", "SCARPE_NATIVE_HEADLESS" => "1",
  "BUNDLE_GEMFILE" => File.join(SCARPE, "Gemfile"),
  "DIEM_RECORD" => "1", "DIEM_RECORD_FPS" => opts[:fps].to_s, "DIEM_SCALE" => opts[:scale].to_s,
}
env["DIEM_STATS_FILE"] = ENV["DIEM_STATS_FILE"] if ENV["DIEM_STATS_FILE"]

def encode(dir, a, b, fps, crf, seg)
  ok = system("ffmpeg", "-y", "-loglevel", "error", "-framerate", fps.to_s, "-start_number", a.to_s,
    "-i", File.join(dir, "%05d.png"), "-frames:v", (b - a + 1).to_s, "-c:v", "libx264", "-preset", "slow",
    "-crf", crf.to_s, "-pix_fmt", "yuv420p", "-g", fps.to_s, "-r", fps.to_s, seg)
  ok && (a..b).each { |i| File.delete(File.join(dir, format("%05d.png", i))) rescue nil }
  ok
end

log "#{last - first + 1} frames in #{chunks.size} chunks, #{opts[:jobs]} at a time"
queue = chunks.each_with_index.to_a
done = Queue.new
running = 0
failures = []
started = Time.now
segments = []
until queue.empty? && running.zero?
  while running < opts[:jobs] && !queue.empty?
    (a, b), k = queue.shift
    dir = File.join(frames_dir, format("chunk%03d", k))
    FileUtils.mkdir_p(dir)
    seg = File.join(seg_dir, format("seg%03d.mp4", k))
    segments[k] = seg
    if File.exist?(seg) && File.size(seg) > 1000 && ENV["DIEM_FRESH"].nil?
      log "chunk #{k} (#{a}..#{b}) already encoded"
      next
    end
    running += 1
    Thread.new(dir, a, b, k, seg) do |dir, a, b, k, seg|
      log_path = File.join(dir, "render.log")
      ok = system(env.merge("DIEM_FRAMES" => "#{a}..#{b}", "DIEM_OUT" => dir), ruby, File.join(SCARPE, "exe/scarpe"),
        "--native", File.join(ROOT, "scarpe_diem.rb"), "--dev", out: log_path, err: log_path)
      ok &&= (a..b).all? { |i| File.exist?(File.join(dir, format("%05d.png", i))) }
      ok &&= encode(dir, a, b, opts[:fps], opts[:crf], seg)
      done << [k, a, b, ok, log_path]
    end
  end
  k, a, b, ok, log_path = done.pop
  running -= 1
  failures << [k, log_path] unless ok
  log "chunk #{k} (#{a}..#{b}) #{ok ? "done" : "FAILED, see #{log_path}"} (#{(Time.now - started).round}s)"
end
abort "failed chunks: #{failures.inspect}" unless failures.empty?

# ---- join and add the music -----------------------------------------------------------------
list = File.join(seg_dir, "#{name}.txt")
File.write(list, segments.compact.map { |s| "file '#{s}'\n" }.join)
video = File.join(OUT, "#{name}.video.mp4")
system("ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", video, exception: true)
final = File.join(OUT, "#{name}.mp4")
# The soundtrack peaks at exactly 0.3 of full scale (the app keeps sound that quiet); a fixed
# gain brings the peak to about -1.2 dBFS for the video and keeps every drop's dynamics intact.
system("ffmpeg", "-y", "-loglevel", "error", "-i", video, "-ss", opts[:from].to_s, "-t", (opts[:to] - opts[:from]).to_s, "-i", wav,
  "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-ar", "48000",
  "-af", "volume=9.3dB", "-movflags", "+faststart", final, exception: true)
log "wrote #{final} (#{(File.size(final) / 1e6).round(1)} MB)"
