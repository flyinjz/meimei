import Foundation

// MARK: - C interface

// The core as the Qt app (Windows, later Linux) sees it: plain C functions,
// declared in Core/include/i2s_core.h. Rules, the same for every function:
// - Strings in and out are UTF-8. Every `char *` the core returns is the
//   caller's: free it with `i2s_free`. Never free one with anything else.
// - Structured data travels as JSON text. Dates in JSON are milliseconds
//   since 1970 (UTC); UUIDs are uppercase strings. Tracks passed in use the
//   same shape as the `tracks` array of the app's library.json.
// - Handles (`i2s_history *`) are not thread-safe: use each from one thread.
// - On failure a function returns NULL (or a non-zero code) and, if the
//   caller passed an `error` pointer, sets it to a message to free.
// On macOS this file compiles into the app too; nothing there calls it.

/// Bumped whenever a function's meaning or a JSON shape changes.
let coreInterfaceVersion = 4

private func duplicate(_ s: String) -> UnsafeMutablePointer<CChar>? {
    #if os(Windows)
    return _strdup(s)
    #else
    return strdup(s)
    #endif
}

private func cString(_ s: String) -> UnsafeMutablePointer<CChar>? { duplicate(s) }

private func fail(_ message: String, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) {
    error?.pointee = duplicate(message)
}

private func string(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }

private let apiEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .millisecondsSince1970
    e.outputFormatting = [.sortedKeys]
    return e
}()

private let apiDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .millisecondsSince1970
    return d
}()

private func json(_ object: Any) -> UnsafeMutablePointer<CChar>? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
    return cString(String(decoding: data, as: UTF8.self))
}

private func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }

@_cdecl("i2s_free")
public func i2s_free(_ p: UnsafeMutablePointer<CChar>?) { free(p) }

/// `{"interface": 1, "core": "…"}`
@_cdecl("i2s_core_version")
public func i2s_core_version() -> UnsafeMutablePointer<CChar>? {
    json(["interface": coreInterfaceVersion, "history": "I2SH 1"])
}

/// Runs the core's checks in `scratch_dir` (created if missing), printing
/// each result; returns how many failed. Debug builds only: -1 otherwise.
@_cdecl("i2s_core_check")
public func i2s_core_check(_ scratchDir: UnsafePointer<CChar>?) -> Int32 {
    #if DEBUG
    guard let path = string(scratchDir) else { return -1 }
    let dir = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Int32(CoreChecks.run(dir))
    #else
    return -1
    #endif
}

// MARK: Listening history

final class HistoryHandle {
    let log: ListenLog
    init(_ log: ListenLog) { self.log = log }
}

private func handle(_ p: OpaquePointer?) -> HistoryHandle? {
    p.map { Unmanaged<HistoryHandle>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

/// Opens (or starts) the sealed history in `dir`. Until the platform's own
/// secret store and TPM key are wired in, the keys are files in `dir`.
@_cdecl("i2s_history_open")
public func i2s_history_open(_ dir: UnsafePointer<CChar>?,
                             _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer? {
    guard let path = string(dir) else { fail("no folder given", errorOut); return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let log = try ListenLog(dir: url, secrets: FileHistorySecrets(dir: url))
        return OpaquePointer(Unmanaged.passRetained(HistoryHandle(log)).toOpaque())
    } catch {
        fail("history could not be opened: \(error)", errorOut)
        return nil
    }
}

@_cdecl("i2s_history_close")
public func i2s_history_close(_ h: OpaquePointer?) {
    guard let h else { return }
    let handle = Unmanaged<HistoryHandle>.fromOpaque(UnsafeRawPointer(h))
    handle.takeUnretainedValue().log.close()
    handle.release()
}

/// What reading the history found:
/// `{"accepted","rejected","implausible","gaps","trustedPrefix","clean","account","device","created","hardwareKey"}`
@_cdecl("i2s_history_report_json")
public func i2s_history_report_json(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    guard let log = handle(h)?.log else { return nil }
    let r = log.report
    return json([
        "accepted": r.accepted, "rejected": r.rejected, "implausible": r.implausible, "gaps": r.gaps,
        "trustedPrefix": r.trustedPrefix, "clean": r.isClean,
        "account": log.identity.account.uuidString, "device": log.identity.device.uuidString,
        "created": ms(log.identity.created), "hardwareKey": log.usesEnclave,
    ])
}

/// Every verified listen, oldest first, as a JSON array of Listen objects.
@_cdecl("i2s_history_listens_json")
public func i2s_history_listens_json(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    guard let log = handle(h)?.log, let data = try? apiEncoder.encode(log.listens) else { return nil }
    return cString(String(decoding: data, as: UTF8.self))
}

/// This installation's device id, for the listens it records.
@_cdecl("i2s_history_device")
public func i2s_history_device(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    handle(h).map { cString($0.log.identity.device.uuidString) } ?? nil
}

/// Seals one listen (a Listen JSON object). Returns 0, or 1 with `error`
/// set when the listen can't be real, the clock reads earlier than the
/// latest listen, or the write failed. The rules are `ListenRules`.
@_cdecl("i2s_history_append_json")
public func i2s_history_append_json(_ h: OpaquePointer?, _ listenJSON: UnsafePointer<CChar>?,
                                    _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let log = handle(h)?.log else { fail("no history", errorOut); return 1 }
    guard let text = string(listenJSON) else { fail("no listen given", errorOut); return 1 }
    let listen: Listen
    do {
        listen = try apiDecoder.decode(Listen.self, from: Data(text.utf8))
    } catch {
        fail("not a listen: \(decodingProblem(error))", errorOut); return 1
    }
    do {
        try log.append(listen)
        return 0
    } catch ListenLog.Failure.implausible(let why) {
        fail("not recorded: \(why)", errorOut); return 1
    } catch {
        fail("not recorded: \(error)", errorOut); return 1
    }
}

/// Whether a listen of `heard` seconds of a `duration`-second track counts.
@_cdecl("i2s_listen_counts")
public func i2s_listen_counts(_ heard: Double, _ duration: Double) -> Int32 {
    ListenRules.counts(heard: heard, duration: duration) ? 1 : 0
}

// MARK: Profile

/// The profile for `range` (0 = 7 days, 1 = 30 days, 2 = 90 days, 3 = 12
/// months, 4 = all time), from the history's verified listens and the
/// library's tracks (a JSON array shaped like library.json's `tracks`).
@_cdecl("i2s_profile_stats_json")
public func i2s_profile_stats_json(_ h: OpaquePointer?, _ tracksJSON: UnsafePointer<CChar>?, _ range: Int32,
                                   _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>? {
    guard let log = handle(h)?.log else { fail("no history", error); return nil }
    guard let r = ProfileRange(rawValue: Int(range)) else { fail("unknown range \(range)", error); return nil }
    var tracks: [Track] = []
    if let text = string(tracksJSON), !text.isEmpty {
        // Library files keep the app's own date encoding (seconds since 2001).
        guard let decoded = try? JSONDecoder().decode([Track].self, from: Data(text.utf8)) else {
            fail("tracks are not in the library.json shape", error); return nil
        }
        tracks = decoded
    }
    let stats = ProfileStats(listens: log.listens, library: tracks, albums: AlbumGroup.groups(from: tracks), range: r)
    return json(stats.jsonObject())
}

extension ProfileStats {
    /// The stats as plain JSON values, every field the profile page shows.
    func jsonObject() -> [String: Any] {
        func rank(_ r: Rank) -> [String: Any] {
            var o: [String: Any] = ["id": r.id, "title": r.title, "subtitle": r.subtitle, "count": r.count,
                                    "seconds": r.seconds, "target": r.target]
            if let c = r.cover { o["cover"] = c }
            return o
        }
        func listen(_ l: Listen) -> Any {
            (try? apiEncoder.encode(l)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        }
        var o: [String: Any] = [
            "range": range.rawValue, "rangeTitle": range.title, "start": ms(start), "days": days,
            "listens": listens, "seconds": seconds, "artists": artists, "albums": albums, "tracks": tracks,
            "dailyAverage": dailyAverage,
            "timeline": timeline.map { ["id": $0.id, "label": $0.label, "help": $0.help, "count": $0.count, "isCurrent": $0.isCurrent] },
            "timelineUnit": timelineUnit,
            "topArtists": topArtists.map(rank), "topAlbums": topAlbums.map(rank), "topTracks": topTracks.map(rank),
            "hours": hours, "weekdays": weekdays,
            "genres": genres.map { ["name": $0.name, "count": $0.count] },
            "decades": decades.map { ["name": $0.name, "count": $0.count] },
            "discoveries": discoveries.map(rank),
            "totalListens": totalListens, "totalSeconds": totalSeconds,
            "milestones": milestones.map { ["number": $0.number, "listen": listen($0.listen)] },
            "currentStreak": currentStreak, "longestStreak": longestStreak,
            "heardTracks": heardTracks, "libraryTracks": libraryTracks,
            "recent": recent.map(listen),
        ]
        if let p = previous {
            o["previous"] = ["listens": p.listens, "seconds": p.seconds, "artists": p.artists, "albums": p.albums, "tracks": p.tracks]
        }
        if let b = busiestDay { o["busiestDay"] = ["date": ms(b.date), "count": b.count] }
        if let s = since { o["since"] = ms(s) }
        if let n = nextMilestone { o["nextMilestone"] = n }
        return o
    }
}

/// A decoding error in plain words: which field, and what was wrong with it.
private func decodingProblem(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return "\(error)" }
    func path(_ c: DecodingError.Context) -> String {
        let p = c.codingPath.map(\.stringValue).joined(separator: ".")
        return p.isEmpty ? "the top level" : "\"\(p)\""
    }
    switch e {
    case .keyNotFound(let key, let c):
        let at = c.codingPath.isEmpty ? "" : " in \(path(c))"
        return "missing \"\(key.stringValue)\"\(at)"
    case .typeMismatch(_, let c), .valueNotFound(_, let c):
        return "\(path(c)) has the wrong type (\(c.debugDescription))"
    case .dataCorrupted(let c):
        return "\(path(c)): \(c.debugDescription)"
    @unknown default:
        return "\(error)"
    }
}

// MARK: Themes, settings, fonts, icons (interface 2)

private let dataEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()

private func encoded<T: Encodable>(_ value: T) -> UnsafeMutablePointer<CChar>? {
    guard let data = try? dataEncoder.encode(value) else { return nil }
    return cString(String(decoding: data, as: UTF8.self))
}

/// The built-in themes, in the catalog's order: a JSON array of themes
/// (`{"id","name","category","isAlbumReactive","bgVoid",…}`, colours as
/// 24-bit RGB integers), the same shape the Mac stores user themes in.
@_cdecl("i2s_theme_starters_json")
public func i2s_theme_starters_json() -> UnsafeMutablePointer<CChar>? {
    encoded(CustomTheme.starterThemes)
}

/// The catalog's category order: a JSON array of strings.
@_cdecl("i2s_theme_categories_json")
public func i2s_theme_categories_json() -> UnsafeMutablePointer<CChar>? {
    encoded(CustomTheme.categoryOrder)
}

/// A theme from at least 8 colours (`colors_json`: a JSON array of 24-bit
/// RGB integers), dark (`light` = 0) or light. NULL with `error` set when
/// there are too few colours.
@_cdecl("i2s_theme_generate_json")
public func i2s_theme_generate_json(_ colorsJSON: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?, _ light: Int32,
                                    _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>? {
    guard let text = string(colorsJSON), let colors = try? JSONDecoder().decode([UInt32].self, from: Data(text.utf8)) else {
        fail("colours must be a JSON array of 24-bit RGB integers", errorOut); return nil
    }
    guard let theme = ThemeGenerator.generate(name: string(name) ?? "Generated", colors: colors, mode: light != 0 ? .light : .dark) else {
        fail("a theme needs at least \(ThemeGenerator.minimumColors) colours", errorOut); return nil
    }
    return encoded(theme)
}

/// Settings as the app stores them, read leniently (unknown or bad keys
/// fall back to defaults) and written back whole: the way to read a settings
/// file, or get the defaults (pass NULL).
@_cdecl("i2s_settings_normalize_json")
public func i2s_settings_normalize_json(_ settingsJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let data = string(settingsJSON).map { Data($0.utf8) } ?? Data("{}".utf8)
    return encoded(AppSettingsData.decodeLeniently(from: data))
}

/// The main window's standard pane layout (the customize layout format).
@_cdecl("i2s_customize_standard_layout_json")
public func i2s_customize_standard_layout_json() -> UnsafeMutablePointer<CChar>? {
    encoded(PaneLayout.standard)
}

/// The bundled type families: `[{"id","label","note","monospaced","faces":{"light","regular","bold"}}]`
/// (faces are PostScript names).
@_cdecl("i2s_fonts_json")
public func i2s_fonts_json() -> UnsafeMutablePointer<CChar>? {
    json(AppFontFamily.allCases.map { f -> [String: Any] in
        ["id": f.rawValue, "label": f.label, "note": f.note, "monospaced": f.isMonospaced,
         "faces": ["light": f.faces.light, "regular": f.faces.regular, "bold": f.faces.bold],
         "faceRule": ["regularBelow": AppFontFamily.regularBelow, "regularWeights": ["medium", "semibold"],
                      "boldWeights": ["bold", "heavy", "black"], "otherwise": "light"]]
    })
}

/// Icons: every role with its name and use, and each pack's table of code
/// points (Nerd Font symbols). `{"roles":[{"role","name","usedFor"}],"packs":[{"id","label","codes":{role: code}}]}`
@_cdecl("i2s_icons_json")
public func i2s_icons_json() -> UnsafeMutablePointer<CChar>? {
    let roles = IconPackTables.material.keys.sorted().map { role -> [String: Any] in
        let info = IconRoles.info[role]
        return ["role": role, "name": info?.name ?? role, "usedFor": info?.usedFor ?? ""]
    }
    let packs = IconPack.allCases.map { p -> [String: Any] in ["id": p.rawValue, "label": p.label, "codes": p.table] }
    return json(["roles": roles, "packs": packs])
}

/// Times the history with `count` listens in `scratch_dir` (release-safe):
/// `{"listens","appendMs","readMs","fullCheckMs"}`; appendMs is per listen.
@_cdecl("i2s_core_bench_history")
public func i2s_core_bench_history(_ scratchDir: UnsafePointer<CChar>?, _ count: Int32) -> UnsafeMutablePointer<CChar>? {
    guard let path = string(scratchDir), count > 0 else { return nil }
    let dir = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let created = Date().addingTimeInterval(-Double(count) * 200 - 3_600)
    let secrets = FileHistorySecrets(dir: dir)
    guard let log = try? ListenLog(dir: dir, secrets: secrets, enclave: false, created: created) else { return nil }
    var clock = created.addingTimeInterval(60)
    log.timing = ListenLog.AppendTiming()
    let t0 = Date()
    for _ in 0..<Int(count) {
        let start = clock.addingTimeInterval(1)
        clock = start.addingTimeInterval(190)
        _ = try? log.append(Listen(id: UUID(), trackID: UUID(), trackKey: "a\u{1F}t\u{1F}r", title: "Title", artist: "Artist",
                                   album: "Record", albumArtist: "Artist", trackDuration: 200, startedAt: start, endedAt: clock,
                                   heardSeconds: 180, device: log.identity.device))
    }
    let append = Date().timeIntervalSince(t0) * 1000 / Double(count)
    let phases = log.timing ?? ListenLog.AppendTiming()
    let n = Double(max(1, phases.count))
    log.close()
    let t1 = Date()
    let warm = try? ListenLog(dir: dir, secrets: secrets, enclave: false)
    let read = Date().timeIntervalSince(t1) * 1000
    // A full check: the anchor gone, so every signature is checked again.
    try? FileManager.default.removeItem(at: dir.appendingPathComponent("secret-anchor"))
    let t2 = Date()
    let cold = try? ListenLog(dir: dir, secrets: secrets, enclave: false)
    let full = Date().timeIntervalSince(t2) * 1000
    return json(["listens": warm?.listens.count ?? 0, "fullCheckListens": cold?.listens.count ?? 0,
                 "appendMs": append, "readMs": read, "fullCheckMs": full,
                 "appendPhasesMs": ["encode": phases.encode / n, "seal": phases.seal / n, "sign": phases.sign / n,
                                    "write": phases.write / n, "sync": phases.sync / n, "bookkeeping": phases.bookkeeping / n,
                                    "anchor": phases.anchor / n]])
}

// MARK: Skin, stored themes, customize state, font faces (interface 3)

private func rgbaObject(_ c: RGBA) -> [String: Any] { ["r": c.r, "g": c.g, "b": c.b, "a": c.a] }

/// The skin every view draws with, from the active theme (stored shape),
/// the settings and the design tokens (each NULL for defaults). `live_cover`
/// != 0 for the live cover theme, whose accent colours are the theme's (pass
/// the cover's) and whose surfaces are always glass. Colours are
/// {"r","g","b","a"}, 0…1, sRGB.
@_cdecl("i2s_skin_json")
public func i2s_skin_json(_ themeJSON: UnsafePointer<CChar>?, _ settingsJSON: UnsafePointer<CChar>?,
                          _ tokensJSON: UnsafePointer<CChar>?, _ liveCover: Int32,
                          _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>? {
    let theme: CustomTheme
    if let text = string(themeJSON) {
        do { theme = try JSONDecoder().decode(CustomTheme.self, from: Data(text.utf8)) }
        catch { fail("not a theme: \(decodingProblem(error))", errorOut); return nil }
    } else {
        theme = CustomTheme.starterThemes[0]
    }
    let settings = AppSettingsData.decodeLeniently(from: string(settingsJSON).map { Data($0.utf8) } ?? Data("{}".utf8))
    let tokens = string(tokensJSON).flatMap { try? JSONDecoder().decode(DesignTokens.self, from: Data($0.utf8)) } ?? DesignTokens()
    let r = SkinRules.styled(accent: RGBA(hex: theme.accent), accentDim: RGBA(hex: theme.accentDim), accentGlow: RGBA(hex: theme.accentGlow),
                             textOnAccent: RGBA(hex: theme.textOnAccent), skinID: liveCover != 0 ? SkinRules.liveCoverID : theme.id.uuidString,
                             tokens: tokens, settings: settings)
    let colors: [String: RGBA] = [
        "bgVoid": r.bgVoid, "bgPanel": r.bgPanel, "bgRow": r.bgRow, "bgRowAlt": r.bgRowAlt, "bgRaised": r.bgRaised,
        "hairline": r.hairline, "textPrimary": r.textPrimary, "textSecondary": r.textSecondary, "textTertiary": r.textTertiary,
        "textOnAccent": r.textOnAccent, "accent": r.accent, "accentDim": r.accentDim, "accentGlow": r.accentGlow,
        "lcdOn": r.lcdOn, "lcdOff": r.lcdOff, "lcdBackground": r.lcdBackground, "selection": r.selection, "hover": r.hover,
    ]
    return json([
        "colors": colors.mapValues(rgbaObject),
        "isGlass": r.isGlass, "allowsBackdropBleed": r.allowsBackdropBleed, "panelOpacity": r.panelOpacity,
        "contentOpacity": min(0.95, r.panelOpacity + 0.16), "borderWidth": r.borderWidth, "showTicks": r.showTicks,
        "tickLength": r.tickLength, "backdrop": r.backdrop.rawValue, "gap": tokens.gap, "textScale": tokens.textScale,
    ])
}

/// The stored theme list made usable (starters when empty, missing catalog
/// themes added, catalog grouping restored) and the active theme id (the
/// stored one if present, else the first): `{"themes":[...],"activeID":"…"}`.
@_cdecl("i2s_themes_normalize_json")
public func i2s_themes_normalize_json(_ storedJSON: UnsafePointer<CChar>?, _ activeID: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let stored = string(storedJSON).flatMap { try? JSONDecoder().decode([CustomTheme].self, from: Data($0.utf8)) } ?? []
    let themes = ThemeLibrary.merged(stored)
    let active = ThemeLibrary.activeID(stored: string(activeID), in: themes)
    guard let data = try? dataEncoder.encode(themes),
          let list = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return json(["themes": list, "activeID": active.uuidString])
}

/// Customize mode's stored state (styles, layout, tokens, workspaces,
/// active workspace), read the app's way: unreadable gives the defaults,
/// the layout is normalised. NULL for the defaults.
@_cdecl("i2s_customize_normalize_json")
public func i2s_customize_normalize_json(_ stateJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    encoded(CustomizeState.read(string(stateJSON).map { Data($0.utf8) }))
}

/// The face (PostScript name) to draw `weight` ("light", "regular",
/// "medium", "semibold", "bold", …) at `size` points in a family.
@_cdecl("i2s_font_face")
public func i2s_font_face(_ family: UnsafePointer<CChar>?, _ size: Double, _ weight: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let f = string(family).flatMap(AppFontFamily.init(rawValue:)) ?? .geistMono
    let w = string(weight).flatMap(FaceWeight.init(rawValue:)) ?? .regular
    return cString(f.face(size: size, weight: w))
}

// MARK: Lyrics (interface 3)

/// Lyrics text (an .lrc or plain): `{"synced": bool, "lines": [{"id","time","text"}]}`.
@_cdecl("i2s_lyrics_read_json")
public func i2s_lyrics_read_json(_ raw: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let read = Lyrics.read(string(raw) ?? "")
    return json(["synced": read.synced, "lines": read.lines.map { ["id": $0.id, "time": $0.time, "text": $0.text] }])
}

/// The line being sung at `time` (seconds, offset already added) among
/// synced lines whose start `times` are given in order; -1 before the first.
@_cdecl("i2s_lyrics_line_at")
public func i2s_lyrics_line_at(_ times: UnsafePointer<Double>?, _ count: Int32, _ time: Double) -> Int32 {
    guard let times, count > 0 else { return -1 }
    let lines = (0..<Int(count)).map { LyricLine(id: $0, time: times[$0], text: "") }
    return Int32(Lyrics.currentIndex(in: lines, at: time) ?? -1)
}

// MARK: Equalizer (interface 3)

/// The built-in EQ profiles (stored shape).
@_cdecl("i2s_eq_profiles_json")
public func i2s_eq_profiles_json() -> UnsafeMutablePointer<CChar>? { encoded(EQProfile.builtIns) }

/// The EQ's stored state read the app's way (older ten-band data
/// converted, bad keys defaulted). NULL for the defaults.
@_cdecl("i2s_eq_normalize_json")
public func i2s_eq_normalize_json(_ stateJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    encoded(EqualizerSettingsData.load(from: string(stateJSON).map { Data($0.utf8) } ?? Data("{}".utf8)))
}

/// The EQ's total gain in dB at each frequency in `hz_json` (a JSON array of
/// numbers): the response curve the graph draws. `state_json` is the stored state.
@_cdecl("i2s_eq_response_json")
public func i2s_eq_response_json(_ stateJSON: UnsafePointer<CChar>?, _ hzJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let state = EqualizerSettingsData.load(from: string(stateJSON).map { Data($0.utf8) } ?? Data("{}".utf8))
    guard let text = string(hzJSON), let hz = try? JSONDecoder().decode([Double].self, from: Data(text.utf8)) else { return nil }
    return encoded(hz.map { EqualizerResponse.gain(atHz: $0, data: state) })
}

/// A profile from parametric EQ text (AutoEQ / Equalizer APO style), or NULL with *error.
@_cdecl("i2s_eq_parse_json")
public func i2s_eq_parse_json(_ text: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?,
                              _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>? {
    guard let profile = ParametricEQText.parse(string(text) ?? "", name: string(name) ?? "Imported") else {
        fail("no EQ bands found in that text", errorOut); return nil
    }
    return encoded(profile)
}

/// The EQ state as parametric EQ text, for export.
@_cdecl("i2s_eq_export")
public func i2s_eq_export(_ stateJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    cString(ParametricEQText.export(EqualizerSettingsData.load(from: string(stateJSON).map { Data($0.utf8) } ?? Data("{}".utf8))))
}

// MARK: Library (interface 3)

/// The library as the Qt app reads it: tracks and playlists from
/// library.json (play counts from the history), with cached search text.
final class LibraryHandle {
    var tracks: [Track]
    var playlists: [Playlist]
    var index: [UUID: Int] = [:]
    var haystack: [String] = []
    init(_ file: LibraryFile) {
        tracks = file.tracks
        playlists = file.playlists
        rebuild()
    }
    func rebuild() {
        index = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, $0.offset) })
        haystack = tracks.map(LibraryRules.searchHaystack)
    }
    func contents(_ p: Playlist) -> [Track] {
        p.isSmart ? p.resolveSmart(from: tracks) : p.trackIDs.compactMap { index[$0].map { tracks[$0] } }
    }
}

private func library(_ p: OpaquePointer?) -> LibraryHandle? {
    p.map { Unmanaged<LibraryHandle>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

/// Opens library.json at `path` (a missing file is an empty library).
@_cdecl("i2s_library_open")
public func i2s_library_open(_ path: UnsafePointer<CChar>?,
                             _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer? {
    guard let p = string(path) else { fail("no path given", errorOut); return nil }
    let file: LibraryFile
    if let data = FileManager.default.contents(atPath: p) {
        do { file = try LibraryFile.read(data) }
        catch { fail("library file can't be read: \(decodingProblem(error))", errorOut); return nil }
    } else {
        file = LibraryFile(tracks: [], playlists: [])
    }
    return OpaquePointer(Unmanaged.passRetained(LibraryHandle(file)).toOpaque())
}

@_cdecl("i2s_library_close")
public func i2s_library_close(_ h: OpaquePointer?) {
    guard let h else { return }
    Unmanaged<LibraryHandle>.fromOpaque(UnsafeRawPointer(h)).release()
}

/// Every track in library order (the library.json track shape; dates are
/// seconds since 2001, the app's own encoding). Indices into this array are
/// what `i2s_library_view_json` returns.
@_cdecl("i2s_library_tracks_json")
public func i2s_library_tracks_json(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    library(h).flatMap { encoded($0.tracks) }
}

/// The playlists (stored shape).
@_cdecl("i2s_library_playlists_json")
public func i2s_library_playlists_json(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    library(h).flatMap { encoded($0.playlists) }
}

/// Fills play counts and last-played dates from the history's verified
/// listens (by track id, else by what the track is). Returns 0.
@_cdecl("i2s_library_apply_history")
public func i2s_library_apply_history(_ lib: OpaquePointer?, _ history: OpaquePointer?) -> Int32 {
    guard let l = library(lib), let log = handle(history)?.log else { return 1 }
    let stats = ListenStats(log.listens)
    for i in l.tracks.indices {
        let e = stats.entry(for: l.tracks[i])
        l.tracks[i].playCount = e?.count ?? 0
        l.tracks[i].lastPlayedAt = e?.last
    }
    return 0
}

/// What a source shows: a JSON array of indices into the track list, after
/// the filter text and, if `sort_key` is given, the column sort ("title",
/// "artist", "album", "genre", "format", "track", "year", "time", "plays",
/// "quality"). `source_key`: "all", "liked", "artist:Name", "genre:Name",
/// "playlist:UUID", "recentlyAdded", "recentlyPlayed", "mostPlayed", …
@_cdecl("i2s_library_view_json")
public func i2s_library_view_json(_ h: OpaquePointer?, _ sourceKey: UnsafePointer<CChar>?, _ filterText: UnsafePointer<CChar>?,
                                  _ sortKey: UnsafePointer<CChar>?, _ ascending: Int32,
                                  _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>? {
    guard let l = library(h) else { fail("no library", errorOut); return nil }
    guard let source = LibrarySource(key: string(sourceKey) ?? "all") else { fail("unknown source", errorOut); return nil }
    var list = LibraryRules.base(for: source, tracks: l.tracks,
                                 playlist: { id in l.playlists.first { $0.id == id } }, contents: l.contents)
    let words = LibraryRules.searchWords(string(filterText) ?? "")
    if !words.isEmpty {
        list = list.filter { t in
            let hay = l.index[t.id].map { l.haystack[$0] } ?? LibraryRules.searchHaystack(t)
            return words.allSatisfy { hay.contains($0) }
        }
    }
    if let key = string(sortKey), !key.isEmpty {
        list = TrackSort.sorted(list, key: key, ascending: ascending != 0)
    }
    return encoded(list.compactMap { l.index[$0.id] })
}

/// Albums (`{"key","title","artist","year","artworkFilePath","trackCount","duration"}`), by title.
@_cdecl("i2s_library_albums_json")
public func i2s_library_albums_json(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    guard let l = library(h) else { return nil }
    return json(AlbumGroup.groups(from: l.tracks).map { a -> [String: Any] in
        var o: [String: Any] = ["key": a.key, "title": a.title, "artist": a.artist, "trackCount": a.trackCount, "duration": a.duration]
        if let y = a.year { o["year"] = y }
        if let p = a.artworkFilePath { o["artworkFilePath"] = p }
        return o
    })
}

// MARK: Library changes (interface 4)

/// Adds tracks read from files (library.json track shape). Tracks whose file
/// is already in the library are skipped; the library stays in library
/// order, and tracks without a cover take their album's. Returns how many
/// were added, or -1 + *error.
@_cdecl("i2s_library_add_tracks_json")
public func i2s_library_add_tracks_json(_ h: OpaquePointer?, _ tracksJSON: UnsafePointer<CChar>?,
                                        _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let l = library(h), let text = string(tracksJSON) else { fail("no library or tracks", errorOut); return -1 }
    let incoming: [Track]
    do { incoming = try JSONDecoder().decode([Track].self, from: Data(text.utf8)) }
    catch { fail("tracks can't be read: \(decodingProblem(error))", errorOut); return -1 }
    var known = Set(l.tracks.map(\.filePath))
    var added = 0
    for t in incoming where known.insert(t.filePath).inserted {
        l.tracks.append(t)
        added += 1
    }
    guard added > 0 else { return 0 }
    // Tracks without art inherit the cover of another track on their album.
    var cover: [String: String] = [:]
    for t in l.tracks { if let p = t.artworkFilePath, cover[t.albumKey] == nil { cover[t.albumKey] = p } }
    for i in l.tracks.indices where l.tracks[i].artworkFilePath == nil {
        if let p = cover[l.tracks[i].albumKey] { l.tracks[i].artworkFilePath = p }
    }
    l.tracks.sort(by: Track.libraryOrder)
    l.rebuild()
    return Int32(added)
}

/// The file paths already in the library (JSON array), so a scan reads only new files.
@_cdecl("i2s_library_file_paths_json")
public func i2s_library_file_paths_json(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    library(h).flatMap { encoded($0.tracks.map(\.filePath)) }
}

private func ids(_ p: UnsafePointer<CChar>?) -> Set<UUID> {
    guard let s = string(p), let list = try? JSONDecoder().decode([String].self, from: Data(s.utf8)) else { return [] }
    return Set(list.compactMap(UUID.init(uuidString:)))
}

/// Likes or unlikes tracks (JSON array of ids).
@_cdecl("i2s_library_set_liked")
public func i2s_library_set_liked(_ h: OpaquePointer?, _ idsJSON: UnsafePointer<CChar>?, _ liked: Int32) {
    guard let l = library(h) else { return }
    for id in ids(idsJSON) { if let i = l.index[id] { l.tracks[i].liked = liked != 0 } }
}

/// A listen was sealed into the history: one more play, last played at
/// `at` (seconds since 1970).
@_cdecl("i2s_library_record_play")
public func i2s_library_record_play(_ h: OpaquePointer?, _ id: UnsafePointer<CChar>?, _ at: Double) {
    guard let l = library(h), let s = string(id), let uuid = UUID(uuidString: s), let i = l.index[uuid] else { return }
    let date = Date(timeIntervalSince1970: at)
    l.tracks[i].playCount += 1
    l.tracks[i].lastPlayedAt = max(l.tracks[i].lastPlayedAt ?? date, date)
}

/// Removes tracks from the library and every playlist (files are untouched).
@_cdecl("i2s_library_remove_tracks")
public func i2s_library_remove_tracks(_ h: OpaquePointer?, _ idsJSON: UnsafePointer<CChar>?) {
    guard let l = library(h) else { return }
    let gone = ids(idsJSON)
    guard !gone.isEmpty else { return }
    for i in l.playlists.indices { l.playlists[i].trackIDs.removeAll { gone.contains($0) } }
    l.tracks.removeAll { gone.contains($0.id) }
    l.rebuild()
}

/// The app's starter smart playlists (Hi-Res, Recently Added, Unplayed),
/// added once on first launch when missing.
@_cdecl("i2s_library_seed_starter_playlists")
public func i2s_library_seed_starter_playlists(_ h: OpaquePointer?) {
    guard let l = library(h) else { return }
    let starters: [(String, [SmartRule], SmartOrder)] = [
        ("Hi-Res", [SmartRule(field: .hiRes, op: .isTrue)], .library),
        ("Recently Added", [SmartRule(field: .addedDaysAgo, op: .lte, value: "30")], .recentlyAdded),
        ("Unplayed", [SmartRule(field: .playCount, op: .equals, value: "0")], .library)
    ]
    for (name, rules, order) in starters where !l.playlists.contains(where: { $0.isSmart && $0.name == name }) {
        l.playlists.append(Playlist(name: name, isSmart: true, rules: rules, isBuiltIn: true, smartOrder: order))
    }
}

/// Playlist changes, as the Mac's LibraryStore makes them. `op_json`:
/// {"op":"create","name","trackIDs"} (returns the new id),
/// {"op":"rename","id","name"}, {"op":"delete","id"},
/// {"op":"add","id","trackIDs"} (manual only, no duplicates),
/// {"op":"remove","id","trackIDs"}, {"op":"move","id","trackIDs","index"}.
/// Returns the playlist id, or NULL + *error.
@_cdecl("i2s_library_playlist_edit_json")
public func i2s_library_playlist_edit_json(_ h: OpaquePointer?, _ opJSON: UnsafePointer<CChar>?,
                                           _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>? {
    guard let l = library(h), let s = string(opJSON),
          let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
          let op = o["op"] as? String else { fail("no library or operation", errorOut); return nil }
    let trackIDs = ((o["trackIDs"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))
    if op == "create" {
        let name = ((o["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Playlist(name: name.isEmpty ? "New Playlist" : name, trackIDs: trackIDs)
        l.playlists.append(p)
        return cString(p.id.uuidString)
    }
    guard let idText = o["id"] as? String, let id = UUID(uuidString: idText),
          let i = l.playlists.firstIndex(where: { $0.id == id }) else { fail("no such playlist", errorOut); return nil }
    switch op {
    case "rename":
        let name = ((o["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { l.playlists[i].name = name }
    case "delete":
        l.playlists.remove(at: i)
    case "add":
        guard !l.playlists[i].isSmart else { break }
        var existing = Set(l.playlists[i].trackIDs)
        for t in trackIDs where existing.insert(t).inserted { l.playlists[i].trackIDs.append(t) }
    case "remove":
        let gone = Set(trackIDs)
        l.playlists[i].trackIDs.removeAll { gone.contains($0) }
    case "move":
        let index = (o["index"] as? Int) ?? 0
        let moving = Set(trackIDs)
        let list = l.playlists[i].trackIDs
        let before = list.prefix(index).filter { !moving.contains($0) }
        let after = list.dropFirst(index).filter { !moving.contains($0) }
        l.playlists[i].trackIDs = Array(before) + list.filter { moving.contains($0) } + Array(after)
    default:
        fail("unknown operation \(op)", errorOut); return nil
    }
    return cString(id.uuidString)
}

/// Writes library.json (atomically). 0 = ok, else 1 + *error.
@_cdecl("i2s_library_save")
public func i2s_library_save(_ h: OpaquePointer?, _ path: UnsafePointer<CChar>?,
                             _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let l = library(h), let p = string(path) else { fail("no library or path", errorOut); return 1 }
    do {
        try LibraryFile(tracks: l.tracks, playlists: l.playlists).encoded().write(to: URL(fileURLWithPath: p), options: .atomic)
        return 0
    } catch {
        fail("library file can't be written: \(error.localizedDescription)", errorOut); return 1
    }
}

/// The table's rows for a source: like `i2s_library_view_json`, then grouped
/// (`group_by`: "none", "album", "albumArtist", "genre", "year"). A JSON
/// array of `{"t": index, "s": stripe}` for tracks and
/// `{"h": title, "d": detail}` for group headers.
@_cdecl("i2s_library_rows_json")
public func i2s_library_rows_json(_ h: OpaquePointer?, _ sourceKey: UnsafePointer<CChar>?, _ filterText: UnsafePointer<CChar>?,
                                  _ sortKey: UnsafePointer<CChar>?, _ ascending: Int32, _ groupBy: UnsafePointer<CChar>?,
                                  _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<CChar>? {
    guard let l = library(h) else { fail("no library", errorOut); return nil }
    guard let source = LibrarySource(key: string(sourceKey) ?? "all") else { fail("unknown source", errorOut); return nil }
    var list = LibraryRules.base(for: source, tracks: l.tracks,
                                 playlist: { id in l.playlists.first { $0.id == id } }, contents: l.contents)
    let words = LibraryRules.searchWords(string(filterText) ?? "")
    if !words.isEmpty {
        list = list.filter { t in
            let hay = l.index[t.id].map { l.haystack[$0] } ?? LibraryRules.searchHaystack(t)
            return words.allSatisfy { hay.contains($0) }
        }
    }
    if let key = string(sortKey), !key.isEmpty { list = TrackSort.sorted(list, key: key, ascending: ascending != 0) }
    let mode = TableGroupMode(rawValue: string(groupBy) ?? "none") ?? .none
    return json(LibraryRow.build(from: list, groupBy: mode).map { row -> [String: Any] in
        switch row {
        case .header(let title, let detail): return ["h": title, "d": detail]
        case .track(let t, let stripe): return ["t": l.index[t.id] ?? -1, "s": stripe ? 1 : 0]
        }
    })
}

/// Records a listen of a library track: `heard` seconds of audible time
/// between `started_at` and `ended_at` (seconds since 1970). Builds the
/// listen the app's way (track key, display artist, this device) and seals
/// it. Returns 0 when recorded, 2 when it wasn't long enough to count, or 1
/// with *error.
@_cdecl("i2s_history_record_track")
public func i2s_history_record_track(_ h: OpaquePointer?, _ lib: OpaquePointer?, _ trackID: UnsafePointer<CChar>?,
                                     _ startedAt: Double, _ endedAt: Double, _ heard: Double,
                                     _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let log = handle(h)?.log, let l = library(lib) else { fail("no history or library", errorOut); return 1 }
    guard let s = string(trackID), let id = UUID(uuidString: s), let i = l.index[id] else { fail("no such track", errorOut); return 1 }
    let t = l.tracks[i]
    guard ListenRules.counts(heard: heard, duration: t.duration) else { return 2 }
    let listen = Listen(id: UUID(), trackID: t.id, trackKey: Listen.key(for: t), title: t.title,
                        artist: t.displayArtist, album: t.album, albumArtist: t.albumArtist,
                        trackDuration: t.duration, startedAt: Date(timeIntervalSince1970: startedAt),
                        endedAt: Date(timeIntervalSince1970: endedAt), heardSeconds: heard, device: log.identity.device)
    do {
        try log.append(listen)
        l.tracks[i].playCount += 1
        l.tracks[i].lastPlayedAt = max(l.tracks[i].lastPlayedAt ?? listen.endedAt, listen.endedAt)
        return 0
    } catch ListenLog.Failure.implausible(let why) {
        fail("not recorded: \(why)", errorOut); return 1
    } catch {
        fail("not recorded: \(error)", errorOut); return 1
    }
}
