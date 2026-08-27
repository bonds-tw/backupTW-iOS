//
//  QRImageDecoder.swift
//  backupTW
//

import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Reads a QR string out of a still image — the fallback for a code too dense to
/// scan off another screen with the live camera.
///
/// Measured on device 2026-08-27: a driving-licence credential offer packs a
/// longer `credential_offer_uri` into its code than a visitor card does, so its
/// QR has more, and therefore smaller, modules; held up to a laptop screen the
/// camera never resolved them and the card would not scan, while the sparser
/// visitor card did. A clean screenshot of the same code carries every module at
/// full fidelity, so Vision reads from the picture what the camera could not read
/// off the glass. The decoded string then goes through the very same parse the
/// camera path uses — this only changes where the bytes come from, never what is
/// trusted about them.
enum QRImageDecoder {

    /// The payload of the first QR code in the image, or `nil` if there is none.
    ///
    /// Two readers, tried in order. Vision is asked first — on a device it is the
    /// stronger reader and the one that pays off for a code photographed at an
    /// angle. It is also, on the Simulator, silent: `VNDetectBarcodesRequest`
    /// finds nothing there however clean the image, which would leave this path
    /// untested in CI. `CIDetector` is Core Image on the CPU, reads the same code
    /// on the Simulator and on a device, and so is both the fallback and what the
    /// test actually exercises. A screenshot decodes through the first; the second
    /// is there so a device that declines the first still reads the card.
    static func firstQRPayload(in image: CGImage) -> String? {
        visionPayload(in: image) ?? ciDetectorPayload(in: image)
    }

    /// Only `.qr` is requested: every code this app reads is a QR, and narrowing
    /// the symbologies keeps a stray barcode elsewhere in a screenshot from being
    /// returned as if it were the offer.
    private static func visionPayload(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { ($0 as? VNBarcodeObservation)?.payloadStringValue }
            .first
    }

    private static func ciDetectorPayload(in image: CGImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }
}
