//
//  CardCapability.swift
//  backupTW
//
//  What each kind of card proves, and what it does not.
//

import Foundation

/// The three kinds of document this wallet can hold, and the honest account of
/// each.
///
/// # Why this type is the point of the whole milestone
///
/// A wallet that holds a national ID, a driving licence and a zero-knowledge
/// proof is not remarkable — the official app holds cards too. What is
/// remarkable, and what this project is for, is **putting the three side by side
/// with their limits written next to them**, because the limits are what differ.
/// One is offline-verifiable and structurally unable to hide the holder's name.
/// One is issued by a government body and cannot be checked for revocation
/// without a network. One reveals no fields at all and shows every verifier the
/// same duplicate-detection number.
///
/// Those are three different trust models, and until they are on one screen
/// together nobody has any reason to notice that they are different at all.
///
/// # The sentence this type may never contain
///
/// Nothing here says a card is unlinkable to the holder's other cards.
/// Per-credential keys (see `HolderKeyring`) sever one link — between cards —
/// and that is all. A TWDIW credential's `cnf.jwk` is fixed by its issuer at
/// collection and is the same key every verifier sees forever; its
/// `statusListIndex` is unique per card, sits outside the selective-disclosure
/// envelope, and goes to every verifier on every presentation. And before any
/// of that: a driving licence discloses a name and a national ID number, and
/// this app's own credential travels with a certificate whose Subject CN *is*
/// the legal name.
///
/// **Two cards shown to one person are joined by the name long before they are
/// joined by a key.** A card face that claimed otherwise would be the exact
/// rounding-up this app exists to refuse.
struct CardCapability: Equatable, Sendable {

    let id: String

    /// The card's name, as the holder would say it.
    let name: String

    /// One sentence: where it came from and who vouches for it.
    let origin: String

    /// What a verifier can rely on after checking it.
    let proves: [String]

    /// What it cannot establish, however carefully it is checked.
    ///
    /// Not "risks" and not "known issues" — those framings invite a reader to
    /// treat them as things that might be fixed later. These are properties.
    let limits: [String]

    /// Every kind, in the order they should be read: ours first, because the
    /// comparison only means something to somebody who already knows what the
    /// offline card does.
    static let all: [CardCapability] = [selfIssued, zeroKnowledge, twdiw]

    static let selfIssued = CardCapability(
        id: "self-issued",
        name: NSLocalizedString("Your own backed-up ID", comment: "card kind"),
        origin: NSLocalizedString(
            "Built on this phone from your MyData record, and signed with your digital certificate.",
            comment: "card origin"),
        proves: [
            NSLocalizedString("That the Ministry of the Interior's certificate signed these fields — checkable with no network at all.", comment: ""),
            NSLocalizedString("Only the fields you switch on. The rest stay as salted commitments the checker cannot open.", comment: ""),
        ],
        limits: [
            // The finding this app had to correct itself about, kept here so it
            // is never quietly dropped.
            NSLocalizedString("Your name is always visible. It is written inside the certificate that signs the document, and the checker needs that certificate to check the signature — so no switch can withhold it.", comment: ""),
            NSLocalizedString("It carries no national ID number, because the certificate does not contain one.", comment: ""),
        ])

    static let zeroKnowledge = CardCapability(
        id: "zero-knowledge",
        name: NSLocalizedString("Zero-knowledge proof", comment: "card kind"),
        origin: NSLocalizedString(
            "Computed on this phone from your digital certificate. The certificate itself is never shown.",
            comment: "card origin"),
        proves: [
            NSLocalizedString("That you hold a real national ID certificate, without revealing which one.", comment: ""),
        ],
        limits: [
            NSLocalizedString("Every checker sees the same duplicate-detection number, so two of them can tell they saw the same person.", comment: ""),
            NSLocalizedString("Offline there is no shared record of what has been used, so two checkers who never speak cannot both refuse the same person.", comment: ""),
        ])

    static let twdiw = CardCapability(
        id: "twdiw",
        name: NSLocalizedString("Government wallet card", comment: "card kind"),
        origin: NSLocalizedString(
            "Issued by a government body through 數位憑證皮夾, and collected over the network.",
            comment: "card origin"),
        proves: [
            NSLocalizedString("That a registered issuing body signed these fields, and which body it was.", comment: ""),
            NSLocalizedString("Only the fields you switch on, the same way as your own document.", comment: ""),
        ],
        limits: [
            // Measured 2026-08-16: the two published credentials are structurally
            // identical and carry no confidence indicator of any kind.
            NSLocalizedString("It does not say how carefully your identity was checked. A card issued after a counter check and one issued from a web form look the same.", comment: ""),
            // The status list is signed by a key that is in no DID document, no
            // trust list entry and no on-chain record.
            NSLocalizedString("Whether it has been cancelled can only be known online, and the list that says so is vouched for by nothing this phone can check offline.", comment: ""),
            // `statusListIndex` sits outside `_sd` in the signed payload.
            NSLocalizedString("It carries a number unique to this card that every checker sees, whichever fields you withhold.", comment: ""),
        ])
}
