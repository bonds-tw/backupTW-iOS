//
//  VerifiableCredentialTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// The signed credential is the one artefact that leaves the device, so its
/// bytes are a compatibility surface: a verifier we never talk to has to be able
/// to read it. These pin the parts an outside party depends on — the JSON key
/// spellings, the three-segment JWS shape, unpadded base64url — and the property
/// that makes the signature meaningful at all, that the same credential always
/// serializes to the same bytes.
struct VerifiableCredentialTests {

    private static let fullModel = NationalIDModel(nationality: "中華民國（臺灣）",
                                                   unifiedNo: "A123456789",
                                                   name: "王小明",
                                                   birthdate: "0700101",
                                                   addressOfHousehold: "臺北市中正區重慶南路一段122號")

    /// A syntactically valid P-256 did:key. It is the W3C-CCG test vector, so it
    /// is a published example rather than anything derived from a real device.
    private static let issuerDID = "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv"

    private static let issuedAt = Date(timeIntervalSince1970: 1_754_400_000)

    private static let deviceKeyTag = "tw.bonds.backupTW.tests.verifiableCredential"

    /// Signing needs a real keychain item. A test bundle that cannot reach the
    /// keychain fails `SecItemAdd` with `errSecMissingEntitlement`, and a device
    /// key backed by the Secure Enclave is simply absent on some simulators —
    /// both are environment problems rather than defects in the code under test,
    /// so the signing tests disable themselves instead of reporting red.
    static let deviceKeyIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.verifiableCredential.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag)) != nil
    }()

    // MARK: - Field mapping

    @Test func mapsEveryNationalIDFieldIntoTheSubject() throws {
        let credential = VerifiableCredential.selfIssuedNationalID(Self.fullModel,
                                                                   issuerDID: Self.issuerDID,
                                                                   validFrom: Self.issuedAt)

        #expect(credential.credentialSubject["nationality"] == "中華民國（臺灣）")
        #expect(credential.credentialSubject["unifiedNo"] == "A123456789")
        #expect(credential.credentialSubject["name"] == "王小明")
        #expect(credential.credentialSubject["birthdate"] == "0700101")
        #expect(credential.credentialSubject["addressOfHousehold"] == "臺北市中正區重慶南路一段122號")
    }

    /// Self-issued means the subject is the issuer; a verifier reads `id` to know
    /// who the claims are about.
    @Test func subjectIsIdentifiedByTheIssuerDID() {
        let credential = VerifiableCredential.selfIssuedNationalID(Self.fullModel,
                                                                   issuerDID: Self.issuerDID,
                                                                   validFrom: Self.issuedAt)
        #expect(credential.credentialSubject["id"] == Self.issuerDID)
        #expect(credential.issuer == Self.issuerDID)
    }

    /// "Not asserted" and "asserted to be empty" are different claims. The MyData
    /// PDF regularly omits the address, and that must not become `""`.
    @Test func omitsMissingFieldsInsteadOfEmittingEmptyStrings() {
        let sparse = NationalIDModel(nationality: nil,
                                     unifiedNo: "A123456789",
                                     name: nil,
                                     birthdate: nil,
                                     addressOfHousehold: nil)
        let credential = VerifiableCredential.selfIssuedNationalID(sparse,
                                                                   issuerDID: Self.issuerDID,
                                                                   validFrom: Self.issuedAt)

        #expect(credential.credentialSubject["nationality"] == nil)
        #expect(credential.credentialSubject["name"] == nil)
        #expect(credential.credentialSubject["birthdate"] == nil)
        #expect(credential.credentialSubject["addressOfHousehold"] == nil)
        // Only `id` and the one field that was present.
        #expect(credential.credentialSubject.count == 2)
        #expect(Set(credential.credentialSubject.keys) == ["id", "unifiedNo"])
    }

    @Test func carriesTheBaseTypeFirst() {
        let credential = VerifiableCredential.selfIssuedNationalID(Self.fullModel,
                                                                   issuerDID: Self.issuerDID,
                                                                   validFrom: Self.issuedAt)
        #expect(credential.type.first == "VerifiableCredential")
        #expect(credential.type.contains("NationalIDCredential"))
    }

    // MARK: - JSON shape

    /// The Swift property is `context` because `@context` is not a legal
    /// identifier; a verifier that receives `"context"` will reject the document.
    @Test func encodesContextWithTheAtSign() throws {
        let json = try Self.encodedObject(of: Self.sampleCredential())

        #expect(json["@context"] != nil)
        #expect(json["context"] == nil)

        let context = try #require(json["@context"] as? [Any])
        // VC 2.0 requires the v2 URL to be the *first* entry, not merely present.
        #expect(context.first as? String == "https://www.w3.org/ns/credentials/v2")
    }

    // MARK: - JSON-LD terms

    /// **The defect these exist for.** `https://www.w3.org/ns/credentials/v2` is
    /// `@protected` and defines no `@vocab`, so a term it does not define has no
    /// IRI at all — and JSON-LD expansion, which is what a verifier runs before
    /// it maps the document into RDF or checks it against a schema, drops such
    /// terms *silently*. The JWS still verifies. The verifier ends up holding a
    /// valid national-ID credential with no national ID in it.
    ///
    /// **What this file can and cannot check.** These are structural assertions,
    /// not a JSON-LD processor: they check the property expansion depends on —
    /// every term the document uses has a definition reachable from `@context` —
    /// rather than performing expansion. Expansion itself was run against
    /// jsonld.js 8.x with the fetched v2 context while writing this. With only
    /// the v2 URL, `toRDF` emitted 5 triples and dropped `nationality`,
    /// `unifiedNo`, `birthdate`, `addressOfHousehold` and the
    /// `NationalIDCredential` type; with the embedded object it emits 10 and
    /// keeps every one, and `expand` in `safe: true` mode goes from rejecting the
    /// document to accepting it. Re-run that before changing anything here.
    @Test func everyTermTheCredentialUsesResolvesToAnIRI() throws {
        let json = try Self.encodedObject(of: Self.sampleCredential())
        let definitions = try Self.embeddedContext(in: json)

        let subject = try #require(json["credentialSubject"] as? [String: Any])
        for term in subject.keys where !VerifiableCredential.v2DefinedTerms.contains(term) {
            let iri = try #require(definitions[term] as? String,
                                   "credentialSubject.\(term) has no term definition")
            #expect(iri.contains("://"), "\(term) must map to an absolute IRI")
        }

        let types = try #require(json["type"] as? [String])
        for type in types where type != VerifiableCredential.baseType {
            let iri = try #require(definitions[type] as? String,
                                   "type \(type) has no term definition")
            #expect(iri.contains("://"), "\(type) must map to an absolute IRI")
        }
    }

    /// Guards the allowlist the test above leans on. Widening `v2DefinedTerms`
    /// is the one edit that would make an undefined term look defined, so the
    /// list is pinned to what the v2 context actually declares.
    @Test func onlyTermsTheV2ContextDeclaresAreExemptFromDefinition() {
        #expect(VerifiableCredential.v2DefinedTerms == ["id", "type", "name", "description"])
    }

    @Test func embeddedContextIsTheSecondEntryAndIsProtected() throws {
        let json = try Self.encodedObject(of: Self.sampleCredential())
        let context = try #require(json["@context"] as? [Any])

        #expect(context.count == 2)
        #expect(context.first as? String == VerifiableCredential.credentialsV2Context)

        let definitions = try #require(context.last as? [String: Any])
        // Without `@protected`, a later context — or a type-scoped one a
        // verifier applies — could rebind `unifiedNo` to some other IRI, which
        // changes what the credential claims without changing a visible field.
        #expect(definitions["@protected"] as? Bool == true)
    }

    @Test func embeddedContextNamesTheBondsTerms() throws {
        let json = try Self.encodedObject(of: Self.sampleCredential())
        let definitions = try Self.embeddedContext(in: json)

        #expect(definitions["NationalIDCredential"] as? String
                == "https://bonds.tw/ns/credentials#NationalIDCredential")
        #expect(definitions["unifiedNo"] as? String == "https://bonds.tw/ns/credentials#unifiedNo")
        #expect(definitions["nationality"] as? String == "https://bonds.tw/ns/credentials#nationality")
        #expect(definitions["birthdate"] as? String == "https://bonds.tw/ns/credentials#birthdate")
        #expect(definitions["addressOfHousehold"] as? String
                == "https://bonds.tw/ns/credentials#addressOfHousehold")
    }

    /// Redefining a `@protected` term is an expansion *error*, not an override:
    /// a well-meant `"name"` entry here would take the whole document down
    /// rather than one field. `name` in particular is already
    /// `https://schema.org/name` in v2, which is why it is absent above.
    @Test(arguments: ["id", "type", "name", "description", "issuer", "credentialSubject",
                      "validFrom", "validUntil", "proof", "credentialStatus",
                      "credentialSchema", "evidence", "termsOfUse", "refreshService"])
    func embeddedContextDoesNotRedefineProtectedV2Terms(term: String) throws {
        let definitions = try Self.embeddedContext(in: Self.encodedObject(of: Self.sampleCredential()))
        #expect(definitions[term] == nil)
    }

    /// The context is inside the signed payload, so a verifier that decodes the
    /// credential and re-encodes it has to get the same bytes back — otherwise
    /// the signing input is no longer derivable from the document.
    @Test func contextSurvivesADecodeEncodeRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let credential = Self.sampleCredential()
        let data = try encoder.encode(credential)
        let decoded = try JSONDecoder().decode(VerifiableCredential.self, from: data)

        #expect(decoded == credential)
        #expect(try encoder.encode(decoded) == data)
    }

    /// VC 2.0 renamed 1.1's `issuanceDate`; emitting the old name reads as a
    /// credential with no validity period at all.
    @Test func usesValidFromRatherThanIssuanceDate() throws {
        let json = try Self.encodedObject(of: Self.sampleCredential())
        #expect(json["issuanceDate"] == nil)
        #expect(json["validFrom"] as? String == "2025-08-05T13:20:00Z")
    }

    /// XSD 1.1 `dateTimeStamp` makes the timezone designator mandatory.
    @Test func timestampsAreUTCWithAnExplicitDesignator() {
        let stamp = VerifiableCredential.timestamp(from: Self.issuedAt)
        #expect(stamp.hasSuffix("Z"))
        #expect(!stamp.contains("."))
    }

    // MARK: - Determinism

    /// The signature covers the encoded payload bytes. If encoding the same
    /// credential twice can differ — Swift seeds dictionary ordering per process,
    /// so it can — then nobody can re-derive the signing input from the decoded
    /// credential, and the JWS stops being checkable.
    @Test func encodingIsDeterministic() throws {
        let credential = Self.sampleCredential()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let first = try encoder.encode(credential)
        for _ in 0..<32 {
            let again = try encoder.encode(credential)
            #expect(again == first)
        }
    }

    @Test func credentialsBuiltFromTheSameInputsAreEqual() {
        let a = VerifiableCredential.selfIssuedNationalID(Self.fullModel,
                                                          issuerDID: Self.issuerDID,
                                                          validFrom: Self.issuedAt)
        let b = VerifiableCredential.selfIssuedNationalID(Self.fullModel,
                                                          issuerDID: Self.issuerDID,
                                                          validFrom: Self.issuedAt)
        #expect(a == b)
    }

    // MARK: - Verification method

    @Test func verificationMethodRepeatsTheMultibaseValueAsFragment() throws {
        let keyID = try VerifiableCredential.verificationMethodID(for: Self.issuerDID)
        #expect(keyID == Self.issuerDID + "#zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv")
    }

    @Test(arguments: ["", "did:key:", "did:web:example.gov", "zDnaerx9CtbPJ1q36T5"])
    func rejectsIssuersThatAreNotDIDKeys(did: String) {
        #expect(throws: VerifiableCredentialError.self) {
            _ = try VerifiableCredential.verificationMethodID(for: did)
        }
    }

    // MARK: - JWS

    @Test(.enabled(if: VerifiableCredentialTests.deviceKeyIsAvailable))
    func compactSerializationHasThreeSegments() throws {
        let (credential, key, did) = try Self.signingFixture()
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }

        let jws = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)
        let segments = jws.components(separatedBy: ".")

        #expect(segments.count == 3)
        #expect(segments.allSatisfy { !$0.isEmpty })
    }

    /// Padding, `+` and `/` are all illegal in a compact JWS: the segments have to
    /// survive being carried in a URL.
    @Test(.enabled(if: VerifiableCredentialTests.deviceKeyIsAvailable))
    func everySegmentIsUnpaddedBase64URL() throws {
        let (credential, key, did) = try Self.signingFixture()
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }

        let jws = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)

        let alphabet = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for segment in jws.components(separatedBy: ".") {
            #expect(!segment.contains("="))
            #expect(!segment.contains("+"))
            #expect(!segment.contains("/"))
            #expect(segment.rangeOfCharacter(from: alphabet.inverted) == nil)
        }
    }

    @Test(.enabled(if: VerifiableCredentialTests.deviceKeyIsAvailable))
    func headerDeclaresES256AndTheIssuerKeyID() throws {
        let (credential, key, did) = try Self.signingFixture()
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }

        let jws = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)
        let headerData = try #require(Self.base64URLDecoded(jws.components(separatedBy: ".")[0]))
        let headerJSON = try JSONSerialization.jsonObject(with: headerData)
        let header = try #require(headerJSON as? [String: Any])

        #expect(header["alg"] as? String == "ES256")
        #expect(header["typ"] as? String == "vc+jwt")
        #expect(header["cty"] as? String == "vc")
        #expect(header["kid"] as? String == did + "#" + did.replacingOccurrences(of: "did:key:", with: ""))
    }

    /// VC-JOSE-COSE broke with VC 1.1 here: the payload is the credential itself,
    /// and a `vc` claim wrapping it MUST NOT be present.
    @Test(.enabled(if: VerifiableCredentialTests.deviceKeyIsAvailable))
    func payloadIsTheBareCredential() throws {
        let (credential, key, did) = try Self.signingFixture()
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }

        let jws = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)
        let payloadData = try #require(Self.base64URLDecoded(jws.components(separatedBy: ".")[1]))
        let payloadJSON = try JSONSerialization.jsonObject(with: payloadData)
        let payload = try #require(payloadJSON as? [String: Any])

        #expect(payload["vc"] == nil)
        #expect(payload["@context"] != nil)
        #expect(payload["credentialSubject"] != nil)
        #expect(payload["issuer"] as? String == did)

        // Round-trips back into the same value it was built from.
        let decoded = try JSONDecoder().decode(VerifiableCredential.self, from: payloadData)
        #expect(decoded == credential)
    }

    /// ES256 signatures are randomised, so the signature segment legitimately
    /// changes between runs — but the two segments that get signed must not.
    @Test(.enabled(if: VerifiableCredentialTests.deviceKeyIsAvailable))
    func signingTwiceProducesTheSameSigningInput() throws {
        let (credential, key, did) = try Self.signingFixture()
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }

        let first = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)
            .components(separatedBy: ".")
        let second = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)
            .components(separatedBy: ".")

        #expect(first[0] == second[0])
        #expect(first[1] == second[1])
    }

    /// ES256 is a fixed-width `r ‖ s`; a DER signature would land here at some
    /// other length and quietly produce an unverifiable credential.
    @Test(.enabled(if: VerifiableCredentialTests.deviceKeyIsAvailable))
    func signatureSegmentIs64Bytes() throws {
        let (credential, key, did) = try Self.signingFixture()
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }

        let jws = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)
        let signature = try #require(Self.base64URLDecoded(jws.components(separatedBy: ".")[2]))
        #expect(signature.count == 64)
    }

    /// Signing with a key that belongs to a different DID would mint a credential
    /// naming one issuer and pointing `kid` at another.
    @Test(.enabled(if: VerifiableCredentialTests.deviceKeyIsAvailable))
    func refusesToSignForADifferentIssuer() throws {
        let (credential, key, _) = try Self.signingFixture()
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }

        #expect(throws: VerifiableCredentialError.issuerMismatch) {
            _ = try credential.jwsCompactSerialization(signedBy: key, issuerDID: Self.issuerDID)
        }
    }

    // MARK: - Helpers

    private static func sampleCredential() -> VerifiableCredential {
        selfIssued(from: fullModel, did: issuerDID)
    }

    private static func selfIssued(from model: NationalIDModel, did: String) -> VerifiableCredential {
        VerifiableCredential.selfIssuedNationalID(model, issuerDID: did, validFrom: issuedAt)
    }

    /// The credential has to be issued by the DID of the key that signs it, so the
    /// fixture derives the DID from a freshly created device key rather than using
    /// the published test vector.
    private static func signingFixture() throws -> (VerifiableCredential, DeviceKey, String) {
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        return (selfIssued(from: fullModel, did: did), key, did)
    }

    /// The inline term-definition object: the entry of `@context` that is a JSON
    /// object rather than a URL.
    private static func embeddedContext(in json: [String: Any]) throws -> [String: Any] {
        let context = try #require(json["@context"] as? [Any])
        return try #require(context.compactMap { $0 as? [String: Any] }.first,
                            "@context carries no inline definitions")
    }

    private static func encodedObject(of credential: VerifiableCredential) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(credential)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    /// Decoding is written out here rather than reusing the production helper —
    /// a test that checks an encoder against its own inverse would pass on any
    /// self-consistent alphabet, including a wrong one.
    private static func base64URLDecoded(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}
