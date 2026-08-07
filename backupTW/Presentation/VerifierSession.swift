//
//  VerifierSession.swift
//  backupTW
//

import Foundation

/// What one check produced.
///
/// `noPendingRequest` is deliberately not a `VerificationFailure`. Folding it in
/// would mean the nearest existing case — `challengeMismatch` — got shown to the
/// person at the counter, and that sentence accuses the holder of replaying an
/// old presentation. "This checker had nothing outstanding" is a statement about
/// *our* device, and saying so is the difference between "show it again" and an
/// allegation.
enum VerifierSessionResult: Equatable {
    case checked(VerificationOutcome)
    /// Nothing was outstanding: no request had been minted, the one that was has
    /// already been answered once, or it aged out.
    case noPendingRequest
}

/// Holds the challenge a verifier minted, and spends it exactly once.
///
/// # The half of replay protection that is not in `OfflineVerifier`
///
/// `OfflineVerifier.verify` is a pure function, so it will happily return
/// `verified` for the same presentation twice — and inside its five-minute
/// freshness window that is a real replay: whoever photographed the holder's
/// screen over their shoulder can hand the same frames back to the same reader.
/// The type documentation there says so and pins it with
/// `verifyingTwiceDoesNotConsumeTheChallenge`, because consumption belongs to
/// whoever owns the pending set. This is that owner.
///
/// # Consumed on refusal too, which is the part that is easy to get wrong
///
/// The obvious implementation clears the pending request on success and keeps it
/// on failure, so the holder can "try again". That hands an attacker an oracle
/// with unlimited attempts against a live challenge — and it is not hypothetical
/// here, because a failure this app expects to see often is a *timing* one: a
/// presentation refused for being 6 minutes old is a presentation that was valid
/// 90 seconds ago, and leaving its challenge outstanding lets it be resubmitted
/// with a different clock. So a challenge is spent by being answered at all.
/// The cost is that a genuine mis-scan makes the holder scan a new request QR;
/// the UI mints one immediately and says so.
///
/// # What this still does not close
///
/// A relay. Mallory can take a genuine challenge from this device's screen, show
/// it to a holder somewhere else under any `purpose` she likes, and bring the
/// answer back — a single-use challenge is satisfied exactly once, by her.
/// Closing that needs the verifier to authenticate itself to the holder, which
/// needs a trust root this project does not have offline. See
/// `PresentationRequest`; it is out of scope, not solved.
///
/// # Threading
///
/// Main thread only, and unsynchronised on purpose rather than by omission. A
/// lock here would suggest the single-use property survives concurrent callers,
/// and the property that actually matters — that two presentations cannot both
/// spend one challenge — is only worth as much as the weakest path into it. One
/// owner, on one queue, is a claim that can be read off the call sites. A check
/// costs about a millisecond (two ECDSA verifications over a few kilobytes), so
/// there is no reason to move it off the main queue in the first place.
final class VerifierSession {

    /// How long an unanswered challenge stays outstanding.
    ///
    /// Not a security boundary — the single-use rule is — but a bound on how
    /// long a photographed request QR is worth anything, and a way for a screen
    /// left open on a counter overnight to stop accepting yesterday's work.
    /// Matched to `OfflineVerifier.maximumPresentationAge` because the two
    /// windows compose: a presentation has to be minted after the request and
    /// accepted within five minutes of being signed, so a longer request
    /// lifetime buys the holder nothing.
    ///
    /// Both timestamps here come from *this* device's clock, unlike the
    /// comparison `OfflineVerifier` refuses to make between a request and a
    /// presentation. Two readings of one clock can be compared; two clocks
    /// cannot.
    static let pendingRequestLifetime: TimeInterval = OfflineVerifier.maximumPresentationAge

    private var pending: PresentationRequest?

    init() {}

    /// The outstanding request, or `nil` once it has aged out.
    ///
    /// Takes `now` rather than reading the clock so that a screen and a test see
    /// the same rule. Expiry is evaluated on read and on use; nothing sweeps in
    /// the background, because a request nobody asks about costs nothing.
    func pendingRequest(now: Date = Date()) -> PresentationRequest? {
        guard let pending else { return nil }
        guard now.timeIntervalSince(pending.createdAt) <= Self.pendingRequestLifetime else {
            return nil
        }
        return pending
    }

    /// Mints a fresh challenge and makes it the outstanding one.
    ///
    /// Replaces whatever was outstanding rather than refusing. The alternative —
    /// keeping the older challenge alive — means a verifier who taps 「重新查驗」
    /// leaves a second live challenge behind, and a set of outstanding challenges
    /// is exactly the thing this type exists to keep at size one.
    ///
    /// Throws only when the system CSPRNG refuses; see
    /// `PresentationRequest.generate`, which will not invent a challenge.
    @discardableResult
    func beginCheck(purpose: String, audience: String? = nil, now: Date = Date()) throws -> PresentationRequest {
        let request = try PresentationRequest.generate(purpose: purpose, audience: audience, now: now)
        pending = request
        return request
    }

    /// Spends the outstanding challenge on `presentationJWS`.
    ///
    /// The clearing happens *before* the check, not after, so that no path out of
    /// `OfflineVerifier` — including one added later that throws or returns early
    /// — can leave the challenge outstanding. `check` returning `.rejected` and
    /// `check` never being reached must have the same effect on the pending set.
    func check(presentationJWS: String, now: Date = Date()) -> VerifierSessionResult {
        guard let request = pendingRequest(now: now) else {
            pending = nil
            return .noPendingRequest
        }
        pending = nil
        return .checked(OfflineVerifier.verify(presentationJWS: presentationJWS,
                                               against: request,
                                               now: now))
    }

    /// Drops the outstanding challenge without answering it — for a screen being
    /// left, so a request that is no longer on anybody's display is no longer
    /// accepted either.
    func cancel() {
        pending = nil
    }
}
