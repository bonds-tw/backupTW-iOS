//
//  WalletCardFactory.swift
//  backupTW
//
//  Turning what the wallet holds into card faces — with every sensitive value
//  masked on the way through.
//
//  # The one job that must not be got wrong
//
//  A card face shows a little of what the list deliberately showed none of, so
//  this is where the promise 「no full 統一編號 / 駕照號碼 / 門號 / 生日 on a
//  glanceable surface」 is kept or broken. Every value that reaches a
//  `WalletCard*` struct here is either a name (which a document cannot withhold,
//  so it is shown) or has been through `WalletCardMask`. The full values live
//  only behind the detail screens' existing reveal step.
//
//  Kept as pure functions over an injected store and a `CardInventoryRow` so the
//  masking can be tested without a view: the same discipline `CardInventory` and
//  `GovernmentCardViewController.read` already follow.
//

import Foundation

enum WalletCardFactory {

    // MARK: - National ID (self-issued)

    /// The national ID card face, or its empty-state invitation.
    ///
    /// - Parameter row: the self-issued row, or `nil` when this phone holds no
    ///   self-issued document yet — which is the invitation card, not an error.
    /// - Parameter store: read to pull the (masked) fields; a store that will not
    ///   open leaves the face with just its title rather than crashing.
    static func nationalIDContent(row: CardInventoryRow?,
                                  store: CredentialStoring?) -> WalletCardContent {
        let title = NSLocalizedString("Republic of China National ID", comment: "wallet card title")

        guard row != nil else {
            return .nationalID(NationalIDCard(
                title: title,
                holderName: "",
                placeholderMessage: NSLocalizedString(
                    "You have not backed up your national ID yet. Build it from your MyData record — the control below starts it.",
                    comment: "national id card empty state")))
        }

        guard let stored = StoredNationalID.load(from: store) else {
            // The row says a self-issued document exists but it would not decode
            // back right now (most often a locked device). Still a card, still
            // named — never a blank or a pretend-empty wallet.
            return .nationalID(NationalIDCard(title: title, holderName: ""))
        }

        let claims = Dictionary(stored.claims.map { ($0.key, $0.value) },
                                uniquingKeysWith: { first, _ in first })

        // Name: masked to the surname on the face (王小明 → 王〇〇). The full name
        // is only on the detail screen, behind its existing reveal — the same
        // rule the 統一編號 has always followed, now extended to the name because
        // the home screen is the over-the-shoulder surface. Sanitised before
        // masking so a bidi override cannot rearrange the masked result.
        let holder = claims["name"].map { WalletCardMask.maskedName(UntrustedText.value($0).text) } ?? ""

        var fields: [WalletCardField] = []
        if let nationality = claims["nationality"], !nationality.isEmpty {
            // Not sensitive: shown as-is (sanitised).
            fields.append(WalletCardField(label: StoredNationalID.label(for: "nationality"),
                                          value: UntrustedText.value(nationality).text))
        }
        if let birth = claims["birthdate"], !birth.isEmpty {
            fields.append(WalletCardField(label: StoredNationalID.label(for: "birthdate"),
                                          value: masked(birth)))
        }

        let idMasked = claims["unifiedNo"].map { masked($0) }
        return .nationalID(NationalIDCard(
            title: title,
            holderName: holder,
            fields: fields,
            idLabel: idMasked == nil ? nil : StoredNationalID.label(for: "unifiedNo"),
            idValueMasked: idMasked,
            // Self-issued: nobody vouches for it but the holder, and the card
            // says so plainly rather than borrowing a trust-list's authority.
            trustSource: NSLocalizedString("行動自然人憑證 · 本人自簽",
                                           comment: "national id card trust source: self-signed")))
    }

    // MARK: - Government / collected credential

    /// A collected card's face. Decodes the stored SD-JWT; anything that stops it
    /// decoding becomes a neutral `.unreadable` face carrying the honest reason,
    /// exactly as the detail screen does — a card face never pretends a card it
    /// cannot read is fine.
    static func credentialContent(row: CardInventoryRow,
                                  store: CredentialStoring?,
                                  now: Date = Date()) -> WalletCardContent {
        // An unrecognised blob: honest neutral face, no guess at what it is.
        if row.source == .unrecognised {
            return .unreadable(NSLocalizedString(
                "This version of the app cannot recognise this card.", comment: "wallet card"))
        }

        guard let store else {
            return .unreadable(NSLocalizedString(
                "This phone's cards cannot be read right now. Anything saved here is still saved.",
                comment: "wallet card: store would not open"))
        }
        let serialized: String?
        do { serialized = try store.load(id: row.id) }
        catch {
            return .unreadable(NSLocalizedString(
                "This card could not be read right now.", comment: "wallet card: load threw"))
        }
        guard let serialized,
              let credential = try? TWDIWCredentialReader.read(serialized, now: now) else {
            // Damaged, or signed by somebody other than the issuer it names —
            // the honest sentence that does not accuse, since this build cannot
            // tell the two apart. The detail screen explains at length.
            return .unreadable(NSLocalizedString(
                "This card could not be read or checked.", comment: "wallet card"))
        }

        return .credential(credentialCard(from: credential))
    }

    /// Builds the credential face from a decoded card. Split out so it can be
    /// exercised directly.
    static func credentialCard(from credential: TWDIWCredential,
                               now: Date = Date()) -> CredentialCard {
        let claims = credential.disclosedClaims

        // Name: masked to the surname on the face (陳筱玲 → 陳〇〇). Full name only
        // on the detail screen — the home screen is the over-the-shoulder surface.
        let holder = claims.first { $0.name.lowercased() == "name" }
            .map { WalletCardMask.maskedName(UntrustedText.value($0.value).text) }

        // The primary number: the first disclosed claim that names a sensitive
        // identifier, masked. Never shown in full on this surface.
        let primary = claims.first { WalletCardMask.isSensitiveKey($0.name) }
            .map { masked(UntrustedText.value($0.value).text) }

        // A curated readable name for the issuer, kind, and trust source. Safe to
        // key off the type: this card is already in the store, so it has already
        // passed both trust gates and its issuer is already vouched for — the
        // directory only puts a readable name to it. See `IssuerDirectory`.
        let descriptor = IssuerDirectory.describe(credentialType: credential.credentialType,
                                                  issuerDID: credential.issuerDID)

        return CredentialCard(
            kind: descriptor.cardKind,
            kindEnglish: nil,
            // The curated friendly issuer name (交通部公路局, 台灣大哥大, …), or —
            // for a card this app has no curated name for — the truncated issuer
            // DID, honest rather than invented. Sanitised.
            issuer: UntrustedText.value(descriptor.issuerName).text,
            holderName: holder,
            primaryMasked: primary,
            trustSource: UntrustedText.value(descriptor.trustSource).text,
            leftField: WalletCardField(
                label: NSLocalizedString("Valid until", comment: "wallet card foot"),
                value: validityText(credential.expires, now: now)),
            rightField: WalletCardField(
                label: NSLocalizedString("Valid from", comment: "wallet card foot"),
                value: Self.dateFormatter.string(from: credential.notBefore)),
            tint: tint(forCredentialType: credential.credentialType,
                       issuer: credential.issuerDID))
    }

    // MARK: - MyData vault

    static func vaultContent() -> WalletCardContent {
        .vault(VaultCard(
            title: NSLocalizedString("Nothing stored here", comment: "vault card title"),
            message: NSLocalizedString(
                "Your household record is fetched through MyData only to build your national ID, then erased — nothing is kept here.",
                comment: "vault card message"),
            status: NSLocalizedString("Sealed", comment: "vault card status")))
    }

    // MARK: - Tint selection (a colour is not a claim)

    /// Picks a stable colour for a credential from its kind. This is the one
    /// place a card's kind steers presentation, and it is safe because a colour
    /// asserts nothing — a wrongly-green card is a cosmetic miss, not a false
    /// statement. Matched on substrings so a new transport or telecom card lands
    /// in the right family without a table that has to be exhaustive.
    static func tint(forCredentialType type: String, issuer: String) -> WalletCardTint {
        let hay = (type + " " + issuer).lowercased()
        let transport = ["driv", "licen", "vehicle", "road", "公路", "監理", "traffic"]
        let telecom = ["mobile", "telecom", "門號", "phone", "msisdn", "carrier",
                       "chunghwa", "taiwanmobile", "fareastone", "中華電信", "台灣大", "遠傳"]
        if transport.contains(where: hay.contains) { return .green }
        if telecom.contains(where: hay.contains) { return .magenta }
        return .neutral
    }

    // MARK: - Helpers

    /// Sanitise then mask: a value that arrived inside a credential goes through
    /// the same display pipe as everywhere else *before* the middle is hidden, so
    /// a bidi override in it cannot rearrange the masked result.
    private static func masked(_ raw: String) -> String {
        WalletCardMask.masked(UntrustedText.value(raw).text)
    }

    /// `.distantFuture` is the reader's stand-in for a card with no `exp` at all,
    /// so it is never printed as a year-4001 date — the same guard `CardInventory`
    /// and the detail screen keep.
    private static func validityText(_ expires: Date, now: Date) -> String {
        if expires == .distantFuture {
            return NSLocalizedString("No expiry", comment: "wallet card foot")
        }
        let formatted = Self.dateFormatter.string(from: expires)
        if expires <= now {
            return String(format: NSLocalizedString("%@ (expired)", comment: "wallet card foot"), formatted)
        }
        return formatted
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy / MM"
        return formatter
    }()
}
