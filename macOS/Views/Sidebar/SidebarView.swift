import SwiftUI

/// The browse list under the now-playing art: the library views, then genres.
/// Playlists live in the collection rail on the right.
struct SidebarView: View {
    @ObservedObject var library: LibraryStore
    var skin: Skin
    var density: LayoutDensity = .comfortable

    @AppStorage("meimei.sidebar.genresExpanded") private var genresExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                SidebarSection(title: "Library", skin: skin)
                row(.all, "All Music", icon: "music.note", count: library.tracks.count)
                row(.albums, "Albums", icon: "square.stack", filled: "square.stack.fill", count: library.albumGroups.count)
                row(.artists, "Artists", icon: "music.mic", count: library.artistGroups.count)
                row(.liked, "Liked Songs", icon: "heart", filled: "heart.fill", count: library.likedCount)

                SidebarSection(title: "Collections", skin: skin)
                row(.recentlyAdded, "Recently Added", icon: "clock.badge.checkmark", count: nil)
                row(.recentlyPlayed, "Recently Played", icon: "clock.arrow.circlepath", count: nil)
                row(.mostPlayed, "Most Played", icon: "chart.bar", filled: "chart.bar.fill", count: nil)

                if !library.genres.isEmpty {
                    SidebarSection(title: "Genres", skin: skin, trailing: AnyView(
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { genresExpanded.toggle() }
                        } label: {
                            Glyph("chevron.right", size: 9)
                                .rotationEffect(.degrees(genresExpanded ? 90 : 0))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(GlyphButtonStyle(skin: skin, restColor: skin.textTertiary))
                        .help(genresExpanded ? "Hide genres" : "Show genres")
                    ))
                    if genresExpanded || isGenreSelected {
                        ForEach(library.genres) { node in
                            if genresExpanded || library.source == .genre(node.name) {
                                row(.genre(node.name), node.name.isEmpty ? "No Genre" : node.name, icon: "guitars", count: node.count)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var isGenreSelected: Bool {
        if case .genre = library.source { return true }
        return false
    }

    private func row(_ source: LibrarySource, _ title: String, icon: String?, filled: String? = nil, count: Int?) -> some View {
        SidebarRow(
            title: title,
            icon: icon,
            selectedIcon: filled,
            count: count,
            selected: library.source == source && library.albumKey == nil,
            skin: skin,
            density: density
        ) {
            library.source = source
            library.albumKey = nil
        }
    }
}

struct SidebarSection: View {
    var title: String
    var skin: Skin
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title.lowercased())
                .textRole(.sectionLabels, size: 11, weight: .medium, color: skin.textTertiary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// One selectable row in the sidebar or collection rail.
struct SidebarRow: View {
    var title: String
    var icon: String?
    var selectedIcon: String? = nil
    var count: Int?
    var selected: Bool
    var skin: Skin
    var density: LayoutDensity = .comfortable
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Glyph(selected ? (selectedIcon ?? icon) : icon, size: 10.5)
                        .foregroundStyle(selected ? skin.accent : skin.textTertiary)
                        .frame(width: 14)
                }
                Text(title)
                    .textRole(.sidebarRows, size: density.rowFontSize + 0.5, weight: selected ? .semibold : .regular,
                              color: selected ? skin.textPrimary : skin.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(AppFont.ui(density.rowFontSize - 1))
                        .foregroundStyle(skin.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: max(26, density.rowHeight + 6))
            .background(
                Rectangle()
                    .fill(selected ? skin.selection.opacity(0.55) : (hovering ? skin.hover : .clear))
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
