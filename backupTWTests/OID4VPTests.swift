//
//  OID4VPTests.swift
//  backupTWTests
//
//  A verifier asked for a presentation. What the wallet signs back, and what
//  it refuses to.
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

// MARK: - Fixtures

/// A verifier that signs request objects the way `demo.wallet.gov.tw` does
/// (measured 2026-08-26): header `oauth-authz-req+jwt`, `client_id` a did:key,
/// signed with the key that DID carries.
private struct TestVerifier {
    let privateKey = P256.Signing.PrivateKey()

    var clientID: String {
        (try? JWKDIDKey.did(fromP256PublicKeyX963: privateKey.publicKey.x963Representation)) ?? ""
    }

    func requestJWT(responseURI: String,
                    nonce: String,
                    state: String,
                    definitionID: String,
                    descriptorID: String,
                    credentialType: String,
                    fields: [String],
                    credentialFormat: String? = nil,
                    signedBy override: P256.Signing.PrivateKey? = nil) -> String {
        let header: [String: Any] = ["kid": "verifier-did", "typ": "oauth-authz-req+jwt", "alg": "ES256"]
        var constraintFields: [[String: Any]] = [
            ["path": ["$.type"], "filter": ["type": "array", "contains": ["const": credentialType]]],
        ]
        for f in fields { constraintFields.append(["path": ["$.credentialSubject.\(f)"]]) }
        var descriptor: [String: Any] = [
            "id": descriptorID,
            "constraints": ["fields": constraintFields],
        ]
        if let credentialFormat {
            descriptor["format"] = [credentialFormat: ["alg": ["RS256", "ES256"]]]
        }
        let payload: [String: Any] = [
            "response_type": "vp_token",
            "response_mode": "direct_post",
            "response_uri": responseURI,
            "client_id": clientID,
            "nonce": nonce,
            "state": state,
            "presentation_definition": [
                "id": definitionID,
                "input_descriptors": [
                    descriptor,
                ],
            ],
        ]
        let h = json(header).base64URLEncodedString()
        let p = json(payload).base64URLEncodedString()
        let signingInput = Data("\(h).\(p)".utf8)
        let key = override ?? privateKey
        let sig = (try? key.signature(for: signingInput))?.rawRepresentation ?? Data()
        return "\(h).\(p).\(sig.base64URLEncodedString())"
    }

    /// The shape used by the production convenience-store request: two `pick`
    /// groups, each offering carrier-specific descriptors.
    func groupedRequestJWT(responseURI: String,
                           nonce: String,
                           state: String,
                           definitionID: String,
                           credentialType: String) -> String {
        func descriptor(id: String, type: String, field: String, group: String) -> [String: Any] {
            [
                "id": id,
                "group": [group],
                "constraints": ["fields": [
                    ["path": ["$.type"],
                     "filter": ["type": "array", "contains": ["const": type]]],
                    ["path": ["$.credentialSubject.\(field)"]],
                ]],
            ]
        }
        let definition: [String: Any] = [
            "id": definitionID,
            "submission_requirements": [
                ["name": "姓名", "rule": "pick", "from": "Group_1", "max": 1],
                ["name": "末五碼", "rule": "pick", "from": "Group_2", "max": 1],
            ],
            "input_descriptors": [
                descriptor(id: "other-name", type: "other-carrier", field: "name", group: "Group_1"),
                descriptor(id: "twm-name", type: credentialType, field: "name", group: "Group_1"),
                descriptor(id: "other-last5", type: "other-carrier", field: "phonel5", group: "Group_2"),
                descriptor(id: "twm-last5", type: credentialType, field: "phonel5", group: "Group_2"),
            ],
        ]
        let header: [String: Any] = ["kid": "verifier-did", "typ": "oauth-authz-req+jwt", "alg": "ES256"]
        let payload: [String: Any] = [
            "response_type": "vp_token",
            "response_mode": "direct_post",
            "response_uri": responseURI,
            "client_id": clientID,
            "nonce": nonce,
            "state": state,
            "presentation_definition": definition,
        ]
        let h = json(header).base64URLEncodedString()
        let p = json(payload).base64URLEncodedString()
        let signature = (try? privateKey.signature(for: Data("\(h).\(p)".utf8)))?.rawRepresentation ?? Data()
        return "\(h).\(p).\(signature.base64URLEncodedString())"
    }

    private func json(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

/// Mints a TWDIW card bound to a given holder DID — the one thing `TWDIWFixture`
/// cannot do, because M5.4's presenting key is a `HolderKeyring` key created for
/// the card, not a fixture's own.
private func mintCard(boundTo holderDID: String, type: String, claims: [(String, String)]) -> String {
    guard let holderKey = try? JWKDIDKey.p256PublicKey(fromDID: holderDID) else { return "" }
    let issuer = P256.Signing.PrivateKey()
    let issuerDID = (try? JWKDIDKey.did(fromP256PublicKeyX963: issuer.publicKey.x963Representation)) ?? ""
    let x963 = holderKey.x963Representation
    let holderJWK = JWKDIDKey.canonicalJWK(x: Data(x963.dropFirst().prefix(32)), y: Data(x963.suffix(32)))
    let disclosures = claims.map { Disclosure(claimName: $0.0, claimValue: $0.1) }
    let header: [String: Any] = ["jku": "https://issuer-vc.wallet.gov.tw/api/keys",
                                 "kid": "key-1", "typ": "vc+sd-jwt", "alg": "ES256"]
    let payload: [String: Any] = [
        "iss": issuerDID, "sub": holderDID, "nbf": 1_759_823_761, "exp": 2_075_356_561,
        "cnf": ["jwk": (try? JSONSerialization.jsonObject(with: holderJWK)) as Any],
        "vc": [
            "@context": ["https://www.w3.org/2018/credentials/v1"],
            "type": ["VerifiableCredential", type],
            "credentialSubject": ["_sd": disclosures.map(\.digest).sorted(), "_sd_alg": "sha-256"],
        ],
    ]
    func j(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
    let h = j(header).base64URLEncodedString()
    let p = j(payload).base64URLEncodedString()
    let sig = (try? issuer.signature(for: Data("\(h).\(p)".utf8)))?.rawRepresentation ?? Data()
    let jwt = "\(h).\(p).\(sig.base64URLEncodedString())"
    return ([jwt] + disclosures.map(\.encoded)).joined(separator: "~") + "~"
}

// MARK: - Request

@Suite("查驗方要什麼、有沒有真的簽")
struct OID4VPRequestTests {

    static let trustedHost: Set<String> = ["verifier-oid4vp.wallet.gov.tw"]
    static let responseURI = "https://verifier-oid4vp.wallet.gov.tw/api/oidvp/authorization-response"

    private func makeRequest(_ verifier: TestVerifier,
                             signedBy override: P256.Signing.PrivateKey? = nil,
                             responseURI: String = responseURI) -> String {
        verifier.requestJWT(responseURI: responseURI, nonce: "NONCE-1", state: "STATE-1",
                            definitionID: "00000000_vpms_20250605",
                            descriptorID: "00000000_vpms_20250605",
                            credentialType: "00000000_vpms_20250605",
                            fields: ["name", "company"], signedBy: override)
    }

    @Test func aVerifiedRequestReducesToWhatWasAsked() throws {
        let verifier = TestVerifier()
        let request = try OID4VPRequest.verify(compactJWS: makeRequest(verifier),
                                               clientID: verifier.clientID,
                                               trustedResponseHosts: Self.trustedHost)
        #expect(request.nonce == "NONCE-1")
        #expect(request.state == "STATE-1")
        #expect(request.credentialType == "00000000_vpms_20250605")
        #expect(request.responseURI == Self.responseURI)
        #expect(Set(request.requestedFields.compactMap(\.claimName)) == ["name", "company"])
    }

    @Test func aSelfIssuedRequestKeepsItsMoicaFormatBoundary() throws {
        let verifier = TestVerifier()
        let jwt = verifier.requestJWT(
            responseURI: Self.responseURI,
            nonce: "N-MOICA",
            state: "S-MOICA",
            definitionID: "bonds-vp",
            descriptorID: "cred",
            credentialType: VerifiableCredential.nationalIDType,
            fields: ["name", "birthdate"],
            credentialFormat: OID4VPCredentialFormat.moica.rawValue)
        let request = try OID4VPRequest.verify(compactJWS: jwt,
                                               clientID: verifier.clientID,
                                               trustedResponseHosts: Self.trustedHost)
        #expect(request.inputDescriptors.first?.credentialFormat == .moica)
        #expect(request.credentialType == VerifiableCredential.nationalIDType)
    }

    @Test func groupedCarrierAlternativesKeepTheirDescriptorBoundaries() throws {
        let verifier = TestVerifier()
        let jwt = verifier.groupedRequestJWT(responseURI: Self.responseURI,
                                             nonce: "N", state: "S",
                                             definitionID: "22555003_711pickup",
                                             credentialType: "twm-card")
        let request = try OID4VPRequest.verify(compactJWS: jwt,
                                               clientID: verifier.clientID,
                                               trustedResponseHosts: Self.trustedHost)

        #expect(request.inputDescriptors.map(\.id) == [
            "other-name", "twm-name", "other-last5", "twm-last5",
        ])
        #expect(request.submissionRequirements.map(\.from) == ["Group_1", "Group_2"])
        #expect(request.submissionRequirements.map(\.max) == [1, 1])
        #expect(request.requestedFields.compactMap(\.claimName) == ["name", "phonel5"])
    }

    @Test func aRequestSignedByAnotherKeyIsRefused() {
        let verifier = TestVerifier()
        // client_id names `verifier`, but a stranger actually signed it.
        let forged = makeRequest(verifier, signedBy: P256.Signing.PrivateKey())
        #expect(throws: OID4VPRequestError.signatureInvalid) {
            _ = try OID4VPRequest.verify(compactJWS: forged, clientID: verifier.clientID,
                                         trustedResponseHosts: Self.trustedHost)
        }
    }

    @Test func aResponseURIOffTheTrustedHostsIsRefused() {
        let verifier = TestVerifier()
        let evil = makeRequest(verifier,
                               responseURI: "https://verifier-oid4vp.wallet.gov.tw.evil.tw/api/oidvp/authorization-response")
        #expect(throws: OID4VPRequestError.responseURINotTrusted(host: "verifier-oid4vp.wallet.gov.tw.evil.tw")) {
            _ = try OID4VPRequest.verify(compactJWS: evil, clientID: verifier.clientID,
                                         trustedResponseHosts: Self.trustedHost)
        }
    }

    @Test func theOfficialAuthorizeSchemeIsParsed() throws {
        let link = try OID4VPAuthorizeLink.parse(
            URL(string: "modadigitalwallet://authorize?client_id=did:key:zABC&request_uri=https%3A%2F%2Fverifier-oid4vp.wallet.gov.tw%2Fapi%2Foidvp%2Frequest%2Fx")!)
        #expect(link == .byReference(clientID: "did:key:zABC",
                                     requestURI: "https://verifier-oid4vp.wallet.gov.tw/api/oidvp/request/x"))
    }
}

// MARK: - Request fetch

@Suite("抓 request_uri:閘門先過、簽章要驗", .serialized)
struct OID4VPRequestFetcherTests {

    static let trusted: Set<String> = ["verifier-oid4vp.wallet.gov.tw"]
    static let requestURI = "https://verifier-oid4vp.wallet.gov.tw/api/oidvp/request/abc"
    static let responseURI = "https://verifier-oid4vp.wallet.gov.tw/api/oidvp/authorization-response"

    private func makeFetcher() -> OID4VPRequestFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OID4VPFetchStubURLProtocol.self]
        return OID4VPRequestFetcher(session: URLSession(configuration: config), trustedHosts: Self.trusted)
    }

    private func requestObject(_ verifier: TestVerifier) -> String {
        verifier.requestJWT(responseURI: Self.responseURI, nonce: "N", state: "S",
                            definitionID: "D", descriptorID: "D",
                            credentialType: "D", fields: ["name"])
    }

    @Test func aTrustedRequestURIIsFetchedAndVerified() async throws {
        OID4VPFetchStubURLProtocol.reset()
        defer { OID4VPFetchStubURLProtocol.reset() }
        let verifier = TestVerifier()
        let jws = requestObject(verifier)
        OID4VPFetchStubURLProtocol.routes = [
            .init(match: "/api/oidvp/request/", status: 200, body: { _, _ in Data(jws.utf8) }),
        ]
        let request = try await makeFetcher().fetch(
            .byReference(clientID: verifier.clientID, requestURI: Self.requestURI))
        #expect(request.nonce == "N")
        #expect(request.responseURI == Self.responseURI)
    }

    @Test func anUntrustedRequestURINeverLeavesTheDevice() async {
        OID4VPFetchStubURLProtocol.reset()
        defer { OID4VPFetchStubURLProtocol.reset() }
        let verifier = TestVerifier()
        await #expect(throws: OID4VPRequestError.requestURINotTrusted(
            host: "verifier-oid4vp.wallet.gov.tw.evil.tw")) {
            _ = try await makeFetcher().fetch(.byReference(
                clientID: verifier.clientID,
                requestURI: "https://verifier-oid4vp.wallet.gov.tw.evil.tw/api/oidvp/request/abc"))
        }
        #expect(OID4VPFetchStubURLProtocol.exchanges.isEmpty)
    }

    @Test func aBadStatusOnTheFetchIsSurfaced() async {
        OID4VPFetchStubURLProtocol.reset()
        defer { OID4VPFetchStubURLProtocol.reset() }
        OID4VPFetchStubURLProtocol.routes = [
            .init(match: "/api/oidvp/request/", status: 404, body: { _, _ in Data() }),
        ]
        await #expect(throws: OID4VPRequestError.badStatus(404)) {
            _ = try await makeFetcher().fetch(.byReference(
                clientID: TestVerifier().clientID, requestURI: Self.requestURI))
        }
    }

    @Test func anInlineRequestObjectSkipsTheFetchButStillVerifies() async throws {
        OID4VPFetchStubURLProtocol.reset()
        defer { OID4VPFetchStubURLProtocol.reset() }
        let verifier = TestVerifier()
        let request = try await makeFetcher().fetch(
            .byValue(clientID: verifier.clientID, requestObject: requestObject(verifier)))
        #expect(request.state == "S")
        #expect(OID4VPFetchStubURLProtocol.exchanges.isEmpty)
    }
}

// MARK: - Response

@Suite("出示的 vp_token 說了該說的、只揭露選的", .serialized)
struct OID4VPResponseTests {

    static let responseURI = "https://verifier-oid4vp.wallet.gov.tw/api/oidvp/authorization-response"
    static let cardType = "00000000_vpms_20250605"

    private let store: CredentialStore
    private let keyring: HolderKeyring

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oid4vp-\(UUID().uuidString)")
        store = try CredentialStore(directory: dir)
        keyring = HolderKeyring(namespace: "tw.bonds.backupTW.tests.oid4vp\(UUID().uuidString.prefix(8)).",
                                legacyTags: [], installID: "test", legacyInstallRecord: nil)
    }

    /// Mints a card bound to a fresh keyring key and stores it, returning the
    /// request the verifier would have sent for it.
    private func seedCardAndRequest(fields: [String] = ["name", "company"]) throws -> OID4VPRequest {
        let key = try keyring.newKey()
        let holderDID = try JWKDIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let card = mintCard(boundTo: holderDID, type: Self.cardType,
                            claims: [("name", "王小明"), ("company", "有備而來"), ("email", "a@b.tw")])
        try store.save(jws: card, id: Self.cardType)
        let verifier = TestVerifier()
        let jwt = verifier.requestJWT(responseURI: Self.responseURI, nonce: "N-1", state: "S-1",
                                      definitionID: Self.cardType, descriptorID: Self.cardType,
                                      credentialType: Self.cardType, fields: fields)
        return try OID4VPRequest.verify(compactJWS: jwt, clientID: verifier.clientID,
                                        trustedResponseHosts: ["verifier-oid4vp.wallet.gov.tw"])
    }

    private func seedGroupedTelecomCardAndRequest() throws -> OID4VPRequest {
        let key = try keyring.newKey()
        let holderDID = try JWKDIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let card = mintCard(boundTo: holderDID, type: Self.cardType,
                            claims: [("name", "王小明"), ("phonel5", "12345")])
        try store.save(jws: card, id: Self.cardType)
        let verifier = TestVerifier()
        let jwt = verifier.groupedRequestJWT(responseURI: Self.responseURI,
                                             nonce: "N-GROUP", state: "S-GROUP",
                                             definitionID: "22555003_711pickup",
                                             credentialType: Self.cardType)
        return try OID4VPRequest.verify(compactJWS: jwt,
                                        clientID: verifier.clientID,
                                        trustedResponseHosts: ["verifier-oid4vp.wallet.gov.tw"])
    }

    private func seedSelfIssuedCardAndRequest() throws -> OID4VPRequest {
        let key = try keyring.newKey()
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                    unifiedNo: "A123456789",
                                    name: "王小明",
                                    birthdate: "民國 083年03月06日",
                                    addressOfHousehold: "臺北市測試路一號")
        let (credential, disclosures) = VerifiableCredential.selectivelyDisclosableNationalID(
            model, issuerDID: did, validFrom: Date(timeIntervalSince1970: 1_786_000_000))
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential)
        let envelope = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: try cardSignature(over: Data(tbs.utf8)).base64EncodedString()),
            issuerJWS: try credential.jwsCompactSerialization(signedBy: key, issuerDID: did),
            disclosures: disclosures.map(\.encoded))
        try store.save(jws: try envelope.serialized(), id: StoredNationalID.credentialID)

        let verifier = TestVerifier()
        let jwt = verifier.requestJWT(
            responseURI: Self.responseURI,
            nonce: "N-SELF",
            state: "S-SELF",
            definitionID: "bonds-vp",
            descriptorID: "cred",
            credentialType: VerifiableCredential.nationalIDType,
            fields: ["name", "birthdate"],
            credentialFormat: OID4VPCredentialFormat.moica.rawValue)
        return try OID4VPRequest.verify(compactJWS: jwt,
                                        clientID: verifier.clientID,
                                        trustedResponseHosts: ["verifier-oid4vp.wallet.gov.tw"])
    }

    private func makeResponder() -> OID4VPResponder {
        let config = URLSessionConfiguration.ephemeral
        // Its own stub class, not the collection suite's: URLProtocol keeps its
        // routes in static storage, and Swift Testing runs suites concurrently,
        // so sharing one class lets two suites clear each other's routes
        // mid-flight. A separate class is the isolation.
        config.protocolClasses = [OID4VPStubURLProtocol.self]
        return OID4VPResponder(session: URLSession(configuration: config), store: store, keyring: keyring)
    }

    @Test func onlyChosenClaimsSurviveReserialisation() throws {
        let request = try seedCardAndRequest()
        let responder = makeResponder()
        let (credential, presented) = try responder.matchAndDisclose(request, chosenClaims: ["name"])
        // The full card carries three disclosures; the presented form carries
        // one, and it is the chosen one.
        #expect(credential.disclosedClaims.count == 3)
        let presentedCard = try TWDIWCredentialReader.read(presented)
        #expect(presentedCard.disclosedClaims.map(\.name) == ["name"])
        // Same issuer signature — selective disclosure removed a segment, not
        // re-signed anything.
        #expect(presentedCard.serialized.hasPrefix(String(credential.serialized.prefix(while: { $0 != "~" }))))
    }

    @Test func groupedPickupUsesTheHeldCarrierDescriptorInEachGroup() throws {
        let request = try seedGroupedTelecomCardAndRequest()
        let (_, presentations) = try makeResponder().presentationMaterial(
            request, chosenClaims: ["name", "phonel5"])

        #expect(presentations.map(\.descriptorID) == ["twm-name", "twm-last5"])
        #expect(try TWDIWCredentialReader.read(presentations[0].serialized)
            .disclosedClaims.map(\.name) == ["name"])
        #expect(try TWDIWCredentialReader.read(presentations[1].serialized)
            .disclosedClaims.map(\.name) == ["phonel5"])

        let submission = makeResponder().presentationSubmission(
            for: request, descriptorIDs: presentations.map(\.descriptorID))
        let map = try #require(submission["descriptor_map"] as? [[String: Any]])
        #expect(map.count == 2)
        #expect((map[0]["path_nested"] as? [String: Any])?["path"] as? String
                == "$.vp.verifiableCredential[0]")
        #expect((map[1]["path_nested"] as? [String: Any])?["path"] as? String
                == "$.vp.verifiableCredential[1]")
    }

    @Test func theVPTokenMatchesTheOfficialBuilder() throws {
        let request = try seedCardAndRequest()
        let responder = makeResponder()
        let key = try keyring.entries().first { !$0.isLegacy }
            .flatMap { try? DeviceKey.load(tag: $0.tag, installRecord: nil) } ?? nil
        let holderKey = try #require(key)
        let stored = try #require(try store.load(id: Self.cardType))
        let presented = OID4VPResponder.reserialise(
            try TWDIWCredentialReader.read(stored), disclosing: ["name"])
        let token = try responder.buildVPToken(request: request, presented: presented, holderKey: holderKey)

        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let payloadData = try #require(Data(base64URLEncoded: parts[1]))
        let payload = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])

        // aud is the verifier's client_id verbatim — a did:key, no prefix.
        #expect(payload["aud"] as? String == request.clientID)
        #expect((payload["aud"] as? String)?.hasPrefix("redirect_uri:") == false)
        #expect(payload["nonce"] as? String == "N-1")
        let holderDID = try JWKDIDKey.did(fromP256PublicKeyX963: holderKey.publicKeyX963)
        #expect(payload["sub"] as? String == holderDID)
        #expect(payload["iss"] as? String == holderDID)
        #expect(payload["nbf"] != nil)
        #expect(payload["exp"] != nil)
        #expect((payload["jti"] as? String)?.isEmpty == false)

        let vp = try #require(payload["vp"] as? [String: Any])
        // The key spelling is `context` (not `@context`), the value the v1 URL.
        #expect((vp["context"] as? [String]) == ["https://www.w3.org/2018/credentials/v1"])
        #expect(vp["@context"] == nil)
        #expect((vp["type"] as? [String]) == ["VerifiablePresentation"])

        // The key rides in the header as a JWK, not a kid, and it really signed.
        let headerData = try #require(Data(base64URLEncoded: parts[0]))
        let header = try #require(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        #expect(header["kid"] == nil)
        let jwk = try #require(header["jwk"] as? [String: Any])
        #expect(jwk["crv"] as? String == "P-256")
        #expect(jwk["kty"] as? String == "EC")
        let holderPub = try P256.Signing.PublicKey(x963Representation: holderKey.publicKeyX963)
        let sigData = try #require(Data(base64URLEncoded: parts[2]))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
        #expect(holderPub.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func aClaimTheCardDoesNotCarryIsNamedNotSilentlyDropped() throws {
        let request = try seedCardAndRequest(fields: ["name"])
        let responder = makeResponder()
        #expect(throws: OID4VPResponseError.requestedClaimNotAvailable("id_number")) {
            _ = try responder.matchAndDisclose(request, chosenClaims: ["id_number"])
        }
    }

    /// The submission matches the official app's own builder
    /// (`moda-gov-tw/TWDIW-official-app`, `openid_vc_vp.dart`): `jwt_vp` at the
    /// root, and a `path_nested` that **repeats the id** and names the credential
    /// `jwt_vc`. The verifier's schema requires the nested id (its own check reads
    /// "descriptor_map id is not the same for each level of nesting"); the two
    /// earlier forms — flat `vc+sd-jwt`, and a nested form missing the id — were
    /// both refused with code 2012 (device 2026-08-27).
    @Test func theSubmissionMatchesTheOfficialBuilder() throws {
        let request = try seedCardAndRequest()
        let submission = makeResponder().presentationSubmission(for: request)
        let map = try #require(submission["descriptor_map"] as? [[String: Any]])
        let descriptor = try #require(map.first)
        let id = try #require(descriptor["id"] as? String)
        #expect(descriptor["format"] as? String == "jwt_vp")
        #expect(descriptor["path"] as? String == "$")
        let nested = try #require(descriptor["path_nested"] as? [String: Any])
        #expect(nested["id"] as? String == id)          // same id at the nested level
        #expect(nested["format"] as? String == "jwt_vc")
        #expect(nested["path"] as? String == "$.vp.verifiableCredential[0]")
        #expect(submission["definition_id"] as? String == Self.cardType)
    }

    @Test func aFullResponsePostsTheTokenBack() async throws {
        OID4VPStubURLProtocol.reset()
        defer { OID4VPStubURLProtocol.reset() }
        OID4VPStubURLProtocol.routes = [
            .init(match: "authorization-response", status: 200, body: { _, _ in Data("{}".utf8) }),
        ]
        let request = try seedCardAndRequest()
        let status = try await makeResponder().respond(to: request, disclosing: ["name", "company"])
        #expect(status == 200)

        let exchange = try #require(OID4VPStubURLProtocol.exchanges.last)
        let form = String(data: exchange.body, encoding: .utf8) ?? ""
        #expect(form.contains("vp_token="))
        #expect(form.contains("presentation_submission="))
        #expect(form.contains("state=S-1"))
    }

    @Test func aSelfIssuedResponseUsesTheMoicaFormatAndOnlyChosenDisclosure() async throws {
        OID4VPStubURLProtocol.reset()
        defer { OID4VPStubURLProtocol.reset() }
        OID4VPStubURLProtocol.routes = [
            .init(match: "authorization-response", status: 200, body: { _, _ in Data("{}".utf8) }),
        ]
        let request = try seedSelfIssuedCardAndRequest()
        _ = try await makeResponder().respond(to: request, disclosing: ["birthdate"])

        let exchange = try #require(OID4VPStubURLProtocol.exchanges.last)
        let body = String(decoding: exchange.body, as: UTF8.self)
        let components = URLComponents(string: "https://test.invalid/?" + body)
        let vpToken = try #require(components?.queryItems?.first(where: { $0.name == "vp_token" })?.value)
        let submission = try #require(components?.queryItems?.first(where: {
            $0.name == "presentation_submission"
        })?.value)
        #expect(submission.contains("vc+moica"))

        let segments = vpToken.split(separator: ".").map(String.init)
        let payloadData = try #require(Data(base64URLEncoded: segments[1]))
        let payload = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        let vp = try #require(payload["vp"] as? [String: Any])
        let presented = try #require((vp["verifiableCredential"] as? [String])?.first)
        let envelope = try MOICASignedCredential.parse(presented)
        #expect(envelope.issuerJWS != nil)
        #expect(envelope.disclosures.compactMap { Disclosure(encoded: $0)?.claimName } == ["birthdate"])
    }
}

// MARK: - Stub transport (isolated from the collection suite)

/// The OID4VP suite's own routing stub. A near-copy of
/// `OID4VCIStubURLProtocol`, deliberately a separate class so the two suites'
/// static route tables cannot clear each other when Swift Testing runs them
/// concurrently.
final class OID4VPStubURLProtocol: URLProtocol {

    struct Route {
        let match: String
        let status: Int
        let body: (URLRequest, Data) -> Data
    }

    struct Exchange {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var routes: [Route] = []
    nonisolated(unsafe) static var exchanges: [Exchange] = []

    static func reset() {
        routes = []
        exchanges = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.drainBody(of: request)
        let url = request.url!
        Self.exchanges.append(Exchange(url: url,
                                       method: request.httpMethod ?? "GET",
                                       headers: request.allHTTPHeaderFields ?? [:],
                                       body: body))
        guard let route = Self.routes.first(where: { url.absoluteString.contains($0.match) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body(request, body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drainBody(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Fetch stub transport (isolated from the response suite)

/// The fetcher suite's own routing stub. Separate class from
/// `OID4VPStubURLProtocol` for the same reason that one is separate from
/// `OID4VCIStubURLProtocol`: Swift Testing runs the fetcher and response
/// suites concurrently, and one shared static route table would let them clear
/// each other mid-run — which is exactly the `network` failure this reproduced
/// on CI while passing locally.
final class OID4VPFetchStubURLProtocol: URLProtocol {

    struct Route {
        let match: String
        let status: Int
        let body: (URLRequest, Data) -> Data
    }

    struct Exchange {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var routes: [Route] = []
    nonisolated(unsafe) static var exchanges: [Exchange] = []

    static func reset() {
        routes = []
        exchanges = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.drainBody(of: request)
        let url = request.url!
        Self.exchanges.append(Exchange(url: url,
                                       method: request.httpMethod ?? "GET",
                                       headers: request.allHTTPHeaderFields ?? [:],
                                       body: body))
        guard let route = Self.routes.first(where: { url.absoluteString.contains($0.match) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body(request, body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drainBody(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
