import SwiftUI

/// Settings sections, listed in the window's left-hand rail.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case layout, panels, table, equalizer, appearance, behavior, sources
    var id: String { rawValue }

    var label: String {
        switch self {
        case .layout: return "Layout"
        case .panels: return "Panels"
        case .table: return "Library Table"
        case .equalizer: return "Equalizer"
        case .appearance: return "Appearance"
        case .behavior: return "Behavior"
        case .sources: return "Sources"
        }
    }
    var icon: String {
        switch self {
        case .layout: return "arrow.up.left.and.arrow.down.right"
        case .panels: return "rectangle.3.group"
        case .table: return "tablecells"
        case .equalizer: return "slider.vertical.3"
        case .appearance: return "paintpalette"
        case .behavior: return "switch.2"
        case .sources: return "dot.radiowaves.up.forward"
        }
    }
    var subtitle: String {
        switch self {
        case .layout: return "Density, rail width, and cover size"
        case .panels: return "Show, size, and tune each piece of chrome individually"
        case .table: return "Columns, grouping, and row styling"
        case .equalizer: return "Parametric EQ and signal path"
        case .appearance: return "Create, name, and recolor your own themes"
        case .behavior: return "Click, crossfade, fetch, and memory"
        case .sources: return "Soulseek network"
        }
    }
}

/// Opens Settings at a page: set `target` to a section's raw value
/// ("equalizer", "sources") and open the "settings" window.
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var target: String?
}

/// The Settings window: frosted glass like the other child windows.
struct SettingsWindowView: View {
    @ObservedObject private var theme = AppSession.shared.theme
    @ObservedObject private var settings = AppSession.shared.settings

    var body: some View {
        let skin = settings.styled(theme.skin)
        SettingsView(settings: settings, theme: theme, equalizer: AppSession.shared.player.equalizer, player: AppSession.shared.player)
            .font(AppFont.ui(12))
            .foregroundStyle(skin.textPrimary)
            .glassWindow(skin, minSize: NSSize(width: 820, height: 600))
            .navigationTitle("Settings")
            .preferredColorScheme(.dark)
    }
}

/// The Settings window's content. Every control is drawn in the active
/// skin, and each page carries a live preview of what it changes.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var theme: ThemeManager
    @ObservedObject var equalizer: EqualizerSettings
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var section: SettingsSection

    /// Opened from the Downloads button while Soulseek is off: say so up front.
    @State private var promptSoulseek: Bool

    init(settings: AppSettings, theme: ThemeManager, equalizer: EqualizerSettings, player: PlayerController,
         startOnEqualizer: Bool = false, startOnSources: Bool = false) {
        _promptSoulseek = State(initialValue: startOnSources)
        self.settings = settings
        self.theme = theme
        self.equalizer = equalizer
        self.player = player
        _section = State(initialValue: startOnEqualizer ? .equalizer : startOnSources ? .sources : .layout)
    }

    private var skin: Skin { settings.styled(theme.skin) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Corners.inset) {
                nav
                    .frame(width: 196)
                    .frostedPane(skin, tint: GlassWindow.railTint)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        page
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipShape(Rectangle())
                .frostedPane(skin, tint: GlassWindow.pageTint)
            }
        }
        .padding(.horizontal, Corners.inset)
        .padding(.bottom, Corners.inset)
        .padding(.top, TitleBand.height)
        .overlay(alignment: .top) { WindowDragArea().frame(height: TitleBand.height) }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                if !settings.data.systemWindowFrame { WindowControls(skin: skin, closeOnly: true) }
                Text("settings").font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
            }
            .frame(height: TitleBand.height)
            .padding(.leading, TitleBand.controlsLeading)
        }
        .frame(minWidth: 820, minHeight: 600)
        .onReceive(SettingsNavigator.shared.$target) { target in
            guard let target else { return }
            if let s = SettingsSection(rawValue: target) { section = s }
            // Sent here from Downloads while Soulseek is off: say so on the Sources page.
            promptSoulseek = target == "sources"
            SettingsNavigator.shared.target = nil
        }
        .preferredColorScheme(.dark)
    }

    private var nav: some View {
        VStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { s in
                SettingsNavRow(icon: s.icon, title: s.label, isSelected: s == section, skin: skin) {
                    section = s
                }
            }
            Spacer()
            Hairline(color: skin.hairline, inset: 4).padding(.vertical, 6)
            Button {
                settings.resetToDefaults()
            } label: {
                HStack(spacing: 6) {
                    Glyph("arrow.counterclockwise", size: 10.5)
                    Text("Reset to Defaults")
                        .font(AppFont.ui(11))
                }
                .foregroundStyle(skin.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .layout: LayoutPage(settings: settings, skin: skin)
        case .panels: PanelsPage(settings: settings, skin: skin)
        case .table: TablePage(settings: settings, skin: skin)
        case .equalizer: EqualizerPage(equalizer: equalizer, player: player, skin: skin)
        case .appearance: AppearancePage(settings: settings, theme: theme, skin: skin)
        case .behavior: BehaviorPage(settings: settings, skin: skin)
        case .sources: SourcesSettingsPage(store: AppSession.shared.soulseek, skin: skin, prompted: promptSoulseek)
        }
    }
}

// MARK: - Layout page

private struct LayoutPage: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Density", skin: skin) {
                SettingsSegmented(options: LayoutDensity.allCases, selection: $settings.data.density, label: \.label, skin: skin)
                Text("Row height, bar height, and type size.")
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
                    .padding(.top, 8)
            }

            SettingsCard(title: "Preview", skin: skin) {
                DensityPreview(skin: skin, density: settings.data.density)
            }

            SettingsCard(title: "Album & Artist Grids", skin: skin) {
                SettingsSliderRow(title: "Cover size", value: $settings.data.albumGridTileSize, range: 110...240, skin: skin,
                                  sliderStyle: settings.data.sliderStyle) { "\(Int($0)) pt" }
            }

            SettingsCard(title: "Library Header", skin: skin) {
                SettingsToggleRow(title: "Filter field", subtitle: "Narrows the list as you type. ⌘F focuses it, Esc clears it.",
                                  isOn: $settings.data.showSearchField, skin: skin)
                SettingsRowDivider(skin: skin)
                SettingsSliderRow(title: "Filter width", value: $settings.data.searchFieldWidth, range: 140...320, skin: skin,
                                  sliderStyle: settings.data.sliderStyle) { "\(Int($0)) pt" }
                    .opacity(settings.data.showSearchField ? 1 : 0.4)
                    .disabled(!settings.data.showSearchField)
            }
        }
    }
}

// MARK: - Panels page (nested master-detail)

private struct PanelsPage: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin
    @State private var selectedPanel: PanelKind = .nowPlayingRail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelLayoutDiagram(skin: skin, settings: settings.data, highlighted: selectedPanel)
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 2) {
                    ForEach(PanelKind.allCases) { panel in
                        SettingsNavRow(
                            icon: panel.icon, title: panel.label, isSelected: panel == selectedPanel,
                            trailingText: isEnabled(panel) ? "On" : "Off", trailingIsOn: isEnabled(panel),
                            skin: skin
                        ) {
                            selectedPanel = panel
                        }
                    }
                }
                .frame(width: 176)
                SettingsCard(title: selectedPanel.label, skin: skin) {
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func isEnabled(_ panel: PanelKind) -> Bool {
        switch panel {
        case .nowPlayingRail: return settings.data.showSidebar
        case .albumGrid: return settings.data.showAlbumGrid
        case .lyrics: return settings.data.showLyrics
        case .statusBar: return settings.data.showStatusBar
        case .spectrum: return settings.data.showSpectrum
        case .transportButtons: return true
        case .eqToggle: return settings.data.showEQToggle
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPanel {
        case .nowPlayingRail: nowPlayingRailDetail
        case .albumGrid: albumGridDetail
        case .lyrics: lyricsDetail
        case .statusBar: statusBarDetail
        case .spectrum: spectrumDetail
        case .transportButtons: transportButtonsDetail
        case .eqToggle: eqToggleDetail
        }
    }

    private var nowPlayingRailDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsToggleRow(title: "Show this panel", isOn: $settings.data.showSidebar, skin: skin)
            SettingsRowDivider(skin: skin)
            SettingsSegmented(options: SidebarWidthMode.allCases, selection: $settings.data.sidebarWidthMode, label: \.label, skin: skin)
            if settings.data.sidebarWidthMode == .proportional {
                SettingsSliderRow(title: "Proportion of window", value: $settings.data.sidebarProportionalPercent, range: 0.16...0.4, skin: skin, sliderStyle: settings.data.sliderStyle) {
                    "\(Int($0 * 100))%"
                }
            } else {
                SettingsSliderRow(title: "Fixed width", value: $settings.data.sidebarFixedWidth, range: 220...480, skin: skin, sliderStyle: settings.data.sliderStyle) { "\(Int($0))px" }
            }
            SettingsRowDivider(skin: skin)
            SettingsToggleRow(title: "Show format/technical info strip", isOn: $settings.data.showFormatStrip, skin: skin)
            SettingsToggleRow(title: "Show album / year subtitle", isOn: $settings.data.showNowPlayingSubtitle, skin: skin)
        }
    }

    private var lyricsDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsToggleRow(
                title: "Show lyrics panel",
                subtitle: "Shows the .lrc next to the playing file. Synced lyrics follow along.",
                isOn: $settings.data.showLyrics,
                skin: skin
            )
            SettingsRowDivider(skin: skin)
            SettingsSliderRow(
                title: "Timing offset",
                value: $settings.data.lyricsOffset,
                range: -5...5,
                skin: skin,
                sliderStyle: settings.data.sliderStyle
            ) { String(format: "%+.1f s", $0) }
        }
    }

    private var albumGridDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsToggleRow(title: "Show this panel", subtitle: "Your playlists and account, on the right.", isOn: $settings.data.showAlbumGrid, skin: skin)
        }
    }

    private var statusBarDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsToggleRow(title: "Show this panel", isOn: $settings.data.showStatusBar, skin: skin)
            SettingsRowDivider(skin: skin)
            SettingsToggleRow(title: "Show selection count", isOn: $settings.data.statusBarShowSelectionCount, skin: skin)
            SettingsToggleRow(title: "Show scan progress", isOn: $settings.data.statusBarShowScanProgress, skin: skin)
        }
    }

    private var spectrumDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsToggleRow(title: "Show this panel", isOn: $settings.data.showSpectrum, skin: skin)
            SettingsRowDivider(skin: skin)
            SettingsSegmented(options: SpectrumStyleOption.allCases, selection: $settings.data.spectrumStyle, label: \.label, skin: skin)
            SettingsSliderRow(title: "Bands", value: Binding(get: { Double(settings.data.spectrumBandCount) }, set: { settings.data.spectrumBandCount = Int($0.rounded()) }),
                              range: 8...64, skin: skin, sliderStyle: settings.data.sliderStyle) { "\(Int($0))" }
            SettingsSliderRow(title: "Bar spacing", value: $settings.data.spectrumBarSpacing, range: 0...5, skin: skin, sliderStyle: settings.data.sliderStyle) { String(format: "%.0f pt", $0) }
            SettingsSliderRow(title: "Width", value: $settings.data.spectrumWidth, range: 60...240, skin: skin, sliderStyle: settings.data.sliderStyle) { "\(Int($0)) pt" }
            SettingsRowDivider(skin: skin)
            SettingsToggleRow(title: "Peak caps", subtitle: "A marker that holds each bar's recent peak, then falls.", isOn: $settings.data.spectrumShowPeaks, skin: skin)
        }
    }

    private var transportButtonsDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Position").font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).padding(.bottom, 4)
            SettingsSegmented(options: PlayerBarPosition.allCases, selection: $settings.data.playerBarPosition, label: \.label, skin: skin)
            SettingsRowDivider(skin: skin)
            Text("Style").font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).padding(.bottom, 4)
            SettingsSegmented(options: PlayerBarStyle.allCases, selection: $settings.data.playerBarStyle, label: \.label, skin: skin)
            Text("Comfy shows the artist and both times; Compact fits everything on one line.")
                .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).padding(.top, 4)
            SettingsRowDivider(skin: skin)
            SettingsToggleRow(title: "Shuffle and repeat", isOn: $settings.data.showShuffleRepeat, skin: skin)
            SettingsToggleRow(title: "Lyrics button", isOn: $settings.data.showLyricsButton, skin: skin)
            SettingsToggleRow(title: "Up Next button", isOn: $settings.data.showQueueButton, skin: skin)
            SettingsToggleRow(title: "Equalizer button", isOn: $settings.data.showEQToggle, skin: skin)
            SettingsToggleRow(title: "Mini player button", isOn: $settings.data.showMiniPlayerButton, skin: skin)
            SettingsToggleRow(title: "Accent-colored progress", subtitle: "Otherwise the progress line uses the text color.",
                              isOn: $settings.data.accentProgress, skin: skin)
            SettingsRowDivider(skin: skin)
            SettingsSliderRow(title: "Control size", value: $settings.data.transportButtonScale, range: 0.85...1.3, skin: skin, sliderStyle: settings.data.sliderStyle) { String(format: "%.2f×", $0) }
            SettingsSliderRow(title: "Volume slider width", value: $settings.data.volumeSliderWidth, range: 50...160, skin: skin, sliderStyle: settings.data.sliderStyle) { "\(Int($0)) pt" }
        }
    }

    private var eqToggleDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsToggleRow(
                title: "Show equalizer button in transport bar",
                subtitle: "Opens the quick EQ rack; it lights up while the EQ is on.",
                isOn: $settings.data.showEQToggle,
                skin: skin
            )
        }
    }
}

// MARK: - Library Table page

private struct TablePage: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Preview", skin: skin) {
                TableColumnsPreview(skin: skin, settings: settings.data)
            }

            SettingsCard(title: "Grouping", skin: skin) {
                SettingsSegmented(options: TableGroupMode.allCases, selection: $settings.data.groupBy, label: \.label, skin: skin)
                Text("Groups are sorted by name; tracks keep the list's order inside each group.")
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
                    .padding(.top, 8)
            }

            SettingsCard(title: "Visible Columns", skin: skin) {
                Text("Title is always shown.")
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
                    .padding(.bottom, 4)
                ForEach(Array(TrackColumnKind.allCases.enumerated()), id: \.offset) { index, column in
                    if index > 0 { SettingsRowDivider(skin: skin) }
                    SettingsToggleRow(
                        title: column.label,
                        isOn: Binding(
                            get: { settings.data.visibleColumns.contains(column) },
                            set: { _ in settings.toggleColumn(column) }
                        ),
                        skin: skin
                    )
                }
            }

            SettingsCard(title: "Row Style", skin: skin) {
                SettingsToggleRow(title: "Show vertical grid lines", isOn: $settings.data.tableShowGridLines, skin: skin)
                SettingsRowDivider(skin: skin)
                SettingsToggleRow(title: "Alternating row colors", isOn: $settings.data.tableAlternatingRows, skin: skin)
                SettingsRowDivider(skin: skin)
                SettingsToggleRow(
                    title: "Hi-Res badge",
                    subtitle: "Icons in the Format column for lossless and hi-res files.",
                    isOn: $settings.data.showHiResBadge,
                    skin: skin
                )
            }
        }
    }
}

// MARK: - Equalizer page

/// The EQ itself lives in its own window; this page shows where the signal
/// goes and opens it.
private struct EqualizerPage: View {
    @ObservedObject var equalizer: EqualizerSettings
    @ObservedObject var player: PlayerController
    var skin: Skin
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Signal Path", skin: skin) {
                SignalPathView(
                    equalizerEnabled: equalizer.data.enabled,
                    preamp: equalizer.data.preampGain,
                    volume: player.engine.volume,
                    sampleRate: player.currentTrack?.sampleRate,
                    bitDepth: player.currentTrack?.bitDepth,
                    fileFormat: player.currentTrack?.fileFormat,
                    isPlaying: player.engine.isPlaying,
                    skin: skin
                )
            }

            SettingsCard(skin: skin) {
                SettingsToggleRow(
                    title: "Enable Equalizer",
                    subtitle: "Bypassed entirely when off: zero effect on sound.",
                    isOn: Binding(get: { equalizer.data.enabled }, set: { equalizer.setEnabled($0) }),
                    skin: skin
                )
            }

            SettingsCard(title: "\(equalizer.activeProfileName) · \(equalizer.data.bands.count) bands", skin: skin) {
                EQCurvePreview(data: equalizer.data, skin: skin, height: 96)
                HStack {
                    Text("Up to \(eqEngineSlots) filters, with solo, A/B compare, undo, and AutoEQ import.")
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.textTertiary)
                    Spacer(minLength: 12)
                    Button("Open Equalizer") { openWindow(id: "equalizer") }
                        .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                }
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Appearance page

private struct AppearancePage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var theme: ThemeManager
    var skin: Skin

    @State private var expandedThemeID: UUID?
    @State private var editingNameID: UUID?
    @State private var editingNameText = ""
    @State private var isCreatingTheme = false
    @State private var showingGenerator = false
    @State private var newThemeName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Preview", skin: skin) {
                AppearancePreviewCard(skin: skin, settings: settings.data)
            }

            SettingsCard(title: "Themes", skin: skin) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedThemes, id: \.label) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.label)
                                .font(AppFont.ui(9.5, weight: .semibold))
                                .foregroundStyle(skin.textTertiary)
                                .padding(.leading, 4)
                                .padding(.bottom, 2)
                            ForEach(group.themes) { t in
                                themeRow(t)
                            }
                        }
                    }
                }
                SettingsRowDivider(skin: skin)
                newThemeRow
            }

            SettingsCard(title: "Window", skin: skin) {
                SettingsToggleRow(title: "Use the system window frame",
                                  subtitle: "Rounded corners and the system's window buttons.",
                                  isOn: $settings.data.systemWindowFrame, skin: skin)
            }
            SettingsCard(title: "Surfaces & Backdrop", skin: skin) {
                Text("Surfaces").font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).padding(.bottom, 4)
                SettingsSegmented(options: SurfaceStyle.allCases, selection: $settings.data.surfaceStyle, label: \.label, skin: skin)
                Text("Glass panels are dark and translucent over the backdrop; Solid panels are opaque.")
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).padding(.top, 4)
                SettingsRowDivider(skin: skin)
                Text("Backdrop").font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).padding(.bottom, 4)
                SettingsSegmented(options: BackdropStyle.allCases, selection: $settings.data.backdropStyle, label: \.label, skin: skin)
                    .disabled(theme.isAlbumReactive)
                Text(theme.isAlbumReactive
                     ? "From Cover always uses the album art."
                     : "Album Art blurs the playing cover behind everything. Wallpaper shows what's behind the window, blurred. Grid is a faint measuring grid; Solid is plain.")
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).padding(.top, 4)
                if settings.data.backdropStyle == .translucent, !theme.isAlbumReactive {
                    SettingsRowDivider(skin: skin)
                    SettingsSliderRow(title: "Wallpaper dimming", value: $settings.data.glassTintStrength, range: 0.15...0.9, skin: skin,
                                      sliderStyle: settings.data.sliderStyle) { "\(Int(($0 * 100).rounded()))%" }
                    Text("Lower shows more of what's behind the window; higher keeps it darker and calmer.")
                        .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                }
                Group {
                    SettingsRowDivider(skin: skin)
                    SettingsSliderRow(title: "Glass window dimming", value: $settings.data.downloadsGlassTint, range: 0...0.6, skin: skin,
                                      sliderStyle: settings.data.sliderStyle) { "\(Int(($0 * 100).rounded()))%" }
                    Text("Downloads, Library, Equalizer, Settings and dialogs are frosted glass. Lower shows more of the desktop's color.")
                        .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                    if SystemAppearance.wallpaperTintingOn {
                        HStack(alignment: .top, spacing: 10) {
                            Glyph( "info.circle").foregroundStyle(skin.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("macOS tints see-through windows toward the wallpaper. Turn off “Allow wallpaper tinting in windows” to keep it neutral.")
                                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Open Appearance Settings") { SystemAppearance.openSettings() }
                                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }

            SettingsCard(title: "Shape & Dividers", skin: skin) {
                SettingsRowDivider(skin: skin)
                SettingsSliderRow(title: "Divider visibility", value: $settings.data.hairlineOpacity, range: 0.2...1.0, skin: skin, sliderStyle: settings.data.sliderStyle) { "\(Int($0 * 100))%" }
            }

            SettingsCard(title: "Controls & Type", skin: skin) {
                Text("Slider style").font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).padding(.bottom, 4)
                SettingsSegmented(options: SliderStyleOption.allCases, selection: $settings.data.sliderStyle, label: \.label, skin: skin)
            }

            SettingsCard(title: "Buttons", skin: skin) {
                ButtonSettingsEditor(settings: settings, skin: skin)
            }

            SettingsCard(title: "Window Controls", skin: skin) {
                WindowControlSettingsEditor(settings: settings, skin: skin)
            }

            SettingsCard(title: "Icons", skin: skin) {
                IconSettingsEditor(settings: settings, skin: skin)
            }

            SettingsCard(title: "Typeface", skin: skin) {
                FontMenu(selection: settings.data.fontFamily, skin: skin) { settings.data.fontFamily = $0 }
            }
        }
    }

    private var groupedThemes: [(label: String, themes: [CustomTheme])] {
        let groups = Dictionary(grouping: theme.themes, by: \.category)
        var ordered = CustomTheme.categoryOrder.compactMap { cat -> (label: String, themes: [CustomTheme])? in
            guard let items = groups[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
        let leftovers = groups.keys.filter { !CustomTheme.categoryOrder.contains($0) }.sorted()
        for key in leftovers {
            if let items = groups[key] { ordered.append((key, items)) }
        }
        return ordered
    }

    @ViewBuilder
    private func themeRow(_ t: CustomTheme) -> some View {
        let isActive = t.id == theme.activeThemeID
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { theme.setActive(t.id) } label: {
                    Glyph(isActive ? "largecircle.fill.circle" : "circle", size: 13)
                        .foregroundStyle(isActive ? skin.accent : skin.textTertiary)
                }
                .buttonStyle(.plain)

                HStack(spacing: 3) {
                    Rectangle().fill(t.isAlbumReactive && isActive ? skin.accent : Color(hex: t.accent)).frame(width: 11, height: 11)
                    Rectangle().fill(t.isAlbumReactive && isActive ? skin.bgPanel : Color(hex: t.bgPanel)).frame(width: 11, height: 11)
                        .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
                }

                if editingNameID == t.id {
                    TextField("", text: $editingNameText, onCommit: {
                        theme.rename(t.id, to: editingNameText)
                        editingNameID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(AppFont.ui(12, weight: .medium))
                    .foregroundStyle(skin.textPrimary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name)
                            .font(AppFont.ui(12, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(skin.textPrimary)
                        if t.isAlbumReactive {
                            Text("Live from the playing cover")
                                .font(AppFont.ui(9.5))
                                .foregroundStyle(skin.textTertiary)
                        }
                    }
                    .onTapGesture {
                        editingNameID = t.id
                        editingNameText = t.name
                    }
                }

                if t.isAlbumReactive {
                    Text("Live")
                        .font(AppFont.ui(8, weight: .semibold))
                        .foregroundStyle(skin.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(Rectangle().strokeBorder(skin.accent.opacity(0.5), lineWidth: 1))
                }

                Spacer()

                if !t.isAlbumReactive {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            expandedThemeID = expandedThemeID == t.id ? nil : t.id
                        }
                    } label: {
                        Glyph("paintbrush.pointed", size: 11)
                            .foregroundStyle(expandedThemeID == t.id ? skin.accent : skin.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit colors")
                }

                Button { theme.duplicate(t.id) } label: {
                    Glyph("plus.square.on.square", size: 11).foregroundStyle(skin.textSecondary)
                }
                .buttonStyle(.plain)
                .help(t.isAlbumReactive ? "Snapshot current cover as a new theme" : "Duplicate")

                if theme.themes.count > 1 {
                    Button { theme.delete(t.id) } label: {
                        Glyph("trash", size: 11).foregroundStyle(skin.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(Rectangle().fill(isActive ? skin.selection.opacity(0.35) : Color.clear))

            if expandedThemeID == t.id && !t.isAlbumReactive {
                themeColorEditor(t.id)
                    .padding(.bottom, 8)
            }
        }
    }

    private func themeColorEditor(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ThemeColorField.groups, id: \.self) { group in
                let fieldsInGroup = ThemeColorField.allCases.filter { $0.group == group }
                VStack(alignment: .leading, spacing: 0) {
                    Text(group)
                        .font(AppFont.ui(9.5, weight: .semibold))
                        .foregroundStyle(skin.textTertiary)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(fieldsInGroup) { field in
                        ColorFieldRow(label: field.label, hex: theme.binding(for: field, themeID: id), skin: skin)
                        if field.id != fieldsInGroup.last?.id {
                            SettingsRowDivider(skin: skin)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background(Rectangle().fill(skin.bgVoid.opacity(0.4)))
        .id(id) // fresh @State for every color row's picker when switching which theme is being edited
    }

    @ViewBuilder
    private var newThemeRow: some View {
        if isCreatingTheme {
            HStack(spacing: 8) {
                TextField("Theme name", text: $newThemeName, onCommit: confirmCreateTheme)
                    .textFieldStyle(.plain)
                    .font(AppFont.ui(12))
                    .foregroundStyle(skin.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Rectangle().fill(skin.bgVoid.opacity(0.6)))
                Button("Create") { confirmCreateTheme() }
                    .buttonStyle(.plain).font(AppFont.ui(11.5, weight: .semibold)).foregroundStyle(skin.accent)
                Button("Cancel") { isCreatingTheme = false; newThemeName = "" }
                    .buttonStyle(.plain).font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
            }
            .padding(.top, 6)
        } else {
            HStack(spacing: 16) {
                Button {
                    isCreatingTheme = true
                    newThemeName = ""
                } label: {
                    HStack(spacing: 6) {
                        Glyph("plus", size: 10.5)
                        Text("New Theme (from current)").font(AppFont.ui(11.5))
                    }
                    .foregroundStyle(skin.accent)
                }
                .buttonStyle(.plain)
                Button { showingGenerator = true } label: {
                    HStack(spacing: 6) {
                        Glyph("paintbrush.pointed", size: 10.5)
                        Text("Generate from colors…").font(AppFont.ui(11.5))
                    }
                    .foregroundStyle(skin.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
            .sheet(isPresented: $showingGenerator) {
                ThemeGeneratorSheet(theme: theme, skin: skin) { showingGenerator = false }
            }
        }
    }

    private func confirmCreateTheme() {
        let trimmed = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newID = theme.createTheme(named: trimmed.isEmpty ? "New Theme" : trimmed)
        theme.setActive(newID)
        isCreatingTheme = false
        newThemeName = ""
        expandedThemeID = newID
    }
}

// MARK: - Behavior page

struct SourcesSettingsPage: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var prompted = false
    @State private var devFirstRun = SoulseekDev.firstRunEveryLaunch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.settings.enabled { offNotice }
            SettingsCard(title: "Soulseek", skin: skin) {
                SettingsToggleRow(title: "Soulseek",
                                  subtitle: "Search and download from the Soulseek peer-to-peer network.",
                                  isOn: Binding(get: { store.settings.enabled }, set: { on in
                                      if on {
                                          store.settings.enabled = true
                                          dismiss()
                                          WindowRequest.downloads.post()
                                      } else {
                                          store.turnOff()
                                      }
                                  }), skin: skin)
                if store.settings.enabled {
                    SettingsRowDivider(skin: skin)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.settings.setupComplete ? store.settings.username : "Setup incomplete")
                                .font(AppFont.ui(12)).foregroundStyle(skin.textPrimary)
                            Text(store.settings.setupComplete ? "Status: \(store.status.label)" : "Complete setup in the Downloads window.")
                                .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                        }
                        Spacer()
                        Button("Open Downloads") { WindowRequest.downloads.post() }
                            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    }
                }
            }
            // DEV: remove before release (see SoulseekDev).
            SettingsCard(title: "Developer", skin: skin) {
                SettingsToggleRow(title: "Reset Soulseek at launch",
                                  subtitle: "Clears the account and setup state each time i2s opens. Downloaded files are kept.",
                                  isOn: Binding(get: { devFirstRun }, set: { devFirstRun = $0; SoulseekDev.firstRunEveryLaunch = $0 }),
                                  skin: skin)
            }
        }
    }
}

extension SourcesSettingsPage {
    /// Shown while Soulseek is off; in the accent when the Downloads button sent the user here.
    fileprivate var offNotice: some View {
        HStack(alignment: .center, spacing: 14) {
            Glyph("downloads", size: 16).foregroundStyle(prompted ? skin.accent : skin.textTertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Soulseek is disabled").font(AppFont.ui(13, weight: .semibold)).foregroundStyle(skin.textPrimary)
                Text("Enable Soulseek to search and download from the network.")
                    .font(AppFont.ui(11)).foregroundStyle(skin.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Enable Soulseek") {
                store.settings.enabled = true
                dismiss()
                WindowRequest.downloads.post()
            }
            .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
        }
        .padding(14)
        .background(Rectangle().fill(prompted ? skin.accent.opacity(0.1) : skin.textPrimary.opacity(0.03)))
        .overlay(Rectangle().strokeBorder(prompted ? skin.accent.opacity(0.6) : skin.textPrimary.opacity(0.12), lineWidth: 1))
        .fuiCorners(skin)
    }
}

private struct BehaviorPage: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Playback", skin: skin) {
                SettingsToggleRow(title: "Play on single click", subtitle: "Instead of double click", isOn: $settings.data.playOnSingleClick, skin: skin)
                SettingsRowDivider(skin: skin)
                SettingsSliderRow(
                    title: "Crossfade",
                    value: $settings.data.crossfadeSeconds,
                    range: 0...8,
                    skin: skin,
                    sliderStyle: settings.data.sliderStyle
                ) { $0 < 0.1 ? "Off (gapless)" : String(format: "%.1f s", $0) }
                Text("Overlaps the end of each track with the next. Off: gapless.")
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
                    .padding(.top, 4)
            }
            SettingsCard(title: "Library", skin: skin) {
                SettingsToggleRow(title: "Confirm before removing tracks from library", isOn: $settings.data.confirmBeforeRemovingFromLibrary, skin: skin)
                SettingsRowDivider(skin: skin)
                SettingsToggleRow(title: "Reopen the last list you were viewing", isOn: $settings.data.rememberLastView, skin: skin)
                SettingsRowDivider(skin: skin)
                SettingsToggleRow(title: "Resume where you left off", subtitle: "Restores the queue and position at launch, paused.", isOn: $settings.data.resumeLastSession, skin: skin)
            }
            SettingsCard(title: "Metadata & artwork", skin: skin) {
                HStack(spacing: 10) {
                    Text("Metadata, covers, lyrics, and online sources are in Library → Metadata.")
                        .font(AppFont.ui(11.5))
                        .foregroundStyle(skin.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open") { WindowRequest.library.post() }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
            }
        }
    }
}


/// Style, icons, size, and tint for i2s's own close / minimize / full-screen
/// buttons, with a live preview. Individual glyphs are set in the icon editor.
/// Window buttons' look, where settings are edited (Customize, Settings):
/// every option inline, and the icons in their own small window.
struct WindowControlSettingsEditor: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin
    @State private var choosingIcons = false

    static func isCustomized(_ d: AppSettingsData) -> Bool {
        let fresh = AppSettingsData()
        return d.windowControlStyle != fresh.windowControlStyle || d.windowControlGlyphs != fresh.windowControlGlyphs
            || d.windowControlAccent || d.windowControlShape != fresh.windowControlShape
            || d.windowControlSide != fresh.windowControlSide || d.windowControlSpacing != fresh.windowControlSpacing
            || d.windowControlIconScale != fresh.windowControlIconScale || d.windowControlBorder != fresh.windowControlBorder
            || d.windowControlColoring != fresh.windowControlColoring || !d.windowControlColors.isEmpty
            || d.windowControlHover != fresh.windowControlHover || d.windowControlRestOpacity != fresh.windowControlRestOpacity
            || d.windowControlCloseLast || WindowControls.Kind.allCases.contains { d.iconOverrides[$0.role] != nil }
    }

    static func reset(_ settings: AppSettings) {
        let fresh = AppSettingsData()
        settings.data.windowControlStyle = fresh.windowControlStyle
        settings.data.windowControlGlyphs = fresh.windowControlGlyphs
        settings.data.windowControlAccent = false
        settings.data.windowControlShape = fresh.windowControlShape
        settings.data.windowControlSide = fresh.windowControlSide
        settings.data.windowControlSpacing = fresh.windowControlSpacing
        settings.data.windowControlIconScale = fresh.windowControlIconScale
        settings.data.windowControlBorder = fresh.windowControlBorder
        settings.data.windowControlColoring = fresh.windowControlColoring
        settings.data.windowControlColors = [:]
        settings.data.windowControlHover = fresh.windowControlHover
        settings.data.windowControlRestOpacity = fresh.windowControlRestOpacity
        settings.data.windowControlCloseLast = false
        for k in WindowControls.Kind.allCases { settings.data.iconOverrides[k.role] = nil }
    }

    var body: some View {
        let d = settings.data
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                WindowControls(skin: skin, preview: true)
                WindowControls(skin: skin, preview: true, closeOnly: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            Button("Change Icons…") { choosingIcons = true }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            row("Style") { SettingsSegmented(options: WindowControlStyle.allCases, selection: $settings.data.windowControlStyle, label: \.label, skin: skin) }
            if d.windowControlStyle != .bare {
                row("Shape") { SettingsSegmented(options: WindowControlShape.allCases, selection: $settings.data.windowControlShape, label: \.label, skin: skin) }
                row("Icons in the buttons") { SettingsSegmented(options: WindowControlGlyphs.allCases, selection: $settings.data.windowControlGlyphs, label: \.label, skin: skin) }
            }
            slider("Size", $settings.data.windowControlSide, 9...24) { "\(Int($0)) pt" }
            slider("Icon size", $settings.data.windowControlIconScale, 0.4...1) { "\(Int(($0 * 100).rounded()))%" }
            slider("Spacing", $settings.data.windowControlSpacing, 2...16) { "\(Int($0)) pt" }
            if d.windowControlStyle == .outline {
                slider("Border", $settings.data.windowControlBorder, 0.5...3) { String(format: "%.1f pt", $0) }
            }
            slider("Strength at rest", $settings.data.windowControlRestOpacity, 0.2...1) { "\(Int(($0 * 100).rounded()))%" }
            row("Color") { SettingsSegmented(options: WindowControlColoring.allCases, selection: $settings.data.windowControlColoring, label: \.label, skin: skin) }
            if d.windowControlColoring == .custom {
                ForEach(WindowControls.Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 8) {
                        Text(kind.title).font(AppFont.ui(11)).foregroundStyle(skin.textSecondary).frame(width: 70, alignment: .leading)
                        ColorWell(value: Binding(get: { settings.data.windowControlColors[kind.rawValue] },
                                                 set: { settings.data.windowControlColors[kind.rawValue] = $0 }),
                                  skin: skin, noneLabel: "theme")
                    }
                }
            }
            row("Under the pointer") { SettingsSegmented(options: WindowControlHover.allCases, selection: $settings.data.windowControlHover, label: \.label, skin: skin) }
            SettingsToggleRow(title: "Close last", subtitle: "Close at the far end instead of first.",
                              isOn: $settings.data.windowControlCloseLast, skin: skin)
            Button("Reset Window Buttons") { Self.reset(settings) }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                .disabled(!Self.isCustomized(d))
            if d.systemWindowFrame {
                Text("Hidden while the system window frame is on.")
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
            }
        }
        .sheet(isPresented: $choosingIcons) {
            WindowButtonsSheet(settings: settings, skin: skin) { choosingIcons = false }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        SettingsSliderRow(title: title, value: value, range: range, skin: skin,
                          sliderStyle: settings.data.sliderStyle, format: format)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppFont.ui(11)).foregroundStyle(skin.textSecondary)
            content()
        }
    }
}

/// The window buttons' icons, in a small window: a tab per button, its
/// suggested icons (every close, minimize or full-screen icon in the
/// symbol set, and plain shapes), then every icon, searchable.
struct WindowButtonsSheet: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin
    var onDone: () -> Void
    /// Off only for offscreen snapshots, whose renderer can't draw scroll views.
    var scrolls = true

    @State private var kind: WindowControls.Kind
    @State private var query = ""
    @State private var glyphs: [(code: UInt32, name: String)] = []
    @ObservedObject private var theme = IconTheme.shared

    init(settings: AppSettings, skin: Skin, start: WindowControls.Kind = .close, scrolls: Bool = true,
         onDone: @escaping () -> Void) {
        self.settings = settings
        self.skin = skin
        self.onDone = onDone
        self.scrolls = scrolls
        _kind = State(initialValue: start)
    }

    /// Every icon in the symbol set made for each button, across the
    /// Material, Codicons, Font Awesome and Octicons sets.
    static func suggested(_ kind: WindowControls.Kind) -> [UInt32] {
        switch kind {
        case .close: return [
            0xF0156, 0xF1398, 0xF06C9, 0xF0159, 0xF015A, 0xF0157, 0xF0158, 0xF015C,
            0xF015D, 0xF05AD, 0xEA76, 0xEAB8, 0xF00D, 0xF057, 0xF05C, 0xF2D3,
            0xF2D4, 0xF467, 0xF52F, 0xF530, 0xE20D, 0xF0425, 0xF073A,
        ]
        case .minimize: return [
            0xF0374, 0xF1639, 0xF0376, 0xF0377, 0xF0375, 0xF06F2, 0xF05B0, 0xEABA,
            0xEACC, 0xEB3B, 0xF068, 0xEF3E, 0xF2D1, 0xF056, 0xF146, 0xF48B,
            0xE224, 0xF0140, 0xF0B27, 0xF09D7, 0xF0792, 0xF0615, 0xF0044, 0xF066,
            0xEAB4,
        ]
        case .zoom: return [
            0xF0616, 0xF004C, 0xF0293, 0xF05AF, 0xF05B2, 0xF0A68, 0xF0415, 0xF11EC,
            0xF0417, 0xF0419, 0xF0416, 0xF0704, 0xEAB9, 0xEABB, 0xEB4C, 0xEA60,
            0xF065, 0xF06F, 0xF2D0, 0xF2D2, 0xF067, 0xF50C, 0xF44D, 0xE25D,
            0xE23C, 0xF0143, 0xF0799, 0xF01A2,
        ]
        }
    }

    /// Plain dots and squares, for buttons that are only a shape.
    static let plain: [UInt32] = [
            0xF0765, 0xF0766, 0xF09DE, 0xF0EC3, 0xF0E95, 0xF0764, 0xF0763, 0xF0A13,
            0xF0A14, 0xF14FB, 0xF14FC, 0xF0E5F, 0xEBB4, 0xEBB5, 0xEA72, 0xF444,
            0xF51D,
    ]

    var body: some View {
        VStack(spacing: Corners.inset) {
            HStack {
                Text("Window Button Icons").font(AppFont.ui(13, weight: .semibold)).foregroundStyle(skin.textPrimary)
                Spacer()
                DialogButton(title: "Done", prominent: true, skin: skin, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            HStack(spacing: Corners.inset) {
                rail
                    .frame(width: 150)
                    .frostedPane(skin, tint: GlassWindow.railTint)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(Rectangle())
                    .frostedPane(skin, tint: GlassWindow.pageTint)
            }
        }
        .padding(Corners.inset)
        .frame(width: 560, height: 440)
        .glassSheet(skin)
        .task {
            if glyphs.isEmpty { glyphs = await Task.detached(priority: .userInitiated) { IconTheme.allGlyphs() }.value }
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: CGFloat(settings.data.windowControlSpacing)) {
                ForEach(WindowControls.Kind.allCases, id: \.self) { k in
                    WindowControlPreviewButton(kind: k, skin: skin, data: settings.data, selected: kind == k) { kind = k }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            ForEach(WindowControls.Kind.allCases, id: \.self) { k in
                SettingsNavRow(icon: k.role, title: k.title, isSelected: kind == k, skin: skin) { kind = k }
            }
            Spacer(minLength: 0)
            if settings.data.iconOverrides[kind.role] != nil {
                TextAction(title: "Use the Default", skin: skin) { settings.data.iconOverrides[kind.role] = nil }
                    .padding(8)
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var page: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            section("For \(kind.title.lowercased())", Self.suggested(kind).map { ($0, "") })
            section("Plain shapes", Self.plain.map { ($0, "") })
            DialogTextField(placeholder: "Search all icons", text: $query, skin: skin)
                .padding(.top, 4)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                grid(filtered)
                if filtered.isEmpty {
                    Text(glyphs.isEmpty ? "Loading icons…" : "No icons match.").font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                }
            }
        }
        .padding(12)
        if scrolls { ScrollView { content } } else { content }
    }

    private func section(_ title: String, _ items: [(code: UInt32, name: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
            grid(items)
        }
    }

    private func grid(_ items: [(code: UInt32, name: String)]) -> some View {
        let role = kind.role
        let current = theme.code(for: role)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.code) { g in
                let on = current == g.code
                Button { settings.data.iconOverrides[role] = g.code == Glyph.codes[role] ? nil : g.code } label: {
                    CodeGlyph(code: g.code, size: 14)
                        .foregroundStyle(skin.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(on ? skin.accent.opacity(0.2) : skin.textPrimary.opacity(0.03))
                        .overlay(Rectangle().strokeBorder(on ? skin.accent : skin.textPrimary.opacity(0.08), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(g.name.isEmpty ? String(format: "U+%05X", g.code) : g.name)
            }
        }
    }

    private var filtered: [(code: UInt32, name: String)] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return Array(glyphs.lazy.filter { g in words.allSatisfy { g.name.lowercased().contains($0) } }.prefix(240))
    }
}

/// Fill, content, size, and accent for every button, with a live preview.
struct ButtonSettingsEditor: View {
    @ObservedObject var settings: AppSettings
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {} label: { Label("Play", glyph: "play.fill") }
                    .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                Button {} label: { Label("Shuffle", glyph: "shuffle") }
                    .buttonStyle(PillButtonStyle(skin: skin))
                Button {} label: { Label("Grouped", glyph: "rectangle.3.group") }
                    .buttonStyle(PillButtonStyle(skin: skin, isActive: true))
                IconButton(icon: "heart", skin: skin) {}
            }
            .fixedSize()
            .padding(.bottom, 4)
            row("Fill") { SettingsSegmented(options: ButtonFill.allCases, selection: $settings.data.buttonFill, label: \.label, skin: skin) }
            row("Shows") { SettingsSegmented(options: ButtonContent.allCases, selection: $settings.data.buttonContent, label: \.label, skin: skin) }
            row("Size") { SettingsSegmented(options: ButtonSize.allCases, selection: $settings.data.buttonSize, label: \.label, skin: skin) }
            SettingsToggleRow(title: "Primary actions in the accent", subtitle: "Play and Save use the accent color.",
                              isOn: $settings.data.buttonAccentPrimary, skin: skin)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppFont.ui(11)).foregroundStyle(skin.textSecondary)
            content()
        }
    }
}
