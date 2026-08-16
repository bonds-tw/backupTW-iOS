//
//  ZKProofScreenLifecycleTests.swift
//  backupTWTests
//
//  What the 最小揭露 screen still holds after it looks finished.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// Two leaks that a screenshot cannot show and a user cannot check.
///
/// The screen tells the holder, in its own words, that the 身分證統一編號 「不會
/// 被儲存」. That sentence is about disk and it is true. What it is heard as is
/// "this number stops existing when I am done with it", and both defects here
/// make that false in memory:
///
///   * the run ended, the button went back to 「建立證明」, and the `ZKProofRunner`
///     — holding a `TWFidOHolderSigner` whose `idNumber` is a plain `String` —
///     was still referenced by the screen for as long as it stayed on the
///     navigation stack;
///   * the alert that collected the number retained itself through its own
///     action's handler, so the `UITextField` holding it was never deallocated
///     at all, for the life of the process.
///
/// Neither has a symptom. Both are one word of capture list, which is exactly
/// the kind of fix that gets dropped by the next edit unless something is
/// standing over it.
@MainActor
struct ZKProofScreenLifecycleTests {

    // MARK: - The runner

    /// The reported defect. Every exit path did `runTask = nil` and none of them
    /// touched `runner`, while the property's own comment said it was thrown
    /// away when the run ended.
    ///
    /// Asserted twice on purpose. `screen.runner == nil` is the direct statement
    /// of what was wrong; the weak reference is the part that matters, because a
    /// property set to nil while something else still points at the runner would
    /// keep the ID number resident just the same.
    @Test func releasesTheRunnerAndTheIdNumberItHoldsWhenTheRunEnds() async throws {
        let screen = Self.screen()
        weak var observed: ZKProofRunner?
        let task: Task<Void, Never>

        do {
            let runner = Self.runner()
            observed = runner
            screen.startRun(runner)
            task = try #require(screen.runTask, "the run never started")
            #expect(screen.runner != nil, "the screen is not holding the runner it was given")
        }

        await task.value
        // The run's last act hops to the main actor; this test is already on it,
        // so by the time `value` returns the hop has landed. The yield is for the
        // task's own frame, which is what holds the last strong reference.
        await Task.yield()

        #expect(screen.runTask == nil)
        #expect(screen.runner == nil, "the screen is still holding the finished run")
        #expect(observed == nil,
                "the runner outlived its run, and the 身分證統一編號 inside it with it")
    }

    /// The same thing for a run that failed, which is the path a teardown
    /// written twice gets wrong. A proof that stops at stage one is the *most*
    /// likely outcome on a phone with no room for the download — and it is
    /// exactly when the user is most likely to leave the screen sitting there.
    @Test func aRunThatFailedAtTheFirstStageAlsoLetsGo() async throws {
        let screen = Self.screen()
        weak var observed: ZKProofRunner?
        let task: Task<Void, Never>

        do {
            // Refused before the prover is reached, which is the shortest run the
            // screen can produce.
            let runner = Self.runner(assets: FakeAssets(planToReturn: Self.outstandingPlan,
                                                        failure: FakeAssets.Refused()))
            observed = runner
            screen.startRun(runner)
            task = try #require(screen.runTask)
        }

        await task.value
        await Task.yield()

        #expect(screen.runner == nil)
        #expect(observed == nil)
    }

    /// The screen has to come back afterwards: a run that ends and leaves
    /// `runTask` set would show 「停止」 forever with nothing to stop.
    @Test func theScreenIsReadyForAnotherRun() async throws {
        let screen = Self.screen()

        for _ in 0..<2 {
            screen.startRun(Self.runner())
            let task = try #require(screen.runTask)
            await task.value
            await Task.yield()
            #expect(screen.runTask == nil)
        }
    }

    // MARK: - The alert that collected the number

    /// The retain cycle, stated as a lifetime. The Continue handler read
    /// `alert.textFields` and therefore captured `alert`, so the alert owned an
    /// action that owned a closure that owned the alert: it was never
    /// deallocated, and neither was the `UITextField` holding the
    /// 身分證統一編號.
    ///
    /// Nothing is presented and nothing is tapped, because the cycle exists the
    /// moment the action is added. That is what makes this checkable at all.
    @Test func theIdNumberPromptDoesNotHoldItselfAlive() {
        weak var observed: UIAlertController?

        autoreleasepool {
            let prompt = ZKProofViewController.makeIDNumberPrompt { _ in }
            observed = prompt
            // Both actions present, so a factory that stopped adding them could
            // not pass this by having nothing to make a cycle out of.
            #expect(prompt.actions.count == 2)
        }

        #expect(observed == nil,
                "the prompt retained itself, and the 身分證統一編號 in its text field with it")
    }

    /// Lifting the prompt out of `promptForIDNumber()` is what made the lifetime
    /// above observable, and an extraction that quietly changed the prompt would
    /// be a worse bug than the leak: an alert with no Cancel is a dialogue a
    /// person cannot back out of.
    @Test func theExtractedPromptIsStillTheSameTwoChoices() {
        let prompt = ZKProofViewController.makeIDNumberPrompt { _ in }

        #expect(prompt.actions.count == 2)
        #expect(prompt.actions.first?.title
                == NSLocalizedString("Send the number to 內政部", comment: ""))
        #expect(prompt.actions.first?.style == .default)
        #expect(prompt.actions.last?.style == .cancel)
    }

    /// The consenting button has to name the act, not the direction of travel.
    ///
    /// It said 「繼續」 while the message above it explained that the number goes
    /// to 內政部 and that 內政部 keeps a record — so the entire weight of the
    /// disclosure sat in the paragraph people skip, and none of it in the
    /// control that performs it. This app's other consent moment already gets
    /// this right (「出示 3 個欄位（含姓名）」).
    ///
    /// Asserted as a property rather than by pinning a string, so that rewording
    /// stays possible and reverting to a contentless verb does not.
    @Test func theConsentingButtonNamesWhatItDoes() throws {
        let title = try #require(ZKProofViewController.makeIDNumberPrompt { _ in }.actions.first?.title)

        // Every contentless label this could regress to, in both languages the
        // app ships. `NSLocalizedString` is deliberately *not* used: these are
        // the words the button must never say, whatever the current locale
        // resolves them to.
        for empty in ["Continue", "繼續", "OK", "好", "Next", "下一步", "Done", "完成"] {
            #expect(title != empty, "the consent button says nothing about what it does: \(title)")
        }
        // And it must name the recipient, which is the fact being consented to.
        #expect(title.contains("內政部"))
    }

    // MARK: - Fixtures

    /// Loaded, not presented: `startRun` applies a diffable snapshot, which needs
    /// the data source `viewDidLoad` builds. Nothing below needs a window.
    private static func screen() -> ZKProofViewController {
        let screen = ZKProofViewController()
        screen.loadViewIfNeeded()
        return screen
    }

    /// A runner with all four seams faked. No download, no 行動自然人憑證, no
    /// proving key, no network — the whole run is a few microseconds of
    /// bookkeeping, which is what makes it usable from a lifetime test.
    private static func runner(assets: FakeAssets = FakeAssets()) -> ZKProofRunner {
        ZKProofRunner(assets: assets,
                      signer: FakeSigner(),
                      prover: FakeProver(),
                      footprint: NoFootprint(),
                      headroomAtStart: { 3_000_000_000 },
                      environment: { Self.environment },
                      now: { Date(timeIntervalSince1970: 1_754_500_000) })
    }

    private static let outstandingPlan = ZKAssetPlan(outstanding: [
        ZKAssetRequirement(name: "cert_chain_rs4096_proving",
                           displayName: "chain key",
                           downloadByteCount: 41_321_996,
                           installedByteCount: 693_663_394,
                           isStale: false)
    ])

    private static let environment = ProvingBenchmark.Environment(
        isSimulator: true,
        hardwareModel: "iPhone14,5",
        simulatedModel: nil,
        osVersion: "16.4.0",
        activeProcessorCount: 6,
        processorCount: 6,
        physicalMemoryBytes: 4_000_000_000,
        thermalState: .nominal,
        isLowPowerModeEnabled: false,
        rayonThreads: nil,
        appVersion: "1.0",
        appBuild: "1",
        capturedOnMainThread: false)
}

// MARK: - Seams

/// Ready by default; `failure` turns the run into one that stops at stage one.
private struct FakeAssets: ZKAssetPreparing {

    struct Refused: Error {}

    var planToReturn: ZKAssetPlan = ZKAssetPlan(outstanding: [])
    var failure: Error?
    var workingDirectory = URL(fileURLWithPath: "/tmp/zk-lifecycle")

    func plan() async -> ZKAssetPlan { planToReturn }

    func prepare(progress: @escaping @Sendable (ZKAssetProgress) -> Void) async throws {
        if let failure { throw failure }
    }
}

private struct FakeSigner: ZKHolderSigning {

    /// Structurally valid and nobody's: a DER SEQUENCE header and a counter. A
    /// real 自然人憑證 carries a living person's name and 身分證統一編號, which
    /// has no business in a fixture.
    static let inputs: ProvingInputs = {
        var certificate: [UInt8] = [0x30, 0x82, 0x01, 0x00]
        certificate += (0..<252).map { UInt8($0 % 251) }
        // Force-tried over material this file just built to satisfy the same
        // structural checks `ProvingInputs` enforces.
        return try! ProvingInputs(
            certificateBase64: Data(certificate).base64EncodedString(),
            signedResponse: Data((0..<256).map { UInt8($0 % 253) }).base64EncodedString(),
            challenge: .holderGenerated(
                VerifiableCredential.base64URLEncoded(Data((0..<16).map { UInt8($0) }))))
    }()

    func sign(challenge: ProofChallenge) async throws -> ProvingInputs { Self.inputs }
}

private struct FakeProver: ZKProving {
    func prove(_ inputs: ProvingInputs) async throws -> ZKProofBundle {
        ZKProofBundle(certificateChain: ProofMetrics(proveMilliseconds: 31_000,
                                                     proofByteCount: 803),
                      userSignature: ProofMetrics(proveMilliseconds: 4_100,
                                                  proofByteCount: 261),
                      caveats: ProofCaveat.allCases,
                      proofDirectory: URL(fileURLWithPath: "/tmp/zk-lifecycle/keys"))
    }
}

/// The real tracker owns a repeating timer. Nothing here is measuring memory.
private struct NoFootprint: ProvingBenchmarkFootprintTracking {
    func start() {}
    func stop() -> UInt64? { 2_100_000_000 }
}
