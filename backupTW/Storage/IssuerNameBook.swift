//
//  IssuerNameBook.swift
//  backupTW
//
//  The locally remembered names of trust-listed issuers, keyed by DID.
//
//  # Why this exists
//
//  A card face used to show a truncated `did:key` for any issuer whose card
//  *type* the curated `IssuerDirectory` did not know — even though the issuer
//  itself sat on the 數位發展部 trust list with a perfectly good display name,
//  because that list lives behind a network fetch and card faces must render
//  offline (回報 2026-09-02). The fix is a tiny local book: every time the
//  trust list is fetched anyway (a collection, opening the trust centre), the
//  DID→name pairs are written down, and the card face can consult them with
//  no network at all.
//
//  # Trust boundary
//
//  Names enter only from `TrustListFetcher` results — the same fetch the
//  collection gates trust — and are laundered through `UntrustedText` on the
//  way out, so a hostile display name cannot carry rewriting code points onto
//  a glanceable surface. The book maps DIDs to names; it makes no trust
//  decision. A card is in the store because it passed both gates, and this
//  book only puts a readable name to the issuer those gates already vouched
//  for — the identical argument `IssuerDirectory` documents for its curated
//  table.
//
//  Erased by `LocalDataEraser`: the book is issuer-level, not personal, but
//  「erase all local data」 means all.
//

import Foundation

enum IssuerNameBook {

    private static let queue = DispatchQueue(label: "tw.bonds.backupTW.issuer-name-book")
    private static var cache: [String: String]?

    private static var fileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("issuer-name-book.json", isDirectory: false)
    }

    /// Writes down the display names of a freshly fetched trust list. Merges —
    /// an issuer that left the list keeps its remembered name, because the
    /// cards it issued are still in the wallet and still deserve a label.
    static func remember(_ issuers: [TWDIWIssuer]) {
        queue.sync {
            var book = loadLocked()
            for issuer in issuers {
                let name = issuer.displayName.isEmpty ? issuer.displayNameEnglish : issuer.displayName
                guard !issuer.did.isEmpty, !name.isEmpty else { continue }
                book[issuer.did] = name
            }
            cache = book
            guard let url = fileURL,
                  let data = try? JSONEncoder().encode(book) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// The remembered name for an issuer DID, sanitised for display, or nil.
    static func name(for did: String) -> String? {
        queue.sync {
            guard let raw = loadLocked()[did] else { return nil }
            let cleaned = UntrustedText.term(raw).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    static func erase() {
        queue.sync {
            cache = [:]
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func loadLocked() -> [String: String] {
        if let cache { return cache }
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().decode([String: String].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = book
        return book
    }
}
