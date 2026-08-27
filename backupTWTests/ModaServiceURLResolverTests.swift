//
//  ModaServiceURLResolverTests.swift
//  backupTWTests
//
//  Resolving a static card-application QR to its issuer page — the URL it builds,
//  the JSON it reads, and the failures it carries back. Never over the wire.
//

import Foundation
import Testing
@testable import backupTW

/// Captures the outgoing request and answers with a canned reply, so the resolver
/// is exercised end-to-end without a network. Static storage and serialisation for
/// the same reason as `OID4VCIStubURLProtocol`: `URLProtocol` has no per-session
/// hook to key a handler off.
final class ModaResolverStubURLProtocol: URLProtocol {

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
        configuration.protocolClasses = [ModaResolverStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("靜態卡片 QR 換發卡頁", .serialized)
struct ModaServiceURLResolverTests {

    /// The 201i endpoint, assembled exactly. The `mode` rides as a query item and
    /// the vcUid as a path segment.
    @Test func buildsThe201iURL() async throws {
        ModaResolverStubURLProtocol.reset()
        defer { ModaResolverStubURLProtocol.reset() }
        ModaResolverStubURLProtocol.status = 200
        ModaResolverStubURLProtocol.responseBody = Data(#"{"type":2,"name":"n","issuerServiceUrl":"https://issuer.example/page"}"#.utf8)

        _ = try await ModaServiceURLResolver.resolve(
            vcUid: "ABC", mode: "vc", session: ModaResolverStubURLProtocol.session())

        #expect(ModaResolverStubURLProtocol.lastRequestedURL?.absoluteString
                == "https://frontend.wallet.gov.tw/api/moda/dwapp/serviceUrl/ABC?mode=vc")
    }

    /// An injected base (a UAT host) is honoured instead of production.
    @Test func honoursAnInjectedFrontendBase() async throws {
        ModaResolverStubURLProtocol.reset()
        defer { ModaResolverStubURLProtocol.reset() }
        ModaResolverStubURLProtocol.responseBody = Data(#"{"type":2,"name":null,"issuerServiceUrl":"https://x/y"}"#.utf8)

        _ = try await ModaServiceURLResolver.resolve(
            vcUid: "ABC", mode: "vc",
            frontendBase: "https://frontend-uat.wallet.gov.tw",
            session: ModaResolverStubURLProtocol.session())

        #expect(ModaResolverStubURLProtocol.lastRequestedURL?.absoluteString
                == "https://frontend-uat.wallet.gov.tw/api/moda/dwapp/serviceUrl/ABC?mode=vc")
    }

    /// A 2xx body decodes into all three fields.
    @Test func decodesAWellFormedResponse() async throws {
        ModaResolverStubURLProtocol.reset()
        defer { ModaResolverStubURLProtocol.reset() }
        ModaResolverStubURLProtocol.status = 200
        ModaResolverStubURLProtocol.responseBody = Data("""
        {"type":2,"name":"電信門號驗證卡","issuerServiceUrl":"https://issuer.example/apply?token=abc"}
        """.utf8)

        let response = try await ModaServiceURLResolver.resolve(
            vcUid: "ABC", mode: "vc", session: ModaResolverStubURLProtocol.session())

        #expect(response.type == 2)
        #expect(response.name == "電信門號驗證卡")
        #expect(response.issuerServiceUrl == "https://issuer.example/apply?token=abc")
    }

    /// The `DwModa201iResponse` shape decodes directly, no session involved — and
    /// its fields are all optional, matching the official client's `guard let`s.
    @Test func decodesTheResponseShapeInIsolation() throws {
        let json = Data(#"{"type":1,"name":"駕照驗證卡","issuerServiceUrl":"https://motc.example/login"}"#.utf8)
        let decoded = try JSONDecoder().decode(DwModa201iResponse.self, from: json)
        #expect(decoded == DwModa201iResponse(type: 1, name: "駕照驗證卡",
                                              issuerServiceUrl: "https://motc.example/login"))

        // Missing fields are tolerated as nil, not a decode failure.
        let sparse = try JSONDecoder().decode(DwModa201iResponse.self, from: Data("{}".utf8))
        #expect(sparse == DwModa201iResponse(type: nil, name: nil, issuerServiceUrl: nil))
    }

    /// A non-2xx reply carries the status and the server's own body back, matching
    /// `OID4VPResponse`'s handling, so a refusal is diagnosable.
    @Test func carriesANon2xxStatusAndBody() async throws {
        ModaResolverStubURLProtocol.reset()
        defer { ModaResolverStubURLProtocol.reset() }
        ModaResolverStubURLProtocol.status = 403
        ModaResolverStubURLProtocol.responseBody = Data(#"{"error":"forbidden"}"#.utf8)

        await #expect(throws: ModaServiceURLResolverError.badStatus(403, body: #"{"error":"forbidden"}"#)) {
            _ = try await ModaServiceURLResolver.resolve(
                vcUid: "ABC", mode: "vc", session: ModaResolverStubURLProtocol.session())
        }
    }

    /// A 2xx whose body is not the expected shape is a malformed response, not a
    /// silently empty one.
    @Test func rejectsAMalformed2xxBody() async throws {
        ModaResolverStubURLProtocol.reset()
        defer { ModaResolverStubURLProtocol.reset() }
        ModaResolverStubURLProtocol.status = 200
        ModaResolverStubURLProtocol.responseBody = Data("not json".utf8)

        await #expect(throws: ModaServiceURLResolverError.malformedResponse) {
            _ = try await ModaServiceURLResolver.resolve(
                vcUid: "ABC", mode: "vc", session: ModaResolverStubURLProtocol.session())
        }
    }
}
