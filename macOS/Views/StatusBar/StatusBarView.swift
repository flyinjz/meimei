import SwiftUI

/// The bottom strip: library totals, selection, and import progress.
struct StatusBarView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var player = AppSession.shared.player
    @ObservedObject private var customize = AppSession.shared.customize
    @ObservedObject private var equalizer = AppSession.shared.player.equalizer
    var visibleCount: Int
    var selectedCount: Int
    var skin: Skin
    var height: CGFloat
    var useMonospaced = true
    var showSelectionCount = true
    var showScanProgress = true

    var body: some View {
        HStack(spacing: 12) {
            stat("\(library.tracks.count) tracks", skin.textSecondary)
            divider
            stat(LibraryHeaderView.longDuration(library.totalDuration), skin.textSecondary)
            divider
            stat("\(visibleCount) shown", skin.textTertiary)
            if showSelectionCount && selectedCount > 0 {
                divider
                stat("\(selectedCount) selected", skin.accent)
            }
            if showScanProgress, let scan = library.scan {
                divider
                CapsuleProgress(fraction: scan.total == 0 ? nil : Double(scan.completed) / Double(scan.total), skin: skin)
                    .frame(width: 80, height: 4)
                stat(scan.total == 0 ? "Looking in \(scan.label)…" : "Importing \(scan.completed) of \(scan.total)", skin.accent)
            }
            Spacer(minLength: 8)
            if player.stopAfterCurrent {
                badge("stop.circle", "Stops after this track") { player.stopAfterCurrent = false }
            }
            if let deadline = player.sleepDeadline {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    badge("moon.zzz", "Sleep in \(max(1, Int(deadline.timeIntervalSinceNow / 60 + 0.5))) min") {
                        player.setSleepTimer(minutes: nil)
                    }
                }
            }
            if equalizer.data.enabled {
                badge("slider.vertical.3", "EQ · \(equalizer.activeProfileName)") {
                    WindowRequest.equalizer.post()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: CGFloat(customize.style(.statusBar).height ?? Double(height)))
        .panelSurface(.statusBar, skin: skin, fallback: skin.bgPanel)
    }

    /// A small capsule status chip; clicking it acts on the status.
    private func badge(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Glyph(icon, size: 9)
                Text("[" + text + "]").font(AppFont.ui(10.5, weight: .medium))
            }
            .foregroundStyle(skin.accent)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Rectangle().fill(skin.accent.opacity(0.14)))
        }
        .buttonStyle(PressDipStyle())
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var divider: some View {
        Hairline(color: skin.hairline, vertical: true).frame(height: 10)
    }

    private func stat(_ text: String, _ color: Color) -> some View {
        Text(text)
            .textRole(.statusText, size: 10.5, color: color)
            .lineLimit(1)
    }
}
