//
//  GovernmentCardViewController.swift
//  backupTW
//

import UIKit

/// Shows a government card (a 數位憑證皮夾 card such as a 駕照電子卡 or a
/// 皮夾夥伴卡) the holder collected onto this phone.
///
/// # The gap this fills
///
/// The store could already hold a TWDIW card and the home screen could already
/// list it, but tapping it hit a dead end: `HomeViewController.open(_:)` put up
/// an alert saying "this version cannot open this card" while
/// `TWDIWCredentialReader` had already decoded every disclosed field into
/// memory. The card was listable and un-openable — the wallet could say a card
/// existed and never show what was in it. This screen is the other side of that
/// tap.
///
/// # Why this mirrors `StoredCredentialViewController` and does not reuse it
///
/// The holder's own self-issued document and a government card are read from two
/// different envelopes — `StoredNationalID` decodes a device- or card-signed
/// VCDM credential, this decodes an SD-JWT through `TWDIWCredentialReader` — so
/// the two screens cannot share a data source. What they *do* share, and what is
/// copied deliberately, is the discipline: the sensitive fields sit behind one
/// tap, the tap says what is about to be shown, backgrounding closes them again,
/// and the screen is on `PrivacyShield`'s list. A person reading a government
/// card is in exactly the same over-the-shoulder situation as one reading their
/// own ID, so it gets exactly the same treatment.
///
/// # Honesty about revocation is the load-bearing part
///
/// A TWDIW card's revocation state can only be known online, and the status list
/// that carries it is signed by a key that is in no DID this phone can check
/// (see `TWDIWCredential`'s note and `CardCapability.twdiw.limits`). So this
/// screen never says the card "is valid" — the issuer's *signature* verified
/// offline (reaching a decoded credential at all means it did), and that is a
/// different and smaller claim than "not revoked", which this build cannot make.
/// Both are stated as themselves.
final class GovernmentCardViewController: UICollectionViewController {

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

    /// The two things reading a stored card can end in. Kept as a value rather
    /// than an optional credential so that "could not be read" carries its own
    /// honest sentence instead of collapsing into a blank screen — the exact
    /// mistake `CardInventory` documents at length for the home screen.
    enum Content: Equatable {
        case card(TWDIWCredential)
        /// The card could not be turned into something to show, with a sentence
        /// saying which of the several honest reasons it was.
        case unreadable(reason: String)

        static func == (lhs: Content, rhs: Content) -> Bool {
            switch (lhs, rhs) {
            case let (.card(a), .card(b)): return a == b
            case let (.unreadable(a), .unreadable(b)): return a == b
            default: return false
            }
        }
    }

    private let credentialID: String

    /// Injectable so a test can point the screen at an in-memory store; `nil`
    /// resolves to the real `CredentialStore` at read time. Resolved lazily
    /// rather than in `init` because constructing the store can itself throw,
    /// and a card screen that cannot be constructed is worse than one that opens
    /// and says the store would not open.
    private let store: CredentialStoring?

    private var dataSource: UICollectionViewDiffableDataSource<Group, Row>!
    private var groups: [Group] = []
    private var isRevealed = false
    private var content: Content = .unreadable(reason: "")

    init(id: String, store: CredentialStoring? = nil) {
        self.credentialID = id
        self.store = store
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = CardCapability.twdiw.name
        configureDataSource()
        reload()

        // Same reasoning as `StoredCredentialViewController`: hide the revealed
        // fields on the return trip from the background, not on a transient
        // interruption. `didEnterBackground` and not `willResignActive`, so an
        // incoming-call banner does not yank the fields shut mid-comparison and
        // teach people to stop using the hide step. The app-switcher snapshot
        // itself is covered by `PrivacyShield`.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRevealed else { return }
            self.isRevealed = false
            self.applySnapshot()
        }
    }

    /// Held so the observation dies with the screen. The block API's token is
    /// not auto-removed: discarding it leaves a live observer behind every visit.
    private var backgroundObserver: NSObjectProtocol?

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    // MARK: - Reading

    /// Loads the stored card and decodes it, or produces the honest reason it
    /// could not be decoded.
    ///
    /// A pure function over an injected store so the mapping from "what went
    /// wrong" to "what the screen says" can be tested without the view
    /// lifecycle. Every failure path a real read has is preserved and named:
    /// the store not opening, the file being unreadable back (most importantly a
    /// locked device), the card being absent, and each `TWDIWCredentialError`.
    /// None of them force-unwrap, and none of them pretend the card is fine.
    static func read(id: String,
                     from store: CredentialStoring?,
                     now: Date = Date()) -> Content {
        guard let store else {
            return .unreadable(reason: NSLocalizedString(
                "This phone's cards cannot be read right now. Anything saved here is still saved.",
                comment: "Government card detail: the credential store would not open"))
        }

        let serialized: String?
        do {
            serialized = try store.load(id: id)
        } catch {
            // Reaches here for a genuinely damaged file and, more often, for a
            // locked device whose class-B credential file cannot be read. Both
            // are "not right now", not "you do not have it".
            return .unreadable(reason: NSLocalizedString(
                "This card could not be read right now. It may be that the phone is locked, or the stored file is damaged.",
                comment: "Government card detail: load threw"))
        }
        guard let serialized else {
            return .unreadable(reason: NSLocalizedString(
                "This card is no longer stored on this phone.",
                comment: "Government card detail: nothing stored under this id"))
        }

        do {
            return .card(try TWDIWCredentialReader.read(serialized, now: now))
        } catch let error as TWDIWCredentialError {
            return .unreadable(reason: message(for: error))
        } catch {
            return .unreadable(reason: NSLocalizedString(
                "This card could not be read, and this build cannot tell why.",
                comment: "Government card detail: unexpected error"))
        }
    }

    /// A true sentence for each way a TWDIW card fails to decode.
    ///
    /// This screen is the one the home row promised would "do the explaining",
    /// so unlike the glanceable list it may name what went wrong — as long as it
    /// stays honest about the one case that genuinely cannot be told apart:
    /// `signatureInvalid` is reached both by a damaged file and by a card
    /// re-signed by somebody else, and this build cannot distinguish them, so it
    /// says both rather than picking one.
    static func message(for error: TWDIWCredentialError) -> String {
        switch error {
        case .malformedCompactSerialization, .malformedJSON, .malformedDisclosure:
            return NSLocalizedString(
                "The stored file is not complete enough to read. It is most likely damaged.",
                comment: "")
        case .unsupportedAlgorithm(let alg):
            return String(format: NSLocalizedString(
                "This card is signed in a way this version does not accept (%@).", comment: ""), alg)
        case .unexpectedType(let type):
            return String(format: NSLocalizedString(
                "This card is in a format this version does not recognise (%@).", comment: ""), type)
        case .unsupportedDigestAlgorithm(let alg):
            return String(format: NSLocalizedString(
                "This card commits to its fields using a method this version does not support (%@).",
                comment: ""), alg)
        case .missingClaim:
            return NSLocalizedString(
                "This card is missing something it needs to be read.", comment: "")
        case .unresolvableIssuer:
            return NSLocalizedString(
                "This build could not turn the issuer's identifier into a key to check the card with.",
                comment: "")
        case .signatureInvalid:
            // The one that must not become an accusation from certainty: it is
            // reached by a well-formed card whose signature does not match as
            // well as by a damaged one, and telling them apart is exactly what
            // failed. Say both.
            return NSLocalizedString(
                "This card's signature did not check out. The stored file may be damaged, or it may not have been signed by the issuer it names — this build cannot tell which.",
                comment: "")
        case .undisclosedDigest:
            return NSLocalizedString(
                "This card includes a field the issuer never signed for, so it is not shown. A card that could add one could claim anything.",
                comment: "")
        }
    }

    // MARK: - Content

    private func reload() {
        content = Self.read(id: credentialID, from: resolvedStore())
        applySnapshot()
    }

    /// The injected store, or the real one. `try?` on purpose: a store that will
    /// not construct becomes `nil`, and `read(id:from:)` turns that into the
    /// honest "cannot be read right now" rather than a crash.
    private func resolvedStore() -> CredentialStoring? {
        store ?? (try? CredentialStore())
    }

    /// Rebuilds the list from the `content` already in memory, without touching
    /// the disk — so the backgrounding observer can hide the fields without a
    /// re-read that a locking device is entitled to fail.
    private func applySnapshot() {
        groups = buildGroups(now: Date())
        var snapshot = NSDiffableDataSourceSnapshot<Group, Row>()
        for group in groups {
            snapshot.appendSections([group])
            snapshot.appendItems(group.rows, toSection: group)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func buildGroups(now: Date) -> [Group] {
        switch content {
        case .unreadable(let reason):
            return [Group(id: "unreadable",
                          title: "",
                          rows: [Row(id: "unreadable",
                                     title: NSLocalizedString("This card could not be opened", comment: ""),
                                     value: reason,
                                     isSensitive: false, isAction: false)])]
        case .card(let credential):
            return cardGroups(credential, now: now)
        }
    }

    private func cardGroups(_ credential: TWDIWCredential, now: Date) -> [Group] {
        var groups: [Group] = []

        // MARK: This card — kind, issuer, validity. None of it is a personal
        // field, so it is shown without the reveal step.
        var aboutRows: [Row] = [
            Row(id: "about.kind",
                title: NSLocalizedString("Card type", comment: ""),
                // The card's only offline name is `vc.type[1]`, an issuer code.
                // Stripped to the readable middle and put through the untrusted
                // pipe, exactly as the home row does — the type is chosen by the
                // issuer and a bidi override in it would rearrange the screen.
                value: UntrustedText.value(CardInventory.readableType(credential.credentialType)).text,
                isSensitive: false, isAction: false),
            Row(id: "about.issuer",
                title: NSLocalizedString("Issued by", comment: ""),
                // The issuer's DID, shown as itself. It is not a personal field
                // — it identifies the issuing body, not the holder — so it is
                // not behind the reveal. Sanitised anyway: it is a string that
                // arrived inside the card.
                value: UntrustedText.value(credential.issuerDID).text,
                isSensitive: false, isAction: false),
            Row(id: "about.validFrom",
                title: NSLocalizedString("Valid from", comment: ""),
                value: Self.dateFormatter.string(from: credential.notBefore),
                isSensitive: false, isAction: false)
        ]
        aboutRows.append(validityRow(credential, now: now))
        groups.append(Group(id: "about",
                            title: NSLocalizedString("This card", comment: ""),
                            rows: aboutRows))

        // MARK: What this check did and did not establish. The honest core. Built
        // here but appended below the disclosed fields, so the page reads
        // 這張卡片 → 欄位 → 可以確認的部分.
        let trustGroup = Group(
            id: "trust",
            title: NSLocalizedString("What can be confirmed", comment: ""),
            rows: [
                Row(id: "trust.signature",
                    title: NSLocalizedString("Issuer's signature", comment: ""),
                    // True and offline-checkable: reaching a decoded credential
                    // means `TWDIWCredentialReader.read` verified the JWS
                    // against the key in the issuer's own DID. That is all it
                    // means — see the next row.
                    value: NSLocalizedString(
                        "Checked on this phone, with no network. The issuer's own key signed these fields.",
                        comment: ""),
                    isSensitive: false, isAction: false),
                Row(id: "trust.revocation",
                    title: NSLocalizedString("Whether it was cancelled", comment: ""),
                    // The load-bearing caveat. The status list is signed by a
                    // key in no DID this phone holds, so revocation has no
                    // offline trust anchor at all. The screen refuses to imply
                    // the card is still valid.
                    value: credential.status == nil
                        ? NSLocalizedString(
                            "This card carries no cancellation list, so whether it was cancelled cannot be known from the card itself.",
                            comment: "")
                        : NSLocalizedString(
                            "Not shown. Whether this card was cancelled can only be known online, and the list that would say so is vouched for by nothing this phone can check offline. A signed card is not the same as one that is still valid.",
                            comment: ""),
                    isSensitive: false, isAction: false)
            ])

        // MARK: The disclosed fields, behind the same one tap as the holder's
        // own ID — the situation that makes them sensitive is identical.
        let claims = credential.disclosedClaims
        if claims.isEmpty {
            groups.append(Group(
                id: "fields",
                title: NSLocalizedString("Fields", comment: ""),
                rows: [Row(id: "fields.none",
                           title: NSLocalizedString("This card discloses no fields.", comment: ""),
                           value: "", isSensitive: false, isAction: false)]))
        } else if isRevealed {
            groups.append(Group(
                id: "fields",
                title: NSLocalizedString("Fields", comment: ""),
                rows: claims.enumerated().map { index, claim in
                    Row(id: "field.\(index)",
                        title: Self.fieldHeading(for: claim.name),
                        value: UntrustedText.value(claim.value).text,
                        isSensitive: true, isAction: false)
                }))
            groups.append(Group(id: "hide", title: "", rows: [
                Row(id: "hide.action",
                    title: NSLocalizedString("Hide the fields", comment: ""),
                    value: "", isSensitive: false, isAction: true)
            ]))
        } else {
            groups.append(Group(id: "reveal", title: "", rows: [
                Row(id: "reveal.action",
                    title: String(format: NSLocalizedString("Show %d fields", comment: ""),
                                  claims.count),
                    value: NSLocalizedString(
                        "These are personal details from the card. Check who can see your screen.",
                        comment: ""),
                    isSensitive: false, isAction: true)
            ]))
        }

        // 「可以確認的部分」 last: 這張卡片 → 欄位 → 可以確認的部分.
        groups.append(trustGroup)

        return groups
    }

    /// `.distantFuture` is `TWDIWCredentialReader`'s stand-in for a card that
    /// carries no `exp` at all, so it must never be printed as a year-4001 date
    /// — that would turn a statement the issuer never made into a confident one,
    /// the failure this whole app is written against (the same guard
    /// `CardInventory` keeps).
    private func validityRow(_ credential: TWDIWCredential, now: Date) -> Row {
        if credential.expires == .distantFuture {
            return Row(id: "about.validUntil",
                       title: NSLocalizedString("Valid until", comment: ""),
                       value: NSLocalizedString("No expiry date is given on this card.", comment: ""),
                       isSensitive: false, isAction: false)
        }
        let formatted = Self.dateFormatter.string(from: credential.expires)
        if credential.expires <= now {
            return Row(id: "about.validUntil",
                       title: NSLocalizedString("Valid until", comment: ""),
                       value: String(format: NSLocalizedString("%@ — expired", comment: ""), formatted),
                       isSensitive: false, isAction: false)
        }
        return Row(id: "about.validUntil",
                   title: NSLocalizedString("Valid until", comment: ""),
                   value: formatted,
                   isSensitive: false, isAction: false)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    /// The heading for a disclosed field.
    ///
    /// Delegates to `ClaimLabel`, which is the app's single table of field
    /// names: a term this build knows becomes the app's own localised noun (so
    /// the checker and the holder read the words printed on the physical card),
    /// and a term it does not know is never presented as this app's own heading
    /// — it is quoted inside a sentence the app wrote. That framing is the fix
    /// `UntrustedText` documents: a driving-licence field this build has not met
    /// (`controlnumber`, `gDate`) is shown honestly as the document's own key
    /// rather than given a Chinese label this app invented for it.
    static func fieldHeading(for term: String) -> String {
        ClaimLabel.label(for: term).heading
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
                // Monospaced and scaled, so an ID number can be read off a digit
                // at a time and compared against a card without miscounting —
                // the same treatment `StoredCredentialViewController` gives its
                // sensitive values, and it scales with Dynamic Type for the
                // reason recorded there.
                content.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .body)
                    .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
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
        // Rebuild from what is already in memory: revealing does not need a
        // re-read, and a re-read is the thing a locking device may refuse.
        applySnapshot()
    }
}
