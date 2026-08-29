//
//  SettingsViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/7/30.
//

import UIKit

private let reuseIdentifier = "SettingsCell"

class SettingsViewController: UICollectionViewController {

    private static let versionString: String = {
        return NSLocalizedString("Version", comment: "") + " "
        + (Bundle.main.infoDictionary?["CFBundleShortVersionString"]
           as? String ?? NSLocalizedString("Unknown", comment: ""))
        + " ("
        + (Bundle.main.infoDictionary?["CFBundleVersion"]
           as? String ?? NSLocalizedString("Unknown", comment: ""))
        + ")"
    }()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    /// Row identity is matched on `title` rather than index, because
    /// `didSelectItemAt` previously keyed off `indexPath.row == 1` and adding a
    /// section above it would have silently pointed the License row at whatever
    /// landed in that slot.
    private enum Row {
        static let license = NSLocalizedString("License", comment: "")
        static let diagnostics = NSLocalizedString("Diagnostics", comment: "")
        static let eraseEverything = NSLocalizedString("Erase all local data", comment: "")
        static let minimalDisclosure = NSLocalizedString("Minimal disclosure", comment: "ZK proof screen title")
        static let capabilities = NSLocalizedString("What this app can prove", comment: "")
        static let updateBackup = NSLocalizedString("Update my ID backup", comment: "settings, self-issued national ID")
        static let trust = NSLocalizedString("Trust", comment: "settings row / screen: trust")
    }

    /// A national ID is stored, so its backup can be refreshed. Home shows the
    /// 「create」 invitation only while empty; once a document exists, refreshing it
    /// is rare housekeeping and lives here instead (per the card-exists → Settings
    /// rule).
    private var hasStoredNationalID: Bool {
        guard let store = try? CredentialStore() else { return false }
        return CardInventory.rows(from: store).contains { $0.source == .selfIssued }
    }

    private var sections: [Section] {
        var support: [Item] = [
            Item(image: UIImage(systemName: "info.circle.fill")?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
                 title: NSLocalizedString("About Bond", comment: ""),
                 secondaryText: Self.versionString),
            // `PresentationScenario` documents itself as the table 「the screen
            // renders」 — and had no screen. Same defect as `LocalDataEraser`
            // below: implemented, unreachable, and therefore a promise the
            // source keeps and the product does not. This is the entrance.
            Item(image: UIImage(systemName: "checklist")?.withTintColor(.systemTeal, renderingMode: .alwaysOriginal),
                 title: Row.capabilities,
                 secondaryText: NSLocalizedString("The three things people ask this app to prove, and which of them come with a limit.", comment: "")),
            Item(image: UIImage(systemName: "doc.text"),
                 title: Row.license,
                 secondaryText: NSLocalizedString("Third Party Software License", comment: ""))
        ]
        if hasStoredNationalID {
            support.insert(
                Item(image: UIImage(systemName: "arrow.clockwise")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                     title: Row.updateBackup,
                     secondaryText: NSLocalizedString("Fetch it again from Taiwan's MyData service and replace what's stored.", comment: "")),
                at: 0)
        }
        return [
        Section(title: NSLocalizedString("Support and About", comment: ""), items: support),
        Section(title: Row.trust, items: [
            Item(image: UIImage(systemName: "checkmark.shield.fill")?.withTintColor(.systemGreen, renderingMode: .alwaysOriginal),
                 title: Row.trust,
                 secondaryText: NSLocalizedString("The issuers this app trusts, and how their fields are named.", comment: ""))
        ]),
        // `LocalDataEraser` has existed with no caller: the promise that a user
        // can remove their identity from the phone was implemented but
        // unreachable. This is the control that makes it true.
        Section(title: NSLocalizedString("Data and Privacy", comment: ""), items: [
            // The three guarantees below cannot be observed in a simulator, so
            // there needs to be somewhere on the phone that reports them.
            Item(image: UIImage(systemName: "stethoscope")?.withTintColor(.systemTeal, renderingMode: .alwaysOriginal),
                 title: Row.diagnostics,
                 secondaryText: NSLocalizedString("See this phone's security status and your card details.", comment: "")),
            Item(image: UIImage(systemName: "trash")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal),
                 title: Row.eraseEverything,
                 secondaryText: NSLocalizedString("Removes your credentials, the documents they came from, and the key that identifies you.", comment: ""))
        ]),
        // 「Experimental」 (the zero-knowledge minimal-disclosure proof) now lives in
        // the 使用 tab's 🧪 實驗中 section, next to the other verification verbs,
        // rather than alone in Settings — so it is no longer a section here.
        ]
    }

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("Settings", comment: "")
        navigationController?.navigationBar.prefersLargeTitles = true
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)

        configureDataSource()
        applySnapshot()
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            var content = cell.defaultContentConfiguration()
            content.image = item.image
            // Plain text with `textProperties`, not attributed strings: an
            // attributed font is frozen at configure time, so a mid-session
            // Dynamic Type change reflowed every label in the app except these.
            content.text = item.title
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = item.secondaryText
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { headerView, elementKind, indexPath in
            let section = self.sections[indexPath.section]
            var content = headerView.defaultContentConfiguration()
            content.text = section.title
            headerView.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }
            return nil
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for section in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(section.items)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

// MARK: UICollectionViewDelegate

extension SettingsViewController {

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item.title {
        case Row.updateBackup:
            let vc = MyDataOnboardViewController()
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case Row.trust:
            navigationController?.pushViewController(TrustCenterViewController(), animated: true)
        case Row.license:
            navigationController?.pushViewController(LicenseViewController(), animated: true)
        case Row.capabilities:
            navigationController?.pushViewController(CapabilityViewController(), animated: true)
        case Row.diagnostics:
            navigationController?.pushViewController(DiagnosticsViewController(), animated: true)
        case Row.eraseEverything:
            confirmEraseEverything(from: indexPath)
        default:
            break
        }
    }

    /// Names what goes, including the identifier — a user who taps "delete
    /// everything" and silently keeps their DID has been misled, and the whole
    /// point of the erase is that the next presentation cannot be linked to the
    /// previous one.
    private func confirmEraseEverything(from indexPath: IndexPath? = nil) {
        let alert = UIAlertController(
            title: NSLocalizedString("Erase all local data?", comment: ""),
            message: NSLocalizedString("Your credentials, the source documents, and your device key will be deleted. The next document you create will use a new identifier and cannot be linked to the current one. This cannot be undone.", comment: ""),
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Erase", comment: ""),
                                      style: .destructive) { [weak self] _ in
            self?.eraseEverything()
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        // An action sheet without a source on iPad raises rather than falling
        // back to a popover anchored anywhere sensible.
        if let popover = alert.popoverPresentationController {
            popover.sourceView = collectionView
            // Anchored to the row that was tapped, so the iPad popover's arrow
            // points at the action it belongs to instead of the whole list.
            popover.sourceRect = indexPath.flatMap { collectionView.cellForItem(at: $0)?.frame }
                ?? collectionView.bounds
        }
        present(alert, animated: true)
    }

    private func eraseEverything() {
        // Keychain and file deletion are both blocking; on a device holding a
        // large unpacked household record this is long enough to drop a frame.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LocalDataEraser().eraseEverything() }
            DispatchQueue.main.async { [weak self] in
                self?.presentEraseResult(result)
            }
        }
    }

    private func presentEraseResult(_ result: Result<Void, Error>) {
        let alert: UIAlertController
        switch result {
        case .success:
            alert = UIAlertController(
                title: NSLocalizedString("Local data erased", comment: ""),
                message: nil, preferredStyle: .alert)
        case .failure(let error):
            // Reporting partial failure matters more than tidiness here: a user
            // told "erased" while something survived will act on a false belief.
            alert = UIAlertController(
                title: NSLocalizedString("Some data could not be erased", comment: ""),
                message: error.localizedDescription,
                preferredStyle: .alert)
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Confirm", comment: ""), style: .default))
        present(alert, animated: true)
    }
}
