//
//  TelecomCardCatalogTests.swift
//  backupTWTests
//
//  The 「申請新卡」 catalogue, filtered to the telecom 門號電子卡 — the JSON it reads,
//  the URL it builds, and the scheme the returned offer will arrive under. Never
//  over the wire for the parse; a stub, never a socket, for the fetch.
//

import Foundation
import Testing
@testable import backupTW

/// A representative `apply/vcList` body: the three carrier 門號電子卡 (all
/// `type == 1`), one non-telecom card that must be filtered out by name, and one
/// telecom-named card with a null `issuerServiceUrl` that must be dropped because
/// it cannot start an application. The `vcUid`/`issuerServiceUrl` values are the
/// ones measured off the live directory on 2026-08-28.
private let sampleVCList = Data("""
{
  "code": "0",
  "message": "success",
  "data": {
    "totalPages": 1,
    "vcItems": [
      {"vcUid": "97176270_twmdiwvc_postpaid", "name": "台灣大哥大門號電子卡", "type": 1, "logoUrl": "https://x/twm.png", "issuerServiceUrl": "https://twm5g.com/8fk2j"},
      {"vcUid": "97179430_fet_vc_prod", "name": "遠傳電信門號電子卡", "type": 1, "logoUrl": "https://x/fet.png", "issuerServiceUrl": "https://dspservice.fetnet.net/twdiwotp/entry"},
      {"vcUid": "96979933_name_phonel5_phonel3", "name": "中華電信門號電子卡", "type": 1, "logoUrl": "https://x/cht.png", "issuerServiceUrl": "https://123.cht.com.tw/DigitalIdentityWallet"},
      {"vcUid": "97000000_driver_licence", "name": "駕照驗證卡", "type": 1, "logoUrl": "https://x/dl.png", "issuerServiceUrl": "https://motc.example/login"},
      {"vcUid": "97111111_broken_phone", "name": "測試門號卡", "type": 1, "logoUrl": "https://x/n.png", "issuerServiceUrl": null}
    ]
  }
}
""".utf8)

@Suite("電信門號卡目錄")
struct TelecomCardCatalogTests {

    /// The heart of the feature: the three carrier cards come back, in order, with
    /// every field mapped; the 駕照 card is filtered out by name; the telecom-named
    /// card with no service URL is dropped.
    @Test func keepsOnlyTheThreeTelecomCards() throws {
        let cards = try TelecomCardCatalog.telecomCards(fromVCListJSON: sampleVCList)

        #expect(cards == [
            TelecomCard(vcUid: "97176270_twmdiwvc_postpaid",
                        name: "台灣大哥大門號電子卡",
                        issuerServiceUrl: "https://twm5g.com/8fk2j",
                        type: 1),
            TelecomCard(vcUid: "97179430_fet_vc_prod",
                        name: "遠傳電信門號電子卡",
                        issuerServiceUrl: "https://dspservice.fetnet.net/twdiwotp/entry",
                        type: 1),
            TelecomCard(vcUid: "96979933_name_phonel5_phonel3",
                        name: "中華電信門號電子卡",
                        issuerServiceUrl: "https://123.cht.com.tw/DigitalIdentityWallet",
                        type: 1),
        ])
    }

    /// The 駕照 card is present in the body and has a service URL, so only the name
    /// filter keeps it out — assert that directly, so a widened filter that started
    /// admitting non-telecom cards is caught.
    @Test func dropsANonTelecomCardEvenWithAServiceURL() throws {
        let cards = try TelecomCardCatalog.telecomCards(fromVCListJSON: sampleVCList)
        #expect(!cards.contains { $0.name.contains("駕照") })
        #expect(!cards.contains { $0.vcUid == "97000000_driver_licence" })
    }

    /// A telecom-named entry with a null `issuerServiceUrl` cannot start an
    /// application, so it is dropped rather than surfaced as a dead row.
    @Test func dropsATelecomCardWithNoServiceURL() throws {
        let cards = try TelecomCardCatalog.telecomCards(fromVCListJSON: sampleVCList)
        #expect(!cards.contains { $0.vcUid == "97111111_broken_phone" })
    }

    /// 「電信」 alone (no 「門號」) still matches — the substring filter is an OR.
    @Test func matchesOnEitherKeyword() throws {
        let body = Data("""
        {"data": {"vcItems": [
          {"vcUid": "a", "name": "某某電信卡", "type": 1, "issuerServiceUrl": "https://a/x"},
          {"vcUid": "b", "name": "某某門號卡", "type": 1, "issuerServiceUrl": "https://b/x"},
          {"vcUid": "c", "name": "學生證", "type": 2, "issuerServiceUrl": "https://c/x"}
        ]}}
        """.utf8)
        let cards = try TelecomCardCatalog.telecomCards(fromVCListJSON: body)
        #expect(cards.map(\.vcUid) == ["a", "b"])
    }

    /// A missing `type` defaults to 1 (external open) rather than dropping an
    /// otherwise-valid telecom card over a missing scalar.
    @Test func defaultsMissingTypeToExternalOpen() throws {
        let body = Data(#"{"data":{"vcItems":[{"vcUid":"a","name":"某電信門號卡","issuerServiceUrl":"https://a/x"}]}}"#.utf8)
        let cards = try TelecomCardCatalog.telecomCards(fromVCListJSON: body)
        #expect(cards.first?.type == 1)
    }

    /// A body that is not the `{data:{vcItems:[…]}}` shape is a malformed response,
    /// not a silently empty list.
    @Test func rejectsAMalformedBody() {
        #expect(throws: TelecomCardCatalogError.malformedResponse) {
            _ = try TelecomCardCatalog.telecomCards(fromVCListJSON: Data("not json".utf8))
        }
        #expect(throws: TelecomCardCatalogError.malformedResponse) {
            _ = try TelecomCardCatalog.telecomCards(fromVCListJSON: Data("{}".utf8))
        }
    }

    /// A well-formed catalogue that lists no telecom card yields an empty array,
    /// not an error — the entry point tells the holder to try later.
    @Test func aCatalogueWithNoTelecomCardIsEmptyNotAnError() throws {
        let body = Data(#"{"data":{"vcItems":[{"vcUid":"a","name":"學生證","type":2,"issuerServiceUrl":"https://a/x"}]}}"#.utf8)
        #expect(try TelecomCardCatalog.telecomCards(fromVCListJSON: body).isEmpty)
    }

    /// The fetch assembles the official directory URL exactly, and filters the
    /// canned reply the same as the pure parse — end-to-end without a socket.
    @Test func fetchBuildsTheVCListURLAndFilters() async throws {
        TelecomCatalogStubURLProtocol.reset()
        defer { TelecomCatalogStubURLProtocol.reset() }
        TelecomCatalogStubURLProtocol.status = 200
        TelecomCatalogStubURLProtocol.responseBody = sampleVCList

        let cards = try await TelecomCardCatalog.fetch(session: TelecomCatalogStubURLProtocol.session())

        #expect(TelecomCatalogStubURLProtocol.lastRequestedURL?.absoluteString
                == "https://frontend.wallet.gov.tw/api/moda/dwapp/apply/vcList?name=&page=0&size=50")
        #expect(cards.count == 3)
    }

    /// A non-2xx reply carries the status and the server's body back, matching the
    /// resolver's handling, so a refusal is diagnosable.
    @Test func fetchCarriesANon2xxStatusAndBody() async throws {
        TelecomCatalogStubURLProtocol.reset()
        defer { TelecomCatalogStubURLProtocol.reset() }
        TelecomCatalogStubURLProtocol.status = 503
        TelecomCatalogStubURLProtocol.responseBody = Data(#"{"error":"maintenance"}"#.utf8)

        await #expect(throws: TelecomCardCatalogError.badStatus(503, body: #"{"error":"maintenance"}"#)) {
            _ = try await TelecomCardCatalog.fetch(session: TelecomCatalogStubURLProtocol.session())
        }
    }
}

/// The `modadigitalwallet://` scheme must be registered, or the offer the carrier
/// app returns is never routed to us and the telecom card can never be collected —
/// while the two schemes the wallet already depended on must still be declared.
@Suite("modadigitalwallet scheme 註冊")
struct TelecomSchemeRegistrationTests {

    private func registeredSchemes() throws -> [String] {
        let info = try #require(Bundle.main.infoDictionary)
        // Anchor on the app's own plist, so this cannot pass by reading the test
        // runner's bundle.
        #expect(info["CFBundleDisplayName"] as? String == "Bond")
        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        return urlTypes.compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 }
    }

    @Test func modadigitalwalletIsRegistered() throws {
        #expect(try registeredSchemes().contains("modadigitalwallet"))
    }

    /// Registering the new scheme must not disturb the two the wallet already
    /// relied on — the FidO callback and the OID4VCI offer entry.
    @Test func theExistingSchemesAreStillRegistered() throws {
        let schemes = try registeredSchemes()
        #expect(schemes.contains("backuptw"))
        #expect(schemes.contains("openid-credential-offer"))
    }

    /// The new scheme has its own URL type dict with a distinct name, not folded
    /// into an existing one — the plist edit added a dict, it did not widen a
    /// scheme list on the wrong entry.
    @Test func modadigitalwalletHasItsOwnURLType() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let entry = urlTypes.first {
            ($0["CFBundleURLSchemes"] as? [String])?.contains("modadigitalwallet") == true
        }
        #expect(entry?["CFBundleURLName"] as? String == "tw.bonds.backupTW.modadigitalwallet")
    }
}

/// Captures the outgoing request and answers with a canned reply, so the catalogue
/// fetch is exercised without a network. Modelled on `ModaResolverStubURLProtocol`:
/// static storage because `URLProtocol` has no per-session hook to key a handler
/// off.
final class TelecomCatalogStubURLProtocol: URLProtocol {

    nonisolated(unsafe) static var lastRequestedURL: URL?
    nonisolated(unsafe) static var status: Int = 200
    nonisolated(unsafe) static var responseBody: Data = Data()

    static func reset() {
        lastRequestedURL = nil
        status = 200
        responseBody = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestedURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelecomCatalogStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
