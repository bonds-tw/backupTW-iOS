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
    private var packages: [OfficialDocumentPackage] = []
    private var packagesUnavailable = false

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
            return 2
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
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0

        switch Section(rawValue: indexPath.section) {
        case .status:
            configureStatus(cell)
        case .documents:
            configureDocument(cell, at: indexPath.row)
        case .action:
            if indexPath.row == 0 {
                configureSigningAction(cell)
            } else {
                configureSyntheticAction(cell)
            }
        case .none:
            break
        }
        return cell
    }

    private func configureStatus(_ cell: UITableViewCell) {
        cell.accessibilityIdentifier = "officialDocuments.status"
        cell.imageView?.image = UIImage(systemName: "checkmark.seal")
        if receiptUnavailable {
            cell.textLabel?.text = NSLocalizedString("The local inbox record could not be read", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("The saved consent evidence could not be verified. It will not be shown as signed, and the app will not overwrite it.", comment: "official document inbox")
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle")
            cell.imageView?.tintColor = .systemOrange
            cell.selectionStyle = .none
        } else if let receipt {
            cell.textLabel?.text = NSLocalizedString("Prototype consent signed", comment: "official document inbox")
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let format = NSLocalizedString("Signed on %@. The saved evidence was reverified; it has not registered an official receiving address.", comment: "official document inbox")
            cell.detailTextLabel?.text = String(format: format,
                                                formatter.string(from: receipt.recordedAt))
            cell.imageView?.tintColor = .systemGreen
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        } else {
            cell.textLabel?.text = NSLocalizedString("Official receiving is not active", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("You can test the 行動自然人憑證 signing hand-off now. Official receiving still requires the Archives Administration's G2C exchange service and an agency delivery policy.", comment: "official document inbox")
            cell.imageView?.tintColor = .secondaryLabel
            cell.selectionStyle = .none
        }
    }

    private func configureSigningAction(_ cell: UITableViewCell) {
        cell.accessibilityIdentifier = "officialDocuments.signConsent"
        if receiptUnavailable {
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle")
            cell.imageView?.tintColor = .systemOrange
            cell.textLabel?.textColor = .label
            cell.textLabel?.text = NSLocalizedString("Consent evidence needs attention", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("Resolve the protected-storage problem before signing again.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }
        if receipt != nil {
            cell.accessibilityIdentifier = "officialDocuments.reviewConsent"
            cell.imageView?.image = UIImage(systemName: "doc.text.magnifyingglass")
            cell.imageView?.tintColor = .tintColor
            cell.textLabel?.textColor = .tintColor
            cell.textLabel?.text = NSLocalizedString("Review signed consent evidence", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("Inspect the signed scope and fingerprints, or remove the local evidence from this iPhone.", comment: "official document inbox")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return
        }
        cell.imageView?.image = UIImage(systemName: "signature")
        cell.imageView?.tintColor = .tintColor
        cell.textLabel?.textColor = .tintColor
        cell.textLabel?.text = isSigning
            ? NSLocalizedString("Waiting for 行動自然人憑證", comment: "official document inbox")
            : NSLocalizedString("Sign the prototype consent", comment: "official document inbox")
        cell.detailTextLabel?.text = isSigning
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

    private func configureDocument(_ cell: UITableViewCell, at index: Int) {
        if packagesUnavailable {
            cell.accessibilityIdentifier = "officialDocuments.unavailable"
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle")
            cell.imageView?.tintColor = .systemOrange
            cell.textLabel?.text = NSLocalizedString("The stored official document index could not be read", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("The protected source files remain on this phone. Do not import another package until the storage problem is resolved.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }
        guard packages.indices.contains(index) else {
            cell.accessibilityIdentifier = "officialDocuments.empty"
            cell.imageView?.image = UIImage(systemName: "tray")
            cell.textLabel?.text = NSLocalizedString("No official documents yet", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("This app is not connected to the government's G2C exchange service yet. No agency can deliver a legally effective document here today.", comment: "official document inbox")
            cell.selectionStyle = .none
            return
        }

        let package = packages[index]
        cell.accessibilityIdentifier = "officialDocuments.document.\(index)"
        cell.imageView?.image = UIImage(systemName: package.localState == .unread
            ? "envelope.badge" : "doc.text")
        cell.imageView?.tintColor = package.localState == .unread ? .tintColor : .secondaryLabel
        cell.textLabel?.text = UntrustedText.value(
            package.document?.subject ?? package.envelope.subject).text
        let state = package.localState == .unread
            ? NSLocalizedString("Unread on this phone", comment: "official document inbox")
            : NSLocalizedString("Viewed on this phone", comment: "official document inbox")
        let format = NSLocalizedString("%@ · %@ · Synthetic test data", comment: "official document inbox")
        cell.detailTextLabel?.text = String(
            format: format,
            UntrustedText.value(package.envelope.sender.organizationName).text,
            state)
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
    }

    private func configureSyntheticAction(_ cell: UITableViewCell) {
        #if DEBUG
        cell.accessibilityIdentifier = "officialDocuments.loadSynthetic"
        cell.imageView?.image = UIImage(systemName: "shippingbox.and.arrow.backward")
        cell.imageView?.tintColor = .systemOrange
        cell.textLabel?.textColor = .systemOrange
        cell.textLabel?.text = NSLocalizedString("Load a synthetic EN / DI / ESW package", comment: "official document inbox")
        cell.detailTextLabel?.text = NSLocalizedString("Developer test only — this did not come from a government agency and creates no receipt.", comment: "official document inbox")
        cell.accessoryType = .disclosureIndicator
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
            packages = try archive.packages()
            packagesUnavailable = false
        } catch {
            packages = []
            packagesUnavailable = true
        }
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
