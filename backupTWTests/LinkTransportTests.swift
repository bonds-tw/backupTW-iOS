//
//  LinkTransportTests.swift
//  backupTWTests
//
//  Framing for the radio, and every way a frame can be unusable.
//

import Foundation
import Testing
@testable import backupTW

/// The transport exists because two payloads outgrew QR: a real card's
/// presentation is 16 frames, and a ZK package is refused outright. So the
/// property under test throughout is *the bytes that come out are the bytes
/// that went in* — across MTUs the sender does not choose, frame orders the
/// radio does not promise, and neighbours whose phones are also transmitting.
struct LinkTransportTests {

    /// Deterministic bytes that DEFLATE cannot shrink.
    ///
    /// Every multi-frame test here first used `Data(repeating:)`, which
    /// compresses to a single frame — so the ordering test shuffled a
    /// one-element array, the duplicate test's first frame already completed
    /// the transfer, and the stray-frame test indexed `theirs[1]` on a
    /// one-element array and took the process down. A fixture that quietly
    /// degenerates to one frame is a test that is not testing its own name.
    static func incompressible(_ count: Int, seed: UInt64 = 0xC0FFEE) -> Data {
        var state = seed
        return Data((0..<count).map { _ -> UInt8 in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    /// The MTUs iOS actually hands out. 20 is the legacy floor, 185 is what a
    /// modern iPhone negotiates for notifications, 512 is the ATT ceiling.
    /// Asserting across all three is the point: the framing takes the MTU as an
    /// argument precisely because the caller learns it only after connecting.
    @Test(arguments: [20, 27, 185, 244, 512])
    func aPayloadSurvivesEveryMTU(_ mtu: Int) throws {
        let payload = Self.incompressible(9000, seed: 5)
        let frames = try LinkTransport.frames(for: payload, maximumFrameBytes: mtu)
        #expect(frames.count > 1)

        #expect(frames.allSatisfy { $0.count <= mtu }, "a frame did not fit the MTU it was framed for")

        let collector = LinkCollector()
        var received: Data?
        for frame in frames {
            if case .completed(let data) = try collector.accept(frame) { received = data }
        }
        #expect(try #require(received) == payload)
    }

    /// A radio delivers what it delivers. Nothing about GATT promises order, and
    /// a reassembler that quietly depended on it would work on a bench and fail
    /// in a room with interference.
    @Test func framesReassembleInAnyOrder() throws {
        let payload = Self.incompressible(4096)
        let frames = try LinkTransport.frames(for: payload, maximumFrameBytes: 185)
        #expect(frames.count > 4, "shuffling one frame proves nothing about order")

        let collector = LinkCollector()
        var received: Data?
        for frame in frames.shuffled() {
            if case .completed(let data) = try collector.accept(frame) { received = data }
        }
        #expect(try #require(received) == payload)
    }

    /// Retransmission is normal on a radio; losing the transfer to it is not.
    @Test func aRepeatedFrameIsReportedWithoutDisturbingProgress() throws {
        let payload = Self.incompressible(2000)
        let frames = try LinkTransport.frames(for: payload, maximumFrameBytes: 185)
        #expect(frames.count > 1, "a single-frame transfer completes on the first accept")
        let collector = LinkCollector()

        _ = try collector.accept(frames[0])
        let before = collector.progress
        guard case .duplicate(let progress) = try collector.accept(frames[0]) else {
            Issue.record("a repeated frame was not reported as a duplicate")
            return
        }
        #expect(progress == before)
        #expect(collector.progress == before)
    }

    /// The counter case, which is why the identifier exists: somebody else's
    /// phone is transmitting in the same room.
    @Test func aFrameFromAnotherTransferIsRefusedAndChangesNothing() throws {
        let mine = try LinkTransport.frames(for: Self.incompressible(1500, seed: 1),
                                            maximumFrameBytes: 185)
        let theirs = try LinkTransport.frames(for: Self.incompressible(1500, seed: 2),
                                              maximumFrameBytes: 185)
        #expect(mine.count > 1 && theirs.count > 1)
        let collector = LinkCollector()
        _ = try collector.accept(mine[0])
        let before = collector.progress

        #expect(throws: LinkTransportError.frameFromAnotherTransfer) {
            _ = try collector.accept(theirs[1])
        }
        #expect(collector.progress == before, "a stranger's frame disturbed a transfer in progress")

        // And mine still completes afterwards.
        var received: Data?
        for frame in mine.dropFirst() {
            if case .completed(let data) = try collector.accept(frame) { received = data }
        }
        #expect(received != nil)
    }

    // MARK: - Refusals

    @Test func aFrameShorterThanItsHeaderIsRefused() {
        for length in 0...LinkTransport.headerByteCount {
            #expect(throws: LinkTransportError.frameTooShort) {
                _ = try LinkTransport.parse(Data(repeating: 0, count: length))
            }
        }
    }

    /// A version this build does not know is refused, never guessed at — the
    /// same rule `ZKProofPackage` applies, for the same reason.
    @Test func anUnknownVersionIsRefused() throws {
        var frame = try LinkTransport.frames(for: Data(repeating: 7, count: 100),
                                             maximumFrameBytes: 185)[0]
        frame[frame.startIndex] = 9
        #expect(throws: LinkTransportError.unsupportedVersion(9)) {
            _ = try LinkTransport.parse(frame)
        }
    }

    /// Reserved flag bits mean something to whoever set them. Ignoring them
    /// would be this build deciding a future sender's payload is what it looks
    /// like.
    @Test func reservedFlagBitsAreRefused() throws {
        var frame = try LinkTransport.frames(for: Data(repeating: 7, count: 100),
                                             maximumFrameBytes: 185)[0]
        frame[frame.startIndex + 1] |= 0x80
        #expect(throws: LinkTransportError.unknownFlags(frame[frame.startIndex + 1])) {
            _ = try LinkTransport.parse(frame)
        }
    }

    /// An index past the declared total is the shape of a sender trying to make
    /// a receiver hold a sparse array of whatever size it likes.
    @Test func anIndexPastTheTotalIsRefused() throws {
        var frame = try LinkTransport.frames(for: Data(repeating: 7, count: 100),
                                             maximumFrameBytes: 185)[0]
        // total = 1, index = 5
        frame[frame.startIndex + 4] = 0
        frame[frame.startIndex + 5] = 5
        #expect(throws: LinkTransportError.indexOutOfRange(index: 5, total: 1)) {
            _ = try LinkTransport.parse(frame)
        }
    }

    @Test func aTransferDeclaringNoChunksIsRefused() throws {
        var frame = try LinkTransport.frames(for: Data(repeating: 7, count: 100),
                                             maximumFrameBytes: 185)[0]
        frame[frame.startIndex + 2] = 0
        frame[frame.startIndex + 3] = 0
        #expect(throws: LinkTransportError.emptyTransfer) {
            _ = try LinkTransport.parse(frame)
        }
    }

    @Test func anEmptyPayloadIsRefusedRatherThanFramedAsNothing() {
        #expect(throws: LinkTransportError.emptyPayload) {
            _ = try LinkTransport.frames(for: Data(), maximumFrameBytes: 185)
        }
    }

    @Test func aPayloadPastTheCeilingIsRefused() {
        #expect(throws: LinkTransportError.payloadTooLarge(limit: LinkTransport.maximumPayloadBytes)) {
            _ = try LinkTransport.frames(
                for: Data(repeating: 0, count: LinkTransport.maximumPayloadBytes + 1),
                maximumFrameBytes: 185)
        }
    }

    /// An MTU with no room for a body cannot be framed for — better to say so
    /// than to emit an infinite number of empty frames.
    @Test func anMTUTooSmallForAnyBodyIsRefused() {
        #expect(throws: LinkTransportError.self) {
            _ = try LinkTransport.frames(for: Data(repeating: 1, count: 10),
                                         maximumFrameBytes: LinkTransport.headerByteCount)
        }
    }

    /// The bound that matters against a hostile sender: it is enforced as the
    /// frames arrive, not once they are all in. A receiver that only checked at
    /// the end has already allocated whatever it was sent.
    @Test func theCeilingIsEnforcedWhileFramesArriveNotAfterwards() throws {
        // A hand-built transfer claiming a plausible total, whose frames are
        // each legal and whose sum is not.
        let identifier = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let body = Data(repeating: 0x5A, count: 500)
        func frame(index: Int, total: Int) -> Data {
            var f = Data([LinkTransport.version, 0,
                          UInt8(total >> 8), UInt8(total & 0xff),
                          UInt8(index >> 8), UInt8(index & 0xff)])
            f.append(identifier)
            f.append(body)
            return f
        }
        let total = LinkTransport.maximumPayloadBytes / body.count + 10
        let collector = LinkCollector()

        var refusedAt: Int?
        for index in 0..<total {
            do { _ = try collector.accept(frame(index: index, total: total)) }
            catch { refusedAt = index; break }
        }
        let stopped = try #require(refusedAt, "the collector accepted more than its ceiling")
        #expect(stopped < total, "the ceiling was only checked once every frame had arrived")
    }

    // MARK: - Integrity

    /// The check that catches everything the per-frame rules cannot: a chunk
    /// swapped for one from a transfer whose identifier collided, a flag that
    /// lied, a final chunk that was truncated.
    @Test func acorruptedChunkIsCaughtAtTheEnd() throws {
        // Incompressible, so the corruption lands in the middle of a transfer
        // rather than in the only frame there is.
        let payload = Self.incompressible(3000, seed: 4)
        var frames = try LinkTransport.frames(for: payload, maximumFrameBytes: 185)
        #expect(frames.count > 2, "the fixture compressed away; this test needs several frames")

        // Flip a bit in a body byte, leaving every header field intact. Pulled
        // out and put back rather than mutated through the array subscript —
        // `frames[i][frames[i].startIndex + n] ^= x` reads the index off the
        // element it is already mutating.
        let victim = frames.count / 2
        var damaged = frames[victim]
        damaged[damaged.startIndex + LinkTransport.headerByteCount] ^= 0xff
        frames[victim] = damaged

        let collector = LinkCollector()
        #expect(throws: LinkTransportError.reassemblyDigestMismatch) {
            for frame in frames {
                _ = try collector.accept(frame)
            }
        }
    }

    /// The identifier is over the *uncompressed* payload, so a sender that
    /// compresses and one that does not agree about what document this is.
    @Test func theIdentifierDoesNotDependOnWhetherItCompressed() throws {
        // Highly compressible and incompressible payloads of the same content
        // shape; the identifier is a function of the plaintext either way.
        let compressible = Data(repeating: 0x42, count: 4000)
        let framed = try LinkTransport.frames(for: compressible, maximumFrameBytes: 185)
        let (header, _) = try LinkTransport.parse(framed[0])

        #expect(header.identifier == LinkTransport.identifier(for: compressible))
        #expect(header.isDeflated, "4000 identical bytes did not compress — check the flag wiring")
    }

    /// Real payloads: the two this transport exists for. Not a size assertion —
    /// those live in `PresentationFrameCountTests` — but a demonstration that
    /// both fit, which is the whole claim being made about this layer.
    @Test(arguments: [8_069, 293_916])
    func theTwoPayloadsThisExistsForBothFit(_ size: Int) throws {
        let payload = Self.incompressible(size, seed: UInt64(size))
        let frames = try LinkTransport.frames(for: payload, maximumFrameBytes: 185)
        #expect(frames.count > 1)

        let collector = LinkCollector()
        var received: Data?
        for frame in frames.shuffled() {
            if case .completed(let data) = try collector.accept(frame) { received = data }
        }
        #expect(try #require(received) == payload)
        #expect(frames.count <= LinkTransport.maximumChunkCount)
    }

    /// Deterministic fuzz. The contract is only "throws or returns, never
    /// traps" — a mutation can legitimately still be a valid frame, and the
    /// bytes come off a stranger's radio.
    @Test func randomMutationsNeverTrap() throws {
        var state: UInt64 = 0x5EED_1234
        func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 16 }

        let frames = try LinkTransport.frames(for: Self.incompressible(2048, seed: 3),
                                              maximumFrameBytes: 185)
        for _ in 0..<800 {
            let collector = LinkCollector()
            for frame in frames {
                var damaged = frame
                if next() % 3 == 0, !damaged.isEmpty {
                    let offset = Int(next() % UInt64(damaged.count))
                    damaged[damaged.startIndex + offset] = UInt8(next() % 256)
                }
                if next() % 7 == 0 {
                    damaged = damaged.prefix(Int(next() % UInt64(damaged.count + 1)))
                }
                _ = try? collector.accept(damaged)
            }
        }
    }

    /// `Data` slices do not start at zero, and every offset in this file is
    /// computed off `startIndex` for that reason. A frame handed over as a
    /// subrange of a receive buffer is the normal case on a radio, not an
    /// exotic one.
    @Test func aFrameThatIsASliceOfALargerBufferParsesIdentically() throws {
        let frame = try LinkTransport.frames(for: Data(repeating: 9, count: 300),
                                             maximumFrameBytes: 185)[0]
        var buffer = Data(repeating: 0xEE, count: 64)
        buffer.append(frame)
        let slice = buffer[(buffer.startIndex + 64)...]

        let (a, bodyA) = try LinkTransport.parse(frame)
        let (b, bodyB) = try LinkTransport.parse(slice)
        #expect(a == b)
        #expect(bodyA == bodyB)
    }
}
