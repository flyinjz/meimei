import SwiftUI

/// The "generate a theme" prompt: at least 8 colors in, a live preview of
/// the theme they make, and a name. Opened from the themes list.
struct ThemeGeneratorSheet: View {
    @ObservedObject var theme: ThemeManager
    var skin: Skin
    var onDone: () -> Void

    @ObservedObject private var saved = SavedColors.shared
    @State private var name = "Generated"
    @State private var colors: [UInt32]
    @State private var selected = 0
    @State private var mode: ThemeGenerator.Mode = .dark
    @State private var pasted = ""

    private static let maxColors = 16

    init(theme: ThemeManager, skin: Skin, onDone: @escaping () -> Void) {
        self.theme = theme
        self.skin = skin
        self.onDone = onDone
        let saved = SavedColors.shared.colors
        _colors = State(initialValue: saved.count >= ThemeGenerator.minimumColors
            ? Array(saved.prefix(Self.maxColors))
            : [skin.bgVoid, skin.bgPanel, skin.bgRaised, skin.hairline,
               skin.textTertiary, skin.textSecondary, skin.textPrimary, skin.accent].map { $0.toHex() })
    }

    private var distinct: Int { Set(colors).count }
    private var generated: CustomTheme? { ThemeGenerator.generate(name: name, colors: colors, mode: mode) }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(title: "Generate a theme",
                         subtitle: "At least 8 colors. The darkest become backgrounds, the lightest text, the most vivid the accent.",
                         skin: skin)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    slots
                    CustomColorPickerPanel(hex: Binding(get: { colors[selected] }, set: { colors[selected] = $0 }), skin: skin)
                        .id(selected)
                    sources
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 12) {
                    Text("name").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                    DialogTextField(placeholder: "Theme name", text: $name, skin: skin)
                    Text("mode").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                    SettingsSegmented(options: ThemeGenerator.Mode.allCases, selection: $mode, label: \.label, skin: skin)
                    Text("preview").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                    if let generated {
                        ThemePreview(theme: generated)
                    } else {
                        Text("Add \(ThemeGenerator.minimumColors - distinct) more different color\(ThemeGenerator.minimumColors - distinct == 1 ? "" : "s").")
                            .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 260)
            }
            .padding(.horizontal, 18)
            HStack {
                Text("[\(distinct) color\(distinct == 1 ? "" : "s")]").font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                Spacer()
                DialogButton(title: "Cancel", skin: skin, action: onDone)
                DialogButton(title: "Create theme", prominent: true, enabled: generated != nil, skin: skin) {
                    guard let generated else { return }
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    let id = theme.createTheme(named: trimmed.isEmpty ? "Generated" : trimmed, basedOn: generated)
                    theme.setActive(id)
                    onDone()
                }
            }
            .padding(18)
        }
        .frame(width: 612)
        .glassSheet(skin)
        .preferredColorScheme(.dark)
    }

    // MARK: Slots

    private var slots: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("colors").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                ForEach(colors.indices, id: \.self) { i in
                    Button { selected = i } label: {
                        Color(hex: colors[i])
                            .frame(width: 30, height: 30)
                            .overlay(Rectangle().strokeBorder(i == selected ? skin.accent : skin.textPrimary.opacity(0.22),
                                                              lineWidth: i == selected ? 2 : 1))
                    }
                    .buttonStyle(PressDipStyle())
                    .help("#" + colors[i].hexString + (colors.count > ThemeGenerator.minimumColors ? " · right-click to remove" : ""))
                    .appContextMenu {
                        MenuContent(title: "#" + colors[i].hexString, entries: [
                            .action("Remove", glyph: "trash", destructive: true,
                                    enabled: colors.count > ThemeGenerator.minimumColors) { remove(i) },
                        ])
                    }
                }
                if colors.count < Self.maxColors {
                    Button {
                        colors.append(colors[selected])
                        selected = colors.count - 1
                    } label: {
                        Glyph("plus", size: 11)
                            .foregroundStyle(skin.textSecondary)
                            .frame(width: 30, height: 30)
                            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                    .buttonStyle(PressDipStyle())
                    .help("Add a color (up to \(Self.maxColors))")
                }
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("or fill from").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
            HStack(spacing: 6) {
                DialogTextField(placeholder: "Paste hex codes…", text: $pasted, skin: skin)
                    .onSubmit(applyPasted)
                DialogButton(title: "Use", skin: skin, action: applyPasted)
            }
            DialogButton(title: "Saved colors (\(saved.colors.count))", enabled: !saved.colors.isEmpty, skin: skin) {
                fill(saved.colors)
            }
        }
    }

    private func applyPasted() {
        fill(ThemeGenerator.parseHexList(pasted))
        pasted = ""
    }

    private func fill(_ list: [UInt32]) {
        guard !list.isEmpty else { return }
        var unique: [UInt32] = []
        for c in list where !unique.contains(c) { unique.append(c) }
        // Fewer than eight keep the current ones after them.
        let padded = unique + colors.filter { !unique.contains($0) }
        colors = Array(padded.prefix(Self.maxColors))
        selected = 0
    }

    private func remove(_ i: Int) {
        guard colors.count > ThemeGenerator.minimumColors else { return }
        colors.remove(at: i)
        selected = min(selected, colors.count - 1)
    }
}

/// A miniature window in a theme's colors: a panel, rows, text levels, and
/// an accent button.
private struct ThemePreview: View {
    var theme: CustomTheme

    var body: some View {
        let s = theme.makeSkin()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("library").font(AppFont.ui(9.5)).foregroundStyle(s.textTertiary)
                Spacer()
                Text("Play")
                    .font(AppFont.ui(10, weight: .semibold))
                    .foregroundStyle(s.textOnAccent)
                    .padding(.horizontal, 8).frame(height: 18)
                    .background(s.accent)
            }
            .padding(8)
            .background(s.bgPanel)
            Rectangle().fill(s.hairline).frame(height: 1)
            row("Track title", "Artist", s.bgRow, s)
            row("Selected track", "Artist", s.selection, s)
            row("Another track", "Artist", s.bgRowAlt, s)
            HStack(spacing: 6) {
                Rectangle().fill(s.accent).frame(width: 40, height: 3)
                Rectangle().fill(s.accentDim).frame(width: 60, height: 3)
                Spacer()
                Text("2:55").font(AppFont.ui(9.5)).foregroundStyle(s.textTertiary)
            }
            .padding(8)
            .background(s.bgRaised)
        }
        .padding(8)
        .background(s.bgVoid)
        .overlay(Rectangle().strokeBorder(s.hairline, lineWidth: 1))
    }

    private func row(_ title: String, _ artist: String, _ bg: Color, _ s: Skin) -> some View {
        HStack {
            Text(title).foregroundStyle(s.textPrimary)
            Spacer()
            Text(artist).foregroundStyle(s.textSecondary)
        }
        .font(AppFont.ui(10.5))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(bg)
    }
}
