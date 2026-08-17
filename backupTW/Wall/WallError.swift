//
//  WallError.swift
//  backupTW
//
//  What went wrong, and — separately — what trying again would cost.
//

import Foundation

/// What it costs to try again.
///
/// # Why this is a property of the outcome and not of the error
///
/// The same `URLError.timedOut` means two different things depending on which
/// call it came from. On the challenge fetch nothing has been spent: try again
/// freely. On the submit it is genuinely ambiguous — the wall may have
/// published — so trying again may add a second signature, and a second
/// signature costs another 身分證統一編號 disclosure to 內政部 plus a duplicate
/// on a wall whose count is supposed to mean something.
///
/// An `Error` cannot carry that distinction, because the distinction is not
/// about what failed. So it travels beside the error.
enum WallRetryCost: Equatable, Sendable {

    /// The challenge is still alive and the proof is still in memory. **The same
    /// bytes can go again**, with no new round trip to 內政部.
    ///
    /// This case exists because a review pointed out that collapsing it into
    /// `startOver` would charge people for the wall's problems: a rate limit, a
    /// spent budget, a switched-off service. None of those touch
    /// `claimChallenge`, so none of them burn anything.
    case resend

    /// A new challenge is needed, which means proving again, which means the
    /// 身分證統一編號 goes to 內政部 again.
    case startOver

    /// We do not know whether it went through. Trying again may publish twice.
    case mightDuplicate

    /// Nothing to retry.
    case none
}

/// Everything that can stop a wall signature, in the words the screen uses.
enum WallError: Error, Equatable {

    // MARK: Nothing was spent

    /// The name did not resolve.
    ///
    /// Its own case rather than "check your connection", because that sentence
    /// sends somebody to look at their Wi-Fi for a problem that is ours. It was
    /// the single most likely failure while the wall's hostname was undecided,
    /// and it stays reachable: a DNS outage, a captive portal that NXDOMAINs.
    case hostDoesNotExist

    /// No usable network.
    case offline

    /// The wall answered something this app cannot read.
    case unreadableReply

    /// The wall is not accepting signatures at the moment.
    case unavailable

    /// Too many attempts from this address.
    case rateLimited

    /// The wall has spent today's verification budget.
    case budgetSpent

    /// The challenge could not be had, or was already dead on arrival.
    case challengeUnusable

    // MARK: The challenge is gone

    /// This challenge has already been spent.
    case challengeAlreadyUsed

    /// The wall could not reach its verifier. The challenge is gone with it.
    case verifierUnavailable

    /// The verifier ran and refused the proof.
    case refused

    // MARK: We do not know

    /// The submit call ended in a way that does not say whether it landed.
    ///
    /// **The most expensive branch, so it is the default for anything
    /// unrecognised.** The wall writes the signature *before* it reads the
    /// board back, and reading the board runs two more database queries — so a
    /// reply that is not JSON, or a status nobody enumerated, is genuinely
    /// consistent with "it published and then fell over". Reporting that as
    /// "nothing happened" would invite a second signature.
    case unknownWhetherPublished

    /// A proof this app will not send: larger than any real proof.
    ///
    /// Refused locally on purpose. Go answers 413 over 2 MiB, the Worker
    /// collapses every non-2xx from the verifier into `verifier-unavailable`,
    /// and that branch has already spent the challenge. Refusing here keeps it.
    case proofTooLarge(bytes: Int)

    /// This build cannot make a proof at all, so it cannot sign.
    case cannotProveInThisBuild

}

/// Whether the app may tell somebody that nothing reached the wall.
///
/// Its own type, and **supplied by the caller** rather than derived from the
/// error — for the same reason `WallRetryCost` is. The first version derived it
/// from `WallError`, which put the decision back on the error and reintroduced
/// exactly the bug this file says it exists to prevent: a `.unreadableReply` on
/// the challenge call provably wrote nothing, and the same case on submit is
/// genuinely ambiguous.
enum WallPublicationState: Equatable, Sendable {

    /// The wall provably returned before `INSERT INTO signature`.
    case nothingWasPublished

    /// It might be up there. **The default for anything unrecognised**, because
    /// the wrong answer in this direction is the one that makes somebody sign
    /// twice — another 身分證統一編號 to 內政部, and a duplicate on a wall whose
    /// count is supposed to mean something.
    case unknown
}

/// A failure, what retrying costs, and whether anything reached the wall.
///
/// # Why neither field is computed from the error
///
/// The same `WallError` means different things depending on which call produced
/// it and what happened earlier in the session. `.unreadableReply` on the
/// challenge fetch spent nothing; on submit it is ambiguous. `.challengeAlreadyUsed`
/// on a **first** submit means somebody else's request spent the nonce; on a
/// **retry** it means *this session's own earlier submit* got past the claim —
/// which is the strongest available evidence that a row exists.
///
/// So both travel beside the error, and the initialiser enforces the one rule
/// that must never be got wrong by hand.
struct WallFailure: Error, Equatable, Sendable {

    let error: WallError
    let retryCost: WallRetryCost
    let publication: WallPublicationState

    var canPromiseNothingWasPublished: Bool { publication == .nothingWasPublished }

    /// `.mightDuplicate` and `.nothingWasPublished` are contradictory, so the
    /// combination is not representable: asking for it gets `.unknown`.
    init(_ error: WallError, retryCost: WallRetryCost, publication: WallPublicationState) {
        self.error = error
        self.retryCost = retryCost
        self.publication = retryCost == .mightDuplicate ? .unknown : publication
    }

    /// A failure on the challenge call.
    ///
    /// Nothing has been spent, by definition: `issueChallenge` contains no
    /// database statement at all, and `claimChallenge` runs inside submit and
    /// nowhere else. So both fields are fixed here rather than passed in.
    static func whileFetchingChallenge(_ error: WallError) -> WallFailure {
        WallFailure(error, retryCost: .resend, publication: .nothingWasPublished)
    }
}
