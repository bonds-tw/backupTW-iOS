//
//  TrustRecordDetailViewController.swift
//  backupTW
//

import UIKit

/// A user-visible audit trail joining one trust-list API entry to the exact
/// Arbitrum transaction the API claims anchored it.
final class TrustRecordDetailViewController: UICollectionViewController {

    private struct Row: Hashable {
        let id: String
        let title: String
        let value: String
        let url: URL?
    }
    private enum Section: Hashable { case main }

    private let issuer: TWDIWIssuer
    private let verification: TWDIWOnChainVerification?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    init(issuer: TWDIWIssuer, verification: TWDIWOnChainVerification?) {
        self.issuer = issuer
        self.verification = verification
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Trust record", comment: "trust record detail title")
        configureDataSource()
        applySnapshot()
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.subtitleCell()
            cell.accessories = []
            content.text = row.title
            content.secondaryText = row.value
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = .secondaryLabel
            if row.id.contains("did") || row.id.contains("contract") || row.id.contains("transaction") {
                content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            }
            if row.url != nil {
                content.textProperties.color = .tintColor
                cell.accessories = [.disclosureIndicator()]
            }
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = row.id
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Row>(collectionView: collectionView) {
            view, indexPath, row in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
    }

    private func applySnapshot() {
        var rows: [Row] = [
            Row(id: "status", title: NSLocalizedString("Integrity check", comment: ""),
                value: statusDescription, url: nil),
            Row(id: "did", title: "did:key", value: issuer.did, url: nil),
        ]
        if let updatedAt = issuer.apiUpdatedAt {
            rows.append(Row(id: "api.updated", title: NSLocalizedString("API record updated", comment: ""),
                            value: DateFormatter.localizedString(from: updatedAt,
                                                                 dateStyle: .medium,
                                                                 timeStyle: .medium), url: nil))
        }
        let apiURL = URL(string: "https://frontend.wallet.gov.tw/api/did")?
            .appendingPathComponent(issuer.did)
        rows.append(Row(id: "api.open", title: NSLocalizedString("Open official API record", comment: ""),
                        value: apiURL?.absoluteString ?? "", url: apiURL))

        if let record = issuer.onChainRecords.last {
            rows.append(Row(id: "contract", title: NSLocalizedString("Registry contract", comment: ""),
                            value: record.contractAddress, url: nil))
            rows.append(Row(id: "transaction", title: NSLocalizedString("Transaction hash", comment: ""),
                            value: record.transactionHash, url: nil))
            let explorer = URL(string: "https://arbiscan.io/tx/\(record.transactionHash)")
            rows.append(Row(id: "transaction.open", title: NSLocalizedString("Open blockchain record", comment: ""),
                            value: NSLocalizedString("Arbiscan · Arbitrum One", comment: ""), url: explorer))
        } else {
            rows.append(Row(id: "transaction.none", title: NSLocalizedString("Blockchain record", comment: ""),
                            value: NSLocalizedString("The official API does not report an anchor for this entry.", comment: ""),
                            url: nil))
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.main])
        snapshot.appendItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private var statusDescription: String {
        switch verification {
        case .verified:
            return NSLocalizedString(
                "Verified: the successful Arbitrum transaction contains the same DID, signed DID document, organisation record and category values as the official API.",
                comment: "")
        case .mismatch:
            return NSLocalizedString(
                "Not verified: the transaction, contract, receipt or recorded values differ from the official API.",
                comment: "")
        case .notAnchored:
            return NSLocalizedString("Not verified: this API entry has no blockchain record.", comment: "")
        case .unavailable:
            return NSLocalizedString("Not checked: Arbitrum could not be reached. The API record is still shown below.", comment: "")
        case nil:
            return NSLocalizedString("Checking the blockchain record…", comment: "")
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let url = dataSource.itemIdentifier(for: indexPath)?.url else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
