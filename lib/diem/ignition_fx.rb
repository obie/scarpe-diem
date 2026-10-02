# frozen_string_literal: true

module Diem
  # The drop's punctuation: one frame of white plate, two shockwave rings and a burst of embers,
  # all behind the logo, so letters punch out of the flash and embers stream out from behind the
  # type. Then the fill: four firework shells in front of the debris, one per snare, each opening
  # with a white core and a ring that shoves the debris aside. Sparks follow a closed-form path
  # (drag plus gravity), so they too are pure functions of t.
  class IgnitionFx
    DROP_BURST = 16.0
    FILL_BURSTS = [31.5, 31.625, 31.75, 31.875].freeze
    # Where each fill burst goes off, in half-widths from the logo centre (y squashed by 0.62),
    # and how big it is: each shell is bigger than the last, the fourth one dead centre.
    FILL_SPOTS = [[-0.6, -0.34], [0.58, -0.44], [-0.32, 0.5], [0.06, 0.04]].freeze
    BURST_SCALE = [1.0, 1.08, 1.18, 1.5].freeze
    BURST_SPARKS = 60
    BURST_WHITE = 0.017 # the core's white frame
    RING_LIFE = 0.27
    CORE_LIFE = 0.16
    SPARK_LIFE = 1.5
    FLASH_FRAME = 0.0155 # just under one frame at 60 fps: exactly one frame of white
    FLASH = [228, 250, 255, 255].freeze
    PARK = { left: -40, top: -40, x2: -40, y2: -40 }.freeze

    def initialize(scene, logo, count, burst_sparks)
      @scene = scene
      @logo = logo
      @n = count
      @nb = burst_sparks
      @u = scene.u
      seed
      seed_bursts
      @cols = Array.new(32) do |i|
        x = i / 31.0
        c = if x < 0.25 then Palette.mix(Palette.mix(Palette::INK, Palette::GOLD, 0.55), Palette::GOLD, x * 4)
            elsif x < 0.65 then Palette.mix(Palette::GOLD, Palette::EMBER, (x - 0.25) / 0.4)
            else Palette.mix(Palette::EMBER, Palette::RUBY, (x - 0.65) / 0.35)
            end
        c = Palette.mix(c, Palette::NIGHT, (x**2.2) * 0.85)
        [c[0].round, c[1].round, c[2].round, 255].freeze
      end
      @hot = Array.new(32) do |i|
        x = i / 31.0
        c = if x < 0.12 then Palette::INK
            elsif x < 0.4 then Palette.mix(Palette::INK, Palette::GOLD, (x - 0.12) / 0.28)
            elsif x < 0.7 then Palette.mix(Palette::GOLD, Palette::EMBER, (x - 0.4) / 0.3)
            else Palette.mix(Palette::EMBER, Palette::RUBY, (x - 0.7) / 0.3)
            end
        c = Palette.mix(c, Palette::NIGHT, (x**2.4) * 0.8)
        [c[0].round, c[1].round, c[2].round, 255].freeze
      end
    end

    GLOW = [1.0, 0.76, 0.54, 0.34].freeze

    # Behind the logo, back to front: the soft glow (galaxy core, then halo), the shockwave
    # rings, the embers and the flash plate.
    def build_back
      s = @scene
      clear = s.rgb(0, 0, 0, 0)
      @glow = GLOW.map { s.oval(0, 0, 0, 0, fill: clear, strokewidth: 0, center: true) }
      @ring_a = s.oval(0, 0, 10, 10, fill: clear, stroke: clear, strokewidth: 4, center: true)
      @ring_b = s.oval(0, 0, 10, 10, fill: clear, stroke: clear, strokewidth: 3, center: true)
      @sparks = Array.new(@n) { s.line(-40, -40, -40, -40, stroke: clear, strokewidth: 2, cap: "round") }
      @flash = s.rect(0, 0, s.w, s.h, fill: clear, strokewidth: 0, hidden: true)
    end

    # In front of everything: the fill's shells, ring under sparks under the white core.
    def build_front
      s = @scene
      clear = s.rgb(0, 0, 0, 0)
      @brings = FILL_BURSTS.map { s.oval(-99, -99, 0, 0, fill: clear, stroke: clear, strokewidth: 3, center: true) }
      @bsparks = Array.new(@nb) { s.line(-40, -40, -40, -40, stroke: clear, strokewidth: 2, cap: "round") }
      @bcores = FILL_BURSTS.map { s.oval(-99, -99, 0, 0, fill: clear, strokewidth: 0, center: true) }
    end

    def reset
      @rings_on = true
      @parked = Array.new(@n, false)
      @bparked = Array.new(@nb, false)
      @bring_on = Array.new(FILL_BURSTS.size, true)
      @bcore_on = Array.new(FILL_BURSTS.size, true)
      @flash_on = nil
      @glow_key = nil
    end

    # True on the single white frame of the drop (the logo draws itself as a silhouette).
    def self.flash?(t) = t >= DROP_BURST && t - DROP_BURST < FLASH_FRAME

    def update(t, cx, cy, kick, hat = 0.0)
      glow(t, cx, cy, kick, hat)
      if t >= IgnitionFlight::BOOM
        rings(t - IgnitionFlight::BOOM, cx, cy, 0.75, 0.8, 0.8)
      else
        # On the drop the rings are born just outside the type, so they burst out from behind it.
        rings(t - DROP_BURST, cx, cy, 1.0, 1.1, 1.08)
      end
      sparks(t, cx, cy)
      bursts(t, cx, cy)
      flash(t)
    end

    # The debris the fill's shells push aside: [x, y, radius, strength] per live shell, flat,
    # in screen pixels; empty outside the fill.
    def holes(t, cx, cy)
      out = @holes ||= []
      out.clear
      return out if t < FILL_BURSTS[0]

      FILL_BURSTS.each_with_index do |t0, b|
        tau = t - t0
        next if tau.negative? || tau > 0.3

        bx, by = burst_centre(b, cx, cy)
        out << bx << by << ring_radius(b, tau) * 1.12 << Math.exp(-tau / 0.11)
      end
      out
    end

    private

    def burst_centre(b, cx, cy)
      sx, sy = FILL_SPOTS[b]
      [cx + sx * @logo.half_w, cy + sy * @logo.half_w * 0.62]
    end

    def ring_radius(b, tau)
      u = @u * BURST_SCALE[b]
      (16.0 + 150.0 * (1.0 - Math.exp(-tau / 0.055))) * u
    end

    # Each shell: a ring racing out, a white core that cools to gold and dies, and its sparks.
    def bursts(t, cx, cy)
      return if t < FILL_BURSTS[0] - 0.1 && @bring_on.none? && @bcore_on.none? && @bparked.all?

      bcx = @bcx ||= Array.new(FILL_BURSTS.size, 0.0)
      bcy = @bcy ||= Array.new(FILL_BURSTS.size, 0.0)
      FILL_BURSTS.each_with_index do |t0, b|
        tau = t - t0
        bx, by = burst_centre(b, cx, cy)
        bcx[b] = bx
        bcy[b] = by
        burst_ring(b, tau, bx, by)
        burst_core(b, tau, bx, by)
      end
      burst_sparks(t, bcx, bcy)
    end

    def burst_ring(b, tau, bx, by)
      ring = @brings[b]
      if tau.negative? || tau >= RING_LIFE
        if @bring_on[b]
          @scene.set(ring, { width: 0, height: 0, strokewidth: 0 })
          @bring_on[b] = false
        end
        return
      end
      @bring_on[b] = true
      r = ring_radius(b, tau)
      age = tau / RING_LIFE
      fade = (1.0 - age)**1.1
      col = hot_ramp(tau < BURST_WHITE * 2 ? 0.0 : 0.25 + age)
      @scene.set(ring, { left: bx.round(1), top: by.round(1), width: (2 * r).round(1), height: (1.7 * r).round(1),
        stroke: @scene.wc(col, fade), strokewidth: ((1.0 + 9.0 * (1.0 - age)**2) * @u * BURST_SCALE[b]).round(1) })
    end

    def burst_core(b, tau, bx, by)
      core = @bcores[b]
      if tau.negative? || tau >= CORE_LIFE
        if @bcore_on[b]
          @scene.set(core, { width: 0, height: 0 })
          @bcore_on[b] = false
        end
        return
      end
      @bcore_on[b] = true
      k = BURST_SCALE[b] * @u
      if tau < BURST_WHITE
        r = 30.0 * k
        fill = [255, 255, 255, 255]
      else
        age = tau / CORE_LIFE
        r = 30.0 * k * (1.0 + 0.6 * age) * (1.0 - age)**2
        fill = @scene.wc(hot_ramp(age * 0.8), 1.0 - age * age)
      end
      @scene.set(core, { left: bx.round(1), top: by.round(1), width: (2 * r).round(1), height: (2 * r).round(1), fill: fill })
    end

    # White, gold, then magenta: saturated enough to stay a colour as it fades over the night.
    def hot_ramp(x)
      if x < 0.4 then Palette.mix(Palette::INK, Palette::GOLD, x / 0.4)
      else Palette.mix(Palette::GOLD, Palette::MAGENTA, ((x - 0.4) / 0.5).clamp(0.0, 1.0))
      end
    end

    def burst_sparks(t, bcx, bcy)
      g = 520.0 * @u
      k = 5.0
      parked = @bparked
      lines = @bsparks
      i = 0
      while i < @nb
        b = @bgrp[i]
        tau = t - FILL_BURSTS[b]
        life = @blife[i]
        if tau.negative? || tau >= life
          unless parked[i]
            @scene.set(lines[i], PARK)
            parked[i] = true
          end
          i += 1
          next
        end
        parked[i] = false
        bx = bcx[b]
        by = bcy[b]
        e = Math.exp(-k * tau)
        vx0 = @bvx[i]
        vy0 = @bvy[i]
        x = bx + vx0 * (1.0 - e) / k
        y = by + (vy0 - g / k) * (1.0 - e) / k + g / k * tau
        vx = vx0 * e
        vy = (vy0 - g / k) * e + g / k
        age = tau / life
        tl = 0.03
        tx = vx * tl
        ty = vy * tl
        cap = 46.0 * @u * BURST_SCALE[b]
        len2 = tx * tx + ty * ty
        if len2 > cap * cap
          f = cap / Math.sqrt(len2)
          tx *= f
          ty *= f
        end
        @scene.set(lines[i], {
          left: x.round(1), top: y.round(1), x2: (x - tx).round(1), y2: (y - ty).round(1),
          stroke: @hot[(age * 31).to_i], strokewidth: ((4.2 - 3.0 * age) * @u).round(1)
        })
        i += 1
      end
    end

    def rings(tau, cx, cy, gain, life, start)
      if tau.negative? || tau > life
        if @rings_on
          off = { width: 0, height: 0, strokewidth: 0 }
          @scene.set(@ring_a, off)
          @scene.set(@ring_b, off)
          @rings_on = false
        end
        return
      end
      @rings_on = true
      r0 = @logo.half_w
      q = 1.0 - (1.0 - tau / life)**3
      fade = (1.0 - tau / life)**1.5 * gain
      r = r0 * (start + (2.5 - start) * q)
      @scene.set(@ring_a, { left: cx.round(1), top: cy.round(1), width: (2 * r).round(1), height: (2 * r * 0.46).round(1),
        stroke: @scene.wc(Palette::CYAN, fade), strokewidth: (1.0 + 14.0 * @u * fade).round(1) })
      r = r0 * (start + 0.1 + (3.4 - start) * q)
      @scene.set(@ring_b, { left: cx.round(1), top: (cy + 6 * @u).round(1), width: (2 * r).round(1), height: (0.36 * r).round(1),
        stroke: @scene.wc(Palette::MAGENTA, fade * 0.9), strokewidth: (1.0 + 9.0 * @u * fade).round(1) })
    end

    # The drop burst, out of the letters.
    def sparks(t, cx, cy)
      return if t > DROP_BURST + SPARK_LIFE + 0.1 && @parked.all?

      g = 900.0 * @u
      k = 2.6
      cap = 13.0 * @u
      parked = @parked
      i = 0
      while i < @n
        j = i
        tau = t - @t0[j]
        life = @life[j]
        if tau.negative? || tau >= life
          unless parked[i]
            @scene.set(@sparks[i], PARK)
            parked[i] = true
          end
          i += 1
          next
        end
        parked[i] = false
        e = Math.exp(-k * tau)
        vy0 = @vy[j]
        vx0 = @vx[j]
        x = @ox[j] + vx0 * (1.0 - e) / k
        y = @oy[j] + (vy0 - g / k) * (1.0 - e) / k + g / k * tau
        vx = vx0 * e
        vy = (vy0 - g / k) * e + g / k
        age = tau / life
        tl = 0.022 * (0.4 + 0.6 * (tau / 0.06).clamp(0.0, 1.0))
        tx = vx * tl
        ty = vy * tl
        len2 = tx * tx + ty * ty
        if len2 > cap * cap
          f = cap / Math.sqrt(len2)
          tx *= f
          ty *= f
        end
        hx = cx + x
        hy = cy + y
        @scene.set(@sparks[i], {
          left: hx.round(1), top: hy.round(1), x2: (hx - tx).round(1), y2: (hy - ty).round(1),
          stroke: @cols[(age * 31).to_i], strokewidth: ((3.0 - 2.0 * age) * @u).round(1)
        })
        i += 1
      end
    end

    # One soft light made of stacked translucent ovals: the galaxy's core waking from 4 s, burning
    # through the riser and tightening through the breath, then a violet halo behind the logo
    # from the drop, pumping on the kick.
    def glow(t, cx, cy, kick, hat)
      u = @u
      if t < IgnitionFlight::BREATH
        wake = smooth(3.0, 10.0, t)
        grow = smooth(4.5, 13.4, t)
        a = (0.044 + 0.016 * hat) * wake + 0.026 * smooth(11.8, 13.4, t)
        a *= 1.0 - 0.45 * smooth(14.6, 15.5, t)
        gw = (130.0 + 170.0 * grow) * u
        gh = (48.0 + 62.0 * grow) * u
        col = Palette.mix(Palette::INK, Palette::VIOLET, 0.45)
      elsif t < IgnitionFlight::DROP
        # The breath: the core tightens and burns hotter as the galaxy draws in, then the snap.
        k = smooth(IgnitionFlight::BREATH, IgnitionLogo::SNAP_FROM, t)
        a = (0.04 + 0.035 * k) * (1.0 - smooth(IgnitionLogo::SNAP_FROM, IgnitionFlight::DROP, t))
        gw = (300.0 - 150.0 * k) * u
        gh = (110.0 - 52.0 * k) * u
        col = Palette.mix(Palette::INK, Palette::VIOLET, 0.45 - 0.2 * k)
      else
        a = (0.04 * kick + 0.07 * Math.exp(-(t - IgnitionFlight::DROP) / 0.4)) * (1.0 - smooth(31.0, 31.6, t))
        gw = (800.0 + 60.0 * kick) * u
        gh = (360.0 + 30.0 * kick) * u
        col = Palette.mix(Palette::VIOLET, Palette::MAGENTA, 0.5 + 0.5 * Math.sin(t * 0.7))
      end
      ai = (a * 255).round
      if ai < 3
        return if @glow_key == :off

        @glow.each { |o| @scene.set(o, { width: 0, height: 0 }) }
        @glow_key = :off
        return
      end
      key = [ai, gw.round, cx.round, cy.round, col.map(&:round)]
      return if key == @glow_key

      @glow_key = key
      fill = [col[0].round, col[1].round, col[2].round, ai]
      @glow.each_with_index do |o, i|
        k = GLOW[i]
        @scene.set(o, { left: cx.round(1), top: cy.round(1), width: (gw * k).round(1), height: (gh * k).round(1), fill: fill })
      end
    end

    def smooth(a, b, t)
      x = ((t - a) / (b - a)).clamp(0.0, 1.0)
      x * x * (3.0 - 2.0 * x)
    end

    # One frame of full white plate behind the logo on the downbeat, then nothing: the blacks
    # never sit at grey.
    def flash(t)
      on = self.class.flash?(t)
      return if on == @flash_on

      @flash_on = on
      @scene.set(@flash, on ? { hidden: false, fill: FLASH } : { hidden: true })
    end

    def seed
      rnd = Random.new(1601)
      @ox = []
      @oy = []
      @vx = []
      @vy = []
      @life = []
      @t0 = []
      @n.times do
        hx, hy = @logo.home(rnd.rand(@logo.count))
        a = rnd.rand * Math::PI * 2
        v = (500.0 + rnd.rand * 1500.0) * @u
        @ox << hx
        @oy << hy
        @vx << Math.cos(a) * v + hx * 1.2
        @vy << Math.sin(a) * v * 0.7 - 300.0 * @u
        @life << 0.6 + rnd.rand * (SPARK_LIFE - 0.6)
        @t0 << DROP_BURST
      end
    end

    # The fill shells' sparks: a fast even shell plus a few slow stragglers, per burst.
    def seed_bursts
      rnd = Random.new(3131)
      @bgrp = []
      @bvx = []
      @bvy = []
      @blife = []
      @nb.times do |i|
        b = i % FILL_BURSTS.size
        a = (i / FILL_BURSTS.size) * 2.39996 + rnd.rand * 0.3
        v = (rnd.rand < 0.75 ? 2000.0 + rnd.rand * 900.0 : 700.0 + rnd.rand * 900.0) * @u * BURST_SCALE[b]
        @bgrp << b
        @bvx << Math.cos(a) * v
        @bvy << Math.sin(a) * v * 0.85 - 120.0 * @u
        @blife << 0.26 + rnd.rand * 0.24
      end
    end
  end
end
