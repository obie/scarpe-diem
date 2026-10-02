# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# A software framebuffer: Ruby writes every pixel of a small 24-bit BMP, and the renderer, which
# re-reads a picture whose file changed, scales it up with bicubic filtering. Two files take turns
# and each is written beside itself then renamed over, so the renderer never reads half a frame.
#
# Pixels are 3-byte BGR Strings. Build each row with Array#join over a palette of such strings
# (Framebuffer.palette) and hand present() the rows; that is the fastest thing plain Ruby does.
module Diem
  class Framebuffer
    attr_reader :fw, :fh, :image

    DIR = Dir.mktmpdir("scarpe-diem-fb")
    at_exit { FileUtils.rm_r(DIR, force: true) }
    @serial = 0

    class << self
      attr_accessor :serial

      # n BGR pixel strings along colour stops given as [r, g, b].
      def palette(stops, n = 256)
        Array.new(n) do |i|
          x = i.fdiv(n - 1) * (stops.size - 1)
          k = [x.floor, stops.size - 2].min
          c = Palette.mix(stops[k], stops[k + 1], x - k)
          pixel(c)
        end
      end

      def pixel(c)
        [c[2].round.clamp(0, 255), c[1].round.clamp(0, 255), c[0].round.clamp(0, 255)].pack("C3").freeze
      end
    end

    # fw must be a multiple of 4, so rows need no padding.
    def initialize(app, fw, fh, left: 0, top: 0, width: W, height: H)
      raise ArgumentError, "framebuffer width must be a multiple of 4" unless (fw % 4).zero?

      @fw = fw
      @fh = fh
      @header = header
      n = (Framebuffer.serial += 1)
      @paths = [File.join(DIR, "fb#{n}a.bmp"), File.join(DIR, "fb#{n}b.bmp")]
      @flip = 0
      blank = @header + ("\0\0\0" * fw * fh)
      @paths.each { |p| File.binwrite(p, blank) }
      @image = app.image(@paths[0], left: left, top: top, width: width, height: height)
    end

    # rows: fh Strings of fw * 3 bytes each, top row first.
    def present(rows)
      @flip ^= 1
      path = @paths[@flip]
      tmp = "#{path}.tmp"
      File.open(tmp, "wb") { |f| f.write(@header, *rows) }
      File.rename(tmp, path)
      Wire.set(@image, { url: path })
    end

    private

    # A top-down 24-bit BMP header (negative height).
    def header
      size = @fw * 3 * @fh
      ["BM", 54 + size, 0, 0, 54, 40, @fw, -@fh, 1, 24, 0, size, 2835, 2835, 0, 0]
        .pack("a2Vv2VVl<l<vvVVl<l<VV")
    end
  end
end
