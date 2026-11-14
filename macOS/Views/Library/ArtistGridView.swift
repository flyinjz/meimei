import SwiftUI

/// An artist's round portrait (their first cover), for the artist page's header.
struct ArtistAvatar: View {
    var name: String
    var path: String?
    var size: CGFloat
    var skin: Skin

    var body: some View {
        Group {
            if path != nil {
                ArtworkView(path: path, size: size, skin: skin, placeholder: "person.fill")
            } else {
                ZStack {
                    LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(initials)
                        .font(AppFont.ui(size * 0.34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Rectangle())
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var tint: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.6)
    }
}

/// The artist page's albums, as a row of covers above their tracks.
struct ArtistAlbumsStrip: View {
    var albums: [AlbumGroup]
    var skin: Skin
    var onOpen: (AlbumGroup) -> Void
    var onPlay: (AlbumGroup) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(albums) { album in
                    StripAlbum(album: album, skin: skin, onOpen: { onOpen(album) }, onPlay: { onPlay(album) })
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    private struct StripAlbum: View {
        let album: AlbumGroup
        let skin: Skin
        let onOpen: () -> Void
        let onPlay: () -> Void
        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                ArtworkView(path: album.artworkFilePath, size: 108, skin: skin, placeholder: "opticaldisc")
                    .clipShape(Rectangle())
                    .overlay(alignment: .bottomTrailing) {
                        if hovering {
                            Button(action: onPlay) {
                                Glyph("play.circle.fill", size: 24)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, skin.accent)
                            }
                            .buttonStyle(PressDipStyle())
                            .padding(6)
                        }
                    }
                    .shadow(color: .black.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 8 : 4, y: 2)
                Text(album.title)
                    .font(AppFont.ui(11, weight: .semibold))
                    .foregroundStyle(skin.textPrimary)
                    .lineLimit(1)
                Text(album.year.map(String.init) ?? "\(album.trackCount) tracks")
                    .font(AppFont.ui(10))
                    .foregroundStyle(skin.textTertiary)
            }
            .frame(width: 108)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        }
    }
}
