import AppKit
import SwiftUI

/// Lyrics for the playing track. Synced `.lrc` lines highlight and scroll
/// with playback (click a line to jump there); plain lyrics are shown as text.
struct LyricsPanelView: View {
    @ObservedObject var player: PlayerController
    let clock: PlaybackClock
    @ObservedObject var lyrics: LyricsStore
    var skin: Skin
    @ObservedObject private var customize = AppSession.shared.customize

    /// The line the clock says is playing.
    @State private var current: Int?
    /// Customize mode: plain lines' frames.
    @State private var plainLineFrames: [Int: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if lyrics.lines.isEmpty {
                emptyState
            } else if lyrics.isSynced {
                SyncedLyricsView(player: player, lyrics: lyrics, skin: skin, current: $current)
            } else {
                plainLines
            }
        }
        .background(skin.surface(skin.bgPanel))
        .background(CurrentLineWatcher(clock: clock, lyrics: lyrics, current: $current))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("lyrics")
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(skin.textTertiary)
            Spacer()
            if !lyrics.sourceLabel.isEmpty {
                Text(lyrics.isSynced ? "[synced]" : "[plain]")
                    .font(AppFont.ui(9.5, weight: .medium))
                    .foregroundStyle(lyrics.isSynced ? skin.accent : skin.textTertiary)
                    .help(lyrics.sourceLabel)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Glyph("quote.bubble", size: 24)
                .foregroundStyle(skin.accent.opacity(0.8))
            Text(player.currentTrack == nil ? "Nothing playing" : "No lyrics for this track")
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(skin.textSecondary)
            if let track = player.currentTrack {
                Button {
                    LibraryNavigator.shared.open(section: "metadata", metadataMode: "lyrics", trackID: track.id)
                } label: { Label("Search for Lyrics", glyph: "magnifyingglass") }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                .help("Look this song up on lrclib.net (opens Library → Metadata → Lyrics)")
                Text("Or put a matching .lrc next to the audio file.")
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var plainLines: some View {
        plainScroll.appContextMenu {
            MenuContent(entries: [
                .action("Copy All Lyrics", glyph: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lyrics.lines.map(\.text).joined(separator: "\n"), forType: .string)
                },
            ] + (player.currentTrack.map { track in [
                .action("Find Synced Lyrics…", glyph: "magnifyingglass") {
                    LibraryNavigator.shared.open(section: "metadata", metadataMode: "lyrics", trackID: track.id)
                },
            ] } ?? []))
        }
    }

    private var plainScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(lyrics.lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .textRole(.lyricsText, size: 12.5, color: skin.textSecondary, reportsFrame: false)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: PlainLineKey.self,
                                                   value: customize.isActive ? [line.id: g.frame(in: .named(customizeSpace))] : [:])
                        })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .onPreferenceChange(PlainLineKey.self) { plainLineFrames = $0 }
        // Customize mode: an outline per line, cut off where the panel ends.
        .background(GeometryReader { g in
            let view = g.frame(in: .named(customizeSpace))
            Color.clear.preference(key: CustomFramesKey.self, value: customize.isActive ? [.lyricsText: lyrics.lines.compactMap { line in
                guard let r = plainLineFrames[line.id]?.insetBy(dx: -3, dy: -2).intersection(view), !r.isNull, r.width > 1, r.height > 1 else { return nil }
                return r
            }] : [:])
        })
    }
}

/// Synced lyrics. Instead of a ScrollView (whose animated `scrollTo` stutters
/// on macOS), every line sits in one stack that is moved with a single offset,
/// so the motion is composited and stays at display rate.
///
/// Two motions:
/// - playback advancing: a slow, critically damped glide; lines settle one
///   after another, outward from the new line;
/// - clicking a line: a quick spring that moves everything together, plus a
///   short press on the clicked line.
private struct SyncedLyricsView: View {
    @ObservedObject var player: PlayerController
    @ObservedObject var lyrics: LyricsStore
    var skin: Skin
    @Binding var current: Int?

    private enum Motion { case glide, jump }

    /// The line drawn as active. Follows `current`, but carries the motion it arrived with.
    @State private var displayed: Int?
    @State private var motion: Motion = .glide
    @State private var hovered: Int?
    @State private var pressed: Int?
    /// After a click, ignore stale clock values for a moment so the highlight doesn't bounce back.
    @State private var hold: (line: Int, until: Date)?
    /// Line frames in the stack's own coordinates, measured once per layout.
    @State private var frames: [Int: CGRect] = [:]
    /// Customize mode: each line's text size, for its outline.
    @State private var textSizes: [Int: CGSize] = [:]
    /// Manual scrolling on top of the follow offset; springs back to 0 when idle.
    @State private var browseOffset: CGFloat = 0
    @State private var browseReset: DispatchWorkItem?
    @State private var viewport: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var customize = AppSession.shared.customize

    private static let glide = Animation.spring(response: 0.75, dampingFraction: 1)
    private static let jump = Animation.spring(response: 0.42, dampingFraction: 0.86)
    private static let anchor: CGFloat = 0.38

    var body: some View {
        GeometryReader { geo in
            stack
                .offset(y: offset(viewport: geo.size.height))
                .animation(stackAnimation, value: displayed)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .background(ScrollWheelCatcher { delta, precise in browse(by: delta, precise: precise, viewport: geo.size.height) })
                .background(Color.clear.preference(key: CustomFramesKey.self,
                                                   value: customize.isActive ? [.lyricsText: outline(geo)] : [:]))
                .onAppear { viewport = geo.size.height }
                .onChange(of: geo.size.height) { viewport = $0 }
        }
        .clipped()
        .mask(edgeFade)
        .appContextMenu { menu }
        .onAppear { displayed = current }
        .onChange(of: current) { advance(to: $0) }
        .onChange(of: lyrics.lines) { _ in frames = [:]; browseOffset = 0 }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lyrics.lines) { line in
                lineView(line)
            }
        }
        .padding(.horizontal, 16)
        .coordinateSpace(name: "lyrics")
        .onPreferenceChange(LineFrameKey.self) { frames = $0 }
        .onPreferenceChange(LineTextSizeKey.self) { textSizes = $0 }
    }

    private func lineView(_ line: LyricLine) -> some View {
        let isCurrent = line.id == displayed
        let isPast = displayed.map { line.id < $0 } ?? false
        let isHovered = hovered == line.id && !isCurrent
        let distance = Double(min(displayed.map { abs(line.id - $0) } ?? 0, 6))
        // Font size and weight never change: that would reflow the text.
        // Emphasis is scale and opacity only, both cheap to animate.
        return Text(line.text.isEmpty ? "♪" : line.text)
            .textRole(.lyricsText, size: 15, weight: .semibold,
                      color: isCurrent || isHovered ? skin.textPrimary : skin.textTertiary, reportsFrame: false)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear.preference(key: LineTextSizeKey.self, value: customize.isActive ? [line.id: g.size] : [:])
            })
            // Hover and click only on the text's own box, not the full row width,
            // and never on lines moved outside the panel: the stack is offset, and
            // SwiftUI still hit-tests content that clipping hides, which let lines
            // above or below the panel catch clicks meant for the player bar.
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
            }
            .onTapGesture { jump(to: line) }
            .allowsHitTesting(isVisible(line.id))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.preference(key: LineFrameKey.self, value: [line.id: g.frame(in: .named("lyrics"))])
            })
            .scaleEffect((isCurrent ? 1 : 0.9) * (pressed == line.id ? 0.97 : 1), anchor: .leading)
            .opacity(isCurrent ? 1 : isHovered ? 0.85 : max(0.28, (isPast ? 0.62 : 0.78) - distance * 0.07))
            .animation(lineAnimation(distance: distance), value: displayed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
    }

    // MARK: Menu

    /// Right-click: line actions for the line under the pointer, then the
    /// ones for the whole song.
    private var menu: MenuContent {
        let line = hovered.flatMap { id in lyrics.lines.first { $0.id == id } }
        let offset = lyrics.offset
        let timing = MenuContent(title: "Timing", subtitle: offset == 0 ? "in sync with the file" : String(format: "%+.1f s", offset), entries: [
            .action("Earlier", glyph: "chevron.up", detail: "−0.5 s") { lyrics.offset -= 0.5 },
            .action("Later", glyph: "chevron.down", detail: "+0.5 s") { lyrics.offset += 0.5 },
            .action("Reset", glyph: "arrow.counterclockwise", enabled: offset != 0) { lyrics.offset = 0 },
        ])
        var groups: [MenuGroup] = []
        if let line {
            groups.append(MenuGroup(nil, [
                .action("Play from Here", glyph: "play.fill", detail: Self.time(line.time)) { jump(to: line) },
                .action("Copy Line", glyph: "doc.on.doc") { Self.copy(line.text) },
            ]))
        }
        groups.append(MenuGroup("lyrics", [
            .action("Copy All Lyrics", glyph: "doc.on.doc") { Self.copy(lyrics.lines.map(\.text).joined(separator: "\n")) },
            .submenu("Timing", glyph: "clock.arrow.circlepath", detail: offset == 0 ? nil : String(format: "%+.1f s", offset), timing),
        ] + (player.currentTrack.map { track in [
            .action("Find Other Lyrics…", glyph: "magnifyingglass") {
                LibraryNavigator.shared.open(section: "metadata", metadataMode: "lyrics", trackID: track.id)
            },
        ] } ?? [])))
        return MenuContent(title: line.map { $0.text.isEmpty ? "♪" : $0.text }, subtitle: line == nil ? nil : "line \(line!.id + 1) of \(lyrics.lines.count)", groups)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func time(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Motion

    private var stackAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.2) }
        return motion == .jump ? Self.jump : Self.glide
    }

    private func lineAnimation(distance: Double) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.2) }
        switch motion {
        case .jump: return Self.jump
        // Each line a beat behind its neighbour: the list settles like a wave.
        case .glide: return Self.glide.delay(distance * 0.035)
        }
    }

    private func advance(to line: Int?) {
        if let hold {
            if Date() < hold.until, line != hold.line { return }
            self.hold = nil
        }
        guard line != displayed else { return }
        motion = .glide
        displayed = line
    }

    private func jump(to line: LyricLine) {
        hold = (line.id, Date().addingTimeInterval(0.6))
        browseReset?.cancel()
        motion = .jump
        withAnimation(Self.jump) { browseOffset = 0 }
        displayed = line.id
        current = line.id
        withAnimation(.easeOut(duration: 0.08)) { pressed = line.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(Self.jump) { if pressed == line.id { pressed = nil } }
        }
        player.seek(to: max(0, line.time - lyrics.offset))
    }

    // MARK: Layout

    /// Space between the panel's top and the first line whenever the song is
    /// near its start, so every song opens at the same place.
    private static let topInset: CGFloat = 12

    private func followOffset(viewport: CGFloat) -> CGFloat {
        guard let displayed, let frame = frames[displayed] else { return Self.topInset }
        // Centre the current line on the anchor, but never push the first line
        // further down than the top inset: early lines read from the top.
        return min(viewport * Self.anchor - frame.midY, Self.topInset)
    }

    private func isVisible(_ id: Int) -> Bool {
        guard let frame = frames[id], viewport > 0 else { return false }
        let y = frame.midY + offset(viewport: viewport)
        return y > 0 && y < viewport
    }

    /// Customize mode: an outline for each line of text in view, drawn
    /// around the text as it is shown (other lines are scaled to 90%) and
    /// cut off where the panel ends. Lines scrolled out of the panel have none.
    private func outline(_ geo: GeometryProxy) -> [CGRect] {
        let size = geo.size
        let shift = offset(viewport: size.height)
        let box = CGRect(origin: .zero, size: size)
        let origin = geo.frame(in: .named(customizeSpace)).origin
        return lyrics.lines.compactMap { line in
            guard let row = frames[line.id], let text = textSizes[line.id] else { return nil }
            // Scaled about the row's leading edge, at its middle.
            let s: CGFloat = line.id == displayed ? 1 : 0.9
            let r = CGRect(x: row.minX, y: row.midY + shift - text.height * s / 2, width: text.width * s, height: text.height * s)
                .insetBy(dx: -3, dy: -2)
            let shown = r.intersection(box)
            guard !shown.isNull, shown.width > 1, shown.height > 1 else { return nil }
            return shown.offsetBy(dx: origin.x, dy: origin.y)
        }
    }

    private func offset(viewport: CGFloat) -> CGFloat {
        followOffset(viewport: viewport) + browseOffset
    }

    /// A wheel notch glides to where it used to jump, and quick notches
    /// carry on from the glide's speed; trackpad movement follows the
    /// fingers exactly.
    private static let notchGlide = Animation.spring(response: 0.2, dampingFraction: 1)

    private func browse(by delta: CGFloat, precise: Bool, viewport: CGFloat) {
        let follow = followOffset(viewport: viewport)
        let bottom = frames.values.map(\.midY).max() ?? 0
        // Keep the first and last lines reachable but never scrolled past the anchor.
        let lower = viewport * Self.anchor - bottom - follow
        let upper = Self.topInset - follow
        let next = min(max(browseOffset + delta, lower), upper)
        if precise {
            browseOffset = next
        } else {
            withAnimation(Self.notchGlide) { browseOffset = next }
        }

        browseReset?.cancel()
        let reset = DispatchWorkItem {
            motion = .glide
            withAnimation(Self.glide) { browseOffset = 0 }
        }
        browseReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: reset)
    }

    private var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.06),
            .init(color: .black, location: 0.88),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// Each line's text size as laid out (before the line's scale).
private struct LineTextSizeKey: PreferenceKey {
    static let defaultValue: [Int: CGSize] = [:]
    static func reduce(value: inout [Int: CGSize], nextValue: () -> [Int: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Plain lyrics: each line's text frame in the customize space.
private struct PlainLineKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LineFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Reports scroll-wheel and trackpad deltas over its bounds. A local monitor
/// rather than a responder override, because SwiftUI content sits on top.
private struct ScrollWheelCatcher: NSViewRepresentable {
    /// The distance, and whether it came from a trackpad (precise) or a wheel notch.
    var onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let view = coordinator.view, event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            let precise = event.hasPreciseScrollingDeltas
            coordinator.onScroll(precise ? event.scrollingDeltaY : event.scrollingDeltaY * 12, precise)
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    final class Coordinator {
        var onScroll: (CGFloat, Bool) -> Void
        weak var view: NSView?
        var monitor: Any?
        init(onScroll: @escaping (CGFloat, Bool) -> Void) { self.onScroll = onScroll }
    }
}

/// Follows the clock and updates `current` only when the line changes, so
/// the lyrics list itself doesn't redraw on every tick.
private struct CurrentLineWatcher: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var lyrics: LyricsStore
    @Binding var current: Int?

    var body: some View {
        Color.clear
            .onChange(of: clock.currentTime) { _ in sync() }
            .onChange(of: lyrics.lines) { _ in sync() }
            .onChange(of: lyrics.offset) { _ in sync() }
            .onAppear(perform: sync)
    }

    private func sync() {
        let index = lyrics.currentIndex(at: clock.currentTime)
        if index != current { current = index }
    }
}
