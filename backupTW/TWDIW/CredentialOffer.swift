//
//  CredentialOffer.swift
//  backupTW
//
//  What a credential-offer QR code actually said — and nothing more.
//

import Foundation

enum CredentialOfferError: Error, Equatable {
    /// Not an `openid-credential-offer` link at all.
    case notACredentialOffer
    /// The link carries both `credential_offer` and `credential_offer_uri`.
    /// OID4VCI says exactly one; a link that says two things is not argued
    /// with, because whichever one a wallet picked would be the attacker's
    /// choice presented as the wallet's.
    case ambiguousOfferForm
    /// Neither form present.
    case missingOfferForm
    /// The offer document is not a JSON object.
    case malformedOfferJSON
    /// No `credential_issuer`.
    case missingCredentialIssuer
    /// `credential_configuration_ids` missing, empty, or not strings.
    case missingConfigurationIDs
    /// The offer carries no pre-authorized code grant. The demo flow this
    /// module exists for is pre-authorized only; an authorization-code offer
    /// is a different protocol leg this wallet has not implemented, and
    /// naming that is more honest than a generic parse failure.
    case noPreAuthorizedGrant
}

/// The two ways an offer link can carry its offer.
///
/// Kept apart rather than resolved here: the by-reference form names a URL
/// that must pass `IssuerAuthorization.authorise(fetchURL:)` **before** any
/// request leaves the device, and collapsing the two forms too early is how
/// that check gets skipped for one of them.
enum CredentialOfferLink: Equatable {
    /// `credential_offer_uri=…` — a URL to fetch the offer from.
    case byReference(fetchURL: String)
    /// `credential_offer=…` — the offer document inline, percent-decoded.
    case byValue(json: String)

    /// The schemes a credential-offer link can arrive under.
    ///
    /// - `openid-credential-offer` is the OID4VCI standard, and the **only one
    ///   this app registers** (`Info.plist`). It is what a conformant issuer or
    ///   a QR generated to spec produces.
    /// - `modadigitalwallet` is 台灣數位憑證皮夾 官方 App 的自訂 scheme, measured
    ///   off `demo.wallet.gov.tw` on 2026-08-26: the deep link reads
    ///   `modadigitalwallet://credential_offer?credential_offer_uri=…`. It is
    ///   **understood but not registered** — registering it would fight the
    ///   official app for the same deep link, whose resolution iOS leaves
    ///   undefined. So a `modadigitalwallet` URL only reaches this parser when
    ///   the holder brought it in another way (a scanned QR, a paste), never by
    ///   the OS routing a tap to us.
    private static let offerSchemes: Set<String> = ["openid-credential-offer", "modadigitalwallet"]

    /// Reads a link from a **scanned string**, tolerating the framing a QR
    /// carries.
    ///
    /// Measured on device 2026-08-26: the official deep link embeds a CR+LF
    /// right after `credential_offer?` —
    /// `modadigitalwallet://credential_offer?\r\ncredential_offer_uri=…` — and a
    /// raw newline inside the query makes `URLComponents` read the parameter
    /// name as `\r\ncredential_offer_uri`, so the lookup for
    /// `credential_offer_uri` finds nothing and the whole thing is rejected as
    /// "not an offer". The card then silently would not scan. A scanner's input
    /// is bytes off a camera, not a URL the OS built, so the newlines are
    /// stripped and surrounding whitespace trimmed before a URL is formed.
    ///
    /// The percent-encoded `credential_offer_uri` value contains no raw
    /// newlines of its own, so removing them only undoes the malformed framing.
    static func parse(scanned: String) throws -> CredentialOfferLink {
        let cleaned = scanned
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: cleaned) else {
            throw CredentialOfferError.notACredentialOffer
        }
        // Unwrap the TWDIW relay page. Decoded off `demo.wallet.gov.tw/getcard`
        // on 2026-08-27, the demo cards' QR does not carry the deep link — it
        // carries a link to `frontend*.wallet.gov.tw/api/moda/vcqrcode?…
        // &deeplink=<base64url of the deep link>`, the page a phone bounces
        // through on its way to the wallet. Scanned by a third-party app that
        // page is just an `https` URL, so the card read as "not an offer" and
        // would not collect. Its `deeplink` parameter is the real thing; decode
        // it and parse that. The official 皮夾夥伴卡 encodes its deep link
        // directly and never reaches here. Nothing is trusted that the gates do
        // not re-check — the `credential_offer_uri` host inside still faces
        // gate 1 before any request leaves the device.
        if let deeplink = relayDeeplink(inside: url) {
            return try parse(scanned: deeplink)
        }
        return try parse(url)
    }

    /// The real deep link a TWDIW `vcqrcode` relay URL wraps, or `nil` if this is
    /// not that page.
    ///
    /// The inner deep link uses a custom scheme (`modadigitalwallet`), so it does
    /// not satisfy the `http(s)` guard on a second pass — the single unwrap in
    /// `parse(scanned:)` cannot loop.
    private static func relayDeeplink(inside url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host.hasSuffix(".wallet.gov.tw"),
              url.path.contains("vcqrcode"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: {
                  $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "deeplink"
              })?.value,
              let data = base64URLDecoded(encoded),
              let deeplink = String(data: data, encoding: .utf8)
        else { return nil }
        return deeplink
    }

    /// base64url (RFC 4648 §5) decoding: `-_` for `+/`, and padding that the URL
    /// form usually omits, restored before the standard decoder is asked.
    private static func base64URLDecoded(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    /// Reads a link, or says exactly why not.
    ///
    /// The scheme comparison is case-insensitive because URL schemes are;
    /// everything after that is bytes we hand on untouched. This function
    /// does not fetch, does not validate hosts, does not parse the offer —
    /// it answers one question: which of the two forms is this, and what is
    /// its payload.
    static func parse(_ url: URL) throws -> CredentialOfferLink {
        guard let scheme = url.scheme?.lowercased(), offerSchemes.contains(scheme) else {
            throw CredentialOfferError.notACredentialOffer
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CredentialOfferError.notACredentialOffer
        }
        // `modadigitalwallet://credential_offer?…` puts `credential_offer` in
        // the host position, so its query lands on `components`. A standard
        // `openid-credential-offer://?…` has an empty host and the same query.
        // Either way the parameters are read the same; the host word, when
        // present, must be `credential_offer` and nothing else.
        if let host = components.host, !host.isEmpty, host != "credential_offer" {
            throw CredentialOfferError.notACredentialOffer
        }
        let items = components.queryItems ?? []
        let byReference = items.first { $0.name == "credential_offer_uri" }?.value
        let byValue = items.first { $0.name == "credential_offer" }?.value

        switch (byReference, byValue) {
        case (.some, .some): throw CredentialOfferError.ambiguousOfferForm
        case (.some(let uri), .none): return .byReference(fetchURL: uri)
        case (.none, .some(let json)): return .byValue(json: json)
        case (.none, .none): throw CredentialOfferError.missingOfferForm
        }
    }
}

/// One parsed credential offer, reduced to what collection needs.
struct CredentialOffer: Equatable {

    /// The issuer identifier the offer names. **Untrusted** until
    /// `IssuerAuthorization.confirm(credentialIssuer:matched:)` has agreed it
    /// belongs to the organisation the offer was fetched from.
    let credentialIssuer: String

    /// Which credentials are on offer. The demo flow offers one; the type is
    /// a list because the field is, and picking `first` is the caller's
    /// decision to make where the user can see it.
    let configurationIDs: [String]

    let preAuthorizedCode: String

    /// Whether the token request must carry a transaction code the user is
    /// told out of band. Carried as a fact; prompting for it is UI's job.
    let requiresTransactionCode: Bool

    private static let preAuthorizedGrant = "urn:ietf:params:oauth:grant-type:pre-authorized_code"

    /// Parses the offer document.
    ///
    /// Reads with `JSONSerialization` rather than `Codable`, matching
    /// `TWDIWIssuer.page(from:)`: the shapes here are measured off a live
    /// deployment, not taken from a spec, and a decoder that silently drops
    /// a mis-typed field is exactly the wrong tool for a document an
    /// attacker may have written.
    static func parse(json: Data) throws -> CredentialOffer {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CredentialOfferError.malformedOfferJSON
        }
        guard let issuer = root["credential_issuer"] as? String, !issuer.isEmpty else {
            throw CredentialOfferError.missingCredentialIssuer
        }
        guard let ids = root["credential_configuration_ids"] as? [String], !ids.isEmpty else {
            throw CredentialOfferError.missingConfigurationIDs
        }
        guard let grants = root["grants"] as? [String: Any],
              let grant = grants[preAuthorizedGrant] as? [String: Any],
              let code = grant["pre-authorized_code"] as? String, !code.isEmpty else {
            throw CredentialOfferError.noPreAuthorizedGrant
        }
        return CredentialOffer(
            credentialIssuer: issuer,
            configurationIDs: ids,
            preAuthorizedCode: code,
            requiresTransactionCode: grant["tx_code"] != nil)
    }
}
