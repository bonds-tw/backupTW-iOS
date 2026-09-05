//
//  VerifierViewController.swift
//  backupTW
//

import UIKit

/// The checker's side of an offline verification.
///
/// Shows a challenge for the holder to scan, reads back the frames they answer
/// with, and reports the result — all of it on this device, with the radio
/// untouched. Whitepaper §5.2's 「不打電話回家」 is not a fallback for bad signal
/// here; it is the property being bought, and `OfflineVerifier` is where it is
/// enforced and tested.
///
/// # The screen is honest about a green tick or it is worse than nothing
///
/// A checker who reads 「通過」 as 「政府說這個人是這個人」 has been misled by us,
/// and the person being checked has no way to correct the impression. So a pass
/// never appears on its own: `VerifiedPresentation.caveats` is always populated
/// — revocation unchecked, self-issued, linkable identifier — and
/// `VerifiedResultSection.order` draws that list immediately under the verdict,
/// *above* anything the other device supplied.
///
/// That ordering is load-bearing and it is a correction. This comment used to
/// claim 「there is no code path that can quietly produce a bare tick」 while the
/// caveats were drawn *below* the disclosed fields — which are a stranger's
/// bytes, so the stranger chose how many of them there were. Forty fields of two
/// hundred characters was measured to push the whole caveat block off the
/// screen: a green tick over a wall of official-looking rows, with every
/// qualification somewhere down the scroll. See `VerifiedResultSection.order`
/// for why capping the list was not enough on its own, and `UntrustedText` for
/// the other half of the same defect — the fields themselves were drawn in this
/// app's own card style, newlines, bidirectional overrides and all.
///
/// What is true now: no code path draws a verdict without the caveats, and
/// nothing attacker-controlled can get between the two. What remains untrue of
/// any screen is that a caveat was *read*.
final class VerifierViewController: UIViewController {

    /// Holds the challenge and spends it exactly once. The single-use rule is the
    /// half of replay protection `OfflineVerifier` deliberately does not own.
    ///
    /// Given a revocation lookup when — and only when — a snapshot is installed
    /// on this device. There is no fallback that fetches one: a verifier screen
    /// that reached for the network to answer 「這張卡還有效嗎」 would spend the
    /// property this whole design exists to buy, and would do it at the moment a
    /// stranger is standing in front of the person holding the phone.
    private let session = VerifierSession(
        revocation: VerifierViewController.installedRevocationLookup(),
        issuerTrust: .installed())

    /// Reassembles the holder's frames. Reset before every scan: a collector
    /// carrying the previous holder's identifier rejects everyone behind them.
    /// Mid-scan the same problem is `FrameIntake`'s to solve, because there the
    /// swap happens with the camera already open.
    private let collector = FrameCollector()

    /// Listens for the same presentation over the radio, under the service
    /// identifier this screen's current request names.
    ///
    /// A second entrance, not a second check: whatever arrives here goes into the
    /// same `session.check` the camera feeds, so the challenge is spent once
    /// whichever way the bytes travelled and a presentation cannot be worth more
    /// for having been received over Bluetooth. `bluetoothAndCameraDeliverIdentical
    /// Bytes` pins the halves that are testable without a radio.
    private var link: BluetoothLinkCentral?

    /// Monotonic instant at which the current request became visible. The
    /// request-to-payload duration includes the two humans aiming their screens;
    /// it is an operational end-to-end number, not a claim about QR or Bluetooth
    /// throughput.
    private var requestShownAtNanoseconds: UInt64?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let codeImageView = UIImageView()
    private let purposeLabel = UILabel()
    private let linkLabel = UILabel()
    private let unavailableLabel = UILabel()
    private let scanButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let credentialSourceControl = UISegmentedControl(items: [
        NSLocalizedString("Self-issued / MyData", comment: "Offline verifier credential source"),
        NSLocalizedString("Government wallet card", comment: "Offline verifier credential source"),
    ])

    private var selectedCredentialSource: PresentationCredentialSource {
        credentialSourceControl.selectedSegmentIndex == 1 ? .twdiw : .selfIssued
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Check a document", comment: "")
        view.backgroundColor = .systemGroupedBackground
        buildInterface()
        #if DEBUG
        startDebugPresentationDropPollIfRequested()
        #endif
    }

    /// A fresh challenge when there is not already a live one — which includes
    /// the way back from a result, because answering spends the challenge.
    ///
    /// The old image must not stay up once its challenge is spent: it would show
    /// a code guaranteed to be refused, and the holder would be told their
    /// presentation answered a different check.
    ///
    /// **The guard is what makes this screen's two halves agree.**
    /// `viewWillDisappear` deliberately does *not* cancel when the scanner is
    /// pushed, on the grounds that the scanner is about to collect an answer to
    /// the challenge on screen. Minting unconditionally here undid that on the
    /// way back: press the scanner's back button, deny the camera, or take any
    /// other round trip, and the live challenge was replaced by a new one. The
    /// holder's honest presentation then answered a challenge that no longer
    /// existed, and `challengeMismatch` reaches the screen as 「可能是先前出示的
    /// 複本」 — a replay accusation aimed at somebody who did nothing wrong.
    /// Refusing a valid presentation is the expensive direction of this screen's
    /// two possible mistakes, and the accusation is how the person pays for it.
    ///
    /// The single-use rule is unchanged. Leaving for good still cancels, so
    /// going away to present on this same device and coming back does mint a
    /// fresh challenge (see the note by the paste button, which relies on that).
    /// What changed is that a round trip through the camera is no longer counted
    /// as leaving.
    /// Raised while this screen's QR is on display. The checker's phone is the
    /// one being photographed here, so it carries the same obligation the
    /// holder's screen already did.
    private let brightness = ScreenBrightnessBoost(read: { UIScreen.main.brightness },
                                                   write: { UIScreen.main.brightness = $0 })

    /// Shared; see `ScreenWakeLock`.
    private let wakeLock = AppScreenWakeLock.shared

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        switch VerifierScreenLifecycle.arriving(hasLiveRequest: session.pendingRequest() != nil) {
        case .keepWaiting:
            return
        case .beginNewCheck:
            // Both statements together, not just `beginCheck`: resetting the
            // collector throws away frames, and the arrival that keeps the
            // challenge is exactly the arrival where frames may have arrived
            // over the radio while the scanner was up.
            collector.reset()
            beginCheck()
        }
        raiseTheScreen()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        switch VerifierScreenLifecycle.leaving(forGood: isMovingFromParent || isBeingDismissed) {
        case .stayLive:
            return
        case .endCheck:
            session.cancel()
            requestShownAtNanoseconds = nil
            stopLink()
            lowerTheScreen()
        }
    }

    /// Brightness and Auto-Lock, for the one screen-to-screen step.
    ///
    /// This QR is the *first* thing that happens and the only step with no
    /// Bluetooth fallback — `linkServiceID` exists nowhere except inside this
    /// image — so a code that will not scan means the exchange never starts,
    /// and neither person can see why. `PresentCredentialViewController` has
    /// raised its brightness for this reason since it was written; this screen,
    /// which is the half being *photographed*, never did.
    ///
    /// Idempotent on both sides (`ScreenBrightnessBoost` ignores a second
    /// `raise`, `ScreenWakeLock` counts), which matters because `viewWillAppear`
    /// runs again on every return from the scanner.
    private func raiseTheScreen() {
        guard !brightness.isRaised else { return }
        brightness.raise()
        wakeLock.hold()
    }

    /// Only from the `.endCheck` branch — that is the whole subtlety.
    ///
    /// Restoring in `viewWillDisappear` unconditionally would give the
    /// brightness back the instant the scanner is presented, which is the
    /// moment this screen's own code is about to be looked at again on return.
    /// Tied to `VerifierScreenLifecycle.leaving(forGood:)` so it follows the
    /// same judgement as `session.cancel()`: the screen is either really gone
    /// or it is not.
    private func lowerTheScreen() {
        guard brightness.isRaised else { return }
        brightness.restore()
        wakeLock.release()
    }

    // MARK: - Interface

    private func buildInterface() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        contentStack.addArrangedSubview(PresentationUI.title(
            NSLocalizedString("Ask the other person to scan this", comment: "")))
        contentStack.addArrangedSubview(PresentationUI.body(
            NSLocalizedString("This code carries a one-time number. Their document has to answer this exact number, so a photograph of an earlier check cannot be reused here.", comment: "")))

        credentialSourceControl.selectedSegmentIndex = 0
        credentialSourceControl.addTarget(self,
                                          action: #selector(credentialSourceChanged),
                                          for: .valueChanged)
        credentialSourceControl.accessibilityLabel = NSLocalizedString("Document source to verify", comment: "")
        contentStack.addArrangedSubview(credentialSourceControl)

        codeImageView.translatesAutoresizingMaskIntoConstraints = false
        codeImageView.contentMode = .scaleAspectFit
        codeImageView.backgroundColor = .white
        // Nearest-neighbour on both filters. A QR resampled with the default
        // linear filter has soft module edges, and softness costs scan rate at
        // exactly the distance where there is none to spare.
        codeImageView.layer.magnificationFilter = .nearest
        codeImageView.layer.minificationFilter = .nearest
        codeImageView.isAccessibilityElement = true
        codeImageView.accessibilityLabel = NSLocalizedString("Verification request code", comment: "")

        let codeContainer = UIView()
        codeContainer.translatesAutoresizingMaskIntoConstraints = false
        codeContainer.addSubview(codeImageView)
        NSLayoutConstraint.activate([
            codeImageView.topAnchor.constraint(equalTo: codeContainer.topAnchor),
            codeImageView.bottomAnchor.constraint(equalTo: codeContainer.bottomAnchor),
            codeImageView.centerXAnchor.constraint(equalTo: codeContainer.centerXAnchor),
            codeImageView.widthAnchor.constraint(equalTo: codeImageView.heightAnchor),
            codeImageView.heightAnchor.constraint(equalToConstant: 260),
            codeImageView.widthAnchor.constraint(lessThanOrEqualTo: codeContainer.widthAnchor),
        ])
        contentStack.addArrangedSubview(codeContainer)

        purposeLabel.numberOfLines = 0
        purposeLabel.textAlignment = .center
        // Footnote weight: both ends are the same build, so the purpose is
        // always the same sentence — worth stating (the holder sees it and the
        // two must match), not worth a slot in the reading order.
        purposeLabel.font = .preferredFont(forTextStyle: .footnote)
        purposeLabel.adjustsFontForContentSizeCategory = true
        purposeLabel.textColor = .tertiaryLabel
        contentStack.addArrangedSubview(purposeLabel)
        contentStack.setCustomSpacing(8, after: codeContainer)

        // Sits under the code because that is the order the checker acts in:
        // hold the code up, and if the radio picks the document up first, this
        // line is what tells them so before they reach for the camera.
        linkLabel.numberOfLines = 0
        linkLabel.textAlignment = .center
        linkLabel.font = .preferredFont(forTextStyle: .footnote)
        linkLabel.adjustsFontForContentSizeCategory = true
        linkLabel.textColor = .secondaryLabel
        contentStack.addArrangedSubview(linkLabel)

        unavailableLabel.numberOfLines = 0
        unavailableLabel.textAlignment = .center
        unavailableLabel.font = .preferredFont(forTextStyle: .body)
        unavailableLabel.adjustsFontForContentSizeCategory = true
        unavailableLabel.textColor = .systemRed
        unavailableLabel.isHidden = true
        contentStack.addArrangedSubview(unavailableLabel)

        var retryConfiguration = UIButton.Configuration.bordered()
        retryConfiguration.title = NSLocalizedString("Try again", comment: "Retry minting a verification request")
        retryButton.configuration = retryConfiguration
        retryButton.addTarget(self, action: #selector(retryBeginCheck), for: .touchUpInside)
        retryButton.isHidden = true
        contentStack.addArrangedSubview(retryButton)

        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Scan their document", comment: "")
        configuration.image = UIImage(systemName: "qrcode.viewfinder")
        configuration.imagePadding = 8
        configuration.buttonSize = .large
        scanButton.configuration = configuration
        scanButton.addTarget(self, action: #selector(scanPresentation), for: .touchUpInside)
        contentStack.addArrangedSubview(scanButton)

        #if DEBUG
        // The simulator has no camera, and cross-device testing against a real
        // credential needs *some* verifier that is not a second iPhone. This
        // feeds pasted frames through `receive(_:)` — the exact path a camera
        // scan takes — so everything after the lens is still what is being
        // tested. Deliberately unlocalized: a development affordance must not
        // read as part of the product, and must not enter the string catalog.
        let pasteButton = UIButton(type: .system)
        var pasteConfiguration = UIButton.Configuration.gray()
        pasteConfiguration.title = "貼上出示內容（開發用）"
        pasteConfiguration.image = UIImage(systemName: "doc.on.clipboard")
        pasteConfiguration.imagePadding = 8
        pasteButton.configuration = pasteConfiguration
        pasteButton.addTarget(self, action: #selector(pastePresentation), for: .touchUpInside)
        contentStack.addArrangedSubview(pasteButton)

        // One phone cannot check its own document through the camera, and the
        // clipboard route does not close the loop either: leaving this screen to
        // go and present mints a fresh challenge on the way back
        // (`viewWillAppear`), so the presentation answering the old one is
        // correctly refused. That is the single-use rule working, not a bug —
        // but it means a lone device could never see a card-signed verification
        // end to end, which is exactly the path that is hardest to test and
        // easiest to get wrong.
        //
        // So this runs the whole round trip in one tap, on this device's real
        // stored credential: mint a request from the real session, have
        // `HolderPresentation` answer it, reassemble the frames through the same
        // `FrameCollector` a camera feeds, and hand the result to the same
        // `check`. Nothing is stubbed and nothing skips a signature. What it
        // does skip is the lens and the QR itself, so it proves everything
        // except that the codes are scannable.
        let selfCheckButton = UIButton(type: .system)
        var selfCheckConfiguration = UIButton.Configuration.gray()
        selfCheckConfiguration.title = "用這支手機自己的證件跑一次（開發用）"
        selfCheckConfiguration.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        selfCheckConfiguration.imagePadding = 8
        selfCheckButton.configuration = selfCheckConfiguration
        selfCheckButton.addTarget(self, action: #selector(checkOwnCredential), for: .touchUpInside)
        contentStack.addArrangedSubview(selfCheckButton)
        #endif

        contentStack.addArrangedSubview(PresentationUI.footnote(
            NSLocalizedString("Nothing is sent anywhere. This check works with the phone in aeroplane mode.", comment: "")))
    }

    #if DEBUG
    /// The pasted text is the frames of one presentation, one per line — what
    /// the holder side's own debug button copies.
    /// Checks this device's own stored credential, start to finish.
    ///
    /// Disclosing nothing, deliberately — that is the interesting case now, and
    /// running it on a real phone is what found the bug it now guards.
    ///
    /// The holder ticks no boxes. `VerifiablePresentation.create` still discloses
    /// `name`, because the certificate carries it either way and withholding it
    /// only cost the checker the CN-to-name comparison. The first time this
    /// button ran, that forcing lived in the holder's *screen* and this method
    /// walked straight past it: the result said 「對方沒有出示姓名，所以無法核對
    /// 上面那張憑證是不是同一個人的」 while printing the name two lines above.
    ///
    /// So the expected result is: the name shown **and** checked, five fields
    /// held back, and the revocation line if a snapshot is installed.
    @objc private func checkOwnCredential() {
        collector.reset()
        // This mints its own request rather than going through `beginCheck`, so
        // the radio would otherwise be left hunting a service identifier that is
        // no longer the outstanding one.
        stopLink()
        linkLabel.text = nil
        let holder = HolderPresentation(store: (try? CredentialStore()) ?? EmptyCredentialStore())

        do {
            // The real session, so the challenge is minted and spent exactly as
            // it would be for a stranger. `beginCheck` replaces whatever this
            // screen last put on the display, which is the same thing tapping
            // 「重新查驗」 does.
            let request = try session.beginCheck(purpose: Self.purpose)
            let frames = try holder.frames(answering: request, disclosing: [])

            var payload: Data?
            for frame in frames {
                if case .payload(let data) = FrameIntake.accept(frame, into: collector) {
                    payload = data
                }
            }
            guard let payload, let jws = String(data: payload, encoding: .utf8) else {
                presentPasteDiagnosis("frames 重組失敗——收到 \(frames.count) 張但拼不回來。")
                return
            }
            // Timed, and reported before the result screen replaces everything.
            //
            // `VerifierSession` justifies its asynchronous path with a figure
            // measured on a Mac against the Go reference implementation: 1.35 s
            // to build the tree from the snapshot. Nobody had measured the Rust
            // one on a phone, and the first device run looked instant — which is
            // exactly the shape of "it is fast" and "it never ran" being
            // indistinguishable. So the number goes on screen.
            requestShownAtNanoseconds = VerificationClock.now()
            verify(presentationJWS: jws, transport: .local) { [weak self] result, record in
                guard let self else { return }
                let revocation: String
                if case .checked(.verified(let presentation)) = result {
                    revocation = String(describing: presentation.revocation)
                } else {
                    revocation = "（未通過或無結果）"
                }
                self.presentPasteDiagnosis(
                    "出示內容 \(jws.utf8.count) bytes，\(frames.count) 張 frame。\n"
                    + "查驗耗時 \(record.verificationMilliseconds ?? 0) ms。\n"
                    + "撤銷檢查：\(revocation)"
                ) { [weak self] in
                    _ = self?.finish(result, timing: record)
                }
            }
        } catch {
            presentPasteDiagnosis("這支手機上沒有可出示的證件，或簽章失敗：\(error)")
        }
    }

    @objc private func pastePresentation() {
        collector.reset()
        // The simulator's pasteboard sync is lazy and cross-process: a poller
        // in a test runner can see content a beat before this process does —
        // measured on 2026-08-09, where the runner saw the frames and this
        // read came back nil. Retry briefly before declaring it empty.
        var pasted: String?
        for _ in 0..<6 {
            pasted = UIPasteboard.general.string
            if pasted?.contains("BTWVP1") == true { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let text = pasted else {
            presentPasteDiagnosis("剪貼簿是空的。先在出示畫面按「複製出示內容」。")
            return
        }

        var last: ScannedFrame = .ignored
        for line in text.split(whereSeparator: \.isNewline) {
            let frame = String(line).trimmingCharacters(in: .whitespaces)
            guard !frame.isEmpty else { continue }
            last = FrameIntake.accept(frame, into: collector)
            if case .payload(let payload) = last {
                guard let jws = String(data: payload, encoding: .utf8) else {
                    session.cancel()
                    _ = finish(.rejected(.presentationIsNotAJWS))
                    return
                }
                verify(presentationJWS: jws, transport: .file)
                return
            }
        }

        // Ran out of lines without a payload. Unlike the camera, paste has an
        // end, so silence here would look like a button that does nothing —
        // the exact defect the frame-intake comment above describes.
        switch last {
        case .progress(let progress):
            presentPasteDiagnosis("只收到 \(progress.received)/\(progress.total) 個 frame。出示畫面的複製鈕會把全部 frame 一次複製，確認貼的是那一份。")
        case .ignored:
            presentPasteDiagnosis("剪貼簿內容不是這個 App 的出示 frame。")
        case .unreadable:
            presentPasteDiagnosis("Frame 讀不出來——可能被別的 App 改寫過（改行、去空白）。")
        case .payload:
            break
        }
    }

    /// A frame channel that iOS privacy does not gate: a file the app reads out
    /// of its own Documents directory.
    ///
    /// The pasteboard route above cannot be driven headlessly. A UI test with no
    /// one to tap 「允許貼上」 gets `Operation not authorized` on every read —
    /// measured 2026-08-10, and it is the wall the first cross-device attempts
    /// hit. An app reading its *own* container is never gated, so a host that
    /// drops frames there (`simctl get_app_container … data`) can feed a live
    /// verifier instance without a second phone and without a camera.
    ///
    /// DEBUG-only and opt-in via a launch environment flag, so it exists in no
    /// shipping build and lies dormant in every normal debug run. The verifier
    /// screen has a live, single-use challenge while this polls, so a dropped
    /// presentation answers the challenge currently on screen — the same
    /// property the camera path relies on.
    private func startDebugPresentationDropPollIfRequested() {
        guard ProcessInfo.processInfo.environment["BONDSTW_DEBUG_PRESENTATION_DROP"] == "1" else {
            return
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("debug-presentation.txt")

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("BTWVP1") else { return }
            // One-shot: remove before consuming so a slow verification cannot be
            // re-triggered by the next tick reading the same file.
            try? FileManager.default.removeItem(at: url)
            timer.invalidate()

            self.collector.reset()
            for line in text.split(whereSeparator: \.isNewline) {
                let frame = line.trimmingCharacters(in: .whitespaces)
                guard !frame.isEmpty else { continue }
                if case .payload(let payload) = FrameIntake.accept(frame, into: self.collector) {
                    guard let jws = String(data: payload, encoding: .utf8) else {
                        self.session.cancel()
                        _ = self.finish(.rejected(.presentationIsNotAJWS))
                        return
                    }
                    self.verify(presentationJWS: jws, transport: .file)
                    return
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func presentPasteDiagnosis(_ message: String, then continuation: (() -> Void)? = nil) {
        let alert = UIAlertController(title: continuation == nil ? "貼上失敗（開發用診斷）" : "開發用診斷",
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation?() })
        present(alert, animated: true)
    }
    #endif

    // MARK: - The challenge

    private func beginCheck() {
        do {
            let request = try session.beginCheck(purpose: Self.purpose,
                                                 credentialSource: selectedCredentialSource)
            let text = try request.encodedForTransport()
            // 1024 device pixels is generous for a ~100-byte code; `qrCode`
            // floors the module size to a whole number and may return something
            // a little smaller, which is why the image view centres rather than
            // stretches.
            #if DEBUG
            EngagementExport.write(text, kind: .credential)
            #endif
            let code = try QRTransport.qrCode(for: text, fittingPixelWidth: 1024)
            codeImageView.image = UIImage(cgImage: code.image)
            codeImageView.isHidden = false
            let source = request.credentialSource == .twdiw
                ? NSLocalizedString("government wallet card", comment: "")
                : NSLocalizedString("self-issued / MyData document", comment: "")
            purposeLabel.text = String(format: NSLocalizedString("Requested: %@ · Reason shown to them: %@", comment: ""),
                                       source, request.purpose)
            purposeLabel.isHidden = false
            unavailableLabel.isHidden = true
            retryButton.isHidden = true
            scanButton.isEnabled = true
            requestShownAtNanoseconds = VerificationClock.now()
            startLink(for: request)
        } catch {
            // `PresentationRequest.generate` refuses rather than inventing a
            // challenge when the system CSPRNG fails, and this is what that
            // refusal has to look like: no code, and no scan button, because a
            // check run without a fresh challenge has no replay defence at all
            // while still displaying a verdict.
            codeImageView.image = nil
            codeImageView.isHidden = true
            purposeLabel.isHidden = true
            unavailableLabel.text = (error as? LocalizedError)?.errorDescription
                ?? NSLocalizedString("This device could not create a verification request.", comment: "")
            unavailableLabel.isHidden = false
            scanButton.isEnabled = false
            retryButton.isHidden = false
            requestShownAtNanoseconds = nil
            // No challenge means nothing this screen receives could be judged, so
            // the radio comes down with the code.
            stopLink()
            linkLabel.text = nil
        }
    }

    /// Changing the requested credential family changes the signed statement,
    /// so it must mint a fresh challenge and BLE service rather than repainting
    /// a label over the previous QR.
    @objc private func credentialSourceChanged() {
        collector.reset()
        session.cancel()
        beginCheck()
    }

    // MARK: - The radio

    /// Starts scanning for the service identifier `request` names.
    ///
    /// Torn down and rebuilt on every `beginCheck`, which is correct here and is
    /// the opposite of the holder side's rule: there, the radio outlives a
    /// carousel restart; here, a new request *is* a new service identifier, and
    /// a central still hunting the previous one would be looking for a device
    /// nobody is any longer pretending to be.
    ///
    /// Bluetooth being unusable costs this screen nothing except this line. The
    /// camera is the path that has always worked and it stays enabled — the one
    /// thing that must never happen is a checker unable to check because a radio
    /// they were not told about is switched off.
    ///
    /// One asymmetry worth naming rather than hiding: the request QR carries a
    /// `linkServiceID` whether or not this device's Bluetooth turns out to be
    /// available, because the code is drawn before CoreBluetooth reports its
    /// state. A holder whose phone reads that code will advertise into an empty
    /// room and their screen will sit at 「waiting for the checker」 while this one
    /// says why. Both screens are telling the truth; they just each know half of
    /// it.
    private func startLink(for request: PresentationRequest) {
        stopLink()
        guard let serviceID = request.linkServiceID else {
            linkLabel.text = nil
            return
        }
        linkLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        try? BluetoothLinkDiagnosticStore.shared.record(role: .verifier, state: .starting)
        let link = BluetoothLinkCentral(serviceID: serviceID,
                                        vocabulary: .credential) { [weak self] state in
            self?.receiveOverLink(state)
        }
        self.link = link
        link.start()
    }

    /// Held as long as the screen is, and released when it goes — not when a
    /// scan starts. `CBCentralManager` does not retain its delegate, so letting
    /// this go is switching the radio off; the holder side has a comment on
    /// `stopLink` about the four device runs that cost.
    private func stopLink() {
        link?.stop()
        link = nil
    }

    /// One line, in the same register as everything else on this screen: what is
    /// happening, never an error code.
    private func receiveOverLink(_ state: BluetoothLinkState) {
        try? BluetoothLinkDiagnosticStore.shared.record(role: .verifier, state: state)
        switch state {
        case .unavailable(let reason):
            linkLabel.text = reason
        case .starting:
            linkLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        case .waiting:
            linkLabel.text = NSLocalizedString("Listening over Bluetooth too — you can also scan their code.", comment: "")
        case .transferring(let fraction):
            linkLabel.text = String(format: NSLocalizedString("Receiving over Bluetooth… %d%%", comment: ""),
                                    Int((fraction * 100).rounded()))
        case .failed(let reason):
            linkLabel.text = reason
        case .finished(let payload):
            // Down the moment the bytes are whole, so that a camera scan finishing
            // a heartbeat later cannot spend a challenge this one already answered
            // and push a second result on top of the first.
            stopLink()
            linkLabel.text = NSLocalizedString("Received over Bluetooth.", comment: "")
            checkReceived(payload, transport: .bluetooth)
        }
    }

    /// The single funnel every reassembled payload goes through, whichever
    /// entrance it arrived by.
    ///
    /// Not text is refused the same way here as on the camera path, including
    /// spending the challenge: bytes that reassembled and matched their digest
    /// were an answer, and leaving the challenge outstanding would let the same
    /// ones be retried against it.
    private func checkReceived(_ payload: Data, transport: VerificationRunRecord.Transport) {
        guard let jws = String(data: payload, encoding: .utf8) else {
            session.cancel()
            show(.rejected(.presentationIsNotAJWS))
            return
        }
        verify(presentationJWS: jws, transport: transport)
    }

    /// Shown only when minting a challenge failed. A transient CSPRNG refusal
    /// should cost one tap, not a navigation round trip — and the scan button
    /// stays disabled meanwhile, because a check without a fresh challenge has
    /// no replay defence.
    @objc private func retryBeginCheck() {
        retryButton.isHidden = true
        beginCheck()
    }

    /// What the holder is told this check is for. Echoed into the signed
    /// presentation and compared by `OfflineVerifier`, so both devices have to
    /// spell it the same way — which they do, because they are the same build.
    private static var purpose: String {
        NSLocalizedString("Identity check", comment: "Default reason a verifier gives for a check")
    }

    // MARK: - Scanning

    @objc private func scanPresentation() {
        collector.reset()

        let scanner = QRScanningViewController(
            title: NSLocalizedString("Scan their document", comment: ""),
            prompt: NSLocalizedString("Point the camera at the other phone.", comment: "")
        ) { [weak self] scanned in
            guard let self else { return .stop }
            return self.receive(scanned)
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

    /// One scanned string, on the main queue, possibly the same one many times a
    /// second.
    private func receive(_ scanned: String) -> QRScanningViewController.Decision {
        switch FrameIntake.accept(scanned, into: collector) {
        case .ignored:
            // Any other QR code that wanders into the viewfinder. Fires once per
            // video frame; silence is the only usable behaviour.
            return .keepScanning(status: nil)
        case .progress(let progress):
            return .keepScanning(status: Self.progressText(progress))
        case .unreadable:
            return .keepScanning(status: NSLocalizedString("That code could not be read. Ask them to show it again from the start.", comment: ""))
        case .payload(let payload):
            // The other entrance closes here, for the same reason it closes the
            // camera: two paths that both reached a whole payload would spend one
            // challenge and stack two results.
            stopLink()
            guard let jws = String(data: payload, encoding: .utf8) else {
                // Reassembled, digest matched, and still not text. Not a
                // presentation from this app; report it as unreadable rather
                // than as a verification failure, which would imply we got far
                // enough to judge it. The challenge is spent anyway — it was
                // answered, badly, and leaving it outstanding would let the
                // same bytes be retried against it.
                session.cancel()
                return finish(.rejected(.presentationIsNotAJWS))
            }
            // Stops the camera now and shows the result when it arrives. The
            // gap is real — a revocation lookup rebuilds the tree from a 22 MB
            // snapshot — so the viewfinder is left with a line saying so rather
            // than frozen and silent.
            verify(presentationJWS: jws, transport: .qr)
            return .keepScanning(status: NSLocalizedString("Checking…", comment: "Shown while a scanned presentation is being verified"))
        }
    }

    /// Times and records the one verification funnel shared by QR, Bluetooth,
    /// file-drop and the DEBUG self-check. The record is written before the
    /// result screen is shown so copying Diagnostics immediately after a run
    /// cannot miss it.
    private func verify(presentationJWS: String,
                        transport: VerificationRunRecord.Transport,
                        completion: ((VerifierSessionResult, VerificationRunRecord) -> Void)? = nil) {
        let verificationStarted = VerificationClock.now()
        let requestShown = requestShownAtNanoseconds ?? verificationStarted
        let measuredRequest = session.pendingRequest()
        session.check(presentationJWS: presentationJWS) { [weak self] result in
            guard let self else { return }
            let completed = VerificationClock.now()
            let succeeded: Bool?
            switch result {
            case .checked(.verified): succeeded = true
            case .checked(.rejected): succeeded = false
            case .noPendingRequest: succeeded = nil
            }
            let record = VerificationRunRecord(
                flow: .offlinePresentation,
                role: .verifier,
                credentialKind: measuredRequest?.credentialSource == .twdiw
                    ? .governmentWallet : .selfIssued,
                transport: transport,
                succeeded: succeeded,
                transportMilliseconds: VerificationClock.milliseconds(
                    from: requestShown, to: verificationStarted),
                verificationMilliseconds: VerificationClock.milliseconds(
                    from: verificationStarted, to: completed),
                endToEndMilliseconds: VerificationClock.milliseconds(
                    from: requestShown, to: completed),
                payloadBytes: UInt64(presentationJWS.utf8.count),
                correlationToken: measuredRequest?.linkServiceID.map {
                    VerificationRunRecord.correlationToken(for: $0.uuidString)
                },
                qrFallbackWasVisible: transport == .qr)
            try? VerificationRunStore.shared.append(record)
            self.requestShownAtNanoseconds = nil
            if let completion {
                completion(result, record)
            } else {
                _ = self.finish(result, timing: record)
            }
        }
    }

    /// Points the session at the snapshot `CircuitAssets` installs, if it is
    /// there.
    ///
    /// Presence is the whole condition. The snapshot arrives with the ZK proving
    /// assets, so most installs will not have one and will keep saying 「離線無法
    /// 確認是否已被撤銷」 — which is true for them. Nothing here downloads
    /// anything, and a missing file is not an error to report.
    private static func installedRevocationLookup() -> RevocationLookup {
        guard let asset = CircuitAssets.required.first(where: { $0.name == "g3_tree_snapshot" }),
              let directory = try? CircuitAssets.defaultDirectory() else {
            return .unavailable
        }
        let url = directory.appendingPathComponent(asset.localFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return .unavailable }
        return .snapshot(at: url, provider: OpenACRevocationProofProvider())
    }

    private func finish(_ result: VerifierSessionResult,
                        timing: VerificationRunRecord? = nil) -> QRScanningViewController.Decision {
        let outcome: VerificationOutcome?
        switch result {
        case .checked(let checked):
            outcome = checked
        case .noPendingRequest:
            outcome = nil
        }
        show(outcome, timing: timing)
        return .stop
    }

    private func finish(_ outcome: VerificationOutcome) -> QRScanningViewController.Decision {
        show(outcome)
        return .stop
    }

    private func show(_ outcome: VerificationOutcome?, timing: VerificationRunRecord? = nil) {
        // Pop the scanner and push the result in one transaction, so the camera
        // screen does not flash back into view between the two.
        guard let navigationController else { return }
        var stack = navigationController.viewControllers
        while stack.last is QRScanningViewController { stack.removeLast() }
        stack.append(VerificationResultViewController(outcome: outcome, timing: timing))
        navigationController.setViewControllers(stack, animated: true)
    }

    private static func progressText(_ progress: FrameCollector.Progress) -> String {
        String(format: NSLocalizedString("Read %1$d of %2$d codes", comment: "Multi-frame scan progress"),
               progress.received, progress.total)
    }
}

// MARK: - Intake

/// What one scanned string meant.
enum ScannedFrame: Equatable {
    /// Not one of ours at all. Say nothing.
    case ignored
    /// A frame of the presentation now being collected.
    case progress(FrameCollector.Progress)
    /// Every frame is in.
    case payload(Data)
    /// Ours, and unusable: a chunk that will not decode, a stream that will not
    /// inflate, a payload larger than this device will reassemble.
    case unreadable
}

/// Feeds scanned strings into a collector that outlives the person in front of
/// it.
///
/// `FrameCollector` holds one presentation and refuses every frame of any other
/// with `frameFromAnotherPresentation`, which is the right call at that layer:
/// it cannot tell "the holder is showing a different document now" from
/// "somebody spliced a frame into this one", and guessing there would decide a
/// security question with a heuristic. Deciding is this layer's job, because
/// only this layer knows the frames are arriving from a live camera pointed at
/// whoever is standing there now.
///
/// **What the missing decision cost.** A verifier who scanned one frame of A —
/// a glance at the queue, a phone lowered mid-carousel — and then scanned B got
/// a throw on *every single frame of B*, forever. Replaying the whole of B, ten
/// times over, could not clear it. The only thing on screen was 「請對方從第一張
/// 重新出示」, which is precisely the action that cannot recover, and the screen
/// otherwise looked like a scanner that was simply not seeing the codes.
///
/// **Why restarting is safe.** A reset can only ever *lose* progress. It cannot
/// admit a payload that would otherwise have been refused: `FrameCollector`
/// re-derives the digest of whatever it reassembles and compares it against the
/// identifier the frames carried, on every completion, and nothing here touches
/// that. So the substituted-chunk case — same identifier, different bytes in a
/// slot already held, which also raises `frameFromAnotherPresentation` —
/// restarts and is caught by the digest at the end exactly as before.
enum FrameIntake {

    static func accept(_ scanned: String, into collector: FrameCollector) -> ScannedFrame {
        do {
            return try take(scanned, into: collector)
        } catch QRTransportError.notATransportFrame {
            return .ignored
        } catch QRTransportError.frameFromAnotherPresentation,
                QRTransportError.inconsistentFrameHeader {
            collector.reset()
            // Re-offered rather than dropped: this frame is the first good frame
            // of the document that is actually on screen, and dropping it would
            // make the count sit at 0 until the carousel came round again — the
            // exact moment a verifier gives up and says it does not work.
            return (try? take(scanned, into: collector)) ?? .unreadable
        } catch {
            return .unreadable
        }
    }

    private static func take(_ scanned: String, into collector: FrameCollector) throws -> ScannedFrame {
        switch try collector.accept(scanned) {
        case .accepted(let progress), .duplicate(let progress):
            return .progress(progress)
        case .completed(let payload):
            return .payload(payload)
        }
    }
}

// MARK: - Result

/// What one check produced, including everything it could not establish.
///
/// The caveat list is not an appendix. A verified presentation proves that the
/// device in front of you holds the key its `did:key` names and answered this
/// challenge — 「本人可驗」 — and nothing whatsoever about whether the national ID
/// data inside is true, whether the holder revoked it, or whether the identifier
/// they showed is one they show everybody. Those three sentences are the
/// difference between this screen and a lie.
final class VerificationResultViewController: UIViewController {

    /// `nil` means this device had no outstanding challenge — the request had
    /// already been answered once, or it aged out. Deliberately not folded into
    /// `VerificationFailure`: the nearest case there accuses the holder of
    /// replaying, and this is a fact about *our* device.
    private let outcome: VerificationOutcome?
    private let timing: VerificationRunRecord?

    init(outcome: VerificationOutcome?, timing: VerificationRunRecord? = nil) {
        self.outcome = outcome
        self.timing = timing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Check result", comment: "")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.hidesBackButton = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Done", comment: ""), style: .done,
            target: self, action: #selector(done))
        buildInterface()
    }

    @objc private func done() {
        navigationController?.popViewController(animated: true)
    }

    private func buildInterface() {
        let scrollView = UIScrollView()
        let stack = UIStackView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20

        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        switch outcome {
        case .some(.verified(let presentation)):
            buildVerified(presentation, into: stack)
        case .some(.rejected(let failure)) where failure.isAboutThisDevice:
            // Orange, and a different word, for the same reason as the `.none`
            // branch below: **nothing about the document was judged.** One of
            // these two is a file this build could not load; the other is this
            // phone's clock reading a date before a certificate starts being
            // valid. An honest document used to get the identical red a forgery
            // gets, under a sentence pointing the reader in one of two wrong
            // directions.
            stack.addArrangedSubview(PresentationUI.verdict("⚠️",
                NSLocalizedString("Nothing was checked", comment: ""), .systemOrange))
            stack.addArrangedSubview(PresentationUI.card(body: failure.message))
            stack.addArrangedSubview(PresentationUI.mitigation(
                NSLocalizedString("This is about this phone, not about the person presenting. What they showed was never examined, so nothing here counts against them.", comment: "")))
        case .some(.rejected(let failure)):
            stack.addArrangedSubview(PresentationUI.verdict("⛔️",
                NSLocalizedString("Not accepted", comment: ""), .systemRed))
            stack.addArrangedSubview(PresentationUI.card(body: failure.message))
            stack.addArrangedSubview(PresentationUI.mitigation(
                NSLocalizedString("A refusal is not proof of a forgery. A wrong clock, a partial scan, or an out-of-date app produce the same answer.", comment: "")))
        case .none:
            // Not the red verdict, and not the same word.
            //
            // Nothing was examined here: this device had no outstanding request
            // to examine anything against, so the branch says nothing whatever
            // about what the other person presented. Wearing 「查驗未通過」 in
            // red made this device's own housekeeping look like a judgement on
            // them — and it was the one branch that did not carry the sentence
            // below, so the reader got the accusation without the qualification.
            //
            // Same rule as `.partial` on the capability screen: a state that is
            // not the bad one must not be drawn as the bad one.
            stack.addArrangedSubview(PresentationUI.verdict("⚠️",
                NSLocalizedString("Nothing was checked", comment: ""), .systemOrange))
            stack.addArrangedSubview(PresentationUI.card(body: NSLocalizedString(
                "This checker had no request outstanding. Each request can be answered once; start a new check and ask them to scan it again.", comment: "")))
            stack.addArrangedSubview(PresentationUI.mitigation(
                NSLocalizedString("This is about this phone, not about the person presenting. What they showed was never examined, so nothing here counts against them.", comment: "")))
        }

        if let timing {
            var lines: [String] = []
            if let milliseconds = timing.transportMilliseconds {
                lines.append(String(format: NSLocalizedString(
                    "Request shown to complete payload: %.2f seconds (includes scanning and handling the phones)",
                    comment: "offline presentation operational timing"),
                    Double(milliseconds) / 1_000))
            }
            if let milliseconds = timing.verificationMilliseconds {
                lines.append(String(format: NSLocalizedString(
                    "Cryptographic verification on this device: %.2f seconds",
                    comment: "offline local verification timing"),
                    Double(milliseconds) / 1_000))
            }
            if let milliseconds = timing.endToEndMilliseconds {
                lines.append(String(format: NSLocalizedString(
                    "Request shown to result: %.2f seconds",
                    comment: "offline verification end-to-end timing"),
                    Double(milliseconds) / 1_000))
            }
            let card = PresentationUI.card(
                title: NSLocalizedString("Verification time", comment: "verification result timing"),
                body: lines.joined(separator: "\n"))
            card.accessibilityIdentifier = "verificationResult.timing"
            // Verdict and its immediate qualification stay first. The number is
            // next, before any variable-length claim list can push it away.
            stack.insertArrangedSubview(card, at: min(2, stack.arrangedSubviews.count))
        }
    }

    /// Draws the blocks in `VerifiedResultSection.order` and nothing else.
    ///
    /// Driven by that array rather than by four statements in a row so that the
    /// arrangement is a value a test can read. The caveats sitting above the
    /// disclosed fields is a security property (see the type there); a security
    /// property that exists only as the sequence of calls in a function body is
    /// one the next edit to that function repeals without anything noticing.
    /// The switch is exhaustive, so a new section cannot be added without a
    /// decision about where it goes.
    /// Date and hour, in the checker's locale. The hour is there because the
    /// snapshot is rebuilt twice a day and a list from this morning is a
    /// materially better answer than one from last night.
    /// When the presenter signed, by their clock. Static for the same reason
    /// `snapshotDateFormatter` is: building a `DateFormatter` per render is the
    /// classic scroll hitch.
    private static let signedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let snapshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return formatter
    }()

    private func buildVerified(_ presentation: VerifiedPresentation, into stack: UIStackView) {
        for section in VerifiedResultSection.order {
            switch section {
            case .verdict:
                let verdict = PresentationUI.verdict("✅",
                    // "this device" used to be here, and it is the one word on
                    // the page that points at the wrong phone. The checker is
                    // holding *a* device while they read it, and the last line
                    // of this same screen calls the other one 「對方手機」. So
                    // the single largest, greenest, most-likely-to-be-read-and-
                    // stopped-at line was the only one using a demonstrative
                    // that resolves to the reader. The claim is unchanged; only
                    // the pronoun now agrees with the rest of the page.
                    NSLocalizedString("They signed this check with the key in their phone", comment: ""), .systemGreen)
                stack.addArrangedSubview(verdict)
                // What the check *gained*, said as this app's own sentence
                // rather than filed among the costs. It reads directly under
                // the verdict because it qualifies the verdict — and pinning
                // it here keeps the group cards below purely about limits.
                let gained = PresentationUI.body(VerificationCaveat.noNetworkQuery.message)
                stack.addArrangedSubview(gained)
                stack.setCustomSpacing(8, after: verdict)
                stack.setCustomSpacing(24, after: gained)

            case .whatThisCheckDidNotEstablish:
                // Position is the security property and it is untouched: every
                // caveat still renders, in full, above anything the other
                // device supplied. What changed is shape — eight visually
                // identical pills became titled groups, because a wall a person
                // scrolls past unread is the polite version of a caveat pushed
                // off the screen.
                let heading = PresentationUI.sectionTitle(
                    NSLocalizedString("What this check did not establish", comment: ""))
                stack.addArrangedSubview(heading)
                stack.setCustomSpacing(8, after: heading)

                // The revocation date rides in the same line as the revocation
                // caveat — 「查了名單」 and 「哪一份名單」 are one statement.
                // Joined with a space, never a newline: a label of its own (or a
                // second line) is exactly the shape a forged field takes, and
                // the tests pin every label to a single line. The date is
                // parsed from a file this device downloaded, not the other
                // device's bytes, so it does not pass through `UntrustedText`.
                var dateSuffix = ""
                if let date = presentation.revocation.snapshot?.generatedAt {
                    dateSuffix = " " + String(
                        format: NSLocalizedString("That list was made on %@.",
                                                  comment: "Date of the revocation snapshot used"),
                        Self.snapshotDateFormatter.string(from: date))
                }

                var lastGroup: UIView?
                for group in VerificationCaveat.Group.displayOrder {
                    let members = presentation.caveats.filter { $0.group == group && $0 != .noNetworkQuery }
                    guard !members.isEmpty else { continue }
                    let card = PresentationUI.caveatGroup(
                        subtitle: group.subtitle,
                        messages: members.map { caveat in
                            caveat.concernsRevocation ? caveat.message + dateSuffix : caveat.message
                        })
                    stack.addArrangedSubview(card)
                    stack.setCustomSpacing(12, after: card)
                    lastGroup = card
                }
                if let lastGroup { stack.setCustomSpacing(28, after: lastGroup) }

            case .whoSigned:
                // Absent entirely for a device-signed credential: the
                // `selfIssuedByTheHolder` caveat already says who vouched
                // (nobody), and a section that said it again would dilute the
                // one case where this section carries real information.
                if let rawName = presentation.cardholderName {
                    // Sanitized like every other string off the other device.
                    // The name passed verification's equality check against the
                    // credential's own `name`, but "verified" is not "safe to
                    // hand a UILabel" — a CN is whatever DirectoryString the CA
                    // encoded, and this app's parser is deliberately more
                    // permissive than any CA's issuing rules.
                    let name = UntrustedText.value(rawName)
                    stack.addArrangedSubview(PresentationUI.sectionTitle(
                        NSLocalizedString("Who signed", comment: "")))
                    // App words first — the same bidirectional discipline as
                    // `ClaimLabel`: a leading strong-direction prefix keeps a
                    // hostile right-to-left run from reordering the sentence.
                    stack.addArrangedSubview(PresentationUI.body(String(
                        format: NSLocalizedString("The certificate that signed these details was issued by the government certification authority to “%@”. That names the signer — it does not mean the government checked the details below.",
                                                  comment: "Verifier result: who the signing certificate belongs to"),
                        name.text)))
                    // Without this line the name above reads as confirmed. When
                    // the holder withheld their name there was nothing to
                    // confirm it against, and a checker comparing the screen to
                    // a face has to know which of the two they are looking at.
                    if !presentation.cardholderNameWasChecked {
                        stack.addArrangedSubview(PresentationUI.caveat(
                            NSLocalizedString("They did not show the name on the document, so this app could not check that the certificate above belongs to the same person.",
                                              comment: "")))
                    }
                }

            case .whatTheyDisclosed:
                buildDisclosedFields(presentation.claims, into: stack)
                // "Three fields" and "three of eight" are materially different
                // statements, and only one of them is what a checker is looking
                // at. Said after the fields, where the count is about what was
                // just read.
                if presentation.withheldClaimCount > 0 {
                    stack.addArrangedSubview(PresentationUI.caveat(String(
                        format: NSLocalizedString("They held back %d more field(s). This app cannot tell which, only that the document commits to them.",
                                                  comment: ""),
                        presentation.withheldClaimCount)))
                }

            case .whenItWasSigned:
                // Person first, then the qualifier. The old phrasing — "Signed
                // at ... by the other device's clock" — read as though the
                // clock did the signing. The qualifier itself is load-bearing
                // and stays: this timestamp is the presenter's claim, and a
                // sign-off that dropped it would promote their clock to a fact.
                let signedAt = PresentationUI.body(
                    String(format: NSLocalizedString("They signed this on %@. That time comes from their phone's clock, which this app cannot verify.", comment: "Verifier result sign-off"),
                           Self.signedAtFormatter.string(from: presentation.presentedAt)))
                stack.addArrangedSubview(signedAt)
            }
        }
    }

    /// Everything below this heading was written by whoever signed the
    /// credential, which for a self-issued document is the person being checked.
    ///
    /// The heading alone was not enough — 「What they disclosed」 reads as a
    /// description of a table this app compiled — so it is followed by a sentence
    /// that says so in words, and every value is drawn behind a quotation rule
    /// that nothing this app asserts ever has. Between them a checker can tell,
    /// without knowing anything about signatures, which sentences on this screen
    /// the app stands behind.
    private func buildDisclosedFields(_ claims: [DisclosedClaim], into stack: UIStackView) {
        let heading = PresentationUI.sectionTitle(
            NSLocalizedString("What they disclosed", comment: ""))
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(8, after: heading)
        stack.addArrangedSubview(PresentationUI.body(NSLocalizedString(
            "The lines below are the document's own words, quoted. This app checked the signature over them, not whether any of it is true.",
            comment: "Attribution above the fields a verified presentation disclosed")))

        guard !claims.isEmpty else {
            stack.addArrangedSubview(PresentationUI.card(body:
                NSLocalizedString("This document disclosed no fields.", comment: "")))
            return
        }

        let presentable = PresentableClaims(claims)
        for claim in presentable.rows {
            stack.addArrangedSubview(PresentationUI.disclosedField(claim))
        }
        if presentable.hiddenCount > 0 {
            // Stated, not silently dropped. How much the holder handed over is a
            // fact about their privacy, and a verifier who cannot see it all is
            // at least told there was more.
            stack.addArrangedSubview(PresentationUI.caveat(String(
                format: NSLocalizedString("This document disclosed %d more field(s) that are not shown here.",
                                          comment: "Shown when a presentation carries more fields than the screen draws"),
                presentable.hiddenCount)))
        }
    }
}

// MARK: - Shared views

/// Plain label and card factories for the two presentation screens.
///
/// These screens are a QR code, a verdict and a stack of sentences, which a
/// `UICollectionViewListCell` models badly — a list cell wants a row of a table,
/// and the caveat list is prose that has to wrap to four lines without being
/// truncated. Everything here is Dynamic Type aware and multi-line by default,
/// because the two things this app cannot afford on these screens are text that
/// is cut off and text that does not grow.
/// The two halves of the checker screen's lifecycle, in one place so they can be
/// read against each other.
///
/// A type rather than an `if` in each callback, for the same reason as
/// `PresentationScreenLifecycle` on the holder's side: the defect this prevents
/// is a **wrong answer** rather than a crash, and it lived in the gap between two
/// callbacks that were correct on their own.
///
/// What went wrong. `viewWillDisappear` deliberately did *not* cancel when the
/// scanner was pushed — the scanner is about to collect the answer to the
/// challenge on screen, and cutting a holder off mid-send would be gratuitous.
/// `viewWillAppear` then minted a fresh challenge unconditionally. So the screen
/// **kept the challenge on the way out and replaced it on the way back**: press
/// the scanner's back button, deny the camera, come back from anywhere at all,
/// and the holder's honest presentation now answered a challenge that no longer
/// existed. `challengeMismatch` reaches the result screen as 「可能是先前出示的
/// 複本」 — a replay accusation, aimed at somebody who did nothing wrong.
///
/// Refusing a valid presentation is the expensive direction of this screen's two
/// possible mistakes, and that sentence is how the person pays for it.
///
/// The single-use rule is untouched: leaving for good still cancels, so going
/// away to present on this same device and coming back does mint a fresh
/// challenge (the note by the paste button depends on that). What changed is
/// that a round trip through the camera is no longer counted as leaving.
enum VerifierScreenLifecycle {

    enum Arrival: Equatable {
        /// Mint a fresh challenge and clear whatever the collector holds.
        case beginNewCheck
        /// Leave the live challenge — and the frames already collected — alone.
        case keepWaiting
    }

    enum Departure: Equatable {
        /// Cancel the challenge and stop the radio.
        case endCheck
        /// Going somewhere that is still part of this check.
        case stayLive
    }

    /// A spent challenge leaves none behind, so `hasLiveRequest` is `false` after
    /// a result and the code on screen is correctly replaced. It is also `false`
    /// once the outstanding request has aged out, which is the same news.
    static func arriving(hasLiveRequest: Bool) -> Arrival {
        hasLiveRequest ? .keepWaiting : .beginNewCheck
    }

    static func leaving(forGood: Bool) -> Departure {
        forGood ? .endCheck : .stayLive
    }
}

enum PresentationUI {

    static func title(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func body(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        // `.label`. See `footnote(_:)` immediately below for the measurement and
        // for the comment that used to say the opposite.
        label.textColor = .label
        return label
    }

    /// Full label ink. The hierarchy is carried by the type scale, not by how
    /// hard the sentence is to read.
    ///
    /// # The comment here used to be wrong, and being wrong was its whole effect
    ///
    /// It said: 「`.tertiaryLabel` is 26% ink … fails WCAG AA at every text size.
    /// **`.secondaryLabel` is 60% and clears it.**」 The first half is right and
    /// the second is not. Measured: `.secondaryLabel` (#3C3C43 at 60%) is
    /// **3.44:1** on `.secondarySystemGroupedBackground` and **3.30:1** on
    /// `.systemGroupedBackground`. Body text needs 4.5:1, and `footnote` is 13pt
    /// so the large-text 3:1 exemption does not apply. Dark mode is 5.95:1 —
    /// again, only light mode is broken, which is to say only daylight.
    ///
    /// The number was already written down **in this same file, 85 lines away**:
    /// `caveatGroup`'s comment says 3.44:1 does not pass AA for body text, which
    /// is why the first audit round moved those messages to `.label`. One
    /// `UIColor`, two comments, opposite claims — and this one is the one every
    /// new screen reads before reaching for the style.
    ///
    /// Four sentences had no full-ink copy anywhere near them: where the purpose
    /// text a checker typed came from, why the name row has no switch beside it,
    /// the airplane-mode claim, and `disclosureNote` — which this file's own
    /// comment calls the fingerprint of a hand-made document.
    static func footnote(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        return label
    }

    /// The sentence that stops a refusal from being read as an accusation.
    ///
    /// Body weight and full label colour, drawn directly under the verdict —
    /// deliberately not a footnote, because the reader it is written for is a
    /// person who has just been shown a red screen in front of somebody else and
    /// has seconds to say something. It was in `.footnote` at `.tertiaryLabel`:
    /// **the one line on the screen protecting an honest person was the faintest
    /// text on it.** Same reasoning as the cycle-time sentence on the holder's
    /// side, which was moved out of the footnote style for the same reason.
    ///
    /// Kept as its own constructor rather than a `body` call so that the role is
    /// named. A style that exists only as an argument at one call site is one the
    /// next edit quietly demotes.
    static func mitigation(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        return label
    }

    /// The one line the whole screen exists to deliver, drawn so it reads first.
    ///
    /// A card rather than a bare label — measured on device (2026-08-11), the
    /// bare `.title2` line in the accent colour had less visual weight than the
    /// caveat pills under it, and coloured text on the grouped background sat
    /// near 2:1 contrast. The colour moved into a tinted background; the text
    /// went back to `.label`, bold. The 「✅  」 prefix stays inside `label.text`
    /// because tests find the verdict by it, and because an icon that VoiceOver
    /// reads with the sentence is part of the sentence.
    static func verdict(_ symbol: String, _ text: String, _ colour: UIColor) -> UIView {
        let label = UILabel()
        label.text = symbol + "  " + text
        label.numberOfLines = 0
        label.font = UIFontMetrics(forTextStyle: .title2)
            .scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label

        let card = UIStackView(arrangedSubviews: [label])
        card.axis = .vertical
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.backgroundColor = colour.withAlphaComponent(0.14)
        card.layer.cornerRadius = 12
        return card
    }

    /// A titled group of caveats: one rounded container, a small app-authored
    /// subtitle, one label per caveat.
    ///
    /// Grouping is presentation, not hierarchy — nothing collapses, nothing
    /// truncates, and the group renders every message it is given in the order
    /// it is given. What it buys is that eight visually identical pills become
    /// three titled paragraphs a person can navigate.
    /// The ground a group sits on when it is **inside** another card.
    ///
    /// # Why this exists
    ///
    /// `caveatGroup` and `card` paint `.secondarySystemGroupedBackground`, which
    /// is the right colour for their thirteen original call sites: every one of
    /// them is added to a screen-level stack on `.systemGroupedBackground`, so
    /// the box is a visible white panel on grey.
    ///
    /// The capability page reused them one level deeper — inside a comparison
    /// card that is *itself* `.secondarySystemGroupedBackground`. Same colour on
    /// same colour is 1.00:1, so the rounded boxes vanished, and the only thing
    /// left separating 「what a checker can rely on」 from 「what it cannot
    /// establish」 was a 12pt 3.44:1 grey subtitle above two lists of identical
    /// black text. Read without that grey line, 「it carries a number unique to
    /// this card that every checker sees」 reads as a feature.
    static let nestedGroupBackground = UIColor.tertiarySystemGroupedBackground

    /// - Parameter nested: true when this group is added inside another card
    ///   rather than onto a screen-level stack. It takes a third-level ground so
    ///   the box is visible, and promotes the subtitle to `.label` — on a page
    ///   where the subtitle is the only thing saying which of two equally black
    ///   lists is the negative one, that subtitle is not category furniture.
    static func caveatGroup(subtitle: String, messages: [String], nested: Bool = false) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.backgroundColor = nested ? nestedGroupBackground : .secondarySystemGroupedBackground
        stack.layer.cornerRadius = 12

        let title = UILabel()
        title.text = subtitle
        title.numberOfLines = 0
        title.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        title.adjustsFontForContentSizeCategory = true
        title.textColor = nested ? .label : .secondaryLabel
        stack.addArrangedSubview(title)

        for message in messages {
            let label = UILabel()
            label.text = "•  " + message
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .callout)
            label.adjustsFontForContentSizeCategory = true
            // `.label`, not `.secondaryLabel` — measured at 3.44:1 in light
            // mode, which does not pass AA for body text.
            //
            // The ordering was backwards, which is the part that matters: the
            // block headed 「這次查驗沒有確認的事」 was entirely grey, while the
            // standalone caveat pill next to it (`.label`, 21:1) carried
            // 「對方另外保留了 2 個欄位」. Bookkeeping in black, the limits of
            // the verdict in grey. And it only failed in light mode, which is
            // what a counter is in during the day.
            //
            // The subtitle above stays `.secondaryLabel`: it is a category
            // name, not a caveat.
            label.textColor = .label
            stack.addArrangedSubview(label)
        }
        return stack
    }

    /// - Parameter nested: see `caveatGroup(subtitle:messages:nested:)`. The
    ///   title here stays `.secondaryLabel` either way — unlike the caveat
    ///   group's, it labels one box rather than distinguishing two.
    static func card(title: String? = nil, body: String, nested: Bool = false) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.backgroundColor = nested ? nestedGroupBackground : .secondarySystemGroupedBackground
        stack.layer.cornerRadius = 12

        if let title {
            let titleLabel = UILabel()
            titleLabel.text = title
            titleLabel.numberOfLines = 0
            titleLabel.font = .preferredFont(forTextStyle: .caption1)
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.textColor = .secondaryLabel
            stack.addArrangedSubview(titleLabel)
        }

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.numberOfLines = 0
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(bodyLabel)
        return stack
    }

    /// One disclosed field, drawn so it cannot be mistaken for something this
    /// app is asserting.
    ///
    /// Three things separate it from `card(title:body:)`, which is what this used
    /// to be and which is still what the app's *own* sentences use:
    ///
    /// 1. **A quotation rule** down the leading edge of the value. It is the one
    ///    piece of chrome no app-authored text on these two screens has, so the
    ///    distinction survives a value that contains ✅ or 「內政部核發」 — filtering
    ///    those out is unwinnable and would refuse people's real names, whereas a
    ///    quoted ✅ is visibly a quoted ✅.
    /// 2. **An app-authored heading, always.** A term this build knows becomes
    ///    this app's noun; one it does not know is quoted inside a sentence this
    ///    app wrote, so `zzz_official = "內政部戶政司 已驗證"` can no longer occupy
    ///    the same slot, in the same style, as 「姓名」.
    /// 3. **Text that has been through `UntrustedText`** — single-run, length
    ///    bounded, and with a note in words when either of those had to act.
    ///
    /// The rule is drawn, so it is invisible to VoiceOver; the value's
    /// `accessibilityLabel` carries the same framing in words instead. A safety
    /// signal that only exists in pixels is not a safety signal for the people
    /// most likely to be handed somebody else's phone to read.
    static func disclosedField(_ claim: PresentableClaim) -> UIView {
        let heading = UILabel()
        heading.numberOfLines = 0
        heading.font = .preferredFont(forTextStyle: .caption1)
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = .secondaryLabel
        switch claim.label {
        case .known(let name):
            heading.text = name
        case .declaredByTheDocument(let term):
            heading.text = String(
                format: NSLocalizedString("Field named by their document: “%@”",
                                          comment: "Heading for a disclosed field whose name this build does not know"),
                term.text)
        }

        let value = UILabel()
        value.text = claim.value.isEmpty
            ? NSLocalizedString("(blank)", comment: "A disclosed field whose value is empty")
            : claim.value.text
        value.numberOfLines = 0
        // `.title3`, not `.body`: the checker's actual task is reading this
        // value against a face or a form, and it used to be the smallest text
        // on the screen. Size is not the quoted-versus-asserted boundary — the
        // quotation rule, the app-authored heading and the VoiceOver framing
        // are — and the verdict grew in the same pass, so it still outranks
        // this.
        value.font = .preferredFont(forTextStyle: .title3)
        value.adjustsFontForContentSizeCategory = true
        value.accessibilityLabel = String(
            format: NSLocalizedString("Quoted from their document: %@",
                                      comment: "VoiceOver framing for a disclosed field's value"),
            value.text ?? "")

        let quoted = UIStackView(arrangedSubviews: [value])
        quoted.axis = .vertical
        quoted.spacing = 4
        if let note = disclosureNote(for: claim.value) {
            quoted.addArrangedSubview(note)
        }

        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = .tertiaryLabel
        rule.layer.cornerRadius = 1.5
        rule.widthAnchor.constraint(equalToConstant: 3).isActive = true

        let quotation = UIStackView(arrangedSubviews: [rule, quoted])
        quotation.axis = .horizontal
        quotation.spacing = 10
        quotation.alignment = .fill

        let stack = UIStackView(arrangedSubviews: [heading, quotation])
        stack.axis = .vertical
        stack.spacing = 6
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.backgroundColor = .secondarySystemGroupedBackground
        stack.layer.cornerRadius = 12
        return stack
    }

    /// Says in words what `UntrustedText` had to do, when it had to do anything.
    ///
    /// An ellipsis on its own is ambiguous — plenty of real values end in one —
    /// and a U+FFFD is meaningless to anybody who has not seen one before. Both
    /// are also the fingerprints of a hand-built credential, so a checker is
    /// better off being told than being left to notice.
    private static func disclosureNote(for text: UntrustedText) -> UILabel? {
        var sentences: [String] = []
        if text.wasTruncated {
            sentences.append(NSLocalizedString("This field was too long to show in full.", comment: ""))
        }
        if text.containedControlCharacters {
            sentences.append(NSLocalizedString("It contained characters that can rearrange text on screen; they are shown as \u{FFFD}.", comment: ""))
        }
        guard !sentences.isEmpty else { return nil }
        return footnote(sentences.joined(separator: " "))
    }

    /// Bulleted, tinted, and never truncated. A caveat that has to be tapped to
    /// read is a caveat that was not shown.
    static func caveat(_ text: String) -> UIView {
        let label = UILabel()
        label.text = "•  " + text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label

        let container = UIStackView(arrangedSubviews: [label])
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        container.backgroundColor = .secondarySystemGroupedBackground
        container.layer.cornerRadius = 12
        return container
    }
}
