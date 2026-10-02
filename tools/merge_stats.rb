# frozen_string_literal: true

# Joins the two halves of the latest live perf run (tools/perf_report.rb) into one stats file
# for the recorder, so the video's credits show numbers a real live run produced.
#   ruby tools/merge_stats.rb  -> record/stats.json
require "json"
ROOT = File.expand_path("..", __dir__)
run = Dir[File.join(ROOT, "shots/perf/2*")].max
passes = Dir[File.join(run, "pass*/home/**/last_run.json")].sort.map { |f| JSON.parse(File.read(f)) }
abort "no passes in #{run}" if passes.empty?

merged = { "frames" => 0, "peak_changes" => 0, "peak_shapes" => 0, "scenes" => {}, "source" => File.basename(run) }
passes.each_with_index do |p, i|
  merged["synth_seconds"] ||= p["synth_seconds"]
  merged["peak_changes"] = [merged["peak_changes"], p["peak_changes"].to_i].max
  merged["peak_shapes"] = [merged["peak_shapes"], p["peak_shapes"].to_i].max
  # the halves overlap (the second starts at Dots); count each scene's frames once, from the
  # pass that played it whole
  p["scenes"].each do |label, st|
    have = merged["scenes"][label]
    merged["scenes"][label] = st if have.nil? || st["frames"] > have["frames"]
  end
end
# "frames drawn" is what the renderer presented, from its own frame log, not Ruby's ticks
report = JSON.parse(File.read(File.join(run, "report.json")))
merged["frames"] = report["scenes"].sum { |r| (r["presented_fps"] * r["seconds"]).round }
merged["ruby_ticks"] = merged["scenes"].values.sum { |st| st["frames"] }
File.write(File.join(ROOT, "record/stats.json"), JSON.pretty_generate(merged))
puts JSON.pretty_generate(merged.reject { |k, _| k == "scenes" })
