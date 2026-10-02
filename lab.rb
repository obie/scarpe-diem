# frozen_string_literal: true

# One scene on its own, for building it: no loader, no audio.
#
#   DIEM_SCENE=Plasma tools/shots.sh 0,2,4      pictures at those seconds into the scene
#   DIEM_SCENE=Plasma ./bench.sh lab.rb 6       a ghost window for six seconds, with stats
#   DIEM_SCENE=Plasma DIEM_AT=3 ./scarpe.sh peek lab.rb --wait 1 --shot shots/x.png
#   DIEM_SCENE=Walk ./scarpe.sh peek lab.rb --key up --wait 0.5 --shot shots/walk.png   the after-party
#   DIEM_TILE=320x180 ...                       the scene as a small tile at density 0.35, as the finale shows it
RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
require_relative "lib/diem"

name = ENV.fetch("DIEM_SCENE")
walk = name == "Walk"
klass, from, to, transition = if walk
  [Diem::Scenes::Placeholder.named("Walk"), 56, 72, :cut]
else
  Diem.schedule.find { |_, f, _, _| Diem::PLAN.find { |n, *| n == name }&.[](1) == f } ||
    raise("no scene called #{name} in Diem::PLAN")
end

Shoes.app(title: "lab: #{name}", width: Diem::W, height: Diem::H, resizable: false) do
  background Diem::Palette.hex(Diem::Palette::NIGHT)
  opts = {}
  if (tile = ENV["DIEM_TILE"])
    tw, th = tile.split("x").map(&:to_i)
    opts = { w: tw, h: th, left: 40, top: 40, density: (ENV["DIEM_DENSITY"] || 0.35).to_f }
  end
  @engine = Diem::Engine.new(self, [[klass, from, to, transition]], loader_class: nil, scene_opts: opts)
  start = from * Diem::Music::BAR

  if (shots = ENV["DIEM_LAB_SHOTS"])
    Scarpe::Native.after_first_heartbeat do
      times = shots.split(",").map { |s| start + s.to_f }
      @engine.lab_shots(times, ENV.fetch("DIEM_OUT"), name.downcase, scale: (ENV["DIEM_SCALE"] || 1).to_f).each { |p| puts p }
      exit
    end
  elsif walk
    @engine.lab_walk
  else
    @engine.lab(start + (ENV["DIEM_AT"] || 0).to_f)
  end
end
