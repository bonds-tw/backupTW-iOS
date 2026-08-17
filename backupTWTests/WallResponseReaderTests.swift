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
        // Asked for the contradictory combination on purpose: the initialiser
        // has to refuse it, because a caller writing these two fields by hand is
        // exactly how they end up disagreeing on screen.
        let failure = WallFailure(error, retryCost: .mightDuplicate,
                                  publication: .nothingWasPublished)
        #expect(!failure.canPromiseNothingWasPublished,
                "\(error) claims nothing was published while a retry might duplicate")
    }

    /// The two shapes consistent with "it wrote the row and then fell over".
    ///
    /// The Worker inserts the signature and *then* reads the board back with two
    /// more queries, so an unreadable reply is not evidence of failure.
    /// A challenge-call failure is always safe, by construction.
    ///
    /// `issueChallenge` contains no database statement at all, so there is
    /// nothing for it to have written. An earlier version derived this from the
    /// error and got it wrong: a twenty-second timeout on the challenge fetch
    /// reported "we do not know whether it published", about a call with no
    /// write path.
    @Test(arguments: [WallError.hostDoesNotExist, .offline, .unreadableReply,
                      .unavailable, .rateLimited])
    func aChallengeFailureAlwaysKnowsNothingWasPublished(_ error: WallError) {
        let failure = WallFailure.whileFetchingChallenge(error)
        #expect(failure.canPromiseNothingWasPublished)
        #expect(failure.retryCost == .resend)
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

    /// # The most expensive case in the file, and it depends on the session
    ///
    /// `challenge-used` means some earlier request got past `claimChallenge`.
    /// On a **retry** that earlier request was this session's own ambiguous
    /// submit — so "already spent" is the strongest evidence available that the
    /// signature exists, and promising otherwise produces the duplicate *and*
    /// a second 身分證統一編號 disclosure at once.
    @Test func aChallengeSpentByOurOwnEarlierSubmitIsNotAPromiseOfSafety() {
        let first = WallResponseReader.failure(forErrorCode: "challenge-used", status: 400,
                                               hasAlreadySubmittedThisChallenge: false)
        #expect(first.canPromiseNothingWasPublished)
        #expect(first.retryCost == .startOver)

        let afterOurOwn = WallResponseReader.failure(forErrorCode: "challenge-used", status: 400,
                                                     hasAlreadySubmittedThisChallenge: true)
        #expect(!afterOurOwn.canPromiseNothingWasPublished,
                "told somebody nothing was published, right after their own submit spent the challenge")
        #expect(afterOurOwn.retryCost == .mightDuplicate)
    }

    /// `challenge-invalid` is the one case where "was it consumed" and "does
    /// this person need a new one" give different answers.
    ///
    /// It sits above the claim, so nothing was spent — but an expired token or a
    /// rotated MAC can never become valid, and the decimal is bound into the
    /// proof, so `.resend` would loop for ever. It has its own test because it
    /// is the classification most likely to be "corrected" by somebody applying
    /// the general rule.
    @Test func anUnusableChallengeNeedsANewOneEvenThoughNothingWasSpent() {
        let failure = WallResponseReader.failure(forErrorCode: "challenge-invalid", status: 400)
        #expect(failure.retryCost == .startOver)
        #expect(failure.canPromiseNothingWasPublished)
    }

    /// Today's actual outcome: `sign-zk` is not routed, so the dispatcher
    /// answers 404 with JSON before any handler runs. Calling that "might have
    /// duplicated" would be false about a request that provably did nothing.
    @Test(arguments: [404, 405])
    func aRoutingLayerRefusalProvablyTouchedNothing(_ status: Int) {
        let failure = WallResponseReader.failure(forErrorCode: "not found", status: status)
        #expect(failure.retryCost == .resend)
        #expect(failure.canPromiseNothingWasPublished)
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

    /// The Worker's post-insert fallback: the row is written and reading the
    /// board back failed, so it answers `{verified:true}` and nothing else.
    ///
    /// An earlier version defaulted the count to zero — so the single branch
    /// built to guarantee "the signature exists" would have shown an empty wall
    /// to somebody seconds after they signed it, inviting the retry that
    /// duplicates.
    @Test func aPublishedSignatureWithNoBoardDoesNotInventACountOfZero() {
        let result = WallResponseReader.readSubmission(
            status: 200, body: Self.body(["verified": true]))
        #expect(result == .success(.published(signatureCount: nil)))
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
        // `true`. This line asserted `false` until an adversarial review pointed
        // out that `issueChallenge` contains no database statement at all — so
        // saying "we do not know whether it published" about a twenty-second
        // timeout on it was false, and pushed people away from a free retry.
        #expect(onChallenge.canPromiseNothingWasPublished)

        let onSubmit = WallResponseReader.failure(forTransport: timeout, duringSubmit: true)
        // The wall may have finished the work and lost the reply.
        #expect(onSubmit.error == .unknownWhetherPublished)
        #expect(onSubmit.retryCost == .mightDuplicate)
    }

    /// A connection that never opened cannot have published anything.
    /// Everything that fails before a single HTTP byte is written: name
    /// resolution, TCP connect, the TLS handshake, a URL that never left the
    /// process. `cannotConnectToHost` is the one that matters most — it is what
    /// a missing route or an unhealthy edge produces, which is precisely the
    /// rollout window.
    @Test(arguments: [URLError.Code.notConnectedToInternet, .dataNotAllowed,
                      .internationalRoamingOff, .cannotConnectToHost,
                      .secureConnectionFailed, .serverCertificateUntrusted,
                      .serverCertificateHasBadDate, .badURL, .unsupportedURL])
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

struct WallSignPlanTests {

    /// The ordering decision that matters most.
    ///
    /// The download can take an hour; the challenge lives thirty minutes.
    /// Fetching the number first would guarantee that a first-time signer on a
    /// slow connection watches it die — and pays for the next one with another
    /// 身分證統一編號 disclosure to 內政部.
    @Test func theBigDownloadHappensBeforeAnyClockStarts() {
        #expect(WallSignPlan.filesBeforeClock)
        let order = WallSignStage.allCases
        let files = order.firstIndex(of: .files)
        let challenge = order.firstIndex(of: .challenge)
        #expect(files != nil && challenge != nil && files! < challenge!)
        // And the clock starts before anything that costs a disclosure.
        #expect(challenge! < order.firstIndex(of: .signature)!)
    }

    /// A proof this phone refused itself never leaves it.
    ///
    /// Sending it would spend the challenge, and a new one costs another round
    /// trip to 內政部. On the proof screen a failed self-check is information;
    /// here it is a decision.
    @Test func aProofThisPhoneRefusedIsNotSent() {
        #expect(!WallSignPlan.maySubmit(selfCheck: .failed(message: "no", recoverable: false)))
    }

    /// Not having checked is not the same as having refused. The verifying keys
    /// are optional, and a phone that never looked has learned nothing.
    @Test func notHavingCheckedIsNotARefusal() {
        #expect(WallSignPlan.maySubmit(selfCheck: .unavailable(reason: "keys not installed")))
        #expect(WallSignPlan.maySubmit(selfCheck: .succeeded(detail: "ok")))
    }

    /// Every artifact goes, whatever happened.
    ///
    /// The `*_instance.bin` files carry a directly parseable nullifier —
    /// `ZKProver`'s own words call them what somebody asking to be forgotten
    /// would want rid of. The wall path has no export, so leaving them behind
    /// ends a political act with a linkable handle on the device.
    @Test func everyArtifactIncludingTheNullifierBearingOnesIsSweptUp() {
        let swept = Set(WallSignPlan.artifactsToDeleteAfterwards)
        for name in ZKProver.proofFilenames + ZKProver.instanceFilenames {
            #expect(swept.contains(name), "\(name) is left on disk after signing")
        }
        #expect(swept.contains { $0.contains("instance") },
                "the nullifier-bearing files are not swept")
    }

    /// Total mapping, so a new `ZKRunStage` fails to compile rather than landing
    /// silently in a bucket somebody has to notice on screen.
    @Test(arguments: ZKRunStage.allCases)
    func everyProofStageHasAWallStage(_ stage: ZKRunStage) {
        _ = WallSignPlan.stage(for: stage)
    }

    /// Two attempts, not a loop. A wall handing out short-lived tokens twice
    /// running is misconfigured, and each attempt is a request with somebody's
    /// address attached.
    @Test func challengesAreNotRetriedIndefinitely() {
        #expect(WallSignPlan.challengeAttempts == 2)
    }
}
