//
//  WallClient.swift
//  backupTW
//
//  The two calls that sign the Lennon Wall.
//

import Foundation

/// What the wall says about itself.
struct WallState: Equatable, Sendable {
    let signatureCount: Int
}

/// The wall's answer to a submitted proof.
enum WallSubmissionResult: Equatable, Sendable {
    case published(signatureCount: Int)
    /// The verifier ran and said no. Distinct from every failure: the wall
    /// worked, and the answer was no.
    case refused
}

/// The seam.
///
/// Every branch below has to be reachable from a test, because **the wall is not
/// routed yet** — `signZK` is unrouted by design until the go-live checklist
/// passes, so there is no environment in which the real client can exercise the
/// interesting cases. A protocol is the only way this flow gets tested at all
/// before it is turned on.
protocol WallSigning: Sendable {
    func readWall() async throws -> WallState
    func issueChallenge() async throws -> WallChallenge
    func submit(_ submission: WallSubmission,
                challenge: WallChallenge) async throws -> WallSubmissionResult
}

/// Turns HTTP into the outcomes above.
///
/// # The rule that shapes every line
///
/// On the submit call, **anything not positively recognised is
/// `.unknownWhetherPublished`.** Not "probably failed", not "check your
/// connection" — unknown. The Worker writes the signature row and *then* reads
/// the board back with two more queries, so a reply that is not JSON is
/// genuinely consistent with "it published and then fell over".
///
/// Saying "nothing was published" when something was is the one mistake here
/// that costs a person something real: they sign again, which sends their
/// 身分證統一編號 to 內政部 a second time and puts a duplicate on a wall whose
/// count is meant to mean something.
enum WallResponseReader {

    /// The Worker's `error` strings, and what each one means for the challenge.
    ///
    /// Derived from the Worker's control flow, in order: `CITIZEN_ENABLED` and
    /// the secrets, the rate limiter, the daily budget, the body parse,
    /// `openChallenge`, **then** `claimChallenge`, then the verifier call.
    /// Everything above the claim leaves the challenge alive.
    static func failure(forErrorCode code: String, status: Int) -> WallFailure {
        switch code {
        case "unavailable":
            return WallFailure(.unavailable, retryCost: .resend)
        case "rate-limited":
            return WallFailure(.rateLimited, retryCost: .resend)
        case "verifier-budget":
            return WallFailure(.budgetSpent, retryCost: .resend)
        case "malformed":
            // This app's bug, not the person's. The challenge survives it, so
            // the honest cost is still `.resend` — even though a resend of the
            // same malformed body will fail identically, which is the screen's
            // problem to phrase, not this function's to lie about.
            return WallFailure(.unreadableReply, retryCost: .resend)
        case "challenge-invalid":
            // Never claimed, but the token is bound to a number the wall does
            // not accept, so there is nothing to resend *with*.
            return WallFailure(.challengeUnusable, retryCost: .startOver)
        case "challenge-used":
            return WallFailure(.challengeAlreadyUsed, retryCost: .startOver)
        case "verifier-unavailable":
            // Claimed. The challenge is gone and nothing was written — the
            // Worker returns before the INSERT on every path that produces this.
            return WallFailure(.verifierUnavailable, retryCost: .startOver)
        default:
            // An error code from a newer wall. Unknown, deliberately: this app
            // cannot know whether that branch is above or below the INSERT.
            _ = status
            return WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate)
        }
    }

    /// Reads a submit response.
    ///
    /// # Why `verified` is read before `signatureCount`
    ///
    /// Success and refusal share no discriminating field — success is
    /// `{signatureCount, recent}` and refusal is `{"verified": false}`. So the
    /// order is the rule: a body carrying both keys falls to **refused**, not to
    /// published. Erring towards "your signature is not up there" is the
    /// direction that cannot manufacture a signature that does not exist.
    static func readSubmission(status: Int, body: Data) -> Result<WallSubmissionResult, WallFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            // Includes the case that mattered before the route existed:
            // `/api/wall` answered 200 with the site's index.html.
            return .failure(WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate))
        }
        if let verified = object["verified"] as? Bool {
            return verified
                ? .success(.published(signatureCount: object["signatureCount"] as? Int ?? 0))
                : .success(.refused)
        }
        if let code = object["error"] as? String {
            return .failure(failure(forErrorCode: code, status: status))
        }
        if let count = object["signatureCount"] as? Int {
            return .success(.published(signatureCount: count))
        }
        return .failure(WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate))
    }

    /// Maps a transport failure.
    ///
    /// `duringSubmit` is the whole argument: the same `URLError` is free to
    /// retry on one call and possibly-duplicating on the other, and only the
    /// caller knows which.
    static func failure(forTransport error: Error, duringSubmit: Bool) -> WallFailure {
        let code = (error as? URLError)?.code
        let named: WallError
        switch code {
        case .some(.cannotFindHost), .some(.dnsLookupFailed):
            named = .hostDoesNotExist
        case .some(.notConnectedToInternet), .some(.networkConnectionLost),
             .some(.dataNotAllowed), .some(.internationalRoamingOff):
            named = .offline
        default:
            named = duringSubmit ? .unknownWhetherPublished : .unreadableReply
        }

        guard duringSubmit else { return .whileFetchingChallenge(named) }

        // On submit, only failures that provably happened *before* the request
        // was accepted can claim nothing was published. A connection that never
        // opened is one; a timeout is not — the wall may have finished the work
        // and lost the reply.
        switch code {
        case .some(.cannotFindHost), .some(.dnsLookupFailed),
             .some(.notConnectedToInternet), .some(.dataNotAllowed),
             .some(.internationalRoamingOff):
            return WallFailure(named, retryCost: .resend)
        default:
            return WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate)
        }
    }
}
