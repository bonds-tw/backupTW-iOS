//
//  ProvingInputs.swift
//  backupTW
//
//  The seven values `generateCertChainRs4096Input` takes, and the checks that
//  have to pass before any of them reaches the circuit.
//

import Foundation
import Security

// MARK: - Errors

/// Why a set of proving inputs was refused before it cost anyone a proof.
///
/// Every case here is caught in memory, in microseconds, on material we already
/// hold. The alternative is finding out after `proveCertChainRs4096` has spent
/// thirty seconds and about two gigabytes producing a proof that is
/// mathematically valid and that no verifier will accept — which is the failure
/// this type exists to convert into a sentence.
///
/// No case carries the offending value. `certificateBase64` and `signedResponse`
/// are the cardholder's national-ID material; an error is the one object in this
/// app most likely to be printed, attached to a support mail, or written to a
/// crash report.
enum ProvingInputError: Error, Equatable {

    /// No certificate at all.
    case certificateEmpty

    /// `result.cert` is documented as base64 DER and did not decode as base64.
    case certificateNotBase64

    /// It decoded, and the bytes do not begin a DER `SEQUENCE` (0x30), so it is
    /// not an X.509 certificate whatever else it may be. A cheap structural
    /// check, not a parse: the point is to catch a caller who passed the
    /// signature, the PEM text, or the issuer here.
    case certificateNotDER

    case signedResponseNotBase64

    /// The holder's 自然人憑證 is RSA-2048, so a PKCS#1 signature over the TBS is
    /// exactly 256 bytes, and `userSigRS2048` reads it as 17 × 121-bit limbs.
    ///
    /// ⚠️ This is the check most likely to be *wrong about the world* rather than
    /// about the input. Upstream is inconsistent about what this field holds: the
    /// README's example writes the placeholder `"<signed-response-json>"`, while
    /// the circuit fixture `user_sig_rs2048_input.json` can only have come from
    /// 256 raw
    /// bytes. If TW FidO ever hands back an envelope instead of the bare
    /// signature, this is the line that will say so — by name, at the call site,
    /// instead of as an opaque `InvalidInput` from Rust. Carrying the byte count
    /// is deliberate for that reason; a length is not identifying.
    case signedResponseWrongLength(byteCount: Int)

    /// `tbs` is the relying-party identifier itself: 31 characters, the field
    /// element's capacity. See `ProvingInputs.relyingPartyIdentifier`.
    case relyingPartyIdentifierMalformed

    /// Not base64url, or empty.
    case challengeMalformed

    /// Under 64 bits of freshness. NIST SP 800-63B's floor for a nonce; below it
    /// the replay defence is decorative.
    case challengeTooShort(byteCount: Int)

    /// Over 31 bytes, which does not fit a BN254 scalar without a reduction
    /// nobody has agreed on. See `ProofChallenge.fieldElement()`.
    case challengeTooLarge(byteCount: Int)
}

extension ProvingInputError: LocalizedError {

    /// One sentence for all of them, on purpose.
    ///
    /// Every case means the same thing to the person holding the phone — the
    /// certificate that just came back from 行動自然人憑證 cannot be turned into
    /// a proof — and the difference between "the signature was 128 bytes" and
    /// "the challenge was not base64url" is a developer's diagnosis, not
    /// something a cardholder standing at a counter can act on. The case itself
    /// is what a bug report should carry.
    var errorDescription: String? {
        NSLocalizedString("This certificate can't be used to create a proof.", comment: "")
    }
}

// MARK: - Challenge

/// The freshness value the proof is bound to, and — the reason this is an enum
/// rather than a `String` — where it came from.
///
/// **The gap this type exists to keep visible.** PSE's design is online: the app
/// asks the server `POST /challenge`, gets a 254-bit field element with a
/// five-minute TTL, and the server refuses a proof built on a challenge it did
/// not mint. That is what makes the proof un-replayable. The whitepaper wants
/// this to work with no server, and offline there are only two honest options:
///
///   * the verifier standing in front of the holder supplies it (their
///     `PresentationRequest.challenge`, which they minted and hold in their own
///     pending set) — replay protection survives, scoped to that verifier; or
///   * the holder generates it, which is fine for a proof the holder is going to
///     show to *someone unspecified later*, and proves nothing about freshness to
///     anybody.
///
/// Both are legitimate; they are not interchangeable, and a `String` parameter
/// would let a call site pick the second while the UI claims the first. So the
/// choice is spelled at the call site, travels with the proof, and comes out the
/// far end as `ProofCaveat.challengeNotBoundToVerifier` when it was the second.
enum ProofChallenge: Equatable, Sendable {

    /// Taken from the verifier's `PresentationRequest.challenge`. base64url.
    case fromVerifier(String)

    /// Minted on this device. base64url. No freshness guarantee to anyone else.
    case holderGenerated(String)

    var base64URL: String {
        switch self {
        case .fromVerifier(let value), .holderGenerated(let value):
            return value
        }
    }

    /// Whether anything ties a proof built on this to the party checking it.
    var boundToVerifier: Bool {
        switch self {
        case .fromVerifier:
            return true
        case .holderGenerated:
            return false
        }
    }

    /// A holder-generated challenge, 16 bytes, matching
    /// `PresentationRequest.challengeByteCount`.
    ///
    /// `SecRandomCopyBytes` failing is reported rather than worked around, for
    /// the reason `PresentationRequest.generate` gives: every fallback produces
    /// something that still looks like a challenge while the replay defence
    /// silently stops existing.
    static func generate() throws -> ProofChallenge {
        var bytes = [UInt8](repeating: 0, count: PresentationRequest.challengeByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PresentationRequestError.randomnessUnavailable
        }
        return .holderGenerated(VerifiableCredential.base64URLEncoded(Data(bytes)))
    }

    /// The `challenge` argument, in the form the circuit reads it.
    ///
    /// **Decimal, not hex and not base64.** Circom inputs are decimal strings —
    /// upstream's own test passes `"1339673755198158349044581307228491536"`
    /// (`OpenACSwiftTests.swift:191`) and the reference server's `/challenge`
    /// returns `"123"`. Handing this base64url unchanged produces an input file
    /// the Rust side rejects, or worse, reads as a different number.
    ///
    /// **Why 31 bytes is a hard ceiling rather than a reduction.** BN254's scalar
    /// field is about 2^253.6, so 31 bytes (2^248 − 1) is the largest width that
    /// is guaranteed to be a valid field element without a modular reduction. A
    /// longer value *could* be folded in — SHA-256 truncated to 31 bytes is the
    /// obvious choice — but that transform has to be agreed with whoever checks
    /// the proof, because they see the reduced number as a public input and have
    /// to reproduce it from the challenge they issued. Inventing one here
    /// unilaterally would produce proofs that verify against nothing.
    ///
    /// So: this refuses. `PresentationRequest` allows challenges up to 64
    /// base64url characters (48 bytes), which means a foreign verifier's longer
    /// nonce is a request this app can read and cannot answer with a proof. That
    /// is a real gap, it is not papered over, and closing it is a protocol
    /// decision rather than a coding one.
    func fieldElement() throws -> String {
        guard let bytes = Self.base64URLDecoded(base64URL), !bytes.isEmpty else {
            throw ProvingInputError.challengeMalformed
        }
        guard bytes.count >= 8 else {
            throw ProvingInputError.challengeTooShort(byteCount: bytes.count)
        }
        guard bytes.count <= 31 else {
            throw ProvingInputError.challengeTooLarge(byteCount: bytes.count)
        }
        return Self.decimalString(bigEndian: bytes)
    }

    /// base64url, unpadded, strict — the standard alphabet's `+`, `/` and `=` are
    /// refused rather than quietly accepted, matching `OfflineVerifier`'s decoder.
    /// A challenge that only half-decodes is worse than one that fails: it
    /// becomes a *different* number, and the proof binds to that.
    static func base64URLDecoded(_ string: String) -> Data? {
        guard !string.isEmpty,
              !string.contains(where: { $0 == "+" || $0 == "/" || $0 == "=" }) else {
            return nil
        }
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    /// Big-endian unsigned bytes as a decimal string.
    ///
    /// Long multiplication over a little-endian array of decimal digits, because
    /// 31 bytes does not fit any of Swift's integer types and pulling in a
    /// bignum dependency to print one number would be worse than twelve lines.
    /// Bounded by construction: the caller has already refused anything over 31
    /// bytes, so this is at most 75 digits and 31 passes.
    static func decimalString(bigEndian bytes: Data) -> String {
        var digits: [UInt8] = [0]
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                let value = Int(digits[index]) * 256 + carry
                digits[index] = UInt8(value % 10)
                carry = value / 10
            }
            while carry > 0 {
                digits.append(UInt8(carry % 10))
                carry /= 10
            }
        }
        // Most-significant digit last during the loop, first on the way out.
        return String(digits.reversed().map { Character(UnicodeScalar(UInt8(48) + $0)) })
    }
}

// MARK: - Inputs

/// Everything `generateCertChainRs4096Input` needs that is not a file path,
/// checked on the way in.
///
/// The initialiser validates, so an invalid set cannot exist in memory — the
/// same reason `PresentationRequest` does it there. A check that lived only at
/// the call site would be absent from the second call site.
///
/// # ⚠️ This object is the cardholder's identity
///
/// `certificateBase64` carries their name and their public key;
/// `signedResponse` is a signature under the private half. It must not be
/// logged, must not be persisted, and must not outlive the proof.
///
/// This used to say the certificate carries the 身分證統一編號 in its serial
/// number. It does not — see `DistinguishedNameAttribute` for the measurement.
/// The Subject DN's `serialNumber` is a 16-digit value that is not the national
/// ID, and no national ID appears anywhere in the DER. That makes this object
/// slightly less dangerous than the note claimed and no less confidential: a
/// name plus a certificate serial is still a direct handle on one person, and
/// the certificate is what the ZK path exists to keep off the wire. `description` and `debugDescription` are overridden to say
/// nothing, so `print(inputs)` and `String(reflecting:)` cannot leak it by
/// accident, and `ZKProver` deletes the input JSON these become as soon as the
/// proofs exist.
struct ProvingInputs: Equatable, Sendable {

    /// TW FidO's `result.cert` — base64 DER of the **holder's** certificate,
    /// passed through verbatim.
    ///
    /// Not re-encoded, not PEM-wrapped, not converted to base64url. The library
    /// wants exactly the string the API returned. Note the reference app calls
    /// its copy of this `athIssuerCert`, which is a misnomer that has cost
    /// people time: the issuer is MOICA-G3 and arrives as a separate file path.
    let certificateBase64: String

    /// TW FidO's `result.signed_response`, passed through verbatim — that one
    /// field, not the enclosing `result` object and not the whole response JSON.
    let signedResponse: String

    /// The `tbs` argument, and the single easiest parameter in this API to get
    /// wrong.
    ///
    /// It is the 31-character relying-party identifier **as an ASCII string** —
    /// not base64, not hex-decoded to bytes, not a digest of anything. Decoding
    /// the shipped fixtures back to bytes shows `"e775f2805fb993e05a208dbff15d1c1"`
    /// followed by ordinary SHA-256 padding, which the function appends itself.
    ///
    /// It is the same value we send to TW FidO as `sign_data`, in a different
    /// encoding: FidO receives `base64(UTF8(app_id))` (see `TWFidOClient`),
    /// the circuit receives the raw string. `signData(appID:)` goes to FidO,
    /// `appID` goes here. Passing the base64 form here yields a proof that
    /// generates successfully and verifies against nothing.
    let relyingPartyIdentifier: String

    let challenge: ProofChallenge

    /// 31 lowercase hex characters — the circuit's field element has room for no
    /// more, which is why `TWFidOConfiguration.bondsAppID` is a truncated digest
    /// rather than the bundle identifier.
    static let relyingPartyIdentifierLength = 31

    /// A PKCS#1 signature under an RSA-2048 key.
    static let signedResponseByteCount = 256

    init(certificateBase64: String,
         signedResponse: String,
         relyingPartyIdentifier: String = TWFidOConfiguration.bondsAppID,
         challenge: ProofChallenge) throws {

        guard !certificateBase64.isEmpty else {
            throw ProvingInputError.certificateEmpty
        }
        guard let certificate = Data(base64Encoded: certificateBase64) else {
            throw ProvingInputError.certificateNotBase64
        }
        // 0x30 is the DER tag for SEQUENCE, and every X.509 certificate is one.
        // This does not parse the certificate — it catches the swap that the
        // reference app's variable naming invites, where the issuer or the
        // signature is passed where the holder's certificate belongs.
        guard certificate.first == 0x30 else {
            throw ProvingInputError.certificateNotDER
        }

        guard let signature = Data(base64Encoded: signedResponse) else {
            throw ProvingInputError.signedResponseNotBase64
        }
        guard signature.count == Self.signedResponseByteCount else {
            throw ProvingInputError.signedResponseWrongLength(byteCount: signature.count)
        }

        let identifier = relyingPartyIdentifier
        guard identifier.count == Self.relyingPartyIdentifierLength,
              identifier.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ProvingInputError.relyingPartyIdentifierMalformed
        }

        // Converted here purely to reject a bad challenge at construction time
        // alongside everything else; the value is recomputed by
        // `challengeFieldElement()` rather than stored, so there is one
        // definition of the conversion.
        _ = try challenge.fieldElement()

        self.certificateBase64 = certificateBase64
        self.signedResponse = signedResponse
        self.relyingPartyIdentifier = identifier
        self.challenge = challenge
    }

    /// The shape the call site actually has: whatever came back from the
    /// 行動自然人憑證 round trip, plus the challenge in play.
    init(signResult: TWFidOSignResult,
         relyingPartyIdentifier: String = TWFidOConfiguration.bondsAppID,
         challenge: ProofChallenge) throws {
        // `hashedIDNumber` is deliberately dropped: nothing in the circuit
        // consumes it, and it is the one field in the result that is a direct
        // handle on the holder.
        try self.init(certificateBase64: signResult.cert,
                      signedResponse: signResult.signedResponse,
                      relyingPartyIdentifier: relyingPartyIdentifier,
                      challenge: challenge)
    }

    /// The `challenge` argument, decimal.
    func challengeFieldElement() throws -> String {
        try challenge.fieldElement()
    }
}

// MARK: - Redaction

/// Both, not just `description`: `String(reflecting:)`, `dump`, the debugger's
/// quick look and `%@` in a format string reach for `debugDescription`, and the
/// default synthesised one for a struct prints every stored property. That is a
/// national-ID certificate and a signature over it, one careless interpolation
/// away from a log line.
///
/// Whether the challenge came from the verifier is kept, because it is the one
/// thing here that is useful in a bug report and identifies nobody.
extension ProvingInputs: CustomStringConvertible, CustomDebugStringConvertible {

    var description: String {
        "ProvingInputs(redacted, boundToVerifier: \(challenge.boundToVerifier))"
    }

    var debugDescription: String { description }
}
