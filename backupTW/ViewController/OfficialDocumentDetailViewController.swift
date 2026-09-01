//
//  OfficialDocumentDetailViewController.swift
//  backupTW
//

import UIKit

/// Holder-facing view of one preserved EN / DI / ESW package index.
///
/// Opening this screen changes only `LocalState`. A Debug sandbox package may
/// additionally record an explicitly simulated confirmation on this device; no
/// path sends the official exchange confirmation a real service may require.
final class OfficialDocumentDetailViewController: UITableViewController {
    private struct Row {
        let id: String
        let title: String
        let value: String
    }

    private struct Group {
        let title: String
        let rows: [Row]
    }

    private let packageID: String
    private let archive: OfficialDocumentInboxArchive
    private var package: OfficialDocumentPackage?
    private var groups: [Group] = []
    private var didMarkViewed = false

    init(packageID: String, archive: OfficialDocumentInboxArchive) {
        self.packageID = packageID
        self.archive = archive
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Electronic official document test package", comment: "official document detail")
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 68
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didMarkViewed else { return }
        didMarkViewed = true
        if let updated = try? archive.markViewed(id: packageID) {
            package = updated
            rebuildGroups()
            tableView.reloadData()
        }
    }

    private func reload() {
        package = try? archive.package(id: packageID)
        rebuildGroups()
        tableView.reloadData()
    }

    private func rebuildGroups() {
        guard let package else {
            groups = [Group(title: "", rows: [
                Row(id: "missing",
                    title: NSLocalizedString("The test package is unavailable", comment: "official document detail"),
                    value: NSLocalizedString("Its protected index could not be opened on this phone.", comment: "official document detail"))
            ])]
            return
        }

        let isG2CSandbox = package.environment == .developmentG2CSandbox
        title = isG2CSandbox
            ? NSLocalizedString("G2C sandbox test document", comment: "official document detail")
            : NSLocalizedString("Electronic official document test package", comment: "official document detail")

        let received = Self.date(package.receivedAt)
        let state = package.localState == .unread
            ? NSLocalizedString("Unread on this phone", comment: "official document inbox")
            : NSLocalizedString("Viewed on this phone", comment: "official document inbox")
        let document = package.document
        let documentRows = [
            Row(id: "subject", title: NSLocalizedString("Subject", comment: "official document detail"),
                value: safe(document?.subject ?? package.envelope.subject)),
            Row(id: "sender", title: NSLocalizedString("Sender stated in EN", comment: "official document detail"),
                value: safe(package.envelope.sender.organizationName)),
            Row(id: "type", title: NSLocalizedString("Document type", comment: ""),
                value: safe(document?.type ?? NSLocalizedString("Encrypted content unavailable", comment: "official document detail"))),
            Row(id: "number", title: NSLocalizedString("Document number", comment: "official document detail"),
                value: safe(document?.number ?? "")),
            Row(id: "date", title: NSLocalizedString("Document date", comment: "official document detail"),
                value: safe(document?.dateText ?? "")),
            Row(id: "priority", title: NSLocalizedString("Priority", comment: "official document detail"),
                value: safe(document?.priority ?? "")),
            Row(id: "received", title: NSLocalizedString("Stored on this phone", comment: "official document detail"),
                value: received),
            Row(id: "localState", title: NSLocalizedString("Local viewing state", comment: "official document detail"),
                value: state)
        ].filter { !$0.value.isEmpty }

        var contentRows: [Row] = []
        if let body = document?.bodyText, !body.isEmpty {
            contentRows.append(Row(id: "body",
                                   title: NSLocalizedString("Document text", comment: "official document detail"),
                                   value: safe(body)))
        } else {
            contentRows.append(Row(
                id: "encrypted",
                title: NSLocalizedString("Document text is encrypted or unavailable", comment: "official document detail"),
                value: NSLocalizedString("有備而來 does not yet have an official ESW decryption contract or recipient key. It will not pretend the content was opened.", comment: "official document detail")))
        }

        let authenticationText = isG2CSandbox
            ? NSLocalizedString("Verified with the repository-owned G2C sandbox sender key. This is not a government agency certificate or official exchange signature.", comment: "official document detail")
            : NSLocalizedString("Not verified — this package is synthetic and has no official exchange signature or address-book proof.", comment: "official document detail")
        let confirmationText: String
        if let confirmation = package.sandboxDelivery?.confirmation {
            confirmationText = String(
                format: NSLocalizedString("Recorded locally by the development simulator on %@. Nothing was sent to a government service.", comment: "official document detail"),
                Self.date(confirmation.recordedAt))
        } else if isG2CSandbox {
            confirmationText = NSLocalizedString("Not recorded yet. You can create a local simulated confirmation below; it will have no legal effect.", comment: "official document detail")
        } else {
            confirmationText = NSLocalizedString("Not created — viewing this test package changes only this phone's local state and sends nothing.", comment: "official document detail")
        }
        var integrityRows = [
            Row(id: "integrity",
                title: NSLocalizedString("File integrity", comment: "official document detail"),
                value: NSLocalizedString("Verified against the SHA-256 fingerprints listed in EN.", comment: "official document detail")),
            Row(id: "authentication",
                title: NSLocalizedString("Sender authentication", comment: "official document detail"),
                value: authenticationText),
            Row(id: "receipt",
                title: NSLocalizedString("Delivery confirmation", comment: "official document detail"),
                value: confirmationText),
            Row(id: "fingerprint",
                title: NSLocalizedString("EN fingerprint", comment: "official document detail"),
                value: package.integrity.envelopeDigest)
        ]
        if isG2CSandbox {
            integrityRows.insert(Row(
                id: "legalEffect",
                title: NSLocalizedString("Legal effect", comment: "official document detail"),
                value: NSLocalizedString("None — this is a local development simulation. No agency policy or government exchange service recognizes it as delivery.", comment: "official document detail")), at: 3)
        }

        var formatRows = [
            Row(id: "en", title: "EN",
                value: NSLocalizedString("Envelope metadata and file fingerprints parsed", comment: "official document detail")),
            Row(id: "di", title: "DI",
                value: document == nil
                    ? NSLocalizedString("Not available outside the encrypted payload", comment: "official document detail")
                    : (isG2CSandbox
                        ? NSLocalizedString("Decrypted from the sandbox ESW and parsed for display", comment: "official document detail")
                        : NSLocalizedString("Synthetic XML document parsed for display", comment: "official document detail")))
        ]
        if let encryptedSwitch = package.encryptedSwitch {
            let format = isG2CSandbox
                ? NSLocalizedString("Decrypted · %@ · %lld sandbox recipient", comment: "official document detail")
                : NSLocalizedString("Metadata only · %@ · %lld synthetic recipient", comment: "official document detail")
            formatRows.append(Row(id: "esw", title: "ESW",
                                  value: String(format: format,
                                                safe(encryptedSwitch.method),
                                                Int64(encryptedSwitch.recipientCount))))
        }

        let boundaryTitle = isG2CSandbox
            ? NSLocalizedString("G2C development sandbox — not a legal delivery", comment: "official document detail")
            : NSLocalizedString("Synthetic test package — not an official delivery", comment: "official document detail")
        let boundaryValue = isG2CSandbox
            ? NSLocalizedString("This repository-owned simulator exercised a non-routable address, sender signature, encrypted content and local confirmation. No government service sent or received it.", comment: "official document detail")
            : NSLocalizedString("This fixture exercises EN, DI, ESW, storage, integrity and viewing state. No government service sent it.", comment: "official document detail")
        groups = [
            Group(title: NSLocalizedString("Development boundary", comment: "official document detail"),
                  rows: [Row(
                    id: "boundary",
                    title: boundaryTitle,
                    value: boundaryValue)]),
            Group(title: NSLocalizedString("Document", comment: "official document detail"), rows: documentRows),
            Group(title: NSLocalizedString("Content", comment: "official document detail"), rows: contentRows),
            Group(title: NSLocalizedString("Evidence and limits", comment: "official document detail"), rows: integrityRows),
            Group(title: NSLocalizedString("Exchange components", comment: "official document detail"), rows: formatRows)
        ]
        if isG2CSandbox, package.sandboxDelivery?.confirmation == nil {
            groups.append(Group(title: "", rows: [Row(
                id: "confirmSandbox",
                title: NSLocalizedString("Record simulated receipt confirmation", comment: "official document detail"),
                value: NSLocalizedString("Records a local technical acknowledgement only. It does not notify an agency or create legal delivery.", comment: "official document detail"))]))
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        groups[section].rows.count
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        groups[section].title
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = groups[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.accessibilityIdentifier = "officialDocuments.detail.\(row.id)"
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.text = row.title
        cell.detailTextLabel?.font = row.id == "fingerprint"
            ? UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            : .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = row.value
        cell.selectionStyle = row.id == "confirmSandbox" ? .default : .none
        if row.id == "confirmSandbox" {
            cell.textLabel?.textColor = .tintColor
            cell.imageView?.image = UIImage(systemName: "checkmark.message")
            cell.imageView?.tintColor = .tintColor
            cell.accessoryType = .disclosureIndicator
        }
        if row.id == "boundary" {
            cell.imageView?.image = UIImage(systemName: "hammer")
            cell.imageView?.tintColor = .systemOrange
        }
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard groups[indexPath.section].rows[indexPath.row].id == "confirmSandbox" else {
            return
        }
        #if DEBUG
        presentSandboxConfirmationPrompt()
        #endif
    }

    #if DEBUG
    private func presentSandboxConfirmationPrompt() {
        let alert = UIAlertController(
            title: NSLocalizedString("Record a simulated receipt confirmation?", comment: "official document detail"),
            message: NSLocalizedString("This records an idempotent acknowledgement only inside this iPhone's development sandbox. It sends no network request and cannot establish legal delivery.", comment: "official document detail"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Record simulated confirmation", comment: "official document detail"),
            style: .default) { [weak self] _ in
                guard let self else { return }
                do {
                    self.package = try self.archive.recordDevelopmentSandboxConfirmation(
                        id: self.packageID)
                    self.rebuildGroups()
                    self.tableView.reloadData()
                    let completed = UIAlertController(
                        title: NSLocalizedString("Sandbox confirmation recorded", comment: "official document detail"),
                        message: NSLocalizedString("The technical receive lifecycle is complete in this development simulator. No government service was contacted, and legal delivery remains inactive.", comment: "official document detail"),
                        preferredStyle: .alert)
                    completed.addAction(UIAlertAction(
                        title: NSLocalizedString("OK", comment: ""), style: .cancel))
                    self.present(completed, animated: true)
                } catch {
                    let failure = UIAlertController(
                        title: NSLocalizedString("The sandbox confirmation was not recorded", comment: "official document detail"),
                        message: error.localizedDescription,
                        preferredStyle: .alert)
                    failure.addAction(UIAlertAction(
                        title: NSLocalizedString("OK", comment: ""), style: .cancel))
                    self.present(failure, animated: true)
                }
            })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }
    #endif

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func safe(_ value: String) -> String { UntrustedText.value(value).text }
}

extension OfficialDocumentDetailViewController: PrivacyShieldedScreen {}
