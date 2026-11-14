import SwiftUI
import AppKit

// MARK: - Saved colors

/// Up to 32 colors the user keeps, shared by every picker in the app.
@MainActor
final class SavedColors: ObservableObject {
    static let shared = SavedColors()
    static let capacity = 32

    @Published private(set) var colors: [UInt32] {
        didSet { DefaultsStore.save(colors, key: Self.key) }
    }

    private static let key = "com.meimei.player.savedColors.v1"

    private init() {
        colors = DefaultsStore.load([UInt32].self, key: Self.key) ?? []
    }

    var isFull: Bool { colors.count >= Self.capacity }

    /// Saves `hex` at the front (or moves it there); false when full.
    @discardableResult
    func save(_ hex: UInt32) -> Bool {
        if let i = colors.firstIndex(of: hex) {
            colors.remove(at: i)
        } else if isFull {
            return false
        }
        colors.insert(hex, at: 0)
        return true
    }

    func remove(_ hex: UInt32) { colors.removeAll { $0 == hex } }
}

// MARK: - Rows

/// One theme color: swatch, name, and hex, expanding into the picker.
struct ColorFieldRow: View {
    var label: String
    @Binding var hex: UInt32
    var skin: Skin

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ColorChip(hex: hex, skin: skin, size: CGSize(width: 30, height: 20))
                    Text(label)
                        .font(AppFont.ui(12))
                        .foregroundStyle(skin.textPrimary)
                    Spacer()
                    Text("#" + hex.hexString)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.textTertiary)
                    Glyph("chevron.down", size: 8)
                        .foregroundStyle(skin.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                CustomColorPickerPanel(hex: $hex, skin: skin)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
    }
}

/// An optional color: a well showing the color (or "none") and its hex,
/// a clear button, and the picker inline below when opened.
struct ColorWell: View {
    @Binding var value: UInt32?
    var skin: Skin
    /// What no color means here ("none", "theme").
    var noneLabel = "none"
    /// Shown in the picker before a color is set.
    var placeholder: UInt32 = 0xFFFFFF

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 8) {
                        if let value {
                            ColorChip(hex: value, skin: skin, size: CGSize(width: 18, height: 18))
                            Text("#" + value.hexString).foregroundStyle(skin.textPrimary)
                        } else {
                            NoneChip(skin: skin).frame(width: 18, height: 18)
                            Text(noneLabel).foregroundStyle(skin.textTertiary)
                        }
                        Spacer(minLength: 4)
                        Glyph("chevron.down", size: 8)
                            .foregroundStyle(skin.textTertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(AppFont.ui(11))
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .background(skin.textPrimary.opacity(open ? 0.07 : 0.04))
                    .overlay(Rectangle().strokeBorder(open ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.16), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if value != nil {
                    IconButton(icon: "window.close", size: 28, help: "Back to \(noneLabel)", skin: skin) {
                        withAnimation(.easeOut(duration: 0.15)) { value = nil }
                    }
                }
            }
            if open {
                CustomColorPickerPanel(hex: Binding(get: { value ?? placeholder }, set: { value = $0 }), skin: skin)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Panel

/// Saturation/brightness field, hue strip, hex entry, RGB channels, and
/// the saved colors.
struct CustomColorPickerPanel: View {
    @Binding var hex: UInt32
    var skin: Skin

    @ObservedObject private var saved = SavedColors.shared
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var hexText: String = ""
    @State private var didInit = false
    @FocusState private var editingHex: Bool

    private var hueBinding: Binding<Double> {
        Binding(get: { hue }, set: { hue = $0; pushHSBToHex() })
    }
    private var saturationBinding: Binding<Double> {
        Binding(get: { saturation }, set: { saturation = $0; pushHSBToHex() })
    }
    private var brightnessBinding: Binding<Double> {
        Binding(get: { brightness }, set: { brightness = $0; pushHSBToHex() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SaturationBrightnessField(hue: hue, saturation: saturationBinding, brightness: brightnessBinding, skin: skin)
                .frame(height: 120)

            HueSlider(hue: hueBinding, skin: skin)
                .frame(height: 12)

            HStack(spacing: 6) {
                ColorChip(hex: hex, skin: skin, size: CGSize(width: 28, height: 24))
                HStack(spacing: 2) {
                    Text("#").foregroundStyle(skin.textTertiary)
                    TextField("", text: $hexText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(skin.textPrimary)
                        .focused($editingHex)
                        .onSubmit(commitHexText)
                        .onChange(of: hexText) { text in
                            // Six digits apply as you type; anything else waits for Return.
                            if editingHex, let parsed = UInt32(hexColorString: text), text.filter(\.isHexDigit).count == 6 {
                                hex = parsed
                                syncFromHex(keepText: true)
                            }
                        }
                }
                .font(AppFont.ui(11.5))
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(Rectangle().fill(Color(white: 0, opacity: 0.35)))
                .overlay(Rectangle().strokeBorder(editingHex ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.16), lineWidth: 1))
                IconButton(icon: "doc.on.doc", size: 24, help: "Copy hex", skin: skin) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("#" + hex.hexString, forType: .string)
                }
                IconButton(icon: "plus", size: 24, help: saved.isFull ? "Saved colors are full (32)" : "Save this color", skin: skin) {
                    withAnimation(.easeOut(duration: 0.15)) { _ = saved.save(hex) }
                }
                .disabled(saved.isFull && !saved.colors.contains(hex))
            }

            rgbRow

            savedGrid
        }
        .padding(10)
        .background(Rectangle().fill(Color(white: 0, opacity: 0.35)))
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
        .onAppear {
            guard !didInit else { return }
            syncFromHex()
            didInit = true
        }
        .onChange(of: hex) { _ in
            if !editingHex, Color(hue: hue, saturation: saturation, brightness: brightness).toHex() != hex { syncFromHex() }
        }
    }

    // MARK: Saved

    private var savedGrid: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("saved")
                Spacer()
                Text("\(saved.colors.count)/\(SavedColors.capacity)")
            }
            .font(AppFont.ui(10))
            .foregroundStyle(skin.textTertiary)
            if saved.colors.isEmpty {
                Text("+ saves the current color here, for every picker.")
                    .font(AppFont.ui(10))
                    .foregroundStyle(skin.textTertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 14), spacing: 4), count: 8), spacing: 4) {
                    ForEach(saved.colors, id: \.self) { color in
                        Button {
                            hex = color
                            syncFromHex()
                        } label: {
                            Color(hex: color)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(Rectangle().strokeBorder(color == hex ? skin.accent : skin.textPrimary.opacity(0.2),
                                                                  lineWidth: color == hex ? 2 : 1))
                        }
                        .buttonStyle(PressDipStyle())
                        .help("#" + color.hexString + " · right-click to remove")
                        .appContextMenu {
                            MenuContent(title: "#" + color.hexString, entries: [
                                .action("Remove", glyph: "trash", destructive: true) {
                                    withAnimation(.easeOut(duration: 0.15)) { saved.remove(color) }
                                },
                            ])
                        }
                    }
                }
            }
        }
    }

    // MARK: RGB

    private var redChannel: Double { Double((hex >> 16) & 0xFF) }
    private var greenChannel: Double { Double((hex >> 8) & 0xFF) }
    private var blueChannel: Double { Double(hex & 0xFF) }

    private var rgbRow: some View {
        VStack(spacing: 5) {
            rgbSlider(label: "r", value: redChannel) { setRGB(r: $0, g: greenChannel, b: blueChannel) }
            rgbSlider(label: "g", value: greenChannel) { setRGB(r: redChannel, g: $0, b: blueChannel) }
            rgbSlider(label: "b", value: blueChannel) { setRGB(r: redChannel, g: greenChannel, b: $0) }
        }
    }

    private func rgbSlider(label: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(AppFont.ui(10))
                .foregroundStyle(skin.textTertiary)
                .frame(width: 10)
            RGBByteSlider(value: Binding(get: { value }, set: onChange), skin: skin)
                .frame(height: 10)
            Text("\(Int(value.rounded()))")
                .font(AppFont.ui(10))
                .foregroundStyle(skin.textSecondary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    private func setRGB(r: Double, g: Double, b: Double) {
        let rr = UInt32(min(255, max(0, r.rounded())))
        let gg = UInt32(min(255, max(0, g.rounded())))
        let bb = UInt32(min(255, max(0, b.rounded())))
        hex = (rr << 16) | (gg << 8) | bb
        syncFromHex()
    }

    private func pushHSBToHex() {
        let newHex = Color(hue: hue, saturation: saturation, brightness: brightness).toHex()
        hex = newHex
        hexText = newHex.hexString
    }

    private func syncFromHex(keepText: Bool = false) {
        let ns = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? NSColor(Color(hex: hex))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Grays have no hue; keep the strip where it was.
        if s > 0.001 { hue = Double(h) }
        saturation = Double(s)
        brightness = Double(b)
        if !keepText { hexText = hex.hexString }
    }

    private func commitHexText() {
        guard let parsed = UInt32(hexColorString: hexText) else {
            hexText = hex.hexString
            return
        }
        hex = parsed
        syncFromHex()
    }
}

// MARK: - Pieces

/// A color square with a 1px frame.
struct ColorChip: View {
    var hex: UInt32
    var skin: Skin
    var size: CGSize

    var body: some View {
        Rectangle()
            .fill(Color(hex: hex))
            .frame(width: size.width, height: size.height)
            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.22), lineWidth: 1))
    }
}

/// "No color": an empty square struck through.
private struct NoneChip: View {
    var skin: Skin

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 2, y: size.height - 2))
            p.addLine(to: CGPoint(x: size.width - 2, y: 2))
            ctx.stroke(p, with: .color(skin.textTertiary), lineWidth: 1)
        }
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.22), lineWidth: 1))
    }
}

/// A square thumb: white with a dark ring, legible on any color.
private struct SquareThumb: View {
    var size: CGFloat
    var body: some View {
        Rectangle()
            .strokeBorder(Color.white, lineWidth: 2)
            .background(Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1).padding(-1))
            .frame(width: size, height: size)
    }
}

/// A 0–255 channel slider.
private struct RGBByteSlider: View {
    @Binding var value: Double
    var skin: Skin

    var body: some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, value / 255))
            ZStack(alignment: .leading) {
                Rectangle().fill(skin.textPrimary.opacity(0.08))
                Rectangle().fill(skin.textPrimary.opacity(0.45))
                    .frame(width: geo.size.width * fraction)
                Rectangle().fill(skin.textPrimary)
                    .frame(width: 2, height: geo.size.height + 4)
                    .position(x: max(1, min(geo.size.width - 1, geo.size.width * fraction)), y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let x = min(max(0, drag.location.x), geo.size.width)
                value = geo.size.width > 0 ? Double(x / geo.size.width) * 255 : 0
            })
        }
    }
}

/// Saturation (x) by brightness (y) for a fixed hue.
private struct SaturationBrightnessField: View {
    var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    var skin: Skin

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                Rectangle().fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1)
                SquareThumb(size: 12)
                    .position(x: saturation * geo.size.width, y: (1 - brightness) * geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let x = min(max(0, drag.location.x), geo.size.width)
                let y = min(max(0, drag.location.y), geo.size.height)
                saturation = geo.size.width > 0 ? x / geo.size.width : 0
                brightness = geo.size.height > 0 ? 1.0 - Double(y / geo.size.height) : 0
            })
        }
    }
}

/// The full hue spectrum with a square thumb.
private struct HueSlider: View {
    @Binding var hue: Double
    var skin: Skin

    private let hueColors: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(LinearGradient(colors: hueColors, startPoint: .leading, endPoint: .trailing))
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
                SquareThumb(size: geo.size.height + 4)
                    .position(x: hue * geo.size.width, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let x = min(max(0, drag.location.x), geo.size.width)
                hue = geo.size.width > 0 ? x / geo.size.width : 0
            })
        }
    }
}
