require_relative "../lib/diem/bitfont"

SAMPLES = [["SCARPE DIEM", 8], ["GREETINGS TO NICK AND THE SCARPE TEAM", 3],
           ["0123456789 O0 I1 !?", 5], ["abc xyz ~ lowercase", 4]].freeze
CHARSET = [*"A".."Z", *"0".."9", *%w[. , ! ? ' " - + : ; / ( ) _ & * = # @ < > % $ ♥]].freeze

def draw_points(app, points, ox, oy, size, color)
  app.fill color
  app.nostroke
  points.each { |x, y| app.rect(ox + x * size, oy + y * size, size - 1, size - 1) }
end

Shoes.app(title: "Bitfont sheet", width: 720, height: 620) do
  background rgb(16, 14, 32)
  CHARSET.each_with_index do |ch, i|
    draw_points(self, Diem::Bitfont.points(ch), 20 + (i % 14) * 50, 16 + (i / 14) * 52, 6, rgb(120, 255, 200))
  end
  y = 300
  SAMPLES.each_with_index do |(line, size), i|
    draw_points(self, Diem::Bitfont.points(line), 20, y, size, rgb(255, 200 - i * 40, 90 + i * 50))
    y += 7 * size + 22
  end
end
