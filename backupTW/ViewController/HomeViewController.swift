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
    }

    private let sections = [
        Section(title: "🔐 " + NSLocalizedString("Valid Document", comment: ""), items: [
            Item(title: Row.backUp,
                 secondaryText: NSLocalizedString("with Taiwan's official MyData service", comment: ""))
        ]),
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
                 secondaryText: NSLocalizedString("Check a proof file. Needs the large checking files on this phone.", comment: ""))
        ])
    ]

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

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            var content = cell.defaultContentConfiguration()
            // `Item` has carried an image since it was written and this screen
            // silently dropped it — the offline rows shipped iconless next to a
            // Settings list where the same struct draws icons fine. Found by
            // looking at the screen, which is the only way this class of defect
            // is ever found.
            content.image = item.image
            content.text = item.title
            content.attributedText = NSAttributedString(
                string: item.title,
                attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)]
            )
            content.secondaryAttributedText = NSAttributedString(
                string: item.secondaryText,
                attributes: [.foregroundColor: UIColor.secondaryLabel,
                             .font: UIFont.preferredFont(forTextStyle: .subheadline)
                            ]
            )
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<CustomHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { headerView, elementKind, indexPath in
            let section = self.sections[indexPath.section]
            headerView.configure(title: section.title, forTextStyle: .title2)
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
