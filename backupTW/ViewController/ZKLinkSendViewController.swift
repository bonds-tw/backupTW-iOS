//
//  ZKLinkSendViewController.swift
//  backupTW
//
//  The screen that holds the radio while ~400 KB crosses a counter.
//

import UIKit

/// Sends one proof to one checker, and shows how far it has got.
///
/// # Why this is a screen and not a spinner on the previous one
///
/// Because it takes long enough to need one. A card-signed presentation is 8 KB
/// and lands before a progress bar could animate; a ZK package is 398,181 bytes
/// measured on a real card, which is **21.7 seconds** on a real radio
/// (2026-08-13). Not the nine this used to claim: that came from extrapolating a
/// twelve-frame transfer's 35 kB/s, and twelve frames never touch back-pressure.
/// At 597 frames the steady state is 13.8 kB/s.
///
/// Twenty-two seconds of unexplained pause is well past where a person puts
/// their phone down, which makes the progress bar below load-bearing rather than
/// decorative.
///
/// It also gives the holder somewhere to stop. The radio lives exactly as long as
/// this screen does: dismissing it releases `BluetoothLinkPeripheral`, and
/// `CBPeripheralManager` does not retain its delegate, so releasing the object is
/// switching the radio off. That equivalence is deliberate — the holder's phone
/// must never be discoverable after they have put the screen away — and it is
/// also the shape of a bug this project has already paid for once: on the
/// credential screen the teardown was placed in a method the *start* path called
/// as a reset, and the peripheral was released microseconds after it was created,
/// before CoreBluetooth's first callback. Here there is one owner and one
/// lifetime, and `deinit` is where it ends.
final class ZKLinkSendViewController: UIViewController {

    private let payload: Data
    private let engagement: ZKLinkEngagement

    private let purposeLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    private var link: BluetoothLinkPeripheral?

    /// True once the checker's phone has acknowledged the whole payload. Kept so
    /// that dismissing after a success is not reported as an interrupted send.
    private var delivered = false

    init(payload: Data, engagement: ZKLinkEngagement) {
        self.payload = payload
        self.engagement = engagement
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Sending the proof", comment: "")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(finish))
        buildInterface()
        startLink()
    }

    /// The radio is the screen's, and it goes when the screen goes — including
    /// when the holder swipes the sheet away rather than tapping Done.
    deinit {
        link?.stop()
    }

    // MARK: - Interface

    private func buildInterface() {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill

        purposeLabel.numberOfLines = 0
        purposeLabel.font = .preferredFont(forTextStyle: .body)
        purposeLabel.adjustsFontForContentSizeCategory = true
        // The checker's own words, drawn as untrusted text for the same reason
        // the result screen does it: this string came off a stranger's QR code
        // and must not be able to impersonate the app's own voice with newlines
        // or bidirectional overrides.
        purposeLabel.text = String(format: NSLocalizedString("They say this check is for: %@", comment: ""),
                                   UntrustedText.value(engagement.purpose).text)
        purposeLabel.accessibilityIdentifier = "zklink.purpose"

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .title3)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityIdentifier = "zklink.status"

        detailLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.text = String(
            format: NSLocalizedString("%@ · nothing is sent anywhere else, and nothing is kept afterwards.", comment: ""),
            ZKStagePresentation.byteString(Int64(payload.count)))
        detailLabel.accessibilityIdentifier = "zklink.detail"

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progress = 0
        progressView.accessibilityIdentifier = "zklink.progress"

        [statusLabel, progressView, purposeLabel, detailLabel].forEach(stack.addArrangedSubview)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - The radio

    private func startLink() {
        statusLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        let link = BluetoothLinkPeripheral(payload: payload, serviceID: engagement.serviceID) { [weak self] state in
            self?.show(state)
        }
        self.link = link
        link.start()
    }

    /// One line about what is happening, never an error code.
    private func show(_ state: BluetoothLinkState) {
        switch state {
        case .unavailable(let reason):
            statusLabel.text = reason
        case .starting:
            statusLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        case .waiting:
            // Deliberately not the same sentence as `.starting`. When those two
            // matched on the credential screen, "advertising and waiting" and
            // "nothing ever happened" were the same pixels, and four device runs
            // went into finding that out.
            statusLabel.text = NSLocalizedString("Ready — waiting for the checker's phone.", comment: "")
        case .transferring(let fraction):
            statusLabel.text = String(format: NSLocalizedString("Sending… %d%%", comment: ""),
                                      Int((fraction * 100).rounded()))
            progressView.setProgress(Float(fraction), animated: true)
        case .finished:
            delivered = true
            progressView.setProgress(1, animated: true)
            statusLabel.text = NSLocalizedString("The checker's phone has the proof.", comment: "")
            // Down at once. A peripheral that kept advertising after delivery
            // would let the next stranger in the queue connect and collect the
            // same proof.
            link?.stop()
            link = nil
        case .failed(let reason):
            statusLabel.text = reason
        }
    }

    @objc private func finish() {
        link?.stop()
        link = nil
        dismiss(animated: true)
    }
}
