//
//  WalletMotionCoordinatorTests.swift
//  backupTWTests
//
//  The two pure gates behind the Phase 2a gyroscope sheen — the start/stop
//  conditions and the radian→tilt normalisation — plus the graceful no-op on
//  hardware with no gyroscope (the Simulator this suite runs on).
//

import CoreMotion
import Testing
@testable import backupTW

struct WalletMotionCoordinatorTests {

    // MARK: - shouldStart gate

    /// Both conditions must hold: motion available AND Reduce Motion off.
    @Test func startsOnlyWhenAvailableAndMotionAllowed() {
        #expect(WalletMotionCoordinator.shouldStart(deviceMotionAvailable: true,
                                                    reduceMotionEnabled: false))
        #expect(!WalletMotionCoordinator.shouldStart(deviceMotionAvailable: false,
                                                     reduceMotionEnabled: false))
        // Reduce Motion wins even when the hardware could supply updates: a holder
        // who stilled motion must get the static card, not the swaying one.
        #expect(!WalletMotionCoordinator.shouldStart(deviceMotionAvailable: true,
                                                     reduceMotionEnabled: true))
        #expect(!WalletMotionCoordinator.shouldStart(deviceMotionAvailable: false,
                                                     reduceMotionEnabled: true))
    }

    // MARK: - normalise clamp/scale

    /// Level device → no tilt on either axis.
    @Test func normaliseIsZeroWhenLevel() {
        let tilt = WalletMotionCoordinator.normalise(roll: 0, pitch: 0)
        #expect(tilt.x == 0)
        #expect(tilt.y == 0)
    }

    /// Within the reference range the mapping is linear: half the reference angle
    /// gives half deflection, and roll→x, pitch→y are kept distinct.
    @Test func normaliseScalesLinearlyWithinRange() {
        let half = WalletMotionCoordinator.referenceAngle / 2
        let tilt = WalletMotionCoordinator.normalise(roll: half, pitch: -half)
        #expect(abs(tilt.x - 0.5) < 0.0001)
        #expect(abs(tilt.y - (-0.5)) < 0.0001)
    }

    /// A full-reference tilt reaches exactly ±1.
    @Test func normaliseReachesUnitAtReference() {
        let ref = WalletMotionCoordinator.referenceAngle
        let tilt = WalletMotionCoordinator.normalise(roll: ref, pitch: -ref)
        #expect(abs(tilt.x - 1) < 0.0001)
        #expect(abs(tilt.y - (-1)) < 0.0001)
    }

    /// Beyond the reference angle the output holds at ±1 rather than running away
    /// — a wrist flick past the comfortable range must not over-rotate the card.
    @Test func normaliseClampsBeyondReference() {
        let far = WalletMotionCoordinator.referenceAngle * 10
        let hi = WalletMotionCoordinator.normalise(roll: far, pitch: far)
        #expect(hi.x == 1)
        #expect(hi.y == 1)
        let lo = WalletMotionCoordinator.normalise(roll: -far, pitch: -far)
        #expect(lo.x == -1)
        #expect(lo.y == -1)
    }

    // MARK: - Lifecycle no-op

    /// On a device with no gyroscope (this Simulator), `start()` must be a silent
    /// no-op: nothing running, no callback, and repeated start/stop stays safe.
    /// The assertions are gated on availability so the test also passes on real
    /// hardware.
    @Test func startIsAGracefulNoOpWithoutGyroscope() {
        let coordinator = WalletMotionCoordinator()
        var received = false
        coordinator.onTilt = { _, _ in received = true }

        // Idempotent before ever starting.
        coordinator.stop()

        coordinator.start()
        coordinator.start() // second start must not double-subscribe

        if !CMMotionManager().isDeviceMotionAvailable {
            #expect(!coordinator.isRunning)
            #expect(!received)
        }

        coordinator.stop()
        coordinator.stop() // idempotent stop
        #expect(!coordinator.isRunning)
    }
}
