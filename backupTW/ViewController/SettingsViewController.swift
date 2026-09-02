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
        static let about = NSLocalizedString("About Bond", comment: "")
        static let license = NSLocalizedString("License", comment: "")
        static let diagnostics = NSLocalizedString("Diagnostics", comment: "")
        static let eraseEverything = NSLocalizedString("Erase all local data", comment: "")
        static let minimalDisclosure = NSLocalizedString("Minimal disclosure", comment: "ZK proof screen title")
        static let capabilities = NSLocalizedString("What this app can prove", comment: "")
        static let updateBackup = NSLocalizedString("Update my ID backup", comment: "settings, self-issued national ID")
        static let trust = NSLocalizedString("Trust", comment: "settings row / screen: trust")
        static let walletIdentity = NSLocalizedString("Wallet identity", comment: "settings row")
    }

    private var sections: [Section] {
        let support: [Item] = [
            Item(image: UIImage(systemName: "info.circle.fill"),
                 title: NSLocalizedString("About Bond", comment: ""),
                 secondaryText: Self.versionString),
            // `PresentationScenario` documents itself as the table 「the screen
            // renders」 — and had no screen. Same defect as `LocalDataEraser`
            // below: implemented, unreachable, and therefore a promise the
            // source keeps and the product does not. This is the entrance.
            Item(image: UIImage(systemName: "checklist"),
                 title: Row.capabilities,
                 secondaryText: NSLocalizedString("The three things people ask this app to prove, and which of them come with a limit.", comment: "")),
            Item(image: UIImage(systemName: "doc.text"),
                 title: Row.license,
                 secondaryText: NSLocalizedString("Third Party Software License", comment: ""))
        ]
        // 「Update my ID backup」 no longer lives here. It used to *appear* in
        // Settings the moment a card existed while vanishing from Home — an
        // entrance that moves teaches the reader that buttons are unreliable
        // (design system §10.4). Its one stable home is the document's own
        // detail screen, where deleting lives too.
        return [
        Section(title: NSLocalizedString("Support and About", comment: ""), items: support),
        Section(title: Row.trust, items: [
            Item(image: UIImage(systemName: "key.horizontal.fill"),
                 title: Row.walletIdentity,
                 secondaryText: NSLocalizedString("The did:key owned by this installation of 有備而來.", comment: "settings wallet identity subtitle")),
            Item(image: UIImage(systemName: "checkmark.shield.fill"),
                 title: Row.trust,
                 secondaryText: NSLocalizedString("The issuers this app trusts, and how their fields are named.", comment: ""))
        ]),
        // `LocalDataEraser` has existed with no caller: the promise that a user
        // can remove their identity from the phone was implemented but
        // unreachable. This is the control that makes it true.
        Section(title: NSLocalizedString("Data and Privacy", comment: ""), items: [
            // The three guarantees below cannot be observed in a simulator, so
            // there needs to be somewhere on the phone that reports them.
            Item(image: UIImage(systemName: "stethoscope"),
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
            // Template icons take the app accent — one interactive colour across
            // every row, per the design system (docs/design-system.md §2). Rows
            // with a semantic colour of their own (the destructive trash) bake it
            // with `.alwaysOriginal`, which this tint cannot override.
            content.imageProperties.tintColor = .tintColor
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
        case Row.about:
            // The row always looked tappable (it is a list cell) and did
            // nothing — a dead control (回報 2026-09-02).
            navigationController?.pushViewController(AboutViewController(), animated: true)
        case Row.trust:
            navigationController?.pushViewController(TrustCenterViewController(), animated: true)
        case Row.walletIdentity:
            navigationController?.pushViewController(WalletIdentityViewController(), animated: true)
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

    static var versionText: String { versionString }

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
        // 「好」, not 「確認」: this button only acknowledges a result. 「確認」 is
        // reserved for buttons that make something happen (design system §11.1).
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - About

/// 設定 › 關於有備而來. What this app is, in its own words, with the places it
/// lives — the row always looked tappable and used to lead nowhere.
final class AboutViewController: UICollectionViewController {

    private enum Item: Hashable {
        case fact(title: String, value: String)
        case link(title: String, subtitle: String, url: String)
        case note(String)
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("About Bond", comment: "")
        navigationItem.largeTitleDisplayMode = .never

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = cell.defaultContentConfiguration()
            cell.accessories = []
            switch item {
            case let .fact(title, value):
                content.text = title
                content.secondaryText = value
                content.secondaryTextProperties.color = .secondaryLabel
            case let .link(title, subtitle, _):
                content.text = title
                content.textProperties.color = .tintColor
                content.secondaryText = subtitle
                content.secondaryTextProperties.color = .secondaryLabel
                content.secondaryTextProperties.font = Bonds.Font.mono(.footnote)
                content.image = UIImage(systemName: "arrow.up.right")
                content.imageProperties.tintColor = .tintColor
            case let .note(text):
                content.text = text
                content.textProperties.color = .secondaryLabel
                content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([
            .note(NSLocalizedString(
                "A civic backup wallet for Taiwan: keep a copy of your identity on your own phone, show it offline, and reveal only what a check actually needs.",
                comment: "about: what this app is")),
            .fact(title: NSLocalizedString("Version", comment: ""),
                  value: SettingsViewController.versionText),
        ], toSection: 0)
        snapshot.appendItems([
            .link(title: NSLocalizedString("Website", comment: "about link"),
                  subtitle: "bonds.tw", url: "https://bonds.tw"),
            .link(title: NSLocalizedString("Source code", comment: "about link"),
                  subtitle: "github.com/mashbean/backupTW-iOS",
                  url: "https://github.com/mashbean/backupTW-iOS"),
        ], toSection: 1)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case let .link(_, _, urlString) = dataSource.itemIdentifier(for: indexPath),
              let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
