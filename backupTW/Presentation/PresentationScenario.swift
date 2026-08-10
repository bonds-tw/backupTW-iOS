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
/// **滿 18 歲** — supported on the credential path, and this entry is a
/// correction. It used to read "cannot be proven at all", which was true of the
/// *circuits* and written as though it were true of the app: the same
/// conflation of "the current architecture cannot" with "this cannot" that this
/// project has made and had to retract three times before.
///
/// What is true of the circuits is unchanged — `generateCertChainRs4096Input`
/// takes a certificate chain and an RSA signature, and there is no date among
/// their inputs, so the *zero-knowledge* path still cannot carry an age
/// predicate. What changed is everything around them. The predicate is derived
/// at issuance from `birthdate`, carried as its own claim
/// (`AgePredicate.claimName`), signed by the holder's 自然人憑證 along with
/// every other field, and shown on its own through `SelectiveDisclosure` while
/// the date stays withheld.
///
/// The remaining qualification is real and is why the caveats below are not
/// empty: this is minimal disclosure of the *field*, not unlinkability. The
/// presentation still carries the app's subject identifier, so two verifiers can
/// still tell they saw the same person — a weaker property than the ZK path's,
/// and one a screen must not blur into "anonymous".
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
        support: .partial(actually: NSLocalizedString(
            "The document carries whether the holder had turned 18 when it was issued, signed by their digital certificate, and that line can be shown on its own without the date of birth. It is not anonymous: the same identifier appears every time, so different checkers can tell it is the same person.",
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
