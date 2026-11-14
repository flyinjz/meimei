import SwiftUI

/// Creates a playlist (manual or smart) or edits an existing one.
struct PlaylistEditorSheet: View {
    @ObservedObject var library: LibraryStore
    var existingID: UUID?
    /// Tracks a new manual playlist starts with (New Playlist from Selection).
    var initialTrackIDs: [UUID] = []
    var skin: Skin
    var onDismiss: () -> Void

    @State private var name = ""
    @State private var isSmart = false
    @State private var matchAll = true
    @State private var rules: [SmartRule] = [SmartRule()]
    @State private var order: SmartOrder = .library
    @State private var limitEnabled = false
    @State private var limit = "25"

    private var existing: Playlist? { existingID.flatMap(library.playlist(id:)) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var title: String {
        guard let existing else { return initialTrackIDs.isEmpty ? "New Playlist" : "New Playlist from Selection" }
        return existing.isSmart ? "Edit Smart Playlist" : "Rename Playlist"
    }

    private var subtitle: String {
        if isSmart { return "Matches update automatically as your library changes." }
        if !initialTrackIDs.isEmpty { return initialTrackIDs.count == 1 ? "Starts with 1 track." : "Starts with \(initialTrackIDs.count) tracks." }
        return "Add tracks by dragging them onto it, or right-click → Add to Playlist."
    }

    private var previewCount: Int {
        let draft = Playlist(name: "", isSmart: true, matchAll: matchAll, rules: rules, smartOrder: order, smartLimit: limitValue)
        return draft.resolveSmart(from: library.tracks).count
    }

    private var limitValue: Int? { limitEnabled ? Int(limit).flatMap { $0 > 0 ? $0 : nil } : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: title, subtitle: subtitle, skin: skin)
            Hairline(color: skin.hairline)

            VStack(alignment: .leading, spacing: 14) {
                DialogTextField(placeholder: "Name", text: $name, skin: skin)

                if existing == nil && initialTrackIDs.isEmpty {
                    SettingsSegmented(options: [false, true], selection: $isSmart, label: { $0 ? "Smart Playlist" : "Playlist" }, skin: skin)
                }

                if isSmart { smartEditor }
            }
            .padding(18)

            Hairline(color: skin.hairline)
            HStack {
                if isSmart {
                    Text(previewCount == 1 ? "1 track matches" : "\(previewCount) tracks match")
                        .font(AppFont.ui(11))
                        .foregroundStyle(skin.textTertiary)
                }
                Spacer()
                DialogButton(title: "Cancel", skin: skin, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                DialogButton(title: existing == nil ? "Create" : "Save", prominent: true, enabled: canSave, skin: skin, action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560)
        .glassSheet(skin)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private var smartEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Match")
                    .font(AppFont.ui(12))
                    .foregroundStyle(skin.textSecondary)
                SettingsSegmented(options: [true, false], selection: $matchAll, label: { $0 ? "all rules" : "any rule" }, skin: skin)
                    .frame(width: 180)
            }
            VStack(spacing: 6) {
                ForEach($rules) { $rule in
                    ruleRow($rule)
                }
            }
            Button {
                rules.append(SmartRule())
            } label: {
                Label("Add Rule", glyph: "plus")
                    .font(AppFont.ui(11.5, weight: .medium))
                    .foregroundStyle(skin.accent)
            }
            .buttonStyle(.plain)

            Hairline(color: skin.hairline).padding(.vertical, 2)

            HStack(spacing: 8) {
                Text("Order by")
                    .font(AppFont.ui(12))
                    .foregroundStyle(skin.textSecondary)
                DialogMenu(options: SmartOrder.allCases, selection: $order, label: \.label, skin: skin)
                    .frame(width: 160)
                Spacer()
                SettingsToggleSwitch(isOn: $limitEnabled, skin: skin)
                Text("Limit to")
                    .font(AppFont.ui(12))
                    .foregroundStyle(limitEnabled ? skin.textSecondary : skin.textTertiary)
                DialogTextField(text: $limit, skin: skin)
                    .frame(width: 52)
                    .disabled(!limitEnabled)
                    .opacity(limitEnabled ? 1 : 0.5)
                Text("tracks")
                    .font(AppFont.ui(12))
                    .foregroundStyle(limitEnabled ? skin.textSecondary : skin.textTertiary)
            }
        }
    }

    private func ruleRow(_ rule: Binding<SmartRule>) -> some View {
        HStack(spacing: 6) {
            DialogMenu(options: SmartField.allCases, selection: rule.field, label: \.label, skin: skin)
                .frame(width: 150)
                .onChange(of: rule.wrappedValue.field) { field in
                    let allowed = SmartOp.ops(for: field)
                    if !allowed.contains(rule.wrappedValue.op), let first = allowed.first {
                        rule.wrappedValue.op = first
                    }
                }
            DialogMenu(options: SmartOp.ops(for: rule.wrappedValue.field), selection: rule.op, label: \.label, skin: skin)
                .frame(width: 130)
            if rule.wrappedValue.field.kind != .flag {
                DialogTextField(placeholder: rule.wrappedValue.field.kind == .number ? "0" : "Value", text: rule.value, skin: skin)
            } else {
                Spacer()
            }
            Button {
                rules.removeAll { $0.id == rule.wrappedValue.id }
            } label: {
                Glyph("minus.circle", size: 12)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(GlyphButtonStyle(skin: skin))
            .disabled(rules.count < 2)
            .help("Remove rule")
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && (!isSmart || !rules.isEmpty)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        isSmart = existing.isSmart
        matchAll = existing.matchAll
        rules = existing.rules.isEmpty ? [SmartRule()] : existing.rules
        order = existing.smartOrder
        if let l = existing.smartLimit {
            limitEnabled = true
            limit = String(l)
        }
    }

    private func save() {
        guard canSave else { return }
        if let existing {
            if existing.isSmart {
                library.updateSmartPlaylist(existing.id, name: trimmedName, rules: rules, matchAll: matchAll, order: order, limit: limitValue)
            } else {
                library.renamePlaylist(existing.id, to: trimmedName)
            }
        } else if isSmart {
            library.createSmartPlaylist(named: trimmedName, rules: rules, matchAll: matchAll, order: order, limit: limitValue)
        } else {
            library.createPlaylist(named: trimmedName, trackIDs: initialTrackIDs)
        }
        onDismiss()
    }
}
