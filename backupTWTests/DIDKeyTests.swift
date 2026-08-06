//
//  DIDKeyTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// The DID is the holder's identity: get one byte of the encoding wrong and the
/// app still produces a plausible-looking `did:key:zDnae…` that no verifier can
/// resolve back to our key. Every vector below is a published one, so a failure
/// here means our encoder is wrong rather than the vector being unusual.
struct DIDKeyTests {

    // MARK: - Known vectors

    /// The P-256 example from the W3C-CCG did:key method specification
    /// (§Test Vectors). `y` is odd, so the compressed point takes the 0x03
    /// prefix — the branch a naive implementation that hardcodes 0x02 gets wrong.
    @Test func encodesW3CCCGP256Vector() throws {
        let x = "8a0ac59a2d3086e8a12a78fd4773a6d52a0ca61ef6c1419e15a05bcc6dafce7b"
        let y = "79fb17e5bd74c7cca3cab8f89f2de919f2dc63b5dbcb52b382a39daa7b2b2483"
        let did = try DIDKey.did(fromP256PublicKeyX963: Self.x963(x: x, y: y))
        #expect(did == "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv")
    }

    /// A second, independently sourced vector, published as a JWK. `y` is even
    /// here, covering the 0x02 prefix.
    @Test func encodesJWKVector() throws {
        let x = try #require(Self.base64URLDecode("OcPddBMXKURtwbPaZ9SfwEb8vwcvzFufpRwFuXQwf5Y"))
        let y = try #require(Self.base64URLDecode("nEA7FjXwRJ8CvUInUeMxIaRDTxUvKysqP2dSGcXZJfY"))
        let did = try DIDKey.did(fromP256PublicKeyX963: Data([0x04]) + x + y)
        #expect(did == "did:key:zDnaeUKTWUXc1HDpGfKbEK31nKLN19yX5aunFd7VK1CUMeyJu")
    }

    /// The multicodec prefix for `p256-pub` (0x1200) is the two-byte varint
    /// 0x80 0x24. Encoding it as the single byte 0x12, or as 0x12 0x00, shifts
    /// every following byte and changes the DID — but only in ways that still
    /// look like a valid DID. Pinning the constant prefix catches that class of
    /// mistake without needing a resolver.
    @Test func everyP256DIDSharesThePrefixAndLength() throws {
        for _ in 0..<32 {
            let key = P256.Signing.PrivateKey().publicKey
            let did = try DIDKey.did(fromP256PublicKeyX963: key.x963Representation)
            #expect(did.hasPrefix("did:key:zDnae"))
            #expect(did.count == 57)
        }
    }

    // MARK: - Rejected input

    @Test(arguments: [0, 32, 33, 64, 66, 130])
    func rejectsWrongLength(count: Int) {
        let data = Data(repeating: 0x04, count: count)
        #expect(throws: DIDKeyError.invalidPublicKeyLength(count)) {
            _ = try DIDKey.did(fromP256PublicKeyX963: data)
        }
    }

    /// Right length, wrong point. Producing a DID from this would create an
    /// identity whose signatures can never verify.
    @Test func rejectsPointNotOnCurve() {
        let data = Data([0x04]) + Data(repeating: 0x01, count: 64)
        #expect(throws: DIDKeyError.invalidPublicKey) {
            _ = try DIDKey.did(fromP256PublicKeyX963: data)
        }
    }

    /// Compressed (0x02/0x03) and hybrid (0x06/0x07) points are all 65 bytes or
    /// fewer; only the uncompressed 0x04 form is accepted here.
    @Test func rejectsNonUncompressedMarker() {
        let data = Data([0x05]) + Data(repeating: 0x01, count: 64)
        #expect(throws: DIDKeyError.invalidPublicKey) {
            _ = try DIDKey.did(fromP256PublicKeyX963: data)
        }
    }

    // MARK: - base58btc

    /// Vectors from draft-msporny-base58, which multibase references for the "z"
    /// prefix.
    @Test func encodesBase58ReferenceVectors() {
        #expect(DIDKey.base58BTCEncode(Data("Hello World!".utf8)) == "2NEpo7TZRRrLZSi2U")
        #expect(DIDKey.base58BTCEncode(Data("The quick brown fox jumps over the lazy dog.".utf8))
                == "USm3fpXnKG5EUBx2ndxBDMPVciP5hGey2Jh4NDv6gmeo1LkMeiKrLJUUBk6Z")
    }

    /// Leading zero bytes carry no numeric value, so big-integer division drops
    /// them; base58btc re-attaches each one as a literal "1". P-256 DIDs never
    /// exercise this (the multicodec prefix starts at 0x80), which is precisely
    /// why it needs its own coverage.
    @Test func preservesLeadingZeroBytes() {
        #expect(DIDKey.base58BTCEncode(Data()) == "")
        #expect(DIDKey.base58BTCEncode(Data([0x00])) == "1")
        #expect(DIDKey.base58BTCEncode(Data([0x00, 0x00])) == "11")
        #expect(DIDKey.base58BTCEncode(Data([0x00, 0x00, 0x00])) == "111")
        // draft-msporny-base58 §Test Vectors: two leading zeros plus a payload.
        #expect(DIDKey.base58BTCEncode(Data([0x00, 0x00, 0x28, 0x7f, 0xb4, 0xcd])) == "11233QC4")
        // A zero byte that is not leading must not produce a "1".
        #expect(DIDKey.base58BTCEncode(Data([0x00, 0x01])) == "12")
    }

    /// 0, O, I and l are absent so that a DID read aloud stays unambiguous. A
    /// transposed alphabet would still round-trip within our own code, so the
    /// check has to be against the digits themselves.
    @Test func usesTheBitcoinAlphabet() {
        // 0x61 is 97 == 1×58 + 39, i.e. digits [1, 39] -> "2g".
        #expect(DIDKey.base58BTCEncode(Data([0x61])) == "2g")
        #expect(DIDKey.base58BTCEncode(Data([0xff])) == "5Q")
        #expect(DIDKey.base58BTCEncode(Data([0xff, 0xff])) == "LUv")

        let encoded = DIDKey.base58BTCEncode(Data(0...255))
        #expect(!encoded.contains(where: { "0OIl".contains($0) }))
    }

    // MARK: - Helpers

    private static func x963(x: String, y: String) -> Data {
        Data([0x04]) + hex(x) + hex(y)
    }

    private static func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex, let end = string.index(index, offsetBy: 2, limitedBy: string.endIndex) {
            guard let byte = UInt8(string[index..<end], radix: 16) else { return data }
            data.append(byte)
            index = end
        }
        return data
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var padded = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

/// Lives here rather than in a `DeviceKeyTests` file because it is the one part
/// of `DeviceKey` that runs identically off-device: everything else needs a real
/// keychain. The DER-to-raw conversion is also the part most likely to be subtly
/// wrong, since a broken implementation still produces correct-looking output
/// most of the time.
struct DeviceKeySignatureFormatTests {

    /// CryptoKit knows both encodings, so it can act as the reference: for any
    /// signature, converting its DER form must reproduce its raw form exactly.
    @Test func matchesCryptoKitForRandomSignatures() throws {
        let key = P256.Signing.PrivateKey()
        for index in 0..<64 {
            let signature = try key.signature(for: Data("message \(index)".utf8))
            let converted = try DeviceKey.rawSignature(fromDER: signature.derRepresentation)
            #expect(converted.count == 64)
            #expect(converted == signature.rawRepresentation)
        }
    }

    /// The two encodings only diverge on specific values, and random sampling
    /// reaches the short-component case roughly once in 256 signatures. These
    /// construct the awkward components directly.
    ///
    /// - `r` starting with 0x00: DER drops the byte, so the INTEGER is short and
    ///   the result must be left-padded back to 32 bytes.
    /// - `s` with the top bit set: DER prepends a 0x00 so the INTEGER is not read
    ///   as negative, and that byte must be stripped again.
    @Test func normalisesComponentsToThirtyTwoBytes() throws {
        let leadingBytes: [(UInt8, UInt8)] = [
            (0x00, 0xff), // short r, padded s
            (0xff, 0x00), // padded r, short s
            (0x00, 0x00), // both short
            (0xff, 0xff), // both padded
            (0x01, 0x7f), // neither
        ]

        for (first, second) in leadingBytes {
            var raw = Data(repeating: 0x42, count: 64)
            raw[raw.startIndex] = first
            raw[raw.startIndex + 32] = second

            let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
            let converted = try DeviceKey.rawSignature(fromDER: signature.derRepresentation)
            #expect(converted == raw, "leading bytes \(first), \(second)")
        }
    }

    /// A component of 1 is 31 leading zero bytes in raw form and a single byte in
    /// DER — the extreme of the same normalisation.
    @Test func handlesMinimalComponents() throws {
        var raw = Data(repeating: 0x00, count: 64)
        raw[raw.startIndex + 31] = 0x01
        raw[raw.startIndex + 63] = 0x01

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(try DeviceKey.rawSignature(fromDER: signature.derRepresentation) == raw)
    }

    /// Malformed input has to throw rather than return a short or misaligned
    /// signature: a 63-byte "signature" would be rejected far downstream, by a
    /// verifier, with no clue as to why.
    @Test(arguments: [
        Data(),                                     // empty
        Data([0x30]),                               // sequence tag, no length
        Data([0x31, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]), // wrong tag
        Data([0x30, 0x06, 0x02, 0x01, 0x01]),       // length overruns the payload
        Data([0x30, 0x04, 0x02, 0x01, 0x01, 0x02]), // truncated second INTEGER
        Data([0x30, 0x06, 0x04, 0x01, 0x01, 0x02, 0x01, 0x01]), // not an INTEGER
        Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01, 0x00]), // trailing byte
        Data([0x30, 0x06, 0x02, 0x00, 0x02, 0x01, 0x01]), // zero-length INTEGER
    ])
    func rejectsMalformedDER(der: Data) {
        #expect(throws: DeviceKeyError.self) {
            _ = try DeviceKey.rawSignature(fromDER: der)
        }
    }

    /// An oversized component cannot be padded into 32 bytes, and silently
    /// truncating it would corrupt the signature.
    @Test func rejectsOversizedComponent() {
        var der = Data([0x30, 0x46, 0x02, 0x21])
        der.append(Data(repeating: 0x01, count: 33))
        der.append(contentsOf: [0x02, 0x21])
        der.append(Data(repeating: 0x01, count: 33))

        #expect(throws: DeviceKeyError.self) {
            _ = try DeviceKey.rawSignature(fromDER: der)
        }
    }
}
