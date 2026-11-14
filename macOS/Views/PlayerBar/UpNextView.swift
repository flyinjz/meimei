import SwiftUI

/// Player-bar button that opens the Up Next list.
struct UpNextButton: View {
    @ObservedObject var player: PlayerController
    var skin: Skin
    var size: CGFloat
    var iconSize: CGFloat
    @State private var showing = false

    var body: some View {
        TransportButton(icon: "list.bullet", size: size, iconSize: iconSize, isActive: showing, help: "Up Next", skin: skin) {
            showing.toggle()
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            UpNextView(player: player, skin: skin) { showing = false }
                .scrollIndicators(.never)
        }
    }
}

/// What plays after the current track, in play order. Click a row to jump to it.
struct UpNextView: View {
    @ObservedObject var player: PlayerController
    var skin: Skin
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next")
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(skin.textPrimary)
                Spacer()
                if player.shuffle {
                    Text("Shuffled")
                        .font(AppFont.ui(10.5, weight: .medium))
                        .foregroundStyle(skin.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            let upcoming = Array(player.upNext.prefix(100).enumerated())
            if upcoming.isEmpty {
                Text(player.currentTrack == nil ? "Nothing is playing." : "Nothing after this track.")
                    .font(AppFont.ui(11.5))
                    .foregroundStyle(skin.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(upcoming, id: \.offset) { offset, track in
                            let play = {
                                if let position = player.position { player.jump(toOrderIndex: position + 1 + offset) }
                            }
                            UpNextRow(track: track, skin: skin, action: play)
                                .appContextMenu { MenuContent.track(track, play: play) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(380, CGFloat(upcoming.count) * 42 + 8))
            }
        }
        .frame(width: 320)
        .background(skin.isGlass ? Color.clear : skin.bgPanel)
    }
}

private struct UpNextRow: View {
    var track: Track
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ArtworkView(path: track.artworkFilePath, size: 30, skin: skin)
                    .clipShape(Rectangle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(AppFont.ui(12, weight: .medium))
                        .foregroundStyle(skin.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(track.formattedDuration)
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Rectangle().fill(hovering ? skin.hover : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
