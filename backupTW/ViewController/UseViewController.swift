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
        static let applyTelecom = NSLocalizedString("Apply for a phone-number card", comment: "")
        static let pickupBarcode = NSLocalizedString("Create a convenience-store pickup barcode", comment: "")
        // 「出示」 is one verb with one entrance. The online row (「Present a
        // card to a verifier」) and the offline row used to sit side by side,
        // told apart only by their subtitles — at a checkpoint, with seconds to
        // choose, that is a coin flip. The single `present` row now scans first
        // and routes by what the QR actually is (design system §10.2).
        static let present = NSLocalizedString("Show my document", comment: "")
        static let verify = NSLocalizedString("Check someone else's document", comment: "")
        static let createAgeProof = NSLocalizedString("Answer an age check", comment: "age proof")
        static let verifyAgeProof = NSLocalizedString("Check age with ZKP or SD-JWT-VC", comment: "age proof")
        static let prepareOffline = NSLocalizedString("Prepare offline checking", comment: "offline preparation")
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
        let store = try? CredentialStore()
        let rows = store.map { CardInventory.rows(from: $0) }

        let hasTelecomCard = store.map(Self.hasTelecomCredential(in:)) ?? false

        return [onlineSection(hasTelecomCard: hasTelecomCard),
                presentAndVerifySection(hasAnyCard: !(rows ?? []).isEmpty,
                                        storeIsReadable: rows != nil),
                zeroKnowledgeSection()]
    }

    /// The zero-knowledge actions gathered under their actual capability name.
    /// Creating and checking are distinct actions and appear together with
    /// different icons.
    private func zeroKnowledgeSection() -> Section {
        Section(title: NSLocalizedString("Zero-knowledge proofs", comment: "use section"), items: [
            Item(image: UIImage(systemName: "arrow.down.circle"), title: Row.prepareOffline,
                 secondaryText: NSLocalizedString("Save issuer trust and proof files before disconnecting. No cards are needed on the checking device.", comment: "offline preparation")),
            Item(image: UIImage(systemName: "person.text.rectangle.fill"),
                 title: Row.createAgeProof,
                 secondaryText: NSLocalizedString(
                    "The request determines whether to disclose a birth date or create a private proof. You confirm before anything is sent.",
                    comment: "age proof")),
            Item(image: UIImage(systemName: "checkmark.seal.text.page.fill"),
                 title: Row.verifyAgeProof,
                 secondaryText: NSLocalizedString(
                    "Compare local age checks using a government card or MyData national ID.",
                    comment: "age proof"))
        ])
    }

    /// The online verbs: getting cards, and the pickup barcode they enable.
    ///
    /// `collect` and `applyTelecom` are unconditional — both are ways to *get* a
    /// first card, so gating them on already holding one would hide them from
    /// exactly the fresh install they are for. `pickupBarcode` is always listed
    /// but disabled with its reason until a telecom card exists — a row that
    /// appears and disappears with state teaches the reader that buttons are
    /// unreliable (design system §8.3).
    private func onlineSection(hasTelecomCard: Bool) -> Section {
        let title = NSLocalizedString("Online", comment: "use section")

        // Collecting an official card by scanning its QR — independent of MyData,
        // so a fresh install collecting a government card first is a real path.
        let collect = Item(image: UIImage(systemName: "qrcode.viewfinder"),
                           title: Row.collect,
                           secondaryText: NSLocalizedString(
                            "Point the camera at a QR from 數位憑證皮夾 to add its card.", comment: ""))

        // The subtitle is one plain line: the carrier's app does the checking and
        // the card returns here on its own. The Wi-Fi-off step and the
        // remove-the-official-app requirement are real but belong to the
        // carrier's own prompts and to one-time setup, not to a row that has to
        // read at a glance.
        let applyTelecom = Item(image: UIImage(systemName: "antenna.radiowaves.left.and.right"),
                                title: Row.applyTelecom,
                                secondaryText: NSLocalizedString(
                                    "Verify your number in your carrier's app; the card returns here.", comment: ""))

        let pickupBarcode = Item(image: UIImage(systemName: "shippingbox.and.arrow.backward"),
                                 title: Row.pickupBarcode,
                                 secondaryText: hasTelecomCard
                                    ? NSLocalizedString(
                                        "Use your phone-number card to create a short-lived 7-ELEVEN pickup barcode.", comment: "")
                                    : NSLocalizedString(
                                        "Needs a phone-number card. Apply for one above, and this becomes available.", comment: "pickup row, disabled reason"),
                                 isEnabled: hasTelecomCard)

        return Section(title: title, items: [collect, applyTelecom, pickupBarcode])
    }

    private static func hasTelecomCredential(in store: CredentialStore) -> Bool {
        for id in (try? store.allIDs()) ?? [] {
            guard let serialized = try? store.load(id: id),
                  StoredCardSource.source(of: serialized) == .twdiw,
                  let credential = try? TWDIWCredentialReader.read(serialized) else { continue }
            if ConvenienceStorePickupCatalog.telecomCredentialTypes.contains(credential.credentialType) {
                return true
            }
        }
        return false
    }

    /// The face-to-face half of the wallet: showing your own document, and
    /// checking someone else's.
    ///
    /// Both roles live together, as they did on the home screen: the whitepaper's
    /// §5.3 scenarios are a 里長, a volunteer, a border desk, and the two roles
    /// swap between the same two phones within a minute of each other. The
    /// `present` row is the single 「出示」 entrance — it scans first and routes
    /// online (OID4VP) and offline requests by the QR itself.
    /// - Parameters:
    ///   - hasAnyCard: whether this phone holds anything at all to show.
    ///   - storeIsReadable: `false` when the store would not open, a different
    ///     state from holding nothing — and the `present` row must not tell the
    ///     reader they hold nothing when the truth is the phone could not be read.
    private func presentAndVerifySection(hasAnyCard: Bool, storeIsReadable: Bool = true) -> Section {
        Section(title: NSLocalizedString("Present and check", comment: "use section"), items: [
            Item(image: UIImage(systemName: "qrcode"),
                 title: Row.present,
                 // Neutral when the store would not open: 「there is nothing to
                 // show yet」 is a false statement about the reader's own phone in
                 // that state.
                 secondaryText: !storeIsReadable
                    ? NSLocalizedString("This phone's cards cannot be read right now.", comment: "")
                    : hasAnyCard
                    ? NSLocalizedString("Scan the checker's QR — face to face or online. You choose what to reveal.", comment: "unified present row")
                    : NSLocalizedString("Add your ID first, then you can show it to a checker.", comment: "")),
            Item(image: UIImage(systemName: "checkmark.shield"),
                 title: Row.verify,
                 secondaryText: NSLocalizedString("Scan someone's document to check it is genuine — no network needed.", comment: ""))
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
    init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        // The big 「使用」 title and the settings gear ride the list's top
        // boundary header, the same shared row 「首頁」 uses, instead of the gear
        // floating in the navigation bar. See `BrandHeaderView`.
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

        title = NSLocalizedString("Use", comment: "")
        // The name and the settings gear are drawn together by the brand header
        // inside the list (see `BrandHeaderView`), so the bar's own title is
        // suppressed here — `.never` for no large title, an empty `titleView`
        // for no inline one — leaving 「使用」 to appear once, on the gear's row.
        // `title` stays set so a pushed screen's back button still refers to it.
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = UIView()
        // The tab bar item is set by `SceneDelegate`, not here: a `tabBarItem` set
        // in `viewDidLoad` does not show until the tab is first selected, and this
        // is the second tab, whose view is not loaded at launch.
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

    /// Presents Settings modally, wrapped in its own navigation controller with a
    /// 「完成」 close button — Settings is no longer a tab, so it needs a way back.
    @objc private func presentSettings() {
        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        // `.fullScreen`, matching the home tab's presentation — the same screen
        // reached from two places must open and close the same way (design
        // system §10.1).
        nav.modalPresentationStyle = .fullScreen
        settings.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Done", comment: ""), style: .done,
            target: self, action: #selector(dismissPresentedSettings))
        present(nav, animated: true)
    }

    @objc private func dismissPresentedSettings() {
        dismiss(animated: true)
    }

    /// Fetches the telecom 門號電子卡 catalogue and opens the carrier's application.
    ///
    /// This is an「申請新卡」action, so it is deliberately *not* the embedded
    /// `WebCollectViewController` path (that is for cards the wallet finishes
    /// inside an in-app webview). A telecom card is `type == 1` — its number
    /// check runs in the carrier's own app over mobile data — so the entry URL is
    /// handed to the OS with `UIApplication.shared.open`. When the carrier is done
    /// it returns a `modadigitalwallet://credential_offer` deep link, which the
    /// scene delegate routes through both `IssuerAuthorization` gates like any
    /// other offer.
    ///
    /// - Parameter anchorCell: the tapped row, used only as the iPad popover
    ///   anchor so the action sheet does not crash on a regular-width layout. Nil
    ///   is tolerated — the presentation falls back to the view's centre.
    private func applyTelecomCard(anchorCell: UICollectionViewCell?) {
        Task { @MainActor in
            let cards: [TelecomCard]
            do {
                cards = try await TelecomCardCatalog.fetch()
            } catch {
                presentTelecomAlert(title: NSLocalizedString("Apply for a phone-number card", comment: ""),
                                    message: UserFacingError.telecomCatalogMessage(for: error))
                return
            }

            guard !cards.isEmpty else {
                // A reachable, well-formed catalogue that simply lists no telecom
                // card right now — a real state (a maintenance window, a rename),
                // said plainly rather than as an error.
                presentTelecomAlert(title: NSLocalizedString("Apply for a phone-number card", comment: ""),
                                    message: NSLocalizedString(
                                        "No phone-number cards are available to apply for right now. Please try again later.", comment: ""))
                return
            }

            let sheet = UIAlertController(
                title: NSLocalizedString("Which carrier?", comment: "telecom apply chooser title"),
                message: NSLocalizedString(
                    "Choose your mobile carrier. Its app opens to verify the number on your line.", comment: ""),
                preferredStyle: .actionSheet)
            for card in cards {
                sheet.addAction(UIAlertAction(title: card.name, style: .default) { _ in
                    guard let url = URL(string: card.issuerServiceUrl) else { return }
                    // `type == 1` → external open. The completion form is used
                    // because the bare `open(_:)` would resolve to the awaitable
                    // overload inside a closure that returns Void.
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                })
            }
            sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
            // iPad presents an action sheet in a popover, which crashes without a
            // source. Anchor on the tapped row when it is still on screen, else the
            // view's centre — never an unset source.
            if let popover = sheet.popoverPresentationController {
                if let anchorCell {
                    popover.sourceView = anchorCell
                    popover.sourceRect = anchorCell.bounds
                } else {
                    popover.sourceView = view
                    popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
            }
            present(sheet, animated: true)
        }
    }

    /// A plain one-button alert for the telecom apply flow's failures and empty
    /// states, in the same shape the collection alert uses.
    private func presentTelecomAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    private func startSevenElevenPickup() {
        collectionView.isUserInteractionEnabled = false
        let activity = UIActivityIndicatorView(style: .medium)
        activity.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: activity)

        Task { @MainActor in
            defer {
                collectionView.isUserInteractionEnabled = true
                navigationItem.rightBarButtonItem = nil
            }
            do {
                let store = try CredentialStore()
                let client = ConvenienceStorePickupClient(store: store, keyring: .app())
                let context = try await client.beginSevenElevenPickup()
                let disclosure = try client.disclosure(for: context)
                navigationController?.pushViewController(
                    ConvenienceStorePickupConsentViewController(
                        context: context, client: client, disclosure: disclosure),
                    animated: true)
            } catch {
                presentTelecomAlert(title: NSLocalizedString("7-ELEVEN parcel pickup", comment: "pickup title"),
                                    message: UserFacingError.pickupMessage(for: error))
            }
        }
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            var content = cell.defaultContentConfiguration()
            content.image = item.image
            // Template icons take the single app accent (design system §2); a
            // disabled row renders entirely in the secondary colour so its state
            // is visible before it is tapped.
            content.imageProperties.tintColor = item.isEnabled ? .tintColor : .secondaryLabel
            // Plain text with `textProperties` — an attributed font is frozen at
            // configure time and ignores mid-session Dynamic Type changes.
            content.text = item.title
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.textProperties.color = item.isEnabled ? .label : .secondaryLabel
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
        let brandRegistration = UICollectionView.SupplementaryRegistration<BrandHeaderView>(
            elementKind: BrandHeaderView.elementKind
        ) { [weak self] headerView, _, _ in
            headerView.configure(title: NSLocalizedString("Use", comment: ""))
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

extension UseViewController {

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        // A disabled row already says why it is disabled on the row itself.
        guard item.isEnabled else { return }

        // The identical dispatch the home screen used before these rows moved, so
        // every action still reaches the same destination and does the same thing.
        switch item.title {
        case Row.collect:
            ScanToCollect.begin(on: navigationController)
        case Row.applyTelecom:
            // The row that needs no card: it *starts* an application. The source
            // cell is captured for the action sheet's iPad popover anchor before
            // the await, because the collection view may recompose while the
            // catalogue is fetched.
            applyTelecomCard(anchorCell: collectionView.cellForItem(at: indexPath))
        case Row.pickupBarcode:
            startSevenElevenPickup()
        case Row.present:
            navigationController?.pushViewController(PresentCredentialViewController(), animated: true)
        case Row.verify:
            navigationController?.pushViewController(VerifierViewController(), animated: true)
        case Row.createAgeProof:
            AgePredicateProofHolderFlow.begin(on: navigationController)
        case Row.prepareOffline:
            navigationController?.pushViewController(OfflinePreparationViewController(), animated: true)
        case Row.verifyAgeProof:
            navigationController?.pushViewController(
                AgePredicateProofVerifierViewController(), animated: true)
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
