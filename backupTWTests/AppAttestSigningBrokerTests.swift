//
//  AppAttestSigningBrokerTests.swift
//  backupTWTests
//

import CryptoKit
import DeviceCheck
import Foundation
import Testing
@testable import backupTW

private let brokerNow = Date(timeIntervalSince1970: 1_788_134_400)
private let brokerExpiry = "2026-08-31T01:00:00.000Z"
private let attestationChallenge = Data(repeating: 0x11, count: 32).base64URLEncoded
private let assertionChallenge = Data(repeating: 0x22, count: 32).base64URLEncoded
private let brokerKeyID = Data(repeating: 0x33, count: 32).base64EncodedString()

private func brokerDeepLink(transactionID: String) -> String {
    "mobilemoica://sign?rtn_val=" + Data(transactionID.utf8).base64URLEncoded
}

private actor MemoryAppAttestKeyStore: AppAttestKeyRecordStoring {
    private(set) var record: AppAttestKeyRecord?

    init(record: AppAttestKeyRecord? = nil) {
        self.record = record
    }

    func load() async throws -> AppAttestKeyRecord? { record }
    func save(_ record: AppAttestKeyRecord) async throws { self.record = record }
    func delete() async throws { record = nil }
}

private actor StubAppAttestService: AppAttestServiceProviding {
    struct Call: Equatable {
        let keyID: String
        let clientDataHash: Data
    }

    nonisolated let isSupported: Bool
    private var generatedKeys: [Result<String, Error>]
    private var attestations: [Result<Data, Error>]
    private var assertions: [Result<Data, Error>]
    private(set) var generateKeyCount = 0
    private(set) var attestationCalls: [Call] = []
    private(set) var assertionCalls: [Call] = []

    init(isSupported: Bool = true,
         generatedKeys: [Result<String, Error>] = [.success(brokerKeyID)],
         attestations: [Result<Data, Error>] = [.success(Data("attestation".utf8))],
         assertions: [Result<Data, Error>] = [.success(Data("assertion".utf8))]) {
        self.isSupported = isSupported
        self.generatedKeys = generatedKeys
        self.attestations = attestations
        self.assertions = assertions
    }

    func generateKey() async throws -> String {
        generateKeyCount += 1
        return try generatedKeys.removeFirst().get()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestationCalls.append(Call(keyID: keyID, clientDataHash: clientDataHash))
        return try attestations.removeFirst().get()
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionCalls.append(Call(keyID: keyID, clientDataHash: clientDataHash))
        return try assertions.removeFirst().get()
    }
}

private actor StubBrokerSender: SigningBrokerRequestSending {
    struct Exchange: Equatable {
        let path: String
        let body: Data
    }

    private var responses: [SigningBrokerHTTPResponse]
    private(set) var exchanges: [Exchange] = []

    init(_ responses: [SigningBrokerHTTPResponse]) {
        self.responses = responses
    }

    func send(path: String, body: Data) async throws -> SigningBrokerHTTPResponse {
        exchanges.append(Exchange(path: path, body: body))
        guard !responses.isEmpty else { throw SigningBrokerClientError.invalidResponse }
        return responses.removeFirst()
    }
}

private actor BlockingBrokerSender: SigningBrokerRequestSending {
    private var responses: [SigningBrokerHTTPResponse]
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var exchangeCount = 0

    init(_ responses: [SigningBrokerHTTPResponse]) {
        self.responses = responses
    }

    func send(path: String, body: Data) async throws -> SigningBrokerHTTPResponse {
        exchangeCount += 1
        if exchangeCount == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return responses.removeFirst()
    }

    func releaseFirstRequest() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

@Suite(.serialized)
struct AppAttestSigningBrokerTests {
    @Test func registersOnceThenSignsAndPollsWithCanonicalAssertions() async throws {
        let appAttest = StubAppAttestService(
            assertions: [.success(Data("start-assertion".utf8)),
                         .success(Data("poll-assertion".utf8))])
        let store = MemoryAppAttestKeyStore()
        let sender = StubBrokerSender([
            response(["challenge": attestationChallenge, "expires_at": brokerExpiry]),
            response(["registered": true], status: 201),
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "session_token": "bst1.1.opaque",
                "deep_link": brokerDeepLink(transactionID: "transaction-123"),
                "expires_at": brokerExpiry,
                "reused": false
            ]),
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "status": "complete",
                "certificate": Data("certificate".utf8).base64EncodedString(),
                "signed_response": Data("signature".utf8).base64EncodedString()
            ])
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        let start = try await transport.start(
            idNumber: "A123456789",
            intent: SigningBrokerIntent(type: .zkHoldingProofV1, tbs: nil, consent: nil),
            timeLimit: 600)
        #expect(start.sessionToken == "bst1.1.opaque")
        #expect(start.transactionID == "transaction-123")

        let result = try #require(try await transport.poll(sessionToken: start.sessionToken))
        #expect(Data(base64Encoded: result.cert) == Data("certificate".utf8))
        #expect(Data(base64Encoded: result.signedResponse) == Data("signature".utf8))
        #expect(result.hashedIDNumber.isEmpty)

        #expect(await appAttest.generateKeyCount == 1)
        #expect(await appAttest.attestationCalls.count == 1)
        #expect(await appAttest.assertionCalls.count == 2)
        let saved = try #require(await store.record)
        #expect(saved.registered)
        #expect(saved.pendingAttestationObject == nil)

        let exchanges = await sender.exchanges
        #expect(exchanges.map(\.path) == [
            "/v1/attest/challenge", "/v1/attest/register",
            "/v1/assertions/challenge", "/v1/signatures/start",
            "/v1/assertions/challenge", "/v1/signatures/poll"
        ])
        let startBody = try json(exchanges[3].body)
        #expect(startBody["request_id"] as? String == "018f6c7e-1234-7123-8123-123456789abc")
        #expect(startBody["id_number"] as? String == "A123456789")
        #expect((startBody["intent"] as? [String: Any])?["type"] as? String == "zk_holding_proof_v1")

        let business: [String: Any] = [
            "id_number": "A123456789",
            "intent": ["type": "zk_holding_proof_v1"],
            "key_id": brokerKeyID
        ]
        let businessHash = SHA256.hash(data: try AppAttestSigningBrokerTransport.canonicalJSON(business)).hex
        let expectedClientData = try AppAttestSigningBrokerTransport.canonicalJSON([
            "api_version": "v1",
            "body_sha256": businessHash,
            "challenge": assertionChallenge,
            "method": "POST",
            "path": "/v1/signatures/start",
            "request_id": "018f6c7e-1234-7123-8123-123456789abc"
        ])
        let assertionCall = try #require(await appAttest.assertionCalls.first)
        #expect(assertionCall.clientDataHash == Data(SHA256.hash(data: expectedClientData)))
    }

    @Test func retriesAppleServerUnavailableWithTheSameKeyChallengeAndHash() async throws {
        let unavailable = NSError(domain: DCError.errorDomain,
                                  code: DCError.serverUnavailable.rawValue)
        let appAttest = StubAppAttestService(
            attestations: [.failure(unavailable), .success(Data("attestation".utf8))])
        let store = MemoryAppAttestKeyStore()
        let sender = StubBrokerSender([
            response(["challenge": attestationChallenge, "expires_at": brokerExpiry]),
            response(["registered": true], status: 201),
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "session_token": "bst1.1.retry",
                "deep_link": brokerDeepLink(transactionID: "retry-transaction"),
                "expires_at": brokerExpiry,
                "reused": false
            ])
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)
        let intent = SigningBrokerIntent(type: .zkHoldingProofV1, tbs: nil, consent: nil)

        await #expect(throws: SigningBrokerClientError.appAttestUnavailable) {
            _ = try await transport.start(idNumber: "A123456789", intent: intent, timeLimit: 600)
        }
        let pending = try #require(await store.record)
        #expect(pending.pendingChallenge == attestationChallenge)
        #expect(!pending.registered)

        let start = try await transport.start(idNumber: "A123456789", intent: intent, timeLimit: 600)
        #expect(start.sessionToken == "bst1.1.retry")
        #expect(await appAttest.generateKeyCount == 1)
        let calls = await appAttest.attestationCalls
        #expect(calls.count == 2)
        #expect(calls[0] == calls[1])
        #expect((await sender.exchanges).filter { $0.path == "/v1/attest/challenge" }.count == 1)
    }

    @Test func transientRegistrationFailureKeepsThePendingAttestationForRetry() async throws {
        let appAttest = StubAppAttestService()
        let store = MemoryAppAttestKeyStore()
        let sender = StubBrokerSender([
            response(["challenge": attestationChallenge, "expires_at": brokerExpiry]),
            response([
                "error": "internal_error",
                "message": "temporary storage failure",
                "request_id": "server-request",
                "retryable": false
            ], status: 500),
            response(["registered": true]),
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "session_token": "bst1.1.registration-retry",
                "deep_link": brokerDeepLink(transactionID: "registration-retry"),
                "expires_at": brokerExpiry,
                "reused": false
            ])
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)
        let intent = SigningBrokerIntent(type: .zkHoldingProofV1, tbs: nil, consent: nil)

        await #expect(throws: SigningBrokerClientError.server(
            code: "internal_error", retryable: false)) {
            _ = try await transport.start(idNumber: "A123456789", intent: intent, timeLimit: 600)
        }
        let pending = try #require(await store.record)
        #expect(pending.pendingAttestationObject == Data("attestation".utf8))

        let start = try await transport.start(
            idNumber: "A123456789", intent: intent, timeLimit: 600)
        #expect(start.sessionToken == "bst1.1.registration-retry")
        #expect(await appAttest.generateKeyCount == 1)
        #expect(await appAttest.attestationCalls.count == 1)
        #expect((await sender.exchanges).filter { $0.path == "/v1/attest/challenge" }.count == 1)
    }

    @Test func invalidAssertionKeyIsForgottenAndRegisteredAgainOnce() async throws {
        let oldKeyID = Data(repeating: 0x44, count: 32).base64EncodedString()
        let invalidKey = NSError(domain: DCError.errorDomain, code: DCError.invalidKey.rawValue)
        let appAttest = StubAppAttestService(
            generatedKeys: [.success(brokerKeyID)],
            assertions: [.failure(invalidKey), .success(Data("new-assertion".utf8))])
        let store = MemoryAppAttestKeyStore(record: AppAttestKeyRecord(
            keyID: oldKeyID,
            scope: "test-scope",
            registered: true,
            pendingChallenge: nil,
            pendingChallengeExpiresAt: nil,
            pendingAttestationObject: nil))
        let sender = StubBrokerSender([
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response(["challenge": attestationChallenge, "expires_at": brokerExpiry]),
            response(["registered": true], status: 201),
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "session_token": "bst1.1.recovered",
                "deep_link": brokerDeepLink(transactionID: "recovered-transaction"),
                "expires_at": brokerExpiry,
                "reused": false
            ])
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        let start = try await transport.start(
            idNumber: "A123456789",
            intent: SigningBrokerIntent(type: .zkHoldingProofV1, tbs: nil, consent: nil),
            timeLimit: 600)
        #expect(start.sessionToken == "bst1.1.recovered")
        #expect((try #require(await store.record)).keyID == brokerKeyID)
        #expect((await appAttest.assertionCalls).map(\.keyID) == [oldKeyID, brokerKeyID])
    }

    @Test func unsupportedDeviceFailsBeforeAnyNetworkOrKeyWork() async throws {
        let appAttest = StubAppAttestService(isSupported: false, generatedKeys: [])
        let store = MemoryAppAttestKeyStore()
        let sender = StubBrokerSender([])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        await #expect(throws: SigningBrokerClientError.appAttestUnsupported) {
            _ = try await transport.start(
                idNumber: "A123456789",
                intent: SigningBrokerIntent(type: .zkHoldingProofV1, tbs: nil, consent: nil),
                timeLimit: 600)
        }
        #expect(await appAttest.generateKeyCount == 0)
        #expect(await sender.exchanges.isEmpty)
        #expect(await store.record == nil)
    }

    @Test func replayRejectionFailsClosedWithoutReplacingTheRegisteredKey() async throws {
        let record = AppAttestKeyRecord(keyID: brokerKeyID,
                                        scope: "test-scope",
                                        registered: true,
                                        pendingChallenge: nil,
                                        pendingChallengeExpiresAt: nil,
                                        pendingAttestationObject: nil)
        let store = MemoryAppAttestKeyStore(record: record)
        let appAttest = StubAppAttestService(assertions: [.success(Data("assertion".utf8))])
        let sender = StubBrokerSender([
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "error": "replay_detected",
                "message": "rejected",
                "request_id": "server-request",
                "retryable": false
            ], status: 409)
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        await #expect(throws: SigningBrokerClientError.server(
            code: "replay_detected", retryable: false)) {
            _ = try await transport.poll(sessionToken: "bst1.1.replayed")
        }
        #expect((try #require(await store.record)).keyID == brokerKeyID)
        #expect(await appAttest.generateKeyCount == 0)
    }

    @Test func malformedSessionTokenFailsBeforeAssertionOrNetworkWork() async throws {
        let record = AppAttestKeyRecord(keyID: brokerKeyID,
                                        scope: "test-scope",
                                        registered: true,
                                        pendingChallenge: nil,
                                        pendingChallengeExpiresAt: nil,
                                        pendingAttestationObject: nil)
        let store = MemoryAppAttestKeyStore(record: record)
        let appAttest = StubAppAttestService(assertions: [])
        let sender = StubBrokerSender([])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        await #expect(throws: SigningBrokerClientError.invalidResponse) {
            _ = try await transport.poll(sessionToken: "not-a-broker-token")
        }
        #expect(await appAttest.assertionCalls.isEmpty)
        #expect(await sender.exchanges.isEmpty)
    }

    @Test func responseWithoutNoStoreIsRejectedBeforeGeneratingAnAssertion() async throws {
        let record = AppAttestKeyRecord(keyID: brokerKeyID,
                                        scope: "test-scope",
                                        registered: true,
                                        pendingChallenge: nil,
                                        pendingChallengeExpiresAt: nil,
                                        pendingAttestationObject: nil)
        let store = MemoryAppAttestKeyStore(record: record)
        let appAttest = StubAppAttestService(assertions: [])
        let sender = StubBrokerSender([
            SigningBrokerHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [
                    "challenge": assertionChallenge,
                    "expires_at": brokerExpiry
                ]))
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        await #expect(throws: SigningBrokerClientError.invalidResponse) {
            _ = try await transport.poll(sessionToken: "bst1.1.pending")
        }
        #expect(await appAttest.assertionCalls.isEmpty)
    }

    @Test func completedPollRejectsMalformedCertificateBase64() async throws {
        let record = AppAttestKeyRecord(keyID: brokerKeyID,
                                        scope: "test-scope",
                                        registered: true,
                                        pendingChallenge: nil,
                                        pendingChallengeExpiresAt: nil,
                                        pendingAttestationObject: nil)
        let store = MemoryAppAttestKeyStore(record: record)
        let appAttest = StubAppAttestService()
        let sender = StubBrokerSender([
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "status": "complete",
                "certificate": "%%%not-base64%%%",
                "signed_response": Data("signature".utf8).base64EncodedString()
            ])
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        await #expect(throws: SigningBrokerClientError.invalidResponse) {
            _ = try await transport.poll(sessionToken: "bst1.1.complete")
        }
    }

    @Test func brokerDeepLinkRequiresABase64URLReturnTransaction() async throws {
        let record = AppAttestKeyRecord(keyID: brokerKeyID,
                                        scope: "test-scope",
                                        registered: true,
                                        pendingChallenge: nil,
                                        pendingChallengeExpiresAt: nil,
                                        pendingAttestationObject: nil)
        let store = MemoryAppAttestKeyStore(record: record)
        let appAttest = StubAppAttestService()
        let sender = StubBrokerSender([
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response([
                "session_token": "bst1.1.bad-return-value",
                "deep_link": "mobilemoica://sign?rtn_val=transaction-123",
                "expires_at": brokerExpiry,
                "reused": false
            ])
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        await #expect(throws: SigningBrokerClientError.invalidResponse) {
            _ = try await transport.start(
                idNumber: "A123456789",
                intent: SigningBrokerIntent(type: .zkHoldingProofV1, tbs: nil, consent: nil),
                timeLimit: 600)
        }
    }

    @Test func concurrentAssertionsAreQueuedAndACancelledWaiterNeverReachesNetwork() async throws {
        let record = AppAttestKeyRecord(keyID: brokerKeyID,
                                        scope: "test-scope",
                                        registered: true,
                                        pendingChallenge: nil,
                                        pendingChallengeExpiresAt: nil,
                                        pendingAttestationObject: nil)
        let store = MemoryAppAttestKeyStore(record: record)
        let appAttest = StubAppAttestService(assertions: [.success(Data("assertion".utf8))])
        let sender = BlockingBrokerSender([
            response(["challenge": assertionChallenge, "expires_at": brokerExpiry]),
            response(["status": "pending"])
        ])
        let transport = try makeTransport(appAttest: appAttest, store: store, sender: sender)

        let first = Task { try await transport.poll(sessionToken: "bst1.1.first") }
        while await sender.exchangeCount == 0 { await Task.yield() }
        let second = Task { try await transport.poll(sessionToken: "bst1.1.second") }
        for _ in 0..<20 { await Task.yield() }
        #expect(await sender.exchangeCount == 1)
        second.cancel()
        await sender.releaseFirstRequest()
        #expect(try await first.value == nil)
        do {
            _ = try await second.value
            Issue.record("A cancelled queued assertion unexpectedly ran")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await sender.exchangeCount == 2)
        #expect(await appAttest.assertionCalls.count == 1)
    }

    @Test func endpointConfigurationRejectsNonHTTPSCredentialsAndNonRootURLs() {
        #expect(throws: SigningBrokerClientError.configurationMissing) {
            _ = try SigningBrokerEndpointConfiguration(baseURL: URL(string: "http://signing.bonds.tw")!)
        }
        #expect(throws: SigningBrokerClientError.configurationMissing) {
            _ = try SigningBrokerEndpointConfiguration(baseURL: URL(string: "https://user@signing.bonds.tw")!)
        }
        #expect(throws: SigningBrokerClientError.configurationMissing) {
            _ = try SigningBrokerEndpointConfiguration(baseURL: URL(string: "https://signing.bonds.tw/api")!)
        }
        #expect(throws: SigningBrokerClientError.configurationMissing) {
            _ = try SigningBrokerEndpointConfiguration(baseURL: URL(string: "https://signing.bonds.tw:8443")!)
        }
    }

    @Test func distributionAssemblyAcceptsOnlyAReviewedCodeSignedEndpoint() throws {
        let allowed = try configurationBundle(baseURL: "https://signing-uat.mashbean.net")
        defer { try? FileManager.default.removeItem(at: allowed.directory) }
        #expect(SigningBrokerSessionAssembly.isConfigured(bundle: allowed.bundle))
        #expect(SigningBrokerSessionAssembly.make(bundle: allowed.bundle) != nil)

        let arbitrary = try configurationBundle(baseURL: "https://signing.attacker.example")
        defer { try? FileManager.default.removeItem(at: arbitrary.directory) }
        #expect(!SigningBrokerSessionAssembly.isConfigured(bundle: arbitrary.bundle))
        #expect(SigningBrokerSessionAssembly.make(bundle: arbitrary.bundle) == nil)
    }

    @Test func debugAppDoesNotSelectTheDistributionEndpoint() {
        #expect(!SigningBrokerSessionAssembly.isConfigured(bundle: .main))
        #expect(SigningBrokerSessionAssembly.make(bundle: .main) == nil)
    }

    @Test func keyRecordRoundTripsInThisDeviceOnlyKeychainStorage() async throws {
        let store = KeychainAppAttestKeyRecordStore(
            service: "tw.bonds.backupTW.tests.app-attest",
            account: UUID().uuidString)
        try await store.delete()
        let expected = AppAttestKeyRecord(
            keyID: brokerKeyID,
            scope: "test-scope",
            registered: false,
            pendingChallenge: attestationChallenge,
            pendingChallengeExpiresAt: brokerNow.addingTimeInterval(300),
            pendingAttestationObject: Data("pending-attestation".utf8))
        try await store.save(expected)
        #expect(try await store.load() == expected)
        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test func onlyRetryableBrokerFailuresAreTransientDuringPoll() {
        #expect(isTransientSignPollFailure(SigningBrokerClientError.appAttestUnavailable))
        #expect(isTransientSignPollFailure(SigningBrokerClientError.invalidResponse))
        #expect(isTransientSignPollFailure(
            SigningBrokerClientError.server(code: "signing_unavailable", retryable: true)))
        #expect(!isTransientSignPollFailure(
            SigningBrokerClientError.server(code: "session_expired", retryable: false)))
        #expect(!isTransientSignPollFailure(SigningBrokerClientError.appAttestUnsupported))
    }

    private func makeTransport(appAttest: StubAppAttestService,
                               store: MemoryAppAttestKeyStore,
                               sender: any SigningBrokerRequestSending) throws
        -> AppAttestSigningBrokerTransport {
        let configuration = try SigningBrokerEndpointConfiguration(
            baseURL: URL(string: "https://broker.test")!,
            keyScope: "test-scope")
        return AppAttestSigningBrokerTransport(
            configuration: configuration,
            appAttest: appAttest,
            keyStore: store,
            sender: sender,
            now: { brokerNow },
            makeRequestID: { "018f6c7e-1234-7123-8123-123456789abc" })
    }

    private func configurationBundle(baseURL: String) throws -> (bundle: Bundle, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "tw.bonds.backupTW.tests.signing-broker",
            "CFBundlePackageType": "BNDL",
            "BondsSigningBrokerBaseURL": baseURL
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"), options: .atomic)
        return (try #require(Bundle(url: directory)), directory)
    }

    private func response(_ object: [String: Any],
                          status: Int = 200) -> SigningBrokerHTTPResponse {
        SigningBrokerHTTPResponse(
            statusCode: status,
            headers: [
                "cache-control": "no-store",
                "content-type": "application/json; charset=utf-8"
            ],
            body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
