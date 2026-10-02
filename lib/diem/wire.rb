# frozen_string_literal: true

# The fast path. A Lacci style call costs about 7 µs of Ruby; posting the same props straight to
# the native child costs about 0.4 µs, which is the difference between 2,300 and 5,000 shapes
# changing every frame. Use it for drawables you only ever write to from a hot loop: Lacci's own
# copy of their styles goes stale, so never read them back or mix in Lacci setters for the same
# props. Colours are [r, g, b, a] Integer arrays (0..255). Positions on art are plain pixels;
# anything that is not art must get Integers, since a Float in (0, 1] is a share of the parent.
module Diem
  module Wire
    @posts = 0

    class << self
      attr_reader :posts

      def child
        @child ||= Scarpe::Native::DisplayService.instance.child
      end

      # One props line for one drawable. props keys are wire names: fill, stroke, left, top,
      # width, height, x2, y2, shape_commands, hidden, angle1, angle2, outer, inner, rotate...
      def set(drawable, props)
        @posts += 1
        child.post({ t: "props", id: drawable.linkable_id, props: props })
      end

      # The same, by linkable id, for loops that cached the ids.
      def set_id(id, props)
        @posts += 1
        child.post({ t: "props", id: id, props: props })
      end
    end
  end
end
