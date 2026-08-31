//
//  OfficialDocumentInboxTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

struct OfficialDocumentInboxTests {
    private static let userFacingStrings = [
        "Electronic official documents",
        "Personal official document inbox",
        "Set up the 行動自然人憑證 signing pilot",
        "Prototype consent signed · Official receiving is not active yet",
        "Receiving status",
        "Official documents",
        "No official documents yet",
        "This app is not connected to the government's G2C exchange service yet. No agency can deliver a legally effective document here today.",
        "Official receiving is not active",
        "You can test the 行動自然人憑證 signing hand-off now. Official receiving still requires the Archives Administration's G2C exchange service and an agency delivery policy.",
        "Sign the prototype consent",
        "This tests the app-to-app signature only. It does not activate legal electronic delivery.",
        "Sign with 行動自然人憑證",
        "This sends your ID number, the service identifier, and a prototype-consent digest to the Ministry of the Interior, which keeps a service record. 有備而來 does not save the ID number you type. The signature will not create an official mailbox.",
        "Send the number and sign",
        "The verified signature is stored on this phone. Official receiving is still inactive until a government G2C service accepts this app and issues a receiving address."
    ]

    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficialDocumentInboxTests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func consent() -> OfficialDocumentInboxConsent {
        OfficialDocumentInboxConsent(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            nonce: "fixture-nonce")
    }

    private func receipt() -> OfficialDocumentInboxReceipt {
        OfficialDocumentInboxReceipt(
            consent: consent(),
            certificate: "certificate-base64",
            signature: "signature-base64",
            recordedAt: Date(timeIntervalSince1970: 1_800_000_010.5))
    }

    @Test func consentIsDomainSeparatedAndContainsNoIdentityNumber() {
        let consent = consent()
        let canonical = String(decoding: consent.canonicalBytes, as: UTF8.self)

        #expect(consent.signingTarget.hasPrefix(OfficialDocumentInboxConsent.tbsDomainPrefix))
        #expect(consent.signingTarget.count == OfficialDocumentInboxConsent.tbsDomainPrefix.count + 64)
        #expect(canonical.contains(OfficialDocumentInboxConsent.version))
        #expect(canonical.contains(OfficialDocumentInboxConsent.scope))
        #expect(canonical.contains("A123456789") == false)
    }

    @Test func archiveRoundTripsThePrototypeReceiptAndPurgesIt() throws {
        let archive = try OfficialDocumentInboxArchive(directory: directory())
        let expected = receipt()

        try archive.store(expected)
        #expect(try archive.receipt() == expected)

        let raw = try String(contentsOf: archive.directory
            .appendingPathComponent("prototype-consent.json"), encoding: .utf8)
        #expect(raw.contains("hashedIDNumber") == false)
        #expect(raw.contains("idNumber") == false)

        try archive.purge()
        #expect(!FileManager.default.fileExists(atPath: archive.directory.path))
    }

    @Test func corruptedReceiptIsNotSilentlyReportedAsUnsigned() throws {
        let archive = try OfficialDocumentInboxArchive(directory: directory())
        try Data("not json".utf8).write(
            to: archive.directory.appendingPathComponent("prototype-consent.json"))

        #expect(throws: (any Error).self) { _ = try archive.receipt() }
    }

    @Test func theInboxDecisionAndLimitsReachTraditionalChineseReaders() {
        for message in Self.userFacingStrings {
            #expect(LocalizationCoverageTests.chineseValue(for: message) != nil,
                    "untranslated official-document inbox string: \(message)")
        }
    }
}

private actor OfficialDocumentStubSession: TWFidOSignSession {
    private(set) var receivedSigning: TWFidOSigningTarget?
    private let result: TWFidOSignResult

    init(result: TWFidOSignResult) { self.result = result }

    func begin(idNumber: String,
               hint: String,
               signing: TWFidOSigningTarget,
               timeLimit: Int) async throws -> (ticket: TWFidOTicket, deepLink: URL) {
        receivedSigning = signing
        return (TWFidOTicket(spTicket: "ticket", transactionID: "transaction", spTicketID: "id"),
                URL(string: "mobilemoica://moica.moi.gov.tw/a2a/verifySign")!)
    }

    func poll(ticket: TWFidOTicket) async throws -> TWFidOSignResult? { result }

    func signingTarget() -> TWFidOSigningTarget? { receivedSigning }
}

private actor ImmediateOfficialDocumentCallbacks: TWFidOCallbackWaiting {
    func waitForCallback(transactionID: String) async {}
    func cancelWait(transactionID: String) async {}
}

struct OfficialDocumentSigningTests {
    @Test func signingUsesTheOfficialDocumentTargetAndReturnsAPrototypeReceipt() async throws {
        let consent = OfficialDocumentInboxConsent(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            nonce: "one-use-nonce")
        let result = TWFidOSignResult(cert: "cert", signedResponse: "signature",
                                      hashedIDNumber: "must-not-be-stored")
        let session = OfficialDocumentStubSession(result: result)
        let recordedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let signing = OfficialDocumentSigning(
            session: session,
            callbacks: ImmediateOfficialDocumentCallbacks(),
            open: { _ in true },
            now: { recordedAt },
            makeReceipt: { consent, result, now in
                OfficialDocumentInboxReceipt(consent: consent,
                                             certificate: result.cert,
                                             signature: result.signedResponse,
                                             recordedAt: now)
            })

        let receipt = try await signing.sign(consent: consent, idNumber: "A123456789")

        guard case .officialDocumentTBS(let target) = await session.signingTarget() else {
            Issue.record("expected the official-document signing target")
            return
        }
        #expect(target == consent.signingTarget)
        #expect(receipt.environment == .localPrototypeOnly)
        #expect(receipt.recordedAt == recordedAt)
        #expect(receipt.certificate == "cert")
        #expect(receipt.signature == "signature")
    }

    @Test func anEmptyIdentityNumberNeverStartsTheSignatureSession() async {
        let session = OfficialDocumentStubSession(
            result: TWFidOSignResult(cert: "cert", signedResponse: "signature",
                                     hashedIDNumber: "hash"))
        let signing = OfficialDocumentSigning(
            session: session,
            callbacks: ImmediateOfficialDocumentCallbacks(),
            open: { _ in true },
            makeReceipt: { consent, result, now in
                OfficialDocumentInboxReceipt(consent: consent,
                                             certificate: result.cert,
                                             signature: result.signedResponse,
                                             recordedAt: now)
            })

        await #expect(throws: OfficialDocumentSigningError.identityNumberMissing) {
            _ = try await signing.sign(
                consent: OfficialDocumentInboxConsent(createdAt: Date(), nonce: "nonce"),
                idNumber: "   ")
        }
        #expect(await session.signingTarget() == nil)
    }
}
