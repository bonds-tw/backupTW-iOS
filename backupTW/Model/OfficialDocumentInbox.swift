//
//  OfficialDocumentInbox.swift
//  backupTW
//
//  Domain objects for the personal electronic official-document inbox.
//

import CryptoKit
import Foundation
import Security

enum OfficialDocumentInboxError: Error, Equatable {
    case randomUnavailable
    case receiptMetadataInvalid
    case malformedSignature
    case signatureInvalid
}

extension OfficialDocumentInboxError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .randomUnavailable:
            return NSLocalizedString("A secure signing request could not be created.", comment: "official document inbox")
        case .receiptMetadataInvalid:
            return NSLocalizedString("The stored consent evidence has invalid metadata, so it cannot be trusted.", comment: "official document inbox")
        case .malformedSignature, .signatureInvalid:
            return NSLocalizedString("The signature that came back does not match this consent, so it was not saved.", comment: "official document inbox")
        }
    }
}

/// The exact consent the holder asks 行動自然人憑證 to sign before joining an
/// electronic-official-document pilot.
///
/// This is intentionally **prototype-only**. It does not allocate a government
/// mailbox, opt the holder into any agency's legal-delivery policy, or claim that
/// a document delivered to this app has legal effect. Those steps require the
/// Archives Administration's G2C exchange service and a policy version issued by
/// the responsible agency. Keeping the scope in the signed bytes prevents a
/// later backend from misreading today's local prototype signature as that future
/// official enrolment.
struct OfficialDocumentInboxConsent: Codable, Equatable, Sendable {
    static let version = "bonds-tw-official-document-inbox-consent-v1"
    static let scope = "local-prototype-only"
    static let tbsDomainPrefix = "bonds-tw-official-document-consent-v1:"

    let createdAt: Date
    /// 256 bits of caller-generated randomness, base64url without padding.
    let nonce: String

    init(createdAt: Date, nonce: String) {
        self.createdAt = createdAt
        self.nonce = nonce
    }

    static func make(createdAt: Date = Date()) throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OfficialDocumentInboxError.randomUnavailable
        }
        let nonce = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self(createdAt: createdAt, nonce: nonce)
    }

    /// A deliberately tiny, deterministic form. It contains no national ID
    /// number and no mailbox address; `id_num` is transport-only input to TW
    /// FidO and must not be persisted inside the consent.
    var canonicalBytes: Data {
        let milliseconds = Int64((createdAt.timeIntervalSince1970 * 1_000).rounded(.down))
        return Data("version=\(Self.version)\nscope=\(Self.scope)\ncreated_at_unix_ms=\(milliseconds)\nnonce=\(nonce)\n".utf8)
    }

    var signingTarget: String {
        let digest = SHA256.hash(data: canonicalBytes)
            .map { String(format: "%02x", $0) }.joined()
        return Self.tbsDomainPrefix + digest
    }

    /// The structured form a Release signing broker needs in order to rebuild
    /// the digest instead of accepting an arbitrary caller-chosen string.
    var signingDescriptor: TWFidOOfficialDocumentConsentTarget {
        TWFidOOfficialDocumentConsentTarget(
            version: Self.version,
            scope: Self.scope,
            createdAtUnixMilliseconds: Int64(
                (createdAt.timeIntervalSince1970 * 1_000).rounded(.down)),
            nonce: nonce,
            toBeSigned: signingTarget)
    }
}

/// The local evidence that the 行動自然人憑證 round trip completed for one
/// prototype consent. The raw ID number and TW FidO's stable `hashed_id_num` are
/// both deliberately absent.
struct OfficialDocumentInboxReceipt: Codable, Equatable, Sendable {
    static let tbsConstruction = "bonds-tw-official-document-consent-v1/payload-sha256-hex/RSASSA-PKCS1-v1_5-SHA256"
    /// The signing session is currently limited to ten minutes. Allow five
    /// additional minutes for callback and persistence, but do not let an
    /// editable local `recordedAt` move certificate validation to an arbitrary
    /// point in history.
    private static let maximumRecordingDelay: TimeInterval = 15 * 60

    enum Environment: String, Codable, Sendable {
        case localPrototypeOnly
    }

    let environment: Environment
    let consent: OfficialDocumentInboxConsent
    let tbsConstruction: String
    let certificate: String
    let signature: String
    let recordedAt: Date

    init(environment: Environment = .localPrototypeOnly,
         consent: OfficialDocumentInboxConsent,
         tbsConstruction: String = Self.tbsConstruction,
         certificate: String,
         signature: String,
         recordedAt: Date) {
        self.environment = environment
        self.consent = consent
        self.tbsConstruction = tbsConstruction
        self.certificate = certificate
        self.signature = signature
        self.recordedAt = recordedAt
    }

    /// SHA-256 identifiers let a holder compare the exact evidence without
    /// exposing the certificate or signature bytes in the UI, logs or sharing.
    var consentFingerprint: String { String(consent.signingTarget.dropFirst(
        OfficialDocumentInboxConsent.tbsDomainPrefix.count)) }

    var certificateFingerprint: String? {
        guard let data = Data(base64Encoded: certificate) else { return nil }
        return Self.sha256(data)
    }

    var signatureFingerprint: String? {
        guard let data = Data(base64Encoded: signature) else { return nil }
        return Self.sha256(data)
    }

    /// Refuses to create a receipt until both the MOICA G3 chain and the returned
    /// signature over these exact consent bytes verify. This still does not make
    /// the receipt an official mailbox registration; it proves only the narrower
    /// statement carried by `OfficialDocumentInboxConsent.scope`.
    static func issue(consent: OfficialDocumentInboxConsent,
                      signResult: TWFidOSignResult,
                      anchor: IssuerCertificate? = nil,
                      now: Date = Date()) throws -> Self {
        let trustAnchor: IssuerCertificate
        if let anchor {
            trustAnchor = anchor
        } else {
            trustAnchor = try IssuerCertificate.loadBundled()
        }
        let holder = try trustAnchor.validateHolderCertificate(base64DER: signResult.cert, now: now)
        guard let signature = Data(base64Encoded: signResult.signedResponse),
              signature.count == MOICACredentialProof.signatureByteCount else {
            throw OfficialDocumentInboxError.malformedSignature
        }
        guard try holder.verifiesPKCS1SHA256(signature, over: Data(consent.signingTarget.utf8)) else {
            throw OfficialDocumentInboxError.signatureInvalid
        }
        return Self(consent: consent,
                    certificate: signResult.cert,
                    signature: signResult.signedResponse,
                    recordedAt: now)
    }

    /// Re-checks persisted evidence every time it is presented as signed. A
    /// successfully decoded JSON file is not evidence: its construction,
    /// one-use nonce, bounded timestamps and signature all still have to match.
    ///
    /// Certificate validity is checked at the locally recorded completion time,
    /// which is allowed to trail the signed consent creation time by at most the
    /// signing-session window above. This preserves historical evidence after a
    /// card certificate later expires without letting an edited timestamp choose
    /// an unrelated validity window.
    func verify(anchor: IssuerCertificate? = nil) throws {
        guard tbsConstruction == Self.tbsConstruction,
              let nonce = MOICASignedCredential.base64URLDecoded(consent.nonce),
              nonce.count == 32,
              recordedAt >= consent.createdAt,
              recordedAt.timeIntervalSince(consent.createdAt) <= Self.maximumRecordingDelay else {
            throw OfficialDocumentInboxError.receiptMetadataInvalid
        }

        let trustAnchor: IssuerCertificate
        if let anchor {
            trustAnchor = anchor
        } else {
            trustAnchor = try IssuerCertificate.loadBundled()
        }
        let holder = try trustAnchor.validateHolderCertificate(base64DER: certificate,
                                                                now: recordedAt)
        try verifySignature(signedBy: holder)
    }

    /// Internal seam for deterministic cryptographic tests. Production callers
    /// use `verify(anchor:)`, which first validates the holder certificate chain.
    func verifySignature(signedBy holder: X509Certificate) throws {
        guard let signature = Data(base64Encoded: signature),
              signature.count == MOICACredentialProof.signatureByteCount else {
            throw OfficialDocumentInboxError.malformedSignature
        }
        guard try holder.verifiesPKCS1SHA256(signature,
                                             over: Data(consent.signingTarget.utf8)) else {
            throw OfficialDocumentInboxError.signatureInvalid
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
