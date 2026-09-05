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
    /// The card predates selective disclosure. It may contain the requested
    /// value, but presenting it would also reveal every other clear-text field.
    case selectiveDisclosureUnavailable
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

struct OID4VPPresentedCredential {
    let descriptorID: String
    let format: OID4VPCredentialFormat
    let serialized: String
}

private struct OID4VPResponseMaterial {
    let holderKey: DeviceKey
    let presentations: [OID4VPPresentedCredential]
}

/// A successful VP receipt. The convenience-store follow-up must be signed by
/// the exact holder key whose DID the verifier just recovered from this VP.
struct OID4VPPresentationReceipt {
    let statusCode: Int
    let holderDID: String
    let holderKey: DeviceKey
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
        try await respondWithReceipt(to: request, disclosing: chosenClaims).statusCode
    }

    func respondWithReceipt(to request: OID4VPRequest,
                            disclosing chosenClaims: Set<String>) async throws -> OID4VPPresentationReceipt {
        let material = try responseMaterial(request, chosenClaims: chosenClaims)
        let holderKey = material.holderKey
        let presentations = material.presentations
        let holderDID = try JWKDIDKey.did(fromP256PublicKeyX963: holderKey.publicKeyX963)
        let vpToken = try buildVPToken(request: request,
                                       presented: presentations.map(\.serialized),
                                       holderKey: holderKey)
        let submission = presentationSubmission(for: request, presented: presentations)
        let status = try await post(vpToken: vpToken, submission: submission,
                                    state: request.state, to: request.responseURI)
        return OID4VPPresentationReceipt(statusCode: status,
                                         holderDID: holderDID,
                                         holderKey: holderKey)
    }

    // MARK: - Selection

    /// Finds the stored card the request wants and produces its serialization
    /// carrying only the chosen disclosures.
    func matchAndDisclose(_ request: OID4VPRequest,
                          chosenClaims: Set<String>) throws -> (TWDIWCredential, String) {
        let (credential, presentations) = try presentationMaterial(request,
                                                                   chosenClaims: chosenClaims)
        guard let first = presentations.first else {
            throw OID4VPResponseError.noMatchingCredential
        }
        return (credential, first.serialized)
    }

    /// Finds one held card that can answer every selected group and serialises
    /// it once per descriptor. The official 7-Eleven request selects the Taiwan
    /// Mobile card in two groups: one SD-JWT reveals `name`, the other `phonel5`.
    func presentationMaterial(_ request: OID4VPRequest,
                              chosenClaims: Set<String>) throws -> (TWDIWCredential, [OID4VPPresentedCredential]) {
        let requested = Set(request.requestedFields.compactMap(\.claimName))
        if let unrequested = chosenClaims.first(where: { !requested.contains($0) }) {
            throw OID4VPResponseError.requestedClaimNotAvailable(unrequested)
        }

        // A claim that matched the requested type but was missing from *some* card —
        // remembered so the error can name it, but only reported after no other
        // stored card can satisfy the request. Auto-pick (this flow has no card
        // picker) must not fail on the first card when a later one has everything
        // asked: a wallet holding a telecom card and a driving licence would
        // otherwise refuse a name/birthday request the licence could have answered.
        var missingOnSomeCard: String?
        for id in (try? store.allIDs()) ?? [] {
            guard let serialized = try? store.load(id: id),
                  StoredCardSource.source(of: serialized) == .twdiw,
                  let credential = try? TWDIWCredentialReader.read(serialized) else { continue }

            // Use the first card that carries every claim the user chose; skip one
            // that is missing any, in case another card has them all.
            let available = Set(credential.disclosedClaims.map(\.name))
            if let missing = chosenClaims.first(where: { !available.contains($0) }) {
                missingOnSomeCard = missing
                continue
            }

            let matching = request.inputDescriptors.filter {
                $0.credentialType == nil || $0.credentialType == credential.credentialType
            }
            var selected: [OID4VPInputDescriptor] = []
            if request.submissionRequirements.isEmpty {
                // An ungrouped list denotes alternatives. Answer the first one
                // that matches this held card and at least one selected claim.
                if let descriptor = matching.first(where: {
                    let claims = Set($0.requestedFields.compactMap(\.claimName))
                    return claims.isEmpty || !claims.isDisjoint(with: chosenClaims)
                }) {
                    selected = [descriptor]
                }
            } else {
                for requirement in request.submissionRequirements {
                    let inGroup = matching.filter { $0.groups.contains(requirement.from) }
                    let groupClaims = Set(inGroup.flatMap { $0.requestedFields.compactMap(\.claimName) })
                    // The general disclosure screen lets the holder withhold an
                    // entire optional `pick` group; then no descriptor is emitted.
                    guard !groupClaims.isDisjoint(with: chosenClaims) else { continue }
                    if let descriptor = inGroup.first(where: {
                        !Set($0.requestedFields.compactMap(\.claimName)).isDisjoint(with: chosenClaims)
                    }) {
                        selected.append(descriptor)
                    }
                }
            }

            let covered = Set(selected.flatMap { $0.requestedFields.compactMap(\.claimName) })
            guard !selected.isEmpty, chosenClaims.isSubset(of: covered) else { continue }
            let presentations = selected.map { descriptor in
                let descriptorClaims = Set(descriptor.requestedFields.compactMap(\.claimName))
                return OID4VPPresentedCredential(
                    descriptorID: descriptor.id,
                    format: .sdJWT,
                    serialized: Self.reserialise(
                        credential,
                        disclosing: chosenClaims.intersection(descriptorClaims)))
            }
            return (credential, presentations)
        }
        if let missing = missingOnSomeCard {
            throw OID4VPResponseError.requestedClaimNotAvailable(missing)
        }
        throw OID4VPResponseError.noMatchingCredential
    }

    /// Chooses the inner credential family from the descriptor's declared
    /// format. A request for this project's `vc+moica` extension never falls
    /// through to a government SD-JWT, and an unlabelled official request keeps
    /// the established TWDIW behaviour for compatibility.
    private func responseMaterial(_ request: OID4VPRequest,
                                  chosenClaims: Set<String>) throws -> OID4VPResponseMaterial {
        let formats = Set(request.inputDescriptors.compactMap(\.credentialFormat))
        if formats.contains(.moica) {
            guard formats.count == 1 else { throw OID4VPResponseError.noMatchingCredential }
            return try selfIssuedMaterial(request, chosenClaims: chosenClaims)
        }

        let (credential, presentations) = try presentationMaterial(request,
                                                                   chosenClaims: chosenClaims)
        guard let holderKey = try? keyring.key(
            matchingPublicKeyX963: credential.holderKey.x963Representation) else {
            throw OID4VPResponseError.holderKeyUnavailable
        }
        return OID4VPResponseMaterial(holderKey: holderKey, presentations: presentations)
    }

    /// Presents a MyData/national-ID envelope through OIDC4VP. The OIDC request,
    /// challenge and outer holder proof are standard; `vc+moica` is a named
    /// project extension whose verifier checks both the per-card DID signature
    /// and the citizen-certificate signature.
    private func selfIssuedMaterial(_ request: OID4VPRequest,
                                    chosenClaims: Set<String>) throws -> OID4VPResponseMaterial {
        let requested = Set(request.requestedFields.compactMap(\.claimName))
        if let unrequested = chosenClaims.first(where: { !requested.contains($0) }) {
            throw OID4VPResponseError.requestedClaimNotAvailable(unrequested)
        }

        var missingOnSomeCard: String?
        var foundLegacyCardWithoutSelectiveDisclosure = false
        for id in (try? store.allIDs()) ?? [] {
            guard let serialized = try? store.load(id: id),
                  StoredCardSource.source(of: serialized) == .selfIssued,
                  var envelope = try? MOICASignedCredential.parse(serialized),
                  envelope.issuerJWS != nil,
                  let credential = try? envelope.credential(),
                  let subjectDID = credential.credentialSubject["id"],
                  credential.issuer == subjectDID else { continue }

            let matching = request.inputDescriptors.filter { descriptor in
                descriptor.credentialFormat == .moica
                    && (descriptor.credentialType == nil
                        || credential.type.contains(descriptor.credentialType!))
            }
            guard !matching.isEmpty else { continue }

            let available: Set<String>
            if let committed = credential.sd,
               let revealed = try? SelectiveDisclosure.reveal(
                    disclosures: envelope.disclosures,
                    committedDigests: committed) {
                available = Set(revealed.map(\.name))
            } else {
                available = Set(credential.credentialSubject.keys).subtracting(["id"])
            }
            if let missing = chosenClaims.first(where: { !available.contains($0) }) {
                missingOnSomeCard = missing
                continue
            }

            guard let descriptor = matching.first(where: {
                let claims = Set($0.requestedFields.compactMap(\.claimName))
                return claims.isEmpty || chosenClaims.isSubset(of: claims)
            }) else { continue }

            // A legacy clear-text envelope cannot selectively withhold claims.
            // New production issuance always has commitments; refuse to imply a
            // choice the wire document cannot honour.
            guard credential.sd != nil else {
                let clearClaims = Set(credential.credentialSubject.keys).subtracting(["id"])
                guard chosenClaims == clearClaims else {
                    foundLegacyCardWithoutSelectiveDisclosure = true
                    continue
                }
                guard let key = try selfIssuedKey(subjectDID: subjectDID) else {
                    throw OID4VPResponseError.holderKeyUnavailable
                }
                return OID4VPResponseMaterial(
                    holderKey: key,
                    presentations: [.init(descriptorID: descriptor.id,
                                           format: .moica,
                                           serialized: try envelope.serialized())])
            }

            envelope.disclosures = envelope.disclosures.filter { encoded in
                guard let disclosure = Disclosure(encoded: encoded) else { return false }
                return chosenClaims.contains(disclosure.claimName)
            }
            guard let key = try selfIssuedKey(subjectDID: subjectDID) else {
                throw OID4VPResponseError.holderKeyUnavailable
            }
            return OID4VPResponseMaterial(
                holderKey: key,
                presentations: [.init(descriptorID: descriptor.id,
                                       format: .moica,
                                       serialized: try envelope.serialized())])
        }

        if foundLegacyCardWithoutSelectiveDisclosure {
            throw OID4VPResponseError.selectiveDisclosureUnavailable
        }
        if let missingOnSomeCard {
            throw OID4VPResponseError.requestedClaimNotAvailable(missingOnSomeCard)
        }
        throw OID4VPResponseError.noMatchingCredential
    }

    private func selfIssuedKey(subjectDID: String) throws -> DeviceKey? {
        let publicKey: P256.Signing.PublicKey
        if let key = try? DIDKey.p256PublicKey(fromDID: subjectDID) {
            publicKey = key
        } else if let key = try? JWKDIDKey.p256PublicKey(fromDID: subjectDID) {
            publicKey = key
        } else {
            return nil
        }
        return try? keyring.key(matchingPublicKeyX963: publicKey.x963Representation)
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
        try buildVPToken(request: request, presented: [presented], holderKey: holderKey)
    }

    /// One credential entry per descriptor map entry. A grouped request may
    /// legitimately carry the same issuer-signed card more than once with a
    /// different SD-JWT disclosure in each entry.
    func buildVPToken(request: OID4VPRequest,
                      presented: [String],
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
            "verifiableCredential": presented,
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
        presentationSubmission(for: request, descriptorIDs: [request.inputDescriptorID])
    }

    func presentationSubmission(for request: OID4VPRequest,
                                descriptorIDs: [String]) -> [String: Any] {
        presentationSubmission(
            for: request,
            presented: descriptorIDs.map {
                OID4VPPresentedCredential(descriptorID: $0,
                                          format: .sdJWT,
                                          serialized: "")
            })
    }

    func presentationSubmission(for request: OID4VPRequest,
                                presented: [OID4VPPresentedCredential]) -> [String: Any] {
        [
            // A stable id derived from the exchange rather than random, so a test
            // can assert on it. The verifier requires only a non-empty string;
            // the official app happens to use a UUID, which this need not copy.
            "id": "submission-" + request.state,
            "definition_id": request.definitionID,
            "descriptor_map": presented.enumerated().map { index, credential in
                [
                    "id": credential.descriptorID,
                    "format": "jwt_vp",
                    "path": "$",
                    "path_nested": [
                        "id": credential.descriptorID,
                        // The official TWDIW compatibility dialect calls its
                        // inner SD-JWT `jwt_vc`; our own envelope is explicitly
                        // named so it cannot be mistaken for JOSE.
                        "format": credential.format == .moica ? "vc+moica" : "jwt_vc",
                        "path": "$.vp.verifiableCredential[\(index)]",
                    ],
                ] as [String: Any]
            },
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
