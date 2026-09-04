//
//  AgePredicateProofFlowViewController.swift
//  backupTW
//
//  The verifier-first age-predicate experiment. The only QR in this flow is
//  the small request; the proof itself travels over the one-time BLE service.
//

import UIKit

@MainActor
enum AgePredicateProofHolderFlow {

    static func begin(on navigationController: UINavigationController?) {
        final class Latch { var fired = false }
        let latch = Latch()
        let scanner = QRScanningViewController(
            title: NSLocalizedString("Scan a field-proof request", comment: "age proof"),
            prompt: NSLocalizedString("Point the camera at the checker's one request code.", comment: "age proof"),
            allowsPhotoImport: true
        ) { [weak navigationController] text in
            guard !latch.fired,
                  let request = try? AgePredicateProofRequest.decode(from: text) else {
                return .keepScanning(status: nil)
            }
            latch.fired = true
            Task { @MainActor in showConsent(for: request, on: navigationController) }
            return .stop
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

    private static func showConsent(for request: AgePredicateProofRequest,
                                    on navigationController: UINavigationController?) {
        guard let navigationController else { return }
        let source = request.credentialSource == .twdiw
            ? NSLocalizedString("government wallet card", comment: "age proof")
            : NSLocalizedString("self-issued MyData document", comment: "age proof")
        var message = String(
            format: NSLocalizedString(
                "The checker asks whether you are at least %d.\n\nPurpose: %@\nSource: %@\n\nYour birth date and card never leave this phone.",
                comment: "age proof consent"),
            request.minimumAge, request.purpose, source)
        if let host = request.responseURL?.host {
            // The one difference from the two-device flow, said before consent:
            // the finished proof (and nothing else) goes to a website.
            message += "\n\n" + String(
                format: NSLocalizedString("The finished proof will be sent to %@.", comment: "age proof consent"),
                host)
        }
        let alert = UIAlertController(
            title: NSLocalizedString("Create a private age proof?", comment: "age proof"),
            message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            navigationController.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Create proof", comment: "age proof"),
                                      style: .default) { _ in
            var stack = navigationController.viewControllers
            if stack.last is QRScanningViewController { stack.removeLast() }
            stack.append(AgePredicateProofSendViewController(request: request))
            navigationController.setViewControllers(stack, animated: true)
        })
        navigationController.topViewController?.present(alert, animated: true)
    }
}

@MainActor
final class AgePredicateProofSendViewController: UIViewController {

    private let request: AgePredicateProofRequest
    private let engine: any AgePredicateProofEngine
    private let webClient: AgePredicateProofWebClient
    private var link: BluetoothLinkPeripheral?
    /// Set the moment a web submission starts, so a failure on the way records
    /// the transport that was attempted rather than 「local」.
    private var usedWeb = false
    private var webOutcome: AgePredicateProofWebOutcome?
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private var createStartedAt: UInt64?
    private var transportStartedAt: UInt64?
    private var createdPackage: AgePredicateProofPackage?
    private var runRecordWritten = false

    init(request: AgePredicateProofRequest,
         engine: any AgePredicateProofEngine = AgePredicateProofEngineAssembly.make(),
         webClient: AgePredicateProofWebClient = AgePredicateProofWebClient()) {
        self.request = request
        self.engine = engine
        self.webClient = webClient
        super.init(nibName: nil, bundle: nil)
        title = NSLocalizedString("Private age proof", comment: "age proof")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        createStartedAt = VerificationClock.now()
        createProof()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        link?.stop()
    }

    private func buildInterface() {
        view.backgroundColor = .systemGroupedBackground
        spinner.startAnimating()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = NSLocalizedString("Creating the proof on this phone…", comment: "age proof")
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.text = NSLocalizedString(
            "Only the yes/no statement is returned. The hidden birth date, card and proving files stay here.",
            comment: "age proof")
        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Done", comment: "")
        configuration.cornerStyle = .large
        doneButton.configuration = configuration
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, detailLabel, doneButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    private func createProof() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try CredentialStore()
                let material = try AgePredicateCredentialProvider(
                    holder: HolderPresentation(store: store)).material(for: request.credentialSource)
                let package = try await engine.prove(
                    request: request,
                    credential: material.sdJWT,
                    issuerDID: material.issuerDID,
                    issuerPublicKeyX963: material.issuerPublicKeyX963,
                    holder: material.holderKey,
                    assetProgress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.detailLabel.text = String(
                                format: NSLocalizedString("Preparing private proof files… %d%%", comment: "age proof"),
                                Int((fraction * 100).rounded()))
                        }
                    })
                try package.validate(answering: request)
                createdPackage = package
                if let responseURL = request.responseURL {
                    sendOverWeb(package, to: responseURL)
                } else {
                    send(try package.encoded())
                }
            } catch {
                showFailure(error)
            }
        }
    }

    /// The web checker's path: one HTTPS POST to the allow-listed website in the
    /// request, then its verdict — the website did the checking, this phone
    /// only reports what it said. Timings come back with the verdict so the
    /// holder's record carries the same numbers the website shows.
    private func sendOverWeb(_ package: AgePredicateProofPackage, to url: URL) {
        usedWeb = true
        transportStartedAt = VerificationClock.now()
        titleLabel.text = NSLocalizedString("Proof ready", comment: "age proof")
        detailLabel.text = String(
            format: NSLocalizedString("Sending it to the checker's website %@…", comment: "age proof"),
            url.host ?? "")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await webClient.submit(package, to: url)
                webOutcome = outcome
                spinner.stopAnimating()
                if outcome.verdict.accepted {
                    titleLabel.text = String(
                        format: NSLocalizedString("The website verified the proof: at least %d", comment: "age proof"),
                        request.minimumAge)
                    detailLabel.text = NSLocalizedString("No birth date or card data was sent.", comment: "age proof")
                        + "\n" + Self.timingSummary(package: package, outcome: outcome)
                    Bonds.Haptic.delivered()
                } else {
                    titleLabel.text = NSLocalizedString("The website did not accept the proof", comment: "age proof")
                    // The website's own words, drawn as untrusted text: it is a
                    // stranger's sentence and must not impersonate this app.
                    detailLabel.text = outcome.verdict.reason.map { UntrustedText($0, limit: 200).text }
                        ?? NSLocalizedString("The zero-knowledge proof did not verify.", comment: "age proof")
                }
                doneButton.isHidden = false
                recordRun(succeeded: outcome.verdict.accepted)
            } catch {
                showFailure(error)
            }
        }
    }

    private static func timingSummary(package: AgePredicateProofPackage,
                                      outcome: AgePredicateProofWebOutcome) -> String {
        let verify = outcome.verdict.timingMs?.verify
        return String(
            format: NSLocalizedString("Proof creation %@ + %@ ms · website verification %@ ms · round trip %@ ms",
                                      comment: "age proof web timing"),
            Self.number(package.prepareMilliseconds),
            Self.number(package.showMilliseconds),
            verify.map(Self.number) ?? "—",
            Self.number(outcome.roundTripMilliseconds))
    }

    private static func number(_ value: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func send(_ payload: Data) {
        transportStartedAt = VerificationClock.now()
        spinner.stopAnimating()
        titleLabel.text = NSLocalizedString("Proof ready", comment: "age proof")
        detailLabel.text = NSLocalizedString(
            "Sending it directly to the checker over Bluetooth. There are no response QR codes to scan.",
            comment: "age proof")
        let link = BluetoothLinkPeripheral(payload: payload,
                                           serviceID: request.serviceID,
                                           vocabulary: .zeroKnowledgeProof) { [weak self] state in
            self?.render(state)
        }
        self.link = link
        link.start()
    }

    private func render(_ state: BluetoothLinkState) {
        switch state {
        case .starting:
            detailLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        case .waiting:
            detailLabel.text = NSLocalizedString("Waiting for the checker to receive the proof…", comment: "age proof")
        case .transferring(let fraction):
            detailLabel.text = String(format: NSLocalizedString("Sending proof… %d%%", comment: "age proof"),
                                      Int((fraction * 100).rounded()))
        case .finished:
            link?.stop()
            link = nil
            titleLabel.text = NSLocalizedString("The checker received the proof", comment: "age proof")
            detailLabel.text = NSLocalizedString("No birth date or card data was sent.", comment: "age proof")
            doneButton.isHidden = false
            recordRun(succeeded: true)
        case .unavailable(let reason), .failed(let reason):
            showFailure(NSError(domain: "AgePredicateBluetooth", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }

    private func showFailure(_ error: Error) {
        spinner.stopAnimating()
        titleLabel.text = NSLocalizedString("The proof was not sent", comment: "age proof")
        detailLabel.text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        doneButton.isHidden = false
        recordRun(succeeded: false)
    }

    private func recordRun(succeeded: Bool) {
        guard !runRecordWritten else { return }
        runRecordWritten = true
        let completed = VerificationClock.now()
        let started = createStartedAt ?? completed
        let transportStarted = transportStartedAt
        let package = createdPackage
        let transport: VerificationRunRecord.Transport
        if usedWeb {
            transport = .https
        } else {
            transport = transportStarted == nil ? .local : .bluetooth
        }
        let record = VerificationRunRecord(
            flow: .privateAgeProof,
            role: .holder,
            credentialKind: request.credentialSource == .twdiw
                ? .governmentWallet : .selfIssued,
            transport: transport,
            succeeded: succeeded,
            preparationMilliseconds: package.map {
                $0.prepareMilliseconds + $0.showMilliseconds
            },
            transportMilliseconds: webOutcome?.roundTripMilliseconds ?? transportStarted.map {
                VerificationClock.milliseconds(from: $0, to: completed)
            },
            // The website's own verification figure, carried back with the
            // verdict; the two-device flow measures this on the iPad instead.
            verificationMilliseconds: webOutcome?.verdict.timingMs?.verify,
            endToEndMilliseconds: VerificationClock.milliseconds(
                from: started, to: completed),
            proofPrepareMilliseconds: package?.prepareMilliseconds,
            proofShowMilliseconds: package?.showMilliseconds,
            correlationToken: VerificationRunRecord.correlationToken(
                for: request.serviceID.uuidString),
            qrFallbackWasVisible: false)
        try? VerificationRunStore.shared.append(record)
    }

    @objc private func done() { navigationController?.popViewController(animated: true) }
}

@MainActor
final class AgePredicateProofVerifierViewController: UIViewController {

    private let engine: any AgePredicateProofEngine
    private let trustLookup: OfflineIssuerTrustLookup
    private var request: AgePredicateProofRequest?
    private var link: BluetoothLinkCentral?
    private var preparationTask: Task<Void, Never>?
    private var requestShownAt: UInt64?
    private var payloadReceivedAt: UInt64?

    private let sourceControl = UISegmentedControl(items: [
        NSLocalizedString("Government card", comment: "age proof"),
        NSLocalizedString("MyData self-asserted", comment: "age proof"),
    ])
    private let codeImageView = UIImageView()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let newCodeButton = UIButton(type: .system)

    init(engine: any AgePredicateProofEngine = AgePredicateProofEngineAssembly.make(),
         trustLookup: OfflineIssuerTrustLookup = .installed()) {
        self.engine = engine
        self.trustLookup = trustLookup
        super.init(nibName: nil, bundle: nil)
        title = NSLocalizedString("Check a private age proof", comment: "age proof")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        beginCheck()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        preparationTask?.cancel()
        stopLink()
    }

    private func buildInterface() {
        view.backgroundColor = .systemGroupedBackground
        sourceControl.selectedSegmentIndex = 0
        sourceControl.addTarget(self, action: #selector(sourceChanged), for: .valueChanged)
        codeImageView.contentMode = .center
        codeImageView.setContentCompressionResistancePriority(.required, for: .vertical)
        statusLabel.font = .preferredFont(forTextStyle: .title3)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        var configuration = UIButton.Configuration.bordered()
        configuration.title = NSLocalizedString("Create a new request", comment: "age proof")
        configuration.cornerStyle = .large
        newCodeButton.configuration = configuration
        newCodeButton.addTarget(self, action: #selector(beginCheck), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [sourceControl, codeImageView,
                                                   statusLabel, detailLabel, newCodeButton])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            codeImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 360),
            newCodeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    @objc private func sourceChanged() { beginCheck() }

    @objc private func beginCheck() {
        preparationTask?.cancel()
        stopLink()
        request = nil
        codeImageView.image = nil
        newCodeButton.isEnabled = false
        statusLabel.text = NSLocalizedString("Preparing offline checking files…", comment: "age proof")
        detailLabel.text = nil
        let source: PresentationCredentialSource = sourceControl.selectedSegmentIndex == 0
            ? .twdiw : .selfIssued
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.prepareVerificationAssets { [weak self] fraction in
                    Task { @MainActor in
                        self?.detailLabel.text = String(
                            format: NSLocalizedString("Preparing checking files… %d%%", comment: "age proof"),
                            Int((fraction * 100).rounded()))
                    }
                }
                try Task.checkCancellation()
                let request = try AgePredicateProofRequest(
                    purpose: NSLocalizedString("Age eligibility check", comment: "age proof"),
                    credentialSource: source)
                self.request = request
                let code = try QRTransport.qrCode(
                    for: request.encodedForTransport(), fittingPixelWidth: 900)
                codeImageView.image = UIImage(cgImage: code.image, scale: UIScreen.main.scale,
                                              orientation: .up)
                requestShownAt = VerificationClock.now()
                statusLabel.text = NSLocalizedString("Ask them to scan this one request code", comment: "age proof")
                detailLabel.text = NSLocalizedString(
                    "Offline checking files are ready. The proof returns over Bluetooth; their phone will not show a QR carousel.",
                    comment: "age proof")
                newCodeButton.isEnabled = true
                startLink(for: request)
            } catch is CancellationError {
                return
            } catch {
                request = nil
                codeImageView.image = nil
                statusLabel.text = NSLocalizedString("Checking files are not ready", comment: "age proof")
                detailLabel.text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                newCodeButton.isEnabled = true
            }
        }
    }

    private func startLink(for request: AgePredicateProofRequest) {
        let link = BluetoothLinkCentral(serviceID: request.serviceID,
                                        vocabulary: .zeroKnowledgeProof) { [weak self] state in
            self?.receive(state)
        }
        self.link = link
        link.start()
    }

    private func stopLink() {
        link?.stop()
        link = nil
    }

    private func receive(_ state: BluetoothLinkState) {
        switch state {
        case .starting:
            detailLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        case .waiting:
            detailLabel.text = NSLocalizedString("Listening for the proof…", comment: "age proof")
        case .transferring(let fraction):
            detailLabel.text = String(format: NSLocalizedString("Receiving proof… %d%%", comment: "age proof"),
                                      Int((fraction * 100).rounded()))
        case .finished(let data):
            payloadReceivedAt = VerificationClock.now()
            stopLink()
            verify(data)
        case .unavailable(let reason), .failed(let reason):
            detailLabel.text = reason
        }
    }

    private func verify(_ data: Data) {
        guard let request else { return }
        let verificationStarted = payloadReceivedAt ?? VerificationClock.now()
        statusLabel.text = NSLocalizedString("Checking the proof on this iPad…", comment: "age proof")
        detailLabel.text = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let package = try AgePredicateProofPackage.decoded(from: data)
                try package.validate(answering: request)
                let expectedKey: Data
                let evidence: String
                switch request.credentialSource {
                case .twdiw:
                    guard trustLookup.find(package.issuerDID) != nil,
                          let key = try? JWKDIDKey.p256PublicKey(fromDID: package.issuerDID) else {
                        throw AgePredicateProofError.credentialIsNotTrusted
                    }
                    expectedKey = key.x963Representation
                    evidence = NSLocalizedString(
                        "Government issuer matched the saved API + Arbitrum trust evidence.",
                        comment: "age proof")
                case .selfIssued:
                    guard let key = try? JWKDIDKey.p256PublicKey(fromDID: package.issuerDID) else {
                        throw AgePredicateProofError.proofRejected
                    }
                    expectedKey = key.x963Representation
                    evidence = NSLocalizedString(
                        "Source: self-asserted MyData derivative; this is not a government attestation.",
                        comment: "age proof")
                }
                let timing = try await engine.verify(
                    package: package, request: request,
                    expectedIssuerPublicKeyX963: expectedKey,
                    assetProgress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.detailLabel.text = String(
                                format: NSLocalizedString("Preparing checking files… %d%%", comment: "age proof"),
                                Int((fraction * 100).rounded()))
                        }
                    })
                statusLabel.text = String(format: NSLocalizedString("Verified: at least %d", comment: "age proof"),
                                          request.minimumAge)
                detailLabel.text = evidence + "\n" + String(
                    format: NSLocalizedString("Proof creation %@ + %@ ms · verification %@ ms", comment: "age proof"),
                    Self.number(timing.prepareMilliseconds),
                    Self.number(timing.showMilliseconds),
                    Self.number(timing.verifyMilliseconds))
                let completed = VerificationClock.now()
                let shown = requestShownAt ?? verificationStarted
                let record = VerificationRunRecord(
                    flow: .privateAgeProof,
                    role: .verifier,
                    credentialKind: request.credentialSource == .twdiw
                        ? .governmentWallet : .selfIssued,
                    transport: .bluetooth,
                    succeeded: true,
                    preparationMilliseconds: timing.prepareMilliseconds
                        + timing.showMilliseconds,
                    transportMilliseconds: VerificationClock.milliseconds(
                        from: shown, to: verificationStarted),
                    verificationMilliseconds: timing.verifyMilliseconds,
                    endToEndMilliseconds: VerificationClock.milliseconds(
                        from: shown, to: completed),
                    proofPrepareMilliseconds: timing.prepareMilliseconds,
                    proofShowMilliseconds: timing.showMilliseconds,
                    correlationToken: VerificationRunRecord.correlationToken(
                        for: request.serviceID.uuidString),
                    qrFallbackWasVisible: false)
                try? VerificationRunStore.shared.append(record)
            } catch {
                statusLabel.text = NSLocalizedString("Proof rejected", comment: "age proof")
                detailLabel.text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let completed = VerificationClock.now()
                let shown = requestShownAt ?? verificationStarted
                let record = VerificationRunRecord(
                    flow: .privateAgeProof,
                    role: .verifier,
                    credentialKind: request.credentialSource == .twdiw
                        ? .governmentWallet : .selfIssued,
                    transport: .bluetooth,
                    succeeded: false,
                    transportMilliseconds: VerificationClock.milliseconds(
                        from: shown, to: verificationStarted),
                    verificationMilliseconds: VerificationClock.milliseconds(
                        from: verificationStarted, to: completed),
                    endToEndMilliseconds: VerificationClock.milliseconds(
                        from: shown, to: completed),
                    correlationToken: VerificationRunRecord.correlationToken(
                        for: request.serviceID.uuidString),
                    qrFallbackWasVisible: false)
                try? VerificationRunStore.shared.append(record)
            }
        }
    }

    private static func number(_ value: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
