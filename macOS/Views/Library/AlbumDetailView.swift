import SwiftUI

/// The header shown above an album's tracks: cover, title, artist, and details.
struct AlbumDetailView: View {
    var album: AlbumGroup
    var tracks: [Track]
    var skin: Skin
    var onBack: () -> Void
    var onPlay: () -> Void
    var onShuffle: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ArtworkView(path: album.artworkFilePath, size: 132, skin: skin, placeholder: "opticaldisc")
                .clipShape(Rectangle())
                .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Glyph("chevron.left", size: 9)
                        Text("Back").font(AppFont.ui(11, weight: .medium))
                    }
                    .foregroundStyle(skin.textTertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer(minLength: 2)

                Text("Album")
                    .font(AppFont.ui(9, weight: .bold))
                    .foregroundStyle(skin.accent)
                Text(album.title)
                    .font(AppFont.ui(20, weight: .bold))
                    .foregroundStyle(skin.textPrimary)
                    .lineLimit(2)
                Text(album.artist.isEmpty ? "Unknown Artist" : album.artist)
                    .font(AppFont.ui(13, weight: .medium))
                    .foregroundStyle(skin.textSecondary)
                    .lineLimit(1)
                Text(details)
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
                    .lineLimit(1)
                    .padding(.top, 1)

                HStack(spacing: 8) {
                    HeaderButton(title: "Play", icon: "play.fill", prominent: true, skin: skin, action: onPlay)
                    HeaderButton(title: "Shuffle", icon: "shuffle", skin: skin, action: onShuffle)
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 132)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.surface(skin.bgRaised))
    }

    private var details: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        let genres = Dictionary(grouping: tracks, by: \.genre).mapValues(\.count)
        if let genre = genres.max(by: { $0.value < $1.value })?.key, genre != "Unknown", !genre.isEmpty {
            parts.append(genre)
        }
        parts.append(tracks.count == 1 ? "1 track" : "\(tracks.count) tracks")
        parts.append(LibraryHeaderView.longDuration(album.duration))
        if let sample = tracks.first {
            parts.append(sample.isLossless ? "\(sample.fileFormat) \(sample.bitDepth)/\(Track.format(sampleRate: sample.sampleRate))" : sample.fileFormat)
        }
        return parts.joined(separator: "  ·  ")
    }
}
