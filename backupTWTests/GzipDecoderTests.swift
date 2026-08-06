//
//  GzipDecoderTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// `GzipDecoder` stands between a 41 MB download and a 662 MB file in `keys/`,
/// and its failure mode when it gets something wrong is not a crash — it is a
/// plausible-looking proving key that produces proofs nobody can verify. So
/// these lean hard on two things: that valid streams round-trip byte for byte,
/// and that every way a download can arrive damaged throws instead of returning
/// partial output.
///
/// Fixtures are deliberately **not** produced with zlib's compressor. Testing an
/// inflater against a deflater from the same library proves only that the two
/// agree. Instead:
///
///   * `Fixtures.huffmanMember` is literal output of `/usr/bin/gzip -n -9`,
///     captured as bytes — real dynamic-Huffman coding, produced by an
///     implementation with nothing to do with ours.
///   * `Fixtures.storedGzip` builds streams from first principles: RFC 1952
///     header, RFC 1951 stored blocks, hand-rolled CRC32. That construction was
///     checked against `/usr/bin/gunzip` for empty, small, exactly-65535-byte
///     and 1 MiB payloads before being ported here.
struct GzipDecoderTests {

    // MARK: - Valid input

    @Test func inflatesGzipCommandLineOutput() throws {
        let output = try GzipDecoder.decompress(Fixtures.huffmanMember)
        #expect(String(decoding: output, as: UTF8.self) == Fixtures.huffmanText)
    }

    /// 65535 is the largest stored block, 65536 forces a second one, and 300_000
    /// crosses the 64 KB input buffer several times.
    @Test(arguments: [0, 1, 255, 4096, 65_535, 65_536, 300_000])
    func roundTripsPayloadOfSize(_ size: Int) throws {
        let payload = Fixtures.pattern(count: size)
        let output = try GzipDecoder.decompress(Fixtures.storedGzip(payload))
        #expect(output == payload)
    }

    /// gzip defines `cat a.gz b.gz` as a single valid stream. The release assets
    /// are produced by tooling we do not control, so this is not hypothetical.
    @Test func treatsConcatenatedMembersAsOneStream() throws {
        let joined = Fixtures.huffmanMember + Fixtures.huffmanMember + Fixtures.huffmanMember
        let output = try GzipDecoder.decompress(joined)
        #expect(String(decoding: output, as: UTF8.self) == String(repeating: Fixtures.huffmanText, count: 3))
    }

    @Test func joinsMembersOfDifferentKinds() throws {
        let payload = Fixtures.pattern(count: 1000)
        let joined = Fixtures.storedGzip(payload) + Fixtures.huffmanMember
        let output = try GzipDecoder.decompress(joined)
        #expect(output == payload + Data(Fixtures.huffmanText.utf8))
    }

    /// Some producers pad the tail with NULs. gzip itself accepts that, so a
    /// padded asset must not be reported as corrupt.
    @Test func toleratesTrailingZeroPadding() throws {
        let padded = Fixtures.huffmanMember + Data(repeating: 0, count: 4096)
        let output = try GzipDecoder.decompress(padded)
        #expect(String(decoding: output, as: UTF8.self) == Fixtures.huffmanText)
    }

    @Test func inflatesEmptyPayload() throws {
        #expect(try GzipDecoder.decompress(Fixtures.storedGzip(Data())).isEmpty)
    }

    // MARK: - Streaming

    /// The real assets inflate to hundreds of megabytes, so the property that
    /// actually matters is that output size is independent of buffer size. 1 MiB
    /// through a 256 KB output buffer exercises the refill path without making
    /// the suite slow.
    @Test func streamsPayloadLargerThanTheInternalBuffers() throws {
        try withTemporaryDirectory { directory in
            let payload = Fixtures.pattern(count: 1_048_576)
            let source = directory.appendingPathComponent("large.gz")
            let destination = directory.appendingPathComponent("large.out")
            try Fixtures.storedGzip(payload).write(to: source)

            let reports = Reports()
            let written = try GzipDecoder.decompress(from: source, to: destination) { reports.append($0) }

            #expect(written == Int64(payload.count))
            #expect(try Data(contentsOf: destination) == payload)

            let values = reports.values
            #expect(values.count > 1, "progress should be reported incrementally, not once at the end")
            #expect(values == values.sorted(), "progress must be monotonic")
            #expect(values.last == written)
        }
    }

    /// Many small members back to back — the path where `inflateReset` runs
    /// thousands of times and a leaked or mis-reset stream would show up.
    @Test func streamsManyConcatenatedMembers() throws {
        try withTemporaryDirectory { directory in
            let count = 20_000
            var joined = Data()
            joined.reserveCapacity(Fixtures.huffmanMember.count * count)
            for _ in 0..<count { joined.append(Fixtures.huffmanMember) }

            let source = directory.appendingPathComponent("many.gz")
            let destination = directory.appendingPathComponent("many.out")
            try joined.write(to: source)

            let written = try GzipDecoder.decompress(from: source, to: destination)
            let expected = Data(Fixtures.huffmanText.utf8).count * count
            #expect(written == Int64(expected))
        }
    }

    @Test func validateChecksIntegrityWithoutWritingAnything() throws {
        try withTemporaryDirectory { directory in
            let payload = Fixtures.pattern(count: 200_000)
            let source = directory.appendingPathComponent("check.gz")
            try Fixtures.storedGzip(payload).write(to: source)

            #expect(try GzipDecoder.validate(at: source) == Int64(payload.count))
            // Nothing new on disk: the whole point is that the snapshot stays
            // gzipped and we only pay for the CRC.
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(contents == ["check.gz"])
        }
    }

    // MARK: - Damaged input throws rather than crashing

    @Test(arguments: [
        "<html><head><title>404 Not Found</title></head></html>",
        "",
        "not gzip at all",
    ])
    func rejectsPayloadThatIsNotGzip(_ text: String) {
        #expect(throws: GzipError.self) {
            _ = try GzipDecoder.decompress(Data(text.utf8))
        }
    }

    /// A zlib-framed stream is valid DEFLATE with the wrong container. Accepting
    /// it would mean a substituted payload could still inflate into `keys/`.
    @Test func rejectsZlibFramedStream() {
        #expect(throws: GzipError.notGzip) {
            _ = try GzipDecoder.decompress(Data([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))
        }
    }

    /// Exactly what a download interrupted mid-flight looks like.
    @Test(arguments: [1, 2, 9, 10, 20, 40, 48, 55])
    func rejectsTruncatedStream(_ prefixLength: Int) {
        #expect(throws: GzipError.self) {
            _ = try GzipDecoder.decompress(Fixtures.huffmanMember.prefix(prefixLength))
        }
    }

    /// The case that matters most in production: a download resumed across a
    /// republish of a rolling `-latest` asset splices two revisions together.
    /// Nothing but the trailing CRC32 catches that.
    @Test func rejectsPayloadWithGoodStructureAndBadChecksum() {
        var damaged = Array(Fixtures.huffmanMember)
        damaged[damaged.count - 8] ^= 0xff          // first CRC32 byte
        #expect(throws: GzipError.self) {
            _ = try GzipDecoder.decompress(Data(damaged))
        }
    }

    @Test func rejectsPayloadWithWrongDeclaredLength() {
        var damaged = Array(Fixtures.huffmanMember)
        damaged[damaged.count - 4] ^= 0x0f          // first ISIZE byte
        #expect(throws: GzipError.self) {
            _ = try GzipDecoder.decompress(Data(damaged))
        }
    }

    /// Every single-byte corruption of the compressed body must throw. Flipping
    /// a bit in DEFLATE data can produce a stream that decodes to *something*,
    /// which is precisely why the CRC has to be checked rather than trusted to
    /// structural validation.
    @Test func everySingleByteCorruptionIsRejected() {
        for index in 10..<Fixtures.huffmanMember.count {
            var damaged = Array(Fixtures.huffmanMember)
            damaged[index] ^= 0xff
            #expect(throws: GzipError.self, "byte \(index) was accepted") {
                _ = try GzipDecoder.decompress(Data(damaged))
            }
        }
    }

    /// Deterministic fuzz: the contract is only "throws, never traps". A
    /// mutation can legitimately still be valid gzip, so success is allowed —
    /// what is not allowed is a crash or a hang.
    @Test func randomMutationsNeverTrap() {
        var random = DeterministicRandom(seed: 0x8B1F_8B1F)
        let base = Array(Fixtures.storedGzip(Fixtures.pattern(count: 2048)))

        for _ in 0..<600 {
            var damaged = base
            for _ in 0..<(1 + Int(random.next() % 8)) {
                damaged[Int(random.next() % UInt64(damaged.count))] = UInt8(random.next() % 256)
            }
            // Truncate sometimes too — corruption and truncation take different
            // paths through the loop.
            if random.next() % 3 == 0 {
                damaged = Array(damaged.prefix(Int(random.next() % UInt64(damaged.count + 1))))
            }
            _ = try? GzipDecoder.decompress(Data(damaged))
        }
    }

    // MARK: - Behaviour around failure

    /// A half-written file left on disk would be indistinguishable from a
    /// finished one to `CircuitAssets.missingAssets()`, which decides
    /// readiness by presence.
    @Test func removesPartialOutputWhenInflationFails() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("bad.gz")
            let destination = directory.appendingPathComponent("bad.out")
            // Valid for 300_000 bytes, then cut off.
            let truncated = Fixtures.storedGzip(Fixtures.pattern(count: 300_000)).dropLast(1000)
            try Data(truncated).write(to: source)

            #expect(throws: GzipError.self) {
                _ = try GzipDecoder.decompress(from: source, to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// How `CircuitAssets` aborts a multi-hundred-megabyte inflate when the user
    /// backs out of the screen.
    @Test func progressCallbackCanAbortTheInflation() throws {
        try withTemporaryDirectory { directory in
            struct Abort: Error {}
            let source = directory.appendingPathComponent("abort.gz")
            let destination = directory.appendingPathComponent("abort.out")
            try Fixtures.storedGzip(Fixtures.pattern(count: 2_000_000)).write(to: source)

            #expect(throws: Abort.self) {
                _ = try GzipDecoder.decompress(from: source, to: destination) { _ in throw Abort() }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func reportsUnreadableSource() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("nothing-here.gz")
            #expect(throws: GzipError.cannotRead(path: missing.path)) {
                _ = try GzipDecoder.decompress(from: missing,
                                               to: directory.appendingPathComponent("out"))
            }
        }
    }

    /// The in-memory variant must refuse to be handed a proving key. Without the
    /// cap this is a ~662 MB allocation and a jetsam instead of an error.
    @Test func inMemoryVariantRefusesOversizedOutput() {
        let payload = Fixtures.pattern(count: 200_000)
        #expect(throws: GzipError.outputTooLarge(limit: 1024)) {
            _ = try GzipDecoder.decompress(Fixtures.storedGzip(payload), limit: 1024)
        }
    }

    // MARK: - Output ceiling
    //
    // The file-to-file path had no ceiling at all, which is the worse of the
    // two omissions: the in-memory one at least ends in a jetsam that only
    // affects this app, whereas inflating without a bound writes until the
    // volume is full — and on iOS that is everyone's problem, from the camera
    // roll to Mail to whatever else is trying to save while our progress bar
    // still reads as healthy. Compression ratio is chosen by whoever produced
    // the file, and the manifest already knows how big the result should be.

    @Test func fileVariantRefusesToWritePastTheLimit() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("big.gz")
            let destination = directory.appendingPathComponent("big.out")
            try Fixtures.storedGzip(Fixtures.pattern(count: 300_000)).write(to: source)

            #expect(throws: GzipError.outputTooLarge(limit: 100_000)) {
                _ = try GzipDecoder.decompress(from: source, to: destination, limit: 100_000)
            }
            // And leaves nothing behind: a partial file is indistinguishable
            // from a finished one to `CircuitAssets.missingAssets()`.
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// The limit is a ceiling, not a budget to stay under — an asset that
    /// inflates to exactly its declared size has to install.
    @Test func fileVariantAcceptsOutputExactlyAtTheLimit() throws {
        try withTemporaryDirectory { directory in
            let payload = Fixtures.pattern(count: 300_000)
            let source = directory.appendingPathComponent("exact.gz")
            let destination = directory.appendingPathComponent("exact.out")
            try Fixtures.storedGzip(payload).write(to: source)

            let written = try GzipDecoder.decompress(from: source, to: destination,
                                                     limit: Int64(payload.count))
            #expect(written == Int64(payload.count))
            #expect(try Data(contentsOf: destination) == payload)
        }
    }

    /// One byte over is over. 65 KB is a whole output block short of the real
    /// size, so this also pins that the check happens per block rather than
    /// only at the end, when the bytes would already be on disk.
    @Test(arguments: [299_999, 234_465, 100, 0])
    func fileVariantRefusesAnythingShortOfTheFullSize(_ limit: Int) throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("short.gz")
            let destination = directory.appendingPathComponent("short.out")
            try Fixtures.storedGzip(Fixtures.pattern(count: 300_000)).write(to: source)

            #expect(throws: GzipError.outputTooLarge(limit: Int64(limit))) {
                _ = try GzipDecoder.decompress(from: source, to: destination, limit: Int64(limit))
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// The snapshot is validated rather than expanded, so nothing is written —
    /// but it is also the one asset deliberately not pinned to a digest, and an
    /// unbounded inflate there spins the CPU behind a bar stuck at 100%.
    @Test func validateRefusesToInflatePastTheLimit() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("snapshot.gz")
            try Fixtures.storedGzip(Fixtures.pattern(count: 300_000)).write(to: source)

            #expect(throws: GzipError.outputTooLarge(limit: 50_000)) {
                _ = try GzipDecoder.validate(at: source, limit: 50_000)
            }
            #expect(try GzipDecoder.validate(at: source, limit: 300_000) == 300_000)
        }
    }

    /// The byte that would breach the limit must never reach the caller: not
    /// written, not counted, not reported as progress.
    @Test func nothingBeyondTheLimitIsEverReported() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("reported.gz")
            let destination = directory.appendingPathComponent("reported.out")
            try Fixtures.storedGzip(Fixtures.pattern(count: 300_000)).write(to: source)

            let reports = Reports()
            #expect(throws: GzipError.self) {
                _ = try GzipDecoder.decompress(from: source, to: destination, limit: 100_000) {
                    reports.append($0)
                }
            }
            #expect(reports.values.allSatisfy { $0 <= 100_000 })
        }
    }

    // MARK: - Helpers

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GzipDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

// MARK: - Fixtures

private enum Fixtures {

    /// `printf '有備而來 backupTW gzip fixture\n' | gzip -n -9`, captured
    /// verbatim. 35 bytes in, 56 bytes of gzip out, dynamic Huffman coding.
    static let huffmanMember = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x7b, 0x36,
        0xa7, 0xf3, 0x69, 0xd3, 0xcc, 0x17, 0x0d, 0x3d, 0x4f, 0xf6, 0xb5, 0x29,
        0x24, 0x25, 0x26, 0x67, 0x97, 0x16, 0x84, 0x84, 0x2b, 0xa4, 0x57, 0x65,
        0x16, 0x28, 0xa4, 0x65, 0x56, 0x94, 0x94, 0x16, 0xa5, 0x72, 0x01, 0x00,
        0xaf, 0x85, 0xbf, 0x37, 0x23, 0x00, 0x00, 0x00,
    ])

    static let huffmanText = "有備而來 backupTW gzip fixture\n"

    /// Deterministic, mildly compressible filler.
    static func pattern(count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 8)))
        }
        return data
    }

    /// Builds a gzip stream using only RFC 1951 *stored* blocks.
    ///
    /// Stored blocks let a fixture of any size be produced without a compressor,
    /// so the decoder is never being checked against its own library's encoder.
    /// Verified against `/usr/bin/gunzip` for empty, 12-byte, 65535-byte and
    /// 1 MiB payloads.
    static func storedGzip(_ payload: Data) -> Data {
        // RFC 1952 header: magic, CM=deflate, no flags, no mtime, OS=Unix.
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])

        if payload.isEmpty {
            // One final, empty stored block.
            output.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
        } else {
            var offset = payload.startIndex
            while offset < payload.endIndex {
                let end = payload.index(offset, offsetBy: 65_535, limitedBy: payload.endIndex)
                    ?? payload.endIndex
                let block = payload[offset..<end]
                offset = end

                // BFINAL in bit 0, BTYPE=00 in bits 1-2, remaining bits padding.
                output.append(offset >= payload.endIndex ? 0x01 : 0x00)
                let length = UInt16(block.count)
                output.append(contentsOf: [UInt8(length & 0xff), UInt8(length >> 8)])
                let complement = ~length
                output.append(contentsOf: [UInt8(complement & 0xff), UInt8(complement >> 8)])
                output.append(contentsOf: block)
            }
        }

        appendLittleEndian(crc32(payload), to: &output)
        appendLittleEndian(UInt32(truncatingIfNeeded: payload.count), to: &output)
        return output
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    /// Textbook CRC-32/ISO-HDLC, written out rather than borrowed from zlib so
    /// the fixture's checksum is not computed by the same code that verifies it.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Seeded so a fuzz failure is reproducible from the printed seed.
private struct DeterministicRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 16
    }
}

/// Collects progress values from a callback that may be invoked off the test's
/// thread.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
