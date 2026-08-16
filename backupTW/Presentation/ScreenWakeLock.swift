//
//  ScreenWakeLock.swift
//  backupTW
//
//  Keeps the screen awake while somebody is holding the phone out.
//

import Foundation
import UIKit

/// Holds off Auto-Lock for as long as a screen needs it.
///
/// # Why this exists
///
/// Two of this app's screens are "press the last button and then do not touch
/// the phone at all": the presentation carousel, and a Bluetooth transfer
/// measured at **21.7 seconds** end to end. `isIdleTimerDisabled` appears
/// nowhere in this app and there is no background mode, so on a phone in Low
/// Power Mode — where Auto-Lock is forced to 30 seconds and cannot be changed —
/// the screen dims and then locks in the middle of the exchange.
///
/// It also cancels out `ScreenBrightnessBoost`, which is the other half of the
/// same problem: the app raises brightness to make the code scannable, and then
/// the system dims it because nobody has touched anything.
///
/// # Counted, not a flag
///
/// `UIApplication.shared.isIdleTimerDisabled` is one boolean for the whole
/// process, so the obvious shape — each screen sets `true` on appear and
/// `false` on disappear — is wrong the moment two of them overlap. On a push,
/// the incoming screen's `viewWillAppear` and the outgoing screen's
/// `viewWillDisappear` both run, and whichever order they land in, a bare
/// `false` from the one that is leaving switches Auto-Lock back on underneath
/// the one that is arriving.
///
/// So holds are counted and the boolean is only written when the count crosses
/// zero. The audit's instruction was "no global flag", and this is what obeying
/// it actually requires: not the absence of shared state, but shared state that
/// cannot be released by somebody who never took it.
///
/// # Shape
///
/// Deliberately the same shape as `ScreenBrightnessBoost` — an injected write,
/// no singleton reached for inside, `isHeld` observable — so the two can be
/// tested the same way and read side by side at the call sites, where they
/// always appear together.
final class ScreenWakeLock {

    private let write: (Bool) -> Void
    private var holders = 0

    var isHeld: Bool { holders > 0 }

    /// Exposed for tests. A caller that leaks a hold shows up here as a count
    /// that never returns to zero, which is the failure worth catching: the
    /// phone silently stops locking for the rest of the session.
    var holderCount: Int { holders }

    init(write: @escaping (Bool) -> Void) {
        self.write = write
    }

    /// Takes a hold. Balanced by exactly one `release()`.
    func hold() {
        holders += 1
        if holders == 1 { write(true) }
    }

    /// Gives one hold back.
    ///
    /// Releasing when nothing is held is a no-op rather than a negative count:
    /// a screen that calls this from a lifecycle method it did not pair is a
    /// bug, but the failure mode of letting the count go negative is that the
    /// *next* legitimate hold does not take effect, which moves the symptom
    /// somewhere unrelated.
    func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { write(false) }
    }
}

/// The one lock the app's screens share.
///
/// A singleton, which this codebase otherwise avoids — justified because the
/// thing being guarded *is* a single process-wide boolean. Two independent
/// `ScreenWakeLock` instances would each count correctly and still fight over
/// `isIdleTimerDisabled`, which is exactly the bug counting exists to prevent.
///
/// The write is the only line that touches UIKit, so tests construct their own
/// `ScreenWakeLock` with a recorder and never come near this.
@MainActor
enum AppScreenWakeLock {
    static let shared = ScreenWakeLock { disabled in
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}
