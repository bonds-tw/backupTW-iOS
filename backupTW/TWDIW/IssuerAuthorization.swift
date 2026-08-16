//
//  IssuerAuthorization.swift
//  backupTW
//
//  Deciding whether a URL that arrived in a QR code may be contacted at all.
//

import Foundation

/// One entry of the TWDIW trust list, reduced to what a wallet needs.
///
/// `displayName` and `displayNameEnglish` are **untrusted text**: they come from
/// a server and end up next to this app's own words on a screen. Route them
/// through `UntrustedText` before drawing them, the same as any claim value in
/// somebody else's document.
///
/// `group` is deliberately absent. The list carries an `orgGroupDetail.name`
/// which reads like a category and is not one: measured 2026-08-16, **all 43
/// production entries are labelled 「政府部門」**, and that set includes
/// FamilyMart, 7-Eleven, Chunghwa Telecom and Taiwan Mobile. A wallet that
/// rendered it would tell its user that a convenience store is a government
/// department, so this type does not carry the field at all — a value you cannot
/// hold is a value nobody can accidentally draw.
struct TWDIWIssuer: Equatable, Sendable {

    let did: String
    let displayName: String
    let displayNameEnglish: String
    let taxID: String

    /// Where this organisation's OID4VCI endpoints live, **in the list's own
    /// spelling**. This is the string to use once a match is made; see
    /// `IssuerAuthorization`.
    let issuerMetadataBaseURL: String?

    /// The organisation's service base, used by entries that are verifiers.
    let serviceBaseURL: String?

    /// Whether the list reports an on-chain anchoring record.
    ///
    /// ⚠️ Self-reported by the same API the anchor exists to make unnecessary,
    /// so `false` means "the list says so", not "we looked at the chain".
    /// Measured 2026-08-16: 41 of 43 report an anchor.
    let reportsOnChainAnchor: Bool
}

/// Whether a URL from a QR code may be contacted, and under whose name.
///
/// # Why this exists
///
/// Every URL in the OID4VCI collection flow arrives in a QR code, and one step
/// of that flow signs a proof JWT with the holder's key whose `aud` is a value
/// the same QR supplied. **Anyone who can put a QR in front of somebody can
/// otherwise make their wallet mint a signed JWT, addressed wherever the
/// attacker chose.**
///
/// This app already has a position on input of that kind, written on
/// `MOICACallbackRouter`: an inbound URL is untrusted, and may be treated as a
/// signal to go and check something — never as a result. The same rule applies
/// here, and the 43-entry trust list is what makes it enforceable offline.
///
/// # Two gates, because the interesting one comes first
///
/// The deep link carries `credential_offer_uri` — a URL to fetch the offer
/// *from*. So the first request leaves the device **before** there is any
/// `credential_issuer` to check, and its query string carries a subject
/// identifier. Checking the offer's contents after fetching it is checking too
/// late.
///
/// 1. `authorise(fetchURL:)` — may this URL be contacted at all? Host must
///    belong to the list.
/// 2. `confirm(credentialIssuer:matched:)` — the offer we got back must name an
///    issuer from the **same** organisation as the URL we fetched it from.
///
/// # No prefix matching, ever
///
/// `candidate.hasPrefix(trusted)` is the obvious implementation and it is
/// wrong: `https://issuer-oid4vci.wallet.gov.tw.evil.tw/` has
/// `https://issuer-oid4vci.wallet.gov.tw` as a prefix. Hosts are compared as
/// hosts — decomposed, lowercased, and equal.
///
/// Anything that cannot be normalised unambiguously is **refused rather than
/// repaired**. A URL with userinfo (`https://a@b/`), a trailing-dot host, a
/// non-ASCII host, an explicit non-443 port, or percent-encoded dots is not a
/// URL this wallet argues with.
enum IssuerAuthorization {

    enum Refusal: Error, Equatable {
        /// Not `https`.
        case notHTTPS
        /// No host, or a host this comparison will not attempt.
        case unusableHost
        /// `user:password@host` — the part before `@` is what browsers show and
        /// what people read, and it is not the host.
        case containsUserInfo
        /// An explicit port other than 443.
        case unexpectedPort(Int)
        /// A host that is not lowercase ASCII once normalised, or ends in a dot.
        /// Punycode and Unicode hosts are refused rather than folded: this list
        /// contains no such entries, so folding could only ever produce a match
        /// that should not exist.
        case hostNotPlainASCII
        /// `%2e`, `..`, or another path escape. Comparing paths that still have
        /// escapes in them compares two different things.
        case pathNotNormalised
        /// Well-formed, and not on the list.
        case notOnTheTrustList(host: String)
        /// The offer named an issuer belonging to a different organisation than
        /// the URL it came from.
        case organisationMismatch
    }

    enum Verdict: Equatable {
        /// Contact it. `canonicalBase` is **the trust list's spelling**, not the
        /// candidate's — see `authorise(fetchURL:against:)`.
        case allowed(issuers: [TWDIWIssuer], canonicalHost: String)
        case refused(Refusal)
    }

    // MARK: - Gate 1

    /// May this URL be contacted?
    ///
    /// Returns every list entry sharing the host, because a host can in
    /// principle belong to more than one registered organisation and it is gate
    /// 2's job to narrow that down. Returning the set rather than picking one
    /// keeps the ambiguity visible instead of resolving it by array order.
    static func authorise(fetchURL: String, against list: [TWDIWIssuer]) -> Verdict {
        let host: String
        switch normalisedHost(of: fetchURL) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let value): host = value
        }

        let matches = list.filter { issuer in
            [issuer.issuerMetadataBaseURL, issuer.serviceBaseURL]
                .compactMap { $0 }
                .contains { (try? normalisedHost(of: $0).get()) == host }
        }
        guard !matches.isEmpty else { return .refused(.notOnTheTrustList(host: host)) }
        return .allowed(issuers: matches, canonicalHost: host)
    }

    // MARK: - Gate 2

    /// The offer came back. Does the issuer it names belong to the organisation
    /// whose URL we fetched it from?
    ///
    /// - Parameter matched: the entries gate 1 returned.
    /// - Returns: the single issuer both gates agree on.
    static func confirm(credentialIssuer: String,
                        matched: [TWDIWIssuer]) -> Result<TWDIWIssuer, Refusal> {
        let host: String
        switch normalisedHost(of: credentialIssuer) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): host = value
        }

        let agreeing = matched.filter { issuer in
            [issuer.issuerMetadataBaseURL, issuer.serviceBaseURL]
                .compactMap { $0 }
                .contains { (try? normalisedHost(of: $0).get()) == host }
        }
        guard let only = agreeing.first, agreeing.count == 1 else {
            // Zero means the offer pointed somewhere else than the QR did. More
            // than one means the list cannot tell us who this is, and a wallet
            // that picked one would be inventing an answer to show the user.
            return .failure(.organisationMismatch)
        }
        return .success(only)
    }

    /// The base URL to actually use, **taken from the trust list rather than
    /// from the offer**.
    ///
    /// Once the host is agreed, nothing is gained by carrying the candidate's
    /// own bytes forward, and something is lost: the `aud` of the proof JWT
    /// would then be a string an attacker influenced (trailing slash, case,
    /// encoding) even though the host matched. Sign over our spelling.
    static func canonicalIssuerBase(for issuer: TWDIWIssuer) -> String? {
        issuer.issuerMetadataBaseURL ?? issuer.serviceBaseURL
    }

    // MARK: - Shape

    /// Decomposes a URL and refuses everything ambiguous.
    static func normalisedHost(of string: String) -> Result<String, Refusal> {
        guard let components = URLComponents(string: string) else {
            return .failure(.unusableHost)
        }
        guard components.scheme?.lowercased() == "https" else {
            return .failure(.notHTTPS)
        }
        if components.user != nil || components.password != nil {
            return .failure(.containsUserInfo)
        }
        if let port = components.port, port != 443 {
            return .failure(.unexpectedPort(port))
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(.unusableHost)
        }
        // A trailing dot is a legal, absolute DNS name that resolves to the same
        // place and is a different string. Two spellings of one host is exactly
        // what this comparison must not have.
        if host.hasSuffix(".") { return .failure(.hostNotPlainASCII) }
        let lowered = host.lowercased()
        guard lowered.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }) else {
            return .failure(.hostNotPlainASCII)
        }
        // `URLComponents.path` is already percent-decoded, so an escaped dot
        // arrives as a real one and `..` would be indistinguishable from a
        // literal segment. Look at the raw string instead.
        let raw = string.lowercased()
        if raw.contains("%2e") || raw.contains("/..") || raw.contains("..%2f") {
            return .failure(.pathNotNormalised)
        }
        return .success(lowered)
    }
}

// MARK: - Reading the list

extension TWDIWIssuer {

    /// Parses one page of `GET /api/did`.
    ///
    /// ⚠️ **Page until the result is empty; do not compute offsets from `size`.**
    /// Measured 2026-08-16: the page size is clamped to 20 while the offset
    /// appears to be derived from the requested `size`, so `size=100&page=1`
    /// returns nothing at all and a client that trusted `size` would conclude
    /// the list was 20 entries long. Both `orgType=1` (20) and `orgType=2` (23)
    /// were enumerated twice at two page sizes to establish the real totals.
    static func page(from json: Data) throws -> [TWDIWIssuer] {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let data = root["data"] as? [String: Any] else {
            return []
        }
        // A single-entry response puts the entry at `data`; a list puts an array
        // at `data.dids`. Both shapes are live.
        let entries: [[String: Any]]
        if let list = data["dids"] as? [[String: Any]] {
            entries = list
        } else if data["id"] is String {
            entries = [data]
        } else {
            entries = []
        }
        return entries.compactMap(TWDIWIssuer.init(entry:))
    }

    init?(entry: [String: Any]) {
        guard let did = entry["id"] as? String,
              let org = entry["org"] as? [String: Any] else { return nil }
        self.did = did
        self.displayName = org["name"] as? String ?? ""
        self.displayNameEnglish = org["name_en"] as? String ?? ""
        self.taxID = org["taxId"] as? String ?? ""
        self.issuerMetadataBaseURL = org["issuerMetadataBaseURL"] as? String
        self.serviceBaseURL = org["serviceBaseURL"] as? String
        self.reportsOnChainAnchor = !((entry["onChainHistory"] as? [Any]) ?? []).isEmpty
    }
}
