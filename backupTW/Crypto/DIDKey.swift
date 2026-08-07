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

    // MARK: Decoding

    // The cases below name the layer that rejected the DID. They are kept apart
    // rather than collapsed into one `malformed` because they are not the same
    // news: an Ed25519 DID is a perfectly good identifier that this function
    // cannot serve, while a bad base58 character is a corrupted string. A
    // verifier that cannot tell those apart will tell the person at the counter
    // the wrong thing.
    //
    // None of them carry any part of the DID, for the reason spelled out on
    // `VerifiableCredentialError`: a DID is a stable, correlatable identifier for
    // its holder, and an error string is exactly how one leaks into a log or a
    // crash report. The multicodec code and the byte count are safe because they
    // describe a format, not a person.

    /// Not a `did:key:` DID at all — a different method, or not a DID.
    case notADIDKey
    /// The multibase prefix is not `z` (base58btc). did:key permits other
    /// multibase encodings in principle and this decoder implements only one, so
    /// the alternative to rejecting is decoding the wrong alphabet.
    case unsupportedMultibaseEncoding
    /// Longer than any `did:key` identifier can be. See the bound in
    /// `p256PublicKey(fromDID:)` for why the length is checked before the
    /// contents.
    case oversizedDID
    /// A character outside the base58btc alphabet.
    case invalidBase58
    /// The multicodec varint runs off the end of the decoded bytes, so where the
    /// key begins is unknowable.
    case malformedMulticodec
    /// A well-formed multicodec for some other key type: `0xed` is Ed25519,
    /// `0xe7` secp256k1. Both are real DIDs; neither is a P-256 key.
    case unsupportedMulticodec(UInt64)
    /// A compressed P-256 point is exactly 33 bytes.
    case invalidCompressedPointLength(Int)
    /// The DID decodes to a valid key but is not the spelling this key produces.
    /// See `p256PublicKey(fromDID:)` for why that has to be refused.
    case nonCanonicalDID
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

    /// The same code as a number, which is the form the decoder compares against.
    ///
    /// Not derived from `p256PublicKeyMulticodec` at runtime: deriving it would
    /// make the two agree by construction and therefore make them agree even when
    /// both are wrong. They are declared independently and pinned against each
    /// other by a test, which is the only arrangement where a typo in either one
    /// shows up as a failure.
    private static let p256PublicKeyMulticodecCode: UInt64 = 0x1200

    /// The Bitcoin alphabet: 0, O, I and l are omitted so that a human reading a
    /// DID aloud cannot introduce an ambiguity.
    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    /// `base58Alphabet` inverted, built from it rather than written out a second
    /// time so that there is exactly one place the alphabet can be wrong.
    private static let base58DigitValues: [Character: UInt8] = {
        var values: [Character: UInt8] = [:]
        for (digit, character) in base58Alphabet.enumerated() {
            values[character] = UInt8(digit)
        }
        return values
    }()

    private static let didKeyPrefix = "did:key:"

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

    // MARK: - Decoding

    /// Recovers the signing key a `did:key` names — the inverse of
    /// `did(fromP256PublicKeyX963:)`.
    ///
    /// This is the function that makes offline verification possible. A verifier
    /// at a queue in a disaster zone holds nothing but the credential in front of
    /// it, and the issuer DID inside that credential is the only route back to a
    /// key that can check the signature. No network, no registry, no call home —
    /// which is the whole point of §5.2.
    ///
    /// **Every failure here is a rejection, never a repair.** A decoder that
    /// shrugs off a wrong multibase prefix, an unknown curve, or a non-canonical
    /// varint still hands its caller *a* key, and the caller has no way left to
    /// notice that it is not the key the DID names. The verifier would then
    /// report a good signature over the wrong identity, which is worse than
    /// reporting nothing.
    ///
    /// Note what this does **not** establish: that the DID belongs to the person
    /// presenting it, or that anyone other than the holder's own device vouched
    /// for the credential it signed. See `VerifiableCredential` — this recovers a
    /// key, and a key is not an authority.
    static func p256PublicKey(fromDID did: String) throws -> P256.Signing.PublicKey {
        guard did.hasPrefix(didKeyPrefix) else { throw DIDKeyError.notADIDKey }

        // multibase: the first character of the identifier names the encoding.
        // did:key only ever emits "z" (base58btc). The alphabets overlap, so an
        // "m" (base64) or "f" (base16) identifier that happens to avoid 0, O, I
        // and l reads cleanly under the wrong alphabet and yields different
        // bytes — a wrong key rather than an error, which is the one outcome a
        // verifier cannot detect.
        let multibase = did.dropFirst(didKeyPrefix.count)
        guard multibase.first == "z" else { throw DIDKeyError.unsupportedMultibaseEncoding }

        // Base conversion is quadratic in the digit count — measured at 6 ms for
        // 3 000 digits and 1.3 s for 50 000 on a desktop, so several seconds on
        // the oldest phone we support. The DID arrives from a QR held by a
        // stranger, so its length has to be bounded before any of it is
        // interpreted.
        //
        // The ceiling is deliberately far above what we need rather than snug
        // against it. A P-256 identifier is always exactly 48 digits, so 64 would
        // do — but P-521 runs to 95 and RSA-4096 to roughly 740, and refusing
        // those for *length* would tell the holder their credential is malformed
        // when the truth is that this app only speaks P-256. Left under the
        // ceiling they reach the multicodec check instead and get named for what
        // they are. 1024 digits decode in about a millisecond, so the headroom is
        // free.
        let identifier = multibase.dropFirst()
        guard identifier.count <= 1024 else { throw DIDKeyError.oversizedDID }

        let decoded = Array(try base58BTCDecode(String(identifier)))
        let (code, prefixLength) = try readUnsignedVarint(decoded)
        guard code == p256PublicKeyMulticodecCode else {
            // Ed25519 and secp256k1 DIDs are well-formed and resolvable, just not
            // by us. Saying so lets the caller explain "that identity is not a
            // P-256 key" rather than complain about a length, thirty lines later,
            // for bytes that were never going to be a P-256 key.
            throw DIDKeyError.unsupportedMulticodec(code)
        }

        let compressed = Array(decoded[prefixLength...])
        guard compressed.count == 33 else {
            throw DIDKeyError.invalidCompressedPointLength(compressed.count)
        }

        // CryptoKit checks that the point is on the curve, and that check is the
        // reason to route through it rather than slice out the coordinates: an
        // off-curve key would verify nothing and we would only learn that at the
        // far end of the flow, as "signature invalid".
        let key: P256.Signing.PublicKey
        do {
            key = try P256.Signing.PublicKey(compressedRepresentation: compressed)
        } catch {
            throw DIDKeyError.invalidPublicKey
        }

        // Canonicality, established by re-encoding rather than by auditing each
        // layer for its own malleability. base58btc and the varint each admit
        // more than one spelling of the same bytes — the overlong varint
        // 0x80 0xa4 0x00 decodes to 0x1200 exactly as happily as 0x80 0x24 does —
        // so without this, several distinct DID strings resolve to one key.
        //
        // That matters because everything downstream compares DIDs *as strings*:
        // a JWS `kid` against the credential's `issuer`, a presenter's DID
        // against `credentialSubject.id`. If two spellings can name one key, then
        // string inequality no longer implies different holders, and those checks
        // stop meaning what they are written to mean.
        guard try Self.did(fromP256PublicKeyX963: key.x963Representation) == did else {
            throw DIDKeyError.nonCanonicalDID
        }

        return key
    }

    /// The inverse of `base58BTCEncode`.
    ///
    /// - Throws: `DIDKeyError.invalidBase58` for any character outside the
    ///   alphabet. Quietly folding the excluded look-alikes onto their neighbours
    ///   (0 → O, l → 1) would be a kindness that yields a different key from the
    ///   one written down, which is the ambiguity the alphabet exists to remove.
    static func base58BTCDecode(_ string: String) throws -> Data {
        // The mirror of the note in `base58BTCEncode`: each leading "1" is the
        // alphabet's zero digit and stands for one literal 0x00 byte that the
        // big-integer conversion below cannot carry.
        let leadingZeros = string.prefix(while: { $0 == "1" }).count

        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.count * 733 / 1000 + 1) // log(58)/log(256) ≈ 0.733

        for character in string.dropFirst(leadingZeros) {
            guard let digit = base58DigitValues[character] else {
                throw DIDKeyError.invalidBase58
            }

            // bytes = bytes × 58 + digit, big-endian, carrying up from the low
            // end. `insert(at: 0)` is O(n) but n is 35 for a DID, and the
            // alternative — a pre-sized buffer with a write cursor — trades that
            // for an off-by-one that only shows up on inputs with a particular
            // number of digits.
            var carry = Int(digit)
            for index in bytes.indices.reversed() {
                let accumulator = Int(bytes[index]) * 58 + carry
                bytes[index] = UInt8(accumulator & 0xff)
                carry = accumulator >> 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xff), at: 0)
                carry >>= 8
            }
        }

        return Data(repeating: 0, count: leadingZeros) + Data(bytes)
    }

    /// Reads one multiformats unsigned varint (unsigned LEB128) off the front.
    ///
    /// - Returns: the code, and how many bytes it occupied — the caller needs the
    ///   second value to know where the key starts, and hardcoding 2 there would
    ///   quietly misread every non-P-256 DID before the check that rejects it.
    private static func readUnsignedVarint(_ bytes: [UInt8]) throws -> (code: UInt64, length: Int) {
        // multiformats caps unsigned varints at nine bytes / 63 bits. That cap is
        // load-bearing twice over: it bounds the work an attacker-supplied DID can
        // demand, and it keeps the shift below from ever exceeding 56.
        let maximumLength = 9
        var code: UInt64 = 0
        var shift: UInt64 = 0

        for (offset, byte) in bytes.prefix(maximumLength).enumerated() {
            code |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return (code, offset + 1)
            }
            shift += 7
        }

        // Either the DID ran out mid-varint or the varint never terminated.
        // Either way the length prefix is unreadable, and guessing where the key
        // begins is how a 33-byte window gets taken from the wrong offset.
        throw DIDKeyError.malformedMulticodec
    }
}
