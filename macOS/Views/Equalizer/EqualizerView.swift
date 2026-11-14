import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The equalizer workspace: a parametric EQ in the style of a DAW plug-in.
/// Response graph with draggable band nodes over a live analyzer, a band
/// strip, an inspector with knobs and typed values, presets with A/B and
/// undo, and input gain with an output meter.
struct EqualizerView: View {
    @ObservedObject var equalizer: EqualizerSettings
    @ObservedObject var engine: AudioEngine
    var skin: Skin

    @State private var naming: NamingRequest?
    @State private var importError: String?

    private var data: EqualizerSettingsData { equalizer.data }
    private var selected: EQBand? { data.bands.first { $0.id == equalizer.selectedBandID } }

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            HStack(spacing: 10) {
                VStack(spacing: 10) {
                    EQGraph(equalizer: equalizer, feed: engine.spectrum, isPlaying: engine.isPlaying, skin: skin)
                        .panelSurface(.eqGraph, skin: skin, fallback: skin.bgPanel, content: true)
                    bandStrip
                }
                gainColumn
                    .frame(width: 112)
            }
            inspector
                .frame(height: 118)
        }
        .padding(.horizontal, Corners.inset)
        .padding(.bottom, Corners.inset)
        .padding(.top, TitleBand.height)
        .overlay(alignment: .top) { WindowDragArea().frame(height: TitleBand.height) }
        .overlay(alignment: .topLeading) {
            if !AppSession.shared.settings.data.systemWindowFrame {
                WindowControls(skin: skin, closeOnly: true).frame(height: TitleBand.height).padding(.leading, TitleBand.controlsLeading)
            }
        }
        .foregroundStyle(skin.textPrimary)
        .onAppear { SpectrumAnalyzer.wantsDetail.value = true }
        .onDisappear { SpectrumAnalyzer.wantsDetail.value = false }
        .background { if !GlassRendering.forceFallback { EQKeyCommands(equalizer: equalizer) } }
        .sheet(item: $naming) { request in
            NamePrompt(title: request.title, initial: request.initial, skin: skin) { name in
                naming = nil
                guard let name else { return }
                if let id = request.renaming { equalizer.renameProfile(id, to: name) } else { equalizer.saveCurrentAsNewProfile(named: name) }
            }
        }
        .alert("Couldn't import that file", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                equalizer.setEnabled(!data.enabled)
            } label: {
                Label(data.enabled ? "On" : "Off", glyph: "power")
            }
            .buttonStyle(PillButtonStyle(skin: skin, isActive: data.enabled))
            .help(data.enabled ? "Turn the equalizer off" : "Turn the equalizer on")

            presetMenu

            HStack(spacing: 2) {
                abButton("A", active: !equalizer.showingB)
                abButton("B", active: equalizer.showingB)
            }
            .padding(2)
            .background(Rectangle().fill(skin.textPrimary.opacity(0.06)))
            .help("Compare two curves. Switching keeps both.")

            IconButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)", skin: skin) { equalizer.undo() }
                .disabled(equalizer.undoStack.isEmpty)
            IconButton(icon: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", skin: skin) { equalizer.redo() }
                .disabled(equalizer.redoStack.isEmpty)

            Spacer(minLength: 8)

            Text("[\(data.bands.count) band\(data.bands.count == 1 ? "" : "s")]")
                .font(AppFont.ui(11))
                .foregroundStyle(skin.textTertiary)

            MenuButton(content: {
                MenuContent(title: "Scale", entries: EQGainRange.allCases.map { r in
                    .action(r.label, checked: data.gainRange == r) { equalizer.setGainRange(r) }
                })
            }) {
                Text(data.gainRange.label)
            }
            .fixedSize()
            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            .help("Vertical scale and gain limit")

            IconButton(icon: "waveform.path.ecg", isActive: data.showAnalyzer, help: "Analyzer", skin: skin) {
                equalizer.setShowAnalyzer(!data.showAnalyzer)
            }

            MenuButton(content: {
                MenuContent([
                    MenuGroup("bands", [
                        .action("Add Band", glyph: "plus", enabled: equalizer.canAddBand) { equalizer.addBand(frequency: 1000) },
                        .action("Invert Gains", glyph: "arrow.uturn.backward") { equalizer.invertGains() },
                        .action("Halve Gains", glyph: "minus.circle") { equalizer.scaleGains(by: 0.5) },
                        .action("Copy to Other A/B Slot", glyph: "doc.on.doc") { equalizer.copyToOtherSlot() },
                    ]),
                    MenuGroup("presets", [
                        .action("Import Preset…", glyph: "arrow.down.left") { importPreset() },
                        .action("Export Preset…", glyph: "arrow.up.right") { exportPreset() },
                    ]),
                    MenuGroup(nil, [.action("Reset to Flat", glyph: "arrow.counterclockwise", destructive: true) { equalizer.resetFlat() }]),
                ])
            }) {
                Glyph("ellipsis", size: 12)
                    .frame(width: 26, height: 26)
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.18), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 6)
    }

    private func abButton(_ title: String, active: Bool) -> some View {
        Button(title) { if !active { equalizer.toggleCompare() } }
            .buttonStyle(PillButtonStyle(skin: skin, isActive: active, compact: true))
    }

    private var presetMenu: some View {
        MenuButton(content: {
            var manage: [MenuEntry] = [
                .action("Save as New Preset…", glyph: "plus") { naming = NamingRequest(title: "Save Preset", initial: "") },
            ]
            if let p = equalizer.activeProfile, !p.isBuiltIn {
                manage.append(.action("Rename \u{201C}\(p.name)\u{201D}…", glyph: "text.alignleft") {
                    naming = NamingRequest(title: "Rename Preset", initial: p.name, renaming: p.id)
                })
                manage.append(.action("Delete \u{201C}\(p.name)\u{201D}", glyph: "trash", destructive: true) { equalizer.deleteProfile(p.id) })
            } else if data.activeProfileID == nil, let last = equalizer.customProfiles.last {
                manage.append(.action("Update \u{201C}\(last.name)\u{201D}", glyph: "arrow.counterclockwise") { equalizer.overwriteProfile(last.id) })
            }
            return MenuContent([
                MenuGroup("built-in", EQProfile.builtIns.map { p in
                    .action(p.name, checked: data.activeProfileID == p.id) { equalizer.applyProfile(p.id) }
                }),
                MenuGroup("yours", equalizer.customProfiles.map { p in
                    .action(p.name, checked: data.activeProfileID == p.id) { equalizer.applyProfile(p.id) }
                }),
                MenuGroup(nil, manage),
            ])
        }) {
            HStack(spacing: 6) {
                Glyph("list.bullet", size: 10)
                Text(equalizer.activeProfileName).lineLimit(1)
                Glyph("chevron.down", size: 8).opacity(0.6)
            }
            .frame(minWidth: 120, alignment: .leading)
        }
        .fixedSize()
        .buttonStyle(PillButtonStyle(skin: skin))
        .help("Presets")
    }

    // MARK: Band strip

    private var bandStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(data.bands.enumerated()), id: \.element.id) { index, band in
                    BandChip(index: index, band: band, selected: band.id == equalizer.selectedBandID,
                             soloed: band.id == equalizer.soloBandID, skin: skin) {
                        equalizer.selectedBandID = band.id
                    }
                }
                Button {
                    equalizer.addBand(frequency: nextFreeFrequency())
                } label: {
                    Label("Add Band", glyph: "plus")
                }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                .disabled(!equalizer.canAddBand)
                .help("Or double-click the graph")
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 30)
    }

    /// The widest gap between existing bands, on a log scale.
    private func nextFreeFrequency() -> Double {
        let points = ([20.0, 20_000] + data.bands.map(\.frequency)).sorted()
        var best = (gap: 0.0, f: 1000.0)
        for (a, b) in zip(points, points.dropFirst()) where log(b / a) > best.gap {
            best = (log(b / a), (a * b).squareRoot())
        }
        return best.f
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        Group {
            if let band = selected, let index = data.bands.firstIndex(of: band) {
                BandInspector(equalizer: equalizer, band: band, index: index, skin: skin)
            } else {
                HStack(spacing: 10) {
                    Glyph("hand.point.up.left", size: 16)
                        .foregroundStyle(skin.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Double-click the graph to add a band")
                            .font(AppFont.ui(12.5, weight: .semibold))
                        Text("Drag a node to move it · scroll over it to change its width · ⇧-drag for fine moves · right-click for its type, solo, and more")
                            .font(AppFont.ui(11))
                            .foregroundStyle(skin.textTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .panelSurface(.eqPanels, skin: skin, fallback: skin.bgPanel)
    }

    // MARK: Gain column

    private var gainColumn: some View {
        VStack(spacing: 10) {
            Text("input")
                .textRole(.eqLabels, size: 11, weight: .medium, color: skin.textTertiary)
            Knob(value: Binding(get: { data.preampGain }, set: { equalizer.setPreamp($0) }),
                 range: -24...12, defaultValue: 0, bipolar: true, size: 52, tint: skin.accent, skin: skin,
                 onBegin: { equalizer.checkpoint() })
            EditableValue(text: String(format: "%+.1f dB", data.preampGain), skin: skin, width: 76,
                          parse: { Double($0.replacingOccurrences(of: ",", with: ".")) }) {
                equalizer.setPreamp($0, checkpoint: true)
            }
            Button {
                equalizer.setAutoPreamp(!data.autoPreamp)
            } label: {
                Text("Auto")
            }
            .buttonStyle(PillButtonStyle(skin: skin, isActive: data.autoPreamp, compact: true))
            .help("Keep the input low enough that boosts can't clip")

            OutputMeter(feed: engine.spectrum, isPlaying: engine.isPlaying, skin: skin)
                .frame(maxHeight: .infinity)
            Text("output")
                .textRole(.eqLabels, size: 11, weight: .medium, color: skin.textTertiary)
        }
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity)
        .panelSurface(.eqPanels, skin: skin, fallback: skin.bgPanel)
    }

    // MARK: Files

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, UTType(filenameExtension: "meimeieq") ?? .json]
        panel.message = "Choose an i2s preset, or an Equalizer APO / AutoEQ ParametricEQ.txt file."
        guard panel.runModal() == .OK, let url = panel.url, let raw = try? Data(contentsOf: url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        if let profile = try? JSONDecoder().decode(EQProfile.self, from: raw) {
            equalizer.importProfile(profile)
        } else if let text = String(data: raw, encoding: .utf8), let profile = ParametricEQText.parse(text, name: name) {
            equalizer.importProfile(profile)
        } else {
            importError = "“\(url.lastPathComponent)” isn't an i2s preset or a ParametricEQ text file."
        }
    }

    private func exportPreset() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = equalizer.activeProfileName + ".txt"
        panel.allowedContentTypes = [.plainText, .json]
        panel.message = "Save as .txt for Equalizer APO / AutoEQ, or .json for i2s."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "json" {
            let profile = EQProfile(name: url.deletingPathExtension().lastPathComponent, bands: data.bands, preampGain: data.preampGain)
            try? JSONEncoder().encode(profile).write(to: url, options: .atomic)
        } else {
            try? ParametricEQText.export(data).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct NamingRequest: Identifiable {
    let id = UUID()
    var title: String
    var initial: String
    var renaming: UUID? = nil
}

// MARK: - Band colors

extension EQBand {
    /// A stable hue per position, so a band keeps its color as it moves.
    static func color(_ index: Int) -> Color {
        Color(hue: (Double(index) * 0.137 + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: 0.95)
    }
}

// MARK: - Graph

private struct EQGraph: View {
    @ObservedObject var equalizer: EqualizerSettings
    let feed: SpectrumFeed
    var isPlaying: Bool
    var skin: Skin

    @State private var dragging: (id: UUID, startF: Double, startG: Double)?
    @State private var hover: CGPoint?
    @State private var analyzer = AnalyzerMotion()
    @State private var analyzerAsleep = true

    private var data: EqualizerSettingsData { equalizer.data }
    private var range: Double { data.gainRange.rawValue }

    private static let gridFrequencies: [Double] = [20, 30, 40, 50, 60, 80, 100, 200, 300, 400, 500, 600, 800, 1000, 2000, 3000, 4000, 5000, 6000, 8000, 10000, 20000]
    private static let labeled: Set<Double> = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, size in drawGrid(&ctx, size) }
                if data.showAnalyzer {
                    TimelineView(.animation(paused: analyzerAsleep)) { t in
                        Canvas { ctx, size in
                            drawAnalyzer(analyzer.step(toward: isPlaying ? feed.detail : [], at: t.date), &ctx, size)
                        }
                    }
                    .allowsHitTesting(false)
                    .task(id: isPlaying) {
                        if isPlaying {
                            analyzerAsleep = false
                        } else {
                            // Let the curve settle before the timeline stops.
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            if !Task.isCancelled { analyzerAsleep = true }
                        }
                    }
                }
                Canvas { ctx, size in drawCurves(&ctx, size) }
                    .opacity(data.enabled ? 1 : 0.45)
                nodeLayer(size)
                Text("response")
                    .textRole(.eqLabels, size: 11, weight: .medium, color: skin.textTertiary)
                    .position(x: 52, y: 12)
                    .allowsHitTesting(false)
                if let hover, dragging == nil, hoveredBand(at: hover, size) == nil {
                    readout(at: hover, size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { e in
                guard hoveredBand(at: e.location, size) == nil else { return }
                equalizer.addBand(frequency: frequency(atX: e.location.x, size.width), gain: gain(atY: e.location.y, size.height))
            })
            .simultaneousGesture(SpatialTapGesture().onEnded { e in
                if hoveredBand(at: e.location, size) == nil { equalizer.selectedBandID = nil }
            })
            .background(ScrollCatcher { delta in
                guard let hover, let id = hoveredBand(at: hover, size)?.id ?? equalizer.selectedBandID,
                      let band = data.bands.first(where: { $0.id == id }) else { return false }
                if band.type.hasQ {
                    equalizer.updateBand(id) { $0.q *= pow(1.004, -delta) }
                } else if band.type.hasSlope, abs(delta) > 2 {
                    equalizer.updateBand(id) { $0.slope = min(48, max(12, $0.slope + (delta > 0 ? -12 : 12))) }
                }
                return true
            })
            .appContextMenu { contextMenu(size) }
        }
        .frame(minHeight: 220)
    }

    // MARK: Mapping

    private func x(_ hz: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(hz / 20) / log(1000)) * w }
    private func frequency(atX x: CGFloat, _ w: CGFloat) -> Double { 20 * pow(1000, Double(min(max(0, x), w) / w)) }
    private func y(_ db: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(db / range) * (h / 2 - 14) }
    private func gain(atY y: CGFloat, _ h: CGFloat) -> Double { min(range, max(-range, Double(h / 2 - y) / Double(h / 2 - 14) * range)) }

    private func nodePoint(_ band: EQBand, _ size: CGSize) -> CGPoint {
        let g = band.type.hasGain ? band.gain : 0
        return CGPoint(x: x(band.frequency, size.width), y: y(g, size.height))
    }

    private func hoveredBand(at p: CGPoint, _ size: CGSize) -> EQBand? {
        data.bands.min { hypot(nodePoint($0, size).x - p.x, nodePoint($0, size).y - p.y) < hypot(nodePoint($1, size).x - p.x, nodePoint($1, size).y - p.y) }
            .flatMap { hypot(nodePoint($0, size).x - p.x, nodePoint($0, size).y - p.y) < 14 ? $0 : nil }
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let label = skin.textTertiary
        for f in Self.gridFrequencies {
            let gx = x(f, size.width)
            var p = Path(); p.move(to: CGPoint(x: gx, y: 0)); p.addLine(to: CGPoint(x: gx, y: size.height))
            ctx.stroke(p, with: .color(skin.textPrimary.opacity(Self.labeled.contains(f) ? 0.08 : 0.035)), lineWidth: 1)
            if Self.labeled.contains(f), f > 20, f < 20_000 {
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(AppFont.ui(9, weight: .medium)).foregroundColor(label),
                         at: CGPoint(x: gx, y: size.height - 8))
            }
        }
        let step = range <= 6 ? 2.0 : range <= 12 ? 3 : range <= 18 ? 6 : 6
        var db = -range
        while db <= range + 0.01 {
            let gy = y(db, size.height)
            var p = Path(); p.move(to: CGPoint(x: 0, y: gy)); p.addLine(to: CGPoint(x: size.width, y: gy))
            ctx.stroke(p, with: .color(skin.textPrimary.opacity(db == 0 ? 0.16 : 0.05)), lineWidth: 1)
            if abs(db) < range - 0.01 {
                ctx.draw(Text(db == 0 ? "0" : String(format: "%+.0f", db)).font(AppFont.ui(9, weight: .medium)).foregroundColor(label),
                         at: CGPoint(x: 16, y: gy - 7))
            }
            db += step
        }
    }

    private func drawAnalyzer(_ levels: [Float], _ ctx: inout GraphicsContext, _ size: CGSize) {
        guard levels.count > 2 else { return }
        let n = levels.count
        // The analyzer has its own scale: −84…−6 dBFS over the full height.
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) / CGFloat(n - 1) * size.width,
                    y: size.height * (1 - CGFloat((min(-6, max(-84, levels[i])) + 84) / 78)))
        }
        // A smooth line through the points: curves between midpoints.
        var line = Path()
        line.move(to: point(0))
        for i in 1..<n - 1 {
            let p = point(i), q = point(i + 1)
            line.addQuadCurve(to: CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2), control: p)
        }
        line.addLine(to: point(n - 1))
        var fill = line
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(skin.textPrimary.opacity(0.06)))
        ctx.stroke(line, with: .color(skin.textPrimary.opacity(0.16)), lineWidth: 1)
    }

    private func drawCurves(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let steps = Int(w / 3)
        let zeroY = y(0, h)
        // Each band's own contribution, faint; the selected one in the accent.
        for band in data.bands where band.enabled {
            let isSelected = band.id == equalizer.selectedBandID
            var path = Path()
            path.move(to: CGPoint(x: 0, y: zeroY))
            for s in 0...steps {
                let px = CGFloat(s) / CGFloat(steps) * w
                path.addLine(to: CGPoint(x: px, y: y(EqualizerResponse.gain(atHz: frequency(atX: px, w), band: band), h)))
            }
            path.addLine(to: CGPoint(x: w, y: zeroY))
            if isSelected {
                ctx.fill(path, with: .color(skin.accent.opacity(0.12)))
                ctx.stroke(path, with: .color(skin.accent.opacity(0.6)), lineWidth: 1)
            } else {
                ctx.stroke(path, with: .color(skin.textPrimary.opacity(0.14)), lineWidth: 1)
            }
        }
        // The summed curve.
        var total = Path()
        for s in 0...steps {
            let px = CGFloat(s) / CGFloat(steps) * w
            let p = CGPoint(x: px, y: min(h + 4, max(-4, y(EqualizerResponse.gain(atHz: frequency(atX: px, w), data: data), h))))
            if s == 0 { total.move(to: p) } else { total.addLine(to: p) }
        }
        ctx.stroke(total, with: .color(skin.textPrimary.opacity(0.92)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        // Crosshair from the selected node to both axes.
        if let band = data.bands.first(where: { $0.id == equalizer.selectedBandID }) {
            let p = nodePoint(band, size)
            var cross = Path()
            cross.move(to: CGPoint(x: p.x, y: p.y + 12)); cross.addLine(to: CGPoint(x: p.x, y: h))
            cross.move(to: CGPoint(x: p.x - 12, y: p.y)); cross.addLine(to: CGPoint(x: 0, y: p.y))
            ctx.stroke(cross, with: .color(skin.accent.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    // MARK: Nodes

    /// The band nodes: numbered squares, the selected one in the accent,
    /// with a crosshair reaching to the axes.
    @ViewBuilder
    private func nodeLayer(_ size: CGSize) -> some View {
        let nodes = ZStack {
            ForEach(Array(data.bands.enumerated()), id: \.element.id) { index, band in
                node(index, band, size)
            }
        }
        .frame(width: size.width, height: size.height)
        nodes
    }

    private func node(_ index: Int, _ band: EQBand, _ size: CGSize) -> some View {
        let p = nodePoint(band, size)
        let isSelected = band.id == equalizer.selectedBandID
        let d: CGFloat = isSelected ? 22 : 18
        return Text("\(index + 1)")
            .font(AppFont.ui(10, weight: .semibold))
            .foregroundStyle(isSelected ? skin.textOnAccent : skin.textPrimary)
            .frame(width: d, height: d)
            .modifier(NodeSurface(skin: skin, selected: isSelected))
            .opacity(band.enabled ? 1 : 0.4)
            .position(p)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragging?.id != band.id {
                        equalizer.checkpoint()
                        equalizer.selectedBandID = band.id
                        dragging = (band.id, band.frequency, band.gain)
                    }
                    guard let start = dragging else { return }
                    let fine = NSEvent.modifierFlags.contains(.shift) ? 0.15 : 1
                    let startX = x(start.startF, size.width)
                    let startY = y(start.startG, size.height)
                    let nx = startX + g.translation.width * fine
                    let ny = startY + g.translation.height * fine
                    // ⌥ locks frequency, ⌘ locks gain.
                    let lockF = NSEvent.modifierFlags.contains(.option)
                    let lockG = NSEvent.modifierFlags.contains(.command)
                    equalizer.updateBand(band.id) { b in
                        if !lockF { b.frequency = frequency(atX: nx, size.width) }
                        if b.type.hasGain, !lockG { b.gain = (gain(atY: ny, size.height) * 10).rounded() / 10 }
                    }
                }
                .onEnded { _ in dragging = nil }
        )
        .onTapGesture(count: 2) { equalizer.updateBand(band.id, checkpoint: true) { $0.enabled.toggle() } }
        .help(describe(band))
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private func readout(at p: CGPoint, _ size: CGSize) -> some View {
        let f = frequency(atX: p.x, size.width)
        let g = gain(atY: p.y, size.height)
        return Text("\(EQFormat.frequency(f))  \(String(format: "%+.1f dB", g))")
            .font(AppFont.ui(9.5, weight: .medium))
            .foregroundStyle(skin.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Rectangle().fill(skin.bgVoid.opacity(0.7)))
            .position(x: min(size.width - 50, max(50, p.x)), y: max(12, p.y - 16))
            .allowsHitTesting(false)
    }

    private func describe(_ band: EQBand) -> String {
        var parts = [band.type.label, EQFormat.frequency(band.frequency)]
        if band.type.hasGain { parts.append(String(format: "%+.1f dB", band.gain)) }
        if band.type.hasQ { parts.append(String(format: "Q %.2f", band.q)) }
        if band.type.hasSlope { parts.append("\(band.slope) dB/oct") }
        return parts.joined(separator: " · ")
    }

    private func contextMenu(_ size: CGSize) -> MenuContent {
        if let hover, let band = hoveredBand(at: hover, size) ?? data.bands.first(where: { $0.id == equalizer.selectedBandID }) {
            let types = MenuContent(entries: EQFilterType.allCases.map { t in
                .action(t.label, checked: band.type == t) { equalizer.updateBand(band.id, checkpoint: true) { $0.type = t } }
            })
            let slopes = MenuContent(entries: EQBand.slopes.map { s in
                .action("\(s) dB/oct", checked: band.slope == s) { equalizer.updateBand(band.id, checkpoint: true) { $0.slope = s } }
            })
            return MenuContent(title: band.type.label + " · " + EQFormat.frequency(band.frequency), subtitle: describe(band), [
                MenuGroup(nil, [.submenu("Type", glyph: "waveform.path.ecg", detail: band.type.label, types)]
                    + (band.type.hasSlope ? [.submenu("Slope", glyph: "chart.bar", detail: "\(band.slope) dB/oct", slopes)] : [])),
                MenuGroup(nil, [
                    .action(band.enabled ? "Bypass" : "Enable", glyph: "power") {
                        equalizer.updateBand(band.id, checkpoint: true) { $0.enabled.toggle() }
                    },
                    .action(equalizer.soloBandID == band.id ? "Unsolo" : "Solo", glyph: "scope",
                            checked: equalizer.soloBandID == band.id) {
                        equalizer.soloBandID = equalizer.soloBandID == band.id ? nil : band.id
                    },
                    .action("Reset Gain", glyph: "arrow.counterclockwise", enabled: band.type.hasGain && band.gain != 0) {
                        equalizer.updateBand(band.id, checkpoint: true) { $0.gain = 0 }
                    },
                    .action("Duplicate", glyph: "plus.square.on.square") { equalizer.duplicateBand(band.id) },
                ]),
                MenuGroup(nil, [.action("Delete Band", glyph: "trash", detail: "⌫", destructive: true) { equalizer.removeBand(band.id) }]),
            ])
        } else if let hover {
            let f = frequency(atX: hover.x, size.width)
            let g = gain(atY: hover.y, size.height)
            return MenuContent(title: "Add band", subtitle: EQFormat.frequency(f) + String(format: " · %+.1f dB", g), entries:
                EQFilterType.allCases.map { type in
                    .action(type.label, glyph: "plus") {
                        equalizer.addBand(frequency: f, gain: type.hasGain ? g : 0, type: type)
                    }
                })
        }
        return MenuContent(entries: [])
    }
}

/// A node's body: a dark square with a 1px frame; solid accent when selected.
private struct NodeSurface: ViewModifier {
    var skin: Skin
    var selected: Bool

    func body(content: Content) -> some View {
        content
            .background(Rectangle().fill(selected ? skin.accent : Color.black.opacity(0.85)))
            .overlay(Rectangle().strokeBorder(selected ? skin.accent : skin.textPrimary.opacity(0.45), lineWidth: 1))
    }
}

/// Eases the analyzer toward each new frame at display rate. The engine's
/// tap delivers only ~10 frames a second; drawn raw, the curve jumps.
/// Rises are quick and falls slow, as on a hardware analyzer, and each
/// point is blended with its neighbors so the line stays fluid.
private final class AnalyzerMotion {
    private var values: [Float] = []
    private var last: Date?

    func step(toward target: [Float], at date: Date) -> [Float] {
        let dt = Float(min(0.1, max(0, date.timeIntervalSince(last ?? date))))
        last = date
        let goal = target.isEmpty ? values.map { _ in Float(-120) } : target
        if values.count != goal.count { values = goal }
        let rise = 1 - exp(-dt / 0.045), fall = 1 - exp(-dt / 0.32)
        for i in values.indices {
            let t = goal[i]
            values[i] += (t - values[i]) * (t > values[i] ? rise : fall)
        }
        guard values.count > 2 else { return values }
        var out = values
        for i in 1..<values.count - 1 {
            out[i] = values[i - 1] * 0.25 + values[i] * 0.5 + values[i + 1] * 0.25
        }
        return out
    }
}

enum EQFormat {
    static func frequency(_ hz: Double) -> String {
        hz >= 1000 ? String(format: hz >= 10_000 ? "%.1f kHz" : "%.2f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    static func parseFrequency(_ s: String) -> Double? {
        let t = s.lowercased().replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "hz", with: "").trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("k"), let v = Double(t.dropLast().trimmingCharacters(in: .whitespaces)) { return v * 1000 }
        return Double(t)
    }
}

// MARK: - Band chip

private struct BandChip: View {
    var index: Int
    var band: EQBand
    var selected: Bool
    var soloed: Bool
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(String(format: "%02d", index + 1))
                    .font(AppFont.ui(10, weight: .medium))
                    .foregroundStyle(selected ? skin.accent : skin.textTertiary)
                Glyph(band.type.symbol, size: 9)
                Text(EQFormat.frequency(band.frequency)).font(AppFont.ui(11, weight: .medium))
                if soloed { Text("S").font(AppFont.ui(9, weight: .heavy)).foregroundStyle(skin.accent) }
            }
            .foregroundStyle(selected ? skin.textPrimary : skin.textSecondary)
            .opacity(band.enabled ? 1 : 0.5)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Rectangle().fill(skin.textPrimary.opacity(selected ? 0.16 : hovering ? 0.1 : 0.05)))
            .overlay(Rectangle().strokeBorder(selected ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDipStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Inspector

private struct BandInspector: View {
    @ObservedObject var equalizer: EqualizerSettings
    var band: EQBand
    var index: Int
    var skin: Skin

    private var color: Color { skin.accent }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("band " + String(format: "%02d", index + 1))
                    .textRole(.eqLabels, size: 11, weight: .medium, color: skin.textTertiary)
                MenuButton(content: {
                    MenuContent(entries: EQFilterType.allCases.map { t in
                        .action(t.label, glyph: t.symbol, checked: band.type == t) { set { $0.type = t } }
                    })
                }) {
                    HStack(spacing: 5) {
                        Glyph(band.type.symbol, size: 9)
                        Text(band.type.label)
                        Glyph("chevron.down", size: 7).opacity(0.6)
                    }
                    .frame(width: 104, alignment: .leading)
                }
                .fixedSize()
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                HStack(spacing: 6) {
                    Button(band.enabled ? "On" : "Off") { set { $0.enabled.toggle() } }
                        .buttonStyle(PillButtonStyle(skin: skin, isActive: band.enabled, compact: true))
                        .help("Bypass this band")
                    Button("Solo") { equalizer.soloBandID = equalizer.soloBandID == band.id ? nil : band.id }
                        .buttonStyle(PillButtonStyle(skin: skin, isActive: equalizer.soloBandID == band.id, compact: true))
                        .help("Hear only what this band's frequency range contains")
                }
            }
            .frame(width: 128, alignment: .leading)

            knob("Frequency", value: Binding(get: { band.frequency }, set: { v in live { $0.frequency = v } }),
                 range: EQBand.frequencyRange, defaultValue: 1000, log: true,
                 text: EQFormat.frequency(band.frequency), parse: EQFormat.parseFrequency) { v in set { $0.frequency = v } }

            if band.type.hasGain {
                knob("Gain", value: Binding(get: { band.gain }, set: { v in live { $0.gain = v } }),
                     range: equalizer.data.gainRange.closed, defaultValue: 0, bipolar: true,
                     text: String(format: "%+.1f dB", band.gain), parse: { Double($0.replacingOccurrences(of: ",", with: ".")) }) { v in set { $0.gain = v } }
            }
            if band.type.hasQ {
                knob("Q", value: Binding(get: { band.q }, set: { v in live { $0.q = v } }),
                     range: EQBand.qRange, defaultValue: band.type == .notch ? 4 : 0.71, log: true,
                     text: String(format: "%.2f", band.q), parse: { Double($0.replacingOccurrences(of: ",", with: ".")) }) { v in set { $0.q = v } }
            }
            if band.type.hasSlope {
                VStack(spacing: 8) {
                    Text("Slope").font(AppFont.ui(11, weight: .medium)).foregroundStyle(skin.textTertiary)
                    HStack(spacing: 3) {
                        ForEach(EQBand.slopes, id: \.self) { s in
                            Button("\(s)") { set { $0.slope = s } }
                                .buttonStyle(PillButtonStyle(skin: skin, isActive: band.slope == s, compact: true))
                        }
                    }
                    Text("dB / octave").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    IconButton(icon: "plus.square.on.square", help: "Duplicate band", skin: skin) { equalizer.duplicateBand(band.id) }
                        .disabled(!equalizer.canAddBand)
                    IconButton(icon: "trash", help: "Delete band (⌫)", skin: skin) { equalizer.removeBand(band.id) }
                }
                VStack(alignment: .trailing, spacing: 3) {
                    Text("⇧ drag  fine")
                    Text("⌥ drag  lock frequency")
                    Text("⌘ drag  lock gain")
                    Text("scroll  width")
                }
                .font(AppFont.ui(10))
                .foregroundStyle(skin.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func knob(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double,
                      log: Bool = false, bipolar: Bool = false, text: String,
                      parse: @escaping (String) -> Double?, commit: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 6) {
            Text(title).textRole(.eqLabels, size: 11, weight: .medium, color: skin.textTertiary)
            Knob(value: value, range: range, defaultValue: defaultValue, logarithmic: log, bipolar: bipolar,
                 size: 46, tint: color, skin: skin, onBegin: { equalizer.checkpoint() })
            EditableValue(text: text, skin: skin, width: 78, parse: parse, commit: commit)
        }
    }

    /// A one-off change that gets its own undo step.
    private func set(_ body: (inout EQBand) -> Void) { equalizer.updateBand(band.id, checkpoint: true, body) }
    /// A step of a gesture whose checkpoint was taken when it began.
    private func live(_ body: (inout EQBand) -> Void) { equalizer.updateBand(band.id, body) }
}

// MARK: - Output meter

/// Peak level after the EQ with a held peak and a clip light, so boosts
/// that overload are visible.
private struct OutputMeter: View {
    let feed: SpectrumFeed
    var isPlaying: Bool
    var skin: Skin

    @State private var held: (db: Float, at: Date) = (-120, .distantPast)
    @State private var clipped = false
    @State private var display: Float = -120

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { t in
            let db = isPlaying ? feed.peakDB : -120
            Canvas { ctx, size in
                let h = size.height
                func fy(_ v: Float) -> CGFloat { h * (1 - CGFloat((min(3, max(-60, v)) + 60) / 63)) }
                let track = Path(CGRect(x: size.width / 2 - 4, y: 0, width: 8, height: h))
                ctx.fill(track, with: .color(skin.textPrimary.opacity(0.08)))
                let top = fy(display)
                ctx.clip(to: track)
                // One flat color; only the top 3 dB turns red.
                ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: h - top)), with: .color(skin.textPrimary.opacity(0.75)))
                if display > -3 {
                    ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: max(0, fy(-3) - top))), with: .color(.red))
                }
                ctx.fill(Path(CGRect(x: 0, y: fy(held.db) - 1, width: size.width, height: 2)), with: .color(skin.textPrimary))
            }
            .overlay {
                Canvas { ctx, size in
                    let h = size.height
                    for mark: Float in [0, -6, -12, -24, -48] {
                        let y = h * (1 - CGFloat((mark + 60) / 63))
                        ctx.draw(Text(mark == 0 ? "0" : "\(Int(mark))").font(AppFont.ui(8.5)).foregroundColor(skin.textTertiary),
                                 at: CGPoint(x: size.width / 2 + 8, y: y), anchor: .leading)
                    }
                }
                .allowsHitTesting(false)
            }
            .onChange(of: t.date) { now in
                display = max(db, display - 1.2)
                if db > held.db || now.timeIntervalSince(held.at) > 1.5 { held = (db, now) }
                if db >= -0.1 { clipped = true }
            }
        }
        .frame(width: 56)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(clipped ? Color.red : skin.textPrimary.opacity(0.1))
                .frame(width: 8, height: 8)
                .offset(y: -12)
                .onTapGesture { clipped = false }
                .help(clipped ? "The output clipped. Click to reset." : "Clip indicator")
        }
        .padding(.top, 12)
    }
}

// MARK: - Keys

/// ⌘Z / ⇧⌘Z for EQ undo, ⌫ to delete the selected band, while the EQ
/// window is key and no text field is editing.
private struct EQKeyCommands: NSViewRepresentable {
    let equalizer: EqualizerSettings

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.equalizer = equalizer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyView: NSView {
        weak var equalizer: EqualizerSettings?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let eq = self.equalizer, event.window === self.window,
                      !(event.window?.firstResponder is NSText) else { return event }
                let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let isZ = event.charactersIgnoringModifiers?.lowercased() == "z"
                let isDelete = event.keyCode == 51 || event.keyCode == 117
                let handled = MainActor.assumeIsolated { () -> Bool in
                    if isZ, mods.contains(.command) {
                        mods.contains(.shift) ? eq.redo() : eq.undo()
                        return true
                    }
                    if mods.isEmpty, isDelete, let id = eq.selectedBandID {
                        eq.removeBand(id)
                        return true
                    }
                    return false
                }
                return handled ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

// MARK: - Name prompt

struct NamePrompt: View {
    var title: String
    var initial: String
    var skin: Skin
    var done: (String?) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(AppFont.ui(14, weight: .semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Rectangle().fill(skin.textPrimary.opacity(0.08)))
                .onSubmit { done(name) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .buttonStyle(PillButtonStyle(skin: skin))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(name) }
                    .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .foregroundStyle(skin.textPrimary)
        .glassSheet(skin)
        .onAppear { name = initial }
    }
}

// MARK: - Window

/// The player bar's EQ button: lit while the EQ is on, opens the window.
struct EqualizerTransportButton: View {
    @ObservedObject var equalizer: EqualizerSettings
    var skin: Skin
    var size: CGFloat
    var iconSize: CGFloat
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TransportButton(icon: "slider.vertical.3", size: size, iconSize: iconSize, isActive: equalizer.data.enabled,
                        help: equalizer.data.enabled ? "Equalizer: \(equalizer.activeProfileName)" : "Equalizer (off)", skin: skin) {
            openWindow(id: "equalizer")
        }
    }
}

/// Root of the Equalizer window: the app's backdrop and chrome around the EQ.
struct EqualizerWindowView: View {
    @ObservedObject private var player = AppSession.shared.player
    @ObservedObject private var theme = AppSession.shared.theme
    @ObservedObject private var settings = AppSession.shared.settings
    @ObservedObject private var customize = AppSession.shared.customize

    var body: some View {
        let skin = settings.glassWindowSkin(theme.skin)
        EqualizerView(equalizer: player.equalizer, engine: player.engine, skin: skin)
            .font(AppFont.ui(12))
            .coordinateSpace(name: customizeSpace)
            .overlayPreferenceValue(CustomFramesKey.self) { frames in
                CustomizeLayer(frames: frames, store: customize, settings: settings, skin: skin)
            }
            .frame(minWidth: 860, minHeight: 560)
            .glassWindow(skin, minSize: NSSize(width: 860, height: 560))
            .navigationTitle("Equalizer")
            .preferredColorScheme(.dark)
    }
}
