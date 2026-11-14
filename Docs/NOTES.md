# Meimei

A native macOS music player for people who miss foobar2000 and Winamp —
dense multi-pane layout, user-editable themes, a real audio-reactive
spectrum analyzer, and nothing but AppKit, SwiftUI, and AVFoundation
underneath.

Builds as a Swift Package; the macOS Command Line Tools are enough.

## Features

**Playback**
- True gapless playback: the next track is scheduled sample-accurately at
  the end of the current one. Optional equal-power crossfade (0–8 s).
- Shuffle with a real play order (no repeats, Previous walks back through
  it), Repeat All / One, Play Next and Add to Queue.
- Resumes the last queue and position at launch (paused).
- A DAW-style parametric EQ in its own window (⌥⌘E): up to 48 filters —
  bells, low/high shelves, low/high cuts at 12–48 dB/oct, notches, and
  band-pass — dragged directly on a response graph over a live analyzer.
  Knobs and typed values per band, solo (hear just that band's range),
  bypass, A/B compare, undo/redo, input gain with auto headroom, an output
  peak meter with clip light, 15 built-in presets, and import/export of
  Equalizer APO / AutoEQ `ParametricEQ.txt` files.
- Stop After Current Track and a sleep timer (Playback menu).
- Media keys, Control Center, and Now Playing integration.

**Library**
- Import folders or files (⌘O or drag onto the window). Imports run in
  parallel, skip files already in the library, and fill in as they go.
- FLAC, ALAC, AAC, MP3, WAV, AIFF; real bit depth for FLAC and ALAC.
- Browse All Music, Albums, Artists (portrait grid and artist pages with
  their albums), Liked Songs, Recently Added, Recently Played, Most Played,
  and genres — ⌘1…⌘7 jump between them, ⌘L shows the playing album.
- A live filter in the library header (⌘F) narrows any view as you type.
- Manual playlists with drag-to-reorder and drag-to-add; smart playlists
  with 17 fields, any/all matching, ordering, and a track limit.
- Get Info writes tags back into FLAC (Vorbis comments), MP3 (ID3v2.4), and
  MP4 files, keeping every frame and comment Meimei doesn't edit. Covers
  and lyrics can be looked up online on request — never automatically.
- Duplicate detection; removal only ever touches the library, not files.

**Customization** (modular, after Cider's layouts and player types)
- Player bar at the top or bottom, Comfy or Compact, with each control
  (shuffle/repeat, lyrics, Up Next, EQ, mini player, spectrum) toggleable.
- Every pane can be shown, hidden, and dragged to the width you want.
  Three densities, nine optional table columns, grouping, Hi-Res marks.
- Look: a brutalist grid (sharp corners, visible 1px borders, corner
  registration ticks) with dark frosted panels over the blurred album art,
  the wallpaper, a faint grid, or a solid base. Surfaces and text use a
  monochrome tonal scale; the theme or the playing cover adds one accent.
- Type: six bundled monospaced Nerd Fonts — Geist Mono (default, Light),
  JetBrains Mono, Blex Mono (IBM Plex), Iosevka, Commit Mono, Monaspice
  Neon — subset to ~1.9 MB. Icons are glyphs from the same fonts, so the
  look carries over unchanged to other platforms. Licenses are in
  `Resources/Fonts/Licenses`.
- Themes set the accent. The live "From Cover" theme takes its accent from
  the playing cover and sits on the blurred art.
- Divider strength, progress style, and typeface apply app-wide. Spectrum: gradient, solid, LED, mirrored.
- Synced `.lrc` lyrics panel with offset; mini player; ⌘K command palette.
- Customize mode (⇧⌘C or the brush in the top bar), a live layout and
  style editor over the real window:
  - Layout: drag any panel to move it — onto another panel's top or bottom
    half to stack, its outer edge for a new column; the player bar snaps
    top or bottom. Columns and stacks resize from their gaps; panels hide
    and show from Layers. Fixed columns shrink together to always fit.
  - Elements: click any panel or text role (⇧-click for several) and edit
    font, size, weight, color (with a WCAG contrast readout), opacity,
    letter spacing, alignment, line count, legibility shadow; panel fill,
    per-side borders, corner ticks, padding, depth, bar heights, column
    widths. Every changed property has its own reset; values can be typed.
    Scroll over text to size it, arrows to nudge, ⌘C / ⌘V to copy styles.
  - Design tokens: accent override, warm / neutral / cool grays, text
    scale, grid gap, panel opacity, border width, corner ticks.
  - Workspaces: save the whole look (layout, tokens, styles) and switch
    with ⌃1–⌃9. Hold ⌥ to compare with the original design. Full undo,
    and export/import as a JSON style file.

## Building & running

```bash
swift build && swift run                 # debug
./Scripts/build_app.sh release           # dist/Meimei.app, ad-hoc signed
open dist/Meimei.app
```

## Development checks

Debug builds include a self-test and a window snapshot tool (no test
framework ships with the Command Line Tools, and neither needs screen
recording permission):

```bash
# Model, tag-writer, analyzer, theme, and audio-engine checks. The engine
# checks play generated tones and measure the rendered output for gaps.
MEIMEI_SUPPORT_DIR=/tmp/meimei-test .build/debug/MeimeiPlayer --self-test

# Render the window(s) to PNG. --open: settings, equalizer, palette,
# albums, album, liked, lyrics, cover, solid, artbackdrop. Put --play last.
MEIMEI_SUPPORT_DIR=/tmp/meimei-test .build/debug/MeimeiPlayer \
    --snapshot /tmp/shot.png --open albums --snapshot-delay 3 --play
```

`MEIMEI_SUPPORT_DIR` keeps these runs away from your real library. The
snapshot tool prints `snapshot: done` and waits to be terminated. Window
capture misses layer-composited SwiftUI content on recent macOS, so it also
writes `<file>-swiftui.png`, an offscreen render of the main view (AppKit
views such as the track table appear as placeholders there, and glass is
drawn as a flat translucent stand-in).

## Project layout

```
Sources/MeimeiPlayer/
  App/      Entry point, menu commands, session wiring, debug hooks
  Models/   Track, Playlist, smart rules, LibraryStore, artwork cache, persistence
  Audio/    AudioEngine (two-deck gapless/crossfade), PlayerController,
            spectrum analysis, equalizer, tag reading/writing, online lookup
  Theme/    Skins, theme catalog, cover-derived palettes, settings model
  Views/    SwiftUI + AppKit UI (transport, table, sidebar, rails, settings…)
Packaging/  Info.plist, app icon
Scripts/    build_app.sh
```

## Data

The library lives in `~/Library/Application Support/MeimeiPlayer/`
(`library.json` plus a content-addressed `Artwork/` cache); preferences in
the app's user defaults. Older library files and settings load as-is.
