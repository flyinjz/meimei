import SwiftUI
import AppKit
import CoreGraphics
import CoreImage

/// Builds the glass skin for the "From Cover" theme. Surfaces are neutral
/// glass over the blurred artwork; only the accent comes from the cover —
/// its most vivid color, lifted until it reads clearly on dark glass.
enum AlbumColorExtractor {
    static let fallbackSkin = glassSkin(accent: RGB(r: 0.92, g: 0.92, b: 0.94), base: RGB(r: 0.08, g: 0.08, b: 0.1))

    static func makeSkin(from image: NSImage) -> Skin {
        guard let samples = samplePixels(image, dimension: 48), !samples.isEmpty else { return fallbackSkin }
        let dominant = dominantColor(samples)
        let vivid = vividColor(samples) ?? dominant
        let hsl = vivid.hsl
        let accent = hsl.s < 0.12
            ? RGB(r: 0.93, g: 0.93, b: 0.95)                          // monochrome cover: white accent
            : RGB.hsl(h: hsl.h, s: max(0.45, min(0.72, hsl.s)), l: max(0.66, min(0.74, hsl.l)))
        // The base stays neutral: a hue taken from the cover tints every
        // glass surface (warm covers turned the whole window bronze).
        return glassSkin(accent: accent, base: RGB(r: 0.075, g: 0.075, b: 0.085))
    }

    private static func glassSkin(accent: RGB, base: RGB) -> Skin {
        let white = Color.white
        return Skin(
            id: "from-cover-live",
            name: "From Cover",
            bgVoid: base.color(),
            bgPanel: .clear,
            bgRow: .clear,
            bgRowAlt: white.opacity(0.035),
            bgRaised: white.opacity(0.05),
            hairline: white.opacity(0.12),
            textPrimary: white.opacity(0.96),
            textSecondary: white.opacity(0.68),
            textTertiary: white.opacity(0.46),
            textOnAccent: accent.luma > 0.6 ? Color.black.opacity(0.85) : white,
            accent: accent.color(),
            accentDim: accent.color(alpha: 0.45),
            accentGlow: accent.mixed(with: RGB(r: 1, g: 1, b: 1), amount: 0.35).color(),
            lcdOn: white.opacity(0.92),
            lcdOff: white.opacity(0.14),
            lcdBackground: Color.black.opacity(0.18),
            selection: white.opacity(0.16),
            hover: white.opacity(0.07),
            allowsBackdropBleed: true,
            isGlass: true
        )
    }

    /// The most saturated well-populated hue: the color a person would call
    /// the cover's color, even when it covers less area than a dull one.
    private static func vividColor(_ samples: [RGB]) -> RGB? {
        let chromatic = samples.filter { $0.isChromatic && $0.saturation > 0.3 }
        guard chromatic.count >= max(6, samples.count / 40) else { return nil }
        let binCount = 24
        var weight = Array(repeating: 0.0, count: binCount)
        for p in chromatic {
            weight[min(binCount - 1, Int(p.hsl.h * Double(binCount)))] += p.saturation * (0.5 + p.luma)
        }
        guard let peak = weight.indices.max(by: { weight[$0] < weight[$1] }) else { return nil }
        let peakHue = (Double(peak) + 0.5) / Double(binCount)
        let cluster = chromatic.filter { hueDistance($0.hsl.h, peakHue) <= 1.5 / Double(binCount) }
        return cluster.isEmpty ? nil : averageColor(cluster)
    }

    /// The cover's main color: the largest same-hue region, edges ignored.
    /// A mean of every pixel turns complementary art into gray; counting by
    /// hue keeps a blue cover blue and a red cover red.
    private static func dominantColor(_ samples: [RGB]) -> RGB {
        let chromatic = samples.filter(\.isChromatic)
        guard chromatic.count >= 12 else {
            let mid = samples.filter { $0.luma > 0.06 && $0.luma < 0.94 }
            return averageColor(mid.isEmpty ? samples : mid)
        }

        let binCount = 24
        var counts = Array(repeating: 0, count: binCount)
        for pixel in chromatic {
            let i = min(binCount - 1, Int(pixel.hsl.h * Double(binCount)))
            counts[i] += 1
        }
        // Neighbor smoothing so a red that straddles the 0/360 wrap still
        // beats a smaller second color.
        var smoothed = counts
        for i in 0..<binCount {
            let prev = (i + binCount - 1) % binCount
            let next = (i + 1) % binCount
            smoothed[i] = counts[i] + counts[prev] + counts[next]
        }
        let peak = smoothed.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let peakHue = (Double(peak) + 0.5) / Double(binCount)
        let cluster = chromatic.filter { hueDistance($0.hsl.h, peakHue) <= (2.0 / Double(binCount)) }
        let chosen = cluster.count >= 8 ? cluster : chromatic
        return averageColor(chosen)
    }

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    private static func samplePixels(_ image: NSImage, dimension: Int) -> [RGB]? {
        let width = dimension
        let height = dimension
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        var proposed = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            // TIFF fallback for representations that don't vend a CGImage directly.
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let fallback = rep.cgImage else { return nil }
            ctx.draw(fallback, in: CGRect(x: 0, y: 0, width: width, height: height))
            return pixels(from: data, width: width, height: height)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels(from: data, width: width, height: height)
    }

    /// Drops the outer ring so a black frame or white border can't outvote the cover.
    private static func pixels(from data: [UInt8], width: Int, height: Int) -> [RGB] {
        let margin = 3
        var result: [RGB] = []
        result.reserveCapacity((width - margin * 2) * (height - margin * 2))
        guard width > margin * 2, height > margin * 2 else { return result }
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                let o = (y * width + x) * 4
                let a = Double(data[o + 3]) / 255.0
                guard a > 0.2 else { continue }
                result.append(RGB(
                    r: (Double(data[o]) / 255.0 / a).clamped01(),
                    g: (Double(data[o + 1]) / 255.0 / a).clamped01(),
                    b: (Double(data[o + 2]) / 255.0 / a).clamped01()
                ))
            }
        }
        return result
    }

    private static func averageColor(_ pixels: [RGB]) -> RGB {
        var r = 0.0, g = 0.0, b = 0.0
        for p in pixels { r += p.r; g += p.g; b += p.b }
        let n = Double(pixels.count)
        return RGB(r: r / n, g: g / n, b: b / n)
    }
}

private struct RGB {
    var r: Double
    var g: Double
    var b: Double

    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var saturation: Double {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        guard maxC > 0.001 else { return 0 }
        return (maxC - minC) / maxC
    }

    /// A real color, including dark navy and deep red. Near-black noise and
    /// blown highlights stay out so they can't become the "main" color.
    var isChromatic: Bool {
        if luma < 0.025 || luma > 0.97 { return false }
        if luma < 0.08 { return saturation > 0.28 }
        return saturation > 0.12
    }

    static func hsl(h: Double, s: Double, l: Double) -> RGB {
        let s = s.clamped01()
        let l = l.clamped01()
        var h = h.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        if s < 0.001 { return RGB(r: l, g: l, b: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGB(r: channel(h + 1.0 / 3), g: channel(h), b: channel(h - 1.0 / 3))
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        guard d > 0.001 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        return ((h / 6).clamped01(), s.clamped01(), l.clamped01())
    }

    func mixed(with other: RGB, amount: Double) -> RGB {
        let t = amount.clamped01()
        return RGB(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t
        )
    }

    func color(alpha: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

private extension Double {
    func clamped01() -> Double { min(1, max(0, self)) }
}

/// Pre-blurs a cover for the window backdrop. Blurring a small copy once
/// costs far less than a live full-window blur filter and looks the same
/// once scaled up.
enum BackdropBlur {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func render(_ image: NSImage) -> NSImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let side = 160.0
        let scale = side / Double(max(cg.width, cg.height))
        let input = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.45,
                kCIInputBrightnessKey: -0.04
            ])
            .cropped(to: extent)
        guard let out = context.createCGImage(blurred, from: extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }
}
