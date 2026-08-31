//
//  VerifyingKeyDerivationTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// `VerifyingKeyDerivation` replaces a 57.8 MB download with a 968 MB local copy,
/// which moves three risks onto this file.
///
/// **The bytes could be wrong.** A verifying key that is not the right one does
/// not fail loudly: `linkVerify` refuses the proof, and the screen says 「這支手機
/// 檢查後不通過」 about a proof that is fine. That is the worst sentence this app
/// can put in front of someone, so the digest check and what happens when it
/// fails are the first thing tested here.
///
/// **The memory could be wrong.** Reading a 693 MB file is the same code whether
/// it streams or not; the difference only shows up as a jetsam kill on a device
/// whose peak is already near 1.8 GB. It is made observable through
/// `VerifyingKeyFileSystem` — the reader below throws if it is ever asked for
/// more than one buffer, so an implementation that reached for `Data(contentsOf:)`
/// fails the test instead of failing a phone.
///
/// **The disk could be wrong.** Running out of room 600 MB into a write leaves a
/// full volume, a partial key and nothing to show, so the refusal has to come
/// before the first byte.
///
/// None of it needs a real key: every fixture here is a few kilobytes, and the
/// one test that has to exceed a buffer exceeds it by 4 KB.
@Suite("Verifying key derivation")
final class VerifyingKeyDerivationTests: Sendable {

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifyingKeyDerivation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("keys", isDirectory: true),
            withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The truncation itself

    @Test("the derived key is the source without its trailing bytes")
    func derivesThePrefix() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "prefix")

        try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: InstrumentedFileSystem())

        #expect(try Data(contentsOf: installed(key)) == Data(bytes.prefix(4096)))
        // The source is read, never rewritten: the proving key it comes from is
        // the one every proof this app makes is generated under.
        #expect(try Data(contentsOf: source(key)) == bytes)
        #expect(staged(key).isReachableFile == false)
    }

    /// The boundary. One byte the wrong side of it is a key the verifier rejects
    /// and a digest that catches it — but the arithmetic should be right first.
    @Test("the last byte kept and the first byte dropped are the ones the count says")
    func truncatesAtExactlyTheBoundary() throws {
        let bytes = Self.bytes(1000 + 32)
        let key = try write(bytes, named: "boundary")

        try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: InstrumentedFileSystem())

        let derived = try Data(contentsOf: installed(key))
        #expect(derived.count == 1000)
        #expect(derived.last == bytes[999])
        // The trailer is not read and discarded, it is never read at all.
        #expect(derived.suffix(1) != Data([bytes[1000]]))
    }

    @Test("a source of exactly the trailer length derives an empty key")
    func aSourceOfExactlyTheTrailerDerivesNothing() throws {
        let bytes = Self.bytes(32)
        let key = try write(bytes, named: "exactly")
        #expect(key.byteCount == 0)

        try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: InstrumentedFileSystem())

        // Absurd as a verifying key and correct as arithmetic. What decides
        // whether an absurd result is accepted is the digest, not a special case
        // in the loop — and the digest of nothing is a real digest.
        #expect(try Data(contentsOf: installed(key)).isEmpty)
    }

    @Test("a source shorter than the trailer is refused before anything is opened")
    func aSourceShorterThanTheTrailerIsRefused() throws {
        let bytes = Self.bytes(20)
        let key = try write(bytes, named: "tooShort", declaredSourceByteCount: 20)
        #expect(key.byteCount == -12)

        let fileSystem = InstrumentedFileSystem()
        #expect(throws: VerifyingKeyDerivationError.sourceShorterThanTrailer(name: key.name)) {
            try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: fileSystem)
        }
        #expect(fileSystem.readCount == 0)
        #expect(fileSystem.createdFileCount == 0)
        #expect(installed(key).isReachableFile == false)
    }

    /// The guard that keeps the trailing-32-bytes claim falsifiable. If upstream
    /// ever changes the layout, the file on disk stops being the length this
    /// truncation was measured against — and the answer to that is to stop, not
    /// to truncate anyway and hope.
    @Test("a source of an unexpected length is refused without being read")
    func aSourceOfTheWrongLengthIsRefused() throws {
        let bytes = Self.bytes(64)
        // The row says the source is the size the measurement was taken at; the
        // file is not.
        let key = try write(bytes, named: "wrongSize", declaredSourceByteCount: 4096 + 32)

        let fileSystem = InstrumentedFileSystem()
        #expect(throws: VerifyingKeyDerivationError.sourceUnexpectedSize(name: key.name,
                                                                         expected: 4128,
                                                                         actual: 64)) {
            try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: fileSystem)
        }
        #expect(fileSystem.readCount == 0)
        #expect(fileSystem.createdFileCount == 0)
    }

    @Test("a source that is not installed is reported as not ready, not as a failure")
    func aMissingSourceIsRefused() throws {
        let key = Self.key(named: "absent", sourceByteCount: 4128, sha256: String(repeating: "0", count: 64))

        #expect(throws: VerifyingKeyDerivationError.sourceMissing(name: key.name)) {
            try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: InstrumentedFileSystem())
        }
        // The sentence a holder gets is the "finish preparing" one, because that
        // is what this is: the proving key has not been downloaded yet.
        #expect(VerifyingKeyDerivationError.sourceMissing(name: key.name).errorDescription
                == NSLocalizedString(
                    "The offline verification files aren't ready yet. Finish preparing them, then try again.",
                    comment: ""))
    }

    // MARK: - The digest

    /// **The one that matters.** A derived key that is not the pinned one must
    /// not survive: `OpenACProofVerifier.missingArtifacts` only asks whether the
    /// file is there, so anything left in `keys/` is a file the verifier will
    /// load, and a wrong verifying key turns a good proof into 「檢查後不通過」.
    @Test("a derived key that misses the pin is deleted and reported")
    func aWrongDigestDeletesTheArtefact() throws {
        let bytes = Self.bytes(4096 + 32)
        let wrong = String(repeating: "ab", count: 32)
        let key = try write(bytes, named: "mismatch", sha256: wrong)

        do {
            try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: InstrumentedFileSystem())
            Issue.record("a key that does not match its pin was installed")
        } catch let error as VerifyingKeyDerivationError {
            guard case .digestMismatch(let name, let expected, let actual) = error else {
                Issue.record("expected a digest mismatch, got \(error)")
                return
            }
            #expect(name == key.name)
            #expect(expected == wrong)
            #expect(actual == Self.hex(Data(bytes.prefix(4096))))
        }

        // Nothing where the verifier looks, and nothing left in staging either —
        // 968 MB of rejected key is not something to leave lying around.
        #expect(installed(key).isReachableFile == false)
        #expect(staged(key).isReachableFile == false)
    }

    /// A failed derivation must not take a working key down with it. The old
    /// copy is only removed once the new bytes have passed.
    @Test("a failed derivation leaves an already-installed key untouched")
    func aFailedDerivationDoesNotDisturbTheInstalledKey() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "keepsOld", sha256: String(repeating: "cd", count: 32))
        let previous = Data("a key that was already here and works".utf8)
        try previous.write(to: installed(key))

        #expect(throws: VerifyingKeyDerivationError.self) {
            try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: InstrumentedFileSystem())
        }

        #expect(try Data(contentsOf: installed(key)) == previous)
    }

    // MARK: - Streaming

    /// The property that keeps this off the jetsam ceiling, made observable.
    ///
    /// The source here is one byte-buffer plus 4 KB, and the filesystem below
    /// throws if the derivation ever asks for more than a buffer's worth. A
    /// version that read the file in one go — which produces byte-identical
    /// output, and would pass every other test in this file — fails here.
    @Test("the source is never read in one go")
    func readsInBoundedChunks() throws {
        let chunk = VerifyingKeyDerivation.defaultChunkByteCount
        let bytes = Self.bytes(chunk + 4096 + 32)
        let key = try write(bytes, named: "streamed")

        let fileSystem = InstrumentedFileSystem(maxSingleRead: chunk)
        try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: fileSystem)

        #expect(try Data(contentsOf: installed(key)) == Data(bytes.prefix(chunk + 4096)))
        #expect(fileSystem.largestRead <= chunk)
        #expect(fileSystem.largestWrite <= chunk)
        // Two full buffers would not have been enough to hold this file.
        #expect(fileSystem.readCount >= 2)
    }

    /// The control for the test above: the cap has to actually bite, or
    /// "streaming" is being asserted by a fake that never says no.
    @Test("the read cap is real")
    func theReadCapRefusesAnOversizedRead() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "capped")

        // One byte below what the derivation will ask for on its first read.
        let fileSystem = InstrumentedFileSystem(maxSingleRead: 4095)
        #expect(throws: VerifyingKeyDerivationError.inputOutput(name: key.name)) {
            try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: fileSystem)
        }
        #expect(installed(key).isReachableFile == false)
        #expect(staged(key).isReachableFile == false)
    }

    @Test("the production buffer is nowhere near the size of a real key")
    func theProductionBufferIsBounded() {
        let smallest = VerifyingKeyDerivation.all.map(\.byteCount).min() ?? 0
        #expect(smallest > 200_000_000)
        // 1 MiB against 274 MB. The figure is not load-bearing; that it is a
        // constant unrelated to the file size is.
        #expect(VerifyingKeyDerivation.defaultChunkByteCount <= 4 << 20)
        #expect(Int64(VerifyingKeyDerivation.defaultChunkByteCount) * 64 < smallest)
    }

    // MARK: - Disk

    @Test("a volume that cannot hold the result is refused before the first write")
    func refusesBeforeWritingWhenTheVolumeIsTooSmall() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "noRoom")

        let fileSystem = InstrumentedFileSystem(capacity: 4095)
        #expect(throws: VerifyingKeyDerivationError.insufficientDiskSpace(required: 4096,
                                                                          available: 4095)) {
            try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: fileSystem)
        }
        // Not "wrote most of it and then failed": nothing was opened at all.
        #expect(fileSystem.readCount == 0)
        #expect(fileSystem.createdFileCount == 0)
        #expect(staged(key).isReachableFile == false)
    }

    /// Per-key checks alone would let the first 662 MB land and the second fail,
    /// which leaves a nearly full volume, half a capability and — because the
    /// verifier needs both keys — nothing to show for it.
    @Test("the whole set is priced before the first key is written")
    func checksSpaceForTheWholeSetUpFront() throws {
        let first = try write(Self.bytes(4096 + 32), named: "setOne")
        let second = try write(Self.bytes(4096 + 32), named: "setTwo")

        // Room for one, not for both.
        let fileSystem = InstrumentedFileSystem(capacity: 6000)
        #expect(throws: VerifyingKeyDerivationError.insufficientDiskSpace(required: 8192,
                                                                          available: 6000)) {
            try VerifyingKeyDerivation.deriveAll([first, second],
                                                 in: directory,
                                                 fileSystem: fileSystem)
        }
        #expect(fileSystem.readCount == 0)
        #expect(installed(first).isReachableFile == false)
        #expect(installed(second).isReachableFile == false)
    }

    @Test("a volume that will not answer is not a refusal")
    func anUnknownCapacityProceeds() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "unknownRoom")

        try VerifyingKeyDerivation.derive(key, in: directory,
                                          fileSystem: InstrumentedFileSystem(capacity: nil))

        #expect(try Data(contentsOf: installed(key)) == Data(bytes.prefix(4096)))
    }

    // MARK: - Readiness

    @Test("a key that still matches its pin is rechecked but not derived again")
    func alreadyDerivedIsSkipped() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "idempotent")
        try VerifyingKeyDerivation.derive(key, in: directory, fileSystem: InstrumentedFileSystem())

        let fileSystem = InstrumentedFileSystem()
        #expect(VerifyingKeyDerivation.outstanding([key], in: directory).isEmpty)
        try VerifyingKeyDerivation.deriveAll([key], in: directory, fileSystem: fileSystem)
        #expect(fileSystem.readCount > 0, "readiness must re-hash the installed bytes")
        #expect(fileSystem.createdFileCount == 0, "a valid key must not be rewritten")
    }

    /// Stricter than `CircuitAssets`' `size > 0`, and it can afford to be: the
    /// expected length is known to the byte before the work starts, so a short
    /// file — what a kill mid-copy would leave — is re-derived rather than handed
    /// to the verifier.
    @Test("a short key on disk counts as not derived")
    func aTruncatedKeyIsDerivedAgain() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "short")
        try Data(bytes.prefix(64)).write(to: installed(key))

        #expect(VerifyingKeyDerivation.isDerived(key, in: directory) == false)
        try VerifyingKeyDerivation.deriveAll([key], in: directory)
        #expect(try Data(contentsOf: installed(key)) == Data(bytes.prefix(4096)))
    }

    @Test("same-size tampering is detected and repaired from the pinned source")
    func aTamperedKeyIsDerivedAgain() throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "tampered")
        try Data(repeating: 0x5a, count: 4096).write(to: installed(key))

        let state = VerifyingKeyDerivation.integrity(of: key, in: directory)
        guard case .digestMismatch = state else {
            Issue.record("same-size tampering was not classified as a digest mismatch")
            return
        }
        #expect(VerifyingKeyDerivation.outstanding([key], in: directory) == [key])

        try VerifyingKeyDerivation.deriveAll([key], in: directory)

        #expect(try Data(contentsOf: installed(key)) == Data(bytes.prefix(4096)))
        #expect(VerifyingKeyDerivation.integrity(of: key, in: directory) == .valid)
    }

    // MARK: - Progress and cancellation

    @Test("progress only ever moves forwards, and reaches the end")
    func progressIsMonotonic() throws {
        let first = try write(Self.bytes(4096 + 32), named: "progressOne")
        let second = try write(Self.bytes(8192 + 32), named: "progressTwo")

        var fractions: [Double] = []
        try VerifyingKeyDerivation.deriveAll([first, second],
                                             in: directory,
                                             chunkByteCount: 1024) { update in
            fractions.append(update.overallFraction)
        }

        #expect(fractions.count > 4)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// The progress callback is how cancellation reaches a `DispatchQueue` block
    /// that has no task to ask. What matters is what it leaves behind.
    @Test("a derivation stopped part way leaves nothing behind")
    func aCancelledDerivationCleansUp() throws {
        let bytes = Self.bytes(8192 + 32)
        let key = try write(bytes, named: "cancelled")

        #expect(throws: CancellationError.self) {
            try VerifyingKeyDerivation.derive(key, in: directory, chunkByteCount: 1024) { written in
                if written > 2048 { throw CancellationError() }
            }
        }
        #expect(staged(key).isReachableFile == false)
        #expect(installed(key).isReachableFile == false)
    }

    // MARK: - The table

    /// Three files have to agree about these two keys: the derivation table, the
    /// asset rows the verifier looks up, and the proving keys they are cut from.
    /// Naming them separately is exactly how they drift apart.
    @Test("the derivation table matches the assets it replaces")
    func theTableAgreesWithTheAssetRows() throws {
        #expect(ZKVerifyingKeyAssets.sourceOwner == "ethereum/zkID")
        #expect(ZKVerifyingKeyAssets.manifestID.contains("RSA-X.509-Cert-latest"))
        #expect(Set(VerifyingKeyDerivation.all.map(\.name))
                == Set(ZKVerifyingKeyAssets.all.map(\.name)))
        #expect(Set(VerifyingKeyDerivation.all.map(\.localFilename))
                == Set(ZKVerifyingKeyAssets.all.map(\.localFilename)))

        for key in VerifyingKeyDerivation.all {
            let asset = try #require(ZKVerifyingKeyAssets.all.first { $0.name == key.name })
            #expect(key.localFilename == asset.localFilename)
            // The published installed size is what the truncation has to produce.
            #expect(key.byteCount == asset.installedByteCount)

            let source = try #require(CircuitAssets.required.first {
                $0.localFilename == key.sourceFilename
            })
            #expect(key.sourceByteCount == source.installedByteCount)
            // The measured difference, in both directions.
            #expect(key.trailingByteCount == 32)
            #expect(source.installedByteCount - asset.installedByteCount == 32)
            // Cut from a file that is itself digest-pinned. Without this the
            // derivation would be a function of unverified bytes.
            #expect(source.sha256 != nil)

            #expect(key.sha256.count == 64)
            #expect(key.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            // Not the `.gz` digest: that one describes bytes this path never
            // produces, and copying it across would fail every derivation.
            #expect(key.sha256 != asset.sha256)
            #expect(asset.installedSHA256 == key.sha256)
        }
    }

    @Test("every file the verifier looks for can be derived")
    func theVerifierNeedsNothingThatIsNotDerivable() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let missing = Set(OpenACProofVerifier().missingArtifacts(in: nowhere))
        #expect(Set(VerifyingKeyDerivation.all.map(\.localFilename)).isSubset(of: missing))
        #expect(VerifyingKeyDerivation.totalByteCount > 900_000_000)
    }

    // MARK: - Wiring

    /// The disclosure is the whole point of the readiness screen, so the moment
    /// these two rows stop costing anything on the wire, the number in front of
    /// the user has to stop including them.
    @Test("the verifying keys are no longer priced as downloads")
    func thePlanChargesNothingOnTheWireForADerivedKey() async throws {
        let empty = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let preparer = CircuitAssetPreparer(store: CircuitAssetPreparer.makeStore(directory: empty)) {
            $0
        }
        let plan = await preparer.plan()

        for key in VerifyingKeyDerivation.all {
            let row = try #require(plan.outstanding.first { $0.name == key.name })
            #expect(row.downloadByteCount == 0)
            // Still nearly a gigabyte of disk, still disclosed before the tap.
            #expect(row.installedByteCount == key.byteCount)
        }
        // 57.8 MB that used to be in this figure and no longer is.
        #expect(plan.downloadByteCount == CircuitAssets.totalDownloadByteCount)
        #expect(plan.installedByteCount > 1_800_000_000)
    }

    /// End to end through the real preparer: plan, prepare, re-plan. The remote
    /// URL points at a port nothing is listening on, so a `prepare` that tried to
    /// download this row would throw instead of passing.
    @Test("prepare derives the key rather than downloading it")
    func prepareDerivesInsteadOfDownloading() async throws {
        let bytes = Self.bytes(4096 + 32)
        let key = try write(bytes, named: "wired")
        let asset = CircuitAsset(name: key.name,
                                 remoteURL: URL(string: "http://127.0.0.1:1/never")!,
                                 localFilename: key.localFilename,
                                 sha256: nil,
                                 compressedByteCount: 41_321_957,
                                 installedByteCount: key.byteCount)
        let store = CircuitAssets(directory: directory,
                                  session: URLSession(configuration: .ephemeral),
                                  assets: [asset])
        let preparer = CircuitAssetPreparer(store: store, derivations: [key]) { $0 }

        let before = await preparer.plan()
        #expect(before.outstanding.first { $0.name == key.name }?.downloadByteCount == 0)
        // The runner has to know this row is the optional half, or a derivation
        // that fails ends a run that could still have produced a proof.
        #expect(preparer.verificationOnlyRequirementNames.contains(key.name))

        let updates = Locked<[ZKAssetProgress]>([])
        try await preparer.prepare { update in updates.mutate { $0.append(update) } }

        #expect(try Data(contentsOf: installed(key)) == Data(bytes.prefix(4096)))
        #expect(updates.value.last?.overallFraction == 1)

        let after = await preparer.plan()
        #expect(after.outstanding.map(\.name) == [CircuitAssetPreparer.issuerRequirementName])
    }

    /// A run whose sources are not there must not be turned into a failure by the
    /// derivation: `prepare` is also the path a store with nothing to do takes.
    @Test("prepare with nothing to derive is a no-op, not a failure")
    func prepareWithNothingToDeriveSucceeds() async throws {
        let store = CircuitAssets(directory: directory, session: .shared, assets: [])
        let preparer = CircuitAssetPreparer(store: store, derivations: []) { $0 }
        try await preparer.prepare { _ in }
    }

    // MARK: - Fixtures

    private func write(_ bytes: Data,
                       named name: String,
                       trailing: Int64 = 32,
                       sha256: String? = nil,
                       declaredSourceByteCount: Int64? = nil) throws -> DerivableVerifyingKey {
        let key = Self.key(named: name,
                           sourceByteCount: declaredSourceByteCount ?? Int64(bytes.count),
                           trailing: trailing,
                           sha256: sha256 ?? Self.hex(
                            Data(bytes.prefix(Int(max(0, Int64(bytes.count) - trailing))))))
        try bytes.write(to: source(key))
        return key
    }

    private static func key(named name: String,
                            sourceByteCount: Int64,
                            trailing: Int64 = 32,
                            sha256: String) -> DerivableVerifyingKey {
        DerivableVerifyingKey(name: name,
                              sourceFilename: "keys/\(name)_source.key",
                              localFilename: "keys/\(name).key",
                              sourceByteCount: sourceByteCount,
                              trailingByteCount: trailing,
                              sha256: sha256)
    }

    private func source(_ key: DerivableVerifyingKey) -> URL {
        directory.appendingPathComponent(key.sourceFilename)
    }

    private func installed(_ key: DerivableVerifyingKey) -> URL {
        directory.appendingPathComponent(key.localFilename)
    }

    private func staged(_ key: DerivableVerifyingKey) -> URL {
        directory.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent("\(key.name).derived")
    }

    /// Deterministic and not constant: a run of identical bytes would let an
    /// off-by-one truncation produce the right digest.
    private static func bytes(_ count: Int) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(count)
        var state: UInt32 = 0x9E37_79B9
        for _ in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            out.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        return Data(out)
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Instrumented filesystem

/// The real filesystem, with the two things a test needs to see: how much was
/// asked for in one go, and how much room the volume claims to have.
///
/// The read cap is enforced rather than merely recorded. An assertion after the
/// fact would pass a derivation that read the whole file and then reported it
/// honestly; throwing is what turns "this streams" from a comment into a test.
private final class InstrumentedFileSystem: VerifyingKeyFileSystem, @unchecked Sendable {

    struct ReadTooLarge: Error {
        let requested: Int
        let cap: Int
    }

    private let base = SystemVerifyingKeyFileSystem()
    private let lock = NSLock()
    private var reads = 0
    private var creates = 0
    private var biggestRead = 0
    private var biggestWrite = 0

    private let maxSingleRead: Int
    private let capacity: Int64?

    init(maxSingleRead: Int = .max, capacity: Int64? = 1 << 40) {
        self.maxSingleRead = maxSingleRead
        self.capacity = capacity
    }

    var readCount: Int { locked { reads } }
    var createdFileCount: Int { locked { creates } }
    var largestRead: Int { locked { biggestRead } }
    var largestWrite: Int { locked { biggestWrite } }

    func fileSize(at url: URL) -> Int64? { base.fileSize(at: url) }

    func availableCapacity(at url: URL) -> Int64? { capacity }

    func prepareDirectories(at url: URL) throws { try base.prepareDirectories(at: url) }

    func openForReading(_ url: URL) throws -> any VerifyingKeyReading {
        CappedReader(inner: try base.openForReading(url), cap: maxSingleRead) { [weak self] count in
            self?.recordRead(count)
        }
    }

    func createFile(at url: URL) throws -> any VerifyingKeyWriting {
        let writer = try base.createFile(at: url)
        locked { creates += 1 }
        return RecordingWriter(inner: writer) { [weak self] count in
            self?.recordWrite(count)
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) { base.removeItem(at: url) }

    private func recordRead(_ count: Int) {
        locked {
            reads += 1
            biggestRead = max(biggestRead, count)
        }
    }

    private func recordWrite(_ count: Int) {
        locked { biggestWrite = max(biggestWrite, count) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CappedReader: VerifyingKeyReading {

    private let inner: any VerifyingKeyReading
    private let cap: Int
    private let record: (Int) -> Void

    init(inner: any VerifyingKeyReading, cap: Int, record: @escaping (Int) -> Void) {
        self.inner = inner
        self.cap = cap
        self.record = record
    }

    func read(upToCount count: Int) throws -> Data? {
        record(count)
        guard count <= cap else {
            throw InstrumentedFileSystem.ReadTooLarge(requested: count, cap: cap)
        }
        return try inner.read(upToCount: count)
    }

    func close() { inner.close() }
}

private final class RecordingWriter: VerifyingKeyWriting {

    private let inner: any VerifyingKeyWriting
    private let record: (Int) -> Void

    init(inner: any VerifyingKeyWriting, record: @escaping (Int) -> Void) {
        self.inner = inner
        self.record = record
    }

    func write(_ bytes: Data) throws {
        record(bytes.count)
        try inner.write(bytes)
    }

    func close() throws { try inner.close() }
}

// MARK: - Plumbing

private final class Locked<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

private extension URL {
    /// Present as a file, without the `FileManager` ceremony at every call site.
    var isReachableFile: Bool { FileManager.default.fileExists(atPath: path) }
}
