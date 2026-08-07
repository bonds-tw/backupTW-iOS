//
//  QRScannerLifecycleTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// When the scanner's camera is allowed to run.
///
/// These are sequence tests, and a sequence is the one thing this screen cannot
/// be checked for any other way. The simulator has no camera, so it never
/// reaches the affected state at all; on a phone, a stopped `AVCaptureSession`
/// leaves `AVCaptureVideoPreviewLayer` holding its last frame, so the broken
/// screen and the working screen are the same picture — a still of the counter,
/// scanning nothing, with no error anywhere on it. The person holding the phone
/// finds out by waiting.
struct QRScannerLifecycleTests {

    /// The reported defect. A drag from the left edge that is released short of
    /// the threshold is a *cancelled* pop: UIKit has already sent
    /// `viewWillDisappear` to this instance and now sends `viewWillAppear` to the
    /// same instance again. Before the fix nothing restarted the session, because
    /// configuration ran once from `viewDidLoad` and never again.
    @Test func restartsTheCameraAfterASwipeBackTheUserAbandoned() {
        var lifecycle = QRScannerLifecycle()
        #expect(lifecycle.willAppear() == .prepare)
        #expect(lifecycle.didPrepare(succeeded: true) == .start)

        #expect(lifecycle.willDisappear() == .stop)
        #expect(lifecycle.willAppear() == .start)
    }

    /// And again, and again. A user who fidgets with the edge of the screen
    /// while waiting for someone to find their phone does this several times.
    @Test func restartsOnEveryReturn() {
        var lifecycle = QRScannerLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.didPrepare(succeeded: true)

        for _ in 0..<5 {
            #expect(lifecycle.willDisappear() == .stop)
            #expect(lifecycle.willAppear() == .start)
        }
    }

    /// Restarting must not mean reconfiguring. A second `AVCaptureDeviceInput`
    /// and a second preview layer stacked on the first is a different bug with
    /// the same trigger.
    @Test func attachesTheCameraOnlyOnce() {
        var lifecycle = QRScannerLifecycle()
        #expect(lifecycle.willAppear() == .prepare)
        _ = lifecycle.didPrepare(succeeded: true)

        _ = lifecycle.willDisappear()
        #expect(lifecycle.willAppear() != .prepare)
        _ = lifecycle.willDisappear()
        #expect(lifecycle.willAppear() != .prepare)
    }

    /// The permission dialog is modal over this screen, and the user can walk
    /// away from it. A grant that lands afterwards must not switch the camera on
    /// behind whatever screen is now in front — that is the lit camera indicator
    /// this file goes out of its way to avoid, and it would be lit over an
    /// unrelated screen.
    @Test func aGrantThatArrivesAfterTheUserLeftDoesNotOpenTheCamera() {
        var lifecycle = QRScannerLifecycle()
        #expect(lifecycle.willAppear() == .prepare)
        #expect(lifecycle.willDisappear() == .stop)

        #expect(lifecycle.didPrepare(succeeded: true) == .nothing)

        // Coming back turns it on, without asking for the camera a second time.
        #expect(lifecycle.willAppear() == .start)
    }

    /// The path a developer sees on every single run, and every phone whose
    /// camera an MDM profile has taken away. There is nothing to restart, and
    /// pretending otherwise would start an unconfigured session.
    @Test func aDeviceWithNoUsableCameraHasNothingToRestart() {
        var lifecycle = QRScannerLifecycle()
        _ = lifecycle.willAppear()
        #expect(lifecycle.didPrepare(succeeded: false) == .nothing)

        #expect(lifecycle.willDisappear() == .stop)
        #expect(lifecycle.willAppear() == .nothing)
    }

    /// Once the caller has what it needed the camera stays off, including
    /// through an appearance the fix above would otherwise restart. The result
    /// screen is pushed asynchronously and this screen can be on its way out
    /// while that happens.
    @Test func nothingBringsTheCameraBackAfterTheCallerSaidStop() {
        var lifecycle = QRScannerLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.didPrepare(succeeded: true)

        #expect(lifecycle.didFinish() == .stop)
        #expect(lifecycle.isFinished)

        #expect(lifecycle.willDisappear() == .stop)
        #expect(lifecycle.willAppear() == .nothing)
    }

    /// Configuration that somehow reports back twice changes nothing the second
    /// time — in particular it cannot revive a scanner that has already stopped.
    @Test func aSecondPreparationResultIsIgnored() {
        var lifecycle = QRScannerLifecycle()
        _ = lifecycle.willAppear()
        _ = lifecycle.didPrepare(succeeded: true)
        _ = lifecycle.didFinish()

        #expect(lifecycle.didPrepare(succeeded: true) == .nothing)
        #expect(lifecycle.isFinished)
    }

    /// Nothing is asked of the camera until the screen is actually in front of
    /// the user: `viewDidLoad` runs for a controller that is being pushed and can
    /// still be interrupted.
    @Test func asksForNothingBeforeTheFirstAppearance() {
        let lifecycle = QRScannerLifecycle()
        #expect(lifecycle.camera == .idle)
        #expect(!lifecycle.isVisible)
        #expect(!lifecycle.isFinished)
    }
}
