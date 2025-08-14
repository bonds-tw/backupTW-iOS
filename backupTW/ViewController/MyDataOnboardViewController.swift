//
//  MyDataOnboardViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/8/11.
//

import UIKit

private let reuseIdentifier = "MyDataOnboardCell"

class MyDataOnboardViewController: UICollectionViewController {

    private var isMobileMoicaReady: Bool {
        let mobileMoicaURLScheme = "mobilemoica://"
        let mobileMoicaURL = URL(string: mobileMoicaURLScheme)!
        let isMobileMoicaReady = UIApplication.shared.canOpenURL(mobileMoicaURL)
        return isMobileMoicaReady
    }

    private enum Section: Int, CaseIterable {
        case cover, data
    }
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var coverItem: Item = Item(
        title: "📋\n" + NSLocalizedString("Create a Valid Document", comment: ""),
        secondaryText: NSLocalizedString("You will use TW FiDO to retrieve your National ID data, and create a valid document.", comment: ""))
    private var items: [Item] = [
        Item(title: NSLocalizedString("Nationality", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Unified No.", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Name", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Birth date", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Address of household", comment: ""), secondaryText: ""),
    ]

    init() {
        let layout = UICollectionViewCompositionalLayout() { sectionIndex, layoutEnvironment in
            let shouldShowHeaderFooter = (sectionIndex != 0)
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = shouldShowHeaderFooter ? .supplementary : .none
            configuration.footerMode = shouldShowHeaderFooter ? .supplementary : .none
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: layoutEnvironment)
            return section
        }
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("Valid Document", comment: "")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Continue", comment: ""), style: .done, target: self, action: #selector(nextAction))
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)
        collectionView.allowsSelection = false

        configureDataSource()
        applySnapshot()
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            var content = UIListContentConfiguration.valueCell()
            let isCover = (indexPath.section == Section.cover.rawValue)
            let textStyle: UIFont.TextStyle = isCover ? .largeTitle : .headline
            let secondaryStyle: UIFont.TextStyle = isCover ? .body : .subheadline
            content.textProperties.alignment = isCover ? .center : .natural
            content.secondaryTextProperties.alignment = isCover ? .center : .natural
            content.textToSecondaryTextVerticalPadding = isCover ? 12.0 : 3.0
            let title = NSMutableAttributedString(
                string: item.title,
                attributes: [.font: UIFont.preferredFont(forTextStyle: textStyle)]
            )
            if isCover {
                title.addAttribute(.font, value: UIFont.systemFont(ofSize: 60), range: NSRange(location: 0, length: 2)) // for the emoji
            }
            content.attributedText = title
            content.secondaryAttributedText = NSAttributedString(
                string: item.secondaryText,
                attributes: [.foregroundColor: UIColor.secondaryLabel,
                             .font: UIFont.preferredFont(forTextStyle: secondaryStyle)]
            )
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { headerView, elementKind, indexPath in
            var content = headerView.defaultContentConfiguration()
            content.text = NSLocalizedString("Document information", comment: "")
            headerView.contentConfiguration = content
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { footerView, elementKind, indexPath in
            var content = footerView.defaultContentConfiguration()
            content.text = NSLocalizedString("All information are stored only on your phone.", comment: "")
            footerView.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            } else {
                return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
            }
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.cover])
        snapshot.appendItems([coverItem])
        snapshot.appendSections([.data])
        for item in items {
            snapshot.appendItems([item])
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func nextAction() {
        if isMobileMoicaReady {
            let vc = MyDataWebViewController(completion: { [weak self] nationalIDModel in
                self?.coverItem = Item(
                    title: "✅\n" + NSLocalizedString("The valid document has been created", comment: ""),
                    secondaryText: "")
                self?.items = [
                    Item(title: NSLocalizedString("Nationality", comment: ""),
                         secondaryText: nationalIDModel.nationality ?? NSLocalizedString("Unknown", comment: "")),
                    Item(title: NSLocalizedString("Unified No.", comment: ""),
                         secondaryText: nationalIDModel.unifiedNo ?? NSLocalizedString("Unknown", comment: "")),
                    Item(title: NSLocalizedString("Name", comment: ""),
                         secondaryText: nationalIDModel.name ?? NSLocalizedString("Unknown", comment: "")),
                    Item(title: NSLocalizedString("Birth date", comment: ""),
                         secondaryText: nationalIDModel.birthdate ?? NSLocalizedString("Unknown", comment: "")),
                    Item(title: NSLocalizedString("Address of household", comment: ""),
                         secondaryText: nationalIDModel.addressOfHousehold ?? NSLocalizedString("Unknown", comment: "")),
                ]
                self?.applySnapshot()
                self?.navigationItem.leftBarButtonItem = nil
                self?.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self?.cancel))
            })
            present(vc, animated: true)
        } else {
            let alert = UIAlertController(
                title: NSLocalizedString("Please apply for TW FidO first", comment: ""),
                message: nil, preferredStyle: .alert)
            let confirm = UIAlertAction(
                title: NSLocalizedString("Go to Application Guide", comment: ""),
                style: .default) { _ in
                    let mobileMoicaOnboarding = "https://fido.moi.gov.tw/pt/teaching"
                    let mobileMoicaOnboardingURL = URL(string: mobileMoicaOnboarding)!
                    UIApplication.shared.open(mobileMoicaOnboardingURL)
                }
            let cancel = UIAlertAction(
                title: NSLocalizedString("Cancel", comment: ""),
                style: .cancel)
            alert.addAction(confirm)
            alert.addAction(cancel)
            present(alert, animated: true)
        }
    }
}
