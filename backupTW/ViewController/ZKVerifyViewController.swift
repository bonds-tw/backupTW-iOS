//
//  ZKVerifyViewController.swift
//  backupTW
//

import UIKit
import UniformTypeIdentifiers

/// The verifier's side of a zero-knowledge proof.
///
/// # Two ways in, and why neither is a camera
///
/// `VerifierViewController` next door shows a QR code and reads the holder's
/// answer through the camera, because a credential presentation is about 8 KB.
/// A proof is not. A package proved on a real card measured **398,181 bytes**
/// (2026-08-11), which at `QRTransport`'s 364 bytes per frame is **824 frames —
/// about 453 seconds of carousel**, assuming the camera catches every one of
/// them first time. It never gets that far: `QRTransport.frames(for:)` refuses
/// any payload over 64 KB, so the proof is not sharded slowly, it is rejected.
///
/// The 「約 100 張」 in the roadmap, and in this file's own history, came from
/// dividing 294 KB by QR version 40's 2,953-byte ceiling. Both numbers were
/// wrong: the package is larger than 294 KB and this app pins symbols at 89
/// modules and error-correction Q, which leaves 364.
///
/// So a proof arrives one of two ways. As a **file** — AirDrop, Files, a share
/// sheet — which is what this screen did first and still does. Or over
/// **Bluetooth**, which is what `LinkTransport` was built for and what this
/// screen now offers: the same 398 KB is 597 frames at the 512-byte MTU a phone
/// negotiates, and **21.7 seconds** measured end to end on a real radio
/// (2026-08-13, Mac→iPhone 14).
///
/// That number is a correction. It was written here as 8.6 seconds, extrapolated
/// from the 35 kB/s a *twelve-frame* transfer managed — and twelve frames all
/// fit in CoreBluetooth's queue at once, so that figure was a warm-up rate, not
/// a throughput. At 597 frames `updateValue` starts returning false and the
/// sender waits on `peripheralManagerIsReady`, which is paced by the connection
/// interval; the steady state is **13.8 kB/s**, two and a half times slower.
/// Measuring the small case and multiplying is exactly the mistake that produced
/// the roadmap's 「約 100 張 QR」, one layer down.
///
/// 22 seconds is still the difference between a path that exists and one that
/// does not: the same proof over QR is 824 frames and about 453 seconds, and
/// `QRTransport` refuses it outright.
///
/// # The code on this screen is an address, not a challenge
///
/// It looks like the QR next door and it is not the same thing.
/// `PresentationRequest` carries a one-time number the holder's signature has to
/// cover; `ZKLinkEngagement` carries a Bluetooth service identifier and nothing
/// else.
///
/// **Not** because a ZK proof cannot answer a challenge — an earlier version of
/// this comment said that and it was wrong. `ZKProver` takes one, it enters the
/// circuit as a public input, and `go-zkid-verifier` reads it back out. The
/// reason is narrower: **this app proves before it knows who is asking.**
/// Producing a proof needs the card, a round trip to 內政部 and minutes of CPU,
/// so the package already exists when this code is scanned and its challenge was
/// minted by the holder's own device — which is what
/// `ProofCaveat.challengeNotBoundToVerifier` is for. See `ZKLinkEngagement` for
/// the full correction.
///
/// The consequence for the checker is the same either way, and the screen says
/// it in words next to the code rather than leaving a reader to infer from the
/// resemblance that this path has a replay defence it does not have.
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

    private let codeImageView = UIImageView()
    private let codeCaptionLabel = UILabel()
    private let linkLabel = UILabel()

    /// Scans for the holder's phone under the identifier this screen's code
    /// names. Held for the life of the screen; `CBCentralManager` does not
    /// retain its delegate, so releasing this is switching the radio off.
    private var link: BluetoothLinkCentral?

    /// What is on screen right now, kept so the code and the radio cannot drift
    /// apart — a displayed identifier nobody is scanning for is a code that
    /// silently does nothing.
    private var engagement: ZKLinkEngagement?

    /// Holds the caveat group. Empty and hidden until there is a verdict, so
    /// the waiting screen does not carry a heading with nothing under it.
    private let caveatContainer = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Check a proof", comment: "")
        view.backgroundColor = .systemGroupedBackground
        configureLayout()
        show(status: NSLocalizedString("No proof loaded yet", comment: ""),
             detail: NSLocalizedString(
                "A zero-knowledge proof is about 400 KB — far too large for a QR code, so it arrives over Bluetooth or as a file.",
                comment: ""),
             verdict: nil)
    }

    /// A fresh identifier every time the screen appears, including on the way
    /// back from a result. Nothing here is a secret, so this is not a security
    /// measure; it is what stops one counter from being recognisable across
    /// visits by the identifier it broadcasts.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        beginEngagement()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            stopLink()
        }
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

        codeImageView.translatesAutoresizingMaskIntoConstraints = false
        codeImageView.contentMode = .scaleAspectFit
        codeImageView.backgroundColor = .white
        // Nearest-neighbour on both filters, as on the other verifier screen: a
        // QR resampled with the default linear filter has soft module edges, and
        // softness costs scan rate at exactly the distance where there is none
        // to spare.
        codeImageView.layer.magnificationFilter = .nearest
        codeImageView.layer.minificationFilter = .nearest
        codeImageView.isAccessibilityElement = true
        codeImageView.accessibilityLabel = NSLocalizedString("Bluetooth pairing code", comment: "")
        codeImageView.accessibilityIdentifier = "zkverify.code"

        let codeContainer = UIView()
        codeContainer.translatesAutoresizingMaskIntoConstraints = false
        codeContainer.addSubview(codeImageView)
        NSLayoutConstraint.activate([
            codeImageView.topAnchor.constraint(equalTo: codeContainer.topAnchor),
            codeImageView.bottomAnchor.constraint(equalTo: codeContainer.bottomAnchor),
            codeImageView.centerXAnchor.constraint(equalTo: codeContainer.centerXAnchor),
            codeImageView.widthAnchor.constraint(equalTo: codeImageView.heightAnchor),
            codeImageView.heightAnchor.constraint(equalToConstant: 220),
            codeImageView.widthAnchor.constraint(lessThanOrEqualTo: codeContainer.widthAnchor),
        ])

        // The sentence that keeps this screen honest. Body weight, not a
        // footnote: 「this code is not a challenge」 is the one thing a reader
        // who knows the other screen will get wrong, and a qualification set in
        // grey 11pt under a QR is a qualification nobody reads.
        codeCaptionLabel.numberOfLines = 0
        codeCaptionLabel.textAlignment = .center
        codeCaptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        codeCaptionLabel.adjustsFontForContentSizeCategory = true
        codeCaptionLabel.textColor = .secondaryLabel
        codeCaptionLabel.accessibilityIdentifier = "zkverify.codeCaption"

        linkLabel.numberOfLines = 0
        linkLabel.textAlignment = .center
        linkLabel.font = .preferredFont(forTextStyle: .footnote)
        linkLabel.adjustsFontForContentSizeCategory = true
        linkLabel.textColor = .secondaryLabel
        linkLabel.accessibilityIdentifier = "zkverify.link"

        caveatContainer.axis = .vertical
        caveatContainer.spacing = 12
        caveatContainer.isHidden = true
        caveatContainer.accessibilityIdentifier = "zkverify.caveats"

        view.addSubview(scroll)
        scroll.addSubview(stack)
        [codeContainer, codeCaptionLabel, linkLabel,
         chooseButton, spinner, statusLabel, detailLabel, caveatContainer].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(8, after: codeContainer)

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

    /// Draws an outcome.
    ///
    /// `caveats` is separate from `detail` on purpose — see
    /// `renderCaveats(_:)`. Passing them joined into `detail` is exactly what
    /// this screen used to do.
    /// `show` under a name a test may call.
    ///
    /// Reaching a verdict for real needs a proof file, the verifying keys and
    /// several seconds of CPU, none of which belong in a layout check. The
    /// alternative was `@testable` access to a private method, which reads as
    /// though the test is exercising the flow when it is exercising the layout.
    func showForReview(status: String, detail: String, caveats: [String], verdict: Bool?) {
        show(status: status, detail: detail, caveats: caveats, verdict: verdict)
    }

    private func show(status: String, detail: String, caveats: [String] = [], verdict: Bool?) {
        statusLabel.text = status
        detailLabel.text = detail
        switch verdict {
        case .some(true): statusLabel.textColor = .systemGreen
        case .some(false): statusLabel.textColor = .systemOrange
        case .none: statusLabel.textColor = .label
        }
        renderCaveats(caveats)
        if verdict != nil { liftTheVerdictAboveTheFold() }
    }

    /// One label per caveat, through the same helper the credential path uses.
    ///
    /// These six sentences used to be `lines.joined(separator: "\n")` inside a
    /// single `UILabel` — 363 characters of it. The credential path has never
    /// done that; `PresentationUI.caveatGroup` gives each one its own label, and
    /// the reason is VoiceOver: one label is **one swipe**, so a checker
    /// navigating by element skipped all six at once and had no way to hear any
    /// one of them again. `signatureMaterialIsReplayable` and
    /// `nullifierSharedAcrossVerifiers` are among the six, and they are the two
    /// least suited to being skimmed past in a block.
    private func renderCaveats(_ messages: [String]) {
        caveatContainer.arrangedSubviews.forEach {
            caveatContainer.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !messages.isEmpty else {
            caveatContainer.isHidden = true
            return
        }
        caveatContainer.isHidden = false
        caveatContainer.addArrangedSubview(PresentationUI.caveatGroup(
            subtitle: NSLocalizedString("What this does not establish:", comment: ""),
            messages: messages))
    }

    /// Once there is a verdict, the verdict goes first.
    ///
    /// The stack's order is fixed for the waiting state, and that order is
    /// right while somebody is being asked to show the pairing code. It is
    /// wrong the moment there is an answer: measured at AX5, `statusLabel`'s
    /// top sat at y=1165 — 322pt below the visible area — and even at the
    /// default text size several caveats fell below the fold, pushed there by
    /// a QR code that `stopLink()` has already made useless.
    ///
    /// This is the same failure `VerifiedResultSection.order` exists to prevent
    /// on the credential screen. The difference is only in who does the
    /// pushing: there it is a stranger's bytes, here it is our own layout.
    ///
    /// Reordering rather than hiding the code: hiding it would make the screen
    /// unable to accept a second proof without a round trip, and a checker at a
    /// counter checks more than one person.
    private func liftTheVerdictAboveTheFold() {
        for (index, view) in [statusLabel, detailLabel, caveatContainer].enumerated()
        where stack.arrangedSubviews.contains(view) {
            stack.insertArrangedSubview(view, at: index)
        }
    }

    // MARK: - The pairing code and the radio

    /// Mints an identifier, draws it, and starts listening for it.
    ///
    /// The three go together on purpose. A code drawn without a scanner running
    /// is a code that does nothing when scanned; a scanner running for an
    /// identifier that is no longer displayed is a phone looking for a device
    /// nobody is pretending to be. `engagement` exists so the two cannot drift.
    private func beginEngagement() {
        let engagement = ZKLinkEngagement(serviceID: UUID(), purpose: Self.purpose)
        self.engagement = engagement

        do {
            let text = try engagement.encodedForTransport()
            #if DEBUG
            EngagementExport.write(text, kind: .zeroKnowledge)
            #endif
            let code = try QRTransport.qrCode(for: text, fittingPixelWidth: 1024)
            codeImageView.image = UIImage(cgImage: code.image)
            codeImageView.isHidden = false
            codeCaptionLabel.text = NSLocalizedString(
                "Scanning this only tells the other phone where to send the proof. It is not a one-time number — the proof was made before you asked for it, so nothing here stops the same proof being sent again later.",
                comment: "Caption under the ZK Bluetooth pairing code")
            codeCaptionLabel.isHidden = false
        } catch {
            // The code is an address, so failing to draw it costs the Bluetooth
            // path and nothing else. The file picker below is untouched, and
            // saying so beats a blank square.
            codeImageView.image = nil
            codeImageView.isHidden = true
            codeCaptionLabel.text = NSLocalizedString(
                "This device could not draw a Bluetooth pairing code. You can still load a proof from a file.",
                comment: "")
            codeCaptionLabel.isHidden = false
            stopLink()
            linkLabel.text = nil
            return
        }

        startLink(for: engagement)
    }

    private func startLink(for engagement: ZKLinkEngagement) {
        stopLink()
        linkLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        let link = BluetoothLinkCentral(serviceID: engagement.serviceID) { [weak self] state in
            self?.receiveOverLink(state)
        }
        self.link = link
        link.start()
    }

    private func stopLink() {
        link?.stop()
        link = nil
    }

    /// One line about the radio, never an error code.
    ///
    /// Bluetooth being unavailable costs this screen the fast path and nothing
    /// else — the file picker is the route that has always worked and it stays
    /// enabled. The one thing that must not happen is a checker unable to check
    /// because a radio they were never told about is switched off.
    private func receiveOverLink(_ state: BluetoothLinkState) {
        switch state {
        case .unavailable(let reason):
            linkLabel.text = reason
        case .starting:
            linkLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        case .waiting:
            linkLabel.text = NSLocalizedString("Listening over Bluetooth — ask them to scan the code above.", comment: "")
        case .transferring(let fraction):
            // Worth a percentage here in a way it is not on the credential
            // screen: 400 KB takes several seconds, and a progress line is the
            // difference between waiting and wondering whether it broke.
            linkLabel.text = String(format: NSLocalizedString("Receiving the proof over Bluetooth… %d%%", comment: ""),
                                    Int((fraction * 100).rounded()))
        case .failed(let reason):
            linkLabel.text = reason
        case .finished(let payload):
            // Down at once: the proof is here, and a second transfer arriving
            // mid-verification would stack a second result on the first.
            stopLink()
            linkLabel.text = String(format: NSLocalizedString("Received %@ over Bluetooth.", comment: ""),
                                    ZKStagePresentation.byteString(Int64(payload.count)))
            do {
                verify(package: try ZKProofPackage.decoded(from: payload))
            } catch {
                // Reassembled and digest-matched, and still not a package. Not a
                // failed check — we never got far enough to judge anything —
                // so this reports as unreadable rather than as a refusal.
                show(status: NSLocalizedString("What arrived was not a proof this app can read.", comment: ""),
                     detail: String(describing: error),
                     verdict: nil)
            }
        }
    }

    /// What the checker says the check is for. Shown to the holder before they
    /// send, and compared to nothing afterwards — see `ZKLinkEngagement.purpose`.
    private static var purpose: String {
        NSLocalizedString("Identity check", comment: "Default reason a verifier gives for a check")
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

        do {
            verify(package: try ZKProofPackage.decoded(from: try Data(contentsOf: url)))
        } catch {
            show(status: NSLocalizedString("This proof file could not be read.", comment: ""),
                 detail: String(describing: error),
                 verdict: nil)
        }
    }

    /// The single place a decoded package is checked, whichever way it arrived.
    ///
    /// A proof received over Bluetooth is checked by exactly this code, with
    /// exactly these caveats. The transport is a courier; nothing about how the
    /// bytes travelled may make a verdict kinder.
    private func verify(package: ZKProofPackage) {
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
                // Not 「同一人」, which is what this row used to say.
                //
                // `outcome.linked` means the two proofs are tied to the same
                // public inputs. It says nothing about whether the person in
                // front of you is who they claim to be — but 「同一人：通過」
                // in the most technical position on the screen reads exactly
                // like an identity verdict, and it is the row a checker is
                // least equipped to second-guess. Named for the mechanism, so
                // that all three rows read as "this proof's three self-checks"
                // rather than "this app's three conclusions about this person".
                lines.append(stated(NSLocalizedString("The two proofs are tied together", comment: ""),
                                    outcome.linked))
            }
            lines.append(String(format: NSLocalizedString("Took %.1f seconds · %@", comment: ""),
                                verdict.seconds,
                                ZKStagePresentation.byteString(Int64(verdict.byteCount))))
            // Always shown, never behind a disclosure arrow. A proof this app
            // can produce establishes materially less than an unqualified tick
            // implies, and the caveats are the difference.
            //
            // They travel as a list, not appended to `lines`: the heading and
            // the bullets are drawn by `PresentationUI.caveatGroup`, one label
            // each, so that each one is its own VoiceOver stop.
            show(status: verdict.accepted
                    ? NSLocalizedString("Checked on this phone, and it passed", comment: "")
                    : NSLocalizedString("This phone checked the proof and refused it", comment: ""),
                 detail: lines.joined(separator: "\n"),
                 caveats: verdict.caveats.map(\.localizedDescription),
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
