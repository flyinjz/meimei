import SwiftUI

/// A bare glyph button. No background in any state: it brightens under the
/// pointer, dips when pressed, and draws in the accent when active.
struct TransportButton: View {
    var icon: String
    var size: CGFloat = 22
    var iconSize: CGFloat = 12
    var weight: Font.Weight = .medium
    var isActive = false
    var help: String? = nil
    var skin: Skin
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(icon, size: iconSize)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlyphButtonStyle(skin: skin, isActive: isActive))
        .help(help ?? "")
    }
}

/// Text-and-glyph style with no background: secondary at rest, primary on
/// hover, accent when active.
struct GlyphButtonStyle: ButtonStyle {
    var skin: Skin
    var isActive = false
    var restColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        GlyphLabel(configuration: configuration, skin: skin, isActive: isActive, restColor: restColor)
    }

    private struct GlyphLabel: View {
        let configuration: Configuration
        let skin: Skin
        let isActive: Bool
        let restColor: Color?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(color)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var color: Color {
            if isActive { return skin.accent }
            if hovering { return skin.textPrimary }
            return restColor ?? skin.textSecondary
        }
    }
}

/// Play / pause: a larger bare glyph in the primary text color.
struct PlayPauseButton: View {
    var isPlaying: Bool
    var size: CGFloat = 28
    var skin: Skin
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(isPlaying ? "pause.fill" : "play.fill", size: size * 0.62)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlyphButtonStyle(skin: skin, restColor: skin.textPrimary))
        .help(isPlaying ? "Pause" : "Play")
    }
}

/// Scales the label down slightly while pressed.
struct PressDipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
