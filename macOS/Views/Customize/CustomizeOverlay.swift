import SwiftUI
import AppKit

/// The overlay and inspector, shown while customizing.
struct CustomizeLayer: View {
    static let space = "meimei.customize.layer"
    var frames: [CustomElement: [CGRect]]
    @ObservedObject var store: CustomizeStore
    @ObservedObject var settings: AppSettings
    var skin: Skin

    var body: some View {
        if store.isActive {
            ZStack(alignment: .topTrailing) {
                CustomizeOverlay(frames: frames, store: store, cursor: store.cursor, settings: settings, skin: skin)
                FadingInspector(fade: store.inspectorFade) {
                    CustomizeInspector(store: store, cursor: store.cursor, settings: settings, skin: skin)
                }
                .padding(.top, 48)
                .padding(.trailing, 14)
            }
            .coordinateSpace(name: Self.space)
            .transition(.opacity)
        }
    }
}

/// The inspector, nearly invisible and click-through while a pane is
/// dragged over or near it, so it never hides a drop target.
private struct FadingInspector<Content: View>: View {
    @ObservedObject var fade: InspectorFade
    @ViewBuilder var content: Content

    var body: some View {
        content
            .opacity(fade.faded ? 0.08 : 1)
            .allowsHitTesting(!fade.faded)
            .onPreferenceChange(InspectorFrameKey.self) { fade.frame = $0 }
    }
}

struct InspectorFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

/// The customize mode's layer over the main window. It takes every click,
/// drag, and hover while active (the app underneath is frozen): picks the
/// smallest element under the pointer, moves panes, and resizes them.
struct CustomizeOverlay: View {
    var frames: [CustomElement: [CGRect]]
    @ObservedObject var store: CustomizeStore
    @ObservedObject var cursor: CustomizeCursor
    @ObservedObject var settings: AppSettings
    var skin: Skin

    @State private var pointer: CGPoint?
    @State private var snap = false
    @State private var resizeStart: CGFloat?
    @State private var paneResize: ResizeState?

    private struct ResizeState {
        var session: PaneResize
        var result: PaneResize.Result
    }
    @State private var move: PaneMove?

    /// A pane (or the player bar) being dragged to a new place.
    private struct PaneMove {
        var element: CustomElement
        var origin: CGRect
        var location: CGPoint
        var target: Target?
    }

    private enum Target: Equatable {
        case pane(DropTarget, indicator: CGRect, label: String)
        case playerBar(PlayerBarPosition, indicator: CGRect)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                veil
                hitLayer(size: geo.size)

                if move == nil, let hovered = cursor.hovered, !cursor.selection.contains(hovered) {
                    MarchingAnts(rects: rects(hovered), color: skin.textPrimary.opacity(0.85))
                    tag(hovered, dim: true)
                }

                ForEach(cursor.selection, id: \.self) { element in
                    ForEach(Array(rects(element).enumerated()), id: \.offset) { _, r in
                        SelectionFrame(color: skin.accent, primary: element == cursor.primary)
                            .frame(width: r.width, height: r.height)
                            .scaleEffect(snap && element == cursor.primary ? 1.025 : 1)
                            .offset(x: r.minX, y: r.minY)
                    }
                    tag(element, dim: element != cursor.primary)
                }
                .allowsHitTesting(false)

                if move == nil, let primary = cursor.primary, cursor.selection.count == 1 {
                    handles(primary)
                }

                if let move { dragFeedback(move) }

                banner
                    .frame(width: geo.size.width)
                    .padding(.top, 8)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(ScrollCatcher { scrollResize($0) })
        .background(CustomizeKeys(store: store, cursor: cursor, settings: settings))
    }

    // MARK: Layers

    /// Dims everything but the selection, so it reads as lifted.
    private var veil: some View {
        Canvas { ctx, size in
            var veil = Path(CGRect(origin: .zero, size: size))
            for e in cursor.selection { for r in rects(e) { veil.addRect(r) } }
            ctx.fill(veil, with: .color(.black.opacity(cursor.selection.isEmpty ? 0.08 : 0.3)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: cursor.selection)
    }

    /// Takes every hover, click, and drag over the window.
    private func hitLayer(size: CGSize) -> some View {
        Color.black.opacity(0.001)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    pointer = p
                    let hit = element(at: p)
                    if hit != cursor.hovered { cursor.hovered = hit }
                } else {
                    pointer = nil
                    cursor.hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 5).onChanged(dragChanged).onEnded(dragEnded))
            .simultaneousGesture(SpatialTapGesture().onEnded { e in
                select(element(at: e.location), extending: NSEvent.modifierFlags.contains(.shift))
            })
    }

    // MARK: Picking

    private func rects(_ element: CustomElement?) -> [CGRect] {
        element.flatMap { frames[$0] }?.filter { $0.width > 1 && $0.height > 1 } ?? []
    }

    /// The smallest element whose frame contains `p`: text inside a panel
    /// wins over the panel.
    private func element(at p: CGPoint, kind: CustomElement.Kind? = nil) -> CustomElement? {
        var best: (CustomElement, CGFloat)?
        for (element, list) in frames where kind == nil || element.kind == kind {
            for r in list where r.contains(p) {
                let area = r.width * r.height
                if best == nil || area < best!.1 { best = (element, area) }
            }
        }
        return best?.0
    }

    private func select(_ element: CustomElement?, extending: Bool) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) {
            cursor.select(element, extending: extending)
            snap = element != nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { snap = false }
        }
    }

    private func tag(_ element: CustomElement, dim: Bool) -> some View {
        Group {
            if let r = rects(element).first {
                let count = rects(element).count
                Text("\(element.label)\(count > 1 ? " ×\(count)" : "")  \(Int(r.width))×\(Int(r.height))")
                    .font(AppFont.ui(10, weight: .medium))
                    .foregroundStyle(dim ? skin.bgVoid : skin.textOnAccent)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(dim ? skin.textPrimary.opacity(0.85) : skin.accent)
                    .fixedSize()
                    .offset(x: r.minX, y: max(0, r.minY - 17))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Moving panes

    private func dragChanged(_ g: DragGesture.Value) {
        if move == nil {
            guard let panel = element(at: g.startLocation, kind: .panel),
                  panel.pane != nil || panel == .playerBar,
                  let origin = rects(panel).first else { return }
            cursor.select(panel)
            move = PaneMove(element: panel, origin: origin, location: g.location)
        }
        guard var m = move else { return }
        m.location = g.location
        m.target = target(for: m, at: g.location)
        move = m
        updateFade(near: g.location, ghost: ghostRect(m))
    }

    private func dragEnded(_ g: DragGesture.Value) {
        let finished = move
        withAnimation(.easeOut(duration: 0.15)) { move = nil }
        updateFade(near: nil)
        guard let finished, let target = finished.target else { return }
        switch target {
        case .pane(let drop, _, _):
            if let pane = finished.element.pane { store.move(pane, to: drop) }
        case .playerBar(let position, _):
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { settings.data.playerBarPosition = position }
        }
    }

    /// Where a drop at `p` would land: a pane's outer quarter makes a new
    /// column beside it; its top or bottom half stacks above or below it.
    private func target(for move: PaneMove, at p: CGPoint) -> Target? {
        if move.element == .playerBar {
            let all = frames.values.flatMap { $0 }
            guard let first = all.first else { return nil }
            let window = all.reduce(first) { $0.union($1) }
            let top = p.y < window.midY
            let position: PlayerBarPosition = top ? .top : .bottom
            guard position != settings.data.playerBarPosition else { return nil }
            let y = top ? window.minY : window.maxY - 4
            return .playerBar(position, indicator: CGRect(x: window.minX, y: y, width: window.width, height: 4))
        }
        guard let dragged = move.element.pane else { return nil }
        let layout = store.layout
        for pane in PaneID.allCases where pane != dragged {
            guard let r = rects(pane.element).first, r.contains(p),
                  let c = layout.columnIndex(of: pane), let i = layout.columns[c].panes.firstIndex(of: pane) else { continue }
            let rx = (p.x - r.minX) / r.width, ry = (p.y - r.minY) / r.height
            let bar: CGFloat = 4
            let drop: DropTarget
            let indicator: CGRect
            let label: String
            if rx < 0.22 {
                drop = .newColumn(index: c)
                indicator = CGRect(x: r.minX - Corners.inset / 2 - bar / 2, y: r.minY, width: bar, height: r.height)
                label = "new column"
            } else if rx > 0.78 {
                drop = .newColumn(index: c + 1)
                indicator = CGRect(x: r.maxX + Corners.inset / 2 - bar / 2, y: r.minY, width: bar, height: r.height)
                label = "new column"
            } else if ry < 0.5 {
                drop = .stack(column: c, index: i)
                indicator = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
                label = "above \(pane.element.label)"
            } else {
                drop = .stack(column: c, index: i + 1)
                indicator = CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
                label = "below \(pane.element.label)"
            }
            var trial = layout
            trial.move(dragged, to: drop)
            guard trial.columns.map(\.panes) != layout.columns.map(\.panes) else { return nil }
            return .pane(drop, indicator: indicator, label: label)
        }
        return nil
    }

    @ViewBuilder
    private func dragFeedback(_ move: PaneMove) -> some View {
        // Where the pane comes from, hatched.
        Hatch(color: skin.accent.opacity(0.35))
            .frame(width: move.origin.width, height: move.origin.height)
            .overlay(Rectangle().strokeBorder(skin.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .offset(x: move.origin.minX, y: move.origin.minY)
            .allowsHitTesting(false)

        if let target = move.target {
            switch target {
            case .pane(_, let indicator, let label):
                let isBar = indicator.width <= 8
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(skin.accent.opacity(isBar ? 1 : 0.16))
                        .overlay(Rectangle().strokeBorder(skin.accent, lineWidth: isBar ? 0 : 1))
                    Text(label)
                        .font(AppFont.ui(10, weight: .medium))
                        .foregroundStyle(skin.textOnAccent)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(skin.accent)
                        .fixedSize()
                        .offset(x: isBar ? 8 : 6, y: 6)
                }
                .frame(width: indicator.width, height: indicator.height, alignment: .topLeading)
                .offset(x: indicator.minX, y: indicator.minY)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: indicator)
            case .playerBar(_, let indicator):
                Rectangle().fill(skin.accent)
                    .frame(width: indicator.width, height: indicator.height)
                    .offset(x: indicator.minX, y: indicator.minY)
                    .allowsHitTesting(false)
            }
        }

        // A ghost of the pane following the pointer.
        let ghost = ghostRect(move)
        let w = ghost.width, h = ghost.height
        VStack(alignment: .leading, spacing: 4) {
            Text(move.element.label).font(AppFont.ui(11, weight: .medium)).foregroundStyle(skin.textPrimary)
            Text("\(Int(move.origin.width))×\(Int(move.origin.height))").font(AppFont.ui(9.5)).foregroundStyle(skin.textTertiary)
        }
        .padding(8)
        .frame(width: w, height: h, alignment: .topLeading)
        .background(Color.black.opacity(0.75))
        .overlay(Rectangle().strokeBorder(skin.accent, lineWidth: 1))
        .fuiCorners(skin)
        .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
        .offset(x: move.location.x - w / 2, y: move.location.y - h / 2)
        .allowsHitTesting(false)
    }

    private func ghostRect(_ move: PaneMove) -> CGRect {
        let scale = min(1, 220 / max(1, move.origin.width), 140 / max(1, move.origin.height))
        let w = move.origin.width * scale, h = move.origin.height * scale
        return CGRect(x: move.location.x - w / 2, y: move.location.y - h / 2, width: w, height: h)
    }

    // MARK: Resizing

    /// Bars resize from their inner edge; panes from any corner or edge
    /// they share with a neighbor.
    private enum HandleKind: Hashable {
        case barHeight(element: CustomElement, edge: Edge)
        case pane(PaneID, horizontal: HorizontalEdge?, vertical: VerticalEdge?)

        var isPane: Bool { if case .pane = self { return true } else { return false } }
    }

    @ViewBuilder
    private func handles(_ element: CustomElement) -> some View {
        if let r = rects(element).first {
            ForEach(handleKinds(element), id: \.self) { kind in
                handle(kind, rect: r)
            }
        }
        if let session = paneResize {
            ForEach(session.result.guides, id: \.self) { guide in
                guideLine(guide)
            }
        }
    }

    private func handleKinds(_ element: CustomElement) -> [HandleKind] {
        switch element {
        case .playerBar:
            return [.barHeight(element: element, edge: settings.data.playerBarPosition == .top ? .bottom : .top)]
        case .statusBar:
            return [.barHeight(element: element, edge: .top)]
        default:
            guard let pane = element.pane else { return [] }
            let edges = PaneResize.movableEdges(of: pane, layout: currentLayout, frames: paneFrames)
            let hs: [HorizontalEdge?] = [nil] + edges.horizontal.map { $0 }
            let vs: [VerticalEdge?] = [nil] + edges.vertical.map { $0 }
            return hs.flatMap { h in vs.compactMap { v in
                h == nil && v == nil ? nil : HandleKind.pane(pane, horizontal: h, vertical: v)
            } }
        }
    }

    /// The layout on screen: the drag's draft while resizing.
    private var currentLayout: PaneLayout { store.draft.layout ?? store.layout }

    private var paneFrames: [PaneID: CGRect] {
        var result: [PaneID: CGRect] = [:]
        for pane in PaneID.allCases { if let r = rects(pane.element).first { result[pane] = r } }
        return result
    }

    private func handle(_ kind: HandleKind, rect r: CGRect) -> some View {
        let (size, center, cursorFor) = handleGeometry(kind, rect: r)
        return Rectangle()
            .fill(skin.accent)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in (inside ? cursorFor() : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(CustomizeLayer.space))
                .onChanged { g in resize(kind, rect: r, g) }
                .onEnded { _ in endResize() })
            .help(kind.isPane ? "Drag to resize · hold ⌘ to turn off snapping" : "Drag to resize")
            .offset(x: center.x - size.width / 2, y: center.y - size.height / 2)
    }

    private func handleGeometry(_ kind: HandleKind, rect r: CGRect) -> (CGSize, CGPoint, () -> NSCursor) {
        switch kind {
        case .barHeight(_, let edge):
            let y = edge == .bottom ? r.maxY : r.minY
            return (CGSize(width: min(56, r.width - 8), height: 6), CGPoint(x: r.midX, y: y), { .resizeUpDown })
        case .pane(_, let h, let v):
            let x: CGFloat = h == .leading ? r.minX : h == .trailing ? r.maxX : r.midX
            let y: CGFloat = v == .top ? r.minY : v == .bottom ? r.maxY : r.midY
            let size: CGSize
            switch (h, v) {
            case (.some, .some): size = CGSize(width: 9, height: 9)
            case (.some, nil): size = CGSize(width: 6, height: min(40, r.height - 24))
            default: size = CGSize(width: min(40, r.width - 24), height: 6)
            }
            return (size, CGPoint(x: x, y: y), { Self.cursor(h, v) })
        }
    }

    private static func cursor(_ h: HorizontalEdge?, _ v: VerticalEdge?) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch (h, v) {
            case (.leading?, .top?): position = .topLeft
            case (.trailing?, .top?): position = .topRight
            case (.leading?, .bottom?): position = .bottomLeft
            case (.trailing?, .bottom?): position = .bottomRight
            case (.leading?, nil): position = .left
            case (.trailing?, nil): position = .right
            case (nil, .top?): position = .top
            default: position = .bottom
            }
            return .frameResize(position: position, directions: .all)
        }
        if h != nil && v != nil { return .crosshair }
        return h != nil ? .resizeLeftRight : .resizeUpDown
    }

    private func resize(_ kind: HandleKind, rect r: CGRect, _ g: DragGesture.Value) {
        switch kind {
        case .barHeight(let element, let edge):
            if resizeStart == nil { resizeStart = r.height }
            guard let start = resizeStart else { return }
            let h = edge == .bottom ? start + g.translation.height : start - g.translation.height
            let range: ClosedRange<Double> = element == .statusBar ? 20...48 : 40...140
            store.edit(element, coalesce: "height") { $0.height = range.clamp(Double(h)) }
        case .pane(let pane, let h, let v):
            if paneResize == nil {
                let session = PaneResize(pane: pane, horizontal: h, vertical: v, frames: paneFrames,
                                         layout: store.layout, gap: Corners.inset)
                paneResize = ResizeState(session: session, result: session.apply(.zero))
            }
            guard var state = paneResize else { return }
            let free = NSEvent.modifierFlags.contains(.command)
            state.result = state.session.apply(g.translation, snapping: !free)
            paneResize = state
            store.draft.layout = state.result.layout
        }
        updateFade(near: g.location)
    }

    private func endResize() {
        resizeStart = nil
        if let state = paneResize {
            store.commitLayout(state.result.layout)
            store.draft.layout = nil
        }
        paneResize = nil
        updateFade(near: nil)
    }

    /// A magnetic guide: a thin accent line across the window where the
    /// dragged edge snapped.
    private func guideLine(_ guide: PaneResize.Guide) -> some View {
        GeometryReader { geo in
            Path { p in
                if guide.axis == .y {
                    p.move(to: CGPoint(x: 0, y: guide.position)); p.addLine(to: CGPoint(x: geo.size.width, y: guide.position))
                } else {
                    p.move(to: CGPoint(x: guide.position, y: 0)); p.addLine(to: CGPoint(x: guide.position, y: geo.size.height))
                }
            }
            .stroke(skin.accent, style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Fades the inspector while a drag passes over or near it.
    private func updateFade(near p: CGPoint?, ghost: CGRect? = nil) {
        let fade = store.inspectorFade
        let zone = fade.frame.insetBy(dx: -40, dy: -40)
        let near = !fade.frame.isNull && (p.map { zone.contains($0) } ?? false || ghost.map { zone.intersects($0) } ?? false)
        if fade.faded != near {
            withAnimation(.easeOut(duration: near ? 0.12 : 0.25)) { fade.faded = near }
        }
    }

    /// Scrolling over selected text resizes it. Anywhere else the scroll
    /// passes through, so the inspector scrolls normally.
    private func scrollResize(_ delta: Double) -> Bool {
        guard let p = pointer, cursor.primary?.kind == .text,
              cursor.targets.contains(where: { e in rects(e).contains { $0.insetBy(dx: -10, dy: -10).contains(p) } }) else { return false }
        store.edit(cursor.targets, coalesce: "size") { s in
            s.sizeScale = min(2.5, max(0.6, (s.sizeScale ?? 1) * pow(1.003, delta)))
        }
        return true
    }

    // MARK: Banner

    private var banner: some View {
        HStack(spacing: 10) {
            Glyph("paintbrush.pointed", size: 12).foregroundStyle(skin.accent)
            Text(store.peekOriginal ? "original design" : "customize")
                .foregroundStyle(store.peekOriginal ? skin.accent : skin.textPrimary)
            Text(hint)
                .foregroundStyle(skin.textTertiary)
                .lineLimit(1)
            Button("Done") { store.isActive = false }
                .buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
        }
        .font(AppFont.ui(11))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(Color.black.opacity(0.85))
        .overlay(Rectangle().strokeBorder(skin.accent.opacity(0.7), lineWidth: 1))
        .fuiCorners(skin)
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: store.peekOriginal)
    }

    private var hint: String {
        if store.peekOriginal { return "release ⌥ to return" }
        if move != nil { return "drop on a pane's edge for a new column, its top or bottom half to stack" }
        if cursor.selection.count > 1 { return "\(cursor.selection.count) selected · edits apply to all · ⌘C ⌘V copy style" }
        if cursor.primary?.kind == .text { return "scroll to size · ↑↓ nudge · ⇧-click adds · hold ⌥ to compare" }
        if cursor.primary != nil { return "drag to move · corners resize and snap (⌘ for free) · hold ⌥ to compare" }
        return "click to select · drag a panel to move it · ⇧-click adds · esc to finish"
    }
}

/// Dashed outlines whose dashes crawl, on every instance of the hovered
/// element. Animates only while something is hovered.
private struct MarchingAnts: View {
    var rects: [CGRect]
    var color: Color

    var body: some View {
        TimelineView(.animation) { t in
            Canvas { ctx, _ in
                let phase = CGFloat(t.date.timeIntervalSinceReferenceDate * 24).truncatingRemainder(dividingBy: 8)
                var path = Path()
                for r in rects { path.addRect(r.insetBy(dx: 0.5, dy: 0.5)) }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: -phase))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A selected element's frame: an accent outline with square corner marks;
/// thinner and unmarked for secondary selections.
private struct SelectionFrame: View {
    var color: Color
    var primary: Bool

    var body: some View {
        Canvas { ctx, size in
            let lw: CGFloat = primary ? 1.5 : 1
            ctx.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: lw / 2, dy: lw / 2)),
                       with: .color(color.opacity(primary ? 1 : 0.7)), lineWidth: lw)
            guard primary else { return }
            let m: CGFloat = 5
            for (x, y) in [(0.0, 0.0), (size.width, 0), (0, size.height), (size.width, size.height)] {
                ctx.fill(Path(CGRect(x: x - m / 2, y: y - m / 2, width: m, height: m)), with: .color(color))
            }
        }
    }
}

/// Diagonal hatching, for where a moved pane comes from.
private struct Hatch: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 8
            }
            ctx.stroke(p, with: .color(color), lineWidth: 1)
        }
        .clipped()
    }
}

/// Keys while customizing: Esc deselects then finishes, Tab cycles,
/// ⌘Z / ⇧⌘Z undo and redo, ⌫ resets, ⌘C / ⌘V copy and paste a style,
/// arrows nudge size, and holding ⌥ shows the original design.
private struct CustomizeKeys: NSViewRepresentable {
    let store: CustomizeStore
    let cursor: CustomizeCursor
    let settings: AppSettings

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.store = store
        v.cursor = cursor
        v.settings = settings
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyView: NSView {
        weak var store: CustomizeStore?
        weak var cursor: CustomizeCursor?
        weak var settings: AppSettings?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, let store = self.store, let cursor = self.cursor, let settings = self.settings,
                      event.window === self.window else { return event }
                let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let isFlags = event.type == .flagsChanged
                if !isFlags, event.window?.firstResponder is NSText { return event }
                let key = isFlags ? 0 : event.keyCode
                let chars = isFlags ? "" : (event.charactersIgnoringModifiers?.lowercased() ?? "")
                let handled = MainActor.assumeIsolated { () -> Bool in
                    if isFlags {
                        let peek = mods == .option
                        if store.peekOriginal != peek { store.peekOriginal = peek }
                        return false
                    }
                    return Self.handle(key: key, chars: chars, mods: mods, store: store, cursor: cursor, settings: settings)
                }
                return handled ? nil : event
            }
        }

        @MainActor
        private static func handle(key: UInt16, chars: String, mods: NSEvent.ModifierFlags,
                                   store: CustomizeStore, cursor: CustomizeCursor, settings: AppSettings) -> Bool {
            if mods.contains(.command) {
                switch chars {
                case "z":
                    mods.contains(.shift) ? store.redo() : store.undo()
                    return true
                case "c":
                    guard let p = cursor.primary else { return false }
                    store.copyStyle(p)
                    return true
                case "v":
                    guard !cursor.selection.isEmpty else { return false }
                    store.pasteStyle(into: cursor.selection)
                    return true
                default:
                    return false
                }
            }
            let step = mods.contains(.shift) ? 4.0 : 1.0
            switch key {
            case 53: // esc
                if !cursor.selection.isEmpty { cursor.selection = [] } else { store.isActive = false }
                return true
            case 48: // tab
                let all = CustomElement.allCases
                let i = cursor.primary.flatMap { all.firstIndex(of: $0) } ?? -1
                cursor.select(all[(i + (mods.contains(.shift) ? all.count - 1 : 1) + all.count) % all.count])
                return true
            case 51, 117: // delete
                guard !cursor.selection.isEmpty else { return false }
                store.reset(cursor.selection)
                return true
            case 126, 125: // up, down
                guard let p = cursor.primary else { return false }
                let dir = key == 126 ? 1.0 : -1.0
                if p.kind == .text {
                    store.edit(cursor.targets, coalesce: "size") { $0.sizeScale = min(2.5, max(0.6, ($0.sizeScale ?? 1) + 0.05 * step * dir)) }
                } else if p == .playerBar || p == .statusBar {
                    let base = p == .statusBar ? 28.0 : Double(settings.data.playerBarStyle.height)
                    let range: ClosedRange<Double> = p == .statusBar ? 20...48 : 40...140
                    store.edit(p, coalesce: "height") { $0.height = range.clamp(($0.height ?? base) + 2 * step * dir) }
                }
                return true
            case 123, 124: // left, right
                guard let pane = cursor.primary?.pane, let c = store.layout.columnIndex(of: pane),
                      !store.layout.columns[c].panes.contains(.library) else { return false }
                let current = store.layout.columns[c].width ?? 280
                store.setColumnWidth(c, min(560, max(160, current + (key == 124 ? 8 : -8) * step)))
                return true
            default:
                return false
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
