//
//  LinkTransport.swift
//  backupTW
//
//  Framing a presentation for a radio link, and putting it back together.
//

import CryptoKit
import Foundation

// MARK: - Why a second transport exists at all
//
// `QRTransport` works and is not being replaced. What changed is the size of
// what has to cross the gap, measured rather than assumed:
//
//   * a card-signed credential presentation is 8,069 bytes — **16 frames** on a
//     real card (measured on device, 2026-08-11), a carousel a little under
//     nine seconds long, and every missed frame costs another full cycle;
//   * a ZK proof package is 293,916 bytes, which is about 808 frames at this
//     app's 364-byte budget and is refused outright by
//     `QRTransport.maximumPayloadBytes` long before that. It travels as a file
//     today, which means AirDrop or the Files app — neither of which exists in
//     the situation §5.3 describes.
//
// So the transport stopped being a nicety for the credential path and became a
// precondition for the ZK one. This file is the part of that which is *ours*:
// the framing, the reassembly, and the refusals. The radio is
// `BluetoothLink`'s problem, and it is deliberately a thin shell over this —
// the same split `RevocationCheck` and `OpenACRevocation` use, for the same
// reason: everything with a decision in it stays testable without hardware.
//
// # Why BLE rather than Wi-Fi Aware or MultipeerConnectivity
//
// Not a performance argument — MultipeerConnectivity is faster and would have
// been less work. It is an interoperability one. **ISO 18013-5, the mobile
// driving licence standard, specifies BLE for device retrieval**, so a verifier
// built for mDL and a verifier built for this app are speaking over the same
// radio with the same shape of exchange. MultipeerConnectivity is Apple-only
// and undocumented on the wire; a national identity document should not be
// reachable only by people holding the same brand of phone.
//
// This is *not* a claim that this app implements ISO 18013-5. It does not: the
// payload is a W3C VP, not an mdoc, and the session encryption that standard
// specifies is not here. What is borrowed is the transport choice and the
// central/peripheral role assignment, so that becoming compatible later is a
// change of payload rather than a change of everything.
//
// # What this layer does not do
//
// It does not encrypt, authenticate, or bind to a session. Every one of those
// is real and every one is somebody else's job here: the presentation is signed
// and carries the verifier's challenge (`VerifiablePresentation`), and the
// verifier checks it offline (`OfflineVerifier`). A transport that added its own
// half-designed encryption on top would be inventing a second security story
// that nobody had reviewed — and BLE's own pairing is not one either, because
// two strangers at a counter have no way to compare a passkey that means
// anything.
//
// The honest statement is: **this carries bytes across a metre of air, and every
// byte is checked after it lands.** An eavesdropper with a radio sees exactly
// what an eavesdropper with a camera sees today.

/// Ways a link frame can be unusable.
enum LinkTransportError: Error, Equatable {
    /// Fewer bytes than a header.
    case frameTooShort
    /// A version this build does not know. Refused rather than guessed at.
    case unsupportedVersion(UInt8)
    /// Reserved flag bits were set. A future sender means something by them and
    /// this build does not know what.
    case unknownFlags(UInt8)
    /// A frame from a different transfer arrived mid-reassembly.
    case frameFromAnotherTransfer
    /// Two frames of one transfer disagree about the total or the flags.
    case inconsistentHeader
    /// An index at or past the declared total.
    case indexOutOfRange(index: Int, total: Int)
    /// A transfer declaring no chunks at all.
    case emptyTransfer
    /// More than this build will reassemble.
    case payloadTooLarge(limit: Int)
    /// Every chunk arrived and the result is not what the sender described.
    case reassemblyDigestMismatch
    /// Nothing to send.
    case emptyPayload
}

/// One frame's header, and the framing rules.
///
/// Binary rather than the base45 text `QRTransport` uses, because a QR code has
/// to survive a camera and a GATT write does not. The shape is deliberately the
/// same, so that the two transports fail in the same ways and a reader of one
/// recognises the other.
///
///     byte  0      version
///     byte  1      flags   (bit 0: body is DEFLATE'd)
///     bytes 2...3  total chunk count, big-endian
///     bytes 4...5  this chunk's index, big-endian
///     bytes 6...9  transfer identifier
///     bytes 10...  body
///
/// Big-endian because every wire format in this project already is, and mixing
/// byte orders inside one app is how a field gets read backwards for a year.
enum LinkTransport {

    static let version: UInt8 = 1
    static let headerByteCount = 10

    private static let deflatedFlag: UInt8 = 0x01
    private static let knownFlags: UInt8 = deflatedFlag

    /// The largest payload this build will reassemble.
    ///
    /// 512 KB rather than `QRTransport`'s 64 KB: the ZK package this exists to
    /// carry is 294 KB, and a ceiling below the thing it was built for would be
    /// a ceiling nobody could use. Still a ceiling, and for the same reason the
    /// other one has one — the bytes arrive from a stranger's radio, the
    /// declared total is theirs to choose, and a reassembler that trusts it
    /// allocates whatever it is told to.
    static let maximumPayloadBytes = 512 * 1024

    /// The largest number of chunks a transfer may declare.
    ///
    /// `UInt16` could say 65,535; this says what the ceiling above actually
    /// implies at the smallest MTU worth supporting, so a hostile sender cannot
    /// make a receiver hold 65,000 sparse entries by sending chunk 64,999 first.
    static let maximumChunkCount = 4096

    /// Splits a payload into frames sized for a negotiated MTU.
    ///
    /// - Parameter maximumFrameBytes: what the link can carry in one write,
    ///   header included. iOS negotiates 20 bytes at worst and 512 at best, and
    ///   the caller learns the real number only after connecting — which is why
    ///   this is an argument rather than a constant.
    static func frames(for payload: Data, maximumFrameBytes: Int) throws -> [Data] {
        guard !payload.isEmpty else { throw LinkTransportError.emptyPayload }
        guard payload.count <= maximumPayloadBytes else {
            throw LinkTransportError.payloadTooLarge(limit: maximumPayloadBytes)
        }
        let bodyBudget = maximumFrameBytes - headerByteCount
        guard bodyBudget > 0 else {
            throw LinkTransportError.payloadTooLarge(limit: 0)
        }

        let identifier = self.identifier(for: payload)
        let deflated = QRTransport.deflateIfSmaller(payload)
        let body = deflated ?? payload
        let flags: UInt8 = deflated == nil ? 0 : deflatedFlag

        // Strided over the body's own indices, never over `0..<count` — a `Data`
        // slice does not have to start at zero, and `subdata(in:)` on one that
        // does not is a trap rather than a wrong answer. `QRTransport.frames`
        // documents the same hazard; it is the same hazard.
        let chunks = stride(from: body.startIndex, to: body.endIndex, by: bodyBudget).map { start in
            body.subdata(in: start..<min(start + bodyBudget, body.endIndex))
        }
        guard chunks.count <= maximumChunkCount else {
            throw LinkTransportError.payloadTooLarge(limit: maximumChunkCount * bodyBudget)
        }

        return chunks.enumerated().map { index, chunk in
            var frame = Data(capacity: headerByteCount + chunk.count)
            frame.append(version)
            frame.append(flags)
            frame.append(UInt8(chunks.count >> 8))
            frame.append(UInt8(chunks.count & 0xff))
            frame.append(UInt8(index >> 8))
            frame.append(UInt8(index & 0xff))
            frame.append(identifier)
            frame.append(chunk)
            return frame
        }
    }

    /// First 4 bytes of SHA-256 over the **uncompressed** payload.
    ///
    /// Two jobs, neither of which is authentication: it tells the reassembler
    /// that two frames belong to one transfer, and it catches a reassembly that
    /// went wrong. Anyone can compute it, so it stops accidents, not attackers —
    /// the signature over the presentation is what stops those, and it is
    /// checked a layer above. Over the uncompressed bytes so that a sender who
    /// compresses and one who does not agree on the identifier for the same
    /// document.
    static func identifier(for payload: Data) -> Data {
        Data(SHA256.hash(data: payload).prefix(4))
    }

    struct Header: Equatable {
        let flags: UInt8
        let total: Int
        let index: Int
        let identifier: Data
        var isDeflated: Bool { flags & deflatedFlag != 0 }
    }

    static func parse(_ frame: Data) throws -> (header: Header, body: Data) {
        guard frame.count > headerByteCount else { throw LinkTransportError.frameTooShort }
        // Indexed off `startIndex`, not 0 — see `frames(for:)`.
        let base = frame.startIndex
        func byte(_ offset: Int) -> UInt8 { frame[base + offset] }

        guard byte(0) == version else { throw LinkTransportError.unsupportedVersion(byte(0)) }
        let flags = byte(1)
        guard flags & ~knownFlags == 0 else { throw LinkTransportError.unknownFlags(flags) }

        let total = Int(byte(2)) << 8 | Int(byte(3))
        let index = Int(byte(4)) << 8 | Int(byte(5))
        guard total > 0 else { throw LinkTransportError.emptyTransfer }
        guard total <= maximumChunkCount else {
            throw LinkTransportError.payloadTooLarge(limit: maximumChunkCount)
        }
        guard index < total else { throw LinkTransportError.indexOutOfRange(index: index, total: total) }

        let identifier = frame.subdata(in: (base + 6)..<(base + 10))
        let body = frame.subdata(in: (base + headerByteCount)..<frame.endIndex)
        return (Header(flags: flags, total: total, index: index, identifier: identifier), body)
    }
}

// MARK: - Reassembly

/// Collects frames until a transfer is whole.
///
/// Deliberately the same shape as `FrameCollector`: accept one frame at a time,
/// report progress, hand back the payload once and only once. Two transports
/// that behave differently under a duplicate or a stray frame are two
/// transports somebody has to reason about separately.
final class LinkCollector {

    struct Progress: Equatable {
        let received: Int
        let total: Int
        var fraction: Double { total == 0 ? 0 : Double(received) / Double(total) }
    }

    enum Reception: Equatable {
        case accepted(Progress)
        case duplicate(Progress)
        case completed(Data)
    }

    private var identifier: Data?
    private var isDeflated = false
    private var total: Int?
    private var chunks: [Int: Data] = [:]
    private var heldBytes = 0

    init() {}

    var progress: Progress? {
        guard let total else { return nil }
        return Progress(received: chunks.count, total: total)
    }

    func reset() {
        identifier = nil
        isDeflated = false
        total = nil
        chunks = [:]
        heldBytes = 0
    }

    /// Takes one frame off the link.
    ///
    /// Throwing leaves the collector exactly as it was. A stray frame from
    /// somebody else's phone — and at a counter there will be other phones —
    /// must not discard a transfer that is nearly done.
    func accept(_ frame: Data) throws -> Reception {
        let (header, body) = try LinkTransport.parse(frame)

        if let identifier {
            guard header.identifier == identifier else {
                throw LinkTransportError.frameFromAnotherTransfer
            }
            guard header.total == total, header.isDeflated == isDeflated else {
                throw LinkTransportError.inconsistentHeader
            }
        }

        // Checked before the chunk is stored, so a hostile sender cannot grow
        // this collector past the ceiling one frame at a time. The compressed
        // body is what is held, and the ceiling is on the *uncompressed* result
        // — so this is the cheap bound; `inflate` enforces the real one.
        guard heldBytes + body.count <= LinkTransport.maximumPayloadBytes else {
            throw LinkTransportError.payloadTooLarge(limit: LinkTransport.maximumPayloadBytes)
        }

        if identifier == nil {
            identifier = header.identifier
            isDeflated = header.isDeflated
            total = header.total
        }

        if chunks[header.index] != nil {
            return .duplicate(Progress(received: chunks.count, total: header.total))
        }
        chunks[header.index] = body
        heldBytes += body.count

        guard chunks.count == header.total else {
            return .accepted(Progress(received: chunks.count, total: header.total))
        }

        let assembled = (0..<header.total).reduce(into: Data()) { $0.append(chunks[$1] ?? Data()) }
        let payload = isDeflated
            ? try QRTransport.inflate(assembled, limit: LinkTransport.maximumPayloadBytes)
            : assembled

        // The last thing checked, and the only one that catches a transfer that
        // was individually plausible frame by frame: a spliced chunk from a
        // transfer whose first four identifier bytes happened to collide, a
        // sender that compressed but cleared the flag, a truncated final chunk.
        guard LinkTransport.identifier(for: payload) == identifier else {
            throw LinkTransportError.reassemblyDigestMismatch
        }
        return .completed(payload)
    }
}
