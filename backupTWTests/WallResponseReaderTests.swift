//
//  WallResponseReaderTests.swift
//  backupTWTests
//
//  The table that decides whether somebody is told to sign again.
//

import Foundation
import Testing
@testable import backupTW

struct WallResponseReaderTests {

    private static func body(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - The invariant that must never be got wrong by hand

    /// If trying again might duplicate, the app may not say nothing was
    /// published. Two statements of one fact; letting them be set separately is
    /// how they end up contradicting each other on screen.
    @Test(arguments: [WallError.hostDoesNotExist, .offline, .unreadableReply, .unavailable,
                      .rateLimited, .budgetSpent, .challengeUnusable, .challengeAlreadyUsed,
                      .verifierUnavailable, .refused, .unknownWhetherPublished,
                      .cannotProveInThisBuild])
    func mightDuplicateNeverPromisesNothingWasPublished(_ error: WallError) {
        let failure = WallFailure(error, retryCost: .mightDuplicate)
        #expect(!failure.canPromiseNothingWasPublished,
                "\(error) claims nothing was published while a retry might duplicate")
    }

    /// The two shapes consistent with "it wrote the row and then fell over".
    ///
    /// The Worker inserts the signature and *then* reads the board back with two
    /// more queries, so an unreadable reply is not evidence of failure.
    @Test func theTwoAmbiguousOutcomesNeverPromiseAnything() {
        for error in [WallError.unreadableReply, .unknownWhetherPublished] {
            for cost in [WallRetryCost.resend, .startOver, .mightDuplicate, .none] {
                #expect(!WallFailure(error, retryCost: cost).canPromiseNothingWasPublished,
                        "\(error) promised nothing was published at cost \(cost)")
            }
        }
    }

    // MARK: - Which errors leave the challenge alive

    /// Everything the Worker returns *above* `claimChallenge`.
    ///
    /// Charging `startOver` for these would make the person pay for the wall's
    /// own state — a rate limit, a spent budget, a switched-off service — with
    /// another 身分證統一編號 disclosure to 內政部.
    @Test(arguments: ["unavailable", "rate-limited", "verifier-budget", "malformed"])
    func theWallsOwnStateDoesNotBurnTheChallenge(_ code: String) {
        #expect(WallResponseReader.failure(forErrorCode: code, status: 503).retryCost == .resend)
    }

    /// Everything at or below the claim.
    @Test(arguments: ["challenge-used", "verifier-unavailable"])
    func aSpentChallengeSaysSo(_ code: String) {
        #expect(WallResponseReader.failure(forErrorCode: code, status: 400).retryCost == .startOver)
    }

    /// An error code from a wall newer than this app.
    ///
    /// It cannot be known whether that branch sits above or below the INSERT, so
    /// it takes the most expensive reading. A `default` that guessed "probably
    /// failed" is exactly how a duplicate gets invited.
    @Test func anUnrecognisedCodeIsTreatedAsUnknown() {
        let failure = WallResponseReader.failure(forErrorCode: "some-future-branch", status: 500)
        #expect(failure.error == .unknownWhetherPublished)
        #expect(failure.retryCost == .mightDuplicate)
        #expect(!failure.canPromiseNothingWasPublished)
    }

    // MARK: - Reading a submit response

    @Test func aSuccessfulSubmissionCarriesTheNewCount() {
        let result = WallResponseReader.readSubmission(
            status: 200, body: Self.body(["signatureCount": 42, "recent": []]))
        #expect(result == .success(.published(signatureCount: 42)))
    }

    @Test func anExplicitRefusalIsNotAFailure() {
        let result = WallResponseReader.readSubmission(
            status: 200, body: Self.body(["verified": false]))
        // The wall worked and said no. That is an answer, not an error.
        #expect(result == .success(.refused))
    }

    /// Success and refusal share no discriminating field, so the *order* is the
    /// rule. A body carrying both must fall to refused — erring towards "your
    /// signature is not up there" cannot manufacture one that does not exist.
    @Test func aBodyCarryingBothKeysIsReadAsRefused() {
        let result = WallResponseReader.readSubmission(
            status: 200, body: Self.body(["verified": false, "signatureCount": 99]))
        #expect(result == .success(.refused))
    }

    /// The case that was live before the route existed: `/api/wall` answered
    /// **200 with the site's index.html**. A client trusting the status code
    /// would have parsed a web page as a wall.
    @Test func anHTMLPageWithATwoHundredIsNotASignature() {
        let html = Data("<!DOCTYPE html><html><body>bonds.tw</body></html>".utf8)
        let result = WallResponseReader.readSubmission(status: 200, body: html)
        guard case .failure(let failure) = result else {
            Issue.record("an HTML page was read as an outcome")
            return
        }
        #expect(failure.error == .unknownWhetherPublished)
        #expect(!failure.canPromiseNothingWasPublished)
    }

    @Test func jsonWithNoKeyThisAppKnowsIsUnknownRatherThanFailed() {
        let result = WallResponseReader.readSubmission(status: 200, body: Self.body(["ok": true]))
        guard case .failure(let failure) = result else {
            Issue.record("an unrecognised body was read as an outcome")
            return
        }
        #expect(failure.retryCost == .mightDuplicate)
    }

    // MARK: - Transport failures, which mean different things per call

    /// The reason the cost is not a property of the error.
    @Test func aTimeoutIsFreeOnTheChallengeAndAmbiguousOnTheSubmit() {
        let timeout = URLError(.timedOut)

        let onChallenge = WallResponseReader.failure(forTransport: timeout, duringSubmit: false)
        #expect(onChallenge.retryCost == .resend)
        #expect(onChallenge.canPromiseNothingWasPublished == false)

        let onSubmit = WallResponseReader.failure(forTransport: timeout, duringSubmit: true)
        // The wall may have finished the work and lost the reply.
        #expect(onSubmit.error == .unknownWhetherPublished)
        #expect(onSubmit.retryCost == .mightDuplicate)
    }

    /// A connection that never opened cannot have published anything.
    @Test(arguments: [URLError.Code.notConnectedToInternet, .dataNotAllowed,
                      .internationalRoamingOff])
    func aConnectionThatNeverOpenedIsSafeToRetry(_ code: URLError.Code) {
        let failure = WallResponseReader.failure(forTransport: URLError(code), duringSubmit: true)
        #expect(failure.retryCost == .resend)
        #expect(failure.canPromiseNothingWasPublished)
    }

    /// DNS gets its own name.
    ///
    /// "Check your connection" sends somebody to look at their Wi-Fi for a
    /// problem that is ours.
    @Test(arguments: [URLError.Code.cannotFindHost, .dnsLookupFailed])
    func aNameThatDoesNotResolveIsNotTheUsersNetwork(_ code: URLError.Code) {
        for duringSubmit in [true, false] {
            let failure = WallResponseReader.failure(forTransport: URLError(code),
                                                     duringSubmit: duringSubmit)
            #expect(failure.error == .hostDoesNotExist)
            #expect(failure.retryCost == .resend)
        }
    }

    /// `networkConnectionLost` is deliberately **not** on the safe list for
    /// submit: the connection existed, so the request may have been delivered
    /// and the reply lost.
    @Test func aDroppedConnectionDuringSubmitIsAmbiguous() {
        let failure = WallResponseReader.failure(forTransport: URLError(.networkConnectionLost),
                                                 duringSubmit: true)
        #expect(failure.retryCost == .mightDuplicate)
        #expect(!failure.canPromiseNothingWasPublished)
    }
}
