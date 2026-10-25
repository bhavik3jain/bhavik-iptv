// Renders Hearth's app icon: the amber rounded-TV-with-play mark from the
// mockups' header on the #0E0F12 background with a warm glow.
//
//   swift render-icon.swift <output-dir>
//
// Writes AppIcon-iOS-1024.png (opaque, no alpha channel: App Store Connect
// rejects icons with alpha) and the macOS sizes (Big Sur style: a rounded
// square on a transparent canvas with a soft shadow).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

let background = color(0x0E0F12)
let backgroundTop = color(0x16181E)
let amber = color(0xF5B841)
let amberLight = color(0xFFD27A)

/// Draws the artwork into `rect` (in CG coordinates, origin bottom-left):
/// the background, the glow and the mark. `rect` is the full icon for iOS and
/// the rounded body for the Mac.
func drawArtwork(_ ctx: CGContext, in rect: CGRect) {
    let s = rect.width

    // Background: a faint lift towards the top so the square isn't flat.
    let bg = CGGradient(colorsSpace: sRGB, colors: [backgroundTop, background] as CFArray, locations: [0, 0.7])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [.drawsAfterEndLocation])

    // The mark sits in the 28 × 28 space of the mockup's SVG, scaled so the
    // TV is about 58% of the icon's width, centred optically (a little high,
    // since the stand adds weight below).
    let unit = s * 0.58 / 23
    let markCenter = CGPoint(x: rect.midX, y: rect.midY + s * 0.005)
    // SVG point (y down) to CG point (y up), with the SVG's (14, 14.5)
    // (the middle of screen plus stand) at markCenter.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: markCenter.x + (x - 14) * unit, y: markCenter.y - (y - 14.5) * unit)
    }

    // Warm glow behind the screen: the hearth.
    let glow = CGGradient(colorsSpace: sRGB, colors: [color(0xF5B841, 0.30), color(0xF5B841, 0.10), color(0xF5B841, 0)] as CFArray, locations: [0, 0.45, 1])!
    let glowCenter = p(14, 12.75)
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: s * 0.56, options: [])

    let stroke = 2.3 * unit
    let screenRect = CGRect(x: p(2.5, 20.5).x, y: p(2.5, 20.5).y, width: 23 * unit, height: 15.5 * unit)
    let screen = CGPath(roundedRect: screenRect, cornerWidth: 4 * unit, cornerHeight: 4 * unit, transform: nil)

    // The screen's face: a faint amber wash, brighter at the top, as if lit.
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    let face = CGGradient(colorsSpace: sRGB, colors: [color(0xF5B841, 0.16), color(0xF5B841, 0.05)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(face, start: CGPoint(x: screenRect.midX, y: screenRect.maxY), end: CGPoint(x: screenRect.midX, y: screenRect.minY), options: [])
    ctx.restoreGState()

    // Outline, stand and play triangle in amber with a slight vertical
    // gradient (lighter at the top).
    let mark = CGMutablePath()
    mark.addPath(screen.copy(strokingWithWidth: stroke, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    let stand = CGMutablePath()
    stand.move(to: p(10, 24.2))
    stand.addLine(to: p(18, 24.2))
    mark.addPath(stand.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10))
    let play = CGMutablePath()
    // The SVG's triangle, a touch larger for the icon, with softened corners.
    let a = p(11.2, 9.0), b = p(17.6, 12.75), c = p(11.2, 16.5)
    let r = 0.9 * unit
    play.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
    play.addArc(tangent1End: a, tangent2End: b, radius: r)
    play.addArc(tangent1End: b, tangent2End: c, radius: r)
    play.addArc(tangent1End: c, tangent2End: a, radius: r)
    play.closeSubpath()
    mark.addPath(play)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.035, color: color(0xF5B841, 0.55))
    ctx.addPath(mark)
    ctx.setFillColor(amber)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(mark)
    ctx.clip()
    let markBounds = mark.boundingBox
    let shine = CGGradient(colorsSpace: sRGB, colors: [amberLight, amber] as CFArray, locations: [0, 0.6])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: markBounds.midX, y: markBounds.maxY), end: CGPoint(x: markBounds.midX, y: markBounds.minY), options: [])
    ctx.restoreGState()
}

func writePNG(_ image: CGImage, _ name: String) throws {
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
    print("wrote \(name) \(image.width)×\(image.height) alpha=\(image.alphaInfo.rawValue)")
}

// iOS: opaque, full bleed (the system applies the mask).
do {
    let px = 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    drawArtwork(ctx, in: CGRect(x: 0, y: 0, width: px, height: px))
    try writePNG(ctx.makeImage()!, "AppIcon-iOS-1024.png")
}

// macOS: Apple's grid puts an 824-pt rounded square (radius ≈ 185) in the
// middle of the 1024 canvas, with room for a shadow.
func macIcon(pixels px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: body, cornerWidth: 185.4 * k, cornerHeight: 185.4 * k, transform: nil)

    if px >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: color(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(background)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.setFillColor(background)
    ctx.fill(body)
    drawArtwork(ctx, in: body)
    ctx.restoreGState()

    // A hairline on the edge so the dark square holds its shape on a dark
    // Dock or desktop.
    if px >= 32 {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1 * k, dy: 1 * k), cornerWidth: 184.4 * k, cornerHeight: 184.4 * k, transform: nil))
        ctx.setStrokeColor(color(0xFFFFFF, 0.10))
        ctx.setLineWidth(max(1, 2 * k))
        ctx.strokePath()
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    try writePNG(macIcon(pixels: points * scale), "AppIcon-mac-\(points)\(suffix).png")
}
