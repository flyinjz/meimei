#if DEBUG
import Foundation

/// The core's own checks: the same ones on every platform. The Mac's
/// self-test runs them along with its app checks; on Windows and Linux the
/// I2SCoreCheck runner (and `i2s_core_check`) runs them alone.
enum CoreChecks {
    nonisolated(unsafe) private(set) static var failures = 0

    static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ✗ \(label) \(detail())")
        }
    }

    /// Runs every core check in `dir` (a scratch folder) and returns how many failed.
    static func run(_ dir: URL) -> Int {
        let before = failures
        print("core")
        models()
        metadataTools()
        themeGenerator()
        sharedData()
        rules(dir)
        history(dir)
        profile(dir)
        interface(dir)
        return failures - before
    }


    // MARK: Listening history

    /// The sealed history: what it accepts, and that edits, forgeries,
    /// copies and impossible listens don't survive a reload.
    static func history(_ dir: URL) {
        let root = dir.appendingPathComponent("history", isDirectory: true)
        let secrets = FileHistorySecrets(dir: { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root }())
        let created = Date().addingTimeInterval(-86_400)
        func open() -> ListenLog? { try? ListenLog(dir: root, secrets: secrets, enclave: true, created: created) }
        guard let log = open() else { check(false, "history: opens"); return }
        let device = log.identity.device
        var clock = created.addingTimeInterval(600)
        func listen(heard: Double = 200, duration: Double = 240, gap: Double = 5) -> Listen {
            let start = clock.addingTimeInterval(gap)
            clock = start.addingTimeInterval(heard + 10)
            return Listen(id: UUID(), trackID: UUID(), trackKey: "artist\u{1F}title\u{1F}album", title: "Title", artist: "Artist",
                          album: "Album", albumArtist: "Artist", trackDuration: duration, startedAt: start, endedAt: clock,
                          heardSeconds: heard, device: device)
        }
        var appended = 0
        for _ in 0..<5 { if (try? log.append(listen())) != nil { appended += 1 } }
        check(appended == 5, "history: genuine listens are sealed", "\(appended)")
        print("  history key: \(log.usesEnclave ? "hardware (Secure Enclave)" : "software")")

        func refused(_ l: Listen, _ label: String) {
            do { try log.append(l); check(false, "history: refuses \(label)") }
            catch { check(true, "history: refuses \(label)") }
        }
        refused(listen(heard: 60, duration: 240), "a listen heard for too little of the track")
        refused(listen(heard: 25, duration: 25), "tracks under 30 seconds")
        var long = listen(); long.heardSeconds = 5_000
        refused(long, "more heard time than wall time")
        var early = listen(); early.startedAt = created.addingTimeInterval(-3_600)
        refused(early, "listens from before the account")
        var future = listen(); future.endedAt = Date().addingTimeInterval(86_400); future.startedAt = future.endedAt.addingTimeInterval(-300)
        refused(future, "listens in the future")
        var overlap = listen(); overlap.startedAt = (log.listens.last?.endedAt ?? created).addingTimeInterval(-60); overlap.endedAt = overlap.startedAt.addingTimeInterval(220)
        refused(overlap, "listens overlapping the previous one")
        if let last = log.listens.last {
            do { try log.append(listen(), now: last.endedAt.addingTimeInterval(-3_600)); check(false, "history: refuses writing while the clock reads earlier than the latest listen") }
            catch { check(error as? ListenLog.Failure == .clockMovedBack, "history: refuses writing while the clock reads earlier than the latest listen") }
        }

        log.close()  // as the app does when it quits: the check-point catches up
        guard let reread = open() else { check(false, "history: reopens"); return }
        check(reread.listens.count == 5 && reread.report.isClean && reread.report.trustedPrefix == 5,
              "history: reads back sealed, signatures checked once", "\(reread.report)")
        check(ListenStats(reread.listens).byKey["artist\u{1F}title\u{1F}album"]?.count == 5, "history: counts come from the listens")

        // Nothing may hold the file while the checks tamper with it.
        log.close()
        reread.close()
        let file = root.appendingPathComponent("listens.i2s")
        let original = (try? Data(contentsOf: file)) ?? Data()
        func with(_ data: Data, _ body: (ListenLog.Report) -> Void) {
            try? data.write(to: file)
            if let l = open() { body(l.report) } else { check(false, "history: opens after tampering") }
            try? original.write(to: file)
        }
        // Record boundaries: header 21 bytes, then u32 length + body.
        var bounds: [Range<Int>] = []
        var at = 21
        while at + 4 <= original.count {
            let n = Int(original[at]) | Int(original[at + 1]) << 8 | Int(original[at + 2]) << 16 | Int(original[at + 3]) << 24
            bounds.append(at..<at + 4 + n)
            at += 4 + n
        }
        check(bounds.count == 5, "history: five records on disk", "\(bounds.count)")
        guard bounds.count == 5 else { return }

        var flipped = original
        flipped[bounds[2].lowerBound + 4 + 8 + 32 + 4 + 20] ^= 0x01
        with(flipped) { r in check(r.accepted == 4 && r.rejected == 1, "history: an edited byte voids that record only", "\(r)") }

        var copied = original
        copied.append(original.subdata(in: bounds[0]))
        with(copied) { r in check(r.accepted == 5 && r.rejected == 1, "history: a copied record doesn't count twice", "\(r)") }

        var removed = original
        removed.removeSubrange(bounds[1])
        with(removed) { r in check(r.accepted == 4 && r.gaps >= 1, "history: a removed record shows as a gap", "\(r)") }

        var cut = original
        cut.removeSubrange(bounds[4])
        with(cut) { r in check(r.accepted == 4 && r.gaps >= 1, "history: records cut off the end are noticed", "\(r)") }

        // A record sealed and signed with keys of its own, as a forger would have to.
        let forgeRoot = dir.appendingPathComponent("history-forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: forgeRoot, withIntermediateDirectories: true)
        if let forger = try? ListenLog(dir: forgeRoot, secrets: FileHistorySecrets(dir: forgeRoot), enclave: false, created: created) {
            for _ in 0..<6 { _ = try? forger.append(listen()) }
            let forged = (try? Data(contentsOf: forgeRoot.appendingPathComponent("listens.i2s"))) ?? Data()
            var spliced = original
            spliced.append(forged.dropFirst(21))
            with(spliced) { r in check(r.accepted == 5 && r.rejected == 6, "history: records signed with another key are refused", "\(r)") }
        }

        // An anchor edited to claim records it never saw just costs a full check.
        if let anchorData = secrets.read("anchor"), var anchor = try? JSONDecoder().decode(ListenLog.Anchor.self, from: anchorData) {
            anchor.count = 3
            secrets.write((try? JSONEncoder().encode(anchor)) ?? Data(), "anchor")
            if let l = open() {
                check(l.report.trustedPrefix == 0 && l.listens.count == 5, "history: an edited anchor is ignored", "\(l.report)")
            }
        }

        // Thousands of listens: a launch only re-checks what's new.
        let perfRoot = dir.appendingPathComponent("history-perf", isDirectory: true)
        try? FileManager.default.createDirectory(at: perfRoot, withIntermediateDirectories: true)
        if let big = try? ListenLog(dir: perfRoot, secrets: FileHistorySecrets(dir: perfRoot), enclave: false, created: created.addingTimeInterval(-86_400 * 400)) {
            clock = big.identity.created.addingTimeInterval(60)
            let t0 = Date()
            for _ in 0..<20_000 { _ = try? big.append(listen(heard: 180, duration: 200, gap: 1)) }
            let write = Date().timeIntervalSince(t0)
            let t1 = Date()
            let warm = try? ListenLog(dir: perfRoot, secrets: FileHistorySecrets(dir: perfRoot), enclave: false)
            let warmTime = Date().timeIntervalSince(t1)
            print("  perf: 20k listens, append \(String(format: "%.2f", write * 1000 / 20_000)) ms each, launch read \(Int(warmTime * 1000)) ms")
            check(warm?.listens.count == 20_000 && warmTime < 2, "history: 20k listens read back quickly", "\(warm?.report as Any)")
        }
    }

    // MARK: Theme generator

    static func themeGenerator() {
        print("theme generator")
        let seven: [UInt32] = [0x101418, 0x1C2128, 0x2A3038, 0x8899AA, 0xC8D0D8, 0xF4F6F8, 0xE0457B]
        check(ThemeGenerator.generate(name: "x", colors: seven) == nil, "fewer than 8 colors is refused")
        let eight = seven + [0x45C4E0]
        guard let dark = ThemeGenerator.generate(name: "x", colors: eight) else { check(false, "8 colors make a theme"); return }
        check(ThemeGenerator.contrast(dark.textPrimary, dark.bgVoid) >= 11, "text reads on the background",
              "\(ThemeGenerator.contrast(dark.textPrimary, dark.bgVoid))")
        check(ThemeGenerator.contrast(dark.accent, dark.bgVoid) >= 3, "accent reads on the background")
        check(ThemeGenerator.luminance(dark.bgVoid) < ThemeGenerator.luminance(dark.textPrimary), "dark mode puts text above background")
        check(dark.accent == 0xE0457B, "the most vivid readable color is the accent", dark.accent.hexString)
        let light = ThemeGenerator.generate(name: "x", colors: eight, mode: .light)
        check(light.map { ThemeGenerator.luminance($0.bgVoid) > ThemeGenerator.luminance($0.textPrimary) } == true, "light mode swaps the ends")
        // All mid-grays: the generator still has to push text and accent apart.
        let grays: [UInt32] = (0..<8).map { 0x707070 + UInt32($0) * 0x030303 }
        if let g = ThemeGenerator.generate(name: "g", colors: grays) {
            check(ThemeGenerator.contrast(g.textPrimary, g.bgVoid) >= 11, "gray input still gets legible text",
                  "\(ThemeGenerator.contrast(g.textPrimary, g.bgVoid))")
        } else { check(false, "gray input makes a theme") }
        check(ThemeGenerator.parseHexList("#ff0000, 00ff00 0x0000FF #abc") == [0xFF0000, 0x00FF00, 0x0000FF], "hex lists parse")
    }

    // MARK: Themes, settings, customize data

    static func sharedData() {
        print("themes and settings")
        let starters = CustomTheme.starterThemes
        check(starters.count == 15 && Set(starters.map(\.id)).count == 15, "fifteen starter themes with their own ids")
        check(starters.last?.id == CustomTheme.albumReactiveID && starters.last?.isAlbumReactive == true,
              "the live cover theme is the reactive one")
        check(Set(Palette.all.map(\.key)).count == Palette.all.count, "palette keys are unique")
        let themeJSON = (try? JSONEncoder().encode(starters)).flatMap { try? JSONDecoder().decode([CustomTheme].self, from: $0) }
        check(themeJSON == starters, "themes round-trip through JSON")

        let stored = #"{"density":"spacious","spectrumStyle":"neon","crossfadeSeconds":2.5,"layoutPreset":"old"}"#
        let decoded = AppSettingsData.decodeLeniently(from: Data(stored.utf8))
        check(decoded.density == .spacious && decoded.crossfadeSeconds == 2.5 && decoded.spectrumStyle == .gradient,
              "lenient settings decode keeps good keys, drops bad ones")
        check(AppSettingsData.decodeLeniently(from: Data("{}".utf8)) == AppSettingsData(), "empty settings are the defaults")

        var style = ElementStyle()
        style.sizeScale = 1.2
        style.borderSides = [.top, .leading]
        let styles: [CustomElement: ElementStyle] = [CustomElement.allCases[0]: style]
        let back = (try? JSONEncoder().encode(styles)).flatMap { try? JSONDecoder().decode([CustomElement: ElementStyle].self, from: $0) }
        check(back == styles, "element styles round-trip through JSON")
        let layout = (try? JSONEncoder().encode(PaneLayout.standard)).flatMap { try? JSONDecoder().decode(PaneLayout.self, from: $0) }
        check(layout == PaneLayout.standard, "the standard layout round-trips through JSON")
        check(GrayTone.warm.rgb(0.5).red > GrayTone.warm.rgb(0.5).blue && GrayTone.neutral.rgb(0.3) == (0.3, 0.3, 0.3),
              "gray tones lean the right way")
    }

    // MARK: Lyrics, skin, library rules

    static func rules(_ dir: URL) {
        print("lyrics, skin and library rules")
        let lrc = "[00:01.50]one\n[00:03.00][00:07.25]two\n[00:05]three\nnot timed"
        let lines = Lyrics.parse(lrc)
        check(lines.map(\.text) == ["one", "two", "three", "two"], "LRC parse handles repeated stamps", "\(lines.map(\.text))")
        check(abs(lines[0].time - 1.5) < 0.001 && abs(lines[3].time - 7.25) < 0.001, "LRC fractions")
        check(Lyrics.currentIndex(in: lines, at: 0.5) == nil && Lyrics.currentIndex(in: lines, at: 4) == 1
              && Lyrics.currentIndex(in: lines, at: 100) == 3, "lyric line lookup")
        let plain = Lyrics.read("first\n  second  \n\n")
        check(!plain.synced && plain.lines.map(\.text) == ["first", "second"], "plain lyrics trimmed, trailing blanks dropped")

        let theme = CustomTheme.starterThemes[0]
        func styled(_ tokens: DesignTokens = DesignTokens(), glass: Bool = false, live: Bool = false) -> StyledSkin {
            var settings = AppSettingsData()
            settings.surfaceStyle = glass ? .glass : .solid
            return SkinRules.styled(accent: RGBA(hex: theme.accent), accentDim: RGBA(hex: theme.accentDim),
                                    accentGlow: RGBA(hex: theme.accentGlow), textOnAccent: RGBA(hex: theme.textOnAccent),
                                    skinID: live ? SkinRules.liveCoverID : theme.id.uuidString, tokens: tokens, settings: settings)
        }
        let solid = styled()
        check(solid.bgPanel.a == 1 && !solid.isGlass && solid.accent == RGBA(hex: theme.accent) && solid.selection.a == 0.18,
              "solid skin: tonal panels, theme accent")
        check(styled(glass: true).bgPanel == .clear && styled(live: true).isGlass && styled(live: true).backdrop == .artwork,
              "glass and the live cover make panels clear")
        var light = DesignTokens(); light.accent = 0xF0F0A0
        var dark = DesignTokens(); dark.accent = 0x202060
        check(styled(light).textOnAccent == RGBA.black.opacity(0.85) && styled(dark).textOnAccent == .white
              && styled(light).accentDim.a == 0.45, "an accent override picks readable text")
        var warm = DesignTokens(); warm.tone = .warm
        check(styled(warm).bgVoid.r > styled(warm).bgVoid.b, "the warm tone leans warm")

        let custom = CustomTheme(id: UUID(), name: "Mine", palette: .voidBlack)
        check(ThemeLibrary.merged([]) == CustomTheme.starterThemes && ThemeLibrary.merged([custom]).count == 16,
              "theme list: starters when empty, missing starters added")
        var regrouped = CustomTheme.starterThemes[3]; regrouped.category = "Custom"
        check(ThemeLibrary.merged([regrouped]).first?.category == CustomTheme.starterThemes[3].category, "catalog grouping restored")
        check(ThemeLibrary.activeID(stored: "nonsense", in: [custom]) == custom.id, "a missing active theme falls back to the first")
        check(CustomizeState.read(nil) == CustomizeState.read(Data("not json".utf8)), "unreadable customize state is the defaults")
        check(AppFontFamily.geistMono.face(size: 12, weight: .regular) == "GeistMonoNF-Light"
              && AppFontFamily.geistMono.face(size: 10, weight: .regular) == "GeistMonoNF"
              && AppFontFamily.geistMono.face(size: 14, weight: .semibold) == "GeistMonoNF"
              && AppFontFamily.geistMono.face(size: 14, weight: .heavy) == "GeistMonoNF-Bold", "font face rule")

        let keys: [LibrarySource] = [.all, .albums, .artists, .liked, .recentlyAdded, .recentlyPlayed, .mostPlayed, .profile,
                                     .artist("A: B"), .genre("Jazz"), .playlist(UUID())]
        check(keys.allSatisfy { LibrarySource(key: $0.key) == $0 } && LibrarySource(key: "nope") == nil, "library source keys round-trip")
        func t(_ title: String, _ artist: String, _ n: Int, plays: Int = 0) -> Track {
            var x = Track(filePath: "/x/\(UUID()).flac", title: title, artist: artist, album: "Record", duration: 200,
                          sampleRate: 44_100, bitDepth: 16, channelCount: 2, estimatedBitrateKbps: 900, fileFormat: "FLAC")
            x.trackNumber = n
            x.playCount = plays
            return x
        }
        let tracks = [t("Banana", "Zed", 2, plays: 3), t("apple", "Émile", 1, plays: 9), t("Cherry", "emile", 3)]
        check(TrackSort.sorted(tracks, key: "title", ascending: true).map(\.title) == ["apple", "Banana", "Cherry"]
              && TrackSort.sorted(tracks, key: "plays", ascending: false).map(\.title) == ["apple", "Banana", "Cherry"]
              && TrackSort.sorted(tracks, key: "title", ascending: true, ranks: TrackSort.ranks("title", ascending: true, over: tracks))
                 .map(\.title) == ["apple", "Banana", "Cherry"], "column sorts, with and without ranks")
        check(LibraryRules.filter(tracks, by: "EMILE").count == 2, "filter ignores case and accents")
        let file = LibraryFile(tracks: tracks, playlists: [])
        let back = (try? file.encoded()).flatMap { try? LibraryFile.read($0) }
        check(back?.tracks.allSatisfy { $0.playCount == 0 } == true && back?.tracks.count == 3, "library file read ignores stored play counts")
        try? file.encoded().write(to: dir.appendingPathComponent("rules-library.json"))
    }

    // MARK: C interface

    /// The functions the Qt app calls, round trip: version, open, report,
    /// append (good and impossible listens), listens, profile JSON.
    static func interface(_ dir: URL) {
        print("c interface")
        func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
            defer { i2s_free(p) }
            return p.map { String(cString: $0) }
        }
        func object(_ s: String?) -> [String: Any]? {
            s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        check((object(take(i2s_core_version()))?["interface"] as? Int) == coreInterfaceVersion, "interface: version")
        let root = dir.appendingPathComponent("interface", isDirectory: true)
        var error: UnsafeMutablePointer<CChar>?
        guard let h = root.path.withCString({ i2s_history_open($0, &error) }) else {
            return check(false, "interface: history opens", take(error) ?? "")
        }
        defer { i2s_history_close(h) }
        check((object(take(i2s_history_report_json(h)))?["clean"] as? Bool) == true, "interface: report")
        guard let device = take(i2s_history_device(h)) else { return check(false, "interface: device id") }
        let now = Date().timeIntervalSince1970 * 1000
        func listenJSON(heard: Double, start: Double, end: Double) -> String {
            #"{"id":"\#(UUID().uuidString)","trackID":"\#(UUID().uuidString)","trackKey":"a\u001Ft\u001Fr","title":"Title","#
            + #""artist":"Artist","album":"Record","albumArtist":"Artist","trackDuration":40,"startedAt":\#(start),"#
            + #""endedAt":\#(end),"heardSeconds":\#(heard),"device":"\#(device)"}"#
        }
        let good = listenJSON(heard: 20, start: now - 5_000, end: now + 10_000)
        check(good.withCString { i2s_history_append_json(h, $0, &error) } == 0, "interface: a real listen is sealed", take(error) ?? "")
        let short = listenJSON(heard: 5, start: now + 11_000, end: now + 14_000)
        let refused = short.withCString { i2s_history_append_json(h, $0, &error) }
        let why = take(error) ?? ""
        check(refused == 1 && why.contains("not heard long enough"), "interface: an impossible listen is refused with the reason", why)
        let listens = take(i2s_history_listens_json(h)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any] }
        check(listens?.count == 1, "interface: listens come back")
        let stats = object(take(i2s_profile_stats_json(h, nil, 4, &error)))
        check((stats?["listens"] as? Int) == 1 && (stats?["totalListens"] as? Int) == 1, "interface: profile stats")
        check(i2s_listen_counts(120, 240) == 1 && i2s_listen_counts(119, 240) == 0 && i2s_listen_counts(25, 25) == 0,
              "interface: listen rule")
        let bad = "{}".withCString { i2s_history_append_json(h, $0, &error) }
        let badWhy = take(error) ?? ""
        check(bad == 1 && badWhy.contains("missing"), "interface: a malformed listen names the missing field", badWhy)

        func array(_ s: String?) -> [Any]? { s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any] } }
        check(array(take(i2s_theme_starters_json()))?.count == 15, "interface: starter themes")
        check(array(take(i2s_theme_categories_json()))?.count == CustomTheme.categoryOrder.count, "interface: theme categories")
        let seven = "[1053720,1845544,2764856,8952234,13160664,16053496,14697851]"
        let tooFew = seven.withCString { c in "x".withCString { i2s_theme_generate_json(c, $0, 0, &error) } }
        let tooFewWhy = take(error) ?? ""
        check(tooFew == nil && tooFewWhy.contains("at least"), "interface: too few theme colours are refused", tooFewWhy)
        let eight = "[1053720,1845544,2764856,8952234,13160664,16053496,14697851,4572384]"
        let generated = object(take(eight.withCString { c in "x".withCString { i2s_theme_generate_json(c, $0, 0, &error) } }))
        check((generated?["accent"] as? Int) == 0xE0457B, "interface: generated theme")
        let defaults = take(i2s_settings_normalize_json(nil)).flatMap { try? JSONDecoder().decode(AppSettingsData.self, from: Data($0.utf8)) }
        check(defaults == AppSettingsData(), "interface: default settings")
        let partial = #"{"density":"spacious","spectrumStyle":"neon"}"#
        let normalized = take(partial.withCString { i2s_settings_normalize_json($0) })
            .flatMap { try? JSONDecoder().decode(AppSettingsData.self, from: Data($0.utf8)) }
        check(normalized?.density == .spacious && normalized?.spectrumStyle == AppSettingsData().spectrumStyle,
              "interface: settings read leniently")
        check(take(i2s_customize_standard_layout_json()).flatMap { try? JSONDecoder().decode(PaneLayout.self, from: Data($0.utf8)) } == PaneLayout.standard,
              "interface: standard layout")
        check(array(take(i2s_fonts_json()))?.count == AppFontFamily.allCases.count, "interface: fonts")
        let icons = object(take(i2s_icons_json()))
        check((icons?["packs"] as? [Any])?.count == IconPack.allCases.count && ((icons?["roles"] as? [Any])?.count ?? 0) > 50,
              "interface: icon roles and packs")
        let skin = object(take(i2s_skin_json(nil, nil, nil, 0, &error)))
        check((skin?["colors"] as? [String: Any])?.count == 18 && (skin?["isGlass"] as? Bool) == (AppSettingsData().surfaceStyle == .glass),
              "interface: skin")
        let liveSkin = object(take(i2s_skin_json(nil, #"{"surfaceStyle":"solid"}"#, nil, 1, &error)))
        check((liveSkin?["isGlass"] as? Bool) == true && (liveSkin?["backdrop"] as? String) == "artwork", "interface: live cover skin")
        let themes = object(take(i2s_themes_normalize_json(nil, nil)))
        check((themes?["themes"] as? [Any])?.count == 15 && (themes?["activeID"] as? String) == CustomTheme.starterThemes[0].id.uuidString,
              "interface: theme list")
        check(take(i2s_customize_normalize_json(nil)).flatMap { try? JSONDecoder().decode(CustomizeState.self, from: Data($0.utf8)) }
              == CustomizeState.read(nil), "interface: customize defaults")
        check(take(i2s_font_face("geistMono", 12, "bold")) == "GeistMonoNF-Bold", "interface: font face")
        let lyric = object(take(i2s_lyrics_read_json("[00:02]a\n[00:04]b")))
        check((lyric?["synced"] as? Bool) == true && (lyric?["lines"] as? [Any])?.count == 2, "interface: lyrics")
        let times: [Double] = [2, 4, 6]
        check(times.withUnsafeBufferPointer { i2s_lyrics_line_at($0.baseAddress, 3, 5) } == 1
              && times.withUnsafeBufferPointer { i2s_lyrics_line_at($0.baseAddress, 3, 1) } == -1, "interface: lyric line at a time")
        check((array(take(i2s_eq_profiles_json()))?.count ?? 0) == EQProfile.builtIns.count, "interface: EQ profiles")
        let response = array(take("[100,1000,10000]".withCString { hz in i2s_eq_response_json(nil, hz) }))
        check(response?.count == 3, "interface: EQ response")
        let apo = "Preamp: -6.2 dB\nFilter 1: ON PK Fc 105 Hz Gain 4.5 dB Q 0.70"
        check(object(take(apo.withCString { i2s_eq_parse_json($0, "Imported", &error) })) != nil, "interface: EQ text import", take(error) ?? "")
        let libPath = dir.appendingPathComponent("rules-library.json").path
        if let lib = libPath.withCString({ i2s_library_open($0, &error) }) {
            defer { i2s_library_close(lib) }
            check(array(take(i2s_library_tracks_json(lib)))?.count == 3, "interface: library tracks")
            let view = array(take("all".withCString { s in "emile".withCString { f in "title".withCString { k in i2s_library_view_json(lib, s, f, k, 1, &error) } } }))
            check(view?.count == 2, "interface: library view filtered and sorted", take(error) ?? "")
            check(i2s_library_apply_history(lib, h) == 0, "interface: play counts from the history")
            check(array(take(i2s_library_albums_json(lib)))?.count == 3, "interface: albums (one per album artist)")
        } else {
            check(false, "interface: library opens", take(error) ?? "")
        }
        let bench = object(take(root.path.withCString { i2s_core_bench_history($0, 300) }))
        check((bench?["listens"] as? Int) == 300 && (bench?["fullCheckListens"] as? Int) == 300, "interface: history benchmark",
              "\(bench ?? [:])")
    }

    // MARK: Profile statistics

    static func profile(_ dir: URL) {
        struct Library: Encodable { var tracks: [Track]; var playlists: [Playlist] = [] }
        let support = dir.appendingPathComponent("profile", isDirectory: true)
        let historyDir = support.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        var tracks: [Track] = []
        for a in 0..<5 {
            for n in 0..<8 {
                tracks.append(Track(filePath: "/x/\(a)/\(n).flac", title: "Song \(n)", artist: "Artist \(a)", album: "Record \(a)",
                                    albumArtist: "Artist \(a)", genre: ["Jazz", "Folk", "Rock"][a % 3], year: 1970 + a * 9, trackNumber: n + 1,
                                    duration: 150 + Double(n * 20), sampleRate: 44100, bitDepth: 16, channelCount: 2,
                                    estimatedBitrateKbps: 900, fileFormat: "FLAC", playCount: 999, lastPlayedAt: Date()))
            }
        }
        try? JSONEncoder().encode(Library(tracks: tracks)).write(to: support.appendingPathComponent("library.json"))
        let secrets = FileHistorySecrets(dir: historyDir)
        ListenSeeder.seed(dir: historyDir, secrets: secrets, tracks: tracks, count: 1_500)
        guard let first = try? ListenLog(dir: historyDir, secrets: secrets), let second = try? ListenLog(dir: historyDir, secrets: secrets) else {
            return check(false, "profile: history opens")
        }
        check(first.listens.count > 1_000 && first.report.isClean, "profile: seeded history is sealed and clean", "\(first.report)")
        let now = Date()
        var same = true
        for range in ProfileRange.allCases {
            let a = ProfileStats(listens: first.listens, library: tracks, albums: [], range: range, now: now)
            let b = ProfileStats(listens: second.listens, library: tracks, albums: [], range: range, now: now)
            same = same && a.listens == b.listens && a.seconds == b.seconds && a.artists == b.artists && a.albums == b.albums
                && a.tracks == b.tracks && a.topArtists == b.topArtists && a.topAlbums == b.topAlbums && a.topTracks == b.topTracks
                && a.timeline == b.timeline && a.hours == b.hours && a.weekdays == b.weekdays && a.genres == b.genres
                && a.decades == b.decades && a.milestones == b.milestones && a.longestStreak == b.longestStreak
                && a.currentStreak == b.currentStreak && a.heardTracks == b.heardTracks
            if let d = range.days {
                let start = Calendar.current.date(byAdding: .day, value: -(d - 1), to: Calendar.current.startOfDay(for: now))!
                same = same && a.listens == first.listens.filter { $0.endedAt >= start }.count
                    && a.timeline.reduce(0) { $0 + $1.count } == a.listens
            }
        }
        check(same, "profile: every range's stats are the same after reading the history back")
        let all = ProfileStats(listens: second.listens, library: tracks, albums: [], range: .all, now: now)
        check(all.totalListens == second.listens.count && all.hours.reduce(0, +) == all.listens
              && all.weekdays.reduce(0, +) == all.listens && all.topArtists.first.map { $0.count > 0 } == true,
              "profile: totals, hours and weekdays add up")
    }

    // MARK: Metadata tools

    static func metadataTools() {
        print("metadata tools")
        let cases: [(String, CaseStyle, String)] = [
            ("the dark side of the moon", .title, "The Dark Side of the Moon"),
            ("HELLO FROM THE OTHER SIDE", .title, "Hello From the Other Side"),
            ("dj shadow - midnight in a perfect world", .title, "DJ Shadow - Midnight in a Perfect World"),
            ("my iPhone song", .title, "My iPhone Song"),
            ("track (remix)", .title, "Track (Remix)"),
            ("rock 'n' roll is here to stay", .title, "Rock 'n' Roll Is Here to Stay"),
            ("songs of the year 2023", .title, "Songs of the Year 2023"),
            ("rocky ii theme", .title, "Rocky II Theme"),
            ("self-titled love", .title, "Self-Titled Love"),
            ("what is it for", .title, "What Is It For"),
            ("Hello World (Remix)", .sentence, "Hello world (Remix)"),
            ("I KNOW WHAT I'M DOING", .sentence, "I know what I'm doing"),
        ]
        for (input, style, expected) in cases {
            let got = TitleCaser.apply(input, style: style)
            check(got == expected, "\(style.label): \"\(input)\"", "→ \"\(got)\"")
        }
        var rules = CleanupRules()
        check(MetadataCleanup.title("Song  ft Drake", rules) == "Song (feat. Drake)", "feat. tidied", MetadataCleanup.title("Song  ft Drake", rules))
        check(MetadataCleanup.title("Song [Featuring The Weeknd]", rules) == "Song (feat. The Weeknd)", "featuring in brackets")
        rules.removeEditionTags = true
        check(MetadataCleanup.title("Heroes (2017 Remaster)", rules) == "Heroes", "edition tags removed", MetadataCleanup.title("Heroes (2017 Remaster)", rules))
        check(MetadataCleanup.title("Heroes (Live)", rules) == "Heroes (Live)", "other brackets kept")

        func track(_ artist: String, album: String = "A") -> Track {
            Track(filePath: "/x/\(UUID()).flac", title: "t", artist: artist, album: album, duration: 1, sampleRate: 44_100,
                  bitDepth: 16, channelCount: 2, estimatedBitrateKbps: 0, fileFormat: "FLAC")
        }
        let spellings = ArtistSpellings.find(in: [track("Beyoncé"), track("Beyoncé"), track("Beyonce"), track("BEYONCÉ"),
                                                  track("The Weeknd"), track("Weeknd"), track("Jay-Z"), track("Jay Z"), track("Drake")])
        check(spellings.count == 3, "artist spellings grouped", "\(spellings.map(\.variants))")
        check(spellings.first { $0.key == "beyonce" }?.suggested == "Beyoncé", "the common spelling is suggested")
    }

    // MARK: Models

    static func models() {
        print("models")
        let t = Track(filePath: "/x.flac", title: "Song", artist: "Björk", album: "Post", duration: 200,
                      sampleRate: 96_000, bitDepth: 24, channelCount: 2, estimatedBitrateKbps: 3000, fileFormat: "FLAC", playCount: 3)
        check(SmartRule(field: .artist, op: .contains, value: "bjo").matches(t), "contains ignores case and diacritics")
        check(!SmartRule(field: .artist, op: .notContains, value: "BJÖ").matches(t), "does-not-contain is the exact inverse")
        check(SmartRule(field: .artist, op: .equals, value: "bjork").matches(t), "text equality ignores case and diacritics")
        check(SmartRule(field: .hiRes, op: .isTrue).matches(t) && !SmartRule(field: .hiRes, op: .isFalse).matches(t), "flag rules")
        check(SmartRule(field: .duration, op: .equals, value: "3").matches(t), "length in whole minutes")
        check(!SmartRule(field: .year, op: .lte, value: "2000").matches(t), "unknown year never matches")
        check(SmartRule(field: .playCount, op: .gte, value: "3").matches(t), "numeric at-least")

        let rows = LibraryRow.build(from: [t, t, t], groupBy: .none)
        check(rows.compactMap { if case .track(_, let s) = $0 { return s } else { return nil } } == [false, true, false], "row striping")
        check(Track.format(seconds: 3725) == "1:02:05" && Track.format(seconds: 59.9) == "0:59", "duration formatting")
    }

}
#endif
