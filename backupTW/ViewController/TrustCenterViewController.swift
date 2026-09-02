//
//  TrustCenterViewController.swift
//  backupTW
//
//  設定 › 信任. Two tabs behind one segmented control:
//   • 信任清單 — the issuers/verifiers on 數位發展部信任清單, fetched live.
//   • 欄位對照表 — how other issuers' machine field keys (id_number, address…) map
//     to the app's own human-readable words.
//

import UIKit

final class TrustCenterViewController: UICollectionViewController {

    private enum Tab: Int { case trustList, fieldMap }
    private enum Section: Hashable { case main }
    private enum Item: Hashable {
        case issuer(did: String, name: String, detail: String)
        case field(label: String, key: String)
        case note(String)
        /// The failed state's way out. 「Check your connection and reopen this
        /// screen」 asked the reader to do this row's job by hand — a network
        /// failure must carry its own retry (design system §8.1).
        case retry
    }
    private enum LoadState { case loading, loaded([TWDIWIssuer]), failed }

    private var selectedTab: Tab = .trustList
    private var trustState: LoadState = .loading
    private var chainResults: [String: TWDIWOnChainVerification] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private let segmented = UISegmentedControl(items: [
        NSLocalizedString("Trust list", comment: "trust center selectedTab"),
        NSLocalizedString("Field guide", comment: "trust center selectedTab"),
    ])

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Trust", comment: "settings row / screen: trust")
        // `.never` on this screen's own item — flipping the shared bar's
        // `prefersLargeTitles` used to leave Settings with a small title after
        // popping back (BondsDesign.swift §Navigation bar 政策).
        navigationItem.largeTitleDisplayMode = .never

        segmented.selectedSegmentIndex = 0
        segmented.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        navigationItem.titleView = segmented

        configureDataSource()
        applySnapshot()
        fetchTrustList()
    }

    @objc private func tabChanged() {
        selectedTab = Tab(rawValue: segmented.selectedSegmentIndex) ?? .trustList
        applySnapshot()
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = cell.defaultContentConfiguration()
            cell.accessories = []
            switch item {
            case let .issuer(did, name, detail):
                content.text = name
                let verification = self?.chainResults[did]
                content.secondaryText = detail + "\n" + Self.verificationSummary(verification)
                content.secondaryTextProperties.numberOfLines = 0
                content.secondaryTextProperties.color = .secondaryLabel
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
                let appearance = Self.verificationAppearance(verification)
                content.image = UIImage(systemName: appearance.symbol)?
                    .withTintColor(appearance.colour, renderingMode: .alwaysOriginal)
                cell.accessories = [.disclosureIndicator()]
            case let .field(label, key):
                // The app's own word leads; the machine key is the quiet detail.
                content.text = label
                content.secondaryText = key
                content.secondaryTextProperties.color = .secondaryLabel
                content.secondaryTextProperties.font = Bonds.Font.mono(.footnote)
                content.image = UIImage(systemName: "arrow.left.arrow.right")?
                    .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
            case let .note(text):
                content.text = text
                content.textProperties.color = .secondaryLabel
                content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            case .retry:
                content.text = NSLocalizedString("Try again", comment: "trust list retry")
                content.textProperties.color = .tintColor
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
                content.image = UIImage(systemName: "arrow.clockwise")
                content.imageProperties.tintColor = .tintColor
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.main])
        switch selectedTab {
        case .trustList:
            switch trustState {
            case .loading:
                snapshot.appendItems([.note(NSLocalizedString("Loading the trust list…", comment: ""))])
            case .failed:
                snapshot.appendItems([
                    .note(NSLocalizedString("The trust list could not be loaded. Check your connection, then try again.", comment: "trust list failed state")),
                    .retry,
                ])
            case .loaded(let issuers):
                snapshot.appendItems([.note(String(
                    format: NSLocalizedString("Loaded %d organisations from the official API. A green check means the API record is confirmed; a shield means its blockchain record also matches.", comment: "trust list status legend"),
                    issuers.count))])
                snapshot.appendItems(issuers.map {
                    // Head+tail so the did:key prefix and the distinguishing last
                    // characters both show (did:key:z6Mk…AbCd), not a tail-only slice.
                    let did = WalletCardMask.middleEllipsis($0.did)
                    let detail = $0.taxID.isEmpty ? did : "\(NSLocalizedString("Tax ID", comment: "")) \($0.taxID) · \(did)"
                    return .issuer(did: $0.did, name: $0.displayName.isEmpty ? $0.displayNameEnglish : $0.displayName, detail: detail)
                })
            }
        case .fieldMap:
            snapshot.appendItems([.note(NSLocalizedString("How other issuers' field names map to the words this app shows. Unknown fields are shown as the issuer named them, never as this app's own word.", comment: ""))])
            snapshot.appendItems(StoredNationalID.fieldLabelTable.map {
                .field(label: $0.label, key: $0.keys.first ?? "")
            })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func fetchTrustList() {
        Task { [weak self] in
            do {
                let issuers = try await TrustListFetcher(session: .shared).fetchAll()
                // A fresh list is a chance to keep the offline name book
                // current — the same book collections write to.
                IssuerNameBook.remember(issuers)
                await MainActor.run {
                    guard let self else { return }
                    self.trustState = .loaded(issuers)
                    if self.selectedTab == .trustList { self.applySnapshot() }
                }
                let verified = await TWDIWOnChainVerifier(session: .shared).verify(issuers)
                await MainActor.run {
                    guard let self else { return }
                    self.chainResults = verified
                    if self.selectedTab == .trustList { self.applySnapshot() }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.trustState = .failed
                    if self.selectedTab == .trustList { self.applySnapshot() }
                }
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if case .retry = dataSource.itemIdentifier(for: indexPath) {
            trustState = .loading
            applySnapshot()
            fetchTrustList()
            return
        }
        guard case let .issuer(did, _, _) = dataSource.itemIdentifier(for: indexPath),
              case .loaded(let issuers) = trustState,
              let issuer = issuers.first(where: { $0.did == did }) else { return }
        navigationController?.pushViewController(
            TrustRecordDetailViewController(issuer: issuer,
                                            verification: chainResults[did]),
            animated: true)
    }

    static func verificationSummary(_ result: TWDIWOnChainVerification?) -> String {
        switch result {
        case nil:
            return NSLocalizedString("Official API loaded · Checking Arbitrum…", comment: "")
        case .verified:
            return NSLocalizedString("Official API connected · Blockchain integrity also verified", comment: "")
        case .notAnchored:
            return NSLocalizedString("Official API connected · No blockchain record is reported", comment: "")
        case .mismatch:
            return NSLocalizedString("Warning: the API and blockchain records do not match", comment: "")
        case .unavailable:
            return NSLocalizedString("Official API connected · Blockchain check is temporarily unavailable", comment: "")
        case .developmentSandbox:
            return NSLocalizedString("Development sandbox · No production blockchain record", comment: "")
        }
    }

    /// The one appearance for a verification state, shared with
    /// `TrustRecordDetailViewController`.
    ///
    /// Two decisions live here, made at different times:
    /// 1. **One mapping for both screens** (2026-09-01). The list used to show
    ///    green for `.notAnchored`/`.unavailable` while the detail screen showed
    ///    the same state in orange — opposite traffic lights for one fact. The
    ///    detail view now delegates here, so they cannot diverge again.
    /// 2. **The official API alone earns the check** (2026-09-02, 使用者拍板).
    ///    A loaded API record shows the plain green check; the *shield* is the
    ///    upgrade reserved for entries whose Arbitrum record also matches. The
    ///    blockchain is corroboration, not a prerequisite — an issuer on the
    ///    official list must not wear a warning colour because a chain lookup
    ///    is missing or unreachable. Only a genuine conflict (`.mismatch`) and
    ///    the sandbox are non-green.
    static func verificationAppearance(_ result: TWDIWOnChainVerification?)
        -> (symbol: String, colour: UIColor) {
        switch result {
        case .verified: return ("checkmark.shield.fill", .systemGreen)
        case .mismatch: return ("exclamationmark.shield.fill", .systemRed)
        case .notAnchored, .unavailable, nil: return ("checkmark.circle.fill", .systemGreen)
        case .developmentSandbox: return ("hammer.fill", .systemOrange)
        }
    }
}
