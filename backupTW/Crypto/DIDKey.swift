//
//  DIDKey.swift
//  backupTW
//

import CryptoKit
import Foundation

enum DIDKeyError: Error, Equatable {
    /// An X9.63 uncompressed P-256 key is exactly 65 bytes; anything else is a
    /// different curve or a different encoding and would silently produce a
    /// well-formed but wrong DID.
    case invalidPublicKeyLength(Int)
    /// Right length, but not a point on P-256.
    case invalidPublicKey
}

/// `did:key` for P-256, per the W3C-CCG did:key method specification.
///
/// The whole method is a pure encoding — no network, no registry — which is why
/// it is the right identifier for a document the holder issues to themselves.
/// The DID *is* the public key, so a verifier who has the DID can check the
/// signature without asking anyone's permission.
enum DIDKey {

    /// multicodec `p256-pub` (0x1200) as an unsigned LEB128 varint.
    ///
    /// Two bytes, not one: 0x1200 needs 14 bits, so the low seven (0x00) get the
    /// continuation bit set and the remaining seven (0x24) follow. Writing this
    /// as a single 0x12 0x00 pair is the classic way to produce a DID that looks
    /// plausible and resolves nowhere.
    private static let p256PublicKeyMulticodec = Data([0x80, 0x24])

    /// The Bitcoin alphabet: 0, O, I and l are omitted so that a human reading a
    /// DID aloud cannot introduce an ambiguity.
    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    /// - Parameter x963: Uncompressed public key, `0x04 || X || Y` — the shape
    ///   `SecKeyCopyExternalRepresentation` and `DeviceKey.publicKeyX963` hand back.
    /// - Returns: `did:key:zDnae…`, always 57 characters for P-256.
    static func did(fromP256PublicKeyX963 x963: Data) throws -> String {
        guard x963.count == 65 else {
            throw DIDKeyError.invalidPublicKeyLength(x963.count)
        }

        // did:key encodes the *compressed* point (33 bytes). CryptoKit both
        // compresses and rejects points that are not on the curve, which is
        // worth more than the dozen lines of modular arithmetic it replaces:
        // a DID derived from a bogus point would be unverifiable and we would
        // only find out at the far end of the flow.
        let compressed: Data
        do {
            compressed = try P256.Signing.PublicKey(x963Representation: x963).compressedRepresentation
        } catch {
            throw DIDKeyError.invalidPublicKey
        }

        // multibase prefix "z" == base58btc; it is the only multibase encoding
        // the did:key document creation algorithm accepts.
        return "did:key:z" + base58BTCEncode(p256PublicKeyMulticodec + compressed)
    }

    /// base58btc, as referenced by multibase (draft-msporny-base58).
    ///
    /// Hand-rolled rather than pulled in as a dependency: it is twenty lines, and
    /// a supply-chain dependency for the one function that turns a key into an
    /// identity is a poor trade.
    static func base58BTCEncode(_ data: Data) -> String {
        // Base conversion treats the input as one big integer, which throws away
        // leading zero bytes — they carry no numeric value but they are part of
        // the encoded data. Each one is re-attached as a literal "1", the
        // alphabet's zero digit. P-256 DIDs never hit this path (the multicodec
        // prefix starts at 0x80), but a decoder or another codec would.
        let leadingZeros = data.prefix(while: { $0 == 0 }).count

        var buffer = Array(data.dropFirst(leadingZeros))
        var digits: [UInt8] = []
        digits.reserveCapacity(buffer.count * 137 / 100 + 1) // log(256)/log(58) ≈ 1.365

        // Repeated long division by 58, in place: each pass emits one digit
        // (least significant first) and shortens the buffer by any leading zero
        // the division produced.
        var start = 0
        while start < buffer.count {
            var remainder = 0
            for index in start..<buffer.count {
                let accumulator = remainder << 8 | Int(buffer[index])
                buffer[index] = UInt8(accumulator / 58)
                remainder = accumulator % 58
            }
            digits.append(UInt8(remainder))
            if buffer[start] == 0 {
                start += 1
            }
        }

        return String(repeating: "1", count: leadingZeros)
            + String(digits.reversed().map { base58Alphabet[Int($0)] })
    }
}
