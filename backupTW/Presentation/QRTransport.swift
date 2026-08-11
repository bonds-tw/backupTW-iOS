//
//  QRTransport.swift
//  backupTW
//

import Compression
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

/// Failures raised while packing a presentation into QR codes or reading one back.
///
/// None of these carry the presentation, a chunk of it, or the frame
/// identifier. The identifier is a digest of the payload, which makes it a
/// stable handle for one particular presentation of one particular person's
/// document — exactly the kind of value `VerifiableCredentialError` refuses to
/// put where a crash reporter or an `os_log` sink can pick it up. Sizes and
/// counts are safe and are carried, because a support conversation that starts
/// with "it says the payload is too large" is worth something.
enum QRTransportError: Error, Equatable {

    /// Nothing to send. A programming error rather than anything the user did.
    case emptyPayload

    /// The payload needs more frames than the wire format can number, or would
    /// exceed the receiver's ceiling once reassembled.
    case payloadTooLarge(limit: Int)

    /// `CIQRCodeGenerator` refused the frame. It returns `nil` rather than
    /// throwing when the content exceeds the version 40 capacity, so this is the
    /// only signal there is — see `qrCode(for:fittingPixelWidth:)`.
    case frameTooLargeForQRCode

    /// Core Graphics would not give us a bitmap. Out of memory, essentially.
    case renderingFailed

    /// The scanned string is not one of ours at all. A verifier's camera sees
    /// whatever is in frame — a Wi-Fi code taped to the counter, a receipt, a
    /// poster — so this is the ordinary case, not an error worth showing anyone.
    case notATransportFrame

    /// Ours, but from a version of the format this build does not implement.
    /// Distinct from `notATransportFrame` because this one *is* worth telling
    /// the user about: the answer is to update the app, not to scan harder.
    case unsupportedFormat(String)

    /// Right scheme and version, unparseable header.
    case malformedFrame

    /// A frame belonging to a different presentation arrived mid-collection.
    /// Two people in the queue, or the holder swiped to a second document.
    case frameFromAnotherPresentation

    /// Same presentation identifier, but the frame count or the compression
    /// flag disagrees with the frames already held. Either a collision in the
    /// truncated digest or someone editing frames by hand.
    case inconsistentFrameHeader

    /// base45 rejected the chunk: a character outside the alphabet, a length
    /// that cannot be a whole number of groups, or a group whose value does not
    /// fit the bytes it claims to encode.
    case corruptChunk

    /// Reassembly would produce more bytes than `FrameCollector` is willing to
    /// hold. See `maximumPayloadBytes` for why a scanner needs this ceiling.
    case oversizedPayload

    /// The chunks reassembled, but the DEFLATE stream inside them did not inflate.
    case decompressionFailed

    /// Every frame arrived and the result does not hash to the identifier the
    /// frames advertised. Something was substituted, truncated, or spliced.
    case payloadDigestMismatch
}

// Deliberately *not* `LocalizedError`.
//
// Most of these cases must never reach a human: `notATransportFrame` fires once
// per video frame for any unrelated QR code in view, and a scanner that surfaced
// it would be unusable. The few that do deserve words — "this is a different
// document", "update the app" — need wording chosen alongside the scanner's
// visual state, not here, and their strings belong to whichever screen owns
// `Localizable.xcstrings`. Handing this type a generic `errorDescription` would
// only make it tempting to print all thirteen cases at a verification counter.

/// Packs an offline presentation into QR codes, and reassembles one from a scan.
///
/// **This layer never looks inside the payload.** It takes `Data` and gives
/// `Data` back. That is the point: the whitepaper's answer to linkability is ZK
/// selective disclosure, and when the OpenACSwift licensing problem clears and
/// the payload becomes a COSE proof object instead of a JOSE presentation,
/// nothing in this file changes. Anything here that parsed a credential would
/// have to be rewritten on that day.
///
/// **What this does not fix.** The presentation this carries embeds a fixed
/// `did:key:`, and the same identifier is handed to every verifier the holder
/// ever meets. Compression does not change that, base45 does not change that,
/// and splitting it across three QR codes does not change that. Two verifiers
/// who compare notes can prove they saw the same person. Nothing in this file
/// should be described to a user as a privacy measure.
///
/// One thing this layer does leak on its own: **the frame count discloses the
/// approximate size of the presentation**, which is a coarse signal about how
/// many fields it carries. It is visible to anyone who can see the screen, which
/// at a verification counter is everyone in the queue. It is small, and it is
/// not fixable without padding every presentation to a constant size — which
/// would be worth doing if the payload were ever reduced to a few hundred bytes.
enum QRTransport {

    // MARK: - Wire format
    //
    //     BTWVP1:<Z|U>:<10 hex>:<NN>:<NN>:<base45 chunk>
    //     └ tag ┘ └flag┘ └ id ┘ └idx┘ └tot┘
    //
    // Uppercase throughout, and every separator drawn from the QR alphanumeric
    // set, for the reason spelled out in `frameCharacterBudget`. That rules out
    // the obvious alternative of a `bondstw://` URI: a lowercase scheme would
    // knock the encoder out of alphanumeric mode, and handing the payload to
    // the system camera to open is the wrong behaviour anyway — the verifier
    // scans with their own app, not with a URL handler.

    static let tag = "BTWVP1"

    /// Everything before the chunk, in characters. Constant, because both
    /// counters are zero-padded — a variable header would make the chunk budget
    /// below depend on how many frames there turn out to be, which depends on
    /// the chunk budget.
    static let headerLength = tag.count + 1 + 1 + 1 + identifierLength + 1 + counterDigits + 1 + counterDigits + 1

    private static let identifierLength = 10
    private static let counterDigits = 2
    private static let uppercaseHexDigits: Set<Character> = Set("0123456789ABCDEF")

    /// The most characters any QR code can hold: version 40, level L,
    /// alphanumeric mode. Measured, and it matches the ISO table exactly.
    /// A scanned string longer than this did not come from a camera.
    private static let absoluteAlphanumericCeiling = 4296

    /// Two digits, so 99. The payload that motivated this file needed three when
    /// the device signed the credential; a card-signed one needs about fourteen,
    /// and a real 自然人憑證 rather than the test fixture will push that to
    /// sixteen or so. See `PresentationFrameCountTests`, which measures it — the
    /// numbers in this file were quoted for a payload that no longer exists.
    static let maximumFrameCount = 99

    private static let deflateFlag = "Z"
    private static let storedFlag = "U"

    // MARK: - Capacity
    //
    // Measured with `CIQRCodeGenerator` on this SDK rather than read off the ISO
    // table, because the generator is the thing that actually decides.

    /// The largest QR a frame may become, as a module count per side —
    /// version 18, 89×89.
    ///
    /// Not a capacity limit; a *legibility* limit, and the only number here with
    /// a physical justification. Scanning reliability is governed by camera
    /// pixels per QR module, and on the oldest device this app supports
    /// (iPhone 8 / SE3, 750 px across a 58.4 mm screen) a version 18 code
    /// displayed at 90% of the screen width, read by a 1080p capture session at
    /// a comfortable 20 cm, lands near 4.7 px/module. The industry floor for a
    /// 2D code is 2.5 and the comfortable region starts around 4. Version 40
    /// under the same conditions gives 2.4 and simply does not scan.
    ///
    /// Version 18 is also where the EU Digital COVID Certificate settled, which
    /// is the only operating point in this space with hundreds of millions of
    /// scans behind it — on cheap phones, held by tired people, at venue doors.
    static let maximumModuleCount = 89

    /// Level Q, 25% recovery.
    ///
    /// The trade-off usually posed is screen versus paper, and it resolves
    /// differently here than it first appears. Because `maximumModuleCount` is
    /// fixed, raising the correction level does **not** make the code physically
    /// harder to read — the modules stay the same size. It costs capacity, and
    /// capacity costs frames: measured on today's card-signed payload, level M
    /// takes about ten frames and level Q about fourteen. (The figures this
    /// paragraph used to give — two and three — were measured on the
    /// device-signed payload this app no longer produces. The argument survived
    /// the change; the numbers did not.)
    ///
    /// The extra frames are worth it because 5.3's setting is not a tidy one. A 里長 office window at noon puts glare across half an OLED
    /// panel; a border queue means a screen held at an angle; and the most
    /// robust carrier in a blackout is a sheet of paper, which gets folded,
    /// smudged, and photocopied. Level M's 15% covers none of those with much
    /// margin. Q is also what the EU DCC chose, for a deployment that had to
    /// work on both screens and printouts.
    ///
    /// Sharding does not cost us the paper case, incidentally. `FrameCollector`
    /// accepts frames in any order, so three codes printed side by side on one
    /// sheet work exactly as well as three shown in sequence on a screen.
    static let errorCorrectionLevel = "Q"

    /// Characters a single frame may contain: 574, measured as the largest
    /// all-alphanumeric string `CIQRCodeGenerator` will still fit inside
    /// `maximumModuleCount` at `errorCorrectionLevel`.
    ///
    /// The alphanumeric part is load-bearing and is why the payload is base45
    /// rather than the base64url it arrives as. QR's byte mode spends 8 bits per
    /// character, so base64url costs 10.67 bits per source byte; alphanumeric
    /// mode packs two characters into 11 bits, so base45's 3-characters-per-
    /// 2-bytes costs 8.25. That 23% is not theoretical — encoding the same 300
    /// random bytes both ways gives version 15 for base64url (400 characters)
    /// and version 13 for base45 (450 characters), and changing a single
    /// character of the base45 string to lowercase pushes it straight back to
    /// version 15. The generator picks its mode from the content, so every byte
    /// of every frame has to stay inside the 45-character set.
    static let frameCharacterBudget = 574

    /// Payload bytes per frame: 364.
    ///
    /// Rounded down to an even number so that base45's 2-bytes-to-3-characters
    /// grouping divides exactly and no frame wastes a character on a short tail.
    static let chunkByteBudget = ((frameCharacterBudget - headerLength) / 3) * 2

    /// The most a scanner will reassemble, before or after inflating.
    ///
    /// A card-signed presentation is about 7.4 KB. This ceiling is roughly 8× that
    /// — it was 32× when a presentation was under 2 KB — and it exists
    /// because the bytes arrive from a stranger's screen: DEFLATE's expansion
    /// ratio is chosen by whoever produced the stream, and a few hundred bytes
    /// of QR can inflate without bound. `GzipDecoder` bounds its output for the
    /// same reason, and this is the same threat wearing a different hat.
    static let maximumPayloadBytes = 64 * 1024

    // MARK: - Sending

    /// Splits `payload` into the strings to show, in order.
    ///
    /// The payload is DEFLATEd first, but only when that actually helps. On a
    /// real presentation it helps a great deal — 1793 bytes to 930, taking the
    /// carousel from five frames to three — because the JOSE payload repeats the
    /// same 57-character DID three times, repeats the `https://bonds.tw/ns/`
    /// namespace five times, and then base64urls the lot, which turns every
    /// repetition into a repetition the compressor can still see. Chinese names
    /// and addresses are not what compresses; the structure around them is. Of
    /// the 826-byte credential body only about 113 bytes are the person's actual
    /// data.
    ///
    /// **That 49% is a symptom, not an achievement.** The same content encoded
    /// as a CWT-style COSE_Sign1 is roughly 270 bytes with no compression at
    /// all — better than five times smaller than the JWS, and a single frame.
    /// Compression here is buying back space that the choice of JSON-LD-over-
    /// JOSE spent, and it should be retired rather than tuned the day the
    /// presentation moves to CBOR.
    ///
    /// `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) with no zlib wrapper, which
    /// makes it interoperable with nothing in particular. That is acceptable
    /// precisely because the frame format is already ours alone; it is also the
    /// thing to remember before anyone points a third-party decoder at these
    /// frames.
    static func frames(for payload: Data) throws -> [String] {
        guard !payload.isEmpty else { throw QRTransportError.emptyPayload }
        guard payload.count <= maximumPayloadBytes else {
            throw QRTransportError.payloadTooLarge(limit: maximumPayloadBytes)
        }

        let identifier = self.identifier(for: payload)
        let deflated = deflateIfSmaller(payload)
        let body = deflated ?? payload
        let flag = deflated == nil ? storedFlag : deflateFlag

        // Strided over the body's own indices rather than over `0..<count`.
        //
        // `body` is `payload` itself whenever compression did not help, and a
        // `Data` does not have to start at zero: `data[100...]`, `dropFirst(n)`,
        // and any subrange of a scan buffer are all `Data` values whose indices
        // are the parent's. `subdata(in: 0..<364)` on one of those is out of
        // bounds and traps — not a wrong answer, a dead process at the counter.
        // The only caller today passes `Data(jws.utf8)`, which starts at zero and
        // hides this; nothing about the signature says it has to.
        let chunks = stride(from: body.startIndex, to: body.endIndex, by: chunkByteBudget).map { start in
            body.subdata(in: start..<min(start + chunkByteBudget, body.endIndex))
        }
        guard chunks.count <= maximumFrameCount else {
            throw QRTransportError.payloadTooLarge(limit: maximumFrameCount * chunkByteBudget)
        }

        return chunks.enumerated().map { index, chunk in
            [tag,
             flag,
             identifier,
             String(format: "%0\(counterDigits)d", index),
             String(format: "%0\(counterDigits)d", chunks.count),
             Base45.encode(chunk)].joined(separator: ":")
        }
    }

    /// First 5 bytes of SHA-256 over the *uncompressed* payload, as uppercase hex.
    ///
    /// Two jobs, and it is worth being clear that neither is authentication.
    /// It tells `FrameCollector` that two frames belong to the same presentation,
    /// and it detects a reassembly that went wrong — a spliced chunk, a bit that
    /// survived error correction, a compression flag that disagreed. Anyone can
    /// compute it, so it stops accidents, not attackers. The signature over the
    /// presentation is the only thing that stops those, and it is checked a
    /// layer above this one.
    ///
    /// Forty bits is sized against accidents: a holder showing two documents in
    /// a row collides with probability 2⁻⁴⁰. Taking the digest over the payload
    /// rather than over the compressed bytes means the check also covers
    /// inflation, which is where a corrupted stream is most likely to produce
    /// plausible-looking garbage.
    fileprivate static func identifier(for payload: Data) -> String {
        let digest = SHA256.hash(data: payload)
        return digest.prefix(identifierLength / 2)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    // MARK: - Rendering

    /// A frame rendered for display, with the numbers a layout needs.
    struct QRCode {
        let image: CGImage
        /// Side length in modules, excluding the quiet zone. 89 at most.
        let moduleCount: Int
        /// Device pixels per module. Always a whole number; see `qrCode(for:fittingPixelWidth:)`.
        let modulePixelSize: Int
        /// Device pixels per point of the display this was sized against.
        ///
        /// 1 when the caller asked in pixels, because a pixel width says nothing
        /// about a screen and pretending otherwise would make `pointSize` a
        /// guess. Anything that has to lay the code out should be using
        /// `qrCode(for:fittingPointWidth:screenScale:)` instead.
        let screenScale: CGFloat
        /// Side length of `image` in device pixels, quiet zone included.
        var pixelSize: Int { (moduleCount + 2 * quietZoneModules) * modulePixelSize }
        /// Side length in points at which `image` has to be laid out for one
        /// module to keep covering exactly `modulePixelSize` device pixels.
        ///
        /// **Not a suggestion.** Flooring the module size to an integer is a
        /// promise about device pixels, and a bitmap dropped into a view of some
        /// other size is resampled by whatever ratio the layout produces —
        /// which is the entire defect this pair of properties exists to close.
        /// Either constrain the view to this number, or build the `UIImage` with
        /// `scale: screenScale` and let it size itself; those are the same
        /// statement. Sizing the view to a round 300 and letting
        /// `.scaleAspectFit` sort it out is not.
        var pointSize: CGFloat { CGFloat(pixelSize) / screenScale }
    }

    /// ISO/IEC 18004 requires four modules of clear margin on every side.
    ///
    /// `CIQRCodeGenerator` emits **one**, which is measurable: a version 1 code
    /// comes out 23×23 for a 21-module symbol. That is not documented anywhere,
    /// and a caller who trusts the extent ships a code that decoders reject when
    /// anything — a card edge, a dark background, a neighbouring view — sits
    /// against the border.
    static let quietZoneModules = 4

    /// Renders one frame at the largest whole-pixel module size that fits.
    ///
    /// Whole pixels matter more than the requested width does. The generator
    /// hands back a bitmap at one pixel per module, and scaling that by a
    /// fractional factor — which is what happens if it is dropped into an image
    /// view and left to fit — makes some modules a pixel wider than their
    /// neighbours and blurs every edge if the layer interpolates. Both cost
    /// scan rate at exactly the distance where there is none to spare. So the
    /// module size is floored to an integer and the result may be a little
    /// narrower than `fittingPixelWidth`; the caller should centre it rather
    /// than stretch it.
    ///
    /// Scale is clamped at 1 rather than 0. A display that cannot give one pixel
    /// per module cannot show a scannable code at all, and returning a
    /// too-large image at least makes that visible instead of returning nothing.
    ///
    /// **A literal here is almost always wrong.** The number has to be the count
    /// of device pixels the code will really cover, which only a laid-out view
    /// knows; see `qrCode(for:fittingPointWidth:screenScale:)`, which is the form
    /// any screen should call.
    static func qrCode(for frame: String, fittingPixelWidth: Int) throws -> QRCode {
        try qrCode(for: frame, fittingPixelWidth: fittingPixelWidth, screenScale: 1)
    }

    /// Renders one frame for a view `pointWidth` points wide on a display with
    /// `screenScale` device pixels to the point, and reports the point size it
    /// must be shown at.
    ///
    /// **The integer module size is only a guarantee if it is computed from the
    /// pixels the code will actually occupy.** Asking for a fixed 1024 and
    /// dropping the result into a 300 pt square is the case that motivated this:
    /// an 89-module frame renders 970 px wide (1024 ÷ 97 = 10 px per module), a
    /// `UIImage` built from that `CGImage` has scale 1 so it measures 970 pt, and
    /// `.scaleAspectFit` then resolves it to 600 device pixels on a 2× screen and
    /// 900 on a 3×. That is a factor of 0.619, and nearest-neighbour resampling
    /// turns uniform 10-pixel modules into a mix of 6 and 7 — a 16% spread in
    /// module width across one symbol, which is precisely the artefact the
    /// flooring above exists to prevent, reintroduced by the layout. Derived
    /// instead, the same view asks for 600, gets 6 px per module, and the symbol
    /// is uniform: 582 px, `pointSize` 291.
    ///
    /// Neither argument is trusted, because both come from UIKit at moments when
    /// UIKit has nothing to report: a view that has not been laid out has a zero
    /// width, an unconstrained one can carry `.greatestFiniteMagnitude`, and
    /// `traitCollection.displayScale` is documented to return 0 when the trait
    /// collection has no display attached. `Int(CGFloat.nan)` traps, so a naive
    /// conversion here would be the same family of crash as the slice bug in
    /// `frames(for:)`. Unusable values fall back to one pixel per module and a
    /// scale of 1, which shows a visibly poor code rather than killing the app
    /// mid-check — the same trade the clamp above already makes.
    static func qrCode(for frame: String,
                       fittingPointWidth pointWidth: CGFloat,
                       screenScale: CGFloat) throws -> QRCode {
        let scale = usableScreenScale(screenScale)
        return try qrCode(for: frame,
                          fittingPixelWidth: fittingPixelWidth(forPointWidth: pointWidth, screenScale: scale),
                          screenScale: scale)
    }

    /// Device pixels to render into for a code `pointWidth` points wide.
    ///
    /// Separate from the renderer so a caller that has to reserve layout space
    /// before rasterising can ask the same question, and so the clamping is
    /// testable without a `CGImage`.
    static func fittingPixelWidth(forPointWidth pointWidth: CGFloat, screenScale: CGFloat) -> Int {
        let requested = (pointWidth * usableScreenScale(screenScale)).rounded(.down)
        // `isFinite` first: `.infinity >= 1` is true, and `Int(.infinity)` traps
        // just as `Int(.nan)` does. NaN fails every comparison and so lands here
        // as well, which is the outcome we want.
        guard requested.isFinite, requested >= 1 else { return 1 }
        return Int(min(requested, CGFloat(maximumRenderPixelWidth)))
    }

    /// The widest bitmap this file will produce, in device pixels per side.
    ///
    /// The buffer is the square of it, so an unbounded width is an unbounded
    /// allocation — and worse, `pixelSide * pixelSide` overflows `Int` and traps
    /// long before the allocator gets a say. The widest display this app runs on
    /// is 2048 px across and a code occupies part of that, so 4096 is twice the
    /// largest honest request and 16 MB of greyscale at the limit.
    static let maximumRenderPixelWidth = 4096

    /// Rejects the scales UIKit reports when it has no screen to report.
    private static func usableScreenScale(_ screenScale: CGFloat) -> CGFloat {
        guard screenScale.isFinite, screenScale >= 1 else { return 1 }
        return screenScale
    }

    private static func qrCode(for frame: String,
                               fittingPixelWidth: Int,
                               screenScale: CGFloat) throws -> QRCode {
        let (side, dark) = try modules(for: frame)

        let sideWithQuietZone = side + 2 * quietZoneModules
        let bounded = min(max(fittingPixelWidth, 0), maximumRenderPixelWidth)
        let scale = max(1, bounded / sideWithQuietZone)
        let pixelSide = sideWithQuietZone * scale

        var pixels = [UInt8](repeating: 0xFF, count: pixelSide * pixelSide)
        for row in 0..<side {
            for column in 0..<side where dark[row * side + column] {
                let top = (row + quietZoneModules) * scale
                let left = (column + quietZoneModules) * scale
                for y in top..<(top + scale) {
                    let rowStart = y * pixelSide
                    for x in left..<(left + scale) {
                        pixels[rowStart + x] = 0x00
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw QRTransportError.renderingFailed
        }
        // 8-bit grey, no alpha, `shouldInterpolate: false`. The last one is the
        // second half of the whole-pixel argument above: it tells every consumer
        // down the line — Core Animation included — not to smooth the edges.
        guard let image = CGImage(width: pixelSide,
                                  height: pixelSide,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 8,
                                  bytesPerRow: pixelSide,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw QRTransportError.renderingFailed
        }

        return QRCode(image: image,
                      moduleCount: side,
                      modulePixelSize: scale,
                      screenScale: screenScale)
    }

    /// The symbol as a grid of dark/light modules, with the generator's
    /// one-module border stripped.
    ///
    /// The bitmap is redrawn into a known 8-bit grey buffer instead of being
    /// read out of the generator's own `CGImage`, whose pixel format is
    /// 32-bit RGB with a premultiplied alpha channel that carries no
    /// information here. Row 0 of a bitmap context is the top scanline, and row
    /// 0 of a `CGImage` built from a data provider is also the top scanline, so
    /// reading and writing in the same order preserves orientation — a QR code
    /// has no vertical symmetry, so getting that wrong produces a symbol nothing
    /// can read. `carriesAPresentationThroughRenderedQRCodes` is the test that
    /// would catch it.
    private static func modules(for frame: String) throws -> (side: Int, dark: [Bool]) {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw QRTransportError.renderingFailed
        }
        filter.setValue(Data(frame.utf8), forKey: "inputMessage")
        filter.setValue(errorCorrectionLevel, forKey: "inputCorrectionLevel")

        // Past version 40 the filter returns nil. It does not throw, does not
        // log, and does not warn, so this guard is the entire error path — and
        // it is reachable in production, because a household address long
        // enough pushes the presentation over the frame count too.
        guard let output = filter.outputImage else {
            throw QRTransportError.frameTooLargeForQRCode
        }

        let rendered = Int(output.extent.width)
        let side = rendered - 2 * 1   // the generator's own one-module border
        guard side > 0 else { throw QRTransportError.renderingFailed }

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let bitmap = context.createCGImage(output, from: output.extent) else {
            throw QRTransportError.renderingFailed
        }

        var grey = [UInt8](repeating: 0, count: rendered * rendered)
        let drawn: Bool = grey.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let target = CGContext(data: base,
                                         width: rendered,
                                         height: rendered,
                                         bitsPerComponent: 8,
                                         bytesPerRow: rendered,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            target.draw(bitmap, in: CGRect(x: 0, y: 0, width: rendered, height: rendered))
            return true
        }
        guard drawn else { throw QRTransportError.renderingFailed }

        var dark = [Bool](repeating: false, count: side * side)
        for row in 0..<side {
            for column in 0..<side {
                dark[row * side + column] = grey[(row + 1) * rendered + (column + 1)] < 128
            }
        }
        return (side, dark)
    }

    // MARK: - Compression

    /// DEFLATEs `payload`, or `nil` when the result would not be smaller.
    ///
    /// The destination is deliberately one byte short of the input: a stream
    /// that will not fit there is a stream not worth sending, so the buffer
    /// bound and the is-this-worth-it test are the same test.
    ///
    /// `COMPRESSION_ZLIB` was picked by measurement, not by reputation. On a
    /// real 1400-byte credential: DEFLATE 720 bytes, LZMA 832, LZFSE 948,
    /// LZ4 1037. LZFSE is the one Apple recommends and it is the second worst
    /// of the four here, because these payloads are small and full of exact
    /// repeats rather than long enough for a modern entropy coder to pay for
    /// its own header.
    /// Internal rather than private because `LinkTransport` frames the same
    /// payloads for a radio and must make the same compress-or-not decision the
    /// same way — two transports that disagreed about when to deflate would
    /// produce two different identifiers for one document.
    static func deflateIfSmaller(_ payload: Data) -> Data? {
        let capacity = payload.count - 1
        guard capacity > 0 else { return nil }

        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.baseAddress else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_encode_buffer(destinationBase.assumingMemoryBound(to: UInt8.self),
                                                 capacity,
                                                 sourceBase.assumingMemoryBound(to: UInt8.self),
                                                 payload.count,
                                                 nil,
                                                 COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    /// Inflates, refusing to produce more than `maximumPayloadBytes`.
    ///
    /// The destination is one byte larger than the ceiling so that "filled the
    /// buffer exactly" and "would have kept going" are distinguishable. Without
    /// that spare byte a payload that happens to inflate to exactly the limit is
    /// indistinguishable from a bomb, and one of those two has to be treated
    /// wrongly.
    ///
    /// **Success here means very little.** Raw DEFLATE has no magic number, no
    /// length field and no checksum — `GzipDecoder` exists in this project
    /// precisely because `COMPRESSION_ZLIB` lacks the framing gzip provides. So
    /// arbitrary bytes routinely inflate: 200 bytes from a linear congruential
    /// generator produce 327 bytes of garbage and a cheerful success code, and
    /// only a first byte that lands on RFC 1951's reserved `BTYPE = 11` reports
    /// failure at all. Nothing about this call validates the payload. The
    /// identifier check in `FrameCollector.assemble` is the gate that does, and
    /// it is a digest over the *plaintext*, which covers inflation as well as
    /// transport — stronger than the checksum a framed container would have
    /// given us.
    ///
    /// `limit` is a parameter rather than the constant it used to be because
    /// `LinkTransport` carries payloads this transport refuses outright — a ZK
    /// package is 294 KB against a QR ceiling of 64. The ceiling still exists
    /// and is still the caller's to state; what changed is that there is now
    /// more than one honest answer to what it should be.
    static func inflate(_ body: Data, limit: Int = maximumPayloadBytes) throws -> Data {
        let capacity = limit + 1
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.baseAddress else { return 0 }
            return body.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase.assumingMemoryBound(to: UInt8.self),
                                                 capacity,
                                                 sourceBase.assumingMemoryBound(to: UInt8.self),
                                                 body.count,
                                                 nil,
                                                 COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw QRTransportError.decompressionFailed }
        guard written <= limit else { throw QRTransportError.oversizedPayload }
        output.count = written
        return output
    }

    // MARK: - Parsing

    /// One frame's header and chunk, before the chunk is decoded.
    fileprivate struct Frame {
        let identifier: String
        let isDeflated: Bool
        let index: Int
        let count: Int
        let chunk: Data
    }

    fileprivate static func parse(_ scanned: String) throws -> Frame {
        // Cheap rejection first. A scanner runs this against every code the
        // camera resolves, most of which have nothing to do with us.
        guard scanned.hasPrefix("BTWVP") else { throw QRTransportError.notATransportFrame }

        // `maxSplits` is not an optimisation. Every character that QR
        // alphanumeric mode allows is also in the base45 alphabet — including
        // the colon — so a chunk can and does contain separators. There is no
        // delimiter available that a chunk cannot produce, which leaves
        // "split a fixed number of times and take the rest verbatim" as the only
        // correct way to read this format.
        let fields = scanned.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)

        guard let first = fields.first, first == tag else {
            throw QRTransportError.unsupportedFormat(String(fields.first ?? ""))
        }
        guard fields.count == 6 else { throw QRTransportError.malformedFrame }

        let flag = String(fields[1])
        guard flag == deflateFlag || flag == storedFlag else { throw QRTransportError.malformedFrame }

        // Spelled out rather than using `Character.isHexDigit`, which is
        // Unicode-aware and accepts fullwidth digits — characters that cannot
        // survive QR alphanumeric mode and so cannot have come from a frame we
        // produced.
        let identifier = String(fields[2])
        guard identifier.count == identifierLength,
              identifier.allSatisfy({ uppercaseHexDigits.contains($0) }) else {
            throw QRTransportError.malformedFrame
        }

        // Length-checked as well as parsed: `Int("7")` succeeds, and a frame
        // numbered "7" instead of "07" would be a different wire format that
        // happened to reassemble, which is the kind of thing that works until
        // one build talks to another.
        guard fields[3].count == counterDigits, fields[4].count == counterDigits,
              let index = Int(fields[3]), let count = Int(fields[4]),
              count >= 1, count <= maximumFrameCount,
              index >= 0, index < count else {
            throw QRTransportError.malformedFrame
        }

        let chunkText = String(fields[5])
        guard chunkText.count <= absoluteAlphanumericCeiling else {
            throw QRTransportError.oversizedPayload
        }

        return Frame(identifier: identifier,
                     isDeflated: flag == deflateFlag,
                     index: index,
                     count: count,
                     chunk: try Base45.decode(chunkText))
    }
}

// MARK: - Receiving

/// Accumulates scanned frames until a payload can be handed back.
///
/// **Not thread-safe, and not `Sendable`.** `AVCaptureMetadataOutput` delivers on
/// whichever queue it was given; confine one collector to one queue.
///
/// The scanning loop is expected to call `accept(_:)` for every code the camera
/// resolves, several times a second, most of them repeats of a frame already
/// held. Repeats are cheap and must not move the progress indicator — a counter
/// that climbed on every video frame would tell the verifier the scan was going
/// well while it was stuck on frame 1 of 3.
///
/// **One collector holds one presentation.** Once complete it keeps answering
/// with that payload, and the first frame of any *other* document is rejected as
/// `frameFromAnotherPresentation`. A counter that scans one person after another
/// must call `reset()` between them; a scanner that forgets will appear to work
/// for the first holder and refuse everyone behind them.
final class FrameCollector {

    /// How much of the presentation is in hand. `received` counts distinct
    /// frames, never scans.
    struct Progress: Equatable {
        let received: Int
        let total: Int
        var isComplete: Bool { received == total }
    }

    enum Reception: Equatable {
        /// A frame not previously held.
        case accepted(Progress)
        /// A frame already held. Progress is unchanged and is returned so the
        /// caller does not have to special-case it.
        case duplicate(Progress)
        /// Every frame is in, and this is the payload.
        case completed(Data)
    }

    private var identifier: String?
    private var isDeflated = false
    private var total: Int?
    private var chunks: [Int: Data] = [:]
    private var completed: Data?

    init() {}

    /// Distinct frames held, or `nil` before the first frame arrives — which is
    /// a real distinction for the UI, because "0 of 3" cannot be shown until a
    /// frame has said what 3 is.
    var progress: Progress? {
        guard let total else { return nil }
        return Progress(received: chunks.count, total: total)
    }

    /// Discards everything and returns to the pre-first-frame state.
    func reset() {
        identifier = nil
        isDeflated = false
        total = nil
        chunks = [:]
        completed = nil
    }

    /// Takes one scanned string.
    ///
    /// Throwing leaves the collector exactly as it was, with one deliberate
    /// exception noted below. That matters more than it sounds: a stray code in
    /// the camera's field of view must not discard a scan that is two thirds
    /// done, and the caller is expected to ignore `notATransportFrame` entirely.
    func accept(_ scanned: String) throws -> Reception {
        let frame = try QRTransport.parse(scanned)

        if let identifier {
            guard frame.identifier == identifier else {
                throw QRTransportError.frameFromAnotherPresentation
            }
            guard frame.count == total, frame.isDeflated == isDeflated else {
                throw QRTransportError.inconsistentFrameHeader
            }
        } else {
            identifier = frame.identifier
            isDeflated = frame.isDeflated
            total = frame.count
        }

        // A carousel keeps playing after the verifier has what they need, and
        // the holder has no way to know the scan succeeded. Answering with the
        // payload again is the honest response; treating late frames as an error
        // would make a working scan look like a failure.
        if let completed {
            return .completed(completed)
        }

        if let held = chunks[frame.index] {
            // Same slot, different bytes. Two presentations whose truncated
            // digests collided, or frames that were edited. Either way the
            // digest check at the end would catch it, but silently overwriting
            // and blaming the digest is worse than saying so here.
            guard held == frame.chunk else {
                throw QRTransportError.frameFromAnotherPresentation
            }
            return .duplicate(Progress(received: chunks.count, total: frame.count))
        }

        // Bound the hold before storing, not after. The frames arrive from a
        // stranger's screen and there are up to 99 of them.
        let held = chunks.values.reduce(0) { $0 + $1.count }
        guard held + frame.chunk.count <= QRTransport.maximumPayloadBytes else {
            throw QRTransportError.oversizedPayload
        }
        chunks[frame.index] = frame.chunk

        guard chunks.count == frame.count else {
            return .accepted(Progress(received: chunks.count, total: frame.count))
        }

        do {
            let payload = try assemble(count: frame.count)
            completed = payload
            return .completed(payload)
        } catch {
            // The one path that clears state, and it has to. Every frame is
            // present and they do not reassemble into what they claimed, so at
            // least one chunk is wrong — but nothing here can say which. Keeping
            // them wedges the collector permanently: the carousel re-delivers
            // the same frames, every one of them matches a slot already held,
            // each is answered `.duplicate`, and the assembly is never retried.
            // Dropping everything costs the verifier one more pass of the
            // carousel and is the only outcome that can recover.
            //
            // `progress` goes back to nil as a result, which is the honest
            // report: the scan really did start over.
            reset()
            throw error
        }
    }

    /// Joins the held chunks, inflates if the frames said so, and checks the
    /// result against the identifier the frames advertised.
    private func assemble(count: Int) throws -> Data {
        // In index order, which is what makes out-of-order arrival work — the
        // dictionary has no order of its own.
        var body = Data()
        for index in 0..<count {
            guard let chunk = chunks[index] else { throw QRTransportError.malformedFrame }
            body.append(chunk)
        }

        let payload = isDeflated ? try QRTransport.inflate(body) : body
        guard payload.count <= QRTransport.maximumPayloadBytes else {
            throw QRTransportError.oversizedPayload
        }
        guard QRTransport.identifier(for: payload) == identifier else {
            throw QRTransportError.payloadDigestMismatch
        }
        return payload
    }
}

// MARK: - base45

/// RFC 9285 base45.
///
/// Exists because it is the only encoding that keeps the payload inside QR's
/// alphanumeric mode — see `QRTransport.frameCharacterBudget` for the 23% that
/// buys, and for why the obvious base64url is the wrong choice here.
///
/// The alphabet includes the space character, which is a hazard worth naming:
/// a chunk can begin with a space (`00 24` encodes to `" 00"`), so anything that
/// trims a scanned string before handing it over corrupts the payload. Nothing
/// here trims, and `preservesASpaceAtTheStartOfAChunk` is the test that keeps it
/// that way. A private 44-symbol alphabet without the space would encode at
/// exactly the same density and remove the hazard, but it would also be a
/// bespoke encoding that the next reader would mistake for base45; the standard
/// is worth more than the hazard costs, and it is the encoding a future move to
/// CBOR would want anyway.
enum Base45 {

    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")

    /// Reverse map over the whole 7-bit range, so decoding is a lookup rather
    /// than a search and an out-of-alphabet character is a `-1` rather than a
    /// silently wrong index.
    private static let values: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (value, character) in alphabet.enumerated() {
            table[Int(character.asciiValue!)] = Int8(value)
        }
        return table
    }()

    /// Two bytes become three characters; a trailing odd byte becomes two.
    static func encode(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity((data.count + 1) / 2 * 3)

        let bytes = [UInt8](data)
        var index = 0
        while index + 1 < bytes.count {
            let value = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            out.append(alphabet[value % 45])
            out.append(alphabet[(value / 45) % 45])
            out.append(alphabet[value / 2025])
            index += 2
        }
        if index < bytes.count {
            let value = Int(bytes[index])
            out.append(alphabet[value % 45])
            out.append(alphabet[value / 45])
        }
        return out
    }

    /// Both range checks below are real corruption detectors, not paperwork.
    ///
    /// A three-character group spans 45³ = 91125 values while it may only encode
    /// 65536, and a two-character group spans 2025 while it may only encode 256;
    /// so a large share of random damage that survives the QR error correction
    /// lands outside the encodable range and is caught here rather than turning
    /// into plausible bytes. A length of 1 modulo 3 is not a group at all.
    static func decode(_ text: String) throws -> Data {
        var symbols = [Int]()
        symbols.reserveCapacity(text.count)
        for character in text.unicodeScalars {
            guard character.isASCII else { throw QRTransportError.corruptChunk }
            let value = values[Int(character.value)]
            guard value >= 0 else { throw QRTransportError.corruptChunk }
            symbols.append(Int(value))
        }

        guard symbols.count % 3 != 1 else { throw QRTransportError.corruptChunk }

        var out = Data()
        out.reserveCapacity(symbols.count / 3 * 2 + 1)
        var index = 0
        while index + 2 < symbols.count {
            let value = symbols[index] + symbols[index + 1] * 45 + symbols[index + 2] * 2025
            guard value <= 0xFFFF else { throw QRTransportError.corruptChunk }
            out.append(UInt8(value >> 8))
            out.append(UInt8(value & 0xFF))
            index += 3
        }
        if index < symbols.count {
            let value = symbols[index] + symbols[index + 1] * 45
            guard value <= 0xFF else { throw QRTransportError.corruptChunk }
            out.append(UInt8(value))
        }
        return out
    }
}
