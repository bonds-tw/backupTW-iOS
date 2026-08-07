//
//  ZKProofRunWiring.swift
//  backupTW
//
//  The production implementations of the four seams in `ZKProofRun.swift`, and
//  the one function that assembles them.
//

import Foundation

// MARK: - Assets

/// `CircuitAssets`, plus the two verifying keys, plus the bundled issuer
/// certificate — everything `ZKProver` and `OpenACProofVerifier` need present.
///
/// # Why the issuer certificate is in the plan at all
///
/// It ships in the app bundle and costs nothing to fetch, so listing it as an
/// outstanding requirement looks like noise. It is there because `ZKProver`
/// refuses to prove without it (`ZKProofError.issuerCertificateMissing`), and a
/// readiness screen that says 「已備妥」 while the prover would refuse is the
/// exact failure this whole stage exists to prevent. Zero bytes of download and
/// a row in the list is the honest rendering.
///
/// It is installed through `IssuerCertificate.install(into:)` rather than
/// `CircuitAssets.installBundledIssuerCertificate(from:)`. The two do different
/// things: the latter copies the bundled file without checking it, and re-reads
/// the bundle to do so. `IssuerCertificate` verifies the SHA-256 pin, re-checks
/// the identity on three independent fields, verifies the chain to GRCA-G3, and
/// then writes **the bytes it just verified** — no second read, so there is no
/// window between the check and the copy.
///
/// That covers the write. The read is covered by `issuerCertificateIsVerified`,
/// which re-hashes the installed file on every `plan()` — i.e. at the start of
/// every run — so an anchor that changed on disk since it was installed is back
/// in the plan and rewritten before a proof can be built on it.
struct CircuitAssetPreparer: ZKAssetPreparing {

    /// What `ZKProver.prove` reads. All three or no proof.
    static var provingAssets: [CircuitAsset] { CircuitAssets.required }

    /// What only `OpenACProofVerifier` reads: 139 MB down the wire, 968 MB on
    /// disk, and not one byte of it opened by `prove`.
    ///
    /// Kept as its own list because the difference is load-bearing in two
    /// places. `makeProvingStore` uses it to keep these rows out of the answer
    /// to "may this device prove?", and
    /// `ZKAssetPreparing.verificationOnlyRequirementNames` uses it to keep a
    /// failure to fetch them from ending a run that can still produce a proof.
    static var verificationAssets: [CircuitAsset] { ZKVerifyingKeyAssets.all }

    /// Everything, in the order it is downloaded: proving keys first, then the
    /// revocation snapshot, then the verifying keys.
    ///
    /// Order matters for a user who runs out of patience or disk halfway: the
    /// first three are what it takes to *produce* a proof, and the last two only
    /// let this device check its own work.
    static var allAssets: [CircuitAsset] {
        provingAssets + verificationAssets
    }

    static var totalDownloadByteCount: Int64 {
        CircuitAssets.totalDownloadByteCount + ZKVerifyingKeyAssets.totalDownloadByteCount
    }

    static var totalInstalledByteCount: Int64 {
        CircuitAssets.totalInstalledByteCount + ZKVerifyingKeyAssets.totalInstalledByteCount
    }

    /// Identifies the issuer-certificate row. Not a download, so it has no
    /// `CircuitAsset`.
    static let issuerRequirementName = "issuer_certificate"

    /// DER length of the pinned MOICA-G3, for the disk figure in the
    /// disclosure. It is a display number and nothing else: what decides whether
    /// the file is accepted is `IssuerCertificate.pinnedIssuerSHA256`, checked
    /// over the bytes before they are written.
    static let issuerCertificateByteCount: Int64 = 1643

    let store: CircuitAssets

    /// Injected so a test can watch the certificate be installed without a
    /// bundle. Returns the installed URL.
    ///
    /// The bundle is captured in the closure rather than stored on this struct:
    /// `Bundle` is a class and not `Sendable`, and this type has to be.
    let installIssuerCertificate: @Sendable (URL) throws -> URL

    var workingDirectory: URL { store.workingDirectory }

    init(store: CircuitAssets,
         bundle: Bundle = .main,
         installIssuerCertificate: (@Sendable (URL) throws -> URL)? = nil) {
        self.store = store
        self.installIssuerCertificate = installIssuerCertificate ?? { directory in
            try IssuerCertificate.loadBundled(from: bundle).install(into: directory)
        }
    }

    /// The production store: the same working directory `CircuitAssets` chooses
    /// for itself, but carrying the verifying keys too, so `missingAssets()` and
    /// `deleteAll()` cover the whole set rather than only the proving half.
    ///
    /// This is the *download* store — what the readiness screen prices and what
    /// stage 1 fetches. It is not what decides whether a proof may be attempted:
    /// see `makeProvingStore`.
    static func makeStore(directory: URL) -> CircuitAssets {
        CircuitAssets(directory: directory,
                      session: URLSession(configuration: CircuitAssets.makeSessionConfiguration()),
                      assets: allAssets)
    }

    /// The store `ZKProver` asks whether it may run.
    ///
    /// # Why this is not `makeStore`
    ///
    /// `ZKProver`'s readiness is its store's `missingAssets()`, so handing it a
    /// store that also lists the verifying keys made `prove` refuse — with
    /// `assetsNotReady`, naming files it never opens — until 968 MB it has no
    /// use for was on disk. On a phone that cannot fit both halves, that is not
    /// a delay: there is no order of downloads and no number of retries that
    /// produces a proof, because the thing being waited for is not needed and
    /// will not fit.
    ///
    /// Same directory, so both stores see the same files; only the question they
    /// answer differs.
    static func makeProvingStore(directory: URL) -> CircuitAssets {
        CircuitAssets(directory: directory,
                      session: URLSession(configuration: CircuitAssets.makeSessionConfiguration()),
                      assets: provingAssets)
    }

    /// The two verifying keys, by requirement name.
    ///
    /// The issuer certificate is deliberately absent: `ZKProver` refuses without
    /// it, so it belongs to the proving half even though it is not a download.
    var verificationOnlyRequirementNames: Set<String> {
        Set(Self.verificationAssets.map(\.name))
    }

    func plan() async -> ZKAssetPlan {
        let missing = await store.missingAssets()
        let stale = await store.staleAssets()
        var outstanding = missing.map {
            ZKAssetRequirement(name: $0.name,
                               displayName: Self.displayName(for: $0),
                               downloadByteCount: $0.compressedByteCount,
                               installedByteCount: $0.installedByteCount,
                               isStale: false)
        }
        outstanding += stale.map {
            ZKAssetRequirement(name: $0.name,
                               displayName: Self.displayName(for: $0),
                               downloadByteCount: $0.compressedByteCount,
                               // Already on disk; refetching it costs the wire,
                               // not the volume.
                               installedByteCount: 0,
                               isStale: true)
        }
        if !issuerCertificateIsVerified {
            outstanding.append(ZKAssetRequirement(
                name: Self.issuerRequirementName,
                displayName: NSLocalizedString("Issuing authority certificate", comment: ""),
                downloadByteCount: 0,
                installedByteCount: Self.issuerCertificateByteCount,
                isStale: false))
        }
        return ZKAssetPlan(outstanding: outstanding)
    }

    func prepare(progress: @escaping @Sendable (ZKAssetProgress) -> Void) async throws {
        let plan = await plan()
        let downloads = plan.outstanding.filter { $0.name != Self.issuerRequirementName }

        // Resolved from the store's own two lists, not from `Self.allAssets`.
        // `plan()` derives every row it emits from `store.missingAssets()` and
        // `store.staleAssets()`, so a store built from any other set — a test
        // fixture, or a second production store like `makeProvingStore` — put
        // rows in the plan that a lookup against the static list did not
        // contain. The `continue` below then skipped them in silence:
        // `prepare()` returned *success* having downloaded nothing, the next
        // `plan()` listed the same requirement outstanding, and nothing anywhere
        // said why. Deriving both from the same source makes the miss
        // impossible rather than merely unlikely.
        let missing = await store.missingAssets()
        let stale = await store.staleAssets()
        let byName = Dictionary((missing + stale).map { ($0.name, $0) },
                                uniquingKeysWith: { first, _ in first })

        // Weighted by transfer size rather than by count: three assets where one
        // is 41 MB and one is 1.6 KB produce a bar that sits at 0% and then jumps
        // to 66% if each row counts the same.
        let totalBytes = max(Int64(1), downloads.reduce(Int64(0)) { $0 + $1.downloadByteCount })
        var completedBytes: Int64 = 0
        var completedCount = 0
        let totalCount = plan.outstanding.count

        // First, and unconditionally: it is cheap, and re-installing it repairs a
        // working directory that a restore or a purge emptied — or altered —
        // without anyone noticing.
        //
        // The verification is in `loadBundled`, which the default closure calls
        // afresh on every `prepare`. `install(into:)` itself verifies nothing;
        // it writes bytes that were verified a moment earlier, which is a
        // different and weaker statement, and an earlier version of this comment
        // claimed otherwise. What makes the installed copy trustworthy on a run
        // that downloads nothing is not this line — it is
        // `issuerCertificateIsVerified` below, which puts the anchor back in the
        // plan whenever the bytes on disk stop matching the pin, and so brings
        // execution here.
        //
        // **Before the downloads rather than after, and that ordering is load
        // bearing.** It used to be the last statement in this function, which
        // meant any download that failed took the free, mandatory step down with
        // it: the anchor stayed uninstalled, so the next `plan()` listed it
        // among the outstanding requirements, so `ZKProofRunner` had something
        // the *prover* needs still outstanding and stopped the run. On a phone
        // that cannot fit the verifying keys that is a permanent state — the
        // download that fails is the one that runs first, every attempt, and the
        // 1.6 KB that would have unblocked everything is queued behind it.
        // Doing it first also means a rejected trust anchor is discovered before
        // 82 MB is spent instead of after (see `ZKRunError.trustAnchorRejected`).
        _ = try installIssuerCertificate(workingDirectory)

        for requirement in downloads {
            guard let asset = byName[requirement.name] else { continue }
            let base = completedBytes
            let weight = Double(requirement.downloadByteCount) / Double(totalBytes)
            let name = requirement.displayName
            let finished = completedCount
            try await store.download(asset) { fraction in
                progress(ZKAssetProgress(
                    displayName: name,
                    overallFraction: min(1, Double(base) / Double(totalBytes) + weight * fraction),
                    completedCount: finished,
                    totalCount: totalCount))
            }
            completedBytes += requirement.downloadByteCount
            completedCount += 1
            progress(ZKAssetProgress(displayName: name,
                                     overallFraction: min(1, Double(completedBytes) / Double(totalBytes)),
                                     completedCount: completedCount,
                                     totalCount: totalCount))
        }
    }

    /// Whether the installed anchor is the one this build pinned — the digest,
    /// not merely a file of non-zero length.
    ///
    /// # Why the size check was not enough
    ///
    /// This property is the whole gate. `ZKProofRunner` calls `plan()` at the
    /// start of every run and only calls `prepare()` when something is
    /// outstanding, so a `true` here means `install` is not reached, which means
    /// the pin is not checked — and `ZKProver.prove` then tests the same file
    /// with `fileExists` alone before handing it to
    /// `generateCertChainRs4096Input` as `issuerCertPath`. With `fileSize > 0`
    /// as the test, every proof after the first install ran against an issuer
    /// public key nothing had re-examined since.
    ///
    /// Hashing 1.6 KB per run is not a cost worth reasoning about next to a
    /// proof that takes tens of seconds and about two gigabytes.
    ///
    /// **Altered bytes are repaired rather than refused**, deliberately. They
    /// end up in the plan under the same row as "never installed", because the
    /// two lead to the same action — write the verified bundle bytes over
    /// whatever is there — and because the realistic cause is a restore or a
    /// corrupted file rather than an adversary. An attacker who can write into
    /// this container can equally write into `keys/`, so refusing here would buy
    /// no security while turning a repairable device into a bricked one. What
    /// must not happen, and no longer does, is *using* the altered bytes.
    private var issuerCertificateIsVerified: Bool {
        IssuerCertificate.installedCertificateIsVerified(in: workingDirectory)
    }

    /// `CircuitAsset.displayName` covers the three rows in `CircuitAssets`
    /// and falls through to the raw identifier for anything else, which would put
    /// `cert_chain_rs4096_verifying` on screen in an app whose interface is
    /// Chinese. The two extra rows get their names here.
    static func displayName(for asset: CircuitAsset) -> String {
        switch asset.name {
        case "cert_chain_rs4096_verifying":
            return NSLocalizedString("Certificate chain checking key", comment: "ZK circuit asset")
        case "user_sig_rs2048_verifying":
            return NSLocalizedString("Signature checking key", comment: "ZK circuit asset")
        default:
            return asset.displayName
        }
    }
}

// MARK: - Signing

/// The TW FidO round trip, behind a seam so the parts this app owns — the
/// polling cadence, the deadline, the holder-certificate gate — can be tested
/// without 內政部.
protocol TWFidOSignSession: Sendable {
    func begin(idNumber: String, hint: String, timeLimit: Int) async throws
        -> (ticket: TWFidOTicket, deepLink: URL)
    func poll(ticket: TWFidOTicket) async throws -> TWFidOSignResult?
}

/// Waiting on the `backuptw://` return leg.
///
/// A protocol rather than `MOICACallbackRouter.shared` directly, because a test
/// that never fires a callback must not spend the whole polling deadline in real
/// time.
protocol TWFidOCallbackWaiting: Sendable {
    func waitForCallback(transactionID: String) async
    func cancelWait(transactionID: String) async
}

extension MOICACallbackRouter: TWFidOCallbackWaiting {}

/// The real session.
///
/// `@unchecked Sendable` and the reason is worth stating rather than suppressing:
/// `TWFidOClient` is a struct holding a `TWFidOConfiguration` (two immutable
/// values), a `URLSession` (documented thread-safe) and an
/// `SPCredentialProviding` whose only method is `async` and whose two
/// implementations are stateless. None of that is mutable shared state; the
/// compiler cannot see it because `TWFidOClient` predates this file and marking
/// it `Sendable` would mean editing a module this change does not own.
struct LiveTWFidOSignSession: TWFidOSignSession, @unchecked Sendable {

    let client: TWFidOClient
    let returnURL: URL

    func begin(idNumber: String, hint: String, timeLimit: Int) async throws
        -> (ticket: TWFidOTicket, deepLink: URL) {
        try await client.requestSignAppToApp(
            TWFidOSignRequest(idNumber: idNumber, hint: hint, timeLimit: timeLimit),
            returnURL: returnURL)
    }

    func poll(ticket: TWFidOTicket) async throws -> TWFidOSignResult? {
        try await client.fetchResult(for: ticket)
    }
}

/// Runs the 行動自然人憑證 app-to-app flow and turns its answer into
/// `ProvingInputs`.
///
/// # The certificate gate, and where it belongs
///
/// `validateHolderCertificate` runs here — after the signature comes back,
/// before `ProvingInputs` exists and therefore before anything reaches the
/// circuit. The reason it is here rather than inside `ZKProver` is cost: a G2
/// certificate produces a proof that is mathematically valid and that no
/// verifier will ever accept, and finding that out after thirty seconds and two
/// gigabytes is thirty seconds and two gigabytes worse than finding it out now.
///
/// The gate is **not** a security boundary and must not be read as one. The AKI
/// it dispatches on is an unauthenticated field and the validity dates it checks
/// are unauthenticated too; the actual check is the signature verification in
/// step three, and the circuit re-derives it regardless. What the gate buys is a
/// sentence the holder can act on ("your certificate is the older G2 kind")
/// instead of an opaque `InvalidInput` from Rust.
struct TWFidOHolderSigner: ZKHolderSigning {

    let idNumber: String
    let session: any TWFidOSignSession
    let callbacks: any TWFidOCallbackWaiting

    /// Hands the deep link to the system. Returns whether anything opened it —
    /// `false` means 行動自然人憑證 is not installed, which is a different
    /// sentence from "the signature was refused".
    let open: @Sendable (URL) async -> Bool

    /// What the holder sees on the certificate app's prompt.
    let hint: String

    /// Seconds. Also the ticket's own `time_limit`, so the deadline this app
    /// enforces and the one 內政部 enforces cannot drift apart.
    let timeLimit: Int

    /// The spec asks for at least four seconds between result polls.
    let pollInterval: TimeInterval

    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Injected so the gate can be exercised without a real 自然人憑證. Returns
    /// nothing; throws to refuse.
    let validateHolderCertificate: @Sendable (String) throws -> Void

    init(idNumber: String,
         session: any TWFidOSignSession,
         callbacks: any TWFidOCallbackWaiting = MOICACallbackRouter.shared,
         open: @escaping @Sendable (URL) async -> Bool,
         hint: String = NSLocalizedString("Prove you hold a valid certificate", comment: ""),
         timeLimit: Int = 600,
         pollInterval: TimeInterval = 4,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         },
         validateHolderCertificate: @escaping @Sendable (String) throws -> Void = { base64 in
             _ = try IssuerCertificate.loadBundled().validateHolderCertificate(base64DER: base64)
         }) {
        self.idNumber = idNumber
        self.session = session
        self.callbacks = callbacks
        self.open = open
        self.hint = hint
        self.timeLimit = timeLimit
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
        self.validateHolderCertificate = validateHolderCertificate
    }

    func sign(challenge: ProofChallenge) async throws -> ProvingInputs {
        let started: (ticket: TWFidOTicket, deepLink: URL)
        do {
            started = try await session.begin(idNumber: idNumber, hint: hint, timeLimit: timeLimit)
        } catch let error as SPCredentialError {
            // Not a failure of the holder's certificate and retrying changes
            // nothing: this build has no way to authenticate to the SP API.
            throw ZKRunError.signingUnavailable(message: Self.credentialMessage(error))
        } catch {
            throw ZKRunError.signingFailed(message: ZKProofRunner.message(for: error))
        }

        guard await open(started.deepLink) else {
            throw ZKRunError.signingUnavailable(message: NSLocalizedString(
                "The 行動自然人憑證 app isn't installed on this device.", comment: ""))
        }

        let deadline = now().addingTimeInterval(TimeInterval(timeLimit))
        let result = try await awaitResult(ticket: started.ticket, deadline: deadline)

        // Before `ProvingInputs`, so a refusal costs a millisecond rather than a
        // proof. See the type's doc comment for why this is not a security gate.
        do {
            try validateHolderCertificate(result.cert)
        } catch let error as IssuerCertificateError {
            throw ZKRunError.signingFailed(message: error.localizedDescription)
        }

        do {
            return try ProvingInputs(signResult: result, challenge: challenge)
        } catch let error as ProvingInputError {
            throw ZKRunError.inputsRejected(error)
        }
    }

    /// Polls until the holder approves, the ticket expires, or the task is
    /// cancelled.
    ///
    /// The `backuptw://` callback is raced against each sleep purely to shorten
    /// the wait — it is never treated as the answer. Any app on the device can
    /// open our scheme, so the callback is a hint that it is worth polling again,
    /// and the signature itself always comes from an `idp_checksum`-authenticated
    /// ATH-02 response. `cancelWait` is called on every exit from the race: the
    /// router holds the continuation in a dictionary and nothing else would ever
    /// resume it, so a wait abandoned here would strand a task for the life of
    /// the process — and the task group would never finish.
    private func awaitResult(ticket: TWFidOTicket, deadline: Date) async throws -> TWFidOSignResult {
        while true {
            try Task.checkCancellation()
            do {
                if let result = try await session.poll(ticket: ticket) {
                    return result
                }
            } catch let error as SPCredentialError {
                throw ZKRunError.signingUnavailable(message: Self.credentialMessage(error))
            } catch {
                throw ZKRunError.signingFailed(message: ZKProofRunner.message(for: error))
            }

            guard now() < deadline else { throw ZKRunError.signingTimedOut }
            await raceCallbackAgainstSleep(transactionID: ticket.transactionID)
        }
    }

    private func raceCallbackAgainstSleep(transactionID: String) async {
        let callbacks = self.callbacks
        let sleep = self.sleep
        let interval = self.pollInterval
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await sleep(interval) }
            group.addTask { await callbacks.waitForCallback(transactionID: transactionID) }
            await group.next()
            // Resumes the callback waiter if it is still parked. Without this the
            // group would wait forever for a continuation nothing resumes.
            await callbacks.cancelWait(transactionID: transactionID)
            group.cancelAll()
        }
    }

    /// `SPCredentialError` is `CustomStringConvertible`, not `LocalizedError` —
    /// deliberately, because its audience is whoever reads the log. On screen
    /// that would render as Foundation's "The operation couldn't be completed",
    /// so it is translated here instead.
    static func credentialMessage(_ error: SPCredentialError) -> String {
        switch error {
        case .notConfigured:
            return NSLocalizedString(
                "This build has no credentials for the digital certificate service, so it can't request a signature.",
                comment: "")
        case .requiresBackend:
            return NSLocalizedString(
                "Signing has to go through the bonds-tw server, which this build can't reach.",
                comment: "")
        }
    }
}

// MARK: - Assembly

/// Builds the production runner.
///
/// A free function rather than a convenience initialiser on `ZKProofRunner`
/// because it is the one place that knows about `#if DEBUG`: the SP credential
/// provider only exists in a debug build, and a release build has no code path
/// that could produce one (see `SPSecrets.swift`). Keeping that fact in the
/// assembly rather than inside the runner means the runner stays testable
/// without a preprocessor.
enum ZKProofRunAssembly {

    /// `nil` when this build cannot reach TW FidO at all, so the screen can say
    /// so up front rather than after a download.
    static func makeSigner(idNumber: String,
                           open: @escaping @Sendable (URL) async -> Bool) -> (any ZKHolderSigning)? {
        #if DEBUG
        guard let returnURL = URL(string: "\(MOICACallbackRouter.scheme)://twfido-sign") else {
            return nil
        }
        let client = TWFidOClient(configuration: .production,
                                  credentials: DevelopmentSPCredentialProvider())
        return TWFidOHolderSigner(
            idNumber: idNumber,
            session: LiveTWFidOSignSession(client: client, returnURL: returnURL),
            open: open)
        #else
        // A distribution build must not hold the SP AES key. Until the bonds-tw
        // backend exists there is nothing to route the request through, and
        // returning nil is how that reaches the screen as a sentence instead of
        // as a failure halfway through.
        _ = idNumber
        _ = open
        return nil
        #endif
    }

    static func makeRunner(directory: URL,
                           signer: any ZKHolderSigning) -> ZKProofRunner {
        // Two stores over one directory, on purpose: the preparer offers and
        // fetches everything, the prover is only ever asked about what it reads.
        let store = CircuitAssetPreparer.makeStore(directory: directory)
        let proving = CircuitAssetPreparer.makeProvingStore(directory: directory)
        return ZKProofRunner(assets: CircuitAssetPreparer(store: store),
                             signer: signer,
                             prover: ZKProverAdapter(prover: ZKProver(assets: proving)),
                             verifier: OpenACProofVerifier())
    }
}
