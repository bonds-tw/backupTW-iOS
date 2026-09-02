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
    private var transferStartedAt: UInt64?
    private var runRecordWritten = false

    /// The privacy sentence, on its own label.
    ///
    /// # It was written, translated, positioned — and never drawn once
    ///
    /// `buildInterface()` set `detailLabel.text` to 「%@ · nothing is sent
    /// anywhere else, and nothing is kept afterwards」 and `viewDidLoad` called
    /// `startLink()` immediately afterwards, which overwrote the same label in
    /// the same runloop with the duration estimate. `show(.starting)` wrote it a
    /// third time. Three assignments to one label, no state that put the first
    /// one back: the sentence was not brief on screen, it was never on screen.
    ///
    /// It happened while adding the estimate: the audit note that asked for it
    /// described this screen as 「four lines of text」, so the estimate was
    /// written *into* the fourth line rather than added as a fifth. The line
    /// count did not change and a sentence quietly left the build.
    ///
    /// Two labels now, because they answer different questions and neither is a
    /// qualification of the other.
    private let privacyLabel = UILabel()

    init(payload: Data, engagement: ZKLinkEngagement) {
        self.payload = payload
        self.engagement = engagement
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shared; see `ScreenWakeLock`.
    private let wakeLock = AppScreenWakeLock.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Sending the proof", comment: "")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(finish))
        buildInterface()
        startLink()
        // 21.7 seconds measured end to end, during which the holder touches
        // nothing. Auto-Lock is 30 seconds in Low Power Mode and cannot be
        // changed there, so this is the screen where the default is closest to
        // cutting the transfer in half.
        wakeLock.hold()
    }

    /// The radio is the screen's, and it goes when the screen goes — including
    /// when the holder swipes the sheet away rather than tapping Done.
    deinit {
        link?.stop()
        // Paired with `viewDidLoad`, not with a lifecycle method, because the
        // radio is paired that way too — and the failure this guards against is
        // the sheet being swiped away rather than dismissed through Done, which
        // is the same reason `link?.stop()` is here.
        MainActor.assumeIsolated { wakeLock.release() }
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
        detailLabel.accessibilityIdentifier = "zklink.detail"
        showTheEstimate()

        privacyLabel.numberOfLines = 0
        privacyLabel.font = .preferredFont(forTextStyle: .footnote)
        privacyLabel.adjustsFontForContentSizeCategory = true
        privacyLabel.text = String(
            format: NSLocalizedString("%@ · nothing is sent anywhere else, and nothing is kept afterwards.", comment: ""),
            ZKStagePresentation.byteString(Int64(payload.count)))
        privacyLabel.accessibilityIdentifier = "zklink.privacy"

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progress = 0
        progressView.accessibilityIdentifier = "zklink.progress"

        [statusLabel, progressView, purposeLabel, detailLabel, privacyLabel].forEach(stack.addArrangedSubview)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    /// An estimate, said as one — and written in one place.
    ///
    /// This file's own header measures the transfer at 398,181 bytes over a
    /// 13.8 kB/s steady state, 21.7 seconds, and none of that used to reach the
    /// screen. The credential screen computes 「約 N 秒」 for a cycle three times
    /// shorter, and this is a modal sheet that a casual downward swipe dismisses,
    /// taking the radio with it — somebody with no expectation of how long it
    /// takes is exactly the person who swipes.
    ///
    /// The twelve-line comment and the assignment were pasted twice. Once.
    private func showTheEstimate() {
        detailLabel.text = String(
            format: NSLocalizedString("A proof is about %1$@, so sending it usually takes about %2$d seconds. Keep this screen open.", comment: "ZK send estimate"),
            ZKStagePresentation.byteString(Int64(payload.count)),
            max(1, Int((Double(payload.count) / 13_800).rounded())))
    }

    // MARK: - The radio

    private func startLink() {
        transferStartedAt = VerificationClock.now()
        statusLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        showTheEstimate()
        let link = BluetoothLinkPeripheral(payload: payload, serviceID: engagement.serviceID,
                                           vocabulary: .zeroKnowledgeProof) { [weak self] state in
            self?.show(state)
        }
        self.link = link
        link.start()
    }

    /// Seam: drive a radio state without a radio. It was a state transition that
    /// ate the privacy sentence, so the test has to make the transitions.
    func showForReview(_ state: BluetoothLinkState) { show(state) }

    /// One line about what is happening, never an error code.
    private func show(_ state: BluetoothLinkState) {
        switch state {
        case .unavailable(let reason):
            statusLabel.text = reason
        case .starting:
            statusLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
            showTheEstimate()
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
            progressView.setProgress(1, animated: true)
            statusLabel.text = NSLocalizedString("The checker's phone has the proof.", comment: "")
            // Down at once. A peripheral that kept advertising after delivery
            // would let the next stranger in the queue connect and collect the
            // same proof.
            link?.stop()
            link = nil
            recordTransfer(succeeded: true)
        case .failed(let reason):
            statusLabel.text = reason
            recordTransfer(succeeded: false)
        }
    }

    private func recordTransfer(succeeded: Bool) {
        guard !runRecordWritten else { return }
        runRecordWritten = true
        let completed = VerificationClock.now()
        let started = transferStartedAt ?? completed
        let milliseconds = VerificationClock.milliseconds(from: started, to: completed)
        let record = VerificationRunRecord(
            flow: .zeroKnowledgeProofVerification,
            role: .holder,
            credentialKind: .mobileCertificate,
            transport: .bluetooth,
            succeeded: succeeded,
            transportMilliseconds: milliseconds,
            endToEndMilliseconds: milliseconds,
            correlationToken: VerificationRunRecord.correlationToken(
                for: engagement.serviceID.uuidString),
            qrFallbackWasVisible: false)
        try? VerificationRunStore.shared.append(record)
    }

    @objc private func finish() {
        link?.stop()
        link = nil
        dismiss(animated: true)
    }
}
