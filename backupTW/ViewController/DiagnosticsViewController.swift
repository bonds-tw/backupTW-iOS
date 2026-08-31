//
//  DiagnosticsViewController.swift
//  backupTW
//

import UIKit

/// Reports the facts that only a real device can settle.
///
/// Three of the guarantees this app makes are invisible in a simulator and
/// cannot be asserted in a test: whether the signing key is actually in the
/// Secure Enclave (the simulator has none, so the code path that matters never
/// runs), whether the stored credential really carries the file protection
/// class it was written with (protection is a no-op on the simulator's
/// filesystem), and whether the identifier presented to a verifier is the one
/// we think it is.
///
/// Without somewhere to read them, "verify on device" means launching the app,
/// seeing no crash, and assuming. This screen exists so those checks have an
/// answer that can be read off the phone and quoted.
final class DiagnosticsViewController: UICollectionViewController {

    private struct Row: Hashable {
        let title: String
        let value: String
        /// nil where there is nothing to judge — a fact, not a check.
        let passed: Bool?
        let opensAppAttestUAT: Bool

        init(title: String, value: String, passed: Bool?, opensAppAttestUAT: Bool = false) {
            self.title = title
            self.value = value
            self.passed = passed
            self.opensAppAttestUAT = opensAppAttestUAT
        }
    }

    private struct Group: Hashable {
        let title: String
        let rows: [Row]
    }

    private var dataSource: UICollectionViewDiffableDataSource<Group, Row>!
    private var groups: [Group] = []

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Diagnostics", comment: "")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain, target: self, action: #selector(copyReport))
        configureDataSource()
        reload()
    }

    // MARK: - Collection

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.value
            content.secondaryTextProperties.color = .secondaryLabel
            // Values are identifiers, paths and byte counts; proportional digits
            // make them hard to compare across launches.
            content.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .body)
                    // This screen exists so somebody can compare a 身分證統一編號
                    // and a 戶籍地址 character by character, and at AX5 the field
                    // *names* were 53pt while the values they label stayed at 12pt.
                    // Monospacing is kept — the digits still need to line up — it
                    // just scales now.
                    .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = row.opensAppAttestUAT
                ? "diagnostics.appAttestUAT"
                : nil
            // Spelled `.some(true)` rather than `true`: matching an Optional<Bool>
            // against boolean literals is only accepted as exhaustive by newer
            // compilers, and CI builds with an older Xcode than this machine has.
            switch row.passed {
            case .some(true):
                cell.accessories = [.customView(configuration: .init(
                    customView: Self.symbol("checkmark.circle.fill", .systemGreen), placement: .trailing()))]
            case .some(false):
                cell.accessories = [.customView(configuration: .init(
                    customView: Self.symbol("exclamationmark.triangle.fill", .systemOrange), placement: .trailing()))]
            case .none:
                cell.accessories = row.opensAppAttestUAT ? [.disclosureIndicator()] : []
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Group, Row>(collectionView: collectionView) {
            view, indexPath, row in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
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

    private func reload() {
        groups = Self.collect()
        var snapshot = NSDiffableDataSourceSnapshot<Group, Row>()
        for group in groups {
            snapshot.appendSections([group])
            snapshot.appendItems(group.rows, toSection: group)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func copyReport() {
        UIPasteboard.general.string = groups
            .map { group in
                ([group.title] + group.rows.map { "  \($0.title): \($0.value)" }).joined(separator: "\n")
            }
            .joined(separator: "\n\n")
        let alert = UIAlertController(title: NSLocalizedString("Copied", comment: ""),
                                      message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Confirm", comment: ""), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Facts

    private static func collect() -> [Group] {
        [selfCheckGroup(), appAttestUATGroup(), myDataGroup(), signingGroup(), storageGroup(), assetsGroup()]
    }

    private static func appAttestUATGroup() -> Group {
        Group(title: NSLocalizedString("Signing backend", comment: ""), rows: [
            Row(title: NSLocalizedString("App Attest UAT check", comment: "diagnostic screen title"),
                value: NSLocalizedString(
                    "Run a privacy-safe TestFlight check against the reviewed Cloudflare endpoint.",
                    comment: "App Attest UAT diagnostics entry"),
                passed: nil,
                opensAppAttestUAT: true)
        ])
    }

    /// The one measurement that decides the credential architecture.
    ///
    /// This app re-signs the MyData fields with the device key, and the only
    /// thing justifying that is the claim that the download carries no
    /// document-level signature. It was a claim, not a measurement. The scan now
    /// runs on the bytes as they pass through, and the answer lands here — a
    /// screen made for exactly this, facts a simulator cannot settle.
    ///
    /// `nil` is rendered as "not measured yet", never as "unsigned". Those are
    /// different answers and the second one would end the investigation.
    private static func myDataGroup() -> Group {
        let title = NSLocalizedString("MyData PDF signature", comment: "")
        guard let scan = PDFSignatureScan.lastRecorded() else {
            return Group(title: title, rows: [
                Row(title: NSLocalizedString("Document-level signature", comment: ""),
                    value: NSLocalizedString(
                        "Not measured yet — download your ID once and come back.", comment: ""),
                    passed: nil)
            ])
        }
        var rows = [Row(title: NSLocalizedString("Document-level signature", comment: ""),
                        value: scan.summary,
                        // No verdict either way: a signature being present is not
                        // a pass, and its absence is not a failure. It is the
                        // input to a design decision.
                        passed: nil)]
        // Keyed on the signature bytes, not on the dictionary. A document
        // prepared for signing and never signed has every marker and nothing to
        // verify, and sending that answer up as "carries its own trust root"
        // would start the wrong rebuild.
        if scan.hasSignatureBytes {
            rows.append(Row(
                title: NSLocalizedString("What this means", comment: ""),
                value: NSLocalizedString(
                    "The download carries its own trust root. Re-signing these fields with this phone's key is weaker than what arrived — the credential design should use the original signature.",
                    comment: ""),
                passed: nil))
        } else if scan.isSigned {
            rows.append(Row(
                title: NSLocalizedString("What this means", comment: ""),
                value: NSLocalizedString(
                    "An empty signature field is not a signature — there is nothing here to verify. Treat this the same as unsigned, and say so when reporting it.",
                    comment: ""),
                passed: nil))
        }
        return Group(title: title, rows: rows)
    }

    /// Put first, and phrased as verdicts rather than values.
    ///
    /// The raw facts below are for someone who already knows which value is
    /// supposed to be which. This section is for everyone else: it states
    /// whether each guarantee holds, and what it would mean if it did not.
    private static func selfCheckGroup() -> Group {
        Group(title: NSLocalizedString("Self-check", comment: ""),
              rows: SelfCheck.runAll().map { result in
            let value: String
            if let consequence = result.consequence {
                value = "\(result.detail)\n\(consequence)"
            } else {
                value = result.detail
            }
            let passed: Bool?
            switch result.verdict {
            case .passed: passed = true
            case .failed: passed = false
            case .informational: passed = nil
            }
            return Row(title: result.title, value: value, passed: passed)
        })
    }

    /// Observes; never creates.
    ///
    /// An earlier version called `loadOrCreate` to show the identifier, which
    /// both contradicted itself — reporting "not created yet" from the check
    /// above while printing a DID from the key it had just minted — and meant
    /// that opening this screen after an erase silently issued a new identity.
    /// A screen used to confirm what is on the device must not change what is
    /// on the device.
    private static func signingGroup() -> Group {
        var rows: [Row] = []
        let backing = try? DeviceKey.storedKeyBacking()
        switch backing {
        case .some(.secureEnclave):
            rows.append(Row(title: NSLocalizedString("Signing key", comment: ""),
                            value: "Secure Enclave", passed: true))
        case .some(let other):
            // On a device this is the finding, not a detail: the private scalar
            // is in the Keychain database rather than sealed in hardware, so a
            // Keychain dump can forge credentials under this DID.
            rows.append(Row(title: NSLocalizedString("Signing key", comment: ""),
                            value: "\(other) — expected Secure Enclave on a device",
                            passed: false))
        case .none:
            rows.append(Row(title: NSLocalizedString("Signing key", comment: ""),
                            value: NSLocalizedString("Not created yet", comment: ""), passed: nil))
            return Group(title: NSLocalizedString("Signing", comment: ""), rows: rows)
        }

        // `load`, not `loadOrCreate` — the comment above this function has said
        // so since the first version, and this line went on calling
        // `loadOrCreate` anyway. Opening a diagnostics screen after an erase
        // minted a fresh identity, and the row above would report "not created
        // yet" while this one printed the DID of the key it had just made.
        if let key = try? DeviceKey.load(),
           let did = try? DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963) {
            rows.append(Row(title: NSLocalizedString("Identifier", comment: ""), value: did, passed: nil))
        }
        return Group(title: NSLocalizedString("Signing", comment: ""), rows: rows)
    }

    private static func storageGroup() -> Group {
        var rows: [Row] = []
        guard let store = try? CredentialStore() else {
            return Group(title: NSLocalizedString("Storage", comment: ""),
                         rows: [Row(title: NSLocalizedString("Credential store", comment: ""),
                                    value: NSLocalizedString("Unavailable", comment: ""), passed: false)])
        }
        let ids = (try? store.allIDs()) ?? []
        rows.append(Row(title: NSLocalizedString("Stored credentials", comment: ""),
                        value: "\(ids.count)", passed: nil))

        // Read the class back off the filesystem rather than trusting the value
        // passed at write time — that is the whole point of checking on device.
        if let id = ids.first {
            // Via the store: identifiers are not filenames, and reconstructing
            // the path here reported "none" for a credential that is protected.
            let actual = try? store.reportedFileProtection(for: id)
            rows.append(Row(title: NSLocalizedString("File protection", comment: ""),
                            value: actual?.rawValue ?? NSLocalizedString("None reported", comment: ""),
                            passed: actual == .completeUnlessOpen))
        }

        let excluded = (try? store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup
        rows.append(Row(title: NSLocalizedString("Excluded from backup", comment: ""),
                        value: excluded.map { $0 ? "true" : "false" } ?? "unknown",
                        passed: excluded))

        // Documents should stay empty: the household PDF used to live here, and
        // the app no longer writes to it at all.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: documents.path))?.count ?? 0
            rows.append(Row(title: NSLocalizedString("Files in Documents", comment: ""),
                            value: "\(leftovers)", passed: leftovers == 0))
        }
        return Group(title: NSLocalizedString("Storage", comment: ""), rows: rows)
    }

    private static func assetsGroup() -> Group {
        let total = CircuitAssets.required.reduce(Int64(0)) { $0 + $1.installedByteCount }
        let formatter = ByteCountFormatter()
        return Group(title: NSLocalizedString("Verification files", comment: ""), rows: [
            Row(title: NSLocalizedString("Required files", comment: ""),
                value: "\(CircuitAssets.required.count)", passed: nil),
            Row(title: NSLocalizedString("Total size when installed", comment: ""),
                value: formatter.string(fromByteCount: total), passed: nil),
        ])
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath)?.opensAppAttestUAT == true else { return }
        navigationController?.pushViewController(AppAttestUATViewController(), animated: true)
    }
}
