# frozen_string_literal: true

# The world of WOLFENSHOES 3D: a hand-drawn map, the kinds of wall in it, the autopilot's
# route and what floats in the air. It is plain data, so a walk-around mode can load the same
# level.
module Diem
  module MazeMap
    NEON = 1    # '#' violet panels with neon trim (and ' ', solid rock nobody sees)
    BRICK = 2   # 'B' ember brick rooms
    CHROME = 3  # 'C' the hall's walls
    PILLAR = 4  # 'O' round gold columns
    LIGHT = 5   # 'D' the doorway at the end
    TECH = 6    # '=' the last corridor
    DOOR = 7    # '|' the hall door, which slides open on the crash

    LEGEND = { "#" => NEON, " " => NEON, "B" => BRICK, "C" => CHROME, "O" => PILLAR, "D" => LIGHT, "=" => TECH, "|" => DOOR }.freeze
    OPEN = [","].freeze           # floor under the open sky (the hall)
    ROUND = { PILLAR => 0.32 }.freeze

    WIDTH = 97
    HALL_CENTRE = [48.5, 20.5].freeze
    ORBIT = 5.0
    DOOR_CELL = [48, 11].freeze

    # The hall's colonnade, as cell offsets from its centre: one ring at about 7 cells, with
    # an aisle left open on the axis (the way in) and at (5, -5) (the way out), so the orbit
    # at 5 cells runs through an empty annulus.
    PILLARS = [[7, 0], [-7, 0], [0, 7], [7, 3], [7, -3], [-7, 3], [-7, -3], [3, 7], [-3, 7],
               [3, -7], [-3, -7], [5, 5], [-5, 5], [-5, -5]].freeze

    # Everything north of the hall, as drawn.
    MAZE = [
      "#            ######  BBBBB",
      "# ######### #......#B.....B#           BBBBB",
      "##.........# #####..........#     ####B.....B############",
      "##.##.####.#     #.#B.....B.#    #.......................#",
      "##.##.#....#   ###.#B.....B.#BBBB#.###B.....B.##.#######.#",
      "##.##.####.#BBB....# BBBBB#.B....B.#  B.....B.##.#     #.#",
      "##.##....#.B.....B.#      #.B....B.### BBBBB#.##.#     #.#",
      "##.# #####.B.....B.#      #...........#     #.##.#     #.#",
      "##.#     #.........#      #.B....B###.#      # #.#     #.#",
      "##.#      #B.....B#       #.B....B  #.#        #.#      #",
      "##.#        BB.BB          # BBBB    #         #.#",
    ].freeze

    def self.build_rows
      cx = HALL_CENTRE[0].floor
      cy = HALL_CENTRE[1].floor
      pillars = PILLARS.map { |ox, oy| [cx + ox, cy + oy] }
      rows = MAZE.map { |line| line.ljust(WIDTH - 1) + "#" }
      rows << ("# #           B".ljust(cx - 8) + "C" * 17).ljust(WIDTH - 1) + "#"
      # the door sits in a short neon passage, so its jambs carry the corridor's trims
      rows[11][DOOR_CELL[0] - 1, 3] = "#|#"
      (cy - 8..cy + 8).each do |y|
        line = "#" + " " * (cx - 10) + "C" + ","  * 17 + "C"
        line += case y - cy
                when -6, -4 then "=" * 36
                when -5 then "." * 36 + "D"
                else ""
                end
        line[cx + 9] = "." if y - cy == -5
        line = line.ljust(WIDTH - 1) + "#"
        pillars.each { |px, py| line[px] = "O" if py == y }
        rows << line
      end
      rows << ("#".ljust(cx - 8) + "C" * 17).ljust(WIDTH - 1) + "#"
      rows << "#" + " " * (WIDTH - 2) + "#"
      vestibule(rows, cy - 5)
      rows.freeze
    end

    # The last corridor opens twice before the light: to three cells wide, then five, and the
    # whole far wall of the last room is the doorway.
    def self.vestibule(rows, y)
      (79..84).each do |x|
        rows[y - 2][x] = "="
        rows[y - 1][x] = rows[y + 1][x] = "."
        rows[y + 2][x] = "="
      end
      (85..93).each do |x|
        rows[y - 3][x] = rows[y + 3][x] = "="
        (y - 2..y + 2).each { |r| rows[r][x] = "." }
      end
      (y - 2..y + 2).each { |r| rows[r][94] = "D" }
    end

    ROWS = build_rows

    # The route, as corridor corners (cell centres). Corners are cut by MazePath.
    MAZE_ROUTE = [
      [2.5, 10.6], [2.5, 2.5], [10.5, 2.5], [10.5, 8.5], [18.5, 8.5], [18.5, 2.5], [27.5, 2.5],
      [27.5, 7.5], [34.5, 7.5], [34.5, 3.5], [48.5, 3.5], [48.5, 11.0],
    ].freeze

    # Through the door on the hall's axis, straight at the great gem, then once all the way
    # round it (clockwise from above), out through the gap at (5, -5) and down the last
    # corridor to the light.
    def self.hall_route
      cx, cy = HALL_CENTRE
      arc = (300..630).step(15).map do |deg|
        a = deg * Math::PI / 180
        [cx + ORBIT * Math.cos(a), cy + ORBIT * Math.sin(a)]
      end
      [[cx, 12.6], [cx + 0.15, 14.4]] + arc + [[cx + 4.0, cy - 5.0], [cx + 9.0, cy - 5.0], [93.7, cy - 5.0]]
    end

    # Room lights: [x, y, height of centre, colour].
    ROOM_ORBS = [
      [12.6, 6.6, 0.72, :cyan], [16.4, 6.6, 0.72, :magenta], [12.6, 9.4, 0.72, :magenta], [16.4, 9.4, 0.72, :cyan],
      [21.6, 1.6, 0.72, :mint], [25.4, 1.6, 0.72, :gold], [21.6, 4.4, 0.72, :gold], [25.4, 4.4, 0.72, :mint],
      [29.6, 5.6, 0.72, :magenta], [32.4, 5.6, 0.72, :violet], [29.6, 9.4, 0.72, :violet], [32.4, 9.4, 0.72, :magenta],
      [39.6, 2.6, 0.72, :gold], [43.4, 2.6, 0.72, :cyan], [39.6, 5.4, 0.72, :cyan], [43.4, 5.4, 0.72, :gold],
      [5.5, 6.5, 0.8, :cyan], [45.5, 7.4, 0.8, :mint], [56.5, 8.4, 0.8, :magenta], [37.5, 9.4, 0.8, :gold],
    ].freeze

    # Lamps down the last corridor, near the ceiling.
    CORRIDOR_LAMPS = (0...9).map { |i| [61.5 + i * 4.0, 15.5, 0.86, i.even? ? :cyan : :magenta] }.freeze

    # Pickups on the route, by distance along it (the autopilot runs through them).
    SHOE_AT = [19.0, 25.5, 32.0, 39.0, 46.5, 53.0, 60.0, 66.5, 73.0].freeze
  end
end
