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
            // The card face reproduces the physical 國民身分證, which prints
            // 「統一編號」 — kept verbatim here even though the field label elsewhere
            // (detail, 對照表) now reads 「身分證字號」, the word people use.
            idLabel: idMasked == nil ? nil : NSLocalizedString("Unified number", comment: "national ID card face footer, matches the physical card"),
            idValueMasked: idMasked,
            // Self-issued: nobody vouches for it but the holder, and the card
            // says so plainly rather than borrowing a trust-list's authority.
            trustSource: NSLocalizedString("行動自然人憑證 · 本人自簽",
                                           comment: "national id card trust source: self-signed"),
            // The flip side. It shows the fuller field list the front had no room
            // for — name, 統一編號, 出生, 戶籍地 — but **every one masked**, because
            // the back is the same over-the-shoulder surface the front is. The
            // 戶籍地址 is the reason this cannot lean on `isSensitiveKey` alone
            // (that set names identifier *numbers*, not an address), so
            // `backFieldValue` masks it explicitly.
            backFields: nationalIDBackFields(stored: stored)))
    }

    /// The masked field list for the national ID's flip side, read in the order a
    /// person reads an ID: who it is about, then the numbers, then where. Built
    /// from what the stored document actually carries, so a card missing a field
    /// simply omits its row rather than showing a blank.
    private static func nationalIDBackFields(stored: StoredNationalID) -> [WalletCardField] {
        let byKey = Dictionary(stored.claims.map { ($0.key, $0.value) },
                               uniquingKeysWith: { first, _ in first })
        var back: [WalletCardField] = []
        func append(_ key: String) {
            guard let raw = byKey[key], !raw.isEmpty else { return }
            back.append(WalletCardField(label: StoredNationalID.label(for: key),
                                        value: backFieldValue(key: key, raw: raw)))
        }
        append("name")
        append("unifiedNo")
        append("birthdate")
        append("nationality")           // not sensitive: shown, sanitised
        append("addressOfHousehold")    // sensitive: masked by `backFieldValue`
        if let age = byKey[AgePredicate.claimName], !age.isEmpty {
            back.append(WalletCardField(
                label: StoredNationalID.label(for: AgePredicate.claimName),
                value: StoredNationalID.displayValue(for: AgePredicate.claimName,
                                                     value: UntrustedText.value(age).text)))
        }
        // 發證日 — a date, not a personal fact, so shown as-is. `createdDescription`
        // already sanitises the raw string on the failed-parse path.
        back.append(WalletCardField(
            label: NSLocalizedString("Issued", comment: "national id back: issuance date"),
            value: stored.createdDescription()))
        return back
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
                                                  issuerDID: credential.issuerDID,
                                                  knownIssuerName: IssuerNameBook.name(for: credential.issuerDID))

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
                       issuer: credential.issuerDID,
                       kind: descriptor.cardKind),
            // The flip side lists every disclosed claim, each masked. It reuses
            // the same `backFieldValue` rule as the national ID: a name to its
            // surname, an identifier / phone / birthdate / address to dots, and a
            // plain non-sensitive field shown as-is. The full values stay behind
            // the detail screen's reveal — see `credentialFaceMasksTheIdentifier`
            // and its back-face sibling test.
            backFields: claims.map {
                WalletCardField(label: claimLabel($0.name),
                                value: backFieldValue(key: $0.name, raw: $0.value))
            })
    }

    /// Masks one claim value for a flip-side row. The one place the back's promise
    /// is kept, mirroring the front's `masked` / `maskedName` split:
    ///
    ///   - a **name** (the key is or contains 「name / 姓名」) → surname kept, rest 〇.
    ///   - an **identifier, phone, birthdate, passport, or address** → dotted by
    ///     `WalletCardMask.masked`. Address is checked here on top of
    ///     `isSensitiveKey`, which only names identifier *numbers* — a 戶籍地址 is
    ///     every bit as identifying and must never appear in full.
    ///   - anything else (nationality, a status flag) → shown, only sanitised.
    ///
    /// Errs toward masking, as the whole file does: an over-masked ordinary field
    /// is a cosmetic loss; an un-masked address or number is the failure this
    /// exists to prevent.
    static func backFieldValue(key: String, raw: String) -> String {
        let text = UntrustedText.value(raw).text
        let lowered = key.lowercased()
        if lowered == "name" || lowered.contains("name") || key.contains("姓名") {
            return WalletCardMask.maskedName(text)
        }
        let addressNeedles = ["address", "addr", "戶籍", "住址", "地址", "location"]
        if WalletCardMask.isSensitiveKey(key) || addressNeedles.contains(where: lowered.contains) {
            return WalletCardMask.masked(text)
        }
        return text
    }

    /// A readable label for a disclosed credential claim key. Delegates to the same
    /// `ClaimLabel` table the detail page uses — so the card back and the screen
    /// behind it name a field the same way, and every key the detail page knows a
    /// Chinese word for (地址, 車輛類別, 電信業者, …) reads that way on the back too,
    /// instead of the raw machine key this once fell through to. Unknown keys stay
    /// framed as the document's own term, never an invented label.
    private static func claimLabel(_ key: String) -> String {
        ClaimLabel.label(for: key).heading
    }

    // MARK: - MyData vault

    static func vaultContent() -> WalletCardContent {
        .vault(VaultCard(
            title: NSLocalizedString("Nothing stored here", comment: "vault card title"),
            message: NSLocalizedString(
                "Import a financial, insurance, tax, property, or household document from MyData. Its protected original stays only on this phone.",
                comment: "vault card message"),
            status: NSLocalizedString("Sealed", comment: "vault card status")))
    }

    /// A held MyData original, kept visually in the graphite vault family rather
    /// than drawn as a credential. The source file has no holder key, issuer
    /// signature or disclosure semantics, so a credential face would promise
    /// properties it does not have and would also expose a meaningless flip side.
    static func vaultDocumentContent(_ document: MyDataVaultArchive.Document) -> WalletCardContent {
        let title = document.entry?.displayName
            ?? MyDataDocumentRegistry.lookup(id: document.id)?.title
            ?? UntrustedText.term(document.id).text
        let format = document.entry.flatMap { entry in
            entry.fileExtension.isEmpty
                ? nil
                : UntrustedText.term(entry.fileExtension.uppercased()).text
        } ?? NSLocalizedString("Unknown format", comment: "vault document card")
        let imported: String
        if let date = document.importedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            imported = String(format: NSLocalizedString("Imported %@", comment: "vault document card"),
                              formatter.string(from: date))
        } else {
            imported = NSLocalizedString("Import time unknown", comment: "vault document card")
        }
        return .vault(VaultCard(
            title: title,
            message: "\(format) · \(imported)",
            status: NSLocalizedString("Original stored", comment: "vault document card")))
    }

    // MARK: - Tint selection (a colour is not a claim)

    /// Picks a stable colour for a credential from its kind. This is the one
    /// place a card's kind steers presentation, and it is safe because a colour
    /// asserts nothing — a wrongly-green card is a cosmetic miss, not a false
    /// statement. Matched on substrings so a new transport or telecom card lands
    /// in the right family without a table that has to be exhaustive.
    static func tint(forCredentialType type: String, issuer: String, kind: String = "") -> WalletCardTint {
        // Include the curated friendly kind/issuer, not just the raw type + DID: a
        // real 台灣大哥大 card's `credentialType` is an opaque 「twmdiwvc_postpaid」
        // with no telecom word in it, so it used to fall through to the graphite
        // neutral — but its readable kind 「門號電子卡」 carries 「門號」 plainly.
        let hay = (type + " " + issuer + " " + kind).lowercased()
        let transport = ["driv", "licen", "vehicle", "road", "公路", "監理", "traffic", "駕照", "車籍"]
        let telecom = ["mobile", "telecom", "門號", "電信", "phone", "msisdn", "carrier",
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
