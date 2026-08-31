//
//  OfficialDocumentInboxViewController.swift
//  backupTW
//

import UIKit

/// The holder-facing home for electronic official documents.
///
/// The first slice is deliberately an enrolment prototype, not a pretend inbox:
/// no government exchange endpoint exists in this app yet, so the screen says so
/// before offering the same 行動自然人憑證 hand-off used by the app's other
/// signatures. Incoming EN/DI/ESW envelopes will appear here only after an
/// official sandbox and routing contract exist.
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
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { 1 }

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
            cell.accessibilityIdentifier = "officialDocuments.empty"
            cell.imageView?.image = UIImage(systemName: "tray")
            cell.textLabel?.text = NSLocalizedString("No official documents yet", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("This app is not connected to the government's G2C exchange service yet. No agency can deliver a legally effective document here today.", comment: "official document inbox")
            cell.selectionStyle = .none
        case .action:
            configureAction(cell)
        case .none:
            break
        }
        return cell
    }

    private func configureStatus(_ cell: UITableViewCell) {
        cell.accessibilityIdentifier = "officialDocuments.status"
        cell.selectionStyle = .none
        cell.imageView?.image = UIImage(systemName: "checkmark.seal")
        do {
            if let receipt = try archive.receipt() {
                cell.textLabel?.text = NSLocalizedString("Prototype consent signed", comment: "official document inbox")
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let format = NSLocalizedString("Signed on %@. This is stored only as local prototype evidence; it has not registered an official receiving address.", comment: "official document inbox")
                cell.detailTextLabel?.text = String(format: format,
                                                    formatter.string(from: receipt.recordedAt))
                cell.imageView?.tintColor = .systemGreen
            } else {
                cell.textLabel?.text = NSLocalizedString("Official receiving is not active", comment: "official document inbox")
                cell.detailTextLabel?.text = NSLocalizedString("You can test the 行動自然人憑證 signing hand-off now. Official receiving still requires the Archives Administration's G2C exchange service and an agency delivery policy.", comment: "official document inbox")
                cell.imageView?.tintColor = .secondaryLabel
            }
        } catch {
            cell.textLabel?.text = NSLocalizedString("The local inbox record could not be read", comment: "official document inbox")
            cell.detailTextLabel?.text = NSLocalizedString("Anything already saved remains on this phone. Do not sign again until the storage problem is resolved.", comment: "official document inbox")
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle")
            cell.imageView?.tintColor = .systemOrange
        }
    }

    private func configureAction(_ cell: UITableViewCell) {
        cell.accessibilityIdentifier = "officialDocuments.signConsent"
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

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .action, !isSigning else { return }
        beginConsentSigning()
    }

    private func beginConsentSigning() {
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
