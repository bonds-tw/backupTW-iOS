//
//  VerifierScreenLifecycleTests.swift
//  backupTWTests
//
//  The screen kept the challenge on the way out and replaced it on the way back.
//

import Foundation
import Testing
@testable import backupTW

/// # Why this is a test and not a comment
///
/// Both callbacks were defensible read on their own. `viewWillDisappear` not
/// cancelling when the scanner is pushed has a comment explaining why, and the
/// reason is good. `viewWillAppear` minting a fresh challenge on every arrival
/// has a comment explaining why, and *that* reason is good too — a challenge
/// spent by being answered must not stay on screen.
///
/// The defect was only visible with both in view at once, which is why they are
/// now one type. A test that drove a `UIViewController` would not have caught it
/// either: the wrong behaviour is a perfectly ordinary sequence of correct calls.
@Suite("查驗畫面的來去")
struct VerifierScreenLifecycleTests {

    /// **The reported defect.** Push the scanner, come back, and the challenge
    /// the scanner was collecting an answer to is gone.
    ///
    /// The consequence is not a confusing screen. `challengeMismatch` is drawn
    /// as 「可能是先前出示的複本」, so an honest holder is told, in front of
    /// whoever is at the counter, that they replayed somebody's presentation.
    @Test func aRoundTripThroughTheScannerDoesNotReplaceTheLiveChallenge() {
        #expect(VerifierScreenLifecycle.leaving(forGood: false) == .stayLive)
        #expect(VerifierScreenLifecycle.arriving(hasLiveRequest: true) == .keepWaiting)
    }

    /// The two halves have to agree, and this is the pairing that says so.
    ///
    /// Asserted as a pair rather than as two separate facts because either one
    /// alone is defensible and the bug was in their disagreement. A future edit
    /// that makes arrival unconditional again passes every other test in this
    /// file.
    @Test func whatDepartureProtectsArrivalDoesNotThrowAway() {
        let stayed = VerifierScreenLifecycle.leaving(forGood: false)
        guard stayed == .stayLive else {
            Issue.record("departure no longer keeps the challenge alive; arrival's guard is now moot")
            return
        }
        #expect(VerifierScreenLifecycle.arriving(hasLiveRequest: true) != .beginNewCheck)
    }

    /// The original reason for minting on arrival, which must still hold.
    ///
    /// A challenge is cleared by being answered, so after a result there is no
    /// live request and the code on screen is replaced. Leaving the spent one up
    /// would show a challenge guaranteed to be refused.
    @Test func aSpentChallengeIsReplacedOnTheWayBackFromAResult() {
        #expect(VerifierScreenLifecycle.arriving(hasLiveRequest: false) == .beginNewCheck)
    }

    /// First arrival, before anything has been minted.
    @Test func theFirstArrivalStartsACheck() {
        #expect(VerifierScreenLifecycle.arriving(hasLiveRequest: false) == .beginNewCheck)
    }

    /// Leaving for good still ends the check, so a request that is no longer on
    /// anybody's display is no longer accepted either.
    @Test func leavingForGoodStillEndsTheCheck() {
        #expect(VerifierScreenLifecycle.leaving(forGood: true) == .endCheck)
    }
}

/// # The same rule, through the real session
///
/// The lifecycle type takes a `Bool`; these check that the `Bool` the screen
/// computes means what the type assumes. `session.pendingRequest() != nil` has to
/// be `false` exactly when a fresh challenge is wanted — after an answer, after
/// expiry, after a cancel — and `true` while one is genuinely outstanding.
@Suite("挑戰的生死與畫面的判斷一致")
struct VerifierLifecycleAgainstSessionTests {

    private static let purpose = "測試"

    @Test func aFreshlyMintedChallengeIsLive() throws {
        let session = VerifierSession()
        try session.beginCheck(purpose: Self.purpose)
        #expect(VerifierScreenLifecycle.arriving(hasLiveRequest: session.pendingRequest() != nil)
                == .keepWaiting)
    }

    @Test func aCancelledChallengeIsNotLive() throws {
        let session = VerifierSession()
        try session.beginCheck(purpose: Self.purpose)
        session.cancel()
        #expect(VerifierScreenLifecycle.arriving(hasLiveRequest: session.pendingRequest() != nil)
                == .beginNewCheck)
    }

    /// An aged-out request is the same news as no request: the holder cannot
    /// answer it any more, so the screen must mint a new one rather than leave a
    /// dead code up.
    @Test func anAgedOutChallengeIsNotLive() throws {
        let session = VerifierSession()
        let minted = try session.beginCheck(purpose: Self.purpose)
        let wellPastIt = minted.createdAt.addingTimeInterval(60 * 60 * 24)
        #expect(session.pendingRequest(now: wellPastIt) == nil)
    }
}
