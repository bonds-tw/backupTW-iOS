//
//  WalletUnlockViewController.swift
//  backupTW
//

import LocalAuthentication
import UIKit

/// The shared, opaque background for both the app-switcher privacy cover and the
/// interactive unlock screen. It deliberately contains no credential data.
final class WalletLockBackdropView: UIView {

    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.23, alpha: 1)
        gradient.colors = [
            UIColor(red: 0.08, green: 0.12, blue: 0.32, alpha: 1).cgColor,
            UIColor(red: 0.22, green: 0.27, blue: 0.63, alpha: 1).cgColor,
            UIColor(red: 0.42, green: 0.24, blue: 0.62, alpha: 1).cgColor,
        ]
        gradient.locations = [0, 0.62, 1]
        gradient.startPoint = CGPoint(x: 0.08, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}

enum WalletLockArtwork {

    static func mark(symbolName: String = "lock.shield.fill", size: CGFloat = 92) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        container.layer.cornerRadius = size * 0.30
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let image = UIImageView(image: UIImage(systemName: symbolName))
        image.tintColor = .white
        image.contentMode = .scaleAspectFit
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: size * 0.42, weight: .medium)
        image.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(image)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size),
            container.heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: size * 0.52),
            image.heightAnchor.constraint(equalTo: image.widthAnchor),
        ])
        return container
    }
}

/// The opaque login gate shown before wallet contents become visible.
/// `.deviceOwnerAuthentication` lets iOS choose Face ID or Touch ID when
/// available and fall back to the device passcode; the app never sees any of
/// those secrets.
final class WalletUnlockViewController: UIViewController {

    var onUnlocked: (() -> Void)?

    private let backdrop = WalletLockBackdropView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let methodIcon = UIImageView()
    private let methodLabel = UILabel()
    private let unlockButton = UIButton(type: .system)
    private let authenticationSurface = UIView()
    private var authenticationInProgress = false
    private var unlockButtonTitle = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        isModalInPresentation = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let brandIcon = UIImageView(image: UIImage(systemName: "checkmark.shield.fill"))
        brandIcon.tintColor = .white
        brandIcon.setContentHuggingPriority(.required, for: .horizontal)
        let brandLabel = UILabel()
        brandLabel.text = "有備而來"
        brandLabel.textColor = .white
        brandLabel.font = .preferredFont(forTextStyle: .headline)
        brandLabel.adjustsFontForContentSizeCategory = true
        let brand = UIStackView(arrangedSubviews: [brandIcon, brandLabel])
        brand.axis = .horizontal
        brand.alignment = .center
        brand.spacing = 8
        brand.isLayoutMarginsRelativeArrangement = true
        brand.layoutMargins = UIEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)
        brand.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        brand.layer.cornerRadius = 18
        brand.setContentHuggingPriority(.required, for: .horizontal)

        let mark = WalletLockArtwork.mark()

        titleLabel.text = NSLocalizedString("Unlock 有備而來", comment: "wallet login title")
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        // Keep the calm lock screen free of implementation details. This label
        // is revealed only when authentication cannot proceed or is cancelled.
        detailLabel.isHidden = true

        methodIcon.contentMode = .scaleAspectFit
        methodIcon.tintColor = .systemIndigo
        methodIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 25, weight: .medium)
        methodIcon.translatesAutoresizingMaskIntoConstraints = false
        methodIcon.widthAnchor.constraint(equalToConstant: 34).isActive = true

        methodLabel.font = .preferredFont(forTextStyle: .subheadline)
        methodLabel.adjustsFontForContentSizeCategory = true
        methodLabel.textColor = .secondaryLabel
        methodLabel.numberOfLines = 0

        let methodRow = UIStackView(arrangedSubviews: [methodIcon, methodLabel])
        methodRow.axis = .horizontal
        methodRow.alignment = .center
        methodRow.spacing = 12

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = .systemIndigo
        unlockButton.configuration = configuration
        unlockButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        unlockButton.addTarget(self, action: #selector(authenticate), for: .touchUpInside)

        configureAuthenticationMethod()

        let panelStack = UIStackView(arrangedSubviews: [methodRow, unlockButton])
        panelStack.axis = .vertical
        panelStack.spacing = 20
        panelStack.isLayoutMarginsRelativeArrangement = true
        panelStack.layoutMargins = UIEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        panelStack.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
        panelStack.layer.cornerRadius = 26
        panelStack.layer.cornerCurve = .continuous
        panelStack.layer.shadowColor = UIColor.black.cgColor
        panelStack.layer.shadowOpacity = 0.18
        panelStack.layer.shadowRadius = 24
        panelStack.layer.shadowOffset = CGSize(width: 0, height: 12)

        let authStack = UIStackView(arrangedSubviews: [mark, titleLabel, detailLabel, panelStack])
        authStack.axis = .vertical
        authStack.alignment = .center
        authStack.spacing = 18
        authStack.setCustomSpacing(24, after: mark)
        authStack.setCustomSpacing(24, after: detailLabel)
        authStack.translatesAutoresizingMaskIntoConstraints = false
        authenticationSurface.addSubview(authStack)
        NSLayoutConstraint.activate([
            authStack.leadingAnchor.constraint(equalTo: authenticationSurface.leadingAnchor),
            authStack.trailingAnchor.constraint(equalTo: authenticationSurface.trailingAnchor),
            authStack.topAnchor.constraint(equalTo: authenticationSurface.topAnchor),
            authStack.bottomAnchor.constraint(equalTo: authenticationSurface.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalTo: authStack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: authStack.widthAnchor),
            panelStack.widthAnchor.constraint(equalTo: authStack.widthAnchor),
        ])

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let layout = UIStackView(arrangedSubviews: [brand, authenticationSurface])
        layout.axis = .vertical
        layout.alignment = .center
        layout.spacing = 42
        layout.translatesAutoresizingMaskIntoConstraints = false

        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        content.addSubview(layout)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            layout.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 28),
            layout.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -32),
            layout.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            layout.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56),
            authenticationSurface.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
    }

    private func configureAuthenticationMethod() {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        switch context.biometryType {
        case .faceID:
            methodIcon.image = UIImage(systemName: "faceid")
            unlockButtonTitle = NSLocalizedString("Use Face ID to unlock", comment: "wallet Face ID button")
        case .touchID:
            methodIcon.image = UIImage(systemName: "touchid")
            unlockButtonTitle = NSLocalizedString("Use Touch ID to unlock", comment: "wallet Touch ID button")
        default:
            methodIcon.image = UIImage(systemName: "lock.open.fill")
            unlockButtonTitle = NSLocalizedString("Use device passcode to unlock", comment: "wallet passcode button")
        }

        methodLabel.text = NSLocalizedString(
            "Your credentials stay protected on this device.",
            comment: "wallet local protection explanation")
        unlockButton.configuration?.title = unlockButtonTitle
        unlockButton.configuration?.image = methodIcon.image
    }

    @objc private func authenticate() {
        guard !authenticationInProgress else { return }
        authenticationInProgress = true
        detailLabel.isHidden = true
        unlockButton.isEnabled = false
        unlockButton.configuration?.showsActivityIndicator = true
        unlockButton.configuration?.title = NSLocalizedString("Confirming…", comment: "wallet authentication progress")

        let context = LAContext()
        context.localizedFallbackTitle = NSLocalizedString("Use device passcode", comment: "biometric fallback")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            restoreAfterAuthentication(
                message: NSLocalizedString("Set a passcode on this device before using the wallet.", comment: "wallet login unavailable"))
            return
        }

        // Fade the app-owned controls before iOS presents its authentication
        // panel. The system sheet now sits over a quiet branded background rather
        // than another Face ID icon, title, explanation and button.
        UIView.animate(withDuration: 0.18, animations: {
            self.authenticationSurface.alpha = 0.06
            self.authenticationSurface.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }) { [weak self] _ in
            guard let self else { return }
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: NSLocalizedString("Confirm it’s you to open 有備而來", comment: "wallet authentication reason")
            ) { [weak self] success, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if success {
                        self.onUnlocked?()
                    } else {
                        self.restoreAfterAuthentication(
                            message: NSLocalizedString("The wallet is still locked.", comment: "wallet login failed"))
                    }
                }
            }
        }
    }

    private func restoreAfterAuthentication(message: String) {
        authenticationInProgress = false
        detailLabel.text = message
        detailLabel.isHidden = false
        unlockButton.configuration?.showsActivityIndicator = false
        unlockButton.configuration?.title = unlockButtonTitle
        unlockButton.isEnabled = true
        UIView.animate(withDuration: 0.22) {
            self.authenticationSurface.alpha = 1
            self.authenticationSurface.transform = .identity
        }
    }
}
