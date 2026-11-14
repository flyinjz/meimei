import SwiftUI
import AppKit
import CoreImage

enum GlassRendering {
    /// Offscreen `ImageRenderer` can't draw platform views; the debug
    /// snapshot tool switches to stand-ins while it renders.
    nonisolated(unsafe) static var forceFallback = false
}

/// The layout grid: the gap between panes and between panes and the
/// window edge.
enum Corners {
    /// The grid gap design token; set by `CustomizeStore`.
    nonisolated(unsafe) static var inset: CGFloat = 6
}

extension View {
    /// A panel of the control layer (sidebar, rails, bars): dark frosted glass
    /// of our own making — a translucent fill over the blurred backdrop, a
    /// 1px border, a faint top highlight — drawn the same on every platform.
    /// Solid skins get `fallback` instead of the translucent fill.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ skin: Skin, in shape: S, fallback: Color? = nil, interactive: Bool = false) -> some View {
        if skin.isGlass {
            self.background(Color.black.opacity(skin.panelOpacity), in: shape)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 1) }
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: skin.borderWidth))
                .fuiCorners(skin)
        } else if let fallback {
            self.background(fallback, in: shape)
                .overlay(shape.strokeBorder(skin.hairline, lineWidth: skin.borderWidth))
                .fuiCorners(skin)
        } else {
            self
        }
    }

    /// The content layer (the library, the EQ graph): denser and darker
    /// than the control panels, so the panels read as a separate layer.
    func contentSurface(_ skin: Skin, fallback: Color) -> some View {
        self.clipShape(Rectangle())
            .background(skin.isGlass ? Color.black.opacity(min(0.95, skin.contentOpacity ?? skin.panelOpacity + 0.16)) : fallback)
            .overlay(Rectangle().strokeBorder(skin.isGlass ? Color.white.opacity(0.14) : skin.hairline, lineWidth: skin.borderWidth))
            .fuiCorners(skin)
    }

    /// Small L-shaped ticks at the four corners, like registration marks on
    /// a technical drawing.
    @ViewBuilder
    func fuiCorners(_ skin: Skin, length: CGFloat? = nil) -> some View {
        if skin.showTicks {
            overlay(FUICorners(color: skin.textPrimary.opacity(0.5), length: length ?? skin.tickLength).allowsHitTesting(false))
        } else {
            self
        }
    }
}

private struct FUICorners: View {
    var color: Color
    var length: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let l = length, w = size.width, h = size.height
            var p = Path()
            for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] {
                p.move(to: CGPoint(x: x + dx * l, y: y + dy * 0.5))
                p.addLine(to: CGPoint(x: x + dx * 0.5, y: y + dy * 0.5))
                p.addLine(to: CGPoint(x: x + dx * 0.5, y: y + dy * l))
            }
            ctx.stroke(p, with: .color(color), lineWidth: 1)
        }
    }
}

/// What fills the window behind the panes.
struct WindowBackdrop: View {
    var style: BackdropStyle
    var skin: Skin
    var artwork: NSImage?
    /// How strongly the theme's base color veils the wallpaper (0…1).
    var glassTint: Double = 0.5
    /// How much of the desktop's color the platform blur lets through.
    var blurMaterial: BlurMaterial = .standard

    enum BlurMaterial { case standard, vivid }

    var body: some View {
        ZStack {
            switch style {
            case .translucent:
                // What's behind the window, blurred by the platform (on macOS
                // the window server; Windows/Linux ports swap in their own).
                if GlassRendering.forceFallback {
                    skin.bgVoid
                } else {
                    PlatformBehindWindowBlur(vivid: blurMaterial == .vivid)
                    skin.bgVoid.opacity(glassTint)
                }
            case .themeColor:
                skin.bgVoid
            case .ambient:
                // A faint measuring grid.
                skin.bgVoid
                Canvas { ctx, size in
                    let step: CGFloat = 24
                    var grid = Path()
                    for x in stride(from: 0, through: size.width, by: step) {
                        grid.move(to: CGPoint(x: x + 0.5, y: 0)); grid.addLine(to: CGPoint(x: x + 0.5, y: size.height))
                    }
                    for y in stride(from: 0, through: size.height, by: step) {
                        grid.move(to: CGPoint(x: 0, y: y + 0.5)); grid.addLine(to: CGPoint(x: size.width, y: y + 0.5))
                    }
                    ctx.stroke(grid, with: .color(Color.white.opacity(0.035)), lineWidth: 1)
                }
            case .artwork:
                skin.bgVoid
                if let artwork, let blurred = BlurredArtwork.image(for: artwork) {
                    // Blurred once at thumbnail size and scaled up: a live
                    // full-window blur re-rendered on every frame of every
                    // animation and resize.
                    Image(nsImage: blurred)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                        .id(ObjectIdentifier(artwork))
                    Color.black.opacity(0.45)
                }
            }
        }
        .animation(.easeInOut(duration: 0.8), value: artwork.map(ObjectIdentifier.init))
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Glass windows

/// The frosted glass every secondary window and dialog uses (Downloads,
/// Library, Equalizer, Settings, sheets): the platform's blur of what's
/// behind the window, a light veil, and dark translucent panes with
/// hairlines, whatever the main window's own backdrop and surfaces are.
enum GlassWindow {
    /// The rails and side panels.
    static let railTint = 0.08
    /// Pages and content.
    static let pageTint = 0.14
    /// Sheets sit over the main window's content, so they veil a little more.
    static let sheetExtra = 0.22

    /// The window-wide veil (Settings → Appearance → Glass window dimming).
    @MainActor static var tint: Double { AppSession.shared.settings.data.downloadsGlassTint }
}

extension AppSettings {
    /// The styled skin with glass surfaces at the glass windows' density.
    func glassWindowSkin(_ skin: Skin) -> Skin {
        var s = styled(skin)
        s.isGlass = true
        s.allowsBackdropBleed = true
        s.bgPanel = .clear
        s.bgRow = .clear
        s.panelOpacity = GlassWindow.railTint
        s.contentOpacity = GlassWindow.pageTint
        return s
    }
}

extension View {
    /// A secondary window's frosted glass: the backdrop, a transparent window,
    /// and its minimum size.
    func glassWindow(_ skin: Skin, minSize: NSSize, tint: Double? = nil) -> some View {
        background {
            WindowBackdrop(style: .translucent, skin: skin, artwork: nil,
                           glassTint: tint ?? GlassWindow.tint, blurMaterial: .vivid)
        }
        .ignoresSafeArea(.container, edges: .top)
        .scrollIndicators(.never)
        .background {
            // Offscreen snapshots can't draw AppKit views; it would cover the render.
            if !GlassRendering.forceFallback { WindowChromeGuard(minSize: minSize, transparent: true) }
        }
    }

    /// A sheet or dialog in the same glass, over whatever window it's attached to.
    func glassSheet(_ skin: Skin) -> some View {
        background {
            WindowBackdrop(style: .translucent, skin: skin, artwork: nil,
                           glassTint: min(0.85, GlassWindow.tint + GlassWindow.sheetExtra), blurMaterial: .vivid)
        }
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.11), lineWidth: 1).allowsHitTesting(false))
        .scrollIndicators(.never)
        .background { if !GlassRendering.forceFallback { ClearSheetWindow() } }
        .modifier(ClearPresentationBackground())
    }
}

/// Frosted glass over the window's own content (the command palette and
/// other floating panels inside a window), in the glass windows' material.
struct InWindowGlass: View {
    var tint: Double = 0.3

    var body: some View {
        ZStack {
            if GlassRendering.forceFallback {
                Color.black.opacity(0.9)
            } else {
                WithinWindowBlur()
                Color.black.opacity(tint)
            }
        }
        .allowsHitTesting(false)
    }

    private struct WithinWindowBlur: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.appearance = NSAppearance(named: .darkAqua)
            v.blendingMode = .withinWindow
            v.state = .active
            return v
        }
        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }
}

/// Makes the sheet's own window see-through, so the blur shows what's
/// behind it, and square like the app's windows: a titled sheet gets the
/// system's rounded frame (macOS 26), so the title style comes off and the
/// window is kept able to take typing.
private struct ClearSheetWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class View: NSView {
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            #if DEBUG
            if DebugHooks.isHeadless {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
            #endif
            window.isOpaque = false
            window.backgroundColor = .clear
            Self.squareOnceAttached(window, tries: 60)
            // SwiftUI can put the title style back when it updates the sheet.
            if keyObserver == nil {
                keyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak window] _ in MainActor.assumeIsolated { window.map(Self.square) } }
            }
        }

        /// The title style has to stay until the sheet is attached: a sheet
        /// window without it never attaches. Checked each frame for a second.
        private static func squareOnceAttached(_ window: NSWindow, tries: Int) {
            if window.sheetParent != nil { square(window); return }
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak window] in
                MainActor.assumeIsolated { window.map { squareOnceAttached($0, tries: tries - 1) } }
            }
        }

        private static func square(_ window: NSWindow) {
            guard window.sheetParent != nil, window.styleMask.contains(.titled) else { return }
            window.styleMask.remove(.titled)
            KeyableWindow.enable(window)
        }

        deinit { keyObserver.map(NotificationCenter.default.removeObserver) }
    }
}

private struct ClearPresentationBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.3, *) {
            content.presentationBackground(.clear)
        } else {
            content
        }
    }
}

/// The backdrop's cover, blurred and desaturated once per image.
@MainActor
enum BlurredArtwork {
    private static var cache: (id: ObjectIdentifier, image: NSImage)?
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for artwork: NSImage) -> NSImage? {
        let id = ObjectIdentifier(artwork)
        if let cache, cache.id == id { return cache.image }
        guard let cg = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // 72 px across; a ~6 px blur here reads like ~70 pt at window size.
        let scale = 72 / CGFloat(max(cg.width, cg.height))
        let input = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 6)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.9])
            .cropped(to: extent)
        guard let out = context.createCGImage(output, from: extent) else { return nil }
        let image = NSImage(cgImage: out, size: extent.size)
        cache = (id, image)
        return image
    }
}

/// The one platform-specific piece of the look: a blur of whatever is
/// behind the window. macOS: `NSVisualEffectView` in behind-window mode.
private struct PlatformBehindWindowBlur: NSViewRepresentable {
    /// A lighter material that keeps more of the desktop's color.
    var vivid = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        // The HUD material stays see-through and keeps the desktop's color even
        // with macOS wallpaper tinting off, which turns window materials gray.
        v.material = vivid ? .hudWindow : .underWindowBackground
        if vivid { v.appearance = NSAppearance(named: .darkAqua) }
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A draggable divider between panes. Invisible except for an optional
/// hairline; shows the resize cursor and reports drags in points.
struct PaneResizeHandle: View {
    var skin: Skin
    var showsLine: Bool
    /// Called with the horizontal drag distance since the drag began.
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        ZStack {
            if showsLine { Hairline(color: skin.hairline, vertical: true) }
        }
        // Without a line, the handle is the gap between floating panes.
        .frame(width: showsLine ? 1 : Corners.inset)
        .frame(maxHeight: .infinity)
        .overlay(
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside, !hovering { NSCursor.resizeLeftRight.push() }
                    if !inside, hovering { NSCursor.pop() }
                    hovering = inside
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onDrag($0.translation.width) }
                        .onEnded { _ in onEnd() }
                )
        )
    }
}
