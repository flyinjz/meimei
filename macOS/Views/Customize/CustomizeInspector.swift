import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The floating editor in customize mode: the selection's properties, the
/// layout's layers, the app-wide design tokens, and saved workspaces.
struct CustomizeInspector: View {
    @ObservedObject var store: CustomizeStore
    @ObservedObject var cursor: CustomizeCursor
    @ObservedObject var settings: AppSettings
    var skin: Skin
    /// Off only for the debug snapshot, whose renderer can't draw scroll views.
    var scrolls = true

    enum Tab: String, CaseIterable { case element = "Element", layers = "Layers", global = "Global", workspaces = "Spaces" }
    @State private var tab: Tab

    init(store: CustomizeStore, cursor: CustomizeCursor, settings: AppSettings, skin: Skin, scrolls: Bool = true, tab: Tab? = nil) {
        self.store = store
        self.cursor = cursor
        self.settings = settings
        self.skin = skin
        self.scrolls = scrolls
        _tab = State(initialValue: tab ?? (cursor.primary == nil ? .layers : .element))
    }
    @State private var drag: CGSize = .zero
    @GestureState private var dragging: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SettingsSegmented(options: Tab.allCases, selection: $tab, label: \.rawValue, skin: skin)
                .padding(10)
            Rectangle().fill(skin.textPrimary.opacity(0.1)).frame(height: 1)
            if scrolls {
                ScrollView { content }
            } else {
                content
            }
        }
        .frame(width: 304)
        .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .background(Color.black.opacity(0.88))
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.22), lineWidth: 1))
        .fuiCorners(skin)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .background(GeometryReader { g in
            Color.clear.preference(key: InspectorFrameKey.self, value: g.frame(in: .named(CustomizeLayer.space)))
        })
        .padding(.bottom, 14)
        .offset(x: drag.width + dragging.width, y: drag.height + dragging.height)
        .onChange(of: cursor.selection) { s in if !s.isEmpty, tab != .element { tab = .element } }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch tab {
            case .element:
                if let primary = cursor.primary {
                    ElementEditor(element: primary, store: store, cursor: cursor, settings: settings, skin: skin)
                } else {
                    Text("Select something in the window, or pick it in Layers.")
                        .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                }
            case .layers:
                LayersEditor(store: store, cursor: cursor, settings: settings, skin: skin)
            case .global:
                GlobalEditor(store: store, settings: settings, skin: skin)
            case .workspaces:
                WorkspacesEditor(store: store, skin: skin)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(skin.textPrimary)
                .lineLimit(1)
            Spacer()
            IconButton(icon: "arrow.uturn.backward", size: 22, help: "Undo (⌘Z)", skin: skin) { store.undo() }
                .disabled(store.undoStack.isEmpty)
            IconButton(icon: "arrow.uturn.forward", size: 22, help: "Redo (⇧⌘Z)", skin: skin) { store.redo() }
                .disabled(store.redoStack.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(skin.textPrimary.opacity(0.04))
        .overlay(alignment: .bottom) { Rectangle().fill(skin.textPrimary.opacity(0.14)).frame(height: 1) }
        .contentShape(Rectangle())
        .gesture(DragGesture()
            .updating($dragging) { v, s, _ in s = v.translation }
            .onEnded { v in drag.width += v.translation.width; drag.height += v.translation.height })
        .help("Drag to move")
    }

    private var title: String {
        switch cursor.selection.count {
        case 0: return "inspector"
        case 1: return cursor.primary?.label ?? ""
        default: return "\(cursor.selection.count) selected"
        }
    }
}

// MARK: - Element

private struct ElementEditor: View {
    /// Passed in, not read from the cursor: this view observes the cursor
    /// itself and can re-render once more after the selection clears.
    let element: CustomElement
    @ObservedObject var store: CustomizeStore
    @ObservedObject var cursor: CustomizeCursor
    @ObservedObject var settings: AppSettings
    var skin: Skin

    private var targets: [CustomElement] { cursor.targets.isEmpty ? [element] : cursor.targets }
    private var style: ElementStyle { store.storedStyle(element) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if cursor.selection.count > targets.count {
                Text("Editing the \(targets.count) selected \(element.kind == .text ? "text" : "panel") elements.")
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
            }
            switch element.kind {
            case .text: typography
            case .panel: surface
            case .controls: WindowControlSettingsEditor(settings: settings, skin: skin)
            }
            if element.kind != .controls { actions }
        }
    }

    private func edit(_ key: String? = nil, _ body: (inout ElementStyle) -> Void) {
        store.edit(targets, coalesce: key, body)
    }

    // MARK: Text

    @ViewBuilder
    private var typography: some View {
        Group {
            PropertyRow("font", set: style.font != nil, skin: skin, reset: { edit { $0.font = nil } }) {
                FontMenu(selection: style.font ?? settings.data.fontFamily, skin: skin) { family in
                    edit { $0.font = family == settings.data.fontFamily ? nil : family }
                }
            }
            PropertyRow("size", set: style.sizeScale != nil, skin: skin, reset: { edit { $0.sizeScale = nil } }) {
                SliderField(value: style.sizeScale ?? 1, range: 0.6...2.5, skin: skin,
                            format: { "\(Int(($0 * 100).rounded()))%" }, parse: { Double($0).map { $0 / 100 } }) { v in
                    edit("size") { $0.sizeScale = v }
                }
            }
        }
        if element != .tableText {
            PropertyRow("weight", set: style.weight != nil, skin: skin, reset: { edit { $0.weight = nil } }) {
                SettingsSegmented(options: TextWeight.allCases, selection: Binding(get: { style.weight ?? .light }, set: { w in edit { $0.weight = w } }),
                                  label: \.rawValue, skin: skin)
            }
            PropertyRow("color", set: style.color != nil, skin: skin, reset: { edit { $0.color = nil } }) {
                ColorWell(value: Binding(get: { style.color }, set: { c in edit { $0.color = c } }), skin: skin)
                if let c = style.color { ContrastBadge(foreground: Color(hex: c), background: Color(white: 0.06), skin: skin) }
            }
            PropertyRow("opacity", set: style.opacity != nil, skin: skin, reset: { edit { $0.opacity = nil } }) {
                SliderField(value: style.opacity ?? 1, range: 0.15...1, skin: skin,
                            format: { "\(Int(($0 * 100).rounded()))%" }, parse: { Double($0).map { $0 / 100 } }) { v in
                    edit("opacity") { $0.opacity = v }
                }
            }
            PropertyRow("letter spacing", set: style.tracking != nil, skin: skin, reset: { edit { $0.tracking = nil } }) {
                SliderField(value: style.tracking ?? 0, range: -1...4, skin: skin,
                            format: { String(format: "%.1f pt", $0) }, parse: { Double($0) }) { v in
                    edit("tracking") { $0.tracking = v }
                }
            }
            if element.isTitle {
                PropertyRow("alignment", set: style.align != nil, skin: skin, reset: { edit { $0.align = nil } }) {
                    SettingsSegmented(options: TextAlign.allCases, selection: Binding(get: { style.align ?? .leading }, set: { a in edit { $0.align = a } }),
                                      label: \.rawValue, skin: skin)
                }
                PropertyRow("lines", set: style.lines != nil, skin: skin, reset: { edit { $0.lines = nil } }) {
                    SettingsSegmented(options: [1, 2, 3], selection: Binding<Int>(get: { style.lines ?? 1 }, set: { n in edit { $0.lines = n } }),
                                      label: { "\($0)" }, skin: skin)
                }
            }
            PropertyRow("legibility shadow", set: style.shadow != nil, skin: skin, reset: { edit { $0.shadow = nil } }) {
                ToggleRow(title: "Soft shadow behind the text, for busy backdrops", isOn: Binding(get: { style.shadow ?? false }, set: { v in edit { $0.shadow = v } }), skin: skin)
            }
        }
    }

    // MARK: Panel

    @ViewBuilder
    private var surface: some View {
        if let pane = element.pane, pane != .library {
            PropertyRow("visible", set: store.layout.hidden.contains(pane), skin: skin, reset: { store.setHidden(pane, false) }) {
                ToggleRow(title: "Show this panel", isOn: Binding(get: { !store.layout.hidden.contains(pane) }, set: { store.setHidden(pane, !$0) }), skin: skin)
            }
        }
        PropertyRow("fill", set: style.fill != nil, skin: skin, reset: { edit { $0.fill = nil; $0.fillOpacity = nil } }) {
            ColorWell(value: Binding(get: { style.fill }, set: { c in edit { $0.fill = c } }), skin: skin)
            if style.fill != nil {
                SliderField(value: style.fillOpacity ?? 0.5, range: 0.05...1, skin: skin,
                            format: { "\(Int(($0 * 100).rounded()))%" }, parse: { Double($0).map { $0 / 100 } }) { v in
                    edit("fillOpacity") { $0.fillOpacity = v }
                }
            }
        }
        PropertyRow("border", set: style.border != nil, skin: skin, reset: { edit { $0.border = nil; $0.borderWidth = nil; $0.borderSides = nil } }) {
            ColorWell(value: Binding(get: { style.border }, set: { c in edit { $0.border = c } }), skin: skin)
            if style.border != nil {
                SettingsSegmented(options: [1.0, 2.0, 3.0], selection: Binding(get: { style.borderWidth ?? 1 }, set: { w in edit { $0.borderWidth = w } }),
                                  label: { "\(Int($0)) px" }, skin: skin)
                SidesPicker(sides: Binding(get: { style.borderSides ?? .all }, set: { s in edit { $0.borderSides = s } }), skin: skin)
            }
        }
        if element != .tableHeader {
        PropertyRow("corner ticks", set: style.ticks != nil, skin: skin, reset: { edit { $0.ticks = nil } }) {
            SettingsSegmented(options: ["global", "on", "off"],
                              selection: Binding(get: { style.ticks.map { $0 ? "on" : "off" } ?? "global" },
                                                 set: { v in edit { $0.ticks = v == "global" ? nil : v == "on" } }),
                              label: { $0 }, skin: skin)
        }
        PropertyRow("inner padding", set: style.padding != nil, skin: skin, reset: { edit { $0.padding = nil } }) {
            SliderField(value: style.padding ?? 0, range: 0...24, skin: skin, format: { "\(Int($0)) pt" }, parse: { Double($0) }) { v in
                edit("padding") { $0.padding = v.rounded() }
            }
        }
        PropertyRow("depth", set: style.depth != nil, skin: skin, reset: { edit { $0.depth = nil } }) {
            SettingsSegmented(options: [0, 1, 2, 3], selection: Binding<Int>(get: { style.depth ?? 0 }, set: { d in edit { $0.depth = d == 0 ? nil : d } }),
                              label: { $0 == 0 ? "flat" : "\($0)" }, skin: skin)
        }
        }
        if element == .tableHeader {
            PropertyRow("height", set: style.height != nil, skin: skin, reset: { edit { $0.height = nil } }) {
                SliderField(value: style.height ?? Double(TableHeaderLook.defaultHeight), range: 18...44, skin: skin,
                            format: { "\(Int($0)) pt" }, parse: { Double($0) }) { v in
                    edit("height") { $0.height = v.rounded() }
                }
            }
        }
        if element == .playerBar || element == .statusBar {
            let base = element == .statusBar ? 28.0 : Double(settings.data.playerBarStyle.height)
            PropertyRow("height", set: style.height != nil, skin: skin, reset: { edit { $0.height = nil } }) {
                SliderField(value: style.height ?? base, range: element == .statusBar ? 20...48 : 40...140, skin: skin,
                            format: { "\(Int($0)) pt" }, parse: { Double($0) }) { v in
                    edit("height") { $0.height = v.rounded() }
                }
            }
        }
        if let pane = element.pane, let c = store.layout.columnIndex(of: pane), !store.layout.columns[c].panes.contains(.library) {
            PropertyRow("column width", set: store.layout.columns[c].width != nil, skin: skin, reset: {}) {
                SliderField(value: store.layout.columns[c].width ?? 280, range: 160...560, skin: skin,
                            format: { "\(Int($0)) pt" }, parse: { Double($0) }) { v in
                    store.setColumnWidth(c, v.rounded())
                }
            }
        }
        if element == .playerBar {
            PropertyRow("position", set: false, skin: skin, reset: {}) {
                SettingsSegmented(options: PlayerBarPosition.allCases, selection: $settings.data.playerBarPosition,
                                  label: { $0.rawValue }, skin: skin)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Copy") { store.copyStyle(element) }
                .help("Copy this style (⌘C)")
            Button("Paste") { store.pasteStyle(into: cursor.selection) }
                .disabled(store.clipboard?.kind != element.kind)
                .help("Paste the copied style onto the selection (⌘V)")
            Spacer()
            Button("Reset") { store.reset(targets) }
                .disabled(targets.allSatisfy { store.storedStyle($0).isEmpty })
                .help("Back to the design (⌫)")
        }
        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
    }

}

// MARK: - Layers

private struct LayersEditor: View {
    @ObservedObject var store: CustomizeStore
    @ObservedObject var cursor: CustomizeCursor
    @ObservedObject var settings: AppSettings
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("bars") {
                row(.playerBar, detail: settings.data.playerBarPosition == .top ? "top" : "bottom")
                row(.statusBar, detail: settings.data.showStatusBar ? nil : "off in settings")
            }
            section("columns") {
                ForEach(Array(store.layout.columns.enumerated()), id: \.element.id) { i, column in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("col \(i + 1) · \(column.panes.contains(.library) ? "stretches" : column.width.map { "\(Int($0)) pt" } ?? "default width")")
                            .font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                        ForEach(column.panes) { pane in
                            row(pane.element, pane: pane, indent: true)
                        }
                    }
                }
                Button("Reset layout") { store.resetLayout() }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    .padding(.top, 4)
            }
            section("text") {
                ForEach(CustomElement.allCases.filter { $0.kind == .text }) { row($0) }
            }
            section("window") {
                row(.windowControls, detail: settings.data.systemWindowFrame ? "system frame in use" : nil)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppFont.ui(10.5, weight: .medium)).foregroundStyle(skin.textTertiary)
            content()
        }
    }

    private func row(_ element: CustomElement, pane: PaneID? = nil, detail: String? = nil, indent: Bool = false) -> some View {
        let selected = cursor.selection.contains(element)
        let changed = !store.storedStyle(element).isEmpty
        let hidden = pane.map { store.layout.hidden.contains($0) } ?? false
        return HStack(spacing: 6) {
            Rectangle().fill(changed ? skin.accent : .clear).frame(width: 5, height: 5)
            Text(element.label)
                .font(AppFont.ui(11.5))
                .foregroundStyle(hidden ? skin.textTertiary : (selected ? skin.textPrimary : skin.textSecondary))
                .strikethrough(hidden)
            if let detail { Text(detail).font(AppFont.ui(10)).foregroundStyle(skin.textTertiary) }
            Spacer()
            if let pane, pane != .library {
                Button { store.setHidden(pane, !hidden) } label: {
                    Glyph(hidden ? "circle" : "checkmark.circle.fill", size: 12)
                        .foregroundStyle(hidden ? skin.textTertiary : skin.accent)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDipStyle())
                .help(hidden ? "Show" : "Hide")
            }
        }
        .padding(.leading, indent ? 10 : 2)
        .padding(.trailing, 2)
        .frame(height: 24)
        .background(selected ? skin.accent.opacity(0.14) : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(skin.accent).frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { cursor.select(element, extending: NSEvent.modifierFlags.contains(.shift)) }
    }
}

// MARK: - Global

private struct GlobalEditor: View {
    @ObservedObject var store: CustomizeStore
    @ObservedObject var settings: AppSettings
    var skin: Skin

    private var t: DesignTokens { store.storedTokens }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PropertyRow("accent", set: t.accent != nil, skin: skin, reset: { store.editTokens { $0.accent = nil } }) {
                ColorWell(value: Binding(get: { t.accent }, set: { c in store.editTokens { $0.accent = c } }), skin: skin, noneLabel: "theme")
            }
            PropertyRow("gray tone", set: t.tone != .neutral, skin: skin, reset: { store.editTokens { $0.tone = .neutral } }) {
                SettingsSegmented(options: GrayTone.allCases, selection: Binding(get: { t.tone }, set: { v in store.editTokens { $0.tone = v } }),
                                  label: \.rawValue, skin: skin)
            }
            PropertyRow("text scale", set: t.textScale != 1, skin: skin, reset: { store.editTokens { $0.textScale = 1 } }) {
                SliderField(value: t.textScale, range: DesignTokens.textScaleRange, skin: skin,
                            format: { "\(Int(($0 * 100).rounded()))%" }, parse: { Double($0).map { $0 / 100 } }) { v in
                    store.editTokens(coalesce: "textScale") { $0.textScale = v }
                }
            }
            PropertyRow("grid gap", set: t.gap != 6, skin: skin, reset: { store.editTokens { $0.gap = 6 } }) {
                SliderField(value: t.gap, range: DesignTokens.gapRange, skin: skin, format: { "\(Int($0)) pt" }, parse: { Double($0) }) { v in
                    store.editTokens(coalesce: "gap") { $0.gap = v.rounded() }
                }
            }
            PropertyRow("panel opacity", set: t.panelOpacity != 0.46, skin: skin, reset: { store.editTokens { $0.panelOpacity = 0.46 } }) {
                SliderField(value: t.panelOpacity, range: 0.1...0.95, skin: skin,
                            format: { "\(Int(($0 * 100).rounded()))%" }, parse: { Double($0).map { $0 / 100 } }) { v in
                    store.editTokens(coalesce: "panelOpacity") { $0.panelOpacity = v }
                }
            }
            PropertyRow("border width", set: t.borderWidth != 1, skin: skin, reset: { store.editTokens { $0.borderWidth = 1 } }) {
                SettingsSegmented(options: [0.0, 1.0, 2.0], selection: Binding(get: { t.borderWidth }, set: { v in store.editTokens { $0.borderWidth = v } }),
                                  label: { $0 == 0 ? "none" : "\(Int($0)) px" }, skin: skin)
            }
            PropertyRow("corner ticks", set: !t.cornerTicks || t.tickLength != 7, skin: skin,
                        reset: { store.editTokens { $0.cornerTicks = true; $0.tickLength = 7 } }) {
                ToggleRow(title: "Registration marks on panel corners", isOn: Binding(get: { t.cornerTicks }, set: { v in store.editTokens { $0.cornerTicks = v } }), skin: skin)
                if t.cornerTicks {
                    SliderField(value: t.tickLength, range: 3...20, skin: skin, format: { "\(Int($0)) pt" }, parse: { Double($0) }) { v in
                        store.editTokens(coalesce: "tick") { $0.tickLength = v.rounded() }
                    }
                }
            }
            PropertyRow("typeface", set: settings.data.fontFamily != .geistMono, skin: skin, reset: { settings.data.fontFamily = .geistMono }) {
                FontMenu(selection: settings.data.fontFamily, skin: skin) { settings.data.fontFamily = $0 }
            }
            PropertyRow("icons", set: settings.data.iconPack != .material || settings.data.iconScale != 1, skin: skin, reset: {
                settings.data.iconPack = .material
                settings.data.iconScale = 1
            }) {
                IconPackMenu(settings: settings, skin: skin)
                IconEditButton(settings: settings, skin: skin)
                SliderField(value: settings.data.iconScale, range: 0.8...1.25, skin: skin,
                            format: { "\(Int(($0 * 100).rounded()))%" }, parse: { Double($0).map { $0 / 100 } }) { v in
                    settings.data.iconScale = v
                }
            }
            PropertyRow("buttons", set: settings.data.buttonFill != .solid || settings.data.buttonContent != .iconAndText
                        || settings.data.buttonSize != .regular || !settings.data.buttonAccentPrimary, skin: skin, reset: {
                settings.data.buttonFill = .solid
                settings.data.buttonContent = .iconAndText
                settings.data.buttonSize = .regular
                settings.data.buttonAccentPrimary = true
            }) {
                ButtonSettingsEditor(settings: settings, skin: skin)
            }
            PropertyRow("window buttons", set: WindowControlSettingsEditor.isCustomized(settings.data), skin: skin, reset: {
                WindowControlSettingsEditor.reset(settings)
            }) {
                WindowControlSettingsEditor(settings: settings, skin: skin)
            }
            PropertyRow("backdrop", set: false, skin: skin, reset: {}) {
                SettingsSegmented(options: BackdropStyle.allCases, selection: $settings.data.backdropStyle, label: \.label, skin: skin)
            }
            PropertyRow("panels", set: false, skin: skin, reset: {}) {
                SettingsSegmented(options: SurfaceStyle.allCases, selection: $settings.data.surfaceStyle, label: \.label, skin: skin)
            }
            PropertyRow("density", set: false, skin: skin, reset: {}) {
                SettingsSegmented(options: LayoutDensity.allCases, selection: $settings.data.density, label: { $0.rawValue }, skin: skin)
            }
            Button("Reset everything") { store.resetAll() }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                .help("Styles, layout, and tokens back to the design. ⌘Z undoes it.")
        }
    }
}

// MARK: - Workspaces

private struct WorkspacesEditor: View {
    @ObservedObject var store: CustomizeStore
    var skin: Skin
    @State private var newName = ""
    @State private var renaming: UUID?
    @State private var draft = ""
    @State private var importFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A workspace keeps a layout, its tokens, and every style. Switch with ⌃1 to ⌃9.")
                .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if store.activeWorkspaceID == nil, !store.workspaces.isEmpty {
                Text("current look: unsaved")
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.accent)
            }
            VStack(spacing: 4) {
                ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { i, ws in row(ws, index: i) }
            }
            HStack(spacing: 6) {
                TextField("New workspace", text: $newName)
                    .textFieldStyle(.plain)
                    .font(AppFont.ui(11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.22), lineWidth: 1))
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
            }
            Rectangle().fill(skin.textPrimary.opacity(0.1)).frame(height: 1)
            Text("style files").font(AppFont.ui(10.5, weight: .medium)).foregroundStyle(skin.textTertiary)
            HStack(spacing: 6) {
                Button("Export…", action: export)
                Button("Import…", action: importStyle)
            }
            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            if importFailed {
                Text("That file isn't an i2s style.").font(AppFont.ui(10.5)).foregroundStyle(skin.accent)
            }
        }
    }

    private func save() {
        store.saveWorkspace(named: newName)
        newName = ""
    }

    private func workspaceMenu(_ ws: Workspace, index: Int) -> MenuContent {
        MenuContent(title: ws.name, [
            MenuGroup(nil, [
                .action("Apply", glyph: "checkmark.circle.fill") { store.applyWorkspace(ws.id) },
                .action("Update with Current Look", glyph: "arrow.counterclockwise") { store.updateWorkspace(ws.id) },
                .action("Rename…", glyph: "text.alignleft") { draft = ws.name; renaming = ws.id },
            ]),
            MenuGroup(nil, [
                .action("Move Up", glyph: "chevron.up", enabled: index > 0) { store.moveWorkspace(at: index, by: -1) },
                .action("Move Down", glyph: "chevron.down", enabled: index < store.workspaces.count - 1) { store.moveWorkspace(at: index, by: 1) },
            ]),
            MenuGroup(nil, [.action("Delete", glyph: "trash", destructive: true) { store.deleteWorkspace(ws.id) }]),
        ])
    }

    private func row(_ ws: Workspace, index: Int) -> some View {
        let active = store.activeWorkspaceID == ws.id
        return HStack(spacing: 6) {
            Text(index < 9 ? "⌃\(index + 1)" : "  ")
                .font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                .frame(width: 22, alignment: .leading)
            if renaming == ws.id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(AppFont.ui(11.5))
                    .onSubmit { store.renameWorkspace(ws.id, to: draft); renaming = nil }
                    .onExitCommand { renaming = nil }
            } else {
                Text(ws.name)
                    .font(AppFont.ui(11.5))
                    .foregroundStyle(active ? skin.textPrimary : skin.textSecondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { draft = ws.name; renaming = ws.id }
            }
            Spacer()
            MenuButton(content: { workspaceMenu(ws, index: index) }) {
                Glyph("ellipsis", size: 12).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(active ? skin.accent.opacity(0.14) : skin.textPrimary.opacity(0.03))
        .overlay(Rectangle().strokeBorder(active ? skin.accent.opacity(0.7) : skin.textPrimary.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { store.applyWorkspace(ws.id) }
        .appContextMenu { workspaceMenu(ws, index: index) }
        .help("Click to apply · double-click the name to rename")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "i2s Style.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exportData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importStyle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        importFailed = !store.importData(data)
    }
}

// MARK: - Pieces

/// A titled property. The square beside the title lights up when the
/// property differs from the design; clicking it resets just that property.
private struct PropertyRow<Content: View>: View {
    var title: String
    var set: Bool
    var skin: Skin
    var reset: () -> Void
    var content: Content

    init(_ title: String, set: Bool, skin: Skin, reset: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.set = set
        self.skin = skin
        self.reset = reset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(AppFont.ui(10.5, weight: .medium)).foregroundStyle(skin.textTertiary)
                if set {
                    Button(action: reset) {
                        Rectangle().fill(skin.accent).frame(width: 6, height: 6)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDipStyle())
                    .help("Changed from the design. Click to reset.")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            content
        }
        .animation(.easeOut(duration: 0.15), value: set)
    }
}

/// A slider with its value beside it; click the value to type an exact one.
private struct SliderField: View {
    var value: Double
    var range: ClosedRange<Double>
    var skin: Skin
    var format: (Double) -> String
    var parse: (String) -> Double?
    var set: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            MinimalSlider(value: Binding(get: { value }, set: { set(range.clamp($0)) }), range: range, skin: skin, style: .knob)
            EditableValue(text: format(value), skin: skin, width: 62,
                          parse: { s in parse(s.trimmingCharacters(in: CharacterSet(charactersIn: "%pt ").union(.whitespaces))) }) {
                set(range.clamp($0))
            }
        }
        .frame(height: 20)
    }
}

/// A title and a switch.
private struct ToggleRow: View {
    var title: String
    @Binding var isOn: Bool
    var skin: Skin

    var body: some View {
        HStack(alignment: .top) {
            Text(title).font(AppFont.ui(11)).foregroundStyle(skin.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            SettingsToggleSwitch(isOn: $isOn, skin: skin)
        }
    }
}

/// Four toggles for which edges a border draws on.
private struct SidesPicker: View {
    @Binding var sides: BorderSides
    var skin: Skin

    var body: some View {
        HStack(spacing: 4) {
            ForEach([("top", BorderSides.top), ("bottom", .bottom), ("left", .leading), ("right", .trailing)], id: \.0) { name, side in
                let on = sides.contains(side)
                Button(name) {
                    var s = sides
                    if on { s.remove(side) } else { s.insert(side) }
                    if !s.isEmpty { sides = s }
                }
                .buttonStyle(PillButtonStyle(skin: skin, isActive: on, compact: true))
            }
        }
    }
}

/// The WCAG contrast of a text color against the panel it sits on.
private struct ContrastBadge: View {
    var foreground: Color
    var background: Color
    var skin: Skin

    var body: some View {
        let ratio = foreground.contrast(with: background)
        let grade = ratio >= 7 ? "AAA" : ratio >= 4.5 ? "AA" : ratio >= 3 ? "AA large" : "low"
        HStack(spacing: 6) {
            Text(String(format: "%.1f:1", ratio))
            Text(grade).foregroundStyle(ratio >= 4.5 ? skin.accent : Color(red: 1, green: 0.55, blue: 0.4))
        }
        .font(AppFont.ui(10))
        .foregroundStyle(skin.textSecondary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
        .help("Contrast against the dark panel. 4.5:1 or more reads comfortably at any size.")
    }
}

