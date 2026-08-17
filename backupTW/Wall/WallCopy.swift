//
//  WallCopy.swift
//  backupTW
//
//  What each ending says: what happened, what it cost, and what a retry costs.
//

import Foundation

/// One failure, in the words a person reads.
///
/// # Three parts, and each answers a different question
///
/// The **title** says what happened. The **body** says what was spent — because
/// the two most expensive things on this path are a 身分證統一編號 disclosure to
/// 內政部 and a duplicate on a public wall, and neither is visible from the
/// title. The **retry label** is named after its own cost, so the button says
/// what pressing it does rather than "try again".
struct WallMessage: Equatable, Sendable {
    let title: String
    let body: String
    /// nil where retrying is not offered.
    let retryLabel: String?
}

enum WallCopy {

    /// The sentence set for a failure, given what it actually cost.
    ///
    /// Takes the whole `WallFailure` rather than the `WallError`, because the
    /// body has to state the cost and the cost is not a property of the error —
    /// the same `.unreadableReply` spent nothing on the challenge call and is
    /// ambiguous on submit.
    static func message(for failure: WallFailure) -> WallMessage {
        switch failure.error {

        case .hostDoesNotExist:
            // Today's reality, and deliberately **not** phrased as "the wall is
            // not accepting proofs yet".
            //
            // The Worker answers an unrouted path and a path this app spelled
            // wrong with the identical 404, and the path names are still this
            // side's unilateral proposal. Saying which one it is would be
            // guessing, in the one branch where a guess is unnecessary: what is
            // certain is that nothing left the phone.
            return WallMessage(
                title: NSLocalizedString("This version cannot find the wall.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "Nothing was sent and nothing on this phone changed. This is an address setting in this version of the app, not your network.",
                    comment: "Wall failure"),
                retryLabel: nil)

        case .offline:
            return WallMessage(
                title: NSLocalizedString("No usable connection.", comment: "Wall failure"),
                body: Self.body(for: failure, base: NSLocalizedString(
                    "Signing needs the internet once, to send the proof.", comment: "Wall failure")),
                retryLabel: Self.retryLabel(for: failure.retryCost))

        case .unavailable:
            return WallMessage(
                title: NSLocalizedString("Signing with a proof is switched off.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "Whoever runs the wall has turned it off. Nothing was sent, and trying again now gets the same answer.",
                    comment: "Wall failure"),
                retryLabel: nil)

        case .rateLimited:
            return WallMessage(
                title: NSLocalizedString("Too many requests from this network.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "Nothing was used up — the same proof can go again. The wall counts by network address, so other people on the same Wi-Fi count towards it too.",
                    comment: "Wall failure"),
                // Not "wait 60 seconds and it will work": the limiter is a ramp,
                // not a wall — seven rapid requests were measured all returning
                // 200. Promising a number the server does not promise is how a
                // second failure reads as the app being broken.
                retryLabel: Self.retryLabel(for: failure.retryCost))

        case .budgetSpent:
            return WallMessage(
                title: NSLocalizedString("The wall has used up today's checks.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "It resets at 08:00 Taipei time. Nothing was used up, so the same proof can go again while the one-time number is still valid.",
                    comment: "Wall failure"),
                retryLabel: Self.retryLabel(for: failure.retryCost))

        case .challengeUnusable:
            // ⚠️ **Does not say "expired".**
            //
            // `openChallenge` returns the same string for a malformed token, a
            // non-lowercase nonce, an expired one, and a bad MAC. This app has
            // already checked the format when parsing and the remaining time on
            // a monotonic clock before sending — so the reasons still standing
            // here are key rotation and clock skew, not expiry.
            //
            // An earlier draft asserted "expired", which guessed, in the one
            // branch that must guess, at the cause it had itself just ruled out.
            return WallMessage(
                title: NSLocalizedString("The wall does not recognise this one-time number.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "It may have expired, or the wall may have changed its keys. Either way, starting again means making a new proof and signing again in 行動自然人憑證.",
                    comment: "Wall failure"),
                retryLabel: Self.retryLabel(for: failure.retryCost))

        case .challengeAlreadyUsed:
            return WallMessage(
                title: NSLocalizedString("This one-time number has already been used.", comment: "Wall failure"),
                body: failure.canPromiseNothingWasPublished
                    ? NSLocalizedString(
                        "Each one counts once. Nothing of yours was published.",
                        comment: "Wall failure")
                    // The retry case. Somebody else spending the nonce is
                    // possible; the overwhelmingly likely explanation is that
                    // this session's own earlier submit got through and the
                    // reply was lost.
                    : NSLocalizedString(
                        "Each one counts once. If your last attempt ended without an answer, that attempt very likely counted — signing again would add a second signature.",
                        comment: "Wall failure"),
                retryLabel: nil)

        case .verifierUnavailable:
            return WallMessage(
                title: NSLocalizedString("The wall could not reach its checking service.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "Your proof was not checked and nothing was published. The one-time number is gone, so trying again means making a new proof — including signing again in 行動自然人憑證.",
                    comment: "Wall failure"),
                retryLabel: Self.retryLabel(for: failure.retryCost))

        case .refused:
            return WallMessage(
                title: NSLocalizedString("The wall checked this proof and did not accept it.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "Nothing was published.", comment: "Wall failure"),
                retryLabel: nil)

        case .unknownWhetherPublished:
            return WallMessage(
                title: NSLocalizedString("We do not know whether this was published.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "The proof was sent and no answer came back. The wall keeps nothing that says which signature is yours, so this cannot be looked up — by anyone, including us. That is the same design that keeps it anonymous. Signing again may add a second signature.",
                    comment: "Wall failure"),
                retryLabel: nil)

        case .unreadableReply:
            return WallMessage(
                title: NSLocalizedString("The wall answered something this app cannot read.", comment: "Wall failure"),
                body: Self.body(for: failure, base: NSLocalizedString(
                    "This is a mismatch between this app and the wall.", comment: "Wall failure")),
                retryLabel: Self.retryLabel(for: failure.retryCost))

        case .proofTooLarge(let bytes):
            return WallMessage(
                title: NSLocalizedString("This proof is too large to send.", comment: "Wall failure"),
                body: String(format: NSLocalizedString(
                    "It is %@, which is far larger than a real proof. It was not sent, so the one-time number is still good.",
                    comment: "Wall failure"), ZKStagePresentation.byteString(Int64(bytes))),
                retryLabel: nil)

        case .cannotProveInThisBuild:
            return WallMessage(
                title: NSLocalizedString("This version cannot make a proof.", comment: "Wall failure"),
                body: NSLocalizedString(
                    "It has no credentials for the digital certificate service, so nothing was asked for and nothing was sent.",
                    comment: "Wall failure"),
                retryLabel: nil)
        }
    }

    /// The refusal message, which needs two variants for the same verdict.
    ///
    /// # Why a phone that passed and a wall that refused is not a contradiction
    ///
    /// This device's self-check bets on three FFI facts. The wall runs the same
    /// pairing check **plus** the app id **plus** the challenge binding — it is
    /// a strict superset. So "passed here, refused there" is the expected
    /// symptom of a `WALL_APP_ID` mismatch, and this sentence is the only place
    /// that misconfiguration ever surfaces to a human.
    ///
    /// An earlier draft read it the other way round and told the person their
    /// card might be the problem.
    static func refusal(selfCheckPassedHere: Bool?) -> WallMessage {
        let title = NSLocalizedString("The wall checked this proof and did not accept it.",
                                      comment: "Wall failure")
        guard selfCheckPassedHere == true else {
            return WallMessage(title: title, body: NSLocalizedString(
                "This phone did not check the proof itself, so there is nothing to compare against. Nothing was published.",
                comment: "Wall failure"), retryLabel: nil)
        }
        return WallMessage(title: title, body: NSLocalizedString(
            "This phone checked the mathematics and it passed. The wall checks the mathematics **and** which service the proof was made for **and** whether it is bound to the number the wall just issued — the last two are things this phone cannot check by itself. So this usually means the wall's settings and this app disagree, not that there is anything wrong with your card. Nothing was published. This is worth reporting.",
            comment: "Wall failure"), retryLabel: nil)
    }

    /// Appends the cost sentence, so no body has to remember to.
    private static func body(for failure: WallFailure, base: String) -> String {
        let cost: String
        switch failure.retryCost {
        case .resend:
            cost = NSLocalizedString("Nothing was used up — the same proof can go again.",
                                     comment: "Wall retry cost")
        case .startOver:
            cost = NSLocalizedString("The one-time number is gone, so trying again means making a new proof.",
                                     comment: "Wall retry cost")
        case .mightDuplicate:
            cost = NSLocalizedString("Signing again may add a second signature.",
                                     comment: "Wall retry cost")
        case .none:
            return base
        }
        return base + " " + cost
    }

    /// The button says what pressing it costs.
    ///
    /// ⚠️ **Every branch routes through here. None hard-codes a label.**
    ///
    /// Four of them did, and the test caught it: `.rateLimited` and
    /// `.budgetSpent` always offered "send the same proof again",
    /// `.challengeUnusable` and `.verifierUnavailable` always offered "start
    /// again" — whatever the actual cost was. So a `.mightDuplicate` outcome
    /// carrying one of those errors would have been handed a retry button.
    ///
    /// That is the **third** time in this file's lineage the same mistake has
    /// been made: deriving something from the error when it is a property of
    /// the outcome. First `retryCost` on `WallError`, then
    /// `isSettledBeforeAnyWrite` left behind when that was fixed, now this. The
    /// shape is always the same — the error is the obvious thing to switch on,
    /// and it is the wrong thing.
    private static func retryLabel(for cost: WallRetryCost) -> String? {
        switch cost {
        case .resend: return NSLocalizedString("Send the same proof again", comment: "Wall retry")
        case .startOver: return NSLocalizedString("Start again", comment: "Wall retry")
        // Deliberately no button. A retry here may publish twice, and that is
        // not a decision to hand somebody behind a one-word label.
        case .mightDuplicate, .none: return nil
        }
    }
}
