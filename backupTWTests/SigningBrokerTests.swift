//
//  SigningBrokerTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

private actor SigningBrokerStubTransport: SigningBrokerTransport {
    private(set) var startedIDNumber: String?
    private(set) var startedIntent: SigningBrokerIntent?
    private(set) var startedTimeLimit: Int?
    private(set) var polledToken: String?

    func start(idNumber: String,
               intent: SigningBrokerIntent,
               timeLimit: Int) async throws -> SigningBrokerStart {
        startedIDNumber = idNumber
        startedIntent = intent
        startedTimeLimit = timeLimit
        return SigningBrokerStart(
            sessionToken: "opaque-session-token",
            transactionID: "broker-transaction",
            deepLink: URL(string: "mobilemoica://moica.moi.gov.tw/a2a/verifySign")!,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_600))
    }

    func poll(sessionToken: String) async throws -> TWFidOSignResult? {
        polledToken = sessionToken
        return TWFidOSignResult(cert: "certificate",
                                signedResponse: "signature",
                                hashedIDNumber: "transport-only")
    }
}

struct SigningBrokerTests {
    private func consent() -> OfficialDocumentInboxConsent {
        OfficialDocumentInboxConsent(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            nonce: String(repeating: "n", count: 43))
    }

    @Test func officialDocumentIntentIsStructuredAndContainsNoIdentityNumber() throws {
        let consent = consent()
        let intent = try SigningBrokerIntent.make(
            from: .officialDocumentConsent(consent.signingDescriptor))

        #expect(intent.type == .officialDocumentInboxConsentV1)
        #expect(intent.tbs == nil)
        #expect(intent.consent?.version == OfficialDocumentInboxConsent.version)
        #expect(intent.consent?.scope == OfficialDocumentInboxConsent.scope)
        #expect(intent.consent?.nonce == consent.nonce)

        let json = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        #expect(json.contains("idNumber") == false)
        #expect(json.contains("hashedIDNumber") == false)
        #expect(json.contains(consent.signingTarget) == false,
                "the broker must rebuild the TBS instead of accepting a caller digest")
    }

    @Test func tamperedOfficialDocumentDescriptorNeverBecomesAnIntent() {
        let consent = consent()
        let tampered = TWFidOOfficialDocumentConsentTarget(
            version: OfficialDocumentInboxConsent.version,
            scope: OfficialDocumentInboxConsent.scope,
            createdAtUnixMilliseconds: consent.signingDescriptor.createdAtUnixMilliseconds,
            nonce: consent.nonce,
            toBeSigned: OfficialDocumentInboxConsent.tbsDomainPrefix + String(repeating: "0", count: 64))

        #expect(throws: SigningBrokerIntentError.malformedOfficialDocumentConsent) {
            _ = try SigningBrokerIntent.make(from: .officialDocumentConsent(tampered))
        }
    }

    @Test func brokerSessionMapsTheExistingSigningSeamWithoutClientHintOrCallbackControl() async throws {
        let transport = SigningBrokerStubTransport()
        let session = SigningBrokerSignSession(transport: transport)
        let consent = consent()

        let started = try await session.begin(
            idNumber: "A123456789",
            hint: "a client-supplied hint the broker must never receive",
            signing: .officialDocumentConsent(consent.signingDescriptor),
            timeLimit: 600)
        let result = try await session.poll(ticket: started.ticket)

        #expect(started.ticket.spTicket == "opaque-session-token")
        #expect(started.ticket.transactionID == "broker-transaction")
        #expect(await transport.startedIDNumber == "A123456789")
        #expect(await transport.startedIntent?.type == .officialDocumentInboxConsentV1)
        #expect(await transport.startedTimeLimit == 600)
        #expect(await transport.polledToken == "opaque-session-token")
        #expect(result?.cert == "certificate")
        #expect(result?.hashedIDNumber == "transport-only")
    }

    @Test func brokerAllowlistRejectsArbitraryTargets() {
        #expect(throws: SigningBrokerIntentError.unsupportedRelyingParty) {
            _ = try SigningBrokerIntent.make(from: .relyingPartyIdentifier("some-other-service"))
        }
        #expect(throws: SigningBrokerIntentError.malformedCredentialTBS) {
            _ = try SigningBrokerIntent.make(from: .credentialTBS("arbitrary-data"))
        }
    }
}
