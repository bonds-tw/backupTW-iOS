//
//  QRScanningViewController.swift
//  backupTW
//

import AVFoundation
import UIKit

/// A camera that reads QR codes and hands the strings to whoever pushed it.
///
/// Shared by both halves of an offline check, which look symmetrical from here:
/// the holder scans one small code carrying the verifier's request, the verifier
/// scans a carousel of frames carrying the presentation. Neither knows anything
/// about the other's payload, and neither does this — it reports strings and the
/// caller decides when it has enough.
///
/// # Everything that is not a camera preview is on purpose
///
/// The screens this replaces would have been a black rectangle in three
/// situations that are all reachable on a real phone and one of which is the
/// only situation a developer ever sees. Camera permission not yet asked,
/// permission refused, and no camera at all (every simulator, and a phone whose
/// camera is disabled by an MDM profile or Screen Time) each get a sentence and,
/// where there is one, the action that resolves it. A verification counter is
/// exactly where "it just doesn't work" is most expensive.
///
/// # Nothing here is recorded
///
/// No `AVCaptureVideoDataOutput`, no photo output, no file. The session carries
/// one metadata output that reports decoded strings, and the preview layer draws
/// frames that are never retained. What the holder's screen showed does not
/// survive the check, which is the same promise `OfflineVerifier` makes about
/// the network.
final class QRScanningViewController: UIViewController {

    /// What the caller wants to happen after a scanned string.
    enum Decision: Equatable {
        /// Not finished. `status` replaces the line under the viewfinder — this
        /// is how the multi-frame case reports 「已讀取 2／3 張」 without this
        /// type knowing what a frame is. `nil` leaves it as it was.
        case keepScanning(status: String?)
        /// Enough. The session stops and no further callbacks arrive.
        ///
        /// Dismissal is deliberately *not* done here: both callers navigate
        /// somewhere specific afterwards, and a screen that pops itself while its
        /// owner is also pushing produces the interleaving that leaves a
        /// navigation stack with two of something.
        case stop
    }

    /// Called on the main queue for every QR code the camera reads, including
    /// the same one dozens of times a second while it stays in frame. Callers
    /// must be idempotent; `FrameCollector` already is.
    private let onScan: (String) -> Decision

    private let prompt: String

    private let session = AVCaptureSession()
    /// `startRunning` blocks — hundreds of milliseconds on a cold camera — so it
    /// never happens on the main queue. Configuration is serialised onto the same
    /// queue so a start cannot overlap a teardown.
    private let sessionQueue = DispatchQueue(label: "tw.bonds.backupTW.scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// Decides what the appearance callbacks do. See `QRScannerLifecycle` for why
    /// this is a separate type.
    private var lifecycle = QRScannerLifecycle()

    private let statusLabel = UILabel()
    private let promptLabel = UILabel()
    /// The bar holding both of the above. Held so it can be taken off screen
    /// whole — see `showUnavailable`.
    private let banner = UIStackView()
    /// Shown instead of the preview when there is nothing to preview.
    private let unavailableView = UIStackView()
    private let unavailableLabel = UILabel()
    private let settingsButton = UIButton(type: .system)

    init(title: String, prompt: String, onScan: @escaping (String) -> Decision) {
        self.prompt = prompt
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildInterface()
        // The camera is *not* started here. Configuration is driven from
        // `viewWillAppear`, which is the only callback that fires again after an
        // appearance the user began and then abandoned — see below.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    /// Every appearance, not just the first.
    ///
    /// A left-edge swipe that is released short of the threshold is a *cancelled*
    /// pop: UIKit has already sent `viewWillDisappear` to this instance and now
    /// sends `viewWillAppear` to it again. The session it stopped on the way out
    /// stays stopped unless something restarts it, and `AVCaptureVideoPreviewLayer`
    /// goes on drawing the frame it was holding when that happened — so the screen
    /// keeps showing a plausible, motionless picture of the counter while the
    /// scanner is dead. Nothing tells the user; they hold the phone up and wait.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply(lifecycle.willAppear())
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stopped on the way out rather than in `deinit`: a scanner left running
        // behind a pushed result screen keeps the camera indicator lit, which on
        // a phone reads as "this app is watching me" and is the one privacy
        // signal iOS gives the user directly.
        apply(lifecycle.willDisappear())
    }

    private func apply(_ effect: QRScannerLifecycle.Effect) {
        switch effect {
        case .nothing:
            break
        case .prepare:
            prepareCamera()
        case .start:
            start()
        case .stop:
            stop()
        }
    }

    /// Idempotent, and safe to call before the session was ever configured.
    private func start() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Idempotent, and safe to call before the session was ever configured.
    private func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Interface

    private func buildInterface() {
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.numberOfLines = 0
        promptLabel.textAlignment = .center
        promptLabel.text = prompt
        promptLabel.font = .preferredFont(forTextStyle: .headline)
        promptLabel.adjustsFontForContentSizeCategory = true
        promptLabel.textColor = .label

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = NSLocalizedString("Point the camera at the code.", comment: "")

        // Both labels sit on an opaque bar rather than directly on the video.
        // White-on-video is unreadable against a bright screen, which is exactly
        // what the camera is pointed at here.
        banner.addArrangedSubview(promptLabel)
        banner.addArrangedSubview(statusLabel)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.axis = .vertical
        banner.spacing = 6
        banner.isLayoutMarginsRelativeArrangement = true
        banner.layoutMargins = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        banner.backgroundColor = .secondarySystemBackground

        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        unavailableLabel.numberOfLines = 0
        unavailableLabel.textAlignment = .center
        unavailableLabel.font = .preferredFont(forTextStyle: .body)
        unavailableLabel.adjustsFontForContentSizeCategory = true
        unavailableLabel.textColor = .secondaryLabel

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setTitle(NSLocalizedString("Open Settings", comment: ""), for: .normal)
        settingsButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        settingsButton.titleLabel?.adjustsFontForContentSizeCategory = true
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        settingsButton.isHidden = true

        // Sized through the symbol configuration rather than by constraining the
        // view: an SF Symbol has an intrinsic size driven by its point size, and
        // a height constraint alone leaves it drawn tiny inside a tall box.
        let symbol = UIImageView(image: UIImage(systemName: "qrcode.viewfinder",
                                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 56,
                                                                                               weight: .regular)))
        symbol.tintColor = .tertiaryLabel
        symbol.contentMode = .scaleAspectFit
        symbol.translatesAutoresizingMaskIntoConstraints = false

        unavailableView.translatesAutoresizingMaskIntoConstraints = false
        unavailableView.axis = .vertical
        unavailableView.spacing = 16
        unavailableView.alignment = .center
        unavailableView.isHidden = true
        unavailableView.addArrangedSubview(symbol)
        unavailableView.addArrangedSubview(unavailableLabel)
        unavailableView.addArrangedSubview(settingsButton)

        view.addSubview(unavailableView)
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            unavailableView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            unavailableView.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            unavailableView.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
    }

    /// The preview layer is inserted *below* the banner so the instructions stay
    /// on top of the video, and the banner is added first for that reason.
    private func showPreview() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        unavailableView.isHidden = true
    }

    private func showUnavailable(_ message: String, offeringSettings: Bool) {
        unavailableLabel.text = message
        settingsButton.isHidden = !offeringSettings
        unavailableView.isHidden = false
        // The whole bar goes, not just the status line. Both sentences on it —
        // 「請將鏡頭對準對方的手機」 and 「請將鏡頭對準條碼」 — are instructions for a
        // camera that is running, and leaving either of them under "this device
        // has no camera" is the self-contradicting screen this project has
        // already shipped once. Caught by taking a screenshot, not by reading
        // the code: the first version cleared only `statusLabel`.
        banner.isHidden = true
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Camera

    /// Runs at most once per instance; `QRScannerLifecycle` guarantees it.
    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            finishPreparing(configureSession())
        case .notDetermined:
            // The prompt is raised here rather than at app launch so that the
            // system alert arrives with the reason visible behind it.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard granted else {
                        self.showUnavailable(Self.deniedMessage, offeringSettings: true)
                        self.finishPreparing(false)
                        return
                    }
                    self.finishPreparing(self.configureSession())
                }
            }
        case .denied:
            showUnavailable(Self.deniedMessage, offeringSettings: true)
            finishPreparing(false)
        case .restricted:
            // Kept apart from `.denied` because this user cannot resolve it in
            // Settings at all (Screen Time, or a managed device). Offering the
            // button anyway would send them to look for a switch that is not
            // there.
            showUnavailable(Self.restrictedMessage, offeringSettings: false)
            finishPreparing(false)
        @unknown default:
            showUnavailable(Self.unavailableMessage, offeringSettings: false)
            finishPreparing(false)
        }
    }

    private func finishPreparing(_ succeeded: Bool) {
        apply(lifecycle.didPrepare(succeeded: succeeded))
    }

    private static var deniedMessage: String {
        NSLocalizedString("This app does not have permission to use the camera, so it cannot read the code.",
                          comment: "")
    }

    private static var restrictedMessage: String {
        NSLocalizedString("Camera access is turned off by a restriction on this device.", comment: "")
    }

    private static var unavailableMessage: String {
        NSLocalizedString("This device has no camera available, so codes cannot be scanned here.", comment: "")
    }

    /// Attaches the camera and puts the preview on screen, without starting the
    /// session — whether it is allowed to run is a question about whether this
    /// screen is in front of the user, and that answer belongs to the lifecycle.
    ///
    /// Returns `false` when there is nothing to attach, in which case the reason
    /// is already on screen.
    private func configureSession() -> Bool {
        // `AVCaptureDevice.default(for: .video)` is nil on every simulator, which
        // is the state a developer sees every single run — so it gets a real
        // message rather than the black screen that made this app's first camera
        // screen look broken.
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showUnavailable(Self.unavailableMessage, offeringSettings: false)
            return false
        }

        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            showUnavailable(Self.unavailableMessage, offeringSettings: false)
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        // Set only after the output is attached; `metadataObjectTypes` is empty
        // until then and assigning `.qr` to it raises.
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        showPreview()
        return true
    }
}

// MARK: - Lifecycle

/// When the scanner's camera may run, as a value with no `AVCaptureSession` and
/// no `UIViewController` in it.
///
/// Split out because the defect it exists to prevent is a *sequence*, and a
/// sequence is the one thing neither a screenshot nor a run on a simulator can
/// catch: the simulator has no camera, so the affected state is never reached
/// there, and on a phone the broken screen is indistinguishable from the working
/// one — a live-looking preview that has silently stopped delivering frames.
///
/// The rules, all of which are testable here:
///
/// - the camera is configured once, and only once, however many times the screen
///   appears;
/// - an appearance that follows a departure restarts the session that departure
///   stopped;
/// - a permission grant that lands *after* the user has left must not switch the
///   camera on behind whatever screen is now in front;
/// - once the caller says `.stop`, nothing starts it again.
struct QRScannerLifecycle: Equatable {

    enum Camera: Equatable {
        /// Never asked for.
        case idle
        /// Permission dialog or configuration in flight.
        case preparing
        /// Configured; may run whenever this screen is visible.
        case ready
        /// No camera, or no permission to use it. Nothing to restart.
        case unavailable
        /// The caller has what it needed.
        case finished
    }

    enum Effect: Equatable {
        case nothing
        /// Ask for access and attach the camera.
        case prepare
        case start
        case stop
    }

    private(set) var camera: Camera = .idle
    private(set) var isVisible = false

    var isFinished: Bool { camera == .finished }

    mutating func willAppear() -> Effect {
        isVisible = true
        switch camera {
        case .idle:
            camera = .preparing
            return .prepare
        case .ready:
            return .start
        case .preparing, .unavailable, .finished:
            return .nothing
        }
    }

    mutating func willDisappear() -> Effect {
        isVisible = false
        // Unconditional, and safe against a session that was never configured:
        // this also covers leaving *while* `.preparing`, where the grant has not
        // come back yet and there is nothing else holding the camera shut.
        return .stop
    }

    /// Configuration finished. `succeeded` is `false` when the camera cannot be
    /// used at all — denied, restricted, or absent.
    mutating func didPrepare(succeeded: Bool) -> Effect {
        guard camera == .preparing else { return .nothing }
        camera = succeeded ? .ready : .unavailable
        return succeeded && isVisible ? .start : .nothing
    }

    mutating func didFinish() -> Effect {
        camera = .finished
        return .stop
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRScanningViewController: AVCaptureMetadataOutputObjectsDelegate {

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !lifecycle.isFinished else { return }

        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  // Nil for any payload that is not a string. Both formats in
                  // this app are printable text precisely so this never happens;
                  // a foreign binary QR in frame lands here and is skipped.
                  let value = readable.stringValue else { continue }

            // Deliberately not trimmed. A base45 chunk can legitimately begin or
            // end with a space (`00 24` encodes as `" 00"`), and trimming it
            // corrupts the payload in a way that only surfaces as a digest
            // mismatch three frames later.
            switch onScan(value) {
            case .keepScanning(let status):
                if let status { statusLabel.text = status }
            case .stop:
                apply(lifecycle.didFinish())
                return
            }
        }
    }
}
