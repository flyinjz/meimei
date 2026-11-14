import SwiftUI
import UniformTypeIdentifiers

/// The right-hand rail: the local account, settings, and playlists. Drop
/// tracks from the table onto a manual playlist to add them.
struct CollectionRailView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var settings: AppSettings
    var skin: Skin
    var onOpenSettings: () -> Void
    var onCreatePlaylist: () -> Void
    var onEditPlaylist: (UUID) -> Void
    var onPlay: (Playlist) -> Void

    @State private var pendingDelete: Playlist?

    var body: some View {
        VStack(spacing: 0) {
            accountHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarSection(title: "Playlists", skin: skin, trailing: AnyView(
                        Button(action: onCreatePlaylist) {
                            Glyph("plus", size: 10)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(GlyphButtonStyle(skin: skin))
                        .help("New Playlist (⌘N)")
                    ))
                    if library.playlists.isEmpty {
                        Text("No playlists yet")
                            .font(AppFont.ui(11))
                            .foregroundStyle(skin.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    ForEach(library.playlists) { playlist in
                        PlaylistRow(
                            playlist: playlist,
                            count: library.playlistCounts[playlist.id] ?? 0,
                            cover: library.playlistCovers[playlist.id],
                            selected: library.source == .playlist(playlist.id) && library.albumKey == nil,
                            skin: skin,
                            onSelect: {
                                library.source = .playlist(playlist.id)
                                library.albumKey = nil
                            },
                            onDropTracks: { ids in library.addTracks(ids, toPlaylist: playlist.id) }
                        )
                        .appContextMenu {
                            MenuContent(title: playlist.name,
                                        subtitle: playlist.isSmart ? "smart playlist" : "\(playlist.trackIDs.count) tracks",
                                        [
                                            MenuGroup(nil, [
                                                .action("Play", glyph: "play.fill") { onPlay(playlist) },
                                                .action(playlist.isSmart ? "Edit Rules…" : "Rename…",
                                                        glyph: playlist.isSmart ? "slider.horizontal.3" : "text.alignleft") { onEditPlaylist(playlist.id) },
                                            ]),
                                            MenuGroup(nil, [
                                                .action("Delete Playlist…", glyph: "trash", destructive: true) { pendingDelete = playlist },
                                            ]),
                                        ])
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .background(skin.surface(skin.bgPanel))
        .sheet(item: $pendingDelete) { playlist in
            ConfirmDialog(
                title: "Delete \u{201C}\(playlist.name)\u{201D}?",
                message: "Only the playlist is deleted. Its tracks stay in your library.",
                confirmTitle: "Delete",
                skin: skin,
                onConfirm: {
                    library.removePlaylist(playlist.id)
                    pendingDelete = nil
                },
                onCancel: { pendingDelete = nil }
            )
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 9) {
            Button {
                library.albumKey = nil
                library.source = .profile
            } label: {
                HStack(spacing: 9) {
                    Glyph("person.crop.circle", size: 20)
                        .foregroundStyle(skin.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AccountName.display(settings))
                            .font(AppFont.ui(12, weight: .semibold))
                            .foregroundStyle(skin.textPrimary)
                            .lineLimit(1)
                        Text("\(library.tracks.count) tracks · \(library.albumGroups.count) albums")
                            .font(AppFont.ui(10))
                            .foregroundStyle(skin.textTertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Your profile")

            Spacer(minLength: 4)

            TransportButton(icon: "gearshape", size: 26, iconSize: 12, help: "Settings (⌘,)", skin: skin, action: onOpenSettings)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

}

private struct PlaylistRow: View {
    var playlist: Playlist
    var count: Int
    var cover: String?
    var selected: Bool
    var skin: Skin
    var onSelect: () -> Void
    var onDropTracks: ([UUID]) -> Void

    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    if cover != nil {
                        ArtworkView(path: cover, size: 32, skin: skin)
                    } else {
                        skin.bgVoid
                        Glyph(playlist.isSmart ? "gearshape" : "music.note.list", size: 11)
                            .foregroundStyle(skin.textTertiary)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(Rectangle())
                .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .textRole(.railRows, size: 12, weight: selected ? .semibold : .regular, color: skin.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(AppFont.ui(10))
                        .foregroundStyle(skin.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Rectangle()
                    .fill(selected ? skin.selection.opacity(0.55) : (hovering ? skin.hover : .clear))
            )
            .overlay(
                Rectangle()
                    .strokeBorder(dropTargeted ? skin.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDrop(of: [.plainText], isTargeted: playlist.isSmart ? nil : $dropTargeted) { providers in
            guard !playlist.isSmart else { return false }
            loadTrackIDs(from: providers, then: onDropTracks)
            return true
        }
    }

    private var detail: String {
        let songs = count == 1 ? "1 song" : "\(count) songs"
        return playlist.isSmart ? "Smart · \(songs)" : songs
    }
}

/// Collects dragged track ids (see `TrackDrag`) from drop providers.
func loadTrackIDs(from providers: [NSItemProvider], then deliver: @escaping ([UUID]) -> Void) {
    let group = DispatchGroup()
    let ids = LockedValue<[(Int, UUID)]>([])
    for (index, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String, let id = TrackDrag.decode(string) {
                ids.mutate { $0.append((index, id)) }
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        deliver(ids.value.sorted { $0.0 < $1.0 }.map(\.1))
    }
}
