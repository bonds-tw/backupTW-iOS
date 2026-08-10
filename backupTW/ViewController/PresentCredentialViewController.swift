//
//  PresentCredentialViewController.swift
//  backupTW
//

import UIKit

/// The holder's side of an offline check.
///
/// Three steps, in this order and not another: read the checker's request, show
/// the user what they are about to hand over and what it costs them, then sign
/// and display. The middle step is not a confirmation dialog for its own sake —
/// see below.
///
/// # ⚠️ Presenting is not free, and the user has to be told before, not after
///
/// This paragraph used to say the cost was a `did:key`: the public key written
/// out, the same string every time, so two checkers comparing notes could prove
/// they saw the same person. That was true when the device signed the credential.
/// It has not been true since the cardholder's 自然人憑證 started signing it, and
/// the paragraph did not change with the code.
///
/// What a card-signed presentation actually costs is larger and simpler. The
/// certificate that signed the credential travels with it, because a checker
/// cannot verify a signature without it, and that certificate is an X.509 whose
/// Subject CN **is** the cardholder's legal name — alongside a serial number and
/// an RSA public key, all stable across every presentation. So it is not that two
/// checkers can work out you are the same person. It is that every checker learns
/// who you are, and no switch on this screen changes that: X.509 has no selective
/// disclosure, the CA's signature covers the whole TBSCertificate, and a
/// certificate with the name removed does not verify. Closing this needs the
/// chain proved inside a circuit instead of sent — the ZK path.
///
/// So the sentence appears on the screen the user taps 「出示」 on, and `name` is
/// stated as a consequence rather than offered as a switch. Putting it on the
/// result, or in Settings, or in a footnote, would be a way of having said it
/// without anyone having read it; offering a switch that does not work would be
/// worse than either.
final class PresentCredentialViewController: UIViewController {

    private enum Stage {
        /// No credential on the device at all.
        case nothingToShow
        /// Waiting for the checker's request.
        case awaitingRequest
        /// Request in hand, not yet signed. `freshness` is judged once, when the
        /// code was read, because that is the question being answered: how long
        /// had this code been sitting there before the camera saw it.
        case confirming(PresentationRequest, freshness: RequestFreshness)
        /// Signed; these are the frames.
        case showing(frames: [String])
        /// Signing failed.
        case failed(String)
    }

    private let holder: HolderPresentation
    private var stage: Stage = .awaitingRequest

    /// The claims the holder has ticked. Starts empty on purpose — see
    /// `renderDisclosureChoices`.
    private var chosenClaims: Set<String> = []
    /// Rebuilt whenever the confirmation screen is drawn, so a stale set from a
    /// previous request cannot decide what this one discloses.
    private var disclosableClaims: [(name: String, value: String)] = []
    private var showButton: UIButton?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    /// Rendered once when the frames arrive. Re-rendering on every tick would
    /// run `CIQRCodeGenerator` twice a second for as long as the screen is up.
    private var renderedFrames: [UIImage] = []
    private var frameIndex = 0
    private var carousel: Timer?
    private let frameImageView = UIImageView()
    private let frameCountLabel = UILabel()

    /// Restored on the way out. Raised on the way in because a dim OLED panel at
    /// an angle is the single most common reason a screen-to-screen scan fails.
    private let brightness = ScreenBrightnessBoost(read: { UIScreen.main.brightness },
                                                   write: { UIScreen.main.brightness = $0 })

    /// Decides when the carousel runs and when the screen is raised. See
    /// `PresentationScreenLifecycle`.
    private var lifecycle = PresentationScreenLifecycle()

    init(holder: HolderPresentation = HolderPresentation(store: (try? CredentialStore()) ?? EmptyCredentialStore())) {
        self.holder = holder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Show my document", comment: "")
        view.backgroundColor = .systemGroupedBackground
        buildScaffold()

        // Asked once, here, rather than at the moment of signing: a user who has
        // erased everything should be told so before they are asked to point a
        // camera at a stranger's phone.
        if (try? holder.storedCredentialID()) == nil {
            stage = .nothingToShow
        }
        render()
    }

    /// Every appearance, not just the first.
    ///
    /// This screen's whole use is being held up in front of somebody else's
    /// camera, at arm's length, in one hand — which is exactly the grip that
    /// brushes the left edge. A swipe begun and released is a *cancelled* pop:
    /// `viewWillDisappear` has already stopped the carousel and put the screen
    /// back down, and without this the codes stay frozen on whichever one was up,
    /// 「第 2／3 張」 stays on the label, and the checker's collector waits for a
    /// frame that will never be shown again.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply(lifecycle.willAppear())
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        apply(lifecycle.willDisappear())
    }

    private func apply(_ effect: PresentationScreenLifecycle.Effect) {
        switch effect {
        case .nothing:
            break
        case .startShowing:
            brightness.raise()
            startCarousel()
        case .stopShowing:
            stopCarousel()
            brightness.restore()
        }
    }

    // MARK: - Scaffold

    private func buildScaffold() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20

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
    }

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch stage {
        case .nothingToShow:
            renderNothingToShow()
        case .awaitingRequest:
            renderAwaitingRequest()
        case .confirming(let request, let freshness):
            renderConfirmation(request, freshness)
        case .showing(let frames):
            renderFrames(frames)
        case .failed(let message):
            renderFailure(message)
        }
    }

    // MARK: - Stages

    private func renderNothingToShow() {
        contentStack.addArrangedSubview(PresentationUI.title(
            NSLocalizedString("No document to show yet", comment: "")))
        contentStack.addArrangedSubview(PresentationUI.body(
            NSLocalizedString("Create a valid document from the home screen first. Nothing can be shown until this device holds one.", comment: "")))
    }

    private func renderAwaitingRequest() {
        contentStack.addArrangedSubview(PresentationUI.title(
            NSLocalizedString("Scan the checker's code", comment: "")))
        contentStack.addArrangedSubview(PresentationUI.body(
            NSLocalizedString("The checker shows a code first. It carries a one-time number that your document has to answer, which is what stops an old screenshot being reused.", comment: "")))
        contentStack.addArrangedSubview(linkabilityWarning())

        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("Scan the checker's code", comment: "")
        configuration.image = UIImage(systemName: "qrcode.viewfinder")
        configuration.imagePadding = 8
        configuration.buttonSize = .large
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.addTarget(self, action: #selector(scanRequest), for: .touchUpInside)
        contentStack.addArrangedSubview(button)
    }

    private func renderConfirmation(_ request: PresentationRequest, _ freshness: RequestFreshness) {
        contentStack.addArrangedSubview(PresentationUI.title(
            NSLocalizedString("Show your document?", comment: "")))

        // Above the reason, not below it. The reason is the checker's own words
        // and is the most persuasive thing on this screen — 「內政部查驗」 reads
        // like authority even though nothing here can confirm it — so the
        // sentence saying this code may not have come from anybody standing in
        // front of you has to be read first, or it will not be read.
        if let warning = Self.stalenessWarning(for: freshness) {
            contentStack.addArrangedSubview(PresentationUI.verdict("⚠️", warning.title, .systemOrange))
            contentStack.addArrangedSubview(PresentationUI.card(body: warning.detail))
        }

        contentStack.addArrangedSubview(PresentationUI.card(
            title: NSLocalizedString("Reason the checker gave", comment: ""),
            body: request.purpose))
        // `purpose` is free text typed by whoever is holding the other phone, and
        // `PresentationRequest` strips the bidirectional overrides that would let
        // it reorder the app's own words around it. What it cannot do is make the
        // claim true, so the screen says who wrote it.
        contentStack.addArrangedSubview(PresentationUI.footnote(
            NSLocalizedString("This wording was written by the checker. This app cannot confirm who they are.", comment: "")))

        renderDisclosureChoices()
        contentStack.addArrangedSubview(linkabilityWarning())

        var configuration = UIButton.Configuration.filled()
        configuration.buttonSize = .large
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.addTarget(self, action: #selector(confirmPresentation), for: .touchUpInside)
        contentStack.addArrangedSubview(button)
        showButton = button
        updateShowButtonTitle()

        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = NSLocalizedString("Cancel", comment: "")
        let cancel = UIButton(type: .system)
        cancel.configuration = cancelConfiguration
        cancel.addTarget(self, action: #selector(cancelPresentation), for: .touchUpInside)
        contentStack.addArrangedSubview(cancel)
    }

    /// One switch per claim the document can withhold.
    ///
    /// # Everything starts off
    ///
    /// The default is to disclose nothing, and that is a decision rather than an
    /// oversight. A pre-ticked list is a list nobody reads: the holder taps
    /// through and hands over a national ID number because it was already
    /// selected, which is the outcome an app called 最小揭露 exists to prevent.
    /// Starting empty makes every field an act, and the button says how many
    /// acts have been taken so a holder cannot show more than they meant to
    /// without seeing the number change.
    ///
    /// A credential issued before selective disclosure has nothing to choose
    /// from, and says so — an empty list would read as "nothing will be shown"
    /// when in fact everything will be.
    private func renderDisclosureChoices() {
        disclosableClaims = (try? holder.disclosableClaims()) ?? []
        chosenClaims = []

        contentStack.addArrangedSubview(PresentationUI.sectionTitle(
            NSLocalizedString("Choose what they will see", comment: "")))

        guard !disclosableClaims.isEmpty else {
            contentStack.addArrangedSubview(PresentationUI.caveat(
                NSLocalizedString("This document was created by an older version of the app and cannot be shown in part. Every field in it will be shown: name, ID number, date of birth, household address and nationality.", comment: "")))
            return
        }

        contentStack.addArrangedSubview(PresentationUI.body(
            NSLocalizedString("Nothing is selected to begin with. Whatever you leave off is not sent — the checker sees only that some fields were held back, not what they were.", comment: "")))

        // The sentence above was false for one field, and the switch that made it
        // false has been taken away rather than left as a choice that does
        // nothing.
        //
        // A card-signed credential travels with the certificate that signed it,
        // because the checker cannot verify the signature without it — and that
        // certificate is an X.509 whose Subject CN *is* the cardholder's legal
        // name (measured: the name sits at byte 76 of the DER this app's own test
        // fixture carries). `MOICASignedCredential` refuses a certificate with no
        // CN, so there is no card-signed presentation that omits it.
        //
        // Nothing here can change that. X.509 has no selective disclosure: the
        // CA's signature covers the whole TBSCertificate, so removing the CN
        // breaks verification. Not drawing the name would change what this app
        // *displays*, not what leaves the device — and the bytes are going to
        // somebody else's program.
        //
        // So the name is stated as a consequence of showing the document at all,
        // in the same place the holder is choosing. A switch that reads
        // 「不給姓名」 and then gives the name is worse than no switch.
        let alwaysVisible = disclosableClaims.filter { Self.cannotBeWithheld.contains($0.name) }
        for claim in disclosableClaims where !Self.cannotBeWithheld.contains(claim.name) {
            contentStack.addArrangedSubview(disclosureRow(for: claim))
        }
        for claim in alwaysVisible {
            contentStack.addArrangedSubview(PresentationUI.caveat(
                String(format: NSLocalizedString("%1$@ (%2$@) is shown either way. It is written into the certificate that signs this document, and the checker needs that certificate to check the signature.",
                                                 comment: "A field the holder cannot withhold"),
                       StoredNationalID.label(for: claim.name), claim.value)))
        }
    }

    /// Claims the holder is not offered a choice about, because the choice would
    /// not be honoured.
    ///
    /// Exactly one, and it is not a policy — it is a fact about where the value
    /// is. See `renderDisclosureChoices`.
    static let cannotBeWithheld: Set<String> = ["name"]

    /// What actually gets disclosed, given what the holder ticked.
    ///
    /// Separated from the screen so it can be tested, because the interesting
    /// case is the one a screen test would not reach: the holder ticks nothing,
    /// and `name` goes anyway. Returning `nil` means "everything", which is what
    /// a credential with nothing to withhold does — an older credential with no
    /// `_sd` commitments cannot be shown in part at all.
    ///
    /// The unwithholdable claims are **added**, never subtracted. Withholding
    /// `name` never hid it — the certificate carries it — but it did cost the
    /// checker the CN-to-`name` comparison that `MOICASignedCredential.verify`
    /// only performs when the claim is disclosed. So disclosing it buys a binding
    /// check for a value that was leaving regardless.
    static func claimsToDisclose(chosen: Set<String>, offered: [String]) -> [String]? {
        guard !offered.isEmpty else { return nil }
        let forced = offered.filter(cannotBeWithheld.contains)
        return Array(chosen.union(forced)).sorted()
    }

    private func disclosureRow(for claim: (name: String, value: String)) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12

        let label = UILabel()
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        // The app's own noun first, then the holder's own value quoted after it.
        // This is the holder's screen and the value is their own record, so it is
        // shown in full — the sanitising `UntrustedText` does is for a stranger's
        // bytes on the verifier's screen, not for a person reading their own
        // document back.
        let title = NSMutableAttributedString(
            string: StoredNationalID.label(for: claim.name),
            attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)])
        title.append(NSAttributedString(
            string: "\n" + claim.value,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline),
                         .foregroundColor: UIColor.secondaryLabel]))
        label.attributedText = title

        let toggle = UISwitch()
        toggle.isOn = false
        toggle.accessibilityLabel = StoredNationalID.label(for: claim.name)
        toggle.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            if toggle.isOn { self.chosenClaims.insert(claim.name) }
            else { self.chosenClaims.remove(claim.name) }
            self.updateShowButtonTitle()
        }, for: .valueChanged)

        row.addArrangedSubview(label)
        row.addArrangedSubview(toggle)
        return row
    }

    /// The count is on the button because that is the last thing read before the
    /// tap. A holder who ticked one more field than they meant to sees it here.
    private func updateShowButtonTitle() {
        guard let showButton else { return }
        var configuration = showButton.configuration ?? UIButton.Configuration.filled()
        configuration.title = disclosableClaims.isEmpty
            ? NSLocalizedString("Show my document", comment: "")
            : String(format: NSLocalizedString("Show %d field(s)", comment: ""), chosenClaims.count)
        showButton.configuration = configuration
    }

    private func renderFrames(_ frames: [String]) {
        // Rasterised before a single view is built, so the failure path replaces
        // this screen instead of re-entering `render()` from halfway through it.
        // 1024 device pixels over an 89-module code is 11 whole pixels per
        // module; `qrCode` floors to an integer for the reason its own
        // documentation gives.
        renderedFrames = frames.compactMap { frame in
            guard let code = try? QRTransport.qrCode(for: frame, fittingPixelWidth: 1024) else { return nil }
            return UIImage(cgImage: code.image)
        }
        guard renderedFrames.count == frames.count, !renderedFrames.isEmpty else {
            // Emptied rather than left holding a partial set: `renderedFrames` is
            // what `startCarousel` and the lifecycle both read to decide whether
            // there is anything on screen to rotate.
            renderedFrames = []
            let message = NSLocalizedString("This document could not be turned into a code on this device.",
                                            comment: "")
            stage = .failed(message)
            renderFailure(message)
            return
        }

        contentStack.addArrangedSubview(PresentationUI.title(
            NSLocalizedString("Hold this up to the checker", comment: "")))

        frameImageView.translatesAutoresizingMaskIntoConstraints = false
        frameImageView.contentMode = .scaleAspectFit
        frameImageView.backgroundColor = .white
        frameImageView.layer.magnificationFilter = .nearest
        frameImageView.layer.minificationFilter = .nearest
        frameImageView.isAccessibilityElement = true
        frameImageView.accessibilityLabel = NSLocalizedString("Document code", comment: "")

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(frameImageView)
        NSLayoutConstraint.activate([
            frameImageView.topAnchor.constraint(equalTo: container.topAnchor),
            frameImageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            frameImageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            frameImageView.widthAnchor.constraint(equalTo: frameImageView.heightAnchor),
            frameImageView.heightAnchor.constraint(equalToConstant: 300),
            frameImageView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
        ])
        contentStack.addArrangedSubview(container)

        frameCountLabel.numberOfLines = 0
        frameCountLabel.textAlignment = .center
        frameCountLabel.font = .preferredFont(forTextStyle: .headline)
        frameCountLabel.adjustsFontForContentSizeCategory = true
        contentStack.addArrangedSubview(frameCountLabel)

        if frames.count > 1 {
            // The count is stated rather than left to be inferred from a
            // flickering image. A checker who does not know there are three
            // codes stops after the first and reports a broken document.
            contentStack.addArrangedSubview(PresentationUI.body(String(
                format: NSLocalizedString("This document does not fit in one code, so it cycles through %d. Keep the screen still until the checker's phone says it has them all; the order does not matter.", comment: ""),
                frames.count)))
        }
        contentStack.addArrangedSubview(PresentationUI.footnote(
            NSLocalizedString("This code stops being accepted about five minutes after it was made.", comment: "")))
        contentStack.addArrangedSubview(linkabilityWarning())

        #if DEBUG
        // Counterpart of the verifier screen's paste button: copies every frame,
        // one per line, so a simulator with no camera can act as the checker.
        // The payload is the holder's own presentation — data they are at this
        // moment holding up on screen for a stranger to scan — so copying it
        // discloses nothing the QR carousel is not already disclosing.
        // Deliberately unlocalized; development affordances stay out of the
        // string catalog.
        let copyButton = UIButton(type: .system)
        var copyConfiguration = UIButton.Configuration.gray()
        copyConfiguration.title = "複製出示內容（開發用）"
        copyConfiguration.image = UIImage(systemName: "doc.on.doc")
        copyConfiguration.imagePadding = 8
        copyButton.configuration = copyConfiguration
        copyButton.addAction(UIAction { _ in
            UIPasteboard.general.string = frames.joined(separator: "\n")
        }, for: .touchUpInside)
        contentStack.addArrangedSubview(copyButton)
        #endif
        // The carousel is *not* started here. Rendering happens once; running is
        // a function of whether this screen is in front of the user, which can
        // change any number of times afterwards.
    }

    private func renderFailure(_ message: String) {
        contentStack.addArrangedSubview(PresentationUI.verdict("⚠️",
            NSLocalizedString("This document could not be shown", comment: ""), .systemOrange))
        contentStack.addArrangedSubview(PresentationUI.card(body: message))
    }

    /// What every presentation gives away regardless of the switches above.
    ///
    /// This used to say the document 「reveals the same identifier」 and that
    /// different checkers 「can compare notes and tell it was you both times」.
    /// That sentence was written when the credential was signed by the device and
    /// the only stable thing in it was a `did:key`; it survived the change to
    /// card signing unedited, and by then it was describing the wrong problem in
    /// the wrong register.
    ///
    /// Linkability is 「two shops can work out you are the same person」. What
    /// actually leaves the device is the cardholder's certificate: legal name,
    /// certificate serial number, RSA public key. Every checker learns who you
    /// are outright — no comparing of notes required. That is a difference in
    /// kind, and describing it with the abstract word is the failure this project
    /// names in `verifierNotAuthenticated`: giving somebody a term instead of a
    /// fact they can act on.
    private func linkabilityWarning() -> UIView {
        PresentationUI.caveat(NSLocalizedString(
            "Showing this document always reveals your name, because it is written into the certificate that signs it. The same certificate goes to every checker, so any two of them can tell it was the same person.", comment: ""))
    }

    // MARK: - How old the checker's code is

    /// What `PresentationRequest.createdAt` says about the code that was just
    /// scanned.
    ///
    /// The field's own documentation says it is there 「so the holder can be shown
    /// a request that is obviously stale」, and nothing read it. The difference
    /// that made is the difference between a checker standing in front of you and
    /// a QR code taped to a shop door or photographed three weeks ago: on this
    /// screen those two were identical, down to the pixel.
    ///
    /// # A warning, never a refusal
    ///
    /// `createdAt` is unauthenticated — whoever prints the code chooses what it
    /// says — so this catches the honest case and not a forger. That is still
    /// worth having, because the honest case is the common one: a laminated code
    /// on a counter, a screenshot passed around a LINE group. Refusing on it would
    /// meanwhile turn a wrong clock into a person being unable to show their ID,
    /// which is the failure this app cannot afford.
    enum RequestFreshness: Equatable {
        case fresh
        /// Older than any request this app's own verifier would still honour.
        case stale(age: TimeInterval)
        /// Dated further ahead than the clock budget allows, so its real age is
        /// not knowable from here at all.
        case datedInTheFuture(skew: TimeInterval)
    }

    /// Older than this and the holder is told.
    ///
    /// Derived rather than picked. `VerifierSession` drops its own pending
    /// request after `pendingRequestLifetime`, so a request older than that
    /// cannot be answered successfully anyway; warning any sooner would mean
    /// warning about codes that would have worked. `OfflineVerifier.maximumClockSkew`
    /// is added because the two devices' clocks are compared here, and it is the
    /// disagreement this app already decided to tolerate elsewhere — without it,
    /// a holder whose phone runs three minutes fast would be shown a fraud
    /// warning at every counter.
    static let staleRequestThreshold: TimeInterval =
        VerifierSession.pendingRequestLifetime + OfflineVerifier.maximumClockSkew

    static func freshness(of request: PresentationRequest, now: Date) -> RequestFreshness {
        let age = now.timeIntervalSince(request.createdAt)
        if age > staleRequestThreshold { return .stale(age: age) }
        // Symmetric with `OfflineVerifier.presentationDatedInTheFuture`: nobody
        // mints a request ahead of time, so this can only be clock error — but it
        // is clock error that makes the staleness test above meaningless, and
        // saying nothing would leave the holder believing a check was run.
        if -age > OfflineVerifier.maximumClockSkew { return .datedInTheFuture(skew: -age) }
        return .fresh
    }

    /// The two sentences a warned holder sees, or `nil` when there is nothing to
    /// say. Separated from the views so the rule and its wording can be asserted
    /// without building a view hierarchy.
    static func stalenessWarning(for freshness: RequestFreshness) -> (title: String, detail: String)? {
        switch freshness {
        case .fresh:
            return nil
        case .stale(let age):
            return (NSLocalizedString("This code was not made just now", comment: ""),
                    String(format: NSLocalizedString("It was made %@ ago. A code taped to a wall or kept in a photograph looks exactly like a checker standing in front of you. Ask them to show a new one.", comment: ""),
                           durationText(age)))
        case .datedInTheFuture(let skew):
            return (NSLocalizedString("This code is dated ahead of your phone's clock", comment: ""),
                    String(format: NSLocalizedString("It claims to have been made %@ from now, so this phone cannot tell how old it really is. One of the two clocks is wrong.", comment: ""),
                           durationText(skew)))
        }
    }

    /// A fresh formatter per call: `DateComponentsFormatter` is a reference type
    /// with mutable options, and this is the same reason `OfflineVerifier` builds
    /// its `ISO8601DateFormatter` per call.
    ///
    /// Floored at a minute because both callers are already past a multi-minute
    /// threshold, and 「0 分鐘前」 would read as "just now" — the exact opposite of
    /// what this sentence is for.
    private static func durationText(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(interval, 60)) ?? ""
    }

    // MARK: - Steps

    @objc private func scanRequest() {
        let scanner = QRScanningViewController(
            title: NSLocalizedString("Scan the checker's code", comment: ""),
            prompt: NSLocalizedString("Point the camera at the checker's screen.", comment: "")
        ) { [weak self] scanned in
            guard let self else { return .stop }
            return self.acceptScannedRequest(scanned)
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

    /// What the scanner's callback does with one string, lifted out of the
    /// closure so the freshness rule can be driven by a test without a camera.
    ///
    /// - Parameter now: the holder's clock, injected for the same reason
    ///   `HolderPresentation.frames` injects one — a rule about time that can
    ///   only be exercised by waiting is a rule with no test.
    @discardableResult
    func acceptScannedRequest(_ scanned: String, now: Date = Date()) -> QRScanningViewController.Decision {
        guard let request = try? PresentationRequest.decode(scanned) else {
            // Any other QR code in the viewfinder, and there will be many.
            // Silence rather than an error per video frame.
            return .keepScanning(status: nil)
        }
        stage = .confirming(request, freshness: Self.freshness(of: request, now: now))
        render()
        navigationController?.popToViewController(self, animated: true)
        return .stop
    }

    @objc private func cancelPresentation() {
        apply(lifecycle.clearFrames())
        renderedFrames = []
        stage = .awaitingRequest
        render()
    }

    @objc private func confirmPresentation(_ sender: UIButton) {
        // Two guards for one tap, and both earn their place. `beginSigning` is
        // the one that holds: the work below is asynchronous, so a second tap
        // that lands in the same run loop turn as the first sees a `stage` that
        // is still `.confirming` and would sign, shard and display a second time
        // — a second Face ID prompt, and a second `startShowing`.
        guard case .confirming(let request, _) = stage, lifecycle.beginSigning() else { return }
        // Disabling the button is what the user sees. It cannot be relied on
        // alone: both taps of a fast double tap can be delivered before UIKit
        // redraws.
        sender.isEnabled = false

        // Signing is a Keychain round trip — a Secure Enclave one on a real
        // phone — and the deflate-and-shard pass runs over a few kilobytes. Both
        // are fast on a good day and both are exactly the calls that stall for a
        // second on a bad one, with a person waiting at a counter.
        // Read on the main thread, before the hop: `chosenClaims` is UI state and
        // a switch flipped mid-signing must not change what was signed.
        //
        // The unwithholdable claims are added back in rather than left out, and
        // that direction is deliberate. Withholding `name` never hid it — the
        // certificate carries it regardless — but it *did* cost something:
        // `MOICASignedCredential.verify` only compares the certificate's CN
        // against the credential's own `name` when that claim was disclosed, so a
        // withheld name meant the checker was shown a name with nothing
        // confirming it belonged to this document. Disclosing it buys the
        // binding check for a value the checker was going to see anyway.
        let disclosing: [String]? = Self.claimsToDisclose(chosen: chosenClaims,
                                                          offered: disclosableClaims.map(\.name))

        DispatchQueue.global(qos: .userInitiated).async { [weak self, holder = self.holder] in
            let result = Result { try holder.frames(answering: request, disclosing: disclosing) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let frames):
                    self.stage = .showing(frames: frames)
                case .failure(let error):
                    self.stage = .failed((error as? LocalizedError)?.errorDescription
                                         ?? NSLocalizedString("This document could not be signed on this device.", comment: ""))
                }
                self.render()
                // Asked of `renderedFrames` rather than of `stage`: rasterising
                // can fail after signing succeeded, and then there is nothing to
                // rotate and no reason to hold the screen at full brightness.
                self.apply(self.lifecycle.finishSigning(producedFrames: !self.renderedFrames.isEmpty))
            }
        }
    }

    // MARK: - Carousel

    /// Starts the rotation over the images `renderFrames` already rasterised.
    /// Restarting an already-running carousel is safe: the old timer is dropped
    /// first, and the sequence begins again from the first code.
    private func startCarousel() {
        stopCarousel()
        frameIndex = 0
        guard !renderedFrames.isEmpty else { return }

        showFrame(0)
        guard renderedFrames.count > 1 else { return }

        // 0.55 s per frame: slow enough that a camera at 30 fps gets a dozen
        // clean looks at each code. This comment used to finish "fast enough that
        // a three-frame cycle completes in under two seconds", which was true of
        // the device-signed payload and has not been true since the card started
        // signing — a card-signed presentation is about fourteen frames, so a full
        // cycle is nearer eight seconds and a scanner that misses one waits for
        // the next pass. `PresentationFrameCountTests` measures both.
        //
        // `.common` mode so the carousel keeps running while the user scrolls this
        // screen — a carousel that stops mid-scan looks like a crash.
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.showFrame((self.frameIndex + 1) % self.renderedFrames.count)
        }
        RunLoop.main.add(timer, forMode: .common)
        carousel = timer
    }

    private func showFrame(_ index: Int) {
        frameIndex = index
        frameImageView.image = renderedFrames[index]
        frameCountLabel.text = renderedFrames.count > 1
            ? String(format: NSLocalizedString("Code %1$d of %2$d", comment: "Carousel position"),
                     index + 1, renderedFrames.count)
            : nil
        frameCountLabel.isHidden = renderedFrames.count <= 1
    }

    private func stopCarousel() {
        carousel?.invalidate()
        carousel = nil
    }
}

// MARK: - Lifecycle

/// When the codes rotate and when the screen is turned up, as a value with no
/// `UIViewController` and no `Timer` in it.
///
/// All three of its rules are about *order*, which is why they are here rather
/// than spread across four callbacks: a screen that came back after a cancelled
/// swipe, a second tap that landed while the first was still in the Secure
/// Enclave, and a departure while the codes are up. None of the three is visible
/// in a screenshot, and the first two produce a screen that looks entirely
/// normal — a still QR code with a caption under it — while being useless to the
/// checker pointing a camera at it.
struct PresentationScreenLifecycle: Equatable {

    enum Effect: Equatable {
        case nothing
        /// Rotate the codes and turn the screen up.
        case startShowing
        /// Stop rotating and put the screen back where the user had it.
        case stopShowing
    }

    private(set) var isVisible = false
    /// Whether there are rasterised codes to rotate.
    private(set) var hasFrames = false
    /// Whether a signature is in flight.
    private(set) var isSigning = false

    mutating func willAppear() -> Effect {
        guard !isVisible else { return .nothing }
        isVisible = true
        return hasFrames ? .startShowing : .nothing
    }

    mutating func willDisappear() -> Effect {
        guard isVisible else { return .nothing }
        isVisible = false
        // Unconditional: the screen has to go back down even in the states where
        // there is no carousel to stop, and stopping one that is not running is
        // free.
        return .stopShowing
    }

    /// The confirm button was tapped. `false` means a signature is already in
    /// flight — the second half of a double tap — and the caller must do nothing
    /// at all, not even start a second Keychain round trip.
    mutating func beginSigning() -> Bool {
        guard !isSigning else { return false }
        isSigning = true
        return true
    }

    /// Signing finished. `producedFrames` is `false` when it failed, or when it
    /// succeeded and the codes could not be rasterised.
    mutating func finishSigning(producedFrames: Bool) -> Effect {
        isSigning = false
        hasFrames = producedFrames
        return producedFrames && isVisible ? .startShowing : .nothing
    }

    /// The codes are gone — the user backed out of the confirmation, or is
    /// starting a new request.
    mutating func clearFrames() -> Effect {
        guard hasFrames else { return .nothing }
        hasFrames = false
        return .stopShowing
    }
}

/// Turns the screen up for a screen-to-screen scan and puts it back exactly
/// where the user had it.
///
/// A type rather than two lines inline, because the failure it exists to prevent
/// is silent and permanent. Raising twice without an intervening restore records
/// the *already raised* level as "what it was before", and from then on there is
/// no record anywhere on the device of what the user had chosen. They leave the
/// screen and their phone is at full brightness, in a blackout, on a battery
/// they may not be able to charge — which is the setting this whole app is for.
///
/// Reads and writes go through injected closures so the sequence can be tested
/// without a screen. `UIScreen.main.brightness` is a device-wide setting: a test
/// that drove the real one would change the machine it runs on.
final class ScreenBrightnessBoost {

    private let read: () -> CGFloat
    private let write: (CGFloat) -> Void
    private let level: CGFloat

    /// The user's own level, held only for as long as it is overridden. `nil` is
    /// the load-bearing state: it means "we are not holding anything of theirs".
    private var saved: CGFloat?

    var isRaised: Bool { saved != nil }

    init(level: CGFloat = 1.0,
         read: @escaping () -> CGFloat,
         write: @escaping (CGFloat) -> Void) {
        self.level = level
        self.read = read
        self.write = write
    }

    /// Second and subsequent calls do nothing — in particular they do not
    /// re-read the current level, which is the whole point.
    func raise() {
        guard saved == nil else { return }
        saved = read()
        write(level)
    }

    func restore() {
        guard let saved else { return }
        write(saved)
        self.saved = nil
    }
}

/// Stands in when `CredentialStore` cannot be constructed at all.
///
/// That happens when Application Support is unwritable or the backup exclusion
/// cannot be set — states in which the store deliberately refuses to exist
/// rather than quietly syncing an identity credential to iCloud. The screen then
/// reports "no document", which is the truthful answer: there is none this device
/// can reach. Writes throw so nothing can be created down this path either.
struct EmptyCredentialStore: CredentialStoring {
    func save(jws: String, id: String) throws { throw CredentialStoreError.invalidIdentifier }
    func load(id: String) throws -> String? { nil }
    func allIDs() throws -> [String] { [] }
    func deleteAll() throws {}
}
