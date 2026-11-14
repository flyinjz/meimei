import SwiftUI

/// Icon pack, size, and per-icon choices (Settings → Appearance, and
/// Customize → Global).
struct IconSettingsEditor: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin
    @State private var editing = false

    static let previewRoles = ["play.fill", "pause.fill", "backward.fill", "shuffle", "repeat", "heart", "magnifyingglass", "gearshape"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(IconPack.allCases) { pack in packTile(pack) }
            }
            SettingsSliderRow(title: "Icon size", value: $settings.data.iconScale, range: 0.8...1.25, skin: skin,
                              sliderStyle: settings.data.sliderStyle) { "\(Int(($0 * 100).rounded()))%" }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Individual icons").font(AppFont.ui(12))
                    Text(settings.data.iconOverrides.isEmpty ? "None changed" : "\(settings.data.iconOverrides.count) changed")
                        .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                }
                Spacer()
                Button("Edit Icons…") { editing = true }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
        }
        .sheet(isPresented: $editing) {
            IconOverridesSheet(settings: settings, skin: skin) { editing = false }
        }
    }

    private func packTile(_ pack: IconPack) -> some View {
        let selected = settings.data.iconPack == pack
        return Button { settings.data.iconPack = pack } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(pack.label).font(AppFont.ui(11.5, weight: selected ? .semibold : .regular))
                    Spacer()
                    if selected { Text("[in use]").font(AppFont.ui(10)).foregroundStyle(skin.accent) }
                }
                HStack(spacing: 9) {
                    ForEach(Self.previewRoles, id: \.self) { role in
                        if let code = pack.table[role] ?? Glyph.codes[role] { CodeGlyph(code: code, size: 14) }
                    }
                }
                .foregroundStyle(selected ? skin.textPrimary : skin.textSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(selected ? skin.accent.opacity(0.1) : skin.textPrimary.opacity(0.03)))
            .overlay(Rectangle().strokeBorder(selected ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Every icon role, and a browser of the whole symbol set to change any
/// one of them.
struct IconOverridesSheet: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin
    var onDone: () -> Void

    @ObservedObject private var theme = IconTheme.shared
    @State private var selected: String

    init(settings: AppSettings, skin: Skin, initialRole: String = "play.fill", onDone: @escaping () -> Void) {
        self.settings = settings
        self.skin = skin
        self.onDone = onDone
        _selected = State(initialValue: initialRole)
    }
    @State private var roleQuery = ""
    @State private var glyphQuery = ""
    @State private var set = "all"
    @State private var glyphs: [(code: UInt32, name: String)] = []

    private static let sets: [(id: String, label: String)] = [
        ("all", "All"), ("md", "Material"), ("cod", "Codicons"), ("fa", "Font Awesome"), ("oct", "Octicons"), ("other", "Other"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: "Icons", skin: skin)
            HStack(alignment: .top, spacing: Corners.inset) {
                roleList
                    .padding(8)
                    .frame(width: 260)
                    .frostedPane(skin, tint: GlassWindow.railTint)
                browser
                    .padding(10)
                    .frostedPane(skin, tint: GlassWindow.pageTint)
            }
            .padding(.horizontal, Corners.inset)
            HStack {
                Button("Reset All Icons") { settings.data.iconOverrides = [:] }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    .disabled(settings.data.iconOverrides.isEmpty)
                Spacer()
                DialogButton(title: "Done", prominent: true, skin: skin, action: onDone)
            }
            .padding(18)
        }
        .frame(width: 820, height: 600)
        .glassSheet(skin)
        .task {
            if glyphs.isEmpty { glyphs = await Task.detached(priority: .userInitiated) { IconTheme.allGlyphs() }.value }
        }
    }

    // MARK: Roles

    private var roleList: some View {
        VStack(spacing: 6) {
            DialogTextField(placeholder: "Find an icon", text: $roleQuery, skin: skin)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(roles, id: \.self) { role in
                        Button { selected = role } label: {
                            HStack(spacing: 10) {
                                Glyph(role, size: 15).frame(width: 22)
                                Text(IconRoles.name(role)).font(AppFont.ui(11.5)).lineLimit(1)
                                Spacer()
                                if settings.data.iconOverrides[role] != nil {
                                    Text("[custom]").font(AppFont.ui(9.5)).foregroundStyle(skin.accent)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(role == selected ? skin.selection.opacity(0.6) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(height: 470)
    }

    // MARK: Browser

    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Glyph(selected, size: 34)
                    .frame(width: 52, height: 52)
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(IconRoles.name(selected)).font(AppFont.ui(12.5, weight: .semibold))
                    Text(IconRoles.usedFor(selected)).font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary)
                    Text(currentName).font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                }
                Spacer()
                Button("Use Pack Icon") { settings.data.iconOverrides[selected] = nil }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    .disabled(settings.data.iconOverrides[selected] == nil)
            }
            HStack(spacing: 6) {
                DialogTextField(placeholder: "Search \(glyphs.count) glyphs (e.g. play, heart, folder)", text: $glyphQuery, skin: skin)
                PopUpMenuButton(items: Self.sets.map { s in PopUpMenuButton.Item(title: s.label, checked: set == s.id) { set = s.id } }) {
                    HStack(spacing: 6) {
                        Text(Self.sets.first { $0.id == set }?.label ?? "All").font(AppFont.ui(11))
                        Glyph("chevron.down", size: 8)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            let shown = filtered
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 12), spacing: 4) {
                    ForEach(shown, id: \.code) { g in
                        let current = theme.code(for: selected) == g.code
                        Button { settings.data.iconOverrides[selected] = g.code } label: {
                            CodeGlyph(code: g.code, size: 18)
                                .frame(width: 40, height: 40)
                                .background(current ? skin.accent.opacity(0.18) : skin.textPrimary.opacity(0.03))
                                .overlay(Rectangle().strokeBorder(current ? skin.accent : skin.textPrimary.opacity(0.08), lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(g.name)
                    }
                }
            }
            Text(glyphs.isEmpty ? "Loading glyphs…" : "\(shown.count) shown" + (shown.count == 600 ? " (refine the search to see more)" : ""))
                .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
        }
        .frame(height: 470)
    }

    /// Roles in name order, matched by name, place, or role id.
    private var roles: [String] {
        IconTheme.roles
            .filter { r in
                roleQuery.isEmpty || [IconRoles.name(r), IconRoles.usedFor(r), r].contains { $0.localizedCaseInsensitiveContains(roleQuery) }
            }
            .sorted { IconRoles.name($0).localizedStandardCompare(IconRoles.name($1)) == .orderedAscending }
    }

    private var currentName: String {
        guard let code = theme.code(for: selected) else { return "" }
        let name = glyphs.first { $0.code == code }?.name ?? String(format: "U+%X", code)
        return (settings.data.iconOverrides[selected] != nil ? "custom · " : "\(theme.pack.label) · ") + name
    }

    /// Matches by words in the glyph name; capped so the grid stays light.
    private var filtered: [(code: UInt32, name: String)] {
        let words = glyphQuery.lowercased().split(separator: " ").map(String.init)
        let known = ["md", "cod", "fa", "oct"]
        let hits = glyphs.filter { g in
            let prefix = g.name.split(separator: "-").first.map(String.init) ?? ""
            let inSet = set == "all" || (set == "other" ? !known.contains(prefix) : prefix == set)
            return inSet && words.allSatisfy { g.name.lowercased().contains($0) }
        }
        return Array(hits.prefix(600))
    }
}

/// The icon pack as a compact dropdown field, for narrow places.
struct IconPackMenu: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin

    var body: some View {
        PopUpMenuButton(items: IconPack.allCases.map { pack in
            PopUpMenuButton.Item(title: pack.label, checked: settings.data.iconPack == pack) { settings.data.iconPack = pack }
        }) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(IconSettingsEditor.previewRoles.prefix(4), id: \.self) { role in
                        if let code = settings.data.iconPack.table[role] ?? Glyph.codes[role] { CodeGlyph(code: code, size: 12) }
                    }
                }
                .foregroundStyle(skin.textSecondary)
                Text(settings.data.iconPack.label).font(AppFont.ui(12)).foregroundStyle(skin.textPrimary)
                Spacer()
                Glyph("chevron.down", size: 8).foregroundStyle(skin.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Rectangle().fill(skin.textPrimary.opacity(0.045)))
            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Opens the icon editor from narrow places (Customize).
struct IconEditButton: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin
    @State private var editing = false

    var body: some View {
        Button(settings.data.iconOverrides.isEmpty ? "Edit Individual Icons…" : "Edit Individual Icons… (\(settings.data.iconOverrides.count) changed)") {
            editing = true
        }
        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
        .sheet(isPresented: $editing) {
            IconOverridesSheet(settings: settings, skin: skin) { editing = false }
        }
    }
}
