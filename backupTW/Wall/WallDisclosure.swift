//
//  WallDisclosure.swift
//  backupTW
//
//  What signing a public wall actually discloses.
//

import Foundation

/// What somebody is agreeing to when they sign the Lennon Wall.
///
/// # Why this is not a `ProofCaveat`
///
/// `ProofCaveat` describes what a **proof** does and does not establish. These
/// describe what **publishing** costs. They are different axes, and a proof
/// caveat list that grew a "goes on the internet" case would be answering a
/// question nobody asked it.
///
/// `CaseIterable` so `LocalizationCoverageTests` can walk it. A sentence that
/// only exists in English is a sentence that does not exist for the people this
/// wall is for.
enum WallDisclosure: String, CaseIterable, Equatable, Sendable {

    /// The first time this app sends anything anywhere.
    case proofLeavesTheDevice

    /// The sharpest one.
    case nullifierReachesTheOperator

    /// The one the app cannot fix.
    case issuerKnowsWhenYouAsked

    case revocationNotCheckedByTheWall
    case countIsSignaturesNotPeople
    case cannotBeWithdrawn
    case operatorMustBeTrusted
    case issuerNotCheckedByTheWall

    var message: String {
        switch self {
        case .proofLeavesTheDevice:
            // 250 KB, not 190 KB. The raw proof is 190,798 bytes; base64 puts
            // 254,400 characters on the wire. This app refuses a submission
            // using the encoded figure, so quoting the raw one to the person
            // paying for it would be shading the number in the flattering
            // direction twice — which is not rounding.
            return NSLocalizedString(
                "This is the only thing in this app that sends anything to a server. About 250 KB of proof goes over the internet.",
                comment: "Wall disclosure")

        case .nullifierReachesTheOperator:
            // **Two numbers, not one.**
            //
            // `nullifier` is derived from an RSA signature over the app id, so
            // it is scoped to this app. `pk_commit` is not: both proofs carry
            // one and they must be equal — that equality is how `linkVerify`
            // ties the two halves together — so it can only be a function of
            // the holder's key, with no relying-party separation at all.
            //
            // ⚠️ Whether `pk_commit` is therefore a global identifier across
            // every zkID relying party is an inference from the verifier's
            // behaviour, not something read out of the circuit. It is listed in
            // the plan as needing confirmation. Until then the copy says "two
            // numbers", which is true either way.
            return NSLocalizedString(
                "The proof carries two numbers that are the same for you every time. bonds.tw says it does not store them and does not publish them. Nothing in the proof stops them — that is a promise, not a property.",
                comment: "Wall disclosure")

        case .issuerKnowsWhenYouAsked:
            // The one this app cannot mitigate.
            //
            // Making a proof tells 內政部 that this ID number asked for a
            // signature for this app, and when. The wall publishes the minute
            // of every signature on an endpoint that needs no authentication.
            // The gap between the two is bounded by this very design — the FidO
            // round trip plus proving plus submitting — and at the default
            // budget of 200 signatures a day, an eleven-minute window holds
            // about 1.5 of them.
            //
            // So for most signers the issuing authority can pick a person out
            // of a public page. `docs/lennon-wall.md` §1's rule — "only badge
            // type and timestamp are published" — was written against a threat
            // model where the attacker needs the nullifier. 內政部 does not.
            //
            // Nothing on the phone fixes this. The only mitigations are the
            // wall's: coarser times, or a random delay before publishing. So
            // what the app can do is say it before somebody agrees.
            return NSLocalizedString(
                "內政部 already knows your ID number asked for a signature for this app, and when. The wall publishes the minute each signature was made. Those two lists can be lined up.",
                comment: "Wall disclosure")

        case .revocationNotCheckedByTheWall:
            return NSLocalizedString(
                "The wall does not check the revocation list. This app applies one when it makes the proof, but the wall does not look at it, so a card already reported lost still earns the badge.",
                comment: "Wall disclosure")

        case .countIsSignaturesNotPeople:
            // Rewritten. The first version said the wall "does not check whether
            // you have signed before", which describes a choice as though it
            // were an inability — in the same list that insists, one item above,
            // on the difference between a promise and a property.
            return NSLocalizedString(
                "The wall counts signatures, not people. It could tell that the same person signed twice — those two numbers in the proof would be identical — it says it does not look. Signing twice is two entries.",
                comment: "Wall disclosure")

        case .cannotBeWithdrawn:
            return NSLocalizedString(
                "A signature cannot be taken back. The wall keeps nothing that says which one is yours — that is the same reason it is anonymous.",
                comment: "Wall disclosure")

        case .operatorMustBeTrusted:
            return NSLocalizedString(
                "The proofs are not published, so nobody outside bonds.tw can recompute the number on the wall. Publishing them would leak the two numbers above.",
                comment: "Wall disclosure")

        case .issuerNotCheckedByTheWall:
            // Unconditional, and that is the correction.
            //
            // The first draft included this only "if the verifier has no issuer
            // certificate configured" — which ties a compile-time constant in a
            // binary that ships on an App Store review cycle to a Cloud Run
            // runtime fact an operator can change in minutes. Both sides would
            // be wrong at different times. So it is always said, and the
            // assumption it encodes is written down where it can be checked.
            return NSLocalizedString(
                "The wall does not check that the certificate behind the proof was issued by 內政部. In this version the badge means a valid proof, not necessarily a real national ID card.",
                comment: "Wall disclosure")
        }
    }

    /// The order they are read in: what leaves, who learns what, what the badge
    /// does not mean, and what cannot be undone.
    static let inReadingOrder: [WallDisclosure] = [
        .proofLeavesTheDevice,
        .nullifierReachesTheOperator,
        .issuerKnowsWhenYouAsked,
        .issuerNotCheckedByTheWall,
        .revocationNotCheckedByTheWall,
        .countIsSignaturesNotPeople,
        .operatorMustBeTrusted,
        .cannotBeWithdrawn,
    ]
}
