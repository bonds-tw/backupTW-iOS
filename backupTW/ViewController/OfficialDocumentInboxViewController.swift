//
//  OfficialDocumentInboxViewController.swift
//  backupTW
//

import UIKit

/// The holder-facing home for electronic official documents.
///
/// The feature remains a development prototype, not a pretend official inbox:
/// no government exchange endpoint exists in this app yet, so the screen says so
/// before offering the same 行動自然人憑證 hand-off used by the app's other
/// signatures. Debug builds can exercise a synthetic EN/DI/ESW package; official
/// incoming envelopes still require a sandbox and routing contract.
final class OfficialDocumentInboxViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case status
        case documents
        case action
    }

    private let archive: OfficialDocumentInboxArchive
    private let makeSigning: () -> OfficialDocumentSigning?
    private var signatureTask: Task<Void, Never>?
    private var isSigning = false
    private var receipt: OfficialDocumentInboxReceipt?
    private var receiptUnavailable = false
    private var physicalCardRequestPending = false
    private var physicalCardResponseReady = false
    private var packages: [OfficialDocumentPackage] = []
    private var packagesUnavailable = false
    #if DEBUG
    private var sandboxRegistration: OfficialDocumentDevelopmentSandboxRegistration?
    private var sandboxRegistrationUnavailable = false
    #endif

    init(archive: OfficialDocumentInboxArchive,
         makeSigning: @escaping () -> OfficialDocumentSigning? = {
             OfficialDocumentSigningAssembly.make()
         }) {
        self.archive = archive
        self.makeSigning = makeSigning
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { signatureTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Electronic official documents", comment: "official document inbox title")
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        reloadPackages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadPackages()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .documents:
            return packages.isEmpty || packagesUnavailable ? 1 : packages.count
        case .action:
            #if DEBUG
            return 4
            #else
            return 1
            #endif
        case .status, .none:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .status:
            return NSLocalizedString("Receiving status", comment: "official document inbox")
        case .documents:
            return NSLocalizedString("Official documents", comment: "official document inbox")
        case .action, .none:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0

        switch Section(rawValue: indexPath.section) {
        case .status:
            configureStatus(cell, &content)
        case .documents:
            configureDocument(cell, &content, at: indexPath.row)
        case .action:
            if indexPath.row == 0 {
                configureSigningAction(cell, &content)
            } else if indexPath.row == 1 {
                configurePhysicalCardAction(cell, &content)
            } else if indexPath.row == 2 {
                configureG2CSandboxAction(cell, &content)
            } else {
                configureSyntheticAction(cell, &content)
            }
        case .none:
            break
        }
        cell.contentConfiguration = content
        return cell
    }

    private func configureStatus(_ cell: UITableViewCell,
                                 _ content: inout UIListContentConfiguration) {
        cell.accessibilityIdentifier = "officialDocuments.status"
        content.image = UIImage(systemName: "checkmark.seal")
        if receiptUnavailable {
            content.text = NSLocalizedString("The local inbox record could not be read", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("The saved consent evidence could not be verified. It will not be shown as signed, and the app will not overwrite it.", comment: "official document inbox")
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemOrange
            cell.selectionStyle = .none
        } else if let receipt {
            content.text = NSLocalizedString("Prototype consent signed", comment: "official document inbox")
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let format = NSLocalizedString("Signed on %@. The saved evidence was reverified; it has not registered an official receiving address.", comment: "official document inbox")
            content.secondaryText = String(format: format,
                                           formatter.string(from: receipt.recordedAt))
            content.imageProperties.tintColor = .systemGreen
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        } else {
            content.text = NSLocalizedString("Official receiving is not active", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("You can test the 行動自然人憑證 signing hand-off now. Official receiving still requires the Archives Administration's G2C exchange service and an agency delivery policy.", comment: "official document inbox")
            content.imageProperties.tintColor = .secondaryLabel
            cell.selectionStyle = .none
        }
    }

    private func configureSigningAction(_ cell: UITableViewCell,
                                        _ content: inout UIListContentConfiguration) {
        cell.accessibilityIdentifier = "officialDocuments.signConsent"
        if receiptUnavailable {
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.color = .label
            content.text = NSLocalizedString("Consent evidence needs attention", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("Resolve the protected-storage problem before signing again.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }
        if receipt != nil {
            cell.accessibilityIdentifier = "officialDocuments.reviewConsent"
            content.image = UIImage(systemName: "doc.text.magnifyingglass")
            content.imageProperties.tintColor = .tintColor
            content.textProperties.color = .tintColor
            content.text = NSLocalizedString("Review signed consent evidence", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("Inspect the signed scope and fingerprints, or remove the local evidence from this iPhone.", comment: "official document inbox")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return
        }
        content.image = UIImage(systemName: "signature")
        content.imageProperties.tintColor = .tintColor
        content.textProperties.color = .tintColor
        content.text = isSigning
            ? NSLocalizedString("Waiting for 行動自然人憑證", comment: "official document inbox")
            : NSLocalizedString("Sign the prototype consent", comment: "official document inbox")
        content.secondaryText = isSigning
            ? NSLocalizedString("Approve the request in 行動自然人憑證, then return here.", comment: "official document inbox")
            : NSLocalizedString("This tests the app-to-app signature only. It does not activate legal electronic delivery.", comment: "official document inbox")
        cell.accessoryType = isSigning ? .none : .disclosureIndicator
        cell.selectionStyle = isSigning ? .none : .default
        if isSigning {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        }
    }

    private func configureDocument(_ cell: UITableViewCell,
                                   _ content: inout UIListContentConfiguration,
                                   at index: Int) {
        if packagesUnavailable {
            cell.accessibilityIdentifier = "officialDocuments.unavailable"
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemOrange
            content.text = NSLocalizedString("The stored official document index could not be read", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("The protected source files remain on this phone. Do not import another package until the storage problem is resolved.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }
        guard packages.indices.contains(index) else {
            cell.accessibilityIdentifier = "officialDocuments.empty"
            content.image = UIImage(systemName: "tray")
            content.text = NSLocalizedString("No official documents yet", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("This app is not connected to the government's G2C exchange service yet. No agency can deliver a legally effective document here today.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }

        let package = packages[index]
        cell.accessibilityIdentifier = "officialDocuments.document.\(index)"
        content.image = UIImage(systemName: package.localState == .unread
            ? "envelope.badge" : "doc.text")
        content.imageProperties.tintColor = package.localState == .unread ? .tintColor : .secondaryLabel
        content.text = UntrustedText.value(
            package.document?.subject ?? package.envelope.subject).text
        let state = package.localState == .unread
            ? NSLocalizedString("Unread on this phone", comment: "official document inbox")
            : NSLocalizedString("Viewed on this phone", comment: "official document inbox")
        let format = package.environment == .developmentG2CSandbox
            ? NSLocalizedString("%@ · %@ · G2C development sandbox", comment: "official document inbox")
            : NSLocalizedString("%@ · %@ · Synthetic test data", comment: "official document inbox")
        content.secondaryText = String(
            format: format,
            UntrustedText.value(package.envelope.sender.organizationName).text,
            state)
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
    }

    private func configureSyntheticAction(_ cell: UITableViewCell,
                                          _ content: inout UIListContentConfiguration) {
        #if DEBUG
        cell.accessibilityIdentifier = "officialDocuments.loadSynthetic"
        content.image = UIImage(systemName: "shippingbox.and.arrow.backward")
        content.imageProperties.tintColor = .systemOrange
        content.textProperties.color = .systemOrange
        content.text = NSLocalizedString("Load a synthetic EN / DI / ESW package", comment: "official document inbox")
        content.secondaryText = NSLocalizedString("Developer test only — this did not come from a government agency and creates no receipt.", comment: "official document inbox")
        cell.accessoryType = .disclosureIndicator
        #endif
    }

    private func configureG2CSandboxAction(_ cell: UITableViewCell,
                                           _ content: inout UIListContentConfiguration) {
        #if DEBUG
        cell.accessibilityIdentifier = "officialDocuments.g2cSandbox"
        content.image = UIImage(systemName: "network.badge.shield.half.filled")
        content.imageProperties.tintColor = .systemPurple
        content.textProperties.color = .systemPurple
        if sandboxRegistrationUnavailable {
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.color = .label
            content.text = NSLocalizedString("G2C sandbox record needs attention", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("The protected sandbox registration could not be read. No test document will be accepted.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }
        if sandboxRegistration == nil {
            content.text = NSLocalizedString("Enable G2C sandbox receiving", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("Creates a non-routable test address and receives one signed, encrypted fixture. It has no legal effect.", comment: "official document inbox")
        } else {
            content.text = NSLocalizedString("Receive another G2C sandbox document", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("Exercises sender verification, ESW decryption, duplicate protection and a local simulated confirmation.", comment: "official document inbox")
        }
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        #endif
    }

    private func configurePhysicalCardAction(_ cell: UITableViewCell,
                                             _ content: inout UIListContentConfiguration) {
        #if DEBUG
        cell.accessibilityIdentifier = "officialDocuments.physicalCardConsent"
        content.image = UIImage(systemName: "creditcard.and.123")
        content.imageProperties.tintColor = .systemOrange
        content.textProperties.color = .systemOrange
        if receipt != nil || receiptUnavailable {
            content.text = NSLocalizedString("Physical-card development signing", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("Unavailable while signed consent evidence exists or needs attention.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }
        if physicalCardResponseReady {
            content.image = UIImage(systemName: "checkmark.shield")
            content.imageProperties.tintColor = .systemGreen
            content.textProperties.color = .systemGreen
            content.text = NSLocalizedString("Verify the physical-card signature", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("The Mac returned a result. This iPhone will now check the exact consent, MOICA certificate chain and RSA signature before saving it.", comment: "official document inbox")
        } else if physicalCardRequestPending {
            content.text = NSLocalizedString("Waiting for the Mac physical-card helper", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("Run the paired-USB helper on the Mac, then tap here again to check for and verify its result.", comment: "official document inbox")
        } else {
            content.text = NSLocalizedString("Test with a physical natural-person certificate", comment: "official document inbox")
            content.secondaryText = NSLocalizedString("Development only. Creates an identity-free one-time request for an attached Mac card reader; it does not contact the government or activate official receiving.", comment: "official document inbox")
        }
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        #endif
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .documents:
            guard !packagesUnavailable, packages.indices.contains(indexPath.row) else { return }
            navigationController?.pushViewController(
                OfficialDocumentDetailViewController(packageID: packages[indexPath.row].id,
                                                     archive: archive),
                animated: true)
        case .action where indexPath.row == 0:
            guard !isSigning, !receiptUnavailable else { return }
            if receipt != nil {
                openConsentEvidence()
            } else {
                beginConsentSigning()
            }
        case .action where indexPath.row == 1:
            #if DEBUG
            guard receipt == nil, !receiptUnavailable else { return }
            handlePhysicalCardSigning()
            #endif
        case .action where indexPath.row == 2:
            #if DEBUG
            guard !sandboxRegistrationUnavailable else { return }
            handleG2CSandboxReceiving()
            #endif
        case .action:
            #if DEBUG
            loadSyntheticPackage()
            #endif
        case .status:
            if receipt != nil, !receiptUnavailable { openConsentEvidence() }
        case .none:
            break
        }
    }

    private func reloadPackages() {
        do {
            receipt = try archive.receipt()
            receiptUnavailable = false
        } catch {
            receipt = nil
            receiptUnavailable = true
        }
        do {
            physicalCardRequestPending = try archive.physicalCardSigningRequest() != nil
            physicalCardResponseReady = archive.hasPhysicalCardSigningResponse
        } catch {
            physicalCardRequestPending = false
            physicalCardResponseReady = false
        }
        do {
            packages = try archive.packages()
            packagesUnavailable = false
        } catch {
            packages = []
            packagesUnavailable = true
        }
        #if DEBUG
        do {
            sandboxRegistration = try archive.sandboxRegistration()
            sandboxRegistrationUnavailable = false
        } catch {
            sandboxRegistration = nil
            sandboxRegistrationUnavailable = true
        }
        #endif
        if isViewLoaded { tableView.reloadData() }
    }

    private func openConsentEvidence() {
        guard let receipt else { return }
        navigationController?.pushViewController(
            OfficialDocumentConsentEvidenceViewController(
                receipt: receipt,
                archive: archive,
                onRemoved: { [weak self] in self?.reloadPackages() }),
            animated: true)
    }

    #if DEBUG
    private func handlePhysicalCardSigning() {
        if physicalCardResponseReady {
            do {
                _ = try archive.importPhysicalCardSigningResponse()
                reloadPackages()
                presentMessage(
                    title: NSLocalizedString("Physical-card consent verified", comment: "official document inbox"),
                    message: NSLocalizedString("The physical-card certificate chain and signature over this exact local-prototype consent were verified and stored on this iPhone. This is still not an official receiving address or legal delivery.", comment: "official document inbox"))
            } catch {
                presentMessage(
                    title: NSLocalizedString("The physical-card result was not saved", comment: "official document inbox"),
                    message: error.localizedDescription)
            }
            return
        }

        if physicalCardRequestPending {
            reloadPackages()
            if physicalCardResponseReady {
                handlePhysicalCardSigning()
            } else {
                presentPhysicalCardInstructions()
            }
            return
        }

        let alert = UIAlertController(
            title: NSLocalizedString("Use a physical natural-person certificate?", comment: "official document inbox"),
            message: NSLocalizedString("This development path creates a one-time request containing only the consent version, local-prototype scope, timestamp and random nonce. The paired Mac asks for the card PIN in a hidden terminal prompt; the PIN is not stored or sent to this app. It does not contact the Ministry of the Interior or create an official inbox.", comment: "official document inbox"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Create one-time request", comment: "official document inbox"),
            style: .default) { [weak self] _ in
                guard let self else { return }
                do {
                    _ = try self.archive.preparePhysicalCardSigningRequest()
                    self.reloadPackages()
                    self.presentPhysicalCardInstructions()
                } catch {
                    self.presentMessage(
                        title: NSLocalizedString("The physical-card request was not created", comment: "official document inbox"),
                        message: error.localizedDescription)
                }
            })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    private func presentPhysicalCardInstructions() {
        presentMessage(
            title: NSLocalizedString("Physical-card request ready", comment: "official document inbox"),
            message: NSLocalizedString("Keep this iPhone unlocked and connected to the Mac. In the backupTW-iOS repository, run ./scripts/physical-card-consent.sh --device mashbean14 within 15 minutes. Insert the card and enter its PIN only at the hidden terminal prompt. When the helper finishes, return here and tap the physical-card row again.", comment: "official document inbox"))
    }

    private func handleG2CSandboxReceiving() {
        if let registration = sandboxRegistration {
            receiveG2CSandboxDocument(registration: registration)
            return
        }
        let alert = UIAlertController(
            title: NSLocalizedString("Enable G2C development sandbox receiving?", comment: "official document inbox"),
            message: NSLocalizedString("This creates a non-routable address beginning with G2C-SANDBOX-NOT-ROUTABLE and receives one repository-owned test document. The sender key, recipient key and confirmation all stay in this development build. No government service is contacted, and no legal delivery is created.", comment: "official document inbox"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Enable and receive test document", comment: "official document inbox"),
            style: .default) { [weak self] _ in
                guard let self else { return }
                do {
                    let registration = try self.archive.enableDevelopmentSandboxReceiving()
                    self.sandboxRegistration = registration
                    self.receiveG2CSandboxDocument(registration: registration)
                } catch {
                    self.presentMessage(
                        title: NSLocalizedString("G2C sandbox receiving was not enabled", comment: "official document inbox"),
                        message: error.localizedDescription)
                }
            })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    private func receiveG2CSandboxDocument(
        registration: OfficialDocumentDevelopmentSandboxRegistration) {
        do {
            let payload = try OfficialDocumentG2CSandboxFixture.make(
                registration: registration)
            let package = try archive.importDevelopmentSandbox(payload)
            reloadPackages()
            navigationController?.pushViewController(
                OfficialDocumentDetailViewController(packageID: package.id,
                                                     archive: archive),
                animated: true)
        } catch {
            presentMessage(
                title: NSLocalizedString("The G2C sandbox document was refused", comment: "official document inbox"),
                message: error.localizedDescription)
        }
    }

    private func loadSyntheticPackage() {
        do {
            let package = try archive.importSynthetic(OfficialDocumentSyntheticFixture.make())
            reloadPackages()
            let detail = OfficialDocumentDetailViewController(packageID: package.id,
                                                              archive: archive)
            navigationController?.pushViewController(detail, animated: true)
        } catch {
            presentMessage(
                title: NSLocalizedString("The synthetic package was not imported", comment: "official document inbox"),
                message: error.localizedDescription)
        }
    }
    #endif

    private func beginConsentSigning() {
        guard receipt == nil, !receiptUnavailable else { return }
        guard OfficialDocumentSigningAssembly.isAvailable,
              let signing = makeSigning() else {
            presentMessage(
                title: NSLocalizedString("Signing is not available in this build", comment: "official document inbox"),
                message: NSLocalizedString("Release signing must go through the bonds-tw backend so the Ministry of the Interior service key never enters the app. That backend is not connected yet.", comment: "official document inbox"))
            return
        }

        let consent: OfficialDocumentInboxConsent
        do {
            consent = try .make()
        } catch {
            presentMessage(
                title: NSLocalizedString("The signing request could not be created", comment: "official document inbox"),
                message: error.localizedDescription)
            return
        }

        present(Self.makeIDNumberPrompt { [weak self] idNumber in
            self?.startSigning(consent: consent, idNumber: idNumber, signing: signing)
        }, animated: true)
    }

    /// The disclosure and consent moment for the one personal identifier this
    /// prototype must send to 內政部. The field is read through a weak reference
    /// to the alert so its ID-number text cannot be retained by an alert/action
    /// cycle after dismissal.
    static func makeIDNumberPrompt(onContinue: @escaping (String) -> Void) -> UIAlertController {
        let alert = UIAlertController(
            title: NSLocalizedString("Sign with 行動自然人憑證", comment: "official document inbox"),
            message: NSLocalizedString("This sends your ID number, the service identifier, and a prototype-consent digest to the Ministry of the Interior, which keeps a service record. 有備而來 does not save the ID number you type. The signature will not create an official mailbox.", comment: "official document inbox"),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = NSLocalizedString("A123456789", comment: "ID number placeholder")
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.keyboardType = .asciiCapable
            field.accessibilityIdentifier = "officialDocuments.idNumberField"
        }
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Send the number and sign", comment: "official document inbox"),
            style: .default) { [weak alert] _ in
                let value = alert?.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                onContinue(value)
            })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        return alert
    }

    private func startSigning(consent: OfficialDocumentInboxConsent,
                              idNumber: String,
                              signing: OfficialDocumentSigning) {
        guard !idNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentMessage(
                title: NSLocalizedString("ID number required", comment: "official document inbox"),
                message: OfficialDocumentSigningError.identityNumberMissing.localizedDescription)
            return
        }
        isSigning = true
        tableView.reloadSections(IndexSet(integer: Section.action.rawValue), with: .none)
        let archive = self.archive
        signatureTask = Task { [weak self] in
            do {
                let receipt = try await signing.sign(consent: consent, idNumber: idNumber)
                try archive.store(receipt)
                guard !Task.isCancelled else { return }
                self?.finishSigning(.success(()))
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishSigning(.failure(error))
            }
        }
    }

    private func finishSigning(_ result: Result<Void, Error>) {
        signatureTask = nil
        isSigning = false
        tableView.reloadData()
        switch result {
        case .success:
            reloadPackages()
            presentMessage(
                title: NSLocalizedString("Prototype consent signed", comment: "official document inbox"),
                message: NSLocalizedString("The verified signature is stored on this phone. Official receiving is still inactive until a government G2C service accepts this app and issues a receiving address.", comment: "official document inbox"))
        case .failure(let error):
            presentMessage(
                title: NSLocalizedString("The consent was not saved", comment: "official document inbox"),
                message: error.localizedDescription)
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }
}

extension OfficialDocumentInboxViewController: PrivacyShieldedScreen {}
