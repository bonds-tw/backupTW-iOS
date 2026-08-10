//
//  ZKPublicInputsTests.swift
//  backupTWTests
//
//  The Swift parser checked against the Go implementation's own output.
//

import Foundation
import Testing
@testable import backupTW

// MARK: - Cross-implementation vectors
//
// Every `packedDecimal` below was produced by running
// `go-zkid-verifier/verifier/public_inputs.go` — the reference implementation
// itself — not by working the packing out by hand. That distinction is the
// point of this file: an encoder checked against its own decoder round-trips
// under any convention, including a reversed one, and byte order is exactly the
// kind of thing that survives such a check while being wrong on the wire.
//
// Regenerate by copying `public_inputs.go` into a standalone package (the file
// is pure Go; the enclosing package needs cgo and the Rust library) and calling
// `PackAppIDLE` / `NormalizeDecimal`.
//
// Decimal, because that is Go's output form. These tests convert to bytes
// through `decimalToBytes` below — deliberately written out here rather than
// reusing anything from the app, so the app's own parsing is never what decides
// whether the app's parsing is right.

/// Schoolbook base-10 → 32-byte big-endian. Slow and obvious on purpose: it
/// exists to be read, and it runs five times.
private func decimalToBigEndian32(_ decimal: String) -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    for character in decimal {
        guard let digit = character.wholeNumberValue else { continue }
        var carry = digit
        for index in stride(from: bytes.count - 1, through: 0, by: -1) {
            let value = Int(bytes[index]) * 10 + carry
            bytes[index] = UInt8(value & 0xFF)
            carry = value >> 8
        }
    }
    return Data(bytes)
}

private struct AppIDVector {
    let name: String
    /// The identifier's raw bytes, hex-encoded — what the circuit packs.
    let rawHex: String
    /// What Go's `PackAppIDLE` returned for those bytes.
    let packedDecimal: String
}

private let appIDVectors: [AppIDVector] = [
    AppIDVector(name: "bondsAppID",
                rawHex: "35353334396666353430333932613037376361336463633962626461346333",
                packedDecimal: "90793885365844560731513681916468596049392961539493220066554409251870291253"),
    AppIDVector(name: "mattersAppID",
                rawHex: "65373735663238303566623939336530356132303864626666313564316331",
                packedDecimal: "87260110652971273325114661307899884180253107364897732854914216462835464037"),
    AppIDVector(name: "iota",
                rawHex: "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                packedDecimal: "54980096196880238888162309298627284197919427551736292421657099673115230721"),
    AppIDVector(name: "allFF",
                rawHex: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                packedDecimal: "452312848583266388373324160190187140051835877600158453279131187530910662655"),
    // Low-order zero bytes: in little-endian these are the *first* bytes of the
    // identifier, so they vanish from the packed integer's magnitude entirely.
    // A decoder that recovered length from the integer would lose them.
    AppIDVector(name: "leadingZeros",
                rawHex: "00000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d",
                packedDecimal: "51432544443285992704842119806939541923003067727421324160644306045421813760"),
]

/// `NormalizeDecimal` vectors, same provenance.
private let normalizeVectors: [(hex: String, decimal: String)] = [
    ("0x00", "0"),
    ("0x01", "1"),
    ("0xff", "255"),
    ("0x0100", "256"),
    ("0xdeadbeef", "3735928559"),
    ("0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000",
     "21888242871839275222246405745257275088548364400416034343698204186575808495616"),
]

private func hexData(_ hex: String) -> Data {
    var out = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index ..< next], radix: 16)!)
        index = next
    }
    return out
}

// MARK: - Tests

struct ZKPublicInputsTests {

    // MARK: Field elements

    /// The parser and Go agree on what a hex field element denotes. This is the
    /// endianness check: `verifier/verifier.go:22-23` documents these strings as
    /// little-endian and the Rust that produces them (`rust/src/lib.rs:15-27`)
    /// reverses to big-endian. Reading the comment instead of the source gives
    /// byte-reversed roots that never match an honest snapshot, and nothing
    /// downstream would say why.
    @Test func fieldElementsAreBigEndian() throws {
        for vector in normalizeVectors {
            let element = try ZKFieldElement(hex: vector.hex)
            #expect(element.bytes == decimalToBigEndian32(vector.decimal),
                    "\(vector.hex) decoded to different bytes than Go's decimal \(vector.decimal)")
        }
    }

    /// Two spellings of one value are one value. A verifier comparing source
    /// strings would report a root as differing from itself.
    @Test func paddingDoesNotChangeAnElement() throws {
        let short = try ZKFieldElement(hex: "0x01")
        let padded = try ZKFieldElement(hex: "0x" + String(repeating: "0", count: 62) + "01")

        #expect(short == padded)
        #expect(short.canonicalHex == padded.canonicalHex)
        #expect(short.canonicalHex.count == 66)
    }

    @Test(arguments: ["", "0x", "0xzz", "0x1", "not hex", "0x 01"])
    func malformedElementsAreRefused(_ hex: String) {
        #expect(throws: ZKPublicInputsError.malformedFieldElement) {
            _ = try ZKFieldElement(hex: hex)
        }
    }

    /// Wider than 32 bytes of actual magnitude is not a field element. Leading
    /// zeros are not magnitude, so they are allowed.
    @Test func oversizedElementsAreRefusedButPaddingIsNot() throws {
        let tooWide = "0x" + String(repeating: "ff", count: 33)
        #expect(throws: ZKPublicInputsError.fieldElementTooWide) {
            _ = try ZKFieldElement(hex: tooWide)
        }

        let paddedNotWide = "0x" + String(repeating: "00", count: 4) + String(repeating: "ab", count: 32)
        #expect(throws: Never.self) { _ = try ZKFieldElement(hex: paddedNotWide) }
    }

    // MARK: app_id

    /// The load-bearing cross-check: Go packed these identifiers, and this
    /// unpacks Go's output back to the bytes Go started from.
    ///
    /// Checked at the *byte* layer, because that is the layer the two
    /// implementations genuinely share. Two of these vectors are byte patterns
    /// rather than text, and asserting they decode to a `String` measures
    /// Swift's `String` rather than the packing.
    @Test func appIDBytesUnpackFromGoPackedVectors() throws {
        for vector in appIDVectors {
            let packed = ZKFieldElement(unchecked: decimalToBigEndian32(vector.packedDecimal))
            let unpacked = try ZKPublicInputs.unpackAppIDBytes(packed)

            #expect(unpacked == hexData(vector.rawHex),
                    "\(vector.name) unpacked to the wrong bytes")
        }
    }

    /// The text layer diverges from Go on purpose, and the divergence is the
    /// behaviour under test: 31 bytes of `0xff` is a valid answer for Go, whose
    /// strings hold arbitrary bytes, and is refused here because no relying
    /// party in this protocol has a non-UTF-8 identifier.
    @Test func aNonTextAppIDIsRefusedEvenThoughGoWouldReturnIt() throws {
        let allFF = appIDVectors.first { $0.name == "allFF" }!
        let packed = ZKFieldElement(unchecked: decimalToBigEndian32(allFF.packedDecimal))

        // The bytes come back...
        #expect(try ZKPublicInputs.unpackAppIDBytes(packed) == hexData(allFF.rawHex))
        // ...and the text does not.
        #expect(throws: ZKPublicInputsError.appIDNotText) {
            _ = try ZKPublicInputs.unpackAppID(packed)
        }
    }

    /// The identifiers that *are* text still round-trip through the text layer.
    @Test func textAppIDsUnpackToTheirIdentifier() throws {
        for vector in appIDVectors {
            let raw = hexData(vector.rawHex)
            guard let expected = String(data: raw, encoding: .utf8),
                  Data(expected.utf8) == raw else { continue }

            let packed = ZKFieldElement(unchecked: decimalToBigEndian32(vector.packedDecimal))
            #expect(try ZKPublicInputs.unpackAppID(packed) == expected,
                    "\(vector.name) did not unpack to its identifier")
        }
    }

    /// And the packer agrees with Go too, so the seam is checked from both
    /// sides rather than only through this file's own decoder.
    @Test func appIDPacksToGoPackedVectors() throws {
        for vector in appIDVectors {
            let identifier = String(decoding: hexData(vector.rawHex), as: UTF8.self)
            // Only the printable identifiers survive a UTF-8 round trip; the
            // byte-pattern vectors are covered by the unpacking test above.
            guard Data(identifier.utf8) == hexData(vector.rawHex) else { continue }

            let packed = try ZKPublicInputs.packAppID(identifier)
            #expect(packed.bytes == decimalToBigEndian32(vector.packedDecimal),
                    "\(vector.name) packed differently from Go")
        }
    }

    /// This app's own relying-party identifier survives the round trip, which is
    /// the only one that will ever appear in a proof this build produces.
    @Test func theProjectsOwnAppIDRoundTrips() throws {
        let packed = try ZKPublicInputs.packAppID(TWFidOConfiguration.bondsAppID)
        let unpacked = try ZKPublicInputs.unpackAppID(packed)

        #expect(unpacked == TWFidOConfiguration.bondsAppID)
        #expect(TWFidOConfiguration.bondsAppID.count == ZKPublicInputs.appIDByteCount)
    }

    /// A packed value with magnitude in the 32nd byte cannot be a 31-byte
    /// identifier, whatever it decodes to.
    @Test func anOversizedPackedAppIDIsRefused() throws {
        var bytes = Data(repeating: 0, count: 32)
        bytes[0] = 0x01
        #expect(throws: ZKPublicInputsError.appIDTooWide) {
            _ = try ZKPublicInputs.unpackAppID(ZKFieldElement(unchecked: bytes))
        }
    }

    // MARK: Layouts

    private func signals(_ count: Int) -> [String] {
        (0 ..< count).map { String(format: "0x%064x", $0 + 1) }
    }

    @Test func rs4096SignalsLandInTheRightSlots() throws {
        var certChain = signals(ZKPublicInputs.certChainRS4096SignalCount)
        let userSig = [signals(4)[0],
                       "0x" + String(repeating: "ab", count: 32),
                       try ZKPublicInputs.packAppID(TWFidOConfiguration.bondsAppID).canonicalHex,
                       "0x" + String(repeating: "cd", count: 32)]
        certChain[35] = "0x" + String(repeating: "ef", count: 32)

        let parsed = try ZKPublicInputs.parse(certChain: certChain, userSig: userSig, circuit: .rs4096)

        #expect(parsed.smtRoot.canonicalHex == "0x" + String(repeating: "ef", count: 32))
        #expect(parsed.nullifier.canonicalHex == "0x" + String(repeating: "ab", count: 32))
        #expect(parsed.challenge.canonicalHex == "0x" + String(repeating: "cd", count: 32))
        #expect(parsed.appID == TWFidOConfiguration.bondsAppID)
        // 34 limbs, and neither pk_commit nor smt_root is one of them.
        #expect(parsed.issuerModulusLimbs.count == 34)
        #expect(!parsed.issuerModulusLimbs.contains(parsed.smtRoot))
    }

    @Test func rs2048UsesTheShorterModulus() throws {
        var certChain = signals(ZKPublicInputs.certChainRS2048SignalCount)
        certChain[18] = "0x" + String(repeating: "ef", count: 32)
        let userSig = [signals(4)[0],
                       "0x" + String(repeating: "ab", count: 32),
                       try ZKPublicInputs.packAppID(TWFidOConfiguration.bondsAppID).canonicalHex,
                       "0x" + String(repeating: "cd", count: 32)]

        let parsed = try ZKPublicInputs.parse(certChain: certChain, userSig: userSig, circuit: .rs2048)

        #expect(parsed.issuerModulusLimbs.count == 17)
        #expect(parsed.smtRoot.canonicalHex == "0x" + String(repeating: "ef", count: 32))
    }

    /// A circuit change announces itself as a signal-count mismatch — upstream
    /// says so in its own test artifacts. Reading the first N and ignoring the
    /// rest would turn that announcement into silence.
    @Test func aWrongSignalCountIsRefusedRatherThanTruncated() throws {
        let short = signals(ZKPublicInputs.certChainRS4096SignalCount - 1)
        let userSig = signals(ZKPublicInputs.userSigSignalCount)

        #expect(throws: ZKPublicInputsError.unexpectedSignalCount(expected: 36, got: 35)) {
            _ = try ZKPublicInputs.parse(certChain: short, userSig: userSig, circuit: .rs4096)
        }
        #expect(throws: ZKPublicInputsError.unexpectedSignalCount(expected: 4, got: 5)) {
            _ = try ZKPublicInputs.parse(certChain: signals(36),
                                         userSig: signals(5),
                                         circuit: .rs4096)
        }
    }

    /// The RS2048 layout is not the RS4096 layout with two fewer limbs by
    /// accident: feeding one circuit's signals to the other must not parse.
    @Test func oneCircuitsSignalsDoNotParseAsTheOthers() throws {
        let userSig = signals(ZKPublicInputs.userSigSignalCount)

        #expect(throws: ZKPublicInputsError.unexpectedSignalCount(expected: 19, got: 36)) {
            _ = try ZKPublicInputs.parse(certChain: signals(36), userSig: userSig, circuit: .rs2048)
        }
    }
}

// MARK: - Test-only construction

private extension ZKFieldElement {
    /// Builds an element from bytes that are already canonical. Test-only: the
    /// production initialiser takes hex because that is what crosses the FFI.
    init(unchecked bytes: Data) {
        self = try! ZKFieldElement(hex: bytes.map { String(format: "%02x", $0) }.joined())
    }
}
