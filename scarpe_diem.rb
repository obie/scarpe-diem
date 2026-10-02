# frozen_string_literal: true

# SCARPE DIEM: a real-time demo in Ruby and Shoes, for the Scarpe native renderer.
#
#   cd ~/scarpe && bundle exec ruby exe/scarpe --native ~/projects/scarpe-diem/scarpe_diem.rb
#
# space pause · left/right skip a scene · 1-9 jump · m mute · f stats · r restart · esc quit
RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
require_relative "lib/diem"

Shoes.app(title: "SCARPE DIEM", width: Diem::W, height: Diem::H, resizable: false) do
  background Diem::Palette.hex(Diem::Palette::NIGHT)
  @engine = Diem::Engine.new(self, Diem.schedule, loader_class: Diem::Loader)

  if Diem::RECORD && ENV["DIEM_FRAMES"]
    first, last = ENV.fetch("DIEM_FRAMES").split("..").map(&:to_i)
    Scarpe::Native.after_first_heartbeat do
      @engine.record(first, last, ENV.fetch("DIEM_OUT"), scale: (ENV["DIEM_SCALE"] || 2).to_f)
      exit
    end
  elsif !Diem::RECORD
    @engine.start
  end
  # With DIEM_RECORD but no frames, nothing starts: a check drives @engine.render_frame itself.
end
