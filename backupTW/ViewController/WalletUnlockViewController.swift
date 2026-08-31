//
//  WalletUnlockViewController.swift
//  backupTW
//

import LocalAuthentication
import UIKit

/// The opaque login gate shown before wallet contents become visible.
/// `.deviceOwnerAuthentication` lets iOS choose Face ID when available and fall
/// back to the device passcode; the app never sees either secret.
final class WalletUnlockViewController: UIViewController {

    var onUnlocked: (() -> Void)?

    private let icon = UIImageView(image: UIImage(systemName: "faceid"))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let unlockButton = UIButton(type: .system)
    private var authenticationStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        isModalInPresentation = true

        icon.tintColor = .systemIndigo
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 58, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.text = NSLocalizedString("Unlock 有備而來", comment: "wallet login title")
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.text = NSLocalizedString("Use Face ID or this phone's passcode. Your biometric data never enters this app.", comment: "wallet login explanation")
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Unlock", comment: "wallet login button")
        configuration.image = UIImage(systemName: "lock.open.fill")
        configuration.imagePadding = 8
        unlockButton.configuration = configuration
        unlockButton.addTarget(self, action: #selector(authenticate), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, unlockButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.setCustomSpacing(28, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 72),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !authenticationStarted else { return }
        authenticationStarted = true
        authenticate()
    }

    @objc private func authenticate() {
        unlockButton.isEnabled = false
        let context = LAContext()
        context.localizedFallbackTitle = NSLocalizedString("Use phone passcode", comment: "Face ID fallback")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            showFailure(NSLocalizedString("Set a passcode on this phone before using the wallet.", comment: "wallet login unavailable"))
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: NSLocalizedString("Unlock your credentials in 有備而來", comment: "Face ID reason")
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.onUnlocked?()
                } else {
                    self.showFailure(NSLocalizedString("The wallet is still locked.", comment: "wallet login failed"))
                }
            }
        }
    }

    private func showFailure(_ message: String) {
        detailLabel.text = message
        unlockButton.isEnabled = true
    }
}
