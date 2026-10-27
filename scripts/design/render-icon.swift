// Renders Hearth's app icon: the amber rounded-TV-with-play mark from the
// mockups' header on the #0E0F12 background with a warm glow.
//
//   swift render-icon.swift <output-dir> [<tv-brand-assets-dir>]
//
// Writes AppIcon-iOS-1024.png (opaque, no alpha channel: App Store Connect
// rejects icons with alpha) and the macOS sizes (Big Sur style: a rounded
// square on a transparent canvas with a soft shadow) into <output-dir>.
//
// With a second directory (App/Resources/Assets.xcassets/AppIconTV.brandassets)
// it also writes the Apple TV's brand asset set: the layered App Icon
// (400×240 @1x and @2x) and its App Store size (1280×768), each as an opaque
// back layer (the background), a middle layer (the glow) and a front layer
// (the mark) so tvOS can tilt them apart under focus; and the two opaque Top
// Shelf images (1920×720 and 2320×720, @1x and @2x) with the wordmark set in
// Sora from Core's fonts. The Contents.json files are written too.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let tvDir = CommandLine.arguments.dropFirst(2).first.map { URL(fileURLWithPath: $0, isDirectory: true) }

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

/// Where the mark goes: the mockup's SVG works in a 28 × 28 space; `unit` is
/// one SVG unit in pixels and the SVG's (14, 14.5) — the middle of screen
/// plus stand — lands on `center`.
struct MarkPlacement {
    var center: CGPoint
    var unit: CGFloat

    /// SVG point (y down) to CG point (y up).
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: center.x + (x - 14) * unit, y: center.y - (y - 14.5) * unit)
    }
}

/// The background: a faint lift towards the top so the square isn't flat.
func drawBackground(_ ctx: CGContext, in rect: CGRect) {
    let bg = CGGradient(colorsSpace: sRGB, colors: [backgroundTop, background] as CFArray, locations: [0, 0.7])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [.drawsAfterEndLocation])
}

/// Warm glow behind the screen: the hearth.
func drawGlow(_ ctx: CGContext, _ placement: MarkPlacement, radius: CGFloat) {
    let glow = CGGradient(colorsSpace: sRGB, colors: [color(0xF5B841, 0.30), color(0xF5B841, 0.10), color(0xF5B841, 0)] as CFArray, locations: [0, 0.45, 1])!
    let glowCenter = placement.p(14, 12.75)
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: radius, options: [])
}

/// The screen's face, its outline, the stand and the play triangle.
func drawMark(_ ctx: CGContext, _ placement: MarkPlacement, shadowBlur: CGFloat) {
    let unit = placement.unit
    let p = placement.p
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
    ctx.setShadow(offset: .zero, blur: shadowBlur, color: color(0xF5B841, 0.55))
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

/// Draws the artwork into `rect` (in CG coordinates, origin bottom-left):
/// the background, the glow and the mark. `rect` is the full icon for iOS and
/// the rounded body for the Mac.
func drawArtwork(_ ctx: CGContext, in rect: CGRect) {
    let s = rect.width
    drawBackground(ctx, in: rect)
    // Scaled so the TV is about 58% of the icon's width, centred optically
    // (a little high, since the stand adds weight below).
    let placement = MarkPlacement(center: CGPoint(x: rect.midX, y: rect.midY + s * 0.005), unit: s * 0.58 / 23)
    drawGlow(ctx, placement, radius: s * 0.56)
    drawMark(ctx, placement, shadowBlur: s * 0.035)
}

func writePNG(_ image: CGImage, _ name: String, in directory: URL = outDir) throws {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

// MARK: - tvOS

/// A canvas of `width` × `height` pixels; opaque ones have no alpha channel
/// (tvOS requires the back layer and the top shelf images to be opaque).
func canvas(_ width: Int, _ height: Int, opaque: Bool) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    if opaque {
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return ctx
}

func writeJSON(_ object: Any, _ path: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: url)
}

let xcodeInfo: [String: Any] = ["author": "xcode", "version": 1]

/// The TV mark's placement on a 5:3 icon: the TV about 37% of the width,
/// well inside the area tvOS keeps when it scales and tilts the layers.
func tvIconPlacement(width: CGFloat, height: CGFloat) -> MarkPlacement {
    MarkPlacement(center: CGPoint(x: width / 2, y: height / 2 + height * 0.01), unit: width * 0.37 / 23)
}

/// One layered App Icon image stack: Back (opaque background), Middle (the
/// glow), Front (the mark), at each scale.
func writeIconStack(_ name: String, size: (Int, Int), scales: [Int], in directory: URL) throws {
    let stack = directory.appendingPathComponent("\(name).imagestack")
    let layers: [(String, (CGContext, CGFloat, CGFloat) -> Void, Bool)] = [
        ("Front", { ctx, w, h in drawMark(ctx, tvIconPlacement(width: w, height: h), shadowBlur: w * 0.02) }, false),
        ("Middle", { ctx, w, h in drawGlow(ctx, tvIconPlacement(width: w, height: h), radius: h * 0.78) }, false),
        ("Back", { ctx, w, h in drawBackground(ctx, in: CGRect(x: 0, y: 0, width: w, height: h)) }, true),
    ]
    for (layer, draw, opaque) in layers {
        let layerDir = stack.appendingPathComponent("\(layer).imagestacklayer")
        var images: [[String: Any]] = []
        for scale in scales {
            let w = size.0 * scale, h = size.1 * scale
            let ctx = canvas(w, h, opaque: opaque)
            draw(ctx, CGFloat(w), CGFloat(h))
            let file = scale == 1 ? "\(layer).png" : "\(layer)@\(scale)x.png"
            try writePNG(ctx.makeImage()!, "Content.imageset/\(file)", in: layerDir)
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        }
        try writeJSON(["images": images, "info": xcodeInfo], "Content.imageset/Contents.json", in: layerDir)
        try writeJSON(["info": xcodeInfo], "Contents.json", in: layerDir)
    }
    try writeJSON(["info": xcodeInfo, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }], "Contents.json", in: stack)
}

/// Core's fonts, for the wordmark on the top shelf.
func font(_ file: String, size: CGFloat) -> CTFont {
    let fonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/Core/Sources/Core/Resources/Fonts")
    guard let provider = CGDataProvider(url: fonts.appendingPathComponent(file) as CFURL),
          let cgFont = CGFont(provider) else {
        fatalError("Couldn't load \(file) from \(fonts.path)")
    }
    return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
}

func line(_ text: String, font: CTFont, color: CGColor, tracking: CGFloat = 0) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
}

/// A top shelf image: the glow, the mark and "Hearth" side by side in the
/// middle, the tagline under the wordmark.
func topShelf(width: Int, height: Int) -> CGImage {
    let ctx = canvas(width, height, opaque: true)
    let w = CGFloat(width), h = CGFloat(height)
    drawBackground(ctx, in: CGRect(x: 0, y: 0, width: w, height: h))

    let k = h / 720
    let wordmark = line("Hearth", font: font("Sora-Bold.ttf", size: 132 * k), color: color(0xF2F1EE), tracking: -1.3 * k)
    let tagline = line("Live TV, movies and shows for everyone at home", font: font("IBMPlexSans-Regular.ttf", size: 34 * k), color: color(0xA3A7B3))
    let wordWidth = CGFloat(CTLineGetTypographicBounds(wordmark, nil, nil, nil))
    let tagWidth = CGFloat(CTLineGetTypographicBounds(tagline, nil, nil, nil))
    let textWidth = max(wordWidth, tagWidth)
    let unit = 11 * k
    let markWidth = 23 * unit
    let gap = 56 * k
    let left = (w - (markWidth + gap + textWidth)) / 2
    let placement = MarkPlacement(center: CGPoint(x: left + markWidth / 2, y: h / 2 + 4 * k), unit: unit)

    drawGlow(ctx, placement, radius: h * 0.9)
    drawMark(ctx, placement, shadowBlur: 18 * k)

    let textX = left + markWidth + gap
    ctx.textPosition = CGPoint(x: textX, y: h / 2 + 2 * k)
    CTLineDraw(wordmark, ctx)
    ctx.textPosition = CGPoint(x: textX + 4 * k, y: h / 2 - 62 * k)
    CTLineDraw(tagline, ctx)
    return ctx.makeImage()!
}

func writeTopShelf(_ name: String, size: (Int, Int), in directory: URL) throws {
    let set = directory.appendingPathComponent("\(name).imageset")
    var images: [[String: Any]] = []
    for scale in [1, 2] {
        let file = scale == 1 ? "\(name).png" : "\(name)@2x.png"
        try writePNG(topShelf(width: size.0 * scale, height: size.1 * scale), file, in: set)
        images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
    }
    try writeJSON(["images": images, "info": xcodeInfo], "Contents.json", in: set)
}

if let tvDir {
    try writeIconStack("App Icon - App Store", size: (1280, 768), scales: [1], in: tvDir)
    try writeIconStack("App Icon", size: (400, 240), scales: [1, 2], in: tvDir)
    try writeTopShelf("Top Shelf Image Wide", size: (2320, 720), in: tvDir)
    try writeTopShelf("Top Shelf Image", size: (1920, 720), in: tvDir)
    try writeJSON([
        "assets": [
            ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
            ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
            ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
            ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
        ],
        "info": xcodeInfo,
    ], "Contents.json", in: tvDir)
}
