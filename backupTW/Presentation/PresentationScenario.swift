//
//  PresentationScenario.swift
//  backupTW
//
//  The whitepaper's §5.3 scenarios, and what this build can actually prove for
//  each of them.
//

import Foundation

/// Which of the two paths a scenario would have to be answered on.
enum PresentationPath: String, Codable, Equatable, Sendable {
    /// The self-issued credential, shown over QR. Fast, works today, and
    /// carries a fixed `did:key` — so two presentations are linkable.
    case credential
    /// The zero-knowledge proof. Unlinkable across relying parties, ~294 KB,
    /// and ~14 seconds to check.
    case zeroKnowledge
}

/// How well this build can answer a scenario.
///
/// Three cases rather than a `Bool`, because "we can prove something adjacent"
/// is the answer for two of the three whitepaper scenarios and is exactly the
/// answer a demo is tempted to round up.
enum ScenarioSupport: Equatable, Sendable {
    /// Provable as stated.
    case supported
    /// Something weaker is provable. The associated value is what is actually
    /// established, in the holder's language — never the requested claim.
    case partial(actually: String)
    /// Not provable on any path this build has. The associated value says what
    /// would have to change, so the gap is actionable rather than a shrug.
    case unsupported(blockedBy: String)

    var isSupported: Bool { self == .supported }
}

/// One of the whitepaper's §5.3 demonstration scenarios.
///
/// # Why this is a type and not a slide
///
/// The roadmap lists "three demonstration scenarios" as M4 work, and the obvious
/// way to build a demo is to write the three screens and let each one say what
/// the script needs it to say. That would be the single easiest way for this
/// project to end up lying: a demo is where a hedge is least welcome and where a
/// green tick is most persuasive.
///
/// So the capability statement lives in code, next to the paths that would have
/// to deliver it, and the screen renders whatever this table says rather than
/// what the demo would prefer. Two of the three scenarios do not survive that
/// treatment intact, which is the point.
///
/// # What the analysis found
///
/// **滿 18 歲** — the two circuits take a certificate chain and an RSA signature.
/// There is no date field among their inputs; `ProofCaveat.certificateExpiryNotProven`
/// says as much about the certificate's own dates. So an age predicate cannot be
/// proven in zero knowledge on this build at all. The credential path *does*
/// carry `birthdate` — but it discloses the date itself, not the predicate, and
/// it is self-issued and linkable. Answering "are you over 18" by handing over a
/// full date of birth attached to a stable identifier is worse than useless: it
/// is the opposite of minimal disclosure while looking like a feature.
///
/// **真人且唯一** — the "real person" half is what the ZK proof establishes. The
/// "and only once" half is `ProofCaveat.noGlobalUniqueness`: the nullifier is
/// derived per relying party, so catching a second use needs a record of
/// nullifiers already seen, and offline there is no shared record. Two verifiers
/// who never speak cannot both refuse the same nullifier. This is not solved
/// below this line and is not solvable offline.
///
/// **曾是台灣人** — this one is exactly what the proof says: some holder of a
/// certificate issued by MOICA-G3 supplied signing material for it. It is the
/// emergency-period scenario and the one the current build genuinely serves.
struct PresentationScenario: Equatable, Sendable {

    let id: String
    /// What a verifier would ask for, in their words.
    let request: String
    /// Which period of the whitepaper's narrative this belongs to.
    let isEmergency: Bool
    let path: PresentationPath
    let support: ScenarioSupport
    /// The caveats that survive even when `support` is `.supported`.
    let caveats: [ProofCaveat]

    static let all: [PresentationScenario] = [ageOver18, uniquePerson, wasTaiwanese]

    static let ageOver18 = PresentationScenario(
        id: "age-over-18",
        request: NSLocalizedString("Prove you are over 18", comment: "scenario"),
        isEmergency: false,
        path: .credential,
        support: .unsupported(blockedBy: NSLocalizedString(
            "The circuits take a certificate chain and a signature — there is no date among their inputs, so an age predicate cannot be proven in zero knowledge. The credential path holds a birthdate, but it would disclose the date itself under a linkable identifier, which is the opposite of what this screen is for.",
            comment: "")),
        caveats: [])

    static let uniquePerson = PresentationScenario(
        id: "unique-person",
        request: NSLocalizedString("Prove you are a real person, counted once", comment: "scenario"),
        isEmergency: false,
        path: .zeroKnowledge,
        support: .partial(actually: NSLocalizedString(
            "A real cardholder — but not that this is their first time. Offline there is no shared record of what has already been used, so two checkers who never speak cannot both refuse the same person.",
            comment: "")),
        caveats: ProofCaveat.unconditional)

    static let wasTaiwanese = PresentationScenario(
        id: "was-taiwanese",
        request: NSLocalizedString("Prove you once held a Taiwanese national ID", comment: "scenario"),
        isEmergency: true,
        path: .zeroKnowledge,
        support: .supported,
        caveats: ProofCaveat.unconditional)
}
