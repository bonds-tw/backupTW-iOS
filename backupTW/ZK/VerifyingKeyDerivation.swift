//
//  VerifyingKeyDerivation.swift
//  backupTW
//
//  Produces `keys/*_verifying.key` from the proving key that is already on
//  disk, instead of fetching 57.8 MB of a blob this device already holds.
//

import CryptoKit
import Foundation

// MARK: - What this is, and why it is allowed to exist
//
// `CircuitAssets.setupOnly` has said since M2 that each verifying key is a
// byte-identical prefix of its proving key, 32 bytes shorter, and that the
// release pipeline publishes the same blob twice. `ZKProver` then said the
// derivation "is not written yet" and `ZKVerifyingKeyAssets` refused to rely on
// the claim, on the grounds that deriving a key "on the strength of a claim in a
// comment" would make a verification result depend on an unverified guess.
//
// That objection was correct and is now answered. Measured on 2026-08-07 against
// both installed blobs on this machine — not read off a manifest, not inferred
// from the published `.gz` sizes:
//
//     cert_chain_rs4096_proving.key    693,663,394 bytes
//     cert_chain_rs4096_verifying.key  693,663,362 bytes   (32 fewer)
//       SHA-256 of the verifying key ........ 498dc132…1da7c
//       SHA-256 of proving[0 ..< 693663362] . 498dc132…1da7c   identical
//
//     user_sig_rs2048_proving.key      274,677,850 bytes
//     user_sig_rs2048_verifying.key    274,677,818 bytes   (32 fewer)
//       SHA-256 of the verifying key ........ d85d0738…c3091
//       SHA-256 of proving[0 ..< 274677818] . d85d0738…c3091   identical
//
// And the downloaded copies those digests describe are the ones a real proof was
// checked against on this device: `verifyCertChainRs4096`, `verifyUserSigRs2048`
// and `linkVerify` all ran on them. So "the derived bytes are usable" is a
// measurement, not an inference from a comment.
//
// The code below was then run against those same installed proving keys, and
// `FileManager.contentsEqual` says both results are identical to the downloaded
// verifying keys. It took 2.3 s for the pair on a Mac — worth knowing because it
// is the figure `CircuitAssetPreparer.downloadShareOfProgress` divides the
// progress bar by, and because "968 MB of local work" sounds slower than it is.
//
// # Why deriving is safer than downloading, not merely cheaper
//
// The saving is real — 57.8 MB of transfer per device — but it is the smaller
// half of the argument. `ZKVerifyingKeyAssets` fetches from a rolling
// `-latest` tag, which is a mutable URL: `CircuitAssets.required` says in as many
// words that anyone who can publish to `privacy-ethereum/zkID` can replace a file
// at a URL this app already trusts. Deriving deletes that trust root outright.
// What the verifying key is, is now a pure function of the proving key, and the
// proving key is SHA-256-pinned before it is ever installed.
//
// That is also why the derivation cannot silently go wrong. It has exactly one
// correctness precondition — that the installed proving key is the pinned one —
// and `CircuitAssets` establishes it before the file exists at all. A republished
// upstream key fails its own pin and is never written, so there is no scenario
// where a *wrong* proving key is sitting there waiting to be truncated.
//
// The pin below is belt and braces on top of that: it is a digest of the exact
// derived bytes, so it also catches a gzip decoder that inflated the pinned
// download differently, a partially-written key that a jetsam kill left behind,
// and any future change to the trailing-32-bytes claim. A derived key that fails
// it is deleted rather than kept, because a wrong verifying key is worse than no
// verifying key: it turns a proof that is fine into 「這支手機檢查後不通過」,
// which is the one sentence on that screen that must never be wrong.
//
// # What is deliberately *not* here: a download fallback
//
// `ZKVerifyingKeyAssets` keeps its rows — they are what tells the store where
// these two files live, what they weigh and where they came from, and
// `deleteAll()` and `installedByteCount()` still need them. What is gone is the
// *download*: `CircuitAssetPreparer.prepare` no longer fetches them.
//
// A fallback was considered and rejected, because it cannot help. Work through
// when derivation fails:
//
//   * the proving key is absent — then no proof can be produced either, and the
//     run stops one stage earlier on a mandatory asset;
//   * the proving key is present but not the pinned one — impossible, see above;
//   * the volume is full — the download needs the same 968 MB *plus* 57.8 MB of
//     wire, so it fails harder;
//   * an I/O error on this container — the download writes to the same container.
//
// There is no state in which downloading succeeds and deriving does not. A path
// reachable only when it would also fail is not a fallback, it is a second thing
// to keep working and a second thing to test. The failure that is left is handled
// honestly rather than routed around: a verifying key that cannot be produced
// leaves `ZKRunStage.verification` `.unavailable`, the run still makes a real
// proof, and the screen says this phone could not check it — which is exactly
// what a failed download did, one download later.

// MARK: - Table

/// One verifying key that is produced on this device rather than fetched.
struct DerivableVerifyingKey: Sendable, Hashable, Identifiable {

    /// The `CircuitAsset.name` of the row this replaces. Shared on purpose: the
    /// plan, the progress rows and
    /// `ZKAssetPreparing.verificationOnlyRequirementNames` all key off it, and a
    /// second spelling here would mean the runner stopped recognising these two
    /// as the optional half.
    let name: String

    /// Path relative to the working directory, so it lines up with
    /// `CircuitAsset.localFilename` — `keys/` prefix included.
    let sourceFilename: String

    let localFilename: String

    /// What the source must measure, to the byte.
    ///
    /// Checked before anything is read, and it is the guard that makes the
    /// trailing-32-bytes claim falsifiable rather than assumed: this is the size
    /// the truncation was measured against, so a source of any other length is
    /// refused instead of being truncated on the assumption that the layout is
    /// unchanged.
    let sourceByteCount: Int64

    /// How many bytes come off the end. 32, measured.
    let trailingByteCount: Int64

    /// SHA-256 of the **derived** bytes, lowercase hex.
    ///
    /// Not the digest in `ZKVerifyingKeyAssets`, and the difference matters:
    /// that one is over the published `.gz`, which nothing on this path ever
    /// produces. This one is over the file that lands in `keys/`.
    let sha256: String

    var byteCount: Int64 { sourceByteCount - trailingByteCount }

    var id: String { name }
}

// MARK: - Errors

/// Why a verifying key was not produced.
///
/// `Equatable` and message-free by construction. Nothing here carries an
/// underlying `Error`, for the reason `ProofBackendFailure` gives: the working
/// directory these run against also holds the cardholder's proof inputs, and a
/// classified case is something a test can assert on and a report can carry
/// without a Foundation string travelling with it.
enum VerifyingKeyDerivationError: Error, Equatable {

    /// The proving key this one is cut from is not installed.
    case sourceMissing(name: String)

    /// It is installed and is not the length the truncation was measured
    /// against. Refused rather than truncated anyway.
    case sourceUnexpectedSize(name: String, expected: Int64, actual: Int64)

    /// The table itself asks to remove more bytes than the source has. A
    /// malformed row, caught before anything is opened.
    case sourceShorterThanTrailer(name: String)

    case insufficientDiskSpace(required: Int64, available: Int64)

    /// The source ran out before the truncation point, having passed the size
    /// check — i.e. it shrank underneath us.
    case sourceEndedEarly(name: String)

    /// The derived bytes are not the pinned ones. **The artefact has been
    /// deleted** by the time this is thrown.
    case digestMismatch(name: String, expected: String, actual: String)

    case inputOutput(name: String)
}

extension VerifyingKeyDerivationError: LocalizedError {

    /// Every sentence here is one the string catalogue already carries, and that
    /// is deliberate rather than lazy: these four failures are the same four the
    /// download path already had sentences for, and inventing a fifth phrasing
    /// for "there is not enough room" would give the same situation two different
    /// voices depending on which mechanism happened to be in use.
    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return NSLocalizedString(
                "The offline verification files aren't ready yet. Finish preparing them, then try again.",
                comment: "")
        case .sourceUnexpectedSize, .sourceShorterThanTrailer, .digestMismatch:
            // Not "try again": the bytes on disk are intact and deriving from
            // them a second time produces exactly the same wrong result. Either
            // this build is too old for what the server now publishes, or the
            // proving key has been replaced.
            return NSLocalizedString(
                "The verification files on the server aren't the ones this app expects. Try again after updating the app.",
                comment: "")
        case .insufficientDiskSpace:
            return NSLocalizedString(
                "There isn't enough free space to prepare the verification files.",
                comment: "")
        case .sourceEndedEarly, .inputOutput:
            return NSLocalizedString("Something went wrong on this device.", comment: "")
        }
    }
}

// MARK: - I/O seam

/// One file being read, a chunk at a time.
///
/// A protocol rather than `FileHandle` directly, and the reason is the single
/// property that most needs pinning here: **this must never hold the whole key
/// in memory.** The proving key is 693 MB and the path it sits on already peaks
/// near 1.8 GB during a proof, which is at the jetsam ceiling for a 4 GB phone;
/// one `Data(contentsOf:)` on this file is not a slow derivation, it is a kill.
/// "Reads in bounded chunks" is invisible from the outside — the output bytes are
/// identical either way — so the seam exists to make it observable, and
/// `VerifyingKeyDerivationTests` drives it with a reader that throws when asked
/// for more than a buffer's worth.
protocol VerifyingKeyReading: AnyObject {

    /// Up to `count` bytes; `nil` or empty at end of file.
    func read(upToCount count: Int) throws -> Data?

    func close()
}

/// One file being written, a chunk at a time. Same reasoning as
/// `VerifyingKeyReading`.
protocol VerifyingKeyWriting: AnyObject {
    func write(_ bytes: Data) throws
    func close() throws
}

/// Everything `VerifyingKeyDerivation` needs from the filesystem.
///
/// `Sendable` because the derivation is handed to a `DispatchQueue`: it blocks
/// its thread for as long as it takes to copy and hash about a gigabyte, which
/// must not happen on the cooperative pool.
protocol VerifyingKeyFileSystem: Sendable {

    /// `nil` when there is no file there.
    func fileSize(at url: URL) -> Int64?

    /// `nil` when the volume will not say — which is not a reason to refuse, see
    /// `CircuitAssets.ensureSpace`.
    func availableCapacity(at url: URL) -> Int64?

    func prepareDirectories(at url: URL) throws
    func openForReading(_ url: URL) throws -> any VerifyingKeyReading
    func createFile(at url: URL) throws -> any VerifyingKeyWriting
    func moveItem(at source: URL, to destination: URL) throws

    /// Best effort. Removing something that is not there is not a failure, and
    /// every caller here is a cleanup path that must not throw over it.
    func removeItem(at url: URL)
}

/// The production filesystem.
struct SystemVerifyingKeyFileSystem: VerifyingKeyFileSystem {

    init() {}

    func fileSize(at url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }

    func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// `CircuitAssets`' own, not a bare `createDirectory`: this is what applies
    /// `.completeUnlessOpen` and the backup exclusion. A verifying key written
    /// into a directory that skipped it would be ~968 MB entering every iCloud
    /// backup, next to the proof inputs.
    func prepareDirectories(at url: URL) throws {
        try CircuitAssets.prepareDirectories(at: url)
    }

    func openForReading(_ url: URL) throws -> any VerifyingKeyReading {
        FileHandleReader(handle: try FileHandle(forReadingFrom: url))
    }

    func createFile(at url: URL) throws -> any VerifyingKeyWriting {
        try? FileManager.default.removeItem(at: url)
        // Created with the class explicitly rather than inherited, so this is
        // not the one place that quietly makes an unprotected file.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileHandleWriter(handle: try FileHandle(forWritingTo: url))
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class FileHandleReader: VerifyingKeyReading {

    private let handle: FileHandle

    init(handle: FileHandle) { self.handle = handle }

    func read(upToCount count: Int) throws -> Data? {
        try handle.read(upToCount: count)
    }

    func close() { try? handle.close() }
}

private final class FileHandleWriter: VerifyingKeyWriting {

    private let handle: FileHandle

    init(handle: FileHandle) { self.handle = handle }

    func write(_ bytes: Data) throws { try handle.write(contentsOf: bytes) }

    func close() throws { try handle.close() }
}

// MARK: - Progress

/// How far the derivation has got, across the whole set.
///
/// Shaped like `ZKAssetProgress` on purpose: `CircuitAssetPreparer` forwards one
/// into the other, and two progress types with different conventions for
/// "completed" is how a bar ends up going backwards halfway through.
struct VerifyingKeyDerivationProgress: Sendable, Equatable {

    let key: DerivableVerifyingKey

    /// Keys finished before this update. Not including the one in progress.
    let completedCount: Int

    /// 0...1 across every key in the set, weighted by output size.
    let overallFraction: Double
}

// MARK: - Derivation

enum VerifyingKeyDerivation {

    /// The two keys, and the measurements that make truncating them safe. See
    /// the header for how these were taken.
    ///
    /// `sourceByteCount` is `CircuitAssets.required`'s `installedByteCount` for
    /// the matching proving key and `byteCount` is `ZKVerifyingKeyAssets`'s for
    /// the matching verifying key; `VerifyingKeyDerivationTests` asserts both
    /// correspondences rather than trusting three files to be edited together.
    static let all: [DerivableVerifyingKey] = [
        DerivableVerifyingKey(
            name: "cert_chain_rs4096_verifying",
            sourceFilename: "keys/cert_chain_rs4096_proving.key",
            localFilename: "keys/cert_chain_rs4096_verifying.key",
            sourceByteCount: 693_663_394,
            trailingByteCount: 32,
            sha256: "498dc13211a4311900fcbf1df029be109880905d08c4ab271a2f795f4fa1da7c"),
        DerivableVerifyingKey(
            name: "user_sig_rs2048_verifying",
            sourceFilename: "keys/user_sig_rs2048_proving.key",
            localFilename: "keys/user_sig_rs2048_verifying.key",
            sourceByteCount: 274_677_850,
            trailingByteCount: 32,
            sha256: "d85d0738827dcdfe13dc5fbf0ce8cddab5cbef3d55e6bf02c9c749190bdc3091")
    ]

    /// 1 MiB, the same unit `CircuitAssets.sha256Hex` streams at.
    ///
    /// The figure itself is not load-bearing; that it is a constant unrelated to
    /// the file size is. 693 MB of key at 1 MiB a time is 662 buffers, and the
    /// peak footprint of this whole operation is one of them.
    static let defaultChunkByteCount = 1 << 20

    /// What deriving everything costs on disk. The number the user is shown
    /// before agreeing to it.
    static var totalByteCount: Int64 { all.reduce(0) { $0 + $1.byteCount } }

    // MARK: Readiness

    /// Whether the derived key is already sitting there, **at its exact size**.
    ///
    /// Stricter than `CircuitAssets.isInstalled`'s `size > 0`, and it can afford
    /// to be: unlike a download, the expected length here is known to the byte
    /// before the work starts. A short file is what a jetsam kill during the copy
    /// would leave if the atomic rename were ever lost, and treating it as
    /// installed would hand the verifier a truncated key.
    static func isDerived(_ key: DerivableVerifyingKey,
                          in directory: URL,
                          fileSystem: any VerifyingKeyFileSystem = SystemVerifyingKeyFileSystem())
        -> Bool {
        fileSystem.fileSize(at: directory.appendingPathComponent(key.localFilename)) == key.byteCount
    }

    static func outstanding(_ keys: [DerivableVerifyingKey] = all,
                            in directory: URL,
                            fileSystem: any VerifyingKeyFileSystem = SystemVerifyingKeyFileSystem())
        -> [DerivableVerifyingKey] {
        keys.filter { !isDerived($0, in: directory, fileSystem: fileSystem) }
    }

    // MARK: Doing it

    /// Derives everything in `keys` that is not already derived.
    ///
    /// Space is checked **once, for the whole set, before the first byte is
    /// written**. Per-key checks alone would let the first 662 MB land and the
    /// second fail, which leaves the user with half a capability, a nearly full
    /// volume and — because `missingArtifacts` needs both keys — nothing to show
    /// for it. `derive` re-checks its own share anyway, so a volume that fills up
    /// underneath us is still caught.
    static func deriveAll(_ keys: [DerivableVerifyingKey] = all,
                          in directory: URL,
                          fileSystem: any VerifyingKeyFileSystem = SystemVerifyingKeyFileSystem(),
                          chunkByteCount: Int = defaultChunkByteCount,
                          progress: ((VerifyingKeyDerivationProgress) throws -> Void)? = nil) throws {
        let pending = outstanding(keys, in: directory, fileSystem: fileSystem)
        guard !pending.isEmpty else { return }

        try ensureSpace(forByteCount: pending.reduce(0) { $0 + $1.byteCount },
                        in: directory,
                        fileSystem: fileSystem)

        let total = max(Int64(1), pending.reduce(0) { $0 + $1.byteCount })
        var base: Int64 = 0
        var completed = 0
        for key in pending {
            let start = base
            let finished = completed
            try derive(key,
                       in: directory,
                       fileSystem: fileSystem,
                       chunkByteCount: chunkByteCount) { written in
                try progress?(VerifyingKeyDerivationProgress(
                    key: key,
                    completedCount: finished,
                    overallFraction: min(1, Double(start + written) / Double(total))))
            }
            base += key.byteCount
            completed += 1
            try progress?(VerifyingKeyDerivationProgress(
                key: key,
                completedCount: completed,
                overallFraction: min(1, Double(base) / Double(total))))
        }
    }

    /// Derives one key: copy the source's leading bytes into staging, hash them
    /// on the way past, and only then rename into place.
    ///
    /// The order is the whole design. Nothing is written to `keys/` until the
    /// digest has matched, so a failure cannot leave a plausible-looking
    /// verifying key where the verifier will find it, and an existing good copy
    /// is not removed to make room for one that turns out to be wrong.
    static func derive(_ key: DerivableVerifyingKey,
                       in directory: URL,
                       fileSystem: any VerifyingKeyFileSystem = SystemVerifyingKeyFileSystem(),
                       chunkByteCount: Int = defaultChunkByteCount,
                       progress: ((Int64) throws -> Void)? = nil) throws {

        guard key.byteCount >= 0 else {
            throw VerifyingKeyDerivationError.sourceShorterThanTrailer(name: key.name)
        }

        let source = directory.appendingPathComponent(key.sourceFilename)
        guard let sourceSize = fileSystem.fileSize(at: source) else {
            throw VerifyingKeyDerivationError.sourceMissing(name: key.name)
        }
        // Before the space check and before anything is opened: a source of an
        // unexpected length is the signal that the layout this truncation was
        // measured against has changed, and the only safe response is to stop.
        guard sourceSize == key.sourceByteCount else {
            throw VerifyingKeyDerivationError.sourceUnexpectedSize(name: key.name,
                                                                   expected: key.sourceByteCount,
                                                                   actual: sourceSize)
        }

        try ensureSpace(forByteCount: key.byteCount, in: directory, fileSystem: fileSystem)

        do {
            try fileSystem.prepareDirectories(at: directory)
        } catch {
            throw VerifyingKeyDerivationError.inputOutput(name: key.name)
        }

        let staged = directory
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent("\(key.name).derived")
        fileSystem.removeItem(at: staged)

        // Registered before the first thing that can fail, so that no exit path
        // — including a digest mismatch, which is the one that matters — leaves
        // ~968 MB of rejected key in staging.
        var succeeded = false
        defer { if !succeeded { fileSystem.removeItem(at: staged) } }

        let digest = try copyPrefix(of: source, to: staged, key: key,
                                    fileSystem: fileSystem,
                                    chunkByteCount: chunkByteCount,
                                    progress: progress)

        guard digest == key.sha256 else {
            throw VerifyingKeyDerivationError.digestMismatch(name: key.name,
                                                             expected: key.sha256,
                                                             actual: digest)
        }

        let destination = directory.appendingPathComponent(key.localFilename)
        do {
            fileSystem.removeItem(at: destination)
            try fileSystem.moveItem(at: staged, to: destination)
        } catch {
            throw VerifyingKeyDerivationError.inputOutput(name: key.name)
        }
        succeeded = true
    }

    /// The streaming core. Returns the SHA-256 of what it wrote, lowercase hex.
    ///
    /// One buffer of `chunkByteCount` is the entire memory cost, whatever the
    /// file weighs. The last read is short by construction — `want` is clamped to
    /// what is left before the truncation point — so the trailing 32 bytes are
    /// never read at all, rather than read and discarded.
    private static func copyPrefix(of source: URL,
                                   to staged: URL,
                                   key: DerivableVerifyingKey,
                                   fileSystem: any VerifyingKeyFileSystem,
                                   chunkByteCount: Int,
                                   progress: ((Int64) throws -> Void)?) throws -> String {
        let reader: any VerifyingKeyReading
        let writer: any VerifyingKeyWriting
        do {
            reader = try fileSystem.openForReading(source)
        } catch {
            throw VerifyingKeyDerivationError.inputOutput(name: key.name)
        }
        defer { reader.close() }
        do {
            writer = try fileSystem.createFile(at: staged)
        } catch {
            throw VerifyingKeyDerivationError.inputOutput(name: key.name)
        }

        var hasher = SHA256()
        var written: Int64 = 0
        let budget = Int64(max(1, chunkByteCount))
        do {
            while written < key.byteCount {
                let want = Int(min(budget, key.byteCount - written))
                guard let read = try reader.read(upToCount: want), !read.isEmpty else {
                    try? writer.close()
                    throw VerifyingKeyDerivationError.sourceEndedEarly(name: key.name)
                }
                // A reader that hands back more than it was asked for would push
                // `written` past the truncation point and quietly append part of
                // the trailer. Clamped, so the loop's arithmetic cannot be talked
                // out of stopping in the right place.
                let chunk = read.count > want ? read.prefix(want) : read
                hasher.update(data: chunk)
                try writer.write(chunk)
                written += Int64(chunk.count)
                try progress?(written)
            }
            try writer.close()
        } catch let error as VerifyingKeyDerivationError {
            try? writer.close()
            throw error
        } catch is CancellationError {
            try? writer.close()
            throw CancellationError()
        } catch {
            try? writer.close()
            throw VerifyingKeyDerivationError.inputOutput(name: key.name)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Enough room, asked before the write rather than discovered during it.
    ///
    /// An unanswerable volume is not a refusal, for the reason
    /// `CircuitAssets.ensureSpace` gives: not knowing is not a reason to stop,
    /// and the write will fail honestly if it comes to that.
    static func ensureSpace(forByteCount required: Int64,
                            in directory: URL,
                            fileSystem: any VerifyingKeyFileSystem = SystemVerifyingKeyFileSystem())
        throws {
        guard required > 0 else { return }
        guard let available = fileSystem.availableCapacity(at: directory) else { return }
        guard available > required else {
            throw VerifyingKeyDerivationError.insufficientDiskSpace(required: required,
                                                                    available: available)
        }
    }

    // MARK: Off the cooperative pool

    /// Copying and hashing about a gigabyte blocks its thread for as long as it
    /// takes, so it goes to a queue of its own — the rule `ZKProver.offload` and
    /// `CircuitAssets.offload` both state. Serial, so two runs cannot derive the
    /// same key into the same staging path at once.
    private static let queue = DispatchQueue(label: "tw.bonds.backupTW.verifyingKeyDerivation",
                                             qos: .utility)

    /// `deriveAll`, off the pool, with Swift task cancellation carried across on
    /// a flag the progress callback checks — `Task.isCancelled` means nothing
    /// inside a plain `DispatchQueue` block.
    static func prepare(_ keys: [DerivableVerifyingKey] = all,
                        in directory: URL,
                        fileSystem: any VerifyingKeyFileSystem = SystemVerifyingKeyFileSystem(),
                        progress: @escaping @Sendable (VerifyingKeyDerivationProgress) -> Void)
        async throws {
        let flag = DerivationCancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try deriveAll(keys, in: directory, fileSystem: fileSystem) { update in
                            if flag.isCancelled { throw CancellationError() }
                            progress(update)
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

/// A cancellation signal that can cross into a plain `DispatchQueue` block.
private final class DerivationCancellationFlag: @unchecked Sendable {

    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
