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
    private let sections = [
        Section(title: NSLocalizedString("Support and About", comment: ""), items: [
            Item(image: UIImage(systemName: "info.circle.fill")?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
                 title: NSLocalizedString("About Bond", comment: ""),
                 secondaryText: versionString),
            Item(image: UIImage(systemName: "doc.text"),
                 title: NSLocalizedString("License", comment: ""),
                 secondaryText: NSLocalizedString("Third Party Software License", comment: ""))
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
        if indexPath.row == 1 {
            let vc = LicenseViewController()
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}
