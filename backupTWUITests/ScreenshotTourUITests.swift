//
//  ScreenshotTourUITests.swift
//  backupTWUITests
//
//  Temporary screenshot tour used for the 2026-09-01 UI/UX audit.
//  Each segment relaunches the app so a stuck modal can never block
//  the rest of the tour. Never asserts — unreachable screens are
//  skipped, not failed. Safe to delete after the audit.

import XCTest

final class ScreenshotTourUITests: XCTestCase {

    var app: XCUIApplication!
    var counter = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func relaunch() {
        app = XCUIApplication()
        app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
        app.launch()
        sleep(2)
    }

    private func shot(_ name: String) {
        counter += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", counter, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func tapLabel(_ labels: [String], timeout: TimeInterval = 4) -> Bool {
        let exact = NSPredicate(format: "label IN %@", labels)
        for query in [app.staticTexts.matching(exact), app.buttons.matching(exact)] {
            let element = query.firstMatch
            if element.waitForExistence(timeout: timeout / 2), element.isHittable {
                element.tap(); return true
            }
        }
        for label in labels {
            let contains = NSPredicate(format: "label CONTAINS %@", label)
            let element = app.staticTexts.matching(contains).firstMatch
            if element.waitForExistence(timeout: 1), element.isHittable {
                element.tap(); return true
            }
        }
        return false
    }

    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 2) { back.tap(); sleep(1) }
    }

    private func allowSystemAlertIfAny() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允許", "好", "Allow", "OK", "Allow While Using App", "使用 App 時允許"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); break }
        }
    }

    func testScreenshotTour() throws {
        // ── Segment 1: Home ─────────────────────────────────────────
        relaunch()
        shot("home-top")
        app.swipeUp()
        shot("home-scrolled")
        app.swipeUp()
        shot("home-bottom")
        if tapLabel(["個人公文匣", "公文匣", "公文"], timeout: 3) {
            sleep(1)
            shot("official-inbox")
            if tapLabel(["合成", "測試"], timeout: 2) { sleep(1); shot("official-inbox-2") }
        }

        // ── Segment 2: MyData onboarding wizard ────────────────────
        relaunch()
        let firstCell = app.collectionViews.firstMatch.cells.element(boundBy: 0)
        if firstCell.waitForExistence(timeout: 3) {
            firstCell.tap()
            sleep(2)
            shot("mydata-onboard-top")
            if tapLabel(["在這支 iPhone 記住 MyData 常用資料", "記住 MyData"], timeout: 2) {
                sleep(1)
                shot("mydata-profile")
                goBack()
            }
            app.swipeUp()
            shot("mydata-onboard-scrolled")
        }

        // ── Segment 3: Vault card → document detail ────────────────
        relaunch()
        app.swipeUp()
        if tapLabel(["已保存原始檔"], timeout: 3) {
            sleep(1)
            shot("vault-after-tap-1")
            _ = tapLabel(["已保存原始檔"], timeout: 2)
            sleep(1)
            shot("vault-after-tap-2")
            if tapLabel(["查看詳情", "管理詳情", "查看/管理詳情"], timeout: 2) {
                sleep(1)
                shot("vault-document-detail")
                app.swipeUp()
                shot("vault-document-detail-scrolled")
            }
        }

        // ── Segment 4: Settings and its sub-screens ────────────────
        relaunch()
        let gear = app.buttons.matching(
            NSPredicate(format: "label IN {'設定', 'Settings'}")).firstMatch
        if gear.waitForExistence(timeout: 3) {
            gear.tap()
            sleep(1)
            shot("settings")
            let rows = ["這個 App 能證明什麼", "能力", "皮夾身分", "信任", "診斷", "授權", "關於"]
            var visited = Set<String>()
            for row in rows where !visited.contains(row) {
                if tapLabel([row], timeout: 2) {
                    visited.insert(row)
                    sleep(2)
                    shot("settings-\(row)")
                    app.swipeUp()
                    shot("settings-\(row)-b")
                    goBack()
                }
            }
        }

        // ── Segment 5: Use tab rows ────────────────────────────────
        relaunch()
        let useTab = app.tabBars.buttons.matching(
            NSPredicate(format: "label IN {'使用', 'Use'}")).firstMatch
        let useButton = useTab.waitForExistence(timeout: 3)
            ? useTab : app.buttons["使用"]
        if useButton.waitForExistence(timeout: 2) {
            useButton.tap()
            sleep(1)
            shot("use-tab")
            app.swipeUp()
            shot("use-tab-b")
            app.swipeDown()

            let useRows: [(String, [String])] = [
                ("present-offline", ["出示我的證件"]),
                ("verify-person", ["查驗他人證件"]),
                ("zk-create", ["建立零知識證明"]),
                ("zk-verify", ["查驗零知識證明"]),
                ("scan-collect", ["掃描加入卡片"]),
                ("telecom", ["申請門號電子卡"]),
            ]
            for (name, labels) in useRows {
                if tapLabel(labels, timeout: 3) {
                    sleep(2)
                    allowSystemAlertIfAny()
                    sleep(1)
                    shot("use-\(name)")
                    app.swipeUp()
                    shot("use-\(name)-b")
                    goBack()
                    sleep(1)
                    if app.navigationBars.buttons.firstMatch.exists { goBack() }
                }
            }
        }

        shot("final")
    }
}
