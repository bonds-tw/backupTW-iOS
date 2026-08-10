//
//  ZKPublicInputs.swift
//  backupTW
//
//  The public signals a zkID proof carries, parsed on device.
//

import Foundation

// MARK: - Why this exists before anything calls it
//
// Nothing in this app can reach these types yet, and that is a known gap rather
// than an oversight. The signals live inside the spartan2 proof binary; the only
// code that ever sees them decoded is the Rust FFI during verification, which
// hands them to its caller through a thread-local `zk_last_signals()` — measured
// in `go-zkid-verifier/rust/src/lib.rs:36-56`. **The iOS static library exports
// no equivalent**: `nm` over `libopenac_mobile_app.a` finds the circuits' own
// `public_values` symbols, but `mopro.swift`'s whole public surface returns
// `Bool` from `linkVerify`/`verifyCertChainRs4096`/`verifyUserSigRs2048`, and
// `ProofResult` carries only timings. So the signals cannot cross the boundary
// until upstream adds an export.
//
// What is written here is everything that does *not* depend on that: the layout,
// the encoding, and the unpacking — all of it checkable against vectors produced
// by the Go implementation itself. When the FFI export lands, the work is to call
// it and hand the strings to `ZKPublicInputs.parse`, not to work out what they
// mean. Wiring points, for whoever does that: `ZKPackageVerifier.verify`
// (verifier side) and `ZKProver.verifyOnThisDevice()` (holder self-check).
//
// # Why there is no big-integer arithmetic here
//
// The Go verifier carries `math/big` throughout because its HTTP API renders
// every signal as a decimal string. This device does neither of the two things
// that would need arithmetic: it *compares* roots and challenges, and it
// *unpacks* an app_id. Both are byte operations. Introducing a bignum
// dependency to reproduce Go's decimal formatting would be adding a dependency
// to produce a string nothing on this device reads.

// MARK: - Errors

/// Why a set of public signals could not be believed.
///
/// No case carries a signal value. A nullifier is a stable per-holder pseudonym
/// and these errors reach logs and support reports.
enum ZKPublicInputsError: Error, Equatable {

    /// The circuit produced a different number of signals than its layout
    /// defines. Upstream's own note is the right reading: a circuit change
    /// surfaces here first, loudly, and must not be papered over.
    case unexpectedSignalCount(expected: Int, got: Int)

    /// A signal was not a `0x`-prefixed hexadecimal field element.
    case malformedFieldElement

    /// A field element was wider than the 32 bytes a BN254 element occupies.
    case fieldElementTooWide

    /// The packed app_id did not fit in `ZKPublicInputs.appIDByteCount` bytes,
    /// so it is not an identifier this protocol could have produced.
    case appIDTooWide

    /// The unpacked app_id bytes are not UTF-8, so they are not the ASCII
    /// relying-party identifier the circuit packed.
    case appIDNotText
}

// MARK: - Field elements

/// One public signal, held as the 32 big-endian bytes it denotes.
///
/// # Endianness, and a stale comment that says otherwise
///
/// Signals cross the FFI as `0x`-prefixed **big-endian** hex. The Rust shim is
/// explicit — `to_repr()` yields little-endian bytes and it reverses them before
/// formatting (`rust/src/lib.rs:15-27`). `go-zkid-verifier`'s own doc comment at
/// `verifier/verifier.go:22-23` says little-endian; that comment is wrong, and
/// every consumer in that repository contradicts it. Anyone porting from the Go
/// comment rather than the Rust source will produce byte-reversed roots that
/// compare unequal against every honest snapshot.
///
/// Stored as fixed-width bytes rather than as the source string so that two
/// spellings of one value — `0x1` and `0x0000…01` — are one value here. A
/// verifier that compared source strings would report a mismatch between a root
/// and itself.
struct ZKFieldElement: Equatable, Hashable, Sendable {

    /// Exactly `byteCount` bytes, big-endian, zero-padded on the left.
    let bytes: Data

    /// BN254's field elements are 254 bits, which the FFI serialises in 32.
    static let byteCount = 32

    init(hex: String) throws {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            text = String(text.dropFirst(2))
        }
        guard !text.isEmpty, text.count % 2 == 0,
              text.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw ZKPublicInputsError.malformedFieldElement
        }

        var raw = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index ..< next], radix: 16) else {
                throw ZKPublicInputsError.malformedFieldElement
            }
            raw.append(byte)
            index = next
        }

        // Wider than 32 bytes is only acceptable when the excess is leading
        // zeros: `0x00…01` and `0x01` are the same element, and a producer that
        // pads is not a producer that is wrong.
        while raw.count > Self.byteCount, raw.first == 0 {
            raw = raw.dropFirst()
        }
        guard raw.count <= Self.byteCount else {
            throw ZKPublicInputsError.fieldElementTooWide
        }
        bytes = Data(repeating: 0, count: Self.byteCount - raw.count) + raw
    }

    /// Lowercase, `0x`-prefixed, always 64 hex characters.
    ///
    /// One spelling per value, so a root written into a log, compared against a
    /// snapshot, or shown on a screen is the same string in all three places.
    var canonicalHex: String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Layouts

/// The public signals of a zkID proof pair.
///
/// Layouts are positional and their lengths are exact — reproduced from
/// `go-zkid-verifier/verifier/public_inputs.go:11-73`:
///
///   * `cert_chain` RS4096 — 36 signals: `[pk_commit, issuer_modulus[34], smt_root]`
///   * `cert_chain` RS2048 — 19 signals: `[pk_commit, issuer_modulus[17], smt_root]`
///   * `user_sig`  RS2048 —  4 signals: `[pk_commit, nullifier, app_id_packed, challenge]`
///
/// A wrong count throws rather than truncating. Upstream's test artifacts note
/// says a circuit change shows up as a public-input count mismatch, which makes
/// this the first place a circuit upgrade announces itself; a parser that read
/// the first N and ignored the rest would turn that announcement into silence.
struct ZKPublicInputs: Equatable, Sendable {

    /// Ties the two proofs together. `linkVerify` already checks that the
    /// cert-chain and user-sig proofs agree on this, so a disagreement here
    /// means the two were verified separately and never linked.
    let pkCommit: ZKFieldElement

    /// ⚠️ A stable per-holder pseudonym for this relying party. Carrying it is
    /// what makes single-verifier de-duplication possible; storing or logging it
    /// is what makes two verifiers able to prove they saw the same person. See
    /// `ProofCaveat.noGlobalUniqueness` for what it still cannot establish.
    let nullifier: ZKFieldElement

    /// The relying-party identifier the circuit packed, unpacked back to text.
    let appID: String

    let challenge: ZKFieldElement

    /// The issuer's RSA modulus, in 121-bit limbs: 34 for RS4096, 17 for RS2048.
    let issuerModulusLimbs: [ZKFieldElement]

    /// The revocation tree root the proof was built against.
    ///
    /// What it is *not*: evidence of anything about revocation on its own. It
    /// names the snapshot the holder proved non-membership in, and believing it
    /// requires knowing that snapshot is one you accept.
    let smtRoot: ZKFieldElement

    /// The relying-party identifier is 31 bytes — one field element's worth of
    /// ASCII, which is why `TWFidOConfiguration.bondsAppID` is a truncated
    /// digest rather than a bundle identifier.
    static let appIDByteCount = 31

    static let certChainRS4096SignalCount = 36
    static let certChainRS2048SignalCount = 19
    static let userSigSignalCount = 4

    /// Which cert-chain circuit produced a proof. This app ships RS4096 only —
    /// `IssuerCertificate.supportedGeneration` is G3, whose CA key is 4096-bit —
    /// but the RS2048 layout is implemented because refusing to *parse* a G2
    /// proof and refusing to *accept* one are different refusals, and only the
    /// second is this build's policy.
    enum CertChainCircuit: Equatable, Sendable {
        case rs4096
        case rs2048

        var signalCount: Int {
            switch self {
            case .rs4096: return ZKPublicInputs.certChainRS4096SignalCount
            case .rs2048: return ZKPublicInputs.certChainRS2048SignalCount
            }
        }

        var modulusLimbCount: Int { signalCount - 2 }
    }

    /// Parses one proof pair's signals.
    ///
    /// - Parameters:
    ///   - certChain: the cert-chain proof's signals, in circuit order.
    ///   - userSig: the user-signature proof's signals, in circuit order.
    static func parse(certChain: [String],
                      userSig: [String],
                      circuit: CertChainCircuit) throws -> ZKPublicInputs {
        guard certChain.count == circuit.signalCount else {
            throw ZKPublicInputsError.unexpectedSignalCount(expected: circuit.signalCount,
                                                            got: certChain.count)
        }
        guard userSig.count == userSigSignalCount else {
            throw ZKPublicInputsError.unexpectedSignalCount(expected: userSigSignalCount,
                                                            got: userSig.count)
        }

        let limbs = try certChain[1 ... circuit.modulusLimbCount].map { try ZKFieldElement(hex: $0) }

        return ZKPublicInputs(
            pkCommit: try ZKFieldElement(hex: userSig[0]),
            nullifier: try ZKFieldElement(hex: userSig[1]),
            appID: try unpackAppID(try ZKFieldElement(hex: userSig[2])),
            challenge: try ZKFieldElement(hex: userSig[3]),
            issuerModulusLimbs: limbs,
            smtRoot: try ZKFieldElement(hex: certChain[circuit.signalCount - 1]))
    }

    /// Recovers the relying-party identifier from its packed field element.
    ///
    /// The circuit packs `tbs[i] * 256^i` — little-endian — so byte *i* of the
    /// identifier is the *i*-th least significant byte of the element
    /// (`public_inputs.go:89-132`). The element itself is stored big-endian, so
    /// recovering the text is a reversal, not arithmetic.
    ///
    /// ⚠️ The per-session `challenge` is packed **big-endian** instead. The two
    /// encodings sit in adjacent signals of the same proof and upstream flags
    /// the difference as deliberate; treating them alike is a mistake with no
    /// symptom until a real challenge fails to match.
    /// Returns the 31 bytes themselves. This is the layer the Go implementation
    /// agrees with byte for byte, and therefore the layer worth cross-checking
    /// against its vectors.
    static func unpackAppIDBytes(_ packed: ZKFieldElement) throws -> Data {
        let padding = ZKFieldElement.byteCount - appIDByteCount
        guard packed.bytes.prefix(padding).allSatisfy({ $0 == 0 }) else {
            throw ZKPublicInputsError.appIDTooWide
        }
        return Data(packed.bytes.suffix(appIDByteCount).reversed())
    }

    /// The identifier as text, which is a **stricter** answer than the Go
    /// implementation gives.
    ///
    /// Go returns `string(out)` and a Go string holds arbitrary bytes, so
    /// upstream will hand back a 31-byte blob that is not text at all. Swift's
    /// `String` cannot, and this build does not want it to: an app_id that is
    /// not UTF-8 is not an identifier any relying party in this protocol chose —
    /// `TWFidOConfiguration.bondsAppID` is 31 lowercase hex characters — so it
    /// is a corrupt proof or a different protocol, and both should stop here
    /// rather than reach a screen as replacement characters.
    ///
    /// The divergence is deliberate and is why the byte-level function above
    /// exists separately: the two implementations agree on the bytes, and this
    /// build adds a policy on top of them.
    static func unpackAppID(_ packed: ZKFieldElement) throws -> String {
        let bytes = try unpackAppIDBytes(packed)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ZKPublicInputsError.appIDNotText
        }
        return text
    }

    /// Packs an identifier the way the circuit does. Present so a test can drive
    /// the unpacking against its own inverse *and* against vectors from the Go
    /// implementation — an encoder checked only against its own decoder agrees
    /// with itself on any convention, including a wrong one.
    static func packAppID(_ identifier: String) throws -> ZKFieldElement {
        let raw = Data(identifier.utf8)
        guard raw.count == appIDByteCount else {
            throw ZKPublicInputsError.appIDTooWide
        }
        let padded = Data(repeating: 0, count: ZKFieldElement.byteCount - appIDByteCount)
            + Data(raw.reversed())
        return try ZKFieldElement(hex: padded.map { String(format: "%02x", $0) }.joined())
    }
}
