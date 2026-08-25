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

    /// Reads a link, or says exactly why not.
    ///
    /// The scheme comparison is case-insensitive because URL schemes are;
    /// everything after that is bytes we hand on untouched. This function
    /// does not fetch, does not validate hosts, does not parse the offer —
    /// it answers one question: which of the two forms is this, and what is
    /// its payload.
    static func parse(_ url: URL) throws -> CredentialOfferLink {
        guard url.scheme?.lowercased() == "openid-credential-offer" else {
            throw CredentialOfferError.notACredentialOffer
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
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
