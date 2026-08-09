//
//  MOICASignedCredentialTests.swift
//  backupTWTests
//
//  The half of card-signed verification that does not need the MOICA anchor.
//

import CryptoKit
import Foundation
import Security
import Testing
@testable import backupTW

// MARK: - Fixtures
//
// An RSA-2048 key pair and two self-signed certificates over it, produced by
// OpenSSL 3.6.2:
//
//   openssl genrsa -out holder.pem 2048
//   openssl req -new -x509 -key holder.pem -sha256 -days 3650 -utf8 \
//     -subj "/C=TW/CN=王小明/serialNumber=1234567890123456" -out holder.crt
//   openssl req -new -x509 -key holder.pem -sha256 -days 3650 -utf8 \
//     -subj "/C=TW/CN=陳小美/serialNumber=9999888877776666" -out other.crt
//   openssl rsa -in holder.pem -outform DER -traditional -out holderKey.der
//
// The second certificate wraps **the same key** under a different name. That is
// what makes the holder-binding test meaningful: the signature verifies
// mathematically against both, so only the name check can tell them apart.
//
// Signatures are not baked in — the tests produce them with
// `SecKeyCreateSignature` over whatever payload the case needs, which is the
// same primitive 內政部's HSM applies (`sign_type: "PKCS#1"`,
// `hash_algorithm: "SHA256"`). Nothing here is hand-assembled DER.
//
// ⚠️ This private key is a throwaway generated for these tests. It signs no
// credential anyone holds and belongs to no cardholder.

private let holderCertificateDER = """
MIIDWTCCAkGgAwIBAgIUcUuFMu2tcgc7snSfqwJR56oFF+swDQYJKoZIhvcNAQELBQAwPDELMAkGA1UEBhMCVFcxEjAQ\
BgNVBAMMCeeOi+Wwj+aYjjEZMBcGA1UEBRMQMTIzNDU2Nzg5MDEyMzQ1NjAeFw0yNjA4MDkxMjM1NDZaFw0zNjA4MDYx\
MjM1NDZaMDwxCzAJBgNVBAYTAlRXMRIwEAYDVQQDDAnnjovlsI/mmI4xGTAXBgNVBAUTEDEyMzQ1Njc4OTAxMjM0NTYw\
ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC3Kh2Z54eC8PdyFME3GSVU2hAjgYEkOvmm6MxR1UvvBsNjvblf\
q0lirzbNWrwu1LfiLGSXq/QG0ml4+VRZGjd062ScTCe/3fW1soRtG33GEdG+KfV91vdwSCP4q4mMTuoXA42yTqatgRs2\
zKw6uOpYgRMmAGZ2MGilxjK9/+A8mWFjb6CrYNnUJWMxGGy9LlozWiLRuKgctoPnqwTV3EO2Pf5yvYUsrnQ6CVqLKg1E\
WoreNkmywn/oHQr952n1sgPKKQkm5KC8js3gRY2Yi/HXEI2Mv2SK5HtLdGc7Ht9LxvhMZIWKZcN230J+QnULpYM7mKkT\
dhKPacylvR6t3B4FAgMBAAGjUzBRMB0GA1UdDgQWBBQbLlsuRhIWnr0Kj8Qo8pj2GM2tyjAfBgNVHSMEGDAWgBQbLlsu\
RhIWnr0Kj8Qo8pj2GM2tyjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAmPGGksLuFM48sfjqEqju3\
vaHxLaJXVFFklX5kqE/jimr6JzdGZ7anAP/wD4uFtHOYhfj/1gUlQFm0nRH92UcqrDxEBW1u2pYh630RArtvbRnzje/G\
SvVyGwaFL5tKuFmRD7Fgj1Vhxze1939u3/wtv4L7S1JptKGaeVUFD9WMn+Sz/LXsoQeIA6MIsPvFZ3NbuFRCfASB1y6q\
+wmtS8LF7ePZlpbadAK82GlAIl7thXiAMRkh+U710esr/wLRrRTybYCgwrK6GaoU2/ghvF5x9hsdhWagYc0Zik/5PiCZ\
dcuAw2FBNs/fyGWDgTQdk6sG5RbfXK+c/HTptxZ6WJq8
"""

/// The same key, certified under a different name.
private let otherCardholderCertificateDER = """
MIIDWTCCAkGgAwIBAgIUccmEYQ8Yr3pQ8XDkg929ehTPt1YwDQYJKoZIhvcNAQELBQAwPDELMAkGA1UEBhMCVFcxEjAQ\
BgNVBAMMCemZs+Wwj+e+jjEZMBcGA1UEBRMQOTk5OTg4ODg3Nzc3NjY2NjAeFw0yNjA4MDkxMjM1NDZaFw0zNjA4MDYx\
MjM1NDZaMDwxCzAJBgNVBAYTAlRXMRIwEAYDVQQDDAnpmbPlsI/nvo4xGTAXBgNVBAUTEDk5OTk4ODg4Nzc3NzY2NjYw\
ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC3Kh2Z54eC8PdyFME3GSVU2hAjgYEkOvmm6MxR1UvvBsNjvblf\
q0lirzbNWrwu1LfiLGSXq/QG0ml4+VRZGjd062ScTCe/3fW1soRtG33GEdG+KfV91vdwSCP4q4mMTuoXA42yTqatgRs2\
zKw6uOpYgRMmAGZ2MGilxjK9/+A8mWFjb6CrYNnUJWMxGGy9LlozWiLRuKgctoPnqwTV3EO2Pf5yvYUsrnQ6CVqLKg1E\
WoreNkmywn/oHQr952n1sgPKKQkm5KC8js3gRY2Yi/HXEI2Mv2SK5HtLdGc7Ht9LxvhMZIWKZcN230J+QnULpYM7mKkT\
dhKPacylvR6t3B4FAgMBAAGjUzBRMB0GA1UdDgQWBBQbLlsuRhIWnr0Kj8Qo8pj2GM2tyjAfBgNVHSMEGDAWgBQbLlsu\
RhIWnr0Kj8Qo8pj2GM2tyjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQA6g93vqtj1Db8r124CSk8B\
C8FW4c/341psNo4zpaf44wJ91YxpwlHNlpEWgE5J/wqLwGTQH3aPBIAxjPfYNXrz4J12wET7KQrjcEGw3FeG+DbmpZAg\
VL6LzJg6kwZkQnlHBhZKd3sQbvDpRkxC3M2x5eJRRAUM66e1aQutIdMVNlRFTLId1dfZUpa1v+i1Ju6kf7zJgffJ0XDL\
0+/EUv5MghHftjVyRV2vQu3W6PyRwqg3X4U0UvbP26oc22s41Kj1zvdwEM1LLCSiP0a8szMw16ZmagaxrG/rS7xCbczY\
ktJyjgPj99w/s9t1v7MZavTmZu+HqcBDmcduyKl/odM+
"""

private let holderPrivateKeyPKCS1DER = """
MIIEowIBAAKCAQEAtyodmeeHgvD3chTBNxklVNoQI4GBJDr5pujMUdVL7wbDY725X6tJYq82zVq8LtS34ixkl6v0BtJp\
ePlUWRo3dOtknEwnv931tbKEbRt9xhHRvin1fdb3cEgj+KuJjE7qFwONsk6mrYEbNsysOrjqWIETJgBmdjBopcYyvf/g\
PJlhY2+gq2DZ1CVjMRhsvS5aM1oi0bioHLaD56sE1dxDtj3+cr2FLK50OglaiyoNRFqK3jZJssJ/6B0K/edp9bIDyikJ\
JuSgvI7N4EWNmIvx1xCNjL9kiuR7S3RnOx7fS8b4TGSFimXDdt9CfkJ1C6WDO5ipE3YSj2nMpb0erdweBQIDAQABAoIB\
ACF0PcfYc/XEkU1y4P9xRlJDKeNySeYWJ3cG2hqwPJhBwfo7stn4bQTrP7UuN2TOUW+r8AuLypxcXgtMbs1/blWakNvD\
RRdUMQaovms3NDezFX4IJ+B+HN+TLY7DtfG8kCD38y94EhVqmU/e/i4TjCnyGU89j3lSyipNEwOE8q3eflQ3AjFLREAR\
tnA9qbu4n5bcXTfnw7PYQ7czKXXoO5r+gnpf9vMO2ee5Zw93D8yI2HCxSwrHqCBqmpfO7KvmrrDkRdUotA52NtRDoNdF\
hBwYv/8nFtwe8oYKio+FYNoUlFgjcS50XlXN+SgEJP6UbI/HLx6aSn9RBJJQeVHmd1kCgYEA8G2+hICy10A34b3lx+Ig\
uSXVw4VK1w8ugM/21t5z9uhWRgvl8+fsnzEeDwhnKr2DBRTBUhq080YTaSGElmx3NRb+zkEkRu15pwQKsR1/Mq/CD5rx\
tsqEb26tAKFZPx7HZUJdl/gOtl7gA+gL8laXZZYAoI4vKxkUB+vGiM7fceMCgYEAwwbxmplYurCLSV/ykdWn+JQgaJ4Q\
ELVVNNmI9s7zPTVfPbVHhToyQ2vTlORIT7yCS/eHn0PRF0K48I40yqoNBunaDo2rR7vJM3ffjwqMLrcixn2ba2I8D1lF\
JG23arho37eFd4TKWhUf5yhioZ34RuBT1T1YKUGl+Kr4WNM6lPcCgYEAzxl5NqG1a3zBpg3xVFAQZ+uTSqwSX1WQdRyu\
Pz+3HEPdrNCq74IjbKzee4x9cW904HeUXqjqnXMLXU+l6fzcYjrAmeG64e3FEHyGyTHjU0HaI58P/qhLk8D9/MD/I0Pb\
9flIrZLa+XSX+kVzpPe5yaOAPsy7DKC5hGkvxsCL8IkCgYAv4Ax/PxWg/qWypXMOibxqMTKje+nFsD3yc1REAhmD9Q4k\
P9QGyHp+QoH2EvQNXuE9dM4+Mo+pfh+YLdCXz5bTE6UL3YsmWNrTX6Hpo1U2Qo6u2zbD7aGAwxFOGADmmc5k3NBOvrJN\
2tGyFR/hPL4t5/OsbRqvRgZQPOgqJfBDkQKBgB2S0heZuXj7h1zeJ7hTJ2Vk4kt8Xzik2tKcInXD0AwT2+EEumbewalh\
lpK2VQkn8oUnTcKfkxO+Zwmvcr56QTityTAIbdKZOuJlzHm+oGaKwxwVw9z7R1bkvTNCMCEBebt5fN/iMcIyW3WRCTj4\
+Sm/7KFDm8x9PmxnCkCjqLrV
"""

private enum FixtureError: Error {
    case keyUnavailable
    case signingFailed
}

/// Signs with the throwaway key, using the same primitive the SP API applies.
private func cardSignature(over message: Data) throws -> Data {
    guard let der = Data(base64Encoded: holderPrivateKeyPKCS1DER) else {
        throw FixtureError.keyUnavailable
    }
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits: 2048,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
        error?.release()
        throw FixtureError.keyUnavailable
    }
    guard let signature = SecKeyCreateSignature(key,
                                                .rsaSignatureMessagePKCS1v15SHA256,
                                                message as CFData,
                                                &error) else {
        error?.release()
        throw FixtureError.signingFailed
    }
    return signature as Data
}

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
        let digest = VerifiableCredential.digestHex(of: bytes)
        let signature = try cardSignature(over: Data(digest.utf8))
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
        let digest = VerifiableCredential.digestHex(of: bytes)
        let raw = try #require(Data(base64Encoded: signed.proof.signature))
        #expect(try other.verifiesPKCS1SHA256(raw, over: Data(digest.utf8)))

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
        let (digest, bytes) = try MOICASignedCredential.toBeSigned(for: credential())
        let rawDigestBytes = Data(SHA256.hash(data: bytes))
        let wrong = try cardSignature(over: rawDigestBytes)

        let signed = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: wrong.base64EncodedString()))

        #expect(digest.count == 64)
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
