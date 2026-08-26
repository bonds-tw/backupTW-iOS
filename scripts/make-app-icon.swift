// Renders 🪪 from Apple Color Emoji at 1024, over a dark diagonal gradient.
import AppKit
import CoreText

let size = 1024.0
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawGlyph(in ctx: CGContext) {
    // Same sizing as the flat version: measure the glyph, scale so it fills 0.80
    // of the tile on its longest axis (iOS bites ~10% off the corners).
    let target = size * 0.80
    let probeSize = 200.0
    let probeFont = CTFontCreateWithName("Apple Color Emoji" as CFString, probeSize, nil)
    let probe = CTLineCreateWithAttributedString(
        NSAttributedString(string: "🪪", attributes: [.font: probeFont]))
    let probeBounds = CTLineGetBoundsWithOptions(probe, .useGlyphPathBounds)
    let pointSize = probeSize * target / max(probeBounds.width, probeBounds.height)

    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, pointSize, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "🪪", attributes: [.font: font]))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX,
                               y: (size - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, ctx)
}

/// A dark diagonal gradient, top-left (lighter) to bottom-right (near black),
/// in the project's green-black family (`#141C19` is the flat ground colour).
func renderGradient(topLeft: (CGFloat, CGFloat, CGFloat),
                    bottomRight: (CGFloat, CGFloat, CGFloat),
                    out: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

    let colors = [
        CGColor(red: topLeft.0, green: topLeft.1, blue: topLeft.2, alpha: 1),
        CGColor(red: bottomRight.0, green: bottomRight.1, blue: bottomRight.2, alpha: 1),
    ] as CFArray
    guard let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { exit(1) }
    // Top-left to bottom-right. CoreGraphics origin is bottom-left, so the
    // start point is the top-left corner (0, size) and the end is (size, 0).
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    drawGlyph(in: ctx)

    guard let image = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(out)"))
    print("\(outDir)/\(out)")
}

func renderFlat(bg: (CGFloat, CGFloat, CGFloat), grey: Bool, out: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    ctx.setFillColor(red: bg.0, green: bg.1, blue: bg.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    drawGlyph(in: ctx)
    guard var image = ctx.makeImage() else { exit(1) }
    if grey, let filter = CIFilter(name: "CIPhotoEffectMono") {
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        if let o = filter.outputImage, let g = CIContext().createCGImage(o, from: o.extent) { image = g }
    }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(out)"))
    print("\(outDir)/\(out)")
}

func c(_ hex: Int) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat((hex >> 16) & 0xFF) / 255.0,
     CGFloat((hex >> 8) & 0xFF) / 255.0,
     CGFloat(hex & 0xFF) / 255.0)
}

// Default + dark: the same dark gradient (a dark icon in both light and dark
// system appearances). Deep teal-green top-left → near-black bottom-right,
// centred on the project's `#141C19` ground.
renderGradient(topLeft: c(0x1B3A31), bottomRight: c(0x080C0A), out: "bonds-id-light.png")
renderGradient(topLeft: c(0x1B3A31), bottomRight: c(0x080C0A), out: "bonds-id-dark.png")
// Tinted stays monochrome — the system tints it, so a gradient would be lost.
renderFlat(bg: c(0x101010), grey: true, out: "bonds-id-tinted.png")
