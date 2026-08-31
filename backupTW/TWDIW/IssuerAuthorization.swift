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

    /// The signed DID document carried by the API under its historical `did`
    /// property. It is one of the strings written into the registry contract.
    let signedDIDDocument: String

    /// The API's organisation object, retained as JSON so it can be compared
    /// structurally with the organisation JSON in the registry transaction.
    let organisationJSON: String

    let orgType: Int
    let orgGroup: Int
    let apiUpdatedAt: Date?
    let onChainRecords: [TWDIWOnChainRecord]

    /// Whether the API reports an on-chain anchoring record. This remains a
    /// compatibility property for the collection gate and its fixtures; the
    /// trust screen does not treat it as verification.
    let reportsOnChainAnchor: Bool

    init(did: String,
         displayName: String,
         displayNameEnglish: String,
         taxID: String,
         issuerMetadataBaseURL: String?,
         serviceBaseURL: String?,
         reportsOnChainAnchor: Bool,
         signedDIDDocument: String = "",
         organisationJSON: String = "{}",
         orgType: Int = 0,
         orgGroup: Int = 0,
         apiUpdatedAt: Date? = nil,
         onChainRecords: [TWDIWOnChainRecord] = []) {
        self.did = did
        self.displayName = displayName
        self.displayNameEnglish = displayNameEnglish
        self.taxID = taxID
        self.issuerMetadataBaseURL = issuerMetadataBaseURL
        self.serviceBaseURL = serviceBaseURL
        self.reportsOnChainAnchor = reportsOnChainAnchor
        self.signedDIDDocument = signedDIDDocument
        self.organisationJSON = organisationJSON
        self.orgType = orgType
        self.orgGroup = orgGroup
        self.apiUpdatedAt = apiUpdatedAt
        self.onChainRecords = onChainRecords
    }
}

struct TWDIWOnChainRecord: Equatable, Sendable {
    let network: String
    let contractAddress: String
    let transactionHash: String
    let status: Int
    let createdAt: Date?
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
/// # Three checks, because the interesting ones come before the request
///
/// The deep link carries `credential_offer_uri` — a URL to fetch the offer
/// *from*. So the first request leaves the device **before** there is any
/// `credential_issuer` to check, and its query string carries a subject
/// identifier. Checking the offer's contents after fetching it is checking too
/// late.
///
/// 1. `authorise(fetchURL:)` — may this URL be contacted at all? Host must
///    belong to the list.
/// 2. `confirmRegistryEvidence(matched:verification:)` — the matching API row,
///    its successful historical transaction and the contract's current,
///    non-revoked state must agree before the issuer receives a request.
/// 3. `confirm(credentialIssuer:matched:)` — the offer we got back must name an
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
        /// The official API entry has no Arbitrum registry record.
        case trustRecordNotAnchored
        /// The API entry, its claimed transaction, or the contract's current
        /// state disagree. A historical transaction alone is not sufficient.
        case trustRecordMismatch
        /// Arbitrum could not be checked for this collection attempt, or a
        /// matching entry had no verification result. Nothing is cached as a
        /// substitute because that would make replay a successful fallback.
        case trustVerificationUnavailable
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

    /// Gate 1b: every API row that can account for this host must independently
    /// match the Arbitrum registry before the offer URL is contacted.
    ///
    /// Requiring every match matters on shared hosts. If one of three
    /// organisations on a host is unverified, host comparison cannot tell which
    /// row the still-unfetched offer represents; accepting because a different
    /// row verified would silently transfer its trust to the unverified one.
    static func confirmRegistryEvidence(
        matched: [TWDIWIssuer],
        verification: [String: TWDIWOnChainVerification]
    ) -> Result<Void, Refusal> {
        guard !matched.isEmpty else { return .failure(.trustVerificationUnavailable) }
        let results = matched.map { verification[$0.did] }
        if results.contains(where: { $0 == .mismatch }) {
            return .failure(.trustRecordMismatch)
        }
        if results.contains(where: { $0 == .notAnchored }) {
            return .failure(.trustRecordNotAnchored)
        }
        guard results.allSatisfy({ $0?.authorisesCollection == true }) else {
            return .failure(.trustVerificationUnavailable)
        }
        return .success(())
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
        // What gate 2 must establish is that the offer's issuer host is one of
        // the trusted hosts gate 1 allowed — not that exactly one *row* carries
        // it. Two facts in the production list break a strict count == 1, and
        // neither is an attack (measured 2026-08-26):
        //
        // - **A distinct DID per row is not a distinct organisation.** An org
        //   registered as both an issuer and a verifier is listed under both,
        //   and 行政院-數位發展部 (moda.wallet.gov.tw) is exactly this — so a card
        //   it issued matched two rows and was refused as if redirected. The
        //   official 皮夾夥伴卡 lands here.
        // - **One host can genuinely belong to several organisations.** Three
        //   universities share `dcert.wallet.gov.tw`, differing only by path.
        //
        // So this refuses only the case that matters — zero rows agree, meaning
        // the offer named a host the QR's host does not — and otherwise returns
        // one agreeing row. Which row is safe: `canonicalIssuerIdentifier` takes
        // the path from the offer, not from the row, so the several rows on a
        // shared host lead to the same signed `aud` regardless of which is
        // picked.
        guard let only = agreeing.first else {
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
        let rawHistory = (entry["onChainHistory"] as? [[String: Any]]) ?? []
        let records: [TWDIWOnChainRecord] = rawHistory.compactMap { value -> TWDIWOnChainRecord? in
            guard let network = value["net"] as? String,
                  let contract = value["scAddress"] as? String,
                  let hash = value["txHash"] as? String else { return nil }
            let created = (value["createdAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            return TWDIWOnChainRecord(network: network,
                                      contractAddress: contract,
                                      transactionHash: hash,
                                      status: (value["status"] as? NSNumber)?.intValue ?? 0,
                                      createdAt: created)
        }
        let orgJSON: String
        if let bytes = try? JSONSerialization.data(withJSONObject: org,
                                                   options: [.sortedKeys, .withoutEscapingSlashes]) {
            orgJSON = String(decoding: bytes, as: UTF8.self)
        } else {
            orgJSON = "{}"
        }
        self.init(did: did,
                  displayName: org["name"] as? String ?? "",
                  displayNameEnglish: org["name_en"] as? String ?? "",
                  taxID: org["taxId"] as? String ?? "",
                  issuerMetadataBaseURL: org["issuerMetadataBaseURL"] as? String,
                  serviceBaseURL: org["serviceBaseURL"] as? String,
                  reportsOnChainAnchor: !rawHistory.isEmpty,
                  signedDIDDocument: entry["did"] as? String ?? "",
                  organisationJSON: orgJSON,
                  orgType: (entry["orgType"] as? NSNumber)?.intValue ?? 0,
                  orgGroup: (entry["orgGroup"] as? NSNumber)?.intValue ?? 0,
                  apiUpdatedAt: (entry["updatedAt"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                  },
                  onChainRecords: records)
    }
}

#if DEBUG
extension TWDIWIssuer {

    /// The `demo.wallet.gov.tw` sandbox issuer, added to the gate **only in
    /// DEBUG**.
    ///
    /// Measured 2026-08-26 (`docs/m52-live-collection-2026-08-26.md` §七): the
    /// demo issuer host `issuer-oid4vci.wallet.gov.tw` is **not** among the 43
    /// production entries of `frontend.wallet.gov.tw/api/did`. Sandbox and
    /// production are separate trust domains, so a wallet that gates on the
    /// production list refuses demo collection — correctly, for a release
    /// build.
    ///
    /// This entry exists so a DEBUG build can act as the **one** party that
    /// dereferences a demo offer (the role a QR scan plays for the official
    /// app), which is the only way to measure whether the token endpoint
    /// accepts `client_id=tw.bonds.backupTW`. It is compiled out of Release
    /// entirely — a shipped wallet trusts the production list and nothing else.
    static let sandboxDemo = TWDIWIssuer(
        did: "did:key:sandbox-demo",
        displayName: "數位憑證皮夾 Demo 沙盒",
        displayNameEnglish: "TWDIW Demo Sandbox",
        taxID: "00000000",
        issuerMetadataBaseURL: "https://issuer-oid4vci.wallet.gov.tw",
        serviceBaseURL: nil,
        reportsOnChainAnchor: false)
}
#endif
