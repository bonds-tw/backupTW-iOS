//
//  HomeViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/6/7.
//

import UIKit

class HomeViewController: UICollectionViewController {

    private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!

    /// Opens the credential store each `buildContent`. Production returns the real
    /// on-disk `CredentialStore`; injectable so a test can seed an in-memory store
    /// and drive the home screen (stack included) without touching the device store.
    private let makeStore: () -> CredentialStoring?

    /// The single device-motion source that drives every visible card's sheen and
    /// micro-tilt. Owned here (strong) and fed to the cards through a closure that
    /// captures `self` weakly, so there is no cycle. Runs only while this screen is
    /// on-screen — see `viewWillAppear` / `viewWillDisappear`.
    private let motionCoordinator = WalletMotionCoordinator()

    /// Whether Home is the on-screen view. It tells 「backgrounded while Home
    /// showed」 (resume the sheen on return) apart from 「backgrounded while
    /// Settings or a detail covered Home」 (do not) — a distinction the foreground
    /// notification cannot make on its own, unlike `viewWillAppear`.
    private var isHomeVisible = false

    /// Phase 2c 疊卡. The government group collapses to a stack — the first card
    /// full, the rest peeking their headers — whenever it holds two or more cards.
    /// A tap on the stack expands it to the full list (and a tap on the header
    /// collapses it again); `false` is the resting, collapsed state.
    private var isGovernmentStackExpanded = false

    /// The stable id of the government group, shared by the section builder, the
    /// stack layout, and the tap routing so they always mean the same section.
    private static let governmentSectionID = "government"
    /// How much of each peeking card's top shows — a sliver (一角) with its name,
    /// Apple-Wallet style. The full 「hero」 card sits at the bottom of the stack and
    /// the peeks fan up above it, each casting a shadow onto the card below.
    private static let stackPeekHeight: CGFloat = 60
    /// Every collapsed-stack card is a 數位憑證皮夾 credential face, so its height is
    /// its width over this one aspect ratio.
    private static let credentialAspect: CGFloat = 1.585

    /// A section of the home screen, identified by a stable id so its header and
    /// its place survive a rebuild even as its cards change.
    private struct HomeSection: Hashable {
        let id: String
        let title: String
    }

    /// One thing in a section: either a wallet card face, or a plain control row
    /// (the 「更新備份」 control, the empty-government CTA). They diff independently
    /// — a card whose masked fields changed is a changed item, and a control that
    /// did not is left alone.
    private enum HomeItem: Hashable {
        case card(id: String, content: WalletCardContent)
        case control(ControlRow)
    }

    /// A tappable list row that is not a card. Its icon and tint are derived from
    /// `kind` at display time, so the struct stays free of `UIColor` — which is
    /// `NSObject`-hashable in a way that is a trap to lean on inside a diffable
    /// item identity.
    private struct ControlRow: Hashable {
        enum Kind: Hashable { case backup, governmentEmpty, importMyData }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String?
    }

    /// The fixed titles of the guide rows and controls, kept as named constants
    /// because the tap handler matches on them.
    private enum Row {
        static let backUp = NSLocalizedString("Back up my national ID", comment: "")
        static let governmentEmpty = NSLocalizedString("No government cards yet", comment: "home card group empty state")
        static let importMyData = NSLocalizedString("Import a MyData document", comment: "vault import row")
    }

    /// Synthetic card identifiers — cards that do not stand for a stored
    /// credential (the invite-to-create ID, the MyData vault, and the two
    /// 「storage would not open」 faces). Kept distinct and, crucially, **unique**:
    /// `NSDiffableDataSourceSnapshot` traps on a duplicated item identity, and the
    /// two unreadable faces say the same words under different sections, so each
    /// carries its own id. This is the same duplicate-identity trap the old row
    /// list documented at length.
    /// Not `private`, so the delete-eligibility rule (`deletableCard(forCardID:in:)`)
    /// can be exercised against these exact synthetic ids in a test without a
    /// window — the ids that must *never* be deletable are the ones this enum
    /// names.
    enum CardID {
        static let nationalIDPlaceholder = "national-id.placeholder"
        static let vault = "mydata.vault"
        static func unreadableStore(in group: String) -> String { "unreadable-store.\(group)" }
    }

    /// Card rows keyed by the identifier the card carries, so a tap can be
    /// answered by *which stored card* it was rather than by a title two cards
    /// share. Recomputed on every rebuild.
    private var cardRows: [String: CardInventoryRow] = [:]

    // MARK: - Content

    /// Reads the store and lays out the three card groups.
    ///
    /// ⚠️ The `nil` is kept, and it is the whole reason this returns an optional
    /// row list per group rather than `?? []`. `CredentialStore.init` gates on
    /// two *write*-side actions, so an intact, readable document can become
    /// 「you have no documents」 because a backup-exclusion xattr could not be
    /// written — byte-for-byte the fresh-install screen. `nil` means 「the store
    /// would not open」, a different screen from an empty one, and it is threaded
    /// to each group so none reports 「you hold nothing」 for a phone that could
    /// not be read.
    private func buildContent() -> [(HomeSection, [HomeItem])] {
        let store = makeStore()
        let rows = store.map { CardInventory.rows(from: $0) }
        cardRows = Dictionary((rows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Self-issued splits two ways: the national ID (its own section, one card)
        // and MyData vault documents (財力/勞保/學歷…), which go to the vault.
        let selfIssued = rows?.filter { $0.source == .selfIssued }
        let nationalID = selfIssued?.filter { !MyDataDocumentRegistry.isVaultDocument(id: $0.id) }
        let vaultDocs = selfIssued?.filter { MyDataDocumentRegistry.isVaultDocument(id: $0.id) }
        // Unrecognised cards ride with the government group, as the old list did:
        // this app mints exactly one self-issued document, so a blob matching
        // neither shape is likelier collected than ours gone wrong.
        let government = rows?.filter { $0.source == .twdiw || $0.source == .unrecognised }

        return [nationalIDSection(rows: nationalID, store: store),
                governmentSection(rows: government, store: store),
                myDataSection(rows: vaultDocs, store: store)]
    }

    /// The national ID this app builds, kept with the 「更新備份」 control that
    /// creates and replaces it — present whether or not the card exists yet,
    /// because it is this one card's own create/refresh control, not a general
    /// verb (those live in the 「使用」 tab).
    private func nationalIDSection(rows: [CardInventoryRow]?,
                                   store: CredentialStoring?) -> (HomeSection, [HomeItem]) {
        let section = HomeSection(id: "national-id",
                                  title: "🪪 " + NSLocalizedString("National ID", comment: "home card group"))

        guard let rows else {
            // No 「create one」 control while the store is unreadable: that control
            // is the single instruction that would cost a second 戶籍謄本 and a
            // second 統一編號, and issuance saves through the constructor that has
            // just failed — so it would fail again after collecting them.
            return (section, [.card(id: CardID.unreadableStore(in: "national-id"),
                                    content: .unreadable(Self.unreadableStoreMessage))])
        }

        var items: [HomeItem] = []
        if let own = rows.first {
            items.append(.card(id: own.id,
                               content: WalletCardFactory.nationalIDContent(row: own, store: store)))
        } else {
            // Empty-state invitation card — still an ID-styled face, still leading
            // to the flow that would fill it.
            items.append(.card(id: CardID.nationalIDPlaceholder,
                               content: WalletCardFactory.nationalIDContent(row: nil, store: store)))
        }

        // The backup control lives on Home only until a document exists — there its
        // job is the create invitation. Once the ID is stored, refreshing the backup
        // is rare housekeeping, so it moves to Settings (「更新我的身分證備份」) and
        // stops taking a slot on the main screen.
        let hasOwnDocument = !rows.isEmpty
        if !hasOwnDocument {
            let subtitle = !CredentialIssuanceAssembly.isAvailable
                ? NSLocalizedString("This version cannot create a document.", comment: "")
                : NSLocalizedString("with Taiwan's official MyData service", comment: "")
            items.append(.control(ControlRow(id: "control.backup", kind: .backup,
                                             title: Row.backUp, subtitle: subtitle)))
        }
        return (section, items)
    }

    /// Cards collected through 數位憑證皮夾, listed vertically (the Phase 2 stack
    /// fan-out replaces this list later). An empty group keeps its inline CTA to
    /// the scanner — an empty government group and 「add a government card」 are the
    /// same intention from two sides.
    private func governmentSection(rows: [CardInventoryRow]?,
                                   store: CredentialStoring?) -> (HomeSection, [HomeItem]) {
        let section = HomeSection(id: "government",
                                  title: "🏛️ " + NSLocalizedString("Government wallet cards", comment: "home card group"))

        guard let rows else {
            return (section, [.card(id: CardID.unreadableStore(in: "government"),
                                    content: .unreadable(Self.unreadableStoreMessage))])
        }

        guard !rows.isEmpty else {
            return (section, [.control(ControlRow(
                id: "control.government-empty", kind: .governmentEmpty,
                title: Row.governmentEmpty,
                subtitle: NSLocalizedString(
                    "Scan a QR from 數位憑證皮夾 to add a card issued by a government body.",
                    comment: "")))])
        }

        return (section, rows.map { row in
            .card(id: row.id, content: WalletCardFactory.credentialContent(row: row, store: store))
        })
    }

    /// MyData, shown as a source even though this build keeps nothing under it:
    /// the household record is fetched to build the national ID and erased
    /// straight after (see `MyDataScratch`). The vault card says that plainly
    /// rather than showing a vault that will always be empty with no word on why.
    private func myDataSection(rows: [CardInventoryRow]?,
                               store: CredentialStoring?) -> (HomeSection, [HomeItem]) {
        let section = HomeSection(id: "mydata",
                                  title: "🗂️ " + NSLocalizedString("MyData vault", comment: "home card group"))
        var items: [HomeItem] = []
        // Held vault documents first, each as its own card face.
        for row in rows ?? [] {
            items.append(.card(id: row.id,
                               content: WalletCardFactory.vaultDocumentContent(row: row, store: store)))
        }
        // The empty-state 「Sealed / nothing here」 card only when the vault is empty.
        if items.isEmpty {
            items.append(.card(id: CardID.vault, content: WalletCardFactory.vaultContent()))
        }
        // The way in: import another document from MyData.
        items.append(.control(ControlRow(
            id: "control.import-mydata", kind: .importMyData,
            title: Row.importMyData,
            subtitle: NSLocalizedString("Bring a financial, insurance, or academic document in from MyData.",
                                        comment: "vault import subtitle"))))
        return (section, items)
    }

    /// The one sentence both card groups show when the store itself would not
    /// open — 「could not be read」, never 「you hold none」.
    private static let unreadableStoreMessage = NSLocalizedString(
        "This phone's cards cannot be read right now. Anything saved here is still saved. This most often means the phone is out of space — free some up and open the app again.",
        comment: "")

    // MARK: - Setup

    init(makeStore: @escaping () -> CredentialStoring? = { try? CredentialStore() }) {
        self.makeStore = makeStore
        super.init(collectionViewLayout: UICollectionViewLayout())
        collectionView.collectionViewLayout = makeLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A compositional layout: one full-width self-sizing item per row, a header
    /// per section, and the big 「有備而來」 brand row as the collection's top
    /// boundary supplementary. Not `.list` any more — cards need their own
    /// height and no list separators — but the two headers are preserved exactly.
    private func makeLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            if let self, let count = self.collapsedStackCardCount(atSectionIndex: index) {
                return Self.collapsedStackSection(cardCount: count, environment: environment)
            }
            return Self.normalCardSection()
        }
        let brand = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .estimated(52)),
            elementKind: BrandHeaderView.elementKind, alignment: .top)
        let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfig.boundarySupplementaryItems = [brand]
        layout.configuration = layoutConfig
        return layout
    }

    /// If the section at `index` is the government group, currently collapsed, and
    /// holds two or more cards, returns that card count — the signal to lay it out
    /// as a stack. `nil` in every other case (use the normal one-per-row layout):
    /// a single card, an empty-state control, the unreadable face, or an already
    /// expanded stack.
    private func collapsedStackCardCount(atSectionIndex index: Int) -> Int? {
        guard !isGovernmentStackExpanded, dataSource != nil else { return nil }
        let snapshot = dataSource.snapshot()
        let sections = snapshot.sectionIdentifiers
        guard index < sections.count, sections[index].id == Self.governmentSectionID else { return nil }
        let cardCount = snapshot.itemIdentifiers(inSection: sections[index]).filter {
            if case .card = $0 { return true } else { return false }
        }.count
        return cardCount >= 2 ? cardCount : nil
    }

    /// Whether the government group holds two or more cards — the condition for the
    /// stack (and its header chevron) to exist at all, whether it is currently
    /// collapsed or expanded. `collapsedStackCardCount` answers the narrower
    /// 「and collapsed right now」 the layout asks.
    private func governmentIsStackable() -> Bool {
        governmentCardItems(in: dataSource.snapshot()).count >= 2
    }

    /// The `.card` items in the government group, in order — the ones the stack
    /// lays out and the ones a toggle must reconfigure so their peek/full mode
    /// tracks the new state.
    private func governmentCardItems(in snapshot: NSDiffableDataSourceSnapshot<HomeSection, HomeItem>) -> [HomeItem] {
        guard let section = snapshot.sectionIdentifiers.first(where: { $0.id == Self.governmentSectionID })
        else { return [] }
        return snapshot.itemIdentifiers(inSection: section).filter {
            if case .card = $0 { return true } else { return false }
        }
    }

    /// Opens or closes the government 疊卡. Reconfigures the government cards so each
    /// cell's peek/full mode is recomputed by the cell provider, then swaps in a
    /// fresh layout (which reads the new state) with an animated transition — the
    /// stack springs open to the full list, or the list gathers back into a stack.
    func setGovernmentStackExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isGovernmentStackExpanded, dataSource != nil else { return }
        isGovernmentStackExpanded = expanded

        var snapshot = dataSource.snapshot()
        let cards = governmentCardItems(in: snapshot)
        guard !cards.isEmpty else { return }
        snapshot.reconfigureItems(cards)
        dataSource.apply(snapshot, animatingDifferences: false)

        collectionView.setCollectionViewLayout(makeLayout(), animated: animated)
        // The layout swap repositions the live header without re-running its
        // registration, so the chevron and its VoiceOver label would otherwise lag
        // the new state — push it on directly.
        refreshGovernmentHeader()
    }

    /// Sets a section header's 疊卡 disclosure: a chevron + header-tap toggle for a
    /// stackable government group (pointing the way the current state implies), and
    /// nothing at all for any other header. The single source of truth shared by
    /// the header registration and `refreshGovernmentHeader`.
    private func configureDisclosure(on header: CustomHeaderView, sectionID: String) {
        guard sectionID == Self.governmentSectionID, governmentIsStackable() else {
            header.setDisclosure(expanded: nil)   // also clears onTap
            return
        }
        header.setDisclosure(expanded: isGovernmentStackExpanded)
        header.onTap = { [weak self] in
            guard let self else { return }
            self.setGovernmentStackExpanded(!self.isGovernmentStackExpanded)
        }
    }

    /// Pushes the government group's current disclosure state onto its live header.
    /// A stack toggle and a content rebuild both reposition that header without
    /// re-dequeuing it, so its chevron/label must be refreshed by hand or it lags
    /// the state (and, after a delete to one card, keeps a stale, live chevron).
    private func refreshGovernmentHeader() {
        guard dataSource != nil,
              let index = dataSource.snapshot().sectionIdentifiers
                  .firstIndex(where: { $0.id == Self.governmentSectionID }),
              let header = collectionView.supplementaryView(
                  forElementKind: UICollectionView.elementKindSectionHeader,
                  at: IndexPath(item: 0, section: index)) as? CustomHeaderView
        else { return }
        configureDisclosure(on: header, sectionID: Self.governmentSectionID)
    }

    /// The normal one-card-per-row section: a self-sizing full-width item, 12pt
    /// gaps, and the group header.
    private static func normalCardSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .estimated(220))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)
        section.boundarySupplementaryItems = [groupHeader()]
        return section
    }

    /// The collapsed 疊卡 section: full rounded cards laid out by hand so they
    /// overlap Apple-Wallet style — the hero at the bottom in front, each card above
    /// tucked behind and offset up by `stackPeekHeight`, so only its rounded top
    /// (a sliver with its name) shows. No clipping; the lower card covers the body
    /// of the one above.
    private static func collapsedStackSection(cardCount: Int,
                                              environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        // A custom group does NOT honour the section's horizontal contentInsets for
        // its item frames — they came out full-bleed, wider than every other card.
        // So the 16pt side margin is put into the item frames by hand (x = inset,
        // width = container − 2·inset) and the section's horizontal insets are left
        // at 0, matching the normal one-per-row cards exactly.
        let inset: CGFloat = 16
        let cardWidth = environment.container.effectiveContentSize.width - inset * 2
        let cardHeight = cardWidth / credentialAspect
        let peek = stackPeekHeight    // visible sliver of each stacked card's top
        let totalHeight = cardHeight + CGFloat(cardCount - 1) * peek
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .absolute(totalHeight))
        // Apple-Wallet stack: every card is a FULL rounded card, and they overlap so
        // a lower card covers the body of the card above it — leaving only that
        // card's rounded top (a `peek`-tall sliver with its name) showing. No
        // clipping: the hero (first card) sits at the BOTTOM, fully visible and in
        // front (highest zIndex); each card above is behind the one below it, so its
        // bottom corners are hidden and its body fills behind the lower card's
        // rounded top — no notch, no pill.
        let group = NSCollectionLayoutGroup.custom(layoutSize: groupSize) { env in
            let w = env.container.effectiveContentSize.width - inset * 2
            let h = w / credentialAspect
            return (0..<cardCount).map { i in
                let y = i == 0 ? CGFloat(cardCount - 1) * peek : CGFloat(i - 1) * peek
                let z = i == 0 ? cardCount : i   // hero in front; each lower card in front of the one above
                return NSCollectionLayoutGroupCustomItem(
                    frame: CGRect(x: inset, y: y, width: w, height: h), zIndex: z)
            }
        }
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0)
        section.boundarySupplementaryItems = [groupHeader()]
        return section
    }

    private static func groupHeader() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                               heightDimension: .estimated(38)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("Bond", comment: "")
        // The name is drawn by the brand header inside the list (see
        // `BrandHeaderView`), which also carries the settings gear. The bar's own
        // title is suppressed so the name appears exactly once; `title` stays set
        // so a pushed screen's back button reads 「有備而來」.
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = UIView()
        tabBarItem = UITabBarItem(title: NSLocalizedString("Documents", comment: "tab bar: the cards you hold"),
                                  image: UIImage(systemName: "person.text.rectangle.fill"), selectedImage: nil)

        configureDataSource()
        applySnapshot()

        // Weak self: the coordinator is a stored property of this controller, so a
        // strong capture here would be a retain cycle. Each tilt is fanned out to
        // whichever cards are currently visible.
        motionCoordinator.onTilt = { [weak self] x, y in
            self?.applyTiltToVisibleCards(x: x, y: y)
        }

        // `viewWillDisappear` does not fire when the app is backgrounded, so the
        // sensor would otherwise stay 「started」 across a background. Stop it on
        // background, resume on foreground — but only if Home is actually showing,
        // since the foreground notification cannot tell that by itself. The detail
        // screens observe the same notification for the same reason.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        motionCoordinator.stop()
    }

    @objc private func appWillEnterForeground() {
        // 陀螺儀傾斜已停用,前景不再啟動感測器。
    }

    /// Pushes one motion update to every on-screen card. Cheap: a bounded walk of
    /// visible cells, each forwarding to a per-frame layer update.
    private func applyTiltToVisibleCards(x: CGFloat, y: CGFloat) {
        for case let cell as WalletCardCell in collectionView.visibleCells {
            cell.applyTilt(x: x, y: y)
        }
    }

    /// Presents Settings modally with a 「完成」 close button — Settings is no
    /// longer a tab, so it needs a way back.
    @objc private func presentSettings() {
        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        settings.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Done", comment: ""), style: .done,
            target: self, action: #selector(dismissPresentedSettings))
        // Full screen, not the default `.pageSheet`. A sheet leaves this
        // controller in the hierarchy, so `viewWillDisappear` never fires and the
        // gyroscope would keep streaming to the dimmed cards behind it. Full
        // screen fires appear/disappear cleanly — the same choice
        // `presentMyDataOnboard` already makes — so the sheen stops with the sheet.
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc private func dismissPresentedSettings() {
        dismiss(animated: true)
    }

    /// Reapplied on every appearance, not just at load: the MyData flow is
    /// presented modally and issues the credential as it dismisses, so the moment
    /// this screen comes back is the first moment there is anything new to show.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
        isHomeVisible = true
        // 陀螺儀傾斜/反光已依使用者要求停用,讓卡片平整、完整呈現形狀——不再啟動感測器。
        // (WalletMotionCoordinator 與 applyTilt 保留但不觸發,方便日後恢復。)
    }

    /// Stop the sensor the moment this screen is covered or left — a Settings
    /// modal, a pushed detail, or switching tabs. Nothing should keep updating
    /// cards nobody can see, and the sensor should not stay draining power. The
    /// now-hidden cards are settled back to flat so they are not frozen mid-tilt
    /// when the screen returns.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isHomeVisible = false
        motionCoordinator.stop()
        for case let cell as WalletCardCell in collectionView.visibleCells {
            cell.resetTilt()
        }
    }

    // MARK: - Data source

    private func configureDataSource() {
        let cardRegistration = UICollectionView.CellRegistration<WalletCardCell, WalletCardContent> {
            [weak self] cell, _, content in
            cell.configure(content)
            // Collapsed 疊卡 vs expanded is a pure layout difference now (the custom
            // group overlaps full cards) — the cell itself is always a full card, so
            // nothing per-cell to switch here.
            // The back's 「查看／管理詳情」 button opens the same detail screen a tap
            // used to. Resolved through the live indexPath at tap time, never a
            // captured one, so a reused cell routes to whatever card it now shows.
            cell.onDetailTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let indexPath = self.collectionView.indexPath(for: cell),
                      let item = self.dataSource.itemIdentifier(for: indexPath),
                      case .card(let id, _) = item,
                      let card = self.cardRows[id] else { return }
                self.open(card)
            }
        }
        let controlRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ControlRow> {
            cell, _, row in
            var content = cell.defaultContentConfiguration()
            content.text = row.title
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = row.subtitle
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.secondaryTextProperties.color = .secondaryLabel
            switch row.kind {
            case .backup:
                content.image = UIImage(systemName: "arrow.clockwise")?
                    .withTintColor(.tintColor, renderingMode: .alwaysOriginal)
            case .governmentEmpty:
                content.image = UIImage(systemName: "qrcode.viewfinder")?
                    .withTintColor(.systemGray, renderingMode: .alwaysOriginal)
            case .importMyData:
                content.image = UIImage(systemName: "tray.and.arrow.down.fill")?
                    .withTintColor(.tintColor, renderingMode: .alwaysOriginal)
            }
            cell.contentConfiguration = content
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.cornerRadius = 14
            cell.backgroundConfiguration = background
        }

        dataSource = UICollectionViewDiffableDataSource<HomeSection, HomeItem>(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .card(_, let content):
                return collectionView.dequeueConfiguredReusableCell(
                    using: cardRegistration, for: indexPath, item: content)
            case .control(let row):
                return collectionView.dequeueConfiguredReusableCell(
                    using: controlRegistration, for: indexPath, item: row)
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<CustomHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] headerView, _, indexPath in
            guard let self, let dataSource = self.dataSource else { return }
            let sections = dataSource.snapshot().sectionIdentifiers
            guard indexPath.section < sections.count else {
                headerView.setDisclosure(expanded: nil)
                return
            }
            headerView.configure(title: sections[indexPath.section].title, forTextStyle: .title2)
            // The government group gets a disclosure chevron and a header-tap toggle
            // for its 疊卡, but only when it holds enough cards to stack; every other
            // header (and a one-card government group) shows none.
            self.configureDisclosure(on: headerView, sectionID: sections[indexPath.section].id)
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
        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
        for (section, items) in buildContent() {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
        // A group that is no longer stackable returns to the resting collapsed
        // state, so a later repopulation (a card scanned back in) defaults to
        // collapsed rather than inheriting a stale 「expanded」 from before it
        // dropped below two cards.
        if !governmentIsStackable() { isGovernmentStackExpanded = false }
        // The header persists across a rebuild without its registration re-running,
        // so push the current disclosure state (or none) onto it directly.
        refreshGovernmentHeader()
    }
}

// MARK: - UICollectionViewDelegate

extension HomeViewController {

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .card(let id, _):
            // Collapsed 疊卡: a tap anywhere on the stack opens it — expand to the
            // full list rather than flip the tapped card. Once expanded, a tap is
            // the flip below; the header chevron collapses it again.
            if collapsedStackCardCount(atSectionIndex: indexPath.section) != nil {
                setGovernmentStackExpanded(true)
                return
            }
            // A flippable card (credential, real national ID) turns to show its
            // masked fields rather than pushing detail; detail is reached from the
            // back's own button. `setFlipped` settles this cell's tilt as it turns,
            // so the flip is not fought by the gyroscope. A second tap on the back
            // (anywhere but the button) turns it back.
            if let cell = collectionView.cellForItem(at: indexPath) as? WalletCardCell,
               cell.canFlip {
                cell.toggleFlip()
                return
            }
            // Not flippable. A stored card opens its own contents, keyed by id —
            // two government cards share a title, so title-matching would open the
            // wrong one. (This path now carries the unreadable stored faces, whose
            // `open` shows the honest 「could not be read」 alert.)
            if let card = cardRows[id] {
                open(card)
            } else if id == CardID.nationalIDPlaceholder || id == CardID.vault {
                // The invite-to-create ID card and the MyData vault are two doors
                // onto the one flow: MyData is fetched only to build the national
                // ID, so both open the onboarding flow.
                presentMyDataOnboard()
            }
            // The two 「storage would not open」 faces have no destination and are
            // left inert.
        case .control(let row):
            switch row.kind {
            case .backup:
                presentMyDataOnboard()
            case .governmentEmpty:
                ScanToCollect.begin(on: navigationController)
            case .importMyData:
                presentImportPicker()
            }
        }
    }

    /// The way into the vault: pick a MyData document type to import. Choosing one
    /// opens that document's own MyData item (see `MyDataDocumentType.myDataItemPath`,
    /// discovered on mydata.nat.gov.tw) and fetches it in-app through 行動自然人憑證
    /// the same way the national ID is fetched, storing the result under the
    /// document's id so it lands in the vault. A document with no MyData counterpart
    /// (學歷) says so instead of opening a flow that cannot fetch it.
    private func presentImportPicker() {
        let sheet = UIAlertController(
            title: NSLocalizedString("Import from MyData", comment: "vault import picker title"),
            message: NSLocalizedString("Choose a document to bring in from Taiwan's MyData service.", comment: ""),
            preferredStyle: .actionSheet)
        for type in MyDataDocumentRegistry.vaultDocuments {
            sheet.addAction(UIAlertAction(title: type.title, style: .default) { [weak self] _ in
                self?.beginImport(of: type)
            })
        }
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
        present(sheet, animated: true)
    }

    private func beginImport(of type: MyDataDocumentType) {
        guard type.myDataItemPath != nil else {
            // A document with no MyData counterpart — 學歷／畢業證書 was verified not
            // to be a MyData item. Say so plainly rather than opening a flow that
            // would fetch the wrong record.
            let alert = UIAlertController(
                title: type.title,
                message: NSLocalizedString("This document isn't available through Taiwan's MyData service, so it can't be imported here.", comment: "vault import: document not on MyData"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            present(alert, animated: true)
            return
        }
        // Opens this document's own MyData item (income / labor insurance / health
        // insurance), fetched in-app through 行動自然人憑證 the same way the national
        // ID is, and stored under the document's id so it lands in the vault.
        presentMyDataOnboard(documentType: type)
    }

    // MARK: - Delete one card

    /// A long-press context menu, offered **only** on a face that stands for a
    /// real stored credential.
    ///
    /// The eligibility rule is `deletableCard(forCardID:in:)` and it is the same
    /// keying the tap router already trusts: a card is deletable exactly when its
    /// id is one `CardInventory` produced from a stored file — every government
    /// card, the self-issued national ID, and a card that is listed-but-unreadable
    /// under its real id. The synthetic faces (the invite-to-create ID, the
    /// MyData vault, the two 「storage would not open」 panels) carry ids this map
    /// never contains, so they get no menu — there is no single file behind them
    /// to remove, and a delete that fell through to `deleteAll` would take every
    /// card. A `.control` row is not a `.card` at all and returns here too.
    override func collectionView(_ collectionView: UICollectionView,
                                 contextMenuConfigurationForItemAt indexPath: IndexPath,
                                 point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .card(let id, _) = item,
              let card = Self.deletableCard(forCardID: id, in: cardRows) else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let present = UIAction(
                title: NSLocalizedString("Present credential", comment: "card context menu"),
                image: UIImage(systemName: "person.badge.shield.checkmark")) { [weak self] _ in
                    guard let self else { return }
                    ScanToPresent.begin(on: self.navigationController)
                }
            let delete = UIAction(
                title: NSLocalizedString("Delete card", comment: "card context menu, destructive"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive) { [weak self] _ in
                    self?.confirmDelete(card)
                }
            return UIMenu(title: "", children: [present, delete])
        }
    }

    /// The stored card a 「刪除卡片」 action on `id` would remove, or nil when the
    /// face is not a deletable stored credential.
    ///
    /// A single documented seam so the menu and its test ask the identical
    /// question. It is deliberately the same `cardRows` lookup as the tap router:
    /// there is one definition of 「this face is a stored card」 in this screen and
    /// both the thing that opens a card and the thing that deletes one read it.
    static func deletableCard(forCardID id: String,
                              in cardRows: [String: CardInventoryRow]) -> CardInventoryRow? {
        cardRows[id]
    }

    /// A destructive operation is never one tap. This confirmation names the card
    /// and says what recovery, if any, exists — a national ID can be rebuilt from
    /// MyData, a government card re-collected from 數位憑證皮夾 — so a holder who
    /// pressed 「刪除卡片」 by mistake, or does not realise the card is retrievable,
    /// finds out before the file is gone rather than after.
    private func confirmDelete(_ card: CardInventoryRow) {
        // Keyed on the canonical national-ID id, not `source`: a national ID that
        // is stored but currently unreadable resolves to `.unrecognised`, and it
        // should still get the 「rebuild through MyData」 wording rather than the
        // government 「re-collect from 數位憑證皮夾」 one.
        let message = card.id == StoredNationalID.credentialID
            ? NSLocalizedString(
                "This card will be removed from this phone. You can build your national ID again later through Taiwan's MyData service.",
                comment: "delete confirmation, self-issued national ID")
            : NSLocalizedString(
                "This card will be removed from this phone. You can collect it again from 數位憑證皮夾.",
                comment: "delete confirmation, government wallet card")

        let alert = UIAlertController(
            title: NSLocalizedString("Delete this card?", comment: "delete confirmation title"),
            message: message,
            preferredStyle: .alert)
        // `.destructive` on the confirm, `.cancel` last so the safe choice is the
        // one under the thumb — the same shape the identity-reset confirmation uses.
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Delete", comment: "delete confirmation, confirm"),
            style: .destructive) { [weak self] _ in
                self?.performDelete(card)
            })
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Cancel", comment: "delete confirmation, cancel"),
            style: .cancel))
        present(alert, animated: true)
    }

    /// Removes exactly this card, then rebuilds the list so it disappears.
    ///
    /// A fresh `CredentialStore()` for the one call, matching every other write
    /// on this screen — the store is stateless between operations and holds a
    /// lock for the duration of each. `delete(id:)`, never `deleteAll()`: the
    /// scope is this one id and the rest of the wallet stays put.
    ///
    /// A failure is surfaced, not swallowed. If the file could not be removed the
    /// card is still on the phone, so the holder is told in the app's
    /// `UserFacingError` voice rather than being shown a list the delete silently
    /// failed to change — a pretend success here would be a lie about where an
    /// identity document is.
    private func performDelete(_ card: CardInventoryRow) {
        do {
            try CredentialStore().delete(id: card.id)
            applySnapshot()
        } catch {
            let alert = UIAlertController(
                title: NSLocalizedString("The card was not deleted", comment: "delete failure title"),
                message: UserFacingError.deletionMessage(for: error),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
            present(alert, animated: true)
        }
    }

    private func presentMyDataOnboard(documentType: MyDataDocumentType = MyDataDocumentRegistry.nationalID) {
        let vc = MyDataOnboardViewController(documentType: documentType)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    /// What tapping a stored card does — including when the answer is 「nothing
    /// yet」. Routed by source and id, never by title: pushing the wrong detail
    /// screen would show a holder a different card's contents under the row they
    /// tapped.
    private func open(_ card: CardInventoryRow) {
        if card.source == .selfIssued, card.state == .usable {
            navigationController?.pushViewController(StoredCredentialViewController(), animated: true)
            return
        }

        if card.source == .twdiw, card.state != .unreadable {
            navigationController?.pushViewController(
                GovernmentCardViewController(id: card.id), animated: true)
            return
        }

        // This alert **is** the screen the card promises, because there is no
        // other one for a card that would not decode. It is reached by a
        // malformed card *and* by a well-formed card whose signature does not
        // verify, and telling the two apart is exactly what failed — so it says
        // both, including the part that is not known.
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
    /// The 疊卡 disclosure control: a chevron pointing down when the stack is
    /// collapsed and up when it is expanded, hidden entirely for sections that do
    /// not stack. When shown, a tap anywhere on the header runs `onTap`.
    private let chevron = UIImageView()
    var onTap: (() -> Void)?

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
        // rendered as 「離線出示與查」 — cut mid-character, no ellipsis, so it read
        // as though the section were simply called that.
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        addSubview(titleLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.isHidden = true
        addSubview(chevron)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(headerTapped)))
    }

    @objc private func headerTapped() { onTap?() }

    func configure(title: String, forTextStyle style: UIFont.TextStyle) {
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: style)
    }

    /// `expanded == nil` hides the chevron (a non-stacking section); otherwise it
    /// points up when the stack is open and down when it is collapsed. Reset on
    /// every reuse, so a recycled header never keeps a stale chevron or callback.
    func setDisclosure(expanded: Bool?) {
        guard let expanded else {
            chevron.isHidden = true
            onTap = nil
            return
        }
        chevron.isHidden = false
        chevron.image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down")
        chevron.accessibilityLabel = expanded
            ? NSLocalizedString("Collapse", comment: "stack disclosure")
            : NSLocalizedString("Expand", comment: "stack disclosure")
    }
}

/// The big 「有備而來」 title and the settings gear, side by side, as the list's
/// top boundary header.
///
/// The gear used to be a `navigationItem.rightBarButtonItem`. On iOS 26 that
/// parks it in a rounded capsule pinned high in the navigation bar, a clear gap
/// above the large title. Here they share one row, the gear trailing-aligned to
/// the name it belongs beside, and both scroll with the list.
///
/// Shared by the 「首頁」 and 「使用」 tabs, which each install it as their list's
/// top boundary supplementary.
final class BrandHeaderView: UICollectionReusableView {
    static let elementKind = "brand-header"

    private let titleLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
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
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, settingsButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
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
