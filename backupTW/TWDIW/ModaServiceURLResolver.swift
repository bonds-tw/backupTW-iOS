//
//  ModaServiceURLResolver.swift
//  backupTW
//
//  Turning a 皮夾夥伴卡 「申請卡片」 QR into the issuer page a holder finishes on.
//

import Foundation

/// A static 「要申請的卡」 QR, reduced to the two things needed to resolve it.
///
/// # What this QR is, and is not
///
/// Measured off the official app on 2026-08-27 (`CustomTabBarViewModel`,
/// `UserRepository.getStaticVerifiableCredential`, `ModaUrlPath.dwModa201i`):
/// some 皮夾夥伴卡 cannot hand you a credential offer straight away — the issuer
/// has to see you complete a flow first (電信卡 verifies the phone number on the
/// line, 駕照驗證卡 makes you log in to 監理服務網). Their printed QR therefore does
/// **not** carry a `modadigitalwallet://credential_offer` deep link. It carries a
/// plain `https` URL —
/// `https://frontend.wallet.gov.tw/api/moda/qrcode?mode=vc&vcUid=<UID>` — that
/// only *identifies which card* is being applied for. The deep link comes later,
/// out of the issuer's own web page, once the holder has done what the issuer
/// needs.
///
/// So this is not an offer and must never be parsed as one. `parse(scanned:)`
/// recognises exactly this shape and nothing else; anything that is not this
/// shape returns `nil`, so a real `openid-credential-offer` /
/// `modadigitalwallet` link falls straight through to `CredentialOfferLink` and
/// collects the way it always did. Widening this match is how an ordinary offer
/// would get swallowed here and never reach the gates.
enum ModaCardApplication {

    /// The vcUid and mode carried by a static card-application QR, or `nil` if the
    /// scanned string is not one.
    ///
    /// CR/LF are stripped first for the same reason `CredentialOfferLink.parse`
    /// does it: a scanner's input is bytes off a camera, and the official QR
    /// framing has been seen to wrap raw newlines into the query, which makes
    /// `URLComponents` read the following parameter name with a `\n` glued to its
    /// front and miss it. Undoing the framing here only undoes the framing — the
    /// percent-encoded values carry no newlines of their own.
    static func parse(scanned: String) -> (vcUid: String, mode: String)? {
        let cleaned = scanned
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: cleaned),
              // `https` only, matching the official QR — a plaintext `http` card
              // application is never legitimate, and resolving it would send the
              // vcUid over the clear before the issuer flow even opens.
              let scheme = url.scheme?.lowercased(), scheme == "https",
              // Host suffix, not equality: the live deployment answers on
              // `frontend.wallet.gov.tw`, but staging/UAT sit on siblings under the
              // same registrable domain. A suffix on `.wallet.gov.tw` (with the
              // leading dot, so `notwallet.gov.tw` cannot match) admits those and
              // nothing off-domain.
              let host = url.host?.lowercased(), host.hasSuffix(".wallet.gov.tw"),
              // The path the official QR uses for a card application. Exact, so a
              // `/api/moda/vcqrcode` relay page (a different official shape the
              // offer parser already unwraps) does not also match here.
              url.path == "/api/moda/qrcode",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let items = components.queryItems ?? []
        // `mode=vc` is what marks this as a verifiable-credential application, and
        // it is the value passed straight back to the resolve endpoint. Require it
        // present and non-empty rather than defaulting it, so a malformed QR is a
        // miss (falls through to the offer parser) rather than a guess.
        guard let mode = items.first(where: { $0.name == "mode" })?.value, !mode.isEmpty,
              let vcUid = items.first(where: { $0.name == "vcUid" })?.value, !vcUid.isEmpty
        else { return nil }

        return (vcUid: vcUid, mode: mode)
    }
}

/// The 201i (`DW-MODA-201i`) response: what the frontend says about the card being
/// applied for.
///
/// Every field is optional because the official client treats them as optional
/// (`CustomTabBarViewModel.getStaticVerifiableCredential` `guard let`s all three
/// and bails if any is missing). `Codable` here — not `JSONSerialization` — is a
/// deliberate departure from the offer parser: this document comes from the moda
/// frontend the app already trusts for the trust list itself, not from an
/// attacker-writable offer, and the fields are plain scalars a decoder cannot be
/// tricked by.
struct DwModa201iResponse: Codable, Equatable {
    /// `1` → the issuer flow opens in the system browser; anything else → inside a
    /// WKWebView. The official mapping is `isInside = type == 1 ? false : true`.
    let type: Int?
    /// The card's display name, used only to title the web screen.
    let name: String?
    /// The issuer's own page the holder finishes the application on. This is a URL
    /// the resolve step produced, loaded into a webview — it is **not** trusted to
    /// issue anything. Whatever deep link that page eventually hands back still
    /// goes through `CredentialOfferLink.parse` and both issuer gates before a
    /// credential is minted.
    let issuerServiceUrl: String?
}

enum ModaServiceURLResolverError: Error, Equatable {
    /// The request never completed, or the reply was not HTTP.
    case network
    /// The frontend answered, but not 2xx. `body` is its own words, kept so a
    /// failure can be read rather than guessed — the same lever
    /// `OID4VPResponseError.badStatus` keeps.
    case badStatus(Int, body: String?)
    /// A 2xx reply whose body was not the JSON shape expected.
    case malformedResponse
    /// The vcUid/mode/base could not be assembled into a valid URL.
    case badURL
}

/// Resolves a static card-application QR to its 201i response over the network.
enum ModaServiceURLResolver {

    /// The production frontend. Injectable rather than hard-coded at the call site
    /// so a test can point at nothing (the tests here never touch the network) and
    /// a UAT build can be aimed at staging without editing this file.
    static let productionFrontendBase = "https://frontend.wallet.gov.tw"

    /// `GET {frontendBase}/api/moda/dwapp/serviceUrl/{vcUid}?mode={mode}`.
    ///
    /// Uses `URLSession` and not a shell `curl`: the frontend sits behind a CDN
    /// that fingerprints and blocks `curl`'s TLS/HTTP signature but passes a native
    /// `URLSession` request, so the only reliable way to reach it from the app is
    /// the app's own stack — which is also the only one that ships.
    ///
    /// A non-2xx reply carries the server's body into the thrown error, matching
    /// `OID4VPResponse`'s handling, so a refusal is diagnosable off the frontend's
    /// own words.
    static func resolve(vcUid: String,
                        mode: String,
                        frontendBase: String = productionFrontendBase,
                        session: URLSession = .shared) async throws -> DwModa201iResponse {
        // Percent-encode the path segment and query value: a vcUid is server-chosen
        // and normally URL-safe, but assembling a URL by hand around untrusted
        // input without encoding is the shape of a path/parameter injection, so it
        // is encoded here regardless.
        guard let encodedUid = vcUid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: frontendBase + "/api/moda/dwapp/serviceUrl/" + encodedUid) else {
            throw ModaServiceURLResolverError.badURL
        }
        components.queryItems = [URLQueryItem(name: "mode", value: mode)]
        guard let url = components.url else {
            throw ModaServiceURLResolverError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ModaServiceURLResolverError.network }
        guard let http = response as? HTTPURLResponse else { throw ModaServiceURLResolverError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw ModaServiceURLResolverError.badStatus(http.statusCode,
                                                        body: String(data: data, encoding: .utf8))
        }
        guard let decoded = try? JSONDecoder().decode(DwModa201iResponse.self, from: data) else {
            throw ModaServiceURLResolverError.malformedResponse
        }
        return decoded
    }
}
