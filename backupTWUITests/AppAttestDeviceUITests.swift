//
//  AppAttestDeviceUITests.swift
//  backupTWUITests
//

import XCTest

/// Exercises the same explicit-confirmation UI used during a human App Attest
/// acceptance run. It is opt-in because it requires a physical device, a
/// reviewed development endpoint, and mutates Apple's per-installation counter.
final class AppAttestDeviceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDevelopmentRegistrationAndRepeatedAssertion() throws {
        guard ProcessInfo.processInfo.environment["APP_ATTEST_DEVICE_UAT"] == "1" else {
            throw XCTSkip("Physical-device UAT; set TEST_RUNNER_APP_ATTEST_DEVICE_UAT=1 to run it.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
        app.launch()

        let settings = app.buttons.matching(
            NSPredicate(format: "label IN {'設定', 'Settings'}")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "Settings was not reachable")
        settings.tap()

        let diagnostics = app.staticTexts.matching(
            NSPredicate(format: "label IN {'診斷', 'Diagnostics'}")).firstMatch
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 15), "Diagnostics was not reachable")
        diagnostics.tap()

        let entry = app.descendants(matching: .any)["diagnostics.appAttestUAT"]
        for _ in 0..<8 where !entry.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "App Attest UAT entry was not reachable")
        entry.tap()

        let endpoint = app.descendants(matching: .any)["appattest.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 10), "App Attest endpoint was not shown")
        XCTAssertTrue(endpoint.label.contains("signing-dev.mashbean.net"),
                      "Device UAT must not run against the TestFlight endpoint: \(endpoint.label)")

        try runCheck(in: app, ordinal: "first")
        try runCheck(in: app, ordinal: "second")
    }

    @MainActor
    private func runCheck(in app: XCUIApplication, ordinal: String) throws {
        let action = app.descendants(matching: .any)["appattest.run"]
        XCTAssertTrue(action.waitForExistence(timeout: 10), "No \(ordinal) App Attest action")
        action.tap()

        let confirm = app.buttons.matching(
            NSPredicate(format: "label IN {'執行檢查', 'Run check'}")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "No \(ordinal) confirmation")
        confirm.tap()

        let status = app.descendants(matching: .any)["appattest.status"]
        let passed = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "通過", "Passed")
        let failed = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "失敗", "Failed")
        let completed = expectation(for: NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "通過", "Passed", "失敗", "Failed"), evaluatedWith: status)
        wait(for: [completed], timeout: 90)
        XCTAssertFalse(failed.evaluate(with: status), "The \(ordinal) App Attest run failed: \(status.label)")
        XCTAssertTrue(passed.evaluate(with: status), "The \(ordinal) App Attest run did not pass: \(status.label)")
    }
}
