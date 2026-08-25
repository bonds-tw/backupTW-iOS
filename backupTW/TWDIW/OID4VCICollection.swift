//
//  OID4VCICollection.swift
//  backupTW
//
//  Collecting one credential from a TWDIW issuer, with the two gates that
//  make a QR code safe to act on.
//

import CryptoKit
import Foundation

enum OID4VCICollectionError: Error, Equatable {

    enum Step: String, Equatable, Sendable {
        case fetchOffer
        case fetchMetadata
        case token
        case credential
    }

    /// A gate said no. The refusal carries the reason; nothing was contacted
    /// after it was raised (for gate 1, nothing was contacted at all).
    case refused(IssuerAuthorization.Refusal)
    /// The network failed at this step. The underlying `URLError` is not
    /// carried because this type is `Equatable` for tests; the step is what a
    /// user can act on ("領卡的第三步連不上"), and the console has the rest.
    case network(step: Step)
    /// The server answered with a status this flow does not accept.
    ///
    /// At `.token` this is also **the measurement M5.2 exists to take**: a
    /// 4xx here with our own `client_id` is the demo deployment refusing a
    /// third-party wallet's name — a finding to report, not a defect to fix.
    case badStatus(step: Step, code: Int)
    /// The response body at this step was not the JSON shape measured off the
    /// deployment this module targets.
    case malformedResponse(step: Step)
    /// A field this flow cannot proceed without was missing.
    case missingField(step: Step, field: String)
    /// The metadata's `credential_endpoint` lives on a different host than
    /// the issuer both gates agreed on. The metadata arrived over TLS from
    /// the agreed host, but an endpoint that points elsewhere would carry the
    /// access token — and our proof — to a place no gate ever looked at.
    case credentialEndpointHostMismatch
    /// The issued document does not parse and verify as a TWDIW credential.
    /// Checked **before** storing, for the same reason `CredentialIssuance`
    /// checks its own work: fail at issuance, not at the counter.
    case issuedCredentialDoesNotVerify
    /// The issued credential's `cnf.jwk` is not the key this collection
    /// created. A card bound to someone else's key can be stored but never
    /// presented; refusing it here names the actual problem.
    case credentialNotBoundToOurKey
    /// The Keychain would not give this collection a fresh key.
    case keyUnavailable
}

/// What one successful collection produced.
struct OID4VCICollectionReceipt: Equatable {
    /// The identifier the credential was stored under.
    let storedID: String
    /// The holder DID the proof was signed under — a fresh key for this card,
    /// per the one-key-per-card rule (`HolderKeyring`).
    let holderDID: String
    /// The `client_id` the token endpoint accepted. Recorded because M5.2's
    /// question is exactly "was `tw.bonds.backupTW` accepted"; the receipt is
    /// the evidence.
    let acceptedClientID: String
}

/// One credential collection, start to finish.
///
/// # The two decisions this type is built around
///
/// Written down in `docs/twdiw-integration-plan.md` §十.D before any of this
/// existed, and load-bearing:
///
/// 1. **Every URL here arrived in a QR code and is untrusted input.**
///    `IssuerAuthorization` gate 1 runs before the first request leaves the
///    device; gate 2 runs before anything is signed. The proof JWT's `aud` is
///    rebuilt from the gate's canonical host rather than taken from the offer,
///    so no attacker-chosen spelling is ever signed over.
/// 2. **One key per card.** The proof is signed with a key created for this
///    collection (`HolderKeyring.newKey()`), never `DeviceKey.defaultTag`.
///    Reusing the app's long-term key would hand the issuer — and every
///    verifier, offline, forever — one index joining every document this
///    device holds. The key is deleted again if collection fails, because an
///    unused key in the namespace is residue the sweep would have to explain.
///
/// # client_id
///
/// Defaults to `tw.bonds.backupTW` — deliberately not `moda_dw`. The token
/// endpoint verifying that string is an echo (§一.B), so sending the official
/// app's value would prove nothing and claim someone else's name. Sending our
/// own is the measurement: accepted means "this field has no discriminating
/// power" (report upstream), refused means "a third-party wallet cannot state
/// its own name" (also report upstream). Either way the string must be true.
struct OID4VCICollector {

    let session: URLSession
    let trustList: [TWDIWIssuer]
    let keyring: HolderKeyring
    let store: CredentialStoring
    var clientID = "tw.bonds.backupTW"
    var now: () -> Date = Date.init

    /// The whole flow: gates, token, proof, credential, verification, store.
    func collect(from link: CredentialOfferLink) async throws -> OID4VCICollectionReceipt {
        // Gate 1 + fetch (or unwrap) the offer document.
        let offer: CredentialOffer
        let matched: [TWDIWIssuer]
        switch link {
        case .byReference(let fetchURL):
            switch IssuerAuthorization.authorise(fetchURL: fetchURL, against: trustList) {
            case .refused(let refusal): throw OID4VCICollectionError.refused(refusal)
            case .allowed(let issuers, _): matched = issuers
            }
            guard let url = URL(string: fetchURL) else {
                throw OID4VCICollectionError.refused(.unusableHost)
            }
            let body = try await get(url, step: .fetchOffer)
            offer = try parseOffer(body)
        case .byValue(let json):
            // The inline form skips the fetch, not the gate: the issuer it
            // names must still be on the list before anything else happens.
            offer = try parseOffer(Data(json.utf8))
            switch IssuerAuthorization.authorise(fetchURL: offer.credentialIssuer,
                                                 against: trustList) {
            case .refused(let refusal): throw OID4VCICollectionError.refused(refusal)
            case .allowed(let issuers, _): matched = issuers
            }
        }

        // Gate 2: the offer's issuer must belong to the organisation the QR
        // pointed at.
        switch IssuerAuthorization.confirm(credentialIssuer: offer.credentialIssuer,
                                           matched: matched) {
        case .failure(let refusal): throw OID4VCICollectionError.refused(refusal)
        case .success: break
        }

        // The issuer identifier this flow will request against and sign over:
        // scheme and host in the gate's canonical spelling, path from the
        // offer (gate 2 already refused non-normalised paths).
        guard let issuerIdentifier = canonicalIssuerIdentifier(offer.credentialIssuer) else {
            throw OID4VCICollectionError.refused(.unusableHost)
        }

        guard let configurationID = offer.configurationIDs.first else {
            throw OID4VCICollectionError.missingField(step: .fetchOffer,
                                                      field: "credential_configuration_ids")
        }

        // Issuer metadata. Only `credential_endpoint` is read from it, and
        // only after its host survives the same comparison as everything else.
        guard let metadataURL = URL(string: issuerIdentifier + "/.well-known/openid-credential-issuer") else {
            throw OID4VCICollectionError.refused(.unusableHost)
        }
        let metadata = try await getJSON(metadataURL, step: .fetchMetadata)
        guard let credentialEndpoint = metadata["credential_endpoint"] as? String else {
            throw OID4VCICollectionError.missingField(step: .fetchMetadata,
                                                      field: "credential_endpoint")
        }
        let issuerHost = try? IssuerAuthorization.normalisedHost(of: issuerIdentifier).get()
        guard let endpointHost = try? IssuerAuthorization.normalisedHost(of: credentialEndpoint).get(),
              endpointHost == issuerHost,
              let credentialURL = URL(string: credentialEndpoint) else {
            throw OID4VCICollectionError.credentialEndpointHostMismatch
        }

        // Token.
        let token = try await requestToken(issuerIdentifier: issuerIdentifier,
                                           offer: offer,
                                           configurationID: configurationID)

        // A fresh key for this card, removed again on any later failure so a
        // collection that died at the credential step does not leave a key
        // the sweep counts and no card explains.
        guard let holderKey = try? keyring.newKey() else {
            throw OID4VCICollectionError.keyUnavailable
        }
        do {
            let holderDID = try didForProof(holderKey)
            let proof = try proofJWT(holderKey: holderKey,
                                     holderDID: holderDID,
                                     issuerIdentifier: issuerIdentifier,
                                     nonce: token.cNonce)
            let serialized = try await requestCredential(
                at: credentialURL,
                accessToken: token.accessToken,
                credentialIdentifier: token.credentialIdentifier ?? configurationID,
                proof: proof)

            // The issuer answered. Before anything is stored: does the
            // document verify, and is it bound to the key we just made?
            guard StoredCardSource.source(of: serialized) == .twdiw,
                  (try? TWDIWCredentialReader.read(serialized, now: now())) != nil else {
                throw OID4VCICollectionError.issuedCredentialDoesNotVerify
            }
            guard credential(serialized, isBoundTo: holderKey) else {
                throw OID4VCICollectionError.credentialNotBoundToOurKey
            }

            // Stored under the configuration id: collecting the same card
            // again replaces it, which is what re-collection means. A second
            // *kind* of card is a second id.
            try store.save(jws: serialized, id: configurationID)
            return OID4VCICollectionReceipt(storedID: configurationID,
                                            holderDID: holderDID,
                                            acceptedClientID: clientID)
        } catch {
            destroy(publicKeyX963: holderKey.publicKeyX963)
            throw error
        }
    }

    /// Removes the key a failed collection created.
    ///
    /// `DeviceKey` deliberately does not remember its own tag, so the key is
    /// found the same way a presentation would find it: by public key, via
    /// the keyring. Best-effort — a key that cannot be deleted right now is
    /// exactly what `HolderKeyring.residue()` exists to surface later.
    private func destroy(publicKeyX963: Data) {
        guard let entries = try? keyring.entries() else { return }
        for entry in entries where entry.publicKeyX963 == publicKeyX963 && !entry.isLegacy {
            try? DeviceKey.deleteKey(tag: entry.tag, installRecord: nil)
        }
    }

    // MARK: - Steps

    private func parseOffer(_ data: Data) throws -> CredentialOffer {
        do { return try CredentialOffer.parse(json: data) }
        catch { throw OID4VCICollectionError.malformedResponse(step: .fetchOffer) }
    }

    private struct TokenGrant {
        let accessToken: String
        let cNonce: String
        /// The identifier the token response says to request the credential
        /// under, when it says one; the configuration id otherwise.
        let credentialIdentifier: String?
    }

    private func requestToken(issuerIdentifier: String,
                              offer: CredentialOffer,
                              configurationID: String) async throws -> TokenGrant {
        guard let url = URL(string: issuerIdentifier + "/token") else {
            throw OID4VCICollectionError.refused(.unusableHost)
        }
        // `authorization_details` names the configuration being asked for.
        // Sent as measured off the deployment (§三 M5.2 step 3), not because
        // RFC 9396 requires this exact shape.
        let details = """
        [{"type":"openid_credential","credential_configuration_id":"\(configurationID)"}]
        """
        // `tx_code` is deliberately absent: the demo's guest flow does not
        // set one, and a flow that does needs UI this version has not built.
        // Sending nothing and letting the server refuse names that gap
        // honestly; `offer.requiresTransactionCode` is there for the UI to
        // consult before it starts.
        let fields = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:pre-authorized_code"),
            ("pre-authorized_code", offer.preAuthorizedCode),
            ("client_id", clientID),
            ("authorization_details", details),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(fields).utf8)

        let json = try await sendJSON(request, step: .token)
        guard let accessToken = json["access_token"] as? String else {
            throw OID4VCICollectionError.missingField(step: .token, field: "access_token")
        }
        guard let cNonce = json["c_nonce"] as? String else {
            throw OID4VCICollectionError.missingField(step: .token, field: "c_nonce")
        }
        var credentialIdentifier: String?
        if let list = json["authorization_details"] as? [[String: Any]] {
            credentialIdentifier = list
                .compactMap { ($0["credential_identifiers"] as? [String])?.first }
                .first
        }
        return TokenGrant(accessToken: accessToken,
                          cNonce: cNonce,
                          credentialIdentifier: credentialIdentifier)
    }

    /// The proof JWT the credential request carries.
    ///
    /// `typ` and the claim set are the deployment's, measured: `kid` is the
    /// holder's did:key in the TWDIW spelling (`JWKDIDKey`, 0xEB51 — the
    /// issuer strips a hardcoded three-byte prefix, so the other spelling
    /// would be parsed as garbage), `iss` is the client_id, and `aud` is the
    /// issuer identifier **with a trailing slash** — without it the demo
    /// issuer rejects the proof (§三 M5.2 step 4).
    private func proofJWT(holderKey: DeviceKey,
                          holderDID: String,
                          issuerIdentifier: String,
                          nonce: String) throws -> String {
        let audience = issuerIdentifier.hasSuffix("/") ? issuerIdentifier : issuerIdentifier + "/"
        let header = try base64URL(json: [
            "typ": "openid4vci-proof+jwt",
            "alg": "ES256",
            "kid": holderDID,
        ])
        let payload = try base64URL(json: [
            "iss": clientID,
            "aud": audience,
            "iat": Int(now().timeIntervalSince1970),
            "nonce": nonce,
        ])
        let signingInput = header + "." + payload
        let signature = try holderKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + signature.base64URLEncodedString()
    }

    private func didForProof(_ key: DeviceKey) throws -> String {
        do { return try JWKDIDKey.did(fromP256PublicKeyX963: key.publicKeyX963) }
        catch { throw OID4VCICollectionError.keyUnavailable }
    }

    private func requestCredential(at url: URL,
                                   accessToken: String,
                                   credentialIdentifier: String,
                                   proof: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "credential_identifier": credentialIdentifier,
            "proofs": ["jwt": [proof]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let json = try await sendJSON(request, step: .credential)
        // Two live shapes: `credentials: [{"credential": …}]` and a bare
        // `credential`. Both are accepted because both have been seen; a
        // third shape is a malformed response, not a nil.
        if let list = json["credentials"] as? [[String: Any]],
           let credential = list.first?["credential"] as? String {
            return credential
        }
        if let credential = json["credential"] as? String {
            return credential
        }
        throw OID4VCICollectionError.missingField(step: .credential, field: "credential")
    }

    // MARK: - Binding

    /// Whether the credential's `cnf.jwk` is exactly the public key of the
    /// key this collection created.
    ///
    /// Compared as coordinates, not as serialised JWK bytes: the issuer
    /// writes the JWK in whatever key order it likes, and two spellings of
    /// one key must not read as two keys.
    private func credential(_ serialized: String, isBoundTo key: DeviceKey) -> Bool {
        let jwt = serialized.prefix(while: { $0 != "~" })
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let cnf = payload["cnf"] as? [String: Any],
              let jwk = cnf["jwk"] as? [String: Any],
              let x = Data(base64URLEncoded: jwk["x"] as? String ?? ""),
              let y = Data(base64URLEncoded: jwk["y"] as? String ?? "") else {
            return false
        }
        // X9.63 uncompressed: 0x04, then 32 bytes of X, then 32 of Y.
        let x963 = key.publicKeyX963
        guard x963.count == 65 else { return false }
        return x == x963[1...32] && y == x963[33...64]
    }

    // MARK: - Shape

    /// Scheme and host from the gate's canonical spelling, path from the
    /// offer. Query and fragment are dropped: an issuer identifier with a
    /// query string is nothing this flow should build URLs on top of.
    private func canonicalIssuerIdentifier(_ credentialIssuer: String) -> String? {
        guard case .success(let host) = IssuerAuthorization.normalisedHost(of: credentialIssuer),
              let components = URLComponents(string: credentialIssuer) else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        return "https://" + host + path
    }

    // MARK: - Plumbing

    private func get(_ url: URL, step: OID4VCICollectionError.Step) async throws -> Data {
        try await send(URLRequest(url: url), step: step)
    }

    private func getJSON(_ url: URL, step: OID4VCICollectionError.Step) async throws -> [String: Any] {
        try await sendJSON(URLRequest(url: url), step: step)
    }

    private func sendJSON(_ request: URLRequest,
                          step: OID4VCICollectionError.Step) async throws -> [String: Any] {
        let data = try await send(request, step: step)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OID4VCICollectionError.malformedResponse(step: step)
        }
        return json
    }

    private func send(_ request: URLRequest,
                      step: OID4VCICollectionError.Step) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw OID4VCICollectionError.network(step: step) }
        guard let http = response as? HTTPURLResponse else {
            throw OID4VCICollectionError.network(step: step)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OID4VCICollectionError.badStatus(step: step, code: http.statusCode)
        }
        return data
    }

    private func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { name, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(name)=\(encoded)"
            }
            .joined(separator: "&")
    }

    private func base64URL(json: [String: Any]) throws -> String {
        // Sorted keys so two runs of one proof serialise identically; the
        // issuer does not care, but a test asserting on bytes does.
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.sortedKeys]) else {
            throw OID4VCICollectionError.keyUnavailable
        }
        return data.base64URLEncodedString()
    }
}
