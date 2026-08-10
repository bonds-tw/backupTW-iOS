//
//  VerifiableCredential.swift
//  backupTW
//

import CryptoKit
import Foundation

/// Errors raised while turning a credential into a signed JWS.
///
/// None of the cases carry the DID or the credential itself. A device DID is a
/// stable, correlatable identifier for its holder, and an error that gets
/// printed or shipped to a crash reporter is exactly how such an identifier
/// leaks — so the failure is described by its kind alone.
enum VerifiableCredentialError: Error, Equatable {
    /// `issuerDID` is not a `did:key:` DID, so no verification method can be derived from it.
    case unsupportedIssuerDID
    /// The DID passed to the signer is not the one recorded in `issuer`.
    case issuerMismatch
    /// `DeviceKey` returned something that is not a 64-byte `r ‖ s` pair.
    case malformedSignature
}

extension VerifiableCredentialError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedIssuerDID, .issuerMismatch, .malformedSignature:
            // Every case here is a programming error rather than something the
            // user did, so they all collapse into one honest sentence instead of
            // leaking internals into the UI.
            return NSLocalizedString("This document could not be signed on this device.", comment: "")
        }
    }
}

/// A W3C Verifiable Credential 2.0 data model object.
///
/// **This type is the payload, and by itself it proves nothing.** What a
/// verifier may believe depends entirely on what is wrapped around these bytes:
///
/// - `MOICASignedCredential` — the cardholder's 自然人憑證 over a digest of the
///   credential. A verifier learns that a named cardholder, whose certificate
///   chains to MOICA G3, asserted exactly these fields. This is what the app
///   issues now.
/// - `jwsCompactSerialization` — the device's own key. A verifier learns that
///   *some device* asserted these fields, which is worth close to nothing on its
///   own, since the device made the key up. Credentials issued before the
///   card-signing change carry this and are still readable.
///
/// Neither is evidence that the *data* is correct. The whitepaper (§5.2) splits
/// 「資料可驗」 (attested by the issuing authority) from 「本人可驗」 (the
/// presenter is the person the data is about); a card signature is a strong
/// version of the second and still not the first — the fields come from a MyData
/// download that carries no signature of its own. Nothing here may be presented
/// to a user as an official endorsement of the contents.
///
/// Field names follow VC 2.0, not 1.1: `issuanceDate` was renamed `validFrom`,
/// and its meaning shifted from "when this was signed" to "when this starts
/// being valid".
struct VerifiableCredential: Codable, Equatable {

    /// Ordered set; the v2 URL has to be the first element per VC 2.0 §4.1.
    /// Later entries may be inline term-definition objects — see
    /// `nationalIDTermDefinitions` for why this credential needs one.
    let context: [JSONLDContextEntry]
    /// Must contain `VerifiableCredential`; more specific types come after it.
    let type: [String]
    /// A URL, which for a self-issued credential is the device's own DID.
    let issuer: String
    /// XSD 1.1 `dateTimeStamp` — see `timestamp(from:)` for why the format matters.
    let validFrom: String
    /// Flat string map; `id` identifies the subject.
    ///
    /// When `sd` is present this holds only `id` — every factual claim has moved
    /// behind a digest, and a claim left in the clear here would be one the
    /// holder can never withhold.
    let credentialSubject: [String: String]

    /// Sorted digests of the claims the issuer committed to, SD-JWT style.
    ///
    /// `nil` on credentials issued before selective disclosure, which carry
    /// their claims in `credentialSubject` and cannot withhold any of them.
    ///
    /// # Why the digests are here and not inside `credentialSubject`
    ///
    /// SD-JWT puts `_sd` inside the object whose members are hidden. This model
    /// types `credentialSubject` as `[String: String]`, which cannot hold an
    /// array, and widening it to a general JSON value would change how every
    /// existing claim is read, signed and displayed — a much larger change than
    /// the one being made. A sibling field is a project-defined placement, it is
    /// named as such, and what matters for soundness is that one side commits
    /// and the other checks against the same list. `MOICASignedCredential`
    /// verifies the card's signature over the whole payload including this
    /// array, so the commitment is as protected as any other field.
    ///
    /// The array is **sorted**, which `SelectiveDisclosure.commit` does and this
    /// relies on: left in claim order, position would say which digest belongs
    /// to which field, and a verifier receiving one disclosure would learn what
    /// the withheld ones are.
    let sd: [String]?

    /// `@context` cannot be spelled as a Swift property name, so the mapping is explicit.
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case type
        case issuer
        case validFrom
        case credentialSubject
        case sd = "_sd"
    }

    // MARK: - Vocabulary

    static let credentialsV2Context = "https://www.w3.org/ns/credentials/v2"
    static let baseType = "VerifiableCredential"
    static let nationalIDType = "NationalIDCredential"

    /// Namespace for the terms bonds-tw defines itself.
    ///
    /// Nothing dereferences this IRI — in JSON-LD a term's IRI is an identifier,
    /// not a fetch instruction, and the definitions travel inside the credential.
    /// It is spelled as an `https:` URL under a domain the project controls so
    /// that the day bonds-tw does host a context document, the second `@context`
    /// entry can be replaced by its URL *without any IRI changing* — credentials
    /// issued before and after keep expanding to the same RDF.
    static let termNamespace = "https://bonds.tw/ns/credentials#"

    /// The inline `@context` object that gives the national-ID terms an IRI.
    ///
    /// **Why this exists at all.** `https://www.w3.org/ns/credentials/v2` is
    /// `@protected` and defines no `@vocab`. A term it does not define therefore
    /// has no IRI, and JSON-LD expansion — which is what a verifier runs before
    /// it maps the document into RDF, checks a schema, or shows a field to a
    /// human — drops such terms *silently*. Measured against jsonld.js 8.x with
    /// the real v2 context: with `@context` holding only the v2 URL, this
    /// credential converts to five triples — `type VerifiableCredential`,
    /// `credentialSubject`, `issuer`, `validFrom`, and `schema:name` (v2 does
    /// define `name`). `unifiedNo`, `birthdate`, `addressOfHousehold`,
    /// `nationality` and the `NationalIDCredential` type are simply gone, while
    /// the JWS still verifies. The verifier is then holding a signed, valid,
    /// national-ID credential that contains no national ID.
    ///
    /// **What is deliberately absent.** `name`, `id`, `type`, `issuer`,
    /// `credentialSubject` and `validFrom` are all defined by v2 under
    /// `@protected`, and redefining a protected term is an expansion error
    /// rather than an override — so this object must define only terms v2 has
    /// never heard of.
    ///
    /// **Why custom IRIs instead of schema.org.** The values are not what the
    /// obvious schema.org properties mean: `birthdate` is a 民國 date
    /// (`0700101`) and not an `xsd:date`, `nationality` is free text where
    /// `schema:nationality` expects a Country node, and `addressOfHousehold` is
    /// a 戶籍 address string rather than a `schema:PostalAddress`. Borrowing
    /// those IRIs would make the credential assert something false to any
    /// consumer that reasons over them.
    static let nationalIDTermDefinitions = JSONLDTermDefinitions(
        isProtected: true,
        terms: [
            nationalIDType: termNamespace + "NationalIDCredential",
            "nationality": termNamespace + "nationality",
            "unifiedNo": termNamespace + "unifiedNo",
            "birthdate": termNamespace + "birthdate",
            "addressOfHousehold": termNamespace + "addressOfHousehold",
            AgePredicate.claimName: termNamespace + AgePredicate.claimName,
        ])

    /// Terms the v2 context already defines, which this credential uses and must
    /// therefore *not* redefine. Kept next to the definitions above because the
    /// two lists have to stay disjoint.
    static let v2DefinedTerms: Set<String> = ["id", "type", "name", "description"]

    private static let didKeyPrefix = "did:key:"
}

// MARK: - Building

extension VerifiableCredential {

    /// Wraps the MyData national ID fields in a credential.
    ///
    /// **This builds the payload. It secures nothing.** The name it used to have
    /// — `selfIssuedNationalID` — described both, back when the device's own key
    /// was the only signature involved, and that made the important question
    /// invisible: what a verifier should believe depends entirely on which
    /// signature is wrapped around these bytes. `MOICASignedCredential` is the
    /// one that matters now; `jwsCompactSerialization` is the older, weaker one.
    ///
    /// Subject and issuer are the same DID on purpose, and it is the *device's*
    /// DID in both cases. That is not a claim that the device vouches for the
    /// contents — the card signature does that — it is the identifier the holder
    /// presents under, and the presentation layer binds to it. It stays the
    /// device's because a cardholder identifier derived from the certificate
    /// could not be put here at all: the certificate only arrives *after* the
    /// signature, and the digest that gets signed has to cover these bytes
    /// already.
    ///
    /// `nil` fields are dropped rather than written as `""`. An empty string is a
    /// claim — it says "this person's household address is the empty string" —
    /// whereas an absent key says "not asserted", which is what a field the MyData
    /// PDF never contained actually means.
    static func nationalID(_ model: NationalIDModel,
                           issuerDID: String,
                           validFrom: Date) -> VerifiableCredential {
        VerifiableCredential(context: [.url(credentialsV2Context),
                                       .definitions(nationalIDTermDefinitions)],
                             type: [baseType, nationalIDType],
                             issuer: issuerDID,
                             validFrom: timestamp(from: validFrom),
                             credentialSubject: ["id": issuerDID]
                                 .merging(nationalIDClaims(model, validFrom: validFrom)) { a, _ in a },
                             sd: nil)
    }

    /// The claims this build derives from a MyData document, in one place so the
    /// plain credential and the selectively-disclosable one cannot disagree
    /// about what a credential contains.
    ///
    /// `nil` fields are dropped rather than written as `""`. An empty string is a
    /// claim — it says "this person's household address is the empty string" —
    /// whereas an absent key says "not asserted", which is what a field the MyData
    /// PDF never contained actually means.
    static func nationalIDClaims(_ model: NationalIDModel, validFrom: Date) -> [String: String] {
        var claims: [String: String] = [:]
        claims["nationality"] = model.nationality
        claims["unifiedNo"] = model.unifiedNo
        claims["name"] = model.name
        claims["birthdate"] = model.birthdate
        claims["addressOfHousehold"] = model.addressOfHousehold
        // Derived at issuance, because that is the only moment the birthdate and
        // a trustworthy clock are both in hand — and because a predicate the
        // card signs carries the same authority as the date it came from, while
        // a predicate computed later by whoever is holding the file carries
        // none. Absent when the birthdate is not a form this build can read:
        // see `AgePredicate.claimValue` for why that must not become "false".
        claims[AgePredicate.claimName] = AgePredicate.claimValue(birthdate: model.birthdate,
                                                                 asOf: validFrom)
        return claims
    }

    /// The same credential with every factual claim behind a digest, plus the
    /// disclosures that open them.
    ///
    /// This is what issuance builds now. The card signs the credential — digests
    /// and all — so a holder can later hand over any subset of the disclosures
    /// and a verifier can check each one against a commitment the cardholder
    /// signed. Nothing here is secret from the holder: they hold every
    /// disclosure and choose which to part with.
    ///
    /// `credentialSubject` keeps only `id`, and that is deliberate rather than
    /// tidy: any claim left beside it would be one the holder has no way to
    /// withhold, which is exactly the property this exists to give them.
    static func selectivelyDisclosableNationalID(
        _ model: NationalIDModel,
        issuerDID: String,
        validFrom: Date
    ) -> (credential: VerifiableCredential, disclosures: [Disclosure]) {
        let claims = nationalIDClaims(model, validFrom: validFrom)
            // Sorted so that issuing the same document twice produces the same
            // *set* of digests in the same order. The salts still differ, so the
            // digests themselves differ — this is reproducibility of structure,
            // not of value, and the sort in `commit` is what protects position.
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, value: $0.value) }
        let (digests, disclosures) = SelectiveDisclosure.commit(claims)

        let credential = VerifiableCredential(
            context: [.url(credentialsV2Context), .definitions(nationalIDTermDefinitions)],
            type: [baseType, nationalIDType],
            issuer: issuerDID,
            validFrom: timestamp(from: validFrom),
            credentialSubject: ["id": issuerDID],
            sd: digests)
        return (credential, disclosures)
    }

    /// VC 2.0 requires an XSD 1.1 `dateTimeStamp`, which — unlike the RFC 3339
    /// profile 1.1 referenced — makes the timezone designator mandatory. Always
    /// emitting UTC sidesteps that entirely.
    ///
    /// Fractional seconds are dropped deliberately. The signed payload has to be
    /// reproducible from the same inputs, and two `Date`s a microsecond apart are
    /// the same instant as far as this credential is concerned.
    static func timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Canonical bytes

extension VerifiableCredential {

    /// The bytes a signature over this credential covers.
    ///
    /// Identical in construction to the JWS payload segment, and for the same
    /// reason: `sortedKeys` is what stops Swift's per-process dictionary seed
    /// from producing a different serialization on the next launch.
    ///
    /// **Callers must keep these bytes, not re-derive them.** A verifier that
    /// re-encodes a decoded credential in order to re-check a digest is trusting
    /// that its `JSONEncoder` emits byte-for-byte what the issuing device's did —
    /// across OS versions, across the swift-foundation rewrite, across whatever
    /// Foundation decides to escape next. `MOICASignedCredential` therefore
    /// carries the payload as bytes and only ever decodes them, which is the same
    /// discipline a compact JWS enforces by construction.
    func canonicalBytes() throws -> Data {
        try Self.canonicalEncoder.encode(self)
    }

    /// Lowercase hex SHA-256 of `bytes` — the ASCII string handed to TW FidO as
    /// the thing to be signed.
    ///
    /// Hex rather than raw digest bytes because `sign_data` travels as a string:
    /// it is concatenated into the `sp_checksum` payload and base64-wrapped into
    /// the request body, and a printable TBS is one that can be compared by eye
    /// against a device log without a decoding step in between. The choice is
    /// load-bearing for verification, so it is named in the proof rather than
    /// left to be inferred — see `MOICACredentialProof.tbsConstruction`.
    static func digestHex(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - JWS

extension VerifiableCredential {

    /// Secures the credential as a compact JWS, per W3C VC-JOSE-COSE.
    ///
    /// The payload is the credential object itself — *not* a JWT claims set with
    /// the credential nested under a `vc` claim. That nesting was the VC 1.1
    /// shape and VC-JOSE-COSE explicitly forbids it, so no `iss`/`sub`/`nbf`
    /// claims are added either: duplicating `issuer` into `iss` only creates two
    /// places for the same fact to disagree.
    func jwsCompactSerialization(signedBy key: DeviceKey, issuerDID: String) throws -> String {
        // Signing with a key whose DID differs from the recorded issuer would
        // produce a credential that names one issuer and points its `kid` at
        // another — silently unverifiable, and easy to miss. Refuse instead.
        guard issuer == issuerDID else {
            throw VerifiableCredentialError.issuerMismatch
        }

        // MUST be present whenever the issuer's key is expressed as a DID URL.
        let keyID = try Self.verificationMethodID(for: issuerDID)

        let header: [String: String] = [
            "alg": "ES256",
            // The media type registered for a secured credential. Earlier drafts
            // used `vc+ld+jwt`; the 2025 Recommendation settled on `vc+jwt`.
            "typ": "vc+jwt",
            "cty": "vc",
            "kid": keyID,
        ]

        let encoder = Self.canonicalEncoder
        let headerData = try encoder.encode(header)
        let payloadData = try encoder.encode(self)

        // The very bytes that were base64url-encoded are the bytes that get
        // signed. Re-encoding the credential for the signature would risk a
        // different serialization and a JWS that fails to verify against itself.
        let signingInput = Self.base64URLEncoded(headerData) + "." + Self.base64URLEncoded(payloadData)
        let signature = try key.signature(for: Data(signingInput.utf8))

        // JOSE wants a fixed-width `r ‖ s`, both left-padded to 32 bytes. A DER
        // signature would arrive here at a different length and be silently
        // accepted as garbage by anything that just splits on dots.
        guard signature.count == 64 else {
            throw VerifiableCredentialError.malformedSignature
        }

        return signingInput + "." + Self.base64URLEncoded(signature)
    }

    /// The `kid` for a `did:key:` issuer: the DID, then the multibase value
    /// repeated as the fragment (`did:key:zDn…#zDn…`).
    ///
    /// The did:key algorithm text says to append the *multicodec* value, but every
    /// example in that same document — and every implementation — appends the
    /// multibase value. The examples win.
    static func verificationMethodID(for did: String) throws -> String {
        guard did.hasPrefix(didKeyPrefix) else {
            throw VerifiableCredentialError.unsupportedIssuerDID
        }
        let multibaseValue = String(did.dropFirst(didKeyPrefix.count))
        guard !multibaseValue.isEmpty else {
            throw VerifiableCredentialError.unsupportedIssuerDID
        }
        return did + "#" + multibaseValue
    }

    /// A fresh encoder per call: `JSONEncoder` is a reference type, and signing can
    /// happen off the main thread.
    ///
    /// `sortedKeys` is the load-bearing option. Swift's dictionary iteration order
    /// is seeded per process, so without it the same credential would serialize
    /// differently between launches — and since the signature covers the encoded
    /// bytes, a caller who re-encoded to verify would get a mismatch.
    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// base64url without padding, as every part of a compact JWS requires.
    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - JSON-LD context

/// One entry of a JSON-LD `@context` array: either a URL a verifier resolves, or
/// an object that defines terms inline.
///
/// Modelled as an enum rather than `[String]` because `@context` is genuinely
/// heterogeneous, and this credential needs the second form: bonds-tw has no
/// domain path serving a context document, so the definitions travel inside the
/// credential itself.
enum JSONLDContextEntry: Equatable {
    case url(String)
    case definitions(JSONLDTermDefinitions)
}

extension JSONLDContextEntry: Codable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let url = try? container.decode(String.self) {
            self = .url(url)
        } else {
            self = .definitions(try container.decode(JSONLDTermDefinitions.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .url(let url):
            try container.encode(url)
        case .definitions(let definitions):
            try container.encode(definitions)
        }
    }
}

/// An inline JSON-LD context object: `@protected`, plus one absolute IRI per
/// term.
///
/// Only the two shapes this credential needs are modelled — a boolean
/// `@protected` and simple `term → IRI` strings. Expanded term definitions
/// (`{"@id": …, "@type": …}`) are not represented, because every term here maps
/// a plain string value and giving one an `@type` it does not have is how a
/// verifier ends up rejecting a well-formed credential.
struct JSONLDTermDefinitions: Equatable {

    /// Mirrors what the v2 context does to its own terms: once defined, a term
    /// cannot be quietly redefined by a later context or a type-scoped one. That
    /// matters here — `unifiedNo` pointing somewhere else halfway through a
    /// document would change what the credential claims without changing a
    /// single visible field.
    let isProtected: Bool

    /// Term name → absolute IRI.
    let terms: [String: String]
}

extension JSONLDTermDefinitions: Codable {

    /// The keys are the term names themselves, so they cannot be an enum.
    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let protectedKeyword = "@protected"

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var isProtected = false
        var terms: [String: String] = [:]
        for key in container.allKeys {
            if key.stringValue == Self.protectedKeyword {
                isProtected = try container.decode(Bool.self, forKey: key)
            } else {
                terms[key.stringValue] = try container.decode(String.self, forKey: key)
            }
        }
        self.isProtected = isProtected
        self.terms = terms
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        // Written only when true: `"@protected": false` is not the same document
        // as one without the keyword, and round-tripping has to reproduce the
        // exact bytes the signature was taken over.
        if isProtected {
            try container.encode(true, forKey: DynamicKey(Self.protectedKeyword))
        }
        // Emitted in whatever order the dictionary yields; `JSONEncoder`'s
        // `.sortedKeys` — which the JWS encoder sets — is what makes the result
        // byte-stable, exactly as it does for `credentialSubject`.
        for (term, iri) in terms {
            try container.encode(iri, forKey: DynamicKey(term))
        }
    }
}
