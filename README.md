# SCARPE DIEM

A real-time demo, in the demoscene tradition, written in Ruby with the Shoes DSL and drawn by
Scarpe's native Rust renderer. Three minutes and twelve seconds, nine scenes, one soundtrack that
Ruby synthesizes on your machine when you start it. Then you can walk the maze yourself.

Everything you see is Shoes drawables (rects, ovals, lines, shapes, paras, images) changed from
Ruby every frame and painted by tiny-skia on the CPU. There is no GPU code, no shader, no video
and no pre-rendered frame anywhere in it.

## Watch it, or run it

The [latest release](https://github.com/obie/scarpe-diem/releases/latest) has the app as a
`.dmg` and a 1080p60 recording of the whole show.

To run it from source you need a clone of [Scarpe](https://github.com/scarpe-team/scarpe) at
`~/scarpe` (or set `SCARPE`), set up as its `FOR_AGENTS.md` describes: Ruby 3.2.11 or newer
(3.4.7 matches the packaged app), `bundle install`, and Rust with `cargo`, since the native
renderer builds itself on first run. Then, from wherever you cloned this:

```sh
cd ~/scarpe && bundle exec ruby exe/scarpe --native /path/to/scarpe-diem/scarpe_diem.rb
```

On first launch it spends about ten seconds synthesizing the soundtrack, and the loader shows
every instrument rendering; after that the WAV is cached in
`~/Library/Application Support/Scarpe Diem`. `tools/package.sh` builds the `.app` and `.dmg`
into `dist/`.

When the show ends, press W and you are inside the maze: seven lost shoes are hidden in it.
Arrows or WASD move you; hold the mouse to walk and steer with it.

| key | does |
|---|---|
| space | pause |
| left / right | previous / next scene |
| 1 to 9 | jump to a scene |
| m | mute |
| f | the stats line: scene, bar, Ruby frame rate and cost, shapes, changes per frame |
| r | replay |
| w | at the end: walk the maze yourself |
| esc | quit |

`DIEM_SIZE=1280x720` gives a bigger window; every scene draws in scaled units.

## Share it

Send the `.dmg` (15 MB) rather than the `.app`: an app is a folder of 1,170 files with symlinks
inside, and many uploaders, or a plain `zip -r`, break it. The `.dmg` is one file and holds the app
plus a link to Applications.

- It runs on Apple silicon Macs only, on macOS 12.2 or later.
- It is ad-hoc signed and not notarized, so macOS blocks the first open of a downloaded copy.
  Drag it to Applications, try to open it once, then choose Open Anyway in System Settings,
  Privacy & Security (or run `xattr -dr com.apple.quarantine "/Applications/Scarpe Diem.app"`).
- Notarizing it would take a Developer ID Application certificate and real signing in Scarpe's
  packager, which today signs ad hoc only.

## What happens

| time | scene | the limit it pushes |
|---|---|---|
| 0:00 | Ignition | 3,400 shapes: a 3D starfield into hyperspace, then 1,300 particles that land on the drop as an extruded logo and turn in 3D |
| 0:32 | Copper | Amiga homage: chrome copper bars woven in depth, a voxel sine scroller of greetings, a reflected checkerboard |
| 0:48 | Plasma | a full-window per-pixel plasma computed in Ruby, 32,400 pixels a frame, singing the bell line |
| 1:04 | Solids | flat-shaded 3D: a torus knot, a spiking icosphere, then a ruby, lit and depth-sorted in Ruby, 500 polygons a frame |
| 1:36 | Dots | 1,600 dots morphing between a sphere, a torus, DNA, the word SHOES and a galaxy |
| 1:52 | Maze | WOLFENSHOES 3D, a raycaster: walls, sprites, a pillared hall at sunset |
| 2:24 | Tunnel | the climax in B minor: a texture-mapped tunnel, per pixel, in Ruby |
| 2:40 | Finale | everything at once: every scene running live as a tile of one video wall |
| 2:56 | Credits | with the real numbers from your run |

## How

- **The soundtrack** is data (`lib/diem/music.rb`): 4,754 notes on 15 tracks. `lib/diem/synth.rb`
  renders it with band-limited oscillators, a sidechain pump, delay and reverb, forking one worker
  per slice of each track so a 24-core machine does it in about six seconds. The scenes read the
  same score through `Diem::Sync`, so a flash lands on the kick because both come from one event.
- **The wire.** A Lacci `style` call costs about 7 µs of Ruby. The engine's hot loops post props
  straight to the renderer's input pipe (`Diem::Wire`, through the display service's public
  `child`), which costs about 0.4 µs. That is the difference between 2,300 and 5,000 shapes
  changing every frame at 60 fps.
- **Real 3D.** A Shoes shape's path is a style, so `style(shape_commands: ...)` rewrites a polygon
  in place. A fixed pool of shapes, refilled far to near each frame, is a painter's-algorithm
  renderer.
- **Per-pixel effects.** The renderer re-reads an image whose file changed, so Ruby writes a small
  BMP each frame (two files taking turns, renamed into place) and the renderer scales it up. That
  is a software framebuffer in a Shoes app.
- **Recording.** `tools/record.rb` renders every frame of the show headless at 2x through the real
  renderer, in parallel chunks, then lays the soundtrack under it: a frame-exact 1080p60 video.

## Measured

Live, in an invisible ghost window on an M2 Ultra driving a 4K display at 1x, 960x540
(`tools/perf_report.rb`, renderer stats):

| scene | presented fps | paint ms | Ruby ms | shapes |
|---|---|---|---|---|
| Ignition | 57.0 | 6.96 | 3.67 | 3,442 |
| Copper | 57.6 | 8.31 | 1.16 | 382 |
| Plasma | 58.1 | 15.2 | 6.56 | 129 |
| Solids | 57.9 | 8.77 | 2.18 | 1,475 |
| Dots | 56.6 | 6.78 | 4.08 | 1,669 |
| Maze | 56.2 | 9.03 | 4.22 | 3,309 |
| Tunnel | 57.6 | 13.85 | 6.34 | 28 |
| Finale | 55.6 | 8.81 | 3.08 | 4,519 |
| Credits | 58.0 | 3.72 | 0.97 | 375 |

The ghost window presents at most about 58 frames a second on this setup (a still scene measures
the same), so every scene runs at the display's pace. The renderer paints on the CPU; on a Retina
display it paints four times the pixels, so expect lower numbers there. The recording shows every
frame regardless. In the finale each live tile updates at 20 Hz: the renderer repaints the whole
window once more than half of it changes, so the tiles take turns, a column a frame.

The packaged app runs on the Ruby that Scarpe bundles (Traveling Ruby 3.4.7), which is built
without YJIT; there the soundtrack takes about ten seconds and Ruby's share of each frame grows,
while staying inside the frame budget in the scenes measured.

The credits in the release's recording show the numbers from the live run in this table.

## Files

```
scarpe_diem.rb        the app
lib/diem/             engine, score, synth, sync, wire, framebuffer, bitfont, scenes
lab.rb                one scene on its own (DIEM_SCENE=Plasma), for building and benchmarking
tools/                shots, contact sheets, recorder, perf report, audio QA
checks/               Scarpe checks (checks/run.sh)
icon/                 icon.rb draws the source in Scarpe; Recraft made icon_final.png from it
tools/package.sh      builds dist/Scarpe Diem.app and .dmg
DESIGN.md             the contract every scene follows, and the measurements behind it
RENDERER_NOTES.md     what the renderer can and cannot do, with citations into Scarpe's source
```

Written by Claude, for Obie Fernandez, on top of Nick's renderer and _why's Shoes.
