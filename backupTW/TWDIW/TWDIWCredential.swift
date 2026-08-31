//
//  TWDIWCredential.swift
//  backupTW
//
//  Reading a credential issued by 台灣數位憑證皮夾（TWDIW）.
//

import CryptoKit
import Foundation

enum TWDIWCredentialError: Error, Equatable {

    /// Not three dot-separated parts before the first `~`.
    case malformedCompactSerialization
    /// A part that is not base64url, or whose bytes are not a JSON object.
    case malformedJSON(part: String)
    /// `alg` is not `ES256`. Refused rather than trusted: `none` and the
    /// HMAC-for-RSA confusion are the two oldest JWT forgeries there are, and
    /// both begin with a verifier that reads `alg` from the token.
    case unsupportedAlgorithm(String)
    /// `typ` is not one this reader knows. Carried so a future media type shows
    /// up as itself rather than as "malformed".
    case unexpectedType(String)
    /// `iss`, `sub`, `cnf.jwk`, `vc.type` or `credentialSubject` missing.
    case missingClaim(String)
    /// The issuer DID is not a DID this reader can turn into a key.
    case unresolvableIssuer
    /// The signature does not verify under the key the issuer's DID names.
    case signatureInvalid
    /// `_sd_alg` is present and is not `sha-256`. Refused rather than assumed,
    /// because assuming is how a verifier computes digests nobody committed to
    /// and then reports that nothing matched.
    case unsupportedDigestAlgorithm(String)
    /// A disclosure whose digest the issuer never committed to. The red line:
    /// a holder who could add one could assert anything.
    case undisclosedDigest(String)
    /// A disclosure that is not a three-element array of strings.
    case malformedDisclosure
}

/// A credential in TWDIW's shape: SD-JWT selective disclosure wrapped in a W3C
/// VCDM 1.1 `vc` claim.
///
/// # This is a hybrid, and neither half is quite standard
///
/// SD-JWT VC puts claims at the top level and names the type in `vct`. TWDIW
/// puts `_sd` inside `vc.credentialSubject` and names the type in `vc.type[1]`,
/// which is the VCDM arrangement. So it is a real SD-JWT carried inside a real
/// VCDM 1.1 credential, and a reader written strictly to either specification
/// finds the wrong thing.
///
/// Worse for anybody arriving through the front door: the issuer metadata says
/// **`"format": "jwt_vc_json"`**. Measured against production on 2026-08-16 —
/// 882 of 882 credential configurations say that, and the string `sd-jwt` does
/// not appear anywhere in the 701 KB document. A client that believed `format`
/// would treat the whole thing as one JWT and never split the disclosures off.
/// The `~` is the only signal there is.
///
/// # What is *not* new here
///
/// The digest is `base64url(SHA-256(<the disclosure's own base64url string>))`
/// — hashed over the encoded string, not the decoded array. That is what this
/// app's own `Disclosure` already computes, so **the cryptography is shared and
/// only the container differs.** Verified against production values rather than
/// assumed: see `TWDIWCredentialTests.theDigestAlgorithmMatchesProduction`,
/// which reproduces two real `_sd` entries from real disclosures.
struct TWDIWCredential: Equatable {

    /// The compact form as received: `<jwt>~<d1>~<d2>~…~`.
    let serialized: String

    let issuerDID: String
    let subjectDID: String

    /// The issuer-assigned credential identifier from the signed JWT `jti`.
    /// Production uses a credential URL whose last path component is the UUID
    /// shown as 「憑證序號」 in the official disclosure screen.
    let credentialID: String?

    /// `vc.type[1]` — the issuer's own opaque identifier for this kind of card,
    /// e.g. `00000000_demo_drivinglicense_202504251418`.
    ///
    /// **This is the only thing distinguishing an identity-proofed credential
    /// from a self-asserted one.** TWDIW carries no IAL: a credential for an
    /// email address somebody typed into a web form and one issued after a
    /// counter check are byte-structurally identical — same `jku`, same `kid`,
    /// same `typ`, same issuer DID. What the card can be relied on for is a
    /// function of who issued it and this string, and of nothing in the
    /// credential itself.
    let credentialType: String

    let notBefore: Date
    let expires: Date

    /// The key the credential is bound to, from `cnf.jwk`. The holder proved
    /// possession of it during issuance, so a presentation that is not signed by
    /// it is not this credential's holder presenting.
    let holderKey: P256.Signing.PublicKey

    let status: TWDIWStatusListEntry?

    /// `vc.credentialSchema.id`, if present. Not fetched — recorded.
    let schemaURL: String?

    /// **Retained, never followed.** See `TWDIWCredentialReader`.
    let declaredKeySourceURL: String?
    let declaredKeyID: String?

    /// The digests the issuer committed to, in the order they appeared.
    let commitments: [String]

    /// The claims the disclosures actually reveal, in disclosure order.
    let disclosedClaims: [(name: String, value: String)]

    static func == (lhs: TWDIWCredential, rhs: TWDIWCredential) -> Bool {
        lhs.serialized == rhs.serialized
    }
}

/// `vc.credentialStatus`, a StatusList2021 entry.
struct TWDIWStatusListEntry: Equatable {
    let statusListURL: String
    let index: Int
    let purpose: String
}

/// Turns TWDIW's wire form into a `TWDIWCredential`, or refuses it.
enum TWDIWCredentialReader {

    /// `typ` values this reader accepts.
    ///
    /// `vc+sd-jwt` is what production emits. `dc+sd-jwt` is the registered media
    /// type the IETF work settled on; it is accepted so that the day TWDIW
    /// updates, cards already in wallets do not become unreadable — while
    /// anything else is named rather than guessed at.
    static let acceptedTypes: Set<String> = ["vc+sd-jwt", "dc+sd-jwt"]

    /// # The key comes from `iss`, and `jku` is never followed
    ///
    /// TWDIW's JWS header carries `jku` — a URL the verifier is invited to fetch
    /// the verifying key from — while `iss` is a `did:key` that *contains* a key.
    /// Two sources that can disagree, one of them named by the document being
    /// verified. This reader uses `iss` and only `iss`.
    ///
    /// That is not caution, it is measurement: **all 43 issuers in the
    /// production trust list embed a usable key in their DID** (2026-08-16), so
    /// following `jku` cannot obtain anything unavailable from `iss` — it can
    /// only add a network fetch chosen by the credential. The official verifier
    /// agrees in effect; `DidUtils.extractIssuerPublicKey(iss)` is its primary
    /// path and `jku` its fallback for DIDs that fail to decode, which no
    /// trust-listed issuer's does.
    ///
    /// `jku` and `kid` are still parsed out and kept on the credential. "Which
    /// URL did this card claim its key lives at" is exactly what a diagnostic
    /// screen or an upstream bug report needs — it just does not get a vote.
    ///
    /// **Where this does not save us: revocation.** The status list is signed by
    /// a key that is *not* in the issuer's DID (measured: the DID publishes
    /// `key-1`, status lists are signed by `key-2`, and the DID document has a
    /// single verification method). So the revocation channel has no
    /// offline-checkable trust anchor at all, and this reader does not pretend
    /// otherwise — it records `status` and leaves checking to a caller that
    /// knows whether it is online. See `docs/twdiw-integration-plan.md` §九.
    static func read(_ serialized: String, now: Date = Date()) throws -> TWDIWCredential {
        let parts = serialized.split(separator: "~", omittingEmptySubsequences: false)
            .map(String.init)
        guard let jwt = parts.first else { throw TWDIWCredentialError.malformedCompactSerialization }

        // A trailing `~` produces a final empty element; anything else empty in
        // the middle is a malformed serialization rather than a disclosure.
        let disclosureStrings = parts.dropFirst().filter { !$0.isEmpty }

        let jwtParts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard jwtParts.count == 3 else { throw TWDIWCredentialError.malformedCompactSerialization }

        let header = try object(jwtParts[0], part: "header")
        let payload = try object(jwtParts[1], part: "payload")

        let alg = header["alg"] as? String ?? ""
        guard alg == "ES256" else { throw TWDIWCredentialError.unsupportedAlgorithm(alg) }
        if let typ = header["typ"] as? String, !acceptedTypes.contains(typ) {
            throw TWDIWCredentialError.unexpectedType(typ)
        }

        guard let iss = payload["iss"] as? String else {
            throw TWDIWCredentialError.missingClaim("iss")
        }
        guard let sub = payload["sub"] as? String else {
            throw TWDIWCredentialError.missingClaim("sub")
        }

        // Signature first: nothing below this line should be read out of a
        // document whose issuer has not been established. A reader that parses
        // the interesting fields and verifies afterwards has already handed
        // attacker-controlled values to whatever it called in between.
        guard let issuerKey = try? JWKDIDKey.p256PublicKey(fromDID: iss) else {
            throw TWDIWCredentialError.unresolvableIssuer
        }
        try verify(jwtParts: jwtParts, with: issuerKey)

        guard let cnf = payload["cnf"] as? [String: Any],
              let holderJWK = cnf["jwk"] as? [String: Any],
              let holderJWKData = try? JSONSerialization.data(withJSONObject: holderJWK),
              let holderKey = try? JWKDIDKey.p256PublicKey(fromJWKBytes: holderJWKData) else {
            throw TWDIWCredentialError.missingClaim("cnf.jwk")
        }

        guard let vc = payload["vc"] as? [String: Any] else {
            throw TWDIWCredentialError.missingClaim("vc")
        }
        guard let types = vc["type"] as? [String], types.count >= 2 else {
            throw TWDIWCredentialError.missingClaim("vc.type")
        }
        guard let subject = vc["credentialSubject"] as? [String: Any] else {
            throw TWDIWCredentialError.missingClaim("vc.credentialSubject")
        }

        if let digestAlgorithm = subject["_sd_alg"] as? String, digestAlgorithm != "sha-256" {
            throw TWDIWCredentialError.unsupportedDigestAlgorithm(digestAlgorithm)
        }
        let commitments = subject["_sd"] as? [String] ?? []

        let claims: [(name: String, value: String)]
        do {
            claims = try SelectiveDisclosure.reveal(disclosures: Array(disclosureStrings),
                                                    committedDigests: commitments)
        } catch SelectiveDisclosure.DisclosureError.undisclosedDigest(let digest) {
            throw TWDIWCredentialError.undisclosedDigest(digest)
        } catch {
            throw TWDIWCredentialError.malformedDisclosure
        }

        return TWDIWCredential(
            serialized: serialized,
            issuerDID: iss,
            subjectDID: sub,
            credentialID: (payload["jti"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            credentialType: types[1],
            notBefore: date(payload["nbf"]) ?? now,
            expires: date(payload["exp"]) ?? .distantFuture,
            holderKey: holderKey,
            status: statusEntry(vc["credentialStatus"]),
            schemaURL: (vc["credentialSchema"] as? [String: Any])?["id"] as? String,
            declaredKeySourceURL: header["jku"] as? String,
            declaredKeyID: header["kid"] as? String,
            commitments: commitments,
            disclosedClaims: claims)
    }

    // MARK: - Plumbing

    private static func object(_ part: String, part name: String) throws -> [String: Any] {
        guard let data = Data(base64URLEncoded: part),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any] else {
            throw TWDIWCredentialError.malformedJSON(part: name)
        }
        return object
    }

    /// ES256 over `base64url(header).base64url(payload)`.
    ///
    /// The signature is the JOSE fixed-width `r || s` pair, not the DER encoding
    /// `SecKeyVerifySignature` expects — hence `rawRepresentation`. Getting this
    /// wrong produces "signature invalid" for perfectly good credentials, which
    /// is the failure this app has already decided is the expensive one.
    private static func verify(jwtParts: [String], with key: P256.Signing.PublicKey) throws {
        guard let signatureBytes = Data(base64URLEncoded: jwtParts[2]),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes) else {
            throw TWDIWCredentialError.signatureInvalid
        }
        let signingInput = Data("\(jwtParts[0]).\(jwtParts[1])".utf8)
        guard key.isValidSignature(signature, for: signingInput) else {
            throw TWDIWCredentialError.signatureInvalid
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }

    private static func statusEntry(_ value: Any?) -> TWDIWStatusListEntry? {
        guard let status = value as? [String: Any],
              let url = status["statusListCredential"] as? String,
              let purpose = status["statusPurpose"] as? String else { return nil }
        // `statusListIndex` is a *string* in production, not a number. Accepting
        // both because the type of an index is exactly the sort of thing that
        // changes between releases, and reading it wrong means checking somebody
        // else's revocation bit.
        let index: Int?
        switch status["statusListIndex"] {
        case let text as String: index = Int(text)
        case let number as NSNumber: index = number.intValue
        default: index = nil
        }
        guard let index else { return nil }
        return TWDIWStatusListEntry(statusListURL: url, index: index, purpose: purpose)
    }
}
