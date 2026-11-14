import SwiftUI

/// A compact companion window: cover, title, seek bar, and transport.
struct MiniPlayerView: View {
    @ObservedObject private var player = AppSession.shared.player
    @ObservedObject private var engine = AppSession.shared.player.engine
    @ObservedObject private var theme = AppSession.shared.theme
    @ObservedObject private var settings = AppSession.shared.settings

    private var skin: Skin { settings.styled(theme.skin) }
    private var track: Track? { player.currentTrack }

    var body: some View {
        HStack(spacing: 12) {
            // Meimei's window controls, or room for the platform's.
            if settings.data.systemWindowFrame {
                Color.clear.frame(width: 52, height: 1)
            } else {
                WindowControls(skin: skin, canZoom: false).frame(width: 52)
            }

            ArtworkView(path: track?.artworkFilePath, size: 62, skin: skin, placeholder: "waveform")
                .clipShape(Rectangle())
                .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track?.title ?? "Nothing playing")
                        .textRole(.miniTitle, size: 13, weight: .semibold, color: skin.textPrimary)
                        .lineLimit(1)
                    Text(track?.artist ?? "i2s")
                        .textRole(.miniArtist, size: 11, color: skin.textSecondary)
                        .lineLimit(1)
                }
                MiniSeekBar(player: player, clock: engine.clock, skin: skin, style: settings.data.sliderStyle,
                            monospaced: settings.data.useMonospacedNumbers)
            }

            HStack(spacing: 4) {
                TransportButton(icon: "backward.fill", size: 24, iconSize: 10, skin: skin) { player.previous() }
                PlayPauseButton(isPlaying: engine.isPlaying, size: 30, skin: skin) { player.togglePlayPause() }
                TransportButton(icon: "forward.fill", size: 24, iconSize: 10, skin: skin) { player.next() }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(width: 480, height: 88)
        .font(AppFont.ui(12))
        .background {
            WindowBackdrop(style: settings.effectiveBackdrop(for: skin), skin: skin, artwork: theme.artworkImage,
                           glassTint: settings.data.glassTintStrength)
        }
        .background(WindowDragArea())
        .background(WindowChromeGuard(transparent: settings.effectiveBackdrop(for: skin) == .translucent))
    }
}

private struct MiniSeekBar: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var clock: PlaybackClock
    var skin: Skin
    var style: SliderStyleOption
    var monospaced: Bool

    @State private var seeking: Double?

    var body: some View {
        HStack(spacing: 6) {
            TimeLabel(text: Track.format(seconds: seeking ?? clock.currentTime), size: 9.5, color: skin.lcdOn, monospaced: monospaced)
            MinimalSlider(
                value: Binding(get: { seeking ?? clock.currentTime }, set: { seeking = $0 }),
                range: 0...max(clock.duration, 0.01),
                onEditingChanged: { editing in
                    if !editing, let target = seeking {
                        player.seek(to: target)
                        seeking = nil
                    }
                },
                skin: skin,
                trackHeight: 3,
                style: style
            )
            .frame(height: 12)
            TimeLabel(text: Track.format(seconds: clock.duration), size: 9.5, color: skin.textTertiary, monospaced: monospaced)
        }
    }
}
