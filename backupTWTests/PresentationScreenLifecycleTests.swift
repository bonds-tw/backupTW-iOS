//
//  PresentationScreenLifecycleTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// When the holder's codes rotate, and when the screen is turned up.
///
/// Both defects these cover are invisible in a screenshot. A carousel stopped on
/// frame 2 of 3 is a perfectly ordinary-looking QR code with a caption under it;
/// the only symptom is that the checker's phone never fills its counter, and the
/// instruction they are given —「請對方從第一張重新出示」— cannot help, because the
/// holder's screen is not cycling at all.
struct PresentationScreenLifecycleTests {

    /// The reported defect. This screen is used held up at arm's length in one
    /// hand, which is precisely the grip that brushes the left edge. A swipe
    /// begun and released is a cancelled pop: `viewWillDisappear` already fired,
    /// and before the fix nothing started the carousel again.
    @Test func restartsTheCarouselAfterASwipeBackTheHolderAbandoned() {
        var lifecycle = PresentationScreenLifecycle()
        #expect(lifecycle.willAppear() == .nothing)
        let signing = lifecycle.beginSigning()
        #expect(signing)
        #expect(lifecycle.finishSigning(producedFrames: true) == .startShowing)

        #expect(lifecycle.willDisappear() == .stopShowing)
        #expect(lifecycle.willAppear() == .startShowing)
    }

    /// A holder waiting at a counter brushes the edge more than once.
    @Test func restartsOnEveryReturn() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.beginSigning()
        _ = lifecycle.finishSigning(producedFrames: true)

        for _ in 0..<5 {
            #expect(lifecycle.willDisappear() == .stopShowing)
            #expect(lifecycle.willAppear() == .startShowing)
        }
    }

    /// The second half of a double tap. The work behind 「出示」 is asynchronous —
    /// a Keychain round trip, a Secure Enclave signature, Face ID — so the second
    /// tap lands while the first is still in flight and sees a screen that has
    /// not changed yet.
    ///
    /// Left unguarded it signs twice, displays twice, and raises the screen
    /// twice. The second raise is the one that costs the user something they
    /// cannot get back: see `ScreenBrightnessBoostTests`.
    @Test func aSecondTapWhileTheFirstIsStillSigningDoesNothing() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()

        let first = lifecycle.beginSigning()
        let second = lifecycle.beginSigning()
        let third = lifecycle.beginSigning()
        #expect(first)
        #expect(!second)
        #expect(!third)

        #expect(lifecycle.finishSigning(producedFrames: true) == .startShowing)
    }

    /// The guard has to lift again, or a signature that failed leaves the button
    /// permanently dead with an error on screen telling the user to try again.
    @Test func theNextTapAfterOneFinishesIsAccepted() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()

        _ = lifecycle.beginSigning()
        #expect(lifecycle.finishSigning(producedFrames: false) == .nothing)
        let retry = lifecycle.beginSigning()
        #expect(retry)
    }

    /// Signing succeeded and the codes could not be rasterised. There is nothing
    /// to rotate, so there is no reason to hold the panel at full brightness over
    /// an error message.
    @Test func aSigningThatProducedNoCodesDoesNotTurnTheScreenUp() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.beginSigning()

        #expect(lifecycle.finishSigning(producedFrames: false) == .nothing)
        #expect(!lifecycle.hasFrames)
        // And a later appearance has nothing to start either.
        _ = lifecycle.willDisappear()
        #expect(lifecycle.willAppear() == .nothing)
    }

    /// Signing that lands while the screen is away — the user backgrounded the
    /// app, or a slow Secure Enclave call finished after they navigated on. The
    /// codes exist but nothing rotates them until the screen is back.
    @Test func codesThatArriveWhileTheScreenIsAwayWaitForItToReturn() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.beginSigning()
        _ = lifecycle.willDisappear()

        #expect(lifecycle.finishSigning(producedFrames: true) == .nothing)
        #expect(lifecycle.willAppear() == .startShowing)
    }

    /// Leaving always puts the screen back, including from the states that never
    /// turned it up. Anything less relies on the raise and the restore agreeing
    /// about which states those are.
    @Test func leavingAlwaysPutsTheScreenBack() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()
        #expect(lifecycle.willDisappear() == .stopShowing)
    }

    /// Backing out of the confirmation while codes are up.
    @Test func clearingTheCodesStopsTheCarousel() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.beginSigning()
        _ = lifecycle.finishSigning(producedFrames: true)

        #expect(lifecycle.clearFrames() == .stopShowing)
        #expect(lifecycle.clearFrames() == .nothing)
        #expect(lifecycle.willAppear() == .nothing)
    }

    /// A repeated `viewWillAppear` without an intervening departure must not
    /// stack a second start on the first.
    @Test func anAppearanceWhileAlreadyVisibleChangesNothing() {
        var lifecycle = PresentationScreenLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.beginSigning()
        _ = lifecycle.finishSigning(producedFrames: true)

        #expect(lifecycle.willAppear() == .nothing)
    }
}

/// The screen brightness override, which is the part of the double-tap defect
/// the user actually pays for.
///
/// Everything else a second tap causes is recoverable by leaving the screen.
/// This is not: once the raised level has been recorded as "what it was before",
/// there is no record anywhere on the device of what the user had chosen, and
/// the phone stays at maximum brightness after they put it away. In a blackout,
/// on a battery they may not be able to charge, which is the situation this app
/// exists for.
struct ScreenBrightnessBoostTests {

    /// Stands in for the panel. `UIScreen.main.brightness` is a device-wide
    /// setting — a test that drove the real one would change the machine it runs
    /// on, and on a CI runner it would change it for every test after it.
    private final class Panel {
        var level: CGFloat
        private(set) var writes = 0

        init(_ level: CGFloat) { self.level = level }

        func boost() -> ScreenBrightnessBoost {
            ScreenBrightnessBoost(read: { self.level },
                                  write: { self.level = $0; self.writes += 1 })
        }
    }

    @Test func turnsTheScreenUpAndPutsItBackWhereItWas() {
        let panel = Panel(0.28)
        let boost = panel.boost()

        boost.raise()
        #expect(panel.level == 1.0)
        #expect(boost.isRaised)

        boost.restore()
        #expect(panel.level == 0.28)
        #expect(!boost.isRaised)
    }

    /// The defect. Two taps of 「出示」 raise twice; the second raise reads the
    /// already-raised 1.0 and records *that* as the level to go back to. Before
    /// the fix this left the panel at 1.0 for good.
    @Test func raisingTwiceDoesNotOverwriteWhatTheUserHad() {
        let panel = Panel(0.28)
        let boost = panel.boost()

        boost.raise()
        boost.raise()
        boost.restore()

        #expect(panel.level == 0.28)
    }

    /// Held to a stronger statement than the one above: a second raise is not a
    /// no-op that happens to work out, it touches nothing at all.
    @Test func raisingTwiceTouchesTheScreenOnlyOnce() {
        let panel = Panel(0.28)
        let boost = panel.boost()

        boost.raise()
        let writes = panel.writes
        boost.raise()
        boost.raise()

        #expect(panel.writes == writes)
    }

    /// Restoring what was never raised must not write anything: it would push a
    /// stale level onto a screen the user has since adjusted themselves.
    @Test func restoringWithoutHavingRaisedChangesNothing() {
        let panel = Panel(0.42)
        let boost = panel.boost()

        boost.restore()

        #expect(panel.level == 0.42)
        #expect(panel.writes == 0)
    }

    /// Show, leave, show again — the ordinary way this screen is used twice. The
    /// second cycle has to pick up whatever the user has set since, not replay
    /// the level from the first.
    @Test func eachCycleRestoresTheLevelThatCycleFound() {
        let panel = Panel(0.28)
        let boost = panel.boost()

        boost.raise()
        boost.restore()
        #expect(panel.level == 0.28)

        panel.level = 0.65
        boost.raise()
        #expect(panel.level == 1.0)
        boost.restore()
        #expect(panel.level == 0.65)
    }

    /// A repeated departure — `viewWillDisappear` can be followed by another
    /// teardown path — must not write a stale level back a second time.
    @Test func restoringTwiceWritesOnlyOnce() {
        let panel = Panel(0.28)
        let boost = panel.boost()

        boost.raise()
        boost.restore()
        panel.level = 0.9
        boost.restore()

        #expect(panel.level == 0.9)
    }
}
