//
//  FailureFaceRenderScratch.swift
//  backupTWTests
//
//  Scratch: renders the refusal screens to PNG so they can be looked at.
//  Not a product test — delete after the review.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@MainActor
struct FailureFaceRenderScratch {

    private static let outputDirectory = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-mashbean-Developer/5aa5c792-8047-4b33-86a4-2be22684042e/scratchpad/failface-shots", isDirectory: true)

    private func render(_ controller: UIViewController, named name: String) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        controller.loadViewIfNeeded()
        // Let CoreAnimation actually draw before the layer tree is captured;
        // without this every capture comes back blank white.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()

        try? FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: format)
        let image = renderer.image { context in
            window.layer.render(in: context.cgContext)
        }
        if let data = image.pngData() {
            try? data.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        }
        // Also dump the label text, which is what actually matters here.
        var lines: [String] = []
        func walk(_ view: UIView, depth: Int) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                lines.append(String(repeating: "  ", count: depth)
                    + "[\(label.font.pointSize)pt \(label.textColor.debugDescription.prefix(0))] " + text)
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(window, depth: 0)
        try? lines.joined(separator: "\n").write(
            to: Self.outputDirectory.appendingPathComponent("\(name).txt"),
            atomically: true, encoding: .utf8)
        print("=== \(name) ===")
        print(lines.joined(separator: "\n"))
    }

    @Test func renderRefusalFaces() {
        render(VerificationResultViewController(outcome: nil), named: "01-noPendingRequest")
        render(VerificationResultViewController(outcome: .rejected(.trustAnchorUnavailable)),
               named: "02-trustAnchorUnavailable")
        render(VerificationResultViewController(outcome: .rejected(.presentationDatedInTheFuture(skew: 400))),
               named: "03-datedInTheFuture")
        render(VerificationResultViewController(outcome: .rejected(.cardholderCertificateRevoked)),
               named: "04-certificateRevoked")
        render(VerificationResultViewController(outcome: .rejected(.credentialUnreadable)),
               named: "05-credentialUnreadable")
        render(VerificationResultViewController(outcome: .rejected(.presentationSignatureInvalid)),
               named: "06-signatureInvalid")
    }

    @Test func packagingErrorStringsAsShown() {
        let cases: [ZKProofPackage.PackagingError] = [
            .unsupportedVersion(3),
            .missingArtifact("cert_chain_rs4096_proof.bin"),
            .artifactTooLarge(name: "user_sig_rs2048_proof.bin", bytes: 9_000_000)
        ]
        for error in cases {
            print("describing:      \(String(describing: error))")
            print("localizedDesc:   \((error as Error).localizedDescription)")
        }
        let link: [LinkTransportError] = [.reassemblyDigestMismatch, .payloadTooLarge(limit: 1024),
                                          .unsupportedVersion(2)]
        for error in link {
            print("link describing: \(String(describing: error))")
            print("link localized:  \((error as Error).localizedDescription)")
        }
    }

    /// A whole transfer that arrives and fails its digest: what does the
    /// collector do afterwards?
    @Test func collectorAfterDigestMismatch() throws {
        let payload = Data((0..<600).map { UInt8($0 % 251) })
        var frames = try LinkTransport.frames(for: payload, maximumFrameBytes: 60)
        #expect(frames.count > 2)
        // Corrupt one byte of the final chunk's body — every frame still parses.
        var last = frames[frames.count - 1]
        last[last.startIndex + LinkTransport.headerByteCount] ^= 0xff
        frames[frames.count - 1] = last

        let collector = LinkCollector()
        var thrown: Error?
        for frame in frames {
            do { _ = try collector.accept(frame) } catch { thrown = error }
        }
        print("thrown on completion: \(String(describing: thrown))")
        print("progress after throw: \(String(describing: collector.progress))")
        // Any further frame now — a resend, a retry — reports as a duplicate at 100%.
        let again = try collector.accept(frames[0])
        print("resend of frame 0 now reports: \(again)")
    }
}

// MARK: - The two codes that look alike

@MainActor
struct WrongCodeScratch {

    /// The holder is on 出示證件 and points the camera at the *proof* checker's
    /// screen. What does the scanner say?
    @Test func credentialHolderScansTheProofCheckersCode() throws {
        let engagement = ZKLinkEngagement(serviceID: UUID(), purpose: "身分查驗")
        let text = try engagement.encodedForTransport()
        print("ZK engagement QR text: \(text)")

        // What the decoder on the credential path makes of it.
        do {
            _ = try PresentationRequest.decode(text)
            print("decoded (unexpected)")
        } catch {
            print("PresentationRequest.decode threw: \(String(describing: error))")
            print("  errorDescription: \(String(describing: (error as? LocalizedError)?.errorDescription))")
        }

        // What the screen actually does with it.
        let screen = PresentCredentialViewController(
            holder: HolderPresentation(store: EmptyCredentialStore()))
        screen.loadViewIfNeeded()
        let decision = screen.acceptScannedRequest(text)
        print("PresentCredentialViewController.acceptScannedRequest -> \(decision)")

        // This used to assert `status: nil` — the silence itself, pinned as
        // though it were the specification. It was not: it was the defect this
        // scratch file was written to demonstrate, and writing it down as an
        // expectation is how a documented bug becomes a protected one.
        //
        // The requirement is that our *own* code, meant for the other screen,
        // is named. Anything else in the viewfinder stays silent.
        guard case .keepScanning(let status) = decision else {
            Issue.record("the wrong code stopped the scanner: \(decision)")
            return
        }
        let named = try #require(status, "our own code, for the other screen, said nothing")
        #expect(!named.isEmpty)
    }

    /// And the mirror: the holder is on 最小揭露 and points the camera at the
    /// *credential* checker's screen.
    @Test func proofHolderScansTheCredentialCheckersCode() throws {
        let request = try PresentationRequest.generate(purpose: "身分查驗")
        let text = try request.encodedForTransport()
        print("PresentationRequest QR text: \(text)")
        do {
            _ = try ZKLinkEngagement.decode(from: text)
            print("decoded (unexpected)")
        } catch {
            print("ZKLinkEngagement.decode threw: \(String(describing: error))")
        }
        // The decoder is expected to refuse it — that half was never in doubt.
        #expect((try? ZKLinkEngagement.decode(from: text)) == nil)

        // What changed is the call site. It used `try?` and dropped the reason
        // on the floor, so `isACardSignedRequest` — a case that exists purely so
        // this situation can be named — never reached a screen. The decoder
        // raising a distinguishable error and the UI discarding it is the exact
        // shape of "the test passes and the person sees nothing".
        var reason: ZKLinkEngagement.DecodingFailure?
        do {
            _ = try ZKLinkEngagement.decode(from: text)
        } catch let failure as ZKLinkEngagement.DecodingFailure {
            reason = failure
        } catch {}
        #expect(reason == .isACardSignedRequest,
                "the one failure the ZK scanner can explain is no longer distinguishable")
    }
}
