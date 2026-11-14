# i2s for Windows: the handbook

Written from the macOS app on 2026-11-13 for the Windows port. Read all of
it before touching the Windows UI again. The macOS app is the reference.
Every screen named here has a reference image in `Reference/` (index at the end).

---

## 0. Read this first

**What i2s is.** A native desktop music player for people who care about
their library and about how their tools look. Three things define it:

1. **Total visual control.** Every surface, every piece of text, every
   button and the window chrome itself is a parameter the user can change,
   live, inside the app. That is the product, not a feature on the side.
2. **A distinctive, fixed design language.** Brutalist grid, 1px lines,
   dark glass, monospace type, Nerd Font icons, grays plus one accent.
3. **Serious library and listening tools.** Fast library over tens of
   thousands of tracks, metadata editing, lyrics, a parametric EQ, a sealed
   last.fm-style listening history with a full stats profile, and a
   Soulseek client ("Raven") with its own window.

**The standard for Windows.** One-to-one with the Mac: every screen,
state, animation, setting, customization and behaviour. The user's words:
"no compromises, no loss of performance, no loss of beautiful design, no
loss of anything". If something genuinely can't match, stop and ask the
user before building around it.

**How the user wants you to work (new, read twice).**
- Real, continuous progress on the actual app. Not a gallery of isolated
  component "build tests". One app that grows screen by screen.
- Send the user checkpoints: a build they can run, with screenshots, every
  time something meaningful lands (at least every major screen), and say
  what's next. Ask before committing or pushing, as always.
- Speed matters: this port is being pushed as fast as possible. Do the
  hard and tedious things first (section 6), not the easy ones.
- Run new design decisions or anything that can't match the Mac past the
  user first. Everything that's already decided by the Mac app: just build it.

---

## 1. Hard rules (unchanged, still absolute)

- No Claude or AI attribution anywhere. Author `xpgr`, every commit signed
  (Windows subkey). Never `--no-gpg-sign`. Never touch the GitHub ruleset.
- Commit messages are public: describe behaviour; never secrets.
- Files have real, descriptive names in descriptive folders (the opaque
  names and the file key were dropped on 2026-11-13).
- The source is plain text since 2026-11-14 (git-crypt removed); the repo
  is public, so never commit secrets. Push only with the user's OK.
- No networking on the user's behalf: no telemetry, no cloud, no accounts
  with us. Outside requests (covers, lyrics, Soulseek) go straight from the
  user's machine, only when the feature is used.
- No real artist, user or track names in examples, fixtures or copy.
- Tests never put windows or dialogs on the user's screen; never touch the
  user's real library or settings (scratch folders only).
- Logic lives once, in the shared Swift core (`Core/`), called through the C
  interface. Never reimplement it in C++ or QML. If the core lacks
  something, add it to the core (section 7).

---

## 2. Architecture you are building on

| Layer | Where | Notes |
|---|---|---|
| Shared core | `Core/` (Swift, Foundation + swift-crypto) | Built as `I2SCore.dll` on Windows. Models, library rules, listening history, profile stats, themes and palettes, skin rules, settings data, customize data, EQ data and maths, lyrics, icon tables, font faces. |
| C interface | `Core/CInterface.swift` + header `Core/include/i2s_core.h` | Version 3 (check `i2s_core_version`). JSON in and out, UTF-8, `i2s_free`. |
| Core checks | `CoreCheck/` runner, `CoreChecks` | `swift run I2SCoreCheck` (debug). Must pass before any commit that touches `Core/`. |
| Mac app | `macOS/` (SwiftUI + AppKit) | The reference. Read it freely to see exactly how anything works. |
| Windows app | `Windows/` (Qt Quick + C++) | Yours. |

**Persistence on Windows.** One JSON file per Mac UserDefaults key under
`%APPDATA%\MeimeiPlayer\defaults\<key>.json`, exact Mac key names, always
read through the core's normalize functions. Library and history live
where the Mac keeps them relative to the support folder
(`library.json`, `Artwork/`, `History/`). Moving between machines is a copy.

| Mac key | What | Core reader |
|---|---|---|
| `com.meimei.player.appSettings.v1` | every setting | `i2s_settings_normalize_json` |
| `com.meimei.player.customize.v2` | styles, layout, tokens, workspaces | `i2s_customize_normalize_json` |
| `com.meimei.player.themes.v1` + `activeThemeID.v1` | theme library + active | `i2s_themes_normalize_json` |
| `com.meimei.player.equalizer.v1` | EQ state | `i2s_eq_normalize_json` |
| `com.meimei.player.session.v1` | queue, position, time | (port the shape from `PlayerController.Session`) |
| `com.meimei.player.repeatMode`, volume | player prefs | plain values |
| `com.meimei.player.soulseek.v1` | Soulseek settings | later (core batch) |

---

## 3. Customization: the heart of the app

> The previous Windows attempt treated customize as "moving panels around".
> That is maybe a tenth of it. Look at `customize-*.png`, `main-customize*`,
> `main-layout*`, `settings-*`, `icons*`, `window-buttons*`, `buttons-*`.

There are **four layers** of customization. All four must exist on Windows,
behave the same and store the same data.

### 3.1 Customize mode (⇧⌘C → Ctrl+Shift+C): a live design editor

The whole main window becomes editable in place, while the app keeps working.

- **Every element has an outline.** Hovering anything draws its outline;
  clicking selects it (Shift adds to the selection). Elements are panels
  (player bar, now playing, browse, library, playlists rail, lyrics panel,
  status bar, EQ graph, EQ panels, table header), text roles (player
  title/artist/times, now-playing title/artist/details, library
  title/summary, section labels, sidebar rows, rail rows, track list, status
  text, lyrics, mini title/artist, EQ labels, table header labels) and
  controls (window buttons). The full table is `CustomElement` (kind, label,
  pane, isTitle). Each **lyric line** gets its own outline, sized to its
  drawn text and clipped to the lyrics viewport.
- **The inspector** floats over the window, can be dragged, and has four tabs:
  - **Element:** every property of the selection. Panels: fill colour and
    opacity, border colour/width/sides, corner ticks, padding, depth
    (shadow layer), height. Text: font family (any bundled face, previewed
    in itself), size scale, weight, colour, opacity, tracking, alignment
    and line count (titles only), shadow. Window buttons: the full window
    button look (section 3.3). Copy/paste style between elements
    (`ElementStyle.merging(_:kind:)`), reset per property and per element.
  - **Layers:** the element tree; select, show/hide panes.
  - **Global:** the design tokens: accent override, gray tone
    (neutral/warm/cool), text scale, grid gap, border width, panel opacity,
    corner ticks on/off and length, and the icon pack, icon size and
    per-icon overrides.
  - **Spaces (workspaces):** save the whole look (styles + layout + tokens)
    as a named workspace, apply one (Ctrl+1…9), export and import a
    workspace as a file, see "unsaved" when edits leave the applied one.
- **Layout editing:** drag a pane by its outline into another column or
  stack (drop targets shown live), resize panes from any edge or corner
  with snapping to other panes' edges (guides drawn), hide and restore
  panes, all animated, with undo (⌘Z / ⇧⌘Z). Rules: `PaneLayout.move`,
  `normalize`, `PaneResize` (minimum sizes, the library always keeps room).
- **Everything applies live** and persists (debounced 0.4 s) to
  `customize.v2`.

The Mac files: `macOS/Views/Customize/CustomizeStore.swift` (store), `macOS/Views/Customize/CustomizeInspector.swift` (inspector),
`macOS/Views/Customize/CustomizeOverlay.swift` (overlay), `macOS/Views/Customize/CustomizeModifiers.swift` (the modifiers every
element uses), `macOS/Views/Customize/PaneResize.swift` (resize rules).

**How to build this on Windows (the key decision):** every visual element
in the Qt app must be created through one wrapper that (a) registers its
`CustomElement` and reports its scene rect while customize mode is on, and
(b) applies the element's `ElementStyle` and the tokens to itself. On the
Mac that's `.panelSurface(_:skin:fallback:)` for panels and
`.textRole(_:size:weight:color:)` for text. Build the Qt equivalents
**first** (`CustomPanel` and `CustomText` items, plus a `CustomControls`
for window buttons) and use them for every element from the first screen
on. Retro-fitting customization later is the single most expensive mistake
this port can make.

### 3.2 Settings window (⌘, → Ctrl+,)

Seven pages, each a reference image (`settings-<page>`):
Layout, Panels, Library Table, Equalizer, Appearance, Behavior, Sources.
Every value in `AppSettingsData` is editable here, with live previews
drawn from the real settings (`macOS/Views/Settings/SettingsPreviews.swift`). Notable groups:

- **Appearance:** theme library (create, duplicate, rename, recolour every
  theme colour field, delete; generate a theme from 8+ colours; the live
  "From Cover" theme), surface style (glass/solid), backdrop (wallpaper,
  solid, grid, album art), glass tint, glass window dimming, hairline
  opacity, slider style, font family, monospaced numbers, icon pack and
  per-icon overrides, buttons (fill solid/outline/text, content icon+text /
  icon / text, size, accent on primary), window buttons (3.3).
- **Layout/Panels:** density, rail widths (proportional or fixed), cover
  size, which panels show, player bar position (top/bottom) and style
  (comfy/compact), transport scale, volume width, which player-bar buttons
  show, spectrum (style, bands, spacing, width, peaks), status bar parts.
- **Library Table:** visible columns and order, grouping, grid lines,
  alternating rows, hi-res badge, single-click play.
- **Behavior:** confirmations, remember last view, resume session,
  crossfade, lyrics offset, online lookups and sources, tag writing,
  cleanup rules, lyrics saving.
- **Sources:** Soulseek on/off and its developer card (to be removed).

### 3.3 Window buttons

The window has no system title bar. Its own buttons are fully configurable:
style, glyphs (always/hover/never), size, shape, side, spacing, icon scale,
border, colouring (theme/accent/per button with colours), hover effect,
resting opacity, close last, and per-button icons chosen from the icon
set's own close/minimize/zoom glyphs. They're editable in Settings, in
customize mode (element "window buttons") and from the buttons' own context
menu. Child windows show only Close. See `window-buttons*.png`.

### 3.4 Themes and icons

15 built-in themes in 5 categories plus the live cover theme (all from the
core: `i2s_themes_normalize_json`, `i2s_skin_json`). Users edit every
colour field (`ThemeColorField`). The skin every view draws with comes
from the core's `i2s_skin_json`: the theme supplies the accent; surfaces
and text are a tonal gray scale from the tokens; glass makes panels clear.
Icons: 8 packs (Material, Material Outline/Filled/Circle/Box, Codicons,
Font Awesome, Octicons), 116 roles, per-role overrides from the whole Nerd
Font symbol set (`i2s_icons_json`). See `icons*.png`.

---

## 4. Design system (exact)

**Look.** Brutalist grid; every pane a rectangle with a 1px line
(`hairline` × `hairlineOpacity`); optional corner ticks (L-shaped marks,
`tickLength`) instead of rounded corners; sharp corners. Dark glass: the
main window shows the user's backdrop (album art blur by default, or
wallpaper, solid, grid) and panes are translucent veils over it
(`panelOpacity` for control panels, `min(0.95, panel + 0.16)` for content
like the library). Child windows (Settings, Library, Downloads, EQ, legal,
sheets, ⌘K palette) use frosted HUD glass with "glass window dimming".
Never stack dark veils (murky); sections inside a glass pane are
transparent with a 1px line only (`pageGlass`).

**Colour.** Grays plus one accent. No gradients, no glow, no hue washed
over surfaces. All values from `i2s_skin_json` (RGBA 0…1).

**Type.** Bundled families (`i2s_fonts_json`): 6 monospaced Nerd Fonts
(Geist Mono default, JetBrains Mono, Blex Mono, Iosevka, Commit Mono,
Monaspice Neon) and 4 sans (Inter, Geist, IBM Plex Sans, Space Grotesk).
Face rule: light by default, regular below 11 pt and for medium/semibold,
bold for bold and heavier (`i2s_font_face`). Sans faces always use
tabular figures where the Mac uses `.monospacedDigit()` (all text roles).
Sizes used on the Mac (pt): 10, 10.5, 11, 11.5, 12, 12.5, 13, 14, 14.5,
15, 17, 20, 22, 28; text scale token multiplies them. Labels are plain
lowercase or sentence case: no ALL CAPS, no `//` prefixes, no brackets as
decoration. Professional copy.

**Icons.** Nerd Font symbols drawn from glyph outlines, fitted at 88% of
their box, centred by bounding box (you already match this).

**Controls.** One button shape: a rectangle with a 1px border that
brightens under the pointer, accent-filled when prominent or active (fill
setting decides solid/outline/text). Transport and toolbar icons are bare
glyphs with no background: brighten on hover, dip on press, accent when
active. Sliders: a thin line that thickens on hover; knob shows on
hover/drag (`line`) or always (`knob`). Our own menus everywhere (never the
OS menu). Hidden scroll bars everywhere; mouse-wheel notches glide 0.16 s
ease-out to exactly the native distance; trackpads untouched.

**Motion.** Hover/press 0.08–0.12 s ease-out; panel/page changes use the
SwiftUI spring (response 0.28–0.3, damping 0.85–0.9, you have the maths);
progress lines glide on the compositor (`CapsuleProgress`/ProgressLayer
timings in the port doc); lyrics lines spring to the current line.

**Window chrome.** Borderless square window, custom title band 46 pt with
controls 14 pt from the left, minimum sizes per window, keep Windows snap,
resize edges and shadow (done).

---

## 5. Feature inventory (screens and what they do)

Each item lists the reference images. "W" = what's specific to Windows.

**Main window** (`main-*`). Player bar on top (or bottom), then columns of
panes (now playing + browse | library | lyrics | playlists by default),
status bar below. Panes: now playing (largest square cover that fits, title,
artist, details/format strip, spectrum optional), browse (library views,
collections, genres with counts), library (header with title/summary,
filter, group menu, shuffle, play; then the track table, or the Albums /
Artists / Profile pages, or an album's detail header + its tracks), lyrics
(synced lines highlight and scroll; click a line to seek; plain lyrics as
text; offset), playlists rail (account header → profile, settings button,
manual and smart playlists, drop tracks onto a playlist). Status bar:
totals, selection, scan progress.

**Track table.** Virtualized (pooled rows), columns from settings
(`TrackColumnKind`), sort by clicking headers (core `TrackSort`; cache text
ranks per library version), grouping (none/album/artist/…), striping,
hi-res badge, now-playing marker, single/double-click play (plays in the
on-screen order), multi-select, drag to playlists and reorder in manual
playlists, the track context menu (`menu.png`), keyboard navigation.
W: QML `TableView`/`ListView` + `QAbstractTableModel` over indices from
`i2s_library_view_json`; never copy track structs per row; text ranks
cached by library version. This is the hardest single UI piece. Do it early.

**Pages** (`main-albums*`, `main-artists*`, `main-profile*`,
`*-wide.png`). Albums: latest addition spread straight on the page, no
box (cover, details, buttons, and the first tracks as striped lines with no
box or scrolling: beside the cover from 860 pt, eight lines to match the
cover's height, the last one "All N tracks ›" when the album is longer;
under the cover below that, eight tracks in two columns from 640 pt, then
the link; the link opens the album). Recently added shelf: a click on a
card's title (anywhere along its line) opens the album, on its artist opens
the artist page; both underline under the pointer. Then every album as rows
straight on the page: heading 15 pt semibold with album count and total time
beside it, and under it in 11 pt "Sort  Recently added ⌄" (plain text, no
box; value brightens on hover) that opens the sort menu; the first cover
sits 10 pt below the sort line, as the shelf's covers sit below its title.
Every row starts with its tracklist showing; clicking the row folds it away
and back. Tracklists run in two columns read across (one under 640 pt), and
every other line is shaded with the skin's `bgRowAlt` when "Alternating row
colors" (`tableAlternatingRows`) is on, exactly like the track table's
stripes (odd lines, 1 px inset each side). Artists: cards with fanned covers, facts, genre, top
three tracks. Profile: range chips (7/30/90 days, 12 months, all time),
totals with change vs previous period, timeline chart, top
artists/albums/tracks, listening clock, weekdays, genres, decades,
discoveries, streaks, milestones, coverage, recent listens, history check
line (all from `i2s_profile_stats_json`).

**Player bar.** Transport (shuffle, previous, play/pause, next, repeat),
what's playing (cover, title, artist, seek line with times), right side
(lyrics, Up Next, EQ toggle, mini player, volume). Comfy/compact, top/bottom.

**Search palette ⌘K** (`palette-overlay.png`): songs, albums, artists,
commands, keyboard driven, in-window glass.

**Up Next** popover (`sheets-sheet-up-next.png`), **mini player**
(`window-mini*`, `sheets-sheet-mini-player.png`).

**Equalizer window** (`eq-window*`, `settings-equalizer*`): parametric EQ
like a DAW plug-in: response graph with draggable band nodes over a live
analyzer, band strip, inspector with knobs and typed values, filter types
(`EQFilterType`), gain range, presets, A/B compare, undo/redo, AutoEQ/APO
import and export, signal path diagram.
W: implement the filters as biquads whose magnitude equals
`EqualizerResponse.gain` (`i2s_eq_response_json`), same Q/slope rules.

**Library window ⇧⌘L** (`library-window-library-*.png`): folders,
scanning and watching, missing files, upkeep, and Library → Metadata
(album-by-album editing, covers from disk or the web, artist spellings,
library-wide cleanup, lookup sources).

**Sheets** (`sheets-sheet-*.png`): Get Info (edit tags, cover, fetch art
or lyrics, save to library and file), new/edit playlist (manual or smart
with rules, order, limit), duplicate review, theme generator. Every sheet is square
like the windows (no system rounded sheet frame).

**Listening history.** Listens timed by audible time on a monotonic clock;
counted at half the track or 4 minutes (tracks ≥ 30 s); every full repeat
counts; sealed, signed, chained log; play counts and the profile come only
from it (`i2s_history_*`, `i2s_listen_counts`). W: the tracker (pause,
mute, track change, gapless advance, quit) is small: port `ListenTracker`
(`macOS/Models/ListenHistory.swift`) exactly, recording through `i2s_history_append_json`.

**Downloads / Raven (Soulseek) ⇧⌘D** (`downloads-*.png`): first-run setup
(overview, network, account, location, sharing, review), search with its
own typed syntax (key, autocomplete, autocorrect), results grouped by
user and folder, transfers grouped by user/folder with history popovers,
browse a user (live trace, failure screen), messages (notice, threads),
sharing, network (route: default / Raven Tunnel WireGuard / SOCKS5; DNS
over TLS; incoming port), log console (⌘J), rail notices, legal window.
W: the transport (Network.framework) must be rewritten; see section 6, P2.

**Keyboard** (Mac ⌘ → Ctrl on Windows, ⌥ → Alt): Settings ⌘, ·
New Playlist ⌘N · Add Music ⌘O · Library ⇧⌘L · Downloads ⇧⌘D · Rescan ⇧⌘R ·
Search ⌘K · Filter ⌘F · Play/Pause Space · Next/Prev ⌘→/⌘← · Stop ⌘. ·
Volume ⌘↑/⌘↓ · Shuffle ⌥⌘S · Repeat ⌥⌘R · Equalizer ⌥⌘E · Now Playing
Album ⌘L · Customize ⇧⌘C · Workspaces ⌃1…9 · Toggle panes ⌥⌘1…4 · Mini
Player ⇧⌘M · Log ⌘J (Downloads) · Back ⌘[ / Forward ⌘] (Windows: Alt+←/→
too), mouse side buttons the same.

**Back and forward** (main window, like a browser): every change of page or
open album is remembered (page + album; at most 100); a new visit clears
what was ahead; a deleted playlist is skipped and a removed album falls back
to its page; restoring the last view at launch starts a fresh history. Moving
back slides the pane in from the left, forward from the right: 44 pt and
transparent to in place, spring (response 0.42, damping 0.84) with a 0.24 s
fade, applied to the pane in place (tables aren't rebuilt) and clipped to it.

---

## 6. Priority order: fastest path to the full app, hard things first

Each step ends with a runnable build and a checkpoint to the user.

**P0, the foundation everything else stands on (do now, in this order)**
1. **Customization plumbing.** `CustomPanel` / `CustomText` / `CustomControls`
   wrappers applying `ElementStyle` + tokens + skin; element registry with
   live scene rects; skin + tokens + settings as one reactive context fed
   from the core. Every later component uses these. (Hard, foundational.)
2. **Main window shell:** title band and window buttons (full options),
   player bar (both styles and positions), pane grid with columns, stacks,
   natural heights (`WeightedStack`), column handles, status bar,
   backdrops (album-art blur, wallpaper via DWM, solid, grid).
3. **Track table** with real data from `i2s_library_*`: columns, sort,
   group, select, play, context menu, drag. (Hardest UI piece.)
4. **Playback end to end:** gapless engine (done) wired to a queue model
   (port `PlayerController` semantics: shuffle order, repeat, play next,
   add to queue, stop after current, sleep timer, session restore,
   crossfade), the listen tracker into the history, SMTC (done).
5. **Library import:** folders, scanning, file watching
   (`ReadDirectoryChangesW`), tag reading (TagLib), content-addressed
   artwork cache, `library.json` written in the Mac shape. Needs core
   library mutations (section 7).

**P1, the rest of the main window and the editors**
6. Customize mode overlay + inspector (all four tabs), layout move/resize
   with snapping and undo, workspaces with import/export.
7. Now playing, browse, playlists rail, lyrics panel, album detail,
   Albums / Artists / Profile pages.
8. Settings window (all seven pages with previews), theme editor and
   generator, icon editor, window-button editor.
9. Our own menus everywhere, ⌘K palette, Up Next, mini player.
10. Equalizer DSP + window; Get Info and tag writing (TagLib); Library
    window; duplicates; playlist editor; metadata page and online lookups.

**P2, Downloads / Raven**
11. Soulseek: the protocol and store logic move into the core (wire format
    is portable already; the socket layer needs a portable rewrite:
    plain sockets or SwiftNIO in the core), then the Downloads window UI.
    WireGuard tunnel: `wireguard-go` builds on Windows as a c-archive/DLL
    the same way (`RavenTunnel/`), so Raven Tunnel can come along.

**P3, release work**
12. History keys in DPAPI + TPM (NCrypt Platform Crypto Provider),
    installer (MSIX or a signed setup), Authenticode signing, Qt LGPL
    compliance (ship Qt as DLLs, licence texts), update policy.

---

## 7. Core work still to do (you own it now)

The Mac session is handing the rest of the port to you, core included.
When you change `Core/`: no Apple-only imports, `swiftc -typecheck` clean,
`I2SCoreCheck` passing, bump `coreInterfaceVersion` + header on any
C or JSON change, and say in the commit message that the shared core
changed so the user can run the Mac self-test before it ships. Keep the
Mac building: anything you move out of `macOS/` must keep the Mac compiling
(read the call sites; the Mac compiles `macOS/` + `Core/` together).

Wanted next, roughly in order:
- Customize rules over C: `CustomElement` table, `PaneLayout.move` /
  `normalize`, `ElementStyle.merging`, and `PaneResize` moved from `macOS/`
  into the core (your request from phase 3).
- Library mutations over C: import results in, remove, relink moved
  files, playlists create/rename/edit/reorder/add/remove, smart playlist
  evaluation, likes, duplicate detection results, artist groups, genres;
  writing `library.json`.
- The now-playing natural height, if it helps: derive it from the panel
  content (cover + text), as you suggested.
- Cover colour extraction for the live theme (`AlbumColorExtractor`) into
  the core, fed sampled pixels.
- Search syntax (`macOS/Views/Downloads/SearchSyntax.swift`) + search filters, then Soulseek.
- Metadata rules that aren't UI (cleanup, title case: already in core;
  online lookup parsing).

---

## 8. Windows implementation pointers

- **Rendering:** Qt Quick scene graph; custom `QQuickItem`macOS/`QSGNode`s for
  lines, ticks, progress and graphs; no Qt Quick Controls styling.
- **Fonts:** `QFontDatabase::addApplicationFont` for every file in `Assets/Fonts`;
  FreeType unhinted greyscale (done). Advances quantize to 1/64 px
  (accepted, ≤0.17%).
- **Glass:** DWM system backdrop (Acrylic) for child windows; for the
  main window, draw the user's backdrop yourself (blurred cover via a
  shader, wallpaper capture if allowed, solid, grid) and the pane veils on
  top. Match the Mac's numbers from `i2s_skin_json`.
- **Track table:** one model over indices; text from the tracks array;
  re-query `i2s_library_view_json` on filter/sort changes only.
- **Audio:** FFmpeg decode + miniaudio WASAPI (done); EQ as biquads before
  output; spectrum FFT (KissFFT) at 10–20 Hz with display-rate easing.
- **Files and dialogs:** `IFileOpenDialog` or Qt's native dialog; "Show in
  Explorer" via `explorer /select,`.
- **Media keys:** SMTC (done).
- **Secrets:** Credential Manager / DPAPI for the Soulseek password and
  history keys.
- **Menus:** popup windows per level (frameless, tool), keyboard driven,
  type-to-select; same model as `MenuContent` (`macOS/Views/Controls/AppMenu.swift`).
- **Performance targets (Mac, release, 10k tracks):** filter 11–20 ms,
  play/like ~6 ms, sort 1–2 ms, scroll p95 ~2.6 ms; history read 20k
  listens ~0.17 s.

---

## 9. Reference images

All in `Reference/`, PNG without extension. "Capture" = a real window capture of
the running app (exactly as shown). "Render" = an offscreen render: glass
blur behind windows isn't shown, and AppKit-hosted parts (text fields, the
track table, some menus) appear as yellow placeholders; use the matching
capture for those parts.

Two more caveats. Child windows (Settings, Library, Equalizer, mini player)
are frosted glass over whatever is behind them on the desktop; a headless
capture has nothing behind them, so they look flat gray here. In use they
are a light frosted HUD glass with the user's "glass window dimming". The
scratch library uses neutral names ("Artist 0", "Record 0-0", "Echo 0 0")
and generated covers; the Downloads sample data is fixture data.

`Reference/main-empty.png` is the main window with an empty library (sent earlier).

The table below maps each state to its file.

| State | File | Pixels | Kind | What it shows |
|---|---|---|---|---|
| buttons-buttons-outline | `Reference/buttons-buttons-outline.png` | 1264×204 | Render | Buttons, fill Outline (same row) |
| buttons-buttons-solid | `Reference/buttons-buttons-solid.png` | 1264×204 | Render | Buttons, fill Solid: Group / Shuffle (disabled) / Play (prominent) / Add Music (active) / Compact |
| buttons-buttons-text | `Reference/buttons-buttons-text.png` | 1264×204 | Render | Buttons, fill Text only (same row) |
| downloads-dl-browse-failed | `Reference/downloads-dl-browse-failed.png` | 1350×870 | Render | Downloads window page/state: browse failed |
| downloads-dl-browse-receiving | `Reference/downloads-dl-browse-receiving.png` | 1350×870 | Render | Downloads window page/state: browse receiving |
| downloads-dl-browse-request | `Reference/downloads-dl-browse-request.png` | 1350×870 | Render | Downloads window page/state: browse request |
| downloads-dl-history | `Reference/downloads-dl-history.png` | 600×495 | Render | Downloads window page/state: history |
| downloads-dl-history-folder | `Reference/downloads-dl-history-folder.png` | 600×495 | Render | Downloads window page/state: history folder |
| downloads-dl-log | `Reference/downloads-dl-log.png` | 1350×1050 | Render | Downloads window page/state: log |
| downloads-dl-messages | `Reference/downloads-dl-messages.png` | 1350×870 | Render | Downloads window page/state: messages |
| downloads-dl-messages-notice | `Reference/downloads-dl-messages-notice.png` | 1350×870 | Render | Downloads window page/state: messages notice |
| downloads-dl-network | `Reference/downloads-dl-network.png` | 1350×2100 | Render | Downloads window page/state: network |
| downloads-dl-search | `Reference/downloads-dl-search.png` | 1350×870 | Render | Downloads window page/state: search |
| downloads-dl-search-assist | `Reference/downloads-dl-search-assist.png` | 1350×870 | Render | Downloads window page/state: search assist |
| downloads-dl-search-corrected | `Reference/downloads-dl-search-corrected.png` | 1350×2700 | Render | Downloads window page/state: search corrected |
| downloads-dl-search-key | `Reference/downloads-dl-search-key.png` | 1350×2475 | Render | Downloads window page/state: search key |
| downloads-dl-search-key-problem | `Reference/downloads-dl-search-key-problem.png` | 1350×870 | Render | Downloads window page/state: search key problem |
| downloads-dl-search-key-typed | `Reference/downloads-dl-search-key-typed.png` | 1350×2700 | Render | Downloads window page/state: search key typed |
| downloads-dl-sharing | `Reference/downloads-dl-sharing.png` | 1350×870 | Render | Downloads window page/state: sharing |
| downloads-dl-transfers | `Reference/downloads-dl-transfers.png` | 1350×870 | Render | Downloads window page/state: transfers |
| downloads-legal | `Reference/downloads-legal.png` | 1350×2250 | Render | Downloads / Raven: legal |
| downloads-network-tunnel | `Reference/downloads-network-tunnel.png` | 1350×2250 | Render | Downloads / Raven: network tunnel |
| downloads-overview-full | `Reference/downloads-overview-full.png` | 1350×3450 | Render | Downloads / Raven: overview full |
| downloads-rail-notice | `Reference/downloads-rail-notice.png` | 294×300 | Render | Downloads / Raven: rail notice |
| downloads-settings-sources | `Reference/downloads-settings-sources.png` | 1620×1050 | Render | Downloads / Raven: settings sources |
| downloads-setup-account | `Reference/downloads-setup-account.png` | 1350×870 | Render | Raven first-run setup step: account |
| downloads-setup-location | `Reference/downloads-setup-location.png` | 1350×870 | Render | Raven first-run setup step: location |
| downloads-setup-network | `Reference/downloads-setup-network.png` | 1350×2250 | Render | Raven first-run setup step: network |
| downloads-setup-overview | `Reference/downloads-setup-overview.png` | 1350×3600 | Render | Raven first-run setup step: overview |
| downloads-setup-review | `Reference/downloads-setup-review.png` | 1350×870 | Render | Raven first-run setup step: review |
| downloads-setup-sharing | `Reference/downloads-setup-sharing.png` | 1350×870 | Render | Raven first-run setup step: sharing |
| downloads-sources-page | `Reference/downloads-sources-page.png` | 1350×870 | Render | Downloads / Raven: sources page |
| downloads-window-buttons | `Reference/downloads-window-buttons.png` | 840×660 | Render | Downloads / Raven: window buttons |
| downloads-window-buttons-look | `Reference/downloads-window-buttons-look.png` | 450×1350 | Render | Downloads / Raven: window buttons look |
| eq-window-swiftui | `Reference/eq-window.png` | 2040×1280 | Render | Equalizer window with six bands, one selected (graph, band strip, inspector) |
| icons-icons | `Reference/icons-icons.png` | 1200×905 | Render | Icon pack, size and per-icon editor |
| library-window-1 | `Reference/library-window-1.png` | 1840×1280 | Capture | Library window (Ctrl+Shift+L), first section |
| library-window-library-folders | `Reference/library-window-library-folders.png` | 1380×1140 | Render | Library window section: folders |
| library-window-library-maintenance | `Reference/library-window-library-maintenance.png` | 1380×1140 | Render | Library window section: maintenance |
| library-window-library-metadata-albums | `Reference/library-window-library-metadata-albums.png` | 1380×1140 | Render | Library window section: metadata albums |
| library-window-library-metadata-artists | `Reference/library-window-library-metadata-artists.png` | 1380×1140 | Render | Library window section: metadata artists |
| library-window-library-metadata-cleanup | `Reference/library-window-library-metadata-cleanup.png` | 1380×1140 | Render | Library window section: metadata cleanup |
| library-window-library-metadata-lyrics | `Reference/library-window-library-metadata-lyrics.png` | 1380×1140 | Render | Library window section: metadata lyrics |
| library-window-library-metadata-sources | `Reference/library-window-library-metadata-sources.png` | 1380×1140 | Render | Library window section: metadata sources |
| library-window-library-missing | `Reference/library-window-library-missing.png` | 1380×1140 | Render | Library window section: missing |
| library-window-library-overview | `Reference/library-window-library-overview.png` | 1380×1140 | Render | Library window section: overview |
| library-window-library-scanning | `Reference/library-window-library-scanning.png` | 1380×1140 | Render | Library window section: scanning |
| main-album | `Reference/main-album.png` | 2480×1560 | Capture | Album detail: header (cover, title, artist, details) above the album tracks |
| main-albums | `Reference/main-albums.png` | 2480×1560 | Capture | Albums page in the library pane (window width) |
| main-albums-wide | `Reference/main-albums-wide.png` | 1000×1500 | Render | Albums page at a wide pane (1000 pt): latest addition spread, Recently added shelf, album list with striped tracklists |
| main-artbackdrop | `Reference/main-artbackdrop.png` | 2480×1560 | Capture | Backdrop: album art (blurred) behind the glass panes |
| main-artist | `Reference/main-artist.png` | 2480×1560 | Capture | One artist (today: header, album strip, tracks; profiles are being redesigned) |
| main-artists | `Reference/main-artists.png` | 2480×1560 | Capture | Artists page in the library pane |
| main-artists-wide | `Reference/main-artists-wide.png` | 1000×1500 | Render | Artists page at a wide pane: cards with fanned covers, facts, top tracks |
| main-cover | `Reference/main-cover.png` | 2480×1560 | Capture | Live "From Cover" theme: accent from the cover, glass over the blurred art |
| main-customize | `Reference/main-customize.png` | 2480×1560 | Capture | Customize mode ON: outlines on every element, a selection, the floating inspector |
| main-customize-element | `Reference/main-customize-element.png` | 688×1482 | Render | Customize inspector, Element tab (selection properties) |
| main-customize-global | `Reference/main-customize-global.png` | 688×4134 | Render | Customize inspector, Global tab (design tokens, icons) |
| main-customize-layers | `Reference/main-customize-layers.png` | 688×2158 | Render | Customize inspector, Layers tab |
| main-customize-spaces | `Reference/main-customize-spaces.png` | 688×648 | Render | Customize inspector, Spaces tab (workspaces) |
| main-default | `Reference/main-default.png` | 2480×1560 | Capture | Main window, empty-ish start: library loaded, nothing playing (default settings, glass, album-art backdrop) |
| main-layout | `Reference/main-layout.png` | 2480×1560 | Capture | Customize layout editing: a pane being rearranged |
| main-liked | `Reference/main-liked.png` | 2480×1560 | Capture | Liked Songs (a normal playlist page) |
| main-lyrics | `Reference/main-lyrics.png` | 2480×1560 | Capture | Main window with the lyrics pane open, synced lyrics following playback, cover backdrop |
| main-npwide | `Reference/main-npwide.png` | 2480×1560 | Capture | Now playing pane made wide (pane resized) |
| main-playing | `Reference/main-playing.png` | 2480×1560 | Capture | Main window playing: player bar, now playing panel, track table with now-playing marker |
| main-profile | `Reference/main-profile.png` | 2480×1560 | Capture | Profile page in the library pane |
| main-profile-wide | `Reference/main-profile-wide.png` | 1000×2700 | Render | Profile page at a wide pane, full height: every statistic |
| main-solid | `Reference/main-solid.png` | 2480×1560 | Capture | Surface style Solid instead of glass |
| menu-menu | `Reference/menu-menu.png` | 631×866 | Render | Our own context menu on a track (second entry highlighted) |
| palette-overlay | `Reference/palette-overlay.png` | 1860×1170 | Render | Search palette (Ctrl+K) over the main window |
| settings-appearance-1 | `Reference/settings-appearance-1.png` | 1800×1360 | Capture | Settings window page: appearance |
| settings-behavior-1 | `Reference/settings-behavior-1.png` | 1800×1360 | Capture | Settings window page: behavior |
| settings-equalizer-1 | `Reference/settings-equalizer-1.png` | 1800×1360 | Capture | Settings window page: equalizer |
| settings-layout-1 | `Reference/settings-layout-1.png` | 1800×1360 | Capture | Settings window page: layout |
| settings-panels-1 | `Reference/settings-panels-1.png` | 1800×1360 | Capture | Settings window page: panels |
| settings-sources-1 | `Reference/settings-sources-1.png` | 1800×1360 | Capture | Settings window page: sources |
| settings-table-1 | `Reference/settings-table-1.png` | 1800×1360 | Capture | Settings window page: table |
| sheets-sheet-duplicates | `Reference/sheets-sheet-duplicates.png` | 1360×1200 | Render | Sheet / popover: duplicates |
| sheets-sheet-edit-smart-playlist | `Reference/sheets-sheet-edit-smart-playlist.png` | 1240×806 | Render | Sheet / popover: edit smart playlist |
| sheets-sheet-equalizer-window | `Reference/sheets-sheet-equalizer-window.png` | 2160×1400 | Render | Sheet / popover: equalizer window |
| sheets-sheet-get-info | `Reference/sheets-sheet-get-info.png` | 1440×1216 | Render | Sheet / popover: get info |
| sheets-sheet-mini-player | `Reference/sheets-sheet-mini-player.png` | 840×400 | Render | Sheet / popover: mini player |
| sheets-sheet-new-playlist | `Reference/sheets-sheet-new-playlist.png` | 1240×578 | Render | Sheet / popover: new playlist |
| sheets-sheet-theme-generator | `Reference/sheets-sheet-theme-generator.png` | 1344×1402 | Render | Sheet / popover: theme generator |
| sheets-sheet-up-next | `Reference/sheets-sheet-up-next.png` | 800×1040 | Render | Sheet / popover: up next |
| window-downloads-1 | `Reference/window-downloads-1.png` | 1800×1360 | Capture | Downloads requested while Soulseek is off: Settings opens on Sources with a prompt |
| window-equalizer-1 | `Reference/window-equalizer-1.png` | 2040×1280 | Capture | Equalizer window as opened from the app |
| window-mini-2 | `Reference/window-mini-2.png` | 920×176 | Capture | Mini player window |
