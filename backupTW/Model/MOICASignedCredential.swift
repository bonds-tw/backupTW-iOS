//
//  MOICASignedCredential.swift
//  backupTW
//
//  A national-ID credential secured by the cardholder's 自然人憑證 rather than
//  by this device's own key.
//

import CryptoKit
import Foundation
import Security

// MARK: - Errors

/// Why a card-signed credential could not be produced or believed.
///
/// No case carries the credential, the certificate, or the holder's name. These
/// errors reach an alert and a support report, and a name plus a certificate is
/// a direct handle on one person.
enum MOICASignedCredentialError: Error, Equatable {

    /// The envelope's `payload` is not base64url, or its bytes are not a
    /// credential this build can decode.
    case malformedPayload

    /// `proof.tbsConstruction` names a rule this build does not implement.
    ///
    /// Refused rather than assumed. The construction decides *what* the
    /// cardholder's key covered, so guessing it wrong produces a verification
    /// that either fails on honest documents or passes on dishonest ones.
    case unsupportedProofConstruction

    /// `proof.signature` is not base64, or is not the 256 bytes an RSA-2048
    /// PKCS#1 signature occupies.
    case malformedSignature

    /// The signature does not verify under the certificate's key.
    ///
    /// **This is also what a tampered payload looks like**, and deliberately so.
    /// There is no separate "digest mismatch" case because there is no stored
    /// digest to compare against: the digest is recomputed from the payload on
    /// every verification and handed straight to the signature check. A digest
    /// carried in the envelope would be a value that can lie — the same shape of
    /// mistake as trusting a JWS header's `alg` — so it is not carried, and
    /// editing a field therefore surfaces here rather than in a case of its own.
    case signatureInvalid

    /// The certificate carries no common name, so there is nothing to check the
    /// credential's subject against.
    case cardholderNameMissing

    /// The credential asserts no `name`, so a card signature over it binds to
    /// nobody in particular.
    case credentialNameMissing

    /// The certificate's common name and the credential's `name` claim are
    /// different people.
    case cardholderNameDiffersFromSubject
}

extension MOICASignedCredentialError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .malformedPayload, .unsupportedProofConstruction, .malformedSignature:
            return NSLocalizedString("This document is in a format this app cannot read.", comment: "")
        case .signatureInvalid:
            return NSLocalizedString("This document does not match the signature on it.", comment: "")
        case .cardholderNameMissing, .credentialNameMissing, .cardholderNameDiffersFromSubject:
            return NSLocalizedString("This document was signed by a different person from the one it describes.",
                                     comment: "")
        }
    }
}

// MARK: - The envelope

/// A credential plus the 自然人憑證 signature over it.
///
/// # What this changed, and why it is not a JWS
///
/// The national-ID credential used to be secured by this device's own key. A
/// verifier who checked that signature learned only that *some device* asserted
/// these fields — the device made up the key itself, so the trust root was the
/// phone in the holder's hand. Alongside it sat a 內政部 signature, obtained for
/// the zero-knowledge holding proof, over a fixed relying-party identifier: real
/// authority, bound to nothing about the data. The two never met.
///
/// This type is the join. The cardholder's key signs a digest of the credential
/// itself, so a verifier who checks it learns that *the holder of a MOICA G3
/// certificate asserted these exact fields*.
///
/// It is deliberately **not** a compact JWS, even though the pieces nearly fit:
/// TW FidO's `PKCS#1` + `SHA256` output is byte-identical to JOSE `RS256`, so
/// setting `sign_data` to `base64(base64url(header) + "." + base64url(payload))`
/// would produce a genuine `vc+jwt`. That was not done because it depends on the
/// SP API accepting a `sign_data` of roughly a kilobyte, and the specification
/// we hold does not state a limit — so it is a thing to *measure* against the
/// real API, not to assume. Until it is measured, the TBS is a domain prefix
/// plus a 64-character digest — 87 ASCII characters, which no plausible limit
/// rejects — and the envelope is spelled as an explicit object so nothing can
/// mistake it for a JWS and hand it to a JOSE verifier that would be right to
/// reject it.
///
/// # What a card signature does and does not establish
///
/// It establishes that a MOICA G3 cardholder put their key over these values.
/// It is **not** 內政部 endorsing that the values are correct: 內政部 signed
/// what this app put in front of the card, and this app got the values from a
/// MyData download that carries no signature of its own (measured 2026-08-09).
/// The honest sentence is 「這位持卡人主張這些值」, not 「內政部背書這些值正確」,
/// and no screen may say more than that.
struct MOICASignedCredential: Codable, Equatable {

    /// base64url of the credential's canonical bytes.
    ///
    /// The bytes, not the object. A verifier recomputing the digest from a
    /// re-encoded credential would be trusting its `JSONEncoder` to emit exactly
    /// what the issuing device's did, across OS versions and Foundation
    /// rewrites. Carrying the bytes removes that dependency the same way a
    /// compact JWS does.
    let payload: String

    let proof: MOICACredentialProof

    /// The credential inside `payload`.
    ///
    /// Decoded on demand rather than stored beside the bytes, so there is no way
    /// for the two to disagree about what this document says.
    func credential() throws -> VerifiableCredential {
        guard let bytes = Self.base64URLDecoded(payload),
              let credential = try? JSONDecoder().decode(VerifiableCredential.self, from: bytes) else {
            throw MOICASignedCredentialError.malformedPayload
        }
        return credential
    }

    func payloadBytes() throws -> Data {
        guard let bytes = Self.base64URLDecoded(payload) else {
            throw MOICASignedCredentialError.malformedPayload
        }
        return bytes
    }

    /// The form that goes on disk and into a presentation.
    ///
    /// JSON rather than a dot-separated compact string, and the reason is that a
    /// compact form here would look exactly like a JWS — three base64url
    /// segments — while verifying under different rules. Anything that split it
    /// on dots and reached for a JOSE library would be holding a header that is
    /// really a payload. The object cannot be mistaken for one.
    func serialized() throws -> String {
        // Sorted so that writing the same envelope twice produces the same file,
        // which is what makes a stored credential comparable between launches.
        // Nothing signs these bytes — the signature is over `payload`'s bytes —
        // so this is reproducibility, not a security property.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func parse(_ serialized: String) throws -> MOICASignedCredential {
        guard let envelope = try? JSONDecoder().decode(MOICASignedCredential.self,
                                                       from: Data(serialized.utf8)) else {
            throw MOICASignedCredentialError.malformedPayload
        }
        return envelope
    }

    static func base64URLDecoded(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}

/// How the cardholder's signature relates to the payload.
struct MOICACredentialProof: Codable, Equatable {

    /// What the card's key actually covered, named rather than implied.
    ///
    /// A signature is meaningless without knowing what was signed, and this is
    /// the one field a future change is most likely to alter — moving to a JWS
    /// signing input, say. Spelling it out means an older build refuses a newer
    /// document instead of checking it against the wrong bytes and reporting a
    /// confident wrong answer.
    let tbsConstruction: String

    /// base64 DER of the cardholder's certificate, exactly as TW FidO's
    /// `result.cert` delivered it.
    let certificate: String

    /// base64 of TW FidO's `result.signed_response`.
    let signature: String

    /// The only construction this build implements: the TBS is
    /// `bonds-tw-credential-v1:` followed by the lowercase hex SHA-256 of the
    /// payload bytes, as ASCII, and the signature is RSASSA-PKCS1-v1_5 over
    /// SHA-256 of that ASCII string. The outer SHA-256 is the SP API's own
    /// (`hash_algorithm: "SHA256"`), so the digest is hashed twice in total —
    /// which is a fact about the API, not a design choice, and is written down
    /// here because it is exactly the kind of detail a reimplementation gets
    /// wrong once.
    static let payloadDigestHexConstruction = "bonds-tw-credential-v1/payload-sha256-hex/RSASSA-PKCS1-v1_5-SHA256"

    /// Domain separation for the TBS.
    ///
    /// **What this stops, said precisely.** Not a malicious relying party — one
    /// of those can put any `sign_data` it likes in front of the card, prefix
    /// included, and no string constant changes that. What it stops is
    /// *accidental* cross-protocol reuse: some honest-but-different service asks
    /// the same cardholder to SIGN a value that happens to be 64 hex characters
    /// — another digest scheme, a transaction hash — and without the prefix,
    /// that signature is byte-for-byte a valid `MOICASignedCredential` proof
    /// over any payload hashing to the same value. With it, a signature only
    /// verifies here if the card was shown a string that names this protocol.
    ///
    /// Added while the set of issued credentials was still empty, which is the
    /// only time a TBS change is free. Changing it later is a migration:
    /// `tbsConstruction` names this rule, and every credential signed under the
    /// old rule is refused by a build that no longer implements it.
    static let tbsDomainPrefix = "bonds-tw-credential-v1:"

    /// A PKCS#1 signature under an RSA-2048 key.
    static let signatureByteCount = 256
}

// MARK: - Issuing

extension MOICASignedCredential {

    /// Builds the envelope from a completed TW FidO SIGN round trip, and refuses
    /// to return one that does not verify.
    ///
    /// Verifying at issuance is the point. Everything that can go wrong here —
    /// a signature over a different digest because the credential was rebuilt
    /// between signing and storing, a certificate from a generation this build
    /// cannot check, a name that does not match — is silent until somebody tries
    /// to present the document, which is at a counter, to a stranger, offline.
    /// Better to fail while the holder is still looking at the screen that
    /// created it.
    static func issue(credential: VerifiableCredential,
                      payloadBytes: Data,
                      signResult: TWFidOSignResult,
                      anchor: IssuerCertificate,
                      now: Date = Date()) throws -> MOICASignedCredential {
        let signed = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(payloadBytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: signResult.cert,
                signature: signResult.signedResponse))

        _ = try signed.verify(against: anchor, now: now)
        return signed
    }

    /// The ASCII string to put in `sign_data` for `credential` — the domain
    /// prefix and the digest, already joined.
    ///
    /// Returned together with the bytes it covers so a caller cannot hash one
    /// serialization, sign it, and store another. Joined *here* rather than at
    /// the call site so there is exactly one place that knows the TBS's shape;
    /// a caller assembling it by hand is a caller who can forget the prefix,
    /// and a card signature over the bare digest verifies against nothing.
    static func toBeSigned(for credential: VerifiableCredential) throws -> (tbs: String, bytes: Data) {
        let bytes = try credential.canonicalBytes()
        return (MOICACredentialProof.tbsDomainPrefix + VerifiableCredential.digestHex(of: bytes), bytes)
    }
}

// MARK: - Verifying

/// What a verified card-signed credential turned out to say.
struct MOICACredentialVerification: Equatable {

    let credential: VerifiableCredential

    /// The cardholder's name, from the certificate's Subject DN.
    ///
    /// Equal to the credential's `name` claim — verification refuses otherwise —
    /// so this is the same string seen from the other side, and having it means
    /// a screen can say *whose* certificate signed without re-parsing the DER.
    let cardholderName: String

    /// The certificate's own serial number, lowercase hex.
    ///
    /// ⚠️ A stable per-certificate correlator, and a 自然人憑證 lasts a year.
    /// Showing it to a verifier makes two presentations linkable. It is carried
    /// because revocation checking needs it, not because it is safe to display.
    let certificateSerialNumberHex: String
}

extension MOICASignedCredential {

    /// Checks the whole chain, offline, and returns what it establishes.
    ///
    /// Admitting the certificate comes first because it is the check with the
    /// most actionable failure: a 自然人憑證 lasts one year, and "your card
    /// expired" is something the holder can go and fix, where the rest are
    /// either format errors or evidence of tampering.
    ///
    /// - Note: this establishes nothing about revocation. The certificate may
    ///   have been revoked this morning and every step still passes.
    @discardableResult
    func verify(against anchor: IssuerCertificate,
                now: Date = Date()) throws -> MOICACredentialVerification {
        let holder = try anchor.validateHolderCertificate(base64DER: proof.certificate, now: now)
        return try verify(signedBy: holder)
    }

    /// Everything the trust anchor is not needed for.
    ///
    /// Split out so it can be driven by a test. Reaching the bundled MOICA G3
    /// anchor requires a certificate MOICA actually signed, and the only one of
    /// those available is a real person's — which is not something to check into
    /// a repository. What this half contains is the logic that is this project's
    /// own, and it is all reachable with a throwaway key:
    ///
    ///   1. **Decode the payload.** Everything after reasons about a credential.
    ///   2. **Pin the TBS construction**, before any cryptography, so a newer
    ///      document is refused rather than checked against assumed bytes.
    ///   3. **Recompute the digest** — the case this whole type exists for:
    ///      fields edited after the card signed them.
    ///   4. **Verify the signature** under the certificate's key.
    ///   5. **Bind the signer to the subject**, the only check about meaning
    ///      rather than mathematics.
    ///
    /// ⚠️ Never call this directly from a verification path. On its own it
    /// establishes that *some* certificate signed these fields, and the holder
    /// chooses which certificate travels in the envelope — so without the anchor
    /// step it accepts a credential signed by a key the holder generated a
    /// moment ago.
    @discardableResult
    func verify(signedBy holder: X509Certificate) throws -> MOICACredentialVerification {
        let bytes = try payloadBytes()
        let credential = try self.credential()

        guard proof.tbsConstruction == MOICACredentialProof.payloadDigestHexConstruction else {
            throw MOICASignedCredentialError.unsupportedProofConstruction
        }

        let digest = VerifiableCredential.digestHex(of: bytes)

        guard let signature = Data(base64Encoded: proof.signature),
              signature.count == MOICACredentialProof.signatureByteCount else {
            throw MOICASignedCredentialError.malformedSignature
        }

        // The signed bytes are the domain-prefixed digest *string*, not the
        // digest's raw bytes: `sign_data` was `base64(ASCII(prefix+digest))` and
        // `tbs_encoding: "base64"` describes only that wrapper. Signing the 32
        // raw bytes — or the bare digest without its prefix — would verify
        // against nothing, and would do so identically on every input, which is
        // the sort of failure that looks like a bad certificate.
        let tbs = MOICACredentialProof.tbsDomainPrefix + digest
        guard try holder.verifiesPKCS1SHA256(signature, over: Data(tbs.utf8)) else {
            throw MOICASignedCredentialError.signatureInvalid
        }

        guard let cardholderName = try holder.subjectAttribute(.commonName) else {
            throw MOICASignedCredentialError.cardholderNameMissing
        }
        guard let subjectName = credential.credentialSubject["name"], !subjectName.isEmpty else {
            throw MOICASignedCredentialError.credentialNameMissing
        }
        // Compared after canonical composition. A name typed into a government
        // form, extracted from a PDF's text layer, and encoded into a DER
        // DirectoryString has passed through three systems with their own ideas
        // about how a CJK character is composed; NFC is what makes those three
        // agree without weakening the comparison to a prefix or a fold.
        guard cardholderName.precomposedStringWithCanonicalMapping
                == subjectName.precomposedStringWithCanonicalMapping else {
            // ⚠️ If this ever fires on a genuine document, suspect the
            // comparison before suspecting the holder: the certificate's common
            // name may carry a disambiguating suffix for duplicate names, which
            // has not been measured against more than one real certificate.
            throw MOICASignedCredentialError.cardholderNameDiffersFromSubject
        }

        return MOICACredentialVerification(credential: credential,
                                           cardholderName: cardholderName,
                                           certificateSerialNumberHex: holder.serialNumberHex)
    }
}
