//
//  ZKProofRunTests.swift
//  backupTWTests
//
//  Everything the 最小揭露 screen does that is not drawing: stage ordering, what
//  stops a run, what "verified" is allowed to mean, and what the report says.
//
//  Nothing here downloads an asset, holds a proving key, or produces a proof.
//  The seams in `ZKProofRun.swift` exist so that this file can run in
//  milliseconds on a CI box with no gigabyte to spare.
//

import Foundation
import Testing
@testable import backupTW

// MARK: - Fixtures

/// A base64 DER blob that satisfies `ProvingInputs`' structural checks without
/// being anybody's certificate: it begins 0x30 (DER SEQUENCE) and is otherwise
/// a counter.
private enum Fixture {

    static let certificateBase64: String = {
        var bytes: [UInt8] = [0x30, 0x82, 0x01, 0x00]
        bytes += (0..<252).map { UInt8($0 % 251) }
        return Data(bytes).base64EncodedString()
    }()

    /// Exactly 256 bytes, which is what an RSA-2048 PKCS#1 signature is.
    static let signedResponse = Data((0..<256).map { UInt8($0 % 253) }).base64EncodedString()

    static let challenge = ProofChallenge.holderGenerated(
        VerifiableCredential.base64URLEncoded(Data((0..<16).map { UInt8($0) })))

    static func inputs() throws -> ProvingInputs {
        try ProvingInputs(certificateBase64: certificateBase64,
                          signedResponse: signedResponse,
                          challenge: challenge)
    }

    static func bundle(certificateChainMs: UInt64 = 31_000,
                       userSignatureMs: UInt64 = 4_100,
                       certificateChainBytes: UInt64 = 803,
                       userSignatureBytes: UInt64 = 261,
                       caveats: [ProofCaveat] = ProofCaveat.allCases,
                       directory: URL = URL(fileURLWithPath: "/tmp/zk"),
                       // The runner no longer calls a verifier, so this — not a
                       // `FakeVerifier` — is how a test says what this device
                       // decided about the proof. Defaulted to the passing case
                       // because that is what `ZKProver` returns on the success
                       // path: a bundle it has already checked here.
                       selfCheck: ZKSelfCheck = .passed(Fixture.outcome)) -> ZKProofBundle {
        ZKProofBundle(
            certificateChain: ProofMetrics(proveMilliseconds: certificateChainMs,
                                           proofByteCount: certificateChainBytes),
            userSignature: ProofMetrics(proveMilliseconds: userSignatureMs,
                                        proofByteCount: userSignatureBytes),
            caveats: caveats,
            proofDirectory: directory,
            selfCheck: selfCheck)
    }

    static func environment(isSimulator: Bool = false,
                            thermalState: ProcessInfo.ThermalState = .nominal,
                            lowPower: Bool = false,
                            onMainThread: Bool = false) -> ProvingBenchmark.Environment {
        ProvingBenchmark.Environment(isSimulator: isSimulator,
                                     hardwareModel: "iPhone14,5",
                                     simulatedModel: nil,
                                     osVersion: "16.4.0",
                                     activeProcessorCount: 6,
                                     processorCount: 6,
                                     physicalMemoryBytes: 4_000_000_000,
                                     thermalState: thermalState,
                                     isLowPowerModeEnabled: lowPower,
                                     rayonThreads: nil,
                                     appVersion: "1.0",
                                     appBuild: "1",
                                     capturedOnMainThread: onMainThread)
    }

    static let outcome = ZKVerificationOutcome(certificateChainValid: true,
                                               userSignatureValid: true,
                                               linked: true,
                                               certificateChainMilliseconds: 120,
                                               userSignatureMilliseconds: 40,
                                               linkMilliseconds: 170)
}

// MARK: - Recording

/// Ordered log of which seam was entered, so "the prover was never called" is
/// something a test can assert rather than infer.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ name: String) {
        lock.lock(); entries.append(name); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func count(_ name: String) -> Int {
        all.filter { $0 == name }.count
    }
}

private struct FakeAssets: ZKAssetPreparing {
    let log: CallLog
    var planToReturn: ZKAssetPlan
    var failure: Error?
    var progressToEmit: [ZKAssetProgress] = []
    var workingDirectory = URL(fileURLWithPath: "/tmp/zk-working")
    /// Empty by default, which is the protocol's own default: every requirement
    /// is mandatory unless a conformance says otherwise.
    var verificationOnly: Set<String> = []

    var verificationOnlyRequirementNames: Set<String> { verificationOnly }

    func plan() async -> ZKAssetPlan {
        log.record("plan")
        return planToReturn
    }

    func prepare(progress: @escaping @Sendable (ZKAssetProgress) -> Void) async throws {
        log.record("prepare")
        for update in progressToEmit { progress(update) }
        if let failure { throw failure }
    }
}

private struct FakeSigner: ZKHolderSigning {
    let log: CallLog
    var result: Result<ProvingInputs, Error>

    func sign(challenge: ProofChallenge) async throws -> ProvingInputs {
        log.record("sign")
        return try result.get()
    }
}

private struct FakeProver: ZKProving {
    let log: CallLog
    var result: Result<ZKProofBundle, Error>
    /// Blocks until resumed, so a concurrent-run test has something to race.
    var gate: Gate?

    func prove(_ inputs: ProvingInputs) async throws -> ZKProofBundle {
        log.record("prove")
        if let gate { await gate.wait() }
        return try result.get()
    }
}

// No `FakeVerifier` here, and no verification-queue marker.
//
// `ZKProofRunner` does not take a verifier: it renders `ZKProofBundle.selfCheck`
// and calls nothing. A fake wired into these tests would be inert, and a test
// that configures an inert dependency and then asserts a behaviour is the
// vacuous kind — it passes for reasons unrelated to what it claims to check.
// The verifier's own semantics, and the rule that the blocking call must leave
// the cooperative pool, are tested against `ZKProver` in `ZKProverTests`.

/// A one-shot barrier. `ZKProver` refuses a second concurrent proof and so does
/// `ZKProofRunner`; testing that needs a first run that is genuinely still in
/// flight rather than one that happened to be slow.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters = []
        for continuation in parked { continuation.resume() }
    }
}

private struct FixedClock: ProvingBenchmarkClock {
    let values: [UInt64]
    let cursor = Counter()

    func nowNanoseconds() -> UInt64 {
        let index = cursor.next()
        return values[min(index, values.count - 1)]
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

private struct NoFootprint: ProvingBenchmarkFootprintTracking {
    let peak: UInt64?
    func start() {}
    func stop() -> UInt64? { peak }
}

private func makeRunner(assets: FakeAssets,
                        signer: FakeSigner,
                        prover: FakeProver,
                        clockValues: [UInt64] = [0, 31_000_000_000, 31_500_000_000],
                        peak: UInt64? = 2_100_000_000,
                        environment: ProvingBenchmark.Environment = Fixture.environment())
    -> ZKProofRunner {
    ZKProofRunner(assets: assets,
                  signer: signer,
                  prover: prover,
                  clock: FixedClock(values: clockValues),
                  footprint: NoFootprint(peak: peak),
                  headroomAtStart: { 3_000_000_000 },
                  environment: { environment },
                  now: { Date(timeIntervalSince1970: 1_754_500_000) })
}

private let readyPlan = ZKAssetPlan(outstanding: [])

private let outstandingPlan = ZKAssetPlan(outstanding: [
    ZKAssetRequirement(name: "cert_chain_rs4096_proving",
                       displayName: "chain key",
                       downloadByteCount: 41_321_996,
                       installedByteCount: 693_663_394,
                       isStale: false)
])

// MARK: - Ordering and gating

@Suite("ZK run orchestration")
struct ZKProofRunnerTests {

    @Test("all four stages run, in order, and every one reports success")
    func runsAllFourStages() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        #expect(snapshot.isFinished)
        for stage in ZKRunStage.allCases {
            guard case .succeeded = snapshot.state(stage) else {
                Issue.record("\(stage) was \(snapshot.state(stage)), expected success")
                continue
            }
        }
        // The whole point of the ordering: nothing is signed before the files
        // exist, and nothing is proved before it is signed.
        //
        // No "verify" any more — not because the check stopped happening, but
        // because it moved inside `prove`, where a refused proof can be withheld
        // instead of returned. Stage 4 above still reports success, and it now
        // reports what `ZKProver` decided rather than a second pass of its own.
        #expect(log.all.filter { $0 != "plan" && $0 != "missingArtifacts" }
                == ["sign", "prove"])
        #expect(snapshot.firstProblem == nil)
    }

    @Test("assets that are already prepared skip the download entirely")
    func readyAssetsSkipPreparation() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        _ = await runner.run(challenge: Fixture.challenge) { _ in }
        #expect(log.count("prepare") == 0)
    }

    @Test("an outstanding plan is downloaded before anything else happens")
    func outstandingPlanIsPrepared() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: outstandingPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        _ = await runner.run(challenge: Fixture.challenge) { _ in }
        let ordered = log.all.filter { $0 == "prepare" || $0 == "sign" }
        #expect(ordered == ["prepare", "sign"])
    }

    @Test("a download failure stops the run and never asks for a signature")
    func assetFailureStopsTheRun() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log,
                               planToReturn: outstandingPlan,
                               failure: CircuitAssetError.noUsableConnection(name: "x")),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        guard case .failed(let message, let recoverable) = snapshot.state(.assets) else {
            Issue.record("expected the assets stage to fail")
            return
        }
        #expect(recoverable)
        // The store writes a better sentence about its own failures than
        // anything above it could; losing it to a generic string is the
        // regression this pins.
        #expect(message == CircuitAssetError.noUsableConnection(name: "x").localizedDescription)
        #expect(log.count("sign") == 0)
        #expect(log.count("prove") == 0)
        #expect(snapshot.state(.signature) == .waiting)
        #expect(snapshot.report == nil)
    }

    /// **The regression test for the classification defect.**
    ///
    /// A tampered trust anchor used to arrive at the generic `catch` and become
    /// `assetsUnavailable`, whose `isRecoverable` is `true` — the same bucket as
    /// the interrupted download in the test above, and rendered with the same
    /// invitation to try again. No retry rewrites the bytes that failed the pin,
    /// so the only thing another attempt can do is have another go at a
    /// substituted certificate authority.
    @Test("a trust anchor that failed its pin is not offered as something to retry")
    func trustAnchorFailureIsNotRecoverable() async throws {
        let log = CallLog()
        let tampered = IssuerCertificateError.fingerprintMismatch(
            resource: IssuerCertificate.issuerResourceName,
            expected: IssuerCertificate.pinnedIssuerSHA256,
            actual: String(repeating: "0", count: 64))
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: outstandingPlan, failure: tampered),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        guard case .failed(let message, let recoverable) = snapshot.state(.assets) else {
            Issue.record("expected the assets stage to fail")
            return
        }
        #expect(recoverable == false)
        // The anchor's own sentence — "has been altered, so it won't be used" —
        // and deliberately not the download vocabulary.
        #expect(message == tampered.localizedDescription)
        #expect(message != CircuitAssetError.corruptDownload(
            name: "x", underlying: CocoaError(.fileNoSuchFile)).localizedDescription)
        #expect(log.count("sign") == 0)
        #expect(log.count("prove") == 0)
        #expect(snapshot.report == nil)
    }

    /// The two sides of the split, next to each other, because the defect was
    /// precisely that they were the same case.
    @Test("a dropped download is recoverable and a broken chain is not")
    func trustAnchorAndDownloadFailuresAreClassifiedApart() {
        #expect(ZKRunError.assetsUnavailable(message: "x").isRecoverable)
        #expect(ZKRunError.trustAnchorRejected(.bundledChainBroken).isRecoverable == false)
        #expect(ZKRunError.trustAnchorRejected(
            .bundledCertificateMismatch(resource: "MOICA-G3",
                                        detail: "serial number")).isRecoverable == false)
        // The exception, carried through rather than flattened: a device whose
        // clock is wrong can be fixed and retried.
        #expect(ZKRunError.trustAnchorRejected(
            .trustAnchorNotYetValid(from: Date(timeIntervalSince1970: 0))).isRecoverable)
    }

    @Test("a signing failure stops the run before two gigabytes are spent proving")
    func signatureFailureStopsBeforeProving() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log,
                               result: .failure(ZKRunError.signingTimedOut)),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        guard case .failed(let message, _) = snapshot.state(.signature) else {
            Issue.record("expected the signature stage to fail")
            return
        }
        #expect(message == ZKRunError.signingTimedOut.localizedDescription)
        #expect(log.count("prove") == 0)
        #expect(snapshot.state(.proof) == .waiting)
    }

    @Test("a proving failure stops the run before verification is attempted")
    func provingFailureStopsBeforeVerifying() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log,
                               result: .failure(ZKProofError.revocationCheckDegraded)))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        guard case .failed(let message, let recoverable) = snapshot.state(.proof) else {
            Issue.record("expected the proof stage to fail")
            return
        }
        #expect(recoverable == false)
        #expect(message == ZKProofError.revocationCheckDegraded.localizedDescription)
        #expect(log.count("verify") == 0)
        #expect(snapshot.state(.verification) == .waiting)
        #expect(snapshot.report == nil)
    }

    @Test("the signing stage keeps ZKProofError's recoverable/not distinction")
    func recoverabilitySurvivesTheStage() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log,
                               result: .failure(ZKProofError.assetsNotReady(missing: ["a"],
                                                                           stale: []))))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }
        guard case .failed(_, let recoverable) = snapshot.state(.proof) else {
            Issue.record("expected a failure")
            return
        }
        // "Finish the download and try again" and "this cannot work" want
        // opposite responses from the screen.
        #expect(recoverable)
    }

    @Test("cancelling reads as stopped, not as a broken certificate")
    func cancellationIsNotAFailureOfTheCertificate() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log,
                               planToReturn: outstandingPlan,
                               failure: CancellationError()),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }
        guard case .failed(let message, _) = snapshot.state(.assets) else {
            Issue.record("expected the assets stage to report the cancellation")
            return
        }
        #expect(message == ZKRunError.cancelled.localizedDescription)
    }

    @Test("download progress reaches the caller with its fraction intact")
    func progressIsForwarded() async throws {
        let log = CallLog()
        let emitted = [
            ZKAssetProgress(displayName: "chain key", overallFraction: 0.25,
                            completedCount: 0, totalCount: 3),
            ZKAssetProgress(displayName: "chain key", overallFraction: 0.5,
                            completedCount: 0, totalCount: 3)
        ]
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: outstandingPlan, progressToEmit: emitted),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let seen = Collected()
        _ = await runner.run(challenge: Fixture.challenge) { snapshot in
            if case .running(let fraction, _) = snapshot.state(.assets), let fraction {
                seen.append(fraction)
            }
        }
        // Without the forward, the bar sits at zero for 140 MB — the exact
        // "looks like it has hung" failure `CircuitAssets` documents.
        #expect(seen.values.contains(0.25))
        #expect(seen.values.contains(0.5))
    }

    @Test("a second run is refused while the first is still proving")
    func refusesConcurrentRuns() async throws {
        let log = CallLog()
        let gate = Gate()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle()), gate: gate))

        async let first = runner.run(challenge: Fixture.challenge) { _ in }
        // Let the first run get as far as the prover.
        while log.count("prove") == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = await runner.run(challenge: Fixture.challenge) { _ in }
        await gate.open()
        let firstResult = await first

        guard case .failed(let message, _) = second.state(.assets) else {
            Issue.record("expected the second run to be refused")
            return
        }
        #expect(message == ZKRunError.alreadyRunning.localizedDescription)
        // Proving holds ~2 GB; a second concurrent run is a kill, not a
        // slowdown. One call, not two.
        #expect(log.count("prove") == 1)
        #expect(firstResult.report != nil)
    }

    @Test("a download failure that only costs on-device checking does not stop the run")
    func verificationOnlyAssetFailureDoesNotStopTheRun() async throws {
        let log = CallLog()
        // The phone this happens on: 1.2 GB free. The 950 MB of proving material
        // installs, then the verifying keys' space check asks for ~778 MB more
        // and cannot have it. Stopping here spends the 950 MB and produces
        // nothing — on this attempt and on every retry, because the file being
        // waited for is one the prover never opens and will never fit.
        let plan = ZKAssetPlan(outstanding: [
            ZKAssetRequirement(name: "cert_chain_rs4096_verifying",
                               displayName: "checking key",
                               downloadByteCount: 41_321_957,
                               installedByteCount: 693_663_362,
                               isStale: false)
        ])
        let runner = makeRunner(
            assets: FakeAssets(log: log,
                               planToReturn: plan,
                               failure: CircuitAssetError.insufficientDiskSpace(
                                   required: 778_000_000, available: 250_000_000),
                               verificationOnly: ["cert_chain_rs4096_verifying"]),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle(
                selfCheck: .notPerformed(missing: ["keys/cert_chain_rs4096_verifying.key"])))))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        // The proof happened.
        #expect(log.count("prove") == 1)
        guard case .succeeded = snapshot.state(.proof) else {
            Issue.record("expected a proof, got \(snapshot.state(.proof))")
            return
        }
        #expect(snapshot.report != nil)
        // And both ends of the story say the same thing: neither a tick nor a
        // warning triangle, because nothing the holder did failed and the proof
        // was not judged.
        guard case .unavailable(let reason) = snapshot.state(.assets) else {
            Issue.record("expected .unavailable, got \(snapshot.state(.assets))")
            return
        }
        #expect(reason.contains(CircuitAssetError
            .insufficientDiskSpace(required: 0, available: 0).localizedDescription))
        #expect(ZKStagePresentation.verdict(for: snapshot.state(.assets)) == nil)
        guard case .unavailable = snapshot.state(.verification) else {
            Issue.record("expected .unavailable, got \(snapshot.state(.verification))")
            return
        }
    }

    @Test("a proving asset that is still outstanding stops the run as before")
    func provingAssetFailureStillStopsTheRun() async throws {
        let log = CallLog()
        // The same failure, one row different: what could not be prepared is a
        // proving key. Nothing downstream can happen, so the tolerance above must
        // not extend to it.
        let plan = ZKAssetPlan(outstanding: [
            ZKAssetRequirement(name: "cert_chain_rs4096_proving",
                               displayName: "chain key",
                               downloadByteCount: 41_321_996,
                               installedByteCount: 693_663_394,
                               isStale: false),
            ZKAssetRequirement(name: "cert_chain_rs4096_verifying",
                               displayName: "checking key",
                               downloadByteCount: 41_321_957,
                               installedByteCount: 693_663_362,
                               isStale: false)
        ])
        let runner = makeRunner(
            assets: FakeAssets(log: log,
                               planToReturn: plan,
                               failure: CircuitAssetError.insufficientDiskSpace(
                                   required: 778_000_000, available: 250_000_000),
                               verificationOnly: ["cert_chain_rs4096_verifying"]),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        guard case .failed = snapshot.state(.assets) else {
            Issue.record("expected the assets stage to fail, got \(snapshot.state(.assets))")
            return
        }
        #expect(log.count("sign") == 0)
        #expect(log.count("prove") == 0)
    }

    @Test("a total from upstream that overflows does not take the run down with it")
    func overflowingTotalsDoNotTrapTheRun() async throws {
        let log = CallLog()
        // `proveMs` is a UInt64 from Rust that nothing validates. The stage row
        // reads their sum, so `+` here traps *after* a thirty-second proof
        // succeeded — losing the run to a bad integer from a dependency.
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log,
                               result: .success(Fixture.bundle(certificateChainMs: .max,
                                                               userSignatureMs: 1,
                                                               certificateChainBytes: .max,
                                                               userSignatureBytes: 2))))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        guard case .succeeded = snapshot.state(.proof) else {
            Issue.record("expected the proof stage to survive, got \(snapshot.state(.proof))")
            return
        }
        let report = try #require(snapshot.report)
        #expect(report.bundle.totalProveMilliseconds == UInt64.max)
        #expect(report.bundle.totalProofByteCount == UInt64.max)
        // Saturated, so the report flags it rather than printing a plausible
        // small number.
        #expect(report.text.contains("IMPOSSIBLE TIMING"))
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - What "verified" is allowed to mean

@Suite("ZK verification semantics")
struct ZKVerificationSemanticsTests {

    /// A rejected proof no longer arrives as a bundle carrying a failing
    /// outcome, because `ZKProver` refuses to return one at all — see
    /// `ZKSelfCheck`. It arrives as `ZKProofError.proofRejectedOnThisDevice`,
    /// and this is the test that the runner does not then mistranslate it.
    ///
    /// Falling into the generic proving-failure branch reported it as stage 3
    /// (「建立證明」) failing, which says the proof could not be built, and left
    /// stage 4 at `.waiting`, which says nothing ever checked it. Both circuits
    /// proved and this device checked the result; only the fourth stage failed.
    @Test("a proof this device rejects fails the check, not the proving")
    func rejectedProofIsAFailure() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log,
                               result: .failure(ZKProofError.proofRejectedOnThisDevice)))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        // Stage 3 succeeded: the circuits ran. The refusal is stage 4's.
        guard case .succeeded = snapshot.state(.proof) else {
            Issue.record("both circuits proved, so 建立證明 must not read as failed: \(snapshot.state(.proof))")
            return
        }
        guard case .failed = snapshot.state(.verification) else {
            Issue.record("a proof that did not verify must not render as success: \(snapshot.state(.verification))")
            return
        }
        #expect(snapshot.isFinished)
        // No report: `ZKProofRunReport` carries a bundle, and there is no bundle
        // for a proof this device refused. The stage states carry the finding.
        #expect(snapshot.report == nil)
    }

    @Test("every one of the three checks has to pass")
    func allThreeChecksAreRequired() {
        func outcome(_ chain: Bool, _ signature: Bool, _ linked: Bool) -> ZKVerificationOutcome {
            ZKVerificationOutcome(certificateChainValid: chain,
                                  userSignatureValid: signature,
                                  linked: linked,
                                  certificateChainMilliseconds: 1,
                                  userSignatureMilliseconds: 1,
                                  linkMilliseconds: 1)
        }
        // Collapsing these into one boolean is how a screen ends up saying
        // 「已驗證」 on the strength of the weakest of the three.
        #expect(outcome(false, true, true).isFullyValid == false)
        #expect(outcome(true, false, true).isFullyValid == false)
        #expect(outcome(true, true, false).isFullyValid == false)
        #expect(outcome(true, true, true).isFullyValid)
    }

    @Test("missing verifying keys are unavailable, not a rejected proof")
    func missingKeysAreUnavailable() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log, result: .success(Fixture.bundle(
                selfCheck: .notPerformed(missing: ["keys/cert_chain_rs4096_verifying.key"])))))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        guard case .unavailable = snapshot.state(.verification) else {
            Issue.record("expected .unavailable, got \(snapshot.state(.verification))")
            return
        }
        // Never called: there is nothing to verify against, and calling anyway
        // would turn a missing file into "your proof is bad".
        #expect(log.count("verify") == 0)
        let report = try #require(snapshot.report)
        #expect(report.verification.outcome == nil)
        guard case .notAttempted = report.verification else {
            Issue.record("expected .notAttempted, got \(report.verification)")
            return
        }
        #expect(report.text.contains("NOT VERIFIED ON THIS DEVICE"))
    }

    /// The classification of "the verifier threw" into `.inconclusive` now
    /// happens in `ZKProver.verifyOnThisDevice` and is tested there
    /// (`distinguishesRejectedFromUncheckableFromUnprepared`). What is left for
    /// the runner, and what this pins, is that it does not upgrade that answer
    /// into a verdict on the way to the screen.
    @Test("a check that broke did not decide anything, and leaks no Rust message")
    func verifierThrowing() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log,
                               result: .success(Fixture.bundle(selfCheck: .inconclusive))))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        // `.unavailable`, not `.failed`: the check did not finish, so nothing was
        // decided about the proof, and a warning triangle would say otherwise.
        guard case .unavailable(let message) = snapshot.state(.verification) else {
            Issue.record("expected .unavailable, got \(snapshot.state(.verification))")
            return
        }
        #expect(!message.isEmpty)
        // The message is ours, not Foundation's rendering of an enum with no
        // `errorDescription` ("The operation couldn't be completed. (… error N.)")
        // and not a raw case name from below the FFI boundary.
        #expect(!message.contains("couldn't be completed"))
        #expect(!message.contains("inputOutput"))
        let report = try #require(snapshot.report)
        guard case .errored = report.verification else {
            Issue.record("expected .errored, got \(report.verification)")
            return
        }
    }

    @Test("an errored check is not reported as 'nothing checked it'")
    func erroredIsNotTheSameAsNotAttempted() {
        // Found by running it: the first real proof errored inside linkVerify and
        // the report announced "A proof was produced and nothing checked it",
        // which was false — something did check it and could not finish.
        let subject = ZKProofRunReport(
            environment: Fixture.environment(),
            bundle: Fixture.bundle(),
            verification: .errored(message: "the check blew up"),
            memory: ProvingBenchmark.MemoryObservation(),
            proveWallClockMs: 100, totalWallClockMs: 200,
            documentsPath: "/tmp", startedAt: Date(timeIntervalSince1970: 0))
        #expect(subject.text.contains("VERIFICATION DID NOT COMPLETE"))
        #expect(subject.text.contains("the check blew up"))
        #expect(!subject.text.contains("nothing checked this proof"))
        #expect(subject.verification.outcome == nil)
    }

    @Test("upstream's refusal arrives as a throw and is folded back into a verdict")
    func verificationFailedBecomesFalse() throws {
        // Measured on 2026-08-07 against real proofs: verifyCertChainRs4096 and
        // verifyUserSigRs2048 returned true, and linkVerify *threw*
        // VerificationFailed rather than returning false. Left alone that error
        // propagates and a refused proof is rendered as an infrastructure
        // hiccup — inviting a retry instead of a stop.
        let (value, _) = try OpenACProofVerifier.timed {
            throw ProofBackendFailure.verificationFailed
        }
        #expect(value == false)

        // Everything else still throws: those say nothing about the proof.
        for failure in [ProofBackendFailure.fileNotFound, .inputOutput, .invalidInput,
                        .setupRequired, .proofGenerationFailed, .unknown] {
            #expect(throws: failure) {
                _ = try OpenACProofVerifier.timed { throw failure }
            }
        }
        let (passing, _) = try OpenACProofVerifier.timed { true }
        #expect(passing)
    }

    @Test("the real verifier looks for the verifying keys and the proof files")
    func realVerifierNamesItsInputs() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let missing = OpenACProofVerifier().missingArtifacts(in: directory)
        // Both verifying keys and both proofs and both instances: six files, all
        // absent from a directory that does not exist.
        #expect(missing.contains("keys/cert_chain_rs4096_verifying.key"))
        #expect(missing.contains("keys/user_sig_rs2048_verifying.key"))
        #expect(missing.contains("keys/cert_chain_rs4096_proof.bin"))
        #expect(missing.contains("keys/cert_chain_rs4096_instance.bin"))
        #expect(missing.count == 6)
    }
}

// MARK: - The report

@Suite("ZK proof run report")
struct ZKProofRunReportTests {

    /// The value in the report row labelled `label`.
    ///
    /// Column alignment is `max(label.count, 26)`, which makes a literal
    /// `"prove user_sig_rs2048      4222 ms"` a padding puzzle rather than an
    /// assertion — and one that fails for the wrong reason the day a label gets
    /// a character longer. Matching the label and reading the rest keeps the
    /// thing being tested (which figure landed in which row) in the test.
    private func value(_ label: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(label) else { continue }
            let rest = trimmed.dropFirst(label.count)
            guard rest.isEmpty || rest.first == " " else { continue }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func report(bundle: ZKProofBundle = Fixture.bundle(),
                        verification: ZKVerificationResult = .completed(Fixture.outcome),
                        environment: ProvingBenchmark.Environment = Fixture.environment(),
                        proveWallClockMs: UInt64 = 34_000,
                        totalWallClockMs: UInt64 = 34_400,
                        peak: UInt64? = 2_100_000_000) -> ZKProofRunReport {
        ZKProofRunReport(environment: environment,
                         bundle: bundle,
                         verification: verification,
                         memory: ProvingBenchmark.MemoryObservation(peakFootprintBytes: peak,
                                                                    headroomAtStartBytes: nil),
                         proveWallClockMs: proveWallClockMs,
                         totalWallClockMs: totalWallClockMs,
                         documentsPath: "/tmp/zk",
                         startedAt: Date(timeIntervalSince1970: 1_754_500_000))
    }

    @Test("each circuit's own timing survives to the page")
    func perCircuitTimings() {
        let text = report(bundle: Fixture.bundle(certificateChainMs: 31_111,
                                                 userSignatureMs: 4_222)).text
        // Two interchangeable UInt64s per circuit made this the class of bug
        // worth pinning by hand: copying one circuit's figure into the other's
        // slot compiles and prints a plausible report.
        #expect(value("prove cert_chain_rs4096", in: text) == "31111 ms (31.11 s)")
        #expect(value("prove user_sig_rs2048", in: text) == "4222 ms (4.22 s)")
        #expect(value("prove reported total", in: text) == "35333 ms (35.33 s)")
    }

    @Test("each circuit's own proof size survives to the page")
    func perCircuitSizes() {
        let text = report(bundle: Fixture.bundle(certificateChainBytes: 801,
                                                 userSignatureBytes: 259)).text
        #expect(value("proof cert_chain_rs4096", in: text) == "801 bytes")
        #expect(value("proof user_sig_rs2048", in: text) == "259 bytes")
        #expect(value("proof total", in: text) == "1.06 kB (1060 bytes)")
    }

    @Test("the report does not claim runCompleteBenchmark as its source")
    func doesNotClaimTheWrongSource() {
        let text = report().text
        #expect(value("source", in: text)?.hasPrefix("ZKProver.prove") == true)
        // `ProvingBenchmark.Report` carries a standing caveat saying the run
        // "just overwrote keys/ with locally generated proving keys". That is
        // true of its own path and false of this one, and it is why this report
        // is a separate type rather than a reuse.
        #expect(!text.contains("just overwrote keys/"))
    }

    @Test("every caveat on the bundle appears in the report")
    func caveatsAreRendered() {
        let text = report(bundle: Fixture.bundle(caveats: ProofCaveat.allCases)).text
        for caveat in ProofCaveat.allCases {
            #expect(text.contains(caveat.rawValue),
                    "\(caveat.rawValue) is missing from the report")
        }
        #expect(text.contains("WHAT THIS PROOF DOES NOT ESTABLISH"))
    }

    /// The two findings that decide what this project is allowed to claim have
    /// to survive into the artefact that gets pasted into an issue, and with
    /// their mechanism attached — on screen the sentence has to be readable by a
    /// cardholder, so "signs a fixed app_id rather than the challenge" can only
    /// be said here.
    @Test("the report states why the signing material is replayable and what the issuer sees")
    func mechanismsBehindTheTwoHighCaveats() {
        let text = report(bundle: Fixture.bundle(caveats: ProofCaveat.allCases)).text
        #expect(text.contains("signatureMaterialIsReplayable"))
        #expect(text.contains("idNumberDisclosedToIssuer"))
        // The mechanism, not just the label: the report is read by whoever has
        // to decide whether this route can be shipped.
        #expect(text.contains("base64(app_id)"))
        #expect(text.contains("ATH-02 returns"))
        #expect(text.contains("id_num"))
        #expect(text.contains("sp_service_id"))
    }

    /// `ZKProofBundle.caveats` is a plain stored array, so a caller that is not
    /// `ZKProver.caveats(for:)` can build a bundle with a limitation missing —
    /// and a report that omits one reads exactly like a report of a proof that
    /// does not have it. That is the one failure here that is silent, so it gets
    /// a banner above every number.
    @Test("a bundle missing an unconditional caveat is called out before any figure")
    func incompleteCaveatListIsBannered() {
        let subject = report(bundle: Fixture.bundle(caveats: [.noGlobalUniqueness]))
        #expect(subject.omittedUnconditionalCaveats
                == [.signatureMaterialIsReplayable,
                    .idNumberDisclosedToIssuer,
                    .certificateExpiryNotProven,
                    .revocationRootNotAnchored])

        let text = subject.text
        #expect(text.contains("CAVEAT LIST INCOMPLETE"))
        for caveat in subject.omittedUnconditionalCaveats {
            #expect(text.contains(caveat.rawValue), "\(caveat.rawValue) was not named")
        }
        guard let banner = text.range(of: "CAVEAT LIST INCOMPLETE"),
              let firstNumber = text.range(of: "TIMING") else {
            Issue.record("the banner and the timing section must both be present")
            return
        }
        #expect(banner.lowerBound < firstNumber.lowerBound)
    }

    /// …and a complete list says nothing, so the banner keeps meaning something.
    @Test("a complete caveat list produces no banner")
    func completeCaveatListIsSilent() {
        let subject = report(bundle: Fixture.bundle(caveats: ProofCaveat.allCases))
        #expect(subject.omittedUnconditionalCaveats.isEmpty)
        #expect(!subject.text.contains("CAVEAT LIST INCOMPLETE"))
    }

    @Test("the uniqueness caveat is stated even when everything verified")
    func uniquenessIsAlwaysStated() {
        let text = report(bundle: Fixture.bundle(caveats: [.noGlobalUniqueness]),
                          verification: .completed(Fixture.outcome)).text
        // A green verdict is exactly when someone is most likely to read
        // 「真人且唯一」 into it.
        #expect(text.contains("noGlobalUniqueness"))
        #expect(text.contains("a real person *and* counted only once"))
    }

    @Test("the simulator banner comes before any number")
    func simulatorBannerComesFirst() {
        let text = report(environment: Fixture.environment(isSimulator: true)).text
        guard let banner = text.range(of: "SIMULATOR RUN"),
              let firstNumber = text.range(of: "TIMING") else {
            Issue.record("the simulator banner and the timing section must both be present")
            return
        }
        // Nobody can quote a figure without having scrolled past the reason not
        // to.
        #expect(banner.lowerBound < firstNumber.lowerBound)
    }

    @Test("a not-verified run says so at the top")
    func notVerifiedBanner() {
        let text = report(verification: .notAttempted(reason: "no verifying keys")).text
        #expect(text.contains("NOT VERIFIED ON THIS DEVICE"))
        #expect(text.contains("no verifying keys"))
        #expect(value("verify", in: text) == "not attempted")
    }

    @Test("stage figures larger than the wall clock are flagged and do not trap")
    func impossibleTiming() {
        let subject = report(bundle: Fixture.bundle(certificateChainMs: 90_000,
                                                    userSignatureMs: 10_000),
                             proveWallClockMs: 1_000)
        // UInt64 subtraction that goes negative traps; this is a crash path, not
        // a formatting nit.
        #expect(subject.unaccountedProveMs == 0)
        #expect(subject.reportedExceedsWallClock)
        #expect(subject.text.contains("IMPOSSIBLE TIMING"))
    }

    @Test("totals saturate rather than trap on figures upstream never checked")
    func totalsSaturate() {
        // Both addends are UInt64s from Rust that nothing between there and here
        // validates. `+` traps, and every sibling total in these two files —
        // `ZKVerificationOutcome.totalMilliseconds`, `unaccountedProveMs` — is
        // already written not to.
        let bundle = Fixture.bundle(certificateChainMs: .max,
                                    userSignatureMs: 1,
                                    certificateChainBytes: .max,
                                    userSignatureBytes: 2)
        #expect(bundle.totalProveMilliseconds == UInt64.max)
        #expect(bundle.totalProofByteCount == UInt64.max)
        // Ordinary sums are untouched by the change.
        let normal = Fixture.bundle(certificateChainMs: 31_000, userSignatureMs: 4_100,
                                    certificateChainBytes: 803, userSignatureBytes: 261)
        #expect(normal.totalProveMilliseconds == 35_100)
        #expect(normal.totalProofByteCount == 1_064)
        // And the two things that read them draw it without trapping either.
        #expect(!ZKStagePresentation.durationString(bundle.totalProveMilliseconds).isEmpty)
        #expect(report(bundle: bundle).text.contains("18446744073709551615"))
    }

    @Test("zero milliseconds is an absence, not a result")
    func zeroIsNotAMeasurement() {
        let text = report(bundle: Fixture.bundle(certificateChainMs: 0, userSignatureMs: 0)).text
        #expect(text.contains("NO PROVE TIMING REPORTED"))
        #expect(text.contains("not reported (upstream returned 0)"))
    }

    @Test("thermal, low power and main-thread runs are all flagged")
    func inadmissibleConditions() {
        #expect(report(environment: Fixture.environment(thermalState: .serious))
            .text.contains("THERMAL STATE SERIOUS"))
        #expect(report(environment: Fixture.environment(lowPower: true))
            .text.contains("LOW POWER MODE"))
        #expect(report(environment: Fixture.environment(onMainThread: true))
            .text.contains("RAN ON THE MAIN THREAD"))
    }

    @Test("rendering is deterministic, so two runs can be diffed")
    func deterministicRendering() {
        let subject = report()
        #expect(subject.text == subject.text)
        for line in subject.text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Trailing whitespace is invisible in a terminal and loud in a diff.
            #expect(!line.hasSuffix(" "), "trailing whitespace on: \(line)")
        }
    }

    @Test("nothing from the holder's certificate reaches the report or the stages")
    func nothingSensitiveIsRendered() async throws {
        let log = CallLog()
        let inputs = try Fixture.inputs()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(inputs)),
            prover: FakeProver(log: log, result: .success(Fixture.bundle())))

        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }
        let report = try #require(snapshot.report)

        // The certificate carries a name and a 身分證統一編號 in its serial
        // number. A report is the single object here most likely to be pasted
        // into an issue.
        #expect(!report.text.contains(inputs.certificateBase64))
        #expect(!report.text.contains(inputs.signedResponse))
        for stage in ZKRunStage.allCases {
            let detail = ZKStagePresentation.detail(for: snapshot.state(stage))
            #expect(!detail.contains(inputs.certificateBase64))
            #expect(!detail.contains(inputs.signedResponse))
        }
    }
}

// MARK: - Stage rendering

@Suite("ZK stage rendering")
struct ZKStageRenderingTests {

    @Test("unavailable is not drawn as a failure")
    func unavailableIsNotAFailure() {
        // The conflation this screen exists to avoid: "this device cannot check
        // the proof" and "this device checked the proof and rejected it" are not
        // the same finding and must not share a warning triangle.
        #expect(ZKStagePresentation.verdict(for: .unavailable(reason: "no keys")) == nil)
        #expect(ZKStagePresentation.verdict(for: .failed(message: "no", recoverable: false))
                == .some(false))
        #expect(ZKStagePresentation.verdict(for: .succeeded(detail: "ok")) == .some(true))
        #expect(ZKStagePresentation.verdict(for: .waiting) == nil)
        #expect(ZKStagePresentation.verdict(for: .running(progress: nil, detail: nil)) == nil)
    }

    @Test("a running stage shows its percentage")
    func runningShowsPercentage() {
        let detail = ZKStagePresentation.detail(for: .running(progress: 0.42, detail: "chain key"))
        #expect(detail.contains("42%"))
        #expect(detail.contains("chain key"))
    }

    @Test("a running stage with no progress still says something")
    func runningWithoutProgress() {
        let detail = ZKStagePresentation.detail(for: .running(progress: nil, detail: nil))
        #expect(!detail.isEmpty)
        #expect(!detail.contains("%"))
    }

    @Test("only running stages spin")
    func onlyRunningSpins() {
        #expect(ZKStagePresentation.isBusy(.running(progress: nil, detail: nil)))
        #expect(!ZKStagePresentation.isBusy(.waiting))
        #expect(!ZKStagePresentation.isBusy(.succeeded(detail: "")))
        #expect(!ZKStagePresentation.isBusy(.unavailable(reason: "")))
    }

    @Test("a duration of zero is not rendered as an instant result")
    func zeroDuration() {
        let text = ZKStagePresentation.durationString(0)
        #expect(!text.contains("0"))
        #expect(ZKStagePresentation.durationString(400).contains("400"))
        #expect(ZKStagePresentation.durationString(31_000).contains("31"))
    }

    @Test("stage details are localized, not the report's ASCII form")
    func stageDetailsAreLocalized() async throws {
        let log = CallLog()
        let runner = makeRunner(
            assets: FakeAssets(log: log, planToReturn: readyPlan),
            signer: FakeSigner(log: log, result: .success(try Fixture.inputs())),
            prover: FakeProver(log: log,
                               result: .success(Fixture.bundle(certificateChainMs: 5_000,
                                                               userSignatureMs: 2_305))))
        let snapshot = await runner.run(challenge: Fixture.challenge) { _ in }

        let detail = ZKStagePresentation.detail(for: snapshot.state(.proof))
        // `ProvingBenchmark.Report.duration` renders "7305 ms (7.30 s)". That
        // belongs in the pasteable report, which is deliberately ASCII so two
        // devices can be diffed — and nowhere near a row of an interface that is
        // otherwise 正體中文.
        #expect(!detail.contains("ms ("))
        #expect(detail == ZKStagePresentation.durationString(7_305))
    }

    @Test("every stage has a non-empty title")
    func stagesAreNamed() {
        for stage in ZKRunStage.allCases {
            #expect(!stage.title.isEmpty)
            // An untranslated key reaching the screen looks like a title; this
            // catches the case where the catalog entry was never added.
            #expect(stage.title != stage.rawValue)
        }
    }

    @Test("every run error has a sentence")
    func errorsAreReadable() {
        let errors: [ZKRunError] = [
            .cancelled, .alreadyRunning,
            .assetsUnavailable(message: "x"),
            .trustAnchorRejected(.bundledChainBroken),
            .trustAnchorRejected(.trustAnchorExpired(on: Date(timeIntervalSince1970: 2_337_000_000))),
            .signingFailed(message: "x"),
            .signingUnavailable(message: "x"),
            .signingTimedOut,
            .inputsRejected(.certificateNotDER),
            .provingFailed(.revocationCheckDegraded),
            .verificationUnavailable(missing: ["a"]),
            .verificationFailed(message: "x")
        ]
        for error in errors {
            let message = error.localizedDescription
            #expect(!message.isEmpty)
            // Foundation's fallback for an Error with no errorDescription.
            #expect(!message.contains("couldn't be completed"))
        }
    }
}

// MARK: - Asset facts

@Suite("ZK asset preparation")
struct ZKAssetPreparationTests {

    @Test("the verifying keys land where the verifier looks for them")
    func verifyingKeyPaths() {
        let expected = Set(["keys/cert_chain_rs4096_verifying.key",
                            "keys/user_sig_rs2048_verifying.key"])
        #expect(Set(ZKVerifyingKeyAssets.all.map(\.localFilename)) == expected)
        // Naming them separately in two files is exactly how they drift apart.
        let directory = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let missing = Set(OpenACProofVerifier().missingArtifacts(in: directory))
        #expect(expected.isSubset(of: missing))
    }

    @Test("both verifying keys are digest-pinned")
    func verifyingKeysArePinned() {
        for asset in ZKVerifyingKeyAssets.all {
            let digest = try? #require(asset.sha256)
            guard let digest else { continue }
            // Every proof this app produces is checked under whatever lands in
            // keys/. A rolling `-latest` tag means an unpinned row is a file
            // anyone with publish rights can swap.
            #expect(digest.count == 64)
            #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(asset.compressedByteCount > 0)
            #expect(asset.installedByteCount > asset.compressedByteCount)
            // Never stale: a circuit is immutable, so there is nothing to
            // refresh, and a refresh interval here would re-download 58 MB daily.
            #expect(asset.refreshInterval == nil)
        }
    }

    @Test("verification roughly doubles what the user is asked for")
    func theExtraCostIsRealAndDisclosed() {
        // Not a rounding error, and the disclosure has to carry it: 81.5 MB
        // becomes 139 MB on the wire and 950 MB becomes 1.9 GB on disk.
        #expect(ZKVerifyingKeyAssets.totalDownloadByteCount > 50_000_000)
        #expect(CircuitAssetPreparer.totalDownloadByteCount
                == CircuitAssets.totalDownloadByteCount
                + ZKVerifyingKeyAssets.totalDownloadByteCount)
        #expect(CircuitAssetPreparer.totalInstalledByteCount > 1_800_000_000)
        #expect(CircuitAssetPreparer.allAssets.count == CircuitAssets.required.count + 2)
    }

    @Test("the prover is never asked for the 968 MB of verifying keys it cannot read")
    func provingStoreLeavesOutTheVerifyingKeys() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("keys"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Exactly what a proof needs, and nothing else — the state a 1.2 GB
        // phone ends up in after the download that fits.
        for asset in CircuitAssetPreparer.provingAssets {
            try Data([0x01]).write(to: directory.appendingPathComponent(asset.localFilename))
        }

        let proving = CircuitAssetPreparer.makeProvingStore(directory: directory)
        let stillMissing = await proving.missingAssets()
        let stale = await proving.staleAssets()
        // `ZKProver`'s readiness is exactly this list. Anything in it that the
        // prover does not read is a refusal to prove over a file it never opens.
        #expect(stillMissing.isEmpty)
        #expect(stale.isEmpty)

        // The download store still offers them: the split is about what blocks a
        // proof, not about hiding what verification costs.
        let download = CircuitAssetPreparer.makeStore(directory: directory)
        let offered = await download.missingAssets()
        #expect(Set(offered.map(\.name))
                == Set(CircuitAssetPreparer.verificationAssets.map(\.name)))
        #expect(CircuitAssetPreparer.provingAssets.count
                + CircuitAssetPreparer.verificationAssets.count
                == CircuitAssetPreparer.allAssets.count)
    }

    @Test("the preparer names the verifying keys as the only optional half")
    func verificationOnlyRequirementsAreNamed() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let preparer = CircuitAssetPreparer(store: CircuitAssets(directory: directory,
                                                                 session: .shared,
                                                                 assets: [])) { $0 }
        #expect(preparer.verificationOnlyRequirementNames
                == Set(ZKVerifyingKeyAssets.all.map(\.name)))
        // The issuer certificate belongs to the proving half even though it is
        // not a download: `ZKProver` refuses without it, so a run that skipped it
        // would fail one stage later with a worse sentence.
        #expect(!preparer.verificationOnlyRequirementNames
            .contains(CircuitAssetPreparer.issuerRequirementName))
        for asset in CircuitAssets.required {
            #expect(!preparer.verificationOnlyRequirementNames.contains(asset.name))
        }
    }

    @Test("the asset names are unique, because they name the resume sidecar too")
    func assetNamesAreUnique() {
        let names = CircuitAssetPreparer.allAssets.map(\.name)
        // `CircuitAssets` writes `<name>.resumedata` into a shared staging
        // directory; a collision means two downloads resume into each other.
        #expect(Set(names).count == names.count)
        let paths = CircuitAssetPreparer.allAssets.map(\.localFilename)
        #expect(Set(paths).count == paths.count)
    }

    @Test("the extra rows get a name a person can read")
    func extraRowsAreNamed() {
        for asset in ZKVerifyingKeyAssets.all {
            let name = CircuitAssetPreparer.displayName(for: asset)
            // `CircuitAsset.displayName` falls through to the raw identifier,
            // which would put `cert_chain_rs4096_verifying` on a Chinese screen.
            #expect(name != asset.name)
            #expect(!name.contains("_"))
        }
        // And the three it does know about are still passed through unchanged.
        for asset in CircuitAssets.required {
            #expect(CircuitAssetPreparer.displayName(for: asset) == asset.displayName)
        }
    }

    @Test("the plan lists the issuer certificate when it is not installed")
    func planIncludesTheIssuerCertificate() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CircuitAssets(directory: directory,
                                  session: .shared,
                                  assets: [])
        let installed = Locked<[URL]>([])
        let preparer = CircuitAssetPreparer(store: store) { url in
            installed.mutate { $0.append(url) }
            return url
        }

        let plan = await preparer.plan()
        // ZKProver refuses without it, so a screen that says 「已備妥」 while the
        // prover would refuse is precisely the failure this row prevents.
        #expect(plan.outstanding.map(\.name) == [CircuitAssetPreparer.issuerRequirementName])
        #expect(plan.isReady == false)
        #expect(plan.downloadByteCount == 0)
        #expect(plan.installedByteCount > 0)

        try await preparer.prepare { _ in }
        #expect(installed.value == [directory])
    }

    @Test("the trust anchor is installed even when a download later fails")
    func issuerCertificateIsNotQueuedBehindTheDownloads() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Refused immediately and without leaving this machine.
        let unreachable = CircuitAsset(name: "unreachable",
                                       remoteURL: URL(string: "http://127.0.0.1:1/nope")!,
                                       localFilename: "unreachable.bin",
                                       compressedByteCount: 1,
                                       installedByteCount: 1,
                                       expandsAfterDownload: false)
        let store = CircuitAssets(directory: directory,
                                  session: URLSession(configuration: .ephemeral),
                                  assets: [unreachable])
        let installed = Locked<[URL]>([])
        let preparer = CircuitAssetPreparer(store: store) { url in
            installed.mutate { $0.append(url) }
            return url
        }

        do {
            try await preparer.prepare { _ in }
            Issue.record("expected the download to fail")
        } catch {
            // The point of the test is what happened before it.
        }

        // Installed last, the free 1.6 KB step was queued behind 82 MB that can
        // fail — and on a device that cannot fit the verifying keys, always
        // does. The anchor then stayed outstanding, so the next run saw a
        // requirement the *prover* needs still missing and stopped, for ever.
        #expect(installed.value == [directory])
    }

    /// The plan is the only thing standing between the file on disk and
    /// `generateCertChainRs4096Input`, so what it accepts is a security
    /// decision. It used to accept any file of non-zero length.
    @Test("only the pinned bytes drop the issuer certificate out of the plan")
    func onlyTheVerifiedIssuerCertificateIsNotOutstanding() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CircuitAssets(directory: directory, session: .shared, assets: [])
        let preparer = CircuitAssetPreparer(store: store)

        // Two bytes that open like a DER certificate and are not one — exactly
        // what the old `fileSize > 0` test called prepared.
        try Data([0x30, 0x82]).write(
            to: directory.appendingPathComponent(IssuerCertificate.installedFilename))
        let withRubbish = await preparer.plan()
        #expect(withRubbish.isReady == false)
        #expect(withRubbish.outstanding.map(\.name)
                == [CircuitAssetPreparer.issuerRequirementName])

        _ = try IssuerCertificate.loadBundled().install(into: directory)
        let withAnchor = await preparer.plan()
        #expect(withAnchor.isReady)
    }

    /// **The regression test for the defect.**
    ///
    /// `plan()` is called at the start of every run and `prepare()` only when
    /// something is outstanding, so an installed anchor that reported itself
    /// prepared was never re-examined — and `ZKProver.prove` checks only that
    /// the path exists before making it the issuer key of every proof. A file
    /// altered after installation is the same length and still non-empty, which
    /// is everything the old check looked at.
    @Test("an anchor altered after installation goes back into the plan and is rewritten")
    func alteredIssuerCertificateIsDetectedAndReplaced() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CircuitAssets(directory: directory, session: .shared, assets: [])
        // The real installer, not a stub: the repair path is the thing under
        // test, and it costs no network because this store has no assets.
        let preparer = CircuitAssetPreparer(store: store)

        let anchor = try IssuerCertificate.loadBundled()
        let installed = try anchor.install(into: directory)
        let afterInstall = await preparer.plan()
        #expect(afterInstall.isReady)

        var altered = try Data(contentsOf: installed)
        altered[altered.count - 1] ^= 0x01
        try altered.write(to: installed)
        #expect(altered.count == anchor.certificate.der.count)

        let afterTampering = await preparer.plan()
        #expect(afterTampering.isReady == false)
        #expect(afterTampering.outstanding.map(\.name)
                == [CircuitAssetPreparer.issuerRequirementName])
        // Nothing to download; the row costs a 1.6 KB write.
        #expect(afterTampering.downloadByteCount == 0)

        try await preparer.prepare { _ in }
        // Detected and refused: the altered bytes are gone, replaced by the ones
        // `loadBundled` verified against the pin.
        #expect(try Data(contentsOf: installed) == anchor.certificate.der)
        let afterRepair = await preparer.plan()
        #expect(afterRepair.isReady)
    }

    @Test("progress is weighted by download size, not by row count")
    func progressIsWeighted() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x30]).write(
            to: directory.appendingPathComponent(IssuerCertificate.installedFilename))

        // A one-byte asset and a huge one. Counting rows would put the bar at
        // 50% after the small one; weighting puts it near zero, which is what
        // the user is actually waiting on.
        let tiny = CircuitAsset(name: "tiny",
                                remoteURL: URL(string: "https://example.invalid/a")!,
                                localFilename: "tiny.bin",
                                compressedByteCount: 1,
                                installedByteCount: 1,
                                expandsAfterDownload: false)
        let huge = CircuitAsset(name: "huge",
                                remoteURL: URL(string: "https://example.invalid/b")!,
                                localFilename: "huge.bin",
                                compressedByteCount: 99,
                                installedByteCount: 99,
                                expandsAfterDownload: false)
        let plan = ZKAssetPlan(outstanding: [tiny, huge].map {
            ZKAssetRequirement(name: $0.name,
                               displayName: $0.name,
                               downloadByteCount: $0.compressedByteCount,
                               installedByteCount: $0.installedByteCount,
                               isStale: false)
        })
        // The arithmetic, not the download: after the 1-byte row finishes, the
        // overall fraction is 1/100, not 1/2.
        let total = plan.downloadByteCount
        #expect(total == 100)
        #expect(Double(tiny.compressedByteCount) / Double(total) == 0.01)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); body(&storage); lock.unlock()
    }
}

// MARK: - The TW FidO round trip

private struct FakeSignSession: TWFidOSignSession {
    let log: CallLog
    var ticket = TWFidOTicket(spTicket: "t", transactionID: "tx", spTicketID: "id")
    var deepLink = URL(string: "mobilemoica://moica.moi.gov.tw/a2a/verifySign")!
    var beginFailure: Error?
    /// One entry per poll: `nil` means "the holder has not finished yet".
    var pollResults: [TWFidOSignResult?] = []
    var pollFailure: Error?

    func begin(idNumber: String, hint: String, timeLimit: Int) async throws
        -> (ticket: TWFidOTicket, deepLink: URL) {
        log.record("begin")
        if let beginFailure { throw beginFailure }
        return (ticket, deepLink)
    }

    func poll(ticket: TWFidOTicket) async throws -> TWFidOSignResult? {
        let index = log.count("poll")
        log.record("poll")
        if let pollFailure { throw pollFailure }
        guard index < pollResults.count else { return nil }
        return pollResults[index]
    }
}

private struct FakeCallbacks: TWFidOCallbackWaiting {
    let log: CallLog
    /// When true, `waitForCallback` returns straight away, standing in for the
    /// `backuptw://` return leg arriving.
    var fires = false

    func waitForCallback(transactionID: String) async {
        log.record("waitForCallback")
        if fires { return }
        // Never resumes on its own. The signer has to call `cancelWait`, and the
        // whole point of this fake is that a signer which forgets deadlocks the
        // test rather than passing it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Box.shared.park(continuation, key: transactionID)
        }
    }

    func cancelWait(transactionID: String) async {
        log.record("cancelWait")
        Box.shared.resume(key: transactionID)
    }
}

private final class Box: @unchecked Sendable {
    static let shared = Box()
    private let lock = NSLock()
    private var parked: [String: [CheckedContinuation<Void, Never>]] = [:]

    func park(_ continuation: CheckedContinuation<Void, Never>, key: String) {
        lock.lock()
        parked[key, default: []].append(continuation)
        lock.unlock()
    }

    func resume(key: String) {
        lock.lock()
        let waiters = parked.removeValue(forKey: key) ?? []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}

private let signResult = TWFidOSignResult(cert: Fixture.certificateBase64,
                                          signedResponse: Fixture.signedResponse,
                                          hashedIDNumber: "irrelevant")

private func makeSigner(session: FakeSignSession,
                        callbacks: FakeCallbacks,
                        opens: Bool = true,
                        clock: Counter = Counter(),
                        timeLimit: Int = 600,
                        validate: @escaping @Sendable (String) throws -> Void = { _ in })
    -> TWFidOHolderSigner {
    // Time advances by five seconds per reading, so a deadline is reached in a
    // bounded number of polls without any real waiting.
    TWFidOHolderSigner(
        idNumber: "A123456789",
        session: session,
        callbacks: callbacks,
        open: { _ in opens },
        timeLimit: timeLimit,
        pollInterval: 0,
        now: { Date(timeIntervalSince1970: 0).addingTimeInterval(Double(clock.next()) * 5) },
        sleep: { _ in },
        validateHolderCertificate: validate)
}

@Suite("TW FidO signing")
struct TWFidOHolderSignerTests {

    @Test("polls until the holder approves, then builds the proving inputs")
    func pollsUntilApproved() async throws {
        let log = CallLog()
        let session = FakeSignSession(log: log, pollResults: [nil, nil, signResult])
        let signer = makeSigner(session: session, callbacks: FakeCallbacks(log: log))

        let inputs = try await signer.sign(challenge: Fixture.challenge)

        #expect(inputs.certificateBase64 == Fixture.certificateBase64)
        #expect(log.count("poll") == 3)
        #expect(log.count("begin") == 1)
    }

    @Test("the callback waiter is always released, or the task group never finishes")
    func callbackWaiterIsAlwaysReleased() async throws {
        let log = CallLog()
        let session = FakeSignSession(log: log, pollResults: [nil, signResult])
        // `MOICACallbackRouter.waitForCallback` parks a continuation in a
        // dictionary and nothing else resumes it. A race that abandons the wait
        // strands the task, and `withTaskGroup` waits for its children — so the
        // signer would hang here rather than fail.
        _ = try await signer(log: log, session: session).sign(challenge: Fixture.challenge)
        #expect(log.count("cancelWait") >= 1)
        #expect(log.count("cancelWait") == log.count("waitForCallback"))
    }

    @Test("a callback shortens the wait instead of replacing the answer")
    func callbackIsAHintNotTheAnswer() async throws {
        let log = CallLog()
        let session = FakeSignSession(log: log, pollResults: [nil, signResult])
        let callbacks = FakeCallbacks(log: log, fires: true)
        _ = try await makeSigner(session: session, callbacks: callbacks)
            .sign(challenge: Fixture.challenge)
        // The signature always comes from an idp_checksum-authenticated ATH-02
        // response; the callback only decides when to ask again. Any app on the
        // device can open our scheme.
        #expect(log.count("poll") == 2)
    }

    @Test("waiting past the ticket's time limit is a timeout, not a hang")
    func stopsAtTheDeadline() async throws {
        let log = CallLog()
        // Never approves. Time advances 5 s per reading, so a 30 s limit ends it.
        let session = FakeSignSession(log: log, pollResults: [])
        let signer = makeSigner(session: session, callbacks: FakeCallbacks(log: log), timeLimit: 30)

        await #expect(throws: ZKRunError.signingTimedOut) {
            _ = try await signer.sign(challenge: Fixture.challenge)
        }
        #expect(log.count("poll") > 1)
    }

    @Test("a missing certificate app is unavailable, not a refused signature")
    func missingCertificateApp() async throws {
        let log = CallLog()
        let signer = makeSigner(session: FakeSignSession(log: log),
                                callbacks: FakeCallbacks(log: log),
                                opens: false)
        do {
            _ = try await signer.sign(challenge: Fixture.challenge)
            Issue.record("expected a refusal")
        } catch let error as ZKRunError {
            guard case .signingUnavailable = error else {
                Issue.record("expected .signingUnavailable, got \(error)")
                return
            }
            #expect(log.count("poll") == 0)
        }
    }

    @Test("missing SP credentials produce a sentence, not Foundation's fallback")
    func credentialErrorIsReadable() async throws {
        let log = CallLog()
        let session = FakeSignSession(log: log, beginFailure: SPCredentialError.notConfigured)
        do {
            _ = try await makeSigner(session: session,
                                     callbacks: FakeCallbacks(log: log))
                .sign(challenge: Fixture.challenge)
            Issue.record("expected a refusal")
        } catch let error as ZKRunError {
            guard case .signingUnavailable(let message) = error else {
                Issue.record("expected .signingUnavailable, got \(error)")
                return
            }
            // `SPCredentialError` is CustomStringConvertible on purpose, not
            // LocalizedError, so `localizedDescription` would be Foundation's
            // "The operation couldn't be completed."
            #expect(!message.contains("couldn't be completed"))
            #expect(!message.isEmpty)
        }
    }

    @Test("a certificate the issuer gate refuses never reaches the circuit")
    func certificateGateRunsBeforeProving() async throws {
        let log = CallLog()
        let session = FakeSignSession(log: log, pollResults: [signResult])
        let signer = makeSigner(session: session,
                                callbacks: FakeCallbacks(log: log)) { _ in
            log.record("validate")
            throw IssuerCertificateError.holderIssuerUnsupported(generation: .g2)
        }
        do {
            _ = try await signer.sign(challenge: Fixture.challenge)
            Issue.record("expected the gate to refuse")
        } catch let error as ZKRunError {
            guard case .signingFailed(let message) = error else {
                Issue.record("expected .signingFailed, got \(error)")
                return
            }
            // A G2 certificate produces a proof that is mathematically valid and
            // that no verifier accepts. Finding out here costs a millisecond;
            // finding out after `prove` costs thirty seconds and two gigabytes.
            #expect(log.count("validate") == 1)
            #expect(message == IssuerCertificateError
                .holderIssuerUnsupported(generation: .g2).localizedDescription)
        }
    }

    @Test("material the circuit would reject is refused before proving")
    func malformedMaterialIsRefused() async throws {
        let log = CallLog()
        let wrongLength = TWFidOSignResult(cert: Fixture.certificateBase64,
                                           signedResponse: Data([0x01, 0x02]).base64EncodedString(),
                                           hashedIDNumber: "")
        let session = FakeSignSession(log: log, pollResults: [wrongLength])
        do {
            _ = try await makeSigner(session: session, callbacks: FakeCallbacks(log: log))
                .sign(challenge: Fixture.challenge)
            Issue.record("expected a refusal")
        } catch let error as ZKRunError {
            guard case .inputsRejected(let reason) = error else {
                Issue.record("expected .inputsRejected, got \(error)")
                return
            }
            #expect(reason == .signedResponseWrongLength(byteCount: 2))
        }
    }

    private func signer(log: CallLog, session: FakeSignSession) -> TWFidOHolderSigner {
        makeSigner(session: session, callbacks: FakeCallbacks(log: log))
    }
}

// MARK: - The screen's copy

/// What the 最小揭露 screen *says*, as opposed to what it does.
///
/// These assertions exist because the defect they pin was not in a function. The
/// section above the button promised that the certificate's "serial number is
/// not in the revocation list" — the exact sentence `IssuerCertificate` forbids
/// in writing, and one the same screen contradicted a few hundred pixels lower
/// with `ProofCaveat.revocationRootNotAnchored`. Nothing failed; the screen
/// simply lied to whoever stopped reading at the top, which is most people.
///
/// Note what is and is not asserted here. Membership and ordering of the caveat
/// list are structural and hold in any language. Content is asserted only
/// negatively — `NSLocalizedString` returns English or 正體中文 depending on the
/// host's language, so a "must contain" over a sentence would pass or fail on
/// the simulator's locale, while "must not contain, in either language" is true
/// either way.
@Suite("最小揭露 screen copy")
struct ZKProofScreenCopyTests {

    /// A plan with work left to do that costs nothing on the wire.
    ///
    /// Not hypothetical, and not a degenerate case: `VerifyingKeyDerivation` cuts
    /// both verifying keys out of a proving key already on disk, so this is what
    /// every device sees once the proving keys are installed. The screen rendered
    /// it through the download wording and told the user 「下載 0 KB」 — the one
    /// screen in the app whose entire job is to itemise a price before a tap,
    /// naming a resource this step does not spend.
    @Test("work that costs nothing on the wire is not priced as a download")
    func derivedAssetsAreNotDescribedAsADownload() {
        let plan = ZKAssetPlan(outstanding: [
            ZKAssetRequirement(name: "cert_chain_rs4096_verifying",
                               displayName: "checking key",
                               downloadByteCount: 0,
                               installedByteCount: 693_663_362,
                               isStale: false)
        ])
        #expect(plan.downloadByteCount == 0)

        let summary = ZKStagePresentation.preparationSummary(for: plan)
        for text in [summary.title, summary.detail] {
            #expect(!text.contains("下載 0"), "priced a derived file as a download: \(text)")
            #expect(!text.contains("Download 0"), "priced a derived file as a download: \(text)")
        }
        // The disk cost is still disclosed — this is a rewording, not a silence.
        #expect(summary.detail.contains(ZKStagePresentation.byteString(693_663_362)))

        let row = ZKStagePresentation.requirementDetail(for: plan.outstanding[0])
        #expect(!row.contains("下載 0") && !row.contains("Download 0"),
                "priced a derived file as a download: \(row)")
        #expect(row.contains(ZKStagePresentation.byteString(693_663_362)))
    }

    /// The other half: a plan that really is a download must still say so, or the
    /// fix above would have removed the disclosure rather than corrected it.
    @Test("a real download is still priced as one")
    func realDownloadsStillSayDownload() {
        let plan = ZKAssetPlan(outstanding: [
            ZKAssetRequirement(name: "g3_tree_snapshot",
                               displayName: "revocation snapshot",
                               downloadByteCount: 27_657_187,
                               installedByteCount: 27_657_187,
                               isStale: false)
        ])
        let summary = ZKStagePresentation.preparationSummary(for: plan)
        let size = ZKStagePresentation.byteString(27_657_187)
        #expect(summary.detail.contains(size))
        #expect(ZKStagePresentation.requirementDetail(for: plan.outstanding[0]).contains(size))
    }

    /// Every phrasing of the claim that a certificate is good, in both
    /// languages the app renders.
    ///
    /// `IssuerCertificate.swift` states the rule next to the code: the snapshot's
    /// trust anchor is the SMT root published on-chain, nothing in this app has
    /// ever compared the two, its SHA-256 is `nil`, and anyone who can publish to
    /// `moica-revocation-smt` can serve a snapshot with revocations quietly
    /// dropped. "Checked against a list we cannot vouch for" is the strongest
    /// true sentence; "not revoked" is not available at any price.
    static let forbiddenRevocationClaims = [
        "not in the revocation list",
        "not on the revocation list",
        "is not revoked",
        "isn't revoked",
        "has not been revoked",
        "hasn't been revoked",
        "不在撤銷清單",
        "沒有在撤銷清單",
        "未被撤銷",
        "沒有被撤銷",
        "沒被撤銷"
    ]

    /// The sentence `IssuerCertificate.swift` forbids by name must not exist in
    /// anything this screen shows — the opening paragraph included, which is
    /// where it was.
    @Test("no sentence on the screen says the certificate is not revoked")
    func noRevocationClaimAnywhere() {
        for sentence in ZKProofCopy.allProse {
            for claim in Self.forbiddenRevocationClaims {
                #expect(!sentence.localizedCaseInsensitiveContains(claim),
                        "forbidden claim 「\(claim)」 in: \(sentence)")
            }
        }
    }

    /// The same rule for the pasteable report, which is the other place a
    /// sentence about revocation could be read as a verdict.
    @Test("the report does not say the certificate is not revoked either")
    func noRevocationClaimInTheReport() {
        let report = ZKProofRunReport(
            environment: Fixture.environment(),
            bundle: Fixture.bundle(caveats: ProofCaveat.allCases),
            verification: .completed(Fixture.outcome),
            memory: ProvingBenchmark.MemoryObservation(peakFootprintBytes: nil,
                                                       headroomAtStartBytes: nil),
            proveWallClockMs: 34_000,
            totalWallClockMs: 34_400,
            documentsPath: "/tmp/zk",
            startedAt: Date(timeIntervalSince1970: 1_754_500_000))
        for claim in Self.forbiddenRevocationClaims {
            #expect(!report.text.localizedCaseInsensitiveContains(claim),
                    "forbidden claim 「\(claim)」 in the report")
        }
    }

    /// **The consistency this screen used to lack.** Before the run it gave an
    /// unconditional claim; after the run it gave qualifiers. Both lists now come
    /// from `ZKProver.caveats(for:)`, so a caveat added there appears in both
    /// places without anyone remembering to.
    @Test("the list shown before the run is the list attached after it")
    func beforeAndAfterAreTheSameList() {
        #expect(ZKProofCopy.plannedCaveats == ZKProver.caveats(for: Fixture.challenge))
        // …and this screen never has a verifier's challenge, so it is the
        // complete list rather than a subset.
        #expect(ZKProofCopy.plannedCaveats == ProofCaveat.allCases)
    }

    /// The two HIGH findings have to be readable *before* the tap, not only in
    /// the result. Someone deciding whether to send their 身分證統一編號 to
    /// 內政部 is deciding at the top of this screen.
    @Test("the two limitations that change what this app may claim are shown up front")
    func theTwoHighCaveatsAreShownBeforeTheButton() {
        #expect(ZKProofCopy.plannedCaveats.contains(.signatureMaterialIsReplayable))
        #expect(ZKProofCopy.plannedCaveats.contains(.idNumberDisclosedToIssuer))
        // First and second, ahead of the older three: they decide whether the
        // rest is worth reading.
        #expect(Array(ZKProofCopy.plannedCaveats.prefix(2))
                == [.signatureMaterialIsReplayable, .idNumberDisclosedToIssuer])
    }

    /// Every planned caveat reaches the screen as its own sentence. An empty or
    /// duplicated one is a limitation that is technically listed and actually
    /// invisible.
    @Test("every caveat the screen plans to show has a sentence of its own")
    func everyPlannedCaveatHasASentence() {
        let sentences = ZKProofCopy.plannedCaveats.map(\.localizedDescription)
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == sentences.count)
        #expect(ZKProofCopy.allProse.allSatisfy { !$0.isEmpty })
    }
}
