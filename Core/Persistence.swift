import Foundation

/// Settings-style payloads that decode leniently: any key missing from the
/// stored JSON (an older build) or holding a value this build can't read
/// (a removed enum case) falls back to the type's default, so a stale
/// preference can never wipe out the rest of the user's customization.
protocol LenientDecodable: Codable {
    init()
}

extension LenientDecodable {
    static func decodeLeniently(from data: Data) -> Self {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(Self()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            return Self()
        }
        let template = merged
        for (key, value) in stored where template[key] != nil {
            merged[key] = value
        }
        if let decoded = decode(merged) { return decoded }

        // Something in the stored payload is unreadable; keep every key
        // that survives on its own and drop the rest.
        var salvaged = template
        for (key, value) in stored where template[key] != nil {
            var candidate = salvaged
            candidate[key] = value
            if decode(candidate) != nil { salvaged = candidate }
        }
        return decode(salvaged) ?? Self()
    }

    private static func decode(_ object: [String: Any]) -> Self? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// A `Codable` value stored as one JSON blob under a UserDefaults key.
enum DefaultsStore {
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func loadLenient<T: LenientDecodable>(_ type: T.Type, key: String) -> T {
        guard let data = UserDefaults.standard.data(forKey: key) else { return T() }
        return T.decodeLeniently(from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Coalesces bursts of saves (a drag across a slider, liking twenty tracks)
/// into one write, and keeps encoding + disk I/O off the main thread.
final class CoalescingFileWriter: @unchecked Sendable {
    private let url: URL
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?
    private let lock = NSLock()

    init(url: URL, delay: TimeInterval = 0.4, label: String) {
        self.url = url
        self.delay = delay
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Schedules `encode` to run on the writer's queue. Only the most
    /// recent request inside the delay window actually runs.
    func schedule(_ encode: @escaping @Sendable () throws -> Data) {
        let item = DispatchWorkItem { [url] in
            do {
                try encode().write(to: url, options: .atomic)
            } catch {
                NSLog("i2s: failed to write %@: %@", url.lastPathComponent, String(describing: error))
            }
        }
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Runs any pending write immediately and waits for it — used on quit.
    func flush() {
        lock.lock()
        let item = pending
        pending = nil
        lock.unlock()
        guard let item, !item.isCancelled else { return }
        item.cancel()
        queue.sync { item.perform() }
    }
}
