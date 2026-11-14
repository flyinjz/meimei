import SwiftUI

/// The cover-art panel. The art is the largest square that fits the
/// panel's width and height (up to `artworkSize`), so the panel can sit in
/// any column and be resized like the others.
struct NowPlayingPanelView: View {
    @ObservedObject var player: PlayerController
    @ObservedObject private var library = AppSession.shared.library
    var skin: Skin
    var artworkSize: CGFloat
    var showFormatStrip = true
    var showSubtitle = true

    private var track: Track? { player.currentTrack }

    var body: some View {
        panel.appContextMenu { track.map { MenuContent.track($0) } ?? MenuContent(entries: []) }
    }

    private var panel: some View {
        ArtworkFitLayout(maxSide: min(artworkSize - 24, Self.maxArtwork)) {
            GeometryReader { geo in
                ArtworkView(path: track?.artworkFilePath, size: max(1, geo.size.width), skin: skin, placeholder: "waveform")
            }
                .clipShape(Rectangle())
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let track { library.albumKey = track.albumKey }
                }
                .help(track == nil ? "" : "Show album")

            VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Nothing playing")
                        .textRole(.nowPlayingTitle, size: 13, weight: .semibold, color: skin.textPrimary)
                        .lineLimit(1)
                    Text(track?.artist ?? "Pick something from your library")
                        .textRole(.nowPlayingArtist, size: 11.5, color: skin.textSecondary)
                        .lineLimit(1)
                    if showSubtitle, let subtitle {
                        Text(subtitle)
                            .textRole(.nowPlayingDetails, size: 10.5, color: skin.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let track {
                    LikeButton(liked: track.liked, skin: skin) {
                        library.setLiked([track.id], !track.liked)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, showFormatStrip ? 6 : 10)

            if showFormatStrip, let track {
                FormatStrip(track: track, skin: skin)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            }
        }
    }

    /// Past this the cover only gets blurrier and pushes everything else away.
    static let maxArtwork: CGFloat = 520

    private var subtitle: String? {
        guard let track else { return nil }
        let parts = [track.album, track.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Codec and resolution as one quiet line; Hi-Res in the accent.
private struct FormatStrip: View {
    var track: Track
    var skin: Skin

    var body: some View {
        HStack(spacing: 6) {
            Text(details)
                .foregroundStyle(skin.textTertiary)
            if track.isHiRes {
                HStack(spacing: 3) {
                    Glyph("badge.hires", size: 8)
                    Text("Hi-Res")
                }
                .foregroundStyle(skin.accent.opacity(0.75))
            }
            Spacer(minLength: 0)
            if track.playCount > 0 {
                Text(track.playCount == 1 ? "1 play" : "\(track.playCount) plays")
                    .foregroundStyle(skin.textTertiary)
            }
        }
        .textRole(.nowPlayingDetails, size: 10.5, weight: .medium, color: skin.textTertiary)
        .lineLimit(1)
    }

    private var details: String {
        if track.isLossless {
            return "\(track.fileFormat) · \(track.bitDepth)-bit · \(Track.format(sampleRate: track.sampleRate))"
        }
        return track.estimatedBitrateKbps > 0 ? "\(track.fileFormat) · \(track.estimatedBitrateKbps) kbps" : track.fileFormat
    }
}

struct LikeButton: View {
    var liked: Bool
    var skin: Skin
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(liked ? "heart.fill" : "heart", size: 12)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(GlyphButtonStyle(skin: skin, isActive: liked))
        .foregroundStyle(liked ? skin.accent : skin.textTertiary)
        .help(liked ? "Unlike" : "Like")
    }
}

/// Lays out the cover over the details: the cover is the largest square
/// that fits the width and leaves room for the details below; any spare
/// height goes under the details.
private struct ArtworkFitLayout: Layout {
    var maxSide: CGFloat
    var padding: CGFloat = 12

    private func side(width: CGFloat, height: CGFloat?, info: CGFloat) -> CGFloat {
        var side = min(width - padding * 2, maxSide)
        if let height, height.isFinite { side = min(side, height - padding - info) }
        return max(48, side.rounded(.down))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.map { $0.isFinite ? $0 : 260 } ?? 260
        let info = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        if let h = proposal.height, h.isFinite { return CGSize(width: width, height: h) }
        return CGSize(width: width, height: padding + side(width: width, height: nil, info: info) + info)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let info = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let s = side(width: bounds.width, height: bounds.height, info: info)
        subviews[0].place(at: CGPoint(x: bounds.midX - s / 2, y: bounds.minY + padding),
                          proposal: ProposedViewSize(width: s, height: s))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + padding + s),
                          proposal: ProposedViewSize(width: bounds.width, height: info))
    }
}
