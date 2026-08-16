//
//  JWKDIDKey.swift
//  backupTW
//

import CryptoKit
import Foundation

enum JWKDIDKeyError: Error, Equatable {

    // MARK: Encoding

    /// An X9.63 uncompressed P-256 key is exactly 65 bytes.
    case invalidPublicKeyLength(Int)
    /// Right length, but not a point on P-256.
    case invalidPublicKey

    // MARK: Decoding

    /// Not a `did:key:` DID at all.
    case notADIDKey
    /// The multibase prefix is not `z` (base58btc).
    case unsupportedMultibaseEncoding
    /// Longer than any DID this decoder will look at. See the bound below.
    case oversizedDID
    /// A character outside the base58btc alphabet.
    case invalidBase58
    /// The multicodec varint runs off the end of the decoded bytes.
    case malformedMulticodec
    /// A well-formed multicodec for some other key type. `0x1200` is the
    /// `p256-pub` spelling this app issues itself — a real DID for the same kind
    /// of key, just not this codec, so it is named rather than lumped in with
    /// junk. See `DIDKey` for that one.
    case unsupportedMulticodec(UInt64)
    /// The bytes after the multicodec are not JSON, or not a JSON object.
    case malformedJWK
    /// A JWK this decoder cannot turn into a P-256 signing key. Carries the two
    /// fields that say why, which describe a *format* and not a person — the
    /// same rule as `DIDKeyError`: nothing here may carry any part of the DID,
    /// because a DID is a stable correlatable identifier for its holder and an
    /// error string is exactly how one reaches a log or a crash report.
    case unsupportedKeyType(kty: String, crv: String)
    /// `x` or `y` missing, not base64url, or not 32 bytes.
    case malformedCoordinate
}

/// `did:key` in the spelling TWDIW uses: multicodec `jwk_jcs-pub` (0xEB51),
/// whose payload is the JWK itself, as JSON text.
///
/// # Why a second spelling rather than a replacement
///
/// This app's own credentials use `DIDKey` — multicodec `p256-pub` (0x1200),
/// payload a 33-byte compressed point, identifier always 48 base58 characters.
/// That is the right identifier for a document the holder issues to themselves,
/// and **none of it changes**. The offline path's DIDs stay as they are.
///
/// The台灣數位憑證皮夾 ecosystem uses the other codec, and it is not optional:
/// its issuer strips a **hardcoded** three-byte prefix (`D1 D6 03`, the varint
/// for 0xEB51) without checking the multibase character or the multicodec at
/// all, then parses whatever is left as JSON. A `did:key:zDn…` handed to it is
/// silently truncated and fails to parse. So interoperating means speaking this
/// codec, and speaking it means carrying both.
///
/// # The asymmetry, which is deliberate
///
/// **Everything this type produces is JCS-canonical. Nothing it accepts is
/// required to be.**
///
/// `jwk_jcs-pub` is defined as a JWK canonicalised per RFC 8785, which orders
/// members by UTF-16 code unit: `crv` < `kty` < `x` < `y`. Measured against
/// real DIDs on 2026-08-16:
///
///     機關（moda）      {"crv","kty","x","y"}   ✅ canonical
///     官方皮夾的 holder  {"crv","x","y","kty"}   ❌ kty last
///
/// So the wallet that every credential in production was issued to emits DIDs
/// that violate the codec they are encoded with. A decoder that enforced
/// canonicality would reject the only Taiwanese wallet that exists. Refusing to
/// interoperate over somebody else's member ordering serves nobody: the bytes of
/// the key are unambiguous either way.
///
/// # What that costs, and how it is paid
///
/// `DIDKey` re-encodes and demands an exact match, and the reason is real:
/// everything downstream compares DIDs **as strings** — a JWS `kid` against an
/// `issuer`, a presenter's DID against `credentialSubject.id`. If two spellings
/// can name one key, string inequality stops implying different holders and
/// those checks stop meaning what they are written to mean.
///
/// Accepting non-canonical input here reopens exactly that. It is closed a
/// different way: **compare `canonicalDID(fromDID:)`, never the raw string.**
/// Two DIDs name the same key if and only if their canonical forms are equal,
/// and the canonical form is computed from the key, so no spelling can hide
/// behind another. Any comparison on this path that uses `==` on the strings as
/// they arrived is a bug, and the doc comment on that function says so where a
/// reader will meet it.
enum JWKDIDKey {

    /// multicodec `jwk_jcs-pub` (0xEB51) as an unsigned LEB128 varint.
    ///
    /// Three bytes. Declared as literal bytes, with the code below declared
    /// independently as a number and the two pinned against each other by a
    /// test — the same arrangement as `DIDKey`, and for the same reason: derive
    /// one from the other and they agree even when both are wrong.
    private static let jwkJCSPublicKeyMulticodec = Data([0xD1, 0xD6, 0x03])

    static let jwkJCSPublicKeyMulticodecCode: UInt64 = 0xEB51

    private static let didKeyPrefix = "did:key:"

    // MARK: - Encoding

    /// - Parameter x963: Uncompressed public key, `0x04 || X || Y` — what
    ///   `DeviceKey.publicKeyX963` hands back.
    /// - Returns: `did:key:z2dmzD81…`, about 190 characters. Four times the
    ///   length of the `p256-pub` spelling, because the payload is JSON text
    ///   rather than a compressed point.
    static func did(fromP256PublicKeyX963 x963: Data) throws -> String {
        guard x963.count == 65 else {
            throw JWKDIDKeyError.invalidPublicKeyLength(x963.count)
        }
        // Route through CryptoKit so an off-curve point is refused here rather
        // than becoming a DID that names nothing and only fails at the far end
        // of the flow, as "signature invalid".
        guard let key = try? P256.Signing.PublicKey(x963Representation: x963) else {
            throw JWKDIDKeyError.invalidPublicKey
        }

        let coordinates = key.x963Representation.dropFirst()
        let x = Data(coordinates.prefix(32))
        let y = Data(coordinates.suffix(32))

        return didKeyPrefix + "z"
            + DIDKey.base58BTCEncode(jwkJCSPublicKeyMulticodec + canonicalJWK(x: x, y: y))
    }

    /// The JCS form of a P-256 public JWK.
    ///
    /// Written out by hand rather than through `JSONEncoder`. `.sortedKeys`
    /// happens to produce this order today, but JCS is a byte-exact contract
    /// that an identifier is derived from — "the encoder currently sorts" is not
    /// the same promise, and the failure if it ever stops being true is a DID
    /// that no longer matches the one already issued.
    ///
    /// No whitespace, no escaped solidus, base64url without padding. The four
    /// members in the one order RFC 8785 permits.
    static func canonicalJWK(x: Data, y: Data) -> Data {
        let encodedX = VerifiableCredential.base64URLEncoded(x)
        let encodedY = VerifiableCredential.base64URLEncoded(y)
        // ASCII by construction: the member names are literals and both values
        // are base64url.
        return Data(#"{"crv":"P-256","kty":"EC","x":"\#(encodedX)","y":"\#(encodedY)"}"#.utf8)
    }

    // MARK: - Decoding

    /// Recovers the signing key a `jwk_jcs-pub` DID names.
    ///
    /// Accepts any member ordering — see the note on the type. Everything else
    /// is a rejection rather than a repair: a decoder that shrugs off a wrong
    /// multibase prefix or an unknown curve still hands back *a* key, and the
    /// caller has no way left to notice it is not the key the DID names.
    static func p256PublicKey(fromDID did: String) throws -> P256.Signing.PublicKey {
        guard did.hasPrefix(didKeyPrefix) else { throw JWKDIDKeyError.notADIDKey }

        let multibase = did.dropFirst(didKeyPrefix.count)
        guard multibase.first == "z" else { throw JWKDIDKeyError.unsupportedMultibaseEncoding }

        // Base conversion is quadratic in the digit count, and this DID arrives
        // from a QR code held by a stranger, so its length is bounded before any
        // of it is interpreted. A P-256 JWK DID is about 190 digits; the ceiling
        // is the same 1024 `DIDKey` uses, which leaves room for a longer curve
        // to reach the check that names it rather than be refused for length.
        let identifier = multibase.dropFirst()
        guard identifier.count <= 1024 else { throw JWKDIDKeyError.oversizedDID }

        let decoded: [UInt8]
        do {
            decoded = Array(try DIDKey.base58BTCDecode(String(identifier)))
        } catch {
            throw JWKDIDKeyError.invalidBase58
        }

        let (code, prefixLength) = try readMulticodec(decoded)
        guard code == jwkJCSPublicKeyMulticodecCode else {
            throw JWKDIDKeyError.unsupportedMulticodec(code)
        }

        return try p256PublicKey(fromJWKBytes: Data(decoded[prefixLength...]))
    }

    /// The canonical spelling of whatever DID is handed in.
    ///
    /// **Compare these, never the raw strings.** A non-canonical DID and the
    /// canonical DID for the same key are different strings naming one holder,
    /// so `presented == credentialSubject.id` on the bytes as they arrived can
    /// be false for a presentation that is perfectly valid — and, read the other
    /// way, a check written that way stops being the check it looks like.
    ///
    /// Idempotent: canonicalising an already-canonical DID returns it unchanged,
    /// which is what makes it safe to apply at the edges without tracking
    /// whether it has been applied already.
    static func canonicalDID(fromDID did: String) throws -> String {
        let key = try p256PublicKey(fromDID: did)
        return try Self.did(fromP256PublicKeyX963: key.x963Representation)
    }

    /// Whether the DID is spelled the way this codec says it must be.
    ///
    /// Exposed so that a diagnostic screen — or a bug report to the ecosystem —
    /// can say *which* DIDs are out of spec, without any of that leaking into
    /// the accept/reject path. Being non-canonical is not a reason to refuse a
    /// credential; it is a reason to tell somebody.
    static func isCanonical(_ did: String) -> Bool {
        (try? canonicalDID(fromDID: did)) == did
    }

    /// - Parameter bytes: the JWK, as the JSON text that follows the multicodec.
    static func p256PublicKey(fromJWKBytes bytes: Data) throws -> P256.Signing.PublicKey {
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              let jwk = object as? [String: Any] else {
            throw JWKDIDKeyError.malformedJWK
        }

        // Read both before judging either, so the error names the pair. "EC with
        // P-384" and "OKP with Ed25519" are different news and a reader chasing
        // one of them should not have to guess which field was the problem.
        let kty = jwk["kty"] as? String ?? ""
        let crv = jwk["crv"] as? String ?? ""
        guard kty == "EC", crv == "P-256" else {
            throw JWKDIDKeyError.unsupportedKeyType(kty: kty, crv: crv)
        }

        guard let x = base64URLDecoded(jwk["x"] as? String), x.count == 32,
              let y = base64URLDecoded(jwk["y"] as? String), y.count == 32 else {
            throw JWKDIDKeyError.malformedCoordinate
        }

        // CryptoKit checks the point is on the curve. A JWK is two integers
        // somebody typed into a JSON object; nothing in the encoding stops them
        // naming a point that is not on P-256.
        guard let key = try? P256.Signing.PublicKey(
            x963Representation: Data([0x04]) + x + y) else {
            throw JWKDIDKeyError.invalidPublicKey
        }
        return key
    }

    // MARK: - Plumbing

    /// base64url without padding, the only spelling a JWK coordinate may use.
    ///
    /// Standard base64 is refused rather than accepted as a kindness: `+` and
    /// `/` decode to different bytes under the two alphabets, so tolerating them
    /// would mean a coordinate that reads cleanly and names a different point.
    private static func base64URLDecoded(_ string: String?) -> Data? {
        guard let string, !string.isEmpty else { return nil }
        // ASCII explicitly. `Character.isLetter` is true for every Unicode
        // letter, including CJK — a screen's worth of characters that are not
        // base64url and have no business reaching a coordinate.
        guard string.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }) else {
            return nil
        }
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    /// One multiformats unsigned varint off the front, and how many bytes it
    /// took.
    ///
    /// Its own copy rather than a call into `DIDKey`'s, because the failure
    /// modes belong to different error types and a shared one would have to
    /// return an error neither caller could name. Nine bytes is the multiformats
    /// cap; it bounds the work an attacker-supplied DID can demand and keeps the
    /// shift below 57.
    private static func readMulticodec(_ bytes: [UInt8]) throws -> (code: UInt64, length: Int) {
        var code: UInt64 = 0
        var shift: UInt64 = 0
        for (offset, byte) in bytes.prefix(9).enumerated() {
            code |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (code, offset + 1) }
            shift += 7
        }
        throw JWKDIDKeyError.malformedMulticodec
    }
}
