//
//  ConvenienceStorePickupViewController.swift
//  backupTW
//

import LocalAuthentication
import UIKit

/// The informed-disclosure step before the telecom credential leaves the phone.
/// It states the relying party and both values, then requires device-owner
/// authentication before the signed VP is posted.
final class ConvenienceStorePickupConsentViewController: UIViewController {

    private let context: ConvenienceStorePickupContext
    private let client: ConvenienceStorePickupClient
    private let disclosure: ConvenienceStorePickupDisclosure
    private let generateButton = UIButton(type: .system)
    private var authenticationContext: LAContext?

    init(context: ConvenienceStorePickupContext,
         client: ConvenienceStorePickupClient,
         disclosure: ConvenienceStorePickupDisclosure) {
        self.context = context
        self.client = client
        self.disclosure = disclosure
        super.init(nibName: nil, bundle: nil)
        title = UntrustedText.value(context.scenario.name).text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        let recipient = makeLabel(
            text: String(format: NSLocalizedString("Providing data to: %@", comment: "pickup recipient"),
                         NSLocalizedString("President Chain Store Corporation", comment: "7-ELEVEN legal name")),
            style: .headline)
        content.addArrangedSubview(recipient)
        content.addArrangedSubview(makeTrustEvidenceCard(context.trustEvidence))
        content.addArrangedSubview(makeLabel(text: NSLocalizedString("Data being provided", comment: "pickup disclosure heading"),
                                             style: .title2))

        let credentialName = UntrustedText.value(disclosure.credentialName).text
        let issuerName = Self.shortIssuerName(UntrustedText.value(disclosure.issuerName).text)
        let credentialID = UntrustedText.value(disclosure.credentialID).text
        content.addArrangedSubview(makeDisclosureCard(
            title: NSLocalizedString("Name", comment: "pickup group: name"),
            credentialName: credentialName,
            issuerName: issuerName,
            credentialID: credentialID,
            fieldName: NSLocalizedString("Name", comment: "pickup claim: name"),
            value: UntrustedText.value(disclosure.holderName).text))
        content.addArrangedSubview(makeDisclosureCard(
            title: NSLocalizedString("Last five digits", comment: "pickup group: phone last five"),
            credentialName: credentialName,
            issuerName: issuerName,
            credentialID: credentialID,
            fieldName: NSLocalizedString("Last 5 digits of phone number", comment: "pickup claim: phone last five"),
            value: UntrustedText.value(disclosure.phoneLastFive).text))

        let consent = makeLabel(
            text: NSLocalizedString(
                "By tapping “Create barcode”, you agree to provide your name and the last five digits of your mobile number to 7-ELEVEN for this parcel pickup check.",
                comment: "pickup consent"),
            style: .body)
        consent.textColor = .secondaryLabel
        content.addArrangedSubview(consent)

        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.title = NSLocalizedString("Create barcode", comment: "pickup create barcode button")
        buttonConfig.cornerStyle = .capsule
        buttonConfig.image = UIImage(systemName: "qrcode")
        buttonConfig.imagePadding = 8
        generateButton.configuration = buttonConfig
        generateButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        generateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        generateButton.addTarget(self, action: #selector(authoriseAndGenerate), for: .touchUpInside)
        content.addArrangedSubview(generateButton)

        let cancel = UIButton(type: .system)
        var cancelConfig = UIButton.Configuration.bordered()
        cancelConfig.title = NSLocalizedString("Cancel", comment: "")
        cancelConfig.cornerStyle = .capsule
        cancel.configuration = cancelConfig
        cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        cancel.addTarget(self, action: #selector(cancelFlow), for: .touchUpInside)
        content.addArrangedSubview(cancel)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }

    @objc private func authoriseAndGenerate() {
        generateButton.isEnabled = false
        let authentication = LAContext()
        authentication.localizedFallbackTitle = NSLocalizedString("Use phone passcode", comment: "Face ID fallback")
        authenticationContext = authentication
        var error: NSError?
        guard authentication.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            generateButton.isEnabled = true
            showError(NSLocalizedString("Set a passcode on this phone before presenting the credential.",
                                        comment: "pickup authentication unavailable"))
            return
        }
        authentication.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: NSLocalizedString(
                "Approve sharing your name and phone-number last five digits for 7-ELEVEN pickup",
                comment: "pickup Face ID reason")) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authenticationContext = nil
                guard success else {
                    self.generateButton.isEnabled = true
                    return
                }
                self.generate()
            }
        }
    }

    private func generate() {
        generateButton.configuration?.showsActivityIndicator = true
        Task { @MainActor in
            do {
                let barcodeSession = try await client.presentAndGenerate(context)
                let controller = ConvenienceStorePickupQRCodeViewController(
                    client: client, barcodeSession: barcodeSession)
                navigationController?.pushViewController(controller, animated: true)
            } catch {
                showError(UserFacingError.pickupMessage(for: error))
            }
            generateButton.configuration?.showsActivityIndicator = false
            generateButton.isEnabled = true
        }
    }

    @objc private func cancelFlow() {
        navigationController?.popViewController(animated: true)
    }

    private func makeDisclosureCard(title: String,
                                    credentialName: String,
                                    issuerName: String,
                                    credentialID: String,
                                    fieldName: String,
                                    value: String) -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.separator.cgColor

        card.addArrangedSubview(makeLabel(text: title, style: .title3))
        card.addArrangedSubview(makeLabel(text: credentialName, style: .headline))
        let issuer = makeLabel(text: issuerName, style: .subheadline)
        issuer.textColor = .secondaryLabel
        card.addArrangedSubview(issuer)
        card.addArrangedSubview(makeValueRow(label: NSLocalizedString("Credential ID", comment: "pickup credential identifier"),
                                             value: credentialID,
                                             selected: false))
        card.addArrangedSubview(makeValueRow(label: fieldName, value: value, selected: true))
        return card
    }

    private func makeTrustEvidenceCard(_ evidence: ConvenienceStorePickupTrustEvidence) -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 6
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        card.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.10)
        card.layer.cornerRadius = 14

        let heading = UIStackView()
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 8
        let icon = UIImageView(image: UIImage(systemName: "checkmark.shield.fill"))
        icon.tintColor = .systemGreen
        icon.setContentHuggingPriority(.required, for: .horizontal)
        heading.addArrangedSubview(icon)
        heading.addArrangedSubview(makeLabel(
            text: NSLocalizedString("Service trust verified", comment: "pickup trust evidence heading"),
            style: .headline))
        card.addArrangedSubview(heading)

        let organisation = UntrustedText.value(evidence.organisationName).text
        let block = UntrustedText.value(evidence.blockNumber).text
        let transaction = UntrustedText.value(evidence.transactionHash).text
        card.addArrangedSubview(makeLabel(
            text: String(format: NSLocalizedString("Trust-list API: %@", comment: "pickup trust API evidence"),
                         organisation),
            style: .subheadline))
        card.addArrangedSubview(makeLabel(
            text: String(format: NSLocalizedString("Arbitrum block: %@", comment: "pickup trust chain block"),
                         block),
            style: .subheadline))
        let transactionLabel = makeLabel(
            text: String(format: NSLocalizedString("Transaction: %@", comment: "pickup trust transaction"),
                         transaction),
            style: .caption1)
        transactionLabel.textColor = .secondaryLabel
        card.addArrangedSubview(transactionLabel)
        return card
    }

    private func makeValueRow(label: String, value: String, selected: Bool) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: selected ? "checkmark.square.fill" : "checkmark.square"))
        icon.tintColor = selected ? .systemIndigo : .tertiaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.accessibilityLabel = selected
            ? NSLocalizedString("Selected", comment: "pickup field selected")
            : NSLocalizedString("Required by the credential protocol", comment: "pickup credential id required")

        let name = makeLabel(text: label, style: .body)
        name.font = .preferredFont(forTextStyle: .headline)
        let fieldValue = makeLabel(text: value, style: .body)
        fieldValue.textColor = .secondaryLabel
        fieldValue.textAlignment = .right
        fieldValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, name, fieldValue])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        return row
    }

    private func makeLabel(text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: context.scenario.name,
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    private static func shortIssuerName(_ name: String) -> String {
        String(name.split(separator: "（", maxSplits: 1).first ?? Substring(name))
    }
}

/// Displays only the verifier-returned PNG and the server-provided lifetime.
/// Regeneration asks the same verifier for new encrypted bytes; this class never
/// turns the disclosed values into a local QR code.
final class ConvenienceStorePickupQRCodeViewController: UIViewController {

    private let client: ConvenienceStorePickupClient
    private var barcodeSession: ConvenienceStorePickupBarcodeSession
    private let imageView = UIImageView()
    private let countdownLabel = UILabel()
    private let regenerateButton = UIButton(type: .system)
    private var timer: Timer?
    private let wakeLock = AppScreenWakeLock.shared
    private var holdsWakeLock = false

    init(client: ConvenienceStorePickupClient,
         barcodeSession: ConvenienceStorePickupBarcodeSession) {
        self.client = client
        self.barcodeSession = barcodeSession
        super.init(nibName: nil, bundle: nil)
        title = UntrustedText.value(barcodeSession.context.scenario.name).text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "qrcode.viewfinder"))
        icon.tintColor = .systemIndigo
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 58, weight: .regular)
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let heading = label(NSLocalizedString("Show this credential barcode to the scanner", comment: "pickup QR heading"),
                            style: .title2, alignment: .center)
        let service = label(barcodeSession.context.scenario.name, style: .headline, alignment: .center)
        let hint = label(NSLocalizedString("Tap the QR code to enlarge it", comment: "pickup QR enlarge hint"),
                         style: .subheadline, alignment: .center)
        hint.textColor = .secondaryLabel

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityLabel = NSLocalizedString("7-ELEVEN pickup barcode", comment: "pickup QR accessibility")
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(enlarge)))
        imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor).isActive = true

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                                                         weight: .semibold)
        countdownLabel.adjustsFontForContentSizeCategory = true
        countdownLabel.textAlignment = .center
        countdownLabel.numberOfLines = 0

        let card = UIStackView(arrangedSubviews: [service, hint, imageView, countdownLabel])
        card.axis = .vertical
        card.spacing = 12
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 18

        let done = UIButton(type: .system)
        var doneConfig = UIButton.Configuration.filled()
        doneConfig.title = NSLocalizedString("Done scanning", comment: "pickup QR done")
        doneConfig.cornerStyle = .capsule
        done.configuration = doneConfig
        done.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        done.addTarget(self, action: #selector(doneScanning), for: .touchUpInside)

        var regenerateConfig = UIButton.Configuration.bordered()
        regenerateConfig.title = NSLocalizedString("Create a new barcode", comment: "pickup QR regenerate")
        regenerateConfig.cornerStyle = .capsule
        regenerateButton.configuration = regenerateConfig
        regenerateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        regenerateButton.addTarget(self, action: #selector(regenerate), for: .touchUpInside)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let stack = UIStackView(arrangedSubviews: [icon, heading, card, done, regenerateButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(22, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        show(barcodeSession)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !holdsWakeLock {
            wakeLock.hold()
            holdsWakeLock = true
        }
        startTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
        if holdsWakeLock {
            wakeLock.release()
            holdsWakeLock = false
        }
    }

    private func show(_ session: ConvenienceStorePickupBarcodeSession) {
        barcodeSession = session
        imageView.image = UIImage(data: session.barcode.imageData)
        imageView.alpha = 1
        updateCountdown()
        startTimer()
    }

    private func startTimer() {
        guard viewIfLoaded?.window != nil else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
    }

    private func updateCountdown() {
        let expiry = barcodeSession.barcode.generatedAt.addingTimeInterval(barcodeSession.barcode.lifetime)
        let remaining = max(0, Int(ceil(expiry.timeIntervalSinceNow)))
        if remaining == 0 {
            countdownLabel.text = NSLocalizedString("This QR code has expired", comment: "pickup QR expired")
            countdownLabel.textColor = .systemRed
            imageView.alpha = 0.25
            timer?.invalidate()
            timer = nil
            return
        }
        countdownLabel.textColor = .secondaryLabel
        countdownLabel.text = String(format: NSLocalizedString("QR code expires in %02d:%02d", comment: "pickup QR countdown"),
                                     remaining / 60, remaining % 60)
    }

    @objc private func regenerate() {
        regenerateButton.isEnabled = false
        regenerateButton.configuration?.showsActivityIndicator = true
        Task { @MainActor in
            do {
                show(try await client.regenerate(barcodeSession))
            } catch {
                let alert = UIAlertController(title: barcodeSession.context.scenario.name,
                                              message: UserFacingError.pickupMessage(for: error),
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                present(alert, animated: true)
            }
            regenerateButton.configuration?.showsActivityIndicator = false
            regenerateButton.isEnabled = true
        }
    }

    @objc private func doneScanning() {
        navigationController?.popToRootViewController(animated: true)
    }

    @objc private func enlarge() {
        guard let image = imageView.image else { return }
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.title = barcodeSession.context.scenario.name
        let enlarged = UIImageView(image: image)
        enlarged.contentMode = .scaleAspectFit
        enlarged.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(enlarged)
        NSLayoutConstraint.activate([
            enlarged.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            enlarged.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            enlarged.centerYAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.centerYAnchor),
            enlarged.heightAnchor.constraint(equalTo: enlarged.widthAnchor),
        ])
        navigationController?.pushViewController(controller, animated: true)
    }

    private func label(_ text: String, style: UIFont.TextStyle, alignment: NSTextAlignment) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = alignment
        return label
    }
}
