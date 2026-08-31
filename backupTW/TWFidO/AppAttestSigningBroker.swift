//
//  AppAttestSigningBroker.swift
//  backupTW
//
//  App Attest registration, canonical assertions, and the fixed signing-broker
//  HTTP contract. No MOI service credential or generic signing target exists
//  on this side of the boundary.
//

import CryptoKit
import DeviceCheck
import Foundation
import Security

enum SigningBrokerClientError: Error, Equatable, Sendable {
    case configurationMissing
    case appAttestUnsupported
    case appAttestUnavailable
    case appAttestKeyInvalid
    case invalidTimeLimit(Int)
    case invalidResponse
    case server(code: String, retryable: Bool)
}

extension SigningBrokerClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTimeLimit:
            return NSLocalizedString("The signing request has an invalid time limit.", comment: "signing broker")
        case .server(let code, _):
            if code == "rate_limited" {
                return NSLocalizedString("Too many signing requests were made. Try again later.", comment: "signing broker")
            }
            return NSLocalizedString("The backend signing service could not complete the request.", comment: "signing broker")
        case .configurationMissing, .appAttestUnsupported, .appAttestUnavailable,
             .appAttestKeyInvalid, .invalidResponse:
            return NSLocalizedString(
                "This device currently cannot use features that require backend signing. Try again later.",
                comment: "signing broker fail-closed message")
        }
    }
}

struct SigningBrokerEndpointConfiguration: Equatable, Sendable {
    let baseURL: URL
    let keyScope: String

    init(baseURL: URL, keyScope: String? = nil) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else {
            throw SigningBrokerClientError.configurationMissing
        }
        self.baseURL = baseURL
        self.keyScope = keyScope ?? baseURL.absoluteString
    }

    /// Runtime configuration remains absent until a reviewed endpoint is
    /// deployed. A code-signed Info.plist can select one of the reviewed hosts;
    /// an arbitrary URL can never turn this app into a client for another
    /// signing service.
    static func fromBundle(_ bundle: Bundle = .main) -> Self? {
        guard let value = bundle.object(forInfoDictionaryKey: "BondsSigningBrokerBaseURL") as? String,
              let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "signing.bonds.tw" || host == "signing-uat.bonds.tw" ||
                host == "signing-dev.bonds.tw" ||
                host == "signing-uat.mashbean.net" else {
            return nil
        }
        return try? Self(baseURL: url)
    }
}

protocol AppAttestServiceProviding: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

struct SystemAppAttestService: AppAttestServiceProviding, @unchecked Sendable {
    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

struct AppAttestKeyRecord: Codable, Equatable, Sendable {
    let keyID: String
    let scope: String
    var registered: Bool
    var pendingChallenge: String?
    var pendingChallengeExpiresAt: Date?
    var pendingAttestationObject: Data?
}

protocol AppAttestKeyRecordStoring: Sendable {
    func load() async throws -> AppAttestKeyRecord?
    func save(_ record: AppAttestKeyRecord) async throws
    func delete() async throws
}

struct KeychainAppAttestKeyRecordStore: AppAttestKeyRecordStoring, Sendable {
    static let defaultService = "tw.bonds.backupTW.app-attest"
    static let defaultAccount = "signing-broker-key-v1"

    private let service: String
    private let account: String

    init(service: String = Self.defaultService,
         account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    func load() async throws -> AppAttestKeyRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let record = try? decoder.decode(AppAttestKeyRecord.self, from: data) else {
            throw SigningBrokerClientError.appAttestUnavailable
        }
        return record
    }

    func save(_ record: AppAttestKeyRecord) async throws {
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw SigningBrokerClientError.appAttestUnavailable
        }
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SigningBrokerClientError.appAttestUnavailable
        }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw SigningBrokerClientError.appAttestUnavailable
        }
    }

    func delete() async throws {
        try Self.deleteRecord(service: service, account: account)
    }

    /// Synchronous because `LocalDataEraser` is a synchronous, exhaustive sweep
    /// over Keychain and filesystem locations. Forgetting the local key ID makes
    /// the next broker use generate a new App Attest key; Apple exposes no API
    /// for deleting the service-side private key itself.
    static func deleteDefaultRecord() throws {
        try deleteRecord(service: defaultService, account: defaultAccount)
    }

    static func deleteRecord(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SigningBrokerClientError.appAttestUnavailable
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct SigningBrokerHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

protocol SigningBrokerRequestSending: Sendable {
    func send(path: String, body: Data) async throws -> SigningBrokerHTTPResponse
}

private final class SigningBrokerNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct SigningBrokerURLSessionSender: SigningBrokerRequestSending, @unchecked Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(
            configuration: configuration,
            delegate: SigningBrokerNoRedirectDelegate(),
            delegateQueue: nil)
    }

    func send(path: String, body: Data) async throws -> SigningBrokerHTTPResponse {
        let component = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(component)
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SigningBrokerClientError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key.lowercased()] = String(describing: value)
        }
        return SigningBrokerHTTPResponse(statusCode: http.statusCode,
                                         headers: headers,
                                         body: data)
    }
}

private actor SigningBrokerOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var held = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !held {
            held = true
            do {
                try Task.checkCancellation()
            } catch {
                release()
                throw error
            }
            return
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        guard granted else { throw CancellationError() }
        do {
            try Task.checkCancellation()
        } catch {
            // Ownership may have transferred to this waiter just before its
            // cancellation became observable. Pass the gate on instead of
            // leaving every later signing request permanently blocked.
            release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

actor AppAttestSigningBrokerTransport: SigningBrokerTransport {
    private static let maximumResponseBytes = 256 * 1024
    private static let registrationPath = "/v1/attest/register"
    private static let attestationChallengePath = "/v1/attest/challenge"
    private static let assertionChallengePath = "/v1/assertions/challenge"
    private static let assertionVerificationPath = "/v1/assertions/verify"
    private static let startPath = "/v1/signatures/start"
    private static let pollPath = "/v1/signatures/poll"

    private let configuration: SigningBrokerEndpointConfiguration
    private let appAttest: any AppAttestServiceProviding
    private let keyStore: any AppAttestKeyRecordStoring
    private let sender: any SigningBrokerRequestSending
    private let now: @Sendable () -> Date
    private let makeRequestID: @Sendable () -> String
    private let gate = SigningBrokerOperationGate()

    init(configuration: SigningBrokerEndpointConfiguration,
         appAttest: any AppAttestServiceProviding = SystemAppAttestService(),
         keyStore: any AppAttestKeyRecordStoring = KeychainAppAttestKeyRecordStore(),
         sender: (any SigningBrokerRequestSending)? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.configuration = configuration
        self.appAttest = appAttest
        self.keyStore = keyStore
        self.sender = sender ?? SigningBrokerURLSessionSender(baseURL: configuration.baseURL)
        self.now = now
        self.makeRequestID = makeRequestID
    }

    func start(idNumber: String,
               intent: SigningBrokerIntent,
               timeLimit: Int) async throws -> SigningBrokerStart {
        guard TWFidOClient.allowedTimeLimits.contains(timeLimit) else {
            throw SigningBrokerClientError.invalidTimeLimit(timeLimit)
        }
        let requestID = makeRequestID()
        try await gate.acquire()
        do {
            let result = try await startSerialized(idNumber: idNumber,
                                                   intent: intent,
                                                   requestID: requestID)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    func poll(sessionToken: String) async throws -> TWFidOSignResult? {
        guard Self.validSessionToken(sessionToken) else {
            throw SigningBrokerClientError.invalidResponse
        }
        try await gate.acquire()
        do {
            let result = try await pollSerialized(sessionToken: sessionToken)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Exercises registration, a fresh server challenge, the Apple-generated
    /// assertion and the server-side monotonic counter. The fixed request shape
    /// cannot carry an ID number, intent, signature payload or session token.
    func verifyAppAttestConnection() async throws {
        try await gate.acquire()
        do {
            try await withKeyRecovery { keyID in
                let business: [String: Any] = ["key_id": keyID]
                let challenge = try await assertionChallenge(keyID: keyID)
                let clientData = try Self.canonicalJSON([
                    "api_version": "v1",
                    "body_sha256": Self.sha256Hex(try Self.canonicalJSON(business)),
                    "challenge": challenge.challenge,
                    "method": "POST",
                    "path": Self.assertionVerificationPath
                ])
                let assertion = try await assertionObject(keyID: keyID, clientData: clientData)
                let response: VerificationResponse = try await post(
                    path: Self.assertionVerificationPath,
                    body: [
                        "assertion_object": assertion.base64EncodedString(),
                        "challenge": challenge.challenge,
                        "key_id": keyID
                    ])
                guard response.verified else {
                    throw SigningBrokerClientError.invalidResponse
                }
            }
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func startSerialized(idNumber: String,
                                 intent: SigningBrokerIntent,
                                 requestID: String) async throws -> SigningBrokerStart {
        try await withKeyRecovery { keyID in
            let intentValue = try Self.intentValue(intent)
            let business: [String: Any] = [
                "id_number": idNumber,
                "intent": intentValue,
                "key_id": keyID
            ]
            let challenge = try await assertionChallenge(keyID: keyID)
            let clientData = try Self.canonicalJSON([
                "api_version": "v1",
                "body_sha256": Self.sha256Hex(try Self.canonicalJSON(business)),
                "challenge": challenge.challenge,
                "method": "POST",
                "path": Self.startPath,
                "request_id": requestID
            ])
            let assertion = try await assertionObject(keyID: keyID, clientData: clientData)
            var body = business
            body["request_id"] = requestID
            body["challenge"] = challenge.challenge
            body["assertion_object"] = assertion.base64EncodedString()
            let response: StartResponse = try await post(path: Self.startPath, body: body)
            guard Self.validSessionToken(response.sessionToken),
                  let deepLink = URL(string: response.deepLink),
                  let transactionID = Self.transactionID(from: deepLink),
                  let expiresAt = Self.parseDate(response.expiresAt),
                  expiresAt > now() else {
                throw SigningBrokerClientError.invalidResponse
            }
            return SigningBrokerStart(sessionToken: response.sessionToken,
                                      transactionID: transactionID,
                                      deepLink: deepLink,
                                      expiresAt: expiresAt)
        }
    }

    private func pollSerialized(sessionToken: String) async throws -> TWFidOSignResult? {
        try await withKeyRecovery { keyID in
            let business: [String: Any] = [
                "key_id": keyID,
                "session_token": sessionToken
            ]
            let challenge = try await assertionChallenge(keyID: keyID)
            let clientData = try Self.canonicalJSON([
                "api_version": "v1",
                "body_sha256": Self.sha256Hex(try Self.canonicalJSON(business)),
                "challenge": challenge.challenge,
                "method": "POST",
                "path": Self.pollPath
            ])
            let assertion = try await assertionObject(keyID: keyID, clientData: clientData)
            var body = business
            body["challenge"] = challenge.challenge
            body["assertion_object"] = assertion.base64EncodedString()
            let response: PollResponse = try await post(path: Self.pollPath, body: body)
            if response.status == "pending" {
                guard response.certificate == nil, response.signedResponse == nil else {
                    throw SigningBrokerClientError.invalidResponse
                }
                return nil
            }
            guard response.status == "complete",
                  let certificate = response.certificate,
                  let signedResponse = response.signedResponse,
                  Self.validBase64(certificate, maximumBytes: 64 * 1024),
                  Self.validBase64(signedResponse, maximumBytes: 16 * 1024) else {
                throw SigningBrokerClientError.invalidResponse
            }
            return TWFidOSignResult(cert: certificate,
                                    signedResponse: signedResponse,
                                    hashedIDNumber: "")
        }
    }

    private func withKeyRecovery<T: Sendable>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        var didReset = false
        while true {
            let keyID = try await ensureRegisteredKey()
            do {
                return try await operation(keyID)
            } catch let error as SigningBrokerClientError where !didReset && Self.requiresKeyReset(error) {
                try await keyStore.delete()
                didReset = true
            }
        }
    }

    private func ensureRegisteredKey() async throws -> String {
        guard appAttest.isSupported else {
            throw SigningBrokerClientError.appAttestUnsupported
        }
        var record = try await loadOrGenerateRecord()
        if record.registered { return record.keyID }

        if let expiry = record.pendingChallengeExpiresAt, expiry <= now() {
            try await keyStore.delete()
            record = try await generateRecord()
        }

        if record.pendingChallenge == nil {
            let challenge: ChallengeResponse = try await post(path: Self.attestationChallengePath, body: [:])
            guard let expiresAt = Self.parseDate(challenge.expiresAt),
                  expiresAt > now(),
                  Self.challengeData(challenge.challenge) != nil else {
                throw SigningBrokerClientError.invalidResponse
            }
            record.pendingChallenge = challenge.challenge
            record.pendingChallengeExpiresAt = expiresAt
            try await keyStore.save(record)
        }

        guard let challenge = record.pendingChallenge,
              let challengeData = Self.challengeData(challenge) else {
            throw SigningBrokerClientError.invalidResponse
        }
        if record.pendingAttestationObject == nil {
            do {
                record.pendingAttestationObject = try await appAttest.attestKey(
                    record.keyID,
                    clientDataHash: Data(SHA256.hash(data: challengeData)))
                try await keyStore.save(record)
            } catch {
                if Self.isDeviceCheck(error, code: .serverUnavailable) {
                    // Keep the key, challenge and hash together. Apple requires
                    // these exact inputs on the next retry.
                    throw SigningBrokerClientError.appAttestUnavailable
                }
                try await keyStore.delete()
                throw SigningBrokerClientError.appAttestKeyInvalid
            }
        }

        guard let attestation = record.pendingAttestationObject else {
            throw SigningBrokerClientError.invalidResponse
        }
        do {
            let response: RegistrationResponse = try await post(path: Self.registrationPath, body: [
                "attestation_object": attestation.base64EncodedString(),
                "challenge": challenge,
                "key_id": record.keyID
            ])
            guard response.registered else { throw SigningBrokerClientError.invalidResponse }
        } catch let error as SigningBrokerClientError {
            if case .server(let code, _) = error, Self.requiresRegistrationReset(code) {
                try await keyStore.delete()
            }
            throw error
        }

        record.registered = true
        record.pendingChallenge = nil
        record.pendingChallengeExpiresAt = nil
        record.pendingAttestationObject = nil
        try await keyStore.save(record)
        return record.keyID
    }

    private func loadOrGenerateRecord() async throws -> AppAttestKeyRecord {
        if let record = try await keyStore.load() {
            guard record.scope == configuration.keyScope,
                  Self.validKeyID(record.keyID) else {
                try await keyStore.delete()
                return try await generateRecord()
            }
            return record
        }
        return try await generateRecord()
    }

    private func generateRecord() async throws -> AppAttestKeyRecord {
        let keyID: String
        do {
            keyID = try await appAttest.generateKey()
        } catch {
            throw SigningBrokerClientError.appAttestUnavailable
        }
        guard Self.validKeyID(keyID) else {
            throw SigningBrokerClientError.appAttestKeyInvalid
        }
        let record = AppAttestKeyRecord(keyID: keyID,
                                        scope: configuration.keyScope,
                                        registered: false,
                                        pendingChallenge: nil,
                                        pendingChallengeExpiresAt: nil,
                                        pendingAttestationObject: nil)
        try await keyStore.save(record)
        return record
    }

    private func assertionChallenge(keyID: String) async throws -> ChallengeResponse {
        let challenge: ChallengeResponse = try await post(
            path: Self.assertionChallengePath,
            body: ["key_id": keyID])
        guard let expiresAt = Self.parseDate(challenge.expiresAt),
              expiresAt > now(),
              Self.challengeData(challenge.challenge) != nil else {
            throw SigningBrokerClientError.invalidResponse
        }
        return challenge
    }

    private func assertionObject(keyID: String, clientData: Data) async throws -> Data {
        do {
            return try await appAttest.generateAssertion(
                keyID,
                clientDataHash: Data(SHA256.hash(data: clientData)))
        } catch {
            if Self.isDeviceCheck(error, code: .invalidKey) {
                throw SigningBrokerClientError.appAttestKeyInvalid
            }
            throw SigningBrokerClientError.appAttestUnavailable
        }
    }

    private func post<Response: Decodable>(path: String,
                                            body: [String: Any]) async throws -> Response {
        let encoded = try Self.canonicalJSON(body)
        let response = try await sender.send(path: path, body: encoded)
        guard response.body.count <= Self.maximumResponseBytes,
              response.headers["cache-control"]?.lowercased().contains("no-store") == true,
              response.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            throw SigningBrokerClientError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            guard let server = try? JSONDecoder().decode(ServerErrorResponse.self, from: response.body),
                  !server.error.isEmpty, server.error.count <= 64 else {
                throw SigningBrokerClientError.invalidResponse
            }
            throw SigningBrokerClientError.server(code: server.error, retryable: server.retryable)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw SigningBrokerClientError.invalidResponse
        }
    }

    static func canonicalJSON(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw SigningBrokerClientError.invalidResponse
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw SigningBrokerClientError.invalidResponse
        }
    }

    static func intentValue(_ intent: SigningBrokerIntent) throws -> [String: Any] {
        switch intent.type {
        case .zkHoldingProofV1:
            guard intent.tbs == nil, intent.consent == nil else {
                throw SigningBrokerClientError.invalidResponse
            }
            return ["type": intent.type.rawValue]
        case .nationalIDCredentialV1:
            guard let tbs = intent.tbs, intent.consent == nil else {
                throw SigningBrokerClientError.invalidResponse
            }
            return ["tbs": tbs, "type": intent.type.rawValue]
        case .officialDocumentInboxConsentV1:
            guard intent.tbs == nil, let consent = intent.consent else {
                throw SigningBrokerClientError.invalidResponse
            }
            return [
                "created_at_unix_ms": consent.createdAtUnixMilliseconds,
                "nonce": consent.nonce,
                "scope": consent.scope,
                "type": intent.type.rawValue,
                "version": consent.version
            ]
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func challengeData(_ value: String) -> Data? {
        guard let decoded = base64URLData(value), decoded.count == 32 else { return nil }
        return decoded
    }

    private static func validKeyID(_ value: String) -> Bool {
        guard let decoded = base64Data(value) else { return false }
        return decoded.count == 32
    }

    private static func validBase64(_ value: String, maximumBytes: Int) -> Bool {
        guard !value.isEmpty, let decoded = base64Data(value) else { return false }
        return !decoded.isEmpty && decoded.count <= maximumBytes
    }

    private static func validSessionToken(_ value: String) -> Bool {
        value.hasPrefix("bst1.") && value.utf8.count > 5 && value.utf8.count <= 16 * 1024
    }

    private static func base64URLData(_ value: String) -> Data? {
        var standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    private static func base64Data(_ value: String) -> Data? {
        if let standard = Data(base64Encoded: value) { return standard }
        return base64URLData(value)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func transactionID(from deepLink: URL) -> String? {
        guard deepLink.scheme?.lowercased() == "mobilemoica",
              let encoded = URLComponents(url: deepLink, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "rtn_val" })?.value,
              !encoded.isEmpty, encoded.utf8.count <= 512,
              let data = base64URLData(encoded),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    private static func isDeviceCheck(_ error: Error, code: DCError.Code) -> Bool {
        let error = error as NSError
        return error.domain == DCError.errorDomain && error.code == code.rawValue
    }

    private static func requiresKeyReset(_ error: SigningBrokerClientError) -> Bool {
        if error == .appAttestKeyInvalid { return true }
        if case .server(let code, _) = error, code == "installation_not_found" { return true }
        return false
    }

    private static func requiresRegistrationReset(_ code: String) -> Bool {
        ["attestation_invalid", "challenge_invalid", "challenge_used", "installation_conflict"]
            .contains(code)
    }
}

private struct ChallengeResponse: Decodable {
    let challenge: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case challenge
        case expiresAt = "expires_at"
    }
}

private struct RegistrationResponse: Decodable {
    let registered: Bool
}

private struct VerificationResponse: Decodable {
    let verified: Bool
}

private struct StartResponse: Decodable {
    let sessionToken: String
    let deepLink: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case deepLink = "deep_link"
        case expiresAt = "expires_at"
    }
}

private struct PollResponse: Decodable {
    let status: String
    let certificate: String?
    let signedResponse: String?

    enum CodingKeys: String, CodingKey {
        case status, certificate
        case signedResponse = "signed_response"
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
    let retryable: Bool
}
