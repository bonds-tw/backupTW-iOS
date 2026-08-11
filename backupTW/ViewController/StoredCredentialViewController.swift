//
//  StoredCredentialViewController.swift
//  backupTW
//

import UIKit

/// Shows the document this device is holding.
///
/// # The gap this fills
///
/// Until this screen existed there was nowhere in the app to look at your own
/// credential. It could be *presented* to somebody else and it could be counted
/// on the diagnostics screen, but the holder could not read the thing they had
/// stored. The MyData flow showed five fields in a sheet and then the sheet went
/// away, which is why finishing it felt like nothing had happened.
///
/// # Why the fields are behind a tap
///
/// The home screen deliberately shows only a count and a date. This screen shows
/// the values — a national ID number, a date of birth, a home address — and that
/// is a deliberate second step rather than an unhelpful one. The document is
/// most often opened in exactly the situations where somebody else can see the
/// screen, so the fields are revealed on request and the screen says what is
/// about to be shown before it shows it.
final class StoredCredentialViewController: UICollectionViewController {

    private struct Row: Hashable {
        let id: String
        let title: String
        let value: String
        let isSensitive: Bool
        let isAction: Bool
    }

    private struct Group: Hashable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private var dataSource: UICollectionViewDiffableDataSource<Group, Row>!
    private var groups: [Group] = []
    private var isRevealed = false
    private var stored: StoredNationalID?

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("My identity document", comment: "")
        configureDataSource()
        reload()

        // Backgrounding closes the fields. `didEnterBackground` and not
        // `willResignActive` — the latter fires for Control Centre and an
        // incoming call, and yanking the fields shut mid-comparison for a
        // banner would teach people to stop using the hide step at all. The
        // app-switcher snapshot is already handled by `PrivacyShield`; this is
        // for the return trip, so a phone handed back does not open on the
        // address.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRevealed else { return }
            self.isRevealed = false
            self.applySnapshot()
        }
    }

    /// Held so the observation dies with the screen. The block API's token is
    /// not auto-removed: discarding it leaves a live observer behind every
    /// visit to this screen, each firing into a dead closure forever.
    private var backgroundObserver: NSObjectProtocol?

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    // MARK: - Content

    private func reload() {
        stored = StoredNationalID.load()
        applySnapshot()
    }

    /// Rebuilds the list from the `stored` already in memory, without touching
    /// the disk.
    ///
    /// Split out for the backgrounding observer: the credential file is class B
    /// (`.completeUnlessOpen`), and re-reading it at the exact moment the
    /// device is locking is the one moment the read is entitled to fail — which
    /// would blank a screen that only needed its switch flipped. Hiding the
    /// fields needs no bytes it does not already have.
    private func applySnapshot() {
        groups = buildGroups()
        var snapshot = NSDiffableDataSourceSnapshot<Group, Row>()
        for group in groups {
            snapshot.appendSections([group])
            snapshot.appendItems(group.rows, toSection: group)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func buildGroups() -> [Group] {
        guard let stored else {
            return [Group(id: "empty",
                          title: "",
                          rows: [Row(id: "empty",
                                     title: NSLocalizedString("No document stored yet", comment: ""),
                                     value: NSLocalizedString(
                                        "Back up your national ID from the home screen first.",
                                        comment: ""),
                                     isSensitive: false, isAction: false)])]
        }

        var groups: [Group] = []

        groups.append(Group(id: "about", title: NSLocalizedString("This document", comment: ""), rows: [
            Row(id: "about.created",
                title: NSLocalizedString("Created", comment: ""),
                value: stored.createdDescription(style: .long),
                isSensitive: false, isAction: false),
            Row(id: "about.issuer",
                title: NSLocalizedString("Signed by", comment: ""),
                // Named plainly, and it has to be the *right* plain answer:
                // this row is the only place the holder is told what their own
                // document is worth, and the two envelopes are worth opposite
                // amounts. Showing a DID instead would be worse than either —
                // `issuer` is this phone's key in both forms, so it would imply
                // an authority that does not exist for the older one and hide
                // the real one for the newer.
                //
                // The wording tracks `VerificationCaveat.assertedByCardholder`
                // on purpose. The holder and whoever checks their document must
                // not read two different accounts of the same file, which is
                // exactly what this screen did when card signing landed and this
                // row kept saying the phone had signed it.
                value: stored.isCardSigned
                    ? NSLocalizedString("Your own digital certificate. That shows you are the one making these claims — not that the government has confirmed them.",
                                        comment: "")
                    : NSLocalizedString("This phone — nobody else vouches for these values.",
                                        comment: ""),
                isSensitive: false, isAction: false)
        ]))

        if isRevealed {
            groups.append(Group(
                id: "fields",
                title: NSLocalizedString("Fields", comment: ""),
                rows: stored.claims.map {
                    Row(id: "field.\($0.key)",
                        title: StoredNationalID.label(for: $0.key),
                        value: StoredNationalID.displayValue(for: $0.key, value: $0.value),
                        isSensitive: true, isAction: false)
                }))
            // Revealing was a deliberate step; un-revealing has to be one tap
            // too, because the situation that made the fields sensitive — a
            // counter, a queue, somebody alongside — does not end when the tap
            // that opened them does.
            groups.append(Group(id: "hide", title: "", rows: [
                Row(id: "hide.action",
                    title: NSLocalizedString("Hide the fields", comment: ""),
                    value: "",
                    isSensitive: false, isAction: true)
            ]))
        } else {
            groups.append(Group(id: "reveal", title: "", rows: [
                Row(id: "reveal.action",
                    title: String(format: NSLocalizedString("Show %d fields", comment: ""),
                                  stored.claims.count),
                    value: NSLocalizedString(
                        "Includes your ID number and home address. Check who can see your screen.",
                        comment: ""),
                    isSensitive: false, isAction: true)
            ]))
        }

        return groups
    }

    // MARK: - Collection

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.value.isEmpty ? nil : row.value
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            if row.isAction {
                content.textProperties.color = .tintColor
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
            } else if row.isSensitive {
                // Monospaced so an ID number can be read off a digit at a time
                // and compared against a card without miscounting.
                content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
                content.secondaryTextProperties.color = .label
            } else {
                content.secondaryTextProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = row.id
        }
        dataSource = UICollectionViewDiffableDataSource<Group, Row>(collectionView: collectionView) {
            view, indexPath, row in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = view.defaultContentConfiguration()
            content.text = self?.groups[indexPath.section].title
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : nil
        }
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath)?.isAction == true
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath), row.isAction else { return }
        isRevealed = row.id == "reveal.action"
        reload()
    }
}
