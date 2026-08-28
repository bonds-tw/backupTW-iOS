//
//  TelecomCardCatalog.swift
//  backupTW
//
//  The 「申請新卡」 directory, reduced to the telecom 門號電子卡 a holder can start.
//

import Foundation

/// One entry of the official 「申請新卡」 catalogue, kept to what the apply flow
/// needs.
///
/// Measured off the official frontend on 2026-08-28:
/// `GET https://frontend.wallet.gov.tw/api/moda/dwapp/apply/vcList?name=&page=0&size=50`
/// (no login) answers `{code,message,data:{vcItems:[…],totalPages,…}}`, and each
/// `vcItems` entry carries a `vcUid`, a display `name`, a `type`, and — for the
/// cards that finish inside a partner's own app or web page — an
/// `issuerServiceUrl`. The three telecom 門號電子卡 are all `type == 1`, meaning
/// the issuer flow opens in an external app/browser rather than an embedded
/// webview (the same `type == 1 → 外開` mapping `DwModa201iResponse` documents):
/// the holder is sent to the carrier to verify the phone number on the line, and
/// the carrier's app hands the credential offer back over the
/// `modadigitalwallet://credential_offer` deep link this app now registers.
struct TelecomCard: Equatable {
    let vcUid: String
    let name: String
    /// Where applying for this card begins — the carrier's own entry URL. Opened
    /// externally (`type == 1`); it is **not** trusted to issue anything. The
    /// offer the carrier eventually returns still passes both
    /// `IssuerAuthorization` gates before a credential is minted.
    let issuerServiceUrl: String
    /// `1` → the apply flow opens externally (every telecom card). Carried so the
    /// caller decides where to open, rather than this type assuming it.
    let type: Int
}

enum TelecomCardCatalogError: Error, Equatable {
    /// The request never completed, or the reply was not HTTP.
    case network
    /// The frontend answered, but not 2xx. `body` is its own words, kept so a
    /// failure can be read rather than guessed — the same lever
    /// `ModaServiceURLResolverError.badStatus` and `OID4VPResponseError` keep.
    case badStatus(Int, body: String?)
    /// A 2xx reply whose body was not the `{data:{vcItems:[…]}}` shape expected.
    case malformedResponse
    /// The base could not be assembled into a valid URL.
    case badURL
}

/// Fetches the official 「申請新卡」 catalogue and keeps only the telecom 門號電子卡.
enum TelecomCardCatalog {

    /// The production frontend. Injectable rather than hard-coded at the call
    /// site, matching `ModaServiceURLResolver.productionFrontendBase`: a test can
    /// point at nothing (the tests here never touch the network) and a UAT build
    /// can be aimed at staging without editing this file.
    static let productionFrontendBase = "https://frontend.wallet.gov.tw"

    /// `GET {frontendBase}/api/moda/dwapp/apply/vcList?name=&page=0&size=50`,
    /// filtered to the telecom 門號電子卡.
    ///
    /// Uses `URLSession`, not a shell `curl`, for the same reason
    /// `ModaServiceURLResolver` does: the frontend sits behind a CDN that
    /// fingerprints and blocks `curl`'s TLS/HTTP signature but passes a native
    /// `URLSession` request. A non-2xx reply carries the server's body into the
    /// thrown error so a refusal is diagnosable off the frontend's own words.
    static func fetch(frontendBase: String = productionFrontendBase,
                      session: URLSession = .shared) async throws -> [TelecomCard] {
        guard var components = URLComponents(string: frontendBase + "/api/moda/dwapp/apply/vcList") else {
            throw TelecomCardCatalogError.badURL
        }
        // The official directory call: an empty `name` (no search filter), the
        // first page, and a page size large enough to hold the whole catalogue in
        // one reply — the three telecom cards sit among a few dozen entries.
        components.queryItems = [
            URLQueryItem(name: "name", value: ""),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "size", value: "50"),
        ]
        guard let url = components.url else {
            throw TelecomCardCatalogError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw TelecomCardCatalogError.network }
        guard let http = response as? HTTPURLResponse else { throw TelecomCardCatalogError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw TelecomCardCatalogError.badStatus(http.statusCode,
                                                    body: String(data: data, encoding: .utf8))
        }
        return try telecomCards(fromVCListJSON: data)
    }

    /// The parse, split off from the fetch so it can be exercised with a canned
    /// body and never a socket.
    ///
    /// # Why `Codable` here, not `JSONSerialization`
    ///
    /// This catalogue comes from the moda frontend the app already trusts for the
    /// trust list itself (`TrustListFetcher`), not from an attacker-writable
    /// offer, and every field read is a plain scalar a decoder cannot be tricked
    /// by. That is the same call `ModaServiceURLResolver` made for `DwModa201i`,
    /// and the opposite of the one `CredentialOffer` makes for an offer document.
    ///
    /// The raw item mirror is all-optional because the directory is a list the
    /// app does not control: one entry missing a field must drop that entry, not
    /// fail the whole fetch and hide the telecom cards behind an unrelated row.
    static func telecomCards(fromVCListJSON data: Data) throws -> [TelecomCard] {
        struct Envelope: Decodable { let data: Payload? }
        struct Payload: Decodable { let vcItems: [RawItem]? }
        struct RawItem: Decodable {
            let vcUid: String?
            let name: String?
            let type: Int?
            let issuerServiceUrl: String?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let items = envelope.data?.vcItems else {
            throw TelecomCardCatalogError.malformedResponse
        }

        return items.compactMap { item -> TelecomCard? in
            // An entry with no service URL cannot start an application, so it is
            // dropped rather than shown as a dead row.
            guard let vcUid = item.vcUid, !vcUid.isEmpty,
                  let name = item.name, !name.isEmpty,
                  let issuerServiceUrl = item.issuerServiceUrl, !issuerServiceUrl.isEmpty else {
                return nil
            }
            // Keep only the telephone-number cards. The three carriers all name
            // their card 「…門號電子卡」 (two also carry 「電信」), so matching either
            // 「電信」 or 「門號」 admits them and nothing else in the catalogue —
            // a 駕照 or 學生證 entry never contains either word. A name-substring
            // filter is deliberately conservative: it never guesses a card *in*
            // that a checker later cannot start, only leaves an ambiguous one out.
            guard name.contains("電信") || name.contains("門號") else { return nil }
            // `type` defaults to 1 (external open) when absent: every telecom card
            // measured is `type == 1`, and an external-open assumption for a card
            // that reached this filter is the safe one — the alternative would
            // silently drop a telecom card over a missing scalar.
            return TelecomCard(vcUid: vcUid,
                               name: name,
                               issuerServiceUrl: issuerServiceUrl,
                               type: item.type ?? 1)
        }
    }
}
