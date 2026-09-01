//
//  OfficialDocumentInboxTests.swift
//  backupTWTests
//

import Foundation
import Testing
import UIKit
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
        "The verified signature is stored on this phone. Official receiving is still inactive until a government G2C service accepts this app and issues a receiving address.",
        "The stored consent evidence has invalid metadata, so it cannot be trusted.",
        "The saved consent evidence could not be verified. It will not be shown as signed, and the app will not overwrite it.",
        "Signed on %@. The saved evidence was reverified; it has not registered an official receiving address.",
        "Consent evidence needs attention",
        "Resolve the protected-storage problem before signing again.",
        "Review signed consent evidence",
        "Inspect the signed scope and fingerprints, or remove the local evidence from this iPhone.",
        "Signed consent evidence",
        "Current state",
        "Local prototype evidence — not an official inbox",
        "The saved signature was checked again before this screen opened. No government G2C service has accepted this app or issued a receiving address.",
        "Signed consent",
        "Signature completed",
        "Signed scope",
        "Local prototype only",
        "What this proves",
        "The holder approved this exact local-prototype consent with 行動自然人憑證.",
        "What this does not prove",
        "It does not prove government enrolment, a receiving address, sender authentication, document receipt or legal delivery.",
        "Evidence fingerprints",
        "Consent fingerprint (SHA-256)",
        "Certificate fingerprint (SHA-256)",
        "Signature fingerprint (SHA-256)",
        "Keep these fingerprints private",
        "A certificate fingerprint can link signatures made with the same certificate. 有備而來 does not transmit, log or share the fingerprints on this screen.",
        "Remove consent evidence from this iPhone",
        "Deletes only the local certificate and signature. It cannot erase the service record kept by the Ministry of the Interior.",
        "Remove this local consent evidence?",
        "This deletes the certificate and signature from this iPhone. It does not revoke an official inbox — none exists — and it cannot erase the service record kept by the Ministry of the Interior.",
        "Remove from this iPhone",
        "The local consent evidence was not removed",
        "Load a synthetic EN / DI / ESW package",
        "Developer test only — this did not come from a government agency and creates no receipt.",
        "Synthetic test package — not an official delivery",
        "This fixture exercises EN, DI, ESW, storage, integrity and viewing state. No government service sent it.",
        "Verified against the SHA-256 fingerprints listed in EN.",
        "Not verified — this package is synthetic and has no official exchange signature or address-book proof.",
        "Not created — viewing this test package changes only this phone's local state and sends nothing.",
        "有備而來 does not yet have an official ESW decryption contract or recipient key. It will not pretend the content was opened.",
        "A file does not match the SHA-256 fingerprint listed in the envelope, so the package was not stored."
    ]

    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficialDocumentInboxTests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    /// Most archive tests exercise persistence rather than the MOICA chain. The
    /// cryptographic cases below use a real throwaway RSA fixture explicitly.
    private func archive() throws -> OfficialDocumentInboxArchive {
        try OfficialDocumentInboxArchive(directory: directory(), verifyReceipt: { _ in })
    }

    private func consent() -> OfficialDocumentInboxConsent {
        OfficialDocumentInboxConsent(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            nonce: "fixture-nonce")
    }

    private func receipt() -> OfficialDocumentInboxReceipt {
        OfficialDocumentInboxReceipt(
            consent: consent(),
            certificate: Data("certificate".utf8).base64EncodedString(),
            signature: Data("signature".utf8).base64EncodedString(),
            recordedAt: Date(timeIntervalSince1970: 1_800_000_010.5))
    }

    private func cryptographicReceipt(nonceByte: UInt8 = 0x2a) throws
        -> OfficialDocumentInboxReceipt {
        let nonce = Data(repeating: nonceByte, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let consent = OfficialDocumentInboxConsent(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            nonce: nonce)
        let signature = try cardSignature(over: Data(consent.signingTarget.utf8))
        return OfficialDocumentInboxReceipt(
            consent: consent,
            certificate: holderCertificateDER,
            signature: signature.base64EncodedString(),
            recordedAt: Date(timeIntervalSince1970: 1_800_000_100))
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
        let archive = try archive()
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
        let archive = try archive()
        try Data("not json".utf8).write(
            to: archive.directory.appendingPathComponent("prototype-consent.json"))

        #expect(throws: (any Error).self) { _ = try archive.receipt() }
    }

    @Test func persistedConsentEvidenceIsCryptographicallyRechecked() throws {
        let holder = try X509Certificate.parse(base64DER: holderCertificateDER)
        let receipt = try cryptographicReceipt()

        try receipt.verifySignature(signedBy: holder)
        #expect(receipt.consentFingerprint.count == 64)
        #expect(receipt.certificateFingerprint?.count == 64)
        #expect(receipt.signatureFingerprint?.count == 64)
        #expect(receipt.consentFingerprint.contains(receipt.certificate) == false)
        #expect(receipt.signatureFingerprint?.contains(receipt.signature) == false)

        let differentConsent = try cryptographicReceipt(nonceByte: 0x2b).consent
        let tampered = OfficialDocumentInboxReceipt(
            consent: differentConsent,
            certificate: receipt.certificate,
            signature: receipt.signature,
            recordedAt: receipt.recordedAt)
        #expect(throws: OfficialDocumentInboxError.signatureInvalid) {
            try tampered.verifySignature(signedBy: holder)
        }
    }

    @Test func archiveRejectsChangedEvidenceAndLocalRemovalKeepsDocuments() throws {
        let holder = try X509Certificate.parse(base64DER: holderCertificateDER)
        let archive = try OfficialDocumentInboxArchive(
            directory: directory(),
            verifyReceipt: { try $0.verifySignature(signedBy: holder) })
        let receipt = try cryptographicReceipt()
        try archive.store(receipt)
        try archive.importSynthetic(OfficialDocumentSyntheticFixture.make())

        let replacement = try cryptographicReceipt(nonceByte: 0x2b)
        let tampered = OfficialDocumentInboxReceipt(
            consent: replacement.consent,
            certificate: receipt.certificate,
            signature: receipt.signature,
            recordedAt: replacement.recordedAt)
        #expect(throws: OfficialDocumentInboxError.signatureInvalid) {
            try archive.store(tampered)
        }
        #expect(try archive.receipt() == receipt)

        try archive.removeReceipt()
        #expect(try archive.receipt() == nil)
        #expect(try archive.packages().count == 1)
    }

    @Test func invalidReceiptMetadataFailsBeforeTrustIsPresented() throws {
        let receipt = OfficialDocumentInboxReceipt(
            consent: consent(),
            certificate: Data("certificate".utf8).base64EncodedString(),
            signature: Data(repeating: 0, count: 256).base64EncodedString(),
            recordedAt: Date(timeIntervalSince1970: 1_800_000_010))

        #expect(throws: OfficialDocumentInboxError.receiptMetadataInvalid) {
            try receipt.verify()
        }
    }

    @Test func theInboxDecisionAndLimitsReachTraditionalChineseReaders() {
        for message in Self.userFacingStrings {
            #expect(LocalizationCoverageTests.chineseValue(for: message) != nil,
                    "untranslated official-document inbox string: \(message)")
        }
    }

    @Test func syntheticENDIESWPackageChecksHashesAndKeepsSourceBoundaries() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_001_000)
        let checkedAt = Date(timeIntervalSince1970: 1_800_001_010)
        let payload = OfficialDocumentSyntheticFixture.make(receivedAt: receivedAt)

        let package = try OfficialDocumentPackageParser.parseSynthetic(payload,
                                                                        checkedAt: checkedAt)

        #expect(package.environment == .syntheticFixtureOnly)
        #expect(package.localState == .unread)
        #expect(package.contentAvailability == .syntheticReadable)
        #expect(package.envelope.sender.organizationName == "電子公文接收站合成測試機關")
        #expect(package.envelope.files.map(\.filename) == ["synthetic.di", "synthetic.esw"])
        #expect(package.envelope.files.map(\.note) == ["合成 DI 本文", "合成 ESW 邊界資料"])
        #expect(package.document?.type == "函")
        #expect(package.document?.subject == "合成測試：防災演練通知")
        #expect(package.encryptedSwitch?.recipientCount == 1)
        #expect(package.encryptedSwitch?.method == "RSA")
        #expect(package.integrity.documentDigest == payload.document.map {
            OfficialDocumentPackageParser.sha256($0.data)
        })
        #expect(package.receivedAt == receivedAt)
        #expect(package.integrity.checkedAt == checkedAt)

        let index = String(decoding: try JSONEncoder().encode(package), as: UTF8.self)
        #expect(index.contains("SYNTHETIC-ONLY") == false)
        #expect(index.contains("CipherData") == false)
    }

    @Test func packageWithAMismatchedDIIsRefusedBeforeStorage() throws {
        let archive = try archive()
        let fixture = OfficialDocumentSyntheticFixture.make()
        let document = try #require(fixture.document)
        let tampered = OfficialDocumentImportPayload(
            envelope: fixture.envelope,
            document: .init(filename: document.filename,
                            data: document.data + Data("tampered".utf8)),
            encryptedSwitch: fixture.encryptedSwitch,
            receivedAt: fixture.receivedAt)

        #expect(throws: OfficialDocumentPackageError.hashMismatch("synthetic.di")) {
            _ = try archive.importSynthetic(tampered)
        }
        #expect(try archive.packages().isEmpty)
    }

    @Test func archivePreservesSourcesAndMovesOnlyTheLocalReadState() throws {
        let archive = try archive()
        let fixture = OfficialDocumentSyntheticFixture.make(
            receivedAt: Date(timeIntervalSince1970: 1_800_002_000))
        let stored = try archive.importSynthetic(
            fixture, checkedAt: Date(timeIntervalSince1970: 1_800_002_010))

        #expect(try archive.sourceData(id: stored.id, fileExtension: "en") == fixture.envelope.data)
        #expect(try archive.sourceData(id: stored.id, fileExtension: "di") == fixture.document?.data)
        #expect(try archive.sourceData(id: stored.id, fileExtension: "esw") == fixture.encryptedSwitch?.data)

        let viewedAt = Date(timeIntervalSince1970: 1_800_002_100)
        let viewed = try archive.markViewed(id: stored.id, at: viewedAt)
        #expect(viewed.localState == .viewedLocally)
        #expect(viewed.viewedAt == viewedAt)
        #expect(viewed.integrity == stored.integrity)
        #expect(viewed.sourceAuthentication == .notVerifiedSynthetic)
    }

    @Test func identicalRepeatIsIdempotentButConflictingApplicationIDIsRefused() throws {
        let archive = try archive()
        let firstPayload = OfficialDocumentSyntheticFixture.make(
            applicationID: "SYNTHETIC-SAME-ID",
            receivedAt: Date(timeIntervalSince1970: 1_800_003_000))
        let first = try archive.importSynthetic(firstPayload)
        _ = try archive.markViewed(id: first.id,
                                   at: Date(timeIntervalSince1970: 1_800_003_010))

        let repeated = try archive.importSynthetic(firstPayload)
        #expect(repeated.localState == .viewedLocally)
        #expect(try archive.packages().count == 1)

        let conflict = OfficialDocumentSyntheticFixture.make(
            applicationID: "SYNTHETIC-SAME-ID",
            subject: "同一 application ID 的不同內容")
        #expect(throws: OfficialDocumentInboxArchiveError.conflictingApplicationID(
            "SYNTHETIC-SAME-ID")) {
            _ = try archive.importSynthetic(conflict)
        }
        #expect(try archive.packages().count == 1)
    }

    @Test func ESWOnlyPackageStaysEncryptedAndNeverPretendsToBeReadable() throws {
        let fixture = OfficialDocumentSyntheticFixture.make()
        let encryptedOnly = OfficialDocumentImportPayload(
            envelope: fixture.envelope,
            document: nil,
            encryptedSwitch: fixture.encryptedSwitch,
            receivedAt: fixture.receivedAt)

        let package = try OfficialDocumentPackageParser.parseSynthetic(encryptedOnly)

        #expect(package.document == nil)
        #expect(package.contentAvailability == .encryptedContentUnavailable)
        #expect(package.encryptedSwitch != nil)
    }

    @Test func officialAddressBookProvesOnlyAnActiveDirectoryListing() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_004_000)
        let data = Data("""
        ORGID,ORGNAME,STATUSCODE,UPDATETIME\r
        200000000A,總統府,T,2025-12-08 11:23:23\r
        QUOTED001,"測試,機關",T,2026-08-31 10:20:30\r
        """.utf8)
        let snapshot = try OfficialDocumentAddressBookSnapshot(data: data,
                                                                checkedAt: checkedAt)
        let evidence = try snapshot.evidence(for: .init(
            organizationID: "QUOTED001",
            organizationName: "測試,機關"))

        #expect(snapshot.records.count == 2)
        #expect(snapshot.sha256.count == 64)
        #expect(snapshot.source == OfficialDocumentAddressBookSnapshot.sourceURL)
        #expect(evidence.scope == .activeDirectoryListingOnly)
        #expect(evidence.organizationID == "QUOTED001")
        #expect(evidence.directorySHA256 == snapshot.sha256)
        #expect(evidence.checkedAt == checkedAt)
    }

    @Test func addressBookRefusesAmbiguousOrUnlistedSenderClaims() throws {
        let data = Data("""
        ORGID,ORGNAME,STATUSCODE,UPDATETIME
        AGENCY001,正確機關名稱,T,2026-08-31 10:20:30
        """.utf8)
        let snapshot = try OfficialDocumentAddressBookSnapshot(data: data)

        #expect(throws: OfficialDocumentAddressBookError.senderNameMismatch(
            expected: "正確機關名稱", actual: "冒名機關")) {
            _ = try snapshot.evidence(for: .init(
                organizationID: "AGENCY001", organizationName: "冒名機關"))
        }
        #expect(throws: OfficialDocumentAddressBookError.senderNotListed("MISSING")) {
            _ = try snapshot.evidence(for: .init(
                organizationID: "MISSING", organizationName: "未登錄"))
        }
    }

    @Test func addressBookRejectsDuplicateInactiveAndMalformedRows() throws {
        let duplicate = Data("""
        ORGID,ORGNAME,STATUSCODE,UPDATETIME
        AGENCY001,機關一,T,2026-08-31 10:20:30
        AGENCY001,機關二,T,2026-08-31 10:20:31
        """.utf8)
        #expect(throws: OfficialDocumentAddressBookError.duplicateOrganizationID("AGENCY001")) {
            _ = try OfficialDocumentAddressBookSnapshot(data: duplicate)
        }

        let inactive = Data("""
        ORGID,ORGNAME,STATUSCODE,UPDATETIME
        AGENCY002,停用機關,F,2026-08-31 10:20:30
        """.utf8)
        let inactiveSnapshot = try OfficialDocumentAddressBookSnapshot(data: inactive)
        #expect(throws: OfficialDocumentAddressBookError.inactiveOrganization("AGENCY002")) {
            _ = try inactiveSnapshot.evidence(for: .init(
                organizationID: "AGENCY002", organizationName: "停用機關"))
        }

        let malformed = Data("""
        ORGID,ORGNAME,STATUSCODE,UPDATETIME
        AGENCY003,"未結束欄位,T,2026-08-31 10:20:30
        """.utf8)
        #expect(throws: OfficialDocumentAddressBookError.malformedCSV(row: 2)) {
            _ = try OfficialDocumentAddressBookSnapshot(data: malformed)
        }
    }

    @Test @MainActor func inboxListsTheSyntheticPackageAndOpensItsDedicatedDetail() throws {
        let archive = try archive()
        let package = try archive.importSynthetic(OfficialDocumentSyntheticFixture.make())
        let controller = OfficialDocumentInboxViewController(archive: archive,
                                                             makeSigning: { nil })
        let navigation = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()

        #expect(controller.tableView.numberOfRows(inSection: 1) == 1)
        let cell = controller.tableView(controller.tableView,
                                        cellForRowAt: IndexPath(row: 0, section: 1))
        #expect(cell.accessibilityIdentifier == "officialDocuments.document.0")
        #expect(cell.textLabel?.text == package.document?.subject)

        controller.tableView(controller.tableView,
                             didSelectRowAt: IndexPath(row: 0, section: 1))
        #expect(navigation.topViewController is OfficialDocumentDetailViewController)
    }

    @Test @MainActor func openingDetailMarksOnlyTheLocalViewingState() throws {
        let archive = try archive()
        let package = try archive.importSynthetic(OfficialDocumentSyntheticFixture.make())
        let controller = OfficialDocumentDetailViewController(packageID: package.id,
                                                              archive: archive)
        controller.loadViewIfNeeded()

        #expect(controller.numberOfSections(in: controller.tableView) == 5)
        let boundary = controller.tableView(controller.tableView,
                                            cellForRowAt: IndexPath(row: 0, section: 0))
        #expect(boundary.accessibilityIdentifier == "officialDocuments.detail.boundary")
        controller.viewDidAppear(false)

        let stored = try archive.package(id: package.id)
        let updated = try #require(stored)
        #expect(updated.localState == .viewedLocally)
        #expect(updated.sourceAuthentication == .notVerifiedSynthetic)
        let receipt = controller.tableView(controller.tableView,
                                           cellForRowAt: IndexPath(row: 2, section: 3))
        #expect(receipt.accessibilityIdentifier == "officialDocuments.detail.receipt")
        #expect(receipt.detailTextLabel?.text?.contains("sends nothing") == true
                || receipt.detailTextLabel?.text?.contains("不會送出") == true)
    }

    @Test @MainActor func signedConsentOpensVerifiedEvidenceInsteadOfSigningAgain() throws {
        let archive = try archive()
        let receipt = receipt()
        try archive.store(receipt)
        let controller = OfficialDocumentInboxViewController(archive: archive,
                                                             makeSigning: { nil })
        let navigation = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()

        let action = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 2))
        #expect(action.accessibilityIdentifier == "officialDocuments.reviewConsent")

        controller.tableView(controller.tableView,
                             didSelectRowAt: IndexPath(row: 0, section: 2))
        let evidence = try #require(
            navigation.topViewController as? OfficialDocumentConsentEvidenceViewController)
        #expect(evidence.numberOfSections(in: evidence.tableView) == 4)
        let boundary = evidence.tableView(
            evidence.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0))
        let remove = evidence.tableView(
            evidence.tableView,
            cellForRowAt: IndexPath(row: 0, section: 3))
        #expect(boundary.accessibilityIdentifier == "officialDocuments.consentEvidence.boundary")
        #expect(remove.accessibilityIdentifier == "officialDocuments.consentEvidence.remove")
        #expect(remove.textLabel?.textColor == .systemRed)
    }
}

private actor OfficialDocumentStubSession: TWFidOSignSession {
    private(set) var receivedSigning: TWFidOSigningTarget?
    private let result: TWFidOSignResult

    init(result: TWFidOSignResult) { self.result = result }

    func begin(idNumber: String,
               hint: String,
               signing: TWFidOSigningTarget,
               timeLimit: Int) async throws -> (handle: TWFidOSignHandle, deepLink: URL) {
        receivedSigning = signing
        return (.local(TWFidOTicket(spTicket: "ticket",
                                   transactionID: "transaction",
                                   spTicketID: "id")),
                URL(string: "mobilemoica://moica.moi.gov.tw/a2a/verifySign")!)
    }

    func poll(handle: TWFidOSignHandle) async throws -> TWFidOSignResult? { result }

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

        guard case .officialDocumentConsent(let target) = await session.signingTarget() else {
            Issue.record("expected the official-document signing target")
            return
        }
        #expect(target.toBeSigned == consent.signingTarget)
        #expect(target.scope == OfficialDocumentInboxConsent.scope)
        #expect(target.nonce == consent.nonce)
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
