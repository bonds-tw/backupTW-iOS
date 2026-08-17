//
//  WallConfiguration.swift
//  backupTW
//
//  Where the Lennon Wall is, and how this app is allowed to talk to it.
//

import Foundation

/// The wall's address and the deadlines around it.
///
/// # This is the first time this app publishes anything
///
/// Every other network call here *fetches*: circuit material, a signature from
/// 內政部, a household record the holder asked for. This one puts something on a
/// public page. That difference is why the boundary is a type with tests rather
/// than a URL at a call site.
enum WallConfiguration {

    /// `https://bonds.tw/api/wall`.
    ///
    /// # Why a path on the site's own domain and not `wall.bonds.tw`
    ///
    /// Decided 2026-08-17, and the reason that settled it is this constant:
    /// **it is compiled into a binary that ships to phones.** The alternative on
    /// offer was `bonds-wall.gimmychang.workers.dev`, a personal account's
    /// subdomain — rename the account and every installed copy loses the wall
    /// permanently, with no way to push a fix to a phone that does not update.
    ///
    /// A subdomain would also have needed a DNS record, and the credential that
    /// configured this holds `zone:read`. The path route needed no zone write
    /// at all.
    ///
    /// `https`, and nothing in `Info.plist` relaxes App Transport Security for
    /// it. Cloudflare serves TLS 1.3 with forward secrecy, so default ATS
    /// passes; an exception for a host that does not need one is a permanent
    /// weakening, and an app that cannot be updated quickly should not pin a
    /// certificate that rotates.
    static let baseURL = URL(string: "https://bonds.tw/api/wall")!

    /// Paths under `baseURL`.
    ///
    /// ⚠️ `challenge` and `signZK` **are not routed yet** — the Worker
    /// dispatches reading and the open signature and nothing else, deliberately,
    /// until the go-live checklist passes. Asking for them today returns the
    /// Worker's own JSON 404, which is a named branch rather than a surprise.
    enum Path {
        static let read = ""
        static let challenge = "challenge"
        static let signZK = "sign-zk"
    }

    /// Fetching a challenge is one small round trip. If it cannot be had in
    /// twenty seconds, telling somebody now beats making them wait.
    static let challengeTimeout: TimeInterval = 20

    /// # Three deadlines, deliberately ordered
    ///
    /// The verifier's own `WriteTimeout` is 120 s and the Worker gives its
    /// subrequest 150 s, so this is 180 s. A client deadline **shorter** than
    /// the server's turns every slow-but-honest verification into a permanent
    /// "we do not know" — and the app's rule for that outcome is that it cannot
    /// promise nothing was published, which invites a second signature that
    /// costs another 身分證統一編號 disclosure to 內政部.
    static let submitRequestTimeout: TimeInterval = 180
    static let submitResourceTimeout: TimeInterval = 240

    /// A session that keeps nothing between the two calls.
    ///
    /// # The cookie jar is the point, and `.ephemeral` is not enough
    ///
    /// `.ephemeral` keeps cache, cookies and credentials **in memory** — which
    /// is still a jar. Cloudflare sets `__cf_bm` on Workers responses, so
    /// without the three lines below that cookie is stored when the challenge
    /// is fetched and sent back minutes later when the proof is submitted,
    /// tying the two calls together. That is precisely the link this wall is
    /// built to not have, and it would survive the user moving from mobile data
    /// to Wi-Fi in between — which is the case where the network layer would
    /// otherwise have lost the thread.
    ///
    /// `allowsConstrainedNetworkAccess = true`, deliberately the opposite of
    /// `CircuitAssets`: that one refuses Low Data Mode so a 950 MB download
    /// fails in a second instead of hanging. 254 KB does not have that problem,
    /// and someone in Low Data Mode is still entitled to sign.
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.httpAdditionalHeaders = ["accept": "application/json"]
        return configuration
    }

    /// Builds a URL under `baseURL`, or nil.
    ///
    /// Returns an optional rather than force-unwrapping: `baseURL` is a literal
    /// and the paths are literals, so this cannot fail today — and a crash on a
    /// wall address is the worst possible way to find out that stopped being
    /// true.
    static func url(for path: String) -> URL? {
        path.isEmpty ? baseURL : URL(string: path, relativeTo: baseURL.appendingPathComponent(""))
    }
}
