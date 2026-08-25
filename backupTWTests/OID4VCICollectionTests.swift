//
//  OID4VCICollectionTests.swift
//  backupTWTests
//
//  A QR code offered a credential. What may happen next, and in what order.
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

// MARK: - Offer parsing

@Suite("領卡連結說了什麼")
struct CredentialOfferTests {

    private func link(_ query: String) -> URL {
        URL(string: "openid-credential-offer://?\(query)")!
    }

    @Test func aByReferenceLinkCarriesItsFetchURL() throws {
        let parsed = try CredentialOfferLink.parse(
            link("credential_offer_uri=https%3A%2F%2Fissuer-sandbox.wallet.gov.tw%2Foffer"))
        #expect(parsed == .byReference(fetchURL: "https://issuer-sandbox.wallet.gov.tw/offer"))
    }

    @Test func aByValueLinkCarriesItsDocument() throws {
        let parsed = try CredentialOfferLink.parse(link("credential_offer=%7B%22a%22%3A1%7D"))
        #expect(parsed == .byValue(json: #"{"a":1}"#))
    }

    @Test func aLinkSayingBothIsNotArguedWith() {
        #expect(throws: CredentialOfferError.ambiguousOfferForm) {
            try CredentialOfferLink.parse(link("credential_offer=%7B%7D&credential_offer_uri=https%3A%2F%2Fa"))
        }
    }

    @Test func aLinkSayingNeitherIsNamed() {
        #expect(throws: CredentialOfferError.missingOfferForm) {
            try CredentialOfferLink.parse(link("unrelated=1"))
        }
    }

    @Test func anotherSchemeIsNotACredentialOffer() {
        #expect(throws: CredentialOfferError.notACredentialOffer) {
            try CredentialOfferLink.parse(URL(string: "https://bonds.tw/?credential_offer_uri=x")!)
        }
    }

    /// The official app's own scheme, measured off `demo.wallet.gov.tw`
    /// 2026-08-26. Understood but not registered — see `CredentialOfferLink`.
    @Test func theOfficialAppSchemeIsUnderstood() throws {
        let parsed = try CredentialOfferLink.parse(
            URL(string: "modadigitalwallet://credential_offer?credential_offer_uri=https%3A%2F%2Fissuer-oid4vci.wallet.gov.tw%2Fapi%2Fissuer%2F00000000%2Foffer")!)
        #expect(parsed == .byReference(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/offer"))
    }

    /// `modadigitalwallet://` with anything other than `credential_offer` in the
    /// host position is not one — the host word carries meaning in this scheme.
    @Test func theOfficialSchemeWithAWrongHostIsRefused() {
        #expect(throws: CredentialOfferError.notACredentialOffer) {
            try CredentialOfferLink.parse(
                URL(string: "modadigitalwallet://something_else?credential_offer_uri=x")!)
        }
    }

    private func offerJSON(issuer: String = "https://issuer-sandbox.wallet.gov.tw/api/issuer/00000000",
                           ids: String = #"["00000000_demo_drivinglicense_202504251418"]"#,
                           grants: String = #"{"urn:ietf:params:oauth:grant-type:pre-authorized_code":{"pre-authorized_code":"CODE-1"}}"#)
        -> Data {
        Data("""
        {"credential_issuer":"\(issuer)","credential_configuration_ids":\(ids),"grants":\(grants)}
        """.utf8)
    }

    @Test func aWellFormedOfferIsRead() throws {
        let offer = try CredentialOffer.parse(json: offerJSON())
        #expect(offer.credentialIssuer == "https://issuer-sandbox.wallet.gov.tw/api/issuer/00000000")
        #expect(offer.configurationIDs == ["00000000_demo_drivinglicense_202504251418"])
        #expect(offer.preAuthorizedCode == "CODE-1")
        #expect(!offer.requiresTransactionCode)
    }

    @Test func aTransactionCodeRequirementIsCarriedAsAFact() throws {
        let offer = try CredentialOffer.parse(json: offerJSON(
            grants: #"{"urn:ietf:params:oauth:grant-type:pre-authorized_code":{"pre-authorized_code":"CODE-1","tx_code":{"length":6}}}"#))
        #expect(offer.requiresTransactionCode)
    }

    @Test func anOfferWithoutAPreAuthorizedGrantIsNamedNotGenericallyRejected() {
        #expect(throws: CredentialOfferError.noPreAuthorizedGrant) {
            try CredentialOffer.parse(json: offerJSON(grants: #"{"authorization_code":{}}"#))
        }
    }

    @Test func anOfferWithoutAnIssuerIsRefused() {
        #expect(throws: CredentialOfferError.missingCredentialIssuer) {
            try CredentialOffer.parse(json: Data(#"{"credential_configuration_ids":["x"]}"#.utf8))
        }
    }

    @Test func anOfferOfferingNothingIsRefused() {
        #expect(throws: CredentialOfferError.missingConfigurationIDs) {
            try CredentialOffer.parse(json: offerJSON(ids: "[]"))
        }
    }
}

// MARK: - Stubbed transport

/// Routes requests by URL substring and records every exchange.
///
/// Static storage for the same reason as `TWFidOStubURLProtocol`: `URLProtocol`
/// offers no per-session hook to key a handler off, so the suite is serialised.
final class OID4VCIStubURLProtocol: URLProtocol {

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

    /// `URLProtocol` never sees `httpBody`; the bytes arrive as a stream.
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

// MARK: - Collection

@Suite("領卡的每一步都要先過閘門", .serialized)
struct OID4VCICollectionTests {

    // The trust list knows one host. Everything else is off the list.
    static let sandbox = TWDIWIssuer(
        did: "did:key:z2dmzD81…sandbox",
        displayName: "數位憑證皮夾沙盒",
        displayNameEnglish: "Sandbox",
        taxID: "00000000",
        issuerMetadataBaseURL: "https://issuer-sandbox.wallet.gov.tw",
        serviceBaseURL: nil,
        reportsOnChainAnchor: true)

    static let issuerIdentifier = "https://issuer-sandbox.wallet.gov.tw/api/issuer/00000000"
    static let configurationID = "00000000_demo_drivinglicense_202504251418"

    private let store: CredentialStore
    private let keyring: HolderKeyring

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oid4vci-tests-\(UUID().uuidString)")
        store = try CredentialStore(directory: directory)
        // Its own namespace per instance: the suite is serialised, but a key
        // left behind by a failing assertion must not leak into the next case.
        keyring = HolderKeyring(namespace: "tw.bonds.backupTW.tests.oid4vci\(UUID().uuidString.prefix(8)).",
                                legacyTags: [],
                                installID: "test",
                                legacyInstallRecord: nil)
    }

    private func makeCollector() -> OID4VCICollector {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OID4VCIStubURLProtocol.self]
        return OID4VCICollector(session: URLSession(configuration: configuration),
                                trustList: [Self.sandbox],
                                keyring: keyring,
                                store: store)
    }

    private func offerLink(fetchURL: String = "\(issuerIdentifier)/credential-offer-object") -> CredentialOfferLink {
        .byReference(fetchURL: fetchURL)
    }

    private static func offerBody(issuer: String = issuerIdentifier) -> Data {
        Data("""
        {"credential_issuer":"\(issuer)",
         "credential_configuration_ids":["\(configurationID)"],
         "grants":{"urn:ietf:params:oauth:grant-type:pre-authorized_code":
                   {"pre-authorized_code":"CODE-1"}}}
        """.utf8)
    }

    private func installHappyRoutesThroughToken(
        credential: @escaping (URLRequest, Data) -> Data = { _, _ in Data("{}".utf8) },
        credentialStatus: Int = 200) {
        OID4VCIStubURLProtocol.routes = [
            .init(match: "credential-offer-object", status: 200, body: { _, _ in Self.offerBody() }),
            .init(match: ".well-known/openid-credential-issuer", status: 200, body: { _, _ in
                Data(#"{"credential_endpoint":"\#(Self.issuerIdentifier)/credential"}"#.utf8)
            }),
            .init(match: "/token", status: 200, body: { _, _ in
                Data(#"{"access_token":"AT-1","c_nonce":"NONCE-1"}"#.utf8)
            }),
            .init(match: "/credential", status: credentialStatus, body: credential),
        ]
    }

    private func nonLegacyKeyCount() throws -> Int {
        try keyring.entries().filter { !$0.isLegacy }.count
    }

    // MARK: Gates

    @Test func aFetchURLOffTheListNeverLeavesTheDevice() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }

        await #expect(throws: OID4VCICollectionError.refused(
            .notOnTheTrustList(host: "issuer-sandbox.wallet.gov.tw.evil.tw"))) {
            _ = try await makeCollector().collect(from: offerLink(
                fetchURL: "https://issuer-sandbox.wallet.gov.tw.evil.tw/offer"))
        }
        #expect(OID4VCIStubURLProtocol.exchanges.isEmpty)
    }

    @Test func anInlineOfferOffTheListIsRefusedBeforeAnyRequest() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }

        let json = String(data: Self.offerBody(issuer: "https://evil.example/api/issuer/1"),
                          encoding: .utf8)!
        await #expect(throws: OID4VCICollectionError.refused(
            .notOnTheTrustList(host: "evil.example"))) {
            _ = try await makeCollector().collect(from: .byValue(json: json))
        }
        #expect(OID4VCIStubURLProtocol.exchanges.isEmpty)
    }

    @Test func anOfferNamingSomeoneElseStopsAfterTheFetch() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }
        OID4VCIStubURLProtocol.routes = [
            .init(match: "credential-offer-object", status: 200, body: { _, _ in
                Self.offerBody(issuer: "https://somewhere-else.example/api/issuer/2")
            }),
        ]

        await #expect(throws: OID4VCICollectionError.refused(.organisationMismatch)) {
            _ = try await makeCollector().collect(from: offerLink())
        }
        // The offer fetch is the only request that may have happened.
        #expect(OID4VCIStubURLProtocol.exchanges.count == 1)
    }

    // MARK: The measurement

    @Test func theTokenRequestStatesOurOwnNameNotTheOfficialApps() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }
        installHappyRoutesThroughToken(credentialStatus: 500)

        await #expect(throws: OID4VCICollectionError.badStatus(step: .credential, code: 500)) {
            _ = try await makeCollector().collect(from: offerLink())
        }

        let token = try #require(OID4VCIStubURLProtocol.exchanges.first {
            $0.url.absoluteString.hasSuffix("/token")
        })
        let form = String(data: token.body, encoding: .utf8) ?? ""
        #expect(form.contains("client_id=tw.bonds.backupTW"))
        #expect(!form.contains("moda_dw"))
        #expect(form.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Apre-authorized_code"))
        #expect(form.contains("pre-authorized_code=CODE-1"))
    }

    @Test func theProofSaysWhatThePlanSaysItMustSay() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }
        installHappyRoutesThroughToken(credentialStatus: 500)

        _ = try? await makeCollector().collect(from: offerLink())

        let request = try #require(OID4VCIStubURLProtocol.exchanges.first {
            $0.url.absoluteString.hasSuffix("/credential")
        })
        #expect(request.headers["Authorization"] == "Bearer AT-1")

        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["credential_identifier"] as? String == Self.configurationID)
        let proofs = try #require(body["proofs"] as? [String: Any])
        let jwt = try #require((proofs["jwt"] as? [String])?.first)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let headerData = try #require(Data(base64URLEncoded: parts[0]))
        let header = try #require(try JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        #expect(header["typ"] as? String == "openid4vci-proof+jwt")
        #expect(header["alg"] as? String == "ES256")
        let kid = try #require(header["kid"] as? String)
        // The TWDIW spelling, not this app's own: the issuer strips a
        // hardcoded 0xEB51 prefix, so a `p256-pub` DID would parse as junk.
        #expect(throws: Never.self) { _ = try JWKDIDKey.p256PublicKey(fromDID: kid) }

        let payloadData = try #require(Data(base64URLEncoded: parts[1]))
        let payload = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        #expect(payload["iss"] as? String == "tw.bonds.backupTW")
        // Trailing slash measured off the deployment; without it the proof
        // is refused (docs/twdiw-integration-plan.md §三 M5.2 step 4).
        #expect(payload["aud"] as? String == Self.issuerIdentifier + "/")
        #expect(payload["nonce"] as? String == "NONCE-1")
    }

    // MARK: Keys

    @Test func aFailedCollectionLeavesNoKeyBehind() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }
        installHappyRoutesThroughToken(credentialStatus: 500)

        _ = try? await makeCollector().collect(from: offerLink())
        #expect(try nonLegacyKeyCount() == 0)
    }

    @Test func aCredentialBoundToSomeoneElsesKeyIsRefusedAndTheKeyRemoved() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }
        // A perfectly valid credential — bound to the fixture's holder,
        // who is not the key this collection created.
        let strangers = TWDIWFixture().serialized
        installHappyRoutesThroughToken(credential: { _, _ in
            Data(#"{"credential":"\#(strangers)"}"#.utf8)
        })

        await #expect(throws: OID4VCICollectionError.credentialNotBoundToOurKey) {
            _ = try await makeCollector().collect(from: offerLink())
        }
        #expect(try nonLegacyKeyCount() == 0)
        #expect(try store.allIDs().isEmpty)
    }

    // MARK: The gate M5.2 exists to pass

    @Test func aCollectedCardLandsInTheStoreBoundToItsOwnFreshKey() async throws {
        OID4VCIStubURLProtocol.reset()
        defer { OID4VCIStubURLProtocol.reset() }
        let issuer = TestIssuer()
        installHappyRoutesThroughToken(credential: { _, body in
            // Mint for whichever key the wallet proved possession of —
            // exactly what the real issuer does with `cnf.jwk`.
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let proofs = json["proofs"] as? [String: Any],
                  let jwt = (proofs["jwt"] as? [String])?.first,
                  let kid = TestIssuer.kid(ofProof: jwt) else { return Data() }
            // Wrapped the way the deployment answers: a JSON envelope, not
            // bare SD-JWT bytes.
            return Data(#"{"credential":"\#(issuer.mint(boundTo: kid))"}"#.utf8)
        })

        let receipt = try await makeCollector().collect(from: offerLink())

        #expect(receipt.storedID == Self.configurationID)
        #expect(receipt.acceptedClientID == "tw.bonds.backupTW")
        let stored = try #require(try store.load(id: Self.configurationID))
        #expect(StoredCardSource.source(of: stored) == .twdiw)
        // Exactly one key was created, and the stored card names it.
        #expect(try nonLegacyKeyCount() == 1)
        let entry = try #require(try keyring.entries().first { !$0.isLegacy })
        _ = try #require(try? keyring.key(matchingPublicKeyX963: entry.publicKeyX963))
    }
}

// MARK: - A test issuer

/// Mints TWDIW-shaped credentials for whatever holder key a proof named.
///
/// `TWDIWFixture` owns the shape of a credential; this type exists for the one
/// thing the fixture deliberately cannot do — bind to a key that did not exist
/// until the collection under test created it.
private struct TestIssuer {

    let privateKey = P256.Signing.PrivateKey()

    static func kid(ofProof jwt: String) -> String? {
        let parts = jwt.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let data = Data(base64URLEncoded: parts[0]),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return header["kid"] as? String
    }

    func mint(boundTo holderDID: String) -> String {
        guard let holderKey = try? JWKDIDKey.p256PublicKey(fromDID: holderDID) else { return "" }
        let issuerDID = (try? JWKDIDKey.did(
            fromP256PublicKeyX963: privateKey.publicKey.x963Representation)) ?? ""
        let x963 = holderKey.x963Representation
        let holderJWK = JWKDIDKey.canonicalJWK(x: Data(x963.dropFirst().prefix(32)),
                                               y: Data(x963.suffix(32)))
        let disclosures = [
            Disclosure(claimName: "name", claimValue: "陳筱玲"),
            Disclosure(claimName: "id_number", claimValue: "A234567890"),
        ]
        let header: [String: Any] = [
            "jku": "https://issuer-vc.wallet.gov.tw/api/keys",
            "kid": "key-1", "typ": "vc+sd-jwt", "alg": "ES256",
        ]
        let payload: [String: Any] = [
            "iss": issuerDID,
            "sub": holderDID,
            "nbf": 1_759_823_761,
            "exp": 2_075_356_561,
            "cnf": ["jwk": (try? JSONSerialization.jsonObject(with: holderJWK)) as Any],
            "vc": [
                "@context": ["https://www.w3.org/2018/credentials/v1"],
                "type": ["VerifiableCredential", OID4VCICollectionTests.configurationID],
                "credentialSubject": [
                    "_sd": disclosures.map(\.digest).sorted(),
                    "_sd_alg": "sha-256",
                ],
            ],
        ]
        let encodedHeader = json(header).base64URLEncodedString()
        let encodedPayload = json(payload).base64URLEncodedString()
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = (try? privateKey.signature(for: signingInput))?.rawRepresentation ?? Data()
        let jwt = "\(encodedHeader).\(encodedPayload).\(signature.base64URLEncodedString())"
        return ([jwt] + disclosures.map(\.encoded)).joined(separator: "~") + "~"
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object,
                                     options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
