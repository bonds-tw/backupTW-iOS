//
//  ZKLinkEngagementTests.swift
//  backupTWTests
//
//  The code on the ZK verifier's screen, and the size of the thing it invites.
//

import Foundation
import Testing
@testable import backupTW

/// # What this file is really pinning
///
/// Two things, and the second is the one that changed a design.
///
/// The wire format, because a QR code read by a camera at a counter is a parser
/// pointed at a stranger's screen, and every way it can fail has to be told
/// apart from every other way.
///
/// And the **size of a ZK proof**, because the number everything downstream was
/// built on was wrong. The roadmap, this app's own comments, and the verifier
/// screen all said 「約 100 張 QR」. That came from dividing 294 KB — measured
/// against upstream's sample circuit inputs — by QR version 40's 2,953-byte
/// ceiling. Neither input applies: a package proved on a real 自然人憑證 is
/// 398,181 bytes, and this app pins symbols at 89 modules and error-correction
/// level Q, which leaves 364 bytes per frame. The true figure is **824 frames**,
/// and `QRTransport` refuses the payload outright long before it gets there.
///
/// So the QR path for a ZK proof was never a slow path. It was not a path.
struct ZKLinkEngagementTests {

    private static let minted = Date(timeIntervalSince1970: 1_786_500_000)

    private static func engagement(purpose: String = "里長辦公室核對受災戶身分") -> ZKLinkEngagement {
        ZKLinkEngagement(serviceID: UUID(uuidString: "73E7299B-2100-4D2F-B84F-7037BA04FD38")!,
                         purpose: purpose,
                         createdAt: minted)
    }

    // MARK: - The wire

    @Test func itSurvivesTheRoundTrip() throws {
        let original = Self.engagement()
        let decoded = try ZKLinkEngagement.decode(from: try original.encodedForTransport())

        #expect(decoded.serviceID == original.serviceID)
        #expect(decoded.purpose == original.purpose)
        #expect(decoded.version == original.version)
        // Seconds, not sub-seconds: the wire carries an integer, and a test that
        // expected exact `Date` equality would be pinning a precision the format
        // deliberately does not have.
        #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 1)
    }

    /// It has to fit a QR that a phone can read off another phone across a
    /// counter, with room for error correction.
    ///
    /// `PresentationRequest` measured 137–162 bytes and the symbol this app
    /// draws holds 213 at level M. This carries no challenge, so it should be
    /// smaller — and if a field is ever added, this is where that shows up.
    @Test func itFitsInAScannableCode() throws {
        let text = try Self.engagement().encodedForTransport()
        #expect(text.utf8.count < 200, "engagement grew to \(text.utf8.count) bytes: \(text)")
    }

    /// Every failure distinguishable, because a camera at a counter sees a lot
    /// of codes that are not this one.
    @Test func everyWayOfBeingWrongReportsDifferently() throws {
        #expect(throws: ZKLinkEngagement.DecodingFailure.notJSON) {
            try ZKLinkEngagement.decode(from: "https://example.invalid/coupon")
        }
        #expect(throws: ZKLinkEngagement.DecodingFailure.unsupportedVersion(99)) {
            try ZKLinkEngagement.decode(from: #"{"b":"73E7299B-2100-4D2F-B84F-7037BA04FD38","p":"x","t":1,"v":99}"#)
        }
        #expect(throws: ZKLinkEngagement.DecodingFailure.malformedServiceID("not-a-uuid")) {
            try ZKLinkEngagement.decode(from: #"{"b":"not-a-uuid","p":"x","t":1,"v":1}"#)
        }
        #expect(throws: ZKLinkEngagement.DecodingFailure.missingField("p")) {
            try ZKLinkEngagement.decode(from: #"{"b":"73E7299B-2100-4D2F-B84F-7037BA04FD38","t":1,"v":1}"#)
        }
    }

    /// A card-signed request must not decode as one of these.
    ///
    /// **This test failed when it was written, and the failure was the point.**
    /// The two formats share `v`, `b`, `p` and `t`; only the challenge `c` tells
    /// them apart, and the decoder was ignoring unknown keys. So a holder on the
    /// ZK screen who scanned the *other* verifier screen's request got a
    /// successful decode with the challenge silently discarded, connected, and
    /// sent 400 KB to a screen expecting 8 KB — which refuses it for a reason
    /// naming neither screen, after spending the challenge.
    ///
    /// Failing safe is not failing legibly. `isACardSignedRequest` is how the
    /// reader says which code it was actually handed.
    @Test func aCardSignedRequestIsNotSilentlyTreatedAsAnEngagement() throws {
        let request = try PresentationRequest(challenge: "Q0hBTExFTkdFLTAwMDAwMA",
                                              purpose: "里長辦公室核對受災戶身分",
                                              createdAt: Self.minted,
                                              audience: nil,
                                              linkServiceID: UUID())

        #expect(throws: ZKLinkEngagement.DecodingFailure.isACardSignedRequest) {
            try ZKLinkEngagement.decode(from: try request.encodedForTransport())
        }
    }

    /// And the confusion does not run the other way either: the card-signed
    /// screen must not accept a ZK engagement as a request. It cannot — there is
    /// no challenge to be had — but a lenient future edit could invent one, and
    /// a request with a challenge nobody minted is worse than no request at all.
    @Test func anEngagementIsNotAcceptedAsACardSignedRequest() throws {
        let text = try Self.engagement().encodedForTransport()
        #expect((try? PresentationRequest.decode(text)) == nil,
                "a ZK engagement decoded as a PresentationRequest — where did its challenge come from?")
    }

    @Test func aStaleCodeIsNotCurrent() {
        let engagement = Self.engagement()
        #expect(engagement.isCurrent(now: Self.minted.addingTimeInterval(60)))
        #expect(!engagement.isCurrent(now: Self.minted.addingTimeInterval(ZKLinkEngagement.lifetime + 1)))
    }

    // MARK: - The size that made this necessary

    /// The measurement, kept where a change to the transport will trip over it.
    ///
    /// Not a live proof — producing one needs a card, a network round trip to
    /// 內政部 and about two gigabytes of circuit material. The figure is from a
    /// real run (iPhone 14, real 自然人憑證, 2026-08-11) and the arithmetic below
    /// is what everything else in this file is arguing about.
    @Test func aRealProofIsNotAQRPayloadAtAnyFrameSize() {
        let measured = 398_181

        let qrFrames = (measured + QRTransport.chunkByteBudget - 1) / QRTransport.chunkByteBudget
        #expect(qrFrames > 800, "QR frame count moved: \(qrFrames)")
        // The path does not even get as far as being slow: the sharder refuses
        // the payload before it counts frames.
        #expect(measured > QRTransport.maximumPayloadBytes)

        // And over the radio it fits, with the headroom the ceiling was raised
        // to provide. The old 512 KB left 22% — this asserts the new one is not
        // quietly consumed by the next thing that grows.
        #expect(measured <= LinkTransport.maximumPayloadBytes)
        #expect(Double(measured) / Double(LinkTransport.maximumPayloadBytes) < 0.5,
                "a real proof now fills \(100 * measured / LinkTransport.maximumPayloadBytes)% of the link ceiling")
    }

    /// The proof really does shard and reassemble over the link at a realistic
    /// size — with incompressible bytes, because the artifacts are base64 of
    /// proof data and deflate barely dents them.
    @Test func aProofSizedPayloadSurvivesTheLink() throws {
        let payload = LinkTransportTests.incompressible(398_181, seed: 0x5EED)

        let frames = try LinkTransport.frames(for: payload, maximumFrameBytes: 512)
        // 793 at 502 bytes of body per frame. The *real* proof deflates to about
        // 300 KB and comes to 597; these bytes deliberately do not compress, so
        // this is the pessimistic end of the same measurement.
        #expect(frames.count > 700, "frame count at 512 B MTU: \(frames.count)")
        #expect(frames.count <= LinkTransport.maximumChunkCount)

        let collector = LinkCollector()
        var reassembled: Data?
        // Reversed: the receiver has no control over arrival order, and
        // `LinkCollector` is order-free by design.
        for frame in frames.reversed() {
            if case .completed(let data) = try collector.accept(frame) { reassembled = data }
        }
        #expect(reassembled == payload)
    }
}
