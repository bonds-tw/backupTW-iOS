//
//  OfficialDocumentDetailViewController.swift
//  backupTW
//

import UIKit

/// Holder-facing view of one preserved EN / DI / ESW package index.
///
/// Opening this screen changes only `LocalState`. It never creates or sends the
/// exchange confirmation message that an official service may later require.
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

        let integrityRows = [
            Row(id: "integrity",
                title: NSLocalizedString("File integrity", comment: "official document detail"),
                value: NSLocalizedString("Verified against the SHA-256 fingerprints listed in EN.", comment: "official document detail")),
            Row(id: "authentication",
                title: NSLocalizedString("Sender authentication", comment: "official document detail"),
                value: NSLocalizedString("Not verified — this package is synthetic and has no official exchange signature or address-book proof.", comment: "official document detail")),
            Row(id: "receipt",
                title: NSLocalizedString("Legal receipt", comment: "official document detail"),
                value: NSLocalizedString("Not created — viewing this test package changes only this phone's local state and sends nothing.", comment: "official document detail")),
            Row(id: "fingerprint",
                title: NSLocalizedString("EN fingerprint", comment: "official document detail"),
                value: package.integrity.envelopeDigest)
        ]

        var formatRows = [
            Row(id: "en", title: "EN",
                value: NSLocalizedString("Envelope metadata and file fingerprints parsed", comment: "official document detail")),
            Row(id: "di", title: "DI",
                value: document == nil
                    ? NSLocalizedString("Not available outside the encrypted payload", comment: "official document detail")
                    : NSLocalizedString("Synthetic XML document parsed for display", comment: "official document detail"))
        ]
        if let encryptedSwitch = package.encryptedSwitch {
            let format = NSLocalizedString("Metadata only · %@ · %lld synthetic recipient", comment: "official document detail")
            formatRows.append(Row(id: "esw", title: "ESW",
                                  value: String(format: format,
                                                safe(encryptedSwitch.method),
                                                Int64(encryptedSwitch.recipientCount))))
        }

        groups = [
            Group(title: NSLocalizedString("Development boundary", comment: "official document detail"),
                  rows: [Row(
                    id: "boundary",
                    title: NSLocalizedString("Synthetic test package — not an official delivery", comment: "official document detail"),
                    value: NSLocalizedString("This fixture exercises EN, DI, ESW, storage, integrity and viewing state. No government service sent it.", comment: "official document detail"))]),
            Group(title: NSLocalizedString("Document", comment: "official document detail"), rows: documentRows),
            Group(title: NSLocalizedString("Content", comment: "official document detail"), rows: contentRows),
            Group(title: NSLocalizedString("Evidence and limits", comment: "official document detail"), rows: integrityRows),
            Group(title: NSLocalizedString("Exchange components", comment: "official document detail"), rows: formatRows)
        ]
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
        cell.selectionStyle = .none
        if row.id == "boundary" {
            cell.imageView?.image = UIImage(systemName: "hammer")
            cell.imageView?.tintColor = .systemOrange
        }
        return cell
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func safe(_ value: String) -> String { UntrustedText.value(value).text }
}

extension OfficialDocumentDetailViewController: PrivacyShieldedScreen {}
