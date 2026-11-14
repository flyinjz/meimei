import SwiftUI

/// A Library page's title: plain text on the grid, no icon tile.
struct LibraryHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var skin: Skin
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppFont.ui(17, weight: .semibold)).foregroundStyle(skin.textPrimary)
                if let subtitle {
                    Text(subtitle).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.bottom, 2)
    }
}

extension LibraryHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, skin: Skin) {
        self.init(title: title, subtitle: subtitle, skin: skin) { EmptyView() }
    }
}

/// A group on a Library page: a label over a 1px panel with corner
/// ticks, like the rest of the interface.
struct LibrarySection<Content: View>: View {
    var title: String?
    var skin: Skin
    /// Stretch the box to the height offered (side-by-side sections of equal height).
    var fillsHeight = false
    var content: Content

    init(title: String? = nil, skin: Skin, fillsHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.skin = skin
        self.fillsHeight = fillsHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.lowercased())
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
            }
            VStack(alignment: .leading, spacing: 2) { content }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
                .background(Rectangle().fill(skin.textPrimary.opacity(0.03)))
                .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
                .fuiCorners(skin)
        }
    }
}

/// A bracketed tag: "[offline]", "[3 missing]".
struct LibraryTag: View {
    var text: String
    var skin: Skin
    var accent = false

    var body: some View {
        Text("[\(text)]")
            .font(AppFont.ui(10))
            .foregroundStyle(accent ? skin.accent : skin.textTertiary)
            .lineLimit(1)
    }
}

// MARK: - Editor controls

/// Joined buttons in one bordered strip (cover actions).
struct SegmentBar: View {
    struct Item: Identifiable {
        var id = UUID()
        var title: String?
        var glyph: String?
        var enabled = true
        var help: String = ""
        var action: () -> Void

        init(title: String, enabled: Bool = true, help: String = "", action: @escaping () -> Void) {
            self.title = title
            self.enabled = enabled
            self.help = help
            self.action = action
        }

        init(glyph: String, enabled: Bool = true, help: String = "", action: @escaping () -> Void) {
            self.glyph = glyph
            self.enabled = enabled
            self.help = help
            self.action = action
        }
    }

    var skin: Skin
    var items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Rectangle().fill(skin.textPrimary.opacity(0.12)).frame(width: 1) }
                SegmentButton(item: item, skin: skin)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 28)
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
    }
}

private struct SegmentButton: View {
    var item: SegmentBar.Item
    var skin: Skin
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            Group {
                if let glyph = item.glyph { Glyph(glyph, size: 11) } else { Text(item.title ?? "").lineLimit(1) }
            }
            .font(AppFont.ui(11))
            .foregroundStyle(hovering ? skin.textPrimary : skin.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovering ? skin.textPrimary.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(item.help)
    }
}

/// A labeled text field for forms: label above, 1px box that lights up
/// in the accent while editing, optional accessory on the right.
struct FormField<Accessory: View>: View {
    var title: String
    @Binding var text: String
    var placeholder: String = ""
    var skin: Skin
    @ViewBuilder var accessory: Accessory
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
            HStack(spacing: 0) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(AppFont.ui(12.5))
                    .foregroundStyle(skin.textPrimary)
                    .focused($focused)
                    .padding(.horizontal, 10)
                accessory
            }
            .frame(height: 30)
            .background(Rectangle().fill(skin.textPrimary.opacity(focused ? 0.07 : 0.045)))
            .overlay(Rectangle().strokeBorder(focused ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.12), lineWidth: 1))
        }
    }
}

extension FormField where Accessory == EmptyView {
    init(title: String, text: Binding<String>, placeholder: String = "", skin: Skin) {
        self.init(title: title, text: text, placeholder: placeholder, skin: skin) { EmptyView() }
    }
}

/// A toolbar button: text, no box of its own (the toolbar is the box).
struct ToolbarAction: View {
    var title: String
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.ui(11.5))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(hovering && isEnabled ? skin.textPrimary : skin.textSecondary)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(hovering && isEnabled ? skin.textPrimary.opacity(0.06) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
    }
}

/// A toolbar button that opens a menu of actions.
struct ToolbarMenu: View {
    var title: String
    var skin: Skin
    var items: [PopUpMenuButton<AnyView>.Item]
    @State private var hovering = false

    var body: some View {
        PopUpMenuButton(items: items) {
            AnyView(
                HStack(spacing: 6) {
                    Text(title).font(AppFont.ui(11.5)).lineLimit(1).fixedSize()
                    Glyph("chevron.down", size: 7).opacity(0.7)
                }
                .foregroundStyle(hovering ? skin.textPrimary : skin.textSecondary)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(hovering ? skin.textPrimary.opacity(0.06) : .clear)
                .contentShape(Rectangle())
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ToolbarDivider: View {
    var skin: Skin
    var body: some View { Rectangle().fill(skin.textPrimary.opacity(0.12)).frame(width: 1) }
}

/// A column title in an editor table.
struct TrackColumnHeader: View {
    var title: String
    var width: CGFloat? = nil
    var trailing = false
    var skin: Skin

    var body: some View {
        Text(title)
            .font(AppFont.ui(10.5))
            .foregroundStyle(skin.textTertiary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, width == nil ? 10 : 6)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: trailing ? .trailing : .leading)
    }
}

/// A borderless cell editor for tables; boxed in the accent while editing.
struct InlineField: View {
    @Binding var text: String
    var trailing = false
    var inset: CGFloat = 10
    var skin: Skin
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(AppFont.ui(12))
            .foregroundStyle(skin.textPrimary)
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .focused($focused)
            .padding(.horizontal, inset)
            .frame(maxHeight: .infinity)
            .background(Rectangle().fill(focused ? skin.textPrimary.opacity(0.07) : hovering ? skin.textPrimary.opacity(0.035) : .clear))
            .overlay(Rectangle().strokeBorder(focused ? skin.accent.opacity(0.8) : .clear, lineWidth: 1))
            .onHover { hovering = $0 }
    }
}
