//
//  CardSignedPresentationTests.swift
//  backupTWTests
//
//  Presenting and checking a credential secured by the holder's 自然人憑證.
//

import Foundation
import Security
import Testing
@testable import backupTW

// MARK: - What cannot be tested here, and why it is said out loud
//
// There is no end-to-end happy path in this file, and that is a limitation
// rather than an oversight. `OfflineVerifier` admits a card-signed credential
// only if its certificate chains to the bundled MOICA G3 anchor, and
// `IssuerCertificate` pins that anchor by SHA-256 — deliberately, so a test
// cannot substitute a CA of its own. The only certificates that satisfy it are
// ones 內政部 issued to a real person, and a real person's 自然人憑證 is not
// something to check into a repository.
//
// So the split is:
//
//   * everything this project decides — digest construction, what was signed,
//     the holder-to-subject binding — is covered by `MOICASignedCredentialTests`
//     against a throwaway key, including the mutation cases;
//   * the *plumbing* — which media type a presentation carries, which verifier
//     branch it reaches, and that a certificate MOICA did not sign is refused —
//     is covered below;
//   * the anchor step itself is exercised only on device, against a real card.
//
// Anyone reading a green run here should not conclude the card path is proven.

private let deviceKeyTag = "tw.bonds.backupTW.tests.cardsigned"

/// Reuses the RSA fixture from `MOICASignedCredentialTests` by rebuilding the
/// envelope the same way; the certificate is a self-signed throwaway, so it is
/// exactly what a verifier must refuse.
private func cardSignedEnvelope(subjectDID: String) throws -> MOICASignedCredential {
    let credential = VerifiableCredential(
        context: [.url(VerifiableCredential.credentialsV2Context),
                  .definitions(VerifiableCredential.nationalIDTermDefinitions)],
        type: [VerifiableCredential.baseType, VerifiableCredential.nationalIDType],
        issuer: subjectDID,
        validFrom: "2026-08-09T12:00:00Z",
        credentialSubject: ["id": subjectDID, "name": "王小明", "birthdate": "0700101"])
    let (digest, bytes) = try MOICASignedCredential.toBeSigned(for: credential)
    return MOICASignedCredential(
        payload: VerifiableCredential.base64URLEncoded(bytes),
        proof: MOICACredentialProof(
            tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
            certificate: holderCertificateDER,
            signature: try cardSignature(over: Data(digest.utf8)).base64EncodedString()))
}

struct CardSignedPresentationTests {

    // MARK: Media type

    @Test func aCardSignedEnvelopeRoundTripsThroughItsDataURI() throws {
        let envelope = try cardSignedEnvelope(subjectDID: Self.did()).serialized()
        let enveloped = EnvelopedVerifiableCredential.enveloping(moicaSigned: envelope)

        #expect(enveloped.id.hasPrefix(EnvelopedVerifiableCredential.moicaSignedPrefix))
        #expect(enveloped.moicaSignedSerialization == envelope)
    }

    /// The two media types must not be readable as each other. A card-signed
    /// envelope handed to a JOSE parser is the type-confusion this separation
    /// exists to prevent, and the accessor is the only thing standing in the way.
    @Test func aCardSignedEnvelopeIsNotReadableAsACompactJWS() throws {
        let enveloped = EnvelopedVerifiableCredential.enveloping(
            moicaSigned: try cardSignedEnvelope(subjectDID: Self.did()).serialized())

        #expect(enveloped.compactJWS == nil)
    }

    @Test func aDeviceSignedEnvelopeIsNotReadableAsACardSignedOne() {
        let enveloped = EnvelopedVerifiableCredential.enveloping(compactJWS: "aGVhZGVy.cGF5bG9hZA.c2ln")

        #expect(enveloped.moicaSignedSerialization == nil)
        #expect(enveloped.compactJWS == "aGVhZGVy.cGF5bG9hZA.c2ln")
    }

    // MARK: Presenting

    @Test func aCardSignedCredentialIsPresentedUnderItsOwnMediaType() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let stored = try cardSignedEnvelope(subjectDID: did).serialized()

        let jws = try VerifiablePresentation.create(credentialJWS: stored,
                                                    request: try Self.request(),
                                                    signedBy: key,
                                                    holderDID: did)

        let enveloped = try Self.envelopedCredential(inPresentation: jws)
        #expect(enveloped.hasPrefix(EnvelopedVerifiableCredential.moicaSignedPrefix))
        // Not the JWS prefix, which is what a fallthrough would have produced.
        #expect(enveloped.hasPrefix(EnvelopedVerifiableCredential.compactJWSPrefix) == false)
    }

    /// Holder binding applies to the card-signed form too. Without this check a
    /// copied credential file plus the thief's own presentation key verifies.
    @Test func aCardSignedCredentialAboutSomebodyElseIsRefused() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let someoneElse = "did:key:zDnaerDaTF5BXEavCrfRZEk316dpbLsfPDZ3WJ5hRTPFU2169"
        let stored = try cardSignedEnvelope(subjectDID: someoneElse).serialized()

        #expect(throws: VerifiablePresentationError.credentialSubjectMismatch) {
            _ = try VerifiablePresentation.create(credentialJWS: stored,
                                                  request: try Self.request(),
                                                  signedBy: key,
                                                  holderDID: did)
        }
    }

    // MARK: Verifying

    /// The dispatch reaches the certificate branch, and a certificate 內政部
    /// never signed is refused there.
    ///
    /// The specific failure matters as much as the refusal. Landing on
    /// `.credentialIsNotAJWS` or `.credentialNotEnveloped` would mean the media
    /// type never routed anywhere, and the branch under test was not entered at
    /// all — a green "it was rejected" that proves nothing.
    @Test func aCredentialSignedByANonMOICACertificateIsRefusedByTheCertificateCheck() throws {
        defer { try? DeviceKey.deleteKey(tag: deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let request = try Self.request()
        let jws = try VerifiablePresentation.create(
            credentialJWS: try cardSignedEnvelope(subjectDID: did).serialized(),
            request: request,
            signedBy: key,
            holderDID: did)

        let outcome = OfflineVerifier.verify(presentationJWS: jws, against: request)

        #expect(outcome == .rejected(.cardholderCertificateUnusable))
    }

    // MARK: - Helpers

    private static func did() throws -> String {
        "did:key:zDnaerDaTF5BXEavCrfRZEk316dpbLsfPDZ3WJ5hRTPFU2169"
    }

    private static func request() throws -> PresentationRequest {
        try PresentationRequest(challenge: "Q0hBTExFTkdFLTAwMDAwMA",
                                purpose: "里長辦公室核對受災戶身分",
                                createdAt: Date(),
                                audience: "urn:bonds-tw:verifier:test")
    }

    /// Reads the enveloped credential's `id` straight out of the presentation's
    /// payload segment, without going through the verifier — the point is to see
    /// what was written, not what a reader makes of it.
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
