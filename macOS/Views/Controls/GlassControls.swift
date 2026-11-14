import SwiftUI
import AppKit

// MARK: - Pill button

/// A rectangular button with a 1px border that brightens under the
/// pointer, accent-filled when prominent or active. The app's one shape for
/// labeled actions.
struct PillButtonStyle: ButtonStyle {
    var skin: Skin
    var prominent = false
    var isActive = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, style: self)
    }

    private struct Pill: View {
        let configuration: Configuration
        let style: PillButtonStyle
        @ObservedObject private var settings = AppSession.shared.settings
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.buttonContentOverride) private var contentOverride

        var body: some View {
            let skin = style.skin
            let d = settings.data
            let accent = style.isActive || (style.prominent && d.buttonAccentPrimary)
            let look = ButtonLook(fill: d.buttonFill, accent: accent, hovering: hovering, skin: skin)
            configuration.label
                .labelStyle(ButtonContentLabelStyle(content: contentOverride ?? d.buttonContent))
                .font(AppFont.ui((style.compact ? 11 : 12) + d.buttonSize.delta / 3, weight: accent ? .semibold : .regular))
                .foregroundStyle(look.foreground)
                .padding(.horizontal, d.buttonFill == .text ? 4 : (style.compact ? 8 : 11))
                .frame(height: (style.compact ? 22 : 26) + d.buttonSize.delta)
                .background(look.background)
                .overlay(Rectangle().strokeBorder(look.border, lineWidth: 1))
                .contentShape(Rectangle())
                .offset(y: configuration.isPressed ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Colors for a button in the chosen fill: solid fills the accent ones,
/// outline draws only the frame, text only draws neither.
struct ButtonLook {
    var fill: ButtonFill
    var accent: Bool
    var hovering: Bool
    var skin: Skin

    var foreground: Color {
        switch (fill, accent) {
        case (.solid, true): return skin.textOnAccent
        case (_, true): return skin.accent
        default: return hovering ? skin.textPrimary : skin.textSecondary
        }
    }

    var background: Color {
        switch fill {
        case .solid: return accent ? skin.accent.opacity(hovering ? 1 : 0.9) : skin.textPrimary.opacity(hovering ? 0.08 : 0.02)
        case .outline: return hovering ? (accent ? skin.accent : skin.textPrimary).opacity(0.08) : .clear
        case .text: return .clear
        }
    }

    var border: Color {
        switch fill {
        case .solid: return accent ? skin.accent : skin.textPrimary.opacity(hovering ? 0.55 : 0.22)
        case .outline: return accent ? skin.accent.opacity(hovering ? 1 : 0.8) : skin.textPrimary.opacity(hovering ? 0.55 : 0.28)
        case .text: return .clear
        }
    }
}

private struct ButtonContentOverrideKey: EnvironmentKey {
    static let defaultValue: ButtonContent? = nil
}

extension EnvironmentValues {
    /// Forces what labeled buttons show, e.g. icons only where space is short.
    var buttonContentOverride: ButtonContent? {
        get { self[ButtonContentOverrideKey.self] }
        set { self[ButtonContentOverrideKey.self] = newValue }
    }
}

/// Icon and title close together, or just one of them, per the setting.
struct ButtonContentLabelStyle: LabelStyle {
    var content: ButtonContent

    func makeBody(configuration: Configuration) -> some View {
        switch content {
        case .iconAndText:
            HStack(spacing: 5) {
                configuration.icon.font(AppFont.ui(10, weight: .semibold))
                configuration.title
            }
        case .text: configuration.title
        case .icon: configuration.icon
        }
    }
}

/// A square icon button with the same treatment as `PillButtonStyle`.
struct IconButton: View {
    var icon: String
    var size: CGFloat = 26
    var isActive = false
    var help: String = ""
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    @ObservedObject private var settings = AppSession.shared.settings

    var body: some View {
        let look = ButtonLook(fill: settings.data.buttonFill, accent: isActive, hovering: hovering, skin: skin)
        Button(action: action) {
                Glyph(icon, size: size * 0.42)
                    .foregroundStyle(look.foreground)
                    .frame(width: size, height: size)
                    .background(look.background)
                    .overlay(Rectangle().strokeBorder(look.border, lineWidth: 1))
                    .contentShape(Rectangle())
        }
        .buttonStyle(PressDipStyle())
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Knob

/// A rotary control in the DAW style: drag up/down (⇧ for fine), scroll,
/// double-click to reset. A 270° arc shows the value; bipolar knobs fill
/// from the center.
struct Knob: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var defaultValue: Double
    /// Logarithmic travel (frequency, Q).
    var logarithmic = false
    var bipolar = false
    var size: CGFloat = 44
    var tint: Color
    var skin: Skin
    var onBegin: () -> Void = {}

    @State private var dragStart: Double?
    @State private var hovering = false

    private var fraction: Double {
        if logarithmic {
            return log(value / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func value(at f: Double) -> Double {
        let f = min(1, max(0, f))
        if logarithmic { return range.lowerBound * pow(range.upperBound / range.lowerBound, f) }
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        let sweep = 0.75
        let f = min(1, max(0, fraction))
        let zero = bipolar ? 0.5 : 0
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(skin.textPrimary.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: min(zero, f) * sweep, to: max(zero, f) * sweep)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .fill(skin.textPrimary.opacity(hovering ? 0.11 : 0.07))
                .padding(size * 0.18)
            Rectangle()
                .fill(skin.textPrimary)
                .frame(width: 2, height: size * 0.16)
                .offset(y: -size * 0.2)
                .rotationEffect(.degrees(-135 + 270 * f))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if dragStart == nil { dragStart = f; onBegin() }
                    let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                    value = self.value(at: (dragStart ?? f) - Double(g.translation.height) / 180 * fine)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { onBegin(); value = defaultValue }
        .background(ScrollCatcher { delta in
            if dragStart == nil { onBegin() }
            value = self.value(at: f + delta / 400)
            return true
        })
        .animation(.easeOut(duration: 0.08), value: f)
    }
}

// MARK: - Editable value

/// A value readout that turns into a text field on click. Return commits,
/// Escape cancels; the parser returns nil to reject input.
struct EditableValue: View {
    var text: String
    var skin: Skin
    var width: CGFloat = 64
    var parse: (String) -> Double?
    var commit: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit {
                        if let v = parse(draft) { commit(v) }
                        editing = false
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { f in if !f { editing = false } }
            } else {
                Text(text)
                    .onTapGesture {
                        draft = text.components(separatedBy: " ").first ?? text
                        editing = true
                        DispatchQueue.main.async { focused = true }
                    }
            }
        }
        .font(AppFont.ui(11, weight: .medium))
        .foregroundStyle(skin.textPrimary)
        .frame(width: width, height: 20)
        .background(Rectangle().fill(skin.textPrimary.opacity(editing ? 0.12 : 0.05)))
        .help("Click to type a value")
    }
}

// MARK: - Scroll wheel

/// Reports vertical scroll-wheel deltas over its area (SwiftUI has no
/// scroll-wheel gesture on macOS). Lets clicks and drags pass through, and
/// passes the scroll on too unless `onScroll` returns true (handled).
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (Double) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((Double) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            // A local monitor sees the wheel even though SwiftUI's hit
            // testing sends the event to the hosting view, not this one.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                return self.onScroll?(Double(dy)) == true ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Progress

/// The app's progress line: a thin solid line. A determinate bar glides
/// between updates over the time since the last one, so it moves
/// continuously instead of jumping; an indeterminate one runs a solid
/// segment along the track that stretches as it speeds up and shortens as
/// it slows, then starts again. Square ends, no gradient, no glow.
///
/// Drawn with Core Animation, so it moves at the display's rate on the
/// render server even while the main thread is busy.
struct CapsuleProgress: View {
    var fraction: Double?
    var skin: Skin
    /// The fill; ink by default.
    var tint: Color? = nil

    var body: some View {
        let fill = tint ?? skin.textPrimary.opacity(0.85)
        let track = skin.textPrimary.opacity(0.1)
        if GlassRendering.forceFallback {
            // Offscreen snapshots can't draw layers: a still frame.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(track)
                    Rectangle().fill(fill)
                        .frame(width: geo.size.width * (fraction.map { CGFloat(min(1, max(0, $0))) } ?? 0.28))
                        .offset(x: fraction == nil ? geo.size.width * 0.36 : 0)
                }
            }
        } else {
            ProgressLayer(fraction: fraction.map { min(1, max(0, $0)) }, track: NSColor(track), fill: NSColor(fill))
        }
    }
}

private struct ProgressLayer: NSViewRepresentable {
    var fraction: Double?
    var track: NSColor
    var fill: NSColor

    func makeNSView(context: Context) -> BarView { BarView() }

    func updateNSView(_ view: BarView, context: Context) {
        view.update(fraction: fraction, track: track, fill: fill)
    }

    final class BarView: NSView {
        private let bar = CALayer()
        private let runner = CALayer()
        private var fraction: Double?
        private var lastUpdate: CFTimeInterval = 0
        private var laidOutWidth: CGFloat = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
                                             "hidden": NSNull(), "frame": NSNull()]
            layer?.actions = still
            for l in [bar, runner] { l.actions = still; l.anchorPoint = .zero }
            layer?.addSublayer(bar)
            layer?.addSublayer(runner)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 2
            for l in [layer, bar, runner] { l?.contentsScale = scale }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Layers can drop repeating animations while off screen.
            laidOutWidth = -1
            needsLayout = true
        }

        func update(fraction new: Double?, track: NSColor, fill: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = track.cgColor
            bar.backgroundColor = fill.cgColor
            runner.backgroundColor = fill.cgColor
            CATransaction.commit()

            let old = fraction
            fraction = new
            if (old == nil) != (new == nil) { laidOutWidth = -1; needsLayout = true }
            guard let new, let old, new != old else { return }
            let now = CACurrentMediaTime()
            let since = now - lastUpdate
            lastUpdate = now
            let width = bounds.width * CGFloat(new)
            let from = bar.presentation()?.bounds.width ?? bar.bounds.width
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.width = width
            CATransaction.commit()
            // Going back (a restart) or the first move after a pause: no glide.
            guard new > old, since < 2 else { return }
            let glide = CABasicAnimation(keyPath: "bounds.size.width")
            glide.fromValue = from
            glide.toValue = width
            glide.duration = min(0.6, max(0.15, since))
            // Eases out so consecutive glides join without a visible stop.
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.4, 1)
            bar.add(glide, forKey: "glide")
        }

        override func layout() {
            super.layout()
            let size = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let fraction {
                runner.isHidden = true
                runner.removeAllAnimations()
                bar.isHidden = false
                bar.position = .zero
                bar.bounds = CGRect(x: 0, y: 0, width: size.width * CGFloat(fraction), height: size.height)
            } else {
                bar.isHidden = true
                runner.isHidden = false
                runner.position = CGPoint(x: -size.width, y: 0)
                runner.bounds = CGRect(x: 0, y: 0, width: 0, height: size.height)
                if laidOutWidth != size.width || runner.animation(forKey: "run") == nil {
                    laidOutWidth = size.width
                    runner.add(Self.run(width: size.width), forKey: "run")
                }
            }
            CATransaction.commit()
        }

        /// A segment that enters from the left short, stretches to about a
        /// third of the track mid-run, and leaves on the right short again.
        private static func run(width w: CGFloat) -> CAAnimation {
            let ease = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
            let x = CAKeyframeAnimation(keyPath: "position.x")
            x.values = [-w * 0.08, w * 0.12, w * 0.62, w]
            x.keyTimes = [0, 0.3, 0.75, 1]
            x.timingFunctions = [ease, ease, ease]
            let len = CAKeyframeAnimation(keyPath: "bounds.size.width")
            len.values = [w * 0.08, w * 0.34, w * 0.26, w * 0.04]
            len.keyTimes = [0, 0.3, 0.75, 1]
            len.timingFunctions = [ease, ease, ease]
            let group = CAAnimationGroup()
            group.animations = [x, len]
            group.duration = 1.6
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            return group
        }
    }
}

/// A button, styled like any other, that pops up a menu under itself.
/// Use instead of SwiftUI's `Menu` wherever the button should keep the
/// app's look.
struct PopUpMenuButton<Label: View>: View {
    struct Item {
        var title: String
        var checked = false
        var action: () -> Void
    }

    var items: [Item]
    @ViewBuilder var label: Label
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button { anchor.popUp(items) } label: { label }
            .background(MenuAnchorView(anchor: anchor))
    }

    /// Holds the AppKit view the menu opens under.
    final class MenuAnchor {
        weak var view: NSView?

        @MainActor func popUp(_ items: [Item]) {
            guard let view, let window = view.window else { return }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            AppMenu.shared.present(MenuContent(entries: items.map { item in
                .action(item.title, checked: item.checked, item.action)
            }), below: rect)
        }
    }

    private struct MenuAnchorView: NSViewRepresentable {
        let anchor: MenuAnchor
        func makeNSView(context: Context) -> NSView {
            let v = FlippedView()
            anchor.view = v
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
