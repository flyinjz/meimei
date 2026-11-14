import SwiftUI

// MARK: - Settings controls
//
// Switches, sliders, segmented pickers, and cards drawn in the active skin,
// so Settings looks like the rest of the app rather than a system form.

/// A pill switch in the accent color.
struct SettingsToggleSwitch: View {
    @Binding var isOn: Bool
    var skin: Skin

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? skin.accent : Color.clear)
                    .overlay(Rectangle().strokeBorder(isOn ? skin.accent : skin.textPrimary.opacity(0.3), lineWidth: 1))
                Rectangle()
                    .fill(isOn ? skin.textOnAccent : skin.textSecondary)
                    .frame(width: 12, height: 12)
                    .padding(3)
            }
            .frame(width: 34, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Title, optional subtitle, and a switch.
struct SettingsToggleRow: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var skin: Skin

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.ui(12))
                    .foregroundStyle(skin.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.textTertiary)
                }
            }
            Spacer(minLength: 8)
            SettingsToggleSwitch(isOn: $isOn, skin: skin)
        }
        .padding(.vertical, 5)
    }
}

/// Title, current value, and the app's own slider.
struct SettingsSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var skin: Skin
    var sliderStyle: SliderStyleOption = .line
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(AppFont.ui(12))
                    .foregroundStyle(skin.textPrimary)
                Spacer()
                Text(format(value))
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textSecondary)
            }
            MinimalSlider(value: $value, range: range, skin: skin, style: sliderStyle)
                .frame(height: 16)
        }
        .padding(.vertical, 5)
    }
}

/// A flat segmented picker.
struct SettingsSegmented<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String
    var skin: Skin
    @Namespace private var segment

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(AppFont.ui(11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? skin.textPrimary : skin.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                Rectangle()
                                    .fill(skin.textPrimary.opacity(0.16))
                                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: segment)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Rectangle().fill(skin.textPrimary.opacity(0.06)))
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selection)
    }
}

/// A titled card grouping related rows.
struct SettingsCard<Content: View>: View {
    var title: String?
    var skin: Skin
    var content: Content

    init(title: String? = nil, skin: Skin, @ViewBuilder content: () -> Content) {
        self.title = title
        self.skin = skin
        self.content = content()
    }

    /// Same look as the Library window's sections.
    var body: some View {
        LibrarySection(title: title, skin: skin) { content }
    }
}

/// A hairline between rows inside a card.
struct SettingsRowDivider: View {
    var skin: Skin
    var body: some View {
        Hairline(color: skin.hairline, inset: 0).padding(.vertical, 4)
    }
}

/// The icon + title + description header used at the top of every settings
/// page and inside the Panels master-detail view.
struct SettingsPageHeader: View {
    var icon: String
    var title: String
    var subtitle: String
    var skin: Skin

    var body: some View {
        HStack(spacing: 12) {
            Glyph(icon, size: 18)
                .foregroundStyle(skin.accent)
                .frame(width: 38, height: 38)
                .background(Rectangle().fill(skin.accentDim.opacity(0.28)))
                .overlay(Rectangle().strokeBorder(skin.accent.opacity(0.35), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.ui(15, weight: .semibold)).foregroundStyle(skin.textPrimary)
                Text(subtitle).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
            }
            Spacer()
        }
    }
}

/// A navigation row (Settings sections, the Panels list): icon, label, and
/// an optional trailing status.
struct SettingsNavRow: View {
    var icon: String
    var title: String
    var isSelected: Bool
    var trailingText: String? = nil
    var trailingIsOn: Bool = false
    var skin: Skin
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Glyph(icon, size: 12)
                    .foregroundStyle(isSelected ? skin.accent : skin.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(AppFont.ui(12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? skin.textPrimary : skin.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(AppFont.ui(9.5, weight: .medium))
                        .foregroundStyle(trailingIsOn ? skin.accent : skin.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Rectangle()
                    .fill(isSelected ? skin.selection.opacity(0.55) : (isHovering ? skin.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
