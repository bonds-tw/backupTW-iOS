import UIKit

/// Explicit online preparation, separate from the nonce-to-verdict interval.
final class OfflinePreparationViewController: UIViewController {
    private let status = UILabel()
    private let trustButton = UIButton(type: .system)
    private let holderButton = UIButton(type: .system)
    private let verifierButton = UIButton(type: .system)
    private var task: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Prepare offline checking", comment: "offline preparation")
        view.backgroundColor = .systemGroupedBackground
        let explanation = UILabel()
        explanation.text = NSLocalizedString("While connected, save issuer trust on both devices. Prepare proof files on the iPhone and checking files on the iPad. Then enable Airplane Mode, turn Wi-Fi off in Settings, and turn Bluetooth back on. The iPad does not need a copy of your cards.", comment: "offline preparation")
        for label in [explanation, status] {
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
        }
        configure(trustButton, "Save issuer trust", #selector(prepareTrust))
        configure(holderButton, "Prepare proof files on this iPhone", #selector(prepareHolder))
        configure(verifierButton, "Prepare checking files on this iPad", #selector(prepareVerifier))
        let stack = UIStackView(arrangedSubviews: [explanation, trustButton, holderButton, verifierButton, status])
        stack.axis = .vertical
        stack.spacing = 20
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        if let snapshots = try? OfflineIssuerTrustStore().registrySnapshots(),
           let date = snapshots.map(\.verifiedAt).min() {
            status.text = String(format: NSLocalizedString("Saved %d issuer records. Oldest check: %@. This does not establish current card revocation status.", comment: "offline preparation"),
                                 snapshots.count, date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        task?.cancel()
    }

    private func configure(_ button: UIButton, _ title: String, _ action: Selector) {
        var config = UIButton.Configuration.bordered()
        config.title = NSLocalizedString(title, comment: "offline preparation")
        config.titleLineBreakMode = .byWordWrapping
        button.configuration = config
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> String) {
        task?.cancel()
        for button in [trustButton, holderButton, verifierButton] { button.isEnabled = false }
        status.text = NSLocalizedString("Preparing… Keep this screen open.", comment: "offline preparation")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { for button in [trustButton, holderButton, verifierButton] { button.isEnabled = true } }
            do {
                let message = try await operation()
                try Task.checkCancellation()
                status.text = message
            } catch is CancellationError {
                return
            } catch {
                status.text = NSLocalizedString("Preparation did not finish. Reconnect and tap the same button to retry. An earlier saved trust record keeps its original date.", comment: "offline preparation")
            }
        }
    }

    @objc private func prepareTrust() {
        run {
            let count = try await OfflineVerificationPreparation.refreshTrust()
            return String(format: NSLocalizedString("Saved %d issuer records. Only matching API and blockchain records can be used offline; current card revocation remains unknown.", comment: "offline preparation"), count)
        }
    }

    @objc private func prepareHolder() { prepare(.prover) }
    @objc private func prepareVerifier() { prepare(.verifier) }

    private func prepare(_ role: AgePredicateAssetRole) {
        run { [weak self] in
            let preparer = try AgePredicateCircuitAssetPreparer()
            _ = try await preparer.prepare(role) { fraction in
                Task { @MainActor [weak self] in
                    self?.status.text = String(format: NSLocalizedString("Preparing files… %d%%", comment: "offline preparation"), Int((fraction * 100).rounded()))
                }
            }
            return NSLocalizedString("Files are downloaded and their checksums match. You can now disconnect and start a check.", comment: "offline preparation")
        }
    }
}
