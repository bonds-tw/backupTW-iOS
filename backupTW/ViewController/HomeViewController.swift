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
    private let sections = [
        Section(title: "🔐 " + NSLocalizedString("Valid Document", comment: ""), items: [
            Item(title: NSLocalizedString("Back up my national ID", comment: ""),
                 secondaryText: NSLocalizedString("with Taiwan's official MyData service", comment: ""))
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
        let vc = MyDataOnboardViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
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
