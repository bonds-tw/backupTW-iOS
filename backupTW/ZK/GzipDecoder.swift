//
//  GzipDecoder.swift
//  backupTW
//

import Foundation
import zlib

/// Failures raised while inflating a gzip stream.
///
/// These are developer-facing. Anything the user should read about a failed
/// circuit-asset download is produced by `CircuitAssetError`, which wraps this.
enum GzipError: Error, Equatable {

    /// The payload does not begin with the gzip magic number `1f 8b`. In
    /// practice this is not corruption but a wrong body: a CDN error page, a
    /// captive-portal login redirect, or a GitHub release asset that was
    /// removed and now 404s into HTML.
    case notGzip

    /// zlib rejected the stream — bad header, bad Huffman data, or a trailing
    /// CRC32/ISIZE that does not match the bytes we inflated. The last of those
    /// is the one that matters here: it is how a download that resumed against
    /// a republished asset gets caught instead of landing in `keys/`.
    case corrupt(code: Int32, message: String)

    /// Input ran out mid-member. A partially downloaded file looks exactly like
    /// this, which is why it is distinct from `corrupt`.
    case truncated

    case initializationFailed(code: Int32)
    case cannotRead(path: String)
    case cannotWrite(path: String)

    /// The stream inflated past the ceiling the caller set.
    ///
    /// Compression ratio is attacker-controlled and unbounded: a few hundred
    /// kilobytes of gzip can expand to gigabytes. Every entry point here takes a
    /// limit for that reason — the in-memory one to avoid a jetsam, the
    /// file-to-file one to avoid writing until the device has no space left for
    /// anyone else's photos or mail.
    case outputTooLarge(limit: Int64)
}

/// Streaming gzip (RFC 1952) decoder built on the system zlib.
///
/// **Why libz and not Compression framework.** Apple's `COMPRESSION_ZLIB` is
/// raw DEFLATE (RFC 1951). It has no gzip container: no magic number, no
/// header flags, no CRC32/ISIZE trailer, and no notion of a stream ending. To
/// use it we would have to hand-parse the header (including the optional
/// FNAME/FEXTRA/FCOMMENT/FHCRC fields), implement CRC32 ourselves, and detect
/// member boundaries by hand — several hundred lines of exactly the code that
/// is worst to get subtly wrong. `libz` is already in the iOS SDK as a system
/// module that autolinks (`link "z"` in the SDK's `zlib.modulemap`), so
/// `import zlib` needs no project change, and with `windowBits = 15 + 16` it
/// does the framing and the integrity check for us.
///
/// **Why the `z_stream` API and not `gzopen`/`gzread`.** `gzread` has a
/// transparent-passthrough mode: handed a file that is not gzip, it copies the
/// bytes through verbatim and reports success. For our assets that would mean
/// an HTML error page silently installed as `cert_chain_rs4096_proving.key`,
/// with the failure surfacing hundreds of megabytes and one proof attempt
/// later. `inflate` refuses. `gzopen` also only reads from a path, which makes
/// the in-memory path and the tests need a scratch file.
///
/// **Everything here streams.** The largest asset inflates to ~662 MB; holding
/// either side in memory would get the app jetsammed on a phone. Input is read
/// 64 KB at a time and output is handed to a sink 256 KB at a time, so peak
/// footprint is a fixed ~320 KB regardless of file size.
enum GzipDecoder {

    /// 64 KB in / 256 KB out. The asymmetry is deliberate — these payloads
    /// inflate ~17x, so a larger output buffer means fewer sink round-trips.
    private static let inputBufferSize = 64 * 1024
    private static let outputBufferSize = 256 * 1024

    /// Cap for the in-memory variant. Well above any legitimate small payload,
    /// far below anything that would threaten the app's memory limit.
    static let inMemoryOutputLimit = 32 * 1024 * 1024

    // MARK: - File to file

    /// Inflates `source` into `destination`, streaming.
    ///
    /// `progress` receives the running count of inflated bytes and is called
    /// once per output block, on whatever thread the caller is on. It may
    /// throw to abort — `CircuitAssets` uses that to honour task cancellation
    /// part-way through a multi-hundred-megabyte inflate.
    ///
    /// `limit` caps the bytes written. Passing `nil` means "however large this
    /// turns out to be", which is only safe for input the caller has already
    /// authenticated. Everything arriving over the network must pass a limit:
    /// without one, a file with a hostile compression ratio writes until the
    /// volume is full, and on iOS a full volume is not this app's problem alone
    /// — every other app's saves, the camera roll and Mail all start failing
    /// while we are still inflating. The limit turns that into a thrown error
    /// with the partial output already cleaned up.
    ///
    /// A partially written `destination` is removed before the error is
    /// rethrown, so a failed call never leaves a plausible-looking file behind
    /// for `missingAssets()` to mistake for a finished one.
    ///
    /// - Returns: the number of bytes written to `destination`.
    @discardableResult
    static func decompress(from source: URL,
                           to destination: URL,
                           limit: Int64? = nil,
                           progress: (@Sendable (Int64) throws -> Void)? = nil) throws -> Int64 {
        guard let reader = try? FileHandle(forReadingFrom: source) else {
            throw GzipError.cannotRead(path: source.path)
        }
        defer { try? reader.close() }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: destination) else {
            throw GzipError.cannotWrite(path: destination.path)
        }

        do {
            let written = try run(
                fill: filler(reading: reader),
                drain: { block in
                    guard let base = block.baseAddress else { return }
                    // `bytesNoCopy` is safe here: `write` is synchronous and
                    // the buffer is not reused until it returns.
                    try writer.write(contentsOf: Data(bytesNoCopy: .init(mutating: base),
                                                      count: block.count,
                                                      deallocator: .none))
                },
                limit: limit,
                progress: progress)
            try writer.close()
            return written
        } catch {
            try? writer.close()
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Integrity check

    /// Inflates `source` and throws the bytes away, purely to run zlib's
    /// CRC32/ISIZE check over it.
    ///
    /// The revocation snapshot is consumed by OpenACSwift *still gzipped*, so
    /// it is the one asset whose integrity is never incidentally verified by
    /// being expanded. One throwaway pass (~27 MB in, ~300 MB through the
    /// inflater, no allocation beyond the fixed buffers) is a cheap price for
    /// not discovering a truncated snapshot at proving time.
    ///
    /// `limit` bounds the work rather than any allocation: nothing is written
    /// or kept, so a hostile ratio here costs CPU and battery instead of disk.
    /// It still needs bounding — the snapshot is the one asset whose bytes are
    /// deliberately not pinned to a hash (see `CircuitAssets.required`), so a
    /// ceiling is the only thing standing between us and a file that inflates
    /// forever behind a progress bar stuck at 100%.
    static func validate(at source: URL,
                         limit: Int64? = nil,
                         progress: (@Sendable (Int64) throws -> Void)? = nil) throws -> Int64 {
        guard let reader = try? FileHandle(forReadingFrom: source) else {
            throw GzipError.cannotRead(path: source.path)
        }
        defer { try? reader.close() }

        return try run(fill: filler(reading: reader), drain: { _ in }, limit: limit, progress: progress)
    }

    /// Adapts a `FileHandle` to the `fill` contract of `run`.
    private static func filler(reading handle: FileHandle) -> (UnsafeMutableRawBufferPointer) throws -> Int {
        return { buffer in
            guard let chunk = try handle.read(upToCount: buffer.count), !chunk.isEmpty else {
                return 0
            }
            _ = chunk.copyBytes(to: buffer.bindMemory(to: UInt8.self))
            return chunk.count
        }
    }

    // MARK: - In memory

    /// Inflates a small payload held in memory.
    ///
    /// Deliberately capped at `inMemoryOutputLimit`. This exists for tests and
    /// for small metadata blobs; routing a proving key through it would be a
    /// ~662 MB allocation and an immediate jetsam, so the cap turns that
    /// mistake into a thrown error instead of a crash report.
    static func decompress(_ data: Data, limit: Int = inMemoryOutputLimit) throws -> Data {
        let reader = DataReader(data)
        var output = Data()

        _ = try run(
            fill: { reader.fill($0) },
            drain: { block in output.append(contentsOf: block) },
            limit: Int64(limit),
            progress: nil)

        return output
    }

    /// Inflates the first `maxBytes` of a stream and stops there.
    ///
    /// The difference from `decompress(_:limit:)` is which outcome counts as an
    /// error. There, a payload larger than the limit is a fault — the caller
    /// asked for the whole thing and it did not fit. Here, a larger payload is
    /// the expected case: this exists to read a header off an asset whose body
    /// runs to hundreds of megabytes, and stopping early is the point.
    ///
    /// **What comes back is unauthenticated.** The trailing CRC32 and length are
    /// never reached, so a caller learns only that the first bytes of a gzip
    /// stream inflated to this — not that the file is intact. The magic number
    /// is still checked, so something that is not gzip at all still throws.
    static func decompressPrefix(_ data: Data, maxBytes: Int) throws -> Data {
        /// Not a failure — the sentinel that unwinds `run` once enough has been
        /// read. Private to this function so nothing else can throw or catch it.
        struct Enough: Error {}

        let reader = DataReader(data)
        var output = Data()

        do {
            _ = try run(
                fill: { reader.fill($0) },
                drain: { block in
                    output.append(contentsOf: block)
                    if output.count >= maxBytes { throw Enough() }
                },
                limit: nil,
                progress: nil)
        } catch is Enough {
            // Exactly what was asked for.
        }

        return Data(output.prefix(maxBytes))
    }

    /// Adapts a `Data` to the `fill` contract of `run`.
    private final class DataReader {
        private let data: Data
        private var offset = 0

        init(_ data: Data) { self.data = data }

        func fill(_ buffer: UnsafeMutableRawBufferPointer) -> Int {
            let count = min(buffer.count, data.count - offset)
            guard count > 0 else { return 0 }
            data.withUnsafeBytes { source in
                buffer.baseAddress!.copyMemory(from: source.baseAddress! + offset, byteCount: count)
            }
            offset += count
            return count
        }
    }

    // MARK: - Core loop

    /// Pulls gzip bytes from `fill` and pushes inflated bytes to `drain`.
    ///
    /// `fill` returns the number of bytes it wrote into the supplied buffer, or
    /// 0 for end of input. Concatenated members (`cat a.gz b.gz`) are handled:
    /// gzip defines that as a valid single stream, and the GitHub release
    /// assets are produced by tooling that may well emit one.
    ///
    /// The limit is enforced *before* the block reaches `drain`, so the byte
    /// that would exceed it is never written, never counted and never seen by
    /// the caller's progress callback.
    private static func run(fill: (UnsafeMutableRawBufferPointer) throws -> Int,
                            drain: (UnsafeRawBufferPointer) throws -> Void,
                            limit: Int64?,
                            progress: ((Int64) throws -> Void)?) throws -> Int64 {
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        defer { input.deallocate() }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
        defer { output.deallocate() }

        let inflater = try Inflater()
        var total: Int64 = 0
        var checkedMagic = false
        var finishedMember = false

        while true {
            if finishedMember {
                // Some producers pad the tail of a stream with NULs. Skip those
                // rather than reporting a corrupt trailer for a file that gzip
                // itself would accept.
                inflater.skipLeadingZeroBytes()

                if inflater.availableInput == 0 {
                    let count = try fill(.init(start: input, count: inputBufferSize))
                    if count == 0 { break }         // clean end of the last member
                    inflater.setInput(input, count: count)
                    continue                        // re-enter to skip padding in this block
                }

                // Real bytes after a complete member: another one is starting.
                // Any garbage instead is caught by zlib's header check below.
                try inflater.reset()
                finishedMember = false
            }

            if inflater.availableInput == 0 {
                let count = try fill(.init(start: input, count: inputBufferSize))
                guard count > 0 else { throw GzipError.truncated }

                if !checkedMagic {
                    checkedMagic = true
                    // zlib would reject this too, but only as a generic
                    // "incorrect header check". Naming the case lets the UI say
                    // "the server sent something else" rather than "corrupt".
                    guard count >= 2, input[0] == 0x1f, input[1] == 0x8b else {
                        throw GzipError.notGzip
                    }
                }
                inflater.setInput(input, count: count)
            }

            let (status, produced) = inflater.step(into: output, capacity: outputBufferSize)
            if produced > 0 {
                if let limit, total + Int64(produced) > limit {
                    throw GzipError.outputTooLarge(limit: limit)
                }
                try drain(.init(start: output, count: produced))
                total += Int64(produced)
                try progress?(total)
            }

            switch status {
            case Z_OK:
                break
            case Z_BUF_ERROR:
                // No progress possible with what we fed it; the next pass
                // refills input, or hits EOF and throws `truncated`.
                break
            case Z_STREAM_END:
                finishedMember = true
            default:
                throw GzipError.corrupt(code: status, message: inflater.message)
            }
        }

        // `fill` returned 0 while a member was still open — see the `truncated`
        // throw above; reaching here always means at least one member closed.
        return total
    }

    // MARK: - zlib wrapper

    /// Owns a `z_stream` and guarantees `inflateEnd` runs exactly once.
    private final class Inflater {

        private var stream = z_stream()
        private var isOpen = false

        /// `windowBits = 15 + 16`: maximum window, gzip framing only.
        ///
        /// The +16 rather than the +32 that would *also* accept a bare zlib
        /// stream is on purpose — every asset we fetch is gzip, and narrowing
        /// the accepted framing means a substituted payload fails here instead
        /// of inflating into something plausible. It is also what makes zlib
        /// verify the CRC32 and ISIZE trailer on our behalf.
        init() throws {
            let status = inflateInit2_(&stream, 15 + 16,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else { throw GzipError.initializationFailed(code: status) }
            isOpen = true
        }

        deinit {
            if isOpen { inflateEnd(&stream) }
        }

        var availableInput: Int { Int(stream.avail_in) }

        var message: String {
            guard let msg = stream.msg else { return "" }
            return String(cString: msg)
        }

        func setInput(_ pointer: UnsafeMutablePointer<UInt8>, count: Int) {
            stream.next_in = pointer
            stream.avail_in = uInt(count)
        }

        func skipLeadingZeroBytes() {
            while stream.avail_in > 0, stream.next_in.pointee == 0 {
                stream.next_in = stream.next_in.advanced(by: 1)
                stream.avail_in -= 1
            }
        }

        /// Resets for the next member of a concatenated stream. `inflateReset`
        /// keeps the allocated window, so this costs nothing.
        func reset() throws {
            let status = inflateReset(&stream)
            guard status == Z_OK else { throw GzipError.initializationFailed(code: status) }
        }

        /// One `inflate` pass. Returns the zlib status and how many bytes
        /// landed in `buffer`.
        func step(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int) -> (Int32, Int) {
            stream.next_out = buffer
            stream.avail_out = uInt(capacity)
            let status = inflate(&stream, Z_NO_FLUSH)
            return (status, capacity - Int(stream.avail_out))
        }
    }
}
