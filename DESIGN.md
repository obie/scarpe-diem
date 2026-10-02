# SCARPE DIEM: how it is built

A real-time demo in the demoscene tradition: Ruby and the Shoes DSL drive Scarpe's native Rust
renderer (tiny-skia, CPU only) through a soundtrack that Ruby synthesizes at launch. Every scene
pushes one limit of the renderer as far as it goes. The point is the moment a viewer says "that
cannot be Shoes".

## Layout

```
scarpe_diem.rb            the app: Shoes.app + Engine
lab.rb                    one scene alone (no loader, no audio) for building and benchmarking
lib/diem.rb               loads everything; PLAN (scene -> bars) and Placeholder
lib/diem/config.rb        W, H, U, FPS, DATA_DIR, Palette
lib/diem/music.rb         the score (data) + chord/section helpers
lib/diem/synth.rb         renders the score to a WAV (child process at launch)
lib/diem/sync.rb          Sync: kick/snare/notes at time t, from the same score
lib/diem/engine.rb        clock, scene switching, veil (fades/flashes), HUD, keys, recording
lib/diem/scene.rb         Scene base class (read it, it is short)
lib/diem/wire.rb          the fast path: props straight to the renderer
lib/diem/framebuffer.rb   a per-pixel software framebuffer through a BMP file
lib/diem/bitfont.rb       5x7 pixel font: Bitfont.points / points_centered / width
lib/diem/scenes/*.rb      one file per scene, class Diem::Scenes::<Name> < Diem::Scene
tools/shots.sh            exact headless pictures of a scene at chosen seconds
tools/sheet.sh            the same, tiled into one contact sheet
bench.sh                  ghost-window run with renderer stats (fps, Ruby ms, paint ms)
RENDERER_NOTES.md         what the renderer can and cannot do, with citations into ~/scarpe
```

## The timeline (120 bpm: 1 beat = 0.5 s, 1 bar = 2 s, 1 step = a 16th = 0.125 s)

| bars  | scene    | arrives | music (see SECTIONS in music.rb) |
|-------|----------|---------|----------------------------------|
| 0-16  | Ignition | fade    | 0-7 intro: pads, arp filter opening, soft hats from bar 4, riser bars 6-7, a breath on bar 7 beat 4. 8: DROP (kick, crash, impact). 8-15 full groove, fill bar 15 |
| 16-24 | Copper   | flash   | theme A lead melody, full groove with open hats, fill bar 23 |
| 24-32 | Plasma   | flash   | half-time groove Dm Am F E, syncopated bass, bell motif, riser bars 30-31 |
| 32-48 | Solids   | flash   | 32-39 theme B; 40-47 theme A + harmony; full groove; fills bars 39 and 47 |
| 48-56 | Dots     | fade    | breakdown: no drums, F G Em Am pads, bell melody, sub; riser + snare roll bars 54-55 |
| 56-72 | Maze     | flash   | 56 DROP 2 (impact), 56-63 driving, 64-71 theme B + harmony, riser 70-71 |
| 72-80 | Tunnel   | flash   | CLIMAX: key change to B minor, theme A + bell octave, galloping 16th bass, crash every 4 bars |
| 80-88 | Finale   | flash   | theme B + harmony + bell, riser 86-87, final hit on bar 88 |
| 88-96 | Credits  | flash   | outro in B minor, G A F#m Bm, bell melody, last chord held to the end |

## Scene contract

- `build` makes every drawable once, inside `draw { }`. Never create or remove drawables in
  `update`; hide them, park them off-screen, or give a rect zero width or a shape empty
  `shape_commands`.
- `update(t, sync)` runs every frame. `t` is seconds since the scene's first bar. `sync` is the
  song at that moment: `sync.hit(:kick, tau)` (1.0 on the hit, decaying), `sync.since(:snare)`,
  `sync.count(:kick)`, `sync.note(:lead)`, `sync.sounding?(:bell)`, `sync.bar`, `sync.beat_phase`,
  `sync.hits_between(:snare, a, b)`; `Music.chord_at(t_song)` gives `[symbol, notes, root]`.
  Tracks: kick snare clap hat ohat crash bass sub arp pad lead lead2 bell riser impact.
- Frames must be a pure function of the sequence of `t` values: no `rand` without a seeded
  `Random`, no `Time.now`. Stateful things (particles) step at a fixed 1/120 s up to `t`, and
  `enter` resets them. The recorder renders frame i at t = i / 60 and must get the same picture
  as the live run.
- Everything is relative to the scene's own slot and scaled by `u` (= h / 540), and counts are
  scaled by `density`, because the finale runs every scene at once as a small tile.
- Hot loops write through `set(drawable, props)` (Wire): colours as Integer arrays
  `[r, g, b, a]` (0..255, `wc(rgb_floats, alpha)` makes one), wire prop names `fill`, `stroke`,
  `left`, `top`, `width`, `height`, `x2`, `y2`, `shape_commands`, `hidden`, `outer`, `inner`,
  `angle1`, `angle2`, `rotate`. Only send what changed. Never mix Wire and Lacci setters on the
  same prop of the same drawable. On anything that is not art, positions must be Integers.
- Pens: unset fill and stroke are black 1 px. Give every shape `strokewidth: 0` (or a stroke).

## Measured on this machine (M2 Ultra, 4K display at 1x, ghost window, 960x540)

| load | result |
|---|---|
| 240 strips restyled (top, height, fill) | 60 fps, Ruby 1.5 ms, paint 4.8 ms |
| 1,000 translucent ovals moved | 60 fps, Ruby 4.7 ms, paint 5.2 ms |
| 2,304 rects recoloured, Lacci style | 48 fps (58 with YJIT), Ruby 16.5 ms |
| 2,304 rects recoloured, Wire | 60 fps, Ruby 1.7 ms, paint 4.9 ms |
| 5,184 rects recoloured, Wire | 60 fps, Ruby 3.7 ms, paint 9.5 ms |
| 9,216 rects recoloured, Wire | Rust-bound: paint 16.5 ms, 25 presented fps |
| 300 / 800 triangles, new points + fill each frame | 60 fps; paint 3.3 / 8.6 ms, Ruby 2.3 / 6.5 ms |
| 160x90 framebuffer (BMP) shown full window | 60 fps, Ruby 0.9 ms, paint 14.3 ms (bicubic resample) |
| 320x180 framebuffer shown full window | 60 fps, Ruby 3.2 ms, paint 14.4 ms |
| build 1,500 ovals / clear them | 85-105 ms / 42 ms |

Budget per scene at 960x540: Ruby `update` under ~7 ms, renderer paint under ~10 ms (the
framebuffer scenes accept ~14 ms of paint and keep everything else light). Measure with
`DIEM_SCENE=Name ./bench.sh lab.rb 8` and read `ruby timers` and `rust paint` (CPU time per
frame), not fps alone: other builders share the machine.
