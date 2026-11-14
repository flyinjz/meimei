import SwiftUI

/// A free resize of one pane from a corner or an edge, with rules: panes
/// stay inside the window's grid, keep usable minimum sizes, leave the
/// library room, and edges snap to the edges of panes in other columns.
///
/// Pure geometry over the pane frames captured when the drag began, so it
/// can be checked without a window.
struct PaneResize {
    var pane: PaneID
    var horizontal: HorizontalEdge?
    var vertical: VerticalEdge?
    /// Pane frames when the drag began (visible panes only).
    var frames: [PaneID: CGRect]
    var layout: PaneLayout
    var gap: CGFloat

    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 560
    static let libraryMinWidth: CGFloat = 360
    static let minHeight: CGFloat = 80
    static let snapDistance: CGFloat = 8

    /// A line an edge snapped to, drawn across the window while dragging.
    struct Guide: Equatable, Hashable {
        enum Axis { case x, y }
        var axis: Axis
        var position: CGFloat
    }

    struct Result {
        var layout: PaneLayout
        var rect: CGRect
        var guides: [Guide]
    }

    /// The edges of `pane` that move something. Outer edges sit on the
    /// window margin, so only edges shared with a neighbor resize.
    static func movableEdges(of pane: PaneID, layout: PaneLayout, frames: [PaneID: CGRect])
        -> (horizontal: [HorizontalEdge], vertical: [VerticalEdge]) {
        let probe = PaneResize(pane: pane, horizontal: nil, vertical: nil, frames: frames, layout: layout, gap: 0)
        guard let c = layout.columnIndex(of: pane) else { return ([], []) }
        let columns = probe.visibleColumns
        guard let pos = columns.firstIndex(of: c) else { return ([], []) }
        var h: [HorizontalEdge] = []
        if pos > 0 { h.append(.leading) }
        if pos < columns.count - 1 { h.append(.trailing) }
        let stack = probe.visiblePanes(in: c)
        var v: [VerticalEdge] = []
        if let i = stack.firstIndex(of: pane) {
            if i > 0 { v.append(.top) }
            if i < stack.count - 1 { v.append(.bottom) }
        }
        return (h, v)
    }

    /// The layout after dragging by `t`; `snapping` off is ⌥ held.
    func apply(_ t: CGSize, snapping: Bool = true) -> Result {
        var result = Result(layout: layout, rect: frames[pane] ?? .zero, guides: [])
        guard let r = frames[pane], let c = layout.columnIndex(of: pane) else { return result }
        if let horizontal { resizeWidth(c, r, horizontal, t.width, snapping, &result) }
        if let vertical { resizeHeight(c, r, vertical, t.height, snapping, &result) }
        return result
    }

    // MARK: Width

    private func resizeWidth(_ c: Int, _ r: CGRect, _ edge: HorizontalEdge, _ dx: CGFloat, _ snapping: Bool,
                             _ result: inout Result) {
        let columns = visibleColumns
        guard let pos = columns.firstIndex(of: c) else { return }
        let neighborPos = edge == .trailing ? pos + 1 : pos - 1
        guard columns.indices.contains(neighborPos) else { return }
        let neighbor = columns[neighborPos]

        // The fixed column on this boundary changes; the library absorbs it.
        let resized = isFlexible(c) ? neighbor : c
        guard let rr = columnRect(resized), let libraryRect = libraryColumnRect else { return }
        let ownSide = resized == c
        // The width of the resized column with this pane's edge at `b`, and back.
        let widthAt = { (b: CGFloat) -> CGFloat in
            switch (ownSide, edge) {
            case (true, .trailing): return b - rr.minX
            case (true, .leading): return rr.maxX - b
            case (false, .trailing): return rr.maxX - (b + gap)
            case (false, .leading): return (b - gap) - rr.minX
            }
        }
        let edgeFor = { (w: CGFloat) -> CGFloat in
            switch (ownSide, edge) {
            case (true, .trailing): return rr.minX + w
            case (true, .leading): return rr.maxX - w
            case (false, .trailing): return rr.maxX - w - gap
            case (false, .leading): return rr.minX + w + gap
            }
        }
        // A column never takes the library below its minimum.
        let upper = min(Self.maxWidth, rr.width + max(0, libraryRect.width - Self.libraryMinWidth))

        var b = (edge == .trailing ? r.maxX : r.minX) + dx
        // Snap to another fixed column's width, so side columns can match.
        if snapping {
            for other in columns where other != resized && !isFlexible(other) {
                guard let o = columnRect(other) else { continue }
                let target = edgeFor(o.width)
                if abs(b - target) < Self.snapDistance {
                    b = target
                    result.guides.append(Guide(axis: .x, position: target))
                    break
                }
            }
        }
        let width = min(upper, max(Self.minWidth, widthAt(b))).rounded()
        if let i = result.layout.columns.firstIndex(where: { $0.id == layout.columns[resized].id }) {
            result.layout.columns[i].width = Double(width)
        }
        let landed = edgeFor(width)
        if edge == .trailing {
            result.rect.size.width = landed - r.minX
        } else {
            result.rect.origin.x = landed
            result.rect.size.width = r.maxX - landed
        }
        result.guides.removeAll { $0.axis == .x && abs($0.position - landed) > 0.5 }
    }

    // MARK: Height

    private func resizeHeight(_ c: Int, _ r: CGRect, _ edge: VerticalEdge, _ dy: CGFloat, _ snapping: Bool,
                              _ result: inout Result) {
        let stack = visiblePanes(in: c)
        guard let i = stack.firstIndex(of: pane) else { return }
        let j = edge == .bottom ? i + 1 : i - 1
        guard stack.indices.contains(j), let n = frames[stack[j]] else { return }

        var line = (edge == .bottom ? r.maxY : r.minY) + dy
        if snapping, let snapped = snapY(line, excluding: c) {
            line = snapped
            result.guides.append(Guide(axis: .y, position: snapped))
        }
        // The pair's combined height is fixed; trade it between them.
        let pair = r.height + n.height
        var mine = edge == .bottom ? line - r.minY : r.maxY - line
        mine = min(pair - Self.minHeight, max(Self.minHeight, mine)).rounded()
        // Weights in points: every pane in the column at its current height.
        var weights: [PaneID: Double] = [:]
        for p in stack { weights[p] = Double(frames[p]?.height ?? 0) }
        weights[pane] = Double(mine)
        weights[stack[j]] = Double(pair - mine)
        if let k = result.layout.columns.firstIndex(where: { $0.id == layout.columns[c].id }) {
            result.layout.columns[k].weights.merge(weights) { $1 }
        }
        if edge == .bottom {
            result.rect.size.height = mine
        } else {
            result.rect.origin.y = r.maxY - mine
            result.rect.size.height = mine
        }
        // Guides only make sense where the edge actually landed.
        let landed = edge == .bottom ? result.rect.maxY : result.rect.minY
        result.guides.removeAll { $0.axis == .y && abs($0.position - landed) > 0.5 }
    }

    /// The nearest top or bottom edge of a pane in another column.
    private func snapY(_ y: CGFloat, excluding column: Int) -> CGFloat? {
        var best: (CGFloat, CGFloat)?
        for (p, f) in frames where layout.columnIndex(of: p) != column {
            for candidate in [f.minY, f.maxY] {
                let d = abs(candidate - y)
                if d < Self.snapDistance, best == nil || d < best!.0 { best = (d, candidate) }
            }
        }
        return best?.1
    }

    // MARK: Columns

    var visibleColumns: [Int] {
        layout.columns.indices.filter { !visiblePanes(in: $0).isEmpty }
    }

    func visiblePanes(in column: Int) -> [PaneID] {
        layout.columns[column].panes.filter { frames[$0] != nil }
    }

    private func columnRect(_ column: Int) -> CGRect? {
        let rects = visiblePanes(in: column).compactMap { frames[$0] }
        guard let first = rects.first else { return nil }
        return rects.reduce(first) { $0.union($1) }
    }

    private func isFlexible(_ column: Int) -> Bool { layout.columns[column].panes.contains(.library) }

    private var libraryColumnRect: CGRect? {
        layout.columnIndex(of: .library).flatMap(columnRect)
    }
}
