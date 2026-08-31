//
//  CrossLanguageChecksumVectorTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing

/// This fixture is copied byte-for-byte into bonds-signing-broker. It catches
/// UTF-8, digest representation, nonce layout, and AES-GCM compatibility drift
/// before the app and broker are tested against MOICA UAT.
struct CrossLanguageChecksumVectorTests {
    private struct Vector: Decodable {
        struct Case: Decodable {
            let payload: String
            let digest: String
            let iv: String
            let checksum: String
        }

        let version: Int
        let aesKeyBase64: String
        let sp: Case
        let idp: Case

        enum CodingKeys: String, CodingKey {
            case version
            case aesKeyBase64 = "aes_key_base64"
            case sp
            case idp
        }
    }

    @Test func sharedNodeAndSwiftVectorAuthenticatesToDigestHex() throws {
        let vector = try Self.loadVector()
        #expect(vector.version == 1)

        let keyData = try #require(Data(base64Encoded: vector.aesKeyBase64))
        let key = SymmetricKey(data: keyData)
        for item in [vector.sp, vector.idp] {
            let digest = SHA256.hash(data: Data(item.payload.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(digest == item.digest)

            let combined = try #require(Self.bytes(fromHex: item.checksum))
            let box = try AES.GCM.SealedBox(combined: combined)
            #expect(Self.hex(Data(box.nonce)) == item.iv)
            let opened = try AES.GCM.open(box, using: key)
            #expect(String(decoding: opened, as: UTF8.self) == item.digest)
        }
    }

    private static func loadVector() throws -> Vector {
        let source = URL(fileURLWithPath: #filePath)
        let fixture = source.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/twfido-checksum-v1.json")
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: fixture))
    }

    private static func bytes(fromHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
