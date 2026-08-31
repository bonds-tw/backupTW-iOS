//
//  TrustListFetcher.swift
//  backupTW
//
//  Every production organisation, fetched with the API's measured paging rules.
//

import Foundation

enum TrustListFetcherError: Error, Equatable {
    case network
    case badStatus(Int)
    /// Zero entries across every page. A live deployment has never answered
    /// this; an empty list would authorise nothing, so it is an error rather
    /// than a valid answer — a wallet holding it would refuse every issuer
    /// and tell the user the issuer is the problem.
    case emptyList
}

/// Fetches the TWDIW trust list from the production registry.
///
/// This is **not** this app's own `TrustList` (the offline commitment model in
/// `Presentation/`), and deliberately so — see `docs/twdiw-integration-plan.md`
/// §四: the TWDIW list is an HTTPS API with an on-chain anchor, and treating
/// it as our offline list would conflate two different trust models. It is
/// fetched fresh, used to gate one collection, and not persisted.
struct TrustListFetcher {

    let session: URLSession
    var base = "https://frontend.wallet.gov.tw/api/did"

    /// Every entry, both organisation types.
    ///
    /// `size=20` is not a tunable: the server clamps the page size to 20 while
    /// deriving the offset from the size **as requested**, so any larger value
    /// skips entries silently (measured 2026-08-16, `TWDIWIssuer.page`'s own
    /// warning). Paging continues until a page comes back empty; the total is
    /// never taken from a count field, because the API's counts are what the
    /// measurement found untrustworthy.
    func fetchAll() async throws -> [TWDIWIssuer] {
        var all: [TWDIWIssuer] = []
        for orgType in [1, 2] {
            var page = 0
            while true {
                let request = try request(page: page, orgType: orgType)
                let data: Data
                let response: URLResponse
                do { (data, response) = try await session.data(for: request) }
                catch { throw TrustListFetcherError.network }
                guard let http = response as? HTTPURLResponse else {
                    throw TrustListFetcherError.network
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw TrustListFetcherError.badStatus(http.statusCode)
                }
                let entries = (try? TWDIWIssuer.page(from: data)) ?? []
                if entries.isEmpty { break }
                all += entries
                page += 1
            }
        }
        guard !all.isEmpty else { throw TrustListFetcherError.emptyList }

        // Deduplicate by DID. Both org types are fetched because either can be
        // the issuer of a card, but an organisation registered as both — like
        // 行政院-數位發展部 — is listed in both and would otherwise appear twice.
        // Two rows for one DID made the issuer gate see an ambiguity that is
        // not one, refusing a card the org legitimately issued. The DID is the
        // organisation's identity here, so it is the key that collapses them.
        var seen = Set<String>()
        return all.filter { seen.insert($0.did).inserted }
    }

    /// A trust decision must not be made from URLCache or an intermediary's
    /// replay of an older response. Registry entries themselves are long-lived,
    /// so their `updatedAt` age is not an expiry signal; freshness here means
    /// fetching the API again and comparing it with the contract's *current*
    /// state for this collection attempt.
    func request(page: Int, orgType: Int) throws -> URLRequest {
        guard let url = URL(string: "\(base)?size=20&page=\(page)&orgType=\(orgType)&status=1") else {
            throw TrustListFetcherError.network
        }
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 20)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }
}
