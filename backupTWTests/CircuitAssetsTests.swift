//
//  CircuitAssetsTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// `CircuitAssets` is the only code path in this app that takes bytes off the
/// public internet and turns them into something the prover trusts. Everything
/// below is about the four ways that goes wrong quietly: the wrong file
/// installed, a download that looks hung, a download that starts over from zero,
/// and a download that never finishes or fails at all.
///
/// Serialised because the stub protocol keeps its response in static storage —
/// `URLProtocol` offers no per-session hook to key one off.
@Suite(.serialized)
final class CircuitAssetsTests: Sendable {

    /// One throwaway directory per test. Swift Testing makes a fresh instance
    /// per `@Test`, so the sandbox is per-test too, and nothing ever points at
    /// the real Application Support directory.
    private let root: URL
    private let directory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CircuitAssetsTests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("ZKCircuitAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // A test may have left a directory read-only on purpose.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Pinned content
    //
    // The scenario these exist for: the assets hang off a rolling `-latest`
    // tag, so anyone able to publish to the upstream repository can replace a
    // proving key at a URL this app already trusts. A substituted key is still
    // valid gzip with a correct CRC32, so nothing downstream notices, and every
    // proof the app ever produces is generated under it.

    @Test func installsAnAssetWhoseBytesMatchThePinnedDigest() async throws {
        let payload = Data("a proving key, allegedly".utf8)
        let body = Gzip.stored(payload)
        let asset = fixture(sha256: Gzip.sha256Hex(body),
                            compressed: Int64(body.count),
                            installed: Int64(payload.count))
        CircuitAssetStub.serve(body)
        defer { CircuitAssetStub.reset() }

        let store = makeStore([asset])
        let installed = try await store.download(asset)

        #expect(try Data(contentsOf: installed) == payload)
        #expect(await store.missingAssets().isEmpty)
    }

    /// The one that matters. The bytes are intact, the gzip CRC32 is correct,
    /// the transfer succeeded — and it is not our circuit.
    @Test func refusesAnAssetWhoseBytesDoNotMatchThePinnedDigest() async throws {
        let ours = Gzip.stored(Data("the circuit we published".utf8))
        let theirs = Gzip.stored(Data("a circuit somebody else published".utf8))
        let asset = fixture(sha256: Gzip.sha256Hex(ours),
                            compressed: Int64(theirs.count),
                            installed: 4096)
        CircuitAssetStub.serve(theirs)
        defer { CircuitAssetStub.reset() }

        let store = makeStore([asset])

        do {
            _ = try await store.download(asset)
            Issue.record("a substituted asset was installed")
        } catch let error as CircuitAssetError {
            guard case .hashMismatch(let name, let expected, let actual) = error else {
                Issue.record("expected a hash mismatch, got \(error)")
                return
            }
            #expect(name == asset.name)
            #expect(expected == Gzip.sha256Hex(ours))
            #expect(actual == Gzip.sha256Hex(theirs))
        }

        // Nothing installed, and nothing left in staging for a retry to resume
        // into — a rejected proving key is the last file we want lying around.
        #expect(await store.missingAssets().map(\.name) == [asset.name])
        #expect(!FileManager.default.fileExists(atPath: directory
            .appendingPathComponent(asset.localFilename).path))
        #expect(try stagingContents().isEmpty)
    }

    /// Every asset whose content is fixed carries a digest. If a row is ever
    /// added without one, this is the test that says so.
    @Test func everyImmutableAssetInTheShippedTableIsPinned() throws {
        let pinned = (CircuitAssets.required + CircuitAssets.setupOnly)
            .filter { $0.refreshInterval == nil }
        #expect(!pinned.isEmpty)
        for asset in pinned {
            let digest = try #require(asset.sha256, "\(asset.name) is not pinned to a SHA-256")
            #expect(digest.count == 64, "\(asset.name): not a SHA-256")
            #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                    "\(asset.name): digest is not lowercase hex")
        }
    }

    /// The deliberate asymmetry, pinned in a test so that "fixing" it means
    /// arguing with this comment first.
    ///
    /// The revocation snapshot is regenerated roughly daily; a pinned digest
    /// would be wrong by tomorrow morning and the app would refuse to prepare
    /// itself. Its trust anchor is the SMT root published on-chain, which is a
    /// check this app does not yet make — see `CircuitAssets.required`. A
    /// `sha256:` here would look like that missing control while being the
    /// wrong one.
    @Test func theRevocationSnapshotIsDeliberatelyNotPinned() throws {
        let snapshot = try #require(CircuitAssets.required.first { $0.refreshInterval != nil })
        #expect(snapshot.name == "g3_tree_snapshot")
        #expect(snapshot.sha256 == nil)
    }

    /// A chunked hash that disagrees with the real one would reject every
    /// asset — or, worse, agree with the wrong file.
    @Test func theStreamingDigestAgreesWithCryptoKit() throws {
        // 2.5 MB against a 1 MB read: two full chunks and a partial one, which
        // is where an off-by-one in the loop would show.
        var payload = Data(capacity: 2_500_000)
        for index in 0..<2_500_000 {
            payload.append(UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 11)))
        }
        let url = root.appendingPathComponent("digest-fixture")
        try payload.write(to: url)

        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(try CircuitAssets.sha256Hex(ofFileAt: url) == expected)
    }

    // MARK: - Progress

    /// The regression this exists for: the transfer used to be run by a task
    /// created with `downloadTask(with:completionHandler:)`, and URLSession
    /// delivers **no** data-delivery delegate callbacks to those — measured at
    /// 0 against 16 for the same bytes through a pure delegate task. So the bar
    /// stayed at zero for the whole 41 MB and only moved once the inflate
    /// started, which is the "looks like it has hung" failure the module's
    /// header comment says the numbers are on screen to avoid.
    @Test func reportsProgressWhileTheBytesAreStillArriving() async throws {
        let payload = Gzip.pattern(count: 1_048_576)
        let body = Gzip.stored(payload)
        let asset = fixture(sha256: nil,
                            compressed: Int64(body.count),
                            installed: Int64(payload.count))
        CircuitAssetStub.serve(body, chunks: 16, chunkDelay: 0.004)
        defer { CircuitAssetStub.reset() }

        let store = makeStore([asset])
        let reports = Reports()
        _ = try await store.download(asset) { reports.append($0) }

        let values = reports.values
        #expect(!values.isEmpty)
        #expect(values == values.sorted(), "progress must never go backwards")
        #expect((values.last ?? 0) > 0.99, "the bar has to reach the end")

        // Everything at or below the transfer/verify boundary was reported by
        // the transfer itself; anything above it came from the inflate.
        let duringTransfer = values.filter { $0 <= 0.72 }
        #expect(duringTransfer.count >= 2,
                "the bar has to move while the bytes are arriving, not only afterwards")
        #expect(duringTransfer.allSatisfy { $0 > 0 })
    }

    // MARK: - Resume data

    /// The 82 MB case: the connection drops, the error handler has just written
    /// resume data covering everything transferred so far, and the recovery
    /// path used to delete exactly that and restart from byte 0 — on cellular,
    /// twice.
    @Test func aTransientFailureKeepsTheResumeDataAndDoesNotStartOver() async throws {
        let store = makeStore([])
        let sidecar = root.appendingPathComponent("asset.resumedata")
        try Data("bytes 0..<60_000_000".utf8).write(to: sidecar)

        let attempts = Attempts()
        do {
            try await store.withResumeSidecar(sidecar) { (resumeData: Data?) -> Void in
                attempts.record(resumeData)
                // What the real delegate does on the way out of a dropped
                // connection: persist how far we got.
                try Data("bytes 0..<75_000_000".utf8).write(to: sidecar)
                throw CircuitAssetError.downloadFailed(
                    name: "asset",
                    underlying: NSError(domain: NSURLErrorDomain,
                                        code: NSURLErrorNetworkConnectionLost))
            }
            Issue.record("the transient failure should have been surfaced")
        } catch {}

        #expect(attempts.count == 1, "a dropped connection must not trigger a full re-download")
        #expect(try Data(contentsOf: sidecar) == Data("bytes 0..<75_000_000".utf8),
                "the freshly written resume data was thrown away")
    }

    /// The other half: when the saved state genuinely cannot work, starting
    /// over is right, and the sidecar must be gone before the retry so the
    /// retry is a clean one.
    @Test func aStaleSidecarIsDiscardedAndTheRetryStartsClean() async throws {
        let store = makeStore([])
        let sidecar = root.appendingPathComponent("asset.resumedata")
        try Data("pointing at a release that was replaced".utf8).write(to: sidecar)

        let attempts = Attempts()
        let sidecarPresentOnRetry = Flag()
        let result = try await store.withResumeSidecar(sidecar) { resumeData -> String in
            attempts.record(resumeData)
            if resumeData != nil {
                throw CircuitAssetError.serverRejected(name: "asset", statusCode: 416)
            }
            sidecarPresentOnRetry.set(FileManager.default.fileExists(atPath: sidecar.path))
            return "downloaded"
        }

        #expect(result == "downloaded")
        #expect(attempts.count == 2)
        #expect(attempts.hadResumeData == [true, false])
        #expect(sidecarPresentOnRetry.value == false)
    }

    @Test(arguments: [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed,
        NSURLErrorSecureConnectionFailed,
    ])
    func aTransientNetworkErrorLeavesTheResumeDataAlone(code: Int) {
        let error = CircuitAssetError.downloadFailed(
            name: "asset", underlying: NSError(domain: NSURLErrorDomain, code: code))
        #expect(CircuitAssets.resumeDataIsStale(after: error) == false)
    }

    @Test(arguments: [
        NSURLErrorUnsupportedURL,               // Foundation could not read the blob
        NSURLErrorFileDoesNotExist,             // the partial file was evicted
        NSURLErrorCannotOpenFile,
        NSURLErrorCannotMoveFile,
        NSURLErrorDownloadDecodingFailedMidStream,
    ])
    func anUnusableSavedStateIsDiscarded(code: Int) {
        let error = CircuitAssetError.downloadFailed(
            name: "asset", underlying: NSError(domain: NSURLErrorDomain, code: code))
        #expect(CircuitAssets.resumeDataIsStale(after: error) == true)
    }

    /// 4xx is the server saying the thing we asked to continue is gone. 5xx is
    /// the server having a bad day, and says nothing about our bytes.
    @Test(arguments: [(404, true), (410, true), (412, true), (416, true),
                      (500, false), (502, false), (503, false)])
    func onlyAClientErrorMeansTheSavedRangeIsGone(statusCode: Int, stale: Bool) {
        let error = CircuitAssetError.serverRejected(name: "asset", statusCode: statusCode)
        #expect(CircuitAssets.resumeDataIsStale(after: error) == stale)
    }

    /// Cancellation is not a failure to recover from — it is the case the
    /// sidecar exists for.
    @Test func cancellationNeverTouchesTheSidecar() async throws {
        let store = makeStore([])
        let sidecar = root.appendingPathComponent("asset.resumedata")
        try Data("half of it".utf8).write(to: sidecar)

        let attempts = Attempts()
        do {
            try await store.withResumeSidecar(sidecar) { (resumeData: Data?) -> Void in
                attempts.record(resumeData)
                throw CancellationError()
            }
            Issue.record("cancellation should propagate")
        } catch is CancellationError {}

        #expect(attempts.count == 1)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    // MARK: - Connectivity

    /// `waitsForConnectivity` plus a six-hour resource timeout plus no
    /// `taskIsWaitingForConnectivity` implementation is not a slow download, it
    /// is a download that never reports anything at all — while `inFlight`
    /// stays occupied so every retry comes back `alreadyInProgress`.
    @Test func theSessionNeverWaitsSilentlyForConnectivity() {
        let configuration = CircuitAssets.makeSessionConfiguration()
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.timeoutIntervalForResource <= 60 * 60)
        #expect(configuration.timeoutIntervalForRequest <= 60)
        // Low Data Mode still means "no bulk transfers"; the fix is to say so,
        // not to start ignoring it.
        #expect(configuration.allowsConstrainedNetworkAccess == false)
    }

    /// Defence in depth for a session handed in with the flag on: the callback
    /// exists and ends the transfer instead of letting it sit.
    @Test func waitingForConnectivityEndsTheTransferInsteadOfHanging() async throws {
        CircuitAssetStub.hang()
        defer { CircuitAssetStub.reset() }

        let session = makeSession()
        let coordinator = CircuitAssetDownloadCoordinator(
            onProgress: { _, _ in },
            saveResumeData: { _ in },
            receiveFile: { _, _ in },
            makeConnectivityError: { CircuitAssetError.noUsableConnection(name: "asset") },
            makeTransferError: { CircuitAssetError.downloadFailed(name: "asset", underlying: $0) })

        let task = session.downloadTask(with: URL(string: "https://example.invalid/asset.gz")!)
        // Nothing else will ever finish this task — that is the point of the
        // stub — so without this it outlives the test still running. Its
        // `startLoading` then lands during a *later* test in this serialized
        // suite and is counted against that test's request tally: observed as
        // `aFailedDownloadDoesNotLockTheAssetOut` seeing `requestCount == 3`
        // instead of 2. The assertion there is correct and stays as it is; the
        // leak is the bug.
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let running = Task { try await coordinator.run { task } }

        // Wait for the *stub* to have been entered, not for the task to be
        // `.running`.
        //
        // This is the whole fix. `.running` is set by `resume()`, which returns
        // before URLSession has handed the request to the protocol — so the
        // wait was satisfied while `startLoading` was still queued, the test
        // finished, `defer` cancelled a task that had not started, and
        // `startLoading` then ran during the next test and incremented a
        // counter that test was about to assert on. `requests` is incremented
        // at the top of `startLoading`, above the `hangs` guard, so a non-zero
        // count is exactly the signal that the protocol has been entered and
        // no later entry is coming.
        var spins = 0
        while CircuitAssetStub.requestCount == 0, spins < 500 {
            try await Task.sleep(nanoseconds: 2_000_000)
            spins += 1
        }
        // Not a silent fall-through. Carrying on from here is what leaked into
        // the next test, so if the request never arrived the failure belongs to
        // this test rather than to whichever one runs after it.
        #expect(CircuitAssetStub.requestCount > 0,
                "the stub was never entered, so this test would leak into the next one")

        coordinator.urlSession(session, taskIsWaitingForConnectivity: task)

        do {
            try await running.value
            Issue.record("waiting for connectivity should not be reported as success")
        } catch let error as CircuitAssetError {
            guard case .noUsableConnection = error else {
                Issue.record("expected a connectivity failure, got \(error)")
                return
            }
        }
    }

    /// The other half of the same defect: a download that ends badly has to
    /// release its slot, or the retry the user is being told to make is
    /// impossible.
    @Test func aFailedDownloadDoesNotLockTheAssetOut() async throws {
        let asset = fixture(sha256: nil, compressed: 32, installed: 32)
        CircuitAssetStub.serve(Data("upstream is having a bad day".utf8), statusCode: 503)
        defer { CircuitAssetStub.reset() }

        let store = makeStore([asset])

        for attempt in 1...2 {
            do {
                _ = try await store.download(asset)
                Issue.record("attempt \(attempt) should have failed")
            } catch let error as CircuitAssetError {
                guard case .serverRejected(_, let statusCode) = error else {
                    Issue.record("attempt \(attempt) failed with \(error), not a rejected status")
                    return
                }
                #expect(statusCode == 503)
            }
        }
        #expect(CircuitAssetStub.requestCount == 2, "the second attempt never reached the server")
    }

    /// A 404 page is a perfectly good file full of HTML. It must not become a
    /// proving key, and it must not be moved into staging on the way.
    @Test func anErrorPageIsNeverInstalled() async throws {
        let asset = fixture(sha256: nil, compressed: 64, installed: 64)
        CircuitAssetStub.serve(Data("<html><title>404 Not Found</title></html>".utf8), statusCode: 404)
        defer { CircuitAssetStub.reset() }

        let store = makeStore([asset])
        await #expect(throws: CircuitAssetError.self) {
            _ = try await store.download(asset)
        }
        #expect(await store.missingAssets().map(\.name) == [asset.name])
        #expect(try stagingContents().isEmpty)
    }

    // MARK: - Directories

    /// `keys/` holds more than a public proving key: OpenACSwift writes its
    /// proof inputs and outputs there, and those are derived from the
    /// cardholder's certificate. `CredentialStore` protects the same kind of
    /// material at class B, and two directories holding material derived from
    /// one national-ID credential must not give two different answers to "can
    /// this be read off a seized locked phone".
    @Test func everyDirectoryIsCreatedWithTheSameProtectionClassAsCredentialStore() throws {
        let spy = ProtectionRecordingFileManager()
        try CircuitAssets.prepareDirectories(at: directory, fileManager: spy)

        let created = spy.created
        #expect(created.count == 3)
        #expect(Set(created.map(\.name)) == [directory.lastPathComponent, "keys", ".staging"])
        for entry in created {
            #expect(entry.protection == FileProtectionType.completeUnlessOpen,
                    "\(entry.name) was created without Data Protection")
        }
    }

    @Test func theWorkingDirectoryIsExcludedFromBackup() throws {
        try CircuitAssets.prepareDirectories(at: directory)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// This used to be a `try?`. Nearly a gigabyte of regenerable blobs
    /// silently entering every iCloud backup is the thing that gets an app
    /// flagged; for `keys/` it is also proof material leaving the device, which
    /// is the one promise this app makes. `CredentialStore` refuses to
    /// construct itself when the same call fails.
    @Test func preparationFailsWhenTheBackupExclusionCannotBeApplied() throws {
        // Pre-create everything so the only operation left to fail is the
        // exclusion itself: `createDirectory` is a no-op for directories that
        // already exist, even inside a read-only parent.
        for path in ["", "keys", ".staging"] {
            let url = path.isEmpty ? directory : directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: directory.path)
        }

        #expect(throws: (any Error).self) {
            try CircuitAssets.prepareDirectories(at: self.directory)
        }
    }

    // MARK: - Inflate ceiling

    /// Without a ceiling, a file with a hostile compression ratio writes until
    /// the volume is full — and a full volume is not this app's problem alone:
    /// the user's photos stop saving and other apps start losing writes while
    /// our progress bar still says it is working.
    @Test func refusesAnAssetThatInflatesPastWhatItsManifestDeclares() async throws {
        let payload = Gzip.pattern(count: 400_000)
        let body = Gzip.stored(payload)
        // The manifest says 100 KB; the stream is four times that.
        let asset = fixture(sha256: nil, compressed: Int64(body.count), installed: 100_000)
        CircuitAssetStub.serve(body)
        defer { CircuitAssetStub.reset() }

        let store = makeStore([asset])
        do {
            _ = try await store.download(asset)
            Issue.record("an oversized asset was installed")
        } catch let error as CircuitAssetError {
            guard case .oversizedContent(let name, let limit) = error else {
                Issue.record("expected an oversize refusal, got \(error)")
                return
            }
            #expect(name == asset.name)
            #expect(limit == 100_000 + 100_000 / 16)
        }

        #expect(await store.missingAssets().map(\.name) == [asset.name])
        #expect(try stagingContents().isEmpty)
    }

    /// The snapshot is the asset we deliberately do not pin, so the ratio
    /// ceiling is the only size control it has. Declaring a small compressed
    /// size here exercises the same arithmetic the real 27 MB row uses.
    @Test func boundsEvenTheAssetThatIsNotPinned() async throws {
        let body = Gzip.stored(Gzip.pattern(count: 100_000))
        let asset = CircuitAsset(name: "fixture_snapshot",
                                 remoteURL: URL(string: "https://example.invalid/snapshot.json.gz")!,
                                 localFilename: "snapshot.json.gz",
                                 sha256: nil,
                                 compressedByteCount: 512,       // ceiling: 512 * 64
                                 installedByteCount: 512,
                                 expandsAfterDownload: false,
                                 refreshInterval: 24 * 60 * 60)
        CircuitAssetStub.serve(body)
        defer { CircuitAssetStub.reset() }

        let store = makeStore([asset])
        do {
            _ = try await store.download(asset)
            Issue.record("an unbounded snapshot was accepted")
        } catch let error as CircuitAssetError {
            guard case .oversizedContent(_, let limit) = error else {
                Issue.record("expected an oversize refusal, got \(error)")
                return
            }
            #expect(limit == 512 * 64)
        }
        #expect(await store.missingAssets().map(\.name) == [asset.name])
    }

    /// The margin exists because `installedByteCount` is a manifest reading
    /// rather than something measured: being a few megabytes out must cost a
    /// slightly larger download, not a feature that can no longer be prepared.
    @Test func theCeilingLeavesRoomForAManifestThatIsSlightlyOff() throws {
        let key = try #require(CircuitAssets.required.first(where: { $0.expandsAfterDownload }))
        let limit = try #require(key.inflateByteLimit)
        #expect(limit > key.installedByteCount)
        #expect(limit < key.installedByteCount + key.installedByteCount / 8)
    }

    /// A limit invented where no size is known would just be a different bug.
    @Test func anAssetWithNoDeclaredSizeHasNoCeiling() {
        let asset = CircuitAsset(name: "unknown",
                                 remoteURL: URL(string: "https://example.invalid/x.gz")!,
                                 localFilename: "x")
        #expect(asset.inflateByteLimit == nil)
    }

    /// The space check has to cover the peak, which for an expanding asset is
    /// the staged `.gz` and the inflated result on disk at once.
    @Test func theSpaceCheckCoversBothCopies() {
        for asset in CircuitAssets.required where asset.expandsAfterDownload {
            #expect(asset.peakDiskByteCount >= asset.compressedByteCount + asset.installedByteCount)
        }
        for asset in CircuitAssets.required where !asset.expandsAfterDownload {
            // Nothing is expanded, so the download is the whole cost.
            #expect(asset.peakDiskByteCount == asset.compressedByteCount)
        }
    }

    // MARK: - Helpers

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CircuitAssetStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeStore(_ assets: [CircuitAsset]) -> CircuitAssets {
        CircuitAssets(directory: directory, session: makeSession(), assets: assets)
    }

    private func fixture(sha256: String?, compressed: Int64, installed: Int64) -> CircuitAsset {
        CircuitAsset(name: "fixture_proving",
                     remoteURL: URL(string: "https://example.invalid/fixture.key.gz")!,
                     localFilename: "keys/fixture.key",
                     sha256: sha256,
                     compressedByteCount: compressed,
                     installedByteCount: installed)
    }

    private func stagingContents() throws -> [String] {
        let staging = directory.appendingPathComponent(".staging", isDirectory: true)
        guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
    }
}

// MARK: - Stub release server

/// Stands in for GitHub's release CDN, and can deliver a body in pieces so that
/// "the progress bar moves while bytes arrive" is a thing a test can see.
final class CircuitAssetStub: URLProtocol {

    private static let lock = NSLock()
    private static var body = Data()
    private static var statusCode = 200
    private static var chunkCount = 1
    private static var chunkDelay: TimeInterval = 0
    private static var hangs = false
    private static var requests = 0

    /// `chunkDelay` matters more than it looks: handed a body with no pauses in
    /// it, URLSession coalesces the lot into a single write and reports progress
    /// once, which would let a regression in incremental reporting pass. A few
    /// milliseconds between chunks is what a real throttled connection looks
    /// like, and is how the delegate-versus-completion-handler difference was
    /// measured in the first place.
    static func serve(_ body: Data,
                      statusCode: Int = 200,
                      chunks: Int = 1,
                      chunkDelay: TimeInterval = 0) {
        lock.lock()
        defer { lock.unlock() }
        Self.body = body
        Self.statusCode = statusCode
        Self.chunkDelay = chunkDelay
        chunkCount = max(1, chunks)
        hangs = false
        requests = 0
    }

    /// Accepts the request and then says nothing at all — a task that is up but
    /// going nowhere.
    static func hang() {
        lock.lock()
        defer { lock.unlock() }
        hangs = true
        requests = 0
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        body = Data()
        statusCode = 200
        chunkCount = 1
        chunkDelay = 0
        hangs = false
        requests = 0
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let body = Self.body
        let statusCode = Self.statusCode
        let chunkCount = Self.chunkCount
        let chunkDelay = Self.chunkDelay
        let hangs = Self.hangs
        Self.lock.unlock()

        guard !hangs, let url = request.url else { return }

        let response = HTTPURLResponse(url: url,
                                       statusCode: statusCode,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let size = max(1, body.count / chunkCount)
        var offset = 0
        while offset < body.count {
            let end = min(offset + size, body.count)
            client?.urlProtocol(self, didLoad: body[offset..<end])
            offset = end
            if chunkDelay > 0, offset < body.count { Thread.sleep(forTimeInterval: chunkDelay) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Recorders
//
// Callbacks arrive on URLSession's delegate queue, so anything they touch is
// locked rather than assumed to be on the test's thread.

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    func record(_ resumeData: Data?) {
        lock.lock()
        storage.append(resumeData != nil)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var hadResumeData: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    func set(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Records the attributes each directory is created with. The simulator does
/// not report `.protectionKey` back through `attributesOfItem`, so the only way
/// to assert the class is to watch it being asked for.
private final class ProtectionRecordingFileManager: FileManager {

    struct Created {
        let name: String
        let protection: FileProtectionType?
    }

    private(set) var created: [Created] = []

    override func createDirectory(at url: URL,
                                  withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        created.append(Created(name: url.lastPathComponent,
                               protection: attributes?[.protectionKey] as? FileProtectionType))
        try super.createDirectory(at: url,
                                  withIntermediateDirectories: createIntermediates,
                                  attributes: attributes)
    }
}

// MARK: - Fixtures

/// Gzip built from first principles — RFC 1952 header, RFC 1951 stored blocks,
/// hand-rolled CRC32 — so a fixture is never produced by the same library that
/// reads it back. Same construction as `GzipDecoderTests`, which checked it
/// against `/usr/bin/gunzip`.
private enum Gzip {

    static func pattern(count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 8)))
        }
        return data
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func stored(_ payload: Data) -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])

        if payload.isEmpty {
            output.append(contentsOf: [0x01, 0x00, 0x00, 0xff, 0xff])
        } else {
            var offset = payload.startIndex
            while offset < payload.endIndex {
                let end = payload.index(offset, offsetBy: 65_535, limitedBy: payload.endIndex)
                    ?? payload.endIndex
                let block = payload[offset..<end]
                offset = end

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
