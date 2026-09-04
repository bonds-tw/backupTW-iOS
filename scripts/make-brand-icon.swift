// 有備而來（Bonds）正式 app icon 產生器。
//
// 圖形語言來自設計系統（docs/design-system.md）：品牌識別色墨松綠
// （卡面漸層 #137A5D → #083A30）作地，盾形勾記作記——解鎖畫面與品牌
// chip 用的同一個符號。取代先前 Apple 範例風格的 🪪 佔位圖。
//
// 用法：swift scripts/make-brand-icon.swift backupTW/Assets.xcassets/AppIcon.appiconset
// 產出 bonds-id-light.png / bonds-id-dark.png / bonds-id-tinted.png（檔名
// 沿用，Contents.json 不必動）。

import AppKit

let size: CGFloat = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// The shield-with-check mark, authored in a 24×24 box (the same geometry as
/// the brand chip's SVG), returned scaled and centred for the tile.
func shieldPath(scale: CGFloat, offset: CGPoint) -> (shield: CGPath, check: CGPath) {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        // Flip y: the source coordinates are SVG-style (y down), CoreGraphics
        // draws y up.
        CGPoint(x: offset.x + x * scale, y: offset.y + (24 - y) * scale)
    }
    let shield = CGMutablePath()
    shield.move(to: point(12, 1.6))
    shield.addLine(to: point(3.4, 5.2))
    shield.addLine(to: point(3.4, 11.2))
    shield.addCurve(to: point(12, 22.4), control1: point(3.4, 16.6), control2: point(7.1, 21.1))
    shield.addCurve(to: point(20.6, 11.2), control1: point(16.9, 21.1), control2: point(20.6, 16.6))
    shield.addLine(to: point(20.6, 5.2))
    shield.closeSubpath()

    let check = CGMutablePath()
    check.move(to: point(10.7, 15.9))
    check.addLine(to: point(7.2, 12.4))
    check.addLine(to: point(8.8, 10.8))
    check.addLine(to: point(10.7, 12.7))
    check.addLine(to: point(15.2, 8.2))
    check.addLine(to: point(16.8, 9.8))
    check.closeSubpath()
    return (shield, check)
}

func render(ground: [(CGFloat, CGFloat, CGFloat)], mark: NSColor, out: String,
            transparentGround: Bool = false) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

    func drawGround() {
        let colors = ground.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray
        let locations: [CGFloat] = ground.count == 3 ? [0, 0.55, 1] : [0, 1]
        guard let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: locations) else { exit(1) }
        // ~150°, matching the card faces' gradient direction.
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // The card faces' baked top-right specular, at icon scale: a soft
        // radial glow that lifts the flat gradient without reading as gloss.
        let highlightColors = [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray
        if let highlight = CGGradient(colorsSpace: cs, colors: highlightColors, locations: [0, 1]) {
            let centre = CGPoint(x: size * 0.74, y: size * 0.80)
            ctx.drawRadialGradient(highlight, startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: size * 0.55, options: [])
        }
    }
    if !transparentGround { drawGround() }

    // The mark fills 58% of the tile, lifted 1.5% above true centre — a shield
    // is bottom-heavy, and geometric centring reads as sagging. (iOS masks
    // ~10% off the corners, so 62% also felt cramped in situ.)
    let markSpan = size * 0.58
    let scale = markSpan / 24
    let offset = CGPoint(x: (size - markSpan) / 2, y: (size - markSpan) / 2 + size * 0.015)
    let (shield, check) = shieldPath(scale: scale, offset: offset)

    // The paper card's stock, not a flat swatch: a barely-there vertical
    // gradient de-flattens the mark the way `WalletCardView`'s faces are lit.
    ctx.saveGState()
    ctx.addPath(shield)
    ctx.clip()
    let markTop = mark.blended(withFraction: 0.06, of: .white) ?? mark
    let markBottom = mark.blended(withFraction: 0.07, of: .black) ?? mark
    let markColors = [markTop.cgColor, markBottom.cgColor] as CFArray
    if let markGradient = CGGradient(colorsSpace: cs, colors: markColors, locations: [0, 1]) {
        ctx.drawLinearGradient(markGradient,
                               start: CGPoint(x: size / 2, y: size),
                               end: CGPoint(x: size / 2, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    } else {
        ctx.setFillColor(mark.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    ctx.restoreGState()
    // A hairline of the ground colour just inside the rim gives the mark a
    // pressed-in edge instead of a sticker's.
    ctx.saveGState()
    ctx.addPath(shield)
    ctx.clip()
    ctx.addPath(shield)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
    ctx.setLineWidth(size * 0.012)
    ctx.strokePath()
    ctx.restoreGState()
    // The check is cut out of the shield so the ground shows through — the
    // same figure-ground trick as the brand chip. An icon must stay opaque, so
    // the cut is made by repainting the ground inside the check, not by
    // clearing to transparency; only the tinted variant, which iOS expects to
    // be an alpha mask, truly clears.
    if transparentGround {
        ctx.setBlendMode(.clear)
        ctx.addPath(check)
        ctx.fillPath()
        ctx.setBlendMode(.normal)
    } else {
        ctx.saveGState()
        ctx.addPath(check)
        ctx.clip()
        drawGround()
        ctx.restoreGState()
    }

    guard let image = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(out)"))
    print("\(outDir)/\(out)")
}

// Light: paper-white shield on the deep pine gradient the cards wear.
render(ground: [(0x13/255, 0x7A/255, 0x5D/255),
                (0x0D/255, 0x5B/255, 0x48/255),
                (0x08/255, 0x3A/255, 0x30/255)],
       mark: NSColor(calibratedRed: 0xF7/255, green: 0xF5/255, blue: 0xEA/255, alpha: 1),
       out: "bonds-id-light.png")

// Dark: near-black green ground, the card faces' mint accent as the mark.
render(ground: [(0x0B/255, 0x15/255, 0x12/255),
                (0x06/255, 0x0C/255, 0x0A/255)],
       mark: NSColor(calibratedRed: 0x5F/255, green: 0xE3/255, blue: 0xC0/255, alpha: 1),
       out: "bonds-id-dark.png")

// Tinted: greyscale mark on transparent — iOS supplies the tint.
render(ground: [], mark: NSColor(calibratedWhite: 0.85, alpha: 1),
       out: "bonds-id-tinted.png", transparentGround: true)
