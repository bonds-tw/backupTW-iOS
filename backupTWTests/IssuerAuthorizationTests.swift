//
//  IssuerAuthorizationTests.swift
//  backupTWTests
//
//  A URL arrived in a QR code. May we contact it?
//

import Foundation
import Testing
@testable import backupTW

@Suite("領卡對象是不是清單上的人")
struct IssuerAuthorizationTests {

    static let sandbox = TWDIWIssuer(
        did: "did:key:z2dmzD81…sandbox",
        displayName: "數位憑證皮夾沙盒",
        displayNameEnglish: "Taiwan Digital Identity Wallet Sandbox",
        taxID: "00000000",
        issuerMetadataBaseURL: "https://issuer-oid4vci.wallet.gov.tw",
        serviceBaseURL: nil,
        reportsOnChainAnchor: true)

    static let moda = TWDIWIssuer(
        did: "did:key:z2dmzD81…moda",
        displayName: "行政院-數位發展部",
        displayNameEnglish: "Ministry of Digital Affairs",
        taxID: "2-16-886-101-20003-20082",
        issuerMetadataBaseURL: nil,
        serviceBaseURL: "https://moda.wallet.gov.tw",
        reportsOnChainAnchor: true)

    static let list = [sandbox, moda]

    // MARK: The ordinary case

    @Test func aHostOnTheListIsAllowed() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/credential-offer-object?nonce=abc&sub=def",
            against: Self.list)
        guard case .allowed(let issuers, let host) = verdict else {
            Issue.record("a real issuer was refused: \(verdict)")
            return
        }
        #expect(issuers == [Self.sandbox])
        #expect(host == "issuer-oid4vci.wallet.gov.tw")
    }

    @Test func aHostThatIsNotOnTheListIsRefused() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://wallet.example.tw/api/issuer/1/credential-offer-object",
            against: Self.list)
        #expect(verdict == .refused(.notOnTheTrustList(host: "wallet.example.tw")))
    }

    // MARK: The attacks prefix matching would let through

    /// **The reason this is not `hasPrefix`.**
    ///
    /// `https://issuer-oid4vci.wallet.gov.tw.evil.tw/` has the trusted base as a
    /// literal string prefix. Compared as hosts it is a different host, and
    /// nothing about it is close.
    @Test func aSuffixedLookalikeHostIsRefused() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw.evil.tw/api/issuer/00000000/",
            against: Self.list)
        #expect(verdict == .refused(.notOnTheTrustList(host: "issuer-oid4vci.wallet.gov.tw.evil.tw")))
    }

    /// `https://issuer-oid4vci.wallet.gov.tw@evil.tw/` reads, to a person
    /// glancing at it, as the government host. The host is `evil.tw`.
    @Test func userInfoIsRefusedRatherThanParsedAround() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw@evil.tw/api/",
            against: Self.list)
        #expect(verdict == .refused(.containsUserInfo))
    }

    /// A trailing dot is a legal absolute DNS name resolving to the same place,
    /// and a different string. Two spellings of one host is the thing this
    /// comparison must not have, so it is refused rather than folded.
    @Test func aTrailingDotHostIsRefused() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw./api/",
            against: Self.list)
        #expect(verdict == .refused(.hostNotPlainASCII))
    }

    @Test func caseInTheHostDoesNotMatter() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://Issuer-OID4VCI.Wallet.GOV.TW/api/",
            against: Self.list)
        guard case .allowed(_, let host) = verdict else {
            Issue.record("case-folding refused a real host")
            return
        }
        #expect(host == "issuer-oid4vci.wallet.gov.tw")
    }

    @Test func plainHTTPIsRefused() {
        #expect(IssuerAuthorization.authorise(
            fetchURL: "http://issuer-oid4vci.wallet.gov.tw/api/",
            against: Self.list) == .refused(.notHTTPS))
    }

    @Test func anExplicitOddPortIsRefused() {
        #expect(IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw:8443/api/",
            against: Self.list) == .refused(.unexpectedPort(8443)))
    }

    /// 443 spelled out is the same endpoint, and refusing it would be pedantry
    /// aimed at somebody honest.
    @Test func port443SpelledOutIsFine() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw:443/api/",
            against: Self.list)
        guard case .allowed = verdict else {
            Issue.record("explicit :443 was refused")
            return
        }
    }

    @Test func percentEncodedDotsAreRefused() {
        #expect(IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/%2e%2e/elsewhere",
            against: Self.list) == .refused(.pathNotNormalised))
    }

    @Test func aNonASCIIHostIsRefusedNotFolded() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw.台灣/api/",
            against: Self.list)
        // Either refusal is defensible; what must not happen is a match.
        guard case .refused = verdict else {
            Issue.record("a Unicode host matched a trusted one")
            return
        }
    }

    // MARK: Gate 2

    /// The offer must name an issuer from the same organisation as the URL it
    /// arrived from. Fetching from one host and being told to collect from
    /// another is exactly the redirection this gate exists to catch.
    @Test func anOfferNamingADifferentOrganisationIsRefused() {
        guard case .allowed(let matched, _) = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/credential-offer-object",
            against: Self.list) else {
            Issue.record("gate 1 refused a real issuer")
            return
        }
        let confirmed = IssuerAuthorization.confirm(
            credentialIssuer: "https://moda.wallet.gov.tw/api/issuer/9/",
            matched: matched)
        #expect(confirmed == .failure(.organisationMismatch))
    }

    @Test func anOfferNamingTheSameOrganisationIsConfirmed() {
        guard case .allowed(let matched, _) = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/credential-offer-object",
            against: Self.list) else {
            Issue.record("gate 1 refused a real issuer")
            return
        }
        #expect(IssuerAuthorization.confirm(
            credentialIssuer: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/",
            matched: matched) == .success(Self.sandbox))
    }

    /// A host that genuinely belongs to more than one organisation is confirmed,
    /// not refused. Measured 2026-08-26: three universities share
    /// `dcert.wallet.gov.tw` and 行政院-數位發展部 is listed as both an issuer and a
    /// verifier — so `matched` legitimately carries more than one row for one
    /// host, and a strict count == 1 refused cards those hosts really issued.
    /// What gate 2 must establish is that the offer's issuer host is a trusted
    /// one; which row is returned is safe because the signed `aud` takes its
    /// path from the offer, not from the row.
    @Test func aHostBelongingToTwoOrganisationsIsConfirmedNotRefused() {
        let twin = TWDIWIssuer(did: "did:key:z2dmzD81…twin", displayName: "另一個機關",
                               displayNameEnglish: "Another Agency", taxID: "11111111",
                               issuerMetadataBaseURL: "https://issuer-oid4vci.wallet.gov.tw",
                               serviceBaseURL: nil, reportsOnChainAnchor: true)
        let list = [Self.sandbox, twin]
        guard case .allowed(let matched, _) = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/", against: list) else {
            Issue.record("gate 1 refused")
            return
        }
        #expect(matched.count == 2)
        let result = IssuerAuthorization.confirm(
            credentialIssuer: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/",
            matched: matched)
        // Confirmed as one of the two — not refused as an ambiguity.
        #expect(result == .success(Self.sandbox) || result == .success(twin))
    }

    /// The same organisation listed twice — as issuer and as verifier — is one
    /// organisation, and a card it issued must confirm rather than read as a
    /// two-org ambiguity. This is the exact shape that refused the official
    /// 皮夾夥伴卡 (行政院-數位發展部) before the fix.
    @Test func oneOrganisationListedTwiceStillConfirms() {
        let asVerifier = TWDIWIssuer(did: Self.sandbox.did, displayName: Self.sandbox.displayName,
                                     displayNameEnglish: Self.sandbox.displayNameEnglish,
                                     taxID: Self.sandbox.taxID,
                                     issuerMetadataBaseURL: nil,
                                     serviceBaseURL: "https://issuer-oid4vci.wallet.gov.tw",
                                     reportsOnChainAnchor: true)
        let matched = [Self.sandbox, asVerifier]
        #expect(IssuerAuthorization.confirm(
            credentialIssuer: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/",
            matched: matched) != .failure(.organisationMismatch))
    }

    @Test func everyOrganisationSharingAHostNeedsRegistryEvidence() {
        let twin = TWDIWIssuer(did: "did:key:zTwin", displayName: "另一個機關",
                               displayNameEnglish: "Another Agency", taxID: "11111111",
                               issuerMetadataBaseURL: Self.sandbox.issuerMetadataBaseURL,
                               serviceBaseURL: nil, reportsOnChainAnchor: true)
        let matched = [Self.sandbox, twin]
        let verified = TWDIWOnChainVerification.verified(blockNumber: "0x1",
                                                         transactionHash: "0xabc")

        guard case .failure(.trustVerificationUnavailable) = IssuerAuthorization.confirmRegistryEvidence(
            matched: matched,
            verification: [Self.sandbox.did: verified]) else {
            Issue.record("a shared-host row without evidence did not fail closed")
            return
        }
        guard case .failure(.trustRecordMismatch) = IssuerAuthorization.confirmRegistryEvidence(
            matched: matched,
            verification: [Self.sandbox.did: verified, twin.did: .mismatch]) else {
            Issue.record("a mismatched shared-host row did not name the mismatch")
            return
        }
        guard case .success = IssuerAuthorization.confirmRegistryEvidence(
            matched: matched,
            verification: [Self.sandbox.did: verified, twin.did: verified]) else {
            Issue.record("two independently verified rows on the shared host were refused")
            return
        }
    }

    @Test func aDevelopmentSandboxResultIsExplicitlyAuthorised() {
        guard case .success = IssuerAuthorization.confirmRegistryEvidence(
            matched: [Self.sandbox],
            verification: [Self.sandbox.did: .developmentSandbox]) else {
            Issue.record("the explicit DEBUG sandbox result was refused")
            return
        }
    }

    @Test func trustListRequestsBypassCaches() throws {
        let request = try TrustListFetcher(session: .shared).request(page: 2, orgType: 1)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache, no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        #expect(request.url?.query?.contains("page=2") == true)
    }

    /// **We sign over our own bytes.** Once the host is agreed there is nothing
    /// to gain from carrying the candidate's spelling forward, and something to
    /// lose: the proof JWT's `aud` would be a string an attacker influenced.
    @Test func theBaseURLUsedAfterwardsComesFromTheListNotTheOffer() {
        #expect(IssuerAuthorization.canonicalIssuerBase(for: Self.sandbox)
                == "https://issuer-oid4vci.wallet.gov.tw")
        #expect(IssuerAuthorization.canonicalIssuerBase(for: Self.moda)
                == "https://moda.wallet.gov.tw")
    }

    // MARK: Reading the list

    @Test func aListPageIsParsed() throws {
        let json = Data("""
        {"msg":"執行成功","code":"0","data":{"count":2,"dids":[
          {"id":"did:key:zA","orgType":1,"orgGroupDetail":{"name":"政府部門"},
           "org":{"name":"行政院-數位發展部","name_en":"Ministry of Digital Affairs",
                  "taxId":"2-16-886-101-20003-20082","serviceBaseURL":"https://moda.wallet.gov.tw"},
           "onChainHistory":[{"net":"arbitrum"}]},
          {"id":"did:key:zB","orgType":1,"orgGroupDetail":{"name":"政府部門"},
           "org":{"name":"中國醫藥大學","name_en":"China Medical University",
                  "taxId":"2-16-886-111-100557","serviceBaseURL":"https://52005408.wallet.gov.tw",
                  "issuerMetadataBaseURL":null},
           "onChainHistory":[]}
        ]}}
        """.utf8)
        let issuers = try TWDIWIssuer.page(from: json)
        #expect(issuers.count == 2)
        #expect(issuers[0].displayName == "行政院-數位發展部")
        #expect(issuers[0].reportsOnChainAnchor)
        // The real entry with no anchor and no issuer metadata URL, kept as a
        // fixture because it is the shape a strict parser would drop.
        #expect(!issuers[1].reportsOnChainAnchor)
        #expect(issuers[1].issuerMetadataBaseURL == nil)
    }

    /// The single-object response shape is live too — `GET /api/did/<did>`
    /// returns the entry directly at `data` rather than in a `dids` array.
    @Test func theSingleEntryResponseShapeIsAlsoParsed() throws {
        let json = Data("""
        {"msg":"執行成功","code":"0","data":{"id":"did:key:zA",
          "org":{"name":"數位憑證皮夾沙盒","taxId":"00000000",
                 "issuerMetadataBaseURL":"https://issuer-oid4vci.wallet.gov.tw"},
          "onChainHistory":[{"net":"arbitrum_testnet"}]}}
        """.utf8)
        let issuers = try TWDIWIssuer.page(from: json)
        #expect(issuers.count == 1)
        #expect(issuers[0].taxID == "00000000")
    }

    /// An empty page is how enumeration knows to stop, so it must parse as empty
    /// rather than throw.
    @Test func anEmptyPageIsEmptyNotAnError() throws {
        let json = Data(#"{"msg":"執行成功","code":"0","data":{"count":20,"dids":[]}}"#.utf8)
        #expect(try TWDIWIssuer.page(from: json).isEmpty)
    }

    @Test func aCompleteChainRecordIsRetainedForIndependentChecking() throws {
        let json = Data("""
        {"code":"0","data":{"id":"did:key:zA","did":"signed-document",
          "orgType":1,"orgGroup":2,"updatedAt":1700000000,
          "org":{"name":"測試單位","taxId":"12345678"},
          "onChainHistory":[{"net":"arbitrum",
            "scAddress":"0x84172caf8dd126c76f1fa8a2733ca3233264d31f",
            "txHash":"0xabc","status":1,"createdAt":1700000001}]}}
        """.utf8)
        let issuer = try #require(TWDIWIssuer.page(from: json).first)
        #expect(issuer.signedDIDDocument == "signed-document")
        #expect(issuer.orgType == 1)
        #expect(issuer.orgGroup == 2)
        #expect(issuer.onChainRecords.first?.transactionHash == "0xabc")
        #expect(issuer.organisationJSON.contains("測試單位"))
    }
}

/// Captures the exact JSON-RPC batch sent by `TWDIWOnChainVerifier`.
/// `URLProtocol` has no per-session storage hook, so the owning suite is
/// serialised and resets this static state around every test.
final class TWDIWRegistryStubURLProtocol: URLProtocol {

    struct Exchange {
        let request: URLRequest
        let body: Data
    }

    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var exchanges: [Exchange] = []

    static func reset() {
        status = 200
        responseBody = Data()
        exchanges = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TWDIWRegistryStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.drainBody(of: request)
        Self.exchanges.append(Exchange(request: request, body: body))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drainBody(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4_096
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

@Suite("信任清單鏈上通訊", .serialized)
struct TWDIWOnChainTransportTests {

    static let did = "did:key:zA"
    static let organisation = #"{"name":"測試單位"}"#
    static let record = TWDIWOnChainRecord(
        network: TWDIWOnChainVerifier.network,
        contractAddress: TWDIWOnChainVerifier.registryContract,
        transactionHash: "0xabc",
        status: 1,
        createdAt: nil)
    static let issuer = TWDIWIssuer(
        did: did,
        displayName: "測試單位",
        displayNameEnglish: "Test",
        taxID: "12345678",
        issuerMetadataBaseURL: "https://issuer.example",
        serviceBaseURL: nil,
        reportsOnChainAnchor: true,
        signedDIDDocument: "signed-document",
        organisationJSON: organisation,
        orgType: 1,
        orgGroup: 2,
        onChainRecords: [record])

    @Test func verifierRequestsHistoryReceiptAndLatestStateWithoutCaches() async throws {
        TWDIWRegistryStubURLProtocol.reset()
        defer { TWDIWRegistryStubURLProtocol.reset() }
        TWDIWRegistryStubURLProtocol.responseBody = try JSONSerialization.data(withJSONObject: [
            ["jsonrpc": "2.0", "id": 0, "result": [
                "hash": "0xabc",
                "to": TWDIWOnChainVerifier.registryContract,
                "input": TWDIWOnChainInputTests.input(
                    strings: [Self.did, "signed-document", Self.organisation],
                    orgType: 1,
                    orgGroup: 2),
                "blockNumber": "0x42",
            ]],
            ["jsonrpc": "2.0", "id": 1, "result": ["status": "0x1"]],
            ["jsonrpc": "2.0", "id": 2, "result": TWDIWOnChainInputTests.currentResult(
                signed: "signed-document",
                organisation: Self.organisation,
                orgType: 1,
                orgGroup: 2,
                revoked: false)],
        ])

        let verifier = TWDIWOnChainVerifier(session: TWDIWRegistryStubURLProtocol.session(),
                                            rpcURL: URL(string: "https://rpc.example")!)
        let result = await verifier.verify([Self.issuer, Self.issuer])
        #expect(result[Self.did] == .verified(blockNumber: "0x42", transactionHash: "0xabc"))

        // A repeated DID is deliberately included above. It must be checked
        // once rather than crashing or producing two conflicting batches.
        let exchange = try #require(TWDIWRegistryStubURLProtocol.exchanges.first)
        #expect(TWDIWRegistryStubURLProtocol.exchanges.count == 1)
        #expect(exchange.request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(exchange.request.value(forHTTPHeaderField: "Cache-Control") == "no-cache, no-store")
        #expect(exchange.request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        let calls = try #require(try JSONSerialization.jsonObject(with: exchange.body)
            as? [[String: Any]])
        #expect(calls.compactMap { $0["method"] as? String } == [
            "eth_getTransactionByHash", "eth_getTransactionReceipt", "eth_call",
        ])
        let latestCall = try #require(calls.last)
        let params = try #require(latestCall["params"] as? [Any])
        let call = try #require(params.first as? [String: Any])
        #expect(call["to"] as? String == TWDIWOnChainVerifier.registryContract)
        #expect((call["data"] as? String)?.hasPrefix(
            "0x" + TWDIWOnChainVerifier.currentRecordSelector) == true)
        #expect(params.last as? String == "latest")
    }

    @Test func rpcInfrastructureErrorFailsClosedAsUnavailable() async throws {
        TWDIWRegistryStubURLProtocol.reset()
        defer { TWDIWRegistryStubURLProtocol.reset() }
        TWDIWRegistryStubURLProtocol.responseBody = try JSONSerialization.data(withJSONObject: [
            ["jsonrpc": "2.0", "id": 0, "result": NSNull()],
            ["jsonrpc": "2.0", "id": 1, "result": NSNull()],
            ["jsonrpc": "2.0", "id": 2,
             "error": ["code": -32_000, "message": "upstream unavailable"]],
        ])
        let verifier = TWDIWOnChainVerifier(session: TWDIWRegistryStubURLProtocol.session(),
                                            rpcURL: URL(string: "https://rpc.example")!)
        let result = await verifier.verify([Self.issuer])
        #expect(result[Self.did] == .unavailable)
    }
}

@Suite("信任清單鏈上交易解碼")
struct TWDIWOnChainInputTests {

    @Test func registryInputRoundTripsTheThreeRecordsAndCategories() throws {
        let input = Self.input(strings: ["did:key:zA", "signed.did.document", #"{"name":"測試單位"}"#],
                               orgType: 1,
                               orgGroup: 2)
        let decoded = try #require(TWDIWOnChainVerifier.decodeRegistryInput(input))
        #expect(decoded.did == "did:key:zA")
        #expect(decoded.signedDIDDocument == "signed.did.document")
        #expect(decoded.organisationJSON == #"{"name":"測試單位"}"#)
        #expect(decoded.orgType == 1)
        #expect(decoded.orgGroup == 2)
    }

    @Test func aDifferentMethodSelectorIsRefused() {
        let input = Self.input(strings: ["a", "b", "{}"], orgType: 1, orgGroup: 1)
        #expect(TWDIWOnChainVerifier.decodeRegistryInput(
            "0x00000000" + String(input.dropFirst(10))) == nil)
    }

    @Test func currentRecordCallUsesTheDeployedGetterAndBoundsTheDID() throws {
        let call = try #require(TWDIWOnChainVerifier.currentRecordCallData(forDID: "did:key:zA"))
        #expect(call.hasPrefix("0x" + TWDIWOnChainVerifier.currentRecordSelector))
        #expect(call.contains(Data("did:key:zA".utf8).map { String(format: "%02x", $0) }.joined()))
        #expect(TWDIWOnChainVerifier.currentRecordCallData(forDID: "") == nil)
        #expect(TWDIWOnChainVerifier.currentRecordCallData(
            forDID: String(repeating: "a", count: 4_097)) == nil)
    }

    @Test func currentRecordReturnDecodesAllFieldsAndRevocation() throws {
        let decoded = try #require(TWDIWOnChainVerifier.decodeCurrentRecord(
            Self.currentResult(signed: "signed-document",
                               organisation: #"{"name":"測試單位"}"#,
                               orgType: 1,
                               orgGroup: 2,
                               revoked: true)))
        #expect(decoded.signedDIDDocument == "signed-document")
        #expect(decoded.organisationJSON == #"{"name":"測試單位"}"#)
        #expect(decoded.orgType == 1)
        #expect(decoded.orgGroup == 2)
        #expect(decoded.revoked)
    }

    @Test func historicalTransactionCannotHideAChangedOrRevokedCurrentRecord() {
        let did = "did:key:zA"
        let organisation = #"{"name":"測試單位"}"#
        let record = TWDIWOnChainRecord(
            network: TWDIWOnChainVerifier.network,
            contractAddress: TWDIWOnChainVerifier.registryContract,
            transactionHash: "0xabc",
            status: 1,
            createdAt: nil)
        let issuer = TWDIWIssuer(did: did,
                                 displayName: "測試單位",
                                 displayNameEnglish: "Test",
                                 taxID: "12345678",
                                 issuerMetadataBaseURL: "https://issuer.example",
                                 serviceBaseURL: nil,
                                 reportsOnChainAnchor: true,
                                 signedDIDDocument: "signed-document",
                                 organisationJSON: organisation,
                                 orgType: 1,
                                 orgGroup: 2,
                                 onChainRecords: [record])
        let transaction: [String: Any] = [
            "hash": "0xabc",
            "to": TWDIWOnChainVerifier.registryContract,
            "input": Self.input(strings: [did, "signed-document", organisation],
                                orgType: 1, orgGroup: 2),
            "blockNumber": "0x42",
        ]
        let receipt: [String: Any] = ["status": "0x1"]
        let current = TWDIWOnChainVerifier.CurrentRegistryRecord(
            signedDIDDocument: "signed-document",
            organisationJSON: organisation,
            orgType: 1,
            orgGroup: 2,
            revoked: false)

        #expect(TWDIWOnChainVerifier.check(issuer: issuer,
                                          record: record,
                                          transaction: transaction,
                                          receipt: receipt,
                                          current: current)
            == .verified(blockNumber: "0x42", transactionHash: "0xabc"))

        let replaced = TWDIWOnChainVerifier.CurrentRegistryRecord(
            signedDIDDocument: "newer-document",
            organisationJSON: organisation,
            orgType: 1,
            orgGroup: 2,
            revoked: false)
        #expect(TWDIWOnChainVerifier.check(issuer: issuer,
                                          record: record,
                                          transaction: transaction,
                                          receipt: receipt,
                                          current: replaced) == .mismatch)

        let revoked = TWDIWOnChainVerifier.CurrentRegistryRecord(
            signedDIDDocument: "signed-document",
            organisationJSON: organisation,
            orgType: 1,
            orgGroup: 2,
            revoked: true)
        #expect(TWDIWOnChainVerifier.check(issuer: issuer,
                                          record: record,
                                          transaction: transaction,
                                          receipt: receipt,
                                          current: revoked) == .mismatch)
    }

    fileprivate static func input(strings: [String], orgType: Int, orgGroup: Int) -> String {
        var tail = Data()
        var offsets: [Int] = []
        for string in strings {
            offsets.append(32 * 6 + tail.count)
            let value = Data(string.utf8)
            tail.append(word(value.count))
            tail.append(value)
            let padding = (32 - value.count % 32) % 32
            tail.append(Data(repeating: 0, count: padding))
        }
        var data = Data()
        offsets.forEach { data.append(word($0)) }
        data.append(word(orgType))
        data.append(word(orgGroup))
        data.append(word(0))
        data.append(tail)
        return "0x" + TWDIWOnChainVerifier.methodSelector + data.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func currentResult(signed: String,
                                          organisation: String,
                                          orgType: Int,
                                          orgGroup: Int,
                                          revoked: Bool) -> String {
        let values = [Data(signed.utf8), Data(organisation.utf8)]
        var tail = Data()
        var offsets: [Int] = []
        for value in values {
            offsets.append(32 * 5 + tail.count)
            tail.append(word(value.count))
            tail.append(value)
            tail.append(Data(repeating: 0, count: (32 - value.count % 32) % 32))
        }
        var tuple = Data()
        offsets.forEach { tuple.append(word($0)) }
        tuple.append(word(orgType))
        tuple.append(word(orgGroup))
        tuple.append(word(revoked ? 1 : 0))
        tuple.append(tail)
        return "0x" + (word(32) + tuple).map { String(format: "%02x", $0) }.joined()
    }

    private static func word(_ value: Int) -> Data {
        var bytes = Data(repeating: 0, count: 32)
        var number = UInt64(value).bigEndian
        withUnsafeBytes(of: &number) { bytes.replaceSubrange(24..<32, with: $0) }
        return bytes
    }
}
