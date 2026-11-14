import SwiftUI

/// A typeface dropdown: the field shows the current family in itself;
/// opening it lists every family, mono and sans, each previewed in its own
/// face. Expands in place, so it works inside scroll views and on every
/// platform the same way.
struct FontMenu: View {
    var selection: AppFontFamily
    var skin: Skin
    var onSelect: (AppFontFamily) -> Void

    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Text(selection.label)
                        .font(Self.font(selection, 12.5))
                        .foregroundStyle(skin.textPrimary)
                    Spacer(minLength: 4)
                    Text(selection.isMonospaced ? "[mono]" : "[sans]")
                        .font(AppFont.ui(10))
                        .foregroundStyle(skin.textTertiary)
                    Glyph("chevron.down", size: 8)
                        .foregroundStyle(skin.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(skin.textPrimary.opacity(open ? 0.07 : 0.04))
                .overlay(Rectangle().strokeBorder(open ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.16), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    group("mono", AppFontFamily.allCases.filter(\.isMonospaced))
                    group("sans", AppFontFamily.allCases.filter { !$0.isMonospaced })
                }
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.16), lineWidth: 1))
                .padding(.top, -1)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func group(_ title: String, _ families: [AppFontFamily]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AppFont.ui(10))
                .foregroundStyle(skin.textTertiary)
                .padding(.horizontal, 9)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(families) { family in
                FontRow(family: family, selected: family == selection, skin: skin) {
                    onSelect(family)
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { open = false }
                }
            }
        }
    }

    static func font(_ family: AppFontFamily, _ size: CGFloat) -> Font {
        .custom(AppFont.face(size, .regular, in: family), fixedSize: size)
    }
}

private struct FontRow: View {
    var family: AppFontFamily
    var selected: Bool
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(selected ? ">" : " ")
                    .font(AppFont.ui(11))
                    .foregroundStyle(skin.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(family.label)
                        .font(FontMenu.font(family, 13.5))
                        .foregroundStyle(skin.textPrimary)
                    Text(family.note)
                        .font(FontMenu.font(family, 10.5))
                        .foregroundStyle(skin.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("Aa 0123")
                    .font(FontMenu.font(family, 11))
                    .foregroundStyle(skin.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? skin.accent.opacity(0.14) : hovering ? skin.textPrimary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
