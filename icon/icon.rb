# frozen_string_literal: true

# The app icon, drawn by Scarpe: a synthwave sun setting behind a neon grid, and a ruby in front.
#   ./scarpe.sh peek icon/icon.rb --shot icon/square.png
#   magick icon/square.png \( -size 1024x1024 xc:none -fill white -draw "roundrectangle 100,100 923,923 185,185" \) \
#     -compose DstIn -composite icon/icon.png
Shoes.app(title: "Scarpe Diem icon", width: 1024, height: 1024, resizable: false) do
  background white
  nostroke
  # the tile
  rect 100, 100, 824, 824, 185, fill: gradient("#1b0b3a", "#05030c", angle: 0), strokewidth: 0
  # the sun, striped at the bottom like an 80s record sleeve
  oval 512, 470, 470, center: true, fill: gradient("#ffd166", "#ff2e88", angle: 0), strokewidth: 0
  top_c = [0x1b, 0x0b, 0x3a]
  bottom_c = [0x05, 0x03, 0x0c]
  [[548, 10], [584, 14], [620, 18], [656, 22], [692, 26]].each do |y, h|
    k = (y + h / 2.0 - 100) / 824.0
    c = top_c.zip(bottom_c).map { |a, b| (a + (b - a) * k).round }
    half = Math.sqrt([235**2 - (y + h / 2.0 - 470)**2, 0].max) + 6
    rect 512 - half, y, half * 2, h, fill: rgb(*c), strokewidth: 0
  end
  # the horizon and the grid rushing toward us
  rect 100, 700, 824, 224, fill: gradient("#2a0f4f", "#0a0518", angle: 0), strokewidth: 0
  stroke rgb(255, 46, 136, 0.85)
  strokewidth 4
  line 100, 700, 924, 700
  [712, 732, 762, 804, 860, 924].each { |y| line 100, y, 924, y }
  (-6..6).each { |i| line 512 + i * 26, 700, 512 + i * 150, 924 }
  # the ruby: table, crown and pavilion facets
  nostroke
  cx = 512
  top = 610
  facets = [
    [[cx - 92, top], [cx + 92, top], [cx + 60, top + 44], [cx - 60, top + 44], "#ff6b9a"],
    [[cx - 92, top], [cx - 60, top + 44], [cx - 150, top + 44], "#e0115f"],
    [[cx + 92, top], [cx + 150, top + 44], [cx + 60, top + 44], "#b00d4a"],
    [[cx - 150, top + 44], [cx - 60, top + 44], [cx, top + 210], "#c2104f"],
    [[cx - 60, top + 44], [cx + 60, top + 44], [cx, top + 210], "#ff3d7f"],
    [[cx + 60, top + 44], [cx + 150, top + 44], [cx, top + 210], "#8a0a3b"],
  ]
  facets.each do |*pts, colour|
    fill colour
    shape do
      move_to(*pts.first)
      pts.drop(1).each { |p| line_to(*p) }
    end
  end
  fill rgb(255, 255, 255, 0.85)
  shape { move_to cx - 70, top + 8; line_to cx - 30, top + 8; line_to cx - 52, top + 30 }
end
