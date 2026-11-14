# Porting i2s to Windows, Linux, web and mobile

> **Status: in progress.** The core split has begun (first batch in `Core/`)
> and the Windows Qt Quick app is being built in parallel. Last reviewed
> 2026-11-12.

## Approach

One shared Swift core, one interface per platform family.

- **Core (`Core/`)**: models, library logic, the sealed listening history,
  profile stats, and in time themes, settings payloads, metadata tools,
  search syntax and the Soulseek protocol. Pure Swift + Foundation (+
  swift-crypto off Apple). On macOS it compiles into the app; on Windows and
  Linux it builds as the `I2SCore` shared library with the `I2SCoreCheck`
  runner. The same checks (`CoreChecks`) run on every platform.
- **macOS UI**: SwiftUI + AppKit, unchanged.
- **Windows UI (later Linux)**: Qt Quick, chosen by a trial against WinUI 3
  and Swift + WinUI. It draws every component itself (no stock Qt
  controls), calls the core through the C interface (`Core/include/i2s_core.h`:
  UTF-8 strings, JSON payloads, `i2s_free`, versioned), and implements the
  platform pieces below natively.
- **Parity**: one-to-one, visually and logically. The same named snapshot
  states at the same sizes on both platforms, compared side by side; every
  setting and Customize option on both; the same performance numbers.
  Qt is used under the LGPL (shipped as separate libraries), to be checked
  in the pre-release legal review.

The design system is the same everywhere: brutalist grid, 1px borders,
corner ticks, dark glass, grays plus one accent, bundled Nerd Fonts, no
platform-specific look.

Files are named for what they are: `Core/` (shared core), `macOS/` (Mac
app), `Windows/` (Qt app), `Assets/Fonts`, `RavenTunnel/`, `Docs/`.

## What already ports (pure Swift + Foundation)

- Models: tracks, playlists, smart playlists, library rows, settings
  payloads (`LenientDecodable`), persistence shapes.
- Library logic: filtering, sorting with cached ranks, grouping, duplicates,
  metadata cleanup (title casing, artist merges).
- Theme data: skins, the theme catalog, the theme generator, icon pack tables
  and icon roles.
- Equalizer maths (band responses, presets, AutoEQ import).
- Soulseek wire format: framing, messages, search replies, share lists, the
  MD5 login hash (written out; CryptoKit is Apple-only).
- Soulseek share indexing and transfer bookkeeping.

## Platform pieces to replace

| Piece | macOS today | Replace with |
|---|---|---|
| Audio output, gapless, crossfade | AVAudioEngine | WASAPI (Windows), PipeWire/ALSA (Linux), Web Audio, AAudio/AVAudioSession on mobile |
| Spectrum FFT | Accelerate (vDSP) | A portable FFT (e.g. KissFFT) |
| Tag reading/writing | AVFoundation + our own FLAC/ID3 code | Keep our FLAC/ID3 code; TagLib for the rest |
| Track table | NSTableView (pooled rows) | Native virtualized list per platform |
| Window chrome, borderless frame | NSWindow tweaks | Custom title bar per platform |
| Behind-window blur (glass) | NSVisualEffectView | Mica/Acrylic (Windows), compositor blur or a static blurred backdrop (Linux, web) |
| App menus (right-click, dropdowns) | Borderless NSPanel per menu level | Popup window or in-window overlay; the model (`MenuContent`) is portable |
| Font registration | CoreText | Platform font APIs, or bundle and load per process |
| Open/save panels, Finder reveal | NSOpenPanel, NSWorkspace | Platform file dialogs, `explorer /select`, `xdg-open` |
| Media keys, now playing | MPRemoteCommandCenter | SystemMediaTransportControls (Windows), MPRIS (Linux) |
| Secrets (Soulseek password) | Keychain (Security framework) | Credential Manager/DPAPI (Windows), libsecret (Linux) |
| Listening history keys (`HistorySecrets`, `HistorySigner`) | Keychain + Secure Enclave P-256 (CryptoKit) | TPM-backed key via CNG Platform Crypto Provider (Windows), TPM2 or libsecret + software key (Linux); swift-crypto for ChaChaPoly/P-256/SHA-256. The file format stays the same. |
| zlib for Soulseek | Apple Compression (raw DEFLATE, we add the zlib header/trailer) | System zlib |
| **Soulseek networking** | **Network.framework** | **SwiftNIO or plain sockets — see below** |
| Progress lines (Downloads, scans, saves) | `ProgressLayer`: two CALayers animated on the render server (fill glides over the time since the last update; the running segment's position and width keyframed, 1.6 s loop) | The same two rectangles and timings in the platform's compositor animation (Windows.UI.Composition, CSS animation); keep the timings so it looks identical |
| In-window glass (command palette) | NSVisualEffectView `.withinWindow` | Acrylic in-app brush (Windows), CSS `backdrop-filter`, or a blurred snapshot |
| Text search in filters | `memmem` over UTF-8 (`String.has`) | Available in every C library; no change |
| Popovers (transfer history, file list trace) | SwiftUI `.popover` | A small anchored overlay panel |
| Scroll bars | Hidden everywhere (`.scrollIndicators(.never)`, the track table's scrollers off) | Hide the platform's scroll bars; scrolling itself stays native |
| Mouse-wheel glide | `SmoothWheel`: NSScrollView's wheel handler swapped at launch; a notch eases over 0.16 s (cubic ease-out) to exactly the distance AppKit would jump (lines × line height); notches add up; trackpad deltas untouched | Windows already animates wheel scrolling; keep its defaults, or match 0.16 s ease-out if a toolkit jumps |

Performance notes that carry over to any port: tracks are copy-on-write (`Track` keeps its fields in one shared box), search results and browse lists are cached and built off the main thread, and file and folder facts (format, quality, cover, year) are worked out once when results arrive. Keep these in the port's data layer; the UI only reads them.

## Soulseek: needs a rewrite of its transport

Soulseek downloads were built on Apple's **Network.framework** because it was
the fastest route on macOS. It is Apple-only, so **the transport must be
rewritten for Windows and Linux.** The damage is contained:

- **Rewrite:** `SlskSocket` (one TCP connection with Soulseek framing) and the
  listener setup inside `SlskClient` (Soulseek engine, `macOS/Soulseek/SlskClient.swift`).
  Options: **SwiftNIO** (solid on Linux; Windows support was still maturing at
  the time of writing) or BSD sockets behind a thin wrapper (Winsock needs
  small adjustments).
- **Keep as is:** everything above the socket: the wire codec
  (`macOS/Soulseek/SlskWire.swift`), the session, peer, search, download and upload logic
  in `SlskClient`, the share index, and the app-side store
  (`macOS/Soulseek/SoulseekStore.swift`) apart from its Keychain helper.
- **Also platform-specific in this feature:** Keychain (password), Apple
  Compression (zlib), NSOpenPanel (folder pickers), NSWorkspace (reveal).
- **Tests:** the self-test runs a whole session against a fake loopback
  server and peer (`macOS/App/FakeSlskNetwork.swift`); port it with the transport and use it
  as the acceptance test.

Not built yet on any platform (macOS included): the distributed search
network (answering other users' searches), UPnP / NAT-PMP port mapping,
obfuscated ports, chat rooms and private messages, wishlists, and speed
limits.

## Suggested order

1. Split the portable code into its own Swift package target (no AppKit,
   SwiftUI, AVFoundation, Network, Security or Compression imports) and build
   it on Linux in CI. This shows exactly what still leaks.
2. Port the Soulseek transport to SwiftNIO or sockets; run the loopback test
   on Linux.
3. Audio engine per platform, then the library table.
4. Window chrome, glass, menus and settings screens.
5. Packaging and signing (MSIX or a plain installer on Windows; AppImage or
   Flatpak on Linux).

Web and mobile come after the desktop ports. The shared core helps there too
(Swift for Android/iOS; WebAssembly for the web), but the audio and file
access models are different enough to need their own plan.
