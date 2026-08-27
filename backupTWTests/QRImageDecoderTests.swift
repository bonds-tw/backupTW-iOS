//
//  QRImageDecoderTests.swift
//  backupTWTests
//
//  The photo-import fallback for a code too dense to scan off a screen. A QR is
//  generated from a known string and read back, so the decode path is exercised
//  without a camera or a fixture image on disk.
//

import Foundation
import CoreImage
import Testing
@testable import backupTW

@Suite("從圖片讀 QR")
struct QRImageDecoderTests {

    /// Builds a QR image carrying `payload`, upscaled so its modules are several
    /// pixels wide — the generator emits one pixel per module, which is below what
    /// the detector will read.
    private func qrImage(of payload: String, scale: CGFloat = 10) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // The generator draws black modules on a transparent ground; a detector
        // needs the light quiet zone, so composite over white — a screenshot of a
        // real code already has one.
        let onWhite = scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent))
        return CIContext().createCGImage(onWhite, from: onWhite.extent)!
    }

    @Test func aGeneratedCodeReadsBackToItsString() {
        let payload = "modadigitalwallet://credential_offer?credential_offer_uri=https%3A%2F%2Fissuer-oid4vci.wallet.gov.tw%2Fapi%2Fissuer%2F00000000%2Fcredential-offer-object%3Fnonce%3Dabc%26sub%3Ddef"
        let decoded = QRImageDecoder.firstQRPayload(in: qrImage(of: payload))
        #expect(decoded == payload)
    }

    @Test func anImageWithoutAQRYieldsNil() {
        // A plain white 40×40 image carries no code.
        let ctx = CIContext()
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let cg = ctx.createCGImage(white, from: white.extent)!
        #expect(QRImageDecoder.firstQRPayload(in: cg) == nil)
    }

    /// A picked screenshot of the official deep link carries the CR+LF the QR
    /// frames its query with; the decoder returns it verbatim and the scan path's
    /// `parse(scanned:)` is what strips it — the decoder trusts nothing about the
    /// bytes, exactly as the camera path does.
    @Test func theDecodedStringIsHandedOnUntouched() throws {
        let framed = "modadigitalwallet://credential_offer?\r\ncredential_offer_uri=https%3A%2F%2Fissuer-oid4vci.wallet.gov.tw%2Fapi%2Fissuer%2F00000000%2Fcredential-offer-object%3Fnonce%3Dx%26sub%3Dy"
        let decoded = try #require(QRImageDecoder.firstQRPayload(in: qrImage(of: framed)))
        // The decoder does not clean it; the shared parse does.
        let link = try CredentialOfferLink.parse(scanned: decoded)
        guard case .byReference(let fetchURL) = link else {
            Issue.record("parsed to \(link), not byReference")
            return
        }
        #expect(fetchURL.contains("issuer-oid4vci.wallet.gov.tw"))
    }
}
