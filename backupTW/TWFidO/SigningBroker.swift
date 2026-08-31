//
//  SigningBroker.swift
//  backupTW
//
//  App-side boundary for the future Release signing broker.
//

import CryptoKit
import Foundation

enum SigningBrokerIntentError: Error, Equatable {
    case unsupportedRelyingParty
    case malformedCredentialTBS
    case malformedOfficialDocumentConsent
}

/// The broker's allowlist in a type the App can test before any network client
/// or App Attest implementation exists. There is deliberately no arbitrary
/// `sign_data`, hint, callback URL, push alias, or provider field here.
struct SigningBrokerIntent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case zkHoldingProofV1 = "zk_holding_proof_v1"
        case nationalIDCredentialV1 = "national_id_credential_v1"
        case officialDocumentInboxConsentV1 = "official_document_inbox_consent_v1"
    }

    struct OfficialDocumentConsent: Codable, Equatable, Sendable {
        let version: String
        let scope: String
        let createdAtUnixMilliseconds: Int64
        let nonce: String
    }

    let type: Kind
    let tbs: String?
    let consent: OfficialDocumentConsent?

    static func make(from target: TWFidOSigningTarget) throws -> Self {
        switch target {
        case .relyingPartyIdentifier(let identifier):
            guard identifier == TWFidOConfiguration.bondsAppID else {
                throw SigningBrokerIntentError.unsupportedRelyingParty
            }
            return Self(type: .zkHoldingProofV1, tbs: nil, consent: nil)

        case .credentialTBS(let tbs):
            guard validDomainSeparatedTBS(tbs, prefix: MOICACredentialProof.tbsDomainPrefix) else {
                throw SigningBrokerIntentError.malformedCredentialTBS
            }
            return Self(type: .nationalIDCredentialV1, tbs: tbs, consent: nil)

        case .officialDocumentConsent(let descriptor):
            guard descriptor.version == OfficialDocumentInboxConsent.version,
                  descriptor.scope == OfficialDocumentInboxConsent.scope,
                  descriptor.nonce.utf8.count >= 32,
                  descriptor.nonce.utf8.count <= 128 else {
                throw SigningBrokerIntentError.malformedOfficialDocumentConsent
            }
            let canonical = Data("version=\(descriptor.version)\nscope=\(descriptor.scope)\ncreated_at_unix_ms=\(descriptor.createdAtUnixMilliseconds)\nnonce=\(descriptor.nonce)\n".utf8)
            let digest = SHA256.hash(data: canonical)
                .map { String(format: "%02x", $0) }.joined()
            let expected = OfficialDocumentInboxConsent.tbsDomainPrefix + digest
            guard descriptor.toBeSigned == expected else {
                throw SigningBrokerIntentError.malformedOfficialDocumentConsent
            }
            return Self(
                type: .officialDocumentInboxConsentV1,
                tbs: nil,
                consent: .init(version: descriptor.version,
                               scope: descriptor.scope,
                               createdAtUnixMilliseconds: descriptor.createdAtUnixMilliseconds,
                               nonce: descriptor.nonce))
        }
    }

    private static func validDomainSeparatedTBS(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.count == 64 && digest.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

struct SigningBrokerStart: Equatable, Sendable {
    let sessionToken: String
    let transactionID: String
    let deepLink: URL
    let expiresAt: Date
}

/// App Attest registration, assertions, canonical request hashing, idempotency
/// and HTTPS live behind this boundary. A concrete implementation must satisfy
/// `docs/release-signing-backend-v0.md`; this protocol is not a permission to
/// ship an unauthenticated fallback transport.
protocol SigningBrokerTransport: Sendable {
    func start(idNumber: String,
               intent: SigningBrokerIntent,
               timeLimit: Int) async throws -> SigningBrokerStart
    func poll(sessionToken: String) async throws -> TWFidOSignResult?
}

/// Lets every existing signing workflow use the same future broker through the
/// existing `TWFidOSignSession` seam. The client-supplied `hint` is deliberately
/// ignored: the backend owns fixed Traditional-Chinese text for each intent.
struct SigningBrokerSignSession: TWFidOSignSession, Sendable {
    let transport: any SigningBrokerTransport

    func begin(idNumber: String,
               hint: String,
               signing: TWFidOSigningTarget,
               timeLimit: Int) async throws -> (handle: TWFidOSignHandle, deepLink: URL) {
        let intent = try SigningBrokerIntent.make(from: signing)
        let start = try await transport.start(idNumber: idNumber,
                                              intent: intent,
                                              timeLimit: timeLimit)
        return (.remote(sessionToken: start.sessionToken,
                        transactionID: start.transactionID,
                        expiresAt: start.expiresAt),
                start.deepLink)
    }

    func poll(handle: TWFidOSignHandle) async throws -> TWFidOSignResult? {
        try await transport.poll(sessionToken: handle.remoteSessionToken())
    }
}

/// The only factory a distribution assembly uses for signing. Absence of a
/// reviewed code-signed endpoint keeps every Release entry point unavailable;
/// there is no fallback to local credentials or an environment variable.
enum SigningBrokerSessionAssembly {
    static func isConfigured(bundle: Bundle = .main) -> Bool {
        SigningBrokerEndpointConfiguration.fromBundle(bundle) != nil
    }

    static func make(bundle: Bundle = .main) -> SigningBrokerSignSession? {
        guard let configuration = SigningBrokerEndpointConfiguration.fromBundle(bundle) else {
            return nil
        }
        return SigningBrokerSignSession(
            transport: AppAttestSigningBrokerTransport(configuration: configuration))
    }
}
