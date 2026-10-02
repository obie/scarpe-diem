# frozen_string_literal: true

# SCARPE DIEM soundtrack synthesizer.
#
# Renders a Diem::Music score (the format is documented in music_test.rb) to a
# 44.1 kHz stereo 16-bit WAV with nothing but the Ruby standard library.
#
#   ruby lib/diem/synth.rb OUT.wav [PROGRESS_FILE] [--test] [--verbose]
#
# Each track is cut into 16 s segments, each rendered in a forked worker
# (unique notes are rendered once and mixed in as copies; track effects run
# in the worker because they are linear). The parent then forks chunk workers
# that sum the stems, run the master bus and write 16-bit PCM. The WAV and the
# progress file are replaced atomically, so readers never see half a file.
# Without fork, the same work runs in this process, slower but bit-identical.

require "tmpdir"

module Diem
  module Synth
    SR = 44_100
    TWO_PI = 2.0 * Math::PI
    ROOT2 = Math.sqrt(2.0)
    TAIL = 3.0            # seconds of ring-out after the last bar
    END_FADE = 0.6        # seconds faded out at the very end of the tail
    PEAK = 0.3            # final peak, as a fraction of full scale
    DRIVE = 1.2           # raw mix peak is scaled to this before the tanh soft clip
    DUCK_RELEASE = 0.25   # sidechain recovery time in seconds

    # Per-track mix settings. gain: fader. pan: -1..1 for mono sources.
    # duck: sidechain depth keyed from the kick. reverb / delay: send levels.
    TRACKS = {
      kick: { gain: 0.85 },
      snare: { gain: 0.70, reverb: 0.30 },
      clap: { gain: 0.90, reverb: 0.40, pan: -0.06 },
      hat: { gain: 0.90, pan: 0.25 },
      ohat: { gain: 0.60, pan: 0.18 },
      crash: { gain: 0.34 },
      bass: { gain: 0.30, duck: 0.6 },
      sub: { gain: 0.13, duck: 0.6 },
      arp: { gain: 0.25, duck: 0.5, delay: 1.0 },
      pad: { gain: 0.24, duck: 0.6, reverb: 0.45 },
      lead: { gain: 0.70, delay: 0.55, reverb: 0.30 },
      lead2: { gain: 0.55, pan: -0.3, delay: 0.55, reverb: 0.35 },
      bell: { gain: 0.26, reverb: 0.55 },
      riser: { gain: 0.45 },
      impact: { gain: 0.50 }
    }.freeze

    Song = Struct.new(:step, :beat, :length, :frames, :kicks)

    # A rendered stereo sound; plain Arrays are mono.
    Stereo = Struct.new(:left, :right)

    Note = Struct.new(:dur, :midi, :vel, :opts, :prev_midi) do
      def freq = DSP.midi_hz(midi || 69)
      def cut = opt(:cut, 0.5).to_f
      def dec = opt(:dec, 1.0).to_f
      def glide? = opt(:glide, false) && !prev_midi.nil?

      def opt(key, default)
        value = opts && opts[key]
        value.nil? ? default : value
      end
    end

    # Sample-level building blocks. Everything works in place on plain Arrays
    # of Floats with while-loops and locals, which is what YJIT runs fastest.
    module DSP
      module_function

      def samples(seconds) = (seconds * SR).round
      def zeros(count) = Array.new(count, 0.0)
      def midi_hz(midi) = 440.0 * (2.0**((midi - 69) / 12.0))
      def cents(amount) = 2.0**(amount / 1200.0)
      def clamp(value, low, high) = value < low ? low : (value > high ? high : value)

      def noise(count, seed)
        rng = Random.new(seed)
        Array.new(count) { (rng.rand * 2.0) - 1.0 }
      end

      def add!(dst, src, gain = 1.0)
        i = 0
        n = src.size < dst.size ? src.size : dst.size
        while i < n
          dst[i] += src[i] * gain
          i += 1
        end
        dst
      end

      def add_at!(dst, src, start, gain = 1.0)
        stop = start + src.size
        stop = dst.size if stop > dst.size
        i = start
        j = 0
        while i < stop
          dst[i] += src[j] * gain
          i += 1
          j += 1
        end
        dst
      end

      # PolyBLEP residual that rounds off a unit step at phase 0.
      def blep(t, dt)
        if t < dt
          x = t / dt
          x + x - (x * x) - 1.0
        elsif t > 1.0 - dt
          x = (t - 1.0) / dt
          (x * x) + x + x + 1.0
        else
          0.0
        end
      end

      # Band-limited sawtooth added into buf. freq is Hz, or an Array of Hz per
      # sample. The PolyBLEP is inlined here: saws are the hottest loop (pads).
      def saw!(buf, freq, gain = 1.0, phase = 0.0)
        per_sample = freq.is_a?(Array)
        dt = per_sample ? 0.0 : freq / SR
        p = phase
        i = 0
        n = buf.size
        while i < n
          dt = freq[i] / SR if per_sample
          p += dt
          p -= 1.0 if p >= 1.0
          v = p + p - 1.0
          if p < dt
            x = p / dt
            v -= x + x - (x * x) - 1.0
          elsif p > 1.0 - dt
            x = (p - 1.0) / dt
            v -= (x * x) + x + x + 1.0
          end
          buf[i] += v * gain
          i += 1
        end
        buf
      end

      # Band-limited pulse (duty 0..1) added into buf, DC removed.
      def pulse!(buf, freq, gain = 1.0, duty = 0.5, phase = 0.0)
        per_sample = freq.is_a?(Array)
        dt = per_sample ? 0.0 : freq / SR
        offset = (2.0 * duty) - 1.0
        p = phase
        i = 0
        n = buf.size
        while i < n
          dt = freq[i] / SR if per_sample
          p += dt
          p -= 1.0 if p >= 1.0
          q = p - duty
          q += 1.0 if q < 0.0
          v = (p < duty ? 1.0 : -1.0) + blep(p, dt) - blep(q, dt)
          buf[i] += (v - offset) * gain
          i += 1
        end
        buf
      end

      def sine!(buf, freq, gain = 1.0)
        per_sample = freq.is_a?(Array)
        inc = per_sample ? 0.0 : freq / SR
        p = 0.0
        i = 0
        n = buf.size
        while i < n
          inc = freq[i] / SR if per_sample
          buf[i] += Math.sin(TWO_PI * p) * gain
          p += inc
          p -= 1.0 if p >= 1.0
          i += 1
        end
        buf
      end

      # Topology-preserving state-variable filter (Cytomic / Simper), 12 dB/oct.
      # mode is :low, :band (unity peak) or :high. cutoff is Hz or a callable
      # taking the sample index, evaluated every 16 samples.
      def svf!(buf, mode, cutoff, q = 0.707)
        k = 1.0 / q
        low, band, high = { low: [1.0, 0.0, 0.0], band: [0.0, k, 0.0], high: [0.0, 0.0, 1.0] }.fetch(mode)
        moving = cutoff.respond_to?(:call)
        a1 = a2 = a3 = ic1 = ic2 = 0.0
        i = 0
        n = buf.size
        while i < n
          if (i & 15).zero? && (moving || i.zero?)
            fc = clamp(moving ? cutoff.call(i) : cutoff, 20.0, SR * 0.45)
            g = Math.tan(Math::PI * fc / SR)
            a1 = 1.0 / (1.0 + (g * (g + k)))
            a2 = g * a1
            a3 = g * a2
          end
          v0 = buf[i]
          v3 = v0 - ic2
          v1 = (a1 * ic1) + (a2 * v3)
          v2 = ic2 + (a2 * ic1) + (a3 * v3)
          ic1 = v1 + v1 - ic1
          ic2 = v2 + v2 - ic2
          buf[i] = (low * v2) + (band * v1) + (high * (v0 - (k * v1) - v2))
          i += 1
        end
        buf
      end

      # Multiply by exp(-t / tau) from sample `from` onwards.
      def decay!(buf, tau, from = 0)
        k = Math.exp(-1.0 / (tau * SR))
        amp = 1.0
        i = from
        n = buf.size
        while i < n
          buf[i] *= amp
          amp *= k
          i += 1
        end
        buf
      end

      # Raised-cosine fade in over the first `seconds`.
      def fade_in!(buf, seconds)
        len = [samples(seconds), buf.size].min
        i = 0
        while i < len
          buf[i] *= 0.5 - (0.5 * Math.cos(Math::PI * i / len))
          i += 1
        end
        buf
      end

      # Raised-cosine fade out starting at `start` seconds; silence afterwards.
      def fade_out!(buf, start, seconds)
        from = samples(start).clamp(0, buf.size)
        len = [samples(seconds), 1].max
        i = from
        n = buf.size
        while i < n
          j = i - from
          buf[i] *= j < len ? 0.5 + (0.5 * Math.cos(Math::PI * j / len)) : 0.0
          i += 1
        end
        buf
      end

      # tanh saturation normalised so a full-scale input stays full scale.
      def saturate!(buf, drive)
        norm = 1.0 / Math.tanh(drive)
        buf.map! { |v| Math.tanh(v * drive) * norm }
      end
    end

    # One method per track. Each takes a Note and returns a mono Array or a
    # Stereo pair at unit velocity; the mixer applies velocity, gain and pan.
    module Instruments
      extend DSP

      HAT_FREQS = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].freeze
      PAD_CENTS = { left: [-19.0, -9.0, -2.0, 7.0, 16.0], right: [-16.0, -6.0, 3.0, 10.0, 20.0] }.freeze
      GLIDE = 0.06

      module_function

      def kick(_note)
        buf = zeros(samples(0.55))
        sweep_k = Math.exp(-1.0 / (0.03 * SR))
        amp_k = Math.exp(-1.0 / (0.1 * SR))
        hold = samples(0.012)
        sweep = 1.0
        amp = 1.0
        phase = 0.0
        i = 0
        while i < buf.size
          phase += (48.0 + (122.0 * sweep)) / SR
          buf[i] = Math.sin(TWO_PI * phase) * amp
          sweep *= sweep_k
          amp *= amp_k if i > hold
          i += 1
        end
        add!(buf, click(samples(0.006), 7), 0.3)
        saturate!(buf, 1.4)
        fade_out!(buf, 0.5, 0.05)
      end

      def click(count, seed)
        burst = svf!(svf!(noise(count, seed), :low, 4500.0), :low, 4500.0)
        fade_in!(burst, 0.0004)
        decay!(burst, 0.0016)
      end

      def snare(note)
        n = samples(0.42)
        crack = decay!(svf!(noise(n, 11), :band, 1900.0, 0.9), 0.055 * note.dec)
        tail = svf!(svf!(noise(n, 12), :high, 900.0), :low, 7500.0)
        fade_out!(decay!(tail, 0.3), 0.15, 0.05)
        body = zeros(n)
        sine!(body, Array.new(n) { |i| 185.0 + (45.0 * Math.exp(-i / (0.012 * SR))) })
        decay!(body, 0.045)
        buf = add!(add!(crack, tail, 0.32), body, 0.55)
        fade_in!(buf, 0.0008)
        fade_out!(buf, 0.37, 0.05)
      end

      def clap(note)
        n = samples(0.4)
        buf = svf!(noise(n, 23), :band, 1200.0, 1.1)
        tail_tau = 0.09 * note.dec
        buf.each_index { |i| buf[i] *= clap_env(i.to_f / SR, tail_tau) }
        svf!(buf, :high, 500.0)
        fade_out!(buf, 0.35, 0.05)
      end

      def clap_env(t, tail_tau)
        bursts = 0.0
        [0.0, 0.010, 0.021].each do |at|
          next if t < at

          bursts += clamp((t - at) / 0.0004, 0.0, 1.0) * Math.exp(-(t - at) / 0.0035)
        end
        tail = t < 0.021 ? 0.0 : 0.7 * Math.exp(-(t - 0.021) / tail_tau)
        bursts + tail
      end

      def hat(note) = metallic_hit(0.12, 0.014 * note.dec, 31)
      def ohat(note) = metallic_hit(0.55, 0.075 * note.dec, 37)

      def metallic_hit(seconds, tau, seed)
        n = samples(seconds)
        buf = metal(n, seed)
        fade_in!(buf, 0.0005)
        decay!(buf, tau)
        fade_out!(buf, seconds - 0.03, 0.03)
      end

      # Six inharmonic squares (the 808 recipe) plus a little noise, high-passed.
      def metal(count, seed)
        buf = zeros(count)
        HAT_FREQS.each_with_index { |f, j| pulse!(buf, f * 1.6, 0.17, 0.5, j * 0.137) }
        add!(buf, noise(count, seed), 0.45)
        svf!(buf, :band, 9500.0, 0.8)
        svf!(buf, :high, 6500.0)
      end

      def crash(note)
        n = samples(2.8)
        sides = [53, 59].map do |seed|
          side = add!(noise(n, seed), metal(n, seed + 1), 0.5)
          svf!(svf!(side, :high, 3500.0, 0.6), :low, 13_000.0)
          fade_in!(side, 0.002)
          decay!(side, 0.55 * note.dec)
          fade_out!(side, 2.5, 0.3)
        end
        Stereo.new(*sides)
      end

      def bass(note)
        dur = note.dur
        f = note.freq
        buf = zeros(samples(dur + 0.03))
        saw!(buf, f * cents(-7.0), 0.5)
        saw!(buf, f * cents(7.0), 0.5, 0.37)
        base = (f * 1.5) + 80.0 + (600.0 * note.cut)
        depth = 300.0 + (3600.0 * note.cut)
        tau = 0.08 * note.dec * SR
        svf!(buf, :low, ->(i) { base + (depth * Math.exp(-i / tau)) }, 2.2)
        saturate!(buf, 1.5)
        fade_in!(buf, 0.002)
        fade_out!(buf, dur, 0.03)
      end

      def sub(note)
        buf = sine!(zeros(samples(note.dur + 0.05)), note.freq)
        fade_in!(buf, 0.012)
        fade_out!(buf, note.dur, 0.05)
      end

      def arp(note)
        dur = note.dur
        f = note.freq
        buf = zeros(samples(dur + 0.12))
        pulse!(buf, f, 0.6, 0.3)
        pulse!(buf, f * cents(6.0), 0.3, 0.3, 0.5)
        cut = note.cut
        tau = 0.06 * SR
        svf!(buf, :low, ->(i) { 350.0 + (4200.0 * cut * cut) + (2500.0 * cut * Math.exp(-i / tau)) }, 1.1)
        decay!(buf, 0.16 * note.dec)
        fade_in!(buf, 0.0015)
        fade_out!(buf, dur, 0.12)
      end

      def pad(note)
        dur = note.dur
        n = samples(dur + 1.0)
        rng = Random.new(note.midi.to_i)
        fc = 900.0 + (2600.0 * note.cut)
        sides = PAD_CENTS.values.map do |detunes|
          side = zeros(n)
          detunes.each { |c| saw!(side, note.freq * cents(c), 0.22, rng.rand) }
          svf!(side, :low, fc, 0.6)
          fade_in!(side, [0.55, dur * 0.6].min)
          fade_out!(side, dur, 1.0)
        end
        Stereo.new(*sides)
      end

      def lead(note)
        dur = note.dur
        freqs = lead_freqs(note, samples(dur + 0.14))
        buf = zeros(freqs.size)
        saw!(buf, freqs, 0.55)
        pulse!(buf, freqs, 0.3)
        cut = note.cut
        tau = 0.2 * SR
        svf!(buf, :low, ->(i) { 2200.0 + (3000.0 * cut) + (1800.0 * Math.exp(-i / tau)) }, 0.9)
        fade_in!(buf, note.glide? ? 0.012 : 0.006)
        fade_out!(buf, dur, 0.14)
      end

      # Per-sample frequency: optional portamento from the previous note, then
      # a 5.5 Hz vibrato that fades in after 0.2 s.
      def lead_freqs(note, count)
        target = Math.log(note.freq)
        from = note.glide? ? Math.log(midi_hz(note.prev_midi)) : target
        Array.new(count) do |i|
          t = i.to_f / SR
          g = t < GLIDE ? smoothstep(t / GLIDE) : 1.0
          depth = 16.0 * clamp((t - 0.2) / 0.35, 0.0, 1.0)
          Math.exp(from + ((target - from) * g)) * cents(depth * Math.sin(TWO_PI * 5.5 * t))
        end
      end

      def smoothstep(x) = x * x * (3.0 - (2.0 * x))

      # Harmony voice under the lead: the same patch, a little darker.
      def lead2(note)
        opts = (note.opts || {}).merge(cut: note.cut * 0.7)
        lead(Note.new(note.dur, note.midi, note.vel, opts, note.prev_midi))
      end

      BELL_RATIO = 3.5      # modulator : carrier
      BELL_FLOOR = 0.4      # FM index the bell keeps after its strike has decayed
      FOLD_LIMIT = SR - 16_000.0 # a sideband above this folds back below 16 kHz
      FOLD_POWER = 1e-6     # most power such sidebands may carry (-60 dB)
      BELL_TOUCHES = 32     # brightness steps across the velocity range

      def bell(note)
        n = samples(2.6 * note.dec)
        strike = (0.8 + (2.0 * bell_touch(note.vel))) * clamp(1500.0 / note.freq, 0.35, 1.0)
        scale = bell_index(note.freq, strike + BELL_FLOOR) / (strike + BELL_FLOOR)
        sides = [0.6, -0.6].map { |detune| fm_bell(n, note.freq + detune, strike * scale, BELL_FLOOR * scale) }
        sides.each do |side|
          fade_in!(side, 0.001)
          fade_out!(side, (n.to_f / SR) - 0.2, 0.2)
        end
        Stereo.new(*sides)
      end

      # Velocity sets the brightness in steps of 1/BELL_TOUCHES, so humanised
      # velocities share renders; the mixer still scales the level exactly.
      def bell_touch(vel) = (vel * BELL_TOUCHES).round / BELL_TOUCHES.to_f

      # The largest FM index up to `wanted` whose sidebands that would alias
      # into the audible band stay under FOLD_POWER. High bells need it: at
      # MIDI 95 the unlimited index folded about -28 dB of power below 16 kHz.
      def bell_index(freq, wanted)
        return wanted if folded_power(freq, wanted) < FOLD_POWER

        low = 0.0
        high = wanted
        30.times do
          mid = (low + high) / 2.0
          folded_power(freq, mid) < FOLD_POWER ? low = mid : high = mid
        end
        low
      end

      # Share of an FM tone's power (sideband k carries J_k(index)^2) above FOLD_LIMIT.
      def folded_power(freq, index)
        (-40..40).sum do |k|
          (freq + (k * BELL_RATIO * freq)).abs > FOLD_LIMIT ? bessel(k.abs, index)**2 : 0.0
        end
      end

      # Bessel function of the first kind, J_order(x), by its power series (fine for x < 10).
      def bessel(order, x)
        half = x / 2.0
        term = (1..order).reduce(1.0) { |t, m| t * half / m }
        sum = 0.0
        40.times do |m|
          sum += term
          term *= -half * half / ((m + 1) * (m + 1 + order))
        end
        sum
      end

      # Carrier:modulator 1:3.5 with a decaying index, plus a soft octave shimmer.
      def fm_bell(count, freq, strike, floor)
        buf = zeros(count)
        amp_k = Math.exp(-1.0 / (0.6 * SR))
        index_k = Math.exp(-1.0 / (0.28 * SR))
        shimmer_k = Math.exp(-1.0 / (0.3 * SR))
        amp = 1.0
        idx = strike
        shimmer = 0.22
        w = TWO_PI * freq / SR
        i = 0
        while i < count
          mod = Math.sin(w * BELL_RATIO * i)
          buf[i] = (Math.sin((w * i) + ((idx + floor) * mod)) * amp) + (Math.sin(w * 2.0 * i) * shimmer)
          amp *= amp_k
          idx *= index_k
          shimmer *= shimmer_k
          i += 1
        end
        buf
      end

      # Band-passed noise sweeping 300 Hz to 8 kHz, swelling, ending exactly at the event end.
      def riser(note)
        n = [samples(note.dur), 1].max
        ratio = Math.log(8000.0 / 300.0)
        sweep = ->(i) { 300.0 * Math.exp(ratio * i / n) }
        sides = [41, 43].map do |seed|
          side = svf!(noise(n, seed), :band, sweep, 2.0)
          side.each_index { |i| side[i] *= (i.to_f / n)**2 }
          fade_out!(side, note.dur - 0.006, 0.006)
        end
        Stereo.new(*sides)
      end

      def impact(note)
        n = samples(2.8)
        boom = zeros(n)
        sine!(boom, Array.new(n) { |i| 30.0 + (40.0 * Math.exp(-i / (0.55 * SR))) })
        decay!(boom, 0.6 * note.dec)
        saturate!(boom, 1.3)
        sides = [61, 67].map do |seed|
          burst = decay!(svf!(noise(n, seed), :low, 1200.0), 0.08)
          side = add!(burst.map { |v| v * 0.5 }, boom)
          fade_in!(side, 0.002)
          fade_out!(side, 2.5, 0.3)
        end
        Stereo.new(*sides)
      end
    end

    # Linear effects, run inside a track job on that job's own signal. Since
    # they are linear (and the sidechain is a per-sample gain), a send bus fed
    # by several tracks equals the sum of each track's own copy, so the buses
    # render in parallel with everything else. Hot loops live in *_span!
    # methods with plain locals, the shape YJIT compiles best.
    module FX
      extend DSP

      COMBS = [1116, 1188, 1277, 1356].freeze
      ALLPASSES = [556, 441].freeze
      SPREAD = 23
      ROOM = 0.84
      DAMP = 0.32
      PREDELAY = 0.022
      REVERB_LEVEL = 0.16
      SEND_HP = Math.exp(-TWO_PI * 250.0 / SR) # keeps the low end out of the reverb
      DELAY_FEEDBACK = 0.35
      DELAY_WET = 0.3
      DELAY_TONE = Math.exp(-TWO_PI * 3500.0 / SR)

      module_function

      # Schroeder/Freeverb style: 4 damped combs into 2 allpasses per channel,
      # processed only over the regions that carry signal (plus a decay tail).
      def reverb!(left, right, amount, regions)
        delay = samples(PREDELAY)
        send = zeros(left.size)
        regions.each { |from, to| send_span!(left, right, send, amount, delay, from, to) }
        # The predelay can push one region into the next; they must not overlap,
        # or the wet signal there would be added twice.
        regions = coalesce(regions.map { |from, to| [from, [to + delay, left.size].min] })
        [[left, 0], [right, SPREAD]].each do |channel, spread|
          wet = zeros(channel.size)
          COMBS.each { |len| each_span(regions, zeros(len + spread)) { |line, a, b| comb_span!(send, wet, line, a, b) } }
          ALLPASSES.each { |len| each_span(regions, zeros(len + spread)) { |line, a, b| allpass_span!(wet, line, a, b) } }
          regions.each { |from, to| add_span!(channel, wet, REVERB_LEVEL, from, to) }
        end
      end

      # Ping-pong delay: the send enters the left line and each repeat crosses sides.
      def ping_pong!(left, right, amount, time, regions)
        line_l = zeros(samples(time))
        line_r = zeros(samples(time))
        regions.each do |from, to|
          line_r.fill(0.0)
          ping_pong_span!(left, right, line_l.fill(0.0), line_r, DELAY_WET * amount, from, to)
        end
      end

      # The synthwave pump: dip on every kick, smooth recovery over DUCK_RELEASE.
      # kicks are [frame, velocity] relative to the buffer and may start before it.
      # Overlapping dips combine by their maximum, so kicks closer together than
      # the release never make the gain jump.
      def duck!(left, right, depth, kicks)
        attack = samples(0.004)
        release = samples(DUCK_RELEASE)
        dip = zeros(left.size)
        kicks.each { |start, vel| dip_span!(dip, depth * vel, start, attack, release) }
        apply_dip!(left, right, dip)
      end

      # Merges sorted [from, to) ranges that touch or overlap.
      def coalesce(regions)
        regions.each_with_object([]) do |(from, to), merged|
          if merged.any? && from <= merged.last[1]
            merged.last[1] = [merged.last[1], to].max
          else
            merged << [from, to]
          end
        end
      end

      # Yields a cleared delay line with each region; state never carries across regions.
      def each_span(regions, line)
        regions.each { |from, to| yield line.fill(0.0), from, to }
      end

      def send_span!(left, right, send, amount, delay, from, to)
        hp = SEND_HP
        prev_in = prev_out = 0.0
        stop = [to, send.size - delay].min
        i = from
        while i < stop
          x = (left[i] + right[i]) * 0.5 * amount
          prev_out = hp * (prev_out + x - prev_in)
          prev_in = x
          send[i + delay] = prev_out
          i += 1
        end
      end

      def comb_span!(input, output, line, from, to)
        len = line.size
        damp = DAMP
        keep = 1.0 - damp
        room = ROOM
        filt = 0.0
        idx = 0
        i = from
        while i < to
          out = line[idx]
          filt = (out * keep) + (filt * damp)
          line[idx] = input[i] + (filt * room)
          idx += 1
          idx = 0 if idx == len
          output[i] += out
          i += 1
        end
      end

      def allpass_span!(buf, line, from, to)
        len = line.size
        idx = 0
        i = from
        while i < to
          delayed = line[idx]
          x = buf[i]
          line[idx] = x + (delayed * 0.5)
          buf[i] = delayed - x
          idx += 1
          idx = 0 if idx == len
          i += 1
        end
      end

      def add_span!(dst, src, gain, from, to)
        i = from
        while i < to
          dst[i] += src[i] * gain
          i += 1
        end
      end

      def ping_pong_span!(left, right, line_l, line_r, wet, from, to)
        len = line_l.size
        tone = DELAY_TONE
        feedback = DELAY_FEEDBACK
        lp = 0.0
        idx = 0
        i = from
        while i < to
          out_l = line_l[idx]
          out_r = line_r[idx]
          lp = (out_r * (1.0 - tone)) + (lp * tone)
          line_l[idx] = ((left[i] + right[i]) * 0.5) + (lp * feedback)
          line_r[idx] = out_l * feedback
          left[i] += out_l * wet
          right[i] += out_r * wet
          idx += 1
          idx = 0 if idx == len
          i += 1
        end
      end

      # One kick's dip: a smoothstep down over `attack`, then a smoothstep back
      # up over `release`, so the gain curve has no corners to click on.
      def dip_span!(dip, amount, start, attack, release)
        stop = start + attack + release
        stop = dip.size if stop > dip.size
        i = start.negative? ? 0 : start
        while i < stop
          j = i - start
          x = j < attack ? j.to_f / attack : 1.0 - ((j - attack).to_f / release)
          d = amount * x * x * (3.0 - (2.0 * x))
          dip[i] = d if d > dip[i]
          i += 1
        end
      end

      def apply_dip!(left, right, dip)
        i = 0
        n = dip.size
        while i < n
          d = dip[i]
          if d > 0.0
            left[i] *= 1.0 - d
            right[i] *= 1.0 - d
          end
          i += 1
        end
      end
    end

    # A slice of one track: the notes that start inside one stretch of the
    # timeline. Its buffer begins at `from` and runs past the last note's end
    # by the effect tail, so slices overlap and simply add up in the mix.
    Segment = Struct.new(:track, :index, :from, :notes) do # notes: [[frame, Note], ...]
      def name = "#{track}-#{index}"
    end

    # A rendered slice on disk: planar float32, all left samples then all right.
    Stem = Struct.new(:path, :offset, :frames)

    # Renders one Segment: unique notes once, copies mixed into the buffer,
    # then the track's effects and sidechain. Velocity and the fader are
    # applied as each copy is mixed in.
    class TrackRenderer
      include DSP

      EFFECT_TAIL = 4.0 # seconds the buffer runs past the last sound

      def initialize(segment, song)
        @segment = segment
        @song = song
        @name = segment.track
        @config = TRACKS.fetch(@name)
        @cache = {}
      end

      def render
        placed = @segment.notes.map { |frame, note| [frame - @segment.from, note, sound_for(note)] }
        frames = buffer_frames(placed)
        left = zeros(frames)
        right = zeros(frames)
        spans = placed.map { |start, note, sound| mix!(left, right, sound, start, note) }
        apply_effects(left, right, merged(spans, frames))
        [left, right]
      end

      private

      def sound_for(note)
        @cache[cache_key(note)] ||= Instruments.public_send(@name, note)
      end

      # What a rendered sound depends on. Velocity only scales the output, so
      # it stays out, except on the bell: its brightness follows velocity in
      # coarse steps, and its length ignores the note's.
      def cache_key(note)
        return [note.midi, note.opts, Instruments.bell_touch(note.vel)] if @name == :bell

        [note.dur, note.midi, note.opts, note.glide? ? note.prev_midi : nil]
      end

      def buffer_frames(placed)
        last = placed.map { |start, _note, sound| start + sound_size(sound) }.max || 0
        [last + samples(EFFECT_TAIL), @song.frames - @segment.from].min
      end

      def sound_size(sound) = sound.is_a?(Stereo) ? sound.left.size : sound.size

      # Mono sounds pan with an equal-power law; stereo ones balance. Returns the span written.
      def mix!(left, right, sound, start, note)
        gain = @config[:gain] * note.vel
        pan = clamp(note.opt(:pan, @config.fetch(:pan, 0.0)).to_f, -1.0, 1.0)
        if sound.is_a?(Stereo)
          add_at!(left, sound.left, start, gain * clamp(1.0 - pan, 0.0, 1.0))
          add_at!(right, sound.right, start, gain * clamp(1.0 + pan, 0.0, 1.0))
        else
          angle = (pan + 1.0) * Math::PI / 4.0
          add_at!(left, sound, start, gain * Math.cos(angle) * ROOT2)
          add_at!(right, sound, start, gain * Math.sin(angle) * ROOT2)
        end
        [start, start + sound_size(sound)]
      end

      def apply_effects(left, right, regions)
        FX.ping_pong!(left, right, @config[:delay], 0.75 * @song.beat, regions) if @config[:delay]
        FX.reverb!(left, right, @config[:reverb], regions) if @config[:reverb]
        FX.duck!(left, right, @config[:duck], local_kicks(left.size)) if @config[:duck]
      end

      def local_kicks(frames)
        reach = samples(0.004 + DUCK_RELEASE)
        @song.kicks.map { |frame, vel| [frame - @segment.from, vel] }
                   .select { |frame, _vel| frame + reach > 0 && frame < frames }
      end

      # Sound spans plus the effect tail, merged into disjoint [from, to) ranges.
      def merged(spans, frames)
        tail = samples(EFFECT_TAIL)
        FX.coalesce(spans.sort.map { |from, to| [from, [to + tail, frames].min] })
      end
    end

    # Sums one range of frames across every stem, runs the master bus and
    # writes interleaved 16-bit PCM. Three steps, so the parent can find the
    # global peaks in between: sum (raw peak), shape (peak after the soft
    # clip and DC blocker), write.
    class ChunkMixer
      DC_POLE = Math.exp(-TWO_PI * 18.0 / SR) # one-pole DC and rumble blocker at 18 Hz
      WARMUP = (0.5 * SR).to_i # frames read before the chunk to settle the blocker

      def initialize(stems, song, from, to)
        @stems = stems
        @song = song
        @from = from
        @to = to
      end

      def sum!
        @lead_in = [@from, WARMUP].min
        @left = read_channel(0, @from - @lead_in)
        @right = read_channel(1, @from - @lead_in)
        [peak(@left, @lead_in), peak(@right, @lead_in)].max
      end

      def shape!(drive)
        [@left, @right].each do |buf|
          soft_clip!(buf, drive)
          dc_block!(buf)
          buf.shift(@lead_in)
        end
        [peak(@left, 0), peak(@right, 0)].max
      end

      def write(gain, path)
        File.binwrite(path, pcm(gain).pack("s<*"))
      end

      private

      def read_channel(channel, start)
        buf = DSP.zeros(@to - start)
        @stems.each do |stem|
          a = [start, stem.offset].max
          b = [@to, stem.offset + stem.frames].min
          next if a >= b

          data = File.open(stem.path, "rb") do |f|
            f.seek(((channel * stem.frames) + a - stem.offset) * 4)
            f.read((b - a) * 4)
          end
          DSP.add_at!(buf, data.unpack("e*"), a - start)
        end
        buf
      end

      def soft_clip!(buf, drive)
        i = 0
        n = buf.size
        while i < n
          buf[i] = Math.tanh(buf[i] * drive)
          i += 1
        end
      end

      def dc_block!(buf)
        pole = DC_POLE
        prev_in = prev_out = 0.0
        i = 0
        n = buf.size
        while i < n
          x = buf[i]
          prev_out = x - prev_in + (pole * prev_out)
          prev_in = x
          buf[i] = prev_out
          i += 1
        end
      end

      def peak(buf, from)
        best = 0.0
        i = from
        n = buf.size
        while i < n
          v = buf[i].abs
          best = v if v > best
          i += 1
        end
        best
      end

      # Interleaved Integers, with a raised-cosine fade over the last END_FADE seconds.
      def pcm(gain)
        scale = gain * 32_767.0
        fade_len = DSP.samples(END_FADE)
        remaining = @song.frames - @from # frames left in the song at i = 0
        out = Array.new(@left.size * 2)
        i = 0
        n = @left.size
        while i < n
          s = scale
          s *= 0.5 - (0.5 * Math.cos(Math::PI * (remaining - i) / fade_len)) if remaining - i < fade_len
          out[2 * i] = (@left[i] * s).round
          out[(2 * i) + 1] = (@right[i] * s).round
          i += 1
        end
        out
      end
    end

    # Writes the progress file atomically: one "<track> <fraction>" line per
    # track plus "mix", then "done <seconds>" once the WAV is in place.
    class Progress
      def initialize(path, names)
        @path = path
        @state = names.to_h { |name| [name.to_s, 0.0] }
        @written_at = 0.0
      end

      def update(name, fraction, force: false)
        @state[name.to_s] = fraction.to_f.clamp(0.0, 1.0)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return unless force || now - @written_at > 0.05

        @written_at = now
        write(lines)
      end

      def done(seconds)
        @state.each_key { |name| @state[name] = 1.0 }
        write(lines + format("done %.3f\n", seconds))
      end

      private

      def lines
        @state.map { |name, fraction| format("%s %.3f\n", name, fraction) }.join
      end

      def write(text)
        return unless @path

        tmp = "#{@path}.tmp-#{Process.pid}"
        File.write(tmp, text)
        File.rename(tmp, @path)
      end
    end

    # Forked children, or plain calls where fork is missing (Windows) or fails.
    # Children are waited on by pid, so a host process's other children are
    # never reaped, and any still running are stopped if the parent bails out.
    module Workers
      module_function

      def forking?
        @forking = probe_fork if @forking.nil?
        @forking
      end

      def probe_fork
        return false unless Process.respond_to?(:fork)

        Process.wait(Process.fork { exit!(0) })
        true
      rescue NotImplementedError, SystemCallError
        false
      end

      def cores
        require "etc"
        Etc.nprocessors
      rescue StandardError, LoadError
        4
      end

      # Runs work.call(job) for every job, at most `size` at once, and calls
      # on_done with each finished job in the parent.
      def pool(jobs, size, work, &on_done)
        unless forking?
          jobs.each do |job|
            work.call(job)
            on_done.call(job)
          end
          return
        end

        queue = jobs.dup
        running = {}
        until queue.empty? && running.empty?
          while running.size < size && (job = queue.shift)
            running[child { work.call(job) }] = job
          end
          pid, status = reap(running.keys)
          job = running.delete(pid)
          raise "synth worker failed: #{job.respond_to?(:name) ? job.name : job}" unless status.success?

          on_done.call(job)
        end
      ensure
        stop(running.keys) if running&.any?
      end

      # Waits for whichever of `pids` exits first.
      def reap(pids)
        loop do
          pids.each do |pid|
            found, status = Process.wait2(pid, Process::WNOHANG)
            return [found, status] if found
          end
          sleep(0.002)
        end
      end

      def stop(pids)
        pids.each { |pid| Process.kill(:TERM, pid) rescue nil } # rubocop:disable Style/RescueModifier
        pids.each { |pid| Process.wait(pid) rescue nil } # rubocop:disable Style/RescueModifier
      end

      # A child with a pipe each way, for the master's peak / gain handshake.
      # `inherited` are the parent's ends of earlier links: the child closes
      # them, so every pipe reaches end-of-file as soon as the parent is gone.
      Link = Struct.new(:pid, :reader, :writer)

      def linked(inherited = [])
        up_r, up_w = IO.pipe
        down_r, down_w = IO.pipe
        pid = child do
          [up_r, down_w, *inherited].each(&:close)
          up_w.sync = true
          yield up_w, down_r
        end
        up_w.close
        down_r.close
        Link.new(pid, up_r, down_w)
      end

      # The next number the parent sends down a link; quits quietly if it is gone.
      def receive(io)
        line = io.gets
        exit!(1) unless line
        line.to_f
      end

      def child
        Process.fork do
          yield
          exit!(0)
        rescue SignalException, Errno::EPIPE
          exit!(1)
        rescue Exception => e # rubocop:disable Lint/RescueException
          warn "synth worker: #{e.class}: #{e.message}\n  #{e.backtrace.first(6).join("\n  ")}"
          exit!(1)
        end
      end
    end

    class << self
      SEGMENT = 16.0 # seconds of timeline per track job (8 bars at 120 BPM)
      COST = { pad: 8, snare: 5, bell: 5, lead: 6, clap: 4, arp: 3 }.freeze

      # Renders score to out_path and returns the wall time in seconds.
      # score is a Music module (STEP, BEAT, LENGTH and .score) or a Hash of
      # events; for a Hash pass step:, beat: and length:, or accept 120 BPM
      # and an end rounded up to the bar.
      def render(score, out_path, progress: nil, verbose: false, step: nil, beat: nil, length: nil)
        enable_yjit
        started = clock
        events, song = prepare(score, step, beat, length)
        meter = Progress.new(progress, events.keys + [:mix])
        Dir.mktmpdir("scarpe-diem-synth") do |dir|
          stems = render_stems(events, song, dir, meter)
          note_time(verbose, "tracks", started)
          write_wav(stems, song, dir, out_path, meter)
        end
        (clock - started).tap do |seconds|
          meter.done(seconds)
          warn format("synth: %s, %.1f s of audio in %.2f s (yjit %s)", out_path, song.frames.fdiv(SR), seconds, jit_status) if verbose
        end
      end

      def load_score(test: false)
        music = File.join(__dir__, "music.rb")
        if !test && File.exist?(music)
          require_relative "music"
          Diem::Music
        else
          require_relative "music_test"
          Diem::MusicTest
        end
      end

      def main(argv)
        reexec_with_jit(argv)
        args = argv.dup
        test = !args.delete("--test").nil?
        verbose = !args.delete("--verbose").nil?
        out, progress = args
        abort "usage: ruby synth.rb OUT.wav [PROGRESS_FILE] [--test] [--verbose]" unless out
        render(load_score(test: test), File.expand_path(out),
               progress: progress && File.expand_path(progress), verbose: verbose)
      end

      private

      # YJIT compiles a method on entry and has no on-stack replacement, so a
      # long loop in a method called once only speeds up with a call
      # threshold of 1, which can only be set on the command line.
      def reexec_with_jit(argv)
        return unless defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled? && ENV["DIEM_SYNTH_JIT"].nil?

        require "rbconfig"
        ENV["DIEM_SYNTH_JIT"] = "1"
        exec(RbConfig.ruby, "--yjit", "--yjit-call-threshold=1", File.expand_path(__FILE__), *argv)
      rescue SystemCallError, NotImplementedError
        nil
      end

      def enable_yjit
        RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable) && !RubyVM::YJIT.enabled?
      rescue StandardError
        nil
      end

      def jit_status = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "on" : "off"

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def note_time(verbose, what, started)
        warn format("synth: %s done at %.2f s", what, clock - started) if verbose
      end

      def prepare(score, step, beat, length)
        module_score = score.respond_to?(:score)
        events = module_score ? score.score : score
        step ||= module_score ? score::STEP : 0.125
        beat ||= module_score ? score::BEAT : step * 4
        length ||= module_score ? score::LENGTH : song_end(events, step, beat)
        known = events.select { |name, list| known_track?(name) && list.any? }
        kicks = (events[:kick] || []).sort_by(&:first).map { |e| [DSP.samples(e[0] * step), e[3].to_f] }
        [known, Song.new(step, beat, length, DSP.samples(length + TAIL), kicks)]
      end

      def known_track?(name)
        return true if TRACKS.key?(name)

        warn "synth: ignoring unknown track #{name.inspect}"
        false
      end

      def song_end(events, step, beat)
        last = events.values.flatten(1).map { |e| (e[0] + e[1]) * step }.max || 0.0
        bar = beat * 4
        (last / bar).ceil * bar
      end

      def render_stems(events, song, dir, meter)
        segments = events.flat_map { |name, list| segments_for(name, list, song) }
        totals = segments.map(&:track).tally
        finished = Hash.new(0)
        stems = {}
        work = lambda do |segment|
          left, right = TrackRenderer.new(segment, song).render
          write_stem(File.join(dir, "#{segment.name}.f32"), left, right)
        end
        jobs = segments.sort_by { |s| [-COST.fetch(s.track, 1) * s.notes.size.clamp(1, 64), s.index] }
        Workers.pool(jobs, Workers.cores, work) do |segment|
          path = File.join(dir, "#{segment.name}.f32")
          stems[segment.name] = Stem.new(path, segment.from, File.size(path) / 8)
          finished[segment.track] += 1
          meter.update(segment.track, finished[segment.track].fdiv(totals[segment.track]))
        end
        stems.values
      end

      # Pairs each event with its predecessor's pitch (for glides), then slices the timeline.
      def segments_for(name, events, song)
        prev = nil
        notes = events.sort_by(&:first).map do |step, len, midi, vel, opts|
          note = Note.new(len * song.step, midi, vel.to_f, opts, prev)
          prev = midi
          [DSP.samples(step * song.step), note]
        end
        width = DSP.samples(SEGMENT)
        notes.group_by { |frame, _note| frame / width }.map do |index, list|
          Segment.new(name, index, index * width, list)
        end
      end

      def write_stem(path, left, right)
        File.open(path, "wb") do |f|
          f.write(left.pack("e*"))
          f.write(right.pack("e*"))
        end
      end

      def write_wav(stems, song, dir, out_path, meter)
        ranges = chunk_ranges(song.frames)
        parts = ranges.each_index.map { |k| File.join(dir, format("mix-%03d.pcm", k)) }
        mixers = ranges.map { |from, to| ChunkMixer.new(stems, song, from, to) }
        if Workers.forking?
          mix_forked(mixers, parts, meter)
        else
          mix_inline(mixers, parts, meter)
        end
        assemble(parts, song.frames, out_path)
      end

      def chunk_ranges(frames)
        count = Workers.forking? ? Workers.cores.clamp(1, 24) : 1
        size = (frames.to_f / count).ceil
        (0...count).map { |k| [k * size, [(k + 1) * size, frames].min] }.reject { |a, b| a >= b }
      end

      def mix_inline(mixers, parts, meter)
        drive = DRIVE / [mixers.map(&:sum!).max, 1e-9].max
        gain = PEAK / [mixers.map { |m| m.shape!(drive) }.max, 1e-9].max
        mixers.zip(parts).each { |m, path| m.write(gain, path) }
        meter.update(:mix, 1.0, force: true)
      end

      # Each chunk sums its frames and reports the raw peak; the parent picks
      # the drive, gathers the shaped peaks, then sends the final gain.
      def mix_forked(mixers, parts, meter)
        links = []
        mixers.each_with_index do |mixer, k|
          links << Workers.linked(links.flat_map { |l| [l.reader, l.writer] }) do |up, down|
            up.puts(mixer.sum!)
            up.puts(mixer.shape!(Workers.receive(down)))
            mixer.write(Workers.receive(down), parts[k])
          end
        end
        broadcast(links, DRIVE / [gather(links), 1e-9].max)
        meter.update(:mix, 0.4, force: true)
        broadcast(links, PEAK / [gather(links), 1e-9].max)
        meter.update(:mix, 0.7, force: true)
        links.each { |link| finish(link) }
        links = []
        meter.update(:mix, 1.0, force: true)
      ensure
        Workers.stop(links.map(&:pid)) if links&.any?
      end

      def gather(links)
        links.map do |link|
          line = link.reader.gets
          raise "synth mixer #{link.pid} died" unless line

          line.to_f
        end.max
      end

      def broadcast(links, value)
        links.each { |link| link.writer.puts(value.to_s) }
      end

      def finish(link)
        link.reader.close
        link.writer.close
        raise "synth mixer #{link.pid} failed" unless Process.wait2(link.pid).last.success?
      end

      def assemble(parts, frames, out_path)
        tmp = "#{out_path}.tmp-#{Process.pid}"
        File.open(tmp, "wb") do |f|
          f.write(wav_header(frames))
          parts.each { |part| File.open(part, "rb") { |src| IO.copy_stream(src, f) } }
        end
        File.rename(tmp, out_path)
      ensure
        File.delete(tmp) if tmp && File.exist?(tmp)
      end

      def wav_header(frames)
        data = frames * 4
        ["RIFF", 36 + data, "WAVE", "fmt ", 16, 1, 2, SR, SR * 4, 4, 16, "data", data].pack("a4Va4a4VvvVVvva4V")
      end
    end
  end
end

Diem::Synth.main(ARGV) if $PROGRAM_NAME && File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
