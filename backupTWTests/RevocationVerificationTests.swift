//
//  RevocationVerificationTests.swift
//  backupTWTests
//
//  What a revocation answer does to a verification.
//

import Foundation
import Testing
@testable import backupTW

// The other half of this — *when* the question gets asked, and that it is not
// asked about a presentation whose signature never verified — needs the
// presentation fixtures, which are file-private to `OfflineVerifierTests`. It
// lives there, under `RevocationLookupOrderTests`.

private let snapshot = RevocationSnapshotInfo(root: "0xa2ed" + String(repeating: "0", count: 60),
                                              crlNumber: 2_026_050_323,
                                              entryCount: 115_584)

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
            _ = try OfflineVerifier.caveat(for: .revoked(snapshot: snapshot))
        }
    }

    /// And the refusal must not read as an accusation of forgery — the commonest
    /// reason a 自然人憑證 is revoked is that the card was lost or replaced, and
    /// the person holding out the phone is very likely its rightful owner with an
    /// out-of-date document.
    @Test func theRefusalTellsThemWhatToDoRatherThanAccusingThem() {
        let message = VerificationFailure.cardholderCertificateRevoked.message

        #expect(message.contains("revoked"))
        #expect(message.contains("issued again"))
        for accusation in ["forged", "fake", "altered", "invalid"] {
            #expect(!message.lowercased().contains(accusation),
                    "the message calls a replaced card \(accusation)")
        }
    }

    @Test func anAbsentCertificateEarnsTheHedgedSentence() throws {
        let caveat = try OfflineVerifier.caveat(for: .notRevokedInThisSnapshot(snapshot: snapshot))

        #expect(caveat == .revocationCheckedInLocalSnapshotOnly)
        // The wording is the whole feature. A verifier told 「未被撤銷」 has been
        // told something this check does not establish — the list is dated and
        // its authenticity is unconfirmed — so the sentence has to keep saying
        // where the answer came from.
        #expect(caveat.message.contains("stored on this device"))
        #expect(caveat.message.contains("cannot confirm"))
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
        let caveat = try OfflineVerifier.caveat(for: .notChecked(reason: reason))

        #expect(caveat == .revocationNotChecked)
    }

    /// A caveat with no message would be a caveat nobody sees, and this enum has
    /// grown a case before.
    @Test(arguments: VerificationCaveat.allCases)
    func everyCaveatHasSomethingToSay(_ caveat: VerificationCaveat) {
        #expect(!caveat.message.isEmpty)
    }
}
