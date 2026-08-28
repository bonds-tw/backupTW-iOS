//
//  PresentedRequestFreshnessTests.swift
//  backupTWTests
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// Whether the holder is told how old the checker's code is.
///
/// `PresentationRequest.createdAt` documents itself as existing 「so the holder
/// can be shown a request that is obviously stale」 and the holder's side never
/// read it. The consequence is not subtle: a code taped to a shop door, or one
/// photographed three weeks earlier and sent round a LINE group, produced a
/// confirmation screen identical in every pixel to a person standing at a counter
/// asking to see your ID. The user agreed to hand over their name, ID number,
/// birth date and household address on the strength of that screen.
///
/// These tests are about the screen, not about the cryptography — `createdAt` is
/// unauthenticated and no test here pretends otherwise. What is being pinned is
/// that the app says out loud what it knows.
@MainActor
struct PresentedRequestFreshnessTests {

    private static let now = Date(timeIntervalSince1970: 1_754_400_000)

    // MARK: - The rule

    /// The scenario from the report, to the day.
    @Test func aRequestFromThreeWeeksAgoIsStale() throws {
        let request = try Self.request(createdAt: Self.now.addingTimeInterval(-21 * 24 * 60 * 60))

        let freshness = PresentCredentialViewController.freshness(of: request, now: Self.now)

        guard case .stale(let age) = freshness else {
            Issue.record("a three-week-old request was not reported as stale: \(freshness)")
            return
        }
        #expect(age == 21 * 24 * 60 * 60)
    }

    /// A code the checker minted while the holder was walking up to the counter.
    /// The warning has to stay off here or it stops meaning anything.
    @Test func aRequestMintedSecondsAgoIsFresh() throws {
        let request = try Self.request(createdAt: Self.now.addingTimeInterval(-8))

        #expect(PresentCredentialViewController.freshness(of: request, now: Self.now) == .fresh)
    }

    /// Two phones whose clocks disagree by a couple of minutes are two ordinary
    /// phones. Warning about them would train the user to tap past the warning on
    /// the day it is real.
    @Test func anOrdinaryClockDisagreementIsNotReportedAsStale() throws {
        let justInside = PresentCredentialViewController.staleRequestThreshold - 1
        let request = try Self.request(createdAt: Self.now.addingTimeInterval(-justInside))

        #expect(PresentCredentialViewController.freshness(of: request, now: Self.now) == .fresh)
    }

    /// The threshold is derived, not chosen: below it the checker's own device
    /// would still be holding the challenge, so a warning would be a warning
    /// about a code that was about to work.
    @Test func theThresholdIsTheCheckersOwnRequestLifetimePlusTheClockBudget() {
        #expect(PresentCredentialViewController.staleRequestThreshold
                == VerifierSession.pendingRequestLifetime + OfflineVerifier.maximumClockSkew)
    }

    /// A code dated into the future makes the staleness test meaningless, and
    /// saying nothing would leave the holder believing one had been run.
    @Test func aRequestDatedBeyondTheClockBudgetIsReported() throws {
        let request = try Self.request(createdAt: Self.now.addingTimeInterval(OfflineVerifier.maximumClockSkew + 60))

        guard case .datedInTheFuture(let skew) = PresentCredentialViewController.freshness(of: request, now: Self.now) else {
            Issue.record("a request dated past the clock budget was accepted as fresh")
            return
        }
        #expect(skew == OfflineVerifier.maximumClockSkew + 60)
    }

    // MARK: - What the holder is shown

    @Test func aFreshRequestProducesNoWarningText() {
        #expect(PresentCredentialViewController.stalenessWarning(for: .fresh) == nil)
    }

    /// A warning nobody can read is not a warning. Both halves have to be there,
    /// and the detail has to name a duration rather than say 「已過期」 — the whole
    /// question the holder is being asked to judge is *how* old.
    @Test func bothWarningsHaveSomethingToShowAHuman() {
        for freshness in [PresentCredentialViewController.RequestFreshness.stale(age: 21 * 24 * 60 * 60 as TimeInterval),
                          .datedInTheFuture(skew: 600)] {
            guard let warning = PresentCredentialViewController.stalenessWarning(for: freshness) else {
                Issue.record("\(freshness) produced no warning")
                continue
            }
            #expect(!warning.title.isEmpty)
            #expect(!warning.detail.isEmpty)
            // `%@` unreplaced means the duration never made it into the sentence.
            #expect(!warning.detail.contains("%@"), "\(freshness) left its format specifier in: \(warning.detail)")
        }
    }

    // MARK: - On the screen the user taps 「出示」 on

    /// The end of the chain, and the only part of it the user meets. A rule that
    /// computes correctly and is then not drawn is the same defect in a different
    /// place.
    @Test func theConfirmationScreenShowsTheWarningForAnOldCode() throws {
        let screen = Self.screen()
        let stale = try Self.request(createdAt: Self.now.addingTimeInterval(-21 * 24 * 60 * 60))

        let decision = screen.acceptScannedRequest(try stale.encodedForTransport(), now: Self.now)

        #expect(decision == .stop)
        let warning = try #require(PresentCredentialViewController.stalenessWarning(for: .stale(age: 21 * 24 * 60 * 60 as TimeInterval)))
        let shown = Self.labelText(in: screen.view)
        #expect(shown.contains(where: { $0.contains(warning.title) }),
                "the confirmation screen does not show the stale-code warning: \(shown)")
        // The reason the checker typed is still there — this is a warning beside
        // the request, not a refusal that replaces it.
        #expect(shown.contains(where: { $0.contains(stale.purpose) }))
    }

    @Test func theConfirmationScreenIsUnchangedForACodeMadeJustNow() throws {
        let screen = Self.screen()
        let fresh = try Self.request(createdAt: Self.now.addingTimeInterval(-5))

        screen.acceptScannedRequest(try fresh.encodedForTransport(), now: Self.now)

        let warning = try #require(PresentCredentialViewController.stalenessWarning(for: .stale(age: 999_999 as TimeInterval)))
        let shown = Self.labelText(in: screen.view)
        #expect(!shown.contains(where: { $0.contains(warning.title) }),
                "a code made five seconds ago was flagged as stale")
        #expect(shown.contains(where: { $0.contains(fresh.purpose) }))
    }

    /// Anything that is not one of our requests is still ignored per video frame,
    /// silently. Lifting the callback out of the scanner must not have changed
    /// that: an error banner thirty times a second is what the original closure
    /// was written to avoid.
    @Test func aQRCodeThatIsNotARequestKeepsTheScannerRunning() {
        let screen = Self.screen()

        #expect(screen.acceptScannedRequest("https://mydata.nat.gov.tw", now: Self.now)
                == .keepScanning(status: nil))
    }

    // MARK: - Fixtures

    private static func request(createdAt: Date) throws -> PresentationRequest {
        try PresentationRequest(challenge: "AAAAAAAAAAAAAAAAAAAAAA",
                                purpose: "Identity check",
                                createdAt: createdAt)
    }

    private static func screen() -> PresentCredentialViewController {
        let screen = PresentCredentialViewController(holder: HolderPresentation(store: StubStore()))
        // Loaded, not presented: `render()` writes into a stack view that
        // `viewDidLoad` builds, and nothing below needs a window.
        screen.loadViewIfNeeded()
        return screen
    }

    private static func labelText(in root: UIView) -> [String] {
        var found: [String] = []
        if let text = (root as? UILabel)?.text { found.append(text) }
        for subview in root.subviews { found.append(contentsOf: labelText(in: subview)) }
        return found
    }

    /// Reports one credential so the screen does not fall straight into
    /// `.nothingToShow`, and never has to produce it: none of these tests signs.
    private struct StubStore: CredentialStoring {
        func save(jws: String, id: String) throws {}
        func load(id: String) throws -> String? { nil }
        func allIDs() throws -> [String] { ["urn:test:credential"] }
        func delete(id: String) throws {}
        func deleteAll() throws {}
    }
}
