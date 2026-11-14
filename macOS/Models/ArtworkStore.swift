import Foundation
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Content-addressed cover cache. The filename is a hash of the original
/// image bytes, so every track on a record (and every re-import of it)
/// shares one file on disk.
struct ArtworkStore: Sendable {
    let directory: URL

    /// Covers are stored at most this many pixels on the long edge — plenty
    /// for a full-window blurred backdrop, a fraction of a 3000px scan.
    static let maxPixelSize = 1400

    func path(forImageData data: Data) -> String {
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("cover_\(digest).jpg").path
    }

    /// Writes `data` (any ImageIO-readable format) as a JPEG and returns its
    /// path, or the existing path if this exact image is already stored.
    func store(_ data: Data) -> String? {
        let destination = path(forImageData: data)
        if FileManager.default.fileExists(atPath: destination) { return destination }
        guard let jpeg = Self.normalizedJPEG(from: data) else { return nil }
        do {
            try jpeg.write(to: URL(fileURLWithPath: destination), options: .atomic)
            return destination
        } catch {
            NSLog("i2s: failed to store artwork: %@", String(describing: error))
            return nil
        }
    }

    /// Deletes cached covers no track points at any more.
    func prune(keeping referenced: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".jpg") && (name.hasPrefix("cover_") || name.hasPrefix("art_")) {
            let full = directory.appendingPathComponent(name).path
            if !referenced.contains(full) {
                try? fm.removeItem(atPath: full)
            }
        }
    }

    static func normalizedJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Decoded, downsampled covers keyed by path and pixel size. Every artwork
/// view goes through here instead of decoding the file in `body`.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "meimei.artwork-decode", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 600
    }

    /// Size buckets keep the number of cached variants small.
    static func bucket(for points: CGFloat) -> Int {
        let pixels = Int(points * 2)
        for size in [64, 128, 256, 512, 1024] where pixels <= size { return size }
        return ArtworkStore.maxPixelSize
    }

    func cached(_ path: String, pixels: Int) -> NSImage? {
        cache.object(forKey: "\(pixels)|\(path)" as NSString)
    }

    /// Synchronous decode — for callers already off the main thread.
    func image(_ path: String, pixels: Int) -> NSImage? {
        let key = "\(pixels)|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = Self.decode(path: path, maxPixels: pixels) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func load(_ path: String, pixels: Int, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let hit = cached(path, pixels: pixels) {
            MainActor.assumeIsolated { completion(hit) }
            return
        }
        queue.async {
            let image = self.image(path, pixels: pixels)
            DispatchQueue.main.async { completion(image) }
        }
    }

    func invalidate(_ path: String) {
        // NSCache can't enumerate; drop everything. Only hit when a cover is replaced.
        cache.removeAllObjects()
    }

    private static func decode(path: String, maxPixels: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
