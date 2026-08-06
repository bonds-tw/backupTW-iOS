//
//  VerifiableCredential.swift
//  backupTW
//

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
/// **What this proves, and what it does not.** The only trust root behind this
/// credential is the key living in this device's keychain. A verifier who checks
/// the signature learns that *this device holds the key and asserted these
/// fields* — nothing more. It is **not** evidence that the data came from, or
/// was signed by, any government system. The whitepaper (§5.2) deliberately
/// splits 「資料可驗」 (the data is attested by its issuing authority) from
/// 「本人可驗」 (the presenter is the person the data is about); this type only
/// ever carries the second half, and the MOICA / TW FidO path is what supplies
/// the first. Nothing here should be presented to a user as an official
/// endorsement of the contents.
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
    let credentialSubject: [String: String]

    /// `@context` cannot be spelled as a Swift property name, so the mapping is explicit.
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case type
        case issuer
        case validFrom
        case credentialSubject
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
        ])

    /// Terms the v2 context already defines, which this credential uses and must
    /// therefore *not* redefine. Kept next to the definitions above because the
    /// two lists have to stay disjoint.
    static let v2DefinedTerms: Set<String> = ["id", "type", "name", "description"]

    private static let didKeyPrefix = "did:key:"
}

// MARK: - Building

extension VerifiableCredential {

    /// Wraps the MyData national ID fields in a credential signed by this device.
    ///
    /// Subject and issuer are the same DID on purpose: this is a self-issued
    /// credential, the device attesting to data it holds about its own owner.
    ///
    /// `nil` fields are dropped rather than written as `""`. An empty string is a
    /// claim — it says "this person's household address is the empty string" —
    /// whereas an absent key says "not asserted", which is what a field the MyData
    /// PDF never contained actually means.
    static func selfIssuedNationalID(_ model: NationalIDModel,
                                     issuerDID: String,
                                     validFrom: Date) -> VerifiableCredential {
        var subject: [String: String] = ["id": issuerDID]
        subject["nationality"] = model.nationality
        subject["unifiedNo"] = model.unifiedNo
        subject["name"] = model.name
        subject["birthdate"] = model.birthdate
        subject["addressOfHousehold"] = model.addressOfHousehold

        // The embedded definitions ride along with every copy of the credential.
        // Anything else would mean a verifier's reading of the document depends
        // on a URL bonds-tw has to keep serving forever.
        return VerifiableCredential(context: [.url(credentialsV2Context),
                                              .definitions(nationalIDTermDefinitions)],
                                    type: [baseType, nationalIDType],
                                    issuer: issuerDID,
                                    validFrom: timestamp(from: validFrom),
                                    credentialSubject: subject)
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
