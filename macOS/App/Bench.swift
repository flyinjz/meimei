#if DEBUG
import AppKit
import SwiftUI

/// `--bench`: times the work a big library makes expensive, each measured
/// until the main thread has drained (so SwiftUI's update and the table's
/// reload are included), plus a frame-by-frame scroll of the track list.
@MainActor
enum Bench {
    static func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        for _ in 0..<100 where NSApp.windows.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        // Past the library's background cache warm-up, as a user would be.
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        let library = AppSession.shared.library
        print("bench: \(library.tracks.count) tracks, \(library.albumGroups.count) albums, \(library.artistGroups.count) artists")
        if let loop = ProcessInfo.processInfo.environment["MEIMEI_BENCH_LOOP"] {
            // For profiling with `sample`: repeat one operation for a while.
            print("bench: looping \(loop)")
            let id = library.tracks[0].id
            let end = CACurrentMediaTime() + 8
            var i = 0
            while CACurrentMediaTime() < end {
                switch loop {
                case "filter": library.filterText = i % 2 == 0 ? "echo" : "ech"
                case "source": library.source = i % 2 == 0 ? .liked : .all
                case "drag":
                    var layout = AppSession.shared.customize.layout
                    if let c = layout.columns.firstIndex(where: { !$0.panes.contains(.library) }) {
                        layout.columns[c].width = Double(220 + (i % 30) * 4)
                    }
                    AppSession.shared.customize.draft.layout = layout
                    NSApp.windows.first?.displayIfNeeded()
                default: library.recordPlay(id)
                }
                i += 1
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            }
            print("bench: \(i) iterations")
            exit(0)
        }

        for text in ["e", "ec", "ech", "echo", "echo 1", ""] {
            await time("filter \"\(text)\"") { library.filterText = text }
        }
        let ids = library.tracks.prefix(5).map(\.id)
        for (n, id) in ids.enumerated() {
            await time("record play #\(n + 1)") { library.recordPlay(id) }
        }
        await time("like one track") { library.setLiked([ids[0]], true) }
        await time("unlike one track") { library.setLiked([ids[0]], false) }
        for source in [LibrarySource.liked, .genre("Jazz"), .albums, .artists, .all] {
            await time("show \(source.key)") { library.source = source }
        }

        let visible = library.visibleTracks
        for key in ["title", "artist", "album", "time", "plays"] {
            await time("sort by \(key)") { _ = TrackTableView.Coordinator.sorted(visible, by: [NSSortDescriptor(key: key, ascending: true)]) }
        }
        // The ranked sort must match sorting with the comparator exactly.
        let subset = LibraryStore.filter(visible, by: "e")
        for key in ["title", "artist", "album", "genre", "format"] {
            for asc in [true, false] {
                for list in [visible, subset] {
                    let fast = TrackTableView.Coordinator.sorted(list, by: [NSSortDescriptor(key: key, ascending: asc)]).map(\.id)
                    let slow = list.sorted { TrackTableView.Coordinator.textOrder(key, $0, $1, asc) }.map(\.id)
                    if fast != slow { print("bench: MISMATCH sorting \(key) \(asc ? "asc" : "desc") (\(list.count) tracks)") }
                }
            }
        }
        print("bench: ranked sorts checked against the comparator")
        for key in ["title", "album"] {
            await time("re-sort by \(key)") { _ = TrackTableView.Coordinator.sorted(visible, by: [NSSortDescriptor(key: key, ascending: true)]) }
        }
        await time("group rows by album") { _ = LibraryRow.build(from: visible, groupBy: .album) }

        await scroll()
        await paneDrag()
        library.source = .albums
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await scrollGrid("albums")
        library.source = .artists
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await scrollGrid("artists")
        fflush(stdout)
        exit(0)
    }

    /// Runs `body`, then waits for the main queue to drain once.
    private static func time(_ label: String, _ body: () -> Void) async {
        let t0 = CACurrentMediaTime()
        body()
        let sync = CACurrentMediaTime() - t0
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        let total = CACurrentMediaTime() - t0
        print(String(format: "bench: %-24@ %7.2f ms  (sync %6.2f ms)", label as NSString, total * 1000, sync * 1000))
    }

    /// Scrolls the track list 400 steps of 24 pt, rendering each step.
    private static func scroll() async {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 400 }),
              let table = find(NSTableView.self, in: window.contentView!), let clip = table.enclosingScrollView?.contentView else {
            print("bench: no table to scroll")
            return
        }
        var frames: [Double] = []
        var y: CGFloat = 0
        for _ in 0..<400 {
            y += 24
            let t0 = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            CATransaction.flush()
            frames.append(CACurrentMediaTime() - t0)
        }
        frames.sort()
        let avg = frames.reduce(0, +) / Double(frames.count)
        print(String(format: "bench: scroll frame avg %.2f ms, p95 %.2f ms, max %.2f ms (%d rows)",
                     avg * 1000, frames[Int(Double(frames.count) * 0.95)] * 1000, frames.last! * 1000, table.numberOfRows))
    }

    /// A column-width drag as customize mode does it: a draft layout per step.
    private static func paneDrag() async {
        let store = AppSession.shared.customize
        var layout = store.layout
        guard let c = layout.columns.firstIndex(where: { !$0.panes.contains(.library) }) else { return }
        var frames: [Double] = []
        for step in 0..<60 {
            layout.columns[c].width = Double(220 + (step % 30) * 4)
            let t0 = CACurrentMediaTime()
            store.draft.layout = layout
            await withCheckedContinuation { cont in DispatchQueue.main.async { cont.resume() } }
            NSApp.windows.first?.displayIfNeeded()
            CATransaction.flush()
            frames.append(CACurrentMediaTime() - t0)
        }
        store.draft.layout = nil
        frames.sort()
        print(String(format: "bench: pane drag step avg %.2f ms, p95 %.2f ms, max %.2f ms",
                     frames.reduce(0, +) / Double(frames.count) * 1000, frames[Int(Double(frames.count) * 0.95)] * 1000, frames.last! * 1000))
    }

    /// Scrolls the biggest SwiftUI scroll view (the grid) 300 steps.
    private static func scrollGrid(_ label: String) async {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 400 }) else { return }
        var scrolls: [NSScrollView] = []
        func collect(_ v: NSView) {
            if let s = v as? NSScrollView, !(s.documentView is NSTableView) { scrolls.append(s) }
            v.subviews.forEach(collect)
        }
        collect(window.contentView!)
        guard let scroll = scrolls.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return }
        let clip = scroll.contentView
        var frames: [Double] = []
        var y: CGFloat = 0
        for _ in 0..<300 {
            y += 24
            let t0 = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            CATransaction.flush()
            frames.append(CACurrentMediaTime() - t0)
            if y > (scroll.documentView?.frame.height ?? 0) { y = 0 }
        }
        frames.sort()
        print(String(format: "bench: %@ grid scroll avg %.2f ms, p95 %.2f ms, max %.2f ms (content %.0f pt)", label,
                     frames.reduce(0, +) / Double(frames.count) * 1000, frames[Int(Double(frames.count) * 0.95)] * 1000,
                     frames.last! * 1000, scroll.documentView?.frame.height ?? 0))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }
}
#endif
