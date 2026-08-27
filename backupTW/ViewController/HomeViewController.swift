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

        // The guide rows a card group shows when it holds nothing. They are
        // verbs wearing a noun's clothes: each stands in an empty card group and,
        // when tapped, starts the flow that would put a card there — so they
        // dispatch to the same destinations as the action rows below, not to a
        // screen of their own.
        static let governmentEmpty = NSLocalizedString("No government cards yet", comment: "home card group empty state")
        // MyData's row is present on every launch, because in this build the
        // MyData group never fills: the household record is fetched only to build
        // the national ID and is erased straight after (see `MyDataScratch`). The
        // row says that plainly rather than showing a vault that will always be
        // empty with no word on why.
        static let myDataVault = NSLocalizedString("Nothing stored from MyData yet", comment: "home card group empty state")
    }

    /// Card rows, keyed by the identifier the `Item` carries.
    ///
    /// `Row` above works because each of those titles appears once. Cards break
    /// that assumption by design — two government cards are both titled
    /// 「政府皮夾卡片」 — so a title match would open whichever one the switch
    /// reached first. The store identifier is the only value unique per card.
    private var cardRows: [String: CardInventoryRow] = [:]

    /// Recomputed on every appearance rather than stored once at init.
    ///
    /// This screen used to be a `let` constant, which is why finishing the
    /// MyData flow left no trace on it: the credential was saved, the home
    /// screen never read the store, and the app looked untouched. A person who
    /// has just handed over their household record and sees no sign of it has
    /// every reason to think it failed — and to do it again.
    ///
    /// A function rather than a computed property since the cards arrived: it
    /// reads the store and records what it found in `cardRows`, and a getter
    /// with a side effect is a getter somebody will call twice.
    private func makeSections() -> [Section] {
        // ⚠️ The `nil` is kept. It used to be `?? []`, one character that turned
        // 「this phone's storage would not open」 into 「you have no documents」 —
        // byte-for-byte the fresh-install screen.
        //
        // `CredentialStore.init` gates on two *write*-side actions
        // (`createDirectory`, the iCloud-exclusion `setResourceValues`), so an
        // intact and perfectly readable document disappears because a
        // backup-exclusion xattr could not be written. The store's own next
        // layer refuses this exact substitution in as many words — 「reporting
        // that as 『you have no document』 sends somebody to apply again for one
        // they already have」 — and `CardInventory` says reading decides what a
        // row *says*, never whether it exists. Both were bypassed here.
        //
        // Note which way round the two paths were: `LocalDataEraser` uses a
        // non-optional `try CredentialStore()`, so the destructive path threw
        // and the informational one swallowed.
        let rows = (try? CredentialStore()).map { CardInventory.rows(from: $0) }
        cardRows = Dictionary((rows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // # Why the home screen shows only what the wallet holds
        //
        // Every card the phone holds and every button used to live in one
        // 「My cards」 section — `rows.map(item(for:)) + [refresh, collect,
        // presentOnline, compare]`. A held card and a thing-you-can-do sat in
        // the same list, told apart only by an icon colour, and the three kinds
        // of thing the wallet is *about* — the national ID it issues, government
        // cards collected from 數位憑證皮夾, and the MyData record the ID is
        // built from — had no structural place. MyData in particular appeared
        // nowhere as a source, only hidden inside the 「back up」 action.
        //
        // The nouns and verbs were first split into sections of one screen; now
        // they are split across two tabs. This screen keeps the nouns — one card
        // group per source, each showing its cards or, when it holds none, a
        // guide row that says so and leads to the flow that would fill it. The
        // verbs (collect, present online, compare, show offline, check others)
        // moved to `UseViewController`, the 「使用」 tab. A source with nothing in
        // it is still shown, so all three of the wallet's targets stand here as
        // peers rather than one being reachable only through a button.
        //
        // `nil` still means 「the store would not open」, a different thing from
        // an empty group, and it is threaded to each group so none of them
        // reports 「you hold nothing of this kind」 when the truth is 「this phone
        // could not be read」.
        let selfIssued = rows?.filter { $0.source == .selfIssued }
        // Unrecognised cards ride with the government group rather than getting a
        // fourth catch-all: this app mints exactly one self-issued document under
        // one fixed id and format, so a blob matching neither shape is far
        // likelier to be something collected than something of ours gone wrong.
        // The row itself already says 「this version does not recognise this
        // card」, so the header claims nothing the row then has to walk back.
        let government = rows?.filter { $0.source == .twdiw || $0.source == .unrecognised }

        return [nationalIDSection(cards: selfIssued),
                governmentSection(cards: government),
                myDataSection()]
    }

    /// The national ID this app builds — the one document it issues, kept with
    /// the action that creates and replaces it.
    ///
    /// The 「back up」 row stays in this group rather than moving out with the
    /// other verbs, because unlike them it is bound to exactly one card: it does
    /// not collect an arbitrary offer, it creates or replaces *this* document in
    /// place (`MyDataOnboardViewController` files it under one constant id). So
    /// it reads as this card's own 「create / refresh」 control, present whether
    /// or not the card exists yet.
    ///
    /// Named fields are still not summarised in the card row. The home screen is
    /// the most over-the-shoulder-readable surface in the app, so rows carry the
    /// card's *kind* and its dates and nothing out of its claims — a rule
    /// enforced in `CardInventory`, where it can be tested, not here.
    /// - Parameter rows: `nil` when the store would not open, which is a
    ///   different screen from an empty one.
    private func nationalIDSection(cards rows: [CardInventoryRow]?) -> Section {
        let title = "🪪 " + NSLocalizedString("National ID", comment: "home card group")

        guard let rows else {
            // No 「create one」 row while the store is unreadable. That row is the
            // single instruction that would cost a second 戶籍謄本 and a second
            // 身分證統一編號 — and issuance saves through the constructor that has
            // just failed, so it would fail again after collecting them.
            return Section(title: title, items: [Self.unreadableStoreRow(in: "national-id")])
        }

        // Keyed to whether *our own* document exists — which, since these rows
        // are already filtered to `.selfIssued`, is simply whether the group is
        // non-empty. Found by rendering the screen with a government card and no
        // self-issued one: the row read 「重新抓一次，取代目前存的這份」 while there
        // was nothing of ours stored to replace. Filtering by source before this
        // point is what keeps a card of some other kind from changing what it says.
        let hasOwnDocument = !rows.isEmpty
        let refresh = Item(image: UIImage(systemName: "arrow.clockwise")?
                            .withTintColor(.systemGray, renderingMode: .alwaysOriginal),
                           title: Row.backUp,
                           secondaryText: !CredentialIssuanceAssembly.isAvailable
                            // Said here as well as on the screen it opens.
                            // Otherwise the home screen is still advertising a
                            // capability whose own destination has just been
                            // gated — and the row is where somebody decides to
                            // go there at all.
                            ? NSLocalizedString("This version cannot create a document.", comment: "")
                            : hasOwnDocument
                            ? NSLocalizedString("Fetch it again and replace what's stored.", comment: "")
                            : NSLocalizedString("with Taiwan's official MyData service", comment: ""))

        return Section(title: title, items: rows.map(item(for:)) + [refresh])
    }

    /// Cards collected from other issuers through 數位憑證皮夾.
    ///
    /// Collecting one is a verb and lives in the actions section, so this group
    /// is nouns only: the government cards themselves, or — when there are none —
    /// a guide row that says so and opens the scanner. The guide is not the
    /// collect action taking a card's place by accident; it dispatches to the
    /// same scanner precisely because an empty government group and 「add a
    /// government card」 are the same intention seen from two sides.
    /// - Parameter rows: `nil` when the store would not open.
    private func governmentSection(cards rows: [CardInventoryRow]?) -> Section {
        let title = "🏛️ " + NSLocalizedString("Government wallet cards", comment: "home card group")

        guard let rows else {
            return Section(title: title, items: [Self.unreadableStoreRow(in: "government")])
        }

        guard !rows.isEmpty else {
            return Section(title: title, items: [
                Item(image: UIImage(systemName: "tray")?
                        .withTintColor(.systemGray, renderingMode: .alwaysOriginal),
                     title: Row.governmentEmpty,
                     secondaryText: NSLocalizedString(
                        "Scan a QR from 數位憑證皮夾 to add a card issued by a government body.", comment: ""))
            ])
        }

        return Section(title: title, items: rows.map(item(for:)))
    }

    /// MyData, shown as a source even though this build keeps nothing under it.
    ///
    /// The point of the row is honesty about an absence, not a placeholder for a
    /// feature. `MyDataScratch` fetches the household record, hands its fields to
    /// issuance, and erases them the moment the PDF has been read — by design
    /// there is no MyData vault to fill. Rather than leave the source off the
    /// home screen (its previous state, discoverable only behind the 「back up」
    /// button) or draw a vault that is permanently empty with no explanation, the
    /// row states what MyData does here and opens the one flow that uses it.
    private func myDataSection() -> Section {
        let title = "🗂️ " + NSLocalizedString("MyData vault", comment: "home card group")
        return Section(title: title, items: [
            Item(image: UIImage(systemName: "lock.doc")?
                    .withTintColor(.systemGray, renderingMode: .alwaysOriginal),
                 title: Row.myDataVault,
                 secondaryText: NSLocalizedString(
                    "Your household record is fetched through MyData only to build your national ID, then erased — nothing is kept here.", comment: ""))
        ])
    }

    /// The one row both card groups show when the store itself would not open.
    ///
    /// Shared so the national ID group and the government group say the same true
    /// thing in the same words — 「could not be read」, never 「you hold none」 —
    /// rather than one of them silently reporting an empty group for a phone whose
    /// storage failed to open.
    /// The same "storage would not open" row appears under **both** the national
    /// ID and government sections when the store will not open, so each needs its
    /// own identifier. `Item`'s identity is `identifier` + title + text (image
    /// ignored), and two rows sharing a `nil` identifier are, to a
    /// `NSDiffableDataSourceSnapshot`, one duplicated item — which traps and kills
    /// the app on the exact path this row exists to explain calmly. `group` makes
    /// the two unique while they still say the same true thing.
    private static func unreadableStoreRow(in group: String) -> Item {
        Item(image: UIImage(systemName: "externaldrive.badge.exclamationmark")?
                .withTintColor(.systemOrange, renderingMode: .alwaysOriginal),
             title: NSLocalizedString("This phone's cards cannot be read right now", comment: ""),
             secondaryText: NSLocalizedString("Anything saved here is still saved. This most often means the phone is out of space — free some up and open the app again.", comment: ""),
             identifier: "unreadable-store.\(group)")
    }

    private func item(for row: CardInventoryRow) -> Item {
        let symbol: String
        let tint: UIColor
        switch row.state {
        case .usable:
            symbol = row.source == .selfIssued ? "checkmark.seal.fill" : "creditcard.fill"
            tint = row.source == .selfIssued ? .systemGreen : .systemBlue
        case .expired:
            // Orange, not red, and not a warning triangle: an expired card is a
            // fact about a date, not a fault by anyone, and it may still be the
            // right thing to show a checker who only needs to see it existed.
            symbol = "clock.badge.exclamationmark"
            tint = .systemOrange
        case .unreadable:
            symbol = "questionmark.square.dashed"
            tint = .systemGray
        }
        return Item(image: UIImage(systemName: symbol)?
                        .withTintColor(tint, renderingMode: .alwaysOriginal),
                    title: row.title,
                    secondaryText: row.detail,
                    identifier: row.id)
    }

    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        // A *boundary* supplementary of the whole collection view (not a section
        // header), so the big 「有備而來」 title with the gear stands above the
        // first card group. See `BrandHeaderView`.
        let brand = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .estimated(52)),
            elementKind: BrandHeaderView.elementKind, alignment: .top)
        let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfig.boundarySupplementaryItems = [brand]
        layout.configuration = layoutConfig
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("Bond", comment: "")
        // The name is drawn by the brand header inside the list (see
        // `BrandHeaderView`), which also carries the settings gear — so the two
        // sit on one row instead of the gear floating in the navigation bar. The
        // bar's own copy of the title is suppressed here: `.never` so no large
        // title, an empty `titleView` so no inline one either, leaving the name
        // to appear exactly once. `title` is still set so a pushed screen's back
        // button refers to 「有備而來」.
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = UIView()
        // different title for tabBarItem needs to be set after setting title (avoid being overwritten)
        tabBarItem = UITabBarItem(title: NSLocalizedString("Home", comment: ""),
                                  image: UIImage(systemName: "house.fill"), selectedImage: nil)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)

        configureDataSource()
        applySnapshot()
    }

    /// Presents Settings modally, wrapped in a navigation controller with a
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
            // `makeSections()` — it re-reads the credential store on every
            // header dequeue, and its answer could disagree with what the rows
            // on screen were built from. The strong `self` capture was also a
            // retain cycle.
            guard let dataSource = self?.dataSource else { return }
            let sections = dataSource.snapshot().sectionIdentifiers
            guard indexPath.section < sections.count else { return }
            headerView.configure(title: sections[indexPath.section].title, forTextStyle: .title2)
        }
        let brandRegistration = UICollectionView.SupplementaryRegistration<BrandHeaderView>(
            elementKind: BrandHeaderView.elementKind
        ) { [weak self] headerView, _, _ in
            headerView.configure(title: NSLocalizedString("Bond", comment: ""))
            headerView.onSettingsTapped = { self?.presentSettings() }
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == BrandHeaderView.elementKind {
                return collectionView.dequeueConfiguredReusableSupplementary(using: brandRegistration, for: indexPath)
            }
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

extension HomeViewController {

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        // Cards are answered by identifier before the title switch runs. Two
        // government cards share a title, so reaching them through `Row` would
        // open the wrong one — and would do it silently.
        if let identifier = item.identifier, let card = cardRows[identifier] {
            open(card)
            return
        }

        switch item.title {
        // The MyData vault guide opens the same flow as 「back up」: the one thing
        // MyData does in this build is fetch the household record to build the
        // national ID. Routed here rather than given a screen of its own, because
        // there is no separate MyData destination — the guide and the create row
        // are two doors onto the one flow, worded for where each is read.
        case Row.backUp, Row.myDataVault:
            let vc = MyDataOnboardViewController()
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        // The empty-government-group guide starts the same scanner the 「使用」
        // tab's collect action does. It stays on the home screen because it is
        // not a general action but an inline CTA for *this empty group* — an empty
        // government group and 「add a government card」 are the same intention
        // seen from two sides.
        case Row.governmentEmpty:
            ScanToCollect.begin(on: navigationController)
        default:
            break
        }
    }

    /// What tapping a card does — including when the answer is "nothing yet".
    ///
    /// Each readable card has a detail screen keyed to its own bytes:
    /// `StoredCredentialViewController` reads the self-issued document (which is
    /// keyed to one fixed identifier, so it may only be pushed for that one),
    /// and `GovernmentCardViewController` reads a TWDIW card *by the id the row
    /// carries*, so the government card the holder tapped is the one whose
    /// contents open. Pushing either for the wrong card would show a holder **a
    /// different card's contents under the row they tapped**, which is why the
    /// routing is by source and id, not by title.
    ///
    /// Only the `unreadable` state has no detail screen, and it keeps the honest
    /// alert: a card that would not decode has no contents to show, and the
    /// alert says the one true thing — that it could be damaged *or* wrongly
    /// signed, and this build cannot tell which — rather than guessing.
    private func open(_ card: CardInventoryRow) {
        if card.source == .selfIssued, card.state == .usable {
            navigationController?.pushViewController(StoredCredentialViewController(), animated: true)
            return
        }

        // A government card that decoded — usable or expired, but not unreadable
        // — now opens onto its contents. An expired card is still readable and
        // the holder is entitled to see what is in it; the detail screen marks
        // the expiry rather than the home screen hiding the fields.
        if card.source == .twdiw, card.state != .unreadable {
            navigationController?.pushViewController(
                GovernmentCardViewController(id: card.id), animated: true)
            return
        }

        // This alert **is** the screen the row promises, because there is no
        // other one for a card that would not decode. It is reached by a
        // malformed card *and* by a well-formed card whose signature does not
        // verify, and telling the two apart is exactly what failed —
        // `CardInventory`'s comment says the row stays silent because 「the
        // screen that can explain properly does the explaining」, so this one
        // explains, including the part that is not known.
        let message = String(format: NSLocalizedString(
            "Something about it did not come out right, and this build cannot tell which: the stored file may be damaged, or its signature may not match. It is listed here so you know it was not lost. Stored as %@.",
            comment: ""), card.id)
        let alert = UIAlertController(
            title: NSLocalizedString("This card could not be read or checked", comment: ""),
            message: message,
            preferredStyle: .alert)
        if card.capability != nil {
            alert.addAction(UIAlertAction(
                title: NSLocalizedString("What this kind of card proves", comment: ""),
                style: .default) { [weak self] _ in
                    self?.navigationController?.pushViewController(CapabilityViewController(), animated: true)
                })
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        present(alert, animated: true)
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
        // Three things that were all missing, which is why at AX5 the header
        // rendered as 「離線出示與查」 — cut mid-character, with no ellipsis, so
        // it read as though the section were simply called that. It names the
        // entry point most used in the scenarios this app is for.
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            // The one that actually did the clipping: with no trailing
            // constraint the label was free to lay itself out past the screen.
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

/// The big 「有備而來」 title and the settings gear, side by side, as the list's
/// top boundary header.
///
/// The gear used to be a `navigationItem.rightBarButtonItem`. On iOS 26 that
/// parks it in a rounded capsule pinned high in the navigation bar, a clear gap
/// above the large title — the app's name and its one global control landed on
/// different lines with nothing tying them together. Here they share one row,
/// the gear trailing-aligned to the name it belongs beside, and both scroll
/// with the list rather than one floating apart from it.
///
/// Shared by the 「首頁」 and 「使用」 tabs, which each install it as their list's
/// top boundary supplementary so both draw the identical title-and-gear row.
final class BrandHeaderView: UICollectionReusableView {
    /// The boundary-supplementary element kind both tabs register it under.
    static let elementKind = "brand-header"

    private let titleLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
    /// Set by the data source: a reusable view cannot reach the view controller
    /// to present Settings on its own.
    var onSettingsTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // A bold 34pt face run through the large-title metrics — the weight and
        // size UIKit would itself have drawn as the navigation bar's large
        // title, so moving the name into the list changes where it sits, not how
        // it looks. `adjustsFontForContentSizeCategory` keeps it scaling.
        let largeTitle = UIFont.systemFont(ofSize: 34, weight: .bold)
        titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let gear = UIImage(systemName: "gearshape",
                           withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2))
        settingsButton.setImage(gear, for: .normal)
        settingsButton.accessibilityLabel = NSLocalizedString("Settings", comment: "")
        // The gear keeps its intrinsic width and never squeezes the title.
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, settingsButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Pinned to the layout-margins guide so the title's leading edge lines
        // up with the inset-grouped card groups below and the gear sits at the
        // same trailing margin the cards respect.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    func configure(title: String) {
        titleLabel.text = title
    }

    @objc private func settingsTapped() {
        onSettingsTapped?()
    }
}
