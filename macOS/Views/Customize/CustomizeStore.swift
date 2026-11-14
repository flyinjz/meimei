import SwiftUI

// MARK: - Drawing the shared customize data

extension TextWeight {
    var font: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .medium
        case .bold: return .bold
        }
    }
}

extension TextAlign {
    var alignment: Alignment { self == .leading ? .leading : self == .center ? .center : .trailing }
    var text: TextAlignment { self == .leading ? .leading : self == .center ? .center : .trailing }
}

extension GrayTone {
    /// A gray at `white`, nudged toward the tone.
    func gray(_ white: Double) -> Color {
        let c = rgb(white)
        return self == .neutral ? Color(white: white) : Color(red: c.red, green: c.green, blue: c.blue)
    }
}

// MARK: - Cursor

/// Hover and selection in customize mode, kept apart from the styles so
/// moving the pointer re-renders only the overlay.
@MainActor
final class CustomizeCursor: ObservableObject {
    @Published var hovered: CustomElement?
    /// In selection order; the last is the primary (shown in the inspector).
    @Published var selection: [CustomElement] = []

    var primary: CustomElement? { selection.last }

    /// The selected elements an edit applies to: those of the primary's kind.
    var targets: [CustomElement] {
        guard let primary else { return [] }
        return selection.filter { $0.kind == primary.kind }
    }

    func select(_ element: CustomElement?, extending: Bool = false) {
        guard let element else {
            if !extending { selection = [] }
            return
        }
        if extending {
            if let i = selection.firstIndex(of: element) { selection.remove(at: i) } else { selection.append(element) }
        } else {
            selection = [element]
        }
    }
}

// MARK: - Drafts

/// A layout being dragged in customize mode. Only the main window's panes
/// observe it, so a resize doesn't re-render every styled view per frame;
/// the store gets the result once, on release.
@MainActor
final class LayoutDraft: ObservableObject {
    @Published var layout: PaneLayout?
}

/// Whether the inspector should get out of the way of a drag near it.
@MainActor
final class InspectorFade: ObservableObject {
    @Published var faded = false
    /// The inspector's frame in the customize layer (not published).
    var frame: CGRect = .null
}

// MARK: - Store

/// The customize mode's state: on/off, the user's layout, design tokens,
/// element styles, workspaces, and undo history, persisted as one blob.
@MainActor
final class CustomizeStore: ObservableObject {
    @Published var isActive = false {
        didSet { if !isActive { cursor.hovered = nil; cursor.selection = []; peekOriginal = false } }
    }
    let cursor = CustomizeCursor()
    let draft = LayoutDraft()
    let inspectorFade = InspectorFade()

    /// While true (⌥ held), everything renders as originally designed.
    @Published var peekOriginal = false {
        didSet { applyTokens() }
    }

    @Published private(set) var styles: [CustomElement: ElementStyle] = [:] { didSet { changed() } }
    @Published private(set) var storedLayout = PaneLayout.standard { didSet { changed() } }
    @Published private(set) var storedTokens = DesignTokens() { didSet { applyTokens(); changed() } }
    @Published private(set) var workspaces: [Workspace] = [] { didSet { changed() } }
    @Published private(set) var activeWorkspaceID: UUID?

    @Published private(set) var undoStack: [Snapshot] = []
    @Published private(set) var redoStack: [Snapshot] = []
    @Published private(set) var clipboard: (kind: CustomElement.Kind, style: ElementStyle)?

    struct Snapshot: Equatable {
        var styles: [CustomElement: ElementStyle]
        var layout: PaneLayout
        var tokens: DesignTokens
    }

    private static let key = "com.meimei.player.customize.v2"
    private static let legacyStylesKey = "com.meimei.player.customStyles.v1"
    private var saveWork: DispatchWorkItem?
    private var loading = true
    private var lastEdit: (key: String, at: Date)?

    init() {
        if let saved = DefaultsStore.load(CustomizeState.self, key: Self.key) {
            styles = saved.styles
            storedLayout = saved.layout
            storedTokens = saved.tokens
            workspaces = saved.workspaces
            activeWorkspaceID = saved.activeWorkspaceID
        } else if let legacy = DefaultsStore.load([CustomElement: ElementStyle].self, key: Self.legacyStylesKey) {
            styles = legacy
        }
        storedLayout.normalize()
        loading = false
        applyTokens()
    }

    // MARK: Reading

    var layout: PaneLayout { peekOriginal ? .standard : storedLayout }
    var tokens: DesignTokens { peekOriginal ? DesignTokens() : storedTokens }

    /// What an element renders with (nothing while peeking at the original).
    func style(_ element: CustomElement) -> ElementStyle {
        peekOriginal ? ElementStyle() : (styles[element] ?? ElementStyle())
    }

    /// What the inspector edits.
    func storedStyle(_ element: CustomElement) -> ElementStyle { styles[element] ?? ElementStyle() }

    // MARK: Undo

    private var snapshot: Snapshot { Snapshot(styles: styles, layout: storedLayout, tokens: storedTokens) }

    /// Records the current state so the next change can be undone.
    func checkpoint() {
        if undoStack.last != snapshot { undoStack.append(snapshot) }
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Checkpoints unless the same kind of change happened a moment ago, so
    /// a drag or a scroll is one undo step.
    private func checkpoint(coalescing key: String?) {
        guard let key else { checkpoint(); return }
        if lastEdit?.key != key || Date().timeIntervalSince(lastEdit?.at ?? .distantPast) > 0.8 { checkpoint() }
        lastEdit = (key, Date())
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ s: Snapshot) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            styles = s.styles
            storedLayout = s.layout
            storedTokens = s.tokens
        }
    }

    // MARK: Styles

    /// Changes elements' styles; only those of the first element's kind.
    func edit(_ elements: [CustomElement], coalesce: String? = nil, _ body: (inout ElementStyle) -> Void) {
        guard let first = elements.first else { return }
        checkpoint(coalescing: coalesce.map { elements.map(\.rawValue).joined(separator: ",") + "." + $0 })
        for element in elements where element.kind == first.kind {
            var s = styles[element] ?? ElementStyle()
            body(&s)
            styles[element] = s.isEmpty ? nil : s
        }
    }

    func edit(_ element: CustomElement, coalesce: String? = nil, _ body: (inout ElementStyle) -> Void) {
        edit([element], coalesce: coalesce, body)
    }

    func reset(_ elements: [CustomElement]) {
        guard elements.contains(where: { styles[$0] != nil }) else { return }
        checkpoint()
        withAnimation(.easeOut(duration: 0.2)) { for e in elements { styles[e] = nil } }
    }

    func copyStyle(_ element: CustomElement) { clipboard = (element.kind, storedStyle(element)) }

    /// Pastes the copied style onto elements of the same kind, keeping
    /// whatever else they already have.
    func pasteStyle(into elements: [CustomElement]) {
        guard let clipboard else { return }
        let targets = elements.filter { $0.kind == clipboard.kind }
        guard !targets.isEmpty else { return }
        checkpoint()
        withAnimation(.easeOut(duration: 0.2)) {
            for e in targets {
                let s = storedStyle(e).merging(clipboard.style, kind: e.kind)
                styles[e] = s.isEmpty ? nil : s
            }
        }
    }

    // MARK: Tokens

    func editTokens(coalesce: String? = nil, _ body: (inout DesignTokens) -> Void) {
        checkpoint(coalescing: coalesce.map { "tokens." + $0 })
        var t = storedTokens
        body(&t)
        storedTokens = t
    }

    /// Pushes the tokens the type and grid read outside SwiftUI's graph.
    private func applyTokens() {
        let t = tokens
        AppFont.textScale = CGFloat(t.textScale)
        Corners.inset = CGFloat(t.gap)
    }

    // MARK: Layout

    func move(_ pane: PaneID, to target: DropTarget) {
        checkpoint()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { storedLayout.move(pane, to: target) }
    }

    func setHidden(_ pane: PaneID, _ hidden: Bool) {
        guard pane != .library else { return }
        checkpoint()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if hidden { storedLayout.hidden.insert(pane) } else { storedLayout.hidden.remove(pane) }
        }
    }

    /// Saves a dragged layout as one undo step.
    func commitLayout(_ layout: PaneLayout) {
        guard layout != storedLayout else { return }
        checkpoint()
        storedLayout = layout
    }

    func setColumnWidth(_ column: Int, _ width: Double) {
        guard storedLayout.columns.indices.contains(column) else { return }
        checkpoint(coalescing: "width.\(column)")
        storedLayout.columns[column].width = width
    }

    func setWeights(column: Int, _ weights: [PaneID: Double]) {
        guard storedLayout.columns.indices.contains(column) else { return }
        checkpoint(coalescing: "weights.\(column)")
        storedLayout.columns[column].weights.merge(weights) { $1 }
    }

    func resetLayout() {
        checkpoint()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { storedLayout = .standard }
    }

    func resetAll() {
        checkpoint()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            styles = [:]
            storedLayout = .standard
            storedTokens = DesignTokens()
        }
    }

    // MARK: Workspaces

    @discardableResult
    func saveWorkspace(named name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ws = Workspace(name: trimmed.isEmpty ? "Workspace \(workspaces.count + 1)" : trimmed,
                           layout: storedLayout, tokens: storedTokens, styles: styles)
        workspaces.append(ws)
        activeWorkspaceID = ws.id
        return ws.id
    }

    func updateWorkspace(_ id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].layout = storedLayout
        workspaces[i].tokens = storedTokens
        workspaces[i].styles = styles
        activeWorkspaceID = id
    }

    func applyWorkspace(_ id: UUID) {
        guard let ws = workspaces.first(where: { $0.id == id }) else { return }
        checkpoint()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            styles = ws.styles
            storedLayout = ws.layout
            storedTokens = ws.tokens
        }
        activeWorkspaceID = id
    }

    func applyWorkspace(number n: Int) {
        guard workspaces.indices.contains(n - 1) else { return }
        applyWorkspace(workspaces[n - 1].id)
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = trimmed
    }

    func deleteWorkspace(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id { activeWorkspaceID = nil }
    }

    func moveWorkspace(at index: Int, by step: Int) {
        let to = index + step
        guard workspaces.indices.contains(index), workspaces.indices.contains(to) else { return }
        workspaces.swapAt(index, to)
    }

    // MARK: Interchange

    struct Export: Codable {
        var format = "meimei-style"
        var version = 2
        var styles: [CustomElement: ElementStyle]
        var layout: PaneLayout?
        var tokens: DesignTokens?
    }

    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(Export(styles: styles, layout: storedLayout, tokens: storedTokens))
    }

    @discardableResult
    func importData(_ data: Data) -> Bool {
        guard let export = try? JSONDecoder().decode(Export.self, from: data), export.format == "meimei-style" else { return false }
        checkpoint()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            styles = export.styles
            if var layout = export.layout { layout.normalize(); storedLayout = layout }
            if let tokens = export.tokens { storedTokens = tokens }
        }
        return true
    }

    // MARK: Saving

    private func changed() {
        guard !loading else { return }
        if let id = activeWorkspaceID, let ws = workspaces.first(where: { $0.id == id }),
           ws.layout != storedLayout || ws.tokens != storedTokens || ws.styles != styles {
            // Edits after applying a workspace leave it; the inspector shows "unsaved".
            activeWorkspaceID = nil
        }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DefaultsStore.save(CustomizeState(styles: self.styles, layout: self.storedLayout, tokens: self.storedTokens,
                                     workspaces: self.workspaces, activeWorkspaceID: self.activeWorkspaceID), key: Self.key)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
