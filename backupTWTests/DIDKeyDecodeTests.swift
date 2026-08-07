//
//  DIDKeyDecodeTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// Decoding is the side of `did:key` that faces an attacker.
///
/// Encoding takes a key this device just generated and turns it into a string;
/// decoding takes a string a stranger held up on a phone screen and turns it into
/// the key a signature will be checked against. So the failures these tests are
/// looking for are not "wrong output" but "output at all": every case below is
/// one where returning *some* P-256 key would let a verifier report a good
/// signature over an identity that was never in the DID.
///
/// The vectors are published ones for the same reason as in `DIDKeyTests` — a
/// decoder tested only against this repo's own encoder agrees with it on any
/// self-consistent alphabet, including a wrong one.
struct DIDKeyDecodeTests {

    // MARK: - Known vectors

    /// The P-256 example from the W3C-CCG did:key method specification. `y` is
    /// odd, so the compressed point carries the 0x03 prefix and decoding has to
    /// recover the odd root.
    @Test func decodesTheW3CCCGP256Vector() throws {
        let x = "8a0ac59a2d3086e8a12a78fd4773a6d52a0ca61ef6c1419e15a05bcc6dafce7b"
        let y = "79fb17e5bd74c7cca3cab8f89f2de919f2dc63b5dbcb52b382a39daa7b2b2483"
        let key = try DIDKey.p256PublicKey(fromDID: "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv")
        #expect(key.x963Representation == Self.x963(x: x, y: y))
    }

    /// The JWK-sourced vector, whose `y` is even — the other root, and the branch
    /// a decoder that always picks one parity gets wrong half the time.
    @Test func decodesTheJWKVector() throws {
        let x = try #require(Self.base64URLDecode("OcPddBMXKURtwbPaZ9SfwEb8vwcvzFufpRwFuXQwf5Y"))
        let y = try #require(Self.base64URLDecode("nEA7FjXwRJ8CvUInUeMxIaRDTxUvKysqP2dSGcXZJfY"))
        let key = try DIDKey.p256PublicKey(fromDID: "did:key:zDnaeUKTWUXc1HDpGfKbEK31nKLN19yX5aunFd7VK1CUMeyJu")
        #expect(key.x963Representation == Data([0x04]) + x + y)
    }

    // MARK: - Round trip

    /// The property the whole verification path rests on: whatever the encoder
    /// published, the decoder gets back. Run over many keys because the parity
    /// bit and the digit count both vary between them.
    @Test func recoversEveryKeyTheEncoderPublishes() throws {
        for _ in 0..<64 {
            let expected = P256.Signing.PrivateKey().publicKey
            let did = try DIDKey.did(fromP256PublicKeyX963: expected.x963Representation)
            let recovered = try DIDKey.p256PublicKey(fromDID: did)
            #expect(recovered.x963Representation == expected.x963Representation)
        }
    }

    /// The same round trip through the key that actually signs credentials.
    ///
    /// `P256.Signing.PrivateKey` above is CryptoKit's own key; this one comes out
    /// of the Keychain or the Secure Enclave by way of
    /// `SecKeyCopyExternalRepresentation`, which is a different code path to the
    /// X9.63 bytes. A DID that round-trips for CryptoKit keys and not for device
    /// keys would break only in production.
    @Test(.enabled(if: DIDKeyDecodeTests.keychainIsAvailable))
    func recoversTheKeyThisDeviceSignsWith() throws {
        let tag = "tw.bonds.backupTW.tests.didKeyDecode.\(UUID().uuidString)"
        defer { try? DeviceKey.deleteKey(tag: tag, installRecord: nil) }

        let device = try DeviceKey.loadOrCreate(tag: tag, installRecord: nil)
        let did = try DIDKey.did(fromP256PublicKeyX963: device.publicKeyX963)
        let recovered = try DIDKey.p256PublicKey(fromDID: did)

        #expect(recovered.x963Representation == device.publicKeyX963)

        // The reason the decoder exists, stated as the thing it enables: a
        // signature made by the device verifies under the key its DID names, with
        // nothing consulted but the DID string itself.
        let message = Data("offline presentation challenge".utf8)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: device.signature(for: message))
        #expect(recovered.isValidSignature(signature, for: message))
    }

    /// Generating a key needs a reachable Keychain, which a test bundle does not
    /// always have (`errSecMissingEntitlement`). That is an environment problem,
    /// not a defect, so the test that needs one disables itself rather than
    /// report red — same reasoning as `DeviceKeyLifecycleTests`.
    static let keychainIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.didKeyDecode.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)) != nil
    }()

    // MARK: - Not a did:key at all

    @Test(arguments: [
        "",
        "did",
        "did:key",                                              // prefix minus its colon
        "did:web:example.gov",
        "did:pkh:eip155:1:0xab16a96d359ec26a11e2c2b3d8f8b8942d5bfcdb",
        "DID:KEY:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv", // DID methods are lowercase
        "zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv",    // bare multibase, no method
        " did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv", // leading space
    ])
    func rejectsWhatIsNotADIDKey(did: String) {
        #expect(throws: DIDKeyError.notADIDKey) {
            _ = try DIDKey.p256PublicKey(fromDID: did)
        }
    }

    /// The multibase prefix has to be checked rather than assumed. `m` is base64
    /// and `f` is base16 in the multibase table; running either through the
    /// base58 alphabet does not fail, it produces different bytes — which is the
    /// one outcome a verifier cannot detect.
    @Test(arguments: [
        "did:key:",                                             // nothing after the method
        "did:key:mAbCdEfGhIjKlMnOpQrStUvWxYz",                  // base64
        "did:key:f8024036e2c6a2c6",                             // base16
        "did:key:ZDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv", // "Z" is base58 *flickr*, not btc
        "did:key:1DnaerxCtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv",
    ])
    func rejectsMultibaseEncodingsOtherThanBase58BTC(did: String) {
        #expect(throws: DIDKeyError.unsupportedMultibaseEncoding) {
            _ = try DIDKey.p256PublicKey(fromDID: did)
        }
    }

    // MARK: - Other curves

    /// Published `did:key` vectors for the curves this app does not use. All
    /// three are valid, resolvable DIDs — the failure being guarded against is
    /// not "malformed input" but "confidently returning a P-256 key built out of
    /// an Ed25519 key's bytes", which would verify nothing and say so at no
    /// point.
    @Test(arguments: [
        ("did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK", UInt64(0xed)), // Ed25519
        ("did:key:zQ3shokFTS3brHcDQrn82RUDfCZESWL1ZdCEJwekUDPQiYBme", UInt64(0xe7)), // secp256k1
        ("did:key:z6LSeu9HkTHSfLLeUs2nnzUSNedgDUevfNQgQjQC23ZCit6F", UInt64(0xec)), // X25519
    ])
    func rejectsOtherCurvesByName(did: String, multicodec: UInt64) {
        #expect(throws: DIDKeyError.unsupportedMulticodec(multicodec)) {
            _ = try DIDKey.p256PublicKey(fromDID: did)
        }
    }

    /// The two spellings of the `p256-pub` multicodec — the bytes the encoder
    /// writes and the number the decoder compares — are declared separately on
    /// purpose, so that a typo in either one is a disagreement rather than a
    /// shared mistake. This is where they are made to agree.
    ///
    /// `0x1200` needs two varint bytes; the classic error is to write it as the
    /// single byte 0x12, or as the pair 0x12 0x00, either of which shifts the key
    /// and still yields a plausible-looking DID.
    @Test func theEncodersPrefixIsTheOnlyOneTheDecoderAccepts() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let did = try DIDKey.did(fromP256PublicKeyX963: key.x963Representation)
        let payload = try DIDKey.base58BTCDecode(String(did.dropFirst("did:key:z".count)))

        #expect(Array(payload.prefix(2)) == [0x80, 0x24])
        #expect(payload.count == 35) // two prefix bytes plus a compressed point

        // The near-miss encodings of the same code, each rejected by number.
        let compressed = key.compressedRepresentation
        for prefix in [Data([0x12]), Data([0x12, 0x00])] {
            let forged = "did:key:z" + DIDKey.base58BTCEncode(prefix + compressed)
            #expect(throws: DIDKeyError.unsupportedMulticodec(0x12)) {
                _ = try DIDKey.p256PublicKey(fromDID: forged)
            }
        }
    }

    // MARK: - Malformed payloads

    /// A varint whose continuation bit never clears. Guessing that the key starts
    /// two bytes in would take a 33-byte window from the wrong offset and hand
    /// back a key that is right about nothing.
    @Test func rejectsAMulticodecThatNeverTerminates() throws {
        for length in [1, 2, 9, 12] {
            let did = "did:key:z" + DIDKey.base58BTCEncode(Data(repeating: 0x80, count: length))
            #expect(throws: DIDKeyError.malformedMulticodec, "length \(length)") {
                _ = try DIDKey.p256PublicKey(fromDID: did)
            }
        }
    }

    /// "did:key:z" with no payload at all decodes to zero bytes, so the varint
    /// read runs off the end immediately.
    @Test func rejectsAnEmptyPayload() {
        #expect(throws: DIDKeyError.malformedMulticodec) {
            _ = try DIDKey.p256PublicKey(fromDID: "did:key:z")
        }
    }

    /// Right prefix, wrong amount of key. A short point silently zero-padded, or
    /// a long one truncated, is a different key than the DID names.
    @Test(arguments: [0, 1, 31, 32, 34, 35, 64, 65])
    func rejectsCompressedPointsOfTheWrongLength(count: Int) {
        let payload = Data([0x80, 0x24]) + Data(repeating: 0x02, count: count)
        let did = "did:key:z" + DIDKey.base58BTCEncode(payload)
        #expect(throws: DIDKeyError.invalidCompressedPointLength(count)) {
            _ = try DIDKey.p256PublicKey(fromDID: did)
        }
    }

    /// 33 bytes, but not a point.
    ///
    /// `x` is all-ones, which exceeds the field prime, so it is invalid whatever
    /// the parity byte says. Note what cannot be used here: flipping a byte of a
    /// real key lands on the curve roughly half the time (measured: 84 of 200
    /// random `x` values), so "mutate and expect a throw" would be a test that
    /// passes at a coin flip.
    @Test(arguments: [UInt8(0x02), UInt8(0x03)])
    func rejectsCoordinatesOutsideTheField(parity: UInt8) {
        let payload = Data([0x80, 0x24, parity]) + Data(repeating: 0xff, count: 32)
        let did = "did:key:z" + DIDKey.base58BTCEncode(payload)
        #expect(throws: DIDKeyError.invalidPublicKey) {
            _ = try DIDKey.p256PublicKey(fromDID: did)
        }
    }

    /// Only 0x02 and 0x03 mark a compressed point. 0x04 is the *uncompressed*
    /// marker at a length that cannot hold an uncompressed key, and 0x00 marks
    /// nothing at all.
    @Test(arguments: [UInt8(0x00), UInt8(0x01), UInt8(0x04), UInt8(0x05), UInt8(0x06)])
    func rejectsNonCompressedPointMarkers(marker: UInt8) throws {
        let key = P256.Signing.PrivateKey().publicKey
        let coordinates = key.compressedRepresentation.dropFirst()
        let did = "did:key:z" + DIDKey.base58BTCEncode(Data([0x80, 0x24, marker]) + coordinates)
        #expect(throws: DIDKeyError.invalidPublicKey) {
            _ = try DIDKey.p256PublicKey(fromDID: did)
        }
    }

    // MARK: - Canonicality

    /// An overlong varint: 0x80 0xa4 0x00 is 0x1200 with a redundant
    /// continuation, and it decodes to the same code and the same key. Accepting
    /// it would mean two different DID strings name one holder — and every
    /// identity check downstream (a JWS `kid` against `issuer`, a presenter's DID
    /// against `credentialSubject.id`) compares those strings, so string
    /// inequality has to keep meaning "different holder".
    @Test func rejectsANonMinimalMulticodecVarint() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let canonical = try DIDKey.did(fromP256PublicKeyX963: key.x963Representation)
        let overlong = "did:key:z" + DIDKey.base58BTCEncode(Data([0x80, 0xa4, 0x00]) + key.compressedRepresentation)

        // The premise: it really is a second spelling of the same key, not just
        // garbage. Without this the test could pass for the wrong reason.
        #expect(overlong != canonical)

        #expect(throws: DIDKeyError.nonCanonicalDID) {
            _ = try DIDKey.p256PublicKey(fromDID: overlong)
        }
        #expect(try DIDKey.p256PublicKey(fromDID: canonical).x963Representation == key.x963Representation)
    }

    /// A leading 0x00 byte survives base58 as a leading "1", so it is a real
    /// alternative spelling rather than an impossible one — and it shifts the
    /// varint read onto a zero byte, which is multicodec `identity`, not P-256.
    @Test func rejectsAPayloadPaddedWithLeadingZeroBytes() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let padded = "did:key:z" + DIDKey.base58BTCEncode(Data([0x00, 0x80, 0x24]) + key.compressedRepresentation)
        #expect(padded.hasPrefix("did:key:z1"))
        #expect(throws: DIDKeyError.unsupportedMulticodec(0x00)) {
            _ = try DIDKey.p256PublicKey(fromDID: padded)
        }
    }

    // MARK: - Hostile input

    /// Truncating or extending a valid DID by one digit changes the whole
    /// big-integer value, so the failure can surface at any layer. What must not
    /// happen is a key coming back.
    @Test func rejectsSingleDigitTruncationAndExtension() throws {
        for _ in 0..<32 {
            let key = P256.Signing.PrivateKey().publicKey
            let did = try DIDKey.did(fromP256PublicKeyX963: key.x963Representation)

            #expect(throws: DIDKeyError.self) {
                _ = try DIDKey.p256PublicKey(fromDID: String(did.dropLast()))
            }
            #expect(throws: DIDKeyError.self) {
                _ = try DIDKey.p256PublicKey(fromDID: did + "2")
            }
        }
    }

    /// The excluded look-alikes must be refused, not folded onto their
    /// neighbours. A decoder that reads "0" as "O" turns a mistyped DID into a
    /// valid one for somebody else's key.
    @Test(arguments: ["0", "O", "I", "l", "+", "/", "=", " ", "-", "\u{0}", "字", "🙂"])
    func rejectsCharactersOutsideTheAlphabet(character: String) {
        let base = "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZp"
        #expect(throws: DIDKeyError.invalidBase58) {
            _ = try DIDKey.p256PublicKey(fromDID: base + character)
        }
    }

    /// Base conversion is quadratic in the digit count, and the DID arrives from
    /// a QR held by a stranger. The bound is checked before any decoding, so this
    /// has to return rather than grind — 50 000 digits took 1.3 s unbounded on a
    /// desktop, which is several seconds on the oldest phone this app supports.
    @Test func rejectsAnIdentifierTooLongToBeADIDKey() {
        let started = Date()
        #expect(throws: DIDKeyError.oversizedDID) {
            _ = try DIDKey.p256PublicKey(fromDID: "did:key:z" + String(repeating: "z", count: 200_000))
        }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    /// The bound has to clear every real `did:key`, not merely our own.
    ///
    /// P-384 and P-521 identifiers are 69 and 95 digits, past the 48 a P-256 DID
    /// takes and past any ceiling drawn snugly around it. Refusing them for
    /// length would tell a holder their credential is malformed when the honest
    /// answer is that this app only reads P-256 — so the bound sits high enough
    /// that they reach the multicodec check and are named there.
    ///
    /// The keys are built here rather than quoted from the spec so the vector
    /// cannot be a misremembered string. The varint spelling is the part worth
    /// corroborating, and it is: the published P-521 DID
    /// `did:key:z2J9gaYxrKVpdoG9A4gRnmpnRCcxU6agDtFVVBVdn1Jedouo…` decodes to
    /// 0x82 0x24 followed by a 67-byte compressed point, which is exactly the
    /// shape below.
    @Test func namesTheCurveOfLongerDIDsRatherThanRefusingThemForLength() throws {
        let longer: [(UInt64, Data, Data)] = [
            (0x1201, Data([0x81, 0x24]), P384.Signing.PrivateKey().publicKey.compressedRepresentation),
            (0x1202, Data([0x82, 0x24]), P521.Signing.PrivateKey().publicKey.compressedRepresentation),
        ]

        for (multicodec, varint, compressed) in longer {
            let did = "did:key:z" + DIDKey.base58BTCEncode(varint + compressed)
            // The premise: these really are longer than a P-256 DID, so the
            // length path is the one that would have caught them.
            #expect(did.count > 57)
            #expect(throws: DIDKeyError.unsupportedMulticodec(multicodec)) {
                _ = try DIDKey.p256PublicKey(fromDID: did)
            }
        }
    }

    /// A run of "1"s is all leading zeros, so it never enters the base conversion
    /// at all — the one long input that is cheap, and therefore the one that
    /// would slip past a bound placed only on the decoded byte count.
    @Test func rejectsALongRunOfZeroDigitsWithoutDecodingItAsAKey() {
        #expect(throws: DIDKeyError.oversizedDID) {
            _ = try DIDKey.p256PublicKey(fromDID: "did:key:z" + String(repeating: "1", count: 100_000))
        }
        #expect(throws: DIDKeyError.unsupportedMulticodec(0x00)) {
            _ = try DIDKey.p256PublicKey(fromDID: "did:key:z" + String(repeating: "1", count: 40))
        }
    }

    // MARK: - base58btc decoding

    /// The reference vectors from draft-msporny-base58, decoded rather than
    /// encoded. These are what stop the alphabet from being self-consistently
    /// wrong: the encoder and decoder share a table, so only an outside vector
    /// can tell whether that table is right.
    @Test func decodesBase58ReferenceVectors() throws {
        #expect(try DIDKey.base58BTCDecode("2NEpo7TZRRrLZSi2U") == Data("Hello World!".utf8))
        #expect(try DIDKey.base58BTCDecode("USm3fpXnKG5EUBx2ndxBDMPVciP5hGey2Jh4NDv6gmeo1LkMeiKrLJUUBk6Z")
                == Data("The quick brown fox jumps over the lazy dog.".utf8))
        #expect(try DIDKey.base58BTCDecode("2g") == Data([0x61]))
        #expect(try DIDKey.base58BTCDecode("5Q") == Data([0xff]))
        #expect(try DIDKey.base58BTCDecode("LUv") == Data([0xff, 0xff]))
    }

    /// The boundary the base-conversion cannot express on its own: leading zero
    /// bytes have no numeric value, so each one has to be carried across as a
    /// literal "1". Getting this wrong shortens the payload, which for a DID
    /// means the multicodec and the key both shift.
    @Test func restoresLeadingZeroBytes() throws {
        #expect(try DIDKey.base58BTCDecode("") == Data())
        #expect(try DIDKey.base58BTCDecode("1") == Data([0x00]))
        #expect(try DIDKey.base58BTCDecode("11") == Data([0x00, 0x00]))
        #expect(try DIDKey.base58BTCDecode("111") == Data([0x00, 0x00, 0x00]))
        // draft-msporny-base58 §Test Vectors: two leading zeros plus a payload.
        #expect(try DIDKey.base58BTCDecode("11233QC4") == Data([0x00, 0x00, 0x28, 0x7f, 0xb4, 0xcd]))
        // A "1" that is not leading is the digit zero, not a byte.
        #expect(try DIDKey.base58BTCDecode("12") == Data([0x00, 0x01]))
        #expect(try DIDKey.base58BTCDecode("21") == Data([0x3a]))
    }

    /// Round trip in the direction the encoder's own tests cannot check, over
    /// inputs chosen for the leading-zero boundary rather than at random.
    @Test func roundTripsArbitraryBytes() throws {
        var cases: [Data] = [Data(), Data(0...255), Data([0x00]), Data([0x00, 0x00, 0x01])]
        for length in 0...40 {
            var bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            cases.append(bytes)
            if length > 0 {
                bytes[0] = 0
                cases.append(bytes)
            }
            if length > 1 {
                bytes[1] = 0
                cases.append(bytes)
            }
        }

        for bytes in cases {
            let encoded = DIDKey.base58BTCEncode(bytes)
            #expect(try DIDKey.base58BTCDecode(encoded) == bytes, "\(Array(bytes))")
        }
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
