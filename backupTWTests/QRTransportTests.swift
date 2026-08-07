//
//  QRTransportTests.swift
//  backupTWTests
//

import Compression
import CoreImage
import Foundation
import Testing
@testable import backupTW

// MARK: - base45

/// Checked against RFC 9285's own vectors rather than against `Base45.encode`.
///
/// A decoder tested only against its matching encoder passes on any
/// self-consistent alphabet, including one with two characters transposed —
/// and a transposed alphabet is invisible until the day something else has to
/// read our frames. The four vectors below are copied from the RFC.
struct Base45Tests {

    @Test func matchesTheRFCVectors() throws {
        let vectors = [("AB", "BB8"),
                       ("Hello!!", "%69 VD92EX0"),
                       ("base-45", "UJCLQE7W581"),
                       ("ietf!", "QED8WEX0")]
        for (plain, encoded) in vectors {
            #expect(Base45.encode(Data(plain.utf8)) == encoded)
            #expect(try Base45.decode(encoded) == Data(plain.utf8))
        }
    }

    @Test func roundTripsEveryByteValue() throws {
        let all = Data((0...255).map { UInt8($0) })
        #expect(try Base45.decode(Base45.encode(all)) == all)
    }

    /// An odd length takes the two-character tail, an even one does not, and
    /// the boundary is where a group-size mistake hides.
    @Test(arguments: [0, 1, 2, 3, 4, 5, 363, 364, 365])
    func roundTripsPayloadOfSize(_ size: Int) throws {
        let payload = Data((0..<size).map { UInt8($0 % 251) })
        #expect(try Base45.decode(Base45.encode(payload)) == payload)
    }

    /// The alphabet contains the space character, and a chunk can genuinely
    /// begin with one — `00 24` is the smallest example. Anything that trims a
    /// scanned string before handing it to `FrameCollector` silently corrupts
    /// the payload, so the encoding of that pair is pinned here.
    @Test func preservesASpaceAtTheStartOfAChunk() throws {
        #expect(Base45.encode(Data([0x00, 0x24])) == " 00")
        #expect(try Base45.decode(" 00") == Data([0x00, 0x24]))
    }

    /// A length of 1 modulo 3 is not a whole number of groups.
    @Test(arguments: ["A", "ABCD", "0123456"])
    func rejectsALengthThatIsNotWholeGroups(_ text: String) {
        #expect(throws: QRTransportError.corruptChunk) { try Base45.decode(text) }
    }

    /// Lowercase is outside the alphabet — and outside QR's alphanumeric mode,
    /// so it cannot have come from a frame we produced.
    @Test(arguments: ["ab8", "BB!", "BB\u{FF10}", "王小明"])
    func rejectsCharactersOutsideTheAlphabet(_ text: String) {
        #expect(throws: QRTransportError.corruptChunk) { try Base45.decode(text) }
    }

    /// Three characters span 45³ = 91125 values but may only encode 65536, and
    /// two span 2025 but may only encode 256. Damage that lands in the unused
    /// range is caught here instead of becoming plausible bytes.
    @Test func rejectsAGroupTooLargeForTheBytesItClaims() {
        // "00X" = 0 + 0×45 + 33×2025 = 66825, past 0xFFFF.
        #expect(throws: QRTransportError.corruptChunk) { try Base45.decode("00X") }
        // "0X" = 0 + 33×45 = 1485, past 0xFF.
        #expect(throws: QRTransportError.corruptChunk) { try Base45.decode("0X") }
    }
}

// MARK: - Framing

struct QRTransportFramingTests {

    @Test func rejectsAnEmptyPayload() {
        #expect(throws: QRTransportError.emptyPayload) { try QRTransport.frames(for: Data()) }
    }

    @Test func rejectsAPayloadLargerThanAScannerWillReassemble() {
        let huge = Data(repeating: 0x5A, count: QRTransport.maximumPayloadBytes + 1)
        #expect(throws: QRTransportError.payloadTooLarge(limit: QRTransport.maximumPayloadBytes)) {
            try QRTransport.frames(for: huge)
        }
    }

    @Test func putsASmallPayloadInASingleFrame() throws {
        let frames = try QRTransport.frames(for: Data("hello".utf8))
        #expect(frames.count == 1)
        #expect(frames[0].hasPrefix("BTWVP1:"))
    }

    /// The density argument in `frameCharacterBudget` only holds if every byte
    /// of every frame stays inside QR's alphanumeric set. One stray character
    /// outside it — a lowercase letter, a hyphen in a UUID, an underscore from
    /// base64url — knocks the encoder into byte mode and costs 23% of the
    /// capacity that the frame budget was calculated against. Nothing else in
    /// the suite would notice; the codes would just quietly get bigger.
    @Test(arguments: [1, 2, 100, 700, 1793, 5000])
    func keepsEveryFrameInsideTheQRAlphanumericSet(_ size: Int) throws {
        let allowed = Set(Base45.alphabet)
        for frame in try QRTransport.frames(for: Fixtures.incompressible(size)) {
            #expect(frame.allSatisfy { allowed.contains($0) })
        }
    }

    /// The budget is a legibility promise, not a capacity one: past 89 modules
    /// the code stops being readable at arm's length on the oldest device this
    /// app supports. This is the test that fails if the header grows, the chunk
    /// budget is raised, or the correction level changes without the arithmetic
    /// being redone.
    @Test(arguments: [1, 700, 1793, 5000])
    func keepsEveryFrameWithinTheModuleBudget(_ size: Int) throws {
        for frame in try QRTransport.frames(for: Fixtures.incompressible(size)) {
            #expect(frame.count <= QRTransport.frameCharacterBudget)
            let code = try QRTransport.qrCode(for: frame, fittingPixelWidth: 750)
            #expect(code.moduleCount <= QRTransport.maximumModuleCount)
        }
    }

    /// `chunkByteBudget` is derived by subtracting `headerLength` from the
    /// character budget, so a header that is not exactly that wide silently
    /// makes every frame over or under size. Splitting a frame at the declared
    /// offset and decoding the remainder proves the two agree.
    @Test func headerIsExactlyTheWidthTheChunkBudgetAssumes() throws {
        let payload = Fixtures.incompressible(QRTransport.chunkByteBudget * 2)
        let frames = try QRTransport.frames(for: payload)
        try #require(frames.count == 2)

        for (index, frame) in frames.enumerated() {
            let chunkText = String(frame.dropFirst(QRTransport.headerLength))
            let start = index * QRTransport.chunkByteBudget
            let expected = payload.subdata(in: start..<(start + QRTransport.chunkByteBudget))
            #expect(try Base45.decode(chunkText) == expected)
        }
    }

    /// Frames are numbered from zero and counted from one, both zero-padded.
    @Test func numbersFramesInOrder() throws {
        let frames = try QRTransport.frames(for: Fixtures.incompressible(QRTransport.chunkByteBudget * 3))
        try #require(frames.count == 3)
        for (index, frame) in frames.enumerated() {
            let fields = frame.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
            #expect(fields[3] == String(format: "%02d", index))
            #expect(fields[4] == "03")
        }
        // One presentation, one identifier.
        let identifiers = Set(frames.map { $0.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)[2] })
        #expect(identifiers.count == 1)
    }

    // MARK: Compression

    /// Compression is what takes the real presentation from five frames to
    /// three. If it stops firing, the carousel gets longer without anything
    /// else failing.
    @Test func deflatesAPayloadThatBenefits() throws {
        let repetitive = Data(String(repeating: "臺北市中正區重慶南路一段122號", count: 60).utf8)
        let frames = try QRTransport.frames(for: repetitive)

        #expect(frames.allSatisfy { $0.hasPrefix("BTWVP1:Z:") })
        let uncompressedFrames = (repetitive.count + QRTransport.chunkByteBudget - 1) / QRTransport.chunkByteBudget
        #expect(frames.count < uncompressedFrames)
        #expect(try Fixtures.collect(frames) == repetitive)
    }

    /// DEFLATE grows incompressible input. Sending the grown version would make
    /// random or already-compressed payloads cost an extra frame for nothing.
    @Test func storesAPayloadThatCompressionWouldGrow() throws {
        let random = Fixtures.incompressible(800)
        let frames = try QRTransport.frames(for: random)

        #expect(frames.allSatisfy { $0.hasPrefix("BTWVP1:U:") })
        #expect(try Fixtures.collect(frames) == random)
    }

    // MARK: Round trips

    /// Sizes that sit either side of a chunk boundary, plus the one-byte case
    /// where the compression buffer would have zero capacity.
    @Test(arguments: [1, 2, 3, 363, 364, 365, 728, 729, 1793, 5000, 20_000])
    func roundTripsPayloadOfSize(_ size: Int) throws {
        let payload = Fixtures.incompressible(size)
        #expect(try Fixtures.collect(QRTransport.frames(for: payload)) == payload)
    }

    /// The transport must stay indifferent to what it carries — that is what
    /// lets a COSE proof object replace the JOSE presentation later without any
    /// of this changing. Bytes that are not valid UTF-8 are the sharp case.
    @Test func carriesArbitraryBinaryUnchanged() throws {
        let binary = Data([0x00, 0xFF, 0xFE, 0xD8, 0x00, 0x1F, 0x8B] + (0..<500).map { UInt8($0 % 256) })
        #expect(try Fixtures.collect(QRTransport.frames(for: binary)) == binary)
    }

    /// A `Data` whose indices do not start at zero still frames correctly.
    ///
    /// Every other payload in this suite is built with `Data(...)`, so all of
    /// them start at zero and none of them can catch this. But a `Data` is a
    /// view: `dropFirst(n)`, `data[100...]` and any subrange of a scan buffer
    /// keep the *parent's* indices, so a 900-byte value can be indexed
    /// 100..<1000. Striding over `0..<count` and calling
    /// `subdata(in: 0..<364)` on such a value is an out-of-bounds access — it
    /// does not return the wrong bytes, it traps, which at a counter is the
    /// holder's app dying mid-presentation.
    ///
    /// The payload must be incompressible so that framing takes the stored
    /// path, where `body` *is* the argument and inherits its indices. On the
    /// deflated path the compressor writes into a fresh zero-based buffer and
    /// the bug cannot show.
    ///
    /// Note this test crashes the run rather than reporting a failure if the
    /// defect returns — a trap is not catchable. That is the honest shape for
    /// this bug: the symptom being tested for *is* the dead process.
    @Test func framesAPayloadWhoseIndicesDoNotStartAtZero() throws {
        let padded = Fixtures.incompressible(QRTransport.chunkByteBudget * 3)
        let offset = padded.dropFirst(100)
        try #require(offset.startIndex == 100)

        let frames = try QRTransport.frames(for: offset)
        #expect(try Fixtures.collect(frames) == Data(offset))
    }
}

// MARK: - Collecting

struct FrameCollectorTests {

    @Test func reportsNoProgressBeforeTheFirstFrame() {
        #expect(FrameCollector().progress == nil)
    }

    /// A verifier holding a phone up to another phone gets whatever frame the
    /// carousel happens to be showing, and a printed sheet has no order at all.
    /// Every permutation of a three-frame presentation is enumerated rather than
    /// shuffled, so a failure names the order that broke it.
    @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    func reassemblesFramesDeliveredInAnyOrder(_ order: [Int]) throws {
        let payload = Fixtures.presentation
        let frames = try QRTransport.frames(for: payload)
        try #require(frames.count == 3)

        let collector = FrameCollector()
        var completed: Data?
        for index in order {
            if case .completed(let data) = try collector.accept(frames[index]) { completed = data }
        }
        #expect(completed == payload)
    }

    /// The scanner calls `accept` for every video frame, so most calls are
    /// repeats. A progress counter that moved on repeats would climb to
    /// "3 of 3" while still missing two thirds of the document.
    @Test func doesNotCountADuplicateAsProgress() throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let collector = FrameCollector()

        #expect(try collector.accept(frames[0]) == .accepted(.init(received: 1, total: 3)))
        for _ in 0..<10 {
            #expect(try collector.accept(frames[0]) == .duplicate(.init(received: 1, total: 3)))
        }
        #expect(collector.progress == FrameCollector.Progress(received: 1, total: 3))

        #expect(try collector.accept(frames[1]) == .accepted(.init(received: 2, total: 3)))
        #expect(try collector.accept(frames[0]) == .duplicate(.init(received: 2, total: 3)))
        #expect(collector.progress?.received == 2)
    }

    /// The failure that matters most: claiming a complete payload from an
    /// incomplete scan would hand the verifier a truncated presentation.
    @Test(arguments: [0, 1, 2])
    func neverCompletesWhileAFrameIsMissing(_ withheld: Int) throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let collector = FrameCollector()

        // Several passes of the carousel, so repetition cannot accumulate into
        // a false completion.
        for _ in 0..<5 {
            for (index, frame) in frames.enumerated() where index != withheld {
                let reception = try collector.accept(frame)
                if case .completed = reception { Issue.record("completed without frame \(withheld)") }
            }
        }
        #expect(collector.progress == FrameCollector.Progress(received: 2, total: 3))
        #expect(collector.progress?.isComplete == false)
    }

    /// The carousel does not know the scan succeeded and keeps playing. Late
    /// frames must not turn a finished scan into an error.
    @Test func keepsReturningThePayloadWhenTheCarouselPlaysOn() throws {
        let payload = Fixtures.presentation
        let frames = try QRTransport.frames(for: payload)
        let collector = FrameCollector()

        for frame in frames { _ = try collector.accept(frame) }
        for frame in frames + frames {
            #expect(try collector.accept(frame) == .completed(payload))
        }
    }

    @Test func startsOverAfterReset() throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let collector = FrameCollector()
        _ = try collector.accept(frames[0])
        collector.reset()
        #expect(collector.progress == nil)
        #expect(try collector.accept(frames[0]) == .accepted(.init(received: 1, total: 3)))
    }

    // MARK: Rejection

    /// Two people in a queue, or a holder who swiped to a second document.
    @Test func rejectsAFrameFromAnotherPresentation() throws {
        let mine = try QRTransport.frames(for: Fixtures.presentation)
        let theirs = try QRTransport.frames(for: Fixtures.presentation + Data("x".utf8))
        let collector = FrameCollector()

        _ = try collector.accept(mine[0])
        #expect(throws: QRTransportError.frameFromAnotherPresentation) {
            try collector.accept(theirs[0])
        }
    }

    /// Rejecting must not cost the verifier the two thirds they already have —
    /// a stray code drifting through the viewfinder is not a reason to start
    /// over.
    @Test func survivesAForeignFrameWithoutLosingProgress() throws {
        let payload = Fixtures.presentation
        let mine = try QRTransport.frames(for: payload)
        let theirs = try QRTransport.frames(for: payload + Data("x".utf8))
        let collector = FrameCollector()

        _ = try collector.accept(mine[0])
        _ = try collector.accept(mine[1])
        #expect(throws: QRTransportError.frameFromAnotherPresentation) { try collector.accept(theirs[2]) }
        #expect(collector.progress == FrameCollector.Progress(received: 2, total: 3))

        #expect(try collector.accept(mine[2]) == .completed(payload))
    }

    /// A verifier's camera resolves whatever is in view. This is the ordinary
    /// case and the caller is expected to ignore it, which only works if it is
    /// distinguishable from the errors that do deserve words.
    @Test(arguments: ["WIFI:S=counter;T=WPA;P=hunter2;;",
                      "https://bonds.tw",
                      "",
                      "BTW",
                      "12345"])
    func ignoresCodesThatAreNotTransportFrames(_ scanned: String) {
        #expect(throws: QRTransportError.notATransportFrame) { try FrameCollector().accept(scanned) }
    }

    /// A newer wallet talking to an older scanner should say "update the app",
    /// not "that is not a QR code we recognise".
    @Test func reportsANewerFormatSeparately() {
        #expect(throws: QRTransportError.unsupportedFormat("BTWVP2")) {
            try FrameCollector().accept("BTWVP2:Z:A1B2C3D4E5:00:01:BB8")
        }
    }

    @Test(arguments: [
        "BTWVP1:Z:A1B2C3D4E5:00:01",           // no chunk field at all
        "BTWVP1:X:A1B2C3D4E5:00:01:BB8",       // compression flag is neither Z nor U
        "BTWVP1:Z:a1b2c3d4e5:00:01:BB8",       // identifier not uppercase hex
        "BTWVP1:Z:A1B2C3D4:00:01:BB8",         // identifier too short
        "BTWVP1:Z:A1B2C3D4E5:0:1:BB8",         // counters not zero-padded
        "BTWVP1:Z:A1B2C3D4E5:03:02:BB8",       // index past the count
        "BTWVP1:Z:A1B2C3D4E5:00:00:BB8",       // a presentation of no frames
        "BTWVP1:Z:A1B2C3D4E5:AA:01:BB8",       // counters not numeric
    ])
    func rejectsAMalformedHeader(_ scanned: String) {
        #expect(throws: QRTransportError.malformedFrame) { try FrameCollector().accept(scanned) }
    }

    /// Damage has to throw, not trap. `Base45.decode` builds `UInt8`s from
    /// arithmetic on scanned input, and an unchecked group would crash the
    /// scanner on a bad read rather than asking for another one.
    @Test(arguments: ["BTWVP1:U:A1B2C3D4E5:00:01:00X",   // group past 0xFFFF
                      "BTWVP1:U:A1B2C3D4E5:00:01:AB",    // not whole groups
                      "BTWVP1:U:A1B2C3D4E5:00:01:bb8"])  // outside the alphabet
    func rejectsACorruptChunkInsteadOfTrapping(_ scanned: String) {
        #expect(throws: QRTransportError.corruptChunk) { try FrameCollector().accept(scanned) }
    }

    @Test func rejectsAFrameCountThatDisagreesWithTheOnesHeld() throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let collector = FrameCollector()
        _ = try collector.accept(frames[0])

        // Same identifier, different count — what a hand-edited frame or a
        // truncated-digest collision looks like.
        let fields = frames[1].split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        let restated = ["BTWVP1", String(fields[1]), String(fields[2]), "01", "09", String(fields[5])]
            .joined(separator: ":")
        #expect(throws: QRTransportError.inconsistentFrameHeader) { try collector.accept(restated) }
    }

    /// Two different chunks claiming the same slot under the same identifier.
    @Test func rejectsASecondChunkForASlotAlreadyHeld() throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let collector = FrameCollector()
        _ = try collector.accept(frames[0])

        let header = String(frames[0].prefix(QRTransport.headerLength))
        let substituted = header + Base45.encode(Data(repeating: 0x00, count: QRTransport.chunkByteBudget))
        #expect(throws: QRTransportError.frameFromAnotherPresentation) { try collector.accept(substituted) }
    }

    // MARK: Integrity

    /// A chunk swapped for a well-formed one that decodes cleanly. Nothing
    /// before the digest check can see it: the header is intact, base45 accepts
    /// it, and the frame count is right.
    ///
    /// The payload is incompressible on purpose, so the frames are stored rather
    /// than deflated and the substitution reaches the digest instead of dying in
    /// the inflater first — which is the weaker of the two gates and the one
    /// that would still catch it.
    @Test func catchesASubstitutedChunkWithThePayloadDigest() throws {
        let frames = try QRTransport.frames(for: Fixtures.incompressible(700))
        try #require(frames.allSatisfy { $0.hasPrefix("BTWVP1:U:") })

        var tampered = frames
        let header = String(frames[0].prefix(QRTransport.headerLength))
        tampered[0] = header + Base45.encode(Data(repeating: 0x00, count: QRTransport.chunkByteBudget))

        let collector = FrameCollector()
        #expect(throws: QRTransportError.payloadDigestMismatch) {
            for frame in tampered { _ = try collector.accept(frame) }
        }
    }

    /// After a failed assembly the held chunks are suspect and at least one is
    /// wrong, but nothing can say which. Keeping them would wedge the collector:
    /// the carousel re-delivers the same frames, each matches a slot already
    /// held, every one is answered `.duplicate`, and the assembly is never
    /// retried. This test is the reason `accept` resets on that path.
    @Test func recoversAfterAFailedAssembly() throws {
        let payload = Fixtures.incompressible(700)
        let frames = try QRTransport.frames(for: payload)
        let header = String(frames[0].prefix(QRTransport.headerLength))
        var tampered = frames
        tampered[0] = header + Base45.encode(Data(repeating: 0x00, count: QRTransport.chunkByteBudget))

        let collector = FrameCollector()
        #expect(throws: QRTransportError.payloadDigestMismatch) {
            for frame in tampered { _ = try collector.accept(frame) }
        }
        #expect(collector.progress == nil)

        // A clean pass of the carousel now succeeds, which it could not do if
        // the poisoned chunk were still occupying slot 0.
        var completed: Data?
        for frame in frames {
            if case .completed(let data) = try collector.accept(frame) { completed = data }
        }
        #expect(completed == payload)
    }

    /// The frames come off a stranger's screen and the expansion ratio of a
    /// DEFLATE stream is chosen by whoever produced it. A megabyte of zeroes
    /// compresses into three frames; without a ceiling those three frames
    /// allocate a megabyte on the verifier's phone, and nothing stops the next
    /// three from allocating a gigabyte.
    @Test func refusesAStreamThatInflatesPastTheCeiling() throws {
        let bomb = Fixtures.deflated(Data(repeating: 0x00, count: 1_000_000))
        let chunks = stride(from: 0, to: bomb.count, by: QRTransport.chunkByteBudget).map {
            bomb.subdata(in: $0..<min($0 + QRTransport.chunkByteBudget, bomb.count))
        }
        try #require(chunks.count <= 99)

        // The identifier is arbitrary: inflation is refused before there is
        // anything to hash.
        let frames = chunks.enumerated().map { index, chunk in
            ["BTWVP1", "Z", "A1B2C3D4E5",
             String(format: "%02d", index), String(format: "%02d", chunks.count),
             Base45.encode(chunk)].joined(separator: ":")
        }

        let collector = FrameCollector()
        #expect(throws: QRTransportError.oversizedPayload) {
            for frame in frames { _ = try collector.accept(frame) }
        }
    }

    /// Bytes that are not a DEFLATE stream, flagged as though they were.
    ///
    /// `0xFF` opens with RFC 1951's `BTYPE = 11`, which the format reserves as
    /// an error, so this is one of the few inputs the inflater actually refuses.
    @Test func reportsAStreamThatWillNotInflate() throws {
        let frame = ["BTWVP1", "Z", "A1B2C3D4E5", "00", "01",
                     Base45.encode(Data(repeating: 0xFF, count: 200))].joined(separator: ":")
        #expect(throws: QRTransportError.decompressionFailed) { try FrameCollector().accept(frame) }
    }

    /// The case above is the *unusual* one, and this is the one that matters.
    ///
    /// Raw DEFLATE has no magic number, no length and no checksum, so garbage
    /// mostly inflates rather than failing: these 200 pseudo-random bytes
    /// usually produce 327 bytes of nonsense and a cheerful success code. If the
    /// digest were taken over the compressed bytes, or skipped because
    /// "decompression succeeded", that nonsense would be handed upward as a
    /// presentation. What is asserted here is therefore that nothing comes back,
    /// not which refusal comes back.
    ///
    /// **Why not the exact error.** An earlier version expected
    /// `.payloadDigestMismatch` and went red about one run in three with
    /// `.decompressionFailed` instead, from byte-identical input. Measured
    /// cause: `compression_decode_buffer` returns 0 for this stream on the
    /// **first call in a process** and 327 on every call after it — 1 zero in
    /// 200, reproducibly the first, across five separate processes. So the
    /// expected error depended on whether some other test had inflated anything
    /// first, which under parallel execution is a coin toss and says nothing
    /// about this code.
    ///
    /// The anomaly does not reach production: probed separately, a *valid*
    /// stream inflates correctly on the first call, so the first scan after
    /// launch is not at risk. It is specific to malformed input, where giving up
    /// early and emitting garbage are both allowed and both refused here.
    ///
    /// The digest gate itself stays pinned exactly, by
    /// `catchesASubstitutedChunkWithThePayloadDigest`, on the stored path where
    /// the inflater is not involved at all.
    @Test func neverHandsUpGarbageThatWasFlaggedAsDeflated() throws {
        let frame = ["BTWVP1", "Z", "A1B2C3D4E5", "00", "01",
                     Base45.encode(Fixtures.incompressible(200))].joined(separator: ":")

        let collector = FrameCollector()
        var reception: FrameCollector.Reception?
        #expect(throws: QRTransportError.self) { reception = try collector.accept(frame) }
        // The load-bearing pair: no payload was returned, and the collector did
        // not quietly retain the frame as progress towards one.
        #expect(reception == nil)
        #expect(collector.progress == nil)
    }
}

// MARK: - Rendering

struct QRRenderingTests {

    /// ISO/IEC 18004 wants four modules of clear margin. `CIQRCodeGenerator`
    /// emits one — measurable, undocumented, and the kind of thing that works
    /// on a white background and fails against a dark card.
    @Test func surroundsTheSymbolWithFourClearModules() throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let code = try QRTransport.qrCode(for: frames[0], fittingPixelWidth: 750)

        #expect(code.image.width == (code.moduleCount + 2 * QRTransport.quietZoneModules) * code.modulePixelSize)
        #expect(code.image.width == code.pixelSize)

        let pixels = try Fixtures.greyPixels(of: code.image)
        let margin = QRTransport.quietZoneModules * code.modulePixelSize
        let side = code.image.width
        for offset in 0..<side {
            for band in 0..<margin {
                #expect(pixels[band * side + offset] == 0xFF)             // top
                #expect(pixels[(side - 1 - band) * side + offset] == 0xFF) // bottom
                #expect(pixels[offset * side + band] == 0xFF)              // left
                #expect(pixels[offset * side + side - 1 - band] == 0xFF)   // right
            }
        }
    }

    /// A fractional module size makes some modules a pixel wider than others
    /// and blurs every edge, at exactly the distance where there is no margin
    /// to spare. The image is therefore never wider than asked, and never more
    /// than one module short of it.
    @Test(arguments: [200, 640, 750, 828, 1000, 1290])
    func scalesModulesByWholePixels(_ width: Int) throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let code = try QRTransport.qrCode(for: frames[0], fittingPixelWidth: width)

        let modules = code.moduleCount + 2 * QRTransport.quietZoneModules
        #expect(code.image.width == modules * code.modulePixelSize)
        #expect(code.image.width <= width)
        #expect(modules * (code.modulePixelSize + 1) > width)
    }

    /// A display too small for one pixel per module cannot show a scannable
    /// code at all; an oversized image at least makes that visible.
    @Test func neverScalesBelowOnePixelPerModule() throws {
        let frames = try QRTransport.frames(for: Fixtures.presentation)
        let code = try QRTransport.qrCode(for: frames[0], fittingPixelWidth: 10)
        #expect(code.modulePixelSize == 1)
        #expect(code.image.width > 10)
    }

    /// The whole chain, through images a camera could actually read: a
    /// presentation the size of a real one is framed, rendered, decoded by a
    /// QR reader that knows nothing about this code, delivered out of order,
    /// and reassembled.
    ///
    /// This is also the only test that would catch the symbol being rendered
    /// upside down. A QR code has no vertical symmetry, so a flip in
    /// `modules(for:)` produces something no decoder will read — and every
    /// other assertion in this file works on frame strings, which a flip
    /// leaves untouched.
    @Test func carriesAPresentationThroughRenderedQRCodes() throws {
        let payload = Fixtures.presentation
        let frames = try QRTransport.frames(for: payload)
        try #require(frames.count == 3)

        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode,
                                               context: CIContext(),
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let collector = FrameCollector()
        var completed: Data?

        for frame in frames.reversed() {
            let code = try QRTransport.qrCode(for: frame, fittingPixelWidth: 750)
            // Unwrapped outside `#require`: the macro rewrites the expression it
            // is given, and an optional chain inside the closure does not
            // survive that.
            let features = detector.features(in: CIImage(cgImage: code.image))
            let messages = features.compactMap { feature in
                (feature as? CIQRCodeFeature)?.messageString
            }
            let scanned = try #require(messages.first)

            // Verbatim, not merely decodable: a scanner that returned the frame
            // with whitespace trimmed would corrupt any chunk beginning with the
            // space that base45 can produce.
            #expect(scanned == frame)
            if case .completed(let data) = try collector.accept(scanned) { completed = data }
        }
        #expect(completed == payload)
    }
}

// MARK: - Fixtures

private enum Fixtures {

    /// A presentation the size of the real thing: the national-ID credential as
    /// a compact JWS, then `~`, then a key-binding JWT — the concatenation
    /// RFC 9901 defines.
    ///
    /// Built here rather than through `VerifiableCredential` so that this
    /// suite tests the transport and nothing else; what matters to a QR code is
    /// the byte count and the byte values, and both are reproduced faithfully.
    /// The credential body mirrors what `VerifiableCredential.swift` emits —
    /// same field set, same inline `@context`, same `.sortedKeys` ordering —
    /// and was measured against it at 826 bytes for the credential and 1400 for
    /// the JWS.
    static let presentation: Data = {
        let did = "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv"
        let namespace = "https://bonds.tw/ns/credentials#"

        let credential: [String: Any] = [
            "@context": [
                "https://www.w3.org/ns/credentials/v2",
                ["@protected": true,
                 "NationalIDCredential": namespace + "NationalIDCredential",
                 "addressOfHousehold": namespace + "addressOfHousehold",
                 "birthdate": namespace + "birthdate",
                 "nationality": namespace + "nationality",
                 "unifiedNo": namespace + "unifiedNo"],
            ],
            "type": ["VerifiableCredential", "NationalIDCredential"],
            "issuer": did,
            "validFrom": "2025-08-07T12:33:20Z",
            "credentialSubject": [
                "id": did,
                "nationality": "中華民國（臺灣）",
                "unifiedNo": "A123456789",
                "name": "陳德恩",
                "birthdate": "0800215",
                "addressOfHousehold": "新北市板橋區文化路一段188巷36號5樓之2",
            ],
        ]

        let body = try! JSONSerialization.data(withJSONObject: credential,
                                               options: [.sortedKeys, .withoutEscapingSlashes])
        let credentialJWS = [base64URL(Data(#"{"alg":"ES256","cty":"vc","kid":"\#(did)#\#(did.dropFirst(8))","typ":"vc+jwt"}"#.utf8)),
                             base64URL(body),
                             base64URL(Data(repeating: 0x41, count: 64))].joined(separator: ".")

        let keyBinding = [base64URL(Data(#"{"alg":"ES256","typ":"kb+jwt"}"#.utf8)),
                          base64URL(Data(#"{"aud":"urn:bonds-tw:verifier:6f3a1c88-4e2b-4f77-9a10-2d5e8b0c7a41","iat":1754570000,"nonce":"Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZmdoaWo","sd_hash":"cXV4MTIzNDU2Nzg5MGFiY2RlZmdoaWpabTl2WW1GeVltRj"}"#.utf8)),
                          base64URL(Data(repeating: 0x42, count: 64))].joined(separator: ".")

        return Data((credentialJWS + "~" + keyBinding).utf8)
    }()

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Deterministic bytes that DEFLATE cannot shrink, so `frames(for:)` takes
    /// the stored path and the payload size maps directly onto frame count.
    ///
    /// A seeded generator rather than `UInt8.random`: a failure at 5000 bytes
    /// has to be reproducible, and "it passed last time" is not a property this
    /// suite should have. The multiplier and increment are the ones from
    /// Numerical Recipes' LCG.
    static func incompressible(_ count: Int) -> Data {
        var state: UInt32 = 0x1234_5678
        return Data((0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
    }

    /// Raw DEFLATE, matching what `QRTransport` inflates. Used to build a
    /// stream the sender would never produce.
    static func deflated(_ payload: Data) -> Data {
        let capacity = payload.count + 4096
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                compression_encode_buffer(destination.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                          capacity,
                                          source.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                          payload.count,
                                          nil,
                                          COMPRESSION_ZLIB)
            }
        }
        output.count = written
        return output
    }

    /// Raised by the helpers below instead of `Issue.record`, so that they stay
    /// ordinary functions rather than depending on a macro that expects to be
    /// expanded inside a running test.
    struct FixtureFailure: Error { let reason: String }

    /// Feeds every frame to a fresh collector and returns the payload.
    static func collect(_ frames: [String]) throws -> Data {
        let collector = FrameCollector()
        var completed: Data?
        for frame in frames {
            if case .completed(let data) = try collector.accept(frame) { completed = data }
        }
        guard let completed else {
            throw FixtureFailure(reason: "collector never completed from \(frames.count) frames")
        }
        return completed
    }

    /// Redraws into a known 8-bit grey buffer rather than trusting the image's
    /// own format.
    static func greyPixels(of image: CGImage) throws -> [UInt8] {
        let side = image.width
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { throw FixtureFailure(reason: "could not create a grey bitmap context") }
        return pixels
    }
}
