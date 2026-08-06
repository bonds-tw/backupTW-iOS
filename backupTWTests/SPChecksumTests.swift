//
//  SPChecksumTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// `sp_checksum` is verified server-side by recomputation and compared as a
/// string. A wrong byte comes back as a generic rejection with no indication of
/// which byte, so these tests pin every property the server relies on: the
/// exact length, the lowercase hex alphabet, the plaintext being the *hex
/// string* of the digest rather than the digest bytes, and the four
/// concatenation orders that differ between transports.
struct SPChecksumTests {

    /// A throwaway key of the right shape. Real SP keys never appear in source;
    /// see `SPCredentialProviding`.
    private static let key = Data(repeating: 0x2A, count: 32).base64EncodedString()

    private static let payload = "TXNSVCA123456789SIGNAPP2APPHINTU0lHTg=="

    // MARK: - Shape

    @Test func checksumIs184LowercaseHexCharacters() throws {
        let checksum = try SPChecksum.compute(payload: Self.payload, aesKeyBase64: Self.key)

        // 12-byte IV + 64-byte ciphertext (the 64-character digest hex) +
        // 16-byte tag = 92 bytes = 184 hex characters. The count is fixed
        // because the plaintext length is fixed.
        #expect(checksum.count == 184)
        #expect(checksum.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// The most valuable assertion in the file: decrypt our own output with the
    /// same key and confirm the plaintext is the lowercase hex of SHA-256 over
    /// the payload. If the implementation ever encrypts the raw digest bytes —
    /// the single most common way to get this wrong — this fails and the length
    /// test fails with it.
    @Test func checksumDecryptsToTheDigestHexString() throws {
        let checksum = try SPChecksum.compute(payload: Self.payload, aesKeyBase64: Self.key)

        let combined = try #require(Self.bytes(fromHex: checksum))
        let key = try #require(Data(base64Encoded: Self.key))
        let box = try AES.GCM.SealedBox(combined: combined)
        let opened = try AES.GCM.open(box, using: SymmetricKey(data: key))

        let expected = SHA256.hash(data: Data(Self.payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(String(decoding: opened, as: UTF8.self) == expected)
        #expect(expected.count == 64)
    }

    @Test func ivIsTheFirstTwelveBytes() throws {
        let checksum = try SPChecksum.compute(payload: Self.payload, aesKeyBase64: Self.key)
        let combined = try #require(Self.bytes(fromHex: checksum))

        // SealedBox(combined:) only accepts a 12-byte nonce prefix, so a
        // successful decode confirms the split point.
        let box = try AES.GCM.SealedBox(combined: combined)
        #expect(Data(box.nonce) == combined.prefix(12))
        #expect(checksum.prefix(24) == Self.hex(combined.prefix(12)))
        #expect(box.tag.count == 16)
    }

    // MARK: - The IV is random

    /// We deliberately diverge from the spec's .NET sample, which hard-codes a
    /// zero IV. Repeating a nonce under a fixed GCM key leaks the authentication
    /// subkey and lets anyone who has seen two checksums forge more, so this is
    /// a property worth defending with a test rather than a comment alone.
    @Test func repeatedCallsProduceDifferentChecksums() throws {
        let first = try SPChecksum.compute(payload: Self.payload, aesKeyBase64: Self.key)
        let second = try SPChecksum.compute(payload: Self.payload, aesKeyBase64: Self.key)

        #expect(first != second)
        #expect(first.prefix(24) != second.prefix(24), "the IV, not just the ciphertext, must vary")
        #expect(first.prefix(24) != String(repeating: "0", count: 24))
    }

    // MARK: - Key validation

    @Test(arguments: [
        // 16 bytes — AES-128, silently produces a checksum the server rejects
        // if we let it through.
        Data(repeating: 0x2A, count: 16).base64EncodedString(),
        Data(repeating: 0x2A, count: 31).base64EncodedString(),
        Data(repeating: 0x2A, count: 33).base64EncodedString(),
        "",
        "not base64 at all!!",
        // The raw hex of a 32-byte key: a plausible transcription mistake that
        // base64-decodes to 48 bytes.
        String(repeating: "2a", count: 32),
    ])
    func rejectsKeysThatAreNot32Bytes(key: String) {
        #expect(throws: SPChecksumError.invalidAESKey) {
            _ = try SPChecksum.compute(payload: Self.payload, aesKeyBase64: key)
        }
    }

    // MARK: - Payload concatenation

    private static let transactionID = "TXN"
    private static let serviceID = "SVC"
    private static let idNumber = "A123456789"
    private static let alias = "DEV"
    private static let hint = "HINT"
    private static let signData = "SIGNDATA"
    private static let ticketID = "TKT"

    /// ATH-03 with a device alias: the alias sits between `id_num` and
    /// `op_code`, which is *not* where it appears in the JSON body.
    @Test func pushWithAliasOrdersAliasBeforeOpCode() {
        let payload = SPChecksum.pushPayload(transactionID: Self.transactionID,
                                             spServiceID: Self.serviceID,
                                             idNumber: Self.idNumber,
                                             deviceAlias: Self.alias,
                                             opCode: "SIGN",
                                             hint: Self.hint,
                                             signData: Self.signData)
        #expect(payload == "TXNSVCA123456789DEVSIGNHINTSIGNDATA")
    }

    /// ATH-03 without one: the alias is absent entirely, not empty-string
    /// padded.
    @Test func pushWithoutAliasOmitsIt() {
        let payload = SPChecksum.pushPayload(transactionID: Self.transactionID,
                                             spServiceID: Self.serviceID,
                                             idNumber: Self.idNumber,
                                             opCode: "SIGN",
                                             hint: Self.hint,
                                             signData: Self.signData)
        #expect(payload == "TXNSVCA123456789SIGNHINTSIGNDATA")

        // Concatenation makes an empty alias indistinguishable from no alias.
        // That is harmless — the client only takes the aliased branch for a
        // non-nil alias — but it means "" must never be used as a sentinel for
        // "push to every device", because the body would then carry an empty
        // device_user_def_desc the checksum does not account for.
        let emptyAlias = SPChecksum.pushPayload(transactionID: Self.transactionID,
                                                spServiceID: Self.serviceID,
                                                idNumber: Self.idNumber,
                                                deviceAlias: "",
                                                opCode: "SIGN",
                                                hint: Self.hint,
                                                signData: Self.signData)
        #expect(emptyAlias == payload)
    }

    /// ATH-01: `op_mode` appears here and only here.
    @Test func appToAppInsertsOpModeAfterOpCode() {
        let payload = SPChecksum.appToAppPayload(transactionID: Self.transactionID,
                                                 spServiceID: Self.serviceID,
                                                 idNumber: Self.idNumber,
                                                 opCode: "SIGN",
                                                 opMode: "APP2APP",
                                                 hint: Self.hint,
                                                 signData: Self.signData)
        #expect(payload == "TXNSVCA123456789SIGNAPP2APPHINTSIGNDATA")
    }

    /// ATH-02 carries no `id_num`, no `hint`, no `sign_data`.
    @Test func resultPayloadIsThreeFields() {
        let payload = SPChecksum.resultPayload(transactionID: Self.transactionID,
                                               spServiceID: Self.serviceID,
                                               spTicketID: Self.ticketID)
        #expect(payload == "TXNSVCTKT")
    }

    /// The four orders must be mutually distinct — otherwise a transport mix-up
    /// would still produce an accepted checksum and hide the bug until the
    /// server behaved unexpectedly.
    @Test func theFourOrdersAreAllDifferent() {
        let payloads = [
            SPChecksum.pushPayload(transactionID: Self.transactionID, spServiceID: Self.serviceID,
                                   idNumber: Self.idNumber, deviceAlias: Self.alias,
                                   opCode: "SIGN", hint: Self.hint, signData: Self.signData),
            SPChecksum.pushPayload(transactionID: Self.transactionID, spServiceID: Self.serviceID,
                                   idNumber: Self.idNumber,
                                   opCode: "SIGN", hint: Self.hint, signData: Self.signData),
            SPChecksum.appToAppPayload(transactionID: Self.transactionID, spServiceID: Self.serviceID,
                                       idNumber: Self.idNumber, opCode: "SIGN", opMode: "APP2APP",
                                       hint: Self.hint, signData: Self.signData),
            SPChecksum.resultPayload(transactionID: Self.transactionID, spServiceID: Self.serviceID,
                                     spTicketID: Self.ticketID),
        ]
        #expect(Set(payloads).count == payloads.count)
    }

    /// Non-ASCII hints are real — the hint is Chinese in production — and the
    /// digest is taken over UTF-8 bytes, not UTF-16 units.
    @Test func nonASCIIHintIsHashedAsUTF8() throws {
        let payload = SPChecksum.appToAppPayload(transactionID: "T", spServiceID: "S",
                                                 idNumber: "A123456789", opCode: "SIGN",
                                                 opMode: "APP2APP",
                                                 hint: "請確認身分", signData: "D")
        let checksum = try SPChecksum.compute(payload: payload, aesKeyBase64: Self.key)

        let combined = try #require(Self.bytes(fromHex: checksum))
        let key = try #require(Data(base64Encoded: Self.key))
        let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: combined),
                                      using: SymmetricKey(data: key))
        let expected = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(String(decoding: opened, as: UTF8.self) == expected)
    }

    // MARK: - Helpers

    private static func bytes(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
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
