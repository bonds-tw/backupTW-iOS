//
//  WalletMotionCoordinator.swift
//  backupTW
//
//  Phase 2a: the device-motion source that drives the wallet cards' reflective
//  sheen and micro-tilt.
//
//  # Why this is its own object
//
//  The card views know how to *apply* a tilt (`WalletCardView.applyTilt`); they
//  do not know where it comes from. Keeping the `CMMotionManager` here — owned by
//  the screen, not by any card — means a single sensor stream feeds every visible
//  card, starts when the screen appears and stops when it leaves, and never keeps
//  updating for cells nobody can see. One manager, one lifecycle, no per-cell
//  sensors.
//
//  # The two gates, and why they are pure
//
//  Motion must not start when the hardware cannot supply it (the Simulator has no
//  gyroscope) or when the holder has asked the system to still motion
//  (`Reduce Motion`). Both decisions are folded into `shouldStart`, a pure
//  function of two booleans, so the gating can be tested without a device and
//  without faking `UIAccessibility`. The normalisation of raw radians into a
//  tidy [-1, 1] tilt is likewise pulled out as `normalise` for the same reason.
//

import CoreMotion
import UIKit

/// Streams a normalised device tilt to a subscriber, gated on hardware
/// availability and the Reduce Motion setting. `start()`/`stop()` are idempotent.
final class WalletMotionCoordinator {

    /// Called on the main thread each update with the normalised tilt, both
    /// components in [-1, 1]. The subscriber (the home screen) must capture its
    /// view controller **weakly** here — this coordinator is owned by that
    /// controller, so a strong capture would be a retain cycle.
    var onTilt: ((CGFloat, CGFloat) -> Void)?

    /// Whether updates are currently flowing. Stays false when `start()` was a
    /// no-op (no hardware, or Reduce Motion on), so a second `start()` is cheap.
    private(set) var isRunning = false

    private let motionManager = CMMotionManager()

    /// ~60 fps, matching the card layer updates the tilt drives.
    private static let updateInterval = 1.0 / 60.0

    /// The tilt angle, in radians, at which a component reaches full deflection
    /// (±1). ~0.6 rad ≈ 34°: a firm but comfortable wrist tilt lights the card
    /// fully, and anything past it simply holds at the maximum. Chosen so the
    /// effect is reachable one-handed without having to lay the phone flat.
    static let referenceAngle: Double = 0.6

    // MARK: - Pure helpers (tested without a device)

    /// Whether motion updates may start. Pure so the gate can be tested directly.
    /// Both conditions must hold: the device can report motion, and the holder
    /// has not turned on Reduce Motion.
    static func shouldStart(deviceMotionAvailable: Bool, reduceMotionEnabled: Bool) -> Bool {
        deviceMotionAvailable && !reduceMotionEnabled
    }

    /// Maps raw attitude radians to a tidy tilt: each axis scaled by
    /// `referenceAngle` and clamped to [-1, 1]. `roll` (tilt left/right) drives x,
    /// `pitch` (tilt toward/away) drives y. Pure, so the clamp/scale is testable.
    static func normalise(roll: Double, pitch: Double) -> (x: CGFloat, y: CGFloat) {
        func clamp(_ radians: Double) -> CGFloat {
            let scaled = radians / referenceAngle
            return CGFloat(min(1, max(-1, scaled)))
        }
        return (clamp(roll), clamp(pitch))
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard Self.shouldStart(deviceMotionAvailable: motionManager.isDeviceMotionAvailable,
                               reduceMotionEnabled: UIAccessibility.isReduceMotionEnabled) else {
            // No hardware, or the holder stilled motion: leave the cards on their
            // static Phase 1 glint and report nothing running.
            return
        }
        isRunning = true
        motionManager.deviceMotionUpdateInterval = Self.updateInterval
        // .xArbitraryZVertical: we only need relative tilt of the screen, not a
        // compass-referenced heading, so we take the cheapest reference frame that
        // gives a stable roll/pitch. Delivered on .main because the callback
        // touches card layers directly.
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let tilt = Self.normalise(roll: motion.attitude.roll, pitch: motion.attitude.pitch)
            self.onTilt?(tilt.x, tilt.y)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
    }

    deinit {
        // A coordinator can be released while a screen is mid-transition; make
        // sure the sensor is never left running behind a dead subscriber.
        motionManager.stopDeviceMotionUpdates()
    }
}
