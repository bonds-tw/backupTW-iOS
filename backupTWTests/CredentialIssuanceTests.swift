//
//  CredentialIssuanceTests.swift
//  backupTWTests
//
//  What the card is asked to sign, and what happens when it never answers.
//

import Foundation
import Testing
@testable import backupTW

// MARK: - Stubs

/// Records what `begin` was asked for. A class so a non-mutating protocol
/// method can still write to it.
private final class SignSessionRecorder: @unchecked Sendable {
    var signing: TWFidOSigningTarget?
    var beginCount = 0
    var pollCount = 0
}

private struct StubSignSession: TWFidOSignSession, @unchecked Sendable {

    let recorder: SignSessionRecorder
    /// One entry per poll; `nil` means "the holder has not finished yet".
    let pollResults: [TWFidOSignResult?]

    func begin(idNumber: String,
               hint: String,
               signing: TWFidOSigningTarget,
               timeLimit: Int) async throws -> (ticket: TWFidOTicket, deepLink: URL) {
        recorder.beginCount += 1
        recorder.signing = signing
        return (TWFidOTicket(spTicket: "sp.ticket", transactionID: "TXN-1", spTicketID: "TKT-1"),
                URL(string: "mobilemoica://moica.moi.gov.tw/a2a/verifySign")!)
    }

    func poll(ticket: TWFidOTicket) async throws -> TWFidOSignResult? {
        defer { recorder.pollCount += 1 }
        guard recorder.pollCount < pollResults.count else { return nil }
        return pollResults[recorder.pollCount]
    }
}

private struct StubCallbacks: TWFidOCallbackWaiting, @unchecked Sendable {
    func waitForCallback(transactionID: String) async {
        // Never fires. The sleep arm of the race is what advances the loop, and
        // a callback that resolved immediately would make every timeout test
        // spin instead of expire.
        try? await Task.sleep(nanoseconds: .max)
    }
    func cancelWait(transactionID: String) async {}
}

private enum StubAnchorError: Error { case unavailable }

// MARK: - Tests

struct CredentialIssuanceTests {

    private static let subjectDID = "did:key:zDnaerDaTF5BXEavCrfRZEk316dpbLsfPDZ3WJ5hRTPFU2169"
    private static let issuedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private static let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                               unifiedNo: "A123456789",
                                               name: "王小明",
                                               birthdate: "0700101",
                                               addressOfHousehold: "臺北市中正區重慶南路一段122號")

    /// Every case below stops at the trust anchor, because the step after it
    /// needs a certificate 內政部 signed. What is under test is everything
    /// *before* that: what was sent, in what order, and what is refused.
    private func issuance(recorder: SignSessionRecorder,
                          pollResults: [TWFidOSignResult?] = [signResult()],
                          open: @escaping @Sendable (URL) async -> Bool = { _ in true },
                          timeLimit: Int = 600,
                          clock: @escaping @Sendable () -> Date = { CredentialIssuanceTests.issuedAt })
        -> CredentialIssuance {
        CredentialIssuance(
            session: StubSignSession(recorder: recorder, pollResults: pollResults),
            callbacks: StubCallbacks(),
            open: open,
            timeLimit: timeLimit,
            pollInterval: 0,
            now: clock,
            sleep: { _ in },
            anchor: { throw StubAnchorError.unavailable })
    }

    private static func signResult() -> TWFidOSignResult {
        TWFidOSignResult(cert: "MIIB", signedResponse: "c2ln", hashedIDNumber: "")
    }

    // MARK: What the card is asked to sign

    /// The heart of the change: the card signs a digest of *this* credential,
    /// not the relying-party constant it used to sign.
    @Test func theCardIsAskedToSignTheDigestOfTheCredentialBeingIssued() async throws {
        let recorder = SignSessionRecorder()

        _ = try? await issuance(recorder: recorder).issue(Self.model, subjectDID: Self.subjectDID)

        let expected = VerifiableCredential.nationalID(Self.model,
                                                       issuerDID: Self.subjectDID,
                                                       validFrom: Self.issuedAt)
        let (tbs, _) = try MOICASignedCredential.toBeSigned(for: expected)

        #expect(recorder.signing == .credentialTBS(tbs))
        // And emphatically not the value the holding proof signs — the mistake
        // this whole change exists to undo.
        #expect(recorder.signing != .relyingPartyIdentifier(TWFidOConfiguration.bondsAppID))
    }

    /// The TBS is the domain prefix plus the full SHA-256 — not a truncation
    /// that would fit the circuit's 31-character `tbs`, and not a bare digest
    /// another protocol could accidentally collide with.
    @Test func theTBSSentIsDomainPrefixedAndCarriesTheWholeHash() async throws {
        let recorder = SignSessionRecorder()

        _ = try? await issuance(recorder: recorder).issue(Self.model, subjectDID: Self.subjectDID)

        let sent = try #require(recorder.signing?.toBeSigned)
        #expect(sent.hasPrefix(MOICACredentialProof.tbsDomainPrefix))
        #expect(sent.count == MOICACredentialProof.tbsDomainPrefix.count + 64)
        #expect(sent.count != ProvingInputs.relyingPartyIdentifierLength)
    }

    // MARK: Refused before anything is sent

    /// Both of these run before `begin`, and the ordering is the point: the SIGN
    /// request carries 身分證統一編號 in the clear, so a document this app was
    /// never going to be able to use must not cost a disclosure to 內政部.
    @Test func aDocumentWithNoIdentityNumberIsRefusedWithoutContactingTheService() async throws {
        let recorder = SignSessionRecorder()
        let model = NationalIDModel(nationality: "中華民國（臺灣）", unifiedNo: nil,
                                    name: "王小明", birthdate: "0700101", addressOfHousehold: nil)

        await #expect(throws: CredentialIssuanceError.identityNumberMissing) {
            _ = try await issuance(recorder: recorder).issue(model, subjectDID: Self.subjectDID)
        }
        #expect(recorder.beginCount == 0)
    }

    /// A nameless credential is one this app's own verifier refuses, because
    /// there would be nothing to bind the signing cardholder to. Catching it at
    /// issuance means the holder finds out here rather than at a counter.
    @Test func aDocumentWithNoNameIsRefusedWithoutContactingTheService() async throws {
        let recorder = SignSessionRecorder()
        let model = NationalIDModel(nationality: "中華民國（臺灣）", unifiedNo: "A123456789",
                                    name: nil, birthdate: "0700101", addressOfHousehold: nil)

        await #expect(throws: CredentialIssuanceError.nameMissing) {
            _ = try await issuance(recorder: recorder).issue(model, subjectDID: Self.subjectDID)
        }
        #expect(recorder.beginCount == 0)
    }

    // MARK: The round trip

    @Test func aMissingCertificateAppIsItsOwnFailure() async throws {
        let recorder = SignSessionRecorder()
        let issuance = issuance(recorder: recorder, open: { _ in false })

        await #expect(throws: CredentialIssuanceError.certificateAppUnavailable) {
            _ = try await issuance.issue(Self.model, subjectDID: Self.subjectDID)
        }
        // The ticket was issued before we found out, which is worth pinning:
        // 內政部 has already seen the request, so the holder should be told the
        // app is missing rather than that nothing happened.
        #expect(recorder.beginCount == 1)
    }

    /// The deadline is the ticket's own `time_limit`, so this app and 內政部
    /// cannot disagree about when the request died.
    @Test func pollingStopsAtTheTicketsOwnDeadline() async throws {
        let recorder = SignSessionRecorder()
        // A clock that jumps past the deadline on its third reading: one for
        // `validFrom`, one to compute the deadline, then expiry.
        let readings = ClockStub(times: [Self.issuedAt,
                                         Self.issuedAt,
                                         Self.issuedAt.addingTimeInterval(601)])
        let issuance = issuance(recorder: recorder,
                                pollResults: [nil, nil, nil],
                                clock: { readings.next() })

        await #expect(throws: CredentialIssuanceError.timedOut) {
            _ = try await issuance.issue(Self.model, subjectDID: Self.subjectDID)
        }
    }
}

/// Hands out a scripted sequence of times, then repeats the last one.
private final class ClockStub: @unchecked Sendable {
    private let times: [Date]
    private var index = 0

    init(times: [Date]) { self.times = times }

    func next() -> Date {
        defer { index += 1 }
        return times[min(index, times.count - 1)]
    }
}
