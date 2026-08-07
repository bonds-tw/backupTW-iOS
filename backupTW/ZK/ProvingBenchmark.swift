//
//  ProvingBenchmark.swift
//  backupTW
//

import Darwin
import Dispatch
import Foundation
import OpenACSwift
import os

// MARK: - What this is for
//
// The whitepaper's selective-disclosure story rests on one number nobody has
// measured on a phone: how long a verifier waits while a proof is checked. If
// it is three seconds, verification happens at the counter. If it is thirteen,
// it cannot, and M3 has to be designed around a pre-verified short-lived token
// instead. That is an architecture decision, not a performance tweak, so the
// measurement has to be trustworthy enough to make it on — which means it has
// to carry its own provenance, and has to refuse to be quoted when it is not
// entitled to be.
//
// Hence the report rather than a log line: a run produces one block of text
// that names the device, the thermal state and the build it came from, and
// leads with a banner when the conditions make its own numbers inadmissible.
// A benchmark whose output can be quoted without its caveats is worse than no
// benchmark, because it launders a simulator guess into a project decision.
//
// # Three things the upstream call is not
//
// `runCompleteBenchmark` is wrapped here, not trusted. Reading the upstream
// binding (Sources/mopro.swift) turns up three mismatches with what this app
// does, and every one of them is a way to be quietly wrong:
//
//   1. **It measures a path this app does not take.** Each circuit runs
//      `setup → save → drop PK → prove → verify`. The setup step *generates*
//      the proving keys locally from the `.r1cs` constraint systems. In
//      production this app downloads pre-generated keys and never calls
//      `setupKeys` at all (see `CircuitAssets.setupOnly`), so `setupMs` is the
//      cost of a step that never happens, and `provingKeyBytes` describes a key
//      this app did not use.
//
//   2. **It destroys the pinned proving keys.** "save" writes the freshly
//      generated keys into `keys/`, on top of the two files whose SHA-256 is
//      pinned in `CircuitAssets.required`. Every proof this app produces is
//      generated under whatever is in `keys/`; silently replacing that with a
//      locally derived key is the single worst side effect available in this
//      module. `preflightBlockers` refuses to start unless the caller says in
//      as many words that it may.
//
//   3. **It cannot run in this app's asset configuration at all.** Setup needs
//      `certChainRS4096.r1cs` and `userSigRS2048.r1cs` in the root of
//      `documentsPath`, and this app deliberately downloads neither — they
//      would cost 77.7 MB of transfer and 823 MB of disk for a step that is
//      skipped. Without the preflight, a run ends in an opaque FFI error after
//      the user has waited; with it, the refusal is immediate and says why.
//
// So the honest reading of this file is: it is the harness, and the wrapped
// call is the *only* measurement available today. Per-circuit numbers — which
// are what the verify decision actually needs — require timing
// `proveCertChainRs4096` / `verifyCertChainRs4096` / `linkVerify` separately.
// `Measurements` is deliberately shaped so a future per-stage harness reports
// through the same formatter.
//
// # Licensing
//
// The circuits themselves (`privacy-ethereum/zkID`) are MIT. The Swift binding
// this file calls into (`privacy-ethereum/openac-rsa-x509-swift`) has **no
// LICENSE file** — nor do `go-zkid-verifier` or `moica-revocation-smt`, checked
// again on 2026-08-07. Work proceeds on the strength of a written reply from
// PSE stating MIT. That is a promise, not a licence, and it is written here
// rather than in a commit message so the next person does not read "upstream is
// MIT" and assume the file exists.

/// Wraps the upstream benchmark and turns it into a report a person can paste.
enum ProvingBenchmark {

    // MARK: - Measurements

    /// The seven figures `runCompleteBenchmark` returns, both circuits
    /// combined.
    ///
    /// Zero is not a measurement. Upstream reports every field as a plain
    /// `UInt64` with no way to say "not measured", and a proof takes seconds,
    /// so a zero here means the figure was never filled in. The formatter says
    /// so rather than printing `0 ms`, which reads like a result.
    struct Measurements: Equatable {
        var setupMs: UInt64 = 0
        var proveMs: UInt64 = 0
        var verifyMs: UInt64 = 0
        var provingKeyBytes: UInt64 = 0
        var verifyingKeyBytes: UInt64 = 0
        var proofBytes: UInt64 = 0
        var witnessBytes: UInt64 = 0

        init(setupMs: UInt64 = 0,
             proveMs: UInt64 = 0,
             verifyMs: UInt64 = 0,
             provingKeyBytes: UInt64 = 0,
             verifyingKeyBytes: UInt64 = 0,
             proofBytes: UInt64 = 0,
             witnessBytes: UInt64 = 0) {
            self.setupMs = setupMs
            self.proveMs = proveMs
            self.verifyMs = verifyMs
            self.provingKeyBytes = provingKeyBytes
            self.verifyingKeyBytes = verifyingKeyBytes
            self.proofBytes = proofBytes
            self.witnessBytes = witnessBytes
        }

        /// Copies an upstream result across, field by field.
        ///
        /// Generic over `OpenACBenchmarkResultsShape` for one reason: seven
        /// same-typed integers in a row means `proveMs: upstream.verifyMs`
        /// compiles, produces a plausible-looking report, and inverts the exact
        /// number M3 turns on. A stand-in conforming type in the tests can be
        /// given seven distinct values and every slot checked — which is not
        /// possible against the real `BenchmarkResults`, because the test
        /// bundle does not link OpenACSwift.
        init<Upstream: OpenACBenchmarkResultsShape>(_ upstream: Upstream) {
            self.init(setupMs: upstream.setupMs,
                      proveMs: upstream.proveMs,
                      verifyMs: upstream.verifyMs,
                      provingKeyBytes: upstream.provingKeyBytes,
                      verifyingKeyBytes: upstream.verifyingKeyBytes,
                      proofBytes: upstream.proofBytes,
                      witnessBytes: upstream.witnessBytes)
        }

        /// Sum of the three timings, saturating rather than trapping.
        var reportedTotalMs: UInt64 {
            let (partial, first) = setupMs.addingReportingOverflow(proveMs)
            let (total, second) = partial.addingReportingOverflow(verifyMs)
            return (first || second) ? UInt64.max : total
        }

        /// True when upstream returned nothing usable at all — the run happened
        /// but measured none of it.
        var reportedNoTiming: Bool { reportedTotalMs == 0 }
    }

    /// What this module observed about memory while the run was in flight.
    ///
    /// Kept apart from `Measurements` because upstream reports neither: its
    /// `witnessBytes` is a file size, not a footprint, and mixing the two in
    /// one struct is how somebody ends up quoting a file size as peak memory.
    struct MemoryObservation: Equatable {
        /// Highest `phys_footprint` seen during the run — the field jetsam
        /// actually meters, not `resident_size`. `nil` when the kernel refused
        /// the query.
        ///
        /// Sampled on a timer from another queue while the prover saturates
        /// every core with rayon, so it is a floor: a spike between two samples
        /// is not seen, and a starved sampler misses more of them. It is also
        /// the *whole process*, so anything else the app is holding is counted.
        var peakFootprintBytes: UInt64?

        /// `os_proc_available_memory()` immediately before the run — how much
        /// headroom this process had before jetsam would kill it.
        ///
        /// `nil` on the simulator, where there is no jetsam and the call returns
        /// nothing meaningful. That absence is the point: a simulator run that
        /// completes says nothing about whether a phone survives it.
        var headroomAtStartBytes: UInt64?

        init(peakFootprintBytes: UInt64? = nil, headroomAtStartBytes: UInt64? = nil) {
            self.peakFootprintBytes = peakFootprintBytes
            self.headroomAtStartBytes = headroomAtStartBytes
        }
    }

    // MARK: - Environment

    /// Where the numbers came from.
    ///
    /// Recorded because the same figure means different things on different
    /// hardware, and because the two conditions that most often invalidate a
    /// run — a hot phone and Low Power Mode — leave no trace in the timings
    /// themselves.
    struct Environment: Equatable {

        /// Decided at compile time, so it cannot be wrong about itself.
        let isSimulator: Bool

        /// `utsname().machine`. On a device this is the model
        /// (`iPhone14,5`); on the simulator it is the host architecture
        /// (`arm64`), which is why `simulatedModel` exists.
        let hardwareModel: String

        /// `SIMULATOR_MODEL_IDENTIFIER` — the device being *pretended*. Nil on
        /// real hardware.
        let simulatedModel: String?

        /// Assembled from `operatingSystemVersion` rather than
        /// `operatingSystemVersionString`, which is localised and would make two
        /// reports from two phones fail to diff.
        let osVersion: String

        let activeProcessorCount: Int
        let processorCount: Int
        let physicalMemoryBytes: UInt64
        let thermalState: ProcessInfo.ThermalState
        let isLowPowerModeEnabled: Bool

        /// The prover is rayon-parallel. Pinning this is the one lever that
        /// makes a simulator run resemble a phone's core count, so a report
        /// that does not say whether it was set is not comparable with one that
        /// does.
        let rayonThreads: String?

        let appVersion: String?
        let appBuild: String?

        /// The upstream call blocks for minutes. If it ran on the main thread
        /// the UI was frozen and the timings include whatever the main thread
        /// was contending with, so the report says so.
        let capturedOnMainThread: Bool

        init(isSimulator: Bool,
             hardwareModel: String,
             simulatedModel: String?,
             osVersion: String,
             activeProcessorCount: Int,
             processorCount: Int,
             physicalMemoryBytes: UInt64,
             thermalState: ProcessInfo.ThermalState,
             isLowPowerModeEnabled: Bool,
             rayonThreads: String?,
             appVersion: String?,
             appBuild: String?,
             capturedOnMainThread: Bool) {
            self.isSimulator = isSimulator
            self.hardwareModel = hardwareModel
            self.simulatedModel = simulatedModel
            self.osVersion = osVersion
            self.activeProcessorCount = activeProcessorCount
            self.processorCount = processorCount
            self.physicalMemoryBytes = physicalMemoryBytes
            self.thermalState = thermalState
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.rayonThreads = rayonThreads
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.capturedOnMainThread = capturedOnMainThread
        }

        static func current(processInfo: ProcessInfo = .processInfo,
                            environmentVariables: [String: String]? = nil,
                            bundle: Bundle = .main,
                            onMainThread: Bool = Thread.isMainThread) -> Environment {
            #if targetEnvironment(simulator)
            let simulator = true
            #else
            let simulator = false
            #endif

            let variables = environmentVariables ?? processInfo.environment
            let version = processInfo.operatingSystemVersion
            let info = bundle.infoDictionary

            return Environment(
                isSimulator: simulator,
                hardwareModel: hardwareModelIdentifier(),
                simulatedModel: variables["SIMULATOR_MODEL_IDENTIFIER"],
                osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                activeProcessorCount: processInfo.activeProcessorCount,
                processorCount: processInfo.processorCount,
                physicalMemoryBytes: processInfo.physicalMemory,
                thermalState: processInfo.thermalState,
                isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                rayonThreads: variables["RAYON_NUM_THREADS"],
                appVersion: info?["CFBundleShortVersionString"] as? String,
                appBuild: info?["CFBundleVersion"] as? String,
                capturedOnMainThread: onMainThread)
        }

        /// What to call the machine in the report.
        var deviceDescription: String {
            if isSimulator {
                let model = simulatedModel ?? "unknown model"
                return "simulator: \(model) (host \(hardwareModel))"
            }
            return hardwareModel
        }

        static func hardwareModelIdentifier() -> String {
            var system = utsname()
            uname(&system)
            return withUnsafePointer(to: &system.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                    String(cString: $0)
                }
            }
        }
    }

    // MARK: - Refusals

    /// A reason the run must not start.
    ///
    /// Collected rather than thrown one at a time: the common state is *both*
    /// (the assets are downloaded, so the pinned keys are there to be
    /// clobbered, and the `.r1cs` files were never fetched), and reporting one
    /// of the two sends the reader off to fix the wrong thing.
    enum Blocker: Equatable {

        /// `setupKeys` — which `runCompleteBenchmark` calls — reads this file
        /// from the root of `documentsPath` and it is not there.
        case missingConstraintSystem(path: String)

        /// Running would overwrite this digest-pinned file with a locally
        /// generated one.
        case wouldOverwritePinnedKey(path: String)

        var explanation: String {
            switch self {
            case .missingConstraintSystem(let path):
                return "missing constraint system: \(path) — runCompleteBenchmark runs setupKeys, "
                    + "which reads the .r1cs files from the root of documentsPath. This app does not "
                    + "download them (CircuitAssets.setupOnly); fetch them by hand to benchmark."
            case .wouldOverwritePinnedKey(let path):
                return "would overwrite a pinned proving key: \(path) — setup saves locally generated "
                    + "keys over the downloaded ones, and every proof this app makes is generated "
                    + "under whatever is in keys/. Pass allowOverwritingPinnedKeys: true, and expect "
                    + "to re-download afterwards."
            }
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case refused([Blocker])

        var description: String {
            switch self {
            case .refused(let blockers):
                return (["benchmark refused to start:"]
                        + blockers.map { "  - \($0.explanation)" })
                    .joined(separator: "\n")
            }
        }
    }

    /// The files `setupKeys` reads, relative to the root of `documentsPath`.
    ///
    /// Root, not `keys/`: upstream's README, its doc comment and its own tests
    /// all agree. `CircuitAssets.setupOnly` currently spells these with a
    /// `keys/` prefix, which would put them where setup cannot find them — that
    /// list is unused so nothing breaks today, and the test alongside this ties
    /// the two together by basename so the two spellings cannot drift further
    /// apart while nobody is looking.
    static let constraintSystemFilenames = ["certChainRS4096.r1cs", "userSigRS2048.r1cs"]

    /// Installed paths, relative to the working directory, of every asset whose
    /// bytes are pinned by digest. Derived rather than repeated, so adding a
    /// pinned asset protects it here automatically.
    static var pinnedAssetPaths: [String] {
        CircuitAssets.required.filter { $0.sha256 != nil }.map { $0.localFilename }
    }

    /// Everything that would make this run either impossible or destructive.
    ///
    /// Order is fixed — constraint systems then pinned keys, each in the order
    /// given — so the message is the same on two runs of the same broken state.
    static func preflightBlockers(documentsPath: String,
                                  allowOverwritingPinnedKeys: Bool,
                                  constraintSystemFilenames: [String] = constraintSystemFilenames,
                                  pinnedAssetPaths: [String] = pinnedAssetPaths,
                                  fileManager: FileManager = .default) -> [Blocker] {
        let root = URL(fileURLWithPath: documentsPath, isDirectory: true)

        var blockers: [Blocker] = constraintSystemFilenames.compactMap { filename in
            let path = root.appendingPathComponent(filename).path
            return fileManager.fileExists(atPath: path) ? nil : .missingConstraintSystem(path: path)
        }

        if !allowOverwritingPinnedKeys {
            blockers += pinnedAssetPaths.compactMap { relative in
                let path = root.appendingPathComponent(relative).path
                return fileManager.fileExists(atPath: path) ? .wouldOverwritePinnedKey(path: path) : nil
            }
        }
        return blockers
    }

    // MARK: - Running

    /// Runs the upstream benchmark and reports it.
    ///
    /// Blocking, for minutes, and it should not be called on the main thread —
    /// the report records which thread it was on rather than asserting, because
    /// a diagnostic that crashes the app it is diagnosing helps nobody.
    ///
    /// Every collaborator is injectable for one reason: the real run downloads
    /// nothing but needs ~950 MB of proving keys already on disk, so no test may
    /// ever take this path. What the tests exercise is the orchestration — the
    /// refusals, the memory bookkeeping, the arithmetic and the wording — with a
    /// stand-in in place of the prover.
    static func run(documentsPath: String,
                    runner: ProvingBenchmarkRunning = OpenACBenchmarkRunner(),
                    allowOverwritingPinnedKeys: Bool = false,
                    constraintSystemFilenames: [String] = constraintSystemFilenames,
                    pinnedAssetPaths: [String] = pinnedAssetPaths,
                    fileManager: FileManager = .default,
                    clock: ProvingBenchmarkClock = UptimeClock(),
                    footprint: ProvingBenchmarkFootprintTracking = MachPeakFootprintTracker(),
                    headroomAtStart: UInt64? = MachMemory.availableMemoryBytes(),
                    environment: Environment? = nil,
                    startedAt: Date = Date()) throws -> Report {

        let blockers = preflightBlockers(documentsPath: documentsPath,
                                         allowOverwritingPinnedKeys: allowOverwritingPinnedKeys,
                                         constraintSystemFilenames: constraintSystemFilenames,
                                         pinnedAssetPaths: pinnedAssetPaths,
                                         fileManager: fileManager)
        // Thrown *before* the runner is touched. The whole value of the
        // preflight is that the user does not wait for the failure.
        guard blockers.isEmpty else { throw Failure.refused(blockers) }

        let capturedEnvironment = environment ?? Environment.current()

        footprint.start()
        let began = clock.nowNanoseconds()
        let measurements: Measurements
        do {
            measurements = try runner.measure(documentsPath: documentsPath)
        } catch {
            // The tracker owns a repeating timer. Letting an error skip the
            // stop leaves it sampling for the life of the process.
            _ = footprint.stop()
            throw error
        }
        let ended = clock.nowNanoseconds()
        let peak = footprint.stop()

        return Report(environment: capturedEnvironment,
                      measurements: measurements,
                      memory: MemoryObservation(peakFootprintBytes: peak,
                                                headroomAtStartBytes: headroomAtStart),
                      wallClockMs: milliseconds(fromNanoseconds: began, to: ended),
                      documentsPath: documentsPath,
                      startedAt: startedAt)
    }

    /// Truncating, and clamped at zero: a monotonic clock should never run
    /// backwards, but an injected one can, and a `UInt64` subtraction that goes
    /// negative traps.
    static func milliseconds(fromNanoseconds began: UInt64, to ended: UInt64) -> UInt64 {
        guard ended > began else { return 0 }
        return (ended - began) / 1_000_000
    }
}

// MARK: - The upstream result, described

/// The shape of `OpenACSwift.BenchmarkResults`.
///
/// Two jobs. It lets `Measurements.init` be tested against a stand-in, because
/// the test bundle does not link OpenACSwift and so cannot build the real
/// struct. And the forwarding wrapper below stops compiling the day upstream
/// renames or retypes a field — which for seven interchangeable `UInt64`s is
/// the only warning we would ever get.
protocol OpenACBenchmarkResultsShape {
    var setupMs: UInt64 { get }
    var proveMs: UInt64 { get }
    var verifyMs: UInt64 { get }
    var provingKeyBytes: UInt64 { get }
    var verifyingKeyBytes: UInt64 { get }
    var proofBytes: UInt64 { get }
    var witnessBytes: UInt64 { get }
}

// MARK: - Seams

/// The blocking call to the prover, behind a protocol.
///
/// This is the line CI must not cross. A real run needs the proving keys —
/// ~85 MB of download, ~950 MB on disk — and on a machine that has them it
/// takes minutes and gigabytes of RAM. Everything on this side of the protocol
/// is orchestration and can be tested; everything on the other side is a
/// manual, on-device exercise.
protocol ProvingBenchmarkRunning {
    /// Named `measure` rather than `runCompleteBenchmark` so the implementation
    /// below cannot accidentally call itself instead of the free function it
    /// wraps.
    func measure(documentsPath: String) throws -> ProvingBenchmark.Measurements
}

/// The real thing.
struct OpenACBenchmarkRunner: ProvingBenchmarkRunning {

    /// Forwards `BenchmarkResults` through `OpenACBenchmarkResultsShape`.
    ///
    /// `private` on purpose: it keeps every mention of an OpenACSwift type out
    /// of this module's internal interface, so the test bundle — which links
    /// the app but not the package — has nothing to resolve.
    private struct Forwarded: OpenACBenchmarkResultsShape {
        let raw: BenchmarkResults
        var setupMs: UInt64 { raw.setupMs }
        var proveMs: UInt64 { raw.proveMs }
        var verifyMs: UInt64 { raw.verifyMs }
        var provingKeyBytes: UInt64 { raw.provingKeyBytes }
        var verifyingKeyBytes: UInt64 { raw.verifyingKeyBytes }
        var proofBytes: UInt64 { raw.proofBytes }
        var witnessBytes: UInt64 { raw.witnessBytes }
    }

    func measure(documentsPath: String) throws -> ProvingBenchmark.Measurements {
        let raw = try OpenACSwift.runCompleteBenchmark(documentsPath: documentsPath)
        return ProvingBenchmark.Measurements(Forwarded(raw: raw))
    }
}

/// A monotonic clock, injectable so the arithmetic can be tested without
/// waiting for real time to pass.
protocol ProvingBenchmarkClock {
    func nowNanoseconds() -> UInt64
}

/// `DispatchTime`, not `Date`: the run takes minutes and a wall clock that the
/// user or NTP adjusts mid-run would produce a negative duration.
struct UptimeClock: ProvingBenchmarkClock {
    func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

protocol ProvingBenchmarkFootprintTracking {
    func start()
    /// The highest footprint seen since `start()`, or `nil` if none was read.
    /// Must be safe to call after a failed run.
    func stop() -> UInt64?
}

/// Polls `phys_footprint` on a timer for the length of the run.
///
/// Polling because the measured work is one blocking FFI call: there is no
/// callback to hang a reading off, and the interesting moment (the proving key
/// coming off disk into the heap) is in the middle of it. The consequence is
/// that the answer is a floor and not a peak — see `MemoryObservation`.
final class MachPeakFootprintTracker: ProvingBenchmarkFootprintTracking {

    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "tw.bonds.backupTW.benchmark.footprint",
                                      qos: .userInitiated)
    private let lock = NSLock()
    private var peak: UInt64?
    private var timer: DispatchSourceTimer?

    /// 100 ms is a compromise. Faster steals cycles from the thing being
    /// measured; slower and a 700 MB key load can land entirely between two
    /// samples.
    init(interval: DispatchTimeInterval = .milliseconds(100)) {
        self.interval = interval
    }

    deinit { timer?.cancel() }

    func start() {
        // Cancelled before the new source is built, not after: a second `start`
        // without a `stop` would otherwise leave the first timer sampling into
        // the same `peak` for the life of the process.
        timer?.cancel()
        lock.lock()
        peak = nil
        lock.unlock()
        // One reading on this thread, so `stop()` has an answer even if the
        // queue never gets scheduled.
        sample()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    func stop() -> UInt64? {
        timer?.cancel()
        timer = nil
        // One last reading on this thread: the run has just finished and the
        // queue may not get scheduled again before the answer is read.
        sample()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    private func sample() {
        guard let reading = MachMemory.physFootprintBytes() else { return }
        lock.lock()
        peak = max(peak ?? 0, reading)
        lock.unlock()
    }
}

// MARK: - Kernel readings

enum MachMemory {

    /// `phys_footprint` for this process.
    ///
    /// This field and not `resident_size`, because this is the one jetsam
    /// meters — an app killed for memory is killed on its footprint, so a
    /// benchmark that reports resident size is reporting the wrong number
    /// against the wrong limit.
    static func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// How much this process may still allocate before jetsam kills it.
    ///
    /// Zero is mapped to `nil` because zero is what the simulator returns —
    /// there is no jetsam there, so there is no limit to have headroom against.
    /// Reporting that as "0 bytes free" would be a false alarm, and reporting
    /// the simulator's real 16 GB would be a far more expensive lie: the
    /// upstream figure for peak proving memory is 1.96–2.27 GiB, which is at or
    /// over the limit for every 4 GB iPhone this app still claims to support.
    static func availableMemoryBytes() -> UInt64? {
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
    }
}

// MARK: - Report

extension ProvingBenchmark {

    /// One run, and everything needed to judge whether it counts.
    struct Report: Equatable {
        let environment: Environment
        let measurements: Measurements
        let memory: MemoryObservation

        /// Measured around the call by this module, not by upstream. The gap
        /// between this and `measurements.reportedTotalMs` is time upstream did
        /// not attribute to any stage — mostly key I/O — and on this workload
        /// that gap is not small.
        let wallClockMs: UInt64

        let documentsPath: String
        let startedAt: Date

        init(environment: ProvingBenchmark.Environment,
             measurements: ProvingBenchmark.Measurements,
             memory: ProvingBenchmark.MemoryObservation,
             wallClockMs: UInt64,
             documentsPath: String,
             startedAt: Date) {
            self.environment = environment
            self.measurements = measurements
            self.memory = memory
            self.wallClockMs = wallClockMs
            self.documentsPath = documentsPath
            self.startedAt = startedAt
        }

        /// Time the run took that upstream attributed to no stage.
        var unaccountedMs: UInt64 {
            let reported = measurements.reportedTotalMs
            return wallClockMs > reported ? wallClockMs - reported : 0
        }

        /// True when the figures add up to more than the run took — which they
        /// cannot, so something is wrong with the clock or with upstream.
        var reportedExceedsWallClock: Bool {
            measurements.reportedTotalMs > wallClockMs
        }

        // MARK: Text

        /// The whole point of the module: one block of text, stable enough to
        /// diff between two devices, that carries its own caveats.
        ///
        /// Deliberately not localised, and deliberately not built with
        /// `ByteCountFormatter` or `NumberFormatter`. This is a record that gets
        /// pasted into an issue and compared against another device's; a report
        /// whose separators and unit names change with the reader's locale
        /// cannot be diffed, and translating it would put the numbers further
        /// from the people who have to act on them, not closer.
        var text: String {
            var sections: [String] = []

            let banners = self.banners
            if !banners.isEmpty {
                sections.append(banners.joined(separator: "\n\n"))
            }

            sections.append(header)
            sections.append(environmentSection)
            sections.append(timingSection)
            sections.append(sizeSection)
            sections.append(memorySection)
            sections.append(caveatSection)

            return sections.joined(separator: "\n\n")
        }

        /// Everything that makes this run inadmissible, first, so that no one
        /// can quote a number without having scrolled past the reason not to.
        private var banners: [String] {
            var banners: [String] = []

            if environment.isSimulator {
                banners.append("""
                !! SIMULATOR RUN — NOT A BASIS FOR AN ON-DEVICE DECISION
                   The prover is rayon-parallel and memory-bandwidth bound. The host Mac has
                   more performance cores and roughly twice the bandwidth of the phones this
                   app targets, and it does not thermally throttle. Treat every duration here
                   as an optimistic lower bound.
                   The memory figures are worse than optimistic: the simulator has no jetsam,
                   so a run that finished here proves nothing about a run on a phone.
                   Useful for catching regressions against another run on this same machine.
                   Not useful for deciding whether verification can happen at the counter.
                """)
            }

            if measurements.reportedNoTiming {
                banners.append("""
                !! NO TIMING REPORTED — this run measured nothing
                   Every duration came back zero. The run completed, so this is a reporting
                   failure rather than a proving failure; the sizes below may still be real.
                """)
            }

            if reportedExceedsWallClock {
                banners.append("""
                !! IMPOSSIBLE TIMING — the stages add up to more than the run took
                   \(measurements.reportedTotalMs) ms of stages inside \(wallClockMs) ms of wall clock.
                   Either the clock moved or the stage figures are not from this run.
                """)
            }

            if environment.thermalState != .nominal {
                banners.append("""
                !! THERMAL STATE \(Self.describe(environment.thermalState).uppercased()) — the device was already throttling
                   A run that starts hot measures the throttle, not the prover.
                """)
            }

            if environment.isLowPowerModeEnabled {
                banners.append("""
                !! LOW POWER MODE WAS ON — the CPU was capped for the whole run
                """)
            }

            if environment.capturedOnMainThread {
                banners.append("""
                !! RAN ON THE MAIN THREAD — the UI was frozen for the duration
                   Fix that before quoting these numbers; the timings include main-thread
                   contention that a background run would not have.
                """)
            }

            return banners
        }

        private var header: String {
            """
            ZK PROVING BENCHMARK
            started    \(Self.timestamp.string(from: startedAt))
            source     OpenACSwift.runCompleteBenchmark(documentsPath:)
            path       \(documentsPath)
            """
        }

        private var environmentSection: String {
            var rows = [
                Self.row("device", environment.deviceDescription),
                Self.row("os", "iOS \(environment.osVersion)"),
                Self.row("cores", "\(environment.activeProcessorCount) active"
                         + " / \(environment.processorCount) total"),
                Self.row("physical memory", Self.bytes(environment.physicalMemoryBytes)),
                Self.row("thermal state", Self.describe(environment.thermalState)),
                Self.row("low power mode", environment.isLowPowerModeEnabled ? "on" : "off"),
                Self.row("RAYON_NUM_THREADS", environment.rayonThreads ?? "unset"),
                Self.row("thread", environment.capturedOnMainThread ? "main" : "background")
            ]
            let build = [environment.appVersion, environment.appBuild.map { "(\($0))" }]
                .compactMap { $0 }
                .joined(separator: " ")
            rows.append(Self.row("app", build.isEmpty ? "unknown" : build))
            return (["ENVIRONMENT"] + rows).joined(separator: "\n")
        }

        private var timingSection: String {
            var rows = [
                Self.row("setup", Self.duration(measurements.setupMs)),
                Self.row("prove", Self.duration(measurements.proveMs)),
                Self.row("verify", Self.duration(measurements.verifyMs)),
                Self.row("wall clock", Self.duration(wallClockMs))
            ]
            if wallClockMs > 0, !reportedExceedsWallClock {
                let share = Double(unaccountedMs) / Double(wallClockMs) * 100
                rows.append(Self.row("unaccounted",
                                     "\(Self.duration(unaccountedMs)) "
                                     + "(\(String(format: "%.1f", share))% of wall clock)"))
            }
            return (["TIMING (both circuits combined, as reported by upstream)"] + rows)
                .joined(separator: "\n")
        }

        private var sizeSection: String {
            let rows = [
                Self.row("proving key", Self.size(measurements.provingKeyBytes)),
                Self.row("verifying key", Self.size(measurements.verifyingKeyBytes)),
                Self.row("proof", Self.size(measurements.proofBytes)),
                Self.row("witness file", Self.size(measurements.witnessBytes))
            ]
            return (["SIZES"] + rows).joined(separator: "\n")
        }

        private var memorySection: String {
            let peak = memory.peakFootprintBytes.map(Self.bytes) ?? "unavailable"
            let headroom = memory.headroomAtStartBytes.map(Self.bytes)
                ?? (environment.isSimulator
                    ? "unavailable (no jetsam on the simulator)"
                    : "unavailable")
            return ["MEMORY (phys_footprint, whole process)",
                    Self.row("peak during run", peak),
                    Self.row("headroom at start", headroom)].joined(separator: "\n")
        }

        private var caveatSection: String {
            var caveats = [
                ["runCompleteBenchmark runs setup -> save -> prove -> verify per circuit.",
                 "Setup generates the proving keys locally; this app downloads them and",
                 "never calls setup, so `setup` above measures a step production does not take."],
                ["The run just overwrote keys/ with locally generated proving keys. The",
                 "digest-pinned downloads in CircuitAssets.required are gone until they are",
                 "fetched again."],
                ["Timings are both circuits combined. The verify figure M3 needs — one circuit,",
                 "on the verifier's own device — is not in here. That needs",
                 "verifyCertChainRs4096 / verifyUserSigRs2048 / linkVerify timed separately."],
                ["`witness file` is a file size on disk, not memory. Peak memory is the MEMORY",
                 "section above, and it is a sampled floor rather than a true peak."],
                ["linkVerify runs on the device, which is what makes offline checking possible",
                 "at all. It does not make nullifiers unique: de-duplicating them needs a shared",
                 "record and nothing offline has one. Nothing measured here supports a claim",
                 "that a holder is a real person *and* counted only once."]
            ]
            if environment.isSimulator {
                caveats.append(["Simulator. See the banner. Comparable only against other runs",
                                "on this same machine."])
            }
            return (["CAVEATS"] + caveats.map(Self.caveat)).joined(separator: "\n")
        }

        /// Hanging indent, wrapped by hand. The report is pasted into issues and
        /// chat windows that do not reflow, so the line breaks have to be in the
        /// text rather than left to whatever renders it.
        private static func caveat(_ lines: [String]) -> String {
            guard let first = lines.first else { return "" }
            return (["  - " + first] + lines.dropFirst().map { "    " + $0 })
                .joined(separator: "\n")
        }

        // MARK: Formatting

        private static let timestamp: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter
        }()

        private static func row(_ label: String, _ value: String) -> String {
            let width = max(label.count, 20)
            return "  " + label.padding(toLength: width, withPad: " ", startingAt: 0) + value
        }

        /// Zero is rendered as an absence, not as a result. A proof stage that
        /// genuinely took under a millisecond does not exist, so `0 ms` in this
        /// report can only ever mean upstream did not fill the field in — and
        /// printing it as a duration invites someone to read "instant".
        static func duration(_ milliseconds: UInt64) -> String {
            guard milliseconds > 0 else { return "not reported (upstream returned 0)" }
            guard milliseconds >= 1000 else { return "\(milliseconds) ms" }
            return "\(milliseconds) ms (\(String(format: "%.2f", Double(milliseconds) / 1000)) s)"
        }

        /// Same rule as `duration`: a zero-byte proving key is not a small
        /// proving key.
        static func size(_ byteCount: UInt64) -> String {
            guard byteCount > 0 else { return "not reported (upstream returned 0)" }
            return bytes(byteCount)
        }

        /// Powers of 1000, and always with the raw count alongside, so two
        /// reports can be diffed on an exact number rather than on a rounding.
        static func bytes(_ byteCount: UInt64) -> String {
            let units = ["kB", "MB", "GB", "TB"]
            guard byteCount >= 1000 else { return "\(byteCount) bytes" }
            var value = Double(byteCount)
            var unit = units[0]
            for candidate in units {
                unit = candidate
                value /= 1000
                if value < 1000 { break }
            }
            return "\(String(format: "%.2f", value)) \(unit) (\(byteCount) bytes)"
        }

        static func describe(_ state: ProcessInfo.ThermalState) -> String {
            switch state {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }
    }
}
