# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require "rbconfig"

# Runs the show: synthesizes (or finds) the soundtrack, builds every scene behind the loader,
# then plays the song and keeps the right scene on screen, in time with it.
#
# Live, the clock is the audio clock. Recording (DIEM_RECORD=1), there is no audio and no timer:
# frame i is song time i / RECORD_FPS, drawn and snapshotted one at a time, so every frame of a
# recording is exact however long it takes to paint.
module Diem
  class Engine
    Entry = Struct.new(:klass, :from_bar, :to_bar, :transition, :scene) do
      def from = from_bar * Music::BAR
      def to = to_bar * Music::BAR
    end

    FADE = Music::BEAT # how long a fade to or from black lasts
    FLASH = 0.6        # how long a white flash takes to clear

    PREBUILD = 2 # scenes built behind the loader; each later one is built while the one before plays
    PRECALC = %w[Tunnel].freeze # tiny on screen but slow to build: also built behind the loader
    LOADER_SLICE = 0.008 # seconds of building per frame behind the loader
    SHOW_SLICE = 0.003   # and in the background during the show

    @building_in_fiber = false
    @slice_started = 0.0
    @slice = LOADER_SLICE
    class << self
      attr_accessor :building_in_fiber, :slice, :app
      alias building_in_fiber? building_in_fiber

      # Called after every drawable is made (and by scenes between steps): while a build runs in
      # a fiber, hands the frame back once this frame's slice of building is used up.
      def breathe
        return unless @building_in_fiber

        clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if clock - @slice_started < @slice
        return if @app&.current_slot.is_a?(Shoes::Shape) # never pause inside a path

        Fiber.yield
      end

      # Runs a building fiber for one slice.
      def slice_of(fiber, seconds)
        @building_in_fiber = true
        @slice = seconds
        @slice_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        fiber.resume
      ensure
        @building_in_fiber = false
      end
    end

    # Every drawable the DSL makes is a place a build can pause.
    module Breather
      %i[oval rect line arrow star arc shape para banner title subtitle tagline caption inscription
         image stack flow background border mask].each do |name|
        define_method(name) do |*args, **kwargs, &blk|
          made = super(*args, **kwargs, &blk)
          Engine.breathe
          made
        end
      end
    end

    attr_reader :entries, :sync, :app

    def initialize(app, schedule, loader_class:, scene_opts: {})
      @app = app
      @sync = Sync.new(Music.score)
      @entries = schedule.map { |klass, from, to, transition| Entry.new(klass, from, to, transition || :cut) }
      @hud_on = !ENV["DIEM_HUD"].to_s.empty?
      Shoes::App.prepend(Breather) unless Shoes::App.include?(Breather)
      Engine.app = app
      # Scenes built during the show go on the backstage, under a curtain that is drawn while they
      # build and warm up, so not a frame of them shows; a scene moves up to the stage to play.
      @backstage = app.stack(left: 0, top: 0, width: W, height: H)
      @curtain = app.rect(0, 0, W, H, fill: Palette.rgb(Palette::NIGHT), strokewidth: 0, hidden: true)
      @stage = app.stack(left: 0, top: 0, width: W, height: H)
      @loader = loader_class.new(app, self) if loader_class && !RECORD
      @scene_opts = scene_opts
      build_overlay
      @active = nil
      @paused = false
      @muted = false
      @frame_times = []
      @prop_changes = 0
      @changes_seen = 0
      @backstage_changes = 0
      @reap = []
      count_lacci_changes
      Diem.stats.replace(JSON.parse(File.read(ENV["DIEM_STATS_FILE"]))) if ENV["DIEM_STATS_FILE"]
    end

    # ---- live -----------------------------------------------------------------------------

    def start
      at_exit { save_stats }
      @state = :loading
      @song_path = soundtrack_path
      start_synth unless File.exist?(@song_path)
      @builder = Fiber.new { build_all_in_fiber }
      @app.keypress { |key| key_pressed(key) }
      @ticker = @app.animate(FPS) { tick }
    end

    def tick
      started = now
      case @state
      when :loading then load_step
      when :show then show_step
      when :walk then walk_step
      end
      reap_step
      ahead_step if @state == :show
      note_frame(started)
    end

    # ---- recording ------------------------------------------------------------------------

    # Builds what the frames need, then draws and snapshots frames first..last.
    def record(first, last, dir, scale: 2)
      need = entries_between(first.fdiv(RECORD_FPS), last.fdiv(RECORD_FPS) + 0.001)
      need.each { |e| build_entry(e) }
      automation = Scarpe::Native::DisplayService.instance.automation
      (first..last).each do |i|
        render_frame(i)
        automation.snapshot(File.join(dir, format("%05d.png", i)), scale: scale)
      end
    rescue Exception => e
      warn e.full_message
      exit! 1
    end

    def render_frame(i)
      draw_at(i.fdiv(RECORD_FPS))
    end

    # ---- the lab: one scene, no loader, no audio ---------------------------------------------

    # Plays live from song time `at`, for peeking and benchmarking a scene on its own.
    def lab(at)
      @entries.each { |e| build_entry(e) }
      @state = :show
      @muted = true
      @t0 = now - at
      @app.keypress { |key| key_pressed(key) }
      @ticker = @app.animate(FPS) { tick }
    end

    # The after-party on its own: the walk scene, keys and mouse live, no audio.
    def lab_walk
      @muted = true
      @app.keypress { |key| key_pressed(key) }
      start_walk
      @ticker = @app.animate(FPS) { tick }
    end

    # Snapshots at the given song times, in order, then returns the paths.
    def lab_shots(times, dir, name, scale: 2)
      @entries.each { |e| build_entry(e) }
      automation = Scarpe::Native::DisplayService.instance.automation
      times.map do |t|
        draw_at(t)
        path = File.join(dir, format("%s-%07.3f.png", name, t))
        automation.snapshot(path, scale: scale)
        path
      end
    rescue Exception => e # a scene that raises must fail the run, never hang it
      warn e.full_message
      exit! 1
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # ---- loading --------------------------------------------------------------------------

    def load_step
      Engine.slice_of(@builder, LOADER_SLICE) if @builder.alive?
      progress = synth_progress
      @loader.update(now - (@load_began ||= now), progress, built_fraction)
      synth_failed = @synth_waiter && !@synth_waiter.alive? && !song_ready?
      @muted = true if synth_failed # no soundtrack: the show goes on in silence
      return if @builder.alive? || !(song_ready? || synth_failed)

      @ready_at ||= now
      return if now - @ready_at < @loader.linger

      begin_show((ENV["DIEM_START_AT"] || 0).to_f)
    end

    # Builds every scene that is not built yet, behind the loader, and warms each one up: it is
    # entered, drawn once and shown for a few frames under the loader, so the renderer's first
    # layout, the text shaping and YJIT's first compiles all happen here, not on a downbeat.
    def build_all_in_fiber
      loader_entries.each do |e|
        next if e.scene

        build_entry(e)
        Fiber.yield
        warm_up(e.scene, e.from)
      end
      TunnelTextures.persist if defined?(TunnelTextures)
    end

    # The first scenes the show will play (from wherever it starts) and the precalc ones.
    def loader_entries
      start = entry_at((ENV["DIEM_START_AT"] || 0).to_f)
      first = @entries[@entries.index(start), PREBUILD]
      (first + @entries.select { |e| PRECALC.include?(scene_name(e)) }).uniq
    end

    def scene_name(entry) = entry.klass.name.to_s.split("::").last

    def warm_up(scene, song_t)
      scene.enter
      scene.update(0.0, @sync.at(song_t))
      scene.show
      3.times { Fiber.yield }
      scene.hide
      scene.leave
    end

    def build_entry(entry, into: @stage)
      finish_ahead(entry)
      return entry.scene if entry.scene

      scene = nil
      into.append { scene = entry.klass.new(@app, **@scene_opts) }
      scene.build
      scene.drawable_count # counted now, not on the scene's first frame
      entry.scene = scene
    end

    # ---- retiring: a scene that has played gives its drawables back -------------------------

    # Hidden drawables still cost the renderer a little every frame, and the finale needs all
    # of it, so once the show moves past a scene, its drawables are removed a few milliseconds'
    # worth a frame. A seek back builds it again.
    def retire(entry)
      scene = entry.scene
      return unless scene && !RECORD && @state == :show

      entry.scene = nil
      @reap.concat(leaves_first(scene.slot))
    end

    def leaves_first(slot, out = [])
      slot.contents.each do |d|
        if d.is_a?(Shoes::Slot) && !d.is_a?(Shoes::Shape)
          leaves_first(d, out)
        else
          out << d
        end
      end
      out << slot
    end

    def reap_step(budget_ms = 2.5)
      return if @reap.empty?

      started = now
      while (d = @reap.shift)
        d.remove unless d.destroyed
        break if (now - started) * 1000 > budget_ms
      end
    end

    def built_fraction
      list = loader_entries
      list.count(&:scene).fdiv(list.size)
    end

    # ---- building ahead: the next scene is built while this one plays ------------------------

    # How far ahead to build while a scene plays. The finale is the biggest build of all and the
    # tunnel before it is the busiest scene, so the finale is built during the maze.
    LOOKAHEAD = { "Maze" => 2 }.freeze

    def build_ahead_of(entry)
      i = @entries.index(entry)
      depth = LOOKAHEAD.fetch(scene_name(entry), 1)
      build_ahead(@entries[i + 1, depth].to_a.compact.reject(&:scene))
    end

    def build_ahead(list)
      return if RECORD || list.empty? || @ahead&.alive?

      @ahead_list = list
      @ahead = Fiber.new do
        list.each do |entry|
          @ahead_entry = entry
          build_entry(entry, into: @backstage)
          warm_up_behind(entry)
        end
      end
    end

    def ahead_step
      return curtain(false) unless @ahead&.alive?

      curtain(true)
      before = Wire.posts + @prop_changes
      Engine.slice_of(@ahead, SHOW_SLICE)
      @backstage_changes += Wire.posts + @prop_changes - before # not on screen: not counted
    end

    def curtain(down)
      return if @curtain_down == down

      Wire.set(@curtain, { hidden: !down })
      @curtain_down = down
    end

    # Drawn for a few frames behind the scene that is playing (which covers the window), so its
    # first layout and text shaping are paid now rather than on its downbeat.
    def warm_up_behind(entry)
      scene = entry.scene
      scene.enter
      scene.update(0.0, Sync.new(Music.score).at(entry.from))
      scene.show
      2.times do
        Fiber.yield
        return if entry.equal?(@active)
      end
      scene.hide
      scene.leave
    end

    # The scene must exist now: finish building it here if the background has not.
    def finish_ahead(entry)
      return if entry.scene
      return unless @ahead&.alive? && @ahead_list&.include?(entry) && !Fiber.current.equal?(@ahead)

      @ahead.resume while @ahead.alive? && entry.scene.nil?
    end

    def soundtrack_path
      digest = Digest::SHA256.hexdigest(%w[music.rb synth.rb].map { |f| File.read(File.join(__dir__, f)) }.join)[0, 12]
      FileUtils.mkdir_p(DATA_DIR)
      File.join(DATA_DIR, "soundtrack-#{digest}.wav")
    end

    def start_synth
      @progress_path = "#{@song_path}.progress"
      File.write(@progress_path, "")
      log = File.open(File.join(DATA_DIR, "synth.log"), "w")
      @synth_pid = Process.spawn(RbConfig.ruby, File.join(__dir__, "synth.rb"), @song_path, @progress_path, out: log, err: log)
      @synth_waiter = Process.detach(@synth_pid)
      at_exit { Process.kill("TERM", @synth_pid) rescue nil unless song_ready? }
    end

    def song_ready? = File.exist?(@song_path)

    # { "kick" => 0.4, ... } from the synth's progress file; done is true once the WAV exists.
    def synth_progress
      return { done: true } if song_ready? && @progress_path.nil?

      lines = File.exist?(@progress_path.to_s) ? File.read(@progress_path).lines : []
      tracks = {}
      done = nil
      lines.each do |l|
        name, value = l.split
        name == "done" ? done = value.to_f : tracks[name] = value.to_f
      end
      Diem.stats["synth_seconds"] = done if done
      { tracks: tracks, done: song_ready?, seconds: done }
    rescue SystemCallError
      { tracks: {}, done: false }
    end

    # ---- the show -------------------------------------------------------------------------

    def begin_show(at)
      @loader&.finish
      Diem.stats["show_started_unix"] ||= Time.now.to_f + AUDIO_LATENCY - at
      @state = :show
      @audio ||= Audio.new(@song_path) if song_ready?
      seek(at)
    end

    def seek(t)
      t = t.clamp(0.0, Music::LENGTH)
      if @paused
        @paused_t = t
      else
        @t0 = @muted || @audio.nil? ? now - t : @audio.play(t) - t
      end
      @active&.scene&.leave
      @active = nil
    end

    def song_time
      @paused ? @paused_t : now - @t0
    end

    def show_step
      t = song_time
      if t >= Music::LENGTH
        @audio&.stop
        save_stats
        end_card
        return
      end
      draw_at([t, 0.0].max)
    end

    # Everything on screen at song time t. Live and recorded frames both come through here.
    def draw_at(t)
      entry = entry_at(t)
      activate(entry) if entry && !entry.equal?(@active)
      @sync.at(t)
      entry&.scene&.update(t - entry.from, @sync)
      paint_veil(t, entry)
      update_hud(t, entry) if @hud_on
    end

    def activate(entry)
      @active&.scene&.leave
      @active&.scene&.hide
      retire(@active) if @active && @entries.index(@active) < @entries.index(entry)
      build_entry(entry)
      entry.scene.slot.set_parent(@stage) unless entry.scene.slot.parent.equal?(@stage)
      entry.scene.enter
      entry.scene.show
      @active = entry
      build_ahead_of(entry)
    end

    def entry_at(t)
      bar = t / Music::BAR
      @entries.find { |e| bar >= e.from_bar && bar < e.to_bar } || @entries.last
    end

    def entries_between(from, to)
      @entries.select { |e| e.to > from && e.from < to }
    end

    # ---- the end, and the after-party --------------------------------------------------------

    WALK_FROM = 56 * 4 * 0.5 # the maze's own bars of the song loop under the walk
    WALK_TO = 72 * 4 * 0.5

    def end_card
      @state = :ended
      @active&.scene&.leave
      @walk&.hide
      Wire.set(@veil, { fill: [0, 0, 0, 255] })
      @veil_shown = [0, 0, 0, 255]
      walk = walk_class ? "   ·   w  walk the maze yourself" : ""
      @card_hint.text = "r  replay#{walk}   ·   esc  quit"
      @card.show
      @app.timer(0.3) { prebuild_walk } if walk_class && !@walk
    end

    # The walk takes half a second to build, so it is built while the end card sits still, and
    # drawn once under the black veil so its first layout is done before anyone presses W.
    def prebuild_walk
      return if @walk || @state != :ended

      @stage.append { @walk = walk_class.new(@app) }
      @walk.build
      @walk.enter
      @walk.update(0.0, @sync.at(WALK_FROM))
      @walk.show
      @app.timer(0.15) { @walk.hide unless @state == :walk }
    end

    def walk_class
      Scenes.const_defined?(:Walk, false) ? Scenes::Walk : nil
    end

    def start_walk
      return unless walk_class

      @card.hide
      @active&.scene&.hide
      unless @walk
        @stage.append { @walk = walk_class.new(@app) }
        @walk.build
      end
      @walk.enter
      @walk.show
      Wire.set(@veil, { fill: [0, 0, 0, 0] })
      @veil_shown = [0, 0, 0, 0]
      @walk_t0 = now
      @state = :walk
      @walk_audio_until = 0
    end

    def walk_step
      t = now - @walk_t0
      loop_t = WALK_FROM + (t % (WALK_TO - WALK_FROM))
      if !@muted && @audio && now >= @walk_audio_until
        @audio.play(loop_t)
        @walk_audio_until = now + (WALK_TO - loop_t)
      end
      @walk.update(t, @sync.at(loop_t))
    end

    # ---- veil: fades and flashes between scenes -------------------------------------------

    def build_overlay
      @overlay = @app.stack(left: 0, top: 0, width: W, height: H) do
        @app.nostroke
        @veil = @app.rect(0, 0, W, H, fill: @app.rgb(0, 0, 0, 0), strokewidth: 0)
        @hud = @app.para("", left: (14 * U).round, top: (H - 30 * U).round, size: (11 * U).round,
          stroke: Palette.rgb(Palette::INK, 0.8), font: "Menlo, monospace", margin: 0, hidden: !@hud_on)
        @card = @app.stack(left: 0, top: (H / 2 - 50 * U).round, width: W, height: (120 * U).round, hidden: true) do
          @app.para("SCARPE DIEM", align: "center", size: (34 * U).round, weight: "heavy", kerning: (8 * U).round,
            stroke: Palette.rgb(Palette::INK), margin: 0)
          @card_hint = @app.para("", align: "center", size: (13 * U).round, stroke: Palette.rgb(Palette::MUTED),
            margin_top: (18 * U).round)
        end
      end
      @veil_shown = nil
    end

    def paint_veil(t, entry)
      colour = veil_colour(t, entry)
      return if colour == @veil_shown

      Wire.set(@veil, { fill: colour })
      @veil_shown = colour
    end

    def veil_colour(t, entry)
      return [0, 0, 0, 0] unless entry

      into = t - entry.from
      left = entry.to - t
      following = @entries[@entries.index(entry) + 1]
      alpha = 0.0
      white = false
      case entry.transition
      when :fade then alpha = [alpha, 1.0 - into / FADE].max if into < FADE
      when :flash
        flash = entry.klass.respond_to?(:flash_length) ? entry.klass.flash_length : FLASH
        if into < flash
          white = true
          alpha = (1.0 - into / flash)**2
        end
      end
      alpha = [alpha, 1.0 - left / FADE].max if following&.transition == :fade && left < FADE
      alpha = [alpha, 1.0 - (Music::LENGTH - t) / (FADE * 4)].max if following.nil? && Music::LENGTH - t < FADE * 4
      a = (alpha.clamp(0.0, 1.0) * 255).round
      white ? [255, 255, 255, a] : [0, 0, 0, a]
    end

    # ---- input ----------------------------------------------------------------------------

    def key_pressed(key)
      case key
      when "f", "F" then toggle_hud
      when "m", "M" then toggle_mute
      when :alt_q then @audio&.stop; @app.exit
      when :escape, "q", "Q" then (@audio&.stop; @app.exit) unless @state == :walk
      end
      if @state == :walk
        key == :escape || key == "q" || key == "Q" ? end_card : @walk.key(key)
        return
      end
      if @state == :ended
        case key
        when "r", "R", " " then restart
        when "w", "W", "\n" then start_walk
        end
        return
      end
      return unless @state == :show

      case key
      when " " then toggle_pause
      when :right then seek(next_start(song_time))
      when :left then seek(previous_start(song_time))
      when "r", "R" then restart
      when "1".."9" then seek(@entries[key.to_i - 1]&.from || song_time)
      end
    end

    # Back to the start. Scenes that have been retired are built again behind the loader.
    def restart
      @walk&.hide
      @card.hide
      @audio&.stop
      @active&.scene&.leave
      @active&.scene&.hide
      @active = nil
      if @entries.all?(&:scene)
        @state = :show
        seek(0.0)
      else
        reload
      end
    end

    def reload
      @loader = Loader.new(@app, self)
      @ready_at = nil
      @load_began = nil
      @builder = Fiber.new { build_all_in_fiber }
      @state = :loading
    end

    def next_start(t)
      (@entries.map(&:from).find { |s| s > t + 0.05 } || Music::LENGTH - 0.01)
    end

    def previous_start(t)
      starts = @entries.map(&:from).select { |s| s < t - 1.0 }
      starts.last || 0.0
    end

    def toggle_pause
      if @paused
        @paused = false
        seek(@paused_t)
      else
        @paused_t = song_time
        @paused = true
        @audio&.stop
      end
    end

    def toggle_mute
      @muted = !@muted
      if @muted
        @audio&.stop
      elsif @state == :walk
        @walk_audio_until = 0
      elsif @audio && @state == :show && !@paused
        t = song_time
        @t0 = @audio.play(t) - t
      end
    end

    # ---- HUD: the numbers that make the point ----------------------------------------------

    def toggle_hud
      @hud_on = !@hud_on
      @hud_on ? @hud.show : @hud.hide
    end

    def count_lacci_changes
      engine = self
      counter = Module.new do
        define_method(:send_shoes_event) do |*args, event_name: nil, **kwargs|
          engine.lacci_change if event_name == "prop_change"
          super(*args, event_name: event_name, **kwargs)
        end
      end
      Shoes::Drawable.prepend(counter)
    end

    public

    def lacci_change
      @prop_changes += 1
    end

    private

    def note_frame(started)
      @busy = (now - started) * 1000
      @frame_times << started
      @frame_times.shift while @frame_times.size > 61
      changes = Wire.posts + @prop_changes - @backstage_changes
      @frame_changes = changes - @changes_seen
      @changes_seen = changes
      record_stats if @state == :show && !@paused && @active
    end

    # What the credits report: per scene, frames, Ruby time per frame, and the peaks.
    def record_stats
      return if ENV["DIEM_STATS_FILE"]

      label = @active.klass.label
      scenes = (Diem.stats["scenes"] ||= {})
      st = (scenes[label] ||= { "frames" => 0, "busy_ms" => 0.0, "peak_changes" => 0, "shapes" => 0, "first_tick" => @frame_times.last })
      st["frames"] += 1
      st["busy_ms"] += @busy
      st["peak_changes"] = [st["peak_changes"], @frame_changes].max
      st["shapes"] = @active.scene.drawable_count
      st["last_tick"] = @frame_times.last
      Diem.stats["frames"] = Diem.stats.fetch("frames", 0) + 1
      Diem.stats["peak_changes"] = [Diem.stats.fetch("peak_changes", 0), @frame_changes].max
      Diem.stats["peak_shapes"] = [Diem.stats.fetch("peak_shapes", 0), st["shapes"]].max
    end

    def save_stats
      return if ENV["DIEM_STATS_FILE"] || Diem.stats.empty?

      FileUtils.mkdir_p(DATA_DIR)
      File.write(File.join(DATA_DIR, "last_run.json"), JSON.pretty_generate(Diem.stats))
    rescue SystemCallError
      nil
    end

    def update_hud(t, entry)
      @hud_frame = (@hud_frame || 0) + 1
      return unless (@hud_frame % 10).zero?

      span = @frame_times.size > 1 ? @frame_times.last - @frame_times.first : 0
      fps = span.positive? ? ((@frame_times.size - 1) / span).round : 0
      bar = (t / Music::BAR).floor
      beat = ((t / Music::BEAT) % 4).floor + 1
      shapes = entry&.scene&.drawable_count || 0
      @hud.text = format("%-9s bar %02d.%d   ruby %2d Hz, %4.1f ms a frame   %5d shapes   %5d changes a frame%s%s",
        entry&.klass&.label, bar, beat, fps, @busy || 0, shapes, @frame_changes || 0, @muted ? "   muted" : "", @paused ? "   paused" : "")
    end
  end
end
