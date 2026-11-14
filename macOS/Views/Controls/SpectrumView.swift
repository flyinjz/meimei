import SwiftUI

/// Live bar spectrum of whatever is playing. Polls `SpectrumFeed` from a
/// `TimelineView` and eases toward each new analyzer frame, so motion is
/// smooth at display rate even though analysis arrives ~10–20×/s.
struct SpectrumView: View {
    let feed: SpectrumFeed
    var isPlaying: Bool
    var skin: Skin
    var style: SpectrumStyleOption = .gradient
    var barSpacing: CGFloat = 2
    var showPeaks = true

    @State private var motion = SpectrumMotion()
    @State private var asleep = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: asleep)) { timeline in
            Canvas { context, size in
                let levels = motion.step(toward: feed.levels, at: timeline.date)
                draw(levels, peaks: motion.peaks, in: &context, size: size)
            }
        }
        .task(id: isPlaying) {
            if isPlaying {
                asleep = false
            } else {
                // Let the bars fall to rest before the timeline stops.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled { asleep = true }
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ levels: [Float], peaks: [Float], in context: inout GraphicsContext, size: CGSize) {
        let count = levels.count
        guard count > 0, size.width > 0, size.height > 0 else { return }
        let spacing = min(barSpacing, size.width / CGFloat(count) * 0.5)
        let barWidth = max(1, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let h = size.height
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [skin.accentDim, skin.accent, skin.accentGlow]),
            startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: 0, y: 0)
        )
        let flat = GraphicsContext.Shading.color(skin.accent)

        for i in 0..<count {
            let x = CGFloat(i) * (barWidth + spacing)
            let level = CGFloat(levels[i])
            switch style {
            case .gradient, .solid:
                let barHeight = max(1, level * h)
                let rect = CGRect(x: x, y: h - barHeight, width: barWidth, height: barHeight)
                context.fill(Path(rect), with: style == .solid ? flat : shading)
            case .mirrored:
                let barHeight = max(1, level * h)
                let rect = CGRect(x: x, y: (h - barHeight) / 2, width: barWidth, height: barHeight)
                context.fill(Path(rect), with: shading)
            case .segmented:
                let segment: CGFloat = 3, gap: CGFloat = 1
                let total = Int(h / (segment + gap))
                let lit = Int((level * CGFloat(total)).rounded())
                for s in 0..<total {
                    let y = h - CGFloat(s + 1) * (segment + gap) + gap
                    let rect = CGRect(x: x, y: y, width: barWidth, height: segment)
                    let on = s < lit
                    context.fill(Path(rect), with: .color(on ? segmentColor(Double(s) / Double(max(1, total - 1))) : skin.lcdOff.opacity(0.6)))
                }
            }
            if showPeaks, style != .mirrored, peaks.indices.contains(i), peaks[i] > 0.02 {
                let y = h - CGFloat(peaks[i]) * h
                context.fill(Path(CGRect(x: x, y: max(0, y - 1.5), width: barWidth, height: 1.5)),
                             with: .color(skin.accentGlow.opacity(0.9)))
            }
        }
    }

    private func segmentColor(_ t: Double) -> Color {
        t < 0.6 ? skin.accentDim.opacity(0.7 + t * 0.5) : (t < 0.85 ? skin.accent : skin.accentGlow)
    }
}

/// Per-frame bar state: fast attack, gravity-style release, and peak caps
/// that hold briefly before falling.
final class SpectrumMotion {
    private(set) var levels: [Float] = []
    private(set) var peaks: [Float] = []
    private var peakHold: [Double] = []
    private var lastStep: Date?

    func step(toward target: [Float], at now: Date) -> [Float] {
        if levels.count != target.count {
            levels = target.map { _ in 0 }
            peaks = levels
            peakHold = target.map { _ in 0 }
        }
        let dt = Float(min(0.1, max(0, now.timeIntervalSince(lastStep ?? now))))
        lastStep = now
        for i in target.indices {
            let goal = target[i]
            if goal > levels[i] {
                levels[i] += (goal - levels[i]) * min(1, dt * 28)
            } else {
                levels[i] = max(goal, levels[i] - dt * 1.4)
            }
            if levels[i] >= peaks[i] {
                peaks[i] = levels[i]
                peakHold[i] = 0.55
            } else if peakHold[i] > 0 {
                peakHold[i] -= Double(dt)
            } else {
                peaks[i] = max(levels[i], peaks[i] - dt * 0.7)
            }
        }
        return levels
    }
}

/// A time readout with tabular digits, so it doesn't jitter as it counts.
struct TimeLabel: View {
    var text: String
    var size: CGFloat = 10.5
    var color: Color
    var monospaced = true
    /// The customize role this readout belongs to, if any.
    var role: CustomElement? = nil

    var body: some View {
        if let role {
            Text(text).textRole(role, size: size, weight: .medium, color: color).lineLimit(1)
        } else {
            Text(text).font(AppFont.ui(size, weight: .medium)).foregroundStyle(color).lineLimit(1)
        }
    }
}
