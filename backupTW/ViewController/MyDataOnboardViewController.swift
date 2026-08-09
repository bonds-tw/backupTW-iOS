//
//  MyDataOnboardViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/8/11.
//

import UIKit

private let reuseIdentifier = "MyDataOnboardCell"

class MyDataOnboardViewController: UICollectionViewController {

    /// The key this device's national ID credential is filed under.
    ///
    /// Constant on purpose. `VerifiableCredential` has no `id` of its own yet, so
    /// the storage key has to be picked by the caller — and picking a fresh one
    /// per run would leave the previous credential on disk beside the new one.
    /// Two credentials asserting the same identity, one of them stale, is worse
    /// than one: nothing downstream could say which is current. Re-running
    /// onboarding replaces.
    private static let nationalIDCredentialID = "national-id"

    private var isMobileMoicaReady: Bool {
        let mobileMoicaURLScheme = "mobilemoica://"
        let mobileMoicaURL = URL(string: mobileMoicaURLScheme)!
        let isMobileMoicaReady = UIApplication.shared.canOpenURL(mobileMoicaURL)
        return isMobileMoicaReady
    }

    private enum Section: Int, CaseIterable {
        case cover, data
    }
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var coverItem: Item = Item(
        title: "📋\n" + NSLocalizedString("Create a Valid Document", comment: ""),
        secondaryText: NSLocalizedString("You will use TW FiDO to retrieve your National ID data, and create a valid document.", comment: ""))
    private var items: [Item] = [
        Item(title: NSLocalizedString("Nationality", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Unified No.", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Name", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Birth date", comment: ""), secondaryText: ""),
        Item(title: NSLocalizedString("Address of household", comment: ""), secondaryText: ""),
    ]

    init() {
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

        title = NSLocalizedString("Valid Document", comment: "")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Continue", comment: ""), style: .done, target: self, action: #selector(nextAction))
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: reuseIdentifier)
        collectionView.allowsSelection = false

        configureDataSource()
        applySnapshot()
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, indexPath, item in
            var content = UIListContentConfiguration.valueCell()
            let isCover = (indexPath.section == Section.cover.rawValue)
            let textStyle: UIFont.TextStyle = isCover ? .largeTitle : .headline
            let secondaryStyle: UIFont.TextStyle = isCover ? .body : .subheadline
            content.textProperties.alignment = isCover ? .center : .natural
            content.secondaryTextProperties.alignment = isCover ? .center : .natural
            content.textToSecondaryTextVerticalPadding = isCover ? 12.0 : 3.0
            let title = NSMutableAttributedString(
                string: item.title,
                attributes: [.font: UIFont.preferredFont(forTextStyle: textStyle)]
            )
            if isCover {
                title.addAttribute(.font, value: UIFont.systemFont(ofSize: 60), range: NSRange(location: 0, length: 2)) // for the emoji
            }
            content.attributedText = title
            content.secondaryAttributedText = NSAttributedString(
                string: item.secondaryText,
                attributes: [.foregroundColor: UIColor.secondaryLabel,
                             .font: UIFont.preferredFont(forTextStyle: secondaryStyle)]
            )
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { headerView, elementKind, indexPath in
            var content = headerView.defaultContentConfiguration()
            content.text = NSLocalizedString("Document information", comment: "")
            headerView.contentConfiguration = content
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { footerView, elementKind, indexPath in
            var content = footerView.defaultContentConfiguration()
            content.text = NSLocalizedString("All information are stored only on your phone.", comment: "")
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
        snapshot.appendSections([.data])
        for item in items {
            snapshot.appendItems([item])
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func nextAction() {
        if isMobileMoicaReady {
            let vc = MyDataWebViewController(completion: { [weak self] nationalIDModel in
                guard let self else { return }
                self.showParsedDocument(nationalIDModel)
                self.issueCredential(for: nationalIDModel)
            })
            present(vc, animated: true)
        } else {
            let alert = UIAlertController(
                title: NSLocalizedString("Please apply for TW FidO first", comment: ""),
                message: nil, preferredStyle: .alert)
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
            alert.addAction(confirm)
            alert.addAction(cancel)
            present(alert, animated: true)
        }
    }

    // MARK: - Issuance

    /// Puts the parsed fields on screen before the credential exists.
    ///
    /// Split out from issuance because the two can fail independently: MyData
    /// gave us the document either way, and the user should see it rather than an
    /// empty list while the device signs. The cover row carries the state of the
    /// signing, so it starts as "in progress" and is corrected by
    /// `finishIssuance(_:)`.
    private func showParsedDocument(_ nationalIDModel: NationalIDModel) {
        coverItem = Item(
            title: "⏳\n" + NSLocalizedString("Waiting for you to sign in 行動自然人憑證", comment: ""),
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
        let credentialID = Self.nationalIDCredentialID

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
                // The device key is still what the holder presents under — the
                // credential's subject identifier — even though it no longer
                // signs anything. See `VerifiableCredential.nationalID`.
                let deviceKey = try DeviceKey.loadOrCreate()
                let subjectDID = try DIDKey.did(fromP256PublicKeyX963: deviceKey.publicKeyX963)

                let signed = try await issuance.issue(nationalIDModel, subjectDID: subjectDID)
                try CredentialStore().save(jws: try signed.serialized(), id: credentialID)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run { self?.finishIssuance(result) }
        }
    }

    private func finishIssuance(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            coverItem = Item(
                title: "✅\n" + NSLocalizedString("The valid document has been created", comment: ""),
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
                title: "⚠️\n" + NSLocalizedString("The document could not be signed", comment: ""),
                secondaryText: error.localizedDescription)
            presentIssuanceFailure(error)
        }
        applySnapshot()
    }

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
