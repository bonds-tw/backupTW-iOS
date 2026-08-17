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
    /// The count is **optional**: the Worker's post-insert fallback answers
    /// `{verified:true}` with no board attached, and reporting that as zero
    /// would show an empty wall to somebody who had just signed it.
    case published(signatureCount: Int?)
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

    /// The Worker's `error` strings, and what each one means.
    ///
    /// Derived from the Worker's control flow, in order: `CITIZEN_ENABLED` and
    /// the secrets, the rate limiter, the daily budget, the body parse,
    /// `openChallenge`, **then** `claimChallenge`, then the verifier call, then
    /// the INSERT. Everything above the claim leaves the challenge alive.
    ///
    /// - Parameter hasAlreadySubmittedThisChallenge: whether *this session* has
    ///   already sent a submit for this challenge. It changes one answer, and
    ///   that answer is the most expensive one in the file — see
    ///   `challenge-used` below.
    static func failure(forErrorCode code: String,
                        status: Int,
                        hasAlreadySubmittedThisChallenge: Bool = false) -> WallFailure {
        switch code {
        case "unavailable":
            return WallFailure(.unavailable, retryCost: .resend, publication: .nothingWasPublished)
        case "rate-limited":
            return WallFailure(.rateLimited, retryCost: .resend, publication: .nothingWasPublished)
        case "verifier-budget":
            return WallFailure(.budgetSpent, retryCost: .resend, publication: .nothingWasPublished)
        case "malformed":
            // This app's bug, not the person's. The Worker returns sixty lines
            // above the INSERT, so nothing was published — an earlier version
            // said "we do not know" here, which pushed people away from a free
            // retry for no reason.
            return WallFailure(.unreadableReply, retryCost: .resend, publication: .nothingWasPublished)

        case "challenge-invalid":
            // ⚠️ `.startOver`, **not** `.resend`, and this is the one case where
            // the rule stated above does not decide it.
            //
            // It *is* above the claim, so the challenge was not consumed — but
            // `openChallenge` returns null for an expired token or a bad MAC,
            // and neither can ever become valid again. The decimal is bound into
            // the proof, so there is nothing to resend *with*: `.resend` would
            // loop for ever.
            //
            // `.resend` answers "was the challenge consumed"; `.startOver`
            // answers "does this person need a new one". Those two questions
            // diverge here and nowhere else, which is why this case has its own
            // test rather than riding along in a parameterised list.
            return WallFailure(.challengeUnusable, retryCost: .startOver,
                               publication: .nothingWasPublished)

        case "challenge-used":
            // # The most expensive line in this file
            //
            // `claimChallenge` found the nonce already recorded, so **some
            // earlier request got past the claim**. Past that point there are
            // exactly two outcomes: no row, or a row.
            //
            // On a first submit, that earlier request was somebody else's
            // problem and nothing of this person's was published. On a **retry**
            // it was this session's own submit — the one that ended ambiguously
            // and sent them here — and "another request already spent this" is
            // then the strongest evidence available that their signature exists.
            //
            // Telling them nothing was published at that moment is what produces
            // the duplicate *and* the second 身分證統一編號 disclosure, which is
            // both worst costs at once. So the answer depends on the session,
            // and the session is the only thing that knows.
            return hasAlreadySubmittedThisChallenge
                ? WallFailure(.challengeAlreadyUsed, retryCost: .mightDuplicate, publication: .unknown)
                : WallFailure(.challengeAlreadyUsed, retryCost: .startOver,
                              publication: .nothingWasPublished)

        case "verifier-unavailable":
            // Claimed, and the Worker returns before the INSERT on every path
            // that produces this.
            return WallFailure(.verifierUnavailable, retryCost: .startOver,
                               publication: .nothingWasPublished)

        default:
            // # A JSON error the routing layer produced, not a handler
            //
            // A 404 or 405 carrying a JSON `error` cannot have reached code that
            // touches the database — the dispatcher answers before any handler
            // runs. **This is today's actual outcome**: `sign-zk` is not routed
            // yet, so every submit this app can currently make lands here, and
            // calling it "might have duplicated" would be false about a request
            // that provably did nothing.
            //
            // The status code is the disambiguator, and an earlier version threw
            // it away with `_ = status`.
            if status == 404 || status == 405 {
                return WallFailure(.unavailable, retryCost: .resend, publication: .nothingWasPublished)
            }
            // An error code from a wall newer than this app. Unknown,
            // deliberately: this build cannot know which side of the INSERT that
            // branch sits on.
            return WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate,
                               publication: .unknown)
        }
    }

    /// Reads a submit response.
    ///
    /// # Why `verified` is read before `signatureCount`
    ///
    /// Success and refusal share no discriminating field — success is
    /// `{signatureCount, recent}` and refusal is `{"verified": false}`. So the
    /// order is the rule: a body carrying both falls to **refused**, not to
    /// published. Erring towards "your signature is not up there" cannot
    /// manufacture one that does not exist.
    static func readSubmission(status: Int,
                               body: Data,
                               hasAlreadySubmittedThisChallenge: Bool = false)
    -> Result<WallSubmissionResult, WallFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            // Not JSON. Cloudflare's own error pages land here, and they are not
            // all the same: 1101 means the Worker threw — possibly after the
            // INSERT — while 1027 (over quota) is served at the edge and the
            // Worker never ran at all.
            if status == 429 {
                return .failure(WallFailure(.rateLimited, retryCost: .resend,
                                            publication: .nothingWasPublished))
            }
            // Includes the case that was live before the route existed:
            // `/api/wall` answered 200 with the site's index.html.
            return .failure(WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate,
                                        publication: .unknown))
        }
        if let verified = object["verified"] as? Bool {
            guard verified else { return .success(.refused) }
            // ⚠️ The count is **optional**, and this branch is why.
            //
            // The Worker emits `{verified:true}` from exactly one place: the
            // catch around reading the board back, after the row is written. It
            // never carries `signatureCount`. An earlier version defaulted to
            // zero — so the single branch built to guarantee "the signature
            // exists" would have rendered a wall with nothing on it, seconds
            // after somebody signed, inviting the retry that duplicates.
            return .success(.published(signatureCount: object["signatureCount"] as? Int))
        }
        if let code = object["error"] as? String {
            return .failure(failure(forErrorCode: code, status: status,
                                    hasAlreadySubmittedThisChallenge: hasAlreadySubmittedThisChallenge))
        }
        if let count = object["signatureCount"] as? Int {
            return .success(.published(signatureCount: count))
        }
        return .failure(WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate,
                                    publication: .unknown))
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

        // # Only failures that provably delivered no bytes may claim safety
        //
        // Everything below fails before any HTTP request is written: name
        // resolution, TCP connect, the TLS handshake, or a URL that never left
        // the process. An earlier version listed only the first few, so the most
        // likely failure during rollout — `cannotConnectToHost`, which is what a
        // missing route or an unhealthy edge produces — was reported as "your
        // signature might have duplicated".
        //
        // `.timedOut` is deliberately **absent**: this app's deadline is longer
        // than the Worker's on purpose, so a timeout genuinely straddles the
        // INSERT. `.networkConnectionLost` is absent for the same reason — the
        // connection existed, so the request may have been delivered and only
        // the reply lost.
        switch code {
        case .some(.cannotFindHost), .some(.dnsLookupFailed),
             .some(.cannotConnectToHost),
             .some(.secureConnectionFailed), .some(.serverCertificateUntrusted),
             .some(.serverCertificateHasBadDate), .some(.serverCertificateHasUnknownRoot),
             .some(.serverCertificateNotYetValid), .some(.clientCertificateRejected),
             .some(.appTransportSecurityRequiresSecureConnection),
             .some(.badURL), .some(.unsupportedURL),
             .some(.notConnectedToInternet), .some(.dataNotAllowed),
             .some(.internationalRoamingOff):
            return WallFailure(named, retryCost: .resend, publication: .nothingWasPublished)
        default:
            return WallFailure(.unknownWhetherPublished, retryCost: .mightDuplicate,
                               publication: .unknown)
        }
    }
}
