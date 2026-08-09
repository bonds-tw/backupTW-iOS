//
//  CrossDeviceVerifierHarnessUITests.swift
//  backupTWUITests
//
//  Lets a headless simulator act as the second device in a cross-device check.
//

import XCTest

/// # Why a UI test is standing in for a person
///
/// The real cross-device test is two phones and two cameras. This machine has
/// one phone and a simulator with no window — the Xcode installation here has
/// no Simulator.app, so nobody can see the simulator's screen or tap it. What
/// still works headlessly is `simctl io screenshot`, `simctl pbcopy`, and this:
/// a test that walks the verifier flow and parks at the points where a human
/// would act.
///
/// The choreography, driven from outside:
///
///   1. Run this test with `TEST_RUNNER_CROSS_DEVICE_HARNESS=1`. It navigates
///      to the verifier screen, which mints a fresh challenge and shows the
///      request QR. (`simctl io screenshot` captures it; the holder scans it
///      off any screen it is displayed on.)
///   2. The holder's phone presents, and its frames arrive on the Mac clipboard
///      via Universal Clipboard. `pbpaste | xcrun simctl pbcopy <udid>` moves
///      them into the simulator's pasteboard.
///   3. This test is polling that pasteboard for `BTWVP1` frames. When they
///      appear it taps the DEBUG paste button — from there on, the exact
///      production path runs: FrameIntake, OfflineVerifier, the result screen.
///   4. It parks on the result long enough for a screenshot.
///
/// The five-minute budget is real: the challenge ages from step 1, and
/// `OfflineVerifier` refuses a presentation older than its freshness window.
/// Start this only when the holder is standing by.
final class CrossDeviceVerifierHarnessUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testActAsVerifier() throws {
        guard ProcessInfo.processInfo.environment["CROSS_DEVICE_HARNESS"] == "1" else {
            throw XCTSkip("Interactive harness; set TEST_RUNNER_CROSS_DEVICE_HARNESS=1 to run it.")
        }

        let app = XCUIApplication()
        app.launch()

        // Home → the verifier flow. Matched in both languages so the harness
        // does not care which locale the simulator happens to be in.
        let verifyEntry = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@",
            "Check someone else's document", "查驗他人證件")).firstMatch
        XCTAssertTrue(verifyEntry.waitForExistence(timeout: 10), "the home screen never offered the verifier flow")
        verifyEntry.tap()

        // The request QR is up; the challenge clock starts here.
        let requestCode = app.images.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@",
            "Verification request code", "查驗請求條碼")).firstMatch
        XCTAssertTrue(requestCode.waitForExistence(timeout: 10), "no request code appeared")

        // Wait for the holder. The pasteboard is simulator-wide, so what
        // `simctl pbcopy` wrote is what `UIPasteboard.general` reads here.
        let deadline = Date().addingTimeInterval(300)
        var framesArrived = false
        while Date() < deadline {
            if UIPasteboard.general.string?.contains("BTWVP1") == true {
                framesArrived = true
                break
            }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(framesArrived, "no presentation frames reached the simulator pasteboard within five minutes")

        // The DEBUG paste button is deliberately unlocalized, so one literal is
        // enough — and this harness only makes sense against a DEBUG build,
        // which is the only build that has the button.
        let paste = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "貼上出示內容")).firstMatch
        XCTAssertTrue(paste.exists, "the DEBUG paste button is missing — is this a DEBUG build?")
        paste.tap()

        // Production verification runs now. Wait for either verdict, then park
        // so an external screenshot can capture what a checker would see.
        let verdict = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "✅", "⚠️")).firstMatch
        XCTAssertTrue(verdict.waitForExistence(timeout: 30), "no verdict appeared after pasting")

        Thread.sleep(forTimeInterval: 60)
    }
}
