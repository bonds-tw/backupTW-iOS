//
//  ZKProver.swift
//  backupTW
//
//  Orchestrates one zero-knowledge proof: readiness → circuit inputs → two
//  proofs → a result that is honest about what it does and does not establish.
//

import Foundation
import OpenACSwift

// MARK: - Provenance and licensing
//
// This module drives `privacy-ethereum/openac-rsa-x509-swift`, which wraps the
// zkID circuits.
//
// **Licensing, stated exactly.** `privacy-ethereum/zkID` — the circuits
// themselves — carries an MIT LICENSE file. `openac-rsa-x509-swift`,
// `go-zkid-verifier` and `moica-revocation-smt` **do not**: as of 2026-08-07
// none of those three repositories contains a LICENSE file of any kind, and the
// GitHub license endpoint returns 404 for each. We are proceeding on a written
// statement from PSE that the intended licence is MIT. That statement is not in
// the repositories, so anyone auditing this app from the upstream sources alone
// will find no licence at all. Do not shorten this to "upstream is MIT".
//
// **What this proof establishes**, so that nothing downstream overstates it:
// that *some* holder of a certificate issued by MOICA-G3 supplied signing
// material for it, and that the certificate's serial number is absent from the
// revocation snapshot this run happened to be built against. Note both hedges.
// "Some holder" rather than "the holder standing here" is
// `ProofCaveat.signatureMaterialIsReplayable`; "the snapshot this run was built
// against" rather than "the revocation list" is
// `ProofCaveat.revocationRootNotAnchored`.
//
// See `ProofCaveat` for everything it does *not* establish. Five of the six are
// attached to every bundle this type produces, so that a screen cannot quietly
// omit one.

// MARK: - Backend

/// The three OpenACSwift calls this orchestration makes, behind a protocol.
///
/// **This seam is not decoration; it is the only way any of this is testable.**
/// A real proof needs `keys/cert_chain_rs4096_proving.key` and
/// `keys/user_sig_rs2048_proving.key` — 82 MB to download, 950 MB on disk, and
/// roughly two gigabytes of resident memory to use. No CI runner is going to do
/// that, and a test that did would be measuring GitHub rather than this code. So
/// the boundary is drawn exactly where the cost appears: everything above it
/// (readiness, argument assembly, ordering, failure classification, deleting the
/// cardholder's material afterwards) runs against a fake in milliseconds, and
/// everything below it is `OpenACProofBackend`, which is a translation layer
/// thin enough to read.
///
/// Note where the line falls. `generateInputs` needs no proving key at all — it
/// touches only the issuer certificate, the revocation snapshot and the two
/// strings from TW FidO — so it *could* have been called for real in a test. It
/// is behind the protocol anyway, because the thing worth asserting is what
/// arguments it receives, and a real call would only tell us that Rust accepted
/// them.
///
/// `Sendable` because the work is handed to a `DispatchQueue`: these calls block
/// for tens of seconds and must not occupy a cooperative pool thread.
protocol ProofBackend: Sendable {

    /// `generateCertChainRs4096Input`. Writes `cert_chain_rs4096_input.json` and
    /// `user_sig_rs2048_input.json` into `outputDirectory`.
    ///
    /// Returns nothing on purpose. The underlying function returns a path
    /// string, but `prove*` does not take it — it re-derives both file names
    /// from `documentsPath` — so the only thing worth checking is that the two
    /// files are there, which the caller does directly.
    func generateInputs(certificateBase64: String,
                        signedResponse: String,
                        relyingPartyIdentifier: String,
                        issuerCertificatePath: String,
                        revocationSnapshotPath: String?,
                        outputDirectory: String,
                        challenge: String) throws

    func proveCertificateChain(documentsPath: String) throws -> ProofMetrics

    func proveUserSignature(documentsPath: String) throws -> ProofMetrics
}

/// What one `prove*` call cost, in the units upstream reports them.
///
/// Milliseconds as `UInt64` rather than `TimeInterval` because that is what
/// `ProofResult.proveMs` is, and converting a measurement on the way through a
/// boundary is how a benchmark ends up off by a factor nobody can find.
struct ProofMetrics: Equatable, Sendable {
    let proveMilliseconds: UInt64
    let proofByteCount: UInt64
}

/// Which of the two circuits a failure came from.
enum ZKCircuit: String, Equatable, Sendable {
    case certificateChain = "cert_chain_rs4096"
    case userSignature = "user_sig_rs2048"
}

/// A backend failure, classified and **stripped of its message**.
///
/// `ZkProofError` carries a `msg: String` from Rust, and its `errorDescription`
/// is `String(reflecting: self)`, so the message travels anywhere the error
/// does. That message is written by code we do not control, on a path whose
/// inputs are a national-ID certificate and a signature over it — an
/// `InvalidInput(msg:)` echoing part of what it rejected is entirely plausible.
/// Translating to a closed set of cases here means the cardholder's material
/// cannot reach a log, an analytics event or a crash report by way of an error,
/// because after this line it is no longer in the error at all.
///
/// The cost is real and is accepted: when a proof fails in the field, this tells
/// us it was `.invalidInput` and not which field. The answer to that is a
/// diagnostic build that opts in, not a default that leaks.
enum ProofBackendFailure: Error, Equatable, Sendable {
    case fileNotFound
    case invalidInput
    case setupRequired
    case inputOutput
    case proofGenerationFailed
    case verificationFailed
    /// Not a `ZkProofError` at all — a Rust panic surfaced through UniFFI, or
    /// something thrown by the Swift shim.
    case unknown
}

// MARK: - Real backend

/// The production `ProofBackend`: OpenACSwift, and nothing else.
///
/// # Two decisions taken here, with their basis
///
/// **`setupKeys` is never called.** Upstream's README §1 says in bold to skip it
/// when the key files already exist, and `CircuitAssets` downloads exactly those
/// files. Calling it would additionally require `certChainRS4096.r1cs` and
/// `userSigRS2048.r1cs` — 77.7 MB more download and 823 MB more disk — to
/// regenerate, slowly and on a phone, blobs we already have. It is absent from
/// `ProofBackend` rather than present-and-unused so that adding it back is a
/// deliberate act.
///
/// (One trap noted while establishing this: `setupKeys` reads the `.r1cs` files
/// from `documentsPath/` — the *root*, per README's "R1CS files (directly in
/// `documentsPath/`)" and upstream's own tests — while `CircuitAssets.setupOnly`
/// lists them under `keys/`. Harmless today because nothing reads that list; it
/// will not be harmless the day someone enables it.)
///
/// **`smtSnapshotPath` is always supplied, never `nil`.** Upstream contradicts
/// itself here and the contradiction resolves against the parameter table:
///
///   * README's table says "reserved for future revocation support; pass `nil`".
///     That line is stale.
///   * README's usage example, twelve lines earlier, passes
///     `documentsPath + "/g3-tree-snapshot.json.gz"`.
///   * The doc comment on the function describes a parameter called `smt_proof`
///     — a name that is not in the signature. It is one revision behind: the
///     Rust side now takes the snapshot path and runs `create_smt_proof_from_gz`
///     itself.
///
/// The reason this matters more than a documentation nit: passing `nil` does not
/// fail. It produces an input file whose `smtRoot` is `"0"` and whose 128
/// siblings are all `"0"` — an empty-tree witness. The circuit is satisfied, the
/// proof generates, and it verifies locally. It is refused by any verifier that
/// compares `smtRoot` against the real on-chain root, which is the entire point
/// of the field. Silent degradation into a proof that is worthless in exactly
/// the situation it was made for is the worst available failure mode, so the
/// path is always passed and `ZKProver` refuses a result whose root came back
/// `"0"`.
///
/// The snapshot is handed over **still gzipped**; the library decompresses it
/// internally. `CircuitAssets` already installs it that way.
struct OpenACProofBackend: ProofBackend {

    func generateInputs(certificateBase64: String,
                        signedResponse: String,
                        relyingPartyIdentifier: String,
                        issuerCertificatePath: String,
                        revocationSnapshotPath: String?,
                        outputDirectory: String,
                        challenge: String) throws {
        do {
            // The return value is the path of the file it wrote. Discarded: the
            // caller checks for both files by name instead, because `prove*`
            // does not consult this value either.
            _ = try OpenACSwift.generateCertChainRs4096Input(
                certb64: certificateBase64,
                signedResponse: signedResponse,
                tbs: relyingPartyIdentifier,
                issuerCertPath: issuerCertificatePath,
                smtSnapshotPath: revocationSnapshotPath,
                outputDir: outputDirectory,
                challenge: challenge)
        } catch {
            throw ProofBackendFailure(error)
        }
    }

    func proveCertificateChain(documentsPath: String) throws -> ProofMetrics {
        do {
            let result = try OpenACSwift.proveCertChainRs4096(documentsPath: documentsPath)
            return ProofMetrics(proveMilliseconds: result.proveMs,
                                proofByteCount: result.proofSizeBytes)
        } catch {
            throw ProofBackendFailure(error)
        }
    }

    func proveUserSignature(documentsPath: String) throws -> ProofMetrics {
        do {
            let result = try OpenACSwift.proveUserSigRs2048(documentsPath: documentsPath)
            return ProofMetrics(proveMilliseconds: result.proveMs,
                                proofByteCount: result.proofSizeBytes)
        } catch {
            throw ProofBackendFailure(error)
        }
    }
}

extension ProofBackendFailure {

    /// Classify, and drop the message. No `default:` on the `ZkProofError`
    /// switch — if upstream adds a case, this stops compiling, which is the
    /// outcome we want: a new failure mode should be classified deliberately
    /// rather than silently folded into `.unknown`.
    ///
    /// Total by construction. Anything that is not a `ZkProofError` — a Rust
    /// panic surfaced through UniFFI, a `ProofBackend` implementation with its
    /// own error type — becomes `.unknown` rather than escaping the seam as a
    /// raw `Error` that the layer above has no case for.
    init(_ error: Error) {
        if let failure = error as? ProofBackendFailure {
            self = failure
            return
        }
        guard let zkError = error as? ZkProofError else {
            self = .unknown
            return
        }
        switch zkError {
        case .FileNotFound:
            self = .fileNotFound
        case .ProofGenerationFailed:
            self = .proofGenerationFailed
        case .VerificationFailed:
            self = .verificationFailed
        case .InvalidInput:
            self = .invalidInput
        case .SetupRequired:
            self = .setupRequired
        case .IoError:
            self = .inputOutput
        }
    }
}

// MARK: - Readiness

/// What the asset store says about the ~950 MB the prover needs.
///
/// Names rather than `CircuitAsset` values because the only thing done with them
/// is telling the user which rows to go and fix, and `displayName` is already
/// the localized string for that.
struct ZKAssetReadiness: Equatable, Sendable {

    /// Not downloaded.
    let missing: [String]

    /// Downloaded but past its refresh interval — only the revocation snapshot
    /// can be here. Treated exactly as severely as missing, and that is the
    /// point: a stale snapshot produces a proof built against yesterday's
    /// revocation set, which is a proof that is refused at the counter after
    /// everything on screen said ready.
    let stale: [String]

    var isReady: Bool { missing.isEmpty && stale.isEmpty }

    static let ready = ZKAssetReadiness(missing: [], stale: [])
}

// MARK: - Caveats

/// Something a proof from this app does **not** establish, carried alongside
/// every proof it produces.
///
/// These are values rather than paragraphs in a design document because the
/// alternative has a track record: a limitation that lives only in prose is one
/// screen away from being forgotten, and the screens here are the ones where a
/// person decides whether to believe a stranger's identity. Attaching them to
/// `ZKProofBundle` means a UI that wants to say 「已驗證」 has to walk past them
/// first.
/// The order of the cases is the order they are shown in, and it is deliberate:
/// the two that decide what this project may claim at all come first.
enum ProofCaveat: String, Equatable, Sendable, CaseIterable {

    /// **Present on every proof. The signing material is a bearer token that
    /// never changes and never expires.**
    ///
    /// TW FidO's SIGN flow does not sign the challenge. `TWFidOClient.signData`
    /// is `base64(UTF8(app_id))` and `app_id` is
    /// `TWFidOConfiguration.bondsAppID`, a constant — so the holder's RSA
    /// signature is over a fixed string, and `result.signed_response` is the
    /// same 256 bytes on the first round trip and on the thousandth. The
    /// challenge enters `generateCertChainRs4096Input` as a separate argument
    /// and is bound by the *circuit*, not by anything the cardholder signed.
    ///
    /// The consequence, stated plainly because it is the load-bearing one:
    /// **`(cert, signed_response)` is sufficient to mint a valid proof for any
    /// new challenge, forever, with no cardholder present and no round trip to
    /// 內政部.** The holder's signature is a *witness* — private input to the
    /// circuit — so replaying it never requires disclosing it, and a verifier
    /// cannot tell a replay from a fresh proof by looking at either proof.
    ///
    /// **Including 內政部 itself**, which is not a hypothetical: ATH-02 returns
    /// exactly `cert` and `signed_response` (`TWFidOSignResult`), so the issuer
    /// holds, for every cardholder who has ever used this app, material it can
    /// mint that cardholder's proofs from indefinitely. So does anyone who ever
    /// obtains one response — an SP operator, a compromised backup, anyone who
    /// reads it out of memory once.
    ///
    /// This is not a defect in this file and there is nothing here to fix. It is
    /// what the SIGN flow is; closing it needs 內政部 to sign a value the
    /// relying party chooses, which is a protocol change, not a code change.
    /// Until then, "this proof was made by the cardholder, now" is not something
    /// the proof supports, and this caveat is how that stops being a sentence in
    /// a design document.
    case signatureMaterialIsReplayable

    /// **Present on every proof. Making one discloses the cardholder to the
    /// issuer, in the clear.**
    ///
    /// The minimal disclosure is against the *verifier*, and only against the
    /// verifier. `TWFidOClient`'s SIGN body carries `id_num` (the raw
    /// 身分證統一編號, not a hash), `sp_service_id` and
    /// `sign_info.sign_data` — which is the relying-party identifier — in a
    /// single request. That is "this person, at this time, obtained signing
    /// material for this relying party", and it is complete: 內政部 sees every
    /// proof this app makes, tied to a national ID number, before the proof
    /// exists.
    ///
    /// So the honest framing is a *shift* of the disclosure rather than its
    /// removal: the counter clerk learns nothing, and the issuer learns
    /// everything. A screen that says 「不會顯示你的身分證字號」 without saying
    /// to whom is true about the clerk and false about 內政部, and a reader will
    /// take from it that nobody knows — which is the one reading that is wrong.
    ///
    /// Unconditional rather than conditional on this run having made the call:
    /// there is no path to a `ProvingInputs` that did not come from a TW FidO
    /// SIGN round trip at some point, and per
    /// `signatureMaterialIsReplayable` a reused response was still disclosed
    /// when it was first obtained.
    case idNumberDisclosedToIssuer

    /// **Present on every proof, and the one that most needs saying.**
    ///
    /// The circuit derives a nullifier from the relying-party identifier and the
    /// holder's key, so the same person proving twice to the same relying party
    /// produces the same nullifier — which is what would let a verifier reject a
    /// second use. Rejecting it requires a record of nullifiers already seen, and
    /// offline there is no shared record to consult. Two verifiers who never
    /// speak cannot both refuse the same nullifier.
    ///
    /// So "a real person" holds; "a real person, and only once" does not. This
    /// is not solved below this line, it is not solvable offline without
    /// something to synchronise against, and nothing in this codebase should
    /// read as though it were done.
    case noGlobalUniqueness

    /// Present on every proof. The circuit's inputs are moduli, signatures, a
    /// serial number and a Merkle witness — there is not one date field among
    /// them. An expired 自然人憑證, or an expired MOICA-G3, still produces a
    /// mathematically valid proof.
    ///
    /// The reference verifier checks validity dates when it *loads the issuer
    /// certificate*, server-side. Offline there is no such step, so the honest
    /// statement of what the proof asserts is "MOICA-G3 issued this", not "this
    /// is valid today".
    case certificateExpiryNotProven

    /// Present on every proof today. The revocation snapshot was applied, so the
    /// proof carries a real non-membership witness — but the snapshot's trust
    /// anchor is supposed to be the SMT root published on-chain, and
    /// `CircuitAssets` says plainly that comparing against it is not
    /// implemented. Whoever can publish to the snapshot repository can therefore
    /// serve one with revocations quietly dropped.
    case revocationRootNotAnchored

    /// Present when the challenge was minted on this device instead of supplied
    /// by the party doing the checking. The proof is then replayable: nothing in
    /// it distinguishes "made for you, now" from "made last week for someone
    /// else". See `ProofChallenge`.
    case challengeNotBoundToVerifier

    /// Whether this is a property of the design rather than of one run — i.e.
    /// whether it is on *every* proof this app can produce.
    ///
    /// A `switch` with no `default:` on purpose. Adding a case stops this
    /// compiling, and the question it then forces — "is this true of every proof
    /// or only of some?" — is the one that decides whether the caveat can be
    /// dropped from a screen. That is not a question to answer by omission.
    var isUnconditional: Bool {
        switch self {
        case .signatureMaterialIsReplayable, .idNumberDisclosedToIssuer,
             .noGlobalUniqueness, .certificateExpiryNotProven,
             .revocationRootNotAnchored:
            return true
        case .challengeNotBoundToVerifier:
            return false
        }
    }

    /// The caveats on every proof, in display order.
    ///
    /// One definition, read by `ZKProver.caveats(for:)`, by the screen's
    /// before-you-run section and by the report's completeness banner — so those
    /// three cannot drift apart, which is exactly how the screen came to promise
    /// 「序號不在撤銷清單裡」 before a run while the result afterwards said the
    /// revocation list had never been checked against anything authoritative.
    static var unconditional: [ProofCaveat] { allCases.filter(\.isUnconditional) }

    /// Shown next to the result. Every one of these is a sentence a verifier is
    /// entitled to read before deciding.
    ///
    /// Written for the person holding the phone, not for a cryptographer: the
    /// mechanism is in the doc comment on each case, and a caveat nobody can
    /// read is the same as no caveat.
    var localizedDescription: String {
        switch self {
        case .signatureMaterialIsReplayable:
            return NSLocalizedString(
                "The signature this proof is built from never changes and never expires. Anyone who has ever received a copy — 內政部 included — can keep making new proofs from it, on any device, without you.",
                comment: "Limitation attached to a zero-knowledge proof")
        case .idNumberDisclosedToIssuer:
            return NSLocalizedString(
                "內政部 is told your ID number and which service asked, every time a proof is made. This hides you from the person checking the proof, not from 內政部.",
                comment: "Limitation attached to a zero-knowledge proof")
        case .noGlobalUniqueness:
            return NSLocalizedString(
                "This proof cannot show whether the same identity has already been used elsewhere.",
                comment: "Limitation attached to a zero-knowledge proof")
        case .certificateExpiryNotProven:
            return NSLocalizedString(
                "This proves who issued the certificate, not that it is still valid today.",
                comment: "Limitation attached to a zero-knowledge proof")
        case .revocationRootNotAnchored:
            return NSLocalizedString(
                "The revocation list was applied but not checked against an authoritative source.",
                comment: "Limitation attached to a zero-knowledge proof")
        case .challengeNotBoundToVerifier:
            return NSLocalizedString(
                "Nothing ties this proof to the person checking it, so it could be shown again elsewhere.",
                comment: "Limitation attached to a zero-knowledge proof")
        }
    }
}

// MARK: - Result

/// A finished pair of proofs, what they cost, and what they do not prove.
struct ZKProofBundle: Equatable, Sendable {

    let certificateChain: ProofMetrics
    let userSignature: ProofMetrics

    /// Never empty — see `ProofCaveat`. In `ProofCaveat.allCases` order, so two
    /// runs are comparable.
    let caveats: [ProofCaveat]

    /// `<workingDirectory>/keys`, where the two `*_proof.bin` and
    /// `*_instance.bin` files were left. The witnesses that were also written
    /// there are gone by the time this exists.
    let proofDirectory: URL

    /// Saturating, not wrapping, and above all not trapping.
    ///
    /// Both addends are `UInt64`s handed over by Rust and validated by nobody:
    /// `ProofResult.proveMs` is whatever upstream put in it. `+` on `UInt64`
    /// traps on overflow, and the place it would trap is not the FFI boundary —
    /// it is here, read while the result screen is being drawn, i.e. *after* a
    /// proof that took thirty seconds and two gigabytes succeeded. Losing the
    /// run to a bad integer from a dependency is not a trade worth making, and
    /// `UInt64.max` in a row that already renders 0 as "not reported" is a
    /// number no reader will mistake for a measurement.
    ///
    /// Same treatment as `ZKVerificationOutcome.totalMilliseconds`, which is the
    /// sibling total on the verification side.
    var totalProveMilliseconds: UInt64 {
        let (total, overflow) = certificateChain.proveMilliseconds
            .addingReportingOverflow(userSignature.proveMilliseconds)
        return overflow ? UInt64.max : total
    }

    /// Saturating for the same reason as `totalProveMilliseconds`:
    /// `ProofResult.proofSizeBytes` is not ours either.
    var totalProofByteCount: UInt64 {
        let (total, overflow) = certificateChain.proofByteCount
            .addingReportingOverflow(userSignature.proofByteCount)
        return overflow ? UInt64.max : total
    }
}

// MARK: - Errors

/// Why a proof did not happen.
///
/// The split that matters, and the reason this is not one `.proofFailed` case:
/// **"the files are not downloaded yet" and "the proof failed" want opposite
/// responses.** The first is a 950 MB download the user can go and finish, after
/// which the same request succeeds; the second means retrying costs another
/// thirty seconds and two gigabytes to fail again. Collapsing them produces a
/// screen that tells someone who has simply not finished preparing that their
/// certificate is broken. `isRecoverable` is the machine-readable form of that
/// distinction.
enum ZKProofError: Error, Equatable {

    /// A proof is already running. Not a queue: the prover holds ~2 GB and
    /// upstream documents a heap-corruption crash when RS4096 witnesses are
    /// generated twice in one process, so a second concurrent run is refused
    /// rather than serialised behind the first.
    case alreadyProving

    /// Recoverable. Names are `CircuitAsset.displayName`s.
    case assetsNotReady(missing: [String], stale: [String])

    /// Recoverable. `MOICA-G3.cer` is not in the working directory. Separate
    /// from `assetsNotReady` because it is not a download — it ships in the app
    /// bundle and is copied into place — so the fix is different even though the
    /// sentence shown is the same.
    case issuerCertificateMissing

    /// Recoverable. `g3-tree-snapshot.json.gz` is not in the working directory.
    case revocationSnapshotMissing

    /// The working directory could not be created, or its Data Protection class
    /// and backup exclusion could not be applied. Fatal by design: this is the
    /// step that decides whether the cardholder's certificate is about to be
    /// written somewhere it can be read off a locked phone or copied into an
    /// iCloud backup, and `CredentialStore` refuses to exist when the same call
    /// fails.
    case workingDirectoryUnavailable

    /// Our own pre-flight checks refused the material. Never reached the backend.
    case inputsRejected(ProvingInputError)

    case inputGenerationFailed(ProofBackendFailure)

    /// `generateInputs` returned without throwing and the files are not there.
    case inputsNotWritten(missing: [String])

    /// The generated input carries `smtRoot == "0"`, i.e. an empty-tree witness:
    /// the revocation check silently became a no-op despite a snapshot being
    /// supplied. See `OpenACProofBackend` for why this is refused rather than
    /// warned about.
    case revocationCheckDegraded

    case proofFailed(circuit: ZKCircuit, reason: ProofBackendFailure)

    /// Whether finishing the preparation the app already asks for would make the
    /// same request succeed.
    var isRecoverable: Bool {
        switch self {
        case .assetsNotReady, .issuerCertificateMissing, .revocationSnapshotMissing:
            return true
        case .inputGenerationFailed(let reason), .proofFailed(_, let reason):
            // A file vanished between the readiness check and the call — a
            // purge, an interrupted download, a snapshot deleted to reclaim
            // space. Downloading it again is exactly the fix.
            return reason == .fileNotFound
        case .alreadyProving, .workingDirectoryUnavailable, .inputsRejected,
             .inputsNotWritten, .revocationCheckDegraded:
            return false
        }
    }
}

extension ZKProofError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .alreadyProving:
            return NSLocalizedString("This device is already creating a proof.", comment: "")

        case .assetsNotReady, .issuerCertificateMissing, .revocationSnapshotMissing:
            return NSLocalizedString(
                "The offline verification files aren't ready yet. Finish preparing them, then try again.",
                comment: "")

        case .inputsRejected(let error):
            return error.errorDescription

        case .revocationCheckDegraded:
            // Deliberately not the generic sentence. This one is not "something
            // went wrong": the proof would have been produced and then refused,
            // and telling the user to try again would produce the same useless
            // proof a second time.
            return NSLocalizedString(
                "The certificate revocation list was not applied, so this proof would be refused.",
                comment: "")

        case .inputGenerationFailed(let reason) where reason == .fileNotFound:
            return NSLocalizedString(
                "The offline verification files aren't ready yet. Finish preparing them, then try again.",
                comment: "")

        case .workingDirectoryUnavailable, .inputGenerationFailed, .inputsNotWritten, .proofFailed:
            // One sentence covering every genuine failure below the seam. The
            // holder cannot act on which circuit or which Rust error it was, and
            // the classification is preserved in the case for a bug report.
            return NSLocalizedString("The proof could not be created on this device.", comment: "")
        }
    }
}

// MARK: - Prover

/// Runs one proof, end to end.
///
/// An `actor` for two reasons that are not interchangeable: it serialises access
/// to `isProving`, and it makes "one at a time" enforceable at all. Proving holds
/// roughly two gigabytes — upstream's own mobile benchmark reports a peak of
/// 1.96–2.27 GiB — which is at or above the jetsam ceiling for a 4 GB iPhone. Two
/// at once is not slow, it is a kill.
///
/// # What this does not do
///
/// **It does not verify.** `verifyCertChainRs4096`, `verifyUserSigRs2048` and
/// `linkVerify` all read `keys/*_verifying.key`, and `CircuitAssets` deliberately
/// does not download those — the note there records that each verifying key is a
/// byte-identical 32-bytes-shorter prefix of its proving key, so they can be
/// derived rather than fetched, and that derivation is not written yet. Until it
/// is, on-device verification is not reachable, and `linkVerify` is precisely the
/// seam the whitepaper's offline story depends on. This is the single largest
/// open risk in M2 and it lives one module over, not here.
actor ZKProver {

    // MARK: Artifact names
    //
    // Read out of the shipped static library rather than guessed:
    //   strings libopenac_mobile_app.a | grep -oE '(cert_chain_rs4096|user_sig_rs2048)[A-Za-z0-9_.]*'
    // which yields the input, proof, instance and witness names below. The
    // `keys/` prefix is from upstream's README ("Key files (in
    // `documentsPath/keys/`)") and matches `CircuitAssets.required`.

    /// Written by `generateInputs`, read by `prove*`. **Contains the
    /// cardholder's certificate**, expanded into circuit limbs.
    static let inputFilenames = [
        "cert_chain_rs4096_input.json",
        "user_sig_rs2048_input.json"
    ]

    /// Written by `prove*`. **The witness is the secret**: it is the assignment
    /// of every wire in the circuit, private inputs included, and for
    /// `certChainRS4096` it is about 62 MB of it. Leaving it on disk would undo
    /// the whole point of a zero-knowledge proof — the proof reveals nothing and
    /// the file next to it reveals everything.
    ///
    /// Deleted after proving. The assumption that makes this safe is that
    /// verification never reads a witness, which is true by definition of what a
    /// witness is; if a future `linkVerify` turns out to need one, that is an
    /// upstream defect and this deletion is where it will surface.
    static let witnessFilenames = [
        "keys/cert_chain_rs4096_witness.bin",
        "keys/user_sig_rs2048_witness.bin"
    ]

    /// The deliverable. Kept.
    static let proofFilenames = [
        "keys/cert_chain_rs4096_proof.bin",
        "keys/user_sig_rs2048_proof.bin"
    ]

    /// Public inputs, needed by whoever verifies. Kept.
    static let instanceFilenames = [
        "keys/cert_chain_rs4096_instance.bin",
        "keys/user_sig_rs2048_instance.bin"
    ]

    /// Where `generateCertChainRs4096Input` records the Merkle root it built the
    /// non-membership witness against. `"0"` means it built none.
    static let revocationRootKey = "smtRoot"

    /// Same name `CircuitAssets` installs it under.
    static let revocationSnapshotFilename = "g3-tree-snapshot.json.gz"

    // MARK: State

    private let workingDirectory: URL
    private let readiness: @Sendable () async -> ZKAssetReadiness
    private let backend: any ProofBackend
    private let fileManager = FileManager.default

    /// The actor alone does not give us this: `prove` suspends at every `await`,
    /// which lets a second call straight in. Same reasoning as
    /// `CircuitAssets.inFlight`.
    private var isProving = false

    /// Proving blocks its thread for tens of seconds. On the cooperative pool
    /// that starves everything else in the app; the pool has one thread per core
    /// and the prover is already using all of them through rayon. A dedicated
    /// serial queue also enforces one-at-a-time a second time, below the
    /// `isProving` flag.
    private static let queue = DispatchQueue(label: "tw.bonds.backupTW.zkProver",
                                             qos: .userInitiated)

    // MARK: Construction

    /// Injection point. `readiness` is a closure rather than a protocol so that
    /// a test can describe a half-prepared install in one line without standing
    /// up an asset store.
    init(workingDirectory: URL,
         readiness: @escaping @Sendable () async -> ZKAssetReadiness,
         backend: any ProofBackend) {
        self.workingDirectory = workingDirectory
        self.readiness = readiness
        self.backend = backend
    }

    /// The production wiring.
    ///
    /// Written out rather than delegating to the initialiser above: an actor's
    /// initialisers are all designated, so `self.init` is not available here.
    init(assets: CircuitAssets, backend: any ProofBackend = OpenACProofBackend()) {
        self.workingDirectory = assets.workingDirectory
        self.readiness = {
            // Two hops rather than one so that "not downloaded" and "downloaded
            // but stale" stay separable all the way to the error the user sees.
            let missing = await assets.missingAssets().map(\.displayName)
            let stale = await assets.staleAssets().map(\.displayName)
            return ZKAssetReadiness(missing: missing, stale: stale)
        }
        self.backend = backend
    }

    // MARK: Proving

    /// Produces both proofs, or explains why it could not.
    ///
    /// The order is fixed and each step has its own failure:
    ///
    ///  1. clear anything an earlier run left behind;
    ///  2. refuse if the assets are missing or stale — **recoverable**, and
    ///     checked before the backend is touched at all;
    ///  3. re-assert the working directory's Data Protection class and backup
    ///     exclusion, because the next step writes the cardholder's certificate
    ///     into it;
    ///  4. assemble and write the circuit inputs;
    ///  5. confirm both files exist and that the revocation witness is real;
    ///  6. prove `cert_chain_rs4096`, then `user_sig_rs2048`;
    ///  7. delete the inputs and the witnesses, whatever happened.
    ///
    /// Step 7 runs on every exit path including a thrown error, which is why it
    /// is a `defer` registered before anything can fail.
    func prove(_ inputs: ProvingInputs) async throws -> ZKProofBundle {
        guard !isProving else { throw ZKProofError.alreadyProving }
        isProving = true
        defer { isProving = false }

        // Registered here, before the first thing that can throw, so that no
        // failure path can leave the cardholder's material on disk.
        defer { discardSecretArtifacts() }

        // A previous run that crashed, or was killed by jetsam mid-proof, leaves
        // inputs and a witness behind. Clearing the stale proof and instance
        // files too means a failure below cannot leave last week's proof sitting
        // where this run's was going to go, looking current.
        discardStaleArtifacts()

        let status = await readiness()
        guard status.isReady else {
            throw ZKProofError.assetsNotReady(missing: status.missing, stale: status.stale)
        }

        do {
            // Not merely `createDirectory`: this is what applies
            // `.completeUnlessOpen` and `isExcludedFromBackup`, and it is
            // re-asserted on every proof rather than once at install, because
            // the directory can be recreated by a restore or a purge. Step 4
            // writes a national-ID certificate into it.
            try CircuitAssets.prepareDirectories(at: workingDirectory, fileManager: fileManager)
        } catch {
            throw ZKProofError.workingDirectoryUnavailable
        }

        let issuerCertificate = workingDirectory
            .appendingPathComponent(CircuitAssets.issuerCertificateFilename)
        guard fileManager.fileExists(atPath: issuerCertificate.path) else {
            throw ZKProofError.issuerCertificateMissing
        }

        let snapshot = workingDirectory.appendingPathComponent(Self.revocationSnapshotFilename)
        guard fileManager.fileExists(atPath: snapshot.path) else {
            throw ZKProofError.revocationSnapshotMissing
        }

        let challenge: String
        do {
            challenge = try inputs.challengeFieldElement()
        } catch let error as ProvingInputError {
            throw ZKProofError.inputsRejected(error)
        }

        // Copied out of `self` under different names, because the closures below
        // run on a `DispatchQueue` and must not capture the actor.
        let proofBackend = self.backend
        let documentsPath = workingDirectory.path
        let issuerPath = issuerCertificate.path
        let snapshotPath = snapshot.path

        do {
            try await offload {
                try proofBackend.generateInputs(
                    certificateBase64: inputs.certificateBase64,
                    signedResponse: inputs.signedResponse,
                    relyingPartyIdentifier: inputs.relyingPartyIdentifier,
                    issuerCertificatePath: issuerPath,
                    // Never nil. See `OpenACProofBackend`.
                    revocationSnapshotPath: snapshotPath,
                    // Must equal the `documentsPath` handed to `prove*`: that is
                    // where `prove*` looks for the two input files, and it does
                    // not take the path this call returns.
                    outputDirectory: documentsPath,
                    challenge: challenge)
            }
        } catch {
            throw ZKProofError.inputGenerationFailed(ProofBackendFailure(error))
        }

        let absent = Self.inputFilenames.filter {
            !fileManager.fileExists(atPath: workingDirectory.appendingPathComponent($0).path)
        }
        guard absent.isEmpty else {
            throw ZKProofError.inputsNotWritten(missing: absent)
        }

        guard revocationWitnessIsReal() else {
            throw ZKProofError.revocationCheckDegraded
        }

        let certificateChain = try await runProof(circuit: .certificateChain) {
            try proofBackend.proveCertificateChain(documentsPath: documentsPath)
        }
        let userSignature = try await runProof(circuit: .userSignature) {
            try proofBackend.proveUserSignature(documentsPath: documentsPath)
        }

        return ZKProofBundle(certificateChain: certificateChain,
                             userSignature: userSignature,
                             caveats: Self.caveats(for: inputs.challenge),
                             proofDirectory: workingDirectory.appendingPathComponent("keys",
                                                                                     isDirectory: true))
    }

    /// Everything this proof fails to establish.
    ///
    /// Five of the six are unconditional, and they are unconditional because
    /// they are properties of the design rather than of a particular run. A
    /// caller that finds this list inconveniently long is being told something
    /// true.
    static func caveats(for challenge: ProofChallenge) -> [ProofCaveat] {
        var caveats = ProofCaveat.unconditional
        if !challenge.boundToVerifier {
            caveats.append(.challengeNotBoundToVerifier)
        }
        // Fixed order, so two bundles are comparable and a test can pin it.
        return ProofCaveat.allCases.filter { caveats.contains($0) }
    }

    // MARK: Cleanup

    /// Removes the cardholder's material: the two input JSONs and the two
    /// witnesses. Leaves the proofs and instances, which are the deliverable and
    /// are meant to be handed to whoever checks them.
    ///
    /// **This is cleanup around one proof, not an erase.** It used to say that
    /// an erase-everything path could call it directly; nothing did, and the
    /// sentence quietly stood in for the feature. "Erase all local data" now
    /// sweeps `LocalDataEraser.proofArtifactFilenames`, which is composed from
    /// the four static lists above — so a file added there still reaches the
    /// erase — and it is a strict superset of this one on purpose: the instances
    /// carry the nullifier, a stable pseudonym for this holder at this relying
    /// party, which is precisely what a user asking to be forgotten is asking to
    /// be rid of. Keeping it here would mean a proof that runs after the erase
    /// is linkable to one from before it.
    ///
    /// Deletion is enough for the reason `CredentialStore.deleteAll` gives: the
    /// contents are sealed under a per-file Data Protection key kept in the
    /// file's own metadata, and unlinking discards it. Overwriting first would be
    /// theatre on flash.
    func discardSecretArtifacts() {
        for name in Self.inputFilenames + Self.witnessFilenames {
            try? fileManager.removeItem(at: workingDirectory.appendingPathComponent(name))
        }
    }

    /// The above, plus the previous run's proof and instance files.
    ///
    /// Run before proving, never after: if step 6 fails, the old proof must not
    /// still be sitting there for a caller to pick up and present as this run's
    /// result.
    func discardStaleArtifacts() {
        discardSecretArtifacts()
        for name in Self.proofFilenames + Self.instanceFilenames {
            try? fileManager.removeItem(at: workingDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Checks

    /// Whether the generated input carries a real non-membership witness.
    ///
    /// Reads exactly one field — `smtRoot`, a public Merkle root that identifies
    /// nobody — out of a file that otherwise holds the cardholder's certificate
    /// expanded into limbs. Nothing from this file is returned, logged or put in
    /// an error.
    ///
    /// A file that cannot be read or parsed counts as *not real*: "we could not
    /// confirm the revocation check happened" and "it did not happen" deserve the
    /// same answer, and the alternative is treating an unreadable file as a pass.
    private func revocationWitnessIsReal() -> Bool {
        let url = workingDirectory
            .appendingPathComponent(Self.inputFilenames[0])
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let root = object[Self.revocationRootKey] as? String else {
            return false
        }
        // "0" is what an empty-tree witness produces, and every shipped fixture
        // that skipped the snapshot has exactly this value.
        return root != "0"
    }

    // MARK: Plumbing

    private func runProof(circuit: ZKCircuit,
                          _ body: @escaping @Sendable () throws -> ProofMetrics) async throws -> ProofMetrics {
        do {
            return try await offload(body)
        } catch {
            throw ZKProofError.proofFailed(circuit: circuit,
                                           reason: ProofBackendFailure(error))
        }
    }

    /// Runs a blocking call on the prover queue.
    ///
    /// No cancellation hook, unlike `CircuitAssets.offload`, and that is a
    /// statement of fact rather than an omission: the FFI call is a single
    /// synchronous entry into Rust with no progress callback and nothing to
    /// check a flag from. A proof, once started, finishes or the process dies.
    /// The way to not spend thirty seconds is to not start.
    private func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Self.queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
