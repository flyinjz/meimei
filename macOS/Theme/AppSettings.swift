import SwiftUI
import AppKit

/// Owns the persisted preferences. Every view reads through this one object.
@MainActor
final class AppSettings: ObservableObject {
    @Published var data: AppSettingsData {
        didSet {
            guard data != oldValue else { return }
            DefaultsStore.save(data, key: Self.defaultsKey)
            AppFont.family = data.fontFamily
        }
    }

    private static let defaultsKey = "com.meimei.player.appSettings.v1"

    init() {
        var loaded = DefaultsStore.loadLenient(AppSettingsData.self, key: Self.defaultsKey)
        // Oct 2026: the window became translucent glass. Move everyone off the
        // old tinted defaults once; later choices are kept.
        if !UserDefaults.standard.bool(forKey: Self.glassMigrationKey) {
            UserDefaults.standard.set(true, forKey: Self.glassMigrationKey)
            if loaded.backdropStyle == .ambient { loaded.backdropStyle = .translucent }
        }
        // v2: the translucent backdrop let the wallpaper tint every window;
        // move back to the neutral one once.
        if !UserDefaults.standard.bool(forKey: Self.neutralBackdropMigrationKey) {
            UserDefaults.standard.set(true, forKey: Self.neutralBackdropMigrationKey)
            if loaded.backdropStyle == .translucent { loaded.backdropStyle = .ambient }
        }
        // v3: the window became tinted Liquid Glass (theme-colored, showing
        // what's behind it); the earlier neutral fallback was a stopgap.
        if !UserDefaults.standard.bool(forKey: Self.windowGlassMigrationKey) {
            UserDefaults.standard.set(true, forKey: Self.windowGlassMigrationKey)
            if loaded.backdropStyle == .ambient { loaded.backdropStyle = .translucent }
        }
        data = loaded
        AppFont.family = data.fontFamily
    }

    private static let windowGlassMigrationKey = "com.meimei.player.windowGlassMigration.v3"

    private static let glassMigrationKey = "com.meimei.player.liquidGlassMigration.v1"
    private static let neutralBackdropMigrationKey = "com.meimei.player.neutralBackdropMigration.v2"

    func resetToDefaults() {
        data = AppSettingsData()
    }

    /// Enabled optional columns, in the table's canonical order.
    var orderedVisibleColumns: [TrackColumnKind] {
        TrackColumnKind.allCases.filter { data.visibleColumns.contains($0) }
    }

    /// Keeps at least one optional column so the table never collapses to the title alone.
    func toggleColumn(_ column: TrackColumnKind) {
        if let i = data.visibleColumns.firstIndex(of: column) {
            guard data.visibleColumns.count > 1 else { return }
            data.visibleColumns.remove(at: i)
        } else {
            data.visibleColumns.append(column)
        }
    }

    /// The active skin with appearance preferences applied: divider
    /// strength, corner roundness, and glass surfaces. Under glass, flat
    /// fills become transparent so the panes' glass (tinted with the
    /// theme's panel color) carries the theme instead.
    func styled(_ skin: Skin) -> Skin {
        // The rules are the shared core's (`SkinRules`); this only turns them into colours.
        let r = SkinRules.styled(accent: skin.accent.rgba, accentDim: skin.accentDim.rgba, accentGlow: skin.accentGlow.rgba,
                                 textOnAccent: skin.textOnAccent.rgba, skinID: skin.id,
                                 tokens: AppSession.shared.customize.tokens, settings: data)
        var s = skin
        if r.accentOverridden {
            s.accent = Color(r.accent)
            s.accentDim = Color(r.accentDim)
            s.accentGlow = Color(r.accentGlow)
            s.textOnAccent = Color(r.textOnAccent)
        }
        s.bgVoid = Color(r.bgVoid)
        s.bgPanel = Color(r.bgPanel)
        s.bgRow = Color(r.bgRow)
        s.bgRowAlt = Color(r.bgRowAlt)
        s.bgRaised = Color(r.bgRaised)
        s.hairline = Color(r.hairline)
        s.textPrimary = Color(r.textPrimary)
        s.textSecondary = Color(r.textSecondary)
        s.textTertiary = Color(r.textTertiary)
        s.lcdOn = Color(r.lcdOn)
        s.lcdOff = Color(r.lcdOff)
        s.lcdBackground = Color(r.lcdBackground)
        s.selection = Color(r.selection)
        s.hover = Color(r.hover)
        s.glassTint = nil
        s.panelOpacity = r.panelOpacity
        s.borderWidth = CGFloat(r.borderWidth)
        s.showTicks = r.showTicks
        s.tickLength = CGFloat(r.tickLength)
        s.isGlass = r.isGlass
        s.allowsBackdropBleed = r.allowsBackdropBleed
        return s
    }

    /// The backdrop actually shown: From Cover is about the cover, so it
    /// always sits on the blurred art.
    func effectiveBackdrop(for skin: Skin) -> BackdropStyle {
        SkinRules.effectiveBackdrop(skinID: skin.id, settings: data)
    }
}

extension ClosedRange where Bound: Comparable {
    func clamp(_ value: Bound) -> Bound { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}

/// System appearance preferences that change how Meimei's glass looks.
enum SystemAppearance {
    /// "Allow wallpaper tinting in windows" (System Settings → Appearance).
    /// The window server tints every see-through surface toward the
    /// wallpaper; apps can't opt out individually.
    static var wallpaperTintingOn: Bool {
        !(UserDefaults(suiteName: UserDefaults.globalDomain)?.bool(forKey: "AppleReduceDesktopTinting") ?? false)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
