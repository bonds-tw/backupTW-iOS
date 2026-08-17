//
//  WallSignRun.swift
//  backupTW
//
//  The order things happen in when somebody signs the wall.
//

import Foundation

/// The stages of signing the wall.
///
/// # A parallel enum, not more cases on `ZKRunStage`
///
/// `ZKProofViewController.stageGroup()` expands `ZKRunStage.allCases`, so adding
/// a case there would draw a row on the proof screen that never moves. The two
/// flows overlap in the middle and differ at both ends.
enum WallSignStage: String, CaseIterable, Equatable, Sendable {
    /// ~950 MB of proving material. Happens **before any clock exists**.
    case files
    /// The clock starts here.
    case challenge
    /// TW FidO, up to 600 seconds.
    case signature
    case proof
    /// Only when the verifying keys are on this phone.
    case selfCheck
    case submission
}

/// How signing ended.
///
/// # `.unknown` is a first-class outcome, not a kind of failure
///
/// The wall deliberately stores nothing that identifies a signature, so "did
/// mine count?" is permanently unanswerable **by design**. Drawing that as a
/// failure would be lying in the direction that looks safe — and the person
/// would then sign again.
enum WallSignOutcome: Equatable, Sendable {
    case published(signatureCount: Int?)
    /// The wall's verifier ran and said no.
    case refused(selfCheckPassedHere: Bool?)
    /// Stopped before anything could have been recorded.
    case notAccepted(WallError)
    /// It went out. The answer did not come back.
    case unknown(WallError)
}

/// The order, and why it is this order.
///
/// Chosen so the cheapest and most likely failures happen first, and so that
/// nothing expensive runs inside a clock that can expire.
enum WallSignPlan {

    /// Whether the ~950 MB of proving material must be ready before a challenge
    /// is fetched.
    ///
    /// **Always true, and it is the ordering decision that matters most.** The
    /// download can take an hour; the challenge lives thirty minutes. Fetching
    /// the number first would guarantee that a first-time signer on a slow
    /// connection watches their challenge die, and then pays for a new one with
    /// another 身分證統一編號 disclosure to 內政部.
    static let filesBeforeClock = true

    /// How many times to ask for a challenge before giving up.
    ///
    /// Two. If the wall hands out a token with less than
    /// `WallChallenge.minimumUsableToStart` left twice running, its TTL is
    /// misconfigured — that is not a condition anybody retries their way out of,
    /// and each attempt is a request somebody's address is attached to.
    static let challengeAttempts = 2

    /// Maps a proof-run stage onto a wall stage.
    ///
    /// Total, with **no `default:`**, so that adding a `ZKRunStage` fails to
    /// compile here rather than silently landing in a bucket somebody has to
    /// notice on screen.
    static func stage(for stage: ZKRunStage) -> WallSignStage {
        switch stage {
        case .assets: return .files
        case .signature: return .signature
        case .proof: return .proof
        case .verification: return .selfCheck
        }
    }

    /// Whether a finished run may be sent to the wall.
    ///
    /// # The phone checking its own proof is worth something here
    ///
    /// On the ZK screen a failed self-check is information. Here it is a
    /// decision: if this device produced a proof and then **refused it itself**,
    /// sending it spends the challenge — and a new one costs another round trip
    /// to 內政部. So a proof this phone will not accept never leaves it.
    ///
    /// `.unavailable` is not a refusal. The verifying keys are optional, and a
    /// phone that never checked has learned nothing either way.
    static func maySubmit(selfCheck: ZKRunStageState) -> Bool {
        switch selfCheck {
        case .failed:
            return false
        case .unavailable, .succeeded, .running, .waiting:
            return true
        }
    }

    /// What to do with a run's artifacts once the wall has answered.
    ///
    /// **Delete all four, whatever the outcome.**
    ///
    /// The two `*_instance.bin` files carry a directly parseable nullifier —
    /// `ZKProver` says in its own words that they are what somebody asking to be
    /// forgotten would want rid of. The wall path has no export and no Bluetooth
    /// send, so nothing downstream reads them. Leaving them behind means a
    /// political act ends with a linkable handle sitting on the device.
    ///
    /// The proof screen keeps its own, deliberately: it offers an export, so
    /// there the files are the deliverable.
    static let artifactsToDeleteAfterwards = ZKProver.proofFilenames + ZKProver.instanceFilenames
}
