import SwiftUI

/// Live diagram of the playback graph so the EQ page feels like a studio
/// rack rather than a pile of sliders.
struct SignalPathView: View {
    var equalizerEnabled: Bool
    var preamp: Double
    var volume: Float
    var sampleRate: Double?
    var bitDepth: Int?
    var fileFormat: String?
    var isPlaying: Bool
    var skin: Skin

    var body: some View {
        HStack(spacing: 0) {
            node(title: fileFormat ?? "File", subtitle: formatLine, lit: fileFormat != nil)
            wire
            node(title: "Player", subtitle: isPlaying ? "running" : "idle", lit: isPlaying)
            wire
            node(
                title: "EQ",
                subtitle: equalizerEnabled ? String(format: "%+.1f dB", preamp) : "bypass",
                lit: equalizerEnabled
            )
            wire
            node(title: "Output", subtitle: String(format: "%.0f%%", Double(volume) * 100), lit: true)
        }
        .padding(.vertical, 4)
    }

    private var formatLine: String {
        guard let sampleRate, let bitDepth else { return "—" }
        let khz = sampleRate / 1000
        let rate = khz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
        return "\(rate) · \(bitDepth)-bit"
    }

    private func node(title: String, subtitle: String, lit: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(AppFont.ui(8.5, weight: .bold))
                .foregroundStyle(lit ? skin.accent : skin.textTertiary)
            Text(subtitle)
                .font(AppFont.ui(8.5))
                .foregroundStyle(skin.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(lit ? skin.accentDim.opacity(0.22) : skin.bgVoid.opacity(0.55))
        )
        .overlay(
            Rectangle()
                .strokeBorder(lit ? skin.accent.opacity(0.55) : skin.hairline, lineWidth: 1)
        )
    }

    private var wire: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [skin.accent.opacity(0.05), skin.accent.opacity(0.55), skin.accent.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: 18, height: 1)
    }
}
