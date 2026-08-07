//
//  ZKProofRun.swift
//  backupTW
//
//  The four stages behind the 最小揭露 screen — prepare the circuit files, get
//  the holder's signature, prove, verify — as one orchestration that a test can
//  drive end to end without a proving key, a certificate, or a network.
//

import Foundation

// MARK: - Provenance and licensing
//
// Same statement as `ZKProver.swift`, repeated rather than cross-referenced
// because this is the file that decides what the screen is allowed to say.
//
// `privacy-ethereum/zkID` — the circuits — carries an MIT LICENSE file.
// `openac-rsa-x509-swift`, `go-zkid-verifier` and `moica-revocation-smt` do
// **not**: as of 2026-08-07 none of the three contains a LICENSE file of any
// kind. We proceed on a written statement from PSE that the intended licence is
// MIT. That statement is not in the repositories. Do not shorten this to
// "upstream is MIT".

// MARK: - Verifying keys

/// The two files on-device verification needs, which `CircuitAssets.required`
/// deliberately leaves out.
///
/// # Why they are declared here instead of there
///
/// `CircuitAssets` is the *proving* asset table: what has to be present before
/// `ZKProver.prove` can run. Verification is a strictly larger ask and the extra
/// cost is not small, so making it a separate list keeps the disclosure honest —
/// a user who only wants to produce a proof is not asked for two gigabytes.
///
/// # What these files actually are, measured rather than assumed
///
/// The note in `CircuitAssets.setupOnly` says each verifying key is a
/// byte-identical prefix of its proving key, 32 bytes shorter, and that the
/// release pipeline publishes the same blob twice. The published sizes are
/// consistent with exactly that and are the reason this is expensive:
///
///     cert_chain_rs4096_proving.key.gz    41,321,996 bytes
///     cert_chain_rs4096_verifying.key.gz  41,321,957 bytes   (39 fewer)
///     user_sig_rs2048_proving.key.gz      16,513,669 bytes
///     user_sig_rs2048_verifying.key.gz    16,513,623 bytes   (46 fewer)
///
/// Read off the release with `curl -sIL` on 2026-08-07. A Groth16 verifying key
/// for these circuits is a few hundred bytes of actual content; 662 MB of it is
/// an upstream packaging defect, not a requirement of the mathematics.
///
/// **These are no longer downloaded.** This comment used to end by refusing to
/// derive them — truncating a proving key on the strength of a claim in another
/// comment would have made verification depend on an unverified guess about a
/// file format — and to name the condition for changing its mind: confirm the
/// truncation against both blobs. That has now been done. `VerifyingKeyDerivation`
/// cuts both files locally, and the derived bytes were checked to be
/// `FileManager.contentsEqual` to the downloaded ones before this changed.
///
/// The rows stay because these are still the files verification needs, and the
/// sizes and digests are still what a download would have to match. What they no
/// longer describe is 57.8 MB of traffic.
///
/// The digests are the ones already recorded in `CircuitAssets.setupOnly`'s doc
/// comment, taken from the same release manifest as the proving keys.
enum ZKVerifyingKeyAssets {

    private static let release = URL(
        string: "https://github.com/privacy-ethereum/zkID/releases/download/RSA-X.509-Cert-latest")!

    /// Installed sizes are the proving keys' figures minus 32 bytes, which is
    /// what the prefix claim implies. They are budget and progress-bar inputs
    /// only — `sha256` is what decides whether a download is accepted — and
    /// `CircuitAsset.inflateByteLimit` already carries a 1/16 margin for exactly
    /// this kind of estimate.
    static let all: [CircuitAsset] = [
        CircuitAsset(name: "cert_chain_rs4096_verifying",
                     remoteURL: release.appendingPathComponent("cert_chain_rs4096_verifying.key.gz"),
                     localFilename: "keys/cert_chain_rs4096_verifying.key",
                     sha256: "ba5054a5044115de5f51dcf4330ecf844423bd9e12aa311ca3e3756e1202fc8e",
                     compressedByteCount: 41_321_957,
                     installedByteCount: 693_663_362),
        CircuitAsset(name: "user_sig_rs2048_verifying",
                     remoteURL: release.appendingPathComponent("user_sig_rs2048_verifying.key.gz"),
                     localFilename: "keys/user_sig_rs2048_verifying.key",
                     sha256: "c4eabf366d7baf99306db72573d129f89aeef5a178d3368ffaef2d475ae81b7b",
                     compressedByteCount: 16_513_623,
                     installedByteCount: 274_677_818)
    ]

    static var totalDownloadByteCount: Int64 {
        all.reduce(0) { $0 + $1.compressedByteCount }
    }

    static var totalInstalledByteCount: Int64 {
        all.reduce(0) { $0 + $1.installedByteCount }
    }
}

// MARK: - Verification

/// What one local verification pass established.
///
/// Three separate booleans rather than one, because they answer three different
/// questions and collapsing them is how a screen ends up saying 「已驗證」 on the
/// strength of the weakest of the three. `linked` is the one the whitepaper's
/// offline story rests on: it is the check that the two proofs belong to the
/// same holder, and it runs on this device with no server.
struct ZKVerificationOutcome: Equatable, Sendable {

    let certificateChainValid: Bool
    let userSignatureValid: Bool

    /// `linkVerify` — both proofs, and that they are linked.
    let linked: Bool

    let certificateChainMilliseconds: UInt64
    let userSignatureMilliseconds: UInt64
    let linkMilliseconds: UInt64

    /// Every one of them, or this proves nothing.
    var isFullyValid: Bool {
        certificateChainValid && userSignatureValid && linked
    }

    var totalMilliseconds: UInt64 {
        let (partial, first) = certificateChainMilliseconds
            .addingReportingOverflow(userSignatureMilliseconds)
        let (total, second) = partial.addingReportingOverflow(linkMilliseconds)
        return (first || second) ? UInt64.max : total
    }
}

/// What happened when this device tried to check its own proof.
///
/// Three cases and not an `Optional<ZKVerificationOutcome>`, because the two
/// kinds of absence mean opposite things and an optional forces them to share a
/// rendering. This was not a hypothetical: the first real run produced a proof,
/// hit an error inside `linkVerify`, and the report announced "A proof was
/// produced and nothing checked it" — which was false. Something did check it.
enum ZKVerificationResult: Equatable, Sendable {

    /// The verifier ran to completion. `outcome.isFullyValid` says what it
    /// decided; a `false` in there is a **rejected proof**, not a malfunction.
    case completed(ZKVerificationOutcome)

    /// Never started, because the files it needs are not on disk. Says nothing
    /// whatsoever about the proof.
    case notAttempted(reason: String)

    /// Started and could not finish for a reason that is not a verdict — I/O, a
    /// missing artefact discovered late, an upstream error we do not classify.
    /// Also says nothing about the proof, but for a different reason, and the
    /// difference is what someone reading the report needs in order to know
    /// whether to fix a download or to look at a bug.
    case errored(message: String)

    var outcome: ZKVerificationOutcome? {
        if case .completed(let outcome) = self { return outcome }
        return nil
    }
}

/// The three verification calls, behind a protocol, for the same reason
/// `ProofBackend` exists: they read `keys/*_verifying.key`, and no CI runner is
/// going to hold a gigabyte of them.
protocol ZKProofVerifying: Sendable {

    /// Whether the files this backend needs are on disk. Checked before the run
    /// so an absent verifying key is reported as *unavailable* rather than as a
    /// verification that failed — those two mean opposite things about the proof.
    func missingArtifacts(in workingDirectory: URL) -> [String]

    func verify(documentsPath: String) throws -> ZKVerificationOutcome
}

/// The production verifier: OpenACSwift, timed.
///
/// Timing is taken here rather than upstream because none of the three verify
/// functions reports a duration — `runCompleteBenchmark` is the only upstream
/// path that does, and it cannot run in this app (see `ProvingBenchmark`). The
/// verify figure is the number M3 turns on, so it has to come from somewhere.
struct OpenACProofVerifier: ZKProofVerifying {

    /// The two verifying keys, plus the four files `prove*` leaves behind.
    ///
    /// The proof and instance files are included because verification without
    /// them is not a failed verification, it is a missing input, and a screen
    /// that shows ❌ for "the proof file is not there" has told the user their
    /// certificate is bad.
    func missingArtifacts(in workingDirectory: URL) -> [String] {
        let required = ZKVerifyingKeyAssets.all.map(\.localFilename)
            + ZKProver.proofFilenames
            + ZKProver.instanceFilenames
        return required.filter {
            !FileManager.default.fileExists(
                atPath: workingDirectory.appendingPathComponent($0).path)
        }
    }

    func verify(documentsPath: String) throws -> ZKVerificationOutcome {
        // Each call is timed separately: the three are not interchangeable and a
        // single combined figure would hide which one is slow.
        let (certificateChain, certificateChainMs) = try Self.timed {
            try Self.verifyCertificateChain(documentsPath: documentsPath)
        }
        let (userSignature, userSignatureMs) = try Self.timed {
            try Self.verifyUserSignature(documentsPath: documentsPath)
        }
        let (linked, linkMs) = try Self.timed {
            try Self.linkVerify(documentsPath: documentsPath)
        }
        return ZKVerificationOutcome(certificateChainValid: certificateChain,
                                     userSignatureValid: userSignature,
                                     linked: linked,
                                     certificateChainMilliseconds: certificateChainMs,
                                     userSignatureMilliseconds: userSignatureMs,
                                     linkMilliseconds: linkMs)
    }

    /// Runs one check and turns "the verifier said no" into `false`.
    ///
    /// # This is not defensive coding; it repairs an inverted verdict
    ///
    /// Upstream's three verify functions return `Bool`, which reads as though a
    /// refused proof comes back `false`. It does not. Measured on the simulator
    /// against real proofs on 2026-08-07:
    ///
    ///     verifyCertChainRs4096 -> true
    ///     verifyUserSigRs2048   -> true
    ///     linkVerify            -> THREW VerificationFailed(msg: "Link verification failed")
    ///
    /// So the `Bool` is only ever `true`, and the interesting answer arrives as
    /// an error. Left alone, that error propagates out of `verify` and the screen
    /// renders 「這支手機無法完成驗證」 — an infrastructure complaint — for a proof
    /// that was checked and **rejected**. That is precisely the conflation
    /// `ZKRunStageState.unavailable` was introduced to prevent, arriving from the
    /// other direction and with the more dangerous polarity: a refused proof
    /// dressed up as a technical hiccup invites the user to retry rather than to
    /// stop.
    ///
    /// # The same inversion arrives through a second door
    ///
    /// Folding only `ProofBackendFailure.verificationFailed` was not enough, and
    /// the case that proved it is worth writing down. Given proving material
    /// whose `app_id` does not match — an unsatisfied constraint system —
    /// `verifyUserSigRs2048` does not throw `VerificationFailed`. The Rust side
    /// **panics** with `InvalidSumcheckProof`, UniFFI turns that into
    /// `UniffiInternalError`, and because that type is `fileprivate` inside
    /// upstream's `mopro.swift` it cannot be caught by name anywhere in this app.
    /// It classified as `.unknown`, propagated out of `verify`, and the screen
    /// rendered 「這支手機無法完成驗證」 — the infrastructure complaint, for a
    /// proof that had been checked and refused. The exact conflation this
    /// function exists to prevent, arriving from the other side of the same
    /// error type.
    ///
    /// So the fold is now `ProofBackendFailure.isRejection`, which recognises
    /// both doors and, critically, **only** those two. `.fileNotFound`,
    /// `.inputOutput`, `.invalidInput` and any panic that is not on
    /// `ProofBackendFailure.rejectionPanicMarkers` still throw, because those
    /// genuinely say nothing about the proof — and 「你的證明無效」 said about a
    /// proof that is fine is the same size of mistake as the one above, pointed
    /// at the holder instead of at the device.
    ///
    /// Internal rather than private so the fold can be tested: the test bundle
    /// does not link OpenACSwift, but this function's contract is entirely about
    /// a thrown `ProofBackendFailure`, which it can construct.
    static func timed(_ body: () throws -> Bool) throws -> (Bool, UInt64) {
        let began = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> UInt64 {
            ProvingBenchmark.milliseconds(fromNanoseconds: began,
                                          to: DispatchTime.now().uptimeNanoseconds)
        }
        do {
            return (try body(), elapsed())
        } catch let failure as ProofBackendFailure where failure.isRejection {
            return (false, elapsed())
        }
    }
}

// MARK: - Errors

/// Why a stage did not finish.
///
/// One type across all four stages, because the screen renders them the same
/// way and the distinction that matters to the person holding the phone is
/// `isRecoverable`, not which module threw.
enum ZKRunError: Error, Equatable {

    /// The user backed out.
    case cancelled

    /// A run is already going.
    case alreadyRunning

    /// Downloading or installing the circuit files failed. `message` is already
    /// localized — `CircuitAssetError` writes better sentences about its own
    /// failures than anything here could.
    ///
    /// Recoverable: everything that reaches this case is a transfer, a volume or
    /// a server having a bad moment, and the same request after the connection
    /// comes back succeeds.
    case assetsUnavailable(message: String)

    /// The trust anchor did not pass its own checks, so nothing was installed
    /// and nothing will be proven against it.
    ///
    /// **Split out of `assetsUnavailable` because the two want opposite
    /// responses.** A download that was interrupted is worth retrying; a
    /// certificate that failed its SHA-256 pin, its identity checks or its chain
    /// to GRCA-G3 is not, because no retry rewrites those bytes. Folded into
    /// `assetsUnavailable` — which is what a generic `catch` did — a substituted
    /// trust anchor was rendered with the same 「再試一次」 affordance as a
    /// dropped connection, so the holder's response to the most serious failure
    /// this stage can report was to tap it again. `ZKProofError` already takes
    /// the opposite and correct position for its own asset failures.
    ///
    /// Carries the error rather than a string so `isRecoverable` stays the
    /// anchor's own answer: the two not-yet-valid cases really are recoverable,
    /// because a wrong device clock is something the holder can fix.
    case trustAnchorRejected(IssuerCertificateError)

    /// The 行動自然人憑證 round trip did not produce a signature.
    case signingFailed(message: String)

    /// This build has no way to reach TW FidO. Distinct from `signingFailed`
    /// because it is not a failure of the holder's certificate and retrying
    /// changes nothing: the SP credentials are not on this machine, or this is a
    /// distribution build that deliberately cannot hold them.
    case signingUnavailable(message: String)

    /// The holder waited out the ticket's `time_limit`.
    case signingTimedOut

    /// `ProvingInputs` refused the material before it cost a proof.
    case inputsRejected(ProvingInputError)

    case provingFailed(ZKProofError)

    /// Verification could not be attempted — the verifying keys are not
    /// downloaded, or the proof files are not where they were expected.
    ///
    /// **Not the same as a proof that failed to verify**, and the split is the
    /// point: this says nothing at all about the proof.
    case verificationUnavailable(missing: [String])

    case verificationFailed(message: String)

    var isRecoverable: Bool {
        switch self {
        case .cancelled, .alreadyRunning, .assetsUnavailable, .signingTimedOut,
             .verificationUnavailable:
            return true
        case .provingFailed(let error):
            return error.isRecoverable
        case .trustAnchorRejected(let error):
            return error.isRecoverable
        case .signingFailed, .signingUnavailable, .inputsRejected, .verificationFailed:
            return false
        }
    }
}

extension ZKRunError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return NSLocalizedString("Stopped.", comment: "A zero-knowledge proof run was cancelled")
        case .alreadyRunning:
            return NSLocalizedString("This device is already creating a proof.", comment: "")
        case .assetsUnavailable(let message):
            return message
        case .trustAnchorRejected(let error):
            // `IssuerCertificateError` already distinguishes "this file has been
            // altered" from "your device's clock is wrong" from "update the
            // app"; collapsing three different instructions into one generic
            // sentence here would undo that.
            return error.errorDescription
        case .signingFailed(let message), .signingUnavailable(let message),
             .verificationFailed(let message):
            return message
        case .signingTimedOut:
            return NSLocalizedString(
                "The signing request expired before it was approved on the certificate app.",
                comment: "")
        case .inputsRejected(let error):
            return error.errorDescription
        case .provingFailed(let error):
            return error.errorDescription
        case .verificationUnavailable:
            return NSLocalizedString(
                "This device can't check the proof yet: the verification keys aren't downloaded.",
                comment: "")
        }
    }
}

// MARK: - Stages

/// The four things that have to happen, in the order they happen.
///
/// An enum with a fixed `allCases` order rather than an array built at the call
/// site, so the screen cannot show them out of order and a test can assert the
/// order without reaching into the view.
enum ZKRunStage: String, CaseIterable, Equatable, Sendable {

    /// Download and install ~2 GB of circuit material.
    case assets

    /// The 行動自然人憑證 app-to-app round trip.
    case signature

    /// Both Groth16 proofs.
    case proof

    /// `linkVerify` and friends, on this device.
    case verification

    var title: String {
        switch self {
        case .assets:
            return NSLocalizedString("Prepare the verification files", comment: "ZK proof stage")
        case .signature:
            return NSLocalizedString("Sign with your digital certificate", comment: "ZK proof stage")
        case .proof:
            return NSLocalizedString("Create the proof", comment: "ZK proof stage")
        case .verification:
            return NSLocalizedString("Check the proof on this device", comment: "ZK proof stage")
        }
    }
}

/// Where one stage has got to.
enum ZKRunStageState: Equatable, Sendable {

    /// Not started. Also where a stage stays when an earlier one failed — it was
    /// never attempted, which is different from having been skipped on purpose.
    case waiting

    /// `progress` is `nil` where the work reports none; the screen shows an
    /// indeterminate spinner rather than a bar frozen at zero.
    case running(progress: Double?, detail: String?)

    case succeeded(detail: String)

    /// Attempted and did not finish.
    case failed(message: String, recoverable: Bool)

    /// Could not be attempted — or could not be attempted *in full* — and the
    /// reason is not a failure of anything the user did.
    ///
    /// Two stages reach this. `verification`, when the verifying keys or the
    /// proof files are not on disk. And `assets`, when everything a proof needs
    /// was installed and only the extra material for checking it here could not
    /// be: that run goes on to produce a real proof, so marking the stage
    /// `failed` would be false, and marking it `succeeded` would be false in the
    /// other direction. See `ZKAssetPreparing.verificationOnlyRequirementNames`.
    case unavailable(reason: String)

    var isTerminal: Bool {
        switch self {
        case .waiting, .running:
            return false
        case .succeeded, .failed, .unavailable:
            return true
        }
    }
}

/// Every stage's state at one instant, plus the result if there is one.
///
/// A value rather than a stream of deltas because the screen re-renders whole
/// sections and a delta that arrives out of order draws a stage that has already
/// finished as still running.
struct ZKRunSnapshot: Equatable, Sendable {

    /// Always `ZKRunStage.allCases` order, always all four.
    let states: [ZKRunStage: ZKRunStageState]

    /// Present once the proof exists, even if verification then failed — the
    /// timings and the caveats are worth showing either way.
    let report: ZKProofRunReport?

    let isFinished: Bool

    static let initial = ZKRunSnapshot(
        states: Dictionary(uniqueKeysWithValues: ZKRunStage.allCases.map { ($0, .waiting) }),
        report: nil,
        isFinished: false)

    func state(_ stage: ZKRunStage) -> ZKRunStageState {
        states[stage] ?? .waiting
    }

    /// The first stage that did not succeed, if any. What the screen puts at the
    /// top when the run is over.
    var firstProblem: (stage: ZKRunStage, state: ZKRunStageState)? {
        for stage in ZKRunStage.allCases {
            switch state(stage) {
            case .failed, .unavailable:
                return (stage, state(stage))
            case .waiting, .running, .succeeded:
                continue
            }
        }
        return nil
    }
}

// MARK: - Presentation

/// Turning a `ZKRunStageState` into something a row can draw.
///
/// A free enum rather than static members on the view controller, and for a
/// reason worth stating: `UIViewController` is `@MainActor`, so its statics are
/// too, and a test asserting that `.unavailable` is not drawn as a failure would
/// have to hop to the main actor to ask. These are pure functions over a value —
/// the isolation would be a cost with no counterpart.
enum ZKStagePresentation {

    /// One sentence describing where a stage has got to.
    static func detail(for state: ZKRunStageState) -> String {
        switch state {
        case .waiting:
            return NSLocalizedString("Not started", comment: "ZK stage state")
        case .running(let progress, let detail):
            var parts: [String] = []
            if let progress {
                parts.append(String(format: "%.0f%%", min(max(progress, 0), 1) * 100))
            }
            if let detail, !detail.isEmpty { parts.append(detail) }
            if parts.isEmpty { parts.append(NSLocalizedString("Working…", comment: "ZK stage state")) }
            return parts.joined(separator: " · ")
        case .succeeded(let detail):
            return detail
        case .failed(let message, _):
            return message
        case .unavailable(let reason):
            return reason
        }
    }

    /// The tick / warning / nothing decision.
    ///
    /// `.unavailable` maps to `nil`, not `false`: a grey row saying "this device
    /// cannot check the proof" is a fact about this device, and drawing it with
    /// the same warning triangle as "the proof was rejected" is the one
    /// conflation this screen exists to avoid.
    static func verdict(for state: ZKRunStageState) -> Bool? {
        switch state {
        case .succeeded:
            return true
        case .failed:
            return false
        case .waiting, .running, .unavailable:
            return nil
        }
    }

    static func isBusy(_ state: ZKRunStageState) -> Bool {
        if case .running = state { return true }
        return false
    }

    /// Localized on purpose — unlike the measurement report, this is chrome a
    /// person reads once and never diffs.
    /// The headline for "Before you start", as a title and a detail line.
    ///
    /// Here rather than inline in the view controller so it can be asserted.
    /// The case that made that worth doing: once `VerifyingKeyDerivation` landed,
    /// a plan could have outstanding work and still cost nothing on the wire, and
    /// the download wording rendered it as 「下載 0 KB」 — an itemised price naming
    /// a resource the step does not spend. A screen whose entire purpose is
    /// disclosure before a tap cannot be wrong about which resource it is asking
    /// for, and the wording was not reachable from any test.
    static func preparationSummary(for plan: ZKAssetPlan) -> (title: String, detail: String) {
        guard plan.downloadByteCount > 0 else {
            return (NSLocalizedString("These files have to be prepared first", comment: ""),
                    String(format: NSLocalizedString("No download · uses %@ on this device",
                                                     comment: "installed size"),
                           byteString(plan.installedByteCount)))
        }
        return (NSLocalizedString("These files have to be downloaded first", comment: ""),
                String(format: NSLocalizedString("Download %@ · uses %@ on this device",
                                                 comment: "download size, installed size"),
                       byteString(plan.downloadByteCount),
                       byteString(plan.installedByteCount)))
    }

    /// The per-file line under that headline.
    static func requirementDetail(for requirement: ZKAssetRequirement) -> String {
        if requirement.downloadByteCount == 0 {
            return String(format: NSLocalizedString("Made on this phone · %@ on disk", comment: ""),
                          byteString(requirement.installedByteCount))
        }
        if requirement.isStale {
            return String(format: NSLocalizedString("Out of date · download %@ again", comment: ""),
                          byteString(requirement.downloadByteCount))
        }
        return String(format: NSLocalizedString("Download %@ · %@ on disk", comment: ""),
                      byteString(requirement.downloadByteCount),
                      byteString(requirement.installedByteCount))
    }

    static func byteString(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    /// Zero is an absence, never "instant". A proof stage that genuinely took
    /// under a millisecond does not exist, so a zero here can only mean upstream
    /// left the field unset.
    static func durationString(_ milliseconds: UInt64) -> String {
        guard milliseconds > 0 else {
            return NSLocalizedString("not reported", comment: "a duration upstream returned as 0")
        }
        guard milliseconds >= 1000 else {
            return String(format: NSLocalizedString("%llu ms", comment: ""), milliseconds)
        }
        return String(format: NSLocalizedString("%.1f s", comment: ""),
                      Double(milliseconds) / 1000)
    }
}

// MARK: - Seams

/// What the run needs from the asset store.
///
/// A protocol rather than `CircuitAssets` itself because the real store's
/// smallest unit of work is an 41 MB download, and the orchestration questions —
/// is the disclosure right, does a failure stop the run, is progress forwarded —
/// have nothing to do with GitHub.
protocol ZKAssetPreparing: Sendable {

    /// What is still outstanding, and what it costs. Called before anything is
    /// downloaded so the user can be told the price first.
    func plan() async -> ZKAssetPlan

    /// Downloads and installs everything in the plan.
    ///
    /// `progress` is 0...1 across the whole set, weighted by download size, and
    /// arrives on a background queue.
    func prepare(progress: @escaping @Sendable (ZKAssetProgress) -> Void) async throws

    /// Where the installed files live — the `documentsPath` the prover and the
    /// verifier are handed.
    var workingDirectory: URL { get }

    /// The `ZKAssetRequirement.name`s that only on-device *checking* needs.
    ///
    /// # Why the run has to be able to tell these apart
    ///
    /// The two verifying keys are 57.8 MB down the wire and 968 MB on disk, and
    /// `ZKProver` never opens either of them. Treating them as part of the same
    /// indivisible "prepare the files" step produced a failure with no way out:
    /// on a phone with 1.2 GB free, the 950 MB of proving material installs, the
    /// verifying keys' `ensureSpace` then asks for ~778 MB it cannot have,
    /// `CircuitAssetError.insufficientDiskSpace` ends stage 1 — and the run
    /// stops, having already spent the download. Every retry does the same
    /// thing, so the 950 MB the holder paid for never produces a single proof.
    ///
    /// A run that cannot check its own work is a run that produces a proof and
    /// says 「這支手機無法檢查這份證明」, which is already a first-class outcome
    /// here (`ZKVerificationResult.notAttempted`). A run that cannot prove is not
    /// a run at all. Only the second one is worth stopping for.
    ///
    /// Defaults to empty, i.e. "everything I list is mandatory", which is the
    /// safe answer for any conformance that has not thought about it.
    var verificationOnlyRequirementNames: Set<String> { get }
}

extension ZKAssetPreparing {

    var verificationOnlyRequirementNames: Set<String> { [] }
}

/// One outstanding asset, in the terms the disclosure is written in.
struct ZKAssetRequirement: Equatable, Sendable {
    let name: String
    let displayName: String
    let downloadByteCount: Int64
    let installedByteCount: Int64
    /// Already on disk but past its refresh interval. Shown differently: a stale
    /// snapshot is not a download the user has never started, it is one they
    /// finished and that has since gone off.
    let isStale: Bool
}

struct ZKAssetPlan: Equatable, Sendable {

    let outstanding: [ZKAssetRequirement]

    var isReady: Bool { outstanding.isEmpty }

    var downloadByteCount: Int64 {
        outstanding.reduce(0) { $0 + $1.downloadByteCount }
    }

    var installedByteCount: Int64 {
        outstanding.reduce(0) { $0 + $1.installedByteCount }
    }
}

struct ZKAssetProgress: Equatable, Sendable {
    let displayName: String
    /// Across the whole set, 0...1.
    let overallFraction: Double
    let completedCount: Int
    let totalCount: Int
}

/// The 行動自然人憑證 round trip, behind a protocol.
protocol ZKHolderSigning: Sendable {
    func sign(challenge: ProofChallenge) async throws -> ProvingInputs
}

/// `ZKProver.prove`, behind a protocol, so the run can be tested without one.
protocol ZKProving: Sendable {
    func prove(_ inputs: ProvingInputs) async throws -> ZKProofBundle
}

/// `ZKProver` is an actor, so this cannot be a conformance on the actor itself
/// without making every call site deal with isolation. A `Sendable` wrapper that
/// awaits it keeps the seam synchronous-looking and the actor untouched.
struct ZKProverAdapter: ZKProving {

    let prover: ZKProver

    func prove(_ inputs: ProvingInputs) async throws -> ZKProofBundle {
        try await prover.prove(inputs)
    }
}

// MARK: - Runner

/// Drives the four stages and reports after each one.
///
/// An `actor` for the same reason `ZKProver` is: proving holds roughly two
/// gigabytes and two concurrent runs is a kill, not a slowdown. The guard is
/// duplicated here rather than left to `ZKProver` because this run also holds a
/// ~2 GB download and a TW FidO ticket, and a second attempt should be refused
/// before either of those starts.
actor ZKProofRunner {

    private let assets: any ZKAssetPreparing
    private let signer: any ZKHolderSigning
    private let prover: any ZKProving
    private let clock: any ProvingBenchmarkClock
    private let footprint: any ProvingBenchmarkFootprintTracking
    private let headroomAtStart: () -> UInt64?
    private let environment: () -> ProvingBenchmark.Environment
    private let now: () -> Date

    private var isRunning = false
    private var states: [ZKRunStage: ZKRunStageState] = ZKRunSnapshot.initial.states

    // There is no verifier and no verification queue here any more.
    //
    // Verification moved into `ZKProver.verifyOnThisDevice`, because refusing a
    // bad proof has to happen where the bundle is created — a runner checking
    // afterwards has already been handed the thing it would be refusing. This
    // actor now renders `ZKProofBundle.selfCheck` and calls nothing. The
    // off-the-executor rule those two lines existed to keep is still enforced,
    // one module over, by `ZKProver.queue`.

    init(assets: any ZKAssetPreparing,
         signer: any ZKHolderSigning,
         prover: any ZKProving,
         clock: any ProvingBenchmarkClock = UptimeClock(),
         footprint: any ProvingBenchmarkFootprintTracking = MachPeakFootprintTracker(),
         headroomAtStart: @escaping () -> UInt64? = { MachMemory.availableMemoryBytes() },
         environment: @escaping () -> ProvingBenchmark.Environment = { .current() },
         now: @escaping () -> Date = { Date() }) {
        self.assets = assets
        self.signer = signer
        self.prover = prover
        self.clock = clock
        self.footprint = footprint
        self.headroomAtStart = headroomAtStart
        self.environment = environment
        self.now = now
    }

    /// What the user has to agree to before anything is fetched.
    ///
    /// Separate from `run` on purpose: the screen shows this, waits for a tap,
    /// and only then calls `run`. A `prepare` that downloaded first and disclosed
    /// afterwards would be the thing the brief forbids.
    func assetPlan() async -> ZKAssetPlan {
        await assets.plan()
    }

    /// Runs all four stages. Never throws — every failure is a stage state, and
    /// the caller renders it.
    ///
    /// `onUpdate` is called after every state change, including the first, so a
    /// screen that subscribes and then renders the returned snapshot cannot miss
    /// an edge.
    @discardableResult
    func run(challenge: ProofChallenge,
             onUpdate: @escaping @Sendable (ZKRunSnapshot) -> Void) async -> ZKRunSnapshot {

        guard !isRunning else {
            // Deliberately does not touch `states`: the run already in flight owns
            // them, and overwriting its stage list with a refusal would erase a
            // proof in progress from the screen.
            var refused = ZKRunSnapshot.initial.states
            refused[.assets] = .failed(
                message: ZKRunError.alreadyRunning.localizedDescription, recoverable: true)
            let snapshot = ZKRunSnapshot(states: refused, report: nil, isFinished: true)
            onUpdate(snapshot)
            return snapshot
        }
        isRunning = true
        defer { isRunning = false }

        states = ZKRunSnapshot.initial.states
        emit(onUpdate)

        // MARK: 1 — assets
        set(.assets, .running(progress: nil, detail: nil))
        emit(onUpdate)
        do {
            let plan = await assets.plan()
            if plan.isReady {
                set(.assets, .succeeded(detail: NSLocalizedString("Already prepared", comment: "")))
            } else {
                try await assets.prepare { progress in
                    // Hopping through the actor would serialise a callback that
                    // fires hundreds of times per download behind the run itself.
                    // The screen coalesces on the main queue instead.
                    onUpdate(Self.snapshot(states: Self.replacing(
                        ZKRunSnapshot.initial.states,
                        stage: .assets,
                        with: .running(progress: progress.overallFraction,
                                       detail: progress.displayName)),
                                           report: nil,
                                           isFinished: false))
                }
                set(.assets, .succeeded(detail: NSLocalizedString("Downloaded and installed",
                                                                  comment: "")))
            }
        } catch is CancellationError {
            return finish(.assets, ZKRunError.cancelled, onUpdate)
        } catch let error as IssuerCertificateError {
            // Before the generic clause, and that ordering is the fix: the
            // generic clause classifies everything as `assetsUnavailable`, whose
            // `isRecoverable` is `true`, which put "the trust anchor this app
            // ships with has been altered" in the same bucket as "the download
            // was interrupted" and offered the same retry.
            return finish(.assets, ZKRunError.trustAnchorRejected(error), onUpdate)
        } catch {
            // What is still outstanding decides whether this is fatal. If the
            // only thing that could not be prepared is material the *verifier*
            // reads, the proof this run exists to produce is still possible, and
            // stopping here would throw away a download that succeeded — see
            // `ZKAssetPreparing.verificationOnlyRequirementNames`.
            //
            // Deliberately re-asked rather than inferred from the error: the
            // store knows what is on disk now, and "prepare threw" says nothing
            // about how far it got. An empty outstanding set is *not* treated as
            // survivable — prepare failed for some reason we cannot see, and the
            // conservative reading of "nothing is outstanding yet something went
            // wrong" is that the plan is not to be trusted.
            let remaining = await assets.plan()
            let outstanding = Set(remaining.outstanding.map(\.name))
            let blocking = outstanding.subtracting(assets.verificationOnlyRequirementNames)
            guard !outstanding.isEmpty, blocking.isEmpty else {
                return finish(.assets,
                              ZKRunError.assetsUnavailable(message: Self.message(for: error)),
                              onUpdate)
            }
            // Not `.succeeded`: a download did fail. Not `.failed`: this run goes
            // on to make a real proof. Stage 4 will say the same thing again from
            // its own side, which is the consistent story.
            set(.assets, .unavailable(reason: String(
                format: NSLocalizedString(
                    "The files for creating a proof are ready, but the extra ones for checking it on this device aren't: %@",
                    comment: "Assets stage: only the verification-only downloads failed"),
                Self.message(for: error))))
        }
        emit(onUpdate)

        // MARK: 2 — signature
        set(.signature, .running(progress: nil, detail: NSLocalizedString(
            "Waiting for approval in the digital certificate app…", comment: "")))
        emit(onUpdate)
        let inputs: ProvingInputs
        do {
            inputs = try await signer.sign(challenge: challenge)
            set(.signature, .succeeded(detail: NSLocalizedString("Signed", comment: "")))
        } catch let error as ZKRunError {
            return finish(.signature, error, onUpdate)
        } catch is CancellationError {
            return finish(.signature, ZKRunError.cancelled, onUpdate)
        } catch let error as ProvingInputError {
            return finish(.signature, ZKRunError.inputsRejected(error), onUpdate)
        } catch {
            return finish(.signature,
                          ZKRunError.signingFailed(message: Self.message(for: error)),
                          onUpdate)
        }
        emit(onUpdate)

        // MARK: 3 — proof
        //
        // The memory tracker starts here and not at stage 1: a 2 GB download is
        // not what gets an app killed, a 2 GB heap is, and a peak that included
        // the download would be measuring the wrong thing.
        set(.proof, .running(progress: nil, detail: NSLocalizedString(
            "This takes a while and uses a lot of memory.", comment: "")))
        emit(onUpdate)

        let headroom = headroomAtStart()
        let capturedEnvironment = environment()
        let startedAt = now()
        footprint.start()
        let began = clock.nowNanoseconds()

        let bundle: ZKProofBundle
        do {
            bundle = try await prover.prove(inputs)
        } catch ZKProofError.proofRejectedOnThisDevice {
            // Both circuits proved; `verifyOnThisDevice` then checked the result
            // and refused it. Letting this fall into the generic
            // `provingFailed` branch below reported it as a failure of stage 3
            // — "the proof could not be built" — and left stage 4 sitting at
            // `.waiting`, saying nothing ever checked it. Checking it is
            // precisely what happened, and the refusal is the most diagnostic
            // outcome this run can produce. Telling the two apart is the reason
            // they are separate stages.
            //
            // No report: `ZKProofRunReport` carries a `ZKProofBundle`, and the
            // prover deliberately does not return one for a proof this device
            // refused, so that no screen downstream can hand it to a verifier.
            // The stage states carry the finding instead.
            _ = footprint.stop()
            set(.proof, .succeeded(detail: NSLocalizedString(
                "Both circuits completed", comment: "ZK stage detail")))
            set(.verification, .failed(message: NSLocalizedString(
                "This device checked the proof and refused it.", comment: "ZK stage detail"),
                recoverable: false))
            let snapshot = ZKRunSnapshot(states: states, report: nil, isFinished: true)
            onUpdate(snapshot)
            return snapshot
        } catch let error as ZKProofError {
            // The tracker owns a repeating timer; a thrown error that skipped the
            // stop would leave it sampling for the life of the process — and a
            // failed proof is exactly when that happens.
            _ = footprint.stop()
            return finish(.proof, ZKRunError.provingFailed(error), onUpdate)
        } catch is CancellationError {
            _ = footprint.stop()
            return finish(.proof, ZKRunError.cancelled, onUpdate)
        } catch {
            _ = footprint.stop()
            return finish(.proof,
                          ZKRunError.provingFailed(.proofFailed(circuit: .certificateChain,
                                                               reason: ProofBackendFailure(error))),
                          onUpdate)
        }
        let proofEnded = clock.nowNanoseconds()
        // The localized form, not `ProvingBenchmark.Report.duration`. That one is
        // ASCII on purpose — it belongs to a report that gets diffed between two
        // devices — and putting `7305 ms (7.30 s)` in a row of an interface that
        // is otherwise 正體中文 is how the measurement vocabulary leaks into the
        // product. Found by looking at the screen.
        set(.proof, .succeeded(detail: ZKStagePresentation.durationString(
            bundle.totalProveMilliseconds)))
        emit(onUpdate)

        // MARK: 4 — verification
        set(.verification, .running(progress: nil, detail: nil))
        emit(onUpdate)

        // `prove` already verified on this device — that is what makes a
        // rejected proof reachable at all — so its verdict is reused rather
        // than recomputed. Verifying again would load the same 968 MB of keys
        // and run the same three checks a second time, adding roughly eight
        // seconds to every successful run, and the figure that reached the
        // report would be the warm second pass rather than what a verifier
        // standing in front of the holder would actually wait.
        let verification: ZKVerificationResult
        switch bundle.selfCheck {
        case .passed(let outcome):
            verification = .completed(outcome)
        case .notPerformed(let missing):
            verification = .notAttempted(
                reason: ZKRunError.verificationUnavailable(missing: missing).localizedDescription)
        case .inconclusive:
            // Ran and broke below the FFI boundary. Says nothing about the
            // proof in either direction, so it must not render as a rejection —
            // `.errored` maps to `.unavailable`, which draws grey rather than a
            // warning.
            verification = .errored(message: NSLocalizedString(
                "The check ran but could not reach a verdict.", comment: "ZK stage detail"))
        }
        let ended = clock.nowNanoseconds()
        let peak = footprint.stop()

        let report = ZKProofRunReport(
            environment: capturedEnvironment,
            bundle: bundle,
            verification: verification,
            memory: ProvingBenchmark.MemoryObservation(peakFootprintBytes: peak,
                                                       headroomAtStartBytes: headroom),
            proveWallClockMs: ProvingBenchmark.milliseconds(fromNanoseconds: began, to: proofEnded),
            totalWallClockMs: ProvingBenchmark.milliseconds(fromNanoseconds: began, to: ended),
            documentsPath: assets.workingDirectory.path,
            startedAt: startedAt)

        switch verification {
        case .completed(let outcome) where outcome.isFullyValid:
            set(.verification,
                .succeeded(detail: ZKStagePresentation.durationString(outcome.totalMilliseconds)))
        case .completed:
            // A verifier that ran and said no. The single most important thing on
            // this screen not to render as a success — nor as a malfunction.
            set(.verification, .failed(message: NSLocalizedString(
                "This device checked the proof and it did not pass.", comment: ""),
                                       recoverable: false))
        case .notAttempted(let reason):
            set(.verification, .unavailable(reason: reason))
        case .errored(let message):
            // `.unavailable`, not `.failed`: the check did not finish, so nothing
            // was decided about the proof, and a warning triangle here would say
            // otherwise.
            set(.verification, .unavailable(reason: message))
        }

        let snapshot = ZKRunSnapshot(states: states, report: report, isFinished: true)
        onUpdate(snapshot)
        return snapshot
    }

    // MARK: Plumbing

    private func set(_ stage: ZKRunStage, _ state: ZKRunStageState) {
        states[stage] = state
    }

    private func emit(_ onUpdate: @escaping @Sendable (ZKRunSnapshot) -> Void) {
        onUpdate(ZKRunSnapshot(states: states, report: nil, isFinished: false))
    }

    /// Marks `stage` failed and ends the run. Every later stage stays `.waiting`,
    /// which is the honest rendering: they were not attempted.
    private func finish(_ stage: ZKRunStage,
                        _ error: ZKRunError,
                        _ onUpdate: @escaping @Sendable (ZKRunSnapshot) -> Void) -> ZKRunSnapshot {
        set(stage, .failed(message: error.localizedDescription, recoverable: error.isRecoverable))
        let snapshot = ZKRunSnapshot(states: states, report: nil, isFinished: true)
        onUpdate(snapshot)
        return snapshot
    }

    private static func replacing(_ states: [ZKRunStage: ZKRunStageState],
                                  stage: ZKRunStage,
                                  with state: ZKRunStageState) -> [ZKRunStage: ZKRunStageState] {
        var copy = states
        copy[stage] = state
        return copy
    }


    private static func snapshot(states: [ZKRunStage: ZKRunStageState],
                                 report: ZKProofRunReport?,
                                 isFinished: Bool) -> ZKRunSnapshot {
        ZKRunSnapshot(states: states, report: report, isFinished: isFinished)
    }

    /// A sentence for the user.
    ///
    /// `localizedDescription` on a bare `Error` is "The operation couldn't be
    /// completed. (Domain error N.)", which is worse than useless on a screen a
    /// person is deciding something from. Types that took the trouble to write a
    /// sentence get theirs; everything else gets one honest generic line rather
    /// than Foundation's.
    static func message(for error: Error) -> String {
        if error is ProofBackendFailure {
            // Deliberately message-free — see `ProofBackendFailure`. The Rust
            // `msg:` was dropped at the seam precisely so it could not reach a
            // screen, and re-deriving a sentence from the case here would tell
            // the holder which field of their certificate was rejected.
            return NSLocalizedString("This device couldn't finish checking the proof.", comment: "")
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return NSLocalizedString("Something went wrong on this device.", comment: "")
    }
}
