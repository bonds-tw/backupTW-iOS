//
//  MOICASignedCredentialTests.swift
//  backupTWTests
//
//  The half of card-signed verification that does not need the MOICA anchor.
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

// MARK: - Tests

struct MOICASignedCredentialTests {

    private static let subjectDID = "did:key:zDnaerDaTF5BXEavCrfRZEk316dpbLsfPDZ3WJ5hRTPFU2169"

    /// A credential whose `name` matches the fixture certificate's common name.
    private func credential(name: String = "王小明",
                            birthdate: String = "0700101") -> VerifiableCredential {
        VerifiableCredential(
            context: [.url(VerifiableCredential.credentialsV2Context),
                      .definitions(VerifiableCredential.nationalIDTermDefinitions)],
            type: [VerifiableCredential.baseType, VerifiableCredential.nationalIDType],
            issuer: Self.subjectDID,
            validFrom: "2026-08-09T12:00:00Z",
            credentialSubject: ["id": Self.subjectDID,
                                "nationality": "中華民國（臺灣）",
                                "name": name,
                                "birthdate": birthdate])
    }

    private func holderCertificate() throws -> X509Certificate {
        try X509Certificate.parse(base64DER: holderCertificateDER)
    }

    /// Builds the envelope the way issuance does, signing whatever bytes are
    /// passed rather than re-deriving them.
    private func sign(_ bytes: Data,
                      certificate: String = holderCertificateDER,
                      construction: String = MOICACredentialProof.payloadDigestHexConstruction)
        throws -> MOICASignedCredential {
        let tbs = MOICACredentialProof.tbsDomainPrefix + VerifiableCredential.digestHex(of: bytes)
        let signature = try cardSignature(over: Data(tbs.utf8))
        return MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(tbsConstruction: construction,
                                        certificate: certificate,
                                        signature: signature.base64EncodedString()))
    }

    // MARK: The happy path

    @Test func aCardSignatureOverTheCredentialVerifies() throws {
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let signed = try sign(bytes)

        let verified = try signed.verify(signedBy: try holderCertificate())

        #expect(verified.cardholderName == "王小明")
        #expect(verified.credential.credentialSubject["birthdate"] == "0700101")
    }

    /// The signature really is 256 bytes of RSA-2048 PKCS#1, the same shape
    /// `result.signed_response` arrives in.
    @Test func theFixtureSignatureHasTheShapeTheSPAPIReturns() throws {
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let signed = try sign(bytes)
        let raw = try #require(Data(base64Encoded: signed.proof.signature))

        #expect(raw.count == MOICACredentialProof.signatureByteCount)
    }

    // MARK: What the binding is for

    /// The whole reason this type exists: a field edited after the card signed
    /// must not survive verification.
    ///
    /// It surfaces as `.signatureInvalid` rather than a tampering-specific case,
    /// and that is the design. The digest is never carried in the envelope — it
    /// is recomputed from the payload and handed to the signature check — so
    /// there is no stored value for an edited payload to disagree with. This
    /// test originally expected a `.digestMismatch` case, and finding that no
    /// code path could ever throw it is why that case no longer exists.
    @Test func aFieldChangedAfterSigningIsRejected() throws {
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let signed = try sign(bytes)

        // Same signature, same certificate, one different claim.
        let (_, forged) = try MOICASignedCredential.toBeSigned(for: credential(birthdate: "0600101"))
        let tampered = MOICASignedCredential(payload: VerifiableCredential.base64URLEncoded(forged),
                                             proof: signed.proof)

        #expect(throws: MOICASignedCredentialError.signatureInvalid) {
            try tampered.verify(signedBy: try self.holderCertificate())
        }
    }

    /// A signature that is mathematically valid and still the wrong person.
    ///
    /// The two fixture certificates wrap the same key, so every cryptographic
    /// step passes under either. Only the name check separates them — and
    /// without it, any cardholder could sign anybody's field facts.
    @Test func aCertificateNamingADifferentCardholderIsRejected() throws {
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let signed = try sign(bytes, certificate: otherCardholderCertificateDER)
        let other = try X509Certificate.parse(base64DER: otherCardholderCertificateDER)

        // The signature does verify under that certificate's key…
        let tbs = MOICACredentialProof.tbsDomainPrefix + VerifiableCredential.digestHex(of: bytes)
        let raw = try #require(Data(base64Encoded: signed.proof.signature))
        #expect(try other.verifiesPKCS1SHA256(raw, over: Data(tbs.utf8)))

        // …and the credential is still refused.
        #expect(throws: MOICASignedCredentialError.cardholderNameDiffersFromSubject) {
            try signed.verify(signedBy: other)
        }
    }

    @Test func aCredentialWithoutANameCannotBeBoundToACardholder() throws {
        let nameless = VerifiableCredential(
            context: [.url(VerifiableCredential.credentialsV2Context)],
            type: [VerifiableCredential.baseType],
            issuer: Self.subjectDID,
            validFrom: "2026-08-09T12:00:00Z",
            credentialSubject: ["id": Self.subjectDID, "birthdate": "0700101"])
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: nameless)
        let signed = try sign(bytes)

        #expect(throws: MOICASignedCredentialError.credentialNameMissing) {
            try signed.verify(signedBy: try self.holderCertificate())
        }
    }

    // MARK: What was signed

    /// The card signs the digest as an **ASCII string**, not as 32 raw bytes.
    ///
    /// Both are 一個 SHA-256 of the payload; only one is what `sign_data =
    /// base64(ASCII(digest))` produced. Getting it wrong yields a signature that
    /// fails on every input, which reads like a bad certificate rather than like
    /// a wrong TBS.
    @Test func signingTheRawDigestBytesInsteadOfTheHexStringDoesNotVerify() throws {
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let rawDigestBytes = Data(SHA256.hash(data: bytes))
        let wrong = try cardSignature(over: rawDigestBytes)

        let signed = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: wrong.base64EncodedString()))

        #expect(tbs.count == MOICACredentialProof.tbsDomainPrefix.count + 64)
        #expect(throws: MOICASignedCredentialError.signatureInvalid) {
            try signed.verify(signedBy: try self.holderCertificate())
        }
    }

    /// The domain-separation property itself: a signature over the *bare*
    /// digest — no `bonds-tw-credential-v1:` prefix — must not verify.
    ///
    /// This is the exact artefact an honest-but-different service produces if it
    /// ever asks the same cardholder to SIGN a 64-hex-character value of its
    /// own. Without the prefix check, that signature is byte-for-byte a valid
    /// proof over any payload hashing to the same value; the prefix is the only
    /// thing making the card's signature *mean* "a bonds-tw credential".
    @Test func aSignatureOverTheUnprefixedDigestIsRejected() throws {
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let bareDigest = String(tbs.dropFirst(MOICACredentialProof.tbsDomainPrefix.count))
        let foreign = try cardSignature(over: Data(bareDigest.utf8))

        let signed = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: foreign.base64EncodedString()))

        // The dropped prefix really was the only difference.
        #expect(bareDigest.count == 64)
        #expect(throws: MOICASignedCredentialError.signatureInvalid) {
            try signed.verify(signedBy: try self.holderCertificate())
        }
    }

    /// The digest covers the bytes the envelope carries, not a re-encoding of
    /// the decoded credential.
    ///
    /// The payload here is deliberately *not* what `canonicalBytes()` would
    /// emit — the keys are in source order and there is whitespace — yet it
    /// decodes to the same credential. A verifier that re-encoded before hashing
    /// would reject this, and would then also reject honest credentials the day
    /// Foundation changes how it serialises anything.
    @Test func theDigestCoversTheCarriedBytes_notAReEncoding() throws {
        let handwritten = """
        {
          "type": ["VerifiableCredential"],
          "issuer": "\(Self.subjectDID)",
          "validFrom": "2026-08-09T12:00:00Z",
          "@context": ["https://www.w3.org/ns/credentials/v2"],
          "credentialSubject": {"name": "王小明", "id": "\(Self.subjectDID)"}
        }
        """
        let bytes = Data(handwritten.utf8)
        let decoded = try JSONDecoder().decode(VerifiableCredential.self, from: bytes)

        // These bytes are genuinely not the canonical ones…
        #expect(try decoded.canonicalBytes() != bytes)

        // …and a signature over their digest still verifies.
        let signed = try sign(bytes)
        let verified = try signed.verify(signedBy: try holderCertificate())
        #expect(verified.credential.credentialSubject["name"] == "王小明")
    }

    // MARK: Refusing what it cannot check

    @Test func anUnrecognisedTBSConstructionIsRefusedRatherThanGuessed() throws {
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let signed = try sign(bytes, construction: "jws-signing-input/RS256")

        #expect(throws: MOICASignedCredentialError.unsupportedProofConstruction) {
            try signed.verify(signedBy: try self.holderCertificate())
        }
    }

    @Test func aSignatureOfTheWrongLengthIsRejectedBeforeAnyCrypto() throws {
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let signed = try sign(bytes)
        let truncated = MOICASignedCredential(
            payload: signed.payload,
            proof: MOICACredentialProof(tbsConstruction: signed.proof.tbsConstruction,
                                        certificate: signed.proof.certificate,
                                        signature: String(signed.proof.signature.dropLast(8))))

        #expect(throws: MOICASignedCredentialError.malformedSignature) {
            try truncated.verify(signedBy: try self.holderCertificate())
        }
    }

    @Test func aPayloadThatIsNotACredentialIsRejected() throws {
        let signed = try sign(Data("not a credential".utf8))

        #expect(throws: MOICASignedCredentialError.malformedPayload) {
            try signed.verify(signedBy: try self.holderCertificate())
        }
    }

    // MARK: Round trip

    @Test func theEnvelopeSurvivesBeingWrittenAndReadBack() throws {
        let (_, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let signed = try sign(bytes)

        let encoded = try JSONEncoder().encode(signed)
        let decoded = try JSONDecoder().decode(MOICASignedCredential.self, from: encoded)

        #expect(decoded == signed)
        #expect(try decoded.verify(signedBy: try holderCertificate()).cardholderName == "王小明")
    }
}
