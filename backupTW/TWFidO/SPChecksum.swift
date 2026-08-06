//
//  SPChecksum.swift
//  backupTW
//
//  sp_checksum per the TW FidO SP API spec v2.9.
//

import CryptoKit
import Foundation

enum SPChecksumError: Error, Equatable {
    /// The configured key was not base64, or not 32 bytes once decoded.
    case invalidAESKey
    /// CryptoKit produced a seal we could not serialise. Should be unreachable
    /// with a 12-byte nonce; surfaced rather than force-unwrapped.
    case encryptionFailed
}

/// Derives the `sp_checksum` field that authenticates every SP API call.
///
/// The server recomputes this from the same fields and compares strings, so any
/// disagreement — a field in the wrong order, an uppercase hex digit, a missing
/// concatenation element — comes back as a generic rejection with no indication
/// of which part was wrong. Everything here is therefore spelled out rather
/// than inferred.
enum SPChecksum {

    /// 5 steps, in the spec's numbering:
    ///
    /// 1. Decode the base64 AES-256 key (32 raw bytes).
    /// 2. SHA-256 the concatenated payload and render the digest as a
    ///    **lowercase hex string**.
    /// 3. Take a 12-byte IV.
    /// 4. AES-256-GCM encrypt — and the plaintext is the 64-character hex
    ///    *string* from step 2, encoded as UTF-8, **not** the 32 raw digest
    ///    bytes. Encrypting the raw digest yields a 32-byte ciphertext and a
    ///    120-character checksum that the server rejects.
    /// 5. Return `hex(IV) ‖ hex(ciphertext) ‖ hex(tag)`, lowercase. 12 + 64 + 16
    ///    bytes = 184 hex characters, always.
    ///
    /// **On the IV.** The spec's .NET sample hard-codes twelve zero bytes and
    /// the reference iOS app copies it. We use a random IV instead. Reusing a
    /// nonce under a fixed GCM key is the one failure mode GCM does not
    /// tolerate: it leaks the XOR of plaintexts and, worse, the authentication
    /// subkey, at which point anyone who has collected two checksums can forge
    /// them. The IV travels in the clear as the first 24 hex characters, so the
    /// server needs no agreement with us about its value — and the spec's own
    /// ATH-01 worked example shows a non-zero IV, confirming the server accepts
    /// both. This costs nothing and removes a real break.
    static func compute(payload: String, aesKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: aesKeyBase64), keyData.count == 32 else {
            throw SPChecksumError.invalidAESKey
        }

        let digestHex = hexString(SHA256.hash(data: Data(payload.utf8)))

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(Data(digestHex.utf8),
                                      using: SymmetricKey(data: keyData),
                                      nonce: AES.GCM.Nonce())
        } catch {
            throw SPChecksumError.encryptionFailed
        }

        // `combined` is exactly nonce ‖ ciphertext ‖ tag, and is non-nil for the
        // 12-byte nonces AES.GCM.Nonce() generates.
        guard let combined = sealed.combined else {
            throw SPChecksumError.encryptionFailed
        }
        return hexString(combined)
    }
}

// MARK: - Payload concatenation

/// The four concatenation orders. They differ between transports in ways that
/// are easy to miss — APP2APP inserts `op_mode` after `op_code`, push omits it
/// entirely, and the device alias (when present) goes *before* `op_code`, not
/// where it sits in the JSON body. Separate functions rather than one
/// parameterised builder, so no call can accidentally emit an alias and an
/// op_mode together — a combination no transport uses and whose ordering the
/// spec therefore does not define.
extension SPChecksum {

    /// ATH-03 push, targeting one bound device.
    ///
    /// `transaction_id ‖ sp_service_id ‖ id_num ‖ device_user_def_desc ‖
    ///  op_code ‖ hint ‖ sign_data`
    static func pushPayload(transactionID: String,
                            spServiceID: String,
                            idNumber: String,
                            deviceAlias: String,
                            opCode: String,
                            hint: String,
                            signData: String) -> String {
        transactionID + spServiceID + idNumber + deviceAlias + opCode + hint + signData
    }

    /// ATH-03 push, fanned out to every device the holder has bound.
    ///
    /// `transaction_id ‖ sp_service_id ‖ id_num ‖ op_code ‖ hint ‖ sign_data`
    static func pushPayload(transactionID: String,
                            spServiceID: String,
                            idNumber: String,
                            opCode: String,
                            hint: String,
                            signData: String) -> String {
        transactionID + spServiceID + idNumber + opCode + hint + signData
    }

    /// ATH-01 app-to-app.
    ///
    /// `transaction_id ‖ sp_service_id ‖ id_num ‖ op_code ‖ op_mode ‖ hint ‖
    ///  sign_data`
    static func appToAppPayload(transactionID: String,
                                spServiceID: String,
                                idNumber: String,
                                opCode: String,
                                opMode: String,
                                hint: String,
                                signData: String) -> String {
        transactionID + spServiceID + idNumber + opCode + opMode + hint + signData
    }

    /// ATH-02 result polling. Note it carries no `id_num` — the ticket already
    /// binds the request to a holder.
    ///
    /// `transaction_id ‖ sp_service_id ‖ sp_ticket_id`
    static func resultPayload(transactionID: String,
                              spServiceID: String,
                              spTicketID: String) -> String {
        transactionID + spServiceID + spTicketID
    }
}

// MARK: - Hex

private let hexDigits: [Character] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
]

/// Lowercase, no separators. The server compares checksums as strings, so case
/// is part of the wire format — `String(format: "%02X")` here would fail every
/// call with no diagnostic.
///
/// A free function rather than an extension on `Data` or `Sequence`: several
/// modules in this app need hex, and a shared extension would be an invalid
/// redeclaration the moment two of them add one.
private func hexString<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var out = String()
    out.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0x0F)])
    }
    return out
}
