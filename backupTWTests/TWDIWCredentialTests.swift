//
//  TWDIWCredentialTests.swift
//  backupTWTests
//
//  Reading 台灣數位憑證皮夾's credentials — starting with the one fact that had
//  to be measured rather than assumed.
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// # The claim this file exists to settle
///
/// Everything about reading a TWDIW credential is container-shuffling except one
/// thing: **what exactly gets hashed to produce an `_sd` entry.** SD-JWT digests
/// the disclosure's *base64url string*, not the JSON it decodes to. The two
/// differ, both are plausible, and choosing wrong yields a reader that finds no
/// match for any honest disclosure and reports every real card as a forgery.
///
/// So it is checked against production values rather than against a
/// specification reading: two real `_sd` entries and the six real disclosures
/// from a driving licence issued 2025-10-07, reproduced here verbatim. The
/// personal data is TWDIW's own published sample (a person who does not exist);
/// the ID number is the ten-character form, which matters because reading these
/// values off the rendered documentation page instead of decoding them produced
/// an eleven-character one.
@Suite("TWDIW 憑證：摘要算法與容器")
struct TWDIWCredentialTests {

    /// The six disclosures of a real 駕照電子卡, exactly as they appeared after
    /// the `~` separators.
    static let productionDisclosures = [
        "WyJhOFNHY1VKY2RYTW1aM2VTVVM2eERRIiwibmFtZSIsIumZs-etseeOsiJd",
        "WyJwbHowWFN6LW9CSEUwZTUzTFVBeWNBIiwiaWRfbnVtYmVyIiwiQTIzNDU2Nzg5MCJd",
        "WyJOdGVYcHFIQWNWZ2p2dXpKQUxJQVpBIiwicm9jX2JpcnRoZGF5IiwiMDU3MDYwNSJd",
        "WyI3RUFnQWFGamVSUlBZUV9kSURwZUhBIiwidHlwZSIsIuaZrumAmuWwj-Wei-i7iiJd",
        "WyJ1NzNEMGs1N252ZUFncUlzMmVQTFJnIiwiY29udHJvbG51bWJlciIsIjQwMTA0MDIwOTE0NDUiXQ",
        "WyJwdENBU0Fvc25BX0RuN2JzRGlGektBIiwiZ0RhdGUiLCIxMDIwNzAxIl0",
    ]

    /// The first two entries of that credential's `vc.credentialSubject._sd`.
    static let productionCommitments = [
        "ApkeYAR85EzxAHS1ojnNHhG7wnCDyTt4_iCIX2VKxaw",
        "PDVMnTCDSl0gJrzo9xUwoAhI8YkTZP1BfPiPrCO8tho",
    ]

    // MARK: The measured fact

    /// **The decisive test.** This app's own `Disclosure.digest` reproduces two
    /// real TWDIW commitments from two real TWDIW disclosures — so the
    /// cryptography is already shared and only the container differs.
    @Test func theDigestAlgorithmMatchesProduction() {
        let digests = Dictionary(uniqueKeysWithValues: Self.productionDisclosures.map {
            (Disclosure.digest(of: $0), Disclosure(encoded: $0)?.claimName ?? "?")
        })
        #expect(digests[Self.productionCommitments[0]] == "id_number")
        #expect(digests[Self.productionCommitments[1]] == "roc_birthday")
    }

    /// The alternative reading, stated so the choice is visible rather than
    /// implied. Hashing the *decoded* array matches nothing.
    @Test func hashingTheDecodedFormMatchesNothing() throws {
        let decodedDigests = Set(Self.productionDisclosures.map { encoded -> String in
            let bytes = Data(base64URLEncoded: encoded) ?? Data()
            return Data(SHA256.hash(data: bytes)).base64URLEncodedString()
        })
        for commitment in Self.productionCommitments {
            #expect(!decodedDigests.contains(commitment))
        }
    }

    /// The disclosures decode to the values TWDIW published, including the two
    /// that were mis-transcribed the first time round from rendered HTML.
    @Test func theProductionDisclosuresDecodeToTheirPublishedValues() throws {
        let claims = Self.productionDisclosures.compactMap(Disclosure.init(encoded:))
        #expect(claims.count == 6)
        let byName = Dictionary(uniqueKeysWithValues: claims.map { ($0.claimName, $0.claimValue) })
        #expect(byName["name"] == "陳筱玲")
        // Ten characters, the real shape of a 統一編號 — not eleven.
        #expect(byName["id_number"] == "A234567890")
        #expect(byName["id_number"]?.count == 10)
        #expect(byName["roc_birthday"] == "0570605")
        #expect(byName["type"] == "普通小型車")
        #expect(byName["controlnumber"] == "4010402091445")
        #expect(byName["gDate"] == "1020701")
    }

    /// `_sd` is sorted, not in claim order. Position must not say which digest
    /// belongs to which field — the property this app already enforces on its
    /// own credentials, and which TWDIW's published prefix is consistent with:
    /// the two published entries are the two smallest of the six.
    @Test func theCommittedDigestsAreSortedNotInClaimOrder() {
        let sorted = Self.productionDisclosures.map(Disclosure.digest(of:)).sorted()
        #expect(Array(sorted.prefix(2)) == Self.productionCommitments)
        // And that is genuinely a different order from the disclosures'.
        #expect(sorted != Self.productionDisclosures.map(Disclosure.digest(of:)))
    }

    // MARK: The container

    @Test func readsAWellFormedCredential() throws {
        let fixture = TWDIWFixture()
        let credential = try TWDIWCredentialReader.read(fixture.serialized)

        #expect(credential.issuerDID == fixture.issuerDID)
        #expect(credential.subjectDID == fixture.holderDID)
        #expect(credential.credentialType == TWDIWFixture.credentialType)
        #expect(credential.holderKey.rawRepresentation == fixture.holderKey.rawRepresentation)
        #expect(credential.schemaURL == TWDIWFixture.schemaURL)
        #expect(Set(credential.disclosedClaims.map(\.name))
                == ["name", "id_number", "roc_birthday"])
    }

    /// A trailing `~` is part of the serialization, not an empty disclosure.
    @Test func theTrailingSeparatorIsNotReadAsADisclosure() throws {
        let fixture = TWDIWFixture()
        #expect(fixture.serialized.hasSuffix("~"))
        let credential = try TWDIWCredentialReader.read(fixture.serialized)
        #expect(credential.disclosedClaims.count == 3)
    }

    /// Withholding is the point: fewer disclosures than commitments is normal,
    /// and a reader that demanded all of them would have abolished selective
    /// disclosure while appearing to implement it.
    @Test func aHolderMayPresentFewerDisclosuresThanWereCommitted() throws {
        let fixture = TWDIWFixture()
        let credential = try TWDIWCredentialReader.read(fixture.withholdingAllBut("name"))
        #expect(credential.disclosedClaims.map(\.name) == ["name"])
        #expect(credential.commitments.count == 3)
    }

    /// **The red line.** A disclosure the issuer never committed to would let a
    /// holder assert anything at all.
    @Test func aDisclosureTheIssuerNeverCommittedToIsRefused() throws {
        let fixture = TWDIWFixture()
        let forged = Disclosure(claimName: "type", claimValue: "大型重型機車")
        do {
            _ = try TWDIWCredentialReader.read(fixture.adding(forged))
            Issue.record("an uncommitted disclosure was accepted")
        } catch let error as TWDIWCredentialError {
            guard case .undisclosedDigest = error else {
                Issue.record("refused for the wrong reason: \(error)")
                return
            }
        }
    }

    /// The signature is checked against the key the issuer's DID names, so a
    /// credential re-signed by anybody else is refused even though every field
    /// still reads correctly.
    @Test func aCredentialSignedByAnotherKeyIsRefused() throws {
        let fixture = TWDIWFixture()
        #expect(throws: TWDIWCredentialError.signatureInvalid) {
            try TWDIWCredentialReader.read(fixture.resignedByAStranger())
        }
    }

    /// And a payload edited after signing.
    @Test func aTamperedPayloadIsRefused() throws {
        let fixture = TWDIWFixture()
        #expect(throws: TWDIWCredentialError.signatureInvalid) {
            try TWDIWCredentialReader.read(fixture.withTamperedType())
        }
    }

    /// `alg: none` and the rest of that family. The verifier must not learn from
    /// the token which algorithm to trust.
    @Test func anAlgorithmOtherThanES256IsRefused() throws {
        let fixture = TWDIWFixture()
        do {
            _ = try TWDIWCredentialReader.read(fixture.withHeaderAlgorithm("none"))
            Issue.record("alg: none was accepted")
        } catch let error as TWDIWCredentialError {
            #expect(error == .unsupportedAlgorithm("none"))
        }
    }

    @Test func anUnknownDigestAlgorithmIsRefusedRatherThanAssumed() throws {
        let fixture = TWDIWFixture()
        #expect(throws: TWDIWCredentialError.unsupportedDigestAlgorithm("sha-512")) {
            try TWDIWCredentialReader.read(fixture.withDigestAlgorithm("sha-512"))
        }
    }

    /// This app's own `did:key` spelling in `iss` cannot be resolved by the
    /// TWDIW reader, and says so as itself rather than as a bad signature.
    @Test func anIssuerDIDInTheOtherSpellingIsNamedNotMisreported() throws {
        let fixture = TWDIWFixture()
        #expect(throws: TWDIWCredentialError.unresolvableIssuer) {
            try TWDIWCredentialReader.read(fixture.withP256PubIssuerDID())
        }
    }

    // MARK: jku is recorded and disobeyed

    /// `jku` is parsed out — a diagnostic screen and an upstream bug report both
    /// need "which URL did this card claim its key lives at".
    @Test func theDeclaredKeySourceIsRetained() throws {
        let fixture = TWDIWFixture()
        let credential = try TWDIWCredentialReader.read(fixture.serialized)
        #expect(credential.declaredKeySourceURL == TWDIWFixture.jku)
        #expect(credential.declaredKeyID == "key-1")
    }

    /// **And disobeyed.** A credential pointing `jku` at somewhere else, signed
    /// by a key that is not the issuer DID's, is refused — the reader never
    /// looks the URL up, so where it points cannot matter.
    @Test func aCredentialThatPointsJKUElsewhereIsStillCheckedAgainstItsDID() throws {
        let fixture = TWDIWFixture()
        #expect(throws: TWDIWCredentialError.signatureInvalid) {
            try TWDIWCredentialReader.read(
                fixture.resignedByAStranger(claimingKeySource: "https://example.invalid/keys"))
        }
    }

    // MARK: The status entry

    /// `statusListIndex` is a *string* in production. Reading it as a number
    /// only would silently drop the entry — and an absent status entry is how a
    /// credential ends up never checked for revocation.
    @Test func aStringStatusListIndexIsRead() throws {
        let fixture = TWDIWFixture()
        let credential = try TWDIWCredentialReader.read(fixture.serialized)
        let status = try #require(credential.status)
        #expect(status.index == 35)
        #expect(status.purpose == "revocation")
        #expect(status.statusListURL == TWDIWFixture.statusListURL)
    }
}

// MARK: - Fixture

/// A credential in TWDIW's exact shape, signed by a key the test controls.
///
/// Synthesised rather than captured because no complete production credential is
/// public — the published examples truncate the payload. What *is* captured is
/// the part that had to be: the digest algorithm, checked against real `_sd`
/// values in the suite above. This fixture reproduces the container: `vc+sd-jwt`
/// with `jku`, `cnf.jwk`, `vc.type[1]`, `StatusList2021Entry` with a string
/// index, and `_sd` inside `vc.credentialSubject`.
struct TWDIWFixture {

    static let credentialType = "00000000_demo_drivinglicense_202504251418"
    static let jku = "https://issuer-vc.wallet.gov.tw/api/keys"
    static let schemaURL = "https://frontend.wallet.gov.tw/api/schema/00000000/demo/V1/b653ad4b"
    static let statusListURL =
        "https://issuer-vc.wallet.gov.tw/api/status-list/00000000_demo_drivinglicense_202504251418/r0"

    let issuerPrivateKey = P256.Signing.PrivateKey()
    let holderPrivateKey = P256.Signing.PrivateKey()
    let disclosures: [Disclosure]

    init() {
        disclosures = [
            Disclosure(claimName: "name", claimValue: "陳筱玲"),
            Disclosure(claimName: "id_number", claimValue: "A234567890"),
            Disclosure(claimName: "roc_birthday", claimValue: "0570605"),
        ]
    }

    var holderKey: P256.Signing.PublicKey { holderPrivateKey.publicKey }

    var issuerDID: String {
        (try? JWKDIDKey.did(fromP256PublicKeyX963: issuerPrivateKey.publicKey.x963Representation)) ?? ""
    }

    var holderDID: String {
        (try? JWKDIDKey.did(fromP256PublicKeyX963: holderKey.x963Representation)) ?? ""
    }

    var serialized: String { build() }

    func withholdingAllBut(_ name: String) -> String {
        build(present: disclosures.filter { $0.claimName == name })
    }

    func adding(_ extra: Disclosure) -> String {
        build(present: disclosures + [extra])
    }

    func resignedByAStranger(claimingKeySource: String? = nil) -> String {
        build(signedBy: P256.Signing.PrivateKey(), jku: claimingKeySource ?? Self.jku)
    }

    func withHeaderAlgorithm(_ alg: String) -> String { build(algorithm: alg) }

    /// A credential with no `exp` claim at all — which the reader substitutes
    /// `.distantFuture` for, and which anything displaying a date has to notice.
    func withoutExpiry() -> String { build(omittingExpiry: true) }

    func withDigestAlgorithm(_ alg: String) -> String { build(digestAlgorithm: alg) }
    func withP256PubIssuerDID() -> String {
        build(issuerDIDOverride:
                (try? DIDKey.did(fromP256PublicKeyX963: issuerPrivateKey.publicKey.x963Representation)))
    }

    /// Edits `vc.type[1]` after the signature is computed, so every field still
    /// reads correctly and only the signature disagrees.
    func withTamperedType() -> String {
        let parts = build().split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        let jwt = parts[0].split(separator: ".").map(String.init)
        guard let data = Data(base64URLEncoded: jwt[1]),
              var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var vc = payload["vc"] as? [String: Any] else { return build() }
        vc["type"] = ["VerifiableCredential", "00000000_something_else"]
        payload["vc"] = vc
        let edited = (try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        let rebuilt = "\(jwt[0]).\(edited.base64URLEncodedString()).\(jwt[2])"
        return ([rebuilt] + parts.dropFirst()).joined(separator: "~")
    }

    private func build(present: [Disclosure]? = nil,
                       signedBy: P256.Signing.PrivateKey? = nil,
                       jku: String = TWDIWFixture.jku,
                       algorithm: String = "ES256",
                       digestAlgorithm: String = "sha-256",
                       issuerDIDOverride: String? = nil,
                       omittingExpiry: Bool = false) -> String {
        let header: [String: Any] = [
            "jku": jku, "kid": "key-1", "typ": "vc+sd-jwt", "alg": algorithm,
        ]
        let holderJWK = JWKDIDKey.canonicalJWK(
            x: Data(holderKey.x963Representation.dropFirst().prefix(32)),
            y: Data(holderKey.x963Representation.suffix(32)))
        let payload: [String: Any] = [
            "iss": issuerDIDOverride ?? issuerDID,
            "sub": holderDID,
            "nbf": 1_759_823_761,
            "exp": 2_075_356_561,
            "cnf": ["jwk": (try? JSONSerialization.jsonObject(with: holderJWK)) as Any],
            "vc": [
                "@context": ["https://www.w3.org/2018/credentials/v1"],
                "type": ["VerifiableCredential", Self.credentialType],
                "credentialStatus": [
                    "type": "StatusList2021Entry",
                    "id": "\(Self.statusListURL)#35",
                    // A string, exactly as production sends it.
                    "statusListIndex": "35",
                    "statusListCredential": Self.statusListURL,
                    "statusPurpose": "revocation",
                ],
                "credentialSchema": ["id": Self.schemaURL, "type": "JsonSchema"],
                "credentialSubject": [
                    "_sd": disclosures.map(\.digest).sorted(),
                    "_sd_alg": digestAlgorithm,
                ],
            ],
        ]

        var finalPayload = payload
        if omittingExpiry { finalPayload.removeValue(forKey: "exp") }

        let encodedHeader = json(header).base64URLEncodedString()
        let encodedPayload = json(finalPayload).base64URLEncodedString()
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let key = signedBy ?? issuerPrivateKey
        let signature = (try? key.signature(for: signingInput))?.rawRepresentation ?? Data()

        let jwt = "\(encodedHeader).\(encodedPayload).\(signature.base64URLEncodedString())"
        let shown = (present ?? disclosures).map(\.encoded)
        // Trailing `~` with no key-binding JWT after it, as production emits.
        return ([jwt] + shown).joined(separator: "~") + "~"
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object,
                                     options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
