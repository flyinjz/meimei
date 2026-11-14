import SwiftUI

// MARK: - Live preview widgets
//
// Each of these renders a small, real (not screenshot/static) sample using
// the actual current settings values, so changes are visible immediately
// without leaving the Customize window.

/// A miniature now-playing card showing the Appearance settings together:
/// accent, slider style, corners, dividers, rounded type, tabular digits.
struct AppearancePreviewCard: View {
    var skin: Skin
    var settings: AppSettingsData
    @State private var demoValue: Double = 0.62

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(LinearGradient(colors: [skin.accentDim, skin.bgVoid], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 54, height: 54)
                .overlay(Glyph("waveform", size: 16).foregroundStyle(skin.textTertiary))

            VStack(alignment: .leading, spacing: 5) {
                Text("Sample Track Title")
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(skin.textPrimary)
                Text("Artist Name")
                    .font(AppFont.ui(11))
                    .foregroundStyle(skin.textSecondary)
                HStack(spacing: 8) {
                    Glyph("play.fill", size: 9)
                        .foregroundStyle(skin.accent)
                    MinimalSlider(value: $demoValue, range: 0...1, skin: skin, style: settings.sliderStyle)
                        .frame(height: 14)
                    Text(numberSample)
                        .font(settings.useMonospacedNumbers ? AppFont.ui(9.5) : AppFont.ui(9.5))
                        .foregroundStyle(skin.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Rectangle().fill(skin.bgPanel))
        .overlay(Rectangle().strokeBorder(skin.hairline.opacity(settings.hairlineOpacity), lineWidth: 1))
    }

    private var numberSample: String { "1:24" }
}

/// A schematic of the window with the selected panel highlighted and hidden
/// panels dimmed.
struct PanelLayoutDiagram: View {
    var skin: Skin
    var settings: AppSettingsData
    var highlighted: PanelKind

    var body: some View {
        VStack(spacing: 3) {
            if settings.playerBarPosition == .top { rect(.transportButtons, w: 240, h: 16) }
            HStack(spacing: 3) {
                rect(.nowPlayingRail, w: 46, h: 84)
                rect(nil, w: settings.showLyrics ? 96 : 138, h: 84)
                if settings.showLyrics {
                    rect(.lyrics, w: 38, h: 84)
                }
                rect(.albumGrid, w: 46, h: 84)
            }
            if settings.playerBarPosition == .bottom { rect(.transportButtons, w: 240, h: 16) }
            rect(.statusBar, w: 240, h: 12)
        }
        .padding(12)
        .background(Rectangle().fill(skin.bgVoid))
        .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
    }

    private func rect(_ panel: PanelKind?, w: CGFloat, h: CGFloat) -> some View {
        let isHighlighted = panel == highlighted
        let shown = panel.map(isEnabled) ?? true
        return Rectangle()
            .fill(isHighlighted ? AnyShapeStyle(skin.accent.opacity(0.4)) : AnyShapeStyle(skin.bgRaised))
            .overlay(
                Rectangle()
                    .strokeBorder(isHighlighted ? skin.accent : skin.hairline, lineWidth: isHighlighted ? 1.5 : 1)
            )
            .overlay {
                if panel == nil {
                    Glyph("tablecells", size: 10).foregroundStyle(skin.textTertiary.opacity(0.6))
                }
            }
            .frame(width: w, height: h)
            .opacity(shown ? 1 : 0.28)
    }

    private func isEnabled(_ panel: PanelKind) -> Bool {
        switch panel {
        case .nowPlayingRail: return settings.showSidebar
        case .albumGrid: return settings.showAlbumGrid
        case .lyrics: return settings.showLyrics
        case .statusBar: return settings.showStatusBar
        case .spectrum: return settings.showSpectrum
        case .transportButtons: return true
        case .eqToggle: return settings.showEQToggle
        }
    }
}

/// Three sample rows at the selected density.
struct DensityPreview: View {
    var skin: Skin
    var density: LayoutDensity

    private let sample: [(String, String)] = [("Dead Flowers", "Bubble Tea and Cigarettes"), ("Plane Crash", "Bubble Tea and Cigarettes"), ("Envelope", "Bubble Tea and Cigarettes")]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(sample.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.0).font(AppFont.ui(density.rowFontSize)).foregroundStyle(skin.textPrimary)
                    Spacer()
                    Text(row.1).font(AppFont.ui(density.rowFontSize)).foregroundStyle(skin.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(height: density.rowHeight)
                .background(index % 2 == 1 ? skin.bgRowAlt : skin.bgRow)
            }
        }
        .clipShape(Rectangle())
        .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
    }
}

/// Two sample rows with the selected columns, grid lines, and striping.
struct TableColumnsPreview: View {
    var skin: Skin
    var settings: AppSettingsData

    private let rows: [[TrackColumnKind: String]] = [
        [.track: "1", .artist: "Bubble Tea and Cigarettes", .album: "we should've killed each other", .year: "2024",
         .time: "2:29", .genre: "Indie", .plays: "12", .format: "FLAC", .quality: "24/48"],
        [.track: "2", .artist: "Bubble Tea and Cigarettes", .album: "we should've killed each other", .year: "2024",
         .time: "3:02", .genre: "Indie", .plays: "7", .format: "FLAC", .quality: "24/48"]
    ]
    private let titles = ["Dead Flowers", "Plane Crash"]

    private func width(_ c: TrackColumnKind) -> CGFloat {
        switch c {
        case .track, .year, .plays, .time: return 30
        case .format, .quality: return 40
        case .genre: return 48
        case .artist, .album: return 90
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    if settings.visibleColumns.contains(.track) { cell(.track, index) }
                    Text(titles[index])
                        .font(AppFont.ui(10.5, weight: .medium))
                        .foregroundStyle(skin.textPrimary)
                        .frame(width: 84, alignment: .leading)
                    ForEach(TrackColumnKind.allCases.filter { $0 != .track && settings.visibleColumns.contains($0) }) { column in
                        if settings.tableShowGridLines { Rectangle().fill(skin.hairline).frame(width: 1) }
                        cell(column, index)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(settings.tableAlternatingRows && index % 2 == 1 ? skin.bgRowAlt : skin.bgRow)
            }
        }
        .clipShape(Rectangle())
        .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
    }

    private func cell(_ column: TrackColumnKind, _ row: Int) -> some View {
        let numeric: Set<TrackColumnKind> = [.track, .year, .plays, .time]
        return Text(rows[row][column] ?? "")
            .font(numeric.contains(column) ? AppFont.ui(10) : AppFont.ui(10))
            .foregroundStyle(skin.textSecondary)
            .frame(width: width(column), alignment: numeric.contains(column) ? .trailing : .leading)
    }
}

/// The equalizer's actual frequency response (summed peaking filters plus
/// preamp) on a log-frequency axis, 20 Hz–20 kHz.
struct EQCurvePreview: View {
    var data: EqualizerSettingsData
    var skin: Skin
    var height: CGFloat = 64

    var body: some View {
        Canvas { context, size in
            let range = data.gainRange.rawValue
            let midY = size.height / 2
            func y(_ db: Double) -> CGFloat { midY - CGFloat(max(-range, min(range, db)) / range) * (size.height / 2 - 4) }
            func x(_ hz: Double) -> CGFloat { size.width * CGFloat(log10(hz / 20) / 3) }

            // Grid: decades and ±half range.
            var grid = Path()
            for hz in [100.0, 1000, 10000] {
                grid.move(to: CGPoint(x: x(hz), y: 0))
                grid.addLine(to: CGPoint(x: x(hz), y: size.height))
            }
            for db in [-range / 2, range / 2] {
                grid.move(to: CGPoint(x: 0, y: y(db)))
                grid.addLine(to: CGPoint(x: size.width, y: y(db)))
            }
            context.stroke(grid, with: .color(skin.hairline.opacity(0.6)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: midY))
            zero.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(zero, with: .color(skin.hairline), lineWidth: 1)

            let steps = max(2, Int(size.width / 2))
            var line = Path()
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: midY))
            for i in 0...steps {
                let hz = 20 * pow(1000, Double(i) / Double(steps))
                let point = CGPoint(x: x(hz), y: y(EqualizerResponse.gain(atHz: hz, data: data)))
                if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                fill.addLine(to: point)
            }
            fill.addLine(to: CGPoint(x: size.width, y: midY))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [skin.accent.opacity(0.35), skin.accent.opacity(0.05)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(skin.accent), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .frame(height: height)
        .background(Rectangle().fill(skin.lcdBackground.opacity(0.7)))
        .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
        .opacity(data.enabled ? 1 : 0.45)
    }
}
