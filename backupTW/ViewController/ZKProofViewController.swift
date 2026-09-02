//
//  ZKProofViewController.swift
//  backupTW
//
//  白皮書 5.2 的最小揭露：證明「有一張真的自然人憑證簽了這份證明」而不揭露憑證內容。
//  刻意不寫「有效」——電路裡沒有日期欄位，certificateExpiryNotProven 就是為了否認它。
//

import UIKit

// MARK: - Copy

/// Every sentence this screen says about what a proof is and is not.
///
/// A type rather than string literals at the call sites, because the defect it
/// exists to prevent is not a bug in a function — it is a sentence. The section
/// above the button used to promise that the certificate's "serial number is not
/// in the revocation list": the exact claim `IssuerCertificate` forbids in
/// writing ("Do not let UI copy say 'not revoked'"), flatly contradicted by
/// `ProofCaveat.revocationRootNotAnchored`, which the same screen showed
/// *afterwards*. Copy that no test can read is copy that drifts, and this screen
/// is the one place in the app where drift decides whether someone believes a
/// stranger's identity.
enum ZKProofCopy {

    /// ⚠️ Two words removed, and each was doing damage.
    ///
    /// **「valid」** — the circuit has no date field. `certificateExpiryNotProven`
    /// is shipped for the sole purpose of denying this: 「This proves who issued
    /// the certificate, not that it is still valid today.」
    ///
    /// **「you」** — the signing material never expires and never changes, so
    /// anybody who has held it once can produce this proof with the holder
    /// absent. `ZKProver`'s own comment says the same, and the capability page
    /// was corrected in the same direction.
    static let whatItDoesTitle = NSLocalizedString("Proves a real certificate signed this",
                                                   comment: "")

    /// What a proof does establish. Every clause is scoped, and the scopes are
    /// the point.
    ///
    /// **"checked against a revocation list this app cannot confirm is
    /// complete"**, not "is not in the revocation list". The proof does carry a
    /// real non-membership witness — `ZKProver` refuses one whose `smtRoot` came
    /// back `"0"` — but the snapshot's trust anchor is the SMT root published
    /// on-chain and nothing here has ever compared the two. Whoever can publish
    /// to `moica-revocation-smt` can serve a snapshot with revocations quietly
    /// dropped, and the proof over it verifies. The strongest true statement is
    /// that the list was applied, not that the certificate is good.
    ///
    /// **"The person checking never sees…"**, not "without showing…". The
    /// non-disclosure holds against the verifier and is false of the issuer:
    /// making a proof sends 身分證統一編號 to 內政部 in the clear. See
    /// `ProofCaveat.idNumberDisclosedToIssuer`.
    static let whatItDoes = NSLocalizedString(
        "Creates a mathematical proof that your 自然人憑證 was issued by 內政部憑證管理中心, and checks its serial number against a revocation list this app cannot confirm is complete. The person checking the proof never sees your name, your ID number, or the certificate itself.",
        comment: "")

    static let limitsTitle = NSLocalizedString("What it cannot show", comment: "")

    /// Shown while asking for the 身分證統一編號, which is the moment the
    /// disclosure actually happens rather than the moment it is summarised.
    ///
    /// "this app does not keep it" rather than "it is not stored": the app's
    /// copy is what is discarded, and `TWFidOClient` goes to some trouble over
    /// that — an ephemeral `URLSession` with no cache so a response carrying
    /// `cert` and `hashed_id_num` never reaches disk, and `ProvingInputs` drops
    /// `hashedIDNumber` on the floor. None of that touches the copy 內政部 keeps,
    /// and the old sentence's "and to nowhere else" invited the reader to hear
    /// "so nobody has it".
    static let idNumberPrompt = NSLocalizedString(
        "內政部 needs this to send the signing request to your phone. It goes to 內政部 and nowhere else, and this app does not keep it — but 內政部 records that you asked, and which service asked.",
        comment: "")

    /// The caveats a run started from this screen will attach to its result,
    /// known before it starts.
    ///
    /// Derived from `ZKProver.caveats(for:)` rather than restated, so the list
    /// shown before the tap and the list shown after it are the same list by
    /// construction. That equality is the fix: before, the "what it cannot show"
    /// paragraph named two limitations while the result named four, and the
    /// shorter list is the one a person reads while deciding.
    ///
    /// `startRun` always mints its own challenge — nobody is standing in front of
    /// this screen with one — so `challengeNotBoundToVerifier` always applies and
    /// this is the complete list. The string in the case is never read;
    /// `caveats(for:)` consults only `boundToVerifier`.
    static let plannedCaveats: [ProofCaveat] = ZKProver.caveats(for: .holderGenerated(""))

    /// Every sentence this screen puts on the subject, in one array a test can
    /// walk. Stage titles and byte counts are excluded: they make no claim about
    /// what a proof means.
    static var allProse: [String] {
        [whatItDoesTitle, whatItDoes, limitsTitle, idNumberPrompt]
            + ProofCaveat.allCases.map(\.localizedDescription)
    }
}

/// The whole zero-knowledge pipeline on one screen: prepare ~2 GB of circuit
/// material, sign with 行動自然人憑證, prove, and check the proof here on the
/// device.
///
/// # What this screen is for
///
/// It is the only place in the app where the M2 claim can be observed rather
/// than asserted. Every other surface either takes proofs on trust or does not
/// mention them; this one runs the four steps in front of the user, shows what
/// each one cost, and — the part that matters most — shows what the finished
/// proof still does **not** establish.
///
/// # Three rules this screen is written to
///
/// **Nothing downloads without being asked for.** The circuit material is close
/// to two gigabytes. `confirmAndRun()` puts the transfer size, the installed
/// size and what the files are for in front of the user and waits for a tap.
/// There is no path from `viewDidLoad` to a download.
///
/// **A failure says which step failed and what it means.** Four stages, four
/// distinguishable outcomes, and `ZKRunStageState.unavailable` exists so that
/// "this device cannot check the proof" is never drawn the same way as "this
/// device checked the proof and rejected it".
///
/// **The caveats are not optional chrome, and they are shown twice.**
/// `ZKProofBundle.caveats` is rendered in the result section, not behind a
/// disclosure arrow, because the sentence a person is most likely to take away
/// from a green tick — 「這個人是真的，而且只有一個」 — is the one thing this
/// proof cannot support offline. The same sentences are also shown *before* the
/// button, from `ZKProofCopy.plannedCaveats`, and the repetition is the design
/// rather than an oversight: the decision to run happens above the fold and the
/// caveats used to live entirely below it. The two lists come from
/// `ZKProver.caveats(for:)`, so they cannot disagree.
final class ZKProofViewController: UICollectionViewController {

    // MARK: - Rows

    private struct Row: Hashable {
        enum Kind: Hashable {
            case prose
            /// One outstanding download, with its size.
            case requirement
            /// A stage with a state accessory.
            case stage(ZKRunStage)
            case action
            /// Hands the finished proof to somebody who can check it.
            case export
            /// Sends the finished proof straight to the checker's phone.
            case send
            case verdict
            case caveat
            /// The pasteable benchmark text.
            case report
        }
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        /// nil where there is nothing to judge.
        let passed: Bool?
        let isBusy: Bool
        let isEnabled: Bool

        init(id: String,
             kind: Kind,
             title: String,
             detail: String = "",
             passed: Bool? = nil,
             isBusy: Bool = false,
             isEnabled: Bool = true) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.passed = passed
            self.isBusy = isBusy
            self.isEnabled = isEnabled
        }
    }

    private struct Group: Hashable {
        let id: String
        let title: String
        let rows: [Row]
    }

    // MARK: - State

    private var dataSource: UICollectionViewDiffableDataSource<Group, Row>!
    private var groups: [Group] = []

    private var plan: ZKAssetPlan?
    private var snapshot: ZKRunSnapshot?
    private var isLoadingPlan = true
    private var recordedReportStart: Date?

    /// `private(set)` rather than `private`, here and on `runner`, so a test can
    /// watch both of them go. See `endRun()` for what was wrong with the version
    /// that had no test.
    private(set) var runTask: Task<Void, Never>?

    /// Built once the user has supplied an ID number, and released the moment the
    /// run ends — it holds nothing sensitive itself, but the signer it wraps
    /// carries the 身分證統一編號 the holder typed, as a plain `String`, for as
    /// long as anything at all points at it.
    private(set) var runner: ZKProofRunner?

    private var isRunning: Bool { runTask != nil }

    // MARK: - Lifecycle

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // A run holds a ~2 GB proof and a TW FidO ticket. Leaving it going after
        // the screen is gone means the user cannot see it, cannot stop it, and
        // gets the memory pressure anyway.
        runTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Minimal disclosure", comment: "ZK proof screen title")
        view.accessibilityIdentifier = "zkProofScreen"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain, target: self, action: #selector(copyReport))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "copyReport"
        navigationItem.rightBarButtonItem?.isEnabled = false

        configureDataSource()
        reload()
        loadPlan()
    }

    // MARK: - Data

    private func loadPlan() {
        Task { [weak self] in
            guard let directory = try? CircuitAssets.defaultDirectory() else {
                await MainActor.run {
                    self?.isLoadingPlan = false
                    self?.reload()
                }
                return
            }
            let store = CircuitAssetPreparer.makeStore(directory: directory)
            let plan = await CircuitAssetPreparer(store: store).plan()
            await MainActor.run {
                self?.plan = plan
                self?.isLoadingPlan = false
                self?.reload()
            }
        }
    }

    private func reload() {
        groups = buildGroups()
        var snapshot = NSDiffableDataSourceSnapshot<Group, Row>()
        for group in groups {
            snapshot.appendSections([group])
            snapshot.appendItems(group.rows, toSection: group)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        navigationItem.rightBarButtonItem?.isEnabled = self.snapshot?.report != nil
    }

    private func buildGroups() -> [Group] {
        var groups = [aboutGroup(), limitsGroup()]
        if let group = preparationGroup() { groups.append(group) }
        groups.append(actionGroup())
        if snapshot != nil { groups.append(stageGroup()) }
        if let group = resultGroup() { groups.append(group) }
        if let group = exportGroup() { groups.append(group) }
        if let group = caveatGroup() { groups.append(group) }
        if let group = reportGroup() { groups.append(group) }
        return groups
    }

    /// Deliberately first, and deliberately not collapsible.
    private func aboutGroup() -> Group {
        Group(id: "about",
              title: NSLocalizedString("What this does", comment: ""),
              rows: [
                Row(id: "about.what",
                    kind: .prose,
                    title: ZKProofCopy.whatItDoesTitle,
                    detail: ZKProofCopy.whatItDoes)
              ])
    }

    /// The limitations, before the button rather than only after the result.
    ///
    /// One row per caveat, straight from `ZKProofCopy.plannedCaveats`, for the
    /// same reason `caveatGroup` gives: a paragraph that names some of them is
    /// how the ones it leaves out stop being said at all. It used to be a
    /// paragraph, it named two, and there were four — the two it dropped were
    /// that the revocation list is unverifiable and that the certificate's
    /// freshness is not bound to the person checking.
    ///
    /// Always present, including while a run is in flight and after it has
    /// finished: this section is what the screen claims, and `caveatGroup` is
    /// what one particular proof carries. Seeing the same sentences in both
    /// places is the intended outcome, not duplication to be tidied away.
    private func limitsGroup() -> Group {
        Group(id: "limits",
              title: ZKProofCopy.limitsTitle,
              rows: ZKProofCopy.plannedCaveats.map { caveat in
                Row(id: "about.caveat.\(caveat.rawValue)",
                    kind: .caveat,
                    title: caveat.localizedDescription,
                    passed: false)
              })
    }

    private func preparationGroup() -> Group? {
        if isLoadingPlan {
            return Group(id: "prepare",
                         title: NSLocalizedString("Before you start", comment: ""),
                         rows: [Row(id: "prepare.loading",
                                    kind: .prose,
                                    title: NSLocalizedString("Checking what's already downloaded…",
                                                             comment: ""),
                                    isBusy: true)])
        }
        guard let plan else {
            return Group(id: "prepare",
                         title: NSLocalizedString("Before you start", comment: ""),
                         rows: [Row(id: "prepare.unknown",
                                    kind: .prose,
                                    title: NSLocalizedString("Couldn't check the verification files.",
                                                             comment: ""),
                                    passed: false)])
        }
        guard !plan.isReady else {
            return Group(id: "prepare",
                         title: NSLocalizedString("Before you start", comment: ""),
                         rows: [Row(id: "prepare.ready",
                                    kind: .prose,
                                    title: NSLocalizedString("Verification files are ready", comment: ""),
                                    detail: String(
                                        format: NSLocalizedString("%@ already on this device",
                                                                  comment: "installed byte count"),
                                        ZKStagePresentation.byteString(CircuitAssetPreparer.totalInstalledByteCount)),
                                    passed: true)])
        }

        // The whole point of this section: the price, itemised, before the tap.
        // The wording lives in `ZKStagePresentation` so it can be asserted —
        // a plan can now have outstanding work and cost nothing on the wire.
        let summary = ZKStagePresentation.preparationSummary(for: plan)
        var rows = [Row(id: "prepare.total",
                        kind: .prose,
                        title: summary.title,
                        detail: summary.detail)]
        rows += plan.outstanding.map { requirement in
            Row(id: "prepare.\(requirement.name)",
                kind: .requirement,
                title: requirement.displayName,
                detail: ZKStagePresentation.requirementDetail(for: requirement))
        }
        return Group(id: "prepare",
                     title: NSLocalizedString("Before you start", comment: ""),
                     rows: rows)
    }

    private func actionGroup() -> Group {
        // # The limit is asked about here, not four screens later
        //
        // `ZKProofRunAssembly.makeSigner` returns nil in a release build, and
        // that was only discovered inside `start(idNumber:)` — *after*
        // `promptForIDNumber()` had already collected a 身分證統一編號. So the
        // most sensitive value this app handles was gathered by a build that was
        // never, at any point, going to be able to send it.
        //
        // The subtitle was worse than silent: it promised 「過程中會請你到行動
        // 自然人憑證 App 完成核可」, which in this build does not happen.
        guard ZKProofRunAssembly.isSigningAvailable else {
            return Group(id: "action", title: "", rows: [
                Row(id: "action.run",
                    kind: .action,
                    title: NSLocalizedString("Create a proof", comment: ""),
                    detail: NSLocalizedString(
                        "This version cannot create a proof: it has no credentials for the digital certificate service. Nothing will be asked for.",
                        comment: ""),
                    isBusy: false,
                    isEnabled: false)
            ])
        }
        let title = isRunning
            ? NSLocalizedString("Stop", comment: "")
            : NSLocalizedString("Create a proof", comment: "")
        return Group(id: "action", title: "", rows: [
            Row(id: "action.run",
                kind: .action,
                title: title,
                detail: isRunning ? "" : NSLocalizedString(
                    "You'll be asked to approve this in the 行動自然人憑證 app.", comment: ""),
                isBusy: false,
                isEnabled: !isLoadingPlan)
        ])
    }

    /// Only after a proof exists, and deliberately not called "share".
    ///
    /// Until this row existed the ZK screen was a cul-de-sac: it produced a
    /// proof, reported on it, and offered no way for the proof to reach anybody
    /// who might want to check it. The offline presentation path next door
    /// carries a credential, not a proof, so the two halves of the whitepaper's
    /// claim never met.
    ///
    /// The size is in the label because it is not a detail here. At ~294 KB this
    /// cannot go over QR the way a credential does — that is 100 frames — so
    /// what leaves this screen is a file, and the person tapping should know
    /// they are moving something the size of a photo rather than flashing a
    /// barcode.
    private func exportGroup() -> Group? {
        guard let report = snapshot?.report else { return nil }
        let size = ZKStagePresentation.byteString(Int64(report.bundle.totalProofByteCount))
        // Bluetooth first, file second. Not a stylistic ordering: over the radio
        // this is about twenty seconds directly onto the checker's phone, while
        // the file route needs AirDrop or a share sheet and leaves a copy of
        // somebody's identity proof wherever it lands. The file stays because
        // the radio is not always available and because AirDrop across the
        // counter is a real thing people do.
        return Group(id: "export", title: "", rows: [
            Row(id: "export.link",
                kind: .send,
                title: NSLocalizedString("Send this proof over Bluetooth", comment: ""),
                detail: String(format: NSLocalizedString(
                    "Scan the checker's code and %@ goes straight to their phone — about twenty seconds. Nothing is stored anywhere else.",
                    comment: "proof package size"), size),
                isBusy: false,
                isEnabled: true),
            Row(id: "export.package",
                kind: .export,
                title: NSLocalizedString("Save this proof as a file", comment: ""),
                detail: String(format: NSLocalizedString(
                    "Saves a %@ file to send by AirDrop or Files. Far too large for a QR code — it would be 824 codes.",
                    comment: "proof package size"), size),
                isBusy: false,
                isEnabled: true)
        ])
    }

    private func stageGroup() -> Group {
        let snapshot = self.snapshot ?? .initial
        let rows = ZKRunStage.allCases.map { stage -> Row in
            let state = snapshot.state(stage)
            return Row(id: "stage.\(stage.rawValue)",
                       kind: .stage(stage),
                       title: stage.title,
                       detail: ZKStagePresentation.detail(for: state),
                       passed: ZKStagePresentation.verdict(for: state),
                       isBusy: ZKStagePresentation.isBusy(state))
        }
        return Group(id: "stages",
                     title: NSLocalizedString("Progress", comment: ""),
                     rows: rows)
    }

    private func resultGroup() -> Group? {
        guard let report = snapshot?.report else { return nil }
        var rows: [Row] = []

        // The verdict, phrased so that "nothing checked it", "the check could not
        // finish" and "it was checked and refused" cannot be read as each other.
        switch report.verification {
        case .completed(let outcome):
            rows.append(Row(
                id: "result.verdict",
                kind: .verdict,
                title: outcome.isFullyValid
                    ? NSLocalizedString("Checked on this device: the proof holds", comment: "")
                    : NSLocalizedString("Checked on this device: the proof does not hold", comment: ""),
                detail: String(format: NSLocalizedString("Checked in %@, with no network",
                                                         comment: "verification duration"),
                               ZKStagePresentation.durationString(outcome.totalMilliseconds)),
                passed: outcome.isFullyValid))
        case .notAttempted:
            rows.append(Row(
                id: "result.verdict",
                kind: .verdict,
                title: NSLocalizedString("A proof was created but nothing checked it", comment: ""),
                detail: NSLocalizedString(
                    "Producing a proof is not evidence that anyone would accept it.", comment: ""),
                passed: nil))
        case .errored(let message):
            rows.append(Row(
                id: "result.verdict",
                kind: .verdict,
                title: NSLocalizedString("The check on this device did not finish", comment: ""),
                detail: message,
                passed: nil))
        }

        rows.append(Row(id: "result.prove",
                        kind: .verdict,
                        title: NSLocalizedString("Time to create the proof", comment: ""),
                        detail: ZKStagePresentation.durationString(report.bundle.totalProveMilliseconds)))
        rows.append(Row(id: "result.size",
                        kind: .verdict,
                        title: NSLocalizedString("Proof size", comment: ""),
                        detail: ZKStagePresentation.byteString(Int64(report.bundle.totalProofByteCount))))

        return Group(id: "result",
                     title: NSLocalizedString("Result", comment: ""),
                     rows: rows)
    }

    /// Its own section rather than four rows tacked onto the result, because as
    /// four rows every one of them repeated the same title — 「仍未證明的事」 —
    /// and a heading that is printed four times stops being read. The sentence is
    /// the row now; the heading says it once.
    private func caveatGroup() -> Group? {
        guard let report = snapshot?.report, !report.bundle.caveats.isEmpty else { return nil }
        return Group(id: "caveats",
                     title: NSLocalizedString("Still unproven", comment: "caveat section title"),
                     rows: report.bundle.caveats.map { caveat in
                        Row(id: "result.caveat.\(caveat.rawValue)",
                            kind: .caveat,
                            title: caveat.localizedDescription,
                            passed: false)
                     })
    }

    private func reportGroup() -> Group? {
        guard let report = snapshot?.report else { return nil }
        return Group(id: "report",
                     title: NSLocalizedString("Measurements", comment: ""),
                     rows: [Row(id: "report.text", kind: .report, title: report.text)])
    }

    // MARK: - Running

    private func handleAction() {
        if isRunning {
            confirmStop()
            return
        }
        confirmAndRun()
    }

    /// Stopping costs little and the button did not say so — and the first
    /// version of this sentence said the opposite of what cancel does. It
    /// claimed the running step 「下次會重新開始」, but `CircuitAssets` keeps the
    /// resume sidecar precisely on cancellation, so an interrupted download is
    /// *kept* and the next run tries to continue from it — succeeding while the
    /// server's signed URL is still valid, restarting transparently once it has
    /// expired. The alert claims only the part that always holds: nothing
    /// already fetched is thrown away. Inflating and installing restart.
    /// `deinit`'s unconditional cancel is untouched: leaving the screen is its
    /// own answer.
    private func confirmStop() {
        let alert = UIAlertController(
            title: NSLocalizedString("Stop this run?", comment: ""),
            message: NSLocalizedString("Downloaded files stay on this phone, and a partly finished download is kept for next time. Unpacking starts over.", comment: ""),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Keep going", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("Stop", comment: ""),
                                      style: .destructive) { [weak self] _ in
            self?.runTask?.cancel()
        })
        present(alert, animated: true)
    }

    /// The consent gate. Nothing is fetched before this returns.
    ///
    /// A multi-gigabyte download deserves a page, not an alert: the old shape
    /// was two stacked alerts (download → ID number), and a decision that
    /// arrives as the first of two dialogs is a decision people click through
    /// (design system §8.2). The ID-number prompt stays an alert — it is the
    /// one dialog that must capture text, and `makeIDNumberPrompt` carries a
    /// tested no-leak guarantee this page must not replace.
    private func confirmAndRun() {
        guard let plan else { return }
        guard plan.isReady == false else {
            promptForIDNumber()
            return
        }
        let consent = ZKDownloadConsentViewController(
            downloadByteCount: plan.downloadByteCount,
            installedByteCount: plan.installedByteCount) { [weak self] in
                guard let self else { return }
                self.navigationController?.popToViewController(self, animated: true)
                self.promptForIDNumber()
            }
        navigationController?.pushViewController(consent, animated: true)
    }

    /// Asked once, up front, so the rest of the run is unattended.
    ///
    /// Asked *before* the download rather than after it for a reason that only
    /// shows up on a build with no SP credentials: `makeSigner` returns nil
    /// there, and finding that out after two gigabytes would be the worst
    /// possible moment to learn it.
    private func promptForIDNumber() {
        present(Self.makeIDNumberPrompt { [weak self] idNumber in
            self?.start(idNumber: idNumber)
        }, animated: true)
    }

    /// Builds the prompt; the caller presents it.
    ///
    /// # Why this is a separate function
    ///
    /// So that the alert's *lifetime* can be observed by a test, because the
    /// version this replaced never ended. Its Continue handler read
    /// `alert.textFields` and so captured `alert` strongly, and an alert that
    /// owns an action that owns a closure that owns the alert is never
    /// deallocated — not on dismissal, not when the screen is popped, not for
    /// the life of the process. What it keeps resident is a `UITextField`
    /// holding the 身分證統一編號, three lines under a message promising that
    /// this app does not keep it. That promise is about disk and is true there;
    /// an immortal alert is how it stops being true in memory. Nothing about it
    /// is visible: the alert dismisses, the run starts, and the leak is one word
    /// of capture list.
    ///
    /// `[weak alert]` is the entire fix, which is exactly why it needs a test
    /// standing over it — it is a single word that any later edit can drop while
    /// the screen goes on behaving identically.
    ///
    /// `static` so it cannot reach `self` at all: the handler closes over
    /// `onContinue` instead, and the caller decides what that does.
    static func makeIDNumberPrompt(onContinue: @escaping (String) -> Void) -> UIAlertController {
        let alert = UIAlertController(
            title: NSLocalizedString("Your ID number", comment: ""),
            // The consent moment for the disclosure, so it is stated here and
            // not only in the caveat list. The previous wording — "sent to
            // 內政部 and to nowhere else, and it is not stored" — was true of
            // this app and read as though it were true of everybody: what is not
            // stored is this app's copy. 內政部 receives `id_num`,
            // `sp_service_id` and `sign_data` in one request body and is the one
            // party that ends up with a record.
            message: ZKProofCopy.idNumberPrompt,
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = NSLocalizedString("A123456789", comment: "ID number placeholder")
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            // Found by looking at the screen: on a phone set to 正體中文 the
            // field opened a 注音 keyboard, which cannot type A123456789 without
            // the user switching layout first. A 身分證統一編號 is one Latin
            // letter and nine digits and nothing else.
            field.keyboardType = .asciiCapable
            field.accessibilityIdentifier = "idNumberField"
        }
        // The button names the act, not the direction of travel.
        //
        // The message above says plainly that the number goes to 內政部 and
        // that 內政部 keeps a record. It said all that while the button said
        // 「繼續」 — so every gram of the disclosure sat in the paragraph people
        // skip, and none of it in the control that actually consents. This app's
        // other consent moment already gets this right: it says 「出示 3 個欄位
        // （含姓名）」, not 「繼續」.
        //
        // Not one word of the message changes. Only the button now carries its
        // share.
        alert.addAction(UIAlertAction(title: NSLocalizedString("Send the number to 內政部", comment: ""),
                                      style: .default) { [weak alert] _ in
            // Alive when this runs — UIKit invokes the handler from the alert
            // itself. Weak only so that the reference does not outlive it.
            let value = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            onContinue(value)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        return alert
    }

    private func start(idNumber: String) {
        guard !idNumber.isEmpty else { return }
        guard let directory = try? CircuitAssets.defaultDirectory() else {
            presentFailure(NSLocalizedString("Couldn't check the verification files.", comment: ""))
            return
        }
        // `open`'s return value is the authority on whether anything handled the
        // link, and `canOpenURL` is still not consulted here.
        //
        // ⚠️ The reason given here used to be that `mobilemoica` is absent from
        // `LSApplicationQueriesSchemes`. **That is no longer true** — it is in
        // `Info.plist` now, and `MyDataOnboardViewController` relies on exactly
        // that query working. The remaining reason is narrower and still holds:
        // `canOpenURL` answers 「is something installed」 and `open` answers
        // 「did the handoff happen」, and only the second is the question at this
        // point in the flow.
        guard let signer = ZKProofRunAssembly.makeSigner(idNumber: idNumber, open: { url in
            await UIApplication.shared.open(url)
        }) else {
            presentFailure(NSLocalizedString(
                "This build can't request a signature: it has no credentials for the digital certificate service.",
                comment: ""))
            return
        }

        // `startRun` takes the reference; nothing here keeps a second one. The
        // signer inside carries `idNumber` in the clear, so the fewer places
        // point at it the shorter its life.
        startRun(ZKProofRunAssembly.makeRunner(directory: directory, signer: signer))
    }

    /// Internal so a test can start a run against fake seams: the production
    /// path builds its own runner inside `start(idNumber:)` — which needs SP
    /// credentials, 內政部 and two gigabytes — and what has to be observable
    /// afterwards is only that both references were dropped.
    func startRun(_ runner: ZKProofRunner) {
        self.runner = runner
        snapshot = .initial
        reload()

        // Built here rather than inside the task, and with a single level of
        // weak capture. Progress callbacks arrive from a download delegate queue
        // hundreds of times per asset; hopping to the main actor is what keeps
        // the list from being mutated off it, and coalescing there is what keeps
        // it from thrashing.
        let onUpdate: @Sendable (ZKRunSnapshot) -> Void = { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }

        runTask = Task { [weak self] in
            // Holder-generated: nobody is standing in front of this screen with a
            // challenge of their own. `ProofCaveat.challengeNotBoundToVerifier`
            // is attached to the result because of it, and shows up in the
            // caveat rows below.
            guard let challenge = try? ProofChallenge.generate() else {
                await MainActor.run {
                    self?.endRun()
                    self?.presentFailure(NSLocalizedString(
                        "This device could not generate a secure random number.", comment: ""))
                }
                return
            }
            let result = await runner.run(challenge: challenge, onUpdate: onUpdate)
            await MainActor.run {
                self?.endRun()
                self?.apply(result)
                // Found by looking at the screen: after a successful download the
                // "開始之前" section still itemised 143 MB of files that were by
                // then on disk, because the plan was read once in `viewDidLoad`
                // and never again. A readiness list that is wrong in the
                // reassuring direction is the one kind this screen must not have.
                self?.loadPlan()
            }
        }
        reload()
    }

    /// The one place a finished run's references are dropped.
    ///
    /// A method rather than two assignments because the defect was precisely
    /// that: every exit path cleared `runTask` and none of them cleared
    /// `runner`. The screen looked finished — the button says 「建立證明」 again,
    /// nothing is spinning — while the runner, its `TWFidOHolderSigner`, and the
    /// 身分證統一編號 that signer holds as a plain `String` stayed resident for
    /// as long as this screen was on the navigation stack. The property's own
    /// comment said it was thrown away when the run ended. It was not.
    @MainActor
    private func endRun() {
        runTask = nil
        runner = nil
    }

    /// Merges an update into what is on screen.
    ///
    /// A mid-run snapshot carries no report, and the download progress callback
    /// deliberately reports only its own stage. Overwriting a finished stage with
    /// `.waiting` from one of those would make the list flicker backwards, so a
    /// non-final update never clears a stage that has already settled.
    @MainActor
    private func apply(_ update: ZKRunSnapshot) {
        if let report = update.report, recordedReportStart != report.startedAt {
            recordedReportStart = report.startedAt
            let succeeded: Bool?
            let verificationMilliseconds: UInt64?
            switch report.verification {
            case .completed(let outcome):
                succeeded = outcome.isFullyValid
                verificationMilliseconds = outcome.totalMilliseconds
            case .notAttempted, .errored:
                succeeded = nil
                verificationMilliseconds = nil
            }
            let record = VerificationRunRecord(
                recordedAt: report.startedAt,
                flow: .zeroKnowledgeProofCreation,
                role: .holder,
                credentialKind: .mobileCertificate,
                transport: .local,
                succeeded: succeeded,
                preparationMilliseconds: report.proveWallClockMs,
                verificationMilliseconds: verificationMilliseconds,
                endToEndMilliseconds: report.totalWallClockMs)
            try? VerificationRunStore.shared.append(record)
        }
        guard let current = snapshot, !update.isFinished else {
            snapshot = update
            reload()
            return
        }
        var merged = current.states
        for stage in ZKRunStage.allCases {
            let incoming = update.state(stage)
            if case .waiting = incoming, current.state(stage).isTerminal { continue }
            merged[stage] = incoming
        }
        snapshot = ZKRunSnapshot(states: merged,
                                 report: update.report ?? current.report,
                                 isFinished: update.isFinished)
        reload()
    }

    private func presentFailure(_ message: String) {
        let alert = UIAlertController(title: NSLocalizedString("Can't start", comment: ""),
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    @objc private func copyReport() {
        guard let report = snapshot?.report else { return }
        UIPasteboard.general.string = report.text
        let alert = UIAlertController(title: NSLocalizedString("Copied", comment: ""),
                                      message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Collection

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.detail.isEmpty ? nil : row.detail
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = .secondaryLabel

            switch row.kind {
            case .action, .export, .send:
                content.text = row.title
                content.textProperties.color = row.isEnabled ? .tintColor : .tertiaryLabel
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
            case .report:
                // Unreachable: the report has its own cell (see `ZKReportCell`).
                break
            case .caveat:
                content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
                content.textProperties.color = .secondaryLabel
            case .prose, .requirement, .stage, .verdict:
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
            }
            cell.contentConfiguration = content

            if row.isBusy {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessories = [.customView(configuration: .init(customView: spinner,
                                                                     placement: .trailing()))]
            } else {
                // Spelled `.some(true)` rather than `true`: matching an
                // Optional<Bool> against boolean literals is only accepted as
                // exhaustive by newer compilers, and CI builds with an older
                // Xcode than this machine has.
                switch row.passed {
                case .some(true):
                    cell.accessories = [.customView(configuration: .init(
                        customView: Self.symbol("checkmark.circle.fill", .systemGreen),
                        placement: .trailing()))]
                case .some(false):
                    cell.accessories = [.customView(configuration: .init(
                        customView: Self.symbol("exclamationmark.triangle.fill", .systemOrange),
                        placement: .trailing()))]
                case .none:
                    cell.accessories = []
                }
            }
            cell.accessibilityIdentifier = row.id
        }
        let reportCell = UICollectionView.CellRegistration<ZKReportCell, Row> { cell, _, row in
            cell.setText(row.title)
            cell.accessibilityIdentifier = row.id
        }
        dataSource = UICollectionViewDiffableDataSource<Group, Row>(collectionView: collectionView) {
            view, indexPath, row in
            if case .report = row.kind {
                return view.dequeueConfiguredReusableCell(using: reportCell, for: indexPath, item: row)
            }
            return view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = view.defaultContentConfiguration()
            content.text = self?.groups[indexPath.section].title
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : nil
        }
    }

    /// Delegates to `VerdictSymbol`, which carries the spoken label too.
    ///
    /// This used to set `isAccessibilityElement` and an identifier and
    /// stop there — so VoiceOver halted on the verdict and read nothing,
    /// under a comment saying the verdict must be readable as something
    /// other than the colour of a glyph.
    private static func symbol(_ name: String, _ colour: UIColor) -> UIImageView {
        VerdictSymbol.view(name, colour)
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row.kind {
        case .action where row.isEnabled:
            handleAction()
        case .export:
            exportProofPackage()
        case .send:
            sendProofOverLink()
        case .report:
            copyReport()
        default:
            break
        }
    }

    /// Scans the checker's code and sends the proof straight to their phone.
    ///
    /// # Why this exists at all
    ///
    /// Because the file route was the *only* route, and for the situation this
    /// app is built for — no network, two strangers at a counter — a route that
    /// depends on AirDrop is thin. The numbers say the rest: the package proved
    /// on a real card is 398,181 bytes, which is **824 QR frames** and about
    /// **453 seconds** of carousel, and `QRTransport` refuses it outright above
    /// 64 KB. Over the radio the same bytes are 597 frames and **21.7 seconds**,
    /// measured 2026-08-13 — see `ZKVerifyViewController` for why the 8.6 this
    /// used to say was an extrapolation from a transfer too small to meet
    /// back-pressure.
    ///
    /// # What the holder is agreeing to
    ///
    /// The scan is the consent. Nothing advertises before a code has been read,
    /// so the proof is discoverable only after the holder pointed their camera
    /// at a specific checker's screen, and only under the identifier that
    /// checker minted. Leaving this screen takes the radio down with it.
    ///
    /// The proof itself is in the clear on the air, as `BluetoothLink` documents
    /// — but a proof is not a secret. It is a statement about a certificate that
    /// reveals no certificate, and an eavesdropper with a radio learns exactly
    /// what one with a camera would have.
    private func sendProofOverLink() {
        guard let report = snapshot?.report else { return }

        let package: Data
        do {
            package = try ZKProofPackage(readingFrom: report.bundle).encoded()
        } catch {
            presentSendFailure(error.localizedDescription)
            return
        }
        // Refused here rather than on the air, where it would look like a
        // dropped connection. `LinkTransport.frames(for:)` would throw anyway;
        // this turns that into a sentence naming both numbers.
        guard package.count <= LinkTransport.maximumPayloadBytes else {
            presentSendFailure(String(
                format: NSLocalizedString(
                    "This proof is %1$@, which is more than the %2$@ this app will send over Bluetooth. Save it as a file instead.",
                    comment: ""),
                ZKStagePresentation.byteString(Int64(package.count)),
                ZKStagePresentation.byteString(Int64(LinkTransport.maximumPayloadBytes))))
            return
        }

        let scanner = QRScanningViewController(
            title: NSLocalizedString("Scan the checker's code", comment: ""),
            prompt: NSLocalizedString("Point the camera at the checker's phone.", comment: "")
        ) { [weak self] scanned in
            guard let self else { return .stop }
            let engagement: ZKLinkEngagement
            do {
                engagement = try ZKLinkEngagement.decode(from: scanned)
            } catch ZKLinkEngagement.DecodingFailure.isACardSignedRequest {
                // The one failure that is not noise, and the one this app is
                // uniquely able to explain: that code is real, it is ours, and
                // it belongs to the other check. `ZKLinkEngagement` checks for
                // it before anything else precisely so it can be named here —
                // and then the `try?` at this call site threw the name away, so
                // the holder pointed a camera at a valid code and the app did
                // nothing at all. Both sides then have no clue, and the
                // conclusion available to them is that the app is broken.
                return .keepScanning(status: NSLocalizedString(
                    "That is the code for checking a document, not a proof. Use 「出示我的證件」 instead.",
                    comment: "Scanned the other kind of code"))
            } catch ZKLinkEngagement.DecodingFailure.unsupportedVersion {
                return .keepScanning(status: NSLocalizedString(
                    "That code was made by a newer version of the app. Update this app first.",
                    comment: "Scanned a newer code"))
            } catch {
                // Everything else fires once per video frame for every other QR
                // in the room. Silence is the only usable behaviour.
                return .keepScanning(status: nil)
            }
            guard engagement.isCurrent() else {
                return .keepScanning(status: NSLocalizedString(
                    "That code has expired. Ask them to show a fresh one.", comment: ""))
            }
            self.beginSending(package, to: engagement)
            return .stop
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

    /// Advertises the proof under the identifier the checker asked for.
    private func beginSending(_ package: Data, to engagement: ZKLinkEngagement) {
        navigationController?.popToViewController(self, animated: true)

        let progress = ZKLinkSendViewController(payload: package, engagement: engagement)
        // A sheet rather than a push: it owns the radio for as long as it is up,
        // and dismissing it is the holder's way of saying stop. A pushed screen
        // can be left by swiping without the gesture meaning anything.
        progress.isModalInPresentation = false
        present(UINavigationController(rootViewController: progress), animated: true)
    }

    private func presentSendFailure(_ message: String) {
        let alert = UIAlertController(
            title: NSLocalizedString("This proof could not be sent", comment: ""),
            message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""),
                                      style: .default))
        present(alert, animated: true)
    }

    /// Writes the proof package to a temporary file and offers it onward.
    ///
    /// The witnesses are already gone by this point — `ZKProver` discards them
    /// after proving — and `ZKProofPackage` names the four files it carries
    /// rather than sweeping the directory, so the cardholder's certificate and
    /// signature cannot be picked up here even if something put them back.
    private func exportProofPackage() {
        guard let report = snapshot?.report else { return }
        do {
            let package = try ZKProofPackage(readingFrom: report.bundle)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("proof-\(Int(Date().timeIntervalSince1970)).zkproof")
            // Same protection class the credential store uses. This file is
            // somebody's identity proof sitting in a world-readable-when-
            // unlocked scratch directory; before this it accumulated there at
            // the default class, which is looser than the app applies to
            // everything else it writes.
            try package.encoded().write(to: url,
                                        options: [.atomic, .completeFileProtectionUnlessOpen])

            let share = UIActivityViewController(activityItems: [url],
                                                 applicationActivities: nil)
            // An action sheet without a source raises on iPad rather than
            // falling back to a popover anchored anywhere sensible.
            if let popover = share.popoverPresentationController {
                popover.sourceView = collectionView
                popover.sourceRect = collectionView.bounds
            }
            // Gone once the share sheet closes, shared or not. AirDrop and the
            // Files app have their copy by then; the scratch copy has no
            // further job, and proofs must not pile up in tmp between runs.
            share.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: url)
            }
            present(share, animated: true)
        } catch {
            let alert = UIAlertController(
                title: NSLocalizedString("This proof could not be packaged", comment: ""),
                message: error.localizedDescription,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Confirm", comment: ""),
                                          style: .default))
            present(alert, animated: true)
        }
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch row.kind {
        case .action:
            return row.isEnabled
        case .export, .send, .report:
            return true
        default:
            return false
        }
    }
}

// MARK: - Report cell

/// The measurement report, in a cell that scrolls sideways.
///
/// Found by looking at the screen. `UIListContentConfiguration` wraps, and the
/// report is a column-aligned ASCII block up to ~90 characters wide; wrapped at
/// a phone's width every row broke in the middle and the alignment that makes
/// the thing readable — and diffable — was gone. It cannot be fixed by shrinking
/// the font without making it unreadable for a different reason.
///
/// So the label does not wrap at all and the cell scrolls horizontally instead.
/// The text stays byte-identical to what the copy button puts on the pasteboard,
/// which is the point: what is on screen and what gets pasted into an issue have
/// to be the same characters.
final class ZKReportCell: UICollectionViewCell {

    private let scrollView = UIScrollView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        // Vertical scrolling belongs to the collection view; without this the
        // cell steals the gesture and the list stops moving over the report.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = true
        contentView.addSubview(scrollView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.lineBreakMode = .byClipping
        label.font = Bonds.Font.mono(.caption2)
        label.textColor = .label
        label.isAccessibilityElement = true
        scrollView.addSubview(label)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            // Only the height is tied to the viewport; the width is free, which
            // is what makes the sideways scroll exist.
            label.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ text: String) {
        label.text = text
        // VoiceOver reads the label, and a 60-line ASCII table read aloud is
        // useless. The copy button is the accessible path to the content.
        label.accessibilityLabel = NSLocalizedString(
            "Measurement report. Use the copy button to read it elsewhere.",
            comment: "accessibility label for the pasteable benchmark report")
    }
}

// MARK: - Download consent page

/// The full-page half of the proof flow's consent (design system §8.2).
///
/// A ~2 GB download used to be approved inside the first of two stacked
/// alerts, which is where decisions go to be clicked through. This page says
/// the same three facts the alert said — how much, from whom, and that the
/// files never leave the phone — with room to be read, and its one filled
/// button names the act. Cancelling is the back button: leaving a consent page
/// unanswered *is* declining it.
final class ZKDownloadConsentViewController: UIViewController {

    private let downloadByteCount: Int64
    private let installedByteCount: Int64
    private let onConsent: () -> Void

    init(downloadByteCount: Int64, installedByteCount: Int64, onConsent: @escaping () -> Void) {
        self.downloadByteCount = downloadByteCount
        self.installedByteCount = installedByteCount
        self.onConsent = onConsent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Before the first proof", comment: "ZK download consent title")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        let download = ZKStagePresentation.byteString(downloadByteCount)
        let installed = ZKStagePresentation.byteString(installedByteCount)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Bonds.Space.page
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(PresentationUI.title(
            NSLocalizedString("Download the verification files?", comment: "")))
        stack.addArrangedSubview(PresentationUI.card(
            title: NSLocalizedString("What is downloaded", comment: "ZK download consent"),
            body: String(format: NSLocalizedString(
                "%@ of mathematical circuits, published by the Privacy & Scaling Explorations team. Installed they use about %@ on this phone.",
                comment: "ZK download consent body"), download, installed)))
        stack.addArrangedSubview(PresentationUI.card(
            title: NSLocalizedString("What it means", comment: "ZK download consent"),
            body: NSLocalizedString(
                "The files stay on your phone and are downloaded once. They are the tools that create and check proofs — they contain nothing about you.",
                comment: "ZK download consent meaning")))

        var configuration = UIButton.Configuration.filled()
        configuration.title = String(format: NSLocalizedString(
            "Download %@ and continue", comment: "ZK download consent button"), download)
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.onConsent() }, for: .touchUpInside)
        stack.addArrangedSubview(button)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Bonds.Space.page),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Bonds.Space.xxl),
        ])
        NSLayoutConstraint.activate(Bonds.readableHorizontal(stack, in: scroll.frameLayoutGuide))
    }
}
