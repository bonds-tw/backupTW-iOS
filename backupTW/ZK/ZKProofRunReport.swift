//
//  ZKProofRunReport.swift
//  backupTW
//
//  The pasteable record of one real proof: per-circuit timings, what the local
//  verifier said, and every reason not to quote the numbers.
//

import Foundation

/// One end-to-end run, rendered as text a person can paste into an issue.
///
/// # Why this is not `ProvingBenchmark.Report`
///
/// It reuses that module's `Environment`, `MemoryObservation`, footprint tracker
/// and every formatting helper — so two reports from two devices still diff — but
/// it cannot reuse `Report` itself, and the reason is that `Report.text` makes
/// two statements that would be false here. It prints
/// `source  OpenACSwift.runCompleteBenchmark(documentsPath:)`, and it carries a
/// standing caveat saying the run "just overwrote keys/ with locally generated
/// proving keys". Neither is true of this path: `runCompleteBenchmark` is
/// unreachable in this app (`ProvingBenchmark.preflightBlockers` refuses it — it
/// needs the 823 MB of `.r1cs` we do not download, and it would clobber the
/// digest-pinned keys we do), so the numbers here come from `prove*` and
/// `verify*` timed individually.
///
/// That is also the shape `ProvingBenchmark`'s own note asks for: per-stage
/// figures, because the number M3 turns on is *verify*, on the verifier's device,
/// and `runCompleteBenchmark` reports both circuits fused into one integer.
struct ZKProofRunReport: Equatable, Sendable {

    let environment: ProvingBenchmark.Environment
    let bundle: ZKProofBundle

    /// Three-valued on purpose. "Nothing checked it", "something checked it and
    /// could not finish" and "something checked it and said no" are three
    /// different sentences, and only the last one is about the proof.
    let verification: ZKVerificationResult

    let memory: ProvingBenchmark.MemoryObservation

    /// Measured around `ZKProver.prove` by this app. The gap between it and the
    /// two `proveMs` figures upstream returns is key I/O — 950 MB of it — and on
    /// this workload it is not a rounding error.
    let proveWallClockMs: UInt64

    /// Around prove *and* verify.
    let totalWallClockMs: UInt64

    let documentsPath: String
    let startedAt: Date

    /// Prove time upstream attributed to no stage: key loading, witness
    /// generation bookkeeping, FFI marshalling.
    var unaccountedProveMs: UInt64 {
        let reported = bundle.totalProveMilliseconds
        return proveWallClockMs > reported ? proveWallClockMs - reported : 0
    }

    /// The stage figures cannot exceed the wall clock they were measured inside.
    /// When they do, the report says so instead of printing a negative gap.
    var reportedExceedsWallClock: Bool {
        bundle.totalProveMilliseconds > proveWallClockMs
    }

    // MARK: - Text

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
        sections.append(verificationSection)
        sections.append(notEstablishedSection)
        sections.append(caveatSection)
        return sections.joined(separator: "\n\n")
    }

    /// The caveats that are true of every proof and are not on this bundle.
    ///
    /// Should always be empty: `ZKProver.caveats(for:)` builds from
    /// `ProofCaveat.unconditional`. It is computed anyway because
    /// `ZKProofBundle.caveats` is a plain stored array that any caller can
    /// construct, and the failure mode it guards is silent — a report that omits
    /// a limitation reads exactly like a report of a proof that does not have
    /// it.
    var omittedUnconditionalCaveats: [ProofCaveat] {
        ProofCaveat.unconditional.filter { !bundle.caveats.contains($0) }
    }

    /// Everything that makes a number here inadmissible, before any number.
    private var banners: [String] {
        var banners: [String] = []

        // First, above even the simulator banner: everything below it describes a
        // proof, and this says the description of that proof is incomplete.
        if !omittedUnconditionalCaveats.isEmpty {
            banners.append("""
            !! CAVEAT LIST INCOMPLETE — this bundle is missing limitations that hold for
               every proof this app can produce:
            \(omittedUnconditionalCaveats.map { "   - \($0.rawValue)" }.joined(separator: "\n"))
               ZKProver.caveats(for:) attaches all of them, so this bundle was not built by
               it. Do not quote this report as a statement of what the proof establishes.
            """)
        }

        if environment.isSimulator {
            banners.append("""
            !! SIMULATOR RUN — NOT A BASIS FOR AN ON-DEVICE DECISION
               The prover is rayon-parallel and memory-bandwidth bound. The host Mac has
               more performance cores and roughly twice the bandwidth of the phones this
               app targets, and it does not thermally throttle. Treat every duration here
               as an optimistic lower bound.
               The memory figures are worse than optimistic: the simulator has no jetsam,
               so a run that finished here proves nothing about a run on a phone.
            """)
        }

        switch verification {
        case .notAttempted(let reason):
            banners.append("""
            !! NOT VERIFIED ON THIS DEVICE — nothing checked this proof
               \(reason)
               Proof generation succeeding says only that the inputs satisfied the circuit
               locally; it is not evidence that any verifier would accept the result.
            """)
        case .errored(let message):
            banners.append("""
            !! VERIFICATION DID NOT COMPLETE — the check itself failed
               \(message)
               This is a statement about this device, not about the proof. Nothing below
               may be read as the proof having been accepted or rejected.
            """)
        case .completed(let outcome) where !outcome.isFullyValid:
            banners.append("""
            !! VERIFICATION FAILED — this device checked the proof and rejected it
               cert_chain_rs4096 \(outcome.certificateChainValid ? "pass" : "FAIL")
               user_sig_rs2048   \(outcome.userSignatureValid ? "pass" : "FAIL")
               linkVerify        \(outcome.linked ? "pass" : "FAIL")
            """)
        case .completed:
            break
        }

        if bundle.totalProveMilliseconds == 0 {
            banners.append("""
            !! NO PROVE TIMING REPORTED — both circuits returned 0 ms
               The proofs exist, so this is a reporting failure rather than a proving
               failure. The wall clock below is still this app's own measurement.
            """)
        }

        if reportedExceedsWallClock {
            banners.append("""
            !! IMPOSSIBLE TIMING — the circuits add up to more than the run took
               \(bundle.totalProveMilliseconds) ms of proving inside \(proveWallClockMs) ms of wall clock.
               Either the clock moved or the stage figures are not from this run.
            """)
        }

        if environment.thermalState != .nominal {
            banners.append("""
            !! THERMAL STATE \(ProvingBenchmark.Report.describe(environment.thermalState).uppercased()) — the device was already throttling
               A run that starts hot measures the throttle, not the prover.
            """)
        }

        if environment.isLowPowerModeEnabled {
            banners.append("!! LOW POWER MODE WAS ON — the CPU was capped for the whole run")
        }

        if environment.capturedOnMainThread {
            banners.append("""
            !! RAN ON THE MAIN THREAD — the UI was frozen for the duration
               Fix that before quoting these numbers.
            """)
        }

        return banners
    }

    private var header: String {
        """
        ZK PROOF RUN (per-stage)
        started    \(Self.timestamp.string(from: startedAt))
        source     ZKProver.prove(_:) then OpenACSwift verify* / linkVerify, timed separately.
                   Not runCompleteBenchmark: that path runs setupKeys, which needs the .r1cs
                   files this app does not download and would overwrite the digest-pinned
                   proving keys in keys/. See ProvingBenchmark.preflightBlockers.
        path       \(documentsPath)
        """
    }

    private var environmentSection: String {
        var rows = [
            Self.row("device", environment.deviceDescription),
            Self.row("os", "iOS \(environment.osVersion)"),
            Self.row("cores", "\(environment.activeProcessorCount) active"
                     + " / \(environment.processorCount) total"),
            Self.row("physical memory", ProvingBenchmark.Report.bytes(environment.physicalMemoryBytes)),
            Self.row("thermal state", ProvingBenchmark.Report.describe(environment.thermalState)),
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
            Self.row("prove cert_chain_rs4096",
                     ProvingBenchmark.Report.duration(bundle.certificateChain.proveMilliseconds)),
            Self.row("prove user_sig_rs2048",
                     ProvingBenchmark.Report.duration(bundle.userSignature.proveMilliseconds)),
            Self.row("prove reported total",
                     ProvingBenchmark.Report.duration(bundle.totalProveMilliseconds)),
            Self.row("prove wall clock", ProvingBenchmark.Report.duration(proveWallClockMs))
        ]
        if proveWallClockMs > 0, !reportedExceedsWallClock {
            let share = Double(unaccountedProveMs) / Double(proveWallClockMs) * 100
            rows.append(Self.row("prove unaccounted",
                                 "\(ProvingBenchmark.Report.duration(unaccountedProveMs)) "
                                 + "(\(String(format: "%.1f", share))% of prove wall clock)"))
        }
        switch verification {
        case .completed(let outcome):
            rows += [
                Self.row("verify cert_chain_rs4096",
                         ProvingBenchmark.Report.duration(outcome.certificateChainMilliseconds)),
                Self.row("verify user_sig_rs2048",
                         ProvingBenchmark.Report.duration(outcome.userSignatureMilliseconds)),
                Self.row("linkVerify",
                         ProvingBenchmark.Report.duration(outcome.linkMilliseconds)),
                Self.row("verify total",
                         ProvingBenchmark.Report.duration(outcome.totalMilliseconds))
            ]
        case .notAttempted:
            rows.append(Self.row("verify", "not attempted"))
        case .errored:
            rows.append(Self.row("verify", "did not complete"))
        }
        rows.append(Self.row("wall clock (whole run)",
                             ProvingBenchmark.Report.duration(totalWallClockMs)))
        return (["TIMING (measured per stage on this device)"] + rows).joined(separator: "\n")
    }

    private var sizeSection: String {
        let rows = [
            Self.row("proof cert_chain_rs4096",
                     ProvingBenchmark.Report.size(bundle.certificateChain.proofByteCount)),
            Self.row("proof user_sig_rs2048",
                     ProvingBenchmark.Report.size(bundle.userSignature.proofByteCount)),
            Self.row("proof total", ProvingBenchmark.Report.size(bundle.totalProofByteCount))
        ]
        return (["SIZES"] + rows).joined(separator: "\n")
    }

    private var memorySection: String {
        let peak = memory.peakFootprintBytes.map(ProvingBenchmark.Report.bytes) ?? "unavailable"
        let headroom = memory.headroomAtStartBytes.map(ProvingBenchmark.Report.bytes)
            ?? (environment.isSimulator
                ? "unavailable (no jetsam on the simulator)"
                : "unavailable")
        return ["MEMORY (phys_footprint, whole process, prove + verify only)",
                Self.row("peak during run", peak),
                Self.row("headroom at start", headroom)].joined(separator: "\n")
    }

    private var verificationSection: String {
        switch verification {
        case .notAttempted:
            return ["VERIFICATION",
                    Self.row("result", "not attempted — see the banner above")]
                .joined(separator: "\n")
        case .errored(let message):
            return ["VERIFICATION",
                    Self.row("result", "did not complete — see the banner above"),
                    Self.row("reason", message)]
                .joined(separator: "\n")
        case .completed(let outcome):
            return ["VERIFICATION (this device, no server)",
                    Self.row("cert_chain_rs4096", outcome.certificateChainValid ? "pass" : "FAIL"),
                    Self.row("user_sig_rs2048", outcome.userSignatureValid ? "pass" : "FAIL"),
                    Self.row("linkVerify", outcome.linked ? "pass" : "FAIL")]
                .joined(separator: "\n")
        }
    }

    /// The bundle's own caveats, rendered from `ProofCaveat` rather than
    /// restated, so a caveat added there appears here without anyone
    /// remembering to.
    private var notEstablishedSection: String {
        (["WHAT THIS PROOF DOES NOT ESTABLISH"]
         + bundle.caveats.map { "  - [\($0.rawValue)] \($0.localizedDescription)" })
            .joined(separator: "\n")
    }

    /// The prose half. Where `notEstablishedSection` renders the caveats a
    /// verifier is shown, this states the mechanism behind them for whoever is
    /// reading the report in an issue tracker — the sentence on screen has to be
    /// readable by a cardholder, and "signs a fixed app_id rather than the
    /// challenge" is not that sentence.
    private var caveatSection: String {
        var caveats = [
            ["The proof's signing material is a static bearer token. TW FidO's SIGN flow signs",
             "sign_data = base64(app_id) — a constant — not the challenge, so (cert,",
             "signed_response) never changes and never expires. Anyone holding that pair can",
             "mint a valid proof for any new challenge, on any device, with no cardholder",
             "present and no round trip to 內政部. The issuer is in that set: ATH-02 returns",
             "both fields. The RSA signature is a circuit witness, so replaying it never",
             "requires disclosing it, and nothing in a proof distinguishes a replay.",
             "See ProofCaveat.signatureMaterialIsReplayable."],
            ["Every proof discloses the cardholder to the issuer. The SIGN request body carries",
             "id_num (raw, not hashed), sp_service_id and sign_info.sign_data together, so",
             "內政部 holds who proved what, when, and for which relying party — before the",
             "proof exists. The unlinkability this route buys is against the verifier only.",
             "See ProofCaveat.idNumberDisclosedToIssuer."],
            ["Timings are per circuit and measured by this app around the FFI call.",
             "runCompleteBenchmark's `setup` figure has no analogue here: this app never",
             "runs setup, so there is no such stage to report."],
            ["Peak memory is a sampled floor, not a peak. The sampler polls every 100 ms",
             "from another queue while rayon saturates every core, so the moment it is most",
             "likely to be starved is the moment the footprint is highest. The authoritative",
             "number is a JetsamEvent-*.ips report from a real device."],
            ["linkVerify runs on the device, which is what makes offline checking possible",
             "at all. It does not make nullifiers unique: de-duplicating them needs a shared",
             "record and nothing offline has one. Nothing here supports a claim that a holder",
             "is a real person *and* counted only once."]
        ]
        if environment.isSimulator {
            caveats.append(["Simulator. See the banner. Comparable only against other runs",
                            "on this same machine."])
        }
        return (["CAVEATS"] + caveats.map(Self.caveat)).joined(separator: "\n")
    }

    /// Hanging indent, wrapped by hand: this text is pasted into issues and chat
    /// windows that do not reflow.
    private static func caveat(_ lines: [String]) -> String {
        guard let first = lines.first else { return "" }
        return (["  - " + first] + lines.dropFirst().map { "    " + $0 })
            .joined(separator: "\n")
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Wider than `ProvingBenchmark`'s 20 because the labels here carry a circuit
    /// name. Same shape, so the two still read as one family.
    private static func row(_ label: String, _ value: String) -> String {
        let width = max(label.count, 26)
        return "  " + label.padding(toLength: width, withPad: " ", startingAt: 0) + value
    }
}
