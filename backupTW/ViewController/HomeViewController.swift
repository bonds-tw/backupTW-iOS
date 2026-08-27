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
        static let collect = NSLocalizedString("Add a card by scanning", comment: "")
        static let presentOnline = NSLocalizedString("Present a card to a verifier", comment: "")
        static let present = NSLocalizedString("Show my document", comment: "")
        static let verify = NSLocalizedString("Check someone else's document", comment: "")
        static let verifyProof = NSLocalizedString("Check a zero-knowledge proof", comment: "")
        static let compare = NSLocalizedString("What each of these cards is worth", comment: "")
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
        return [validDocumentSection(cards: rows),
                offlineSection(hasDocument: rows?.contains { $0.source == .selfIssued } ?? false,
                               storeIsReadable: rows != nil)]
    }

    /// Every card this phone holds, not only the one this app issues.
    ///
    /// The section used to be a single row for the self-issued document, which
    /// was the whole truth while that was the only thing the store could hold.
    /// A card collected from 數位憑證皮夾 would have been saved successfully and
    /// then been invisible — the same class of defect as the one the comment on
    /// `makeSections` describes, and with the same consequence: a person with no
    /// evidence their card arrived goes and collects it again.
    ///
    /// Named fields are still not summarised here. The home screen is the most
    /// over-the-shoulder-readable surface in the app, so rows carry the card's
    /// *kind* and its dates and nothing out of its claims. That rule is enforced
    /// in `CardInventory`, where it can be tested, not here.
    /// - Parameter rows: `nil` when the store would not open, which is a
    ///   different screen from an empty one.
    private func validDocumentSection(cards rows: [CardInventoryRow]?) -> Section {
        // Not 「正式證件」 any more. That header is the onboarding screen's, where
        // it names the document about to be created; over a list that can now
        // contain an expired card and a card this build cannot read, it would be
        // the section itself making a claim the rows underneath contradict.
        let title = "🔐 " + NSLocalizedString("My cards", comment: "home section")

        // Keyed to *our own* document, not to whether any card exists.
        //
        // Found by rendering the screen with a government card and no
        // self-issued one: the row read 「重新抓一次，取代目前存的這份」 while
        // there was nothing of ours stored to replace. This row only ever
        // creates or replaces the MyData-backed document, so a card of some
        // other kind must not change what it says.
        guard let rows else {
            // No 「create one」 row at all. That is the single instruction that
            // would cost a second 戶籍謄本 and a second 身分證統一編號 — and
            // issuance saves through the constructor that has just failed, so it
            // would fail again after collecting them.
            return Section(title: title, items: [
                Item(image: UIImage(systemName: "externaldrive.badge.exclamationmark")?
                        .withTintColor(.systemOrange, renderingMode: .alwaysOriginal),
                     title: NSLocalizedString("This phone's cards cannot be read right now", comment: ""),
                     secondaryText: NSLocalizedString("Anything saved here is still saved. This most often means the phone is out of space — free some up and open the app again.", comment: ""))
            ])
        }

        let hasOwnDocument = rows.contains { $0.source == .selfIssued }
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

        // Collecting an official card by scanning its QR. Present whether or not
        // a self-issued document exists — the official flow (「皮夾夥伴卡」) is
        // independent of MyData, and a fresh install collecting a government card
        // first is a real path. This is the entry the wallet was missing: the
        // scanner otherwise only opened for presentation and verification, so an
        // official credential-offer QR had nowhere to be pointed.
        let collect = Item(image: UIImage(systemName: "qrcode.viewfinder")?
                            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                           title: Row.collect,
                           secondaryText: NSLocalizedString(
                            "Point the camera at a QR from 數位憑證皮夾 to add its card.", comment: ""))

        guard !rows.isEmpty else {
            return Section(title: title, items: [refresh, collect])
        }

        // The row that carries the milestone's argument onto the screen people
        // actually open. Last, not first: the comparison only means anything to
        // somebody who has just seen that they hold more than one kind of thing.
        let compare = Item(image: UIImage(systemName: "list.bullet.rectangle")?
                            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                           title: Row.compare,
                           secondaryText: NSLocalizedString(
                            "What a checker can rely on, and what none of them can establish.", comment: ""))

        // Presenting an official card online — the mirror of collecting one, and
        // the wallet's whole point next to it: scan the verifier's request, then
        // choose which of the asked-for fields to actually reveal. Shown only
        // once there is a card to present; a self-issued document is not a TWDIW
        // credential and would find no match, so this leads with the cards that can.
        let presentOnline = Item(image: UIImage(systemName: "person.badge.shield.checkmark")?
                                    .withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                                 title: Row.presentOnline,
                                 secondaryText: NSLocalizedString(
                                    "Scan a verifier's QR and choose exactly what to show.", comment: ""))

        return Section(title: title, items: rows.map(item(for:)) + [refresh, collect, presentOnline, compare])
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

    /// # Why this takes the document state
    ///
    /// It used to be a constant, so 「出示我的證件」 promised 「掃描查驗者的條碼
    /// 並回應」 on a phone with nothing stored — and the screen it opens is 600pt
    /// of empty with no button on it. That is the most expensive empty state in
    /// the app, because the place it is discovered is in front of a checker.
    ///
    /// The row is not hidden. Hiding it would make the app look like it cannot
    /// do the thing it is for, and this screen's job is to say what this phone
    /// can do *right now* — which is what the neighbouring `proofRowSubtitle()`
    /// already does for the checking files.
    private func offlineSection(hasDocument: Bool, storeIsReadable: Bool = true) -> Section {
        // Both halves live on the home screen rather than one of them being
        // buried in Settings. The whitepaper's §5.3 scenarios are a 里長, a
        // volunteer, a border desk — people who are checking documents as their
        // task, not adjusting a preference — and the two roles swap between the
        // same two phones within a minute of each other.
        Section(title: "📶 " + NSLocalizedString("Offline check", comment: ""), items: [
            Item(image: UIImage(systemName: "qrcode")?
                    .withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
                 title: Row.present,
                 // Neutral when the store would not open. 「There is nothing on
                 // this phone to show yet」 is an unconditional statement of fact
                 // about the reader's own phone, and in that state it is false.
                 secondaryText: !storeIsReadable
                    ? NSLocalizedString("This phone's cards cannot be read right now.", comment: "")
                    : hasDocument
                    ? NSLocalizedString("Answer a checker's code. Neither phone needs a network.", comment: "")
                    : NSLocalizedString("Add your ID first, then you can show it to a checker.", comment: "")),
            Item(image: UIImage(systemName: "checkmark.shield")?
                    .withTintColor(.systemTeal, renderingMode: .alwaysOriginal),
                 title: Row.verify,
                 secondaryText: NSLocalizedString("Scan someone's document to check it is genuine — no network needed.", comment: "")),
            // The proof half of the checker's job, next to the credential half
            // rather than in Settings, for the reason above: the 里長 and the
            // border desk are doing one task, and which kind of thing they were
            // handed is not their problem to route.
            Item(image: UIImage(systemName: "eye.slash")?
                    .withTintColor(.systemPurple, renderingMode: .alwaysOriginal),
                 title: Row.verifyProof,
                 secondaryText: Self.proofRowSubtitle())
        ])
    }

    /// Whether this phone can actually check a proof, said on the row itself.
    ///
    /// The generic sentence sent people into the screen to find out; the state
    /// was knowable from here. Both variants state a *local* fact — files
    /// present or files missing — and neither implies anything about any proof
    /// being valid: readiness is not a verdict, so no tick, no colour.
    ///
    /// Keyed to `ZKVerifyingKeyAssets.all` — the exact set the destination
    /// screen's `ZKPackageVerifier` gates on — and not to
    /// `CircuitAssets.required`, which this first checked. The review that
    /// caught it: `required` is the *prover's* set (proving keys + revocation
    /// snapshot), so a phone whose verifying keys were derived but whose
    /// proving keys were reclaimed would read 「尚未下載」 on a row that opens a
    /// screen that works. A readiness sentence keyed to a different screen's
    /// prerequisites is a sentence about nothing.
    private static func proofRowSubtitle() -> String {
        // One copy of the question, in `ZKVerifyingKeyAssets`. It lived here, so
        // the screen that actually checks proofs could not ask it.
        if ZKCheckingAvailability.current.canCheck {
            return NSLocalizedString("Verify a zero-knowledge proof. The checking files are on this phone.", comment: "")
        }
        // 「not downloaded **yet**」 is a promise, and in a shipping build it is
        // permanently false.
        //
        // The only entry point that downloads these files sits behind
        // `ZKProofRunAssembly.makeSigner`, which returns nil in a release build
        // — so 「yet」 describes a future that this binary cannot reach. The
        // person who pays for that sentence is the one on the other phone, who
        // spends twenty seconds sending a proof of their identity to a device
        // that was never able to check it.
        //
        // The right fix is upstream and is written down: **downloading and
        // signing should not be the same gate**, because a checker needs the
        // verifying keys and does not need to sign anything. Until then the row
        // says which of the two situations this actually is.
        // The two situations are told apart by `ZKCheckingAvailability` now, so
        // this row and the checking screen cannot drift into different tenses.
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

        title = NSLocalizedString("Bond", comment: "")
        navigationController?.navigationBar.prefersLargeTitles = true
        // different title for tabBarItem needs to be set after setting title (avoid being overwritten)
        tabBarItem = UITabBarItem(title: NSLocalizedString("Home", comment: ""),
                                  image: UIImage(systemName: "house.fill"), selectedImage: nil)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)

        configureDataSource()
        applySnapshot()
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
        case Row.compare:
            navigationController?.pushViewController(CapabilityViewController(), animated: true)
        case Row.backUp:
            let vc = MyDataOnboardViewController()
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case Row.collect:
            ScanToCollect.begin(on: navigationController)
        case Row.presentOnline:
            ScanToPresent.begin(on: navigationController)
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

    /// What tapping a card does — including when the answer is "nothing yet".
    ///
    /// Only the self-issued document has a detail screen.
    /// `StoredCredentialViewController` reads `StoredNationalID.load()`, which is
    /// keyed to one fixed identifier, so pushing it for a government card would
    /// show the holder **a different card's contents under the row they
    /// tapped** — the worst available outcome, and the one that happens by
    /// default if this method does not exist.
    ///
    /// So the government card says plainly that this build lists it but cannot
    /// open it, and offers the one thing it genuinely can answer. A row that
    /// silently did nothing would read as a bug, and a row that pretended would
    /// be one.
    private func open(_ card: CardInventoryRow) {
        if card.source == .selfIssued, card.state == .usable {
            navigationController?.pushViewController(StoredCredentialViewController(), animated: true)
            return
        }

        // This alert **is** the screen the row promises, because there is no
        // other one. It used to assert 「this build cannot read it」, which is a
        // confident claim in the one branch that cannot support one: it is
        // reached by a malformed card *and* by a well-formed card whose
        // signature does not verify, and telling the two apart is exactly what
        // failed. `CardInventory`'s comment says the row stays silent because
        // 「the screen that can explain properly does the explaining」 — so this
        // one now explains, including the part that is not known.
        let message: String
        switch card.state {
        case .unreadable:
            message = String(format: NSLocalizedString(
                "Something about it did not come out right, and this build cannot tell which: the stored file may be damaged, or its signature may not match. It is listed here so you know it was not lost. Stored as %@.",
                comment: ""), card.id)
        default:
            message = NSLocalizedString("It is stored on this phone and was read correctly. There is no screen for its contents yet.", comment: "")
        }
        let alert = UIAlertController(
            title: card.state == .unreadable
                ? NSLocalizedString("This card could not be read or checked", comment: "")
                : NSLocalizedString("This version cannot open this card", comment: ""),
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
