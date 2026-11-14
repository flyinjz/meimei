import SwiftUI
import AppKit

/// A cover image, decoded off the main thread at the size it's shown and
/// cached. Shows a placeholder glyph until (or unless) the art loads.
struct ArtworkView: View {
    var path: String?
    /// Display size in points, used to pick a decode size.
    var size: CGFloat
    var skin: Skin
    var placeholder = "music.note"

    @State private var loaded: (key: String, image: NSImage)?

    private var pixels: Int { ArtworkCache.bucket(for: size) }
    private var key: String? { path.map { "\(pixels)|\($0)" } }

    var body: some View {
        let image = currentImage
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                skin.bgRaised
                Glyph(placeholder, size: max(9, size * 0.26))
                    .foregroundStyle(skin.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: key) { await load() }
    }

    private var currentImage: NSImage? {
        guard let key, let path else { return nil }
        if let loaded, loaded.key == key { return loaded.image }
        return ArtworkCache.shared.cached(path, pixels: pixels)
    }

    private func load() async {
        guard let key, let path, loaded?.key != key else { return }
        let pixels = self.pixels
        let image = await withCheckedContinuation { continuation in
            ArtworkCache.shared.load(path, pixels: pixels) { continuation.resume(returning: $0) }
        }
        if let image { loaded = (key, image) }
    }
}
