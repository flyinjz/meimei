import SwiftUI

/// The player bar: transport on the left, what's playing centered, and the
/// utility controls on the right. Bare glyphs, no button chrome. Comfy or
/// Compact, at the top or bottom; under glass surfaces it floats as a
/// rounded band with corners concentric to the window.
struct PlayerBarView: View {
    @ObservedObject private var customize = AppSession.shared.customize
    @ObservedObject var player: PlayerController
    @ObservedObject var engine: AudioEngine
    @ObservedObject var settings: AppSettings
    var skin: Skin
    var onOpenMiniPlayer: () -> Void

    private var data: AppSettingsData { settings.data }
    private var scale: CGFloat { CGFloat(data.transportButtonScale) }
    private var compact: Bool { data.playerBarStyle == .compact }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)
                NowPlayingModule(
                    player: player,
                    clock: engine.clock,
                    skin: skin,
                    compact: compact,
                    sliderStyle: data.sliderStyle,
                    accentProgress: data.accentProgress,
                    monospaced: data.useMonospacedNumbers
                )
                .frame(width: min(540, max(280, geo.size.width * 0.4)))
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: geo.size.height)
        }
        .padding(.horizontal, 16)
        .frame(height: CGFloat(customize.style(.playerBar).height ?? Double(data.playerBarStyle.height)))
        .panelSurface(.playerBar, skin: skin, fallback: skin.bgPanel)
    }

    // MARK: Leading: transport

    private var leading: some View {
        HStack(spacing: 2 * scale) {
            if data.showShuffleRepeat {
                TransportButton(icon: "shuffle", size: 26 * scale, iconSize: 12 * scale,
                                isActive: player.shuffle, help: player.shuffle ? "Shuffle: On" : "Shuffle: Off", skin: skin) {
                    player.shuffle.toggle()
                }
            }
            TransportButton(icon: "backward.fill", size: 30 * scale, iconSize: 15 * scale, help: "Previous", skin: skin) {
                player.previous()
            }
            PlayPauseButton(isPlaying: engine.isPlaying, size: (compact ? 30 : 34) * scale, skin: skin) {
                player.togglePlayPause()
            }
            TransportButton(icon: "forward.fill", size: 30 * scale, iconSize: 15 * scale, help: "Next", skin: skin) {
                player.next()
            }
            if data.showShuffleRepeat {
                TransportButton(icon: player.repeatMode.symbolName, size: 26 * scale, iconSize: 12 * scale,
                                isActive: player.repeatMode != .off, help: repeatHelp, skin: skin) {
                    player.repeatMode = player.repeatMode.next
                }
            }
        }
    }

    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: return "Repeat: Off"
        case .all: return "Repeat: All"
        case .one: return "Repeat: One"
        }
    }

    // MARK: Trailing: utilities and volume

    private var trailing: some View {
        HStack(spacing: 4 * scale) {
            if data.showSpectrum {
                SpectrumView(
                    feed: engine.spectrum,
                    isPlaying: engine.isPlaying,
                    skin: skin,
                    style: data.spectrumStyle,
                    barSpacing: data.spectrumBarSpacing,
                    showPeaks: data.spectrumShowPeaks
                )
                .frame(width: data.spectrumWidth, height: compact ? 16 : 20)
                .padding(.trailing, 8)
            }
            if data.showLyricsButton {
                TransportButton(icon: "quote.bubble", size: 26 * scale, iconSize: 13 * scale,
                                isActive: data.showLyrics, help: "Lyrics", skin: skin) {
                    withAnimation(.easeOut(duration: 0.2)) { settings.data.showLyrics.toggle() }
                }
            }
            if data.showQueueButton {
                UpNextButton(player: player, skin: skin, size: 26 * scale, iconSize: 13 * scale)
            }
            if data.showEQToggle {
                EqualizerTransportButton(equalizer: player.equalizer, skin: skin, size: 26 * scale, iconSize: 13 * scale)
            }
            if data.showMiniPlayerButton {
                TransportButton(icon: "pip", size: 26 * scale, iconSize: 13 * scale, help: "Mini Player", skin: skin,
                                action: onOpenMiniPlayer)
            }
            VolumeControl(player: player, engine: engine, skin: skin, style: data.sliderStyle)
                .frame(width: data.volumeSliderWidth + 26)
                .padding(.leading, 6)
        }
    }
}

/// Cover, title, artist, and progress. No background: it's text and a
/// line, centered in the bar. Only the times and the line (inside
/// `ClockReader`s) redraw on every clock tick.
struct NowPlayingModule: View {
    @ObservedObject var player: PlayerController
    let clock: PlaybackClock
    var skin: Skin
    var compact: Bool
    var sliderStyle: SliderStyleOption
    var accentProgress: Bool
    var monospaced: Bool

    @State private var seekValue: Double?

    private func time(_ clock: PlaybackClock) -> TimeInterval { seekValue ?? clock.currentTime }
    private var track: Track? { player.currentTrack }

    var body: some View {
        HStack(spacing: compact ? 9 : 11) {
            ArtworkView(path: track?.artworkFilePath, size: compact ? 30 : 44, skin: skin, placeholder: "music.note")
                .clipShape(Rectangle())
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .opacity(track == nil ? 0.5 : 1)
                .onTapGesture { if let track { AppSession.shared.library.albumKey = track.albumKey } }
                .help(track == nil ? "" : "Show album")

            VStack(spacing: compact ? 3 : 4) {
                if compact {
                    HStack(spacing: 6) {
                        titleText
                        Spacer(minLength: 6)
                        ClockReader(clock: clock) { times($0) }
                    }
                } else {
                    VStack(spacing: 1) {
                        titleText
                        Text(subtitle)
                            .textRole(.playerSubtitle, size: 11, color: skin.textSecondary)
                            .lineLimit(1)
                            .onTapGesture {
                                if let track {
                                    AppSession.shared.library.source = .artist(track.displayArtist)
                                }
                            }
                            .help(track == nil ? "" : "Show artist")
                    }
                    .frame(maxWidth: .infinity)
                }
                ClockReader(clock: clock) { progress($0) }
            }
        }
    }

    private func progress(_ clock: PlaybackClock) -> some View {
        let time = self.time(clock)
        return HStack(spacing: 8) {
                    if !compact {
                        TimeLabel(text: Track.format(seconds: time), size: 9.5, color: skin.textTertiary, monospaced: monospaced, role: .playerTimes)
                            .frame(width: 34, alignment: .trailing)
                    }
                    MinimalSlider(
                        value: Binding(get: { time }, set: { seekValue = $0 }),
                        range: 0...max(clock.duration, 0.01),
                        onEditingChanged: { editing in
                            if editing {
                                seekValue = clock.currentTime
                            } else if let target = seekValue {
                                player.seek(to: target)
                                seekValue = nil
                            }
                        },
                        skin: skin,
                        trackHeight: compact ? 2 : 3,
                        style: sliderStyle,
                        accentFill: accentProgress
                    )
                    .frame(height: 10)
                    .disabled(track == nil)
                    if !compact {
                        TimeLabel(text: "−" + Track.format(seconds: max(0, clock.duration - time)), size: 9.5,
                                  color: skin.textTertiary, monospaced: monospaced, role: .playerTimes)
                            .frame(width: 38, alignment: .leading)
                    }
                }
    }

    private var titleText: some View {
        Text(track?.title ?? "Not Playing")
            .textRole(.playerTitle, size: compact ? 11.5 : 12.5, weight: .semibold, color: track == nil ? skin.textTertiary : skin.textPrimary)
            .lineLimit(1)
    }

    private var subtitle: String {
        guard let track else { return " " }
        return [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private func times(_ clock: PlaybackClock) -> some View {
        TimeLabel(text: "\(Track.format(seconds: time(clock))) / \(Track.format(seconds: clock.duration))", size: 9.5,
                  color: skin.textTertiary, monospaced: monospaced)
    }
}

/// Opens the Library window; shows scanning progress while a scan runs.
private struct LibraryButton: View {
    var skin: Skin
    @ObservedObject private var scanner = AppSession.shared.scanner
    @ObservedObject private var library = AppSession.shared.library

    var body: some View {
        let busy = scanner.isScanning || library.scan != nil
        TransportButton(icon: "music.note.house", size: 24, iconSize: 13, weight: .regular, isActive: busy,
                        help: busy ? "Library (scanning…) ⇧⌘L" : "Library: folders and scanning (⇧⌘L)", skin: skin) {
            WindowRequest.library.post()
        }
        .overlay(alignment: .topTrailing) {
            if !scanner.missingIDs.isEmpty {
                Rectangle().fill(skin.accent).frame(width: 5, height: 5).offset(x: -2, y: 2)
                    .help("\(scanner.missingIDs.count) missing files")
            }
        }
    }
}

/// Re-renders only its content when the clock ticks.
struct ClockReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder var content: (PlaybackClock) -> Content

    var body: some View { content(clock) }
}

/// Speaker glyph (click to mute / restore) and the volume line.
private struct VolumeControl: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var engine: AudioEngine
    var skin: Skin
    var style: SliderStyleOption
    @State private var volumeBeforeMute: Float = 0.7

    var body: some View {
        HStack(spacing: 4) {
            TransportButton(icon: icon, size: 22, iconSize: 12, weight: .regular,
                            help: engine.volume > 0.001 ? "Mute" : "Unmute", skin: skin) {
                if engine.volume > 0.001 {
                    volumeBeforeMute = engine.volume
                    player.setVolume(0)
                } else {
                    player.setVolume(max(0.1, volumeBeforeMute))
                }
            }
            MinimalSlider(
                value: Binding(get: { Double(engine.volume) }, set: { player.setVolume(Float($0)) }),
                range: 0...1,
                skin: skin,
                trackHeight: 3,
                style: style
            )
        }
    }

    private var icon: String {
        switch engine.volume {
        case ..<0.001: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// A Spotlight-style capsule that opens the command palette.
private struct SearchPill: View {
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Glyph("magnifyingglass", size: 11)
                    .foregroundStyle(hovering ? skin.accent : skin.textTertiary)
                Text("Search songs, albums, artists, commands")
                    .font(AppFont.ui(11.5))
                    .foregroundStyle(hovering ? skin.textSecondary : skin.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("[⌘K]")
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(width: 380, height: 28)
            .background(Rectangle().fill(skin.textPrimary.opacity(hovering ? 0.08 : 0.045)))
            .overlay(Rectangle().strokeBorder(hovering ? skin.accent.opacity(0.7) : skin.textPrimary.opacity(0.16), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDipStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Search songs, albums, artists, and commands (⌘K)")
    }
}

/// The strip beside the window's traffic lights: the sidebar toggle and
/// search. Drawn without a fill, so the window backdrop shows above the
/// player band.
struct TitleStrip: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin
    var onSearch: () -> Void
    var onCustomize: () -> Void = {}

    var body: some View {
        // The pill is centered on the window itself, whatever sits at the sides.
        // Glyph buttons are 24pt with a 13pt icon, so their visible edge sits
        // 5.5pt inside the frame. Outer padding is set so the window controls
        // on the left and the last icon on the right sit the same 14pt from
        // the window edge.
        ZStack {
            HStack(spacing: 10) {
                // Meimei's window controls, or room for the platform's.
                if settings.data.systemWindowFrame {
                    Color.clear.frame(width: 62, height: 1)
                } else {
                    WindowControls(skin: skin)
                        .padding(.leading, 5.5)
                }
                TransportButton(icon: "sidebar.left", size: 24, iconSize: 13, weight: .regular,
                                help: settings.data.showSidebar ? "Hide Sidebar" : "Show Sidebar", skin: skin) {
                    withAnimation(.easeOut(duration: 0.2)) { settings.data.showSidebar.toggle() }
                }
                Spacer()
                DownloadsButton(skin: skin)
                LibraryButton(skin: skin)
                TransportButton(icon: "paintbrush.pointed", size: 24, iconSize: 13, weight: .regular,
                                isActive: AppSession.shared.customize.isActive,
                                help: "Customize the interface (⇧⌘C)", skin: skin, action: onCustomize)
            }
            SearchPill(skin: skin, action: onSearch)
        }
        .padding(.horizontal, 8.5)
        // The platform's traffic lights sit low in the band; only then nudge down to match them.
        .padding(.top, settings.data.systemWindowFrame ? 6 : 0)
        .frame(height: 46) // the titlebar band
        .background(WindowDragArea())
    }
}

/// Opens the Downloads window, or, while Soulseek is off, Settings → Sources.
private struct DownloadsButton: View {
    var skin: Skin
    @ObservedObject private var store = AppSession.shared.soulseek

    var body: some View {
        TransportButton(icon: "downloads", size: 24, iconSize: 13, weight: .regular,
                        isActive: store.downloads.contains { $0.state == .downloading },
                        help: store.settings.enabled ? "Downloads (⇧⌘D)" : "Downloads (Soulseek is disabled)", skin: skin) {
            WindowRequest.downloads.post()
        }
    }
}
