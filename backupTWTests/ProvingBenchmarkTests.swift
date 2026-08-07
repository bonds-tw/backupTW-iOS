//
//  ProvingBenchmarkTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// `ProvingBenchmark` produces the number M3 is designed around, so the ways it
/// can be wrong are all quiet ones: a field copied into the wrong slot, a zero
/// printed as though it were a measurement, a simulator run quoted as if it
/// came off a phone, or a refusal that arrives only after the proving keys have
/// already been overwritten.
///
/// **Nothing here runs a proof.** A real run needs ~950 MB of proving keys on
/// disk and minutes of CPU; CI has neither. Everything below the
/// `ProvingBenchmarkRunning` seam is stubbed, and what is tested is the part
/// that is ours: the refusals, the arithmetic, the environment capture and the
/// wording.
struct ProvingBenchmarkTests {

    // MARK: - Copying the upstream result
    //
    // `BenchmarkResults` is seven `UInt64`s in a row. Writing `proveMs` where
    // `verifyMs` belongs compiles, reports plausible figures, and inverts the
    // one number the M3 go/no-go turns on. Nothing downstream would notice.

    @Test func everyUpstreamFieldLandsInItsOwnSlot() {
        // Seven distinct values, so any swap shows up as a mismatch rather than
        // being masked by an accidental equality.
        let upstream = StubUpstream(setupMs: 1, proveMs: 2, verifyMs: 3,
                                    provingKeyBytes: 4, verifyingKeyBytes: 5,
                                    proofBytes: 6, witnessBytes: 7)

        let measurements = ProvingBenchmark.Measurements(upstream)

        #expect(measurements.setupMs == 1)
        #expect(measurements.proveMs == 2)
        #expect(measurements.verifyMs == 3)
        #expect(measurements.provingKeyBytes == 4)
        #expect(measurements.verifyingKeyBytes == 5)
        #expect(measurements.proofBytes == 6)
        #expect(measurements.witnessBytes == 7)
    }

    // MARK: - Zero is an absence, not a result

    @Test func aZeroDurationIsReportedAsMissingRatherThanAsInstant() {
        #expect(ProvingBenchmark.Report.duration(0) == "not reported (upstream returned 0)")
    }

    @Test func aZeroByteCountIsReportedAsMissingRatherThanAsEmpty() {
        #expect(ProvingBenchmark.Report.size(0) == "not reported (upstream returned 0)")
    }

    /// The scenario: upstream fills in `prove` but leaves `setup` at zero. A
    /// report that prints `setup  0 ms` reads as "setup was free", which is the
    /// opposite of true — setup is the most expensive stage there is.
    @Test func aPartiallyReportedRunMarksOnlyTheMissingStage() {
        let text = Self.report(measurements: .init(setupMs: 0,
                                                   proveMs: 5231,
                                                   verifyMs: 13_004)).text

        #expect(Self.row("setup", in: text) == "not reported (upstream returned 0)")
        #expect(Self.row("prove", in: text) == "5231 ms (5.23 s)")
        #expect(Self.row("verify", in: text) == "13004 ms (13.00 s)")
    }

    @Test func aDurationOverASecondIsAlsoGivenInSeconds() {
        // 13 004 ms is the figure that decides whether verification can happen
        // at a counter. It has to be legible at a glance.
        #expect(ProvingBenchmark.Report.duration(13_004) == "13004 ms (13.00 s)")
        #expect(ProvingBenchmark.Report.duration(999) == "999 ms")
    }

    /// Rounded units are for reading; the raw count is for diffing two devices'
    /// reports against each other.
    @Test func byteCountsCarryBothTheUnitAndTheRawNumber() {
        let text = ProvingBenchmark.Report.bytes(693_663_394)
        #expect(text.contains("693663394"))
        #expect(text.contains("693.66 MB"))
        #expect(ProvingBenchmark.Report.bytes(512) == "512 bytes")
    }

    /// `nil` and `0` mean different things and must not print the same. `nil`
    /// is "the kernel would not say"; printing it as `0 bytes` would look like
    /// a measured result of zero peak memory.
    @Test func anUnavailablePeakFootprintSaysSoRatherThanPrintingZero() {
        let text = Self.report(memory: .init(peakFootprintBytes: nil,
                                             headroomAtStartBytes: nil)).text

        #expect(Self.row("peak during run", in: text) == "unavailable")
        #expect(Self.row("headroom at start", in: text) == "unavailable")
    }

    /// On the simulator the absence has a specific cause worth naming, because
    /// "no headroom reading" and "no memory limit at all" are opposite
    /// conclusions and only one of them is reassuring.
    @Test func aSimulatorReportExplainsWhyThereIsNoHeadroomFigure() {
        let text = Self.report(environment: Self.environment(isSimulator: true),
                               memory: .init(peakFootprintBytes: 100,
                                             headroomAtStartBytes: nil)).text
        #expect(Self.row("headroom at start", in: text)
                == "unavailable (no jetsam on the simulator)")
    }

    // MARK: - The report as an artefact

    /// Every one of the seven upstream figures reaches the page, in its own
    /// labelled row. Checked by row rather than by substring so that a figure
    /// landing under the wrong label still fails.
    @Test func everyUpstreamFigureReachesItsOwnRow() {
        let text = Self.report(measurements: .init(setupMs: 111,
                                                   proveMs: 222,
                                                   verifyMs: 333,
                                                   provingKeyBytes: 444,
                                                   verifyingKeyBytes: 555,
                                                   proofBytes: 666,
                                                   witnessBytes: 777)).text

        #expect(Self.row("setup", in: text) == "111 ms")
        #expect(Self.row("prove", in: text) == "222 ms")
        #expect(Self.row("verify", in: text) == "333 ms")
        #expect(Self.row("proving key", in: text) == "444 bytes")
        #expect(Self.row("verifying key", in: text) == "555 bytes")
        #expect(Self.row("proof", in: text) == "666 bytes")
        #expect(Self.row("witness file", in: text) == "777 bytes")
    }

    /// It gets pasted into an issue and diffed against another device's run, so
    /// two renders of the same values have to be byte-identical.
    @Test func theSameRunRendersIdenticallyTwice() {
        let report = Self.report()
        #expect(report.text == report.text)
    }

    @Test func theReportDoesNotEndWithStrayWhitespace() {
        let text = Self.report().text
        #expect(!text.hasSuffix("\n"))
        #expect(!text.hasSuffix(" "))
    }

    // MARK: - Banners
    //
    // A run can be inadmissible for reasons that leave no trace in the numbers.
    // The reasons go first, before anything quotable.

    @Test func aSimulatorRunLeadsWithItsOwnDisclaimer() {
        let text = Self.report(environment: Self.environment(isSimulator: true)).text

        #expect(text.hasPrefix("!! SIMULATOR RUN"))
        #expect(text.contains("NOT A BASIS FOR AN ON-DEVICE DECISION"))
        // The reason has to be there too — "simulator numbers are wrong" is not
        // actionable, "no jetsam, more cores, more bandwidth, no throttling" is.
        #expect(text.contains("jetsam"))
    }

    @Test func aDeviceRunCarriesNoSimulatorDisclaimer() {
        let text = Self.report(environment: Self.environment(isSimulator: false)).text
        #expect(!text.contains("SIMULATOR RUN"))
    }

    /// The banner is worthless if it appears after the figures — someone
    /// quoting the prove time would never reach it.
    @Test func theDisclaimerPrecedesEveryNumber() throws {
        let text = Self.report(environment: Self.environment(isSimulator: true),
                               measurements: .init(proveMs: 5231)).text

        let banner = try #require(text.range(of: "!! SIMULATOR RUN"))
        let timing = try #require(text.range(of: "5231"))
        #expect(banner.lowerBound < timing.lowerBound)
    }

    /// The run happened, so the sizes may be real, but nothing about duration
    /// can be read off it.
    @Test func aRunThatMeasuredNoTimeAtAllSaysSo() {
        let text = Self.report(measurements: .init(setupMs: 0, proveMs: 0, verifyMs: 0,
                                                   proofBytes: 8192)).text
        #expect(text.contains("NO TIMING REPORTED"))
    }

    @Test func timingsThatDoNotSayNothingRaiseNoSuchBanner() {
        let text = Self.report(measurements: .init(proveMs: 1)).text
        #expect(!text.contains("NO TIMING REPORTED"))
    }

    @Test func aThrottledDeviceIsFlaggedAndANominalOneIsNot() {
        let hot = Self.report(environment: Self.environment(thermalState: .serious)).text
        #expect(hot.contains("THERMAL STATE SERIOUS"))

        let cool = Self.report(environment: Self.environment(thermalState: .nominal)).text
        #expect(!cool.contains("THERMAL STATE"))
    }

    @Test func lowPowerModeIsFlagged() {
        #expect(Self.report(environment: Self.environment(lowPower: true)).text
            .contains("LOW POWER MODE WAS ON"))
        #expect(!Self.report(environment: Self.environment(lowPower: false)).text
            .contains("LOW POWER MODE"))
    }

    /// The upstream call blocks for minutes. Wiring it straight to a button
    /// handler freezes the app, and the timings then include whatever the main
    /// thread was fighting over.
    @Test func aRunOnTheMainThreadIsFlagged() {
        #expect(Self.report(environment: Self.environment(onMainThread: true)).text
            .contains("RAN ON THE MAIN THREAD"))
        #expect(!Self.report(environment: Self.environment(onMainThread: false)).text
            .contains("RAN ON THE MAIN THREAD"))
    }

    // MARK: - Caveats that must survive being pasted

    @Test func theReportSaysThatTheRunDestroyedThePinnedKeys() {
        // The most consequential side effect in the module. If this line ever
        // goes missing, someone benchmarks, keeps using the app, and every
        // proof afterwards is generated under a locally derived key.
        #expect(Self.report().text.contains("overwrote keys/"))
    }

    @Test func theReportSaysThatSetupIsNotAStepProductionTakes() {
        #expect(Self.report().text.contains("never calls setup"))
    }

    /// Verification timings invite the conclusion "so offline checking works".
    /// It does, for the proof — but not for uniqueness, and the report must not
    /// let that half-truth travel on its own.
    @Test func theReportRefusesToLetVerifyTimeImplyUniqueness() {
        let text = Self.report().text
        #expect(text.contains("nullifier"))
        #expect(text.contains("real person"))
    }

    // MARK: - Arithmetic

    @Test func timeUpstreamDidNotAccountForIsTheWallClockRemainder() {
        let report = Self.report(measurements: .init(setupMs: 100, proveMs: 200, verifyMs: 300),
                                 wallClockMs: 1000)
        #expect(report.measurements.reportedTotalMs == 600)
        #expect(report.unaccountedMs == 400)
        #expect(report.text.contains("40.0% of wall clock"))
    }

    /// A `UInt64` subtraction that goes negative traps, which would turn a
    /// merely suspicious run into a crash in the diagnostics screen.
    @Test func stagesLongerThanTheRunDoNotCrashTheReport() {
        let report = Self.report(measurements: .init(setupMs: 5000, proveMs: 5000, verifyMs: 5000),
                                 wallClockMs: 10)

        #expect(report.unaccountedMs == 0)
        #expect(report.reportedExceedsWallClock)
        #expect(report.text.contains("IMPOSSIBLE TIMING"))
    }

    @Test func aSaneRunIsNotAccusedOfImpossibleTiming() {
        let report = Self.report(measurements: .init(proveMs: 10), wallClockMs: 100)
        #expect(!report.reportedExceedsWallClock)
        #expect(!report.text.contains("IMPOSSIBLE TIMING"))
    }

    @Test func summingTheStagesSaturatesRatherThanOverflowing() {
        let measurements = ProvingBenchmark.Measurements(setupMs: .max,
                                                         proveMs: .max,
                                                         verifyMs: .max)
        #expect(measurements.reportedTotalMs == UInt64.max)
    }

    @Test func aClockThatRunsBackwardsYieldsZeroRatherThanTrapping() {
        #expect(ProvingBenchmark.milliseconds(fromNanoseconds: 5_000_000, to: 1_000_000) == 0)
        #expect(ProvingBenchmark.milliseconds(fromNanoseconds: 1_000_000, to: 5_000_000) == 4)
    }

    // MARK: - Environment capture

    @Test func aSimulatorReportNamesTheDeviceItIsPretendingToBe() {
        let environment = Self.environment(isSimulator: true,
                                           hardwareModel: "arm64",
                                           simulatedModel: "iPhone17,1")
        #expect(environment.deviceDescription == "simulator: iPhone17,1 (host arm64)")
    }

    @Test func aSimulatorWithNoModelIdentifierStillSaysItIsASimulator() {
        let environment = Self.environment(isSimulator: true,
                                           hardwareModel: "arm64",
                                           simulatedModel: nil)
        #expect(environment.deviceDescription.contains("simulator"))
        #expect(environment.deviceDescription.contains("unknown model"))
    }

    @Test func aDeviceReportNamesTheHardwareModel() {
        let environment = Self.environment(isSimulator: false, hardwareModel: "iPhone14,5")
        #expect(environment.deviceDescription == "iPhone14,5")
    }

    /// Compiled for the simulator, so this must say so. The detection is a
    /// compile-time flag precisely so it cannot be talked out of it.
    @Test func theCapturedEnvironmentKnowsWhereItIsRunning() {
        let environment = ProvingBenchmark.Environment.current(environmentVariables: [:])
        #if targetEnvironment(simulator)
        #expect(environment.isSimulator)
        #else
        #expect(!environment.isSimulator)
        #endif
        #expect(!environment.hardwareModel.isEmpty)
        #expect(!environment.osVersion.isEmpty)
        #expect(environment.physicalMemoryBytes > 0)
    }

    @Test func theCapturedEnvironmentReadsTheSimulatedModelFromTheProcessEnvironment() {
        let environment = ProvingBenchmark.Environment.current(
            environmentVariables: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone16,2"])
        #expect(environment.simulatedModel == "iPhone16,2")
    }

    /// The prover is rayon-parallel, so a run with the thread count pinned is
    /// not comparable with one without. A report that does not say which it was
    /// cannot be compared with anything.
    @Test func theRayonThreadCountIsRecordedWhetherOrNotItIsSet() {
        let pinned = ProvingBenchmark.Environment.current(
            environmentVariables: ["RAYON_NUM_THREADS": "2"])
        #expect(pinned.rayonThreads == "2")
        #expect(Self.report(environment: Self.environment(rayonThreads: "2")).text
            .contains("RAYON_NUM_THREADS"))

        let unset = ProvingBenchmark.Environment.current(environmentVariables: [:])
        #expect(unset.rayonThreads == nil)
        #expect(Self.report(environment: Self.environment(rayonThreads: nil)).text
            .contains("unset"))
    }

    // MARK: - Refusing to start
    //
    // Both refusals exist because the alternative is worse than an error: one
    // ends in an opaque FFI failure after a long wait, the other in the silent
    // replacement of two digest-pinned proving keys.

    @Test func refusesWhenTheConstraintSystemsAreNotThere() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let blockers = ProvingBenchmark.preflightBlockers(documentsPath: directory.path,
                                                          allowOverwritingPinnedKeys: true,
                                                          pinnedAssetPaths: [])

        #expect(blockers.count == 2)
        #expect(blockers.allSatisfy {
            if case .missingConstraintSystem = $0 { return true }
            return false
        })
    }

    /// Upstream reads the `.r1cs` files from the root of `documentsPath`, not
    /// from `keys/`. Looking in the wrong place would make the preflight refuse
    /// a run that could have gone ahead.
    @Test func theConstraintSystemsAreLookedForInTheRootNotUnderKeys() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let blockers = ProvingBenchmark.preflightBlockers(documentsPath: directory.path,
                                                          allowOverwritingPinnedKeys: true,
                                                          pinnedAssetPaths: [])
        for blocker in blockers {
            guard case .missingConstraintSystem(let path) = blocker else { continue }
            #expect(!path.contains("/keys/"))
            #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == directory.path)
        }
    }

    /// Ties this module's spelling of the filenames to the asset table's, so
    /// the two cannot drift while nobody is watching. Compared by basename
    /// because the directories deliberately differ — `CircuitAssets.setupOnly`
    /// carries a `keys/` prefix that setup would not find.
    @Test func theConstraintSystemNamesMatchTheAssetTable() {
        let fromTable = Set(CircuitAssets.setupOnly.map {
            URL(fileURLWithPath: $0.localFilename).lastPathComponent
        })
        #expect(Set(ProvingBenchmark.constraintSystemFilenames) == fromTable)
    }

    @Test func acceptsTheRunOnceTheConstraintSystemsArePresent() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)

        let blockers = ProvingBenchmark.preflightBlockers(documentsPath: directory.path,
                                                          allowOverwritingPinnedKeys: true,
                                                          pinnedAssetPaths: [])
        #expect(blockers.isEmpty)
    }

    @Test func refusesWhenItWouldOverwriteAPinnedProvingKey() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)
        try Self.touch(["keys/cert_chain_rs4096_proving.key"], in: directory)

        let blockers = ProvingBenchmark.preflightBlockers(
            documentsPath: directory.path,
            allowOverwritingPinnedKeys: false,
            pinnedAssetPaths: ["keys/cert_chain_rs4096_proving.key"])

        #expect(blockers == [.wouldOverwritePinnedKey(
            path: directory.appendingPathComponent("keys/cert_chain_rs4096_proving.key").path)])
    }

    @Test func consentToOverwritingClearsThatRefusalOnly() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)
        try Self.touch(["keys/cert_chain_rs4096_proving.key"], in: directory)

        #expect(ProvingBenchmark.preflightBlockers(
            documentsPath: directory.path,
            allowOverwritingPinnedKeys: true,
            pinnedAssetPaths: ["keys/cert_chain_rs4096_proving.key"]).isEmpty)
    }

    @Test func anAbsentPinnedKeyIsNothingToRefuseOver() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)

        #expect(ProvingBenchmark.preflightBlockers(
            documentsPath: directory.path,
            allowOverwritingPinnedKeys: false,
            pinnedAssetPaths: ["keys/cert_chain_rs4096_proving.key"]).isEmpty)
    }

    /// The state a real user is actually in: assets downloaded, `.r1cs` never
    /// fetched. Reporting one problem sends them off to fix the wrong thing.
    @Test func bothKindsOfRefusalAreReportedTogetherAndInAStableOrder() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(["keys/a.key", "keys/b.key"], in: directory)

        let blockers = ProvingBenchmark.preflightBlockers(
            documentsPath: directory.path,
            allowOverwritingPinnedKeys: false,
            pinnedAssetPaths: ["keys/a.key", "keys/b.key"])

        #expect(blockers.count == 4)
        #expect(blockers == ProvingBenchmark.preflightBlockers(
            documentsPath: directory.path,
            allowOverwritingPinnedKeys: false,
            pinnedAssetPaths: ["keys/a.key", "keys/b.key"]))

        let described = ProvingBenchmark.Failure.refused(blockers).description
        #expect(described.contains("certChainRS4096.r1cs"))
        #expect(described.contains("keys/a.key"))
    }

    /// The two proving keys are the whole reason this guard exists — every
    /// proof the app makes is generated under them. The revocation snapshot is
    /// not pinned by digest and is refetched daily, so overwriting it costs
    /// nothing and must not block a benchmark.
    @Test func thePinnedListCoversTheProvingKeysAndNothingElse() {
        let pinned = ProvingBenchmark.pinnedAssetPaths
        #expect(pinned.contains("keys/cert_chain_rs4096_proving.key"))
        #expect(pinned.contains("keys/user_sig_rs2048_proving.key"))
        #expect(!pinned.contains { $0.hasSuffix(".json.gz") })
    }

    /// The point of the preflight is that the refusal costs nothing. If the
    /// prover were reached first, the user would wait minutes — or lose the
    /// keys — before being told no.
    @Test func aRefusedRunNeverReachesTheProver() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runner = StubRunner(result: .success(.init(proveMs: 1)))
        var refused = false
        do {
            _ = try ProvingBenchmark.run(documentsPath: directory.path,
                                         runner: runner,
                                         pinnedAssetPaths: [],
                                         headroomAtStart: nil,
                                         environment: Self.environment())
        } catch is ProvingBenchmark.Failure {
            refused = true
        } catch {
            Issue.record("expected a refusal, got \(error)")
        }

        #expect(refused)
        #expect(runner.callCount == 0)
    }

    // MARK: - Orchestration

    @Test func aPermittedRunReachesTheProverWithTheWorkingDirectory() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)

        let runner = StubRunner(result: .success(.init(proveMs: 5231, verifyMs: 13_004)))
        let report = try ProvingBenchmark.run(documentsPath: directory.path,
                                              runner: runner,
                                              pinnedAssetPaths: [],
                                              clock: StubClock([0, 20_000_000_000]),
                                              footprint: StubFootprint(peak: 2_370_000_000),
                                              headroomAtStart: 3_000_000_000,
                                              environment: Self.environment())

        #expect(runner.callCount == 1)
        #expect(runner.documentsPaths == [directory.path])
        #expect(report.measurements.proveMs == 5231)
        #expect(report.documentsPath == directory.path)
    }

    @Test func theWallClockComesFromThisModuleNotFromUpstream() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)

        let report = try ProvingBenchmark.run(
            documentsPath: directory.path,
            runner: StubRunner(result: .success(.init(proveMs: 1000, verifyMs: 2000))),
            pinnedAssetPaths: [],
            clock: StubClock([1_000_000_000, 6_000_000_000]),
            footprint: StubFootprint(peak: nil),
            headroomAtStart: nil,
            environment: Self.environment())

        #expect(report.wallClockMs == 5000)
        // 5 s of wall clock against 3 s of attributed stages: the 2 s upstream
        // never accounted for is the key I/O this benchmark exists to expose.
        #expect(report.unaccountedMs == 2000)
    }

    @Test func thePeakFootprintOnTheReportIsTheOneTheTrackerObserved() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)

        let footprint = StubFootprint(peak: 2_270_000_000)
        let report = try ProvingBenchmark.run(documentsPath: directory.path,
                                              runner: StubRunner(result: .success(.init(proveMs: 1))),
                                              pinnedAssetPaths: [],
                                              footprint: footprint,
                                              headroomAtStart: 1_500_000_000,
                                              environment: Self.environment())

        #expect(footprint.startCount == 1)
        #expect(footprint.stopCount == 1)
        #expect(report.memory.peakFootprintBytes == 2_270_000_000)
        #expect(report.memory.headroomAtStartBytes == 1_500_000_000)
    }

    /// The tracker owns a repeating timer. A run that throws past the stop
    /// leaves it sampling `phys_footprint` every 100 ms for the life of the
    /// process — and a failed proof is exactly when that happens.
    @Test func aFailedRunStillStopsTheFootprintTimer() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.touch(ProvingBenchmark.constraintSystemFilenames, in: directory)

        let footprint = StubFootprint(peak: 1)
        var thrown: Error?
        do {
            _ = try ProvingBenchmark.run(
                documentsPath: directory.path,
                runner: StubRunner(result: .failure(StubError(tag: "prover exploded"))),
                pinnedAssetPaths: [],
                footprint: footprint,
                headroomAtStart: nil,
                environment: Self.environment())
        } catch {
            thrown = error
        }

        #expect((thrown as? StubError)?.tag == "prover exploded")
        #expect(footprint.startCount == 1)
        #expect(footprint.stopCount == 1)
    }

    // MARK: - The kernel readings
    //
    // Real calls, and cheap — no proving key involved. The mach plumbing is
    // easy to get subtly wrong (a miscounted `mach_msg_type_number_t` returns
    // `KERN_INVALID_ARGUMENT` and the whole memory section silently becomes
    // "unavailable"), so it is worth one test that would notice.

    @Test func theProcessCanReadItsOwnFootprint() throws {
        let footprint = try #require(MachMemory.physFootprintBytes())
        // A running test bundle is comfortably over a megabyte; a plausible
        // figure here means the struct size and flavour were right.
        #expect(footprint > 1_000_000)
    }

    @Test func theFootprintTrackerReturnsAReadingWithoutWaitingForATick() {
        let tracker = MachPeakFootprintTracker()
        tracker.start()
        let peak = tracker.stop()
        #expect(peak != nil)
        #expect((peak ?? 0) > 1_000_000)
    }

    /// Documents the simulator's answer rather than papering over it: there is
    /// no jetsam here, so there is no headroom to report, and a run finishing
    /// proves nothing about a phone.
    @Test func headroomIsUnavailableWhereThereIsNoJetsam() {
        #if targetEnvironment(simulator)
        #expect(MachMemory.availableMemoryBytes() == nil)
        #else
        #expect((MachMemory.availableMemoryBytes() ?? 0) > 0)
        #endif
    }

    // MARK: - Fixtures

    private static func environment(isSimulator: Bool = false,
                                    hardwareModel: String = "iPhone14,5",
                                    simulatedModel: String? = nil,
                                    thermalState: ProcessInfo.ThermalState = .nominal,
                                    lowPower: Bool = false,
                                    rayonThreads: String? = nil,
                                    onMainThread: Bool = false)
        -> ProvingBenchmark.Environment {
        ProvingBenchmark.Environment(isSimulator: isSimulator,
                                     hardwareModel: hardwareModel,
                                     simulatedModel: simulatedModel,
                                     osVersion: "16.0.0",
                                     activeProcessorCount: 6,
                                     processorCount: 6,
                                     physicalMemoryBytes: 4_000_000_000,
                                     thermalState: thermalState,
                                     isLowPowerModeEnabled: lowPower,
                                     rayonThreads: rayonThreads,
                                     appVersion: "1.0",
                                     appBuild: "1",
                                     capturedOnMainThread: onMainThread)
    }

    private static func report(environment: ProvingBenchmark.Environment? = nil,
                               measurements: ProvingBenchmark.Measurements = .init(proveMs: 5231,
                                                                                   verifyMs: 13_004),
                               memory: ProvingBenchmark.MemoryObservation = .init(
                                peakFootprintBytes: 2_270_000_000,
                                headroomAtStartBytes: 3_000_000_000),
                               wallClockMs: UInt64 = 20_000) -> ProvingBenchmark.Report {
        ProvingBenchmark.Report(environment: environment ?? self.environment(),
                                measurements: measurements,
                                memory: memory,
                                wallClockMs: wallClockMs,
                                documentsPath: "/tmp/ZKCircuitAssets",
                                // Fixed, so two renders of the same run compare equal.
                                startedAt: Date(timeIntervalSince1970: 1_770_000_000))
    }

    /// The value on the `label` row, or nil if there is no such row.
    ///
    /// Rows are asserted on rather than the whole text, because substring
    /// matching on a report full of numbers is treacherous: `"20000 ms ("`
    /// contains `"0 ms ("`, so a naive "no zero durations" check passes on a
    /// report that is full of them. Matching the label to its own value also
    /// catches a figure printed under the wrong heading, which substring
    /// matching never would.
    ///
    /// The trailing-space guard is what keeps `prove` from matching the
    /// `proving key` row.
    private static func row(_ label: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("  \(label)") else { continue }
            let rest = line.dropFirst(2 + label.count)
            guard rest.first == " " else { continue }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvingBenchmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func touch(_ relativePaths: [String], in directory: URL) throws {
        for relative in relativePaths {
            let file = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("not a real key".utf8).write(to: file)
        }
    }
}

// MARK: - Stand-ins

/// Shaped like `OpenACSwift.BenchmarkResults`, which the test bundle cannot
/// build: it links the app, not the package. This is the whole reason
/// `Measurements.init` is generic.
private struct StubUpstream: OpenACBenchmarkResultsShape {
    let setupMs: UInt64
    let proveMs: UInt64
    let verifyMs: UInt64
    let provingKeyBytes: UInt64
    let verifyingKeyBytes: UInt64
    let proofBytes: UInt64
    let witnessBytes: UInt64
}

private struct StubError: Error, Equatable {
    let tag: String
}

/// Stands in for the ~950 MB of proving keys and the minutes of CPU that a real
/// run costs. Counts its calls, because "was the prover reached at all" is the
/// assertion the preflight tests turn on.
private final class StubRunner: ProvingBenchmarkRunning {
    private let result: Result<ProvingBenchmark.Measurements, Error>
    private(set) var callCount = 0
    private(set) var documentsPaths: [String] = []

    init(result: Result<ProvingBenchmark.Measurements, Error>) {
        self.result = result
    }

    func measure(documentsPath: String) throws -> ProvingBenchmark.Measurements {
        callCount += 1
        documentsPaths.append(documentsPath)
        return try result.get()
    }
}

/// Hands out prepared readings so the duration arithmetic can be checked
/// without waiting for real seconds to elapse.
private final class StubClock: ProvingBenchmarkClock {
    private var readings: [UInt64]

    init(_ readings: [UInt64]) {
        self.readings = readings
    }

    func nowNanoseconds() -> UInt64 {
        readings.isEmpty ? 0 : readings.removeFirst()
    }
}

private final class StubFootprint: ProvingBenchmarkFootprintTracking {
    private let peak: UInt64?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(peak: UInt64?) {
        self.peak = peak
    }

    func start() { startCount += 1 }

    func stop() -> UInt64? {
        stopCount += 1
        return peak
    }
}
