//
//  ZKVerifyViewController.swift
//  backupTW
//

import UIKit
import UniformTypeIdentifiers

/// The verifier's side of a zero-knowledge proof.
///
/// # Why this is a file picker and not a camera
///
/// `VerifierViewController` next door shows a QR code and reads the holder's
/// answer through the camera, because a credential presentation is about 3 KB.
/// A proof is not: `VerifierCostSpike` measured 293,916 bytes across the four
/// artifacts, which is ~100 QR frames at version 40's ceiling. So the proof
/// arrives as a file — AirDrop, Files, a share sheet — until the Wi-Fi Aware or
/// BLE transport M3 still owes gets built.
///
/// # What this screen is careful about
///
/// Three outcomes, kept apart, for the same reason `ZKSelfCheck` keeps them
/// apart. "This device has not downloaded the checking files" is the verifier's
/// own setup problem and says nothing about the holder's proof. "The check ran
/// and could not finish" also says nothing. Only a completed check that returned
/// all three booleans true is an acceptance, and even that one is shown with the
/// caveats attached, because a proof this app can produce establishes materially
/// less than a green tick implies.
final class ZKVerifyViewController: UIViewController {

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let chooseButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Check a proof", comment: "")
        view.backgroundColor = .systemGroupedBackground
        configureLayout()
        show(status: NSLocalizedString("No proof loaded yet", comment: ""),
             detail: NSLocalizedString(
                "A zero-knowledge proof is about 290 KB — too large for a QR code, so it arrives as a file.",
                comment: ""),
             verdict: nil)
    }

    // MARK: - Layout

    private func configureLayout() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill

        statusLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityIdentifier = "zkverify.status"

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.accessibilityIdentifier = "zkverify.detail"

        spinner.hidesWhenStopped = true

        var config = UIButton.Configuration.filled()
        config.title = NSLocalizedString("Choose a proof file", comment: "")
        chooseButton.configuration = config
        chooseButton.accessibilityIdentifier = "zkverify.choose"
        chooseButton.addTarget(self, action: #selector(chooseFile), for: .touchUpInside)

        view.addSubview(scroll)
        scroll.addSubview(stack)
        [chooseButton, spinner, statusLabel, detailLabel].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20)
        ])
    }

    private func show(status: String, detail: String, verdict: Bool?) {
        statusLabel.text = status
        detailLabel.text = detail
        switch verdict {
        case .some(true): statusLabel.textColor = .systemGreen
        case .some(false): statusLabel.textColor = .systemOrange
        case .none: statusLabel.textColor = .label
        }
    }

    // MARK: - Loading

    @objc private func chooseFile() {
        // `.data` rather than a custom UTI: the exporter writes `.zkproof`,
        // which no system knows about, and a picker restricted to an
        // unregistered type shows every file greyed out.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func verify(fileAt url: URL) {
        // A file from the Files app lives outside this app's container; without
        // this the read fails with a permission error that reads like a corrupt
        // proof.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let package: ZKProofPackage
        do {
            package = try ZKProofPackage.decoded(from: try Data(contentsOf: url))
        } catch {
            show(status: NSLocalizedString("This proof file could not be read.", comment: ""),
                 detail: String(describing: error),
                 verdict: nil)
            return
        }

        spinner.startAnimating()
        chooseButton.isEnabled = false
        show(status: NSLocalizedString("Checking…", comment: ""),
             detail: NSLocalizedString(
                "This takes about fifteen seconds and runs entirely on this phone.", comment: ""),
             verdict: nil)

        guard let directory = try? CircuitAssets.defaultDirectory() else {
            spinner.stopAnimating()
            chooseButton.isEnabled = true
            show(status: NSLocalizedString("No verdict", comment: ""),
                 detail: NSLocalizedString(
                    "This device does not have the files needed to check a proof yet.", comment: ""),
                 verdict: nil)
            return
        }
        // Off the main thread and off the cooperative pool: the three checks
        // block for tens of seconds inside Rust. Same rule as `ZKProver.queue`.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try ZKPackageVerifier(assetDirectory: directory).verify(package)
            }
            DispatchQueue.main.async { self?.present(result, package: package) }
        }
    }

    private func present(_ result: Result<ZKPackageVerdict, Error>, package: ZKProofPackage) {
        spinner.stopAnimating()
        chooseButton.isEnabled = true

        switch result {
        case .success(let verdict):
            var lines: [String] = []
            if let outcome = verdict.outcome {
                // One check per line, in words. The single dotted line wrapped
                // unpredictably at accessibility sizes, and a bare ✗ gives
                // VoiceOver a glyph where the person needs a verdict — worse,
                // it never says *which* check the mark belongs to once the line
                // has folded.
                func stated(_ name: String, _ passed: Bool) -> String {
                    String(format: passed
                        ? NSLocalizedString("%@: passed", comment: "One ZK verification check")
                        : NSLocalizedString("%@: failed", comment: "One ZK verification check"), name)
                }
                lines.append(stated(NSLocalizedString("Certificate chain", comment: ""), outcome.certificateChainValid))
                lines.append(stated(NSLocalizedString("Signature", comment: ""), outcome.userSignatureValid))
                lines.append(stated(NSLocalizedString("Linked", comment: ""), outcome.linked))
            }
            lines.append(String(format: NSLocalizedString("Took %.1f seconds · %@", comment: ""),
                                verdict.seconds,
                                ZKStagePresentation.byteString(Int64(verdict.byteCount))))
            // Always shown, never behind a disclosure arrow. A proof this app
            // can produce establishes materially less than an unqualified tick
            // implies, and the caveats are the difference.
            lines.append("")
            lines.append(NSLocalizedString("What this does not establish:", comment: ""))
            lines.append(contentsOf: verdict.caveats.map { "• " + $0.localizedDescription })

            show(status: verdict.accepted
                    ? NSLocalizedString("Checked on this phone, and it passed", comment: "")
                    : NSLocalizedString("This phone checked the proof and refused it", comment: ""),
                 detail: lines.joined(separator: "\n"),
                 verdict: verdict.accepted)

        case .failure(let error):
            // Neither an acceptance nor a rejection. `verdict: nil` keeps it
            // grey: an orange warning here would say the proof is bad, when what
            // happened is that this device could not answer.
            show(status: NSLocalizedString("No verdict", comment: ""),
                 detail: error.localizedDescription,
                 verdict: nil)
        }
    }
}

// MARK: - UIDocumentPickerDelegate

extension ZKVerifyViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        verify(fileAt: url)
    }
}
