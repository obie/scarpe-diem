# frozen_string_literal: true

require_relative "../ignition_flight"
require_relative "../ignition_starfield"
require_relative "../ignition_logo"
require_relative "../ignition_tagline"
require_relative "../ignition_fx"

module Diem
  module Scenes
    # Bars 0-16. Deep space: a perspective starfield creeps, then warps into hyperspace on the
    # riser while a cloud of particles spirals in out of the vanishing point. On the last beat
    # everything holds its breath. On the drop the particles slam into a voxel SCARPE DIEM with a
    # flash, shockwaves and sparks; the logo then lives on the groove, turns a full circle in
    # perspective, twists, and blows apart, and four firework shells punch through the debris on
    # the fill.
    class Ignition < Scene
      STARS = 1300
      SPARKS = 192
      BURST_SPARKS = 4 * IgnitionFx::BURST_SPARKS

      def build
        origin = (PLAN.find { |name, *| name == "Ignition" }&.[](1) || 0) * Music::BAR
        @flight = IgnitionFlight.new(origin)
        dense = density >= 0.6
        @lc_x = w / 2.0
        @lc_y = h * 0.41
        @stars = IgnitionStarfield.new(self, (STARS * density).round, @flight)
        @logo = IgnitionLogo.new(self, @flight, dense: dense)
        @tagline = IgnitionTagline.new(self, @logo.cell, @lc_y + @logo.half_h + 64 * u) if dense
        @fx = IgnitionFx.new(self, @logo, (SPARKS * density).round, (BURST_SPARKS * density).round)

        draw do
          background Palette.rgb(Palette::NIGHT)
          @stars.build
          @fx.build_back
        end
        breathe
        draw { @logo.build }
        breathe
        draw do
          @tagline&.build
          @fx.build_front
        end
      end

      def enter
        @stars.reset
        @logo.reset
        @tagline&.reset
        @fx.reset
      end

      def update(t, sync)
        kick = t >= IgnitionFlight::DROP ? sync.hit(:kick, 0.11) : 0.0
        cx, cy = centre(t)
        drift = 1.0 - smooth(9.0, 13.2, t)
        yaw = 0.2 * Math.sin(t * 0.23 + 0.4) * drift
        pitch = 0.12 * Math.sin(t * 0.19 - 0.6) * drift
        sparkle = t < IgnitionFlight::BREATH ? 0.8 * sync.hit(:arp, 0.12) * smooth(0.5, 5.0, t) * (1.0 - smooth(12.5, 14.0, t)) : 0.0
        @stars.update(t, cx, cy, star_glow(t, sync, kick), yaw, pitch, sparkle, sync.count(:arp) & 7,
          solid: t >= IgnitionFlight::BOOM, haze: t < IgnitionFlight::DROP ? 1.0 + 0.55 * smooth(4.0, 11.0, t) : 0.0,
          floor: t >= IgnitionFlight::BREATH && t < IgnitionFlight::DROP ? 3 : 1)
        @logo.swell = 1.0 + 0.42 * kick
        snare = t >= IgnitionFlight::BOOM ? sync.hit(:snare, 0.07) : 0.0
        @logo.update(t, cx, cy, kick, snare, t >= IgnitionFlight::BOOM ? @fx.holes(t, cx, cy) : nil)
        @tagline&.update(t, kick)
        @fx.update(t, cx, cy, kick, t < IgnitionFlight::BREATH ? sync.hit(:hat, 0.08) : 0.0)
      end

      private

      # The logo's centre on screen, shaken by the impact and dipped a little through the turn,
      # whose perspective swell would otherwise crowd the top edge.
      def centre(t)
        tau = t - IgnitionFlight::DROP
        if t > 24.0 && t < 28.0
          return [@lc_x, @lc_y + 9.0 * u * Math.sin(Math::PI * (t - 24.0) / 4.0)]
        end
        return [@lc_x, @lc_y] if tau.negative? || tau > 0.8

        k = 11.0 * u * Math.exp(-tau / 0.11)
        [@lc_x + k * Math.sin(tau * 97.0), @lc_y + k * Math.cos(tau * 71.0)]
      end

      def star_glow(t, sync, kick)
        if t < IgnitionFlight::BREATH
          # Up from the fade, then a slow brightening from 4 s as the flight picks up, handed back
          # to the riser at the level it always had.
          lift = 0.13 * smooth(4.0, 11.0, t) * (1.0 - smooth(12.0, 14.0, t))
          ((0.3 + 0.7 * smooth(0.0, 1.8, t) + lift) * (0.9 + 0.1 * sync.hit(:hat, 0.06)) +
            0.1 * smooth(12.0, 15.4, t)).clamp(0.0, 1.0 + lift)
        elsif t < IgnitionFlight::DROP
          0.06 + 0.94 * (1.0 - smooth(15.5, 15.64, t))
        else
          (1.0 - 0.38 * smooth(16.1, 17.2, t) + 0.25 * kick + 0.5 * smooth(31.0, 31.9, t)).clamp(0.0, 1.0)
        end
      end

      def smooth(a, b, t)
        x = ((t - a) / (b - a)).clamp(0.0, 1.0)
        x * x * (3.0 - 2.0 * x)
      end
    end
  end
end
