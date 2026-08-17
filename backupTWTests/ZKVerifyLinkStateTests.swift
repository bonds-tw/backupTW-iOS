//
//  ZKVerifyLinkStateTests.swift
//  backupTWTests
//
//  The pairing code and the radio are one thing, and this is the file that says
//  so out loud.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// # What went wrong
///
/// `.finished` calls `stopLink()` first thing. `beginEngagement()` — the only
/// place that mints an identifier, draws a code and starts a scanner — had one
/// caller: `viewWillAppear`. Nothing re-opened it, and the file picker is a
/// sheet so it does not re-trigger appearance either.
///
/// So after one proof the code stayed on screen with nothing listening behind
/// it. The next person scanned it, their phone broadcast into an empty room and
/// sat at 「ready — waiting for the checker's phone」 (there is no advertising
/// timeout), and the checker's screen did not change by a pixel: the *previous*
/// person's verdict had just been lifted to the top, with no timestamp anywhere
/// on the screen to say it was old.
///
/// The screen's own comment says 「a code drawn without a scanner running is a
/// code that does nothing when scanned … `engagement` exists so the two cannot
/// drift」. This is the assertion that comment implies and never had.
@MainActor
struct ZKVerifyLinkStateTests {

    /// Puts the controller through a real appearance cycle, which is what starts
    /// the engagement.
    private static func onScreen() -> (ZKVerifyViewController, UIWindow) {
        let controller = ZKVerifyViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        return (controller, window)
    }

    /// The invariant, stated once and checked at all three points.
    private func agree(_ controller: ZKVerifyViewController, _ moment: String) {
        #expect(controller.radioIsListeningForReview == controller.pairingCodeIsShownForReview,
                "code and radio have drifted apart \(moment): code shown \(controller.pairingCodeIsShownForReview), radio listening \(controller.radioIsListeningForReview)")
    }

    @Test func aProofThatArrivesTakesThePairingCodeDownWithTheRadio() {
        let (controller, window) = Self.onScreen()
        defer { window.isHidden = true }

        agree(controller, "while waiting")
        // Only when this phone could actually answer the invitation — see
        // `ZKCheckingAvailability`. A simulator with no downloaded verifying
        // keys is in the same position as a shipped build, and this screen must
        // not put a live code up in that state.
        #expect(controller.pairingCodeIsShownForReview == controller.canCheckAProofForReview)
        #expect(!controller.nextPersonIsOfferedForReview)
        guard controller.canCheckAProofForReview else { return }

        // Three bytes that are not a package: the branch where the transfer
        // finished, the radio went off, and no verdict was ever reached. It used
        // to leave the radio off permanently over a proof nobody judged.
        controller.receiveForReview(.finished(payload: Data([0x00, 0x01, 0x02])))

        agree(controller, "after a transfer finished")
        #expect(!controller.radioIsListeningForReview)
        #expect(!controller.pairingCodeIsShownForReview,
                "the code is still on screen with nothing listening behind it")
        #expect(controller.nextPersonIsOfferedForReview,
                "the radio is off and nothing on screen offers a way to start again")
    }

    /// And the way back is a new engagement, not the old code.
    @Test func askingForTheNextPersonClearsTheLastOneBeforeOpeningUpAgain() {
        let (controller, window) = Self.onScreen()
        defer { window.isHidden = true }

        controller.showForReview(status: "這支手機查驗過了，通過",
                                 detail: "花了 8.4 秒",
                                 caveats: ProofCaveat.unconditional.map(\.localizedDescription),
                                 verdict: true)
        controller.receiveForReview(.finished(payload: Data([0x00])))
        #expect(controller.verdictIsShownForReview == false || !controller.pairingCodeIsShownForReview,
                "a live pairing code and the previous person's verdict are on screen together")

        controller.checkNextPersonForReview()
        window.layoutIfNeeded()

        agree(controller, "after asking for the next person")
        #expect(controller.pairingCodeIsShownForReview == controller.canCheckAProofForReview)
        #expect(!controller.verdictIsShownForReview,
                "the next person's code is up and the last person's verdict is still on screen")
        #expect(!controller.nextPersonIsOfferedForReview)
    }

    /// The wake lock is held for exactly as long as the code is up.
    ///
    /// Measured 21.7 seconds end to end, during which nobody touches this phone
    /// — and Low Power Mode pins Auto-Lock at 30 seconds with no way to change
    /// it. Losing the screen kills `BluetoothLinkCentral` permanently: there is
    /// no reconnect path, so recovery means leaving and returning, which mints a
    /// new code for the other person to scan again.
    @Test func theScreenIsHeldAwakeWhileThisScreenIsUp() {
        let before = AppScreenWakeLock.shared.holderCount
        let (controller, window) = Self.onScreen()
        #expect(AppScreenWakeLock.shared.holderCount > before,
                "the one screen that has to survive 21.7 seconds does not hold the screen awake")

        controller.beginAppearanceTransition(false, animated: false)
        window.rootViewController = nil
        controller.endAppearanceTransition()
        window.isHidden = true
        #expect(AppScreenWakeLock.shared.holderCount == before,
                "the wake lock outlived the screen — it is process-global")
    }
}

/// A screen that cannot check a proof must not invite one.
///
/// # Two instructions on one screen, and the cost lands on the other person
///
/// In a shipped build `ZKVerifyingKeyAssets.areInstalled` is permanently false —
/// the only path that writes verifying keys sits behind
/// `ZKProofRunAssembly.makeSigner`, nil in release, and no `.key` ships in the
/// bundle. The screen said so at load: 「this version cannot download the files …
/// tell them before they send one.」 Then `viewWillAppear` drew a pairing code
/// and started listening anyway, and the invitation sat four views *above* the
/// disqualification — 「ask them to scan the code above」 at the top, the sentence
/// that withdraws it below the fold.
///
/// `verify(package:)` never asked either, so a proof really did arrive,
/// reassemble, spin for fifteen seconds, and come back 「no verdict」.
@MainActor
struct ZKCheckingAvailabilityTests {

    @Test func theThreeStatesAreDistinguishedAndSayDifferentThings() {
        let sentences = [ZKCheckingAvailability.ready.sentence,
                         ZKCheckingAvailability.notDownloadedYet.sentence,
                         ZKCheckingAvailability.impossibleInThisBuild.sentence]
        #expect(Set(sentences).count == 3, "two of the three states say the same thing")
        #expect(ZKCheckingAvailability.ready.canCheck)
        #expect(!ZKCheckingAvailability.notDownloadedYet.canCheck)
        #expect(!ZKCheckingAvailability.impossibleInThisBuild.canCheck)
    }

    /// 「Yet」 is a promise, and only one of the three states can keep it.
    @Test func onlyTheStateThatCanDownloadSaysYet() {
        for promise in ["yet", "還沒", "尚未"] {
            #expect(!ZKCheckingAvailability.impossibleInThisBuild.sentence.contains(promise),
                    "a build that can never download says 「\(promise)」")
        }
    }

    /// And the screen's own invitation follows it.
    @Test func theScreenOffersNoPairingCodeWhenItCannotCheck() {
        let controller = ZKVerifyViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        #expect(controller.pairingCodeIsShownForReview == controller.canCheckAProofForReview,
                "the screen invites a transfer it cannot check")
        #expect(controller.radioIsListeningForReview == controller.canCheckAProofForReview)
    }
}
