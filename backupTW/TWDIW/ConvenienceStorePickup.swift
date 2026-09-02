//
//  ConvenienceStorePickup.swift
//  backupTW
//
//  The official offline-verifier flow used to turn a telecom credential into a
//  short-lived barcode a convenience-store till can actually read.
//

import Foundation

struct ConvenienceStorePickupScenario: Equatable {
    let vpUid: String
    let name: String
    let verifierModuleURL: String
    let logoURL: String?
}

enum ConvenienceStorePickupError: Error, Equatable {
    case network
    case badStatus(Int)
    case malformedResponse
    case scenarioUnavailable
    case untrustedService
    case trustEvidenceUnavailable
    case unexpectedRequest
    case serverCode(String)
    case invalidBarcodeImage
}

enum ConvenienceStorePickupCatalog {
    static let productionFrontendBase = "https://frontend.wallet.gov.tw"
    static let sevenElevenVPUID = "22555003_711pickup"
    static let telecomCredentialTypes: Set<String> = [
        "96979933_name_phonel5_phonel3",
        "97179430_fet_vc_prod",
        "97176270_twmdiwvc_postpaid",
    ]

    static func fetch(frontendBase: String = productionFrontendBase,
                      session: URLSession = .shared) async throws -> [ConvenienceStorePickupScenario] {
        guard var components = URLComponents(
            string: frontendBase + "/api/moda/dwapp/offline/vpList") else {
            throw ConvenienceStorePickupError.malformedResponse
        }
        components.queryItems = [
            URLQueryItem(name: "name", value: ""),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "size", value: "100"),
        ]
        guard let url = components.url else {
            throw ConvenienceStorePickupError.malformedResponse
        }
        let data = try await get(url, session: session)
        return try scenarios(from: data)
    }

    static func scenarios(from data: Data) throws -> [ConvenienceStorePickupScenario] {
        struct Envelope: Decodable { let code: String?; let data: Payload? }
        struct Payload: Decodable { let vpItems: [Item]? }
        struct Item: Decodable {
            let vpUid: String?
            let name: String?
            let verifierModuleUrl: String?
            let logoUrl: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.code == nil || envelope.code == "0",
              let items = envelope.data?.vpItems else {
            throw ConvenienceStorePickupError.malformedResponse
        }
        return items.compactMap { item in
            guard let vpUid = item.vpUid, !vpUid.isEmpty,
                  let name = item.name, !name.isEmpty,
                  let verifierModuleURL = item.verifierModuleUrl,
                  !verifierModuleURL.isEmpty else { return nil }
            return ConvenienceStorePickupScenario(vpUid: vpUid,
                                                   name: name,
                                                   verifierModuleURL: verifierModuleURL,
                                                   logoURL: item.logoUrl)
        }
    }

    fileprivate static func get(_ url: URL, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch { throw ConvenienceStorePickupError.network }
        guard let http = response as? HTTPURLResponse else {
            throw ConvenienceStorePickupError.network
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ConvenienceStorePickupError.badStatus(http.statusCode)
        }
        return data
    }
}

struct ConvenienceStorePickupContext {
    let scenario: ConvenienceStorePickupScenario
    let transactionID: String
    let request: OID4VPRequest
    let trustEvidence: ConvenienceStorePickupTrustEvidence
}

struct ConvenienceStorePickupTrustEvidence {
    let organisationName: String
    let blockNumber: String
    let transactionHash: String
}

struct ConvenienceStorePickupBarcode {
    let imageData: Data
    let lifetime: TimeInterval
    let generatedAt: Date
}

/// Converts the verifier-provided lifetime into an absolute, testable deadline.
/// The screen always asks this value again rather than decrementing a counter,
/// so time spent in the background, in Face ID, or scrolling cannot make an
/// expired store token look current.
struct ConvenienceStorePickupCountdown {
    let expiresAt: Date

    init(barcode: ConvenienceStorePickupBarcode) {
        expiresAt = barcode.generatedAt.addingTimeInterval(barcode.lifetime)
    }

    func remainingSeconds(at now: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
    }
}

struct ConvenienceStorePickupBarcodeSession {
    let context: ConvenienceStorePickupContext
    let receipt: OID4VPPresentationReceipt
    let barcode: ConvenienceStorePickupBarcode
}

struct ConvenienceStorePickupDisclosure {
    let credentialName: String
    let issuerName: String
    let credentialID: String
    let holderName: String
    let phoneLastFive: String
}

/// Orchestrates the four official operations without ever inventing a barcode:
/// catalogue → transaction/deep-link (401) → OID4VP response → encrypted image
/// (402). The last image is generated by the verifier that the store's scanner
/// trusts; a locally rendered QR would only look similar and would not work.
struct ConvenienceStorePickupClient {
    let session: URLSession
    let store: CredentialStoring
    let keyring: HolderKeyring
    var now: () -> Date = Date.init

    init(session: URLSession = .shared,
         store: CredentialStoring,
         keyring: HolderKeyring) {
        self.session = session
        self.store = store
        self.keyring = keyring
    }

    func beginSevenElevenPickup() async throws -> ConvenienceStorePickupContext {
        let scenarios = try await ConvenienceStorePickupCatalog.fetch(session: session)
        guard let scenario = scenarios.first(where: {
            $0.vpUid == ConvenienceStorePickupCatalog.sevenElevenVPUID
        }) else {
            throw ConvenienceStorePickupError.scenarioUnavailable
        }
        return try await begin(scenario)
    }

    func begin(_ scenario: ConvenienceStorePickupScenario) async throws -> ConvenienceStorePickupContext {
        guard let module = URL(string: scenario.verifierModuleURL),
              module.scheme?.lowercased() == "https",
              let moduleHost = module.host?.lowercased() else {
            throw ConvenienceStorePickupError.untrustedService
        }
        let trustList = try await TrustListFetcher(session: session).fetchAll()
        let trustedHosts = OID4VPPresentation.verifierHosts(from: trustList)
        guard trustedHosts.contains(moduleHost) else {
            throw ConvenienceStorePickupError.untrustedService
        }
        let serviceIssuers = trustList.filter { issuer in
            [issuer.issuerMetadataBaseURL, issuer.serviceBaseURL]
                .compactMap { $0 }
                .contains { Self.host(of: $0) == moduleHost }
        }
        guard !serviceIssuers.isEmpty else {
            throw ConvenienceStorePickupError.untrustedService
        }
        let chainResults = await TWDIWOnChainVerifier(session: session).verify(serviceIssuers)
        let evidence = serviceIssuers.compactMap { issuer -> ConvenienceStorePickupTrustEvidence? in
            guard case .verified(let blockNumber, let transactionHash) = chainResults[issuer.did] else {
                return nil
            }
            return ConvenienceStorePickupTrustEvidence(
                organisationName: issuer.displayName,
                blockNumber: blockNumber,
                transactionHash: transactionHash)
        }.first
        guard let evidence else {
            if serviceIssuers.contains(where: { chainResults[$0.did] == .unavailable }) {
                throw ConvenienceStorePickupError.trustEvidenceUnavailable
            }
            throw ConvenienceStorePickupError.untrustedService
        }

        let startURL = module
            .appendingPathComponent("api/ext/offline/qrcode")
            .appendingPathComponent(scenario.vpUid)
        let startData = try await ConvenienceStorePickupCatalog.get(startURL, session: session)
        let start = try Self.parseStart(startData)
        let link = try OID4VPAuthorizeLink.parse(scanned: start.deepLink)

        // The catalogue selected one verifier module. Even another trusted host
        // must not be substituted inside its response: this transaction belongs
        // to this module, and the 402 call will return to the same one.
        if case .byReference(_, let requestURI) = link {
            guard case .success(let requestHost) = IssuerAuthorization.normalisedHost(of: requestURI),
                  requestHost == moduleHost else {
                throw ConvenienceStorePickupError.unexpectedRequest
            }
        }
        let request = try await OID4VPRequestFetcher(session: session,
                                                     trustedHosts: trustedHosts).fetch(link)
        guard request.definitionID == scenario.vpUid,
              case .success(let responseHost) = IssuerAuthorization.normalisedHost(of: request.responseURI),
              responseHost == moduleHost else {
            throw ConvenienceStorePickupError.unexpectedRequest
        }

        // This screen explicitly promises the two facts in the production
        // scenario. If the server changes the request, stop and show an error
        // instead of relabelling a different disclosure as 「姓名／末五碼」.
        let claims = Set(request.requestedFields.compactMap(\.claimName))
        guard claims.contains("name"), claims.contains("phonel5") else {
            throw ConvenienceStorePickupError.unexpectedRequest
        }
        return ConvenienceStorePickupContext(scenario: scenario,
                                              transactionID: start.transactionID,
                                              request: request,
                                              trustEvidence: evidence)
    }

    func presentAndGenerate(_ context: ConvenienceStorePickupContext) async throws
        -> ConvenienceStorePickupBarcodeSession {
        let responder = OID4VPResponder(session: session, store: store, keyring: keyring)
        let receipt = try await responder.respondWithReceipt(
            to: context.request, disclosing: ["name", "phonel5"])
        let barcode = try await requestBarcode(context: context, receipt: receipt)
        return ConvenienceStorePickupBarcodeSession(context: context,
                                                     receipt: receipt,
                                                     barcode: barcode)
    }

    /// The exact values the consent screen is about to send. They come from the
    /// already verified SD-JWT reader; the view still sanitises them before
    /// drawing because an issuer-supplied string is not app chrome.
    func disclosure(for context: ConvenienceStorePickupContext) throws
        -> ConvenienceStorePickupDisclosure {
        for id in (try? store.allIDs()) ?? [] {
            guard let serialized = try? store.load(id: id),
                  StoredCardSource.source(of: serialized) == .twdiw,
                  let credential = try? TWDIWCredentialReader.read(serialized),
                  context.request.inputDescriptors.contains(where: {
                      $0.credentialType == credential.credentialType
                  }) else { continue }
            var claims: [String: String] = [:]
            for claim in credential.disclosedClaims { claims[claim.name] = claim.value }
            guard let holderName = claims["name"],
                  let phoneLastFive = claims["phonel5"] else { continue }
            let descriptor = context.request.inputDescriptors.first(where: {
                $0.credentialType == credential.credentialType
            })
            guard let credentialID = credential.credentialID,
                  let serial = Self.credentialSerial(from: credentialID) else {
                throw ConvenienceStorePickupError.unexpectedRequest
            }
            return ConvenienceStorePickupDisclosure(
                credentialName: descriptor?.credentialName ?? NSLocalizedString("Phone-number credential", comment: "pickup card fallback"),
                issuerName: descriptor?.issuerName ?? NSLocalizedString("Credential issuer", comment: "pickup issuer fallback"),
                credentialID: serial,
                holderName: holderName,
                phoneLastFive: phoneLastFive)
        }
        throw OID4VPResponseError.noMatchingCredential
    }

    static func credentialSerial(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return trimmed.split(separator: "/").last.map(String.init)
    }

    private static func host(of value: String) -> String? {
        guard case .success(let host) = IssuerAuthorization.normalisedHost(of: value) else {
            return nil
        }
        return host
    }

    func regenerate(_ prior: ConvenienceStorePickupBarcodeSession) async throws
        -> ConvenienceStorePickupBarcodeSession {
        let barcode = try await requestBarcode(context: prior.context, receipt: prior.receipt)
        return ConvenienceStorePickupBarcodeSession(context: prior.context,
                                                     receipt: prior.receipt,
                                                     barcode: barcode)
    }

    private func requestBarcode(context: ConvenienceStorePickupContext,
                                receipt: OID4VPPresentationReceipt) async throws
        -> ConvenienceStorePickupBarcode {
        let header: [String: Any] = [
            "typ": "JWT",
            "alg": "ES256",
            "kid": receipt.holderDID,
        ]
        let payload: [String: Any] = ["transactionId": context.transactionID]
        let signingInput = try Self.base64URL(header) + "." + Self.base64URL(payload)
        let signature = try receipt.holderKey.signature(for: Data(signingInput.utf8))
        let jwt = signingInput + "." + signature.base64URLEncodedString()

        guard let module = URL(string: context.scenario.verifierModuleURL) else {
            throw ConvenienceStorePickupError.untrustedService
        }
        let url = module.appendingPathComponent("api/ext/offline/getEncryptionData")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jwt": jwt])

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ConvenienceStorePickupError.network }
        guard let http = response as? HTTPURLResponse else {
            throw ConvenienceStorePickupError.network
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ConvenienceStorePickupError.badStatus(http.statusCode)
        }
        return try Self.parseBarcode(data, now: now())
    }

    static func parseStart(_ data: Data) throws -> (transactionID: String, deepLink: String) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConvenienceStorePickupError.malformedResponse
        }
        try Self.checkServerCode(envelope)
        guard let body = envelope["data"] as? [String: Any],
              let transactionID = body["transactionId"] as? String, !transactionID.isEmpty,
              let deepLink = body["deepLink"] as? String, !deepLink.isEmpty else {
            throw ConvenienceStorePickupError.malformedResponse
        }
        return (transactionID, deepLink)
    }

    static func parseBarcode(_ data: Data, now: Date) throws -> ConvenienceStorePickupBarcode {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConvenienceStorePickupError.malformedResponse
        }
        try Self.checkServerCode(envelope)
        guard let body = envelope["data"] as? [String: Any],
              let dataURL = body["qrcode"] as? String,
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].lowercased().hasPrefix("data:image/png;base64"),
              let imageData = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]),
                                   options: [.ignoreUnknownCharacters]),
              imageData.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              imageData.count <= 5_000_000,
              let timeoutText = body["totptimeout"] as? String,
              let timeout = TimeInterval(timeoutText), timeout > 0 else {
            throw ConvenienceStorePickupError.invalidBarcodeImage
        }
        return ConvenienceStorePickupBarcode(imageData: imageData,
                                              lifetime: timeout,
                                              generatedAt: now)
    }

    private static func checkServerCode(_ envelope: [String: Any]) throws {
        let code: String
        if let string = envelope["code"] as? String { code = string }
        else if let number = envelope["code"] as? NSNumber { code = number.stringValue }
        else { throw ConvenienceStorePickupError.malformedResponse }
        guard code == "0" else { throw ConvenienceStorePickupError.serverCode(code) }
    }

    private static func base64URL(_ object: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw ConvenienceStorePickupError.malformedResponse
        }
        return data.base64URLEncodedString()
    }
}
