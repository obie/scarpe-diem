# frozen_string_literal: true

# The per-pixel heart of the Plasma scene. Every frame, for every pixel:
#
#   v = COL[x] + DIAG[x + y] + ROW[y] + sum of RIPPLE_i[dist(x, y, centre_i)]
#
# COL, DIAG and ROW are sine fields resampled once per frame (one entry per column or row), the
# ripples are radial profiles looked up through one shared distance table, so the inner loop is
# nothing but Array reads and Integer adds. A ripple that covers most of the picture is read in
# that loop; a small ring (a young bell, a raindrop) is zero outside its annulus, so it is added
# into a row accumulator only across the span of each row it crosses. v is treated as the height of a liquid surface: its
# slope picks one of NL light levels, its value picks one of HUES colours, and the pair indexes a
# palette of ready-made BGR pixel strings.
module Diem
  class PlasmaField
    NL = 64          # light levels
    HUES = 128       # colours around the palette loop
    LIGHT = 256      # slope buckets (128 = flat)
    HUE_SHIFT = 7    # v units per palette entry = 128
    MAX_TERMS = 12   # radial terms the kernels are written for
    SUB = 16         # distance table steps per pixel (coarser shows as grain on steep ripples)

    attr_reader :fw, :fh, :dw

    def initialize(fw, fh)
      @fw = fw
      @fh = fh
      @dw = fw * 2
      dh = fh * 2
      # Four distance tables, for centres on whole and half pixels in x and y.
      @dists = Array.new(4) do |q|
        ox = (q & 1) * 0.5
        oy = (q >> 1) * 0.5
        Array.new(@dw * dh) do |i|
          dx = i % @dw - fw - ox
          dy = i / @dw - fh - oy
          (Math.sqrt(dx * dx + dy * dy) * SUB).round
        end.freeze
      end.freeze
      @dist_len = ((Math.sqrt(@dw * @dw + dh * dh) * SUB).ceil + 2)
      @up = Array.new(fw, 0)
      @row = Array.new(fw)
      @rows = Array.new(fh)
      @acc = Array.new(fw, 0)
    end

    # Radial profiles are indexed by distance in 1/SUB pixels.
    def dist_len = @dist_len

    # One frame. cxs/cys: centres in half pixels (0..2fw, 2..2fh), one per ripple table in tabs.
    # rings: the small rings, flat, RING values each: table index (into all_tabs), centre x and
    # y (half pixels, as cxs), outer and inner radius (pixels, with a margin, Floats).
    # vigx: four arrays of per-column light offsets, picked by row & 3 (vignette plus dither).
    def render(tabs, cxs, cys, rings, all_tabs, colv, diag, rowv, rowlev, vigx, pal, lev, cyc)
      @ring_tabs = all_tabs
      name = rings.empty? ? KERNELS[tabs.size] : ACC_KERNELS[tabs.size]
      send(name, @rows, tabs, cxs, cys, colv, diag, rowv, rowlev, vigx, pal, lev, cyc, @up, @row, rings, @acc)
      @rows
    end

    RING = 5

    # Adds every small ring's term into acc for row yy, across only the span the ring covers.
    def fill_acc(acc, yy, rings)
      fw = @fw
      fh = @fh
      dw = @dw
      j = 0
      n = rings.size
      while j < n
        tab = @ring_tabs[rings[j]]
        hx = rings[j + 1]
        hy = rings[j + 2]
        ro = rings[j + 3]
        ri = rings[j + 4]
        j += RING
        dy = 2 * yy - hy
        dy = -dy if dy < 0
        dy *= 0.5
        next if dy >= ro

        d = @dists[(hx & 1) | ((hy & 1) << 1)]
        cx = hx >> 1
        b = (yy - (hy >> 1) + fh) * dw + fw - cx
        mid = hx * 0.5
        half = Math.sqrt(ro * ro - dy * dy)
        x0 = (mid - half).floor
        x0 = 0 if x0 < 0
        x1 = (mid + half).ceil + 1
        x1 = fw if x1 > fw
        if dy < ri
          inner = Math.sqrt(ri * ri - dy * dy)
          a1 = (mid - inner).ceil
          a1 = x1 if a1 > x1
          x = x0
          while x < a1
            acc[x] += tab[d[b + x]]
            x += 1
          end
          x0 = (mid + inner).floor
          x0 = a1 if x0 < a1
        end
        x = x0
        while x < x1
          acc[x] += tab[d[b + x]]
          x += 1
        end
      end
    end

    # The inner loops, one per number of ripple terms, so no pixel pays for a ripple that is not
    # there. Row -1 is row 0 computed once to prime the row above, so the top row lights right.
    def self.kernel_source(n, acc)
      terms = (0...n).map { |i| " + t#{i}[d#{i}[b#{i} + x]]" }.join
      terms += " + acc[x]" if acc
      <<~RUBY
        def #{acc ? "acc_" : ""}kernel_#{n}(rows, tabs, cxs, cys, colv, diag, rowv, rowlev, vigx, pal, lev, cyc, up, row, rings, acc)
          dists = @dists
          fw = @fw
          fh = @fh
          dw = @dw
          lmax = #{LIGHT - 1}
          #{(0...n).map { |i| "t#{i} = tabs[#{i}]; cx#{i} = cxs[#{i}] >> 1; cy#{i} = cys[#{i}] >> 1; d#{i} = dists[(cxs[#{i}] & 1) | ((cys[#{i}] & 1) << 1)]" }.join("\n  ")}
          #{acc ? "acc.fill(0)\n  fill_acc(acc, 0, rings)" : ""}
          y = -1
          while y < fh
            yy = y < 0 ? 0 : y
            #{acc ? "if y > 0\n      acc.fill(0)\n      fill_acc(acc, yy, rings)\n    end" : ""}
            rv = rowv[yy]
            rl = rowlev[yy]
            vg = vigx[yy & 3]
            #{(0...n).map { |i| "b#{i} = (yy - cy#{i} + fh) * dw + fw - cx#{i}" }.join("\n    ")}
            left = up[0]
            x = 0
            while x < fw
              v = colv[x] + diag[x + yy] + rv#{terms}
              li = (((v - left) + (v - up[x])) >> 4) + rl + vg[x]
              li = 0 if li < 0
              li = lmax if li > lmax
              up[x] = v
              left = v
              row[x] = pal[lev[li] | (((v >> #{HUE_SHIFT}) + cyc) & #{HUES - 1})]
              x += 1
            end
            rows[y] = row.join if y >= 0
            y += 1
          end
        end
      RUBY
    end

    KERNELS = (0..MAX_TERMS).map do |n|
      class_eval(kernel_source(n, false), __FILE__, __LINE__)
      :"kernel_#{n}"
    end.freeze

    ACC_KERNELS = (0..MAX_TERMS).map do |n|
      class_eval(kernel_source(n, true), __FILE__, __LINE__)
      :"acc_kernel_#{n}"
    end.freeze
  end
end
