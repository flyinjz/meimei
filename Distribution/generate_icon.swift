import AppKit
import CoreGraphics

// Draws a simple Y2K/audiophile-mark app icon: a dark rounded tile with a
// violet gradient, three EQ-style bars, and a small play triangle accent —
// procedurally generated (no external art), then exported at 1024x1024.

let size = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)

guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no ctx") }

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((h >> 16) & 0xFF) / 255,
        green: CGFloat((h >> 8) & 0xFF) / 255,
        blue: CGFloat(h & 0xFF) / 255,
        alpha: a
    )
}

// Background: rounded square with dark-to-void gradient.
let cornerRadius: CGFloat = CGFloat(size) * 0.225
let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [hex(0x14101F), hex(0x0A0A0D)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Subtle inner hairline border.
ctx.setStrokeColor(hex(0x8B6BFF, 0.35))
ctx.setLineWidth(CGFloat(size) * 0.01)
ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: CGFloat(size)*0.01, dy: CGFloat(size)*0.01), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
ctx.strokePath()

// Three EQ bars, glowing violet, uneven heights like a paused spectrum analyzer.
let barCount = 5
let barWidth = CGFloat(size) * 0.09
let spacing = CGFloat(size) * 0.06
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
let startX = (CGFloat(size) - totalWidth) / 2
let baseY = CGFloat(size) * 0.28
let heights: [CGFloat] = [0.30, 0.52, 0.72, 0.46, 0.36].map { $0 * CGFloat(size) }
let barColors: [CGColor] = [
    hex(0xB79CFF), hex(0x9C7CFF), hex(0x8B6BFF), hex(0x9C7CFF), hex(0xB79CFF)
]

for i in 0..<barCount {
    let x = startX + CGFloat(i) * (barWidth + spacing)
    let h = heights[i]
    let barRect = CGRect(x: x, y: baseY, width: barWidth, height: h)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth/2, cornerHeight: barWidth/2, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: CGFloat(size) * 0.035, color: barColors[i].copy(alpha: 0.85))
    ctx.addPath(barPath)
    ctx.setFillColor(barColors[i])
    ctx.fillPath()
    ctx.restoreGState()
}

guard let image = ctx.makeImage() else { fatalError("no image") }
let bitmapRep = NSBitmapImageRep(cgImage: image)
guard let data = bitmapRep.representation(using: .png, properties: [:]) else { fatalError("no png data") }

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try data.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
