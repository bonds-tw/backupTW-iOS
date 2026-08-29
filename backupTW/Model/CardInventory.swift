//
//  CardInventory.swift
//  backupTW
//
//  Every card this phone holds, as rows, each one saying which kind it is.
//

import Foundation

/// One row of the home screen's card list.
struct CardInventoryRow: Equatable, Sendable {

    /// Whether the card is usable right now, said plainly rather than implied
    /// by the card's absence.
    enum State: Equatable, Sendable {
        case usable
        case expired
        /// Stored, and this build cannot read it. Still a row — see the note on
        /// `rows(from:now:)`.
        case unreadable
    }

    let id: String
    let source: StoredCardSource

    /// The honest account of what this *kind* of card can and cannot do, or nil
    /// when the kind is not one this app knows.
    let capability: CardCapability?

    /// What the row is called. Never a field out of the credential.
    let title: String

    /// One line under the title. Never a claim value — see below.
    let detail: String

    let state: State
}

/// Turns the credential store into the home screen's list.
///
/// # Why this is a pure function and not a method on the view controller
///
/// Three of the decisions below are wrong in ways that are invisible on a
/// screenshot — an unreadable card silently missing, an unstable order, a claim
/// value leaking onto a glanceable surface. Each of those is one line here and
/// one test there. Inside `HomeViewController` they would be none of either.
enum CardInventory {

    /// # A card that cannot be read still gets a row
    ///
    /// The tempting shape is `compactMap` — read each stored credential, keep
    /// the ones that parse. It produces a clean list and a bad failure: a card
    /// the holder collected, that is sitting in the store right now, simply is
    /// not on the screen. From the holder's side that is indistinguishable from
    /// the app having lost it, and the reasonable response is to go and collect
    /// it again — which, for a government-issued card, may mean a counter visit.
    ///
    /// So every identifier in the store becomes a row. Reading is what decides
    /// what the row *says*, never whether it exists.
    ///
    /// # The order is ours, not the store's
    ///
    /// `allIDs()` returns directory order. It is stable enough in practice to
    /// look deliberate and unstable enough to reorder the holder's cards after
    /// an unrelated write — the worst combination, because nobody tests for a
    /// bug they cannot reproduce. Ours first (it is the document this app is
    /// about), then by identifier.
    ///
    /// # What a row may not contain
    ///
    /// No claim value. The home screen is the most over-the-shoulder-readable
    /// surface in the app, and `StoredNationalID` already refuses to summarise
    /// named fields here for that reason.
    ///
    /// The card *kind* is different, and is shown: which cards a person holds is
    /// what a wallet is for, and a list of blank rectangles would be unusable to
    /// avoid disclosing something the holder is about to hand over anyway.
    static func rows(from store: CredentialStoring, now: Date = Date()) -> [CardInventoryRow] {
        let ids = (try? store.allIDs()) ?? []
        return ids
            .map { row(for: $0, in: store, now: now) }
            .sorted { left, right in
                if (left.source == .selfIssued) != (right.source == .selfIssued) {
                    return left.source == .selfIssued
                }
                return left.id < right.id
            }
    }

    private static func row(for id: String,
                            in store: CredentialStoring,
                            now: Date) -> CardInventoryRow {
        // One binding, not two: `try?` on an already-optional result flattens,
        // so "the store threw" and "the store had nothing" arrive as the same
        // nil. That is fine *here* — both mean the row cannot be filled in — but
        // it is the same flattening that hid a real distinction in `DeviceKey`,
        // so it is worth saying which case this is.
        guard let serialized = try? store.load(id: id) else {
            // In the store's index but not readable back. Rare, and the one
            // case where saying nothing would be actively misleading.
            return CardInventoryRow(
                id: id, source: .unrecognised, capability: nil,
                title: NSLocalizedString("Unreadable card", comment: "card list"),
                detail: NSLocalizedString("It is listed on this phone but could not be opened.", comment: ""),
                state: .unreadable)
        }

        switch StoredCardSource.source(of: serialized) {
        case .selfIssued:
            return selfIssuedRow(id: id, store: store)
        case .twdiw:
            return twdiwRow(id: id, serialized: serialized, now: now)
        case .unrecognised:
            return CardInventoryRow(
                id: id, source: .unrecognised, capability: nil,
                title: NSLocalizedString("Unreadable card", comment: "card list"),
                detail: NSLocalizedString("This version of the app does not recognise this card's format.", comment: ""),
                state: .unreadable)
        }
    }

    private static func selfIssuedRow(id: String, store: CredentialStoring) -> CardInventoryRow {
        // A vault document — any registered self-issued document that is not the
        // national ID — carries its document-type title and is routed to the
        // 資料保險箱 by the home screen (via `MyDataDocumentRegistry.isVaultDocument`),
        // rather than the national-ID section, which only ever shows one card.
        if MyDataDocumentRegistry.isVaultDocument(id: id),
           let type = MyDataDocumentRegistry.lookup(id: id) {
            return CardInventoryRow(
                id: id, source: .selfIssued, capability: .selfIssued,
                title: type.title,
                detail: NSLocalizedString("Held by you · from MyData", comment: "vault document origin"),
                state: .usable)
        }
        // `StoredNationalID.load` is keyed to the one canonical identifier, so a
        // second self-issued document — which nothing creates today — gets the
        // kind's own sentence rather than a count belonging to another card.
        guard id == StoredNationalID.credentialID,
              let stored = StoredNationalID.load(from: store) else {
            return CardInventoryRow(
                id: id, source: .selfIssued, capability: .selfIssued,
                title: CardCapability.selfIssued.name,
                detail: CardCapability.selfIssued.origin,
                state: .usable)
        }
        return CardInventoryRow(
            id: id, source: .selfIssued, capability: .selfIssued,
            title: CardCapability.selfIssued.name,
            detail: String(format: NSLocalizedString("%d fields · created %@", comment: "credential summary"),
                           stored.claims.count, stored.createdDescription()),
            state: .usable)
    }

    private static func twdiwRow(id: String, serialized: String, now: Date) -> CardInventoryRow {
        guard let credential = try? TWDIWCredentialReader.read(serialized, now: now) else {
            // Reached by a card whose signature does not verify as well as by
            // one that is malformed, and the row does not distinguish them.
            // Deliberate: a home screen that announced "this card's signature is
            // invalid" would be making an accusation from a glance, and the
            // holder can do nothing with it either way. The card opens; the
            // screen that can explain properly does the explaining.
            return CardInventoryRow(
                id: id, source: .twdiw, capability: .twdiw,
                title: CardCapability.twdiw.name,
                // ⚠️ 「could not be checked」 is ambiguous in English and the
                // Chinese picked the wrong half of it: 「沒能通過檢查」 is a
                // verdict — checked, and failed. What is true is that the check
                // could not be *carried out*, which is what the comment above
                // says this row must not turn into an accusation.
                //
                // And the row now says what the tap gives you. It used to say
                // 「open it for details」 while the only thing on the other side
                // was an alert claiming the opposite: 「this build cannot read
                // it」, which is a confident story about a card that may be
                // perfectly well-formed with a signature that does not match.
                // Two screens, two mutually exclusive certainties, and the true
                // sentence the comment was protecting — that it could be either
                // — said by neither.
                detail: NSLocalizedString("This card could not be read or checked.", comment: ""),
                state: .unreadable)
        }

        // Through the untrusted pipe, like every other string that arrived
        // inside a credential: the type is chosen by the issuer, and a newline
        // or a bidi override in it would rearrange the list around it.
        //
        // `value`, not `term`, despite this being closer to a field name in
        // spirit. `term`'s cap is 40 characters and the production type strings
        // are 41 (`00000000_demo_drivinglicense_202504251418`), so every real
        // card would arrive with its date truncated — and two cards issued in
        // different months would then read identically.
        let kind = UntrustedText.value(Self.readableType(credential.credentialType)).text
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let detail: String
        let expired: Bool
        if credential.expires == .distantFuture {
            // `TWDIWCredentialReader` substitutes `.distantFuture` when the
            // credential carries no `exp` at all, so this is not a card that
            // expires in the year 4001 — it is a card with nothing said about
            // when it stops being true. Printing the substituted date would
            // turn a missing statement into a confident one, which is the
            // failure this whole app is written against.
            detail = String(format: NSLocalizedString("%@ · no expiry date given", comment: "card list"), kind)
            expired = false
        } else if credential.expires <= now {
            detail = String(format: NSLocalizedString("%@ · expired %@", comment: "card list"),
                            kind, formatter.string(from: credential.expires))
            expired = true
        } else {
            detail = String(format: NSLocalizedString("%@ · valid until %@", comment: "card list"),
                            kind, formatter.string(from: credential.expires))
            expired = false
        }

        return CardInventoryRow(
            id: id, source: .twdiw, capability: .twdiw,
            title: CardCapability.twdiw.name,
            detail: detail,
            state: expired ? .expired : .usable)
    }

    /// # A TWDIW card has no name a person can read
    ///
    /// This came out of rendering the screen and looking at it. The row read
    /// `00000000_demo_drivinglicense_202504251418`, forty-one characters of
    /// machine identifier wrapped over two lines, under a title that promised a
    /// card. That is what the credential actually carries: `vc.type[1]` is the
    /// only name inside it, and the human-readable one lives in the issuer's
    /// online metadata (`credential_configurations_supported[…].display[].name`)
    /// — which a wallet that is offline, by design, cannot see. **A card in a
    /// wallet with no offline human-readable name is a finding**, and it is
    /// recorded as one rather than papered over here.
    ///
    /// What this does is the small honest part: drop the two segments that are
    /// meaningless to the holder — a leading all-digit issuer code and a
    /// trailing issuance timestamp — and show the rest. No table of known types,
    /// because a table is a guess about every type it does not contain, and the
    /// unknown ones are exactly where a wrong guess would matter.
    ///
    /// Both edits are conditional on the shape being there, and the original is
    /// returned whenever stripping would leave nothing. A type that does not
    /// look like this arrives on the screen exactly as issued.
    static func readableType(_ raw: String) -> String {
        var parts = raw.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2 else { return raw }

        if let first = parts.first, !first.isEmpty, first.allSatisfy(\.isNumber) {
            parts.removeFirst()
        }
        if let last = parts.last, (8...14).contains(last.count), last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }

        let stripped = parts.joined(separator: "_")
        return stripped.isEmpty ? raw : stripped
    }
}
