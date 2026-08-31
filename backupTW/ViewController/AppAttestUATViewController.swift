//
//  AppAttestUATViewController.swift
//  backupTW
//

import UIKit

struct AppAttestUATReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case passed
        case failed(code: String)
    }

    let outcome: Outcome
    let endpointHost: String
    let appVersion: String
    let systemVersion: String
    let checkedAt: Date

    static func make(
        outcome: Outcome,
        endpointHost: String,
        bundle: Bundle = .main,
        systemVersion: String = UIDevice.current.systemVersion,
        checkedAt: Date = Date()
    ) -> Self {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? NSLocalizedString("Unknown", comment: "")
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? NSLocalizedString("Unknown", comment: "")
        return Self(outcome: outcome,
                    endpointHost: endpointHost,
                    appVersion: "\(version) (\(build))",
                    systemVersion: systemVersion,
                    checkedAt: checkedAt)
    }

    static func safeErrorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is URLError { return "network_unavailable" }
        guard let error = error as? SigningBrokerClientError else {
            return "unexpected_error"
        }
        switch error {
        case .configurationMissing: return "configuration_missing"
        case .appAttestUnsupported: return "app_attest_unsupported"
        case .appAttestUnavailable: return "app_attest_unavailable"
        case .appAttestKeyInvalid: return "app_attest_key_invalid"
        case .invalidTimeLimit: return "invalid_time_limit"
        case .invalidResponse: return "invalid_response"
        case .server(let code, _):
            // Server error codes are public API vocabulary, but still constrain
            // them before placing one on the clipboard.
            guard !code.isEmpty, code.utf8.count <= 64,
                  code.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0)
                  }) else {
                return "invalid_response"
            }
            return "server_\(code)"
        }
    }

    var copyText: String {
        let result: String
        let errorCode: String?
        switch outcome {
        case .passed:
            result = "PASS"
            errorCode = nil
        case .failed(let code):
            result = "FAIL"
            errorCode = code
        }
        var rows = [
            "App Attest UAT",
            "result=\(result)",
            "endpoint=\(endpointHost)",
            "app_version=\(appVersion)",
            "ios_version=\(systemVersion)",
            "checked_at=\(checkedAtText)"
        ]
        if let errorCode { rows.append("error_code=\(errorCode)") }
        rows.append("identity_data_sent=false")
        rows.append("signing_started=false")
        return rows.joined(separator: "\n")
    }

    var checkedAtText: String {
        Self.timestampFormatter.string(from: checkedAt)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// An explicit, privacy-safe real-device acceptance check. Merely opening the
/// screen never creates a key or contacts the server; the state change happens
/// only after the user confirms the Run action.
final class AppAttestUATViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case explanation
        case result
        case action
    }

    private let checker: (any AppAttestUATChecking)?
    private var report: AppAttestUATReport?
    private var runTask: Task<Void, Never>?
    private var isRunning = false

    init(checker: (any AppAttestUATChecking)? = SigningBrokerSessionAssembly.makeAppAttestUATCheck()) {
        self.checker = checker
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("App Attest UAT check", comment: "diagnostic screen title")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyReport))
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AppAttestUATCell")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || isBeingDismissed else { return }
        runTask?.cancel()
        runTask = nil
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .explanation: return 2
        case .result: return report == nil ? 4 : 5
        case .action: return 1
        case .none: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .explanation: return NSLocalizedString("What this checks", comment: "")
        case .result: return NSLocalizedString("Result", comment: "")
        case .action, .none: return nil
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AppAttestUATCell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.accessibilityIdentifier = nil
        cell.selectionStyle = .none

        switch Section(rawValue: indexPath.section) {
        case .explanation:
            if indexPath.row == 0 {
                content.text = NSLocalizedString("Production App Attest chain", comment: "")
                content.secondaryText = NSLocalizedString(
                    "Registers or reuses this installation's App Attest key, creates a fresh assertion, and asks the reviewed Cloudflare server to verify its environment, app version, signature, and counter.",
                    comment: "App Attest UAT scope")
            } else {
                content.text = NSLocalizedString("No identity or signing data", comment: "")
                content.secondaryText = NSLocalizedString(
                    "This check sends no ID number, credential field, zero-knowledge proof, MOICA request, or signing payload.",
                    comment: "App Attest UAT privacy boundary")
            }
        case .result:
            configureResult(content: &content, cell: cell, row: indexPath.row)
        case .action:
            cell.accessibilityIdentifier = "appattest.run"
            content.text = isRunning
                ? NSLocalizedString("Checking…", comment: "App Attest UAT running")
                : NSLocalizedString("Run App Attest check", comment: "App Attest UAT action")
            content.textProperties.color = isRunning ? .secondaryLabel : .systemBlue
            content.textProperties.alignment = .center
            cell.selectionStyle = isRunning ? .none : .default
            if isRunning {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
        case .none:
            break
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .action, !isRunning else { return }
        confirmRun()
    }

    private func configureResult(content: inout UIListContentConfiguration,
                                 cell: UITableViewCell,
                                 row: Int) {
        let endpoint = checker?.endpointHost
            ?? NSLocalizedString("Not configured in this build", comment: "App Attest UAT endpoint")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        switch row {
        case 0:
            cell.accessibilityIdentifier = "appattest.status"
            content.text = NSLocalizedString("Status", comment: "")
            if isRunning {
                content.secondaryText = NSLocalizedString("Checking…", comment: "App Attest UAT running")
            } else if let report {
                switch report.outcome {
                case .passed:
                    content.secondaryText = NSLocalizedString("Passed", comment: "")
                    cell.accessoryView = VerdictSymbol.view("checkmark.circle.fill", .systemGreen)
                case .failed:
                    content.secondaryText = NSLocalizedString("Failed", comment: "")
                    cell.accessoryView = VerdictSymbol.view(
                        "exclamationmark.triangle.fill", .systemOrange)
                }
            } else {
                content.secondaryText = NSLocalizedString("Not run yet", comment: "")
            }
        case 1:
            cell.accessibilityIdentifier = "appattest.endpoint"
            content.text = NSLocalizedString("Endpoint", comment: "")
            content.secondaryText = endpoint
        case 2:
            content.text = NSLocalizedString("App build", comment: "")
            content.secondaryText = "\(version) (\(build))"
        case 3:
            content.text = NSLocalizedString("iOS version", comment: "")
            content.secondaryText = UIDevice.current.systemVersion
        default:
            content.text = NSLocalizedString("Checked at / error code", comment: "")
            if let report {
                switch report.outcome {
                case .passed:
                    content.secondaryText = report.checkedAtText
                case .failed(let code):
                    content.secondaryText = "\(report.checkedAtText)\n\(code)"
                }
            }
        }
    }

    private func confirmRun() {
        let alert = UIAlertController(
            title: NSLocalizedString("Run App Attest UAT check?", comment: ""),
            message: NSLocalizedString(
                "This creates or reuses this installation's App Attest key and advances its server-side assertion counter. No identity data or signing request is sent.",
                comment: "App Attest UAT confirmation"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Run check", comment: "App Attest UAT confirmation action"),
            style: .default) { [weak self] _ in self?.startRun() })
        present(alert, animated: true)
    }

    private func startRun() {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.reloadData()
        runTask = Task { [weak self] in
            guard let self else { return }
            let endpoint = checker?.endpointHost ?? "unconfigured"
            let outcome: AppAttestUATReport.Outcome
            do {
                guard let checker else { throw SigningBrokerClientError.configurationMissing }
                try await checker.run()
                outcome = .passed
            } catch is CancellationError {
                return
            } catch {
                outcome = .failed(code: AppAttestUATReport.safeErrorCode(error))
            }
            report = .make(outcome: outcome, endpointHost: endpoint)
            isRunning = false
            runTask = nil
            navigationItem.rightBarButtonItem?.isEnabled = true
            tableView.reloadData()
        }
    }

    @objc private func copyReport() {
        guard let report else { return }
        UIPasteboard.general.string = report.copyText
        let alert = UIAlertController(title: NSLocalizedString("Copied", comment: ""),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Confirm", comment: ""), style: .default))
        present(alert, animated: true)
    }
}
