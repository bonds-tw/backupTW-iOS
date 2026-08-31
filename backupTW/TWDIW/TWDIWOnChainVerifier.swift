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

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// Checks that the successful Arbitrum transaction named by the API actually
/// wrote the same DID, signed DID document, organisation object and category
/// values. The API's `onChainHistory` flag alone is never called verification.
struct TWDIWOnChainVerifier: Sendable {

    static let network = "arbitrum"
    static let registryContract = "0x84172caf8dd126c76f1fa8a2733ca3233264d31f"
    static let methodSelector = "f6e0d282"
    static let rpcURL = URL(string: "https://arb1.arbitrum.io/rpc")!

    let session: URLSession
    var rpcURL = Self.rpcURL

    func verify(_ issuers: [TWDIWIssuer]) async -> [String: TWDIWOnChainVerification] {
        var results = Dictionary(uniqueKeysWithValues: issuers.map {
            ($0.did, TWDIWOnChainVerification.notAnchored)
        })
        let work = issuers.compactMap { issuer -> (TWDIWIssuer, TWDIWOnChainRecord)? in
            guard let record = issuer.onChainRecords.last else { return nil }
            return (issuer, record)
        }
        guard !work.isEmpty else { return results }

        var calls: [[String: Any]] = []
        for (index, item) in work.enumerated() {
            calls.append(["jsonrpc": "2.0", "id": index * 2,
                          "method": "eth_getTransactionByHash",
                          "params": [item.1.transactionHash]])
            calls.append(["jsonrpc": "2.0", "id": index * 2 + 1,
                          "method": "eth_getTransactionReceipt",
                          "params": [item.1.transactionHash]])
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: calls)
            var request = URLRequest(url: rpcURL)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
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
                let transaction = byID[index * 2]?["result"] as? [String: Any]
                let receipt = byID[index * 2 + 1]?["result"] as? [String: Any]
                results[item.0.did] = Self.check(issuer: item.0,
                                                 record: item.1,
                                                 transaction: transaction,
                                                 receipt: receipt)
            }
        } catch {
            for item in work { results[item.0.did] = .unavailable }
        }
        return results
    }

    private static func check(issuer: TWDIWIssuer,
                              record: TWDIWOnChainRecord,
                              transaction: [String: Any]?,
                              receipt: [String: Any]?) -> TWDIWOnChainVerification {
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

    private static func abiString(_ data: Data, headWord: Int) -> String? {
        guard let offset = abiInteger(data, word: headWord),
              offset >= 192,
              offset.isMultiple(of: 32),
              offset <= data.count - 32,
              let length = integer(from: data.subdata(in: offset..<(offset + 32))),
              length <= data.count - offset - 32 else { return nil }
        return String(data: data.subdata(in: (offset + 32)..<(offset + 32 + length)),
                      encoding: .utf8)
    }

    private static func abiInteger(_ data: Data, word: Int) -> Int? {
        let start = word * 32
        guard start + 32 <= data.count else { return nil }
        return integer(from: data.subdata(in: start..<(start + 32)))
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
