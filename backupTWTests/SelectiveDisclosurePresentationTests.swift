//
//  SelectiveDisclosurePresentationTests.swift
//  backupTWTests
//
//  What actually leaves the device when a holder withholds a field.
//

import Foundation
import Testing
@testable import backupTW

private let deviceKeyTag = "tw.bonds.backupTW.tests.sdpresent"

struct SelectiveDisclosurePresentationTests {

    private static let issuedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private static let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                               unifiedNo: "A123456789",
                                               name: "王小明",
                                               birthdate: "民國 083年03月06日",
                                               addressOfHousehold: "臺北市中正區重慶南路一段122號")

    /// A stored credential in the shape issuance now produces.
    private func store(for did: String) throws -> InMemoryStore {
        let (credential, disclosures) = VerifiableCredential.selectivelyDisclosableNationalID(
            Self.model, issuerDID: did, validFrom: Self.issuedAt)
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential)
        let envelope = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: try cardSignature(over: Data(tbs.utf8)).base64EncodedString()),
            disclosures: disclosures.map(\.encoded))

        let store = InMemoryStore()
        try store.save(jws: try envelope.serialized(), id: StoredNationalID.credentialID)
        return store
    }

    private static func request() throws -> PresentationRequest {
        try PresentationRequest(challenge: "Q0hBTExFTkdFLTAwMDAwMA",
                                purpose: "里長辦公室核對受災戶身分",
                                createdAt: issuedAt,
                                audience: nil)
    }

    /// The presentation's own bytes, reassembled from the frames the holder
    /// would actually display. Everything below asserts against *these* — what a
    /// scanner receives — rather than against any in-memory object, because the
    /// question is what left the device.
    private static func presented(_ frames: [String]) throws -> String {
        let collector = FrameCollector()
        var payload: Data?
        for frame in frames {
            if case .completed(let data) = try collector.accept(frame) { payload = data }
        }
        return String(decoding: try #require(payload), as: UTF8.self)
    }

    // MARK: What leaves the device

    /// The load-bearing assertion of the whole feature: a withheld value is not
    /// in the bytes. Not hidden behind a flag, not encrypted, not present — a
    /// scanner that keeps every frame it ever saw has nothing to go back to.
    @Test func awithheldValueIsAbsentFromTheBytesThatLeave() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let holder = HolderPresentation(store: try store(for: did), loadKey: { key })

        let frames = try holder.frames(answering: Self.request(),
                                       disclosing: [AgePredicate.claimName],
                                       now: Self.issuedAt)
        let presentation = try Self.presented(frames)

        // The disclosures are base64url of JSON, so the plain values are not
        // literally searchable — decode the envelope and look at what it holds.
        let enveloped = try Self.envelopedCredential(inPresentation: presentation)
        let serialized = try #require(EnvelopedVerifiableCredential(
            context: "", id: enveloped, type: "").moicaSignedSerialization)
        let envelope = try MOICASignedCredential.parse(serialized)
        let names = envelope.disclosures.compactMap { Disclosure(encoded: $0)?.claimName }

        // `name` rides along whether or not it was asked for — see
        // `VerifiablePresentation.claimsThatCannotBeWithheld`. It is in the
        // certificate regardless, so disclosing it costs nothing and buys the
        // checker the CN-to-name comparison.
        #expect(Set(names) == [AgePredicate.claimName, "name"])

        // Searched across the **whole envelope**, not just the disclosures.
        //
        // This test used to look only at `envelope.disclosures`, which is what
        // made it green while being wrong: the certificate travels in
        // `proof.certificate` in the same envelope, and the cardholder's name is
        // inside it. The assertion passed, its name claimed the value was
        // "absent from the bytes that leave", and the value had left.
        let everything = try #require(serialized.data(using: .utf8))
        let certificate = try #require(Data(base64Encoded: envelope.proof.certificate))

        for value in ["A123456789", "民國 083年03月06日", "臺北市中正區重慶南路一段122號"] {
            let bytes = Data(value.utf8)
            #expect(!everything.contains(subsequence: bytes),
                    "\(value) left the device despite being withheld")
        }

        // And the asymmetry, asserted rather than glossed. Three values can be
        // withheld and are; the name cannot be, because the certificate carries
        // it and the checker needs the certificate to verify anything at all.
        //
        // The second assertion reads like a test protecting a defect, and that
        // is the point: if anybody restores 「姓名不會送出」 to the holder's
        // screen, this goes red.
        let name = Data("王小明".utf8)
        #expect(certificate.contains(subsequence: name),
                "the certificate no longer carries the name — if that is real, the holder's screen can stop saying it does")
    }

    /// Withholding must not disturb the signature. If it did, the holder would
    /// be choosing between privacy and a document that verifies.
    @Test func aPartialPresentationStillVerifiesAgainstTheCardSignature() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let holder = HolderPresentation(store: try store(for: did), loadKey: { key })

        let frames = try holder.frames(answering: Self.request(),
                                       disclosing: [AgePredicate.claimName],
                                       now: Self.issuedAt)
        let enveloped = try Self.envelopedCredential(inPresentation: try Self.presented(frames))
        let serialized = try #require(EnvelopedVerifiableCredential(
            context: "", id: enveloped, type: "").moicaSignedSerialization)

        let verified = try MOICASignedCredential.parse(serialized)
            .verify(signedBy: try X509Certificate.parse(base64DER: holderCertificateDER))

        #expect(verified.claims == [AgePredicate.claimName: "true", "name": "王小明"])
        #expect(verified.withheldClaimCount == 4)
        // True now, and it is the whole reason the name is forced: the checker
        // gets the certificate's CN compared against the document's own `name`
        // rather than a name on screen with nothing tying it to the document.
        #expect(verified.cardholderNameWasChecked)
    }

    /// Disclosing nothing is a legitimate answer to "prove you hold a document",
    /// and it must not be mistaken for a broken presentation.
    ///
    /// "Nothing" means nothing the holder could withhold. The name goes either
    /// way — this is the exact request the on-device debug check makes, and it is
    /// how the gap was found: it asked for nothing, got nothing, and the checker
    /// was left printing a name it could not tie to the document.
    @Test func disclosingNothingStillProducesAValidPresentation() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let holder = HolderPresentation(store: try store(for: did), loadKey: { key })

        let frames = try holder.frames(answering: Self.request(), disclosing: [], now: Self.issuedAt)
        let enveloped = try Self.envelopedCredential(inPresentation: try Self.presented(frames))
        let serialized = try #require(EnvelopedVerifiableCredential(
            context: "", id: enveloped, type: "").moicaSignedSerialization)

        let verified = try MOICASignedCredential.parse(serialized)
            .verify(signedBy: try X509Certificate.parse(base64DER: holderCertificateDER))

        #expect(verified.claims == ["name": "王小明"])
        #expect(verified.withheldClaimCount == 5)
        #expect(verified.cardholderNameWasChecked)
    }

    /// `nil` means everything, which is what a credential with nothing to
    /// withhold does anyway — the two must not diverge.
    @Test func passingNoChoiceDisclosesEverything() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let holder = HolderPresentation(store: try store(for: did), loadKey: { key })

        let frames = try holder.frames(answering: Self.request(), now: Self.issuedAt)
        let enveloped = try Self.envelopedCredential(inPresentation: try Self.presented(frames))
        let serialized = try #require(EnvelopedVerifiableCredential(
            context: "", id: enveloped, type: "").moicaSignedSerialization)

        let verified = try MOICASignedCredential.parse(serialized)
            .verify(signedBy: try X509Certificate.parse(base64DER: holderCertificateDER))

        #expect(verified.withheldClaimCount == 0)
        #expect(verified.claims["unifiedNo"] == "A123456789")
    }

    // MARK: What the holder is offered

    /// The choices are the document's own claims, in reading order — so the
    /// screen lists them the way an ID card is read rather than the way a
    /// dictionary iterates.
    @Test func theHolderIsOfferedEveryClaimInReadingOrder() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let holder = HolderPresentation(store: try store(for: did), loadKey: { key })

        let offered = try holder.disclosableClaims().map(\.name)

        #expect(offered.first == "nationality")
        #expect(offered.contains(AgePredicate.claimName))
        #expect(Set(offered) == ["nationality", "unifiedNo", "name", "birthdate",
                                 AgePredicate.claimName, "addressOfHousehold"])
    }

    // MARK: - Helpers

    private static func envelopedCredential(inPresentation jws: String) throws -> String {
        let segments = jws.components(separatedBy: ".")
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let data = try #require(Data(base64Encoded: base64))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let array = try #require(object?["verifiableCredential"] as? [Any])
        let first = try #require(array.first as? [String: Any])
        return try #require(first["id"] as? String)
    }
}

private final class InMemoryStore: CredentialStoring {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { Array(items.keys).sorted() }
    func delete(id: String) throws { items.removeValue(forKey: id) }
    func deleteAll() throws { items.removeAll() }
}
