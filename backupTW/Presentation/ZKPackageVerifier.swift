//
//  ZKPackageVerifier.swift
//  backupTW
//
//  Checking a ZK proof that somebody else produced.
//

import Foundation

/// What checking somebody else's ZK proof established, and what it cost.
struct ZKPackageVerdict: Equatable {

    /// All three upstream checks passed. The only state that may be drawn as
    /// an acceptance.
    let accepted: Bool

    let outcome: ZKVerificationOutcome?

    /// Carried from the package, not recomputed. Never empty in practice — see
    /// `ProofCaveat` — and a screen that shows `accepted` without these is
    /// overstating what happened.
    let caveats: [ProofCaveat]

    /// The producing device's own claim about its own proof. Advisory: it comes
    /// from the party being checked.
    let producerSelfCheckPassed: Bool

    let seconds: Double
    let byteCount: Int
}

enum ZKPackageVerificationError: Error, Equatable {

    /// The verifying keys are not on this device. **Says nothing about the
    /// proof** — the same distinction `ZKSelfCheck.notPerformed` exists to keep.
    /// A verifier that rendered this as a rejection would be telling a holder
    /// their certificate is bad because the verifier had not finished setting up.
    case verifyingKeysMissing([String])

    /// The package could not be read or laid out.
    case unusablePackage(String)

    /// The check ran and could not reach a verdict — see
    /// `ZKSelfCheck.inconclusive`. Also says nothing about the proof.
    case inconclusive(String)
}

extension ZKPackageVerificationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .verifyingKeysMissing:
            // ⚠️ No 「yet」 here. This is the generic description, reached from
            // anywhere; the two situations 「not downloaded yet」 and 「this
            // version cannot download them」 are told apart by
            // `ZKCheckingAvailability`, which is what the screens render.
            return NSLocalizedString(
                "This device does not have the files needed to check a proof.", comment: "")
        case .unusablePackage:
            return NSLocalizedString("This proof file could not be read.", comment: "")
        case .inconclusive:
            return NSLocalizedString(
                "The check ran but could not reach a verdict.", comment: "ZK stage detail")
        }
    }
}

/// Runs the three upstream checks against a proof this device did not make.
///
/// # Why this is separate from `ZKProver.verifyOnThisDevice`
///
/// That one is a *self*-check: the prover refusing to hand back work it can see
/// is bad. This one is the actual verifier role — different inputs (a package
/// off the wire rather than a directory it just wrote), different failure
/// meanings (a missing verifying key here is the verifier's own setup problem,
/// not the holder's), and different consequences for getting it wrong.
///
/// # What it costs, measured
///
/// `VerifierCostSpike` on 2026-08-08: 14.47 s cold, 12.21 s warm, on the
/// simulator against real proofs. The 15% gap is the important part — reading
/// all 968 MB of verifying keys cold, bypassing the page cache, takes 0.59 s, so
/// this is compute and not I/O. **Preloading the keys does not help**, and
/// holding them resident is not available on a phone. Anyone tempted to add a
/// cache here should read that measurement first.
struct ZKPackageVerifier {

    private let verifier: any ZKProofVerifying
    private let assetDirectory: URL

    /// Where a serial queue would go if this ever gets called concurrently. It
    /// does not: the caller offloads, exactly as `ZKProver` does, because these
    /// calls block for tens of seconds and must not occupy a cooperative pool
    /// thread.
    init(verifier: any ZKProofVerifying = OpenACProofVerifier(),
         assetDirectory: URL) {
        self.verifier = verifier
        self.assetDirectory = assetDirectory
    }

    /// Checks a package, using this device's verifying keys.
    ///
    /// The scratch directory is created fresh and removed afterwards even on the
    /// failure paths: a verifier's device should not accumulate other people's
    /// identity proofs, and the previous holder's artifacts must not be sitting
    /// there to be picked up as the next holder's.
    func verify(_ package: ZKProofPackage) throws -> ZKPackageVerdict {
        try package.validate()

        // Asked before anything is written, so "you have not downloaded the
        // checking files" cannot be reported as a bad proof.
        //
        // `missingArtifacts` also lists the proof and instance files, which are
        // legitimately absent here — they arrive in the package, not on this
        // device — so they are filtered out. What is left is the verifying keys,
        // and those really are this verifier's own missing setup.
        let missing = verifier.missingArtifacts(in: assetDirectory).filter { path in
            !ZKProofPackage.artifactNames.contains { path.hasSuffix($0) }
        }
        guard missing.isEmpty else {
            throw ZKPackageVerificationError.verifyingKeysMissing(missing)
        }

        let scratch = assetDirectory
            .appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // The verifying keys live in `assetDirectory/keys`, and upstream resolves
        // both the keys and the proof from the *same* documents path. So the
        // scratch directory gets the proof artifacts and symlinked keys rather
        // than a 968 MB copy.
        do {
            try package.write(into: scratch)
            try linkVerifyingKeys(into: scratch)
        } catch {
            throw ZKPackageVerificationError.unusablePackage(String(describing: error))
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let outcome: ZKVerificationOutcome
        do {
            outcome = try verifier.verify(documentsPath: scratch.path)
        } catch {
            // Same classification as `ZKProver.verifyOnThisDevice`, and for the
            // same reason: upstream returns "no" by throwing, and everything not
            // on the rejection allowlist is "we cannot tell" rather than "bad".
            guard ProofBackendFailure(error).isRejection else {
                throw ZKPackageVerificationError.inconclusive(String(describing: error))
            }
            return ZKPackageVerdict(accepted: false,
                                    outcome: nil,
                                    caveats: package.caveatsToDisplay,
                                    producerSelfCheckPassed: package.producerSelfCheckPassed,
                                    seconds: Self.seconds(since: start),
                                    byteCount: package.totalByteCount)
        }

        return ZKPackageVerdict(accepted: outcome.isFullyValid,
                                outcome: outcome,
                                caveats: package.caveatsToDisplay,
                                producerSelfCheckPassed: package.producerSelfCheckPassed,
                                seconds: Self.seconds(since: start),
                                byteCount: package.totalByteCount)
    }

    /// Symlinks rather than copies: the two verifying keys are 968 MB, and a
    /// verifier that copied them per presentation would spend a second and a
    /// gigabyte per person in the queue.
    private func linkVerifyingKeys(into scratch: URL) throws {
        let destination = scratch.appendingPathComponent("keys", isDirectory: true)
        for asset in ZKVerifyingKeyAssets.all {
            let name = (asset.localFilename as NSString).lastPathComponent
            let source = assetDirectory.appendingPathComponent(asset.localFilename)
            let target = destination.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}


/// Why this phone can or cannot check a proof, in one place.
///
/// # 「Yet」 is a promise, and a shipped build never keeps it
///
/// The home row already told the two apart. The screen that actually checks
/// proofs did not: its `.failure` branch printed `localizedDescription`
/// unclassified, so 「this phone does not have the files needed to check a proof
/// **yet**」 arrived **after** 400 KB had crossed. At that moment the cheapest,
/// most obvious and most wrong inference available is 「send it again」 — a
/// retry costs a tap here and another twenty-two seconds of Bluetooth on the
/// other person's phone.
///
/// The screen says the true, permanent thing at load — 「this version cannot
/// download the files … tell them before they send one」 — and `show()` rewrites
/// both labels, so by the only moment that matters the permanent truth had been
/// replaced by a temporary tense.
///
/// The only path that writes verifying keys sits behind
/// `ZKProofRunAssembly.makeSigner`, which is nil in a release build, and no
/// `.key` ships in the bundle. So on the App Store this is not an edge case, it
/// is the permanent state.
enum ZKCheckingAvailability: Equatable, Sendable {

    /// The files are on this phone.
    case ready
    /// Not downloaded, but this build can download them.
    case notDownloadedYet
    /// This build has no way to get them at all.
    case impossibleInThisBuild

    static var current: ZKCheckingAvailability {
        if ZKVerifyingKeyAssets.areInstalled { return .ready }
        return ZKProofRunAssembly.isSigningAvailable ? .notDownloadedYet : .impossibleInThisBuild
    }

    var canCheck: Bool { self == .ready }

    /// What the checking screen says when it cannot reach a verdict for this
    /// reason. Same split as the home row's subtitle, and asked of the same two
    /// flags.
    var sentence: String {
        switch self {
        case .ready:
            // Reached when the files are present and the check still could not
            // run — a path problem, not a download one.
            return NSLocalizedString(
                "The checking files are on this phone, but they could not be opened.", comment: "")
        case .notDownloadedYet:
            return NSLocalizedString(
                "The large checking files have not been downloaded to this phone yet, so a proof sent here cannot be checked.",
                comment: "")
        case .impossibleInThisBuild:
            return NSLocalizedString(
                "This version cannot download the files needed to check a proof, so a proof sent here cannot be checked. Say so before they send one.",
                comment: "")
        }
    }
}
