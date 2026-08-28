//
//  TransportEquivalenceTests.swift
//  backupTWTests
//
//  The claim the verifier screen makes by having two entrances: the radio is a
//  courier and nothing more.
//

import Foundation
import Testing
@testable import backupTW

private let deviceKeyTag = "tw.bonds.backupTW.tests.transportequivalence"

/// Two ways in, one document.
///
/// `VerifierViewController` now accepts a presentation from a camera **or** from
/// Bluetooth, and both land in the same `VerifierSession.check`. That is a
/// security claim, not a convenience one: if the two paths could deliver
/// different bytes, or if one could produce a verdict the other would not, then
/// "received over Bluetooth" would quietly mean something different from
/// "scanned", and an attacker would pick whichever entrance judged them more
/// kindly.
///
/// The radio itself cannot be exercised here — CoreBluetooth does not exist in
/// the simulator, which is the whole reason `BluetoothLink` is thin and
/// `LinkTransport` is where the decisions live. What *can* be pinned, and is
/// pinned here, is everything on either side of the antenna: one signing path,
/// two shardings, two reassemblies, and one verdict.
struct TransportEquivalenceTests {

    private static let issuedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private static let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                               unifiedNo: "A123456789",
                                               name: "王小明",
                                               birthdate: "民國 083年03月06日",
                                               addressOfHousehold: "臺北市中正區重慶南路一段122號")

    /// A card-signed presentation, and the request it answers — the largest
    /// payload this app actually ships, and so the one worth proving the
    /// sharding on.
    ///
    /// It does **not** verify, and cannot: the certificate in this fixture is a
    /// test one, so `OfflineVerifier` refuses it at
    /// `.cardholderCertificateUnusable`, correctly. That is why the verdict test
    /// below uses a device-signed credential instead — two matching *rejections*
    /// would be a weak equivalence, since the earliest check rejects both before
    /// most of the bytes are ever read.
    private static func cardSignedPresentation() throws -> (payload: Data, request: PresentationRequest) {
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

        let store = TransportEquivalenceStore()
        try store.save(jws: try envelope.serialized(), id: StoredNationalID.credentialID)
        let holder = HolderPresentation(store: store, loadKey: { key })

        let request = try PresentationRequest(challenge: "VFJBTlNQT1JULUVRVUktMDAx",
                                              purpose: "里長辦公室核對受災戶身分",
                                              createdAt: issuedAt,
                                              audience: nil,
                                              linkServiceID: UUID())
        return (try holder.presentation(answering: request, now: issuedAt), request)
    }

    /// A self-issued presentation that really does verify, so the verdict being
    /// compared is a pass.
    ///
    /// Smaller than the card-signed one — no certificate, no RSA signature — so
    /// `oneVerdictWhicheverEntranceItCameThrough` asserts its own multi-frame
    /// precondition rather than inheriting it.
    private static func deviceSignedPresentation() throws -> (payload: Data, request: PresentationRequest) {
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)

        let credential = VerifiableCredential.nationalID(model,
                                                        issuerDID: did,
                                                        validFrom: issuedAt.addingTimeInterval(-3600))
        let store = TransportEquivalenceStore()
        try store.save(jws: try credential.jwsCompactSerialization(signedBy: key, issuerDID: did),
                       id: StoredNationalID.credentialID)
        let holder = HolderPresentation(store: store, loadKey: { key })

        let request = try PresentationRequest(challenge: "VFJBTlNQT1JULUVRVUktMDAy",
                                              purpose: "里長辦公室核對受災戶身分",
                                              createdAt: issuedAt,
                                              audience: nil,
                                              linkServiceID: UUID())
        return (try holder.presentation(answering: request, now: issuedAt), request)
    }

    /// Both couriers, one payload, out the other side.
    private static func deliver(_ payload: Data) throws -> (camera: Data?, radio: Data?,
                                                            qrFrames: Int, bleFrames: Int) {
        let camera = FrameCollector()
        var throughCamera: Data?
        let qrFrames = try QRTransport.frames(for: payload)
        for frame in qrFrames {
            if case .payload(let data) = FrameIntake.accept(frame, into: camera) {
                throughCamera = data
            }
        }

        let radio = LinkCollector()
        var throughRadio: Data?
        // 512 is what the 2026-08-12 exchange with a Mac negotiated; it is the
        // receiver's MTU on the day, not a constant, which is exactly why these
        // tests assert on the payload and not on the frame count.
        let bleFrames = try LinkTransport.frames(for: payload, maximumFrameBytes: 512)
        for frame in bleFrames {
            if case .completed(let data) = try radio.accept(frame) {
                throughRadio = data
            }
        }
        return (throughCamera, throughRadio, qrFrames.count, bleFrames.count)
    }

    /// The headline: the same bytes come out of both couriers.
    ///
    /// Asserted on the reassembled payload rather than on the frames, because the
    /// frames are *supposed* to differ — one lot is base45 text sized for a QR
    /// symbol, the other is binary sized for an ATT MTU. What must not differ is
    /// what the verifier ends up holding.
    @Test func bluetoothAndCameraDeliverIdenticalBytes() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let (payload, _) = try Self.cardSignedPresentation()

        let delivered = try Self.deliver(payload)

        #expect(delivered.camera == payload)
        #expect(delivered.radio == payload)
        #expect(delivered.camera == delivered.radio)
    }

    /// Both really were multi-frame. Without this the test above would pass just
    /// as well on a payload that fitted in one frame each way — which would prove
    /// nothing about sharding, and this file exists to prove something about
    /// sharding.
    @Test func neitherPathWasASingleFrame() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let (payload, _) = try Self.cardSignedPresentation()

        let delivered = try Self.deliver(payload)

        #expect(delivered.qrFrames > 1, "QR sharding untested: \(payload.count) B fitted in one frame")
        #expect(delivered.bleFrames > 1, "BLE sharding untested: \(payload.count) B fitted in one frame")
    }

    /// One verdict, whichever way it arrived.
    ///
    /// The strong form of the claim: not just the same bytes, but the same
    /// answer from the verifier — and specifically a *pass*, so that an
    /// equivalence of two rejections cannot stand in for it.
    @Test func oneVerdictWhicheverEntranceItCameThrough() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let (payload, request) = try Self.deviceSignedPresentation()

        let delivered = try Self.deliver(payload)
        // Its own precondition: this payload is smaller than the card-signed one,
        // and an equivalence proved on one frame each way would be an equivalence
        // about nothing.
        #expect(delivered.qrFrames > 1, "QR sharding untested: \(payload.count) B fitted in one frame")
        #expect(delivered.bleFrames > 1, "BLE sharding untested: \(payload.count) B fitted in one frame")

        let scanned = try #require(delivered.camera.flatMap { String(data: $0, encoding: .utf8) })
        let received = try #require(delivered.radio.flatMap { String(data: $0, encoding: .utf8) })

        // `OfflineVerifier.verify` is pure — the single-use rule lives in
        // `VerifierSession` — so the same challenge can legitimately be checked
        // twice here. On the screen it cannot, and that is the next test.
        let now = Self.issuedAt.addingTimeInterval(30)
        let fromCamera = OfflineVerifier.verify(presentationJWS: scanned, against: request, now: now)
        let fromRadio = OfflineVerifier.verify(presentationJWS: received, against: request, now: now)

        guard case .verified = fromCamera else {
            Issue.record("camera path did not verify: \(String(describing: fromCamera.failure))")
            return
        }
        #expect(fromCamera == fromRadio)
    }

    /// The screen has two entrances and one challenge, and the challenge is the
    /// thing that must not be spendable twice.
    ///
    /// This is the failure mode the view controller's `stopLink()` calls exist to
    /// prevent, one layer down: whichever courier arrives second finds nothing
    /// outstanding. It matters because both entrances are live at once — the
    /// checker can be holding the camera up while the radio is still receiving —
    /// and a session that answered both would have let one presentation satisfy
    /// two checks.
    @Test func theSecondEntranceFindsTheChallengeAlreadySpent() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let (payload, _) = try Self.deviceSignedPresentation()
        let jws = try #require(String(data: payload, encoding: .utf8))

        let session = VerifierSession()
        // Not the request the payload answers — that one was minted by the
        // fixture. This checks the spending rule, which does not depend on the
        // presentation being valid, and using a mismatched challenge makes the
        // point sharper: even a *rejected* answer spends it.
        _ = try session.beginCheck(purpose: "里長辦公室核對受災戶身分", now: Self.issuedAt)

        let first = session.check(presentationJWS: jws, now: Self.issuedAt)
        let second = session.check(presentationJWS: jws, now: Self.issuedAt)

        guard case .checked = first else {
            Issue.record("the first arrival should have been checked, got \(first)")
            return
        }
        #expect(second == .noPendingRequest)
    }
}

private final class TransportEquivalenceStore: CredentialStoring {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { Array(items.keys).sorted() }
    func delete(id: String) throws { items.removeValue(forKey: id) }
    func deleteAll() throws { items.removeAll() }
}
