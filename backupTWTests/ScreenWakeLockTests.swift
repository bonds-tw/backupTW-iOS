//
//  ScreenWakeLockTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

struct ScreenWakeLockTests {

    /// Records every write, so "how many times" is checkable and not just
    /// "what is it now".
    private final class Recorder: @unchecked Sendable {
        private(set) var writes: [Bool] = []
        func write(_ value: Bool) { writes.append(value) }
    }

    @Test func aHoldDisablesAutoLockAndReleasingRestoresIt() {
        let recorder = Recorder()
        let lock = ScreenWakeLock(write: recorder.write)

        lock.hold()
        #expect(lock.isHeld)
        #expect(recorder.writes == [true])

        lock.release()
        #expect(!lock.isHeld)
        #expect(recorder.writes == [true, false])
    }

    /// The reason this type counts instead of setting a flag.
    ///
    /// On a push, the arriving screen's `viewWillAppear` and the leaving
    /// screen's `viewWillDisappear` both run. With a bare boolean, the one
    /// leaving switches Auto-Lock back on underneath the one arriving — and the
    /// symptom is a phone that locks halfway through a 21.7-second Bluetooth
    /// transfer, on the screen that did everything right.
    @Test func aScreenLeavingDoesNotUnlockTheScreenArriving() {
        let recorder = Recorder()
        let lock = ScreenWakeLock(write: recorder.write)

        lock.hold()          // the presentation screen
        lock.hold()          // the transfer screen, pushed on top
        lock.release()       // the presentation screen leaves

        #expect(lock.isHeld, "the screen still showing lost its hold")
        #expect(recorder.writes == [true], "the boolean was written more than once")

        lock.release()
        #expect(!lock.isHeld)
        #expect(recorder.writes == [true, false])
    }

    /// A double release must not leave the count negative — that would make the
    /// *next* real hold do nothing, moving the symptom to an unrelated screen.
    @Test func releasingMoreThanWasHeldDoesNotGoNegative() {
        let recorder = Recorder()
        let lock = ScreenWakeLock(write: recorder.write)

        lock.hold()
        lock.release()
        lock.release()
        lock.release()
        #expect(lock.holderCount == 0)

        lock.hold()
        #expect(lock.isHeld, "a later hold was swallowed by an earlier over-release")
        #expect(recorder.writes == [true, false, true])
    }

    @Test func releasingWithoutHoldingWritesNothing() {
        let recorder = Recorder()
        ScreenWakeLock(write: recorder.write).release()
        #expect(recorder.writes.isEmpty)
    }
}
