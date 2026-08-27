//
//  OID4VPResponse.swift
//  backupTW
//
//  Building the signed vp_token a verifier asked for, and posting it back.
//

import CryptoKit
import Foundation

enum OID4VPResponseError: Error, Equatable {
    /// No stored card matches the type the request required.
    case noMatchingCredential
    /// The request asked for a claim the matched card does not disclose. Named
    /// rather than silently dropped: a verifier expecting a field, and a token
    /// that omits it, should fail with a reason, not a shrug.
    case requestedClaimNotAvailable(String)
    /// The device does not hold the key this card is bound to, so it cannot
    /// present it. One key per card (`HolderKeyring`) means the presenting key
    /// is the card's own — never `DeviceKey.defaultTag`.
    case holderKeyUnavailable
    case network
    /// The verifier refused the posted token. `body` is what it said — captured
    /// so a refusal can be diagnosed the way the collection 400 was, off the
    /// server's own words rather than a guess about the format. Surfaced to the
    /// holder only in DEBUG; a shipped wallet shows the number, not the verifier's
    /// raw reply.
    case badStatus(Int, body: String?)
}

/// Builds and sends the response to an `OID4VPRequest`.
///
/// # The two deviations this deliberately reproduces
///
/// Both measured against production, both load-bearing, both commented so a
/// later reader does not "fix" them into breaking interop (see
/// `docs/twdiw-integration-plan.md` §一.H.2 / §三 M5.4):
///
/// 1. **`aud` is prefixed with `redirect_uri:`.** The verifier checks the token's
///    audience against `redirect_uri:<response_uri>`, literally — the prefix is
///    part of the string, not a description of it. Sign over exactly that.
/// 2. **The VP claim uses `context`, not `@context`.** Measured: the official
///    verifier does no JSON-LD expansion and reads the presentation by the
///    literal key `context`, which is what the official app emits. Sending a
///    spec-correct `@context` would hand it a document missing the `context`
///    key it looks for. Copying the spelling is how the presentation is
///    actually received.
///    ⚠️ The mirror-image cost, stated so nobody thinks this is free: a
///    *conformant* JSON-LD verifier that DOES expand would drop this VP's
///    claims, because `context` is not the `@context` keyword. That is the
///    interop defect worth reporting (see `docs/upstream-reports.md` A6, which
///    corrects an earlier, wrong version of this very reasoning — "JSON-LD
///    processing silently drops the claims" was false, because TWDIW's own
///    verifier loses nothing today). It is not a current data-loss bug. When
///    TWDIW fixes this upstream, this must change back to `@context` — a
///    compatibility shim with an expiry, not this app's own spelling.
struct OID4VPResponder {

    let session: URLSession
    let store: CredentialStoring
    let keyring: HolderKeyring
    var now: () -> Date = Date.init

    /// Runs the whole response: pick the card, disclose only what was asked,
    /// sign the token with that card's key, post it back.
    ///
    /// - Parameter disclosing: the claim names the user chose to reveal. Must be
    ///   a subset of what the request asked for — the UI narrows the request's
    ///   fields to the user's selection, and this method reveals exactly those.
    @discardableResult
    func respond(to request: OID4VPRequest,
                 disclosing chosenClaims: Set<String>) async throws -> Int {
        let (credential, presented) = try matchAndDisclose(request, chosenClaims: chosenClaims)

        guard let holderKey = try? keyring.key(matchingPublicKeyX963: credential.holderKey.x963Representation) else {
            throw OID4VPResponseError.holderKeyUnavailable
        }
        let vpToken = try buildVPToken(request: request, presented: presented, holderKey: holderKey)
        let submission = presentationSubmission(for: request)

        return try await post(vpToken: vpToken, submission: submission, state: request.state,
                              to: request.responseURI)
    }

    // MARK: - Selection

    /// Finds the stored card the request wants and produces its serialization
    /// carrying only the chosen disclosures.
    func matchAndDisclose(_ request: OID4VPRequest,
                          chosenClaims: Set<String>) throws -> (TWDIWCredential, String) {
        for id in (try? store.allIDs()) ?? [] {
            guard let serialized = try? store.load(id: id),
                  StoredCardSource.source(of: serialized) == .twdiw,
                  let credential = try? TWDIWCredentialReader.read(serialized) else { continue }
            if let wanted = request.credentialType, credential.credentialType != wanted { continue }

            // Every claim the user chose must actually be on the card.
            let available = Set(credential.disclosedClaims.map(\.name))
            for claim in chosenClaims where !available.contains(claim) {
                throw OID4VPResponseError.requestedClaimNotAvailable(claim)
            }
            return (credential, Self.reserialise(credential, disclosing: chosenClaims))
        }
        throw OID4VPResponseError.noMatchingCredential
    }

    /// Rebuilds a TWDIW SD-JWT keeping only the chosen disclosures.
    ///
    /// The wire form is `<jwt>~<d1>~<d2>~…~`, and `disclosedClaims[i]`
    /// corresponds to the `i`-th disclosure segment. Dropping a segment removes
    /// that claim from what the verifier can see while the issuer's signature
    /// over the JWT — and its digest commitments — stay intact, which is the
    /// whole point of selective disclosure. The trailing `~` is preserved
    /// because production emits it even with nothing disclosed.
    static func reserialise(_ credential: TWDIWCredential,
                            disclosing chosenClaims: Set<String>) -> String {
        let segments = credential.serialized
            .split(separator: "~", omittingEmptySubsequences: false)
            .map(String.init)
        guard let jwt = segments.first else { return credential.serialized }

        var kept: [String] = []
        // segments[0] is the JWT; disclosure i lives at segments[i+1].
        for (i, claim) in credential.disclosedClaims.enumerated() where chosenClaims.contains(claim.name) {
            let index = i + 1
            if index < segments.count { kept.append(segments[index]) }
        }
        return ([jwt] + kept).joined(separator: "~") + "~"
    }

    // MARK: - Token

    func buildVPToken(request: OID4VPRequest,
                      presented: String,
                      holderKey: DeviceKey) throws -> String {
        let holderDID = try JWKDIDKey.did(fromP256PublicKeyX963: holderKey.publicKeyX963)
        let header: [String: Any] = ["typ": "JWT", "alg": "ES256", "kid": holderDID]
        let vp: [String: Any] = [
            // `context`, not `@context` — see the type doc. The value is a
            // conventional VCDM context; it is not JSON-LD-expanded by the
            // verifier, so what matters is the key spelling, not this URL.
            "context": ["https://www.w3.org/ns/credentials/v2"],
            "type": ["VerifiablePresentation"],
            "verifiableCredential": [presented],
        ]
        let payload: [String: Any] = [
            "iss": holderDID,
            // The `redirect_uri:` prefix is part of the audience string the
            // verifier checks, literally — not a description of it.
            "aud": "redirect_uri:" + request.responseURI,
            "nonce": request.nonce,
            "vp": vp,
        ]
        let signingInput = try Self.base64URL(header) + "." + Self.base64URL(payload)
        let signature = try holderKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + signature.base64URLEncodedString()
    }

    /// The DIF presentation submission naming which descriptor this token
    /// answers and where the credential sits inside it.
    func presentationSubmission(for request: OID4VPRequest) -> [String: Any] {
        [
            // A stable id derived from the exchange rather than random, so the
            // same request builds the same submission — nothing here needs to be
            // unpredictable, and a test can assert on it.
            "id": "submission-" + request.state,
            "definition_id": request.definitionID,
            "descriptor_map": [
                [
                    "id": request.inputDescriptorID,
                    // TWDIW cards are SD-JWT on the wire despite the metadata's
                    // `jwt_vc_json`. Sent as `vc+sd-jwt`; ⚠️待實測確認 the
                    // verifier accepts this exact token — measured requests do
                    // not pin the response format.
                    "format": "vc+sd-jwt",
                    "path": "$",
                ],
            ],
        ]
    }

    // MARK: - Send

    private func post(vpToken: String,
                      submission: [String: Any],
                      state: String,
                      to responseURI: String) async throws -> Int {
        guard let url = URL(string: responseURI),
              let submissionJSON = try? JSONSerialization.data(withJSONObject: submission),
              let submissionString = String(data: submissionJSON, encoding: .utf8) else {
            throw OID4VPResponseError.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded([
            ("vp_token", vpToken),
            ("presentation_submission", submissionString),
            ("state", state),
        ]).utf8)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw OID4VPResponseError.network }
        guard let http = response as? HTTPURLResponse else { throw OID4VPResponseError.network }
        guard (200..<300).contains(http.statusCode) else {
            // Keep the verifier's own words so a refusal can be read, not guessed.
            let body = String(data: data, encoding: .utf8)
            throw OID4VPResponseError.badStatus(http.statusCode, body: body)
        }
        return http.statusCode
    }

    // MARK: - Plumbing

    private static func base64URL(_ object: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw OID4VPResponseError.network
        }
        return data.base64URLEncodedString()
    }

    private func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
