//
//  TWDIWOnChainVerifier.swift
//  backupTW
//

import Foundation

/// The independent result shown beside an API trust-list entry.
enum TWDIWOnChainVerification: Hashable, Sendable {
    case verified(blockNumber: String, transactionHash: String)
    case notAnchored
    case mismatch
    case unavailable
    /// The official demo issuer is a separate trust domain and has no
    /// production Arbitrum record. Only DEBUG collection code can create this
    /// result; keeping it distinct avoids calling a sandbox bypass verified.
    case developmentSandbox

    var authorisesCollection: Bool {
        switch self {
        case .verified, .developmentSandbox: return true
        case .notAnchored, .mismatch, .unavailable: return false
        }
    }
}

/// Checks that the successful Arbitrum transaction named by the API actually
/// wrote the same DID, signed DID document, organisation object and category
/// values. The API's `onChainHistory` flag alone is never called verification.
struct TWDIWOnChainVerifier: Sendable {

    static let network = "arbitrum"
    static let registryContract = "0x84172caf8dd126c76f1fa8a2733ca3233264d31f"
    static let methodSelector = "f6e0d282"
    /// `getDocById(bytes)`, derived from the deployed contract selector and
    /// checked against the live return shape on 2026-08-31.
    static let currentRecordSelector = "fba6fe49"
    static let rpcURL = URL(string: "https://arb1.arbitrum.io/rpc")!

    let session: URLSession
    var rpcURL = Self.rpcURL

    func verify(_ issuers: [TWDIWIssuer]) async -> [String: TWDIWOnChainVerification] {
        // The API can return one DID under more than one organisation type.
        // `TrustListFetcher` removes those duplicates, but keep this lower
        // boundary safe too: `Dictionary(uniqueKeysWithValues:)` traps on a
        // duplicate and an untrusted registry response must never crash the app.
        var results: [String: TWDIWOnChainVerification] = [:]
        var uniqueIssuers: [TWDIWIssuer] = []
        for issuer in issuers where results[issuer.did] == nil {
            results[issuer.did] = .notAnchored
            uniqueIssuers.append(issuer)
        }
        var work: [(issuer: TWDIWIssuer, record: TWDIWOnChainRecord, currentCall: String)] = []
        for issuer in uniqueIssuers {
            guard let record = issuer.onChainRecords.last else { continue }
            guard let currentCall = Self.currentRecordCallData(forDID: issuer.did) else {
                results[issuer.did] = .mismatch
                continue
            }
            work.append((issuer, record, currentCall))
        }
        guard !work.isEmpty else { return results }

        var calls: [[String: Any]] = []
        for (index, item) in work.enumerated() {
            calls.append(["jsonrpc": "2.0", "id": index * 3,
                          "method": "eth_getTransactionByHash",
                          "params": [item.record.transactionHash]])
            calls.append(["jsonrpc": "2.0", "id": index * 3 + 1,
                          "method": "eth_getTransactionReceipt",
                          "params": [item.record.transactionHash]])
            // A historical transaction matching the API is not enough: an API
            // replay could present a record that was later replaced or revoked.
            // Query the contract's current state under the DID in the same
            // attempt and require it to match too.
            calls.append(["jsonrpc": "2.0", "id": index * 3 + 2,
                          "method": "eth_call",
                          "params": [["to": Self.registryContract,
                                      "data": item.currentCall], "latest"]])
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: calls)
            var request = URLRequest(url: rpcURL,
                                     cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                     timeoutInterval: 20)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let replies = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw URLError(.badServerResponse)
            }
            let byID = Dictionary(uniqueKeysWithValues: replies.compactMap { reply -> (Int, [String: Any])? in
                guard let id = (reply["id"] as? NSNumber)?.intValue else { return nil }
                return (id, reply)
            })
            for (index, item) in work.enumerated() {
                let replies = [byID[index * 3], byID[index * 3 + 1], byID[index * 3 + 2]]
                guard replies.allSatisfy({ $0 != nil }),
                      !replies.compactMap({ $0 }).contains(where: Self.isInfrastructureError) else {
                    results[item.issuer.did] = .unavailable
                    continue
                }
                let transaction = replies[0]?["result"] as? [String: Any]
                let receipt = replies[1]?["result"] as? [String: Any]
                let current = (replies[2]?["result"] as? String).flatMap(Self.decodeCurrentRecord)
                results[item.issuer.did] = Self.check(issuer: item.issuer,
                                                      record: item.record,
                                                      transaction: transaction,
                                                      receipt: receipt,
                                                      current: current)
            }
        } catch {
            for item in work { results[item.issuer.did] = .unavailable }
        }
        return results
    }

    /// JSON-RPC infrastructure errors mean the independent source could not be
    /// checked and must be shown as unavailable. A contract execution revert is
    /// different: Arbitrum answered, but the claimed current record does not
    /// exist, so the caller records a mismatch through the nil decoded value.
    private static func isInfrastructureError(_ reply: [String: Any]) -> Bool {
        guard let error = reply["error"] as? [String: Any] else { return false }
        let message = (error["message"] as? String)?.lowercased() ?? ""
        return !message.contains("execution reverted")
    }

    static func check(issuer: TWDIWIssuer,
                      record: TWDIWOnChainRecord,
                      transaction: [String: Any]?,
                      receipt: [String: Any]?,
                      current: CurrentRegistryRecord?) -> TWDIWOnChainVerification {
        guard record.network.lowercased() == network,
              record.contractAddress.lowercased() == registryContract,
              record.status == 1,
              let transaction,
              let receipt,
              (transaction["hash"] as? String)?.lowercased() == record.transactionHash.lowercased(),
              (transaction["to"] as? String)?.lowercased() == registryContract,
              receipt["status"] as? String == "0x1",
              let input = transaction["input"] as? String,
              let decoded = decodeRegistryInput(input),
              decoded.did == issuer.did,
              decoded.signedDIDDocument == issuer.signedDIDDocument,
              decoded.orgType == issuer.orgType,
              decoded.orgGroup == issuer.orgGroup,
              jsonObjectsEqual(decoded.organisationJSON, issuer.organisationJSON),
              let current,
              current.signedDIDDocument == issuer.signedDIDDocument,
              current.orgType == issuer.orgType,
              current.orgGroup == issuer.orgGroup,
              !current.revoked,
              jsonObjectsEqual(current.organisationJSON, issuer.organisationJSON),
              let blockNumber = transaction["blockNumber"] as? String else {
            return .mismatch
        }
        return .verified(blockNumber: blockNumber, transactionHash: record.transactionHash)
    }

    struct RegistryInput: Equatable {
        let did: String
        let signedDIDDocument: String
        let organisationJSON: String
        let orgType: Int
        let orgGroup: Int
    }

    struct CurrentRegistryRecord: Equatable {
        let signedDIDDocument: String
        let organisationJSON: String
        let orgType: Int
        let orgGroup: Int
        let revoked: Bool
    }

    /// ABI-decodes the production registry method. It has six 32-byte head
    /// words; the first three are offsets to strings and the next two are the
    /// category values this screen compares. The final word is not needed for
    /// this integrity check.
    static func decodeRegistryInput(_ value: String) -> RegistryInput? {
        let hex = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard hex.count >= 8, String(hex.prefix(8)).lowercased() == methodSelector,
              let bytes = data(fromHex: String(hex.dropFirst(8))), bytes.count >= 192 else { return nil }
        guard let first = abiString(bytes, headWord: 0),
              let second = abiString(bytes, headWord: 1),
              let third = abiString(bytes, headWord: 2),
              let orgType = abiInteger(bytes, word: 3),
              let orgGroup = abiInteger(bytes, word: 4) else { return nil }
        return RegistryInput(did: first,
                             signedDIDDocument: second,
                             organisationJSON: third,
                             orgType: orgType,
                             orgGroup: orgGroup)
    }

    /// ABI-encodes `getDocById(bytes)` for a current-state lookup. The DID is
    /// bounded before allocation because every byte came from the network.
    static func currentRecordCallData(forDID did: String) -> String? {
        let value = Data(did.utf8)
        guard !value.isEmpty, value.count <= 4_096 else { return nil }
        var encoded = abiWord(32)
        encoded.append(abiWord(value.count))
        encoded.append(value)
        encoded.append(Data(repeating: 0, count: (32 - value.count % 32) % 32))
        return "0x" + currentRecordSelector
            + encoded.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes the live contract's current record return:
    /// `(signedDIDDocument, organisationJSON, orgType, orgGroup, revoked)`.
    static func decodeCurrentRecord(_ value: String) -> CurrentRegistryRecord? {
        let hex = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard let bytes = data(fromHex: hex), bytes.count >= 32,
              let base = abiInteger(bytes, word: 0),
              base >= 32, base <= bytes.count - 160,
              let signed = abiString(bytes, headWord: 0, base: base, headWordCount: 5),
              let organisation = abiString(bytes, headWord: 1, base: base, headWordCount: 5),
              let orgType = abiInteger(bytes, word: 2, base: base),
              let orgGroup = abiInteger(bytes, word: 3, base: base),
              let revokedValue = abiInteger(bytes, word: 4, base: base),
              revokedValue == 0 || revokedValue == 1 else { return nil }
        return CurrentRegistryRecord(signedDIDDocument: signed,
                                     organisationJSON: organisation,
                                     orgType: orgType,
                                     orgGroup: orgGroup,
                                     revoked: revokedValue == 1)
    }

    private static func abiString(_ data: Data,
                                  headWord: Int,
                                  base: Int = 0,
                                  headWordCount: Int = 6) -> String? {
        guard let offset = abiInteger(data, word: headWord, base: base),
              offset >= headWordCount * 32,
              offset.isMultiple(of: 32),
              base <= data.count - offset - 32 else { return nil }
        let start = base + offset
        guard let length = integer(from: data.subdata(in: start..<(start + 32))),
              length <= data.count - start - 32 else { return nil }
        return String(data: data.subdata(in: (start + 32)..<(start + 32 + length)),
                      encoding: .utf8)
    }

    private static func abiInteger(_ data: Data, word: Int, base: Int = 0) -> Int? {
        let start = base + word * 32
        guard start + 32 <= data.count else { return nil }
        return integer(from: data.subdata(in: start..<(start + 32)))
    }

    private static func abiWord(_ value: Int) -> Data {
        guard value >= 0 else { return Data() }
        var bytes = Data(repeating: 0, count: 32)
        var number = UInt64(value).bigEndian
        withUnsafeBytes(of: &number) { bytes.replaceSubrange(24..<32, with: $0) }
        return bytes
    }

    private static func integer(from bytes: Data) -> Int? {
        guard bytes.count == 32, bytes.prefix(24).allSatisfy({ $0 == 0 }) else { return nil }
        var value = 0
        for byte in bytes.suffix(8) {
            let multiplied = value.multipliedReportingOverflow(by: 256)
            guard !multiplied.overflow else { return nil }
            let added = multiplied.partialValue.addingReportingOverflow(Int(byte))
            guard !added.overflow else { return nil }
            value = added.partialValue
        }
        return value
    }

    private static func data(fromHex value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func jsonObjectsEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: Data(lhs.utf8)),
              let right = try? JSONSerialization.jsonObject(with: Data(rhs.utf8)) else { return false }
        return (left as AnyObject).isEqual(right)
    }
}
