//
//  PresentationFrameCountTests.swift
//  backupTWTests
//
//  How many QR codes the holder actually has to hold still for.
//

import Foundation
import Testing
@testable import backupTW

private let deviceKeyTag = "tw.bonds.backupTW.tests.framecount"

/// The number nobody had measured.
///
/// The roadmap said 「約 6.5KB ≈ 3 個 QR frame」 and a comment in
/// `CardSignedPresentationTests` said the deciding number was the 2,953 bytes a
/// QR version 40 symbol holds. Dividing one by the other gives about three, and
/// that is where the three came from.
///
/// Neither input was right. The payload is larger than 6.5 KB, and 2,953 is not
/// the number that decides anything here: this app pins symbols at 89 modules and
/// error-correction level Q so a code stays scannable across a gap between two
/// phone screens, which leaves `QRTransport.chunkByteBudget` = 364 bytes per
/// frame. The real answer is about fourteen.
///
/// So this file exists to keep the figure attached to a measurement. It asserts a
/// range rather than an equality because each disclosure carries 128 bits of
/// random salt, so the wire size moves by a few bytes between runs.
struct PresentationFrameCountTests {

    private static let issuedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private static let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                               unifiedNo: "A123456789",
                                               name: "王小明",
                                               birthdate: "民國 083年03月06日",
                                               addressOfHousehold: "臺北市中正區重慶南路一段122號")

    /// The measurement itself: build a card-signed, selectively disclosable
    /// presentation and shard it exactly as the holder's screen does.
    private static func frames(disclosing: [String]?) throws -> (frames: [String], jwsBytes: Int) {
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)

        let (credential, disclosures) = VerifiableCredential.selectivelyDisclosableNationalID(
            model, issuerDID: did, validFrom: issuedAt)
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential)
        let envelope = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: try cardSignature(over: Data(tbs.utf8)).base64EncodedString()),
            disclosures: disclosures.map(\.encoded))

        let store = FrameCountStore()
        try store.save(jws: try envelope.serialized(), id: StoredNationalID.credentialID)
        let holder = HolderPresentation(store: store, loadKey: { key })

        let request = try PresentationRequest(challenge: "Q0hBTExFTkdFLTAwMDAwMA",
                                              purpose: "里長辦公室核對受災戶身分",
                                              createdAt: issuedAt,
                                              audience: nil)
        let frames = try holder.frames(answering: request, disclosing: disclosing, now: issuedAt)
        let jws = try VerifiablePresentation.create(
            credentialJWS: try envelope.serialized(),
            request: request,
            signedBy: key,
            holderDID: did,
            disclosing: disclosing)
        return (frames, jws.utf8.count)
    }

    /// The headline. If this range is wrong, every sentence anywhere that quotes a
    /// frame count is wrong with it.
    @Test func aCardSignedPresentationIsAboutFourteenFrames() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let (frames, jwsBytes) = try Self.frames(disclosing: nil)

        #expect((12...16).contains(frames.count),
                "frame count moved: \(frames.count) frames, JWS \(jwsBytes) bytes, budget \(QRTransport.chunkByteBudget) B/frame")
        // Not three, and not because of 2,953. Stated as its own assertion so a
        // regression to the folklore number fails loudly rather than sliding
        // under a range.
        #expect(frames.count > 3)
    }

    /// Withholding fields barely helps, which is worth knowing before anybody
    /// proposes selective disclosure as a way to shrink the carousel. The
    /// certificate and the card's RSA signature dominate, and neither is
    /// withholdable.
    @Test func withholdingEverythingBarelyShortensTheCarousel() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let everything = try Self.frames(disclosing: nil)
        let minimum = try Self.frames(disclosing: [])

        #expect(everything.frames.count - minimum.frames.count <= 2,
                "disclosing nothing saved \(everything.frames.count - minimum.frames.count) frames — if that is now large, the size comment needs rewriting")
    }

    /// The frames really do reassemble. A count means nothing if the payload does
    /// not survive it, and the carousel shows them in order but a scanner sees
    /// them in whatever order the camera catches.
    @Test func everyFrameIsNeededAndTheyReassembleInAnyOrder() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let (frames, jwsBytes) = try Self.frames(disclosing: nil)

        let collector = FrameCollector()
        var payload: Data?
        for frame in frames.reversed() {
            if case .completed(let data) = try collector.accept(frame) { payload = data }
        }
        #expect(try #require(payload).count == jwsBytes)

        // And one frame short is not enough — otherwise the count above would be
        // measuring padding.
        let short = FrameCollector()
        var completedEarly = false
        for frame in frames.dropLast() {
            if case .completed = try short.accept(frame) { completedEarly = true }
        }
        #expect(!completedEarly)
    }

    /// How long the holder stands there. The carousel is a 0.55 s timer, so the
    /// frame count is a duration: at fourteen frames a full cycle is about eight
    /// seconds, and a scanner that misses one waits for the next pass.
    @Test func afullCycleTakesAboutEightSeconds() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let (frames, _) = try Self.frames(disclosing: nil)

        let cycle = Double(frames.count) * 0.55
        #expect(cycle > 5, "a comment somewhere still says a cycle finishes in under two seconds")
        #expect(cycle < 10)
    }
}

private final class FrameCountStore: CredentialStoring {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { Array(items.keys).sorted() }
    func delete(id: String) throws { items.removeValue(forKey: id) }
    func deleteAll() throws { items.removeAll() }
}
