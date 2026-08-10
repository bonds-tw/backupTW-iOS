//
//  RevocationVerificationTests.swift
//  backupTWTests
//
//  What a revocation answer does to a verification.
//

import Foundation
import UIKit
import Testing
@testable import backupTW

// The other half of this — *when* the question gets asked, and that it is not
// asked about a presentation whose signature never verified — needs the
// presentation fixtures, which are file-private to `OfflineVerifierTests`. It
// lives there, under `RevocationLookupOrderTests`.

private let snapshot = RevocationSnapshotInfo(root: "0xa2ed" + String(repeating: "0", count: 60),
                                              crlNumber: 2_026_050_323,
                                              entryCount: 115_584)

/// One hour after the fixture snapshot was made — comfortably inside the
/// 72-hour freshness window, so tests that are not about staleness read as the
/// ordinary case.
private let anHourAfterTheSnapshot = snapshot.generatedAt!.addingTimeInterval(3600)

/// `OfflineVerifier.caveat(for:)` is the only part of the revocation path a test
/// can reach end to end. Everything upstream needs a certificate 內政部 issued
/// to a real person — `IssuerCertificate` pins the MOICA G3 anchor by digest so
/// a test cannot substitute a CA of its own, which is why
/// `CardSignedPresentationTests` has no happy path either. A three-way decision
/// reachable only on device would be one nobody had ever watched take two of its
/// branches.
struct RevocationVerdictTests {

    /// Being on the list is a refusal, not a footnote.
    ///
    /// The asymmetry with the case below is deliberate and follows from which way
    /// a stale list can be wrong: an old list can miss a revocation that has
    /// since happened, but it cannot invent one. A serial is in the tree because
    /// 內政部 published a CRL saying so.
    @Test func aRevokedCertificateRefusesThePresentation() {
        #expect(throws: VerificationFailure.cardholderCertificateRevoked) {
            _ = try OfflineVerifier.caveat(for: .revoked(snapshot: snapshot), now: anHourAfterTheSnapshot)
        }
    }

    /// And the refusal must not read as an accusation of forgery — the commonest
    /// reason a 自然人憑證 is revoked is that the card was lost or replaced, and
    /// the person holding out the phone is very likely its rightful owner with an
    /// out-of-date document.
    ///
    /// Asserted against the **Chinese**, which is what a checker at a counter in
    /// Taiwan actually reads. The first version of this test matched English
    /// substrings of `message` and passed — because the string had no `zh-Hant`
    /// entry yet, so `message` returned its own key. It went red the moment the
    /// translation landed. A wording test that only holds while the wording is
    /// untranslated is testing the bug.
    @Test func theRefusalTellsThemWhatToDoRatherThanAccusingThem() throws {
        let chinese = try #require(Self.chinese(for:
            "The digital certificate that signed this document has been revoked. The document needs to be issued again with a current certificate."))

        #expect(chinese.contains("重新簽發"), "the message does not say what to do next")
        for accusation in ["偽造", "假的", "竄改", "無效"] {
            #expect(!chinese.contains(accusation),
                    "a replaced card is described as \(accusation)")
        }
    }

    @Test func anAbsentCertificateEarnsTheHedgedSentence() throws {
        let caveat = try OfflineVerifier.caveat(for: .notRevokedInThisSnapshot(snapshot: snapshot), now: anHourAfterTheSnapshot)
        #expect(caveat == .revocationCheckedInLocalSnapshotOnly)

        // Two different sentences, always. Collapsing them would make "we did
        // not look" and "we looked and it is not listed" read alike.
        #expect(caveat.message != VerificationCaveat.revocationNotChecked.message)

        // The wording is the whole feature. A verifier told 「未被撤銷」 has been
        // told something this check does not establish — the list is dated and
        // its authenticity is unconfirmed — so the sentence has to keep saying
        // where the answer came from.
        let chinese = try #require(Self.chinese(for:
            "The signing certificate was checked against a revocation list stored on this device and is not on it. That list has a date, and this app cannot confirm it is the genuine current one."))
        #expect(chinese.contains("這支手機"), "the sentence does not say where the answer came from")
        #expect(chinese.contains("無法確認"), "the sentence does not say what remains unconfirmed")
    }

    /// The shipping Chinese for a string, looked up by the English key the source
    /// uses. `nil` when there is no translation — which is a failure worth
    /// naming rather than a reason to fall back to English.
    private static func chinese(for englishKey: String) -> String? {
        guard let path = Bundle(for: VerifierViewController.self)
                  .path(forResource: "zh-Hant", ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let sentinel = "__no-translation__"
        let value = bundle.localizedString(forKey: englishKey, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    /// Every reason for not looking lands on the same sentence, and it is a
    /// different sentence from the one above. A screen that rendered "we did not
    /// look" and "we looked and it is not listed" alike would turn the absence of
    /// a check into a clean bill of health.
    @Test(arguments: [RevocationStatus.NotCheckedReason.snapshotUnavailable,
                      .snapshotUnusable,
                      .proofDidNotVerify,
                      .noCertificateToCheck])
    func notLookingIsNeverReportedAsLooking(_ reason: RevocationStatus.NotCheckedReason) throws {
        let caveat = try OfflineVerifier.caveat(for: .notChecked(reason: reason), now: anHourAfterTheSnapshot)

        #expect(caveat == .revocationNotChecked)
    }

    /// A caveat with no message would be a caveat nobody sees, and this enum has
    /// grown a case before.
    @Test(arguments: VerificationCaveat.allCases)
    func everyCaveatHasSomethingToSay(_ caveat: VerificationCaveat) {
        #expect(!caveat.message.isEmpty)
    }
}

// MARK: - How old is too old to stay quiet about

/// The threshold changes a sentence, never a verdict — because of which way a
/// stale list can be wrong. An old list can miss a revocation published after
/// it; it cannot invent one. So `.revoked` stays a rejection at any age, and
/// what ages out is only the right to imply the silence is fresh.
struct RevocationFreshnessTests {

    /// 72 h: upstream rebuilds twice a day with a measured publish lag topping
    /// out around 3.4 h, so a device online at any point in the last day holds a
    /// list under ~52 h old. Past 72 the device has been offline a while — the
    /// exact situation this app exists for, which is why the check is not
    /// withheld, only re-worded.
    @Test func theFreshSentenceEndsExactlyAtTheThreshold() throws {
        let made = try #require(snapshot.generatedAt)
        let justInside = made.addingTimeInterval(OfflineVerifier.maximumSnapshotFreshness - 1)
        let justOutside = made.addingTimeInterval(OfflineVerifier.maximumSnapshotFreshness + 1)

        #expect(try OfflineVerifier.caveat(for: .notRevokedInThisSnapshot(snapshot: snapshot),
                                           now: justInside)
                == .revocationCheckedInLocalSnapshotOnly)
        #expect(try OfflineVerifier.caveat(for: .notRevokedInThisSnapshot(snapshot: snapshot),
                                           now: justOutside)
                == .revocationCheckedInStaleSnapshot)
    }

    /// A snapshot whose date cannot be read gets the stale sentence. "We cannot
    /// say when this list was made" and "this list is old" both mean its silence
    /// must not be read as fresh.
    @Test func anUndatableSnapshotIsTreatedAsStale() throws {
        let undatable = RevocationSnapshotInfo(root: "0xab", crlNumber: 999, entryCount: 1)
        #expect(undatable.generatedAt == nil)

        #expect(try OfflineVerifier.caveat(for: .notRevokedInThisSnapshot(snapshot: undatable),
                                           now: anHourAfterTheSnapshot)
                == .revocationCheckedInStaleSnapshot)
    }

    /// The one thing age must never do. A serial in the tree was put there by a
    /// published CRL; three months do not un-publish it.
    @Test func aRevokedCertificateIsRefusedAtAnyAge() throws {
        let made = try #require(snapshot.generatedAt)
        let monthsLater = made.addingTimeInterval(90 * 24 * 3600)

        #expect(throws: VerificationFailure.cardholderCertificateRevoked) {
            _ = try OfflineVerifier.caveat(for: .revoked(snapshot: snapshot), now: monthsLater)
        }
    }

    /// And the stale sentence is still a "we looked" sentence — it must never
    /// collapse into the "we did not look" one.
    @Test func staleIsStillDistinctFromNotChecked() throws {
        let made = try #require(snapshot.generatedAt)
        let monthsLater = made.addingTimeInterval(90 * 24 * 3600)

        let caveat = try OfflineVerifier.caveat(for: .notRevokedInThisSnapshot(snapshot: snapshot),
                                                now: monthsLater)
        #expect(caveat == .revocationCheckedInStaleSnapshot)
        #expect(caveat != .revocationNotChecked)
        #expect(caveat.message != VerificationCaveat.revocationNotChecked.message)
    }
}

