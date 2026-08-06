//
//  CircuitAssets.swift
//  backupTW
//

import CryptoKit
import Foundation

// MARK: - Asset table
//
// What "離線前先備妥" actually costs, and why the numbers are in the UI rather
// than hidden behind a spinner:
//
//   download   81.5 MB   (41.3 + 15.7 + 26.4)
//   on disk   949.9 MB   (661.5 + 262.0 + 26.4)
//
// The two Groth16 proving keys inflate roughly 17x — 41 MB on the wire becomes
// 662 MB in `keys/` — so the download bar and the disk cost are different
// stories and the UI has to tell both. Nearly a gigabyte is more than most of
// this app's users have spare, which drives three decisions made here:
//
//   * The working directory lives in Application Support and is excluded from
//     backup. In Documents this would be ~950 MB of regenerable blobs in every
//     user's iCloud backup.
//   * Nothing is deleted after a successful proof. The upstream example app
//     wipes the keys after each verify and re-downloads next time; for an app
//     whose entire premise is being prepared in advance, that is exactly
//     backwards.
//   * The revocation snapshot is refetched on a schedule. It is regenerated
//     roughly daily and the verifier checks the proof's root against the
//     current one, so a snapshot cached for a fortnight produces proofs that
//     are rejected. Only the proving keys are genuinely download-once.
//
// And one thing this module cannot fix, which the UI copy must not overclaim:
// having these files does not mean verification works offline. The challenge
// (5-minute TTL), the 行動自然人憑證 app-to-app round trip, and the proof
// submission are all online steps. "備妥" here means "the 82 MB is already
// downloaded so you are not waiting on it at the counter" — not "works with no
// signal".

/// One file that has to be on disk before a proof can be generated.
struct CircuitAsset: Sendable, Hashable, Identifiable {

    /// Stable identifier. Also names the resume-data sidecar, so it must not
    /// collide and must be path-safe.
    let name: String

    let remoteURL: URL

    /// Destination **path relative to the working directory** — not just a leaf
    /// name, despite what the name suggests. OpenACSwift reads the proving keys
    /// from `<documentsPath>/keys/` and the snapshot from `<documentsPath>/`,
    /// so this carries the `keys/` prefix where that applies.
    let localFilename: String

    /// SHA-256 of the **downloaded bytes** — the `.gz` as published, before any
    /// inflation — lowercase hex, taken from the GitHub release manifest.
    ///
    /// `nil` is not "we did not get round to it": it means this asset's content
    /// is *expected* to change under a fixed URL, so pinning it would break the
    /// app on a schedule. See the note on `CircuitAssets.required` for which is
    /// which and why.
    let sha256: String?

    /// Transfer size, from the GitHub release manifest.
    ///
    /// An estimate, never an assertion: these hang off rolling `-latest` tags
    /// and are republished. It is used to draw a progress bar when the server
    /// omits `Content-Length`, and to budget disk space — never to validate a
    /// finished download. Integrity is `sha256`'s job, with the gzip CRC32
    /// underneath it.
    let compressedByteCount: Int64

    /// Size once installed. Equal to `compressedByteCount` for assets that stay
    /// gzipped.
    let installedByteCount: Int64

    /// Whether the downloaded `.gz` is inflated into place, or installed as-is.
    ///
    /// The revocation snapshot is the odd one out: `generateCertChainRs4096Input`
    /// wants the path to the **still-compressed** `g3-tree-snapshot.json.gz` and
    /// decompresses it internally. Inflating it here would waste 300 MB and hand
    /// the library a file it cannot read.
    let expandsAfterDownload: Bool

    /// How long before the installed copy should be refetched. `nil` means it
    /// never goes stale.
    let refreshInterval: TimeInterval?

    var id: String { name }

    init(name: String,
         remoteURL: URL,
         localFilename: String,
         sha256: String? = nil,
         compressedByteCount: Int64 = 0,
         installedByteCount: Int64 = 0,
         expandsAfterDownload: Bool = true,
         refreshInterval: TimeInterval? = nil) {
        self.name = name
        self.remoteURL = remoteURL
        self.localFilename = localFilename
        self.sha256 = sha256
        self.compressedByteCount = compressedByteCount
        self.installedByteCount = installedByteCount
        self.expandsAfterDownload = expandsAfterDownload
        self.refreshInterval = refreshInterval
    }

    /// Hard ceiling on what inflating this asset may produce.
    ///
    /// Compression ratio is chosen by whoever produced the file, and gzip will
    /// happily turn 27 MB into a terabyte. Without a ceiling the inflate loop
    /// writes until the volume is full — and a full volume on iOS is not a
    /// local failure: the user's photos stop saving, Mail stops syncing, other
    /// apps start losing writes, all while our progress bar says it is working.
    ///
    /// For assets that expand, the manifest already knows the answer, so the
    /// ceiling is that figure plus 1/16. The margin is there because
    /// `installedByteCount` is a manifest reading rather than something we
    /// measured, and being a few megabytes out must degrade into "downloads a
    /// bit more than budgeted", not "this app can no longer be prepared".
    ///
    /// For the snapshot, which is not inflated onto disk and whose expanded
    /// size grows as the revocation list does, the ceiling is a ratio instead:
    /// it runs about 12x today, and nothing gzip does to a JSON Merkle
    /// snapshot approaches 64x. That bounds a hostile file without breaking a
    /// legitimate one that grew.
    ///
    /// `nil` where no size is known at all (the initialiser's defaults), since
    /// a limit invented out of nothing would just be a different bug.
    var inflateByteLimit: Int64? {
        if expandsAfterDownload {
            guard installedByteCount > 0 else { return nil }
            return installedByteCount + installedByteCount / 16
        } else {
            guard compressedByteCount > 0 else { return nil }
            return compressedByteCount * 64
        }
    }

    /// What the whole operation costs on disk at its peak, for the space check.
    ///
    /// An asset that expands has the staged `.gz` and the inflated result on
    /// disk at once; one that does not is simply moved into place.
    var peakDiskByteCount: Int64 {
        guard expandsAfterDownload else { return compressedByteCount }
        return compressedByteCount + (inflateByteLimit ?? installedByteCount)
    }

    /// Row title for the readiness checklist.
    var displayName: String {
        switch name {
        case "cert_chain_rs4096_proving":
            return NSLocalizedString("Certificate chain proving key", comment: "ZK circuit asset")
        case "user_sig_rs2048_proving":
            return NSLocalizedString("Signature proving key", comment: "ZK circuit asset")
        case "g3_tree_snapshot":
            return NSLocalizedString("Certificate revocation snapshot", comment: "ZK circuit asset")
        default:
            return name
        }
    }
}

// MARK: - Errors

enum CircuitAssetError: Error, LocalizedError {
    case alreadyInProgress(name: String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case serverRejected(name: String, statusCode: Int)
    case downloadFailed(name: String, underlying: Error?)
    /// The bytes arrived but did not survive the gzip integrity check.
    case corruptDownload(name: String, underlying: Error)
    /// The bytes arrived intact and are **not the asset we pinned**. Distinct
    /// from `corruptDownload` because nothing is damaged and retrying fetches
    /// the same wrong file: either the release was republished under the same
    /// rolling tag, or someone with publish rights to the upstream repository
    /// swapped it.
    case hashMismatch(name: String, expected: String, actual: String)
    /// The download inflated past the size its manifest declares.
    case oversizedContent(name: String, limit: Int64)
    /// There is no connection this download can use — offline, or Low Data Mode
    /// refusing a bulk transfer. Reported instead of waiting, see
    /// `makeSessionConfiguration()`.
    case noUsableConnection(name: String)
    case bundledResourceMissing(filename: String)

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return NSLocalizedString("This download is already running.", comment: "")
        case .insufficientDiskSpace:
            return NSLocalizedString("There isn't enough free space to prepare the verification files.",
                                     comment: "")
        case .serverRejected, .downloadFailed:
            return NSLocalizedString("The verification files couldn't be downloaded.", comment: "")
        case .corruptDownload:
            return NSLocalizedString("The downloaded file was damaged. Please try again.", comment: "")
        case .hashMismatch, .oversizedContent:
            // Deliberately not "please try again": the bytes are intact and the
            // next attempt fetches exactly the same ones. Either the app is too
            // old for what the server now publishes, or the file has been
            // replaced — and telling the user to retry into a substituted
            // proving key is the one thing this message must not do.
            return NSLocalizedString(
                "The verification files on the server aren't the ones this app expects. Try again after updating the app.",
                comment: "")
        case .noUsableConnection:
            return NSLocalizedString(
                "This download needs Wi-Fi or full cellular data. Check your connection, or turn off Low Data Mode.",
                comment: "")
        case .bundledResourceMissing:
            return NSLocalizedString("A file this app ships with is missing.", comment: "")
        }
    }
}

// MARK: - Store

/// Downloads, verifies and installs the zero-knowledge circuit assets.
///
/// An actor because the readiness screen polls `missingAssets()` while a
/// download is running, and both touch the same directory.
actor CircuitAssets {

    /// Everything that has to be fetched over the network.
    ///
    /// Sizes, URLs and digests were checked against the GitHub release
    /// manifests on 2026-08-06.
    ///
    /// **Why the proving keys are pinned and the snapshot is not.** These are
    /// two different kinds of file wearing the same kind of URL, and the
    /// difference decides what "verified" can mean for each:
    ///
    ///   * A circuit is immutable. `certChainRS4096` either is the constraint
    ///     system the verifier expects or it is not, and it will never
    ///     legitimately change under the same name — so the trust anchor is the
    ///     content itself and we pin its SHA-256. This matters more than it
    ///     might look: the URLs hang off a rolling `-latest` tag, so anyone who
    ///     can publish to `privacy-ethereum/zkID` — or anyone holding a stolen
    ///     token for it — can replace the proving key at a URL we already
    ///     trust. The gzip CRC32 underneath does not help; it proves the bytes
    ///     arrived as sent, not that they are ours. Every proof this app ever
    ///     produces is generated under whatever proving key lands in `keys/`,
    ///     so that file is the single most security-critical download here.
    ///
    ///   * The revocation snapshot is the opposite: it is regenerated roughly
    ///     daily and a pinned digest would be wrong by tomorrow morning. Its
    ///     trust anchor is not the file, it is the **SMT root published
    ///     on-chain** — the right check is "does this snapshot's Merkle root
    ///     match the root the contract holds", which makes a substituted
    ///     snapshot detectable no matter what its bytes hash to.
    ///
    ///     ⚠️ That check is **not implemented**. Today the snapshot is verified
    ///     only for gzip integrity and bounded size, which means a party who can
    ///     publish to `privacy-ethereum/moica-revocation-smt` can serve a
    ///     snapshot with revoked certificates quietly omitted. The consequence
    ///     is a proof built against a stale revocation set, which the verifier
    ///     rejects when it checks the root — so this is an availability and
    ///     correctness gap rather than a way to forge a passing proof. It stays
    ///     named here rather than papered over, because a `sha256:` on this row
    ///     would *look* like the missing control while being the wrong one.
    static let required: [CircuitAsset] = [
        CircuitAsset(name: "cert_chain_rs4096_proving",
                     remoteURL: zkIDRelease.appendingPathComponent("cert_chain_rs4096_proving.key.gz"),
                     localFilename: "keys/cert_chain_rs4096_proving.key",
                     sha256: "d6276ab7ba7ddef3193b33ec889d9439da4f490953c7429c4a12187599662035",
                     compressedByteCount: 41_321_996,
                     installedByteCount: 693_663_394),
        CircuitAsset(name: "user_sig_rs2048_proving",
                     remoteURL: zkIDRelease.appendingPathComponent("user_sig_rs2048_proving.key.gz"),
                     localFilename: "keys/user_sig_rs2048_proving.key",
                     sha256: "5fdfa2da727769d5b0eee5c35ba89d1c336a5ed64731efe42468202256fc391e",
                     compressedByteCount: 16_513_669,
                     installedByteCount: 274_677_850),
        CircuitAsset(name: "g3_tree_snapshot",
                     remoteURL: smtRelease.appendingPathComponent("g3-tree-snapshot.json.gz"),
                     localFilename: "g3-tree-snapshot.json.gz",
                     sha256: nil,        // see above — freshness, not fixity
                     compressedByteCount: 27_657_187,
                     installedByteCount: 27_657_187,
                     expandsAfterDownload: false,
                     refreshInterval: 24 * 60 * 60)
    ]

    /// Deliberately **not** in `required`, kept here so the omission reads as a
    /// decision rather than an oversight.
    ///
    /// The `.r1cs` constraint systems are inputs to `setupKeys`, which we never
    /// call — the proving keys already embed the constraint system, which is
    /// why they are 662 MB. Fetching these would add 77.7 MB of download and
    /// 823 MB of disk for a step that is skipped. Only add them back if
    /// on-device Groth16 setup ever becomes necessary.
    ///
    /// The verifying keys are also skipped, for a different reason: each one is
    /// a byte-identical prefix of its proving key (32 bytes shorter). The
    /// release pipeline publishes the same blob twice. Their digests from the
    /// same manifest, in case that ever stops being true and they have to come
    /// back as rows here:
    ///
    ///     cert_chain_rs4096_verifying.key.gz
    ///       ba5054a5044115de5f51dcf4330ecf844423bd9e12aa311ca3e3756e1202fc8e
    ///     user_sig_rs2048_verifying.key.gz
    ///       c4eabf366d7baf99306db72573d129f89aeef5a178d3368ffaef2d475ae81b7b
    static let setupOnly: [CircuitAsset] = [
        CircuitAsset(name: "cert_chain_rs4096_r1cs",
                     remoteURL: zkIDRelease.appendingPathComponent("certChainRS4096.r1cs.gz"),
                     localFilename: "keys/certChainRS4096.r1cs",
                     sha256: "681381623e81abfe91b7035f20ca48000ceb5ef73fbf54ac6c4126dcd0bbe2d1",
                     compressedByteCount: 60_138_417,
                     installedByteCount: 619_522_980),
        CircuitAsset(name: "user_sig_rs2048_r1cs",
                     remoteURL: zkIDRelease.appendingPathComponent("userSigRS2048.r1cs.gz"),
                     localFilename: "keys/userSigRS2048.r1cs",
                     sha256: "465d173c134b20ffb81ce18b0ffeb3fd850d4c1f06dbfcdfe95a3d202afb37c0",
                     compressedByteCount: 21_320_330,
                     installedByteCount: 243_519_416)
    ]

    /// The issuing sub-CA (內政部憑證管理中心). Ships in the app bundle rather
    /// than being downloaded — it is 1.6 KB, it is a trust anchor, and fetching
    /// a trust anchor over the network to check certificates with is circular.
    static let issuerCertificateFilename = "MOICA-G3.cer"

    static var totalDownloadByteCount: Int64 {
        required.reduce(0) { $0 + $1.compressedByteCount }
    }

    static var totalInstalledByteCount: Int64 {
        required.reduce(0) { $0 + $1.installedByteCount }
    }

    // These are compile-time literals; the force-unwraps cannot fire at runtime.
    private static let zkIDRelease = URL(
        string: "https://github.com/privacy-ethereum/zkID/releases/download/RSA-X.509-Cert-latest")!
    private static let smtRelease = URL(
        string: "https://github.com/privacy-ethereum/moica-revocation-smt/releases/download/snapshot-latest")!

    /// Inflating a 662 MB key must not run on the cooperative thread pool —
    /// it would occupy a pool thread for seconds and starve unrelated work.
    /// Hashing 41 MB is shorter but has the same shape, and shares the queue.
    private static let inflateQueue = DispatchQueue(label: "tw.bonds.backupTW.circuitAssets.inflate",
                                                    qos: .utility)

    private let directory: URL
    private let session: URLSession
    private let fileManager = FileManager.default

    /// The set this instance considers mandatory. Defaults to `required`;
    /// overridable so tests can exercise the readiness logic against fixtures
    /// instead of reaching for 82 MB of GitHub.
    private let assets: [CircuitAsset]

    /// Guards against two `download` calls racing on the same staging paths.
    /// The actor alone does not prevent this: `download` suspends at every
    /// `await`, which lets a second call in.
    private var inFlight: Set<String> = []

    init(directory: URL) {
        self.init(directory: directory,
                  session: URLSession(configuration: Self.makeSessionConfiguration()))
    }

    /// Injection point for tests.
    init(directory: URL, session: URLSession, assets: [CircuitAsset] = CircuitAssets.required) {
        self.directory = directory
        self.session = session
        self.assets = assets
    }

    /// The transfer policy, exposed so it can be asserted on rather than only
    /// read.
    ///
    /// **`waitsForConnectivity` is off on purpose.** With it on, a task that
    /// cannot start does not fail — it waits, silently, up to
    /// `timeoutIntervalForResource`. Combined with `allowsConstrainedNetworkAccess
    /// = false` that is not a rare corner: every user with Low Data Mode on hits
    /// it on the first tap, and gets a spinner that never moves and never errors
    /// while `inFlight` stays occupied and every retry comes back
    /// `alreadyInProgress`. Failing in a second with something the UI can put on
    /// screen — "this needs Wi-Fi or full cellular data" — is worth more than a
    /// download that might start by itself later in an app the user is no longer
    /// looking at. (`CircuitAssetDownloadCoordinator` also implements
    /// `taskIsWaitingForConnectivity` and fails fast there, which covers a
    /// session handed in by a caller that sets this flag differently.)
    ///
    /// The resource timeout is one hour rather than six. Six hours cannot
    /// happen in the foreground anyway — this is not a background session, so
    /// the transfer stops when the app is suspended — and with resume data a
    /// timeout costs one tap, whereas six hours of unbounded silence costs the
    /// user their trust in the readiness screen. One hour still covers 41 MB at
    /// about 12 kB/s.
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        // The per-request timeout is the stall detector: 60 s with no data
        // moving ends the attempt, and the resume sidecar keeps the bytes.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        // Low Data Mode means "do not do bulk transfers". 82 MB is exactly what
        // the user turned it on to avoid; fail loudly instead of ignoring it.
        configuration.allowsConstrainedNetworkAccess = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Application Support, not Documents and not Caches.
    ///
    /// Documents is backed up to iCloud by default, and ~950 MB of regenerable
    /// blobs in every user's backup is the kind of thing that gets an app
    /// flagged. Caches is purgeable under disk pressure — silently losing files
    /// the app told the user were ready is the one failure this feature exists
    /// to prevent.
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        return base.appendingPathComponent("ZKCircuitAssets", isDirectory: true)
    }

    /// The path to hand OpenACSwift as its `documentsPath`.
    nonisolated var workingDirectory: URL { directory }

    // MARK: - Readiness

    /// Assets still to fetch — the backing list for the "離線前先備妥" screen.
    ///
    /// Presence is treated as proof of completeness because installation is
    /// atomic: everything is downloaded and inflated under `.staging` and only
    /// then renamed into place. Re-verifying 950 MB on every launch would cost
    /// seconds of I/O to learn what the rename already guarantees.
    func missingAssets() -> [CircuitAsset] {
        assets.filter { !isInstalled($0) }
    }

    /// Installed assets that have aged past their refresh interval.
    ///
    /// Only the revocation snapshot can appear here. A stale snapshot is worse
    /// than a missing one: everything downloads, every screen says ready, and
    /// the proof is rejected at the counter because its Merkle root no longer
    /// matches the verifier's.
    func staleAssets(asOf now: Date = Date()) -> [CircuitAsset] {
        assets.filter { asset in
            guard let interval = asset.refreshInterval, isInstalled(asset) else { return false }
            guard let modified = try? installedURL(for: asset)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return false
            }
            return now.timeIntervalSince(modified) > interval
        }
    }

    /// Bytes currently occupied, for a settings row that lets the user get them
    /// back.
    func installedByteCount() -> Int64 {
        assets.reduce(0) { total, asset in
            let size = (try? installedURL(for: asset)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    func installedURL(for asset: CircuitAsset) -> URL {
        directory.appendingPathComponent(asset.localFilename)
    }

    // MARK: - Download

    /// Fetches, verifies and installs one asset, resuming a previous attempt if
    /// there is anything to resume from.
    ///
    /// `progress` reports 0...1 across the whole operation, not just the
    /// transfer, because all three phases are slow enough to look like a hang
    /// on their own: 41 MB down the wire, a SHA-256 pass over it, then a 662 MB
    /// inflate. It is called from a background queue — hop to the main actor
    /// before touching UI.
    @discardableResult
    func download(_ asset: CircuitAsset,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard !inFlight.contains(asset.name) else {
            throw CircuitAssetError.alreadyInProgress(name: asset.name)
        }
        inFlight.insert(asset.name)
        defer { inFlight.remove(asset.name) }

        try prepareDirectories()
        try ensureSpace(for: asset)

        let staged = stagingURL(for: asset, suffix: "download")
        let expanded = stagingURL(for: asset, suffix: "expanded")
        let destination = installedURL(for: asset)
        let sidecar = resumeDataURL(for: asset)

        // Phase boundaries, as fractions of the whole operation.
        let transferEnd = asset.expandsAfterDownload ? 0.72 : 0.88
        let verifyEnd = asset.sha256 == nil ? transferEnd
                                            : (asset.expandsAfterDownload ? 0.80 : 0.94)
        let report: @Sendable (Double) -> Void = { value in
            progress?(min(max(value, 0), 1))
        }

        // MARK: transfer
        try await fetchWithResume(asset, into: staged, sidecar: sidecar) { written, expected in
            // `expected` is NSURLSessionTransferSizeUnknown (-1) when the server
            // omits Content-Length; fall back to the manifest figure so the bar
            // still moves.
            let total = expected > 0 ? expected : asset.compressedByteCount
            guard total > 0 else { return }
            report(transferEnd * Double(written) / Double(total))
        }

        do {
            // MARK: is this the file we asked for?
            //
            // Before anything is inflated or installed, and before the CRC32
            // check, because this is the check that answers "are these our
            // bytes" rather than "did they arrive intact".
            if let expected = asset.sha256 {
                let actual = try await sha256Hex(ofFileAt: staged) { hashed in
                    guard asset.compressedByteCount > 0 else { return }
                    let fraction = min(1, Double(hashed) / Double(asset.compressedByteCount))
                    report(transferEnd + (verifyEnd - transferEnd) * fraction)
                }
                guard actual == expected else {
                    throw CircuitAssetError.hashMismatch(name: asset.name,
                                                         expected: expected,
                                                         actual: actual)
                }
            }

            // MARK: install
            if asset.expandsAfterDownload {
                try await inflate(from: staged, to: expanded, limit: asset.inflateByteLimit) { bytes in
                    guard asset.installedByteCount > 0 else { return }
                    let fraction = min(1, Double(bytes) / Double(asset.installedByteCount))
                    report(verifyEnd + (1 - verifyEnd) * fraction)
                }
                try install(expanded, at: destination)
            } else {
                // This one stays gzipped, so nothing else will ever incidentally
                // check it. Inflate it once into nowhere purely for the CRC.
                try await validateGzip(at: staged, limit: asset.inflateByteLimit) { bytes in
                    guard asset.installedByteCount > 0 else { return }
                    let fraction = min(1, Double(bytes) / Double(asset.installedByteCount * 12))
                    report(verifyEnd + (1 - verifyEnd) * fraction)
                }
                try install(staged, at: destination)
            }
        } catch let error as GzipError {
            // Everything here means the staged bytes are unusable, so the
            // partial state has to go — otherwise every retry resumes into the
            // same broken file.
            discardStagedState(staged: staged, expanded: expanded, sidecar: sidecar)
            if case .outputTooLarge(let limit) = error {
                throw CircuitAssetError.oversizedContent(name: asset.name, limit: limit)
            }
            // The realistic cause is not a flaky connection: these assets hang
            // off rolling `-latest` tags, so a download resumed across a
            // republish splices two different revisions together.
            throw CircuitAssetError.corruptDownload(name: asset.name, underlying: error)
        } catch let error as CircuitAssetError {
            // The hash mismatch path. Same reasoning, plus one more: leaving a
            // rejected proving key in `.staging` is exactly the file we least
            // want lying around.
            discardStagedState(staged: staged, expanded: expanded, sidecar: sidecar)
            throw error
        }
        // A `CancellationError` deliberately passes through untouched: the user
        // backing out is the case the resume sidecar exists for.

        discardStagedState(staged: staged, expanded: expanded, sidecar: sidecar)
        return destination
    }

    /// Copies the bundled issuing certificate into the working directory, where
    /// `generateCertChainRs4096Input` expects to find it as `issuerCertPath`.
    ///
    /// Note this is the *issuer*, not the cardholder's certificate — the latter
    /// arrives from TW FidO as `result.cert` and goes in as `certb64`. Swapping
    /// the two is the obvious way to get a proof that never verifies.
    @discardableResult
    func installBundledIssuerCertificate(from bundle: Bundle = .main) throws -> URL {
        try prepareDirectories()
        let destination = directory.appendingPathComponent(Self.issuerCertificateFilename)
        guard let source = bundle.url(forResource: "MOICA-G3", withExtension: "cer") else {
            throw CircuitAssetError.bundledResourceMissing(filename: Self.issuerCertificateFilename)
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    /// Removes every installed asset and any partial state.
    ///
    /// The directory itself stays so the backup exclusion does not have to be
    /// re-applied on the next download.
    func deleteAll() throws {
        for asset in assets {
            try? fileManager.removeItem(at: installedURL(for: asset))
        }
        try? fileManager.removeItem(at: stagingDirectory)
    }

    // MARK: - Transfer

    private func fetchWithResume(_ asset: CircuitAsset,
                                 into staged: URL,
                                 sidecar: URL,
                                 report: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await withResumeSidecar(sidecar) { resumeData in
            try await fetch(asset, into: staged, sidecar: sidecar,
                            resumeData: resumeData, report: report)
        }
    }

    /// Runs `attempt` with whatever resume data is on disk, and decides what
    /// happens to the sidecar when it fails.
    ///
    /// The sidecar is discarded in exactly one case: we resumed from it and the
    /// failure says the saved state itself is unusable — the server no longer
    /// has that entity (4xx), or Foundation could not make sense of the blob.
    /// Then, and only then, is starting over the right move.
    ///
    /// **Every other failure keeps it.** An earlier version deleted the sidecar
    /// on *any* error and immediately restarted from byte 0, which gets the
    /// common case exactly backwards: for an 82 MB download the normal failure
    /// is the connection dropping, and the error handler has just written fresh
    /// resume data covering everything transferred so far. Deleting that and
    /// re-fetching from zero threw away the bytes the user had already paid for
    /// — on cellular, twice — and on a connection bad enough to drop once, it
    /// tends to drop again, so the second attempt usually failed too, from
    /// further back.
    ///
    /// Not retrying transient failures here is deliberate: the sidecar means a
    /// later attempt picks up where this one stopped, so the honest thing is to
    /// surface the error and let the user (or the readiness screen) retry, with
    /// the bytes still on disk.
    ///
    /// Internal rather than private so a test can drive the policy with an
    /// `attempt` it controls; the failure this guards against is measured in
    /// megabytes of someone's data plan and is not observable from the outside.
    @discardableResult
    func withResumeSidecar<T>(_ sidecar: URL, attempt: (Data?) async throws -> T) async throws -> T {
        let resumeData = try? Data(contentsOf: sidecar)
        do {
            return try await attempt(resumeData)
        } catch is CancellationError {
            // The user backed out. Keep everything: this is the case resuming
            // exists for.
            throw CancellationError()
        } catch {
            guard resumeData != nil,
                  !Task.isCancelled,
                  Self.resumeDataIsStale(after: error) else { throw error }
            try? fileManager.removeItem(at: sidecar)
            return try await attempt(nil)
        }
    }

    /// Whether a failed attempt means the saved resume data can never work.
    ///
    /// The default is "no". A network that dropped says nothing about the bytes
    /// we already have, and treating those two the same is what turned every
    /// interrupted download into a full one.
    static func resumeDataIsStale(after error: Error) -> Bool {
        switch error {
        case let error as CircuitAssetError:
            switch error {
            case .serverRejected(_, let statusCode):
                // 4xx on a resumed request is the server saying the thing we
                // asked to continue is gone: 404/410 after a republish, 412 when
                // the ETag moved, 416 when our offset is past the new length.
                // A 5xx is the server having a bad day and implies nothing about
                // our partial file.
                return (400...499).contains(statusCode)
            case .downloadFailed(_, let underlying):
                return underlying.map(isUnusableResumeURLError) ?? false
            default:
                return false
            }
        default:
            return isUnusableResumeURLError(error)
        }
    }

    private static func isUnusableResumeURLError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorUnsupportedURL:
            // What Foundation actually returns for a resume blob it cannot
            // parse — measured, not guessed: garbage bytes, an empty file and a
            // well-formed plist with the wrong keys all fail the task with
            // -1002 rather than throwing at construction time.
            return true
        case NSURLErrorFileDoesNotExist, NSURLErrorCannotOpenFile, NSURLErrorCannotCreateFile,
             NSURLErrorCannotWriteToFile, NSURLErrorCannotMoveFile, NSURLErrorCannotRemoveFile,
             NSURLErrorCannotCloseFile:
            // The partial file the blob points at has been evicted from the
            // system's temporary storage.
            return true
        case NSURLErrorDownloadDecodingFailedMidStream, NSURLErrorDownloadDecodingFailedToComplete:
            // The two halves do not splice — content-encoding state cannot pick
            // up from where the saved bytes stop.
            return true
        default:
            // timedOut, networkConnectionLost, notConnectedToInternet,
            // cannotConnectToHost, dataNotAllowed, secureConnectionFailed …
            // all transient. Keep the bytes.
            return false
        }
    }

    private func fetch(_ asset: CircuitAsset,
                       into staged: URL,
                       sidecar: URL,
                       resumeData: Data?,
                       report: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let name = asset.name
        let session = self.session
        let remoteURL = asset.remoteURL

        let coordinator = CircuitAssetDownloadCoordinator(
            onProgress: report,
            saveResumeData: { data in try? data.write(to: sidecar, options: .atomic) },
            receiveFile: { location, response in
                // A 404 still produces a perfectly good temporary file full of
                // GitHub's error page. Refusing it here means it is never even
                // moved into staging — and it reaches `withResumeSidecar` as a
                // `serverRejected`, which is what lets a stale sidecar be told
                // apart from a bad network.
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw CircuitAssetError.serverRejected(name: name, statusCode: http.statusCode)
                }
                // This has to happen inside the delegate callback: Foundation
                // deletes the temporary file the moment it returns.
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.moveItem(at: location, to: staged)
            },
            makeConnectivityError: { CircuitAssetError.noUsableConnection(name: name) },
            makeTransferError: { CircuitAssetError.downloadFailed(name: name, underlying: $0) })

        try await withTaskCancellationHandler {
            try await coordinator.run {
                if let resumeData {
                    return session.downloadTask(withResumeData: resumeData)
                }
                return session.downloadTask(with: remoteURL)
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    // MARK: - Verify

    /// Streaming SHA-256 of a file, 1 MB at a time.
    ///
    /// Streaming rather than `Data(contentsOf:)` for the same reason everything
    /// else here streams: this runs against a 41 MB file on a phone, and the
    /// memory-mapped shortcut stops being a shortcut the first time the OS
    /// decides to fault the whole thing in.
    static func sha256Hex(ofFileAt url: URL,
                          progress: ((Int64) throws -> Void)? = nil) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }

        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            try progress?(total)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(ofFileAt url: URL,
                           report: @escaping @Sendable (Int64) -> Void) async throws -> String {
        try await offload { flag in
            try Self.sha256Hex(ofFileAt: url) { bytes in
                if flag.isCancelled { throw CancellationError() }
                report(bytes)
            }
        }
    }

    // MARK: - Inflate

    private func inflate(from source: URL,
                         to destination: URL,
                         limit: Int64?,
                         report: @escaping @Sendable (Int64) -> Void) async throws {
        _ = try await offload { flag in
            try GzipDecoder.decompress(from: source, to: destination, limit: limit) { bytes in
                if flag.isCancelled { throw CancellationError() }
                report(bytes)
            }
        }
    }

    private func validateGzip(at source: URL,
                              limit: Int64?,
                              report: @escaping @Sendable (Int64) -> Void) async throws {
        _ = try await offload { flag in
            try GzipDecoder.validate(at: source, limit: limit) { bytes in
                if flag.isCancelled { throw CancellationError() }
                report(bytes)
            }
        }
    }

    /// Runs a long synchronous job on a dedicated queue while still honouring
    /// Swift task cancellation.
    ///
    /// `Task.isCancelled` is meaningless inside a plain `DispatchQueue` block —
    /// there is no current task there — so cancellation is carried across on an
    /// explicit flag that the progress callback checks.
    private func offload<T: Sendable>(_ body: @escaping @Sendable (CancellationFlag) throws -> T) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                Self.inflateQueue.async {
                    do {
                        continuation.resume(returning: try body(flag))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    // MARK: - Filesystem

    private var stagingDirectory: URL {
        directory.appendingPathComponent(".staging", isDirectory: true)
    }

    private func stagingURL(for asset: CircuitAsset, suffix: String) -> URL {
        stagingDirectory.appendingPathComponent("\(asset.name).\(suffix)")
    }

    private func resumeDataURL(for asset: CircuitAsset) -> URL {
        stagingDirectory.appendingPathComponent("\(asset.name).resumedata")
    }

    private func isInstalled(_ asset: CircuitAsset) -> Bool {
        let size = (try? installedURL(for: asset)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
    }

    private func discardStagedState(staged: URL, expanded: URL, sidecar: URL) {
        try? fileManager.removeItem(at: staged)
        try? fileManager.removeItem(at: expanded)
        try? fileManager.removeItem(at: sidecar)
    }

    private func prepareDirectories() throws {
        try Self.prepareDirectories(at: directory, fileManager: fileManager)
    }

    /// Creates the working tree, and re-asserts on every call the two things
    /// that have to hold for the whole life of the app rather than only the
    /// first time.
    ///
    /// **Data Protection.** Class B (`.completeUnlessOpen`), the same class
    /// `CredentialStore` uses, and for the same reason: `keys/` is not only
    /// where a public 662 MB proving key lands, it is also where OpenACSwift
    /// writes its proof inputs and outputs, and those are derived from the
    /// cardholder's certificate. Two directories holding material derived from
    /// the same national-ID credential should not have two different answers to
    /// "can this be read off a seized locked phone", and the weaker of the two
    /// answers is the one that counts. Files created inside inherit the class,
    /// which covers everything we write; the snapshot keeps whatever class it
    /// had when URLSession created it in the system temporary directory, which
    /// is acceptable precisely because it is a public revocation list published
    /// on GitHub.
    ///
    /// Class B's cost — nothing here is readable while the device is locked —
    /// is close to theoretical for this feature: none of this is a background
    /// session, so a transfer or an inflate only makes progress while the app is
    /// in the foreground, which means unlocked.
    ///
    /// **Backup exclusion is fatal if it fails, not best-effort.** It used to be
    /// a `try?`. ~950 MB of regenerable blobs silently entering every iCloud
    /// backup is both the thing that gets an app flagged and, for `keys/`, a
    /// copy of proof material leaving the device — the one promise this app
    /// makes. `CredentialStore` already refuses to construct itself when the
    /// same call fails; matching that here is the point.
    static func prepareDirectories(at directory: URL, fileManager: FileManager = .default) throws {
        let attributes = directoryAttributes
        // The root first and by name: creating it as a by-product of
        // `withIntermediateDirectories` would leave it without the attributes.
        // `keys/` is created eagerly because OpenACSwift writes its proof output
        // there too, and it will not create the directory itself.
        for url in [directory,
                    directory.appendingPathComponent("keys", isDirectory: true),
                    directory.appendingPathComponent(".staging", isDirectory: true)] {
            try fileManager.createDirectory(at: url,
                                            withIntermediateDirectories: true,
                                            attributes: attributes)
        }

        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(excluded)
    }

    /// Enough room for the peak, not just the download.
    private func ensureSpace(for asset: CircuitAsset) throws {
        guard let available = try? directory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else {
            // Not knowing is not a reason to refuse; the write will fail
            // honestly if it comes to that.
            return
        }
        let required = asset.peakDiskByteCount
        guard available > required else {
            throw CircuitAssetError.insufficientDiskSpace(required: required, available: available)
        }
    }

    /// The Data Protection class every directory here is created with. See
    /// `prepareDirectories(at:fileManager:)` for why it is this one.
    private static let directoryAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.completeUnlessOpen
    ]

    /// Rename into place. Same volume, so this is atomic — which is what lets
    /// `missingAssets()` treat a file's existence as proof it is complete.
    private func install(_ source: URL, at destination: URL) throws {
        // Carries the attributes too: this is a no-op for a directory
        // `prepareDirectories` already made, but it must not be the one place
        // that quietly creates an unprotected one.
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: Self.directoryAttributes)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: source, to: destination)
    }
}

// MARK: - Concurrency plumbing

/// Drives one `URLSessionDownloadTask` and turns its delegate callbacks into a
/// single `async` result.
///
/// **Pure delegate, no completion handler, and that is the entire point.** A
/// task created with `downloadTask(with:completionHandler:)` gets *no*
/// data-delivery delegate callbacks at all — not `didWriteData`, not
/// `didFinishDownloadingTo`, not `didCompleteWithError`. Measured, against a
/// protocol serving 1 MiB in 16 chunks: the completion-handler task reported 0
/// callbacks of any kind, the delegate task reported all 16 plus completion.
/// The previous version of this file combined the two and left a comment
/// claiming `didWriteData` still fired; it did not, so the progress bar sat at
/// zero for the entire 41 MB — the exact "looks like it has hung" failure the
/// header comment says the numbers are in the UI to avoid.
///
/// Internal rather than private so the connectivity path can be tested without
/// a network that is genuinely unavailable.
final class CircuitAssetDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let saveResumeData: @Sendable (Data) -> Void
    /// Claims the finished temporary file. Called on the delegate queue, and
    /// must be synchronous — see `didFinishDownloadingTo`.
    private let receiveFile: @Sendable (URL, URLResponse?) throws -> Void
    private let makeConnectivityError: @Sendable () -> Error
    private let makeTransferError: @Sendable (Error) -> Error

    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    /// A failure decided before the task finished — a rejected status code, or
    /// the connectivity stall — which has to outlive the `cancelled` error that
    /// follows it.
    private var recordedFailure: Error?
    private var isCancelled = false
    private var isSettled = false

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void,
         saveResumeData: @escaping @Sendable (Data) -> Void,
         receiveFile: @escaping @Sendable (URL, URLResponse?) throws -> Void,
         makeConnectivityError: @escaping @Sendable () -> Error,
         makeTransferError: @escaping @Sendable (Error) -> Error) {
        self.onProgress = onProgress
        self.saveResumeData = saveResumeData
        self.receiveFile = receiveFile
        self.makeConnectivityError = makeConnectivityError
        self.makeTransferError = makeTransferError
    }

    // MARK: Driving

    /// Starts the task `makeTask` builds and returns when it has finished, one
    /// way or another.
    func run(_ makeTask: () -> URLSessionDownloadTask) async throws {
        let task = makeTask()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isSettled {
                // Cancelled before we got here.
                let failure = recordedFailure ?? CancellationError()
                lock.unlock()
                task.cancel()
                continuation.resume(throwing: failure)
                return
            }
            self.continuation = continuation
            let cancelled = isCancelled
            if cancelled {
                lock.unlock()
                task.cancel()
                settle(with: CancellationError())
                return
            }
            self.task = task
            lock.unlock()

            // Per-task delegate rather than a session-wide one: this object
            // knows about exactly one transfer, and the session is shared.
            task.delegate = self
            task.resume()
        }
    }

    /// Cancellation from the Swift task, i.e. the user left the screen.
    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        let settled = isSettled
        lock.unlock()

        if let task {
            // Keep the bytes: `byProducingResumeData` is why an 82 MB download
            // survives someone backing out to check something.
            task.cancel(byProducingResumeData: { [saveResumeData] data in
                if let data { saveResumeData(data) }
            })
        } else if !settled {
            // Cancellation arrived before the task was handed over; `run` will
            // find this on the way in.
            settle(with: CancellationError())
        }
    }

    private func record(_ error: Error) {
        lock.lock()
        if recordedFailure == nil { recordedFailure = error }
        lock.unlock()
    }

    private func settle(with error: Error?) {
        lock.lock()
        guard !isSettled else { lock.unlock(); return }
        isSettled = true
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        if continuation == nil, let error { recordedFailure = error }
        lock.unlock()

        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Foundation deletes `location` as soon as this returns, so the file is
        // claimed here and the outcome is remembered for `didCompleteWithError`,
        // which always follows and is the single place the continuation
        // resumes.
        do {
            try receiveFile(location, downloadTask.response)
        } catch {
            record(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let recorded = recordedFailure
        lock.unlock()

        guard let error else {
            // A rejected status code lands here with no transport error.
            settle(with: recorded)
            return
        }

        let nsError = error as NSError
        // Foundation hands back whatever is already on disk so the next attempt
        // can pick up from there. This fires for dropped connections as well as
        // cancellation, which is the more common way an 82 MB download dies.
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            saveResumeData(data)
        }

        if let recorded {
            // We cancelled the task ourselves for a reason we already know; the
            // resulting `cancelled` error would only hide it.
            settle(with: recorded)
        } else if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            // Surface cancellation as `CancellationError` so callers can tell
            // "the user left" from "the network failed".
            settle(with: CancellationError())
        } else if nsError.domain == NSURLErrorDomain, Self.connectivityErrorCodes.contains(nsError.code) {
            settle(with: makeConnectivityError())
        } else {
            settle(with: makeTransferError(error))
        }
    }

    /// "There is no network this transfer is allowed to use", as opposed to
    /// "the network misbehaved". `dataNotAllowed` is what Low Data Mode
    /// produces once `waitsForConnectivity` is off — which is the whole reason
    /// it is off.
    private static let connectivityErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
    ]

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        // Only reachable when someone hands in a session with
        // `waitsForConnectivity` on. Waiting is the failure mode this whole
        // path exists to avoid: the task neither starts nor fails, the caller
        // gets nothing to show, and `inFlight` stays occupied until the
        // resource timeout. Turn it into an error now.
        record(makeConnectivityError())
        task.cancel()
    }
}

/// A cancellation signal that can cross into a plain `DispatchQueue` block.
private final class CancellationFlag: @unchecked Sendable {

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
