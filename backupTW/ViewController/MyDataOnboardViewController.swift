//
//  MyDataOnboardViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/8/11.
//

import UIKit

private let reuseIdentifier = "MyDataOnboardCell"

/// The four human-visible hand-offs in one MyData request. Both the preparation
/// screen and the web screen render this same model, so the explanation cannot
/// drift away from the stage the browser is actually in.
enum MyDataFlowStep: Int, CaseIterable {
    case details, certificate, returnToBonds, download

    var shortTitle: String {
        switch self {
        case .details: return NSLocalizedString("Details", comment: "short MyData flow step")
        case .certificate: return NSLocalizedString("Certificate", comment: "short MyData flow step")
        case .returnToBonds: return NSLocalizedString("Return", comment: "short MyData flow step")
        case .download: return NSLocalizedString("Download", comment: "short MyData flow step")
        }
    }
}

/// One compact, linked progress strip. It replaces four independent list rows:
/// the connecting rule communicates sequence and the current step is exposed as
/// one accessibility value rather than four unrelated announcements.
final class MyDataFlowProgressView: UIView {
    private let line = UIView()
    private let stack = UIStackView()
    private var dots: [UILabel] = []
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "mydata.flow.steps"

        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = .separator
        addSubview(line)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for step in MyDataFlowStep.allCases {
            let dot = UILabel()
            dot.textAlignment = .center
            dot.font = .preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
            dot.adjustsFontForContentSizeCategory = true
            dot.layer.cornerRadius = 12
            dot.clipsToBounds = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 24),
                dot.heightAnchor.constraint(equalToConstant: 24),
            ])

            let label = UILabel()
            label.text = step.shortTitle
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .caption2)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
            label.minimumScaleFactor = 0.75
            label.adjustsFontSizeToFitWidth = true

            let column = UIStackView(arrangedSubviews: [dot, label])
            column.axis = .vertical
            column.alignment = .center
            column.spacing = 5
            stack.addArrangedSubview(column)
            dots.append(dot)
            labels.append(label)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 2),
            line.centerYAnchor.constraint(equalTo: topAnchor, constant: 12),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),
        ])
        configure(current: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `nil` is the pre-flight overview. Once the government page is open, the
    /// active stage and everything already completed are visually distinct.
    func configure(current: MyDataFlowStep?, completed: Bool = false) {
        for (index, dot) in dots.enumerated() {
            let isPast = completed || (current.map { index < $0.rawValue } ?? false)
            let isCurrent = !completed && current?.rawValue == index
            dot.text = isPast ? "✓" : "\(index + 1)"
            dot.backgroundColor = (isPast || isCurrent) ? .systemBlue : .tertiarySystemFill
            dot.textColor = (isPast || isCurrent) ? .white : .secondaryLabel
            labels[index].textColor = isCurrent ? .label : .secondaryLabel
            labels[index].font = isCurrent
                ? .preferredFont(forTextStyle: .caption2).withTraits(.traitBold)
                : .preferredFont(forTextStyle: .caption2)
        }
        line.backgroundColor = current == nil ? .separator : .systemBlue.withAlphaComponent(0.45)
        if completed {
            accessibilityValue = NSLocalizedString("Completed", comment: "MyData flow status")
        } else if let current {
            accessibilityValue = String(format: NSLocalizedString("Step %lld of 4: %@", comment: "MyData flow accessibility"),
                                        Int64(current.rawValue + 1), current.shortTitle)
        } else {
            accessibilityValue = NSLocalizedString("Four steps", comment: "MyData flow overview")
        }
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

private final class MyDataFlowOverviewCell: UICollectionViewCell {
    private let progress = MyDataFlowProgressView()
    private let note = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = .secondarySystemGroupedBackground
        background.cornerRadius = 14
        backgroundConfiguration = background

        progress.translatesAutoresizingMaskIntoConstraints = false
        note.font = .preferredFont(forTextStyle: .footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.textAlignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progress)
        contentView.addSubview(note)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            progress.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            note.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            note.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        accessibilityIdentifier = "mydataOnboard.flow"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(estimatedMinutes: Int?, entryMode: MyDataDocumentType.EntryMode) {
        progress.configure(current: nil)
        if entryMode == .personalDocuments {
            note.text = NSLocalizedString(
                "Sign in once, then keep this screen open and download all completed files. MyData may still require identity verification for each new request.",
                comment: "MyData Personal documents multi-file overview")
        } else if let estimatedMinutes {
            note.text = String(format: NSLocalizedString("MyData may take about %lld minutes. You can leave and continue later from Personal documents.", comment: "MyData slow document overview"), Int64(estimatedMinutes))
        } else {
            note.text = NSLocalizedString("After signing, return here to download and save the file in this iPhone.", comment: "MyData flow overview")
        }
    }
}

class MyDataOnboardViewController: UICollectionViewController {

    /// The key this device's national ID credential is filed under.
    ///
    private var isMobileMoicaReady: Bool {
        let mobileMoicaURLScheme = "mobilemoica://"
        let mobileMoicaURL = URL(string: mobileMoicaURLScheme)!
        let isMobileMoicaReady = UIApplication.shared.canOpenURL(mobileMoicaURL)
        return isMobileMoicaReady
    }

    private enum Section: Int, CaseIterable {
        case cover, guidance, profile, data
    }
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    /// # Why the cover states the build's limit before anything is spent
    ///
    /// `CredentialIssuanceAssembly.make()` returns nil in a release build, and
    /// that is a compile-time fact. The screen only found out at
    /// `issueCredential(for:)` — by which point the holder had authenticated to
    /// a government service, downloaded their entire household record, and typed
    /// their 身分證統一編號 into a decryption box.
    ///
    /// **The cost of the late answer is not bandwidth, it is identity data.**
    /// `ZKProofViewController` already wrote this principle down; it had just
    /// never been applied to this path.
    private var coverItem: Item
    private var items: [Item]

    /// Which document this run fetches and stores. Defaults to the national ID (the
    /// historical single-document flow). A vault import passes its own type, so the
    /// signed result is stored under that type's id and surfaces in the 資料保險箱
    /// rather than as the national ID. The MyData fetch mechanism (行動自然人憑證 →
    /// the household record) is shared: vault documents reuse the national ID's path
    /// and data until each gets its own (「路徑與身分證資料一致」).
    private let documentType: MyDataDocumentType

    private var isNationalID: Bool { documentType.id == MyDataDocumentRegistry.nationalID.id }
    private var canProceed: Bool { !isNationalID || CredentialIssuanceAssembly.isAvailable }

    private let guidanceItem = Item(title: "MyData flow", secondaryText: "",
                                    identifier: "mydata.flow")

    private var profileItem: Item {
        let saved = MyDataAutofillProfileStore.load() != nil
        return Item(
            image: UIImage(systemName: saved ? "checkmark.shield.fill" : "person.crop.circle.badge.plus"),
            title: NSLocalizedString("Remember MyData details on this iPhone", comment: "MyData profile row"),
            secondaryText: saved
                ? NSLocalizedString("Saved in Keychain · tap to change or forget", comment: "MyData profile row")
                : NSLocalizedString("Optional · saves repeated ID number and birth-date entry", comment: "MyData profile row"),
            identifier: "mydata.profile")
    }

    init(documentType: MyDataDocumentType = MyDataDocumentRegistry.nationalID) {
        self.documentType = documentType
        if documentType.id == MyDataDocumentRegistry.nationalID.id {
            self.coverItem = CredentialIssuanceAssembly.isAvailable
                ? Item(image: Self.statusImage("person.text.rectangle", colour: .systemBlue),
                       title: NSLocalizedString("Create a Valid Document", comment: ""),
                       secondaryText: NSLocalizedString("You will use TW FiDO to retrieve your National ID data, and create a valid document.", comment: ""))
                : Item(image: Self.statusImage("xmark.shield.fill", colour: .systemOrange),
                       title: NSLocalizedString("This version cannot create a document", comment: ""),
                       secondaryText: NSLocalizedString("Signing needs a service this build cannot reach, so the document could not be created even after fetching your data. Nothing is fetched.", comment: ""))
            self.items = []
        } else {
            let summary: String
            if documentType.entryMode == .personalDocuments {
                summary = NSLocalizedString(
                    "Sign in once, then keep this screen open and download all completed files. MyData may still require identity verification for each new request.",
                    comment: "MyData Personal documents multi-file overview")
            } else {
                summary = NSLocalizedString("The downloaded original will be protected in the data vault on this iPhone.", comment: "")
            }
            self.coverItem = Item(
                image: Self.statusImage("tray.and.arrow.down.fill", colour: .systemBlue),
                title: NSLocalizedString("Import from Taiwan MyData", comment: "MyData document import title"),
                secondaryText: summary)
            self.items = []
        }
        let layout = UICollectionViewCompositionalLayout() { sectionIndex, layoutEnvironment in
            let shouldShowHeaderFooter = (sectionIndex != 0)
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = shouldShowHeaderFooter ? .supplementary : .none
            configuration.footerMode = shouldShowHeaderFooter ? .supplementary : .none
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: layoutEnvironment)
            return section
        }
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = isNationalID ? NSLocalizedString("Valid Document", comment: "") : documentType.title
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        // # The button obeys the same fact the cover states
        //
        // The cover says 「因此不會去抓」 when this build cannot sign. That
        // sentence was added and **the button was not**, so pressing Continue
        // walked the person through the entire MyData flow — a full household
        // record downloaded, their 身分證統一編號 typed into a decryption prompt,
        // five identity fields on screen — before `issueCredential` reached
        // `CredentialIssuanceAssembly.make()` and gave up. Identity data spent,
        // nothing kept: the only `save` sits *after* `issue(...)`, which a
        // release build never reaches.
        //
        // The same commit got this right one screen over
        // (`ZKProofViewController` returns a row with `isEnabled: false`), so
        // this was an asymmetry inside one change rather than a policy. Copy and
        // behaviour each looked reasonable alone, which is exactly the shape.
        let proceed = UIBarButtonItem(title: NSLocalizedString("Continue", comment: ""),
                                      style: .done, target: self, action: #selector(nextAction))
        proceed.isEnabled = canProceed
        navigationItem.rightBarButtonItem = proceed
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)
        collectionView.allowsSelection = true

        configureDataSource()
        applySnapshot()
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            let section = Section(rawValue: indexPath.section)
            let isCover = section == .cover
            // The household address is structurally a long field, even when a
            // particular test value happens to be short.  Keeping it in the
            // trailing-value layout makes the value fight the title for width
            // and produces the clipped row seen on an iPhone.  Other long
            // MyData values get the same stacked treatment automatically.
            let isHouseholdAddress = self.isNationalID && section == .data && indexPath.item == 4
            let usesStackedValue = isHouseholdAddress
                || item.secondaryText.count > 18
                || item.secondaryText.contains("\n")
            var content = isCover || usesStackedValue
                ? UIListContentConfiguration.subtitleCell()
                : UIListContentConfiguration.valueCell()

            if isCover {
                // This is a short status summary, not another document title.
                // The large icon/title treatment repeated the navigation title
                // and pushed the actual flow below the first screenful.
                content.image = item.image
                content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
                content.textProperties.color = .label
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
                content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                    top: 14, leading: 16, bottom: 14, trailing: 16)
            } else {
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            }
            content.text = item.title
            content.secondaryText = item.secondaryText
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = .secondaryLabel
            content.textToSecondaryTextVerticalPadding = isCover ? 6 : 3
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = isCover
                ? "mydataOnboard.cover"
                : section == .profile ? "mydataOnboard.profile"
                : section == .data ? "mydataOnboard.data.\(indexPath.item)"
                : "mydataOnboard.row.\(indexPath.item)"
            cell.accessories = section == .profile ? [.disclosureIndicator()] : []
            cell.isUserInteractionEnabled = section == .profile
        }
        let flowRegistration = UICollectionView.CellRegistration<MyDataFlowOverviewCell, Item> {
            [weak self] cell, _, _ in
            cell.configure(estimatedMinutes: self?.documentType.estimatedMinutes,
                           entryMode: self?.documentType.entryMode ?? .directItem)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            if Section(rawValue: indexPath.section) == .guidance {
                return collectionView.dequeueConfiguredReusableCell(
                    using: flowRegistration, for: indexPath, item: item)
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration, for: indexPath, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { headerView, elementKind, indexPath in
            var content = headerView.defaultContentConfiguration()
            switch Section(rawValue: indexPath.section) {
            case .guidance:
                content.text = NSLocalizedString("What happens next", comment: "MyData guidance header")
            case .profile:
                content.text = NSLocalizedString("Make the next visit easier", comment: "MyData profile header")
            case .data:
                content.text = NSLocalizedString("Document information", comment: "")
            default:
                content.text = nil
            }
            headerView.contentConfiguration = content
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { footerView, elementKind, indexPath in
            var content = footerView.defaultContentConfiguration()
            switch Section(rawValue: indexPath.section) {
            case .profile:
                content.text = NSLocalizedString("Remembered details are stored in the iOS Keychain on this iPhone and filled only on mydata.nat.gov.tw.", comment: "MyData profile footer")
            case .data:
                content.text = NSLocalizedString("All information are stored only on your phone.", comment: "")
            default:
                content.text = nil
            }
            footerView.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            } else {
                return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
            }
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.cover])
        snapshot.appendItems([coverItem])
        snapshot.appendSections([.guidance])
        snapshot.appendItems([guidanceItem])
        snapshot.appendSections([.profile])
        snapshot.appendItems([profileItem])
        if !items.isEmpty {
            snapshot.appendSections([.data])
            snapshot.appendItems(items)
        }
        // This sheet changes from preparation to result in one state transition.
        // A diff animation makes the list re-anchor under the user's finger and
        // reads as the same vertical jump as the card stack.
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .profile else { return }
        navigationController?.pushViewController(
            MyDataProfileViewController { [weak self] in self?.applySnapshot() }, animated: true)
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func nextAction() {
        // Belt as well as braces. The disabled button is what a person sees; this
        // is what holds if some future path invokes the action another way —
        // a keyboard shortcut, a restored state, a test. The thing being
        // guarded is somebody's national ID number, so it is guarded twice.
        guard canProceed else { return }

        if isMobileMoicaReady {
            // The web controller resolves the entry URL from the document's item path
            // (guarded non-nil upstream) and archives the original for vault documents.
            let vc = MyDataWebViewController(documentType: documentType, completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .nationalID(let nationalIDModel):
                    self.showParsedDocument(nationalIDModel)
                    self.issueCredential(for: nationalIDModel)
                case .vaultDocument(let entry):
                    self.finishVaultImport(entry)
                }
            })
            vc.modalPresentationStyle = .fullScreen
            present(vc, animated: true)
        } else {
            // The check is `canOpenURL("mobilemoica://")`, which measures
            // exactly one thing: whether that app is installed on this phone.
            // It was reported as 「請先申請行動自然人憑證」 — an assertion about
            // the person, and a wrong one for the most ordinary case there is,
            // somebody who already has a 行動自然人憑證 and is holding a new
            // phone. They were sent off to apply for something they have.
            //
            // So the title states the local fact, and the two actions cover the
            // two real situations: install it, or apply for it.
            let alert = UIAlertController(
                title: NSLocalizedString("The TW FidO app is not on this phone", comment: ""),
                message: NSLocalizedString(
                    "This app cannot check whether you already have a 行動自然人憑證 — only whether the app that holds it is installed here.",
                    comment: ""),
                preferredStyle: .alert)
            let install = UIAlertAction(
                title: NSLocalizedString("Get the app", comment: ""),
                style: .default) { _ in
                    UIApplication.shared.open(
                        URL(string: "https://apps.apple.com/tw/app/id1523302632")!)
                }
            let confirm = UIAlertAction(
                title: NSLocalizedString("Go to Application Guide", comment: ""),
                style: .default) { _ in
                    let mobileMoicaOnboarding = "https://fido.moi.gov.tw/pt/teaching"
                    let mobileMoicaOnboardingURL = URL(string: mobileMoicaOnboarding)!
                    UIApplication.shared.open(mobileMoicaOnboardingURL)
                }
            let cancel = UIAlertAction(
                title: NSLocalizedString("Cancel", comment: ""),
                style: .cancel)
            alert.addAction(install)
            alert.addAction(confirm)
            alert.addAction(cancel)
            present(alert, animated: true)
        }
    }

    // MARK: - Issuance

    private func finishVaultImport(_ entry: MyDataVaultArchive.Entry) {
        coverItem = Item(
            image: Self.statusImage("checkmark.circle.fill", colour: .systemGreen),
            title: NSLocalizedString("Saved in MyData vault", comment: ""),
            secondaryText: NSLocalizedString("The original file is protected on this phone. It was not turned into national-ID data or a self-issued credential.", comment: ""))
        items = [
            Item(title: NSLocalizedString("Document type", comment: ""), secondaryText: documentType.title),
            Item(title: NSLocalizedString("Source", comment: ""), secondaryText: NSLocalizedString("Taiwan MyData", comment: "")),
            Item(title: NSLocalizedString("File format", comment: ""), secondaryText: entry.fileExtension.isEmpty ? NSLocalizedString("Unknown", comment: "") : entry.fileExtension.uppercased()),
            Item(title: NSLocalizedString("File fingerprint", comment: ""), secondaryText: WalletCardMask.middleEllipsis(entry.sha256)),
        ]
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(cancel))
        applySnapshot()
    }

    /// Puts the parsed fields on screen before the credential exists.
    ///
    /// Split out from issuance because the two can fail independently: MyData
    /// gave us the document either way, and the user should see it rather than an
    /// empty list while the device signs. The cover row carries the state of the
    /// signing, so it starts as "in progress" and is corrected by
    /// `finishIssuance(_:)`.
    private func showParsedDocument(_ nationalIDModel: NationalIDModel) {
        coverItem = Item(
            image: Self.statusImage("signature", colour: .systemIndigo),
            title: NSLocalizedString("Waiting for you to sign in 行動自然人憑證", comment: ""),
            // The wait is not this app's — it is a hand-off to another app and
            // back, and a screen that said only 「處理中」 would leave somebody
            // watching a spinner while the prompt they need to tap sits behind
            // it.
            secondaryText: NSLocalizedString("Your certificate signs these details, which is what lets anyone checking them see that you are the one making the claim.",
                                             comment: ""))
        items = [
            Item(title: NSLocalizedString("Nationality", comment: ""),
                 secondaryText: nationalIDModel.nationality ?? NSLocalizedString("Unknown", comment: "")),
            Item(title: NSLocalizedString("Unified No.", comment: ""),
                 secondaryText: nationalIDModel.unifiedNo ?? NSLocalizedString("Unknown", comment: "")),
            Item(title: NSLocalizedString("Name", comment: ""),
                 secondaryText: nationalIDModel.name ?? NSLocalizedString("Unknown", comment: "")),
            Item(title: NSLocalizedString("Birth date", comment: ""),
                 secondaryText: nationalIDModel.birthdate ?? NSLocalizedString("Unknown", comment: "")),
            Item(title: NSLocalizedString("Address of household", comment: ""),
                 secondaryText: nationalIDModel.addressOfHousehold ?? NSLocalizedString("Unknown", comment: "")),
        ]
        applySnapshot()
        navigationItem.leftBarButtonItem = nil
        // Deliberately left enabled while signing runs. Disabling it would make a
        // slow Keychain call into a modal the user cannot leave; letting them
        // dismiss costs nothing, because issuance does not need this screen to
        // finish — it only needs it to report.
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(cancel))
    }

    /// Turns the parsed document into a credential this device has signed, and
    /// writes it to disk.
    ///
    /// Off the main thread on purpose. Creating the device key is a Keychain
    /// round trip — a Secure Enclave one on real hardware — and the write goes
    /// through Data Protection. Neither is slow enough to notice on a good day,
    /// and both are exactly the kind of call that stalls for a second on a bad
    /// one, right when a sheet is animating away.
    private func issueCredential(for nationalIDModel: NationalIDModel) {
        // Stored under the document type's id — 「national-id」 for the national ID,
        // 「mydata-…」 for a vault document — which is what routes it to the right
        // section (CardInventory classifies self-issued docs by id). The id is
        // stable per document type on purpose: re-running onboarding replaces the
        // previous credential rather than leaving a stale twin on disk beside it.
        let credentialID = documentType.id

        // Detached rather than a child of any screen's task: issuance is a round
        // trip out to 行動自然人憑證 and back, and if the user taps Done in the
        // middle of it the credential should still be saved. Only the reporting
        // needs the screen, and that is what the weak reference is for.
        Task.detached(priority: .userInitiated) { [weak self] in
            // `Result(catching:)` has no `async` overload, so the two arms are
            // written out rather than smuggled through a synchronous closure.
            let result: Result<Void, Error>
            do {
                guard let issuance = CredentialIssuanceAssembly.make() else {
                    // Deliberately *not* `SPCredentialError.requiresBackend.description`.
                    // That type is `CustomStringConvertible` rather than
                    // `LocalizedError` on purpose — its own doc says its audience
                    // is whoever reads the log — and piping it here would put
                    // 「sp_checksum must be computed by the bonds-tw backend」 in
                    // front of somebody who was trying to back up their ID card.
                    throw CredentialIssuanceError.signingUnavailable(
                        message: NSLocalizedString("This version cannot sign documents yet. Signing has to go through the bonds-tw service, which is not available in this build.",
                                                   comment: ""))
                }
                // A national ID owns its key. The app installation has a separate
                // WalletIdentity DID, and every TWDIW card already follows the
                // same per-credential rule through HolderKeyring.
                let keyring = HolderKeyring.app()
                let documentKey = try keyring.newKey()
                do {
                    let subjectDID = try DIDKey.did(fromP256PublicKeyX963: documentKey.publicKeyX963)
                    let signed = try await issuance.issue(nationalIDModel,
                                                          subjectDID: subjectDID,
                                                          issuerKey: documentKey)
                    try CredentialStore().save(jws: try signed.serialized(), id: credentialID)
                } catch {
                    Self.destroyProvisionalKey(documentKey, in: keyring)
                    throw error
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run { self?.finishIssuance(result) }
        }
    }

    private static func destroyProvisionalKey(_ key: DeviceKey, in keyring: HolderKeyring) {
        guard let entries = try? keyring.entries() else { return }
        for entry in entries where entry.publicKeyX963 == key.publicKeyX963 && !entry.isLegacy {
            try? DeviceKey.deleteKey(tag: entry.tag, installRecord: nil)
        }
    }

    private func finishIssuance(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            coverItem = Item(
                image: Self.statusImage("checkmark.seal.fill", colour: .systemGreen),
                title: NSLocalizedString("The valid document has been created", comment: ""),
                secondaryText: "")
        case .failure(let error):
            // The five fields below are still on screen and still correct — what
            // failed is the signing — so the list is corrected rather than
            // cleared. Putting the reason in the row as well as in the alert is
            // not redundancy for its own sake: the alert can be swallowed if the
            // MyData sheet has not finished animating out, and a user left with
            // no credential and no explanation would reasonably assume they had
            // one.
            coverItem = Item(
                image: Self.statusImage("exclamationmark.triangle.fill", colour: .systemOrange),
                title: NSLocalizedString("The document could not be signed", comment: ""),
                secondaryText: error.localizedDescription)
            presentIssuanceFailure(error)
        }
        applySnapshot()
    }

    private static func statusImage(_ name: String, colour: UIColor) -> UIImage? {
        UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))?
            .withTintColor(colour, renderingMode: .alwaysOriginal)
    }

    #if DEBUG
    /// A deterministic, non-personal fixture for layout and screenshot tests.
    /// It exercises the same post-signing state that previously expanded into a
    /// broken hero card on real devices.
    func seedSuccessfulNationalIDPreviewForUITest() {
        guard isNationalID else { return }
        showParsedDocument(NationalIDModel(
            nationality: "中華民國（臺灣）",
            unifiedNo: "TEST000001",
            name: "版面測試",
            birthdate: "民國 100 年 01 月 01 日",
            addressOfHousehold: "測試市測試區第一里第二鄰測試路三段四十二巷五號十二樓之十"))
        finishIssuance(.success(()))
    }
    #endif

    /// Reports a signing failure once the screen is actually able to show it.
    ///
    /// `MyDataWebViewController` asks to be dismissed in the same run-loop turn
    /// that it hands over the parsed document, so when issuance finishes the
    /// sheet may still be on screen or still animating out. UIKit does not queue
    /// a presentation attempted in that window, it drops it. Retrying is bounded
    /// so that "the stack never settles" — including the case where the user
    /// dismissed this screen and there is nothing left to present on — decays
    /// into no alert rather than a timer that runs forever.
    private func presentIssuanceFailure(_ error: Error, attemptsRemaining: Int = 20) {
        guard presentedViewController == nil, viewIfLoaded?.window != nil else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.presentIssuanceFailure(error, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        let alert = UIAlertController(
            title: NSLocalizedString("The document could not be signed", comment: ""),
            // Every error reaching here conforms to LocalizedError, so this is the
            // module's own sentence. The underlying OSStatus and DID stay out of
            // it — an error string is one of the easier ways for an identifier to
            // end up in a screenshot or a crash report.
            message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Confirm", comment: ""), style: .default))
        present(alert, animated: true)
    }
}
