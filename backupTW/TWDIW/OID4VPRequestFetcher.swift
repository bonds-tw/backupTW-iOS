//
//  OID4VPRequestFetcher.swift
//  backupTW
//
//  Turning a scanned verifier link into a verified request — the network leg
//  M5.4 needs before anything can be signed.
//

import Foundation

/// Fetches and verifies an OID4VP request object from a scanned authorize link.
///
/// # Where this sits
///
/// `OID4VPAuthorizeLink.parse` reads the QR; `OID4VPRequest.verify` checks a
/// request object's signature and reduces it. This is the piece between them
/// for the by-reference form measured off `demo.wallet.gov.tw` (2026-08-26):
/// the QR carries `request_uri=https://verifier-oid4vp.wallet.gov.tw/api/oidvp/
/// request/<id>`, and the wallet must GET it to see the request object at all.
///
/// # The gate is before the GET, not after
///
/// The `request_uri` arrived in a QR, so it is untrusted input — the same
/// position `IssuerAuthorization.authorise(fetchURL:)` takes for a credential
/// offer. Its host is checked against the trusted set **before** the request
/// leaves the device; a verifier off the list cannot even make this wallet
/// perform a fetch it chose. After the object is fetched, `OID4VPRequest.verify`
/// applies the second gate — that the `response_uri` inside it is also trusted —
/// so nothing is signed for, or posted to, a host this wallet did not choose.
struct OID4VPRequestFetcher {

    let session: URLSession

    /// Hosts this wallet will fetch a request object from and post a token to.
    /// The verifier-side trust set, distinct from the issuer trust list.
    let trustedHosts: Set<String>

    /// Resolves a scanned link into a verified request.
    func fetch(_ link: OID4VPAuthorizeLink) async throws -> OID4VPRequest {
        switch link {
        case .byValue(let clientID, let requestObject):
            // Nothing to fetch; the object was inline. `verify` still gates the
            // response_uri.
            return try OID4VPRequest.verify(compactJWS: requestObject,
                                            clientID: clientID,
                                            trustedResponseHosts: trustedHosts)

        case .byReference(let clientID, let requestURI):
            // Gate 1: may this URL be contacted at all?
            switch IssuerAuthorization.normalisedHost(of: requestURI) {
            case .failure:
                throw OID4VPRequestError.requestURINotTrusted(host: requestURI)
            case .success(let host):
                guard trustedHosts.contains(host) else {
                    throw OID4VPRequestError.requestURINotTrusted(host: host)
                }
            }
            guard let url = URL(string: requestURI) else {
                throw OID4VPRequestError.requestURINotTrusted(host: requestURI)
            }

            let compactJWS = try await get(url)
            // Gate 2 is inside verify: the response_uri must be trusted too.
            return try OID4VPRequest.verify(compactJWS: compactJWS,
                                            clientID: clientID,
                                            trustedResponseHosts: trustedHosts)
        }
    }

    /// GETs the request object, which is served as a bare compact JWS string
    /// (measured: `Content-Type` is not JSON — the body is the token itself).
    private func get(_ url: URL) async throws -> String {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch { throw OID4VPRequestError.network }
        guard let http = response as? HTTPURLResponse else { throw OID4VPRequestError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw OID4VPRequestError.badStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OID4VPRequestError.malformedRequestObject
        }
        // Trim whitespace/newlines a server might frame the token with; the
        // compact JWS itself contains none.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
