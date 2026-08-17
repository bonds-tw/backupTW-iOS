//
//  CheckerClockTests.swift
//  backupTWTests
//
//  A checker whose own phone has the wrong date must not be told the document
//  is the problem.
//

import Foundation
import Testing
@testable import backupTW

/// # The comparison has no accuser
///
/// This is the same shape as the first audit round's `a-6`, two certificates
/// earlier. There, two clock readings were subtracted and the loser was told the
/// *other* device was wrong. Here the reading is compared against a certificate's
/// `notBefore` — the bundled anchor's is 2022-06-07 — and a phone whose clock has
/// slipped before it fails every document it sees.
///
/// Both certificate checks used to `catch` bare and drop the error, so the two
/// cases `IssuerCertificateError.isRecoverable` exists to name arrived on screen
/// as ⛔️ 「not accepted」 with one of two sentences pointing in wrong directions:
/// update the app, or renew a certificate that is perfectly valid — the branch
/// means *not valid yet*, the opposite direction.
struct CheckerClockTests {

    @Test func theTwoClockErrorsAreTheOnesIssuerCertificateAlreadyNamed() {
        let from = Date(timeIntervalSince1970: 1_654_560_000)
        for error in [IssuerCertificateError.trustAnchorNotYetValid(from: from),
                      .holderCertificateNotYetValid(from: from)] {
            #expect(error.isRecoverable)
            #expect(error.validFrom == from)
        }
        // And the far end of the window is a different fact, not this one.
        #expect(IssuerCertificateError.trustAnchorExpired(on: from).validFrom == nil)
        #expect(IssuerCertificateError.holderCertificateExpired(on: from).validFrom == nil)
    }

    /// The two outcomes that say nothing about the document must not wear the
    /// verdict that does.
    @Test func aFailureAboutThisPhoneIsNotAJudgementOnTheDocument() {
        #expect(VerificationFailure.trustAnchorUnavailable.isAboutThisDevice)
        #expect(VerificationFailure
            .deviceClockPrecedesCertificate(validFrom: Date()).isAboutThisDevice)
        // The ones that *are* about the document.
        for failure: VerificationFailure in [.cardSignatureInvalid,
                                             .cardholderCertificateRevoked,
                                             .cardholderCertificateUnusable,
                                             .credentialExpired,
                                             .presentationDatedInTheFuture(skew: 180)] {
            #expect(!failure.isAboutThisDevice, "\(failure) accuses this phone instead of the document")
        }
    }

    /// The message must not send the reader in either of the two wrong
    /// directions the discarded errors used to produce.
    @Test func theMessageBlamesNeitherTheAppNorTheirCertificate() {
        let message = VerificationFailure
            .deviceClockPrecedesCertificate(validFrom: Date(timeIntervalSince1970: 1_654_560_000))
            .message
        // Not "update the app", and not "it has expired" — this branch is the
        // opposite direction from expiry.
        for wrong in ["expired", "已經過期", "更新這個 App", "update the app"] {
            #expect(!message.contains(wrong), "the clock message says \(wrong): \(message)")
        }
        // It names the date and points at this phone, in whichever language ships.
        #expect(message.contains("2022"))
        for right in ["this phone", "這支手機"] where message.contains(right) {
            return
        }
        Issue.record("the clock message never says which device to check: \(message)")
    }
}
