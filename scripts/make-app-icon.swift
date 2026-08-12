// Renders 🆔 from Apple Color Emoji at 1024, over the project's ground colour.
import AppKit
import CoreText

let size = 1024.0
func render(bg: (CGFloat, CGFloat, CGFloat), grey: Bool, out: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    ctx.setFillColor(red: bg.0, green: bg.1, blue: bg.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // 🪪 is a landscape card, so a point size chosen as a fraction of the tile
    // leaves it as a thin band with most of the square empty — and at 16pt a
    // thin band is a smudge. Measured once at a reference size, then scaled so
    // the *drawn glyph* fills the target fraction of the tile on its longest
    // axis. iOS bites ~10% off the corners, hence 0.80 rather than something
    // braver.
    let target = size * 0.80
    let probeSize = 200.0
    let probeFont = CTFontCreateWithName("Apple Color Emoji" as CFString, probeSize, nil)
    let probe = CTLineCreateWithAttributedString(
        NSAttributedString(string: "🪪", attributes: [.font: probeFont]))
    let probeBounds = CTLineGetBoundsWithOptions(probe, .useGlyphPathBounds)
    let pointSize = probeSize * target / max(probeBounds.width, probeBounds.height)

    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, pointSize, nil)
    let attributed = NSAttributedString(string: "🪪", attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX,
                               y: (size - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, ctx)

    guard var image = ctx.makeImage() else { exit(1) }
    if grey, let filter = CIFilter(name: "CIPhotoEffectMono") {
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        if let o = filter.outputImage,
           let g = CIContext().createCGImage(o, from: o.extent) { image = g }
    }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print(out)
}
render(bg: (0xF7/255.0, 0xF8/255.0, 0xF5/255.0), grey: false, out: "logo/emoji-id-light.png")
render(bg: (0x14/255.0, 0x1C/255.0, 0x19/255.0), grey: false, out: "logo/emoji-id-dark.png")
render(bg: (0x10/255.0, 0x10/255.0, 0x10/255.0), grey: true,  out: "logo/emoji-id-tinted.png")
