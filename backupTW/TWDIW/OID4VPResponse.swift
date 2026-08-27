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
/// # The deviation this deliberately reproduces
///
/// The whole token and submission are built to the official app's own source
/// (`moda-gov-tw/TWDIW-official-app`, `APP/APPSDK/lib/openid_vc_vp.dart`) — see
/// `buildVPToken` and `presentationSubmission` for the field-by-field match.
/// The one non-obvious spelling worth flagging at the type level:
///
/// 1. **The VP claim uses `context`, not `@context`.** Measured: the official
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

    /// Built field-for-field to the official app's own token
    /// (`moda-gov-tw/TWDIW-official-app`, `openid_vc_vp.dart` `generateVPKx`),
    /// which is the thing the verifier is known to accept. The M5.4 notes that
    /// preceded that source were wrong on three counts, all corrected here:
    ///
    /// - **`aud` is the verifier's `client_id` verbatim** — a `did:key`, no
    ///   `redirect_uri:` prefix. (The prefix belongs to a different client-id
    ///   scheme; TWDIW authenticates the request by the DID's key, so the DID is
    ///   the audience.)
    /// - **the key rides in the header as `jwk`**, not as a `kid` DID, so the
    ///   verifier reads it from the token rather than resolving the DID.
    /// - **`vp.context` is `…/2018/credentials/v1`.** The key spelling is still
    ///   `context`, not `@context` — that part the notes had right — but the URL
    ///   the official app emits is the v1 one.
    ///
    /// `sub`/`nbf`/`exp`/`jti` are present because the official token carries
    /// them; `jti` is a fresh URN rather than the official app's hardcoded moda
    /// URL, which is not ours to send.
    func buildVPToken(request: OID4VPRequest,
                      presented: String,
                      holderKey: DeviceKey) throws -> String {
        let holderDID = try JWKDIDKey.did(fromP256PublicKeyX963: holderKey.publicKeyX963)
        // x963 is `0x04 || X || Y`; drop the tag, split the 64 coordinate bytes.
        let coordinates = holderKey.publicKeyX963.dropFirst()
        let jwk: [String: Any] = [
            "kty": "EC",
            "crv": "P-256",
            "x": Data(coordinates.prefix(32)).base64URLEncodedString(),
            "y": Data(coordinates.dropFirst(32)).base64URLEncodedString(),
        ]
        let header: [String: Any] = ["typ": "JWT", "alg": "ES256", "jwk": jwk]
        let issued = Int(now().timeIntervalSince1970)
        let vp: [String: Any] = [
            "context": ["https://www.w3.org/2018/credentials/v1"],
            "type": ["VerifiablePresentation"],
            "verifiableCredential": [presented],
        ]
        let payload: [String: Any] = [
            "sub": holderDID,
            "aud": request.clientID,
            "iss": holderDID,
            "nbf": issued,
            "vp": vp,
            "exp": issued + 60 * 60 * 24 * 30,
            "nonce": request.nonce,
            "jti": "urn:uuid:" + UUID().uuidString.lowercased(),
        ]
        let signingInput = try Self.base64URL(header) + "." + Self.base64URL(payload)
        let signature = try holderKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + signature.base64URLEncodedString()
    }

    /// The DIF presentation submission naming which descriptor this token
    /// answers and where the credential sits inside it.
    ///
    /// The descriptor is **nested and repeats its id**, matched to the official
    /// app's own builder (`moda-gov-tw/TWDIW-official-app`,
    /// `APP/APPSDK/lib/openid_vc_vp.dart` `generateVPKx`). The token is a
    /// `VerifiablePresentation` JWT whose credential sits at
    /// `$.vp.verifiableCredential[0]`, so the top describes the presentation
    /// (`jwt_vp`, `path: "$"`) and `path_nested` reaches the credential —
    /// carrying **the same `id`** (the verifier's own check reads "descriptor_map
    /// id is not the same for each level of nesting", `PresentationSubmissionValidator.java`)
    /// and the format **`jwt_vc`**, not `vc+sd-jwt`.
    ///
    /// The two earlier forms were both refused as an invalid schema (code 2012,
    /// device 2026-08-27): the flat `vc+sd-jwt`-at-`$`, and the nested form whose
    /// `path_nested` omitted the `id` the verifier's schema requires.
    func presentationSubmission(for request: OID4VPRequest) -> [String: Any] {
        [
            // A stable id derived from the exchange rather than random, so a test
            // can assert on it. The verifier requires only a non-empty string;
            // the official app happens to use a UUID, which this need not copy.
            "id": "submission-" + request.state,
            "definition_id": request.definitionID,
            "descriptor_map": [
                [
                    "id": request.inputDescriptorID,
                    "format": "jwt_vp",
                    "path": "$",
                    "path_nested": [
                        "id": request.inputDescriptorID,
                        "format": "jwt_vc",
                        "path": "$.vp.verifiableCredential[0]",
                    ],
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
            var body = String(data: data, encoding: .utf8)
            #if DEBUG
            // Also carry what we sent, so a schema refusal shows both sides — the
            // submission the verifier rejected and its reason — in one alert. The
            // fastest way to tell a stale build from a wrong guess.
            if let sent = try? JSONSerialization.data(withJSONObject: submission),
               let sentString = String(data: sent, encoding: .utf8) {
                body = "sent=" + sentString + "  ||  " + (body ?? "")
            }
            #endif
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
