# frozen_string_literal: true

# Everything SCARPE DIEM is made of, in load order.
require_relative "diem/config"
if File.exist?(File.join(__dir__, "diem", "music.rb"))
  require_relative "diem/music"
else
  require_relative "diem/music_test"
  Diem::Music = Diem::MusicTest
end
require_relative "diem/sync"
require_relative "diem/wire"
require_relative "diem/framebuffer"
require_relative "diem/audio"
require_relative "diem/bitfont" if File.exist?(File.join(__dir__, "diem", "bitfont.rb"))
require_relative "diem/scene"
require_relative "diem/loader"
require_relative "diem/engine"

# The lab (DIEM_SCENE=Name) loads only the scene it is showing, so a scene being edited elsewhere
# cannot break it. The full show loads them all; one that fails to load becomes a placeholder.
lab_scene = ENV["DIEM_SCENE"]&.gsub(/([a-z\d])([A-Z])/, '\\1_\\2')&.downcase
Dir[File.join(__dir__, "diem", "scenes", "*.rb")].sort.each do |f|
  next if lab_scene && ENV["DIEM_LAB_ALL"].nil? && File.basename(f, ".rb") != lab_scene

  begin
    require f
  rescue ScriptError, StandardError => e
    warn "scarpe diem: #{File.basename(f)} did not load (#{e.class}: #{e.message.lines.first&.strip})"
  end
end

module Diem
  # Bars of the song each scene owns, and how it arrives.
  PLAN = [
    ["Ignition", 0, 16, :fade],
    ["Copper", 16, 24, :flash],
    ["Plasma", 24, 32, :flash],
    ["Solids", 32, 48, :flash],
    ["Dots", 48, 56, :fade],
    ["Maze", 56, 72, :flash],
    ["Tunnel", 72, 80, :flash],
    ["Finale", 80, 88, :flash],
    ["Credits", 88, 96, :flash],
  ].freeze

  module Scenes
    # Stands in for a scene that is not written yet: its name, pulsing on the kick.
    class Placeholder < Scene
      class << self
        attr_accessor :scene_name

        def named(name)
          Class.new(self) { self.scene_name = name }
        end

        def label = scene_name.upcase
      end

      def build
        draw do
          background Palette.rgb(Palette::NIGHT)
          nostroke
          @pulse = oval(w / 2, h / 2, 40 * u, center: true, fill: Palette.rgb(Palette::MAGENTA), strokewidth: 0)
          para self.class.scene_name.upcase, left: (40 * u).round, top: (40 * u).round, size: (40 * u).round,
            stroke: Palette.rgb(Palette::INK), margin: 0
        end
      end

      def update(t, sync)
        d = (40 + 160 * sync.hit(:kick, 0.12)) * u
        set(@pulse, { width: d.round(1), height: d.round(1) })
      end
    end
  end

  def self.schedule
    PLAN.map do |name, from, to, transition|
      klass = Scenes.const_defined?(name, false) ? Scenes.const_get(name, false) : Scenes::Placeholder.named(name)
      [klass, from, to, transition]
    end
  end
end
