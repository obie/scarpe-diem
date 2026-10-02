# frozen_string_literal: true

module Diem
  # SCARPE DIEM as a solid of voxels: every lit pixel of the 5x7 font becomes 2x2 squares on a
  # front face and 2x2 on a back face. They fly in from deep space along spirals, hang in the air
  # through the breath, slam home on the drop, then ripple, turn a full circle in perspective,
  # twist and explode. Every particle is a pure function of t; each frame they are depth sorted
  # and written into the rect pool far to near, so the pool order is the painter's order.
  class IgnitionLogo
    TEXT = "SCARPE\nDIEM"
    HEATS = 8
    HUES = 48
    LEVELS = 24
    SPAWN = (11.2..13.4).freeze
    SNAP_FROM = 15.925 # the vortex bursts into the letters over the last 4 frames before the drop
    SNAP_EASE = 1.5 # accelerating into the downbeat
    INHALE = 0.5 # how far the galaxy draws in on itself through the breath
    WHIRL = 10.0 # and how much faster it turns as it does
    GROW = 0.5 # px added to each held voxel face, so neighbours overlap and no hairline seams open
    TWIST_GROW = 1.6 # and more per radian of twist, which shears the rows apart by up to ~1 px
    GALAXY_TILT_COS = Math.cos(1.18)
    GALAXY_TILT_SIN = Math.sin(1.18)
    TAU = Math::PI * 2
    TWIST_K = 0.0068
    REAR = 0.62 # brightness of the face turned away from the camera, so the slab reads as extruded

    attr_reader :count, :cell, :half_w, :half_h

    def initialize(scene, flight, dense:)
      @scene = scene
      @flight = flight
      @u = scene.u
      @dense = dense
      @cam = 1000.0 * @u
      @cell = [scene.w * 0.70 / 35.0, scene.h * 0.56 / 16.0].min
      @half_w = 17.5 * @cell
      @half_h = 8.0 * @cell
      place
      build_colours
      @boom = Array.new(@count * 3, 0.0)
      @count.times { |i| hold_point(i, IgnitionFlight::BOOM, 0.0, @boom, i * 3) }
    end

    def build
      s = @scene
      night = Palette.rgb(Palette::NIGHT)
      @rects = Array.new(@count) { s.rect(-50, -50, 0, 0, fill: night, strokewidth: 0, center: true) }
    end

    def reset
      @empty.fill(false)
      @rl.fill(-1e9)
    end

    # The world position of particle i at its rest pose, for sparks that start on the logo.
    def home(i) = [@hx[i], @hy[i]]

    # Size multiplier for this frame (the kick swell); set before update.
    attr_writer :swell

    # snare: the fill's hits, which flare the exploding particles. holes: the shells' shock
    # fronts ([x, y, radius, strength] flat, screen pixels), which shove debris aside.
    def update(t, cx, cy, kick, snare = 0.0, holes = nil)
      n = 0
      vis = @vis
      vis.clear
      if t < IgnitionFlight::DROP
        n = incoming(t, vis)
      elsif t < IgnitionFlight::BOOM
        n = holding(t, kick, vis)
      else
        n = exploding(t, kick + 3.0 * snare, vis)
      end
      held = t >= IgnitionFlight::DROP && t < IgnitionFlight::BOOM && !IgnitionFx.flash?(t)
      grow = held ? GROW + TWIST_GROW * twist_of(t) : 0.0
      emit(vis, cx, cy, t < IgnitionFlight::DROP, holes, deep: t >= IgnitionFlight::BOOM, grow: grow)
      n
    end

    private

    # Particle i at rest at time t, written to out[o..o+2]; returns the lighting term.
    def hold_point(i, t, kick, out, o)
      tau = t - IgnitionFlight::DROP
      x = @hx[i]
      y = @hy[i]
      z = @hz[i]
      g = pose(t, kick)
      light = 0.0
      if g[:ripple] > 0.0
        ph = @phase[i] - (t - 20.0) * 3.4
        z += g[:ripple] * Math.sin(ph)
        light = 0.4 * Math.cos(ph) * g[:ripple] / (24.0 * @u)
      end
      ay = g[:ay]
      ay += g[:twist] * Math.sin(y * TWIST_K / @u + (t - 28.0) * 3.6) if g[:twist] > 0.0
      ca = Math.cos(ay)
      sa = Math.sin(ay)
      xr = x * ca + z * sa
      zr = -x * sa + z * ca
      cb = g[:cb]
      sb = g[:sb]
      yr = y * cb - zr * sb
      zr = y * sb + zr * cb + g[:dz]
      out[o] = xr
      out[o + 1] = yr
      out[o + 2] = zr
      tau.negative? ? 0.0 : light
    end

    # The whole logo's pose at t: angles, depth push, ripple and twist amplitudes.
    def pose(t, kick)
      tau = t - IgnitionFlight::DROP
      u = @u
      sway = smooth(16.6, 18.6, t) * (1.0 - smooth(23.0, 24.0, t))
      ay = 0.22 * Math.sin(tau * 0.85) * sway
      ax = 0.10 * Math.sin(tau * 0.63 + 0.5) * sway
      q = smoother(((t - 24.0) / 4.0).clamp(0.0, 1.0))
      ay += TAU * q
      ax += 0.24 * Math.sin(Math::PI * q)
      dz = -28.0 * u * kick
      dz -= 90.0 * u * Math.sin(tau * 17.0) * Math.exp(-tau / 0.15) if tau < 1.2
      ripple = 24.0 * u * smooth(20.0, 21.2, t) * (1.0 - smooth(23.4, 24.4, t))
      twist = twist_of(t)
      { ay: ay, cb: Math.cos(ax), sb: Math.sin(ax), dz: dz, ripple: ripple, twist: twist }
    end

    # How far the rows wind against each other (radians at the crest), from 28 s.
    def twist_of(t) = 0.5 * smooth(28.1, 29.4, t)

    # 11.2-15.5: streak in from deep space and wheel round a tilted spiral galaxy. 15.5-16: the
    # breath, when the galaxy keeps turning and draws in on itself like an inhale. Over the last
    # four frames before the drop it bursts out into the letters, which land on the downbeat.
    def incoming(t, vis)
      xs = @px
      ys = @py
      zs = @pz
      bs = @pb
      cs = @pc
      fs = @pf
      breath = IgnitionFlight::BREATH
      cam = @cam
      ct = GALAXY_TILT_COS
      st = GALAXY_TILT_SIN
      zc0 = 520.0 * @u
      inhale = t > breath ? smooth(breath, SNAP_FROM, t) : 0.0
      pull = 1.0 - INHALE * inhale
      whirl = t > breath ? WHIRL * (t - breath)**2 : 0.0
      snap = t > SNAP_FROM ? ((t - SNAP_FROM) / (IgnitionFlight::DROP - SNAP_FROM)).clamp(0.0, 1.0)**SNAP_EASE : 0.0
      i = 0
      n = @count
      while i < n
        ts = @ts[i]
        if t < ts
          i += 1
          next
        end
        life = t - ts
        prog = life / (breath - ts)
        r = @rad[i] * (1.0 - 0.45 * prog) * pull
        a = @a0[i] + (life * (1.0 + 0.8 * prog) + whirl) * @spin[i]
        q = life / 1.7
        q = 1.0 if q > 1.0
        dy = r * Math.sin(a)
        dx = r * Math.cos(a)
        dzz = zc0 + @dz[i] * (1.0 - q) * (1.0 - q) + dy * st
        dy *= ct
        fade = life / 0.5
        fade = 1.0 if fade > 1.0
        if snap > 0.0
          w = snap
          x = dx + (@hx[i] - dx) * w
          y = dy + (@hy[i] - dy) * w
          z = dzz + (@hz[i] - dzz) * w
        else
          w = 0.0
          x = dx
          y = dy
          z = dzz
        end
        xs[i] = x
        ys[i] = y
        zs[i] = z
        sc = cam / (cam + z)
        b = (0.7 + 0.5 * sc) * fade
        b = 1.0 if b > 1.0
        bs[i] = b
        fs[i] = 0.5 + 0.5 * w
        heat = (@disk_heat[i] * (1.0 - w) + (2.0 + 5.0 * w) * w).round
        hue = (@disk_hue[i] * (1.0 - w)).round
        cs[i] = (heat * HUES + hue) * LEVELS
        vis << i
        i += 1
      end
      vis.size
    end

    def holding(t, kick, vis)
      xs = @px
      ys = @py
      zs = @pz
      bs = @pb
      cs = @pc
      tau = t - IgnitionFlight::DROP
      g = pose(t, kick)
      ay = g[:ay]
      cb = g[:cb]
      sb = g[:sb]
      dz = g[:dz]
      ripple = g[:ripple]
      twist = g[:twist]
      ca = Math.cos(ay)
      sa = Math.sin(ay)
      lightk = 0.4 / (24.0 * @u)
      ph_t = (t - 20.0) * 3.4
      tw_t = (t - 28.0) * 3.6
      tw_k = TWIST_K / @u
      heat0 = 7.0 * Math.exp(-tau / 0.5)
      hue_t = tau * 0.22
      glint_t = tau * 0.5
      depth_k = 0.55 / @half_w
      silhouette = IgnitionFx.flash?(t)
      half = @front
      mid = 0.5 * (1.0 + REAR)
      side_k = 0.5 * (1.0 - REAR)
      i = 0
      n = @count
      while i < n
        x = @hx[i]
        y = @hy[i]
        z = @hz[i]
        light = 0.0
        if ripple > 0.0
          ph = @phase[i] - ph_t
          z += ripple * Math.sin(ph)
          light = lightk * ripple * Math.cos(ph)
        end
        if twist > 0.0
          a = ay + twist * Math.sin(y * tw_k + tw_t)
          c = Math.cos(a)
          s = Math.sin(a)
        else
          c = ca
          s = sa
        end
        xr = x * c + z * s
        zr = -x * s + z * c
        yr = y * cb - zr * sb
        zr = y * sb + zr * cb + dz
        xs[i] = xr
        ys[i] = yr
        zs[i] = zr
        b = 0.86 - zr * depth_k + light + kick * 0.18
        f = c * cb * 3.0
        f = 1.0 if f > 1.0
        f = -1.0 if f < -1.0
        b *= i < half ? mid + side_k * f : mid - side_k * f
        b = 0.12 if b < 0.12
        b = 1.0 if b > 1.0
        b = 0.0 if silhouette
        bs[i] = b
        hue = @hue[i] - hue_t
        gl = Math.cos((@hue[i] * 1.3 - glint_t) * TAU)
        gl = gl > 0.0 ? (gl2 = gl * gl; gl4 = gl2 * gl2; gl4 * gl4) : 0.0
        heat = (heat0 + gl * 5.0 + kick * 1.5).to_i
        heat = HEATS - 1 if heat >= HEATS
        cs[i] = (heat * HUES + ((hue - hue.floor) * HUES).to_i) * LEVELS
        vis << i
        i += 1
      end
      n
    end

    def exploding(t, kick, vis)
      xs = @px
      ys = @py
      zs = @pz
      bs = @pb
      cs = @pc
      tau = t - IgnitionFlight::BOOM
      # Drag keeps the debris on screen right up to the cut, still lit by the fill.
      dk = 1.6
      drag = (1.0 - Math.exp(-dk * tau)) / dk
      grav = 0.5 * 760.0 * @u * tau * tau
      fade = t < 32.0 ? 1.0 : 0.0 # the next scene flashes in over the debris
      heat = (6.0 * Math.exp(-tau / 0.25) + kick).to_i
      heat = HEATS - 1 if heat >= HEATS
      hue_t = (t - IgnitionFlight::DROP) * 0.22
      boom = @boom
      cam = @cam
      lim = 40.0 - cam
      bright = (0.8 + 0.2 * kick.clamp(0.0, 1.0)) * fade
      return 0 if fade <= 0.0
      i = 0
      n = @count
      while i < n
        o = i * 3
        z = boom[o + 2] + @vz[i] * drag
        if z < lim
          i += 1
          next
        end
        xs[i] = boom[o] + @vx[i] * drag
        ys[i] = boom[o + 1] + @vy[i] * drag + grav
        zs[i] = z
        # Debris sinking away cools toward the night, so the blast has depth.
        sc = cam / (cam + z)
        bs[i] = sc < 1.0 ? bright * (1.0 - 1.7 * (1.0 - sc)).clamp(0.3, 1.0) : bright
        hue = @hue[i] - hue_t
        cs[i] = (heat * HUES + ((hue - hue.floor) * HUES).to_i) * LEVELS
        vis << i
        i += 1
      end
      vis.size
    end

    # Depth sort, project and write each visible particle into the pool, far to near.
    # sized: the incoming flight's per-particle sizes. deep: the explosion, where size goes with
    # the square of the projection so near debris looms and far debris shrinks to specks.
    # grow: px added to every face (the held logo), so neighbouring voxels overlap.
    def emit(vis, cx, cy, sized, holes = nil, deep: false, grow: 0.0)
      zs = @pz
      vis.sort_by! { |i| -zs[i] }
      xs = @px
      ys = @py
      bs = @pb
      cs = @pc
      cols = @cols
      rects = @rects
      cam = @cam
      size0 = @size
      swell = @swell
      lv = LEVELS - 1
      rl = @rl
      rt = @rt
      rs = @rs
      rc = @rc
      k = 0
      m = vis.size
      while k < m
        i = vis[k]
        sc = cam / (cam + zs[i])
        sz = if sized then (size0 * sc * @pf[i]).round(1)
             elsif deep then (size0 * sc * sc * swell).round(1)
             else (size0 * sc * swell + grow).round(1)
             end
        x = cx + xs[i] * sc
        y = cy + ys[i] * sc
        b = bs[i]
        if holes && !holes.empty?
          x, y, b = shove(holes, x, y, b)
        end
        x = x.round(1)
        y = y.round(1)
        ci = cs[i] + (b * lv).round
        if x != rl[k] || y != rt[k] || sz != rs[k] || ci != rc[k]
          rl[k] = x
          rt[k] = y
          rs[k] = sz
          rc[k] = ci
          @scene.set(rects[k], { left: x, top: y, width: sz, height: sz, fill: cols[ci] })
        end
        @empty[k] = false
        k += 1
      end
      while k < @count
        unless @empty[k]
          @scene.set(rects[k], { width: 0, height: 0 })
          @empty[k] = true
          rs[k] = 0.0
        end
        k += 1
      end
    end

    # A shell's shock front pushes debris inside it out towards its edge and dims what it
    # pushes, so each burst opens a dark hole to read against.
    def shove(holes, x, y, b)
      j = 0
      m = holes.size
      while j < m
        dx = x - holes[j]
        dy = y - holes[j + 1]
        r = holes[j + 2]
        d2 = dx * dx + dy * dy
        if d2 < r * r
          s = holes[j + 3]
          d = Math.sqrt(d2) + 1e-3
          f = 1.0 - d / r
          push = (r - d) * s * 0.8
          x += dx / d * push
          y += dy / d * push
          b *= 1.0 - 0.75 * s * f
        end
        j += 4
      end
      [x, y, b]
    end

    # A two-armed spiral galaxy: radius, arm angle, spin (inner stars faster), fall-in depth,
    # colour (white-hot core, magenta rim).
    def galaxy(rnd, n)
      rmin = 70.0 * @u
      rmax = 620.0 * @u
      @ts = Array.new(n) { SPAWN.min + rnd.rand * (SPAWN.max - SPAWN.min) }
      @rad = Array.new(n) { rmin + (rmax - rmin) * rnd.rand**0.8 }
      @a0 = Array.new(n) { |i| (i % 2) * Math::PI + 2.9 * Math.log(@rad[i] / rmin) + gauss(rnd) * 0.2 }
      @spin = Array.new(n) { |i| 0.55 + 1.1 * rmin / @rad[i] }
      @dz = Array.new(n) { (2600.0 + rnd.rand * 2600.0) * @u }
      n.times { rnd.rand } # the old ghost depths: kept as draws so the debris below is unchanged
      @disk_heat = Array.new(n) { |i| (6.5 * (1.0 - (@rad[i] - rmin) / (rmax - rmin))**2).clamp(0.0, 6.4) }
      @disk_hue = Array.new(n) { |i| (HUES * 0.4 * ((@rad[i] - rmin) / (rmax - rmin))**0.7).clamp(0.0, HUES * 0.4) }
    end

    def gauss(rnd)
      Math.sqrt(-2.0 * Math.log(1.0 - rnd.rand)) * Math.cos(TAU * rnd.rand)
    end

    def place
      rnd = Random.new(1612)
      pts = Bitfont.points_centered(TEXT)
      c = @cell
      subs = @dense ? [[-0.25, -0.25], [0.25, -0.25], [-0.25, 0.25], [0.25, 0.25]] : [[0.0, 0.0]]
      layers = @dense ? [-0.36, 0.36] : [0.0]
      @size = c * (@dense ? 0.52 : 0.9)
      @swell = 1.0
      @hx = []
      @hy = []
      @hz = []
      layers.each do |lz|
        pts.each do |fx, fy|
          subs.each do |sx, sy|
            @hx << (fx + 0.5 + sx) * c
            @hy << (fy + 0.5 + sy) * c
            @hz << lz * c
          end
        end
      end
      @count = @hx.size
      @front = @dense ? @count / 2 : @count
      n = @count
      @hue = Array.new(n) { |i| @hx[i] / (2.0 * @half_w) * 0.55 + @hy[i] / (2.0 * @half_h) * 0.22 + 0.5 }
      @phase = Array.new(n) { |i| @hx[i] * 0.0105 / @u + @hy[i] * 0.004 / @u }
      galaxy(rnd, n)
      @vx = []
      @vy = []
      @vz = []
      n.times do |i|
        dx = @hx[i]
        dy = @hy[i] * 1.6
        len = Math.sqrt(dx * dx + dy * dy) + 1e-3
        v = (150.0 + rnd.rand * 480.0) * @u
        @vx << dx / len * v + (rnd.rand - 0.5) * 200.0 * @u
        @vy << dy / len * v - (220.0 + rnd.rand * 360.0) * @u
        # Mostly drifting, some sinking away, a few flying right at the camera.
        @vz << (600.0 - 1650.0 * rnd.rand**1.4) * @u
      end
      @px = Array.new(n, 0.0)
      @py = Array.new(n, 0.0)
      @pz = Array.new(n, 0.0)
      @pb = Array.new(n, 0.0)
      @pc = Array.new(n, 0)
      @pf = Array.new(n, 1.0)
      @vis = []
      @empty = Array.new(n, false)
      @rl = Array.new(n, -1e9)
      @rt = Array.new(n, 0.0)
      @rs = Array.new(n, 0.0)
      @rc = Array.new(n, -1)
    end

    # HEATS x HUES x LEVELS opaque colours: a cyan-violet-magenta-gold loop, heated toward white
    # and faded toward the night.
    def build_colours
      stops = [Palette::CYAN, Palette::VIOLET, Palette::MAGENTA, Palette::EMBER, Palette::GOLD, Palette::CYAN]
      @cols = []
      HEATS.times do |he|
        HUES.times do |hi|
          x = hi.fdiv(HUES) * (stops.size - 1)
          k = x.floor
          c = Palette.mix(stops[k], stops[k + 1], x - k)
          c = Palette.mix(c, Palette::INK, (he.fdiv(HEATS - 1))**1.3)
          LEVELS.times do |bi|
            m = Palette.mix(Palette::NIGHT, c, bi.fdiv(LEVELS - 1))
            @cols << [m[0].round, m[1].round, m[2].round, 255].freeze
          end
        end
      end
    end

    def smooth(a, b, t)
      x = ((t - a) / (b - a)).clamp(0.0, 1.0)
      x * x * (3.0 - 2.0 * x)
    end

    def smoother(x) = x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
  end
end
