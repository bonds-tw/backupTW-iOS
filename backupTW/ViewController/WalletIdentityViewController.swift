//
//  WalletIdentityViewController.swift
//  backupTW
//

import UIKit

/// Shows the DID owned by this installation, without implying that it identifies
/// the person holding the phone.
final class WalletIdentityViewController: UICollectionViewController {

    private enum Section: Hashable { case identity, explanation }
    private enum Item: Hashable {
        case did(String)
        case backing(String)
        case note(String)
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var walletDID: String?
    private var backingDescription = NSLocalizedString("Unavailable", comment: "wallet identity key status")

    init() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Wallet identity", comment: "settings screen title")
        navigationController?.navigationBar.prefersLargeTitles = false
        collectionView.allowsSelection = false
        loadIdentity()
        configureDataSource()
        applySnapshot()
    }

    private func loadIdentity() {
        do {
            let key = try WalletIdentity.key()
            walletDID = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
            backingDescription = key.isHardwareBacked
                ? NSLocalizedString("Secure Enclave", comment: "wallet identity key backing")
                : NSLocalizedString("Protected by iOS Keychain", comment: "wallet identity key backing")
        } catch {
            walletDID = nil
            backingDescription = NSLocalizedString("The wallet identity is unavailable while this device is locked.", comment: "")
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.subtitleCell()
            switch item {
            case .did(let did):
                content.text = NSLocalizedString("有備而來 did:key", comment: "wallet identity field")
                content.secondaryText = did
                content.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .footnote)
                    .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
                content.secondaryTextProperties.numberOfLines = 0
                content.image = UIImage(systemName: "key.horizontal.fill")?
                    .withTintColor(.systemIndigo, renderingMode: .alwaysOriginal)
            case .backing(let value):
                content.text = NSLocalizedString("Private key", comment: "wallet identity field")
                content.secondaryText = value
                content.image = UIImage(systemName: "lock.shield.fill")?
                    .withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
            case .note(let note):
                content.text = note
                content.textProperties.color = .secondaryLabel
                content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            }
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessories = []
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            let sections = self?.dataSource.snapshot().sectionIdentifiers ?? []
            var content = view.defaultContentConfiguration()
            if indexPath.section < sections.count {
                content.text = sections[indexPath.section] == .identity
                    ? NSLocalizedString("This installation", comment: "wallet identity section")
                    : NSLocalizedString("What it means", comment: "wallet identity section")
            }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : nil
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.identity])
        if let walletDID {
            snapshot.appendItems([.did(walletDID), .backing(backingDescription)], toSection: .identity)
        } else {
            snapshot.appendItems([.backing(backingDescription)], toSection: .identity)
        }
        snapshot.appendSections([.explanation])
        snapshot.appendItems([.note(NSLocalizedString(
            "This DID names this installation of 有備而來, not you. Each national ID and government card uses its own key so one card's DID does not identify the others.",
            comment: "wallet identity explanation"))], toSection: .explanation)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

}
