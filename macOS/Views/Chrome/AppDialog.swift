import SwiftUI

/// Shared chrome for sheets: settings, Get Info, duplicates, playlist editor.
/// One button and field style so prompts don't fall back to stock macOS controls.

struct DialogHeader: View {
    var title: String
    var subtitle: String? = nil
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(skin.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(AppFont.ui(11.5))
                    .foregroundStyle(skin.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

struct DialogButton: View {
    var title: String
    var prominent: Bool = false
    var enabled: Bool = true
    var skin: Skin
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle(skin: skin, prominent: prominent))
            .disabled(!enabled)
    }
}

struct DialogTextField: View {
    var placeholder: String = ""
    @Binding var text: String
    var skin: Skin

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(AppFont.ui(12))
            .foregroundStyle(skin.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Rectangle().fill(skin.textPrimary.opacity(0.07)))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

struct DialogMenu<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var skin: Skin

    var body: some View {
        MenuButton(content: {
            MenuContent(entries: options.map { option in
                .action(label(option), checked: option == selection) { selection = option }
            })
        }) {
            HStack(spacing: 6) {
                Text(label(selection))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Glyph("chevron.up.chevron.down", size: 8)
                    .foregroundStyle(skin.textTertiary)
            }
            .font(AppFont.ui(11))
            .foregroundStyle(skin.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(skin.textPrimary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ConfirmDialog: View {
    var title: String
    var message: String
    var confirmTitle: String
    var skin: Skin
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: title, skin: skin)
            Text(message)
                .font(AppFont.ui(12.5))
                .foregroundStyle(skin.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            HStack {
                Spacer()
                DialogButton(title: "Cancel", skin: skin, action: onCancel)
                DialogButton(title: confirmTitle, prominent: true, skin: skin, action: onConfirm)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: 420)
        .glassSheet(skin)
        .preferredColorScheme(.dark)
    }
}
