//
//  JWKDIDKeyTests.swift
//  backupTWTests
//
//  The second did:key spelling — the one TWDIW uses, and does not itself obey.
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// # Fixtures are real, and that is the point
///
/// Both DIDs below were taken from live TWDIW responses on 2026-08-16 —
/// `GET https://frontend.wallet.gov.tw/api/did?…` for the ministry, and the
/// `sub` of a sandbox-issued credential for the wallet. A round-trip test
/// against DIDs this codebase generated would pass with the member ordering
/// wrong, the multicodec wrong, or both, because it would be checking that we
/// agree with ourselves.
@Suite("did:key 的第二種拼法（jwk_jcs-pub）")
struct JWKDIDKeyTests {

    /// 行政院-數位發展部, from the production trust list. Canonical.
    static let ministryDID = "did:key:z2dmzD81cgPx8Vki7JbuuMmFYrWPgYoytykUZ3eyqht1j9Kbrzifm9txeerMVc9oLUg2nBJJnUtgYcAYd35rw1rCLq8y3bLDDBUPH5yTYB7ocY7oPESPBXqubuwMcRzw9evbeHHyFkwsmDc43myibDChGhDk8zrgZDB4KNyXPiQvkktUwn"

    /// The official wallet's holder DID. **Not** canonical: `kty` is last.
    static let officialWalletDID = "did:key:z2dmzD81cgPx8Vki7JbuuMmFYrWPodrZSqMbCy9Ndu4UgUGy3RNkhH479eLPpbfAhVSNu7B4oJvUwLzyxiP4Jt5k9cqqmChanxAazTGxJMvGxYDApNkXeDW5MPZgZRkjRgD1yaig5KCEgAaVbg8zrvYjMTi1BzqdDpPpkeSFmJwiej9YNY"

    /// What that wallet's DID *would* be if it were spelled per the codec.
    /// A different string for the same key, which is the whole difficulty.
    static let officialWalletCanonicalDID = "did:key:z2dmzD81cgPx8Vki7JbuuMmFYrWPgYoytykUZ3eyqht1j9KbnhCBwrGzqyVmK7CZc45E1Gsnwud4DCC5LELR1guUsX2p8zZDMKNhgtvBMsNL3Key6Xs6ZvMLorTbhiqutKH5gPiMr4BPFfC3SWpKDdiyXdBk9d8JfiHVuSbXAs48M6yq9W"

    // MARK: The two facts the whole design rests on

    /// A real government DID decodes, and re-encodes to itself byte for byte.
    ///
    /// This is what says our encoder agrees with the ecosystem rather than only
    /// with itself: the ministry spelled this string, not us.
    @Test func aRealMinistryDIDRoundTripsExactly() throws {
        let key = try JWKDIDKey.p256PublicKey(fromDID: Self.ministryDID)
        #expect(try JWKDIDKey.did(fromP256PublicKeyX963: key.x963Representation) == Self.ministryDID)
        #expect(JWKDIDKey.isCanonical(Self.ministryDID))
    }

    /// **The reason the decoder is permissive.**
    ///
    /// `jwk_jcs-pub` means the JWK is canonicalised per RFC 8785, which orders
    /// members `crv` < `kty` < `x` < `y`. The official wallet emits
    /// `crv, x, y, kty`. Every credential in production was issued to a DID
    /// spelled that way, so a decoder that enforced the codec's own rule would
    /// reject the only Taiwanese wallet there is.
    @Test func theOfficialWalletsOwnDIDIsNotCanonicalAndIsAcceptedAnyway() throws {
        #expect(!JWKDIDKey.isCanonical(Self.officialWalletDID))
        // Accepted regardless: the bytes of the key are unambiguous either way.
        _ = try JWKDIDKey.p256PublicKey(fromDID: Self.officialWalletDID)
    }

    /// And it is not a near miss — the canonical spelling is a wholly different
    /// string. Anything comparing DIDs as they arrive would call these two
    /// different holders.
    @Test func theTwoSpellingsOfTheSameKeyAreDifferentStrings() throws {
        #expect(Self.officialWalletDID != Self.officialWalletCanonicalDID)
        let fromRaw = try JWKDIDKey.p256PublicKey(fromDID: Self.officialWalletDID)
        let fromCanonical = try JWKDIDKey.p256PublicKey(fromDID: Self.officialWalletCanonicalDID)
        #expect(fromRaw.x963Representation == fromCanonical.x963Representation)
    }

    /// **How the cost of permissiveness is paid.** `canonicalDID` is the
    /// comparison key: two DIDs name one holder exactly when these agree.
    @Test func canonicalisingCollapsesBothSpellingsOntoOne() throws {
        #expect(try JWKDIDKey.canonicalDID(fromDID: Self.officialWalletDID)
                == Self.officialWalletCanonicalDID)
        #expect(try JWKDIDKey.canonicalDID(fromDID: Self.officialWalletCanonicalDID)
                == Self.officialWalletCanonicalDID)
    }

    /// Idempotent, which is what makes it safe to apply without tracking
    /// whether it has been applied.
    @Test func canonicalisingTwiceChangesNothing() throws {
        let once = try JWKDIDKey.canonicalDID(fromDID: Self.officialWalletDID)
        #expect(try JWKDIDKey.canonicalDID(fromDID: once) == once)
    }

    // MARK: The two codecs stay apart

    /// This app's own DIDs are unchanged and are **not** silently readable as
    /// the other codec. A decoder that shrugged at the multicodec would take a
    /// 33-byte compressed point and try to parse it as JSON.
    @Test func thisAppsOwnDIDIsRefusedByTheOtherDecoder() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let ours = try DIDKey.did(fromP256PublicKeyX963: key.x963Representation)

        do {
            _ = try JWKDIDKey.p256PublicKey(fromDID: ours)
            Issue.record("a p256-pub DID was accepted as jwk_jcs-pub")
        } catch let error as JWKDIDKeyError {
            #expect(error == .unsupportedMulticodec(0x1200))
        }
    }

    /// And the reverse, so neither decoder is quietly doing the other's job.
    @Test func aJWKDIDIsRefusedByTheP256PubDecoder() throws {
        do {
            _ = try DIDKey.p256PublicKey(fromDID: Self.ministryDID)
            Issue.record("a jwk_jcs-pub DID was accepted as p256-pub")
        } catch let error as DIDKeyError {
            #expect(error == .unsupportedMulticodec(JWKDIDKey.jwkJCSPublicKeyMulticodecCode))
        }
    }

    /// Both spellings of one key round-trip through their own codec, so holding
    /// two identifiers for one device key is a real option rather than an
    /// accident waiting to be discovered.
    @Test func oneKeyHasBothIdentifiersAndEachDecodesToIt() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let x963 = key.x963Representation

        let ours = try DIDKey.did(fromP256PublicKeyX963: x963)
        let theirs = try JWKDIDKey.did(fromP256PublicKeyX963: x963)
        #expect(ours != theirs)

        #expect(try DIDKey.p256PublicKey(fromDID: ours).x963Representation == x963)
        #expect(try JWKDIDKey.p256PublicKey(fromDID: theirs).x963Representation == x963)
    }

    /// The multicodec bytes and the number are declared independently, so a
    /// typo in either shows up here rather than as a DID that resolves nowhere.
    @Test func theMulticodecBytesAndTheCodeAgree() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let did = try JWKDIDKey.did(fromP256PublicKeyX963: key.x963Representation)
        let bytes = try DIDKey.base58BTCDecode(String(did.dropFirst("did:key:z".count)))
        // D1 D6 03 is the LEB128 varint for 0xEB51.
        #expect(Array(bytes.prefix(3)) == [0xD1, 0xD6, 0x03])
        #expect(JWKDIDKey.jwkJCSPublicKeyMulticodecCode == 0xEB51)
    }

    // MARK: Everything else is a refusal, not a repair

    @Test func aMemberOrderingIsToleratedButAWrongCurveIsNot() throws {
        let jwk = Data(#"{"crv":"P-384","kty":"EC","x":"AA","y":"AA"}"#.utf8)
        do {
            _ = try JWKDIDKey.p256PublicKey(fromJWKBytes: jwk)
            Issue.record("a P-384 JWK was accepted")
        } catch let error as JWKDIDKeyError {
            #expect(error == .unsupportedKeyType(kty: "EC", crv: "P-384"))
        }
    }

    @Test func aCoordinateThatIsNotThirtyTwoBytesIsRefused() throws {
        let short = VerifiableCredential.base64URLEncoded(Data(repeating: 1, count: 31))
        let full = VerifiableCredential.base64URLEncoded(Data(repeating: 2, count: 32))
        let jwk = Data(#"{"crv":"P-256","kty":"EC","x":"\#(short)","y":"\#(full)"}"#.utf8)
        #expect(throws: JWKDIDKeyError.malformedCoordinate) {
            try JWKDIDKey.p256PublicKey(fromJWKBytes: jwk)
        }
    }

    /// Standard base64 is refused rather than accepted as a kindness: `+` and
    /// `/` decode to different bytes under the two alphabets, so tolerating them
    /// means a coordinate that reads cleanly and names a different point.
    @Test func standardBase64InACoordinateIsRefused() throws {
        // Chosen so both disputed characters actually appear: 0xFB opens with
        // the six bits 111110 (index 62, `-` / `+`) and a run of 0xFF gives
        // index 63 (`_` / `/`). The first attempt at this fixture used an
        // arithmetic pattern and produced neither, so the test asserted nothing
        // — which is why the guard below is an assertion and not a comment.
        var coordinate = VerifiableCredential.base64URLEncoded(
            Data([0xFB] + Array(repeating: UInt8(0xFF), count: 31)))
        #expect(coordinate.contains("-") && coordinate.contains("_"))
        coordinate = coordinate.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let jwk = Data(#"{"crv":"P-256","kty":"EC","x":"\#(coordinate)","y":"\#(coordinate)"}"#.utf8)
        #expect(throws: JWKDIDKeyError.malformedCoordinate) {
            try JWKDIDKey.p256PublicKey(fromJWKBytes: jwk)
        }
    }

    /// A well-formed JWK naming a point that is not on P-256. Nothing in the
    /// encoding prevents it; CryptoKit is what does.
    @Test func aPointThatIsNotOnTheCurveIsRefused() throws {
        let bogus = VerifiableCredential.base64URLEncoded(Data(repeating: 0xAB, count: 32))
        let jwk = Data(#"{"crv":"P-256","kty":"EC","x":"\#(bogus)","y":"\#(bogus)"}"#.utf8)
        #expect(throws: JWKDIDKeyError.invalidPublicKey) {
            try JWKDIDKey.p256PublicKey(fromJWKBytes: jwk)
        }
    }

    @Test func nonJSONAfterTheMulticodecIsRefused() {
        #expect(throws: JWKDIDKeyError.malformedJWK) {
            try JWKDIDKey.p256PublicKey(fromJWKBytes: Data([0x00, 0x01, 0x02]))
        }
    }

    @Test func aMultibasePrefixOtherThanZIsRefused() {
        #expect(throws: JWKDIDKeyError.unsupportedMultibaseEncoding) {
            try JWKDIDKey.p256PublicKey(fromDID: "did:key:mAAAA")
        }
    }

    @Test func somethingThatIsNotADIDKeyIsRefused() {
        #expect(throws: JWKDIDKeyError.notADIDKey) {
            try JWKDIDKey.p256PublicKey(fromDID: "https://example.tw/keys/1")
        }
    }

    /// Base conversion is quadratic in the digit count and this string arrives
    /// from a stranger's QR code, so the length is bounded before any of it is
    /// interpreted.
    @Test func anAbsurdlyLongIdentifierIsRefusedBeforeItIsDecoded() {
        let long = "did:key:z" + String(repeating: "1", count: 2000)
        #expect(throws: JWKDIDKeyError.oversizedDID) {
            try JWKDIDKey.p256PublicKey(fromDID: long)
        }
    }

    /// No error may carry any part of the DID. A DID is a stable, correlatable
    /// identifier for its holder, and an error string is exactly how one reaches
    /// a log or a crash report.
    @Test func noErrorCarriesAnyPartOfTheDID() {
        let secret = "z2dmzD81cgPx8Vki7JbuuMmFYrWPodrZSqMbCy9Ndu4UgUGy3RNkhH479eLPpbfAhVSNu7B4oJv"
        let malformed = "did:key:" + secret + "!!!"
        do {
            _ = try JWKDIDKey.p256PublicKey(fromDID: malformed)
            Issue.record("a DID with a bad base58 character decoded")
        } catch {
            let text = "\(error)"
            #expect(!text.contains(secret))
            #expect(!text.contains("z2dmzD81"))
        }
    }
}
