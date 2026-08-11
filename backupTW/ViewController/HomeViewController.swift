//
//  HomeViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/6/7.
//

import UIKit

private let reuseIdentifier = "HomeCell"

class HomeViewController: UICollectionViewController {

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    /// Rows are matched on `title`, never on `indexPath`.
    ///
    /// `didSelectItemAt` used to push the onboarding screen for any tap at all,
    /// which was correct while there was exactly one row and silently wrong the
    /// moment a second section appeared below it — the same trap
    /// `SettingsViewController` documents, arrived at from the other direction.
    private enum Row {
        static let backUp = NSLocalizedString("Back up my national ID", comment: "")
        static let present = NSLocalizedString("Show my document", comment: "")
        static let verify = NSLocalizedString("Check someone else's document", comment: "")
        static let verifyProof = NSLocalizedString("Check a zero-knowledge proof", comment: "")
        static let myDocument = NSLocalizedString("My identity document", comment: "")
    }

    /// Recomputed on every appearance rather than stored once at init.
    ///
    /// This screen used to be a `let` constant, which is why finishing the
    /// MyData flow left no trace on it: the credential was saved, the home
    /// screen never read the store, and the app looked untouched. A person who
    /// has just handed over their household record and sees no sign of it has
    /// every reason to think it failed — and to do it again.
    private var sections: [Section] {
        [validDocumentSection, offlineSection]
    }

    private var validDocumentSection: Section {
        let title = "🔐 " + NSLocalizedString("Valid Document", comment: "")
        guard let stored = StoredNationalID.load() else {
            return Section(title: title, items: [
                Item(title: Row.backUp,
                     secondaryText: NSLocalizedString("with Taiwan's official MyData service", comment: ""))
            ])
        }
        // Named fields are *not* summarised here. A home screen is the most
        // over-the-shoulder-readable surface in the app, and this document
        // carries a national ID number and a home address; the count and the
        // date say it worked without putting either on a screen that gets
        // glanced at in public.
        return Section(title: title, items: [
            Item(image: UIImage(systemName: "checkmark.seal.fill")?
                    .withTintColor(.systemGreen, renderingMode: .alwaysOriginal),
                 title: Row.myDocument,
                 secondaryText: String(format: NSLocalizedString(
                    "%d fields · created %@", comment: "credential summary"),
                    stored.claims.count, stored.createdDescription())),
            Item(image: UIImage(systemName: "arrow.clockwise")?
                    .withTintColor(.systemGray, renderingMode: .alwaysOriginal),
                 title: Row.backUp,
                 secondaryText: NSLocalizedString("Fetch it again and replace what's stored.", comment: ""))
        ])
    }

    private var offlineSection: Section {
        // Both halves live on the home screen rather than one of them being
        // buried in Settings. The whitepaper's §5.3 scenarios are a 里長, a
        // volunteer, a border desk — people who are checking documents as their
        // task, not adjusting a preference — and the two roles swap between the
        // same two phones within a minute of each other.
        Section(title: "📶 " + NSLocalizedString("Offline check", comment: ""), items: [
            Item(image: UIImage(systemName: "qrcode")?
                    .withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
                 title: Row.present,
                 secondaryText: NSLocalizedString("Answer a checker's code. Works with no network on either phone.", comment: "")),
            Item(image: UIImage(systemName: "checkmark.shield")?
                    .withTintColor(.systemTeal, renderingMode: .alwaysOriginal),
                 title: Row.verify,
                 secondaryText: NSLocalizedString("Check a document someone shows you, without contacting any server.", comment: "")),
            // The proof half of the checker's job, next to the credential half
            // rather than in Settings, for the reason above: the 里長 and the
            // border desk are doing one task, and which kind of thing they were
            // handed is not their problem to route.
            Item(image: UIImage(systemName: "eye.slash")?
                    .withTintColor(.systemPurple, renderingMode: .alwaysOriginal),
                 title: Row.verifyProof,
                 secondaryText: Self.proofRowSubtitle())
        ])
    }

    /// Whether this phone can actually check a proof, said on the row itself.
    ///
    /// The generic sentence sent people into the screen to find out; the state
    /// was knowable from here. Both variants state a *local* fact — files
    /// present or files missing — and neither implies anything about any proof
    /// being valid: readiness is not a verdict, so no tick, no colour.
    private static func proofRowSubtitle() -> String {
        let ready = (try? CircuitAssets.defaultDirectory()).map { directory in
            CircuitAssets.required.allSatisfy { asset in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(asset.localFilename).path)
            }
        } ?? false
        return ready
            ? NSLocalizedString("Check a proof file. The checking files are on this phone.", comment: "")
            : NSLocalizedString("Check a proof file. The large checking files are not downloaded yet.", comment: "")
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

        title = NSLocalizedString("Bond", comment: "")
        navigationController?.navigationBar.prefersLargeTitles = true
        // different title for tabBarItem needs to be set after setting title (avoid being overwritten)
        tabBarItem = UITabBarItem(title: NSLocalizedString("Home", comment: ""),
                                  image: UIImage(systemName: "house.fill"), selectedImage: nil)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)

        configureDataSource()
        applySnapshot()
    }

    /// Reapplied on every appearance, not just at load.
    ///
    /// The MyData flow is presented modally and issues the credential in the
    /// background as it dismisses, so the moment this screen comes back is the
    /// first moment there is anything new to show. Without this the fix above
    /// would only take effect on the next cold launch, which is indistinguishable
    /// from the bug.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            var content = cell.defaultContentConfiguration()
            // `Item` has carried an image since it was written and this screen
            // silently dropped it — the offline rows shipped iconless next to a
            // Settings list where the same struct draws icons fine. Found by
            // looking at the screen, which is the only way this class of defect
            // is ever found.
            content.image = item.image
            // Plain text with `textProperties` — an attributed font is frozen
            // at configure time and ignores mid-session Dynamic Type changes.
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
        let headerRegistration = UICollectionView.SupplementaryRegistration<CustomHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, elementKind, indexPath in
            // From the snapshot the data source is showing, not from
            // `self.sections` — the computed property re-reads the credential
            // store (a Keychain round trip) on every header dequeue, and its
            // answer could disagree with what the rows on screen were built
            // from. The strong `self` capture was also a retain cycle.
            guard let dataSource = self?.dataSource else { return }
            let sections = dataSource.snapshot().sectionIdentifiers
            guard indexPath.section < sections.count else { return }
            headerView.configure(title: sections[indexPath.section].title, forTextStyle: .title2)
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

extension HomeViewController {

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item.title {
        case Row.backUp:
            let vc = MyDataOnboardViewController()
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case Row.present:
            navigationController?.pushViewController(PresentCredentialViewController(), animated: true)
        case Row.verify:
            navigationController?.pushViewController(VerifierViewController(), animated: true)
        case Row.verifyProof:
            navigationController?.pushViewController(ZKVerifyViewController(), animated: true)
        case Row.myDocument:
            navigationController?.pushViewController(StoredCredentialViewController(), animated: true)
        default:
            break
        }
    }
}

// MARK: -

private class CustomHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    func configure(title: String, forTextStyle style: UIFont.TextStyle) {
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: style)
    }
}
