import SwiftUI
import AppKit

/// Reviews tracks and albums that look like duplicates. Removal only
/// affects the library; files on disk are never touched.
struct DuplicateReviewView: View {
    @ObservedObject var library: LibraryStore
    var skin: Skin
    var onDismiss: () -> Void

    @State private var keep: Set<UUID> = []

    private var groupCount: Int { library.pendingDuplicates.count }
    private var copyCount: Int { library.pendingDuplicates.reduce(0) { $0 + $1.tracks.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline(color: skin.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your library has the same song or album more than once, and every copy's file is still on disk. Tick the copies to keep; the rest leave the library. No files are deleted. Copies whose files are gone are handled in Library → Missing, not here.")
                        .font(AppFont.ui(11.5))
                        .foregroundStyle(skin.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(library.pendingDuplicates) { group in
                        groupCard(group)
                    }
                }
                .padding(18)
            }
            Hairline(color: skin.hairline)
            footer
        }
        .frame(width: 620, height: 540)
        .glassSheet(skin)
        .preferredColorScheme(.dark)
        .onAppear {
            var initial: Set<UUID> = []
            for group in library.pendingDuplicates {
                if let first = group.tracks.first { initial.insert(first.id) }
            }
            keep = initial
        }
    }

    private var header: some View {
        DialogHeader(
            title: "The same music is in your library more than once",
            subtitle: "\(groupCount) song\(groupCount == 1 ? "" : "s") or album\(groupCount == 1 ? "" : "s") with extra copies · \(copyCount) files in all",
            skin: skin
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            DialogButton(title: "Keep Every Copy", skin: skin) {
                library.dismissDuplicatesKeepingAll()
                onDismiss()
            }
            Spacer()
            DialogButton(title: "Ask Later", skin: skin) {
                library.deferDuplicates()
                onDismiss()
            }
            DialogButton(title: "Keep Ticked, Remove Rest", prominent: true, enabled: !keep.isEmpty, skin: skin) {
                library.resolveDuplicates(keeping: keep)
                onDismiss()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(skin.bgRaised)
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(group.kind == .albums ? "Album" : "TRACK")
                    .font(AppFont.ui(9, weight: .semibold))
                    .foregroundStyle(skin.textTertiary)
                Text(group.title)
                    .font(AppFont.ui(12.5, weight: .semibold))
                    .foregroundStyle(skin.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(group.subtitle)
                    .font(AppFont.ui(11))
                    .foregroundStyle(skin.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(skin.bgVoid.opacity(0.35))

            ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                if index > 0 { Hairline(color: skin.hairline) }
                row(track, in: group)
            }
        }
        .clipShape(Rectangle())
        .overlay(
            Rectangle()
                .strokeBorder(skin.hairline, lineWidth: 1)
        )
    }

    private func row(_ track: Track, in group: DuplicateGroup) -> some View {
        let selected = keep.contains(track.id)
        return Button {
            toggle(track.id, in: group)
        } label: {
            HStack(spacing: 10) {
                Glyph(selected ? "checkmark.circle.fill" : "circle", size: 14)
                    .foregroundStyle(selected ? skin.accent : skin.textTertiary)

                ArtworkView(path: track.artworkFilePath, size: 32, skin: skin)
                    .clipShape(Rectangle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(AppFont.ui(12.5))
                        .foregroundStyle(skin.textPrimary)
                        .lineLimit(1)
                    Text(location(for: track))
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(track.fileFormat)
                        .font(AppFont.ui(10.5, weight: .medium))
                        .foregroundStyle(skin.textSecondary)
                    Text(track.formattedDuration)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Rectangle().fill(selected ? skin.hover.opacity(0.55) : Color.clear))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    private func location(for track: Track) -> String {
        let folder = track.url.deletingLastPathComponent().lastPathComponent
        return "\(folder)/\(track.url.lastPathComponent)"
    }

    private func toggle(_ id: UUID, in group: DuplicateGroup) {
        if keep.contains(id) {
            let others = group.tracks.map(\.id).filter { $0 != id }
            if others.contains(where: { keep.contains($0) }) {
                keep.remove(id)
            }
        } else {
            keep.insert(id)
        }
    }
}
