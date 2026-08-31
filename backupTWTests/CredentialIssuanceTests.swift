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

/// What one poll does. A script of these is how a test says "fail once, then
/// succeed" — the shape the real flow has on real hardware, where the first
/// poll dies with the app's own backgrounding.
private enum PollOutcome {
    case pending
    case success(TWFidOSignResult)
    case failure(Error)
}

private struct StubSignSession: TWFidOSignSession, @unchecked Sendable {

    let recorder: SignSessionRecorder
    /// One entry per poll; runs off the end as `.pending`.
    let pollScript: [PollOutcome]

    func begin(idNumber: String,
               hint: String,
               signing: TWFidOSigningTarget,
               timeLimit: Int) async throws -> (handle: TWFidOSignHandle, deepLink: URL) {
        recorder.beginCount += 1
        recorder.signing = signing
        return (.local(TWFidOTicket(spTicket: "sp.ticket",
                                   transactionID: "TXN-1",
                                   spTicketID: "TKT-1")),
                URL(string: "mobilemoica://moica.moi.gov.tw/a2a/verifySign")!)
    }

    func poll(handle: TWFidOSignHandle) async throws -> TWFidOSignResult? {
        defer { recorder.pollCount += 1 }
        guard recorder.pollCount < pollScript.count else { return nil }
        switch pollScript[recorder.pollCount] {
        case .pending: return nil
        case .success(let result): return result
        case .failure(let error): throw error
        }
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
                          pollScript: [PollOutcome] = [.success(signResult())],
                          open: @escaping @Sendable (URL) async -> Bool = { _ in true },
                          timeLimit: Int = 600,
                          clock: @escaping @Sendable () -> Date = { CredentialIssuanceTests.issuedAt })
        -> CredentialIssuance {
        CredentialIssuance(
            session: StubSignSession(recorder: recorder, pollScript: pollScript),
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
    ///
    /// The exact digest cannot be predicted any more, and that is the newer
    /// property rather than a weakening of this one: selective disclosure salts
    /// every claim, so two issuances of the same document commit to different
    /// digests. What stays checkable — and is what this test is for — is that
    /// the card is asked to sign *this credential's* TBS and not a constant.
    @Test func theCardIsAskedToSignTheCredentialsOwnTBS() async throws {
        let recorder = SignSessionRecorder()

        _ = try? await issuance(recorder: recorder).issue(Self.model, subjectDID: Self.subjectDID)

        let sent = try #require(recorder.signing)
        guard case .credentialTBS = sent else {
            Issue.record("issuance signed \(sent) rather than a credential TBS")
            return
        }
        // Emphatically not the value the holding proof signs — the mistake this
        // whole change exists to undo.
        #expect(sent != .relyingPartyIdentifier(TWFidOConfiguration.bondsAppID))
    }

    /// Two issuances of the same document must not produce the same TBS.
    ///
    /// Salted commitments are what make that true, and it matters beyond
    /// tidiness: identical digests across issuances would let anyone holding two
    /// presentations tell they came from one document, which is a correlator the
    /// holder never agreed to.
    @Test func twoIssuancesOfTheSameDocumentSignDifferentDigests() async throws {
        let first = SignSessionRecorder()
        let second = SignSessionRecorder()

        _ = try? await issuance(recorder: first).issue(Self.model, subjectDID: Self.subjectDID)
        _ = try? await issuance(recorder: second).issue(Self.model, subjectDID: Self.subjectDID)

        #expect(first.signing != nil)
        #expect(first.signing != second.signing)
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

    // MARK: Transport failures while polling

    /// The failure real hardware guarantees: the first poll fires in the same
    /// breath as the `mobilemoica://` hand-off, iOS kills the suspended app's
    /// socket, and the request completes as a connection error *after the
    /// holder has already signed*. Measured on an iPhone 14 on 2026-08-09 —
    /// 行動自然人憑證 showing 簽章成功 while this app reported failure. A
    /// transient transport error must be retried, not treated as the outcome.
    @Test func aKilledSocketOnTheFirstPollIsRetriedNotFatal() async throws {
        let recorder = SignSessionRecorder()
        let issuance = issuance(recorder: recorder,
                                pollScript: [.failure(URLError(.networkConnectionLost)),
                                             .pending,
                                             .success(Self.signResult())])

        // The stub anchor still throws, so the flow errs *after* polling — what
        // matters here is that polling consumed the whole script instead of
        // dying on entry number one.
        _ = try? await issuance.issue(Self.model, subjectDID: Self.subjectDID)

        #expect(recorder.pollCount == 3)
    }

    /// The counter-case that keeps the retry honest: a body that failed the
    /// `idp_checksum` check is not a hiccup, it is evidence. Retrying it would
    /// hand whoever is forging bodies unlimited attempts inside the polling
    /// window, so one bad body ends the flow.
    @Test func anUnauthenticatedResultIsTerminalNotRetried() async throws {
        let recorder = SignSessionRecorder()
        let issuance = issuance(recorder: recorder,
                                pollScript: [.failure(TWFidOError.unauthenticatedResult),
                                             .success(Self.signResult())])

        await #expect(throws: CredentialIssuanceError.self) {
            _ = try await issuance.issue(Self.model, subjectDID: Self.subjectDID)
        }
        // Never reached the success entry: the first poll was the end.
        #expect(recorder.pollCount == 1)
    }

    /// When the deadline arrives after transport failures, the error must blame
    /// the connection — `timedOut`'s message says the holder never approved,
    /// and on this path they may be looking at 簽章成功 on the other screen.
    @Test func transportFailuresUntilTheDeadlineReportUnreachableNotExpired() async throws {
        let recorder = SignSessionRecorder()
        let readings = ClockStub(times: [Self.issuedAt,
                                         Self.issuedAt,
                                         Self.issuedAt,
                                         Self.issuedAt.addingTimeInterval(601)])
        let issuance = issuance(recorder: recorder,
                                pollScript: [.failure(URLError(.notConnectedToInternet)),
                                             .failure(URLError(.notConnectedToInternet))],
                                clock: { readings.next() })

        await #expect(throws: CredentialIssuanceError.resultUnreachable) {
            _ = try await issuance.issue(Self.model, subjectDID: Self.subjectDID)
        }
    }

    @Test func retryableBrokerFailurePollsAgainButNeverRestartsCredentialSigning() async throws {
        let recorder = SignSessionRecorder()
        let readings = ClockStub(times: [Self.issuedAt,
                                         Self.issuedAt,
                                         Self.issuedAt,
                                         Self.issuedAt.addingTimeInterval(601)])
        let failure = SigningBrokerClientError.server(
            code: "signing_unavailable", retryable: true)
        let issuance = issuance(recorder: recorder,
                                pollScript: [.failure(failure), .failure(failure)],
                                clock: { readings.next() })

        await #expect(throws: CredentialIssuanceError.resultUnreachable) {
            _ = try await issuance.issue(Self.model, subjectDID: Self.subjectDID)
        }
        #expect(recorder.beginCount == 1,
                "an unknown result must never create a second signing request")
        #expect(recorder.pollCount == 2)
    }

    @Test func terminalBrokerFailureStopsCredentialPollingImmediately() async throws {
        let recorder = SignSessionRecorder()
        let issuance = issuance(
            recorder: recorder,
            pollScript: [.failure(SigningBrokerClientError.server(
                code: "session_expired", retryable: false)),
                         .success(Self.signResult())])

        await #expect(throws: CredentialIssuanceError.self) {
            _ = try await issuance.issue(Self.model, subjectDID: Self.subjectDID)
        }
        #expect(recorder.beginCount == 1)
        #expect(recorder.pollCount == 1)
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
                                pollScript: [.pending, .pending, .pending],
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
