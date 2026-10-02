# frozen_string_literal: true

# A scene owns one clipped, placed slot and everything drawn in it. The engine builds it once
# (hidden), shows it when the music reaches it, and calls update every frame with the time since
# the scene began and the Sync cursor for the whole song.
module Diem
  class Scene
    # The Shoes DSL, sent on to the app so scene code reads like an app body.
    DSL = %i[
      oval rect line shape star arrow arc para banner title subtitle tagline caption inscription
      stack flow image fill stroke nofill nostroke strokewidth cap background border rgb gray
      gradient transform rotate mask span strong em code font
    ].freeze

    DSL.each do |name|
      define_method(name) { |*args, **kwargs, &blk| @app.public_send(name, *args, **kwargs, &blk) }
    end

    attr_reader :slot, :w, :h, :u, :app, :density

    # The name the HUD shows.
    def self.label = name.split("::").last.upcase

    # w, h, left, top: the viewport, in the parent slot. A scene must draw everything relative
    # to its own slot and in units of u, so the finale can run it as a small tile.
    # density: 1.0 normally; lower in a tile, so scale counts (stars, dots, strips) by it.
    def initialize(app, w: W, h: H, left: 0, top: 0, density: 1.0)
      @app = app
      @w = w
      @h = h
      @u = h / 540.0
      @density = density
      @slot = app.stack(left: left, top: top, width: w, height: h, hidden: true)
    end

    # Make every drawable, once. Never create or remove drawables in update.
    def build; end

    # Called each time the scene becomes active, including after a seek: reset state here.
    def enter; end

    # t: seconds since this scene's first bar (may run a little past its end).
    # sync: Diem::Sync, already at the song time.
    def update(t, sync); end

    def leave; end

    def show = @slot.show
    def hide = @slot.hide

    # Draw into this scene's slot. Pens set inside (fill, nostroke...) stay on the slot.
    def draw(&blk)
      @slot.append(&blk)
    end

    # Let the loader (or the show, when a scene is built while the one before plays) keep moving
    # while a big scene builds. Every drawable made is already a place to pause; call this
    # between expensive steps that make none (tables, warm-up updates).
    def breathe
      Engine.breathe
    end

    # How many drawables this scene holds, for the HUD.
    def drawable_count
      @drawable_count ||= count_in(@slot)
    end

    # Wire shortcuts for hot loops (see wire.rb).
    def set(drawable, props) = Wire.set(drawable, props)

    # Integer colour array for the wire, from [r, g, b] Floats and an alpha 0..1.
    def wc(c, alpha = 1.0)
      [c[0].round.clamp(0, 255), c[1].round.clamp(0, 255), c[2].round.clamp(0, 255), (alpha * 255).round.clamp(0, 255)]
    end

    private

    def count_in(slot)
      slot.contents.sum { |d| d.respond_to?(:contents) && !d.is_a?(Shoes::Shape) ? 1 + count_in(d) : 1 }
    end
  end
end
