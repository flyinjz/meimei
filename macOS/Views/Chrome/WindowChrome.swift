import SwiftUI
import AppKit

/// Configures the hosting window once it exists: Meimei's own square,
/// borderless frame (or, with `systemFrame`, the platform's titlebar with
/// its traffic lights), and a real minimum size.
///
/// SwiftUI's `.frame(minWidth:)` is only a layout hint; a smaller frame
/// restored from a previous session would otherwise squeeze the fixed-height
/// bars. Setting `contentMinSize` makes AppKit enforce the floor, and a
/// restored frame below it is grown back once.
struct WindowChromeGuard: NSViewRepresentable {
    var minSize: NSSize?
    /// See-through window (the Glass backdrop). Otherwise the window is
    /// opaque: in a non-opaque window the panes' glass samples the desktop
    /// behind the window instead of the app's own backdrop.
    var transparent = false
    var systemFrame = AppSession.shared.settings.data.systemWindowFrame

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.minSize = minSize
        view.transparent = transparent
        view.systemFrame = systemFrame
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowObservingView else { return }
        if view.transparent != transparent {
            view.transparent = transparent
            view.applyOpacity()
        }
        if view.systemFrame != systemFrame {
            view.systemFrame = systemFrame
            view.applyFrame()
        }
    }

    private final class WindowObservingView: NSView {
        var minSize: NSSize?
        var transparent = false
        var systemFrame = false
        private var keyObserver: NSObjectProtocol?

        /// Square and borderless: no titlebar, so no traffic lights and no
        /// rounded corners. Still resizable, and key-capable because of it.
        func applyFrame() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            if systemFrame {
                if !window.styleMask.contains(.titled) { window.styleMask.insert(.titled) }
                window.styleMask.insert([.closable, .miniaturizable, .fullSizeContentView])
                // An empty compact toolbar gives the frame its compact titlebar band.
                if window.toolbar == nil { window.toolbar = NSToolbar() }
                window.toolbarStyle = .unifiedCompact
            } else if window.styleMask.contains(.titled) {
                window.toolbar = nil
                window.styleMask = [.borderless, .resizable, .miniaturizable, .closable, .fullSizeContentView]
                KeyableWindow.enable(window)
                window.hasShadow = true
                window.invalidateShadow()
            }
        }

        deinit {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }

        func applyOpacity() {
            guard let window else { return }
            window.isOpaque = !transparent
            window.backgroundColor = transparent ? .clear : .black
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            #if DEBUG
            if DebugHooks.isHeadless {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
            #endif
            applyFrame()
            // SwiftUI can restore the titled style when it updates the
            // window; put the square frame back whenever it comes forward.
            if keyObserver == nil {
                keyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.applyFrame() } }
            }
            // Only the top band moves the window (`WindowDragArea`): moving
            // by the whole background hijacked drags on knobs and sliders.
            window.isMovableByWindowBackground = false
            applyOpacity()
            guard let minSize else { return }
            window.contentMinSize = minSize
            let current = window.contentLayoutRect.size
            if current.width < minSize.width || current.height < minSize.height {
                window.setContentSize(NSSize(width: max(current.width, minSize.width), height: max(current.height, minSize.height)))
            }
        }
    }
}

/// A borderless window can't become key or main, so it would take no
/// typing or shortcuts. SwiftUI owns the window's class, so the window gets
/// a runtime subclass of whatever that class is, overriding only those two.
enum KeyableWindow {
    private static var classes: [ObjectIdentifier: AnyClass] = [:]

    @MainActor
    static func enable(_ window: NSWindow) {
        let base: AnyClass = type(of: window)
        if NSStringFromClass(base).hasPrefix("MeimeiKeyable_") { return }
        let sub: AnyClass
        if let cached = classes[ObjectIdentifier(base)] {
            sub = cached
        } else {
            let name = "MeimeiKeyable_" + NSStringFromClass(base).replacingOccurrences(of: ".", with: "_")
            if let existing = NSClassFromString(name) {
                sub = existing
            } else {
                guard let made = objc_allocateClassPair(base, name, 0) else { return }
                let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
                let imp = imp_implementationWithBlock(yes)
                class_addMethod(made, #selector(getter: NSWindow.canBecomeKey), imp, "c@:")
                class_addMethod(made, #selector(getter: NSWindow.canBecomeMain), imp, "c@:")
                objc_registerClassPair(made)
                sub = made
            }
            classes[ObjectIdentifier(base)] = sub
        }
        object_setClass(window, sub)
    }
}

/// An empty strip that moves the window when dragged and zooms it on a
/// double-click, like a title bar. Put it behind a window's top band.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Close, minimize, and zoom, drawn by Meimei for its square frame: three
/// small bordered squares at the top left. Hidden when the platform frame
/// is on (it brings its own).
/// The band across the top of every i2s window: the window controls sit
/// in it at the same spot as in the main window (14pt from the left edge,
/// centered in a 46pt band).
enum TitleBand {
    static let height: CGFloat = 46
    static let controlsLeading: CGFloat = 14
}

struct WindowControls: View {
    var skin: Skin
    /// Mini player and similar windows can't zoom.
    var canZoom = true
    /// A settings preview: drawn and hoverable, but the buttons do nothing.
    var preview = false
    /// Child windows (Library, Settings, Downloads, Equalizer): only Close,
    /// drawn with the same customization as the main window's buttons.
    var closeOnly = false
    @ObservedObject private var settings = AppSession.shared.settings
    @ObservedObject private var customize = AppSession.shared.customize
    @State private var hoveringGroup = false
    @State private var editing = false
    /// The window these buttons sit in, not whichever is key.
    @State private var window: NSWindow?

    enum Kind: String, CaseIterable {
        case close, minimize, zoom
        var role: String { "window." + rawValue }
        var title: String {
            switch self {
            case .close: return "Close"
            case .minimize: return "Minimize"
            case .zoom: return "Full screen"
            }
        }
        var help: String {
            switch self {
            case .close: return "Close"
            case .minimize: return "Minimize"
            case .zoom: return "Full screen (⌃⌘F) · ⌥-click to zoom"
            }
        }
    }

    private var kinds: [Kind] {
        var list: [Kind] = closeOnly ? [.close] : canZoom ? [.close, .minimize, .zoom] : [.close, .minimize]
        if settings.data.windowControlCloseLast { list = list.filter { $0 != .close } + [.close] }
        return list
    }

    var body: some View {
        let d = settings.data
        HStack(spacing: CGFloat(d.windowControlStyle == .bare ? d.windowControlSpacing + 2 : d.windowControlSpacing)) {
            ForEach(kinds, id: \.self) { kind in control(kind) }
        }
        .onHover { hoveringGroup = $0 }
        .background(WindowReader { window = $0 })
        .customFrame(.windowControls, active: customize.isActive && !preview)
        .appContextMenu {
            MenuContent(title: "Window buttons", [
                MenuGroup(nil, [
                    .action("Change Icons…", glyph: "paintbrush.pointed") { editing = true },
                ]),
                MenuGroup("style", WindowControlStyle.allCases.map { s in
                    .action(s.label, checked: settings.data.windowControlStyle == s) { settings.data.windowControlStyle = s }
                }),
                MenuGroup("shape", WindowControlShape.allCases.map { s in
                    .action(s.label, checked: settings.data.windowControlShape == s) { settings.data.windowControlShape = s }
                }),
            ])
        }
        .sheet(isPresented: $editing) {
            WindowButtonsSheet(settings: settings, skin: skin) { editing = false }
        }
    }

    private func control(_ kind: Kind) -> some View {
        let d = settings.data
        let showsGlyph: Bool = {
            if d.windowControlStyle == .bare { return true }
            switch d.windowControlGlyphs {
            case .hover: return hoveringGroup
            case .always: return true
            case .never: return false
            }
        }()
        return WindowControlButton(kind: kind, skin: skin, data: d, showsGlyph: showsGlyph,
                                   action: preview ? {} : { perform(kind) })
            .help(kind.help)
    }

    private func perform(_ kind: Kind) {
        switch kind {
        case .close: window?.close()
        case .minimize: window?.miniaturize(nil)
        case .zoom:
            if NSEvent.modifierFlags.contains(.option) { window?.zoom(nil) } else { window?.toggleFullScreen(nil) }
        }
    }
}

/// One window button as drawn, for the editor: clicking it picks it.
struct WindowControlPreviewButton: View {
    var kind: WindowControls.Kind
    var skin: Skin
    var data: AppSettingsData
    var selected: Bool
    var action: () -> Void

    var body: some View {
        WindowControlButton(kind: kind, skin: skin, data: data, showsGlyph: true, action: action)
            .padding(3)
            .overlay(Rectangle().strokeBorder(selected ? skin.accent : .clear, lineWidth: 1))
            .help("Change the \(kind == .zoom ? "full screen" : kind.rawValue) icon")
    }
}

private struct WindowControlButton: View {
    var kind: WindowControls.Kind
    var skin: Skin
    var data: AppSettingsData
    var showsGlyph: Bool
    var action: () -> Void
    @State private var hovering = false

    private var style: WindowControlStyle { data.windowControlStyle }
    private var side: CGFloat { CGFloat(data.windowControlSide) }

    var body: some View {
        let shape = self.shape
        Button(action: action) {
            Glyph(kind.role, size: side * CGFloat(style == .bare ? min(1, data.windowControlIconScale * 1.35) : data.windowControlIconScale))
                .opacity(showsGlyph ? 1 : 0)
                .foregroundStyle(glyphColor)
                .frame(width: side, height: side)
                .background(shape.fill(fill))
                .overlay(shape.stroke(border, lineWidth: style == .outline ? CGFloat(data.windowControlBorder) : 0).padding(CGFloat(data.windowControlBorder) / 2))
                .contentShape(Rectangle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: showsGlyph)
    }

    private var shape: AnyShape {
        switch data.windowControlShape {
        case .square: return AnyShape(Rectangle())
        case .rounded: return AnyShape(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
        case .circle: return AnyShape(Circle())
        }
    }

    /// The button's own color at rest.
    private var base: Color {
        switch data.windowControlColoring {
        case .accent: return skin.accent
        case .custom: return data.windowControlColors[kind.rawValue].map { Color(hex: $0) } ?? skin.textPrimary
        case .theme: return data.windowControlAccent ? skin.accent : skin.textPrimary
        }
    }

    private var hoverColor: Color {
        switch data.windowControlHover {
        case .accent: return skin.accent
        case .own, .brighten: return base
        }
    }

    private var restStrength: Double { data.windowControlRestOpacity }

    private var glyphColor: Color {
        switch style {
        case .bare: return hovering ? hoverColor : base.opacity(restStrength)
        case .outline, .filled:
            guard hovering else { return base.opacity(min(1, restStrength + 0.3)) }
            if data.windowControlHover == .brighten { return base }
            return hoverColor.luminance > 0.55 ? Color.black.opacity(0.85) : .white
        }
    }

    private var fill: Color {
        switch style {
        case .bare: return .clear
        case .outline:
            if hovering { return data.windowControlHover == .brighten ? base.opacity(0.18) : hoverColor }
            return base.opacity(0.06)
        case .filled:
            if hovering { return data.windowControlHover == .brighten ? base.opacity(0.6) : hoverColor }
            return base.opacity(restStrength * 0.5)
        }
    }

    private var border: Color { hovering ? hoverColor : base.opacity(restStrength * 0.6) }
}

/// Hands its hosting window to `found` once it's in one.
private struct WindowReader: NSViewRepresentable {
    var found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { [found] in found?(w) }
        }
    }
}

// MARK: - Mouse-wheel glide

/// Mouse wheels move scroll views in a short glide instead of a jump: the
/// same distance AppKit would scroll for that notch, eased over 0.16 s,
/// and notches in quick succession add to where the glide is heading.
/// Trackpads, Magic Mouse and momentum (precise deltas) are left exactly
/// as they are. Platform piece: Windows and most toolkits already glide.
@MainActor
enum SmoothWheel {
    static let duration: CFTimeInterval = 0.16
    /// Off only for the self-test's comparison with AppKit's own scrolling.
    static var enabled = true
    private static var installed = false
    private static var glides: [ObjectIdentifier: Glide] = [:]

    static func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.scrollWheel(with:))),
              let smooth = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.i2s_glideScrollWheel(with:))) else { return }
        method_exchangeImplementations(original, smooth)
    }

    /// One scroll view's glide in progress.
    final class Glide {
        weak var scrollView: NSScrollView?
        var from: NSPoint
        var to: NSPoint
        var start: CFTimeInterval
        var timer: Timer?
        init(_ scrollView: NSScrollView, from: NSPoint, to: NSPoint) {
            self.scrollView = scrollView
            self.from = from
            self.to = to
            start = CACurrentMediaTime()
        }
    }

    /// Where a scroll view is gliding to, or its position if it's still.
    static func target(of scrollView: NSScrollView) -> NSPoint {
        glides[ObjectIdentifier(scrollView)]?.to ?? scrollView.contentView.bounds.origin
    }

    static func glide(_ scrollView: NSScrollView, to target: NSPoint) {
        let key = ObjectIdentifier(scrollView)
        let now = scrollView.contentView.bounds.origin
        if let g = glides[key] {
            g.from = now
            g.to = target
            g.start = CACurrentMediaTime()
            return
        }
        let g = Glide(scrollView, from: now, to: target)
        glides[key] = g
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { step(key) }
        }
        g.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        step(key)
    }

    private static func step(_ key: ObjectIdentifier) {
        guard let g = glides[key], let scrollView = g.scrollView else {
            glides[key]?.timer?.invalidate()
            glides[key] = nil
            return
        }
        let t = min(1, (CACurrentMediaTime() - g.start) / duration)
        // Ease out: quick to respond, settling softly on the exact target.
        let e = 1 - pow(1 - t, 3)
        let p = NSPoint(x: g.from.x + (g.to.x - g.from.x) * e, y: g.from.y + (g.to.y - g.from.y) * e)
        let clip = scrollView.contentView
        clip.scroll(to: p)
        scrollView.reflectScrolledClipView(clip)
        if t >= 1 {
            g.timer?.invalidate()
            glides[key] = nil
        }
    }
}

extension NSScrollView {
    /// Swapped with `scrollWheel(with:)` at launch, so calling this name
    /// here runs AppKit's own handler.
    @objc func i2s_glideScrollWheel(with event: NSEvent) {
        guard SmoothWheel.enabled, !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
              let document = documentView, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else {
            i2s_glideScrollWheel(with: event)
            return
        }
        let clip = contentView
        var target = SmoothWheel.target(of: self)
        // The distance AppKit scrolls for a notch: the event's lines times the line height.
        target.y += (document.isFlipped ? -event.scrollingDeltaY : event.scrollingDeltaY) * verticalLineScroll
        target.x -= event.scrollingDeltaX * horizontalLineScroll
        target = clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin
        guard target != clip.bounds.origin || SmoothWheel.target(of: self) != clip.bounds.origin else { return }
        SmoothWheel.glide(self, to: target)
    }
}
