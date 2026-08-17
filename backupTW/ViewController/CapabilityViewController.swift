//
//  CapabilityViewController.swift
//  backupTW
//
//  The whitepaper's three scenarios, with this build's honest answer to each.
//

import UIKit

/// What this app can and cannot prove, as a screen.
///
/// # Why this exists
///
/// `PresentationScenario` says of itself that "the screen renders whatever this
/// table says rather than what the demo would prefer" — and there was no screen.
/// The type, its three entries, its `.partial(actually:)` case and its tests all
/// existed, reachable from nothing. So the safeguard against a demo rounding
/// 「我們能證明一個相近的東西」 up to a green tick protected the test target and
/// nobody else.
///
/// This is the same defect, and the same fix, as the one recorded two rows up in
/// `SettingsViewController`: `LocalDataEraser` was implemented and unreachable,
/// which made the promise that you can remove your identity from the phone false
/// in practice while true in the source. Code with no caller is a claim with no
/// evidence.
///
/// # The one rule this screen is written to
///
/// **`.partial` must not be able to look like `.supported`.** Two of the three
/// whitepaper scenarios are partial, and a partial answer is the single most
/// likely thing to be misread in the room where it matters — a demo, with an
/// audience, where hedges are least welcome.
///
/// So the difference is carried three times over, because any one of them can be
/// missed: a different word (「做得到一半」, not a qualified 「做得到」), a different
/// colour, and — the load-bearing one — the `actually` sentence rendered
/// immediately under the verdict, at body weight, never behind a disclosure
/// arrow and never truncated. That sentence is written in the holder's language
/// and states what *is* established, so a reader who takes nothing else away
/// takes away the true claim rather than the requested one.
///
/// The caveats sit under that, for the same reason `VerifiedResultSection.order`
/// puts them above the disclosed fields: a qualification that can be scrolled
/// past is a qualification that will be.
final class CapabilityViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    /// Injected so the gated configuration is testable. `DEBUG` is true wherever
    /// the tests run, so a screen that read the flags directly could only be
    /// tested in the one configuration where the gate never fires.
    private let paths: BuildPaths

    init(paths: BuildPaths = .current) {
        self.paths = paths
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("What this app can prove", comment: "")
        view.backgroundColor = .systemGroupedBackground
        buildInterface()
    }

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

        contentStack.addArrangedSubview(PresentationUI.body(NSLocalizedString(
            "Three things someone might ask this app to prove, and what it can honestly answer today. Two of the three are only half answered, and this page says which half.",
            comment: "")))

        // Grouped by the whitepaper's own division rather than by verdict.
        // Sorting by verdict would put the one full 「做得到」 at the top and
        // read as a scoreboard; the division that matters is *when* a scenario
        // is for, because the emergency one is the one this build genuinely
        // serves and it is the last one a reader would reach in request order.
        appendSection(NSLocalizedString("Everyday", comment: "Scenario group"),
                      scenarios: PresentationScenario.all.filter { !$0.isEmergency })
        appendSection(NSLocalizedString("During an emergency", comment: "Scenario group"),
                      scenarios: PresentationScenario.all.filter(\.isEmergency))

        // ⚠️ **The previous sentence was the thing it was reassuring you about.**
        //
        // It read 「這些答案來自 App 其他地方讀的同一張表，所以這個畫面說不出比程式
        // 碼實際做得到的更多。」 Nothing else in the app target read
        // `PresentationScenario`, and the table asked neither build switch — so
        // the one sentence promising the verdicts were derived was itself the
        // only claim on the page with nothing behind it.
        //
        // What is written now is what this screen can actually stand behind: the
        // caveats are the proof code's own list, the availability is read from
        // the same switches the rest of the app reads, and the wording of each
        // verdict is a human judgement that no test can check for honesty.
        contentStack.addArrangedSubview(PresentationUI.footnote(NSLocalizedString(
            "The caveats under each answer are the list the proof code itself carries, and whether a path exists at all is read from the same build switch the rest of the app reads. The wording of each answer is written by hand — it is this project's own account of its design, not a measurement.",
            comment: "")))

        appendCardComparison()
    }

    // MARK: - Three kinds of card, side by side

    /// # Why the comparison is on this page and not a page of its own
    ///
    /// Above, the question is 「can this app prove X」. Here it is 「what is each
    /// of my cards worth」, and the two are the same question asked from the two
    /// ends. A reader who has just been told that two of three scenarios are
    /// half-answered is exactly the reader who should then see that the three
    /// documents differ in *which* half they give up.
    ///
    /// A wallet holding a national ID, a driving licence and a proof is not
    /// unusual — the official app holds cards too. Putting their limits next to
    /// each other is the part nobody else is doing, and it only works as a
    /// comparison: read alone, each card's limits look like a list of faults.
    private func appendCardComparison() {
        contentStack.addArrangedSubview(PresentationUI.sectionTitle(
            NSLocalizedString("What each card is worth", comment: "card comparison")))
        contentStack.addArrangedSubview(PresentationUI.body(NSLocalizedString(
            "Three kinds of document, three different trust models. Each one gives something up, and it is not the same something — which is only visible with all three on one screen.",
            comment: "")))
        CardCapability.all.forEach { contentStack.addArrangedSubview(comparisonCard(for: $0)) }
    }

    private func comparisonCard(for card: CardCapability) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.backgroundColor = .secondarySystemGroupedBackground
        stack.layer.cornerRadius = 14
        stack.accessibilityIdentifier = "cardCapability.\(card.id)"

        let name = UILabel()
        name.text = card.name
        name.numberOfLines = 0
        name.font = UIFontMetrics(forTextStyle: .headline)
            .scaledFont(for: .systemFont(ofSize: 18, weight: .semibold))
        name.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(name)

        stack.addArrangedSubview(PresentationUI.footnote(card.origin))

        // Before the claim lists, not after: it changes what they mean.
        if let note = card.buildNote(in: paths) {
            stack.addArrangedSubview(PresentationUI.card(
                title: NSLocalizedString("In this version", comment: ""),
                body: note, nested: true))
        }

        stack.addArrangedSubview(PresentationUI.caveatGroup(
            subtitle: NSLocalizedString("What a checker can rely on:", comment: ""),
            messages: card.proves, nested: true))

        // The limits are drawn with the same weight as what the card proves, and
        // directly after it. Putting them in a lighter style, or behind a
        // disclosure arrow, would make the comparison decorative — and this
        // whole section exists because the limits are the part that differs.
        stack.addArrangedSubview(PresentationUI.caveatGroup(
            subtitle: NSLocalizedString("What it cannot establish:", comment: ""),
            messages: card.limits, nested: true))

        return stack
    }

    private func appendSection(_ title: String, scenarios: [PresentationScenario]) {
        guard !scenarios.isEmpty else { return }
        contentStack.addArrangedSubview(PresentationUI.sectionTitle(title))
        scenarios.forEach { contentStack.addArrangedSubview(card(for: $0)) }
    }

    // MARK: - One scenario

    private func card(for scenario: PresentationScenario) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.backgroundColor = .secondarySystemGroupedBackground
        stack.layer.cornerRadius = 14
        stack.accessibilityIdentifier = "capability.\(scenario.id)"

        // The request, in the asking party's words, first — this is a page about
        // answers, and an answer shown without its question is a claim floating
        // free of what it was a claim about.
        let request = UILabel()
        request.text = "「" + scenario.request + "」"
        request.numberOfLines = 0
        request.font = UIFontMetrics(forTextStyle: .headline)
            .scaledFont(for: .systemFont(ofSize: 18, weight: .semibold))
        request.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(request)

        // Resolved once. Reading `scenario.support` again below would render a
        // gated verdict above an ungated explanation.
        let support = scenario.support(in: paths)

        stack.addArrangedSubview(PresentationUI.verdict(Self.symbol(for: support),
                                                        Self.headline(for: support),
                                                        Self.colour(for: support)))

        // The whole point of the screen. Body weight, immediately under the
        // verdict, never collapsed.
        switch support {
        case .partial(let actually):
            stack.addArrangedSubview(PresentationUI.card(
                title: NSLocalizedString("What it actually shows", comment: ""),
                body: actually, nested: true))
        case .unsupported(let blockedBy):
            stack.addArrangedSubview(PresentationUI.card(
                title: NSLocalizedString("What would have to change", comment: ""),
                body: blockedBy, nested: true))
        case .supported:
            break
        }

        stack.addArrangedSubview(PresentationUI.footnote(Self.pathDescription(scenario.path)))

        if !scenario.caveats.isEmpty {
            stack.addArrangedSubview(PresentationUI.caveatGroup(
                subtitle: NSLocalizedString("Still true even when this passes:", comment: ""),
                messages: scenario.caveats.map(\.localizedDescription), nested: true))
        }
        return stack
    }

    // MARK: - Words for a verdict

    /// Deliberately not 「通過 / 部分通過」. 「部分」 as a modifier reads as a
    /// qualified version of the same answer; 「做得到一半」 reads as a different
    /// answer, which is what it is.
    static func headline(for support: ScenarioSupport) -> String {
        switch support {
        case .supported: return NSLocalizedString("Yes, this app can show that", comment: "")
        case .partial: return NSLocalizedString("Only half of that", comment: "")
        case .unsupported: return NSLocalizedString("No, not on any path this app has", comment: "")
        }
    }

    /// Not a tick for `.partial`, and not a cross either. A tick would be the
    /// rounding-up this whole type exists to prevent; a cross would say the app
    /// can do nothing here, which is also false and would undersell a real
    /// capability.
    static func symbol(for support: ScenarioSupport) -> String {
        switch support {
        case .supported: return "✓"
        case .partial: return "◐"
        case .unsupported: return "✗"
        }
    }

    static func colour(for support: ScenarioSupport) -> UIColor {
        switch support {
        case .supported: return .systemGreen
        case .partial: return .systemOrange
        case .unsupported: return .secondaryLabel
        }
    }

    /// What answering on this path costs the holder — the part a scenario list
    /// otherwise leaves out.
    ///
    /// Both sentences are the corrected ones. The credential path is not
    /// 「只是可連結」: the cardholder's X.509 certificate has to travel for the
    /// signature to be checkable at all, and its Subject CN is their legal name,
    /// so every checker learns who they are. The ZK path is not 「不可連結」
    /// either: `bondsAppID` is one constant, so the nullifier is one value per
    /// person shown identically to everyone.
    static func pathDescription(_ path: PresentationPath) -> String {
        switch path {
        case .credential:
            return NSLocalizedString(
                "Answered with your signed document, shown as QR codes or over Bluetooth. The checker sees your name either way — your certificate has to travel with it, and your name is inside the certificate.",
                comment: "")
        case .zeroKnowledge:
            return NSLocalizedString(
                "Answered with a zero-knowledge proof, sent over Bluetooth. The checker never sees your certificate — but every checker sees the same duplicate-detection number, so they can still tell it is the same person.",
                comment: "")
        }
    }
}
