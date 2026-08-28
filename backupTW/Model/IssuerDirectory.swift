//
//  IssuerDirectory.swift
//  backupTW
//
//  A friendly issuer name and human-readable card kind for a stored credential,
//  from a small curated table keyed on the credential's own type string.
//
//  # Why it is safe to name an issuer from a card's type
//
//  A `did:key` is the honest thing a card carries, but it is unreadable — a
//  holder glancing at 「did:key:z6Mk…」 learns nothing. This maps the card's
//  type onto the name of the body that issues that kind of card.
//
//  Inferring an issuer from a type would be dangerous in general: anyone can mint
//  a JWT whose `vc.type[1]` says `drivinglicense`. It is safe *here* because of
//  what has already happened to every card this table ever sees. Nothing reaches
//  a card face until it has passed both trust gates — a signature that verifies
//  under an issuer DID, and that issuer DID being on the 數位發展部 trust list
//  (see `TWDIWCredentialReader.read` and the trust-list check). A card in the
//  store is therefore already known to come from a trusted issuer; all this table
//  does is put a readable name to the issuer the gates already vouched for. A
//  stored driving-licence card genuinely came from 公路局, because a forged one
//  would never have been stored. The type→issuer step is a lookup for an
//  already-authenticated card, not a trust decision.
//
//  # Honesty rules the table keeps
//
//  - A **sandbox / demo / example** card is labelled as exactly that, *before*
//    any card-type rule runs, so a test driving licence is never dressed up as a
//    real 公路局 card. This is why `demo_drivinglicense` resolves to 沙盒系統 and
//    not 交通部公路局 — the demo issuer, honestly named.
//  - A **type this table does not know** falls back to the truncated issuer DID
//    (the honest identifier, never an invented name), the existing
//    `CardInventory.readableType`, and a source that says it is not on this list.
//    An unknown card is shown as unknown, not guessed at.
//
//  Kept as a pure function so the mapping is tested without a view — the same
//  discipline `WalletCardMask` and `WalletCardFactory` follow.
//

import Foundation

/// A readable identity for a stored credential's issuer and kind.
struct IssuerDescriptor: Equatable {
    /// The issuing body's friendly name, e.g. 「交通部公路局」 — or, for a card
    /// whose type this table does not know, the truncated issuer DID.
    let issuerName: String
    /// A human-readable card kind, e.g. 「駕照電子卡」 — or `CardInventory.readableType`
    /// for a card this table does not have a curated name for.
    let cardKind: String
    /// Where the trust in this card comes from, e.g. 「數位發展部信任清單」.
    let trustSource: String
}

enum IssuerDirectory {

    /// The curated trust-list source shared by the government and telecom cards:
    /// they are trusted because their issuer DID is on 數位發展部's list.
    private static let modaTrustList = "數位發展部信任清單"

    /// Resolves a stored credential's issuer name, readable kind, and trust
    /// source from its type string (matched case-insensitively on substrings) and
    /// its issuer DID.
    ///
    /// - Parameter credentialType: `vc.type[1]`, e.g.
    ///   `00000000_demo_drivinglicense_202504251418`.
    /// - Parameter issuerDID: the issuer's `did:key`, used both to spot sandbox
    ///   issuers and as the honest fallback name when nothing matches.
    static func describe(credentialType: String, issuerDID: String) -> IssuerDescriptor {
        let type = credentialType.lowercased()
        let issuer = issuerDID.lowercased()
        let readableKind = UntrustedText.value(CardInventory.readableType(credentialType)).text

        // Sandbox / demo first, and on purpose. A demo driving licence contains
        // the substring `drivinglicense`, but it is *not* a 公路局 card and must
        // not be shown as one. Naming it 沙盒系統 keeps every card-type rule below
        // safe to state as a real-world issuer, because a test card can never
        // reach them.
        let sandboxNeedles = ["sandbox", "demo", "example"]
        if sandboxNeedles.contains(where: { type.contains($0) || issuer.contains($0) }) {
            return IssuerDescriptor(issuerName: "沙盒系統",
                                    cardKind: readableKind,
                                    trustSource: "沙盒/測試")
        }

        // Driving licence → 交通部公路局.
        if ["drivinglicense", "driving", "駕照"].contains(where: type.contains) {
            return IssuerDescriptor(issuerName: "交通部公路局",
                                    cardKind: "駕照電子卡",
                                    trustSource: modaTrustList)
        }

        // Telecom 門號電子卡, one carrier each. Checked before the generic 數發部
        // partner rule so a carrier is named as itself. `chtme`/`cht` (中華),
        // `twmdiwvc`/`twm` (台灣大), `fet` (遠傳) are the type prefixes production
        // issues under.
        if ["twmdiwvc", "twm"].contains(where: type.contains) {
            return telecom("台灣大哥大")
        }
        if type.contains("fet") {
            return telecom("遠傳電信")
        }
        if ["chtme", "cht"].contains(where: type.contains) {
            return telecom("中華電信")
        }

        // 數位發展部 partner card (e.g. the official partner card). After the
        // carriers so a telecom type is not swallowed by a stray `moda`.
        if ["moda", "partner"].contains(where: type.contains) {
            return IssuerDescriptor(issuerName: "數位發展部",
                                    cardKind: readableKind,
                                    trustSource: modaTrustList)
        }

        // Not on this list: the honest fallback. The issuer's own identifier
        // (truncated for the face), the readable-ised type, and a source that
        // says plainly it is not curated here. No invented name.
        return IssuerDescriptor(issuerName: truncatedDID(issuerDID),
                                cardKind: readableKind,
                                trustSource: "未列於對照表")
    }

    private static func telecom(_ name: String) -> IssuerDescriptor {
        IssuerDescriptor(issuerName: name, cardKind: "門號電子卡", trustSource: modaTrustList)
    }

    /// A `did:key` shortened to something a card face can show without a name to
    /// put to it — head and tail kept, the long multibase middle elided. The
    /// point is only legibility; the full DID is on the detail screen.
    private static func truncatedDID(_ did: String) -> String {
        let sanitised = UntrustedText.value(did).text
        let characters = Array(sanitised)
        guard characters.count > 24 else { return sanitised }
        return String(characters.prefix(16)) + "…" + String(characters.suffix(6))
    }
}
