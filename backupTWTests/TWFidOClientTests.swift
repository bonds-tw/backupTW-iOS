//
//  TWFidOClientTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

// MARK: - Fixtures
//
// File scope rather than static members: `@Test(arguments:)` evaluates its
// expressions outside the enclosing type, so `Self.` is not available there.

private func base64URL(_ string: String) -> String {
    Data(string.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// base64url → bytes, padding optional. Used to show what a receiver does with
/// `rtn_val`, so it is spelled out here rather than reusing the client's own
/// decoder: an encoder checked against its own inverse passes on any alphabet,
/// including a wrong one.
private func base64URLData(_ string: String) -> Data? {
    var standard = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: standard)
}

/// Seals an `idp_checksum` the way 內政部 does:
/// `hex(IV ‖ AES-256-GCM(lowercase hex of SHA-256(payload)) ‖ tag)` over
/// `transaction_id ‖ error_code ‖ hashed_id_num ‖ signed_response`.
///
/// This is the *inverse* of what the client does — it seals, the client opens —
/// and it is written out from the spec rather than calling into the production
/// helper, so the two can genuinely disagree.
private func idpChecksum(transactionID: String = "TXN-1",
                         errorCode: String = "0",
                         hashedIDNumber: String = "aGFzaA==",
                         signedResponse: String = "c2ln",
                         key: String) throws -> String {
    guard let keyData = Data(base64Encoded: key), keyData.count == 32 else {
        throw StubError.unusableTestKey
    }
    let payload = transactionID + errorCode + hashedIDNumber + signedResponse
    let digestHex = SHA256.hash(data: Data(payload.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let sealed = try AES.GCM.seal(Data(digestHex.utf8), using: SymmetricKey(data: keyData))
    guard let combined = sealed.combined else { throw StubError.unusableTestKey }
    return combined.map { String(format: "%02x", $0) }.joined()
}

/// Shaped like the real thing: base64url payload, a dot, an opaque digest.
private let stubSPTicket =
    base64URL(#"{"transaction_id":"TXN-1","sp_ticket_id":"TKT-1","op_code":"SIGN"}"#)
    + ".ZGlnZXN0LXNlZ21lbnQ"

private let stubTicket = TWFidOTicket(spTicket: stubSPTicket,
                                      transactionID: "TXN-1",
                                      spTicketID: "TKT-1")

private let malformedTickets: [String] = [
    "no-dot-at-all",
    "!!!not-base64!!!.ZGlnZXN0",
    base64URL(#"{"sp_ticket_id":"TKT-1"}"#) + ".ZGlnZXN0",
    base64URL(#"{"transaction_id":"TXN-1"}"#) + ".ZGlnZXN0",
    base64URL("plain text, not JSON") + ".ZGlnZXN0",
    "",
]

/// The last two are the reason this client does not use
/// `URLComponents.queryItems`: their base64 contains `+` and `/` respectively,
/// and `queryItems` leaves both raw.
private let returnURLs: [String] = [
    "backuptw://fido/callback",
    "backuptw://callback",
    "backuptw://fido/callback?x=1",
    "backuptw://fido/a~",
    "backuptw://fido/a?",
]

/// Codes the server uses for "the holder has not finished yet".
private let pendingErrorCodes: [String] = [
    "20002",
    "20003",
    "SP-API-ATH-02-SPTKTID_TXNLOG_NF",
    "SPTKTID_TXNLOG_NF",
    "SPTKTID_TXNLOG_NF: transaction log not found",
]

private let terminalErrorCodes: [String] = [
    "SPTKT_OVD",
    "SPTKT_TIME_ORV",
    "PM_IDN_FT_ERR",
    "INV_SP_CHECKSUM",
    "20001",
    "99999",
]

// MARK: - Tests

/// Serialised because the stubbed protocol keeps its handler in static storage;
/// `URLProtocol` offers no per-session hook to key one off.
@Suite(.serialized)
struct TWFidOClientTests {

    private static let serviceID = "SP-TEST-0001"
    private static let aesKey = Data(repeating: 0x2A, count: 32).base64EncodedString()
    private static let idNumber = "A123456789"

    private func makeClient(configuration: TWFidOConfiguration = .production) -> TWFidOClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TWFidOStubURLProtocol.self]
        return TWFidOClient(
            configuration: configuration,
            credentials: StubCredentialProvider(
                value: SPCredentials(serviceID: Self.serviceID, aesKeyBase64: Self.aesKey)),
            session: URLSession(configuration: sessionConfiguration))
    }

    private func signRequest(deviceAlias: String? = nil,
                             timeLimit: Int = 600) -> TWFidOSignRequest {
        TWFidOSignRequest(idNumber: Self.idNumber,
                          hint: "請確認身分",
                          deviceAlias: deviceAlias,
                          timeLimit: timeLimit)
    }

    private let callback = URL(string: "backuptw://fido/callback")!

    // MARK: Endpoints

    @Test func pushPostsToRequestAthOrSignPush() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest())

        let exchange = try #require(TWFidOStubURLProtocol.exchanges.last)
        #expect(exchange.request.url?.host == "fidoapi.moi.gov.tw")
        #expect(exchange.request.url?.path == "/moise/sp/requestAthOrSignPush")
        #expect(exchange.request.httpMethod == "POST")
    }

    @Test func appToAppPostsToGetSpTicket() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignAppToApp(signRequest(), returnURL: callback)

        let exchange = try #require(TWFidOStubURLProtocol.exchanges.last)
        #expect(exchange.request.url?.path == "/moise/sp/getSpTicket")
    }

    @Test func fetchResultPostsToGetAthOrSignResult() async throws {
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().fetchResult(for: stubTicket)

        let exchange = try #require(TWFidOStubURLProtocol.exchanges.last)
        #expect(exchange.request.url?.path == "/moise/sp/getAthOrSignResult")
    }

    @Test func uatConfigurationTargetsTheTestHost() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient(configuration: .uat).requestSignPush(signRequest())

        let exchange = try #require(TWFidOStubURLProtocol.exchanges.last)
        #expect(exchange.request.url?.host == "fido-test.moi.gov.tw")
        #expect(TWFidOConfiguration.uat.appID == TWFidOConfiguration.production.appID)
    }

    // MARK: op_mode

    /// The push endpoint rejects a body carrying `op_mode`, and the push
    /// checksum payload has no slot for it either. Absence is the contract.
    @Test func pushBodyOmitsOpMode() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest())

        let body = try lastBody()
        #expect(body.keys.contains("op_mode") == false)
        #expect(body["op_code"] as? String == "SIGN")
    }

    @Test func appToAppBodyCarriesOpMode() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignAppToApp(signRequest(), returnURL: callback)

        let body = try lastBody()
        #expect(body["op_mode"] as? String == "APP2APP")
        #expect(body["op_code"] as? String == "SIGN")
    }

    // MARK: device_user_def_desc

    @Test func deviceAliasIsOmittedWhenNotSpecified() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest(deviceAlias: nil))

        // Present-but-null is not the same as absent here: absence is what fans
        // the push out to every device the holder has bound.
        let body = try lastBody()
        #expect(body.keys.contains("device_user_def_desc") == false)
    }

    @Test func deviceAliasIsIncludedWhenSpecified() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest(deviceAlias: "豆泥的 iPhone"))

        let body = try lastBody()
        #expect(body["device_user_def_desc"] as? String == "豆泥的 iPhone")
    }

    @Test func appToAppNeverSendsDeviceAlias() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignAppToApp(signRequest(deviceAlias: "豆泥的 iPhone"),
                                                       returnURL: callback)

        // An alias would have to appear in the checksum payload too, and the
        // app-to-app order has no position for one.
        let body = try lastBody()
        #expect(body.keys.contains("device_user_def_desc") == false)
    }

    // MARK: sign_info

    @Test func signDataDecodesToTheApplicationIdentifier() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignAppToApp(signRequest(), returnURL: callback)

        let signInfo = try #require(try lastBody()["sign_info"] as? [String: Any])
        let signData = try #require(signInfo["sign_data"] as? String)
        let decoded = try #require(Data(base64Encoded: signData))

        #expect(String(decoding: decoded, as: UTF8.self) == TWFidOConfiguration.bondsAppID)
        // 31 hex characters is what the circuit's field element holds; a
        // different length silently changes every derived nullifier.
        #expect(TWFidOConfiguration.bondsAppID.count == 31)
    }

    @Test func signInfoPinsPKCS1() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest())

        let signInfo = try #require(try lastBody()["sign_info"] as? [String: Any])
        // PKCS#7 or CMS would wrap the signature in a structure the zkID
        // circuit cannot parse, and the failure only surfaces much later,
        // during proving.
        #expect(signInfo["sign_type"] as? String == "PKCS#1")
        #expect(signInfo["tbs_encoding"] as? String == "base64")
        #expect(signInfo["hash_algorithm"] as? String == "SHA256")
    }

    // MARK: Common body fields

    /// `time_limit` goes out as a JSON **number**. The spec's field table types
    /// it as Integer and the official JAVA sample posts
    /// `formBody.put("time_limit", 600)`. This assertion used to pin the quoted
    /// form and claim a number would be rejected — a claim with nothing behind
    /// it, and one that kept the client sending a type the spec does not
    /// describe.
    @Test func bodyCarriesChecksumAndNumericTimeLimit() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest())

        let body = try lastBody()
        #expect(body["sp_service_id"] as? String == Self.serviceID)
        #expect(body["id_num"] as? String == Self.idNumber)
        #expect(body["time_limit"] as? Int == 600)
        #expect(body["time_limit"] as? String == nil)
        #expect((body["sp_checksum"] as? String)?.count == 184)
        #expect((body["transaction_id"] as? String)?.isEmpty == false)
    }

    /// Both endpoints, because they build their bodies separately and only one
    /// of them was ever exercised here.
    @Test func appToAppAlsoSendsANumericTimeLimit() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignAppToApp(signRequest(), returnURL: callback)

        let body = try lastBody()
        #expect(body["time_limit"] as? Int == 600)
        #expect(body["time_limit"] as? String == nil)
    }

    // MARK: time_limit range

    /// The spec allows 30–600 seconds. Without a check here the request is built
    /// and posted, and the server's refusal arrives as an opaque `error_code` —
    /// *after* 身分證統一編號 has already left the device. The failure has to
    /// happen before anything is sent.
    @Test(arguments: [0, 29, 601, -1, 3600])
    func outOfRangeTimeLimitFailsBeforeAnythingIsSent(limit: Int) async {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.invalidTimeLimit(limit)) {
            _ = try await makeClient().requestSignPush(signRequest(timeLimit: limit))
        }
        await #expect(throws: TWFidOError.invalidTimeLimit(limit)) {
            _ = try await makeClient().requestSignAppToApp(signRequest(timeLimit: limit),
                                                           returnURL: callback)
        }
        #expect(TWFidOStubURLProtocol.exchanges.isEmpty)
    }

    /// The check must not narrow what the spec permits: both ends are legal.
    @Test(arguments: [30, 600])
    func boundaryTimeLimitsAreAccepted(limit: Int) async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest(timeLimit: limit))
        #expect(try lastBody()["time_limit"] as? Int == limit)
    }

    // MARK: Response caching

    /// An ATH-02 response carries `cert` — the holder's X.509 certificate, the
    /// disclosure this whole ZK route exists to avoid — and `hashed_id_num`, a
    /// stable per-person correlator. `URLSession.shared` writes through the
    /// shared, disk-backed `URLCache`, so with it as the default transport the
    /// app was one `Cache-Control` header away from leaving both in a file that
    /// outlives the flow and rides along into a device backup.
    @Test func theDefaultTransportCannotCacheAnythingToDisk() {
        let client = TWFidOClient(
            configuration: .production,
            credentials: StubCredentialProvider(
                value: SPCredentials(serviceID: Self.serviceID, aesKeyBase64: Self.aesKey)))

        #expect(client.session !== URLSession.shared)
        #expect(client.session.configuration.urlCache == nil)
        #expect(client.session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// Also asserted on the request, so the policy survives a caller that
    /// injects a session of its own.
    @Test func requestsOptOutOfTheCacheEvenOnAnInjectedSession() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest())

        let exchange = try #require(TWFidOStubURLProtocol.exchanges.last)
        #expect(exchange.request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// The AES key derives the checksum and must never itself travel.
    @Test func requestBodyNeverContainsTheAESKey() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().requestSignPush(signRequest(deviceAlias: "iPhone"))

        let exchange = try #require(TWFidOStubURLProtocol.exchanges.last)
        let raw = String(decoding: exchange.body, as: UTF8.self)
        #expect(raw.contains(Self.aesKey) == false)
    }

    @Test func resultRequestCarriesTicketIdentifiersAndNoIDNumber() async throws {
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse())
        defer { TWFidOStubURLProtocol.reset() }

        _ = try await makeClient().fetchResult(for: stubTicket)

        let body = try lastBody()
        #expect(body["transaction_id"] as? String == "TXN-1")
        #expect(body["sp_ticket_id"] as? String == "TKT-1")
        // ATH-02 is keyed on the ticket. Re-sending the ID would be an
        // avoidable disclosure and is not part of this checksum payload.
        #expect(body.keys.contains("id_num") == false)
        #expect((body["sp_checksum"] as? String)?.count == 184)
    }

    // MARK: Ticket parsing

    @Test func ticketIdentifiersAreReadFromThePayloadSegment() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        let ticket = try await makeClient().requestSignPush(signRequest())

        #expect(ticket.spTicket == stubSPTicket)
        #expect(ticket.transactionID == "TXN-1")
        #expect(ticket.spTicketID == "TKT-1")
    }

    /// The transaction ID we generate for the request is not the one we poll
    /// with — the server mints its own inside the ticket, and polling with ours
    /// fails the checksum.
    @Test func ticketTransactionIDIsNotTheRequestedOne() async throws {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        let ticket = try await makeClient().requestSignPush(signRequest())
        let sent = try #require(try lastBody()["transaction_id"] as? String)

        #expect(sent != ticket.transactionID)
    }

    @Test(arguments: malformedTickets)
    func malformedTicketsAreRejected(ticket: String) {
        #expect(throws: TWFidOError.self) {
            _ = try TWFidOClient.parseTicket(ticket)
        }
    }

    /// Dots inside the decoded claims must survive — the split happens on the
    /// encoded string, not on anything it contains.
    @Test func dotsInsideTheDecodedClaimsSurvive() throws {
        let ticket = base64URL(#"{"transaction_id":"T.1","sp_ticket_id":"K.1","op_code":"SIGN"}"#)
            + ".ZGlnZXN0"
        let parsed = try TWFidOClient.parseTicket(ticket)
        #expect(parsed.transactionID == "T.1")
        #expect(parsed.spTicketID == "K.1")
    }

    // MARK: Deep link

    @Test func deepLinkTargetsTheMOICAApp() throws {
        let url = try TWFidOClient.deepLink(ticket: stubTicket, returnURL: callback)
        #expect(url.scheme == "mobilemoica")
        #expect(url.host == "moica.moi.gov.tw")
        #expect(url.path == "/a2a/verifySign")
    }

    @Test func deepLinkCarriesTicketReturnURLAndNonce() throws {
        let url = try TWFidOClient.deepLink(ticket: stubTicket, returnURL: callback)
        let query = try queryItems(of: url)

        #expect(query["sp_ticket"] == stubSPTicket)
        let encodedReturnURL = try #require(query["rtn_url"])
        let rtnURL = try #require(Data(base64Encoded: encodedReturnURL))
        #expect(String(decoding: rtnURL, as: UTF8.self) == callback.absoluteString)
        // rtn_val comes back to us untouched, so the callback handler can use it
        // to reject a deep link it was not expecting — and it is base64url on
        // the wire, not the bare identifier.
        #expect(query["rtn_val"] == "VFhOLTE")
        #expect(query["rtn_val"] == base64URL("TXN-1"))
    }

    /// A real `transaction_id` is a UUID, and that is what makes the plain-text
    /// form so quiet: `-` is a legal base64url character and 36 characters is a
    /// legal length, so a receiver decoding the parameter as what it is defined
    /// to be gets 27 meaningless bytes back rather than an error. The value that
    /// returns on the callback then never matches the transaction being waited
    /// on, and the app-to-app leg stalls with nothing logged anywhere.
    @Test func rtnValIsBase64URLOfTheTransactionID() throws {
        let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        let ticket = TWFidOTicket(spTicket: stubSPTicket, transactionID: uuid, spTicketID: "TKT-1")

        let value = try #require(try queryItems(of: TWFidOClient.deepLink(ticket: ticket,
                                                                         returnURL: callback))["rtn_val"])
        #expect(value != uuid)
        let decoded = try #require(base64URLData(value))
        #expect(String(decoding: decoded, as: UTF8.self) == uuid)

        // The old behaviour, spelled out: decoding the raw UUID succeeds and
        // yields something that is not the transaction ID.
        let misread = try #require(base64URLData(uuid))
        #expect(misread.count == 27)
        #expect(String(data: misread, encoding: .utf8) != uuid)
    }

    /// `URLComponents.queryItems` escapes `=` but leaves `+` and `/` raw. In a
    /// base64 `rtn_url`, a surviving `+` becomes a space if the receiver
    /// form-decodes; the decode fails, and the holder signs successfully but
    /// never returns to us — with no error anywhere. Only some return URLs
    /// produce those characters, which is what makes it a latent bug rather
    /// than an obvious one.
    @Test(arguments: returnURLs)
    func deepLinkQueryEscapesEverythingOutsideTheUnreservedSet(returnURL: String) throws {
        let url = try #require(URL(string: returnURL))
        let deepLink = try TWFidOClient.deepLink(ticket: stubTicket, returnURL: url)
        let raw = try #require(
            URLComponents(url: deepLink, resolvingAgainstBaseURL: false)?.percentEncodedQuery)

        #expect(raw.contains("+") == false)
        #expect(raw.contains("/") == false)

        let decoded = try queryItems(of: deepLink)
        let encodedReturnURL = try #require(decoded["rtn_url"])
        let rtnURL = try #require(Data(base64Encoded: encodedReturnURL))
        #expect(String(decoding: rtnURL, as: UTF8.self) == url.absoluteString)
    }

    /// Guards the fixtures themselves: if these two stop producing `+` and `/`
    /// the test above still passes but has stopped testing anything.
    @Test func returnURLFixturesActuallyExerciseThePlusAndSlashCases() throws {
        let tilde = try #require(URL(string: "backuptw://fido/a~"))
        let question = try #require(URL(string: "backuptw://fido/a?"))
        #expect(Data(tilde.absoluteString.utf8).base64EncodedString().contains("+"))
        #expect(Data(question.absoluteString.utf8).base64EncodedString().contains("/"))
    }

    // MARK: Result classification

    @Test func zeroReturnsTheSignatureMaterial() async throws {
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse())
        defer { TWFidOStubURLProtocol.reset() }

        let result = try #require(await makeClient().fetchResult(for: stubTicket))
        #expect(result.cert == "Y2VydA==")
        #expect(result.signedResponse == "c2ln")
        #expect(result.hashedIDNumber == "aGFzaA==")
    }

    // MARK: idp_checksum

    /// `idp_checksum` is the only field in an ATH-02 response that says the
    /// response came from 內政部 — it is sealed with the SP AES key only 內政部
    /// and this app hold. TLS proves we reached the host we dialled; it says
    /// nothing about the body being a real MOICA outcome. Unverified, any body
    /// that reaches this method saying `{"error_code":"0","result":{…}}` is
    /// accepted as a completed 自然人憑證 signature, and the attacker's own
    /// `cert` and `signed_response` are what the rest of the app then proves
    /// over.
    @Test func resultWithoutIDPChecksumIsRejected() async throws {
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse(omitChecksum: true))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.missingResultField("idp_checksum")) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    /// Well-formed hex of the right length, but not a sealed box under our key.
    @Test func resultWithAFabricatedIDPChecksumIsRejected() async throws {
        // 184 hex characters — the exact length a real checksum has, so the
        // rejection comes from the authentication tag rather than from a shape
        // check that a slightly better forgery would walk past.
        let fabricated = String(repeating: "ab", count: 92)
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse(checksum: fabricated))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.unauthenticatedResult) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    /// Sealed correctly — correct payload, correct construction — but under a
    /// key that is not ours. This is the property that makes the field origin
    /// authentication rather than a mere integrity check: knowing the format is
    /// not enough to produce one.
    @Test func resultSealedUnderADifferentKeyIsRejected() async throws {
        let otherKey = Data(repeating: 0x5B, count: 32).base64EncodedString()
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse(key: otherKey))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.unauthenticatedResult) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    /// A genuine checksum, lifted from a different transaction and pasted onto
    /// this response. It opens under our key, so only the payload comparison
    /// catches it — which is why the client checks the plaintext instead of
    /// stopping at a successful decrypt.
    @Test func idpChecksumFromAnotherTransactionIsRejected() async throws {
        let borrowed = try idpChecksum(transactionID: "TXN-SOMEONE-ELSE", key: Self.aesKey)
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse(checksum: borrowed))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.unauthenticatedResult) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    /// The signature material swapped after the server issued its checksum.
    @Test func swappedSignatureMaterialIsRejected() async throws {
        let honest = try idpChecksum(signedResponse: "c2ln", key: Self.aesKey)
        TWFidOStubURLProtocol.install(
            respondingWith: try signResultResponse(signedResponse: "c3dhcHBlZA==", checksum: honest))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.unauthenticatedResult) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    /// The result is authenticated before any field is read out of it — a body
    /// that fails the check must not be able to reach the field-presence checks
    /// and be reported as a merely incomplete response.
    @Test func integrityIsCheckedBeforeFieldPresence() async throws {
        TWFidOStubURLProtocol.install(
            respondingWith: try signResultResponse(cert: nil,
                                                   checksum: String(repeating: "cd", count: 92)))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.unauthenticatedResult) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    /// Pending, not failed. `SPTKTID_TXNLOG_NF` in particular is a poll that
    /// beat the server's own bookkeeping; treating it as terminal aborts flows
    /// that were about to succeed.
    @Test(arguments: pendingErrorCodes)
    func pendingCodesReturnNil(code: String) async throws {
        TWFidOStubURLProtocol.install(respondingWith: envelope(errorCode: code))
        defer { TWFidOStubURLProtocol.reset() }

        let result = try await makeClient().fetchResult(for: stubTicket)
        #expect(result == nil)
    }

    @Test(arguments: terminalErrorCodes)
    func terminalCodesThrow(code: String) async {
        TWFidOStubURLProtocol.install(respondingWith: envelope(errorCode: code))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.self) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    @Test func pendingClassificationIsSpelledOutIndependently() {
        #expect(TWFidOClient.isPending(errorCode: "20002"))
        #expect(TWFidOClient.isPending(errorCode: "SPTKTID_TXNLOG_NF"))
        #expect(TWFidOClient.isPending(errorCode: "SP-API-ATH-02-SPTKTID_TXNLOG_NF"))
        #expect(TWFidOClient.isPending(errorCode: "0") == false)
        #expect(TWFidOClient.isPending(errorCode: "SPTKT_OVD") == false)
        // Prefix-before-colon, not substring: a longer code that merely
        // contains a pending one stays terminal.
        #expect(TWFidOClient.isPending(errorCode: "SPTKTID_TXNLOG_NF_OTHER") == false)
    }

    /// `error_code` is documented as a string but does not always arrive as one.
    @Test func numericErrorCodeIsAccepted() async throws {
        TWFidOStubURLProtocol.install(
            respondingWith: (200, Data(#"{"error_code":20002,"error_message":""}"#.utf8)))
        defer { TWFidOStubURLProtocol.reset() }

        let result = try await makeClient().fetchResult(for: stubTicket)
        #expect(result == nil)
    }

    /// `cert` is outside the `idp_checksum` payload, so this response passes the
    /// integrity check and still has to be rejected on its own merits.
    @Test func successWithoutCertificateIsAnError() async throws {
        TWFidOStubURLProtocol.install(
            respondingWith: try signResultResponse(hashedIDNumber: nil, cert: nil))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.missingResultField("cert")) {
            _ = try await makeClient().fetchResult(for: stubTicket)
        }
    }

    /// `hashed_id_num` is documented but nothing downstream reads it. Losing it
    /// must not discard an otherwise complete signature — and the checksum has
    /// to be checked against the response as it actually arrived, empty field
    /// and all, rather than against the shape we hoped for.
    @Test func missingHashedIDNumberDoesNotFailTheFlow() async throws {
        TWFidOStubURLProtocol.install(respondingWith: try signResultResponse(hashedIDNumber: nil))
        defer { TWFidOStubURLProtocol.reset() }

        let result = try #require(await makeClient().fetchResult(for: stubTicket))
        #expect(result.hashedIDNumber.isEmpty)
    }

    // MARK: Transport failures

    @Test func nonOKStatusThrows() async {
        TWFidOStubURLProtocol.install(respondingWith: (503, Data("service unavailable".utf8)))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.self) {
            _ = try await makeClient().requestSignPush(signRequest())
        }
    }

    @Test func serverRejectionOfATicketRequestThrows() async {
        TWFidOStubURLProtocol.install(respondingWith: envelope(errorCode: "INV_SP_CHECKSUM"))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.self) {
            _ = try await makeClient().requestSignPush(signRequest())
        }
    }

    @Test func nonJSONBodyThrows() async {
        TWFidOStubURLProtocol.install(respondingWith: (200, Data("<html>maintenance</html>".utf8)))
        defer { TWFidOStubURLProtocol.reset() }

        await #expect(throws: TWFidOError.self) {
            _ = try await makeClient().requestSignPush(signRequest())
        }
    }

    /// A fresh checkout has no key anywhere. That must fail before the ID
    /// number leaves the device, not after.
    @Test func missingCredentialsThrowBeforeAnyNetworkCall() async {
        TWFidOStubURLProtocol.install(respondingWith: ticketResponse())
        defer { TWFidOStubURLProtocol.reset() }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TWFidOStubURLProtocol.self]
        let client = TWFidOClient(configuration: .production,
                                  credentials: DevelopmentSPCredentialProvider(environment: [:]),
                                  session: URLSession(configuration: sessionConfiguration))

        await #expect(throws: SPCredentialError.notConfigured) {
            _ = try await client.requestSignPush(signRequest())
        }
        #expect(TWFidOStubURLProtocol.exchanges.isEmpty)
    }

    @Test func environmentSuppliedCredentialsAreUsed() async throws {
        let provider = DevelopmentSPCredentialProvider(environment: [
            "TWFIDO_SP_SERVICE_ID": "SP-ENV",
            "TWFIDO_SP_AES_KEY": Self.aesKey,
        ])
        let credentials = try await provider.credentials()
        #expect(credentials.serviceID == "SP-ENV")
    }

    @Test(arguments: [
        ["TWFIDO_SP_SERVICE_ID": "SP-ENV"],
        ["TWFIDO_SP_AES_KEY": "AAAA"],
        ["TWFIDO_SP_SERVICE_ID": "", "TWFIDO_SP_AES_KEY": "AAAA"],
        ["TWFIDO_SP_SERVICE_ID": "SP-ENV", "TWFIDO_SP_AES_KEY": ""],
    ])
    func partialEnvironmentIsNotUsable(environment: [String: String]) async {
        let provider = DevelopmentSPCredentialProvider(environment: environment)
        await #expect(throws: SPCredentialError.notConfigured) {
            _ = try await provider.credentials()
        }
    }

    // MARK: Helpers

    private func lastBody() throws -> [String: Any] {
        guard let exchange = TWFidOStubURLProtocol.exchanges.last else {
            throw StubError.noRequestRecorded
        }
        guard let json = try JSONSerialization.jsonObject(with: exchange.body) as? [String: Any] else {
            throw StubError.bodyIsNotAJSONObject
        }
        return json
    }

    private func queryItems(of url: URL) throws -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw StubError.noQuery
        }
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    private func ticketResponse() -> (Int, Data) {
        (200, Data(#"{"error_code":"0","error_message":"","result":{"sp_ticket":"\#(stubSPTicket)"}}"#.utf8))
    }

    /// A completed ATH-02 result. By default it carries an `idp_checksum` that
    /// genuinely authenticates its own contents under the test SP key, which is
    /// what the real server sends; every parameter exists so a test can take one
    /// property away and watch the client refuse.
    ///
    /// `omitChecksum` and an explicit `checksum` are separate knobs because
    /// "absent" and "present but wrong" are different failures, and the client
    /// reports them differently on purpose.
    private func signResultResponse(transactionID: String = "TXN-1",
                                    hashedIDNumber: String? = "aGFzaA==",
                                    signedResponse: String? = "c2ln",
                                    cert: String? = "Y2VydA==",
                                    checksum: String? = nil,
                                    omitChecksum: Bool = false,
                                    key: String = TWFidOClientTests.aesKey) throws -> (Int, Data) {
        var result: [String: String] = [:]
        result["hashed_id_num"] = hashedIDNumber
        result["signed_response"] = signedResponse
        result["cert"] = cert
        if !omitChecksum {
            // The server hashes what it actually sent, so the fixture does too:
            // an omitted field is hashed as the empty string, not skipped.
            result["idp_checksum"] = try checksum ?? idpChecksum(
                transactionID: transactionID,
                hashedIDNumber: hashedIDNumber ?? "",
                signedResponse: signedResponse ?? "",
                key: key)
        }
        let envelope: [String: Any] = ["error_code": "0", "error_message": "", "result": result]
        return (200, try JSONSerialization.data(withJSONObject: envelope))
    }

    private func envelope(errorCode: String) -> (Int, Data) {
        (200, Data(#"{"error_code":"\#(errorCode)","error_message":"stub","result":null}"#.utf8))
    }
}

// MARK: - Test doubles

private enum StubError: Error {
    case noRequestRecorded
    case bodyIsNotAJSONObject
    case noQuery
    case unusableTestKey
}

private struct StubCredentialProvider: SPCredentialProviding {
    let value: SPCredentials
    func credentials() async throws -> SPCredentials { value }
}

/// Captures the outgoing request and replays a canned response.
///
/// `URLSession` moves a request's `httpBody` into `httpBodyStream` before it
/// reaches a `URLProtocol`. Reading `httpBody` here would silently see `nil`
/// and every body assertion in this file would pass vacuously.
final class TWFidOStubURLProtocol: URLProtocol {

    struct Exchange {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    private static var responder: ((URLRequest, Data) -> (Int, Data))?
    private static var recorded: [Exchange] = []

    static func install(respondingWith response: (Int, Data)) {
        install { _, _ in response }
    }

    static func install(_ responder: @escaping (URLRequest, Data) -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        Self.responder = responder
        recorded = []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responder = nil
        recorded = []
    }

    static var exchanges: [Exchange] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)

        Self.lock.lock()
        Self.recorded.append(Exchange(request: request, body: body))
        let responder = Self.responder
        Self.lock.unlock()

        guard let responder = responder, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: StubError.noRequestRecorded)
            return
        }

        let (status, data) = responder(request, body)
        let response = HTTPURLResponse(url: url,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[..<read])
        }
        return data
    }
}
