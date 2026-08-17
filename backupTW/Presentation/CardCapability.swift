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
            // ⚠️ **This used to say the card carries no national ID number.**
            //
            // It does. `VerifiableCredential.nationalIDClaims` sets
            // `unifiedNo`, and `CredentialIssuance` refuses to issue the card
            // at all without one. It is a switch on the presentation screen,
            // and switching it on puts the number on the checker's display
            // among the verified fields.
            //
            // What is true — and measured — is a fact about the **certificate**:
            // a real MOICA G3 Subject DN carries only C, CN and serialNumber,
            // and that serialNumber is not the national ID number. A true
            // sentence about the certificate was written as a sentence about
            // the card.
            //
            // The direction is what makes it an (a): it claimed the card was
            // **safer than it is**, on the one page in this app that promises
            // to list limits honestly, about the national ID number
            // specifically. It is the same shape as
            // `WallDisclosure.countIsSignaturesNotPeople` — a choice and an
            // inability confused — pointing the other way.
            NSLocalizedString("It carries your national ID number, but that is a field you can switch off each time you show it — switched off, the checker sees only a commitment they cannot open.", comment: ""),
        ])

    static let zeroKnowledge = CardCapability(
        id: "zero-knowledge",
        name: NSLocalizedString("Zero-knowledge proof", comment: "card kind"),
        origin: NSLocalizedString(
            "Computed on this phone from your digital certificate. The certificate itself is never shown.",
            comment: "card origin"),
        proves: [
            // ⚠️ Not "you hold a real 自然人憑證".
            //
            // The app's own caveat says the signing material is a bearer token
            // that never changes and never expires — anybody who has held it
            // once, 內政部 included, can produce this proof without the holder
            // present. So the subject of the sentence cannot be 「你」, and
            // `ZKProver`'s own comment already says so in as many words.
            NSLocalizedString("That somebody's real national ID certificate signed this, without revealing which one.", comment: ""),
        ],
        // # Every unconditional caveat, taken from the source of truth
        //
        // This list used to be two sentences, hand-written, against six
        // unconditional `ProofCaveat` cases — and the four it dropped included
        // the two that `ZKProver`'s ordering comment calls the ones that
        // "decide what this project can claim at all".
        //
        // Worse, it read next to the government card, which *does* declare a
        // revocation limit — so the comparison implied the zero-knowledge card
        // did not have that problem. It is strictly worse: the circuit has no
        // date field at all and the revocation root is unanchored.
        //
        // `limits` is documented as "things it cannot establish however
        // carefully it is checked", which is exactly `isUnconditional`. So the
        // list is derived, and a seventh unconditional caveat appears here the
        // day it is added rather than the day somebody remembers.
        limits: ProofCaveat.unconditional.map(\.localizedDescription))

    static let twdiw = CardCapability(
        id: "twdiw",
        name: NSLocalizedString("Government wallet card", comment: "card kind"),
        origin: NSLocalizedString(
            "Issued by a government body through 數位憑證皮夾, and collected over the network.",
            comment: "card origin"),
        proves: [
            NSLocalizedString("That a registered issuing body signed these fields, and which body it was.", comment: ""),
            // ⚠️ Was 「…, the same way as your own document.」
            //
            // Behind the self-issued card's identical claim there is a real
            // `UISwitch` on a screen that works. That clause pointed at it and
            // said this card is the same, on a page titled 「what this app can
            // prove」 — while this app has no way to show this card at all. The
            // claim about the *format* is true; the comparison was to a path
            // that exists, from one that does not.
            NSLocalizedString("Only the fields you switch on.", comment: ""),
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

    /// What **this build** can do with this kind of card, which is a different
    /// question from what the kind of card can do.
    ///
    /// # Why this is not a fourth `limits` entry
    ///
    /// `limits` is documented as what the card cannot establish however
    /// carefully it is checked — properties of the format, true on every build
    /// forever. "This version has no screen for it" is a property of the app in
    /// August 2026. Filing it under `limits` would be the same mistake this file
    /// has already made twice in the other direction: a true sentence about one
    /// subject written as a sentence about another.
    ///
    /// It is rendered **above** the two claim lists rather than after them,
    /// because it changes how the lists should be read.
    func buildNote(in paths: BuildPaths) -> String? {
        switch id {
        case "twdiw":
            // Not gated by a switch, because there is nothing to switch. OID4VP
            // is milestone M5.4 and appears in this repo only as three comments
            // and a plan; nothing writes a TWDIW card to the store, and
            // `HolderPresentation.storedCredentialID()` returns `.selfIssued`
            // only.
            return NSLocalizedString(
                "This version has no way to collect or show this card. What it describes is the card as the government issues it.",
                comment: "")
        case "self-issued":
            return paths.credential ? nil : NSLocalizedString(
                "This version cannot create a document.", comment: "")
        case "zero-knowledge":
            return paths.zeroKnowledge ? nil : NSLocalizedString(
                "This version cannot make a proof.", comment: "")
        default:
            return nil
        }
    }
}
