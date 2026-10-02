# frozen_string_literal: true

# Plays the whole show live in a ghost window (invisible, silent) with the renderer's stats on,
# then reports, per scene, the frames the renderer really presented and what each cost.
#   ruby tools/perf_report.rb            -> shots/perf/report.md and report.json
require "json"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
require File.join(ROOT, "lib/diem/config")
require File.join(ROOT, "lib/diem/music")
PLAN = File.read(File.join(ROOT, "lib/diem.rb")).scan(/\["(\w+)", (\d+), (\d+), :\w+\]/).map { |n, a, b| [n, a.to_i, b.to_i] }

root_out = File.join(ROOT, "shots", "perf", Time.now.strftime("%Y%m%d-%H%M%S"))
# The renderer keeps 10,000 frame rows, so the show plays in two halves, each from a scene start.
HALVES = [[0, 112.0], [96.0, Diem::Music::LENGTH]].freeze
passes = HALVES.each_with_index.map do |(from, to), i|
  out = File.join(root_out, "pass#{i}")
  FileUtils.mkdir_p(out)
  box = File.join(out, "home")
  # the first pass synthesizes the soundtrack into its scratch home; later passes reuse it
  if i.positive?
    src = Dir[File.join(root_out, "pass0", "home", "**", "soundtrack-*.wav")].first
    dst = File.join(box, "Library", "Application Support", "Scarpe Diem")
    FileUtils.mkdir_p(dst)
    FileUtils.cp(src, dst) if src
  end
  secs = (to - from) + 40
  env = { "SCARPE_NATIVE_STATS" => out, "SCARPE_NATIVE_GHOST" => "1", "SCARPE_NATIVE_ARGS" => "--exit-after #{secs}",
          "SCARPE_HOME" => box, "DIEM_START_AT" => from.to_s, "DIEM_HUD" => ENV["DIEM_HUD"] }.compact
  system(env, File.join(ROOT, "scarpe.sh"), "--native", File.join(ROOT, "scarpe_diem.rb"), out: File.join(out, "run.log"), err: [:child, :out])
  rust = JSON.parse(File.read(File.join(out, "rust.json")))
  run = JSON.parse(File.read(Dir[File.join(box, "**", "last_run.json")].first || raise("no last_run.json in pass #{i}: did the show finish?")))
  cols = rust["frame_columns"]
  { rust: rust, run: run, frames: rust["frames"].map { |row| cols.zip(row).to_h }, from: from, to: to }
end
out = root_out
run = passes.last[:run]
report = PLAN.map do |name, from, to|
  pass = passes.find { |p| from * Diem::Music::BAR >= p[:from] && to * Diem::Music::BAR <= p[:to] } || passes.last
  rust = pass[:rust]
  frames = pass[:frames]
  start = pass[:run].fetch("show_started_unix")
  a = start + from * Diem::Music::BAR
  b = start + to * Diem::Music::BAR
  inside = frames.select { |f| (t = rust["started_unix"] + f["at"]) >= a && t < b }
  gaps = inside.each_cons(2).map { |p, q| (q["at"] - p["at"]) * 1000 }.sort
  ruby = pass[:run].dig("scenes", name.upcase) || {}
  {
    "scene" => name, "seconds" => (b - a).round(1),
    "presented_fps" => (inside.size / (b - a)).round(1),
    "p50_ms" => gaps[gaps.size / 2]&.round(1), "p95_ms" => gaps[(gaps.size * 0.95).floor]&.round(1),
    "paint_ms" => (inside.sum { |f| f["paint"] } / [inside.size, 1].max).round(2),
    "ruby_ms" => ruby["frames"].to_i.positive? ? (ruby["busy_ms"] / ruby["frames"]).round(2) : nil,
    "ruby_hz" => ruby["frames"] ? (ruby["frames"] / (b - a)).round(1) : nil,
    "shapes" => ruby["shapes"], "peak_changes" => ruby["peak_changes"],
  }
end
File.write(File.join(out, "report.json"), JSON.pretty_generate({ "scenes" => report, "runs" => passes.map { |p| p[:run] } }))
md = +"| scene | presented fps | p50 / p95 frame ms | paint ms | ruby ms | shapes | peak changes/frame |\n|---|---|---|---|---|---|---|\n"
report.each { |r| md << "| #{r["scene"]} | #{r["presented_fps"]} | #{r["p50_ms"]} / #{r["p95_ms"]} | #{r["paint_ms"]} | #{r["ruby_ms"]} | #{r["shapes"]} | #{r["peak_changes"]} |\n" }
File.write(File.join(out, "report.md"), md)
puts md
puts "\n#{out}"
