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
                    signedBy override: P256.Signing.PrivateKey? = nil) -> String {
        let header: [String: Any] = ["kid": "verifier-did", "typ": "oauth-authz-req+jwt", "alg": "ES256"]
        var constraintFields: [[String: Any]] = [
            ["path": ["$.type"], "filter": ["type": "array", "contains": ["const": credentialType]]],
        ]
        for f in fields { constraintFields.append(["path": ["$.credentialSubject.\(f)"]]) }
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
                    ["id": descriptorID, "constraints": ["fields": constraintFields]],
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

    @Test func theVPTokenSaysExactlyWhatM54Requires() throws {
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

        // The `redirect_uri:` prefix is literal.
        #expect(payload["aud"] as? String == "redirect_uri:" + Self.responseURI)
        #expect(payload["nonce"] as? String == "N-1")
        let vp = try #require(payload["vp"] as? [String: Any])
        // The typo is copied, and the spec-correct key is absent.
        #expect(vp["context"] != nil)
        #expect(vp["@context"] == nil)
        #expect((vp["type"] as? [String]) == ["VerifiablePresentation"])

        // The holder key really signed it.
        let headerData = try #require(Data(base64URLEncoded: parts[0]))
        let header = try #require(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        let kid = try #require(header["kid"] as? String)
        let holderPub = try JWKDIDKey.p256PublicKey(fromDID: kid)
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
