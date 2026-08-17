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
        /// The store itself would not open, so what this phone holds is unknown.
        ///
        /// # Not the same screen as "you have nothing"
        ///
        /// `CredentialStore.init` gates on two *write*-side actions —
        /// `createDirectory` and the iCloud-exclusion `setResourceValues`. So an
        /// intact, readable document becomes 「there is nothing on this phone」
        /// because a backup-exclusion xattr could not be written.
        ///
        /// The store's own next layer refuses exactly this substitution: 「only a
        /// file that really is absent becomes nil. Anything else is thrown,
        /// because reporting that as 『you have no document』 **sends somebody to
        /// apply again for one they already have**.」 `CardInventory` says the
        /// same: reading decides what a row *says*, never whether it exists.
        /// Both disciplines were bypassed one level up by `try?`.
        ///
        /// And the route the old screen recommended was guaranteed to fail:
        /// issuance saves through the same constructor. So the advice cost a
        /// second 戶籍謄本 and a second 身分證統一編號 for a certain failure.
        case cardsUnreadable
        /// Waiting for the checker's request.
        case awaitingRequest
        /// Request in hand, not yet signed. `freshness` is judged once, when the
        /// code was read, because that is the question being answered: how long
        /// had this code been sitting there before the camera saw it.
        case confirming(PresentationRequest, freshness: RequestFreshness)
        /// Signed; these are the frames.
        case showing(frames: [String], request: PresentationRequest)
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
    /// Filled in step with the carousel, so the eye has somewhere to see 「it is
    /// moving forward」 that is not a two-digit number.
    private let frameProgress = UIProgressView(progressViewStyle: .default)
    /// Alive only while the frames are on screen. Torn down in `stopCarousel`
    /// together with everything else that makes this phone discoverable — a
    /// peripheral that outlived the screen would keep advertising after the
    /// holder had put the phone away.
    private var link: BluetoothLinkPeripheral?
    private let linkLabel = UILabel()
    /// The signed presentation itself, kept so the radio sends the document
    /// rather than the QR frames of it — the two transports carry the same
    /// bytes, framed for different media.
    private var presentationPayload: Data?

    /// The service identifier the checker offered, kept past the frame render.
    ///
    /// # Why the peripheral needed an address it could come back to
    ///
    /// The radio was only ever started inside `renderFrames`, and `render()` has
    /// four call sites, none of them on the appearance path. So a back gesture
    /// begun and released — the exact grip this screen is held in, one hand, arm
    /// extended, in front of somebody else's camera — ran `viewWillDisappear`
    /// then `viewWillAppear`: the carousel restarted from frame 0 and the
    /// brightness came back, while `CBPeripheralManager` had been released and
    /// **was never rebuilt**.
    ///
    /// `BluetoothLink.stop()` posts no state, so `linkLabel` froze on whatever it
    /// last said — 「已可透過藍牙被搜尋到…」 or 「透過藍牙傳送… N%」. The holder was
    /// told the transfer was still going. The checker, if already connected, was
    /// told it ended early; if not yet connected, `didDisconnectPeripheral` says
    /// nothing at all because `collector.progress` is nil, so they scanned a
    /// silent screen to the end.
    ///
    /// This screen's own comment lists what a cancelled back gesture breaks —
    /// frozen codes, a stale 「第 2／3 張」, a waiting collector. The radio was not
    /// on that list. Now its lifetime is the same `.startShowing`/`.stopShowing`
    /// pair as the brightness and the carousel, which is what the comment on
    /// `stopLink()` already said the wanted lifetime was.
    private var linkServiceID: UUID?
    /// One place for the carousel pace. The cycle-time sentence above and the
    /// timer below must never quote two different speeds.
    private static let frameInterval: TimeInterval = 0.55

    /// The pace, given the reader's own setting.
    ///
    /// A function rather than a second constant so that everything which quotes
    /// a duration — the 「約 N 秒」 sentence included — asks the same question
    /// and cannot answer it differently.
    static func frameInterval(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? frameInterval * 2 : frameInterval
    }

    /// The pause control. Built once; its title tracks the state.
    private let pauseButton = UIButton(type: .system)

    /// Which codes have been on screen at least once this showing. See
    /// `showFrame`.
    private var shownFrames: Set<Int> = []

    /// Set by the pause control. The timer keeps running and does nothing, so
    /// resuming does not have to rebuild it — and a paused carousel still holds
    /// the last code up, which is the one a scanner might still catch.
    private var isCarouselPaused = false

    /// Restored on the way out. Raised on the way in because a dim OLED panel at
    /// an angle is the single most common reason a screen-to-screen scan fails.
    /// Shared, so that a screen leaving cannot switch Auto-Lock back on
    /// underneath a screen arriving. See `ScreenWakeLock`.
    private let wakeLock = AppScreenWakeLock.shared

    private let brightness = ScreenBrightnessBoost(read: { UIScreen.main.brightness },
                                                   write: { UIScreen.main.brightness = $0 })

    /// Decides when the carousel runs and when the screen is raised. See
    /// `PresentationScreenLifecycle`.
    private var lifecycle = PresentationScreenLifecycle()

    /// Whether the store opened. `false` is a different screen from "empty".
    private let storeIsReadable: Bool

    init(holder: HolderPresentation, storeIsReadable: Bool = true) {
        self.holder = holder
        self.storeIsReadable = storeIsReadable
        super.init(nibName: nil, bundle: nil)
    }

    /// Opens the store **once** and keeps both facts: what it holds, and whether
    /// it opened at all. The `?? EmptyCredentialStore()` that used to be inline
    /// threw the second one away at the moment it was known.
    convenience init() {
        let store = try? CredentialStore()
        self.init(holder: HolderPresentation(store: store ?? EmptyCredentialStore()),
                  storeIsReadable: store != nil)
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
        if !storeIsReadable {
            stage = .cardsUnreadable
        } else if (try? holder.storedCredentialID()) == nil {
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
            // Next to the brightness boost because it is the other half of the
            // same problem: this screen raises the brightness so a checker can
            // scan it, and then the system dims and locks the phone because
            // nobody has touched it. Low Power Mode forces Auto-Lock to 30
            // seconds and does not let the owner change it, so this is not a
            // preference the holder could have set differently.
            wakeLock.hold()
            startCarousel()
            // Third, and for the same reason as the other two: this runs on
            // every appearance, including the one after a cancelled swipe.
            startLinkIfPossible()
        case .stopShowing:
            stopCarousel()
            stopLink()
            brightness.restore()
            wakeLock.release()
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
        case .cardsUnreadable:
            renderCardsUnreadable()
        case .awaitingRequest:
            renderAwaitingRequest()
        case .confirming(let request, let freshness):
            renderConfirmation(request, freshness)
        case .showing(let frames, let request):
            renderFrames(frames, request: request)
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

    /// A fact about this phone, and deliberately no route that costs identity
    /// data again.
    ///
    /// 「Create a new one」 is the one instruction that would make somebody hand
    /// over a 戶籍謄本 and a 身分證統一編號 a second time — into a save path that
    /// uses the same constructor that has just failed. This app already knows the
    /// right answer and has a row for it in Settings → Diagnostics
    /// (`SelfCheck` 「儲存空間無法使用」); it was only the home screen that had no
    /// way to point at it.
    private func renderCardsUnreadable() {
        contentStack.addArrangedSubview(PresentationUI.title(
            NSLocalizedString("This phone's cards cannot be read right now", comment: "")))
        contentStack.addArrangedSubview(PresentationUI.body(
            NSLocalizedString("This is about this phone's storage, not about your documents — anything saved here is still saved. This most often means the phone is out of space. Free some up, then open this screen again. Settings ▸ Diagnostics says which check failed.", comment: "")))
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
        // One pass, in the document's own order. The unwithholdable claim used
        // to be pulled out of the list and appended at the bottom as a warning
        // pill — which made a neutral fact read like an error, and put 「姓名」
        // in a different place from every other field. It is a row like the
        // others; what differs is the trailing control, and that difference is
        // the whole message.
        var explainedTheLockedRow = false
        for claim in disclosableClaims {
            if Self.cannotBeWithheld.contains(claim.name) {
                contentStack.addArrangedSubview(nonWithholdableRow(for: claim))
                explainedTheLockedRow = true
            } else {
                contentStack.addArrangedSubview(disclosureRow(for: claim))
            }
        }
        if explainedTheLockedRow {
            contentStack.addArrangedSubview(PresentationUI.footnote(
                NSLocalizedString("Your name is written into the certificate that signs this document, and the checker needs that certificate to check the signature.",
                                  comment: "Why the name row has no switch")))
        }
    }

    /// A claim the holder is shown but not asked about.
    ///
    /// Same layout as `disclosureRow` — the same heading, the same value — with
    /// the switch's place taken by a word. Keeping the shape identical is the
    /// point: the screen says 「this is a field like the others, and this one is
    /// not yours to withhold」, not 「something went wrong」.
    private func nonWithholdableRow(for claim: (name: String, value: String)) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12

        let label = UILabel()
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        let title = NSMutableAttributedString(
            string: StoredNationalID.label(for: claim.name),
            attributes: [.font: UIFont.preferredFont(forTextStyle: .headline)])
        title.append(NSAttributedString(
            string: "\n" + StoredNationalID.displayValue(for: claim.name, value: claim.value),
            attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline),
                         .foregroundColor: UIColor.secondaryLabel]))
        label.attributedText = title

        // The text label stretches; the trailing word hugs. Without this the
        // stack gave the slack to neither and 「一律出示」 floated mid-row next
        // to the name instead of sitting where every switch sits (photographed
        // on device 2026-08-11).
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let always = UILabel()
        always.text = NSLocalizedString("Always shown", comment: "Trailing text on the field the holder cannot withhold")
        always.font = .preferredFont(forTextStyle: .footnote)
        always.adjustsFontForContentSizeCategory = true
        always.textColor = .secondaryLabel
        always.setContentCompressionResistancePriority(.required, for: .horizontal)
        always.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(label)
        row.addArrangedSubview(always)
        return row
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
            string: "\n" + StoredNationalID.displayValue(for: claim.name, value: claim.value),
            attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline),
                         .foregroundColor: UIColor.secondaryLabel]))
        label.attributedText = title
        // The text yields, the control does not. Without this the row's slack
        // belongs to nobody: a 戶籍地址 is long enough to out-resist a
        // `UISwitch`, and the switch gets pushed past the trailing edge — the
        // holder sees a field they cannot turn off. Measured on device.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toggle = UISwitch()
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
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

        // A 44×44 target over the switch.
        //
        // A `UISwitch` is 51×31 and this row has no gesture recognizer of any
        // kind, so at AX5 the row is 237pt tall and the only part of it that
        // changes anything is a 63×28 patch at the trailing edge. What that
        // switch decides is whether a 身分證統一編號 leaves the phone, and the
        // people most likely to miss a small target — unsteady hands, low
        // vision, gloves at a disaster site — are the people this app is for.
        //
        // The overlay rather than resizing the switch: the control keeps the
        // system's own metrics and appearance, and only the area that forwards
        // a tap to it grows. Tapping the label is deliberately *not* wired —
        // the row is long, and a stray touch anywhere in 237pt of text
        // toggling a disclosure is the opposite of the fix.
        let target = UIView()
        target.translatesAutoresizingMaskIntoConstraints = false
        target.backgroundColor = .clear
        // Not an accessibility element: the switch already is one, and a second
        // stop that says nothing is what `VerdictSymbol` exists to correct
        // elsewhere.
        target.isAccessibilityElement = false
        target.addGestureRecognizer(UITapGestureRecognizer(target: toggle,
                                                           action: #selector(UISwitch.toggleFromHitTarget)))
        row.addSubview(target)
        NSLayoutConstraint.activate([
            target.centerXAnchor.constraint(equalTo: toggle.centerXAnchor),
            target.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            target.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            target.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            target.widthAnchor.constraint(greaterThanOrEqualTo: toggle.widthAnchor),
            target.heightAnchor.constraint(greaterThanOrEqualTo: toggle.heightAnchor)
        ])
        return row
    }

    /// The count is on the button because that is the last thing read before the
    /// tap. A holder who ticked one more field than they meant to sees it here.
    private func updateShowButtonTitle() {
        guard let showButton else { return }
        var configuration = showButton.configuration ?? UIButton.Configuration.filled()
        // Counted by the same function that decides what actually leaves —
        // `claimsToDisclose` — not by the switches. The old title read the
        // switches and said 「Show 0 field(s)」 while the presentation went out
        // carrying the name; a button caption is still a sentence on a screen,
        // and it was one the evidence did not support.
        let disclosing = Self.claimsToDisclose(chosen: chosenClaims,
                                               offered: disclosableClaims.map(\.name))
        if let disclosing {
            configuration.title = disclosing == ["name"]
                ? NSLocalizedString("Show only my name", comment: "Present button when nothing else is ticked")
                : String(format: NSLocalizedString("Show %d fields (name included)", comment: "Present button"), disclosing.count)
        } else {
            configuration.title = NSLocalizedString("Show my document", comment: "")
        }
        showButton.configuration = configuration
    }

    private func renderFrames(_ frames: [String], request: PresentationRequest) {
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
        // Monospaced digits: at fifteen frames the counter ticks twice a
        // second, and proportional digits make the whole line shiver.
        frameCountLabel.font = UIFontMetrics(forTextStyle: .headline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 17, weight: .semibold))
        frameCountLabel.adjustsFontForContentSizeCategory = true
        contentStack.addArrangedSubview(frameCountLabel)

        if frames.count > 1 {
            frameProgress.progressTintColor = .systemBlue
            frameProgress.trackTintColor = .systemFill
            contentStack.addArrangedSubview(frameProgress)
            contentStack.setCustomSpacing(12, after: frameProgress)

            // Offered whatever the accessibility settings say.
            //
            // WCAG 2.2.2's exemption for essential motion excuses not being able
            // to *stop*; it does not excuse having no control. And the practical
            // case has nothing to do with settings: a holder whose code will not
            // scan wants to hold one still so the checker can point at it, and
            // there was no way to do that except walk away.
            isCarouselPaused = false
            updatePauseButton()
            pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
            contentStack.addArrangedSubview(pauseButton)
            contentStack.setCustomSpacing(12, after: pauseButton)

            // The count is stated rather than left to be inferred from a
            // flickering image — and so is the time. Measured on device: a real
            // card's presentation is fifteen frames, which at the carousel's
            // pace is a little over eight seconds a cycle. A holder who expects
            // two seconds moves the phone away at four and restarts the scan.
            let cycleSeconds = Int((Double(frames.count)
                                    * Self.frameInterval(reduceMotion: UIAccessibility.isReduceMotionEnabled))
                                       .rounded())
            contentStack.addArrangedSubview(PresentationUI.body(String(
                format: NSLocalizedString("This document does not fit in one code, so it cycles through %1$d — one full cycle takes about %2$d seconds. Keep the screen still until the checker's phone says it has them all; the order does not matter.", comment: ""),
                frames.count, cycleSeconds)))
        }
        // Body weight, not footnote: this is the only sentence on the screen
        // with a deadline in it, and blowing the deadline restarts the whole
        // exchange. It was in the lowest-contrast style the screen has.
        // The radio, when the checker's code offered one. **Additive**: the
        // codes stay on screen and stay scannable, because the other phone may
        // be an older build, may have Bluetooth switched off, or may simply be
        // a camera. A transport that replaced the QR would take away the one
        // that works everywhere.
        // Always drawn, even when there is no radio to offer, because the first
        // device attempt produced *no line at all* and that is the one outcome
        // that cannot be diagnosed: 「the checker offered no radio」, 「the
        // payload was missing」 and 「the code never ran」 all look identical
        // when the screen says nothing. Saying which is a debug affordance in
        // the honest sense — the shipping strings below are the same either way.
        linkLabel.numberOfLines = 0
        linkLabel.textAlignment = .center
        linkLabel.font = .preferredFont(forTextStyle: .subheadline)
        linkLabel.adjustsFontForContentSizeCategory = true
        linkLabel.textColor = .secondaryLabel

        if request.linkServiceID == nil {
            linkLabel.text = NSLocalizedString("This checker's code did not offer Bluetooth, so the codes above are the only way across.", comment: "")
            contentStack.addArrangedSubview(linkLabel)
        } else if presentationPayload == nil {
            linkLabel.text = NSLocalizedString("Bluetooth was offered but this document could not be prepared for it.", comment: "")
            contentStack.addArrangedSubview(linkLabel)
        }

        if let serviceID = request.linkServiceID, presentationPayload != nil {
            linkServiceID = serviceID
            linkLabel.numberOfLines = 0
            linkLabel.textAlignment = .center
            linkLabel.font = .preferredFont(forTextStyle: .subheadline)
            linkLabel.adjustsFontForContentSizeCategory = true
            linkLabel.textColor = .secondaryLabel
            linkLabel.text = NSLocalizedString("Also sending this over Bluetooth, so the checker does not have to scan every code.", comment: "")
            contentStack.addArrangedSubview(linkLabel)
            startLinkIfPossible()
        }

        contentStack.addArrangedSubview(PresentationUI.body(
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
            // The mirror of the ZK screen's case: our own code, for the other
            // screen. Recognised here by shape rather than by a thrown case,
            // because `PresentationRequest` has no reason to know about the
            // other format — and a decoder that started refusing things by
            // naming a sibling format would be the wrong place for that
            // knowledge.
            if (try? ZKLinkEngagement.decode(from: scanned)) != nil {
                return .keepScanning(status: NSLocalizedString(
                    "That is the code for sending a zero-knowledge proof, not for showing a document.",
                    comment: "Scanned the other kind of code"))
            }
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
            let result = Result { () -> (frames: [String], payload: Data) in
                // Signed once; sharded twice. `presentation` is the document and
                // `frames` is that same document cut for a camera — deriving
                // them separately would sign the challenge twice.
                let payload = try holder.presentation(answering: request, disclosing: disclosing)
                return (try QRTransport.frames(for: payload), payload)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let signed):
                    self.presentationPayload = signed.payload
                    self.stage = .showing(frames: signed.frames, request: request)
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
        shownFrames.removeAll()
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
        // # Reduce Motion slows it; it does not stop it
        //
        // 1.8 Hz at full brightness, held up in front of a stranger, for as many
        // cycles as it takes. This is **not** a claim that it is a seizure risk
        // — it is below WCAG 2.3.1's three-flash threshold — but 2.2.2's
        // exemption for essential motion excuses not *stopping*, not withholding
        // control.
        //
        // Halving the rate is safe for the scanner: the pacing argument is that
        // a camera at 30 fps gets a dozen clean looks at each code, and slower
        // gives it more. It costs a longer cycle, which is why the sentence
        // above recomputes from the same constant rather than restating it.
        let timer = Timer(timeInterval: Self.frameInterval(reduceMotion: UIAccessibility.isReduceMotionEnabled),
                          repeats: true) { [weak self] _ in
            guard let self, !self.isCarouselPaused else { return }
            self.showFrame((self.frameIndex + 1) % self.renderedFrames.count)
        }
        RunLoop.main.add(timer, forMode: .common)
        carousel = timer
    }

    @objc private func togglePause() {
        isCarouselPaused.toggle()
        updatePauseButton()
    }

    private func updatePauseButton() {
        var configuration = UIButton.Configuration.gray()
        configuration.title = isCarouselPaused
            ? NSLocalizedString("Resume the codes", comment: "Carousel control")
            : NSLocalizedString("Hold this code still", comment: "Carousel control")
        // Says what tapping does, not what state it is in — the same rule as the
        // consent button that now reads 「把號碼送給內政部」 rather than 「繼續」.
        pauseButton.configuration = configuration
        pauseButton.accessibilityIdentifier = "present.pause"
    }

    private func showFrame(_ index: Int) {
        frameIndex = index
        frameImageView.image = renderedFrames[index]

        // # The bar counts codes *shown at least once*, and never goes back
        //
        // It used to be `(index + 1) / count`, so it filled over about six
        // seconds and then snapped to 0.08 and did it again, for as long as the
        // holder stood there. The holder is the one person who cannot read the
        // words beside it — the screen is pointed away from them — so that bar
        // is the only thing on this screen they can take in at a glance, and
        // what it was telling them was a loop.
        //
        // Worse, it implied progress towards something. It measured position in
        // a cycle, which is not progress towards anything at all.
        //
        // What this phone genuinely knows is how much of the document has been
        // put on screen at least once. That is a real quantity, it only ever
        // goes up, and when it reaches the end it stays there — which is the
        // honest shape, because after one full pass every code has had its
        // chance and the rest is repetition for a camera that missed one.
        shownFrames.insert(index)
        frameProgress.setProgress(Float(shownFrames.count) / Float(max(renderedFrames.count, 1)),
                                  animated: true)
        frameCountLabel.text = renderedFrames.count > 1
            ? String(format: NSLocalizedString("Code %1$d of %2$d", comment: "Carousel position"),
                     index + 1, renderedFrames.count)
            : nil
        frameCountLabel.isHidden = renderedFrames.count <= 1
    }

    /// One line, in the register the rest of the screen uses: what is happening,
    /// never a raw error. A holder who is told 「CBErrorDomain 7」 has been given
    /// a fact they cannot act on.
    private func showLink(_ state: BluetoothLinkState) {
        switch state {
        case .unavailable(let reason):
            linkLabel.text = reason
        case .starting:
            linkLabel.text = NSLocalizedString("Turning on Bluetooth…", comment: "")
        case .waiting:
            // Deliberately *not* the same sentence the label starts with. It was,
            // and that made 「advertising, waiting for the checker」 and 「nothing
            // ever happened」 the same pixels.
            linkLabel.text = NSLocalizedString("Discoverable over Bluetooth — waiting for the checker to connect.", comment: "")
        case .transferring(let fraction):
            linkLabel.text = String(format: NSLocalizedString("Sending over Bluetooth… %d%%", comment: ""),
                                    Int((fraction * 100).rounded()))
        case .finished:
            linkLabel.text = NSLocalizedString("The checker's phone has the document.", comment: "")
            // The only non-visual signal in the app, at the only moment there is
            // evidence for one.
            //
            // Everything on this screen faces the checker: the instruction says
            // 「keep the screen still until the checker's phone says it has them
            // all」 while both screens point away from the person being asked to
            // read it. A buzz is the one channel that reaches the holder.
            //
            // Only on `.finished`, and only on the radio path — that is the
            // single state where the other device has actually acknowledged
            // receipt. A haptic on 「the carousel completed a pass」 would be a
            // buzz meaning "it has been shown", which a holder would reasonably
            // hear as "it worked".
            PresentationHaptics.delivered()
        case .failed(let reason):
            linkLabel.text = reason
        }
    }

    private func stopCarousel() {
        carousel?.invalidate()
        carousel = nil
    }

    /// Torn down when the screen goes away — **not** from `stopCarousel`.
    ///
    /// It was, on the reasoning that the carousel and the radio both mean 「this
    /// screen is in front of the holder」. They do; but `startCarousel` opens by
    /// calling `stopCarousel` as a reset, so the peripheral was destroyed a few
    /// microseconds after it was created, before CoreBluetooth delivered its
    /// first state callback. The screen said 「正在開啟藍牙…」 and then nothing,
    /// ever — which is exactly what three device attempts showed.
    ///
    /// `CBPeripheralManager` does not retain its delegate, so releasing this
    /// object is releasing the radio. The lifetime that was wanted is the
    /// screen's, and that is `.stopShowing`.
    private func stopLink() {
        let wasRunning = link != nil
        link?.stop()
        link = nil
        // `BluetoothLink.stop()` posts no state, so without this the label keeps
        // whatever it last said — including 「sending over Bluetooth… 63%」 for a
        // transfer whose radio no longer exists. The holder must not be told a
        // transfer is in progress when there is none.
        if wasRunning {
            linkLabel.text = NSLocalizedString("Bluetooth sending has stopped.", comment: "")
        }
    }

    /// Starts the radio if there is something to send and somewhere to send it.
    ///
    /// Idempotent on `link == nil`, so `.startShowing` firing on an appearance
    /// where the radio is already up costs nothing — and the frame render and
    /// the lifecycle can both call it without either having to know about the
    /// other.
    // MARK: - Seams for the radio's lifetime
    //
    // Narrow, and deliberately below the real path: reaching the frames for real
    // needs a stored credential, a Keychain round trip and a Secure Enclave
    // signature, none of which say anything about whether a cancelled back
    // gesture leaves the radio dead.

    /// Stands in for the frame render having happened.
    func prepareLinkForReview(serviceID: UUID, payload: Data) {
        linkServiceID = serviceID
        presentationPayload = payload
    }

    var radioIsAdvertisingForReview: Bool { link != nil }

    var linkLineForReview: String? { linkLabel.text }

    func applyForReview(_ effect: PresentationScreenLifecycle.Effect) { apply(effect) }

    private func startLinkIfPossible() {
        guard link == nil, let serviceID = linkServiceID, let payload = presentationPayload else { return }
        let link = BluetoothLinkPeripheral(payload: payload, serviceID: serviceID) { [weak self] state in
            self?.showLink(state)
        }
        self.link = link
        link.start()
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

extension UISwitch {

    /// Flips the switch from an enlarged hit target and reports it.
    ///
    /// `setOn(_:animated:)` alone does **not** send `.valueChanged`, so a switch
    /// driven this way would move on screen while `chosenClaims` stayed as it
    /// was — the holder would see a field ticked and the presentation would go
    /// out without it. That divergence is silent in exactly the direction that
    /// matters: the screen over-promises what is being disclosed.
    @objc func toggleFromHitTarget() {
        setOn(!isOn, animated: true)
        sendActions(for: .valueChanged)
    }
}

// MARK: - The one buzz

/// A single success haptic, for the single moment that has evidence behind it.
///
/// # Why a type rather than two call sites
///
/// The rule is what needs protecting, not the API call. There is exactly one
/// state in this app where the other device has *acknowledged* receipt —
/// `BluetoothLinkState.finished` — and a buzz anywhere else would be a signal
/// the holder cannot help hearing as "it worked". The obvious next request is
/// "buzz when the carousel finishes a pass", which is a buzz meaning "shown",
/// and shown is not received.
///
/// Keeping it here means the next person who wants a haptic finds the argument
/// before they find the generator.
enum PresentationHaptics {

    @MainActor
    static func delivered() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
}
