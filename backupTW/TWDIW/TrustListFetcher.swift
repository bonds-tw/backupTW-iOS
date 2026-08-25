//
//  TrustListFetcher.swift
//  backupTW
//
//  The 43 organisations, fetched the only way that returns all of them.
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
                guard let url = URL(string: "\(base)?size=20&page=\(page)&orgType=\(orgType)&status=1") else {
                    throw TrustListFetcherError.network
                }
                let data: Data
                let response: URLResponse
                do { (data, response) = try await session.data(from: url) }
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
        return all
    }
}
