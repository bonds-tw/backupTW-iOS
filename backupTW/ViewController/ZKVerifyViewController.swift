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

    /// The only screen-to-screen screen in this app that held neither a wake
    /// lock nor a brightness boost — and the one that has to survive 21.7
    /// measured seconds.
    ///
    /// The other half of the same transfer holds one and says why: the holder
    /// touches nothing for the whole transfer, and Low Power Mode pins Auto-Lock
    /// at 30 seconds with no way to change it. This phone has been sitting on
    /// the pairing screen untouched since *before* the holder started scanning,
    /// so the idle timer is already part-spent when the transfer begins.
    ///
    /// Losing the screen mid-transfer is not recoverable by touching it:
    /// `BluetoothLinkCentral` has no reconnect path — `didDiscover` is guarded
    /// on `peripheral == nil` and scanning has already stopped — so the instance
    /// is permanently dead and recovery means leaving and returning, which mints
    /// a new serviceID and a new code for the other person to scan again.
    ///
    /// The brightness half is deliberately not taken: this code has a real
    /// fallback in `chooseFile()`, unlike the credential screen's, whose QR is
    /// the only way its `linkServiceID` ever reaches anybody.
    private let wakeLock = AppScreenWakeLock.shared

    /// Holds the verdict card. See `show(status:detail:caveats:verdict:)`.
    private let verdictContainer = UIStackView()

    /// Offered once the radio is off, because from that moment the code on
    /// screen is an address nobody is listening at. See `retireTheCode()`.
    private let nextPersonButton = UIButton(type: .system)

    /// The arranged order of the waiting state, captured once.
    ///
    /// `liftTheVerdictAboveTheFold()` reorders in place and there is no other
    /// way back: this screen never pushes, pops or reloads.
    private var waitingOrder: [UIView] = []

    /// Holds the caveat group. Empty and hidden until there is a verdict, so
    /// the waiting screen does not carry a heading with nothing under it.
    private let caveatContainer = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Check a proof", comment: "")
        view.backgroundColor = .systemGroupedBackground
        configureLayout()
        // Said at load, not after the other phone has spent twenty seconds
        // sending 400 KB. `verdict: nil` throughout — this is a fact about this
        // device's setup and says nothing about anybody's proof.
        let ready = ZKVerifyingKeyAssets.areInstalled
        show(status: NSLocalizedString("No proof loaded yet", comment: ""),
             detail: ready || ZKProofRunAssembly.isSigningAvailable
                ? NSLocalizedString(
                    "A zero-knowledge proof is about 400 KB — far too large for a QR code, so it arrives over Bluetooth or as a file.",
                    comment: "")
                : NSLocalizedString(
                    "This version cannot download the files needed to check a proof, so a proof sent here cannot be checked. Say so before they send one.",
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
        // Same lifetime as the engagement, and counted rather than flagged, so
        // returning to this screen twice costs nothing. `isIdleTimerDisabled` is
        // process-global — see `ScreenWakeLock`.
        wakeLock.hold()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            stopLink()
            wakeLock.release()
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

        var nextConfig = UIButton.Configuration.filled()
        nextConfig.title = NSLocalizedString("Check the next person", comment: "")
        nextPersonButton.configuration = nextConfig
        nextPersonButton.accessibilityIdentifier = "zkverify.next"
        nextPersonButton.isHidden = true
        nextPersonButton.addTarget(self, action: #selector(checkNextPerson), for: .touchUpInside)

        verdictContainer.axis = .vertical
        verdictContainer.spacing = 12
        verdictContainer.isHidden = true
        verdictContainer.accessibilityIdentifier = "zkverify.verdict"

        caveatContainer.axis = .vertical
        caveatContainer.spacing = 12
        caveatContainer.isHidden = true
        caveatContainer.accessibilityIdentifier = "zkverify.caveats"

        view.addSubview(scroll)
        scroll.addSubview(stack)
        [codeContainer, codeCaptionLabel, linkLabel, nextPersonButton,
         chooseButton, spinner, verdictContainer, statusLabel, detailLabel,
         caveatContainer].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(8, after: codeContainer)
        waitingOrder = stack.arrangedSubviews

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

    // MARK: - Seams for the code/radio invariant
    //
    // Narrow on purpose: the pair below is the whole assertion, and it is the
    // one this screen's own comment claims cannot come apart.

    /// Whether a scanner is running for the identifier currently drawn.
    var radioIsListeningForReview: Bool { link != nil }

    /// Whether there is a pairing code on screen.
    var pairingCodeIsShownForReview: Bool { !codeImageView.isHidden }

    var nextPersonIsOfferedForReview: Bool { !nextPersonButton.isHidden }

    var verdictIsShownForReview: Bool { !verdictContainer.isHidden }

    func receiveForReview(_ state: BluetoothLinkState) { receiveOverLink(state) }

    func checkNextPersonForReview() { checkNextPerson() }

    private func show(status: String, detail: String, caveats: [String] = [], verdict: Bool?) {
        statusLabel.text = status
        detailLabel.text = detail
        // The status line stays `.label`, always.
        //
        // # Two defects, one cause: coloured text on a grouped background
        //
        // These three lines used to set `.systemGreen` / `.systemOrange` here.
        // Measured on the grouped background: **1.99:1 for green, 1.97:1 for
        // orange, and 1.01:1 against each other** — the same luminance. Only
        // light mode is broken, which is to say only a counter in daylight.
        //
        // Worse than the contrast: **orange meant "refused" on this screen and
        // "not a judgement about anybody" everywhere else in this app.** The
        // credential path spends a red ⛔️ on a real refusal and reserves orange
        // for 「沒有東西被查驗」, under a comment saying a state that is not bad
        // must not be drawn as a bad state. The home screen uses orange for an
        // expired card because a date is nobody's fault. So a 里長 who had just
        // learned red-means-refused, orange-means-my-phone-has-nothing would
        // read a refused proof as "this device could not answer" — which is a
        // *different state that exists on this very screen*, drawn in black.
        //
        // That is the mirror of the first audit's `a-3`: that one drew a
        // housekeeping state as an accusation, this one drew an accusation as
        // housekeeping — moving the fault off the proof and onto the device,
        // which is the flattering direction.
        //
        // ⚠️ The fix is a **new card beside** the status line, not a recolour of
        // it. `statusLabel` is shared: it also carries 「尚未載入證明」,
        // 「檢查中…」 and every `verdict: nil` error, `liftTheVerdictAboveTheFold`
        // reorders by its object identity, and `ZKVerifyUITests` asserts on
        // `zkverify.status`.
        statusLabel.textColor = .label
        renderVerdictCard(verdict)
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
    /// The verdict, in the same three-way vocabulary as the credential path.
    ///
    /// The symbol goes in the **label text**, not in an image: VoiceOver reads
    /// the text, and a verdict carried only by a coloured glyph is a verdict a
    /// blind checker does not get.
    private func renderVerdictCard(_ verdict: Bool?) {
        verdictContainer.arrangedSubviews.forEach {
            verdictContainer.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let verdict else {
            // `nil` is 「this device could not answer」, and it stays plain. It
            // is not a verdict, so it does not get a verdict card.
            verdictContainer.isHidden = true
            return
        }
        verdictContainer.isHidden = false
        verdictContainer.addArrangedSubview(verdict
            ? PresentationUI.verdict("✅", NSLocalizedString("This proof passed", comment: ""), .systemGreen)
            // Red, matching a refused presentation. The two refusals are the
            // same kind of answer and now look like it.
            : PresentationUI.verdict("⛔️", NSLocalizedString("This proof was refused", comment: ""), .systemRed))
    }

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
        for (index, view) in [verdictContainer, statusLabel, detailLabel, caveatContainer].enumerated()
        where stack.arrangedSubviews.contains(view) {
            stack.insertArrangedSubview(view, at: index)
        }
        announceTheVerdict()
    }

    /// The one notification this app has ever posted.
    ///
    /// # Fifteen seconds of silence, and then a silent answer
    ///
    /// `UIAccessibility.post` appeared **nowhere** in this app. iOS does not
    /// re-speak a `UILabel` whose `text` changed; the spinner is not an
    /// accessibility element, so starting and stopping it is silent; nothing is
    /// removed from the hierarchy when the first verdict lands, so the
    /// "focused element disappeared" recovery never fires; and this screen never
    /// pushes or pops, so there is no transition to ride on. The credential path
    /// is fine only by accident — it pushes a whole result view controller and
    /// UIKit announces that itself.
    ///
    /// Over Bluetooth it was worse: 21.7 measured seconds of transfer writing
    /// percentages into a label nobody hears, then fifteen more of checking.
    ///
    /// `.layoutChanged` rather than `.screenChanged`, because the screen was not
    /// replaced. The argument does two jobs at once: it speaks the verdict, and
    /// it parks the cursor on the verdict **before** `liftTheVerdictAboveTheFold`
    /// moves three views out from under it.
    private func announceTheVerdict() {
        let target: UIView = verdictContainer.isHidden
            ? statusLabel
            : (verdictContainer.arrangedSubviews.first ?? statusLabel)
        UIAccessibility.post(notification: .layoutChanged, argument: target)
    }

    /// Takes the pairing code down at the moment the radio goes off.
    ///
    /// # A code nobody is listening at, over the last person's verdict
    ///
    /// `.finished` calls `stopLink()` first thing, and `beginEngagement()` — the
    /// only thing that mints an identifier, draws a code and starts a scanner —
    /// had exactly one caller: `viewWillAppear`. Nothing re-opened it. The file
    /// picker is a sheet, so it does not trigger `viewWillAppear` either.
    ///
    /// So the second person in the queue scanned a code that was still on
    /// screen, their phone broadcast into a room with nobody listening
    /// (`BluetoothLink` has no advertising timeout), and they sat at 「ready —
    /// waiting for the checker's phone」 while the checker's screen did not
    /// change by one pixel: `liftTheVerdictAboveTheFold()` had just moved the
    /// *previous* person's green 「passed」 to the top, with 「received 389 KB over
    /// Bluetooth」 under it and no timestamp anywhere on the screen.
    ///
    /// This screen's own comments state both halves of the rule it was breaking:
    /// 「a code drawn without a scanner running is a code that does nothing when
    /// scanned … `engagement` exists so the two cannot drift」, and the reason
    /// the code is *not* hidden after a verdict, which is that a checker at a
    /// counter checks more than one person. Both are right. What was missing was
    /// the step in between: the way to the next person is a new engagement, not
    /// a stale code.
    ///
    /// So the code comes down with the radio, and comes back only when somebody
    /// asks for the next person — which also clears the verdict, because a live
    /// code and the previous person's answer must never be on screen together.
    private func retireTheCode() {
        engagement = nil
        codeImageView.image = nil
        codeImageView.isHidden = true
        codeCaptionLabel.text = NSLocalizedString(
            "The pairing code is down. This proof is being dealt with, so nobody else can send one until you ask for the next person.",
            comment: "")
        codeCaptionLabel.isHidden = false
        nextPersonButton.isHidden = false
    }

    @objc private func checkNextPerson() {
        // Everything about the last person goes before anything about the next
        // one arrives.
        nextPersonButton.isHidden = true
        show(status: NSLocalizedString("No proof loaded yet", comment: ""),
             detail: NSLocalizedString(
                "A zero-knowledge proof is about 400 KB — far too large for a QR code, so it arrives over Bluetooth or as a file.",
                comment: ""),
             verdict: nil)
        for (index, view) in waitingOrder.enumerated() where stack.arrangedSubviews.contains(view) {
            stack.insertArrangedSubview(view, at: index)
        }
        linkLabel.text = nil
        beginEngagement()
        UIAccessibility.post(notification: .screenChanged, argument: codeImageView)
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
        let link = BluetoothLinkCentral(serviceID: engagement.serviceID,
                                        vocabulary: .zeroKnowledgeProof) { [weak self] state in
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
            // And the code down with it. Both branches below are terminal for
            // the radio — including the one where the bytes arrived and could
            // not be decoded, which used to switch the radio off permanently
            // over a proof that was never judged at all.
            retireTheCode()
            linkLabel.text = String(format: NSLocalizedString("Received %@ over Bluetooth.", comment: ""),
                                    ZKStagePresentation.byteString(Int64(payload.count)))
            do {
                verify(package: try ZKProofPackage.decoded(from: payload))
            } catch {
                // Reassembled and digest-matched, and still not a package. Not a
                // failed check — we never got far enough to judge anything —
                // so this reports as unreadable rather than as a refusal.
                let outcome = Self.unreadable(error)
                show(status: outcome.status, detail: outcome.detail, verdict: nil)
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
            let outcome = Self.unreadable(error)
            show(status: outcome.status, detail: outcome.detail, verdict: nil)
        }
    }

    /// Turns a decoding failure into a sentence and, where it can, the right
    /// heading.
    ///
    /// # The heading was the actual defect
    ///
    /// Both call sites used to say "this file could not be read" and print
    /// `String(describing: error)` underneath — so `unsupportedVersion(3)`
    /// appeared verbatim beneath a Chinese sentence, and the sentence blamed the
    /// wrong party. A proof this app cannot read *because it is newer* is not a
    /// broken file: the person holding this phone needs to update, and the
    /// person who made the proof did nothing wrong. Telling a checker the other
    /// person's document is unreadable, when the fix is on the checker's side,
    /// is the same class of mistake as `a-6`'s clock accusation.
    private static func unreadable(_ error: Error) -> (status: String, detail: String) {
        if case ZKProofPackage.PackagingError.unsupportedVersion = error {
            return (NSLocalizedString("This app is too old to read this proof.", comment: ""),
                    error.localizedDescription)
        }
        return (NSLocalizedString("This proof file could not be read.", comment: ""),
                // `localizedDescription`, which `PackagingError` now provides.
                // Anything else that lands here at least gets its own
                // `LocalizedError` rather than its Swift type name.
                error.localizedDescription)
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
