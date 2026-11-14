import SwiftUI

/// The app's horizontal slider: a thin line that thickens slightly under the
/// pointer. With the `.line` style the knob only appears while hovering or
/// dragging; `.knob` keeps a small knob visible.
struct MinimalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    var skin: Skin
    var trackHeight: CGFloat = 3
    var style: SliderStyleOption = .line
    /// Fill in the accent color instead of the primary text color.
    var accentFill = false

    @State private var isHovering = false
    @State private var isDragging = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private var isActive: Bool { isHovering || isDragging }
    private var thickness: CGFloat { isActive ? trackHeight + 1 : trackHeight }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * fraction

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(skin.textPrimary.opacity(0.14))
                    .frame(height: thickness)
                Rectangle()
                    .fill(fillColor)
                    .frame(width: max(thickness, x), height: thickness)
                if style == .knob || isActive {
                    Rectangle()
                        .fill(skin.textPrimary)
                        .frame(width: isActive ? 11 : 8, height: isActive ? 11 : 8)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .offset(x: x - (isActive ? 5.5 : 4))
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { isHovering = h } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let f = width > 0 ? min(max(0, drag.location.x), width) / width : 0
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isActive)
        }
        .frame(height: 14)
    }

    private var fillColor: Color {
        if accentFill { return skin.accent }
        return skin.textPrimary.opacity(isActive ? 0.9 : 0.62)
    }
}
