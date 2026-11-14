import SwiftUI

/// The coordinate space customizable elements report their frames in: the
/// main window's root.
let customizeSpace = "meimei.customize"

/// Every on-screen instance of each customizable element (a role like
/// "browse rows" has many), collected for the customize overlay.
struct CustomFramesKey: PreferenceKey {
    static let defaultValue: [CustomElement: [CGRect]] = [:]
    static func reduce(value: inout [CustomElement: [CGRect]], nextValue: () -> [CustomElement: [CGRect]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

extension View {
    /// Text drawn in a customizable role: `size`, `weight`, and `color` are
    /// the design's values, which the user's overrides replace.
    /// `reportsFrame: false` when the container reports one outline for all
    /// of its lines instead (lyrics: only what the panel shows).
    func textRole(_ element: CustomElement, size: CGFloat, weight: Font.Weight = .regular, color: Color,
                  reportsFrame: Bool = true) -> some View {
        modifier(TextRole(element: element, size: size, weight: weight, color: color, reportsFrame: reportsFrame))
    }

    /// A customizable panel's whole surface: the design's glass or solid
    /// panel (or, with `content`, the denser content layer) plus the user's
    /// padding, fill, borders, corner ticks, and depth.
    func panelSurface(_ element: CustomElement, skin: Skin, fallback: Color, content: Bool = false) -> some View {
        modifier(PanelSurface(element: element, skin: skin, fallback: fallback, content: content))
    }

    /// Reports this view's frame for `element`, only while customizing.
    @ViewBuilder
    func customFrame(_ element: CustomElement, active: Bool) -> some View {
        if active {
            background(GeometryReader { geo in
                Color.clear.preference(key: CustomFramesKey.self, value: [element: [geo.frame(in: .named(customizeSpace))]])
            })
        } else {
            self
        }
    }
}

private struct TextRole: ViewModifier {
    let element: CustomElement
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    var reportsFrame = true
    @ObservedObject private var store = AppSession.shared.customize

    func body(content: Content) -> some View {
        let s = store.style(element)
        let pt = size * CGFloat(s.sizeScale ?? 1) * AppFont.textScale
        let face = AppFont.face(pt, s.weight?.font ?? weight, in: s.font ?? AppFont.family)
        content
            .font(.custom(face, fixedSize: pt).monospacedDigit())
            .tracking(CGFloat(s.tracking ?? 0))
            .foregroundStyle(s.color.map { Color(hex: $0) } ?? color)
            .opacity(s.opacity ?? 1)
            .modifier(Aligned(align: s.align, lines: s.lines))
            .modifier(TextShadow(on: s.shadow == true))
            .customFrame(element, active: store.isActive && reportsFrame)
    }
}

/// A legibility shadow, only when asked for: even a clear shadow costs an
/// offscreen pass per text view.
private struct TextShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.shadow(color: .black.opacity(0.85), radius: 3, y: 1) } else { content }
    }
}

/// Alignment and line count, applied only when set so un-styled text keeps
/// its natural size and the call site's own line limit.
private struct Aligned: ViewModifier {
    let align: TextAlign?
    let lines: Int?
    func body(content: Content) -> some View {
        switch (align, lines) {
        case (nil, nil): content
        case (nil, let n?): content.lineLimit(n)
        case (let a?, nil): content.multilineTextAlignment(a.text).frame(maxWidth: .infinity, alignment: a.alignment)
        case (let a?, let n?): content.lineLimit(n).multilineTextAlignment(a.text).frame(maxWidth: .infinity, alignment: a.alignment)
        }
    }
}

private struct PanelSurface: ViewModifier {
    let element: CustomElement
    let skin: Skin
    let fallback: Color
    let content: Bool
    @ObservedObject private var store = AppSession.shared.customize

    func body(content view: Content) -> some View {
        let s = store.style(element)
        var sk = skin
        if let ticks = s.ticks { sk.showTicks = ticks }
        let depth = Double(s.depth ?? 0)
        return Group {
            if content {
                surfaced(view, s).contentSurface(sk, fallback: fallback)
            } else {
                surfaced(view, s).clipShape(Rectangle()).glassSurface(sk, in: Rectangle(), fallback: fallback)
            }
        }
        .overlay {
            if let border = s.border {
                EdgeBorder(sides: s.borderSides ?? .all, width: CGFloat(s.borderWidth ?? 1), color: Color(hex: border))
                    .allowsHitTesting(false)
            }
        }
        .background {
            if depth > 0 {
                Rectangle().fill(Color.black.opacity(0.6))
                    .shadow(color: .black.opacity(0.35 + depth * 0.1), radius: depth * 6, y: depth * 3)
            }
        }
        .customFrame(element, active: store.isActive)
    }

    private func surfaced(_ view: Content, _ s: ElementStyle) -> some View {
        view
            .padding(CGFloat(s.padding ?? 0))
            .background {
                if let fill = s.fill { Color(hex: fill).opacity(s.fillOpacity ?? 0.5) }
            }
    }
}

/// A border on chosen sides only.
private struct EdgeBorder: View {
    var sides: BorderSides
    var width: CGFloat
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let w = width
            if sides.contains(.top) { ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: w)), with: .color(color)) }
            if sides.contains(.bottom) { ctx.fill(Path(CGRect(x: 0, y: size.height - w, width: size.width, height: w)), with: .color(color)) }
            if sides.contains(.leading) { ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: size.height)), with: .color(color)) }
            if sides.contains(.trailing) { ctx.fill(Path(CGRect(x: size.width - w, y: 0, width: w, height: size.height)), with: .color(color)) }
        }
    }
}
