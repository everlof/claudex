import AppKit
import CoreGraphics
import Foundation

// Renders the Claudex app icon: a gauge glyph on the Claude→Codex diagonal gradient,
// inside the macOS rounded-rectangle (squircle) shape with the standard icon padding.
// Emits PNGs at every size the .icns needs.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let terracotta = color(0xd9752f)
let teal = color(0x3ea986)
// Slightly deepened endpoints give the gradient more life at icon scale.
let warmHi = color(0xe8863a)
let coolLo = color(0x2f9478)
// A short, punchy crossover keeps the warm and cool halves vivid and avoids a muddy
// brown band where terracotta and teal meet.

/// Draw the full icon into a bitmap of `px`×`px` and return it as PNG data.
func renderIcon(px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Apple's icon grid: the art sits in a rounded square inset from the canvas edges.
    // ~10% padding all around; corner radius ≈ 22.37% of the tile (the macOS squircle).
    let pad = size * 0.10
    let tile = CGRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
    let radius = tile.width * 0.2237

    // Rounded-rect tile clip.
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()

    // Diagonal terracotta→teal gradient (top-left warm → bottom-right cool).
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [warmHi.cgColor, terracotta.cgColor, teal.cgColor, coolLo.cgColor] as CFArray,
        locations: [0.0, 0.46, 0.56, 1.0])!
    cg.drawLinearGradient(grad,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: [])

    // Soft top sheen for depth.
    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.18).cgColor,
                 NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
        locations: [0.0, 1.0])!
    cg.drawLinearGradient(sheen,
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.midY),
        options: [])
    cg.restoreGState()

    // ---- Gauge glyph, centred in the tile ----
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let gaugeR = tile.width * 0.30
    let lineW = tile.width * 0.075

    // The gauge arc spans ~230° (like a speedometer): from 210° down to -30°.
    let startAngle = CGFloat.pi * (210.0 / 180.0)
    let endAngle = CGFloat.pi * (-30.0 / 180.0)

    // Track (faint, full arc).
    cg.setLineCap(.round)
    cg.setLineWidth(lineW)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    cg.addArc(center: c, radius: gaugeR, startAngle: startAngle, endAngle: endAngle,
              clockwise: true)
    cg.strokePath()

    // Filled portion (white, ~67% of the sweep — the "67 percent" gauge motif).
    let fillFraction: CGFloat = 0.67
    let filledEnd = startAngle - (startAngle - endAngle) * fillFraction
    cg.setLineWidth(lineW)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    cg.addArc(center: c, radius: gaugeR, startAngle: startAngle, endAngle: filledEnd,
              clockwise: true)
    cg.strokePath()

    // Needle pointing to the filled end.
    let needleLen = gaugeR * 0.86
    let needleAngle = filledEnd
    let tip = CGPoint(x: c.x + cos(needleAngle) * needleLen,
                      y: c.y + sin(needleAngle) * needleLen)
    cg.setLineCap(.round)
    cg.setLineWidth(lineW * 0.62)
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.move(to: c)
    cg.addLine(to: tip)
    cg.strokePath()

    // Hub dot.
    let hubR = lineW * 0.72
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))
    // Tinted centre so the hub reads as a dial pivot, not a blob.
    let innerR = hubR * 0.5
    cg.setFillColor(terracotta.cgColor)
    cg.fillEllipse(in: CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let data = renderIcon(px: s)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(s).png")
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent)")
}
