//
//  UseViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/8/27.
//

import UIKit

private let reuseIdentifier = "UseCell"

/// The 「使用」 tab: the verbs the wallet can do, taken off the home screen.
///
/// # Why the actions moved here
///
/// The home screen used to carry both the things you *hold* (the national ID,
/// government cards, the MyData source) and the things you can *do* (collect,
/// present, compare, show offline, check others). A held card and a button sat
/// in adjacent sections of one scrolling list, told apart only by a header. The
/// nouns now stay on 「首頁」 and the verbs live here, so each screen answers one
/// question — 「what do I have?」 and 「what can I do?」 — rather than both at once.
///
/// This screen mirrors `HomeViewController` deliberately: the same list
/// configuration, the same `Section`/`Item`/diffable-data-source spine, the same
/// title-keyed dispatch, and the same care about the credential store — `nil`
/// (the store would not open) is kept distinct from an empty store, because
/// reporting the former as 「you have nothing to show」 would be a lie about the
/// reader's own phone in front of a checker.
class UseViewController: UICollectionViewController {

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    /// Rows are matched on `title`, never on `indexPath` — the same discipline
    /// `HomeViewController` and `SettingsViewController` document, so inserting a
    /// section above a row can never silently repoint it.
    private enum Row {
        static let collect = NSLocalizedString("Add a card by scanning", comment: "")
        static let presentOnline = NSLocalizedString("Present a card to a verifier", comment: "")
        static let compare = NSLocalizedString("What each of these cards is worth", comment: "")
        static let present = NSLocalizedString("Show my document", comment: "")
        static let verify = NSLocalizedString("Check someone else's document", comment: "")
        static let verifyProof = NSLocalizedString("Check a zero-knowledge proof", comment: "")
    }

    /// Recomputed on every appearance, not stored once at init.
    ///
    /// Two rows here depend on what the store holds — `presentOnline` and
    /// `compare` are only meaningful once a card exists, and the `present` row's
    /// subtitle says whether there is anything to show — so this screen reads the
    /// store on every appearance for the same reason `HomeViewController` does:
    /// finishing the MyData flow (presented modally, issuing in the background as
    /// it dismisses) leaves nothing to see until the store is re-read.
    ///
    /// A function rather than a computed property because it performs I/O; a
    /// getter with a side effect is a getter somebody calls twice.
    private func makeSections() -> [Section] {
        // ⚠️ The `nil` is kept, exactly as on the home screen. `?? []` would turn
        // 「this phone's storage would not open」 into 「you hold no cards」 — and
        // here the second lie is spoken in front of a checker. `CredentialStore`'s
        // own layers refuse this substitution, and so does `HomeViewController`.
        let rows = (try? CredentialStore()).map { CardInventory.rows(from: $0) }

        // `presentOnline` and `compare` appear only once at least one card exists
        // — the gating the home screen already applied (`!rows.isEmpty`): there is
        // nothing to present online, and nothing for the comparison to be about,
        // on a phone that holds no card. `collect` is unconditional, because a
        // fresh install scanning a government offer first is a real path.
        let hasAnyCard = !(rows ?? []).isEmpty

        return [onlineSection(hasAnyCard: hasAnyCard),
                offlineSection(hasDocument: rows?.contains { $0.source == .selfIssued } ?? false,
                               storeIsReadable: rows != nil)]
    }

    /// The online verbs: collecting an official card, presenting one to a
    /// verifier, and comparing what the wallet's cards can prove.
    ///
    /// `collect` is unconditional; `presentOnline` and `compare` are gated on
    /// there being at least one card, which is the gating the single-list home
    /// screen already had — not a new rule, the same one relocated.
    private func onlineSection(hasAnyCard: Bool) -> Section {
        let title = "🌐 " + NSLocalizedString("Online", comment: "use section")

        // Collecting an official card by scanning its QR — independent of MyData,
        // so a fresh install collecting a government card first is a real path.
        let collect = Item(image: UIImage(systemName: "qrcode.viewfinder")?
                            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                           title: Row.collect,
                           secondaryText: NSLocalizedString(
                            "Point the camera at a QR from 數位憑證皮夾 to add its card.", comment: ""))

        guard hasAnyCard else {
            return Section(title: title, items: [collect])
        }

        // Presenting an official card online — scan the verifier's request, then
        // choose which of the asked-for fields to actually reveal. Shown only once
        // there is a card to present.
        let presentOnline = Item(image: UIImage(systemName: "person.badge.shield.checkmark")?
                                    .withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                                 title: Row.presentOnline,
                                 secondaryText: NSLocalizedString(
                                    "Scan a verifier's QR and choose exactly what to show.", comment: ""))

        // What a checker can rely on across the cards, and what none of them can
        // establish. Last, because the comparison only means something to someone
        // who already holds more than one kind of thing.
        let compare = Item(image: UIImage(systemName: "list.bullet.rectangle")?
                            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                           title: Row.compare,
                           secondaryText: NSLocalizedString(
                            "What a checker can rely on, and what none of them can establish.", comment: ""))

        return Section(title: title, items: [collect, presentOnline, compare])
    }

    /// The offline half of the wallet: showing your own document to a checker,
    /// and the two checker's tasks — verifying someone's document and verifying a
    /// zero-knowledge proof — that need no network.
    ///
    /// Both roles live together, as they did on the home screen: the whitepaper's
    /// §5.3 scenarios are a 里長, a volunteer, a border desk, and the two roles
    /// swap between the same two phones within a minute of each other.
    /// - Parameters:
    ///   - hasDocument: whether this phone holds a self-issued document to show.
    ///   - storeIsReadable: `false` when the store would not open, a different
    ///     state from holding nothing — and the `present` row must not tell the
    ///     reader they hold nothing when the truth is the phone could not be read.
    private func offlineSection(hasDocument: Bool, storeIsReadable: Bool = true) -> Section {
        Section(title: "📶 " + NSLocalizedString("Offline check", comment: ""), items: [
            Item(image: UIImage(systemName: "qrcode")?
                    .withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
                 title: Row.present,
                 // Neutral when the store would not open: 「there is nothing to
                 // show yet」 is a false statement about the reader's own phone in
                 // that state.
                 secondaryText: !storeIsReadable
                    ? NSLocalizedString("This phone's cards cannot be read right now.", comment: "")
                    : hasDocument
                    ? NSLocalizedString("Answer a checker's code. Neither phone needs a network.", comment: "")
                    : NSLocalizedString("Add your ID first, then you can show it to a checker.", comment: "")),
            Item(image: UIImage(systemName: "checkmark.shield")?
                    .withTintColor(.systemTeal, renderingMode: .alwaysOriginal),
                 title: Row.verify,
                 secondaryText: NSLocalizedString("Scan someone's document to check it is genuine — no network needed.", comment: "")),
            Item(image: UIImage(systemName: "eye.slash")?
                    .withTintColor(.systemPurple, renderingMode: .alwaysOriginal),
                 title: Row.verifyProof,
                 secondaryText: Self.proofRowSubtitle())
        ])
    }

    /// Whether this phone can actually check a proof, said on the row itself.
    ///
    /// A verbatim copy of `HomeViewController`'s row subtitle, kept local so this
    /// screen owns its rows the way that one does. Keyed to
    /// `ZKCheckingAvailability` — the exact question the checking screen's
    /// `ZKPackageVerifier` gates on — so the row and the screen it opens cannot
    /// drift into different tenses. Both variants state a *local* fact (files
    /// present or absent) and neither implies any verdict, so no tick and no
    /// colour.
    private static func proofRowSubtitle() -> String {
        if ZKCheckingAvailability.current.canCheck {
            return NSLocalizedString("Verify a zero-knowledge proof. The checking files are on this phone.", comment: "")
        }
        return ZKCheckingAvailability.current == .notDownloadedYet
            ? NSLocalizedString("Verify a zero-knowledge proof. The first time, it downloads the checking files (about 950 MB).", comment: "")
            : NSLocalizedString("Verify a zero-knowledge proof. This version cannot download the checking files.", comment: "")
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

        title = NSLocalizedString("Use", comment: "")
        navigationController?.navigationBar.prefersLargeTitles = true
        // The tab bar item is set by `SceneDelegate`, not here: a `tabBarItem` set
        // in `viewDidLoad` does not show until the tab is first selected, and this
        // is the second tab, whose view is not loaded at launch.
        // Settings moved off the tab bar into the top-right of both tabs; see
        // `SceneDelegate`. Each tab installs its own gear so Settings is one tap
        // away wherever the person is.
        navigationItem.rightBarButtonItem = Self.makeSettingsButton(target: self,
                                                                    action: #selector(presentSettings))
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)

        configureDataSource()
        applySnapshot()
    }

    /// Reapplied on every appearance, not just at load — the store can change
    /// while this screen is off-stack (a card collected, the ID created), and the
    /// rows keyed to the store must reflect that when the tab returns.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
    }

    /// The gear both tabs put in the top-right. Factored out so 「首頁」 and
    /// 「使用」 build the identical control and label it the same way.
    static func makeSettingsButton(target: Any?, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "gearshape"),
                                   style: .plain, target: target, action: action)
        item.accessibilityLabel = NSLocalizedString("Settings", comment: "")
        return item
    }

    /// Presents Settings modally, wrapped in its own navigation controller with a
    /// 「完成」 close button — Settings is no longer a tab, so it needs a way back.
    @objc private func presentSettings() {
        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        settings.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Done", comment: ""), style: .done,
            target: self, action: #selector(dismissPresentedSettings))
        present(nav, animated: true)
    }

    @objc private func dismissPresentedSettings() {
        dismiss(animated: true)
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            var content = cell.defaultContentConfiguration()
            content.image = item.image
            // Plain text with `textProperties` — an attributed font is frozen at
            // configure time and ignores mid-session Dynamic Type changes.
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
            // `makeSections()`, which would re-read the store on every header
            // dequeue and could disagree with the rows on screen. Weak `self`
            // avoids a retain cycle.
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
        for section in makeSections() {
            snapshot.appendSections([section])
            snapshot.appendItems(section.items)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

// MARK: UICollectionViewDelegate

extension UseViewController {

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        // The identical dispatch the home screen used before these rows moved, so
        // every action still reaches the same destination and does the same thing.
        switch item.title {
        case Row.collect:
            ScanToCollect.begin(on: navigationController)
        case Row.presentOnline:
            ScanToPresent.begin(on: navigationController)
        case Row.compare:
            navigationController?.pushViewController(CapabilityViewController(), animated: true)
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

/// Header view for the list sections — a multi-line, Dynamic-Type-aware label.
///
/// A file-local mirror of `HomeViewController`'s `CustomHeaderView`: three
/// settings that were once all missing (`numberOfLines = 0`,
/// `adjustsFontForContentSizeCategory`, a trailing constraint) are what stop a
/// header from being clipped mid-character at the largest accessibility sizes.
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
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: 0),
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
