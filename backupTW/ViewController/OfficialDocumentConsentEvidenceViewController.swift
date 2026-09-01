//
//  OfficialDocumentConsentEvidenceViewController.swift
//  backupTW
//

import UIKit

/// Lets the holder inspect and remove the locally verified pilot-consent
/// evidence without ever rendering or exporting the certificate/signature.
///
/// The screen keeps the legal boundary visible: this receipt proves only the
/// narrow signed `local-prototype-only` statement. It is not an inbox address,
/// a government enrolment response or a legal-delivery receipt.
final class OfficialDocumentConsentEvidenceViewController: UITableViewController {
    private struct Row {
        let id: String
        let title: String
        let value: String
        var isFingerprint = false
    }

    private struct Group {
        let title: String
        let rows: [Row]
    }

    private let receipt: OfficialDocumentInboxReceipt
    private let archive: OfficialDocumentInboxArchive
    private let onRemoved: () -> Void
    private var groups: [Group] = []

    init(receipt: OfficialDocumentInboxReceipt,
         archive: OfficialDocumentInboxArchive,
         onRemoved: @escaping () -> Void = {}) {
        self.receipt = receipt
        self.archive = archive
        self.onRemoved = onRemoved
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Signed consent evidence", comment: "official document consent evidence")
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        buildGroups()
    }

    private func buildGroups() {
        groups = [
            Group(title: NSLocalizedString("Current state", comment: "official document consent evidence"),
                  rows: [Row(
                    id: "boundary",
                    title: NSLocalizedString("Local prototype evidence — not an official inbox", comment: "official document consent evidence"),
                    value: NSLocalizedString("The saved signature was checked again before this screen opened. No government G2C service has accepted this app or issued a receiving address.", comment: "official document consent evidence"))]),
            Group(title: NSLocalizedString("Signed consent", comment: "official document consent evidence"),
                  rows: [
                    Row(id: "signedAt",
                        title: NSLocalizedString("Signature completed", comment: "official document consent evidence"),
                        value: Self.date(receipt.recordedAt)),
                    Row(id: "scope",
                        title: NSLocalizedString("Signed scope", comment: "official document consent evidence"),
                        value: NSLocalizedString("Local prototype only", comment: "official document consent evidence")),
                    Row(id: "signingChannel",
                        title: NSLocalizedString("Signing method", comment: "official document consent evidence"),
                        value: signingMethod),
                    Row(id: "proof",
                        title: NSLocalizedString("What this proves", comment: "official document consent evidence"),
                        value: proofStatement),
                    Row(id: "limits",
                        title: NSLocalizedString("What this does not prove", comment: "official document consent evidence"),
                        value: NSLocalizedString("It does not prove government enrolment, a receiving address, sender authentication, document receipt or legal delivery.", comment: "official document consent evidence"))
                  ]),
            Group(title: NSLocalizedString("Evidence fingerprints", comment: "official document consent evidence"),
                  rows: [
                    Row(id: "consentFingerprint",
                        title: NSLocalizedString("Consent fingerprint (SHA-256)", comment: "official document consent evidence"),
                        value: Self.displayFingerprint(receipt.consentFingerprint),
                        isFingerprint: true),
                    Row(id: "certificateFingerprint",
                        title: NSLocalizedString("Certificate fingerprint (SHA-256)", comment: "official document consent evidence"),
                        value: Self.displayFingerprint(receipt.certificateFingerprint ?? ""),
                        isFingerprint: true),
                    Row(id: "signatureFingerprint",
                        title: NSLocalizedString("Signature fingerprint (SHA-256)", comment: "official document consent evidence"),
                        value: Self.displayFingerprint(receipt.signatureFingerprint ?? ""),
                        isFingerprint: true),
                    Row(id: "fingerprintPrivacy",
                        title: NSLocalizedString("Keep these fingerprints private", comment: "official document consent evidence"),
                        value: NSLocalizedString("A certificate fingerprint can link signatures made with the same certificate. 有備而來 does not transmit, log or share the fingerprints on this screen.", comment: "official document consent evidence"))
                  ]),
            Group(title: "", rows: [Row(
                id: "remove",
                title: NSLocalizedString("Remove consent evidence from this iPhone", comment: "official document consent evidence"),
                value: removalSummary)])
        ]
    }

    private var signingMethod: String {
        switch receipt.signingChannel {
        case .physicalNaturalPersonCertificate:
            return NSLocalizedString("Physical natural-person certificate via the local Mac development helper", comment: "official document consent evidence")
        case .mobileNaturalPersonCertificate, .none:
            return NSLocalizedString("行動自然人憑證 app-to-app", comment: "official document consent evidence")
        }
    }

    private var proofStatement: String {
        switch receipt.signingChannel {
        case .physicalNaturalPersonCertificate:
            return NSLocalizedString("The holder used the physical natural-person certificate private key to approve this exact local-prototype consent.", comment: "official document consent evidence")
        case .mobileNaturalPersonCertificate, .none:
            return NSLocalizedString("The holder approved this exact local-prototype consent with 行動自然人憑證.", comment: "official document consent evidence")
        }
    }

    private var removalSummary: String {
        switch receipt.signingChannel {
        case .physicalNaturalPersonCertificate:
            return NSLocalizedString("Deletes only the local certificate and signature. This development path did not create a Ministry of the Interior service record.", comment: "official document consent evidence")
        case .mobileNaturalPersonCertificate, .none:
            return NSLocalizedString("Deletes only the local certificate and signature. It cannot erase the service record kept by the Ministry of the Interior.", comment: "official document consent evidence")
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        groups[section].rows.count
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        let title = groups[section].title
        return title.isEmpty ? nil : title
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = groups[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.accessibilityIdentifier = "officialDocuments.consentEvidence.\(row.id)"
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.text = row.title
        cell.detailTextLabel?.font = row.isFingerprint
            ? UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            : .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = row.value
        cell.selectionStyle = row.id == "remove" ? .default : .none

        if row.id == "boundary" {
            cell.imageView?.image = UIImage(systemName: "checkmark.shield")
            cell.imageView?.tintColor = .systemGreen
        } else if row.id == "remove" {
            cell.textLabel?.textColor = .systemRed
            cell.imageView?.image = UIImage(systemName: "trash")
            cell.imageView?.tintColor = .systemRed
        }
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard groups[indexPath.section].rows[indexPath.row].id == "remove" else { return }
        presentRemovalConfirmation()
    }

    private func presentRemovalConfirmation() {
        let alert = UIAlertController(
            title: NSLocalizedString("Remove this local consent evidence?", comment: "official document consent evidence"),
            message: removalConfirmation,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Remove from this iPhone", comment: "official document consent evidence"),
            style: .destructive) { [weak self] _ in self?.removeEvidence() })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    private var removalConfirmation: String {
        switch receipt.signingChannel {
        case .physicalNaturalPersonCertificate:
            return NSLocalizedString("This deletes the physical-card certificate and signature from this iPhone. It does not revoke an official inbox — none exists — and the development helper created no government service record.", comment: "official document consent evidence")
        case .mobileNaturalPersonCertificate, .none:
            return NSLocalizedString("This deletes the certificate and signature from this iPhone. It does not revoke an official inbox — none exists — and it cannot erase the service record kept by the Ministry of the Interior.", comment: "official document consent evidence")
        }
    }

    private func removeEvidence() {
        do {
            try archive.removeReceipt()
            onRemoved()
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(
                title: NSLocalizedString("The local consent evidence was not removed", comment: "official document consent evidence"),
                message: error.localizedDescription,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            present(alert, animated: true)
        }
    }

    private static func displayFingerprint(_ fingerprint: String) -> String {
        guard !fingerprint.isEmpty else {
            return NSLocalizedString("Unavailable", comment: "official document consent evidence")
        }
        let upper = fingerprint.uppercased()
        return stride(from: 0, to: upper.count, by: 4).map { offset in
            let start = upper.index(upper.startIndex, offsetBy: offset)
            let end = upper.index(start, offsetBy: min(4, upper.count - offset))
            return String(upper[start..<end])
        }.joined(separator: " ")
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension OfficialDocumentConsentEvidenceViewController: PrivacyShieldedScreen {}
