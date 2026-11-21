// Renders the ToSlash app icon ("to/" on a dark tile) into an .icns.
//
//   swift make-icon.swift <SpaceGrotesk[wght].ttf> <out.icns>
//
// The font is Space Grotesk from github.com/google/fonts (ofl/spacegrotesk), OFL licensed.
// Only the rendered .icns is committed, so building the app never needs the font.
import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <font.ttf> <out.icns>\n".utf8))
    exit(2)
}
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: args[1]) as CFURL) as! [CTFontDescriptor]
let bold = CTFontDescriptorCreateCopyWithAttributes(
    descriptors[0], [kCTFontVariationAttribute: [0x7767_6874 /* 'wght' */: 700]] as CFDictionary)

/// The design is drawn in a 100-unit, y-down space matching the canvas SVG:
/// tile rx 22.5, "to" at 42 units centred on x 47 with baseline 63, slash 68,70 → 82,30.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: k, y: -k)
    // Apple's macOS grid: an 824 px tile centred in the 1024 px canvas.
    ctx.translateBy(x: 100, y: 100)
    ctx.scaleBy(x: 8.24, y: 8.24)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    let text = NSAttributedString(string: "to", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithFontDescriptor(bold, 42, nil),
        NSAttributedString.Key(kCTKernAttributeName as String): -2,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ])
    let line = CTLineCreateWithAttributedString(text)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.translateBy(x: 47 - width / 2, y: 63)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(.white)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    ctx.setStrokeColor(NSColor(srgbRed: 0xC6 / 255, green: 0xF4 / 255, blue: 0x32 / 255, alpha: 1).cgColor)
    ctx.setLineWidth(7.5)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 68, y: 70))
    ctx.addLine(to: CGPoint(x: 82, y: 30))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
