import SwiftUI
import AppKit

/// A pane's share of a stack's flexible height. 0 means "my own height".
struct PaneWeight: LayoutValueKey {
    static let defaultValue: Double = 1
}

/// A vertical stack where weight-0 children (a now-playing panel, split
/// handles) take their natural height and the rest divide what's left in
/// proportion to their weights. A natural-height pane never takes more
/// than `intrinsicShare` of the stack while flexible panes share it.
struct WeightedStack: Layout {
    var intrinsicShare: CGFloat = 0.6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var heights = [CGFloat](repeating: 0, count: subviews.count)
        var fixed: CGFloat = 0
        let totalWeight = subviews.reduce(0) { $0 + $1[PaneWeight.self] }
        let cap = totalWeight > 0 ? bounds.height * intrinsicShare : bounds.height
        for (i, sv) in subviews.enumerated() where sv[PaneWeight.self] == 0 {
            let natural = sv.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            // Handles are tiny; panes are capped so they can't crowd out the rest.
            heights[i] = natural > 40 ? sv.sizeThatFits(ProposedViewSize(width: width, height: min(natural, cap))).height : natural
            fixed += heights[i]
        }
        let flexible = max(0, bounds.height - fixed)
        var y = bounds.minY
        for (i, sv) in subviews.enumerated() {
            let w = sv[PaneWeight.self]
            let h = w == 0 ? heights[i] : (totalWeight > 0 ? flexible * CGFloat(w / totalWeight) : 0)
            sv.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: width, height: h))
            y += h
        }
    }
}

/// The gap between stacked panes, which drags to rebalance them.
struct StackSplitHandle: View {
    var enabled: Bool
    /// Called with the vertical drag distance since the drag began.
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(height: Corners.inset)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                guard enabled else { return }
                if inside, !hovering { NSCursor.resizeUpDown.push() }
                if !inside, hovering { NSCursor.pop() }
                hovering = inside
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { if enabled { onDrag($0.translation.height) } }
                .onEnded { _ in if enabled { onEnd() } })
            .layoutValue(key: PaneWeight.self, value: 0)
    }
}
