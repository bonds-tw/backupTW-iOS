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
    /// The card-signed credential, shown over QR. Fast and works today.
    ///
    /// Not linkable-via-`did:key` as this used to say — that described the
    /// self-issued era. What it actually reveals is larger: the cardholder's
    /// X.509 certificate travels with the credential (the checker cannot verify
    /// the signature without it) and its Subject CN is the holder's legal name.
    /// Every checker learns who they are, disclosure switches notwithstanding.
    /// Measured 2026-08-10 at about 7.4 KB, roughly fourteen QR frames.
    case credential

    /// The zero-knowledge proof. ~294 KB, and ~14 seconds to check.
    ///
    /// **Not** "unlinkable across relying parties", which is what this line used
    /// to claim. The nullifier is derived from the relying-party identifier and
    /// the cardholder's key, and this app has exactly one such identifier —
    /// `TWFidOConfiguration.bondsAppID`, a constant shared by the production and
    /// UAT configurations. So the nullifier is one value per person, identical
    /// for every checker they ever present to, and it is a public signal.
    ///
    /// Unlinkability across relying parties is a property of *per-verifier*
    /// namespaces, which this build does not have. The proof does hide the
    /// certificate, so it reveals far less than the credential path — that is a
    /// real difference and it is the reason the path exists. It is not the same
    /// as unlinkable.
    case zeroKnowledge
}

/// Which of the two paths this build actually has.
///
/// # Why the table needed this
///
/// `PresentationScenario` is a hand-written statement about the *design*. It was
/// rendered as a statement about *this build*, and the two are not the same: the
/// factories behind both paths are `#if DEBUG`, so an App Store or TestFlight
/// copy can neither create a document nor make a proof.
///
/// On such a build the capability screen showed a green ✓「是，這個 App 做得到」
/// and, two rows further down the same settings screen, a disabled 「最小揭露」
/// row reading 「這個版本無法建立證明」. It was the only verdict screen in the app
/// not wired to the availability flags — four others already were — and its own
/// closing footnote assured the reader it was.
///
/// Injectable rather than read from the flags at the point of use, because the
/// interesting case is the one no test machine is ever in: `DEBUG` is true
/// everywhere the tests run, so a screen that asked the flags directly could
/// only ever be tested in the configuration where the bug is invisible.
struct BuildPaths: Equatable, Sendable {

    let credential: Bool
    let zeroKnowledge: Bool

    /// What this build really has.
    static var current: BuildPaths {
        BuildPaths(credential: CredentialIssuanceAssembly.isAvailable,
                   zeroKnowledge: ZKProofRunAssembly.isSigningAvailable)
    }

    /// The design as designed — what the table describes when nothing is gated.
    static let complete = BuildPaths(credential: true, zeroKnowledge: true)

    func has(_ path: PresentationPath) -> Bool {
        switch path {
        case .credential: return credential
        case .zeroKnowledge: return zeroKnowledge
        }
    }
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
/// **曾是台灣人** — the proof says *some* holder of a MOICA-G3 certificate
/// supplied the signing material. The request says 「你」, and the gap between
/// those two is `ProofCaveat.signatureMaterialIsReplayable`, so this is
/// `.partial` like the other two rather than the page's one green tick. It is
/// the emergency-period scenario and the one the current build serves best.
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

    /// The answer for a given build, which is not always the answer in the table.
    ///
    /// A path this build does not have cannot support anything, so the verdict
    /// collapses to `.unsupported` and `blockedBy` says which switch is off —
    /// in the same words the home screen and the proof screen already use, so a
    /// reader who has seen one recognises the other.
    ///
    /// ⚠️ This is the whole verdict, not a badge added next to it. A green tick
    /// with a note beside it is still a green tick, and this screen's own header
    /// comment says the verdict, the colour and the `actually` sentence are the
    /// three carriers — gating one of them would leave the other two claiming
    /// the capability.
    func support(in paths: BuildPaths) -> ScenarioSupport {
        guard !paths.has(path) else { return support }
        switch path {
        case .credential:
            return .unsupported(blockedBy: NSLocalizedString(
                "This version cannot create a document.", comment: ""))
        case .zeroKnowledge:
            return .unsupported(blockedBy: NSLocalizedString(
                "This version cannot make a proof.", comment: ""))
        }
    }

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
            "A real cardholder's signing material — but not that they are here, and not that this is their first time. Offline there is no shared record of what has already been used, so two checkers who never speak cannot both refuse the same person.",
            comment: "")),
        caveats: ProofCaveat.unconditional)

    static let wasTaiwanese = PresentationScenario(
        id: "was-taiwanese",
        request: NSLocalizedString("Prove you once held a Taiwanese national ID", comment: "scenario"),
        isEmergency: true,
        path: .zeroKnowledge,
        // ⚠️ **Was `.supported`, and it was the page's only green tick.**
        //
        // The request's subject is 「你」. The first unconditional caveat says the
        // signing material never changes and never expires, so anybody who has
        // held it once — 內政部 included — can produce this same proof with the
        // holder absent and unaware. `ZKProver.swift:432-448` states both halves
        // outright: `(cert, signed_response)` answers any fresh challenge, and
        // "the holder made this proof just now" is not something it supports.
        //
        // So the green tick sat on the **largest** gap on the page, while the
        // two smaller gaps beside it were already `.partial`. A page whose whole
        // reason to exist is stopping a demo from rounding half an answer up to
        // a tick cannot round the biggest half-answer up to the only tick.
        //
        // The sentence below is the file's own comment at :103-105, which had
        // already written this claim correctly with 「你」 removed.
        support: .partial(actually: NSLocalizedString(
            "That some holder of a certificate issued by MOICA-G3 supplied the signing material for this proof. Not that it was you, and not that it was made just now — the signing material never expires, so anybody who has ever held it can make this same proof without you.",
            comment: "")),
        caveats: ProofCaveat.unconditional)
}
