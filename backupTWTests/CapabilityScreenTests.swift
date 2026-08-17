//
//  CapabilityScreenTests.swift
//  backupTWTests
//
//  The screen that says what this app cannot do, and the rule that it must not
//  be able to say otherwise.
//

import UIKit
import Testing
@testable import backupTW

/// # Why these assert on the rendered screen rather than on the table
///
/// `PresentationScenarioTests` already pins the table: two of three scenarios
/// are `.partial`, and what each of them actually establishes. Those tests were
/// green for the whole time the table had **no screen at all** — which is the
/// defect that produced this file. A capability statement nothing renders is a
/// capability statement nobody reads, and it passes every test you write about
/// the data.
///
/// So everything below walks the real view hierarchy of the real view
/// controller. The question is not "does the table say partial", it is "does a
/// person looking at this screen see partial".
///
/// # Two things this file got wrong first, both worth keeping written down
///
/// **`@MainActor` is not decoration here.** Without it these tests did not fail,
/// they *crashed* — Swift Testing runs concurrently on arbitrary threads, unlike
/// XCTest, and the first `layer.cornerRadius` reached
/// `_raiseExceptionForBackgroundThreadLayerPropertyModification`. Swift Testing
/// reports that as 「Issue recorded」 with no message and no summary line, which
/// looks exactly like an assertion failure whose text got lost. It is not; the
/// evidence was in the crash report, not the test log.
///
/// **Assertions about wording must be made in the language that ships.** The
/// first version of `neitherPathIsDescribedAsAnonymous` looked for the substring
/// "name" in a sentence that is 「姓名」 in the built app. That test would have
/// been green for exactly as long as the string was untranslated, and turned red
/// on the day the translation landed — the day it started being correct. This
/// project has made that mistake before and it is the reason
/// `LocalizationCoverageTests` exists.
@MainActor
struct CapabilityScreenTests {

    private static func screen() -> CapabilityViewController {
        let screen = CapabilityViewController()
        // Loaded, not presented: the whole hierarchy is built in `viewDidLoad`
        // and nothing here needs a window.
        screen.loadViewIfNeeded()
        return screen
    }

    private static func labelText(in root: UIView) -> [String] {
        var found: [String] = []
        if let text = (root as? UILabel)?.text { found.append(text) }
        for subview in root.subviews { found.append(contentsOf: labelText(in: subview)) }
        return found
    }

    /// Every scenario in the table reaches the screen.
    ///
    /// A screen that rendered two of three would be worse than no screen: it
    /// would look complete.
    @Test func everyScenarioIsOnTheScreen() {
        let text = Self.labelText(in: Self.screen().view).joined(separator: "\n")
        for scenario in PresentationScenario.all {
            #expect(text.contains(scenario.request),
                    "scenario \(scenario.id) is in the table and not on the screen")
        }
    }

    /// **The rule this screen exists for.** What a `.partial` scenario actually
    /// establishes is on the screen, in full, not summarised and not truncated.
    ///
    /// Asserted on the whole string rather than a prefix, because the part most
    /// likely to be cut is the end — and in both partial scenarios the end is
    /// where the limitation lives ("different checkers can tell it is the same
    /// person", "two checkers who never speak cannot both refuse the same
    /// person").
    @Test func aPartialAnswerSaysWhatItActuallyShows() {
        let text = Self.labelText(in: Self.screen().view).joined(separator: "\n")
        var partials = 0
        for scenario in PresentationScenario.all {
            guard case .partial(let actually) = scenario.support else { continue }
            partials += 1
            #expect(text.contains(actually),
                    "\(scenario.id) is partial and the screen does not say what it actually shows")
        }
        // If the table ever stops having partial scenarios, this test starts
        // proving nothing — and that would be a change worth noticing, not a
        // test worth quietly passing.
        //
        // Three, not two: `wasTaiwanese` was demoted from the page's one green
        // tick, because the request asks about 「你」 and the proof establishes
        // that *somebody's* signing material was used.
        #expect(partials == 3, "expected three partial scenarios, found \(partials)")
    }

    /// A partial answer must not be able to wear the supported answer's clothes.
    ///
    /// Three signals carry the difference — word, symbol, colour — and this
    /// checks all three are actually different, because a refactor that unified
    /// any one of them would leave the other two doing the work silently.
    @Test func partialAndSupportedDoNotLookAlike() {
        let cases: [ScenarioSupport] = [.supported,
                                        .partial(actually: "x"),
                                        .unsupported(blockedBy: "y")]
        let headlines = cases.map { CapabilityViewController.headline(for: $0) }
        let symbols = cases.map { CapabilityViewController.symbol(for: $0) }
        let colours = cases.map { CapabilityViewController.colour(for: $0) }

        #expect(Set(headlines).count == 3, "two support cases share a headline: \(headlines)")
        #expect(Set(symbols).count == 3, "two support cases share a symbol: \(symbols)")
        #expect(Set(colours).count == 3, "two support cases share a colour")
    }

    /// A tick belongs to `.supported` alone.
    ///
    /// The specific failure mode this project keeps having is a qualification
    /// rendered next to a mark that means "fine". `◐` is not a tick and not a
    /// cross, and neither of the other two cases may borrow it either.
    @Test func onlyAFullAnswerGetsATick() {
        #expect(CapabilityViewController.symbol(for: .supported) == "✓")
        #expect(CapabilityViewController.symbol(for: .partial(actually: "x")) != "✓")
        #expect(CapabilityViewController.symbol(for: .unsupported(blockedBy: "y")) != "✓")
        // And not a cross either: the app can do something here, and a cross
        // would undersell a real capability as surely as a tick oversells one.
        #expect(CapabilityViewController.symbol(for: .partial(actually: "x")) != "✗")
    }

    /// The caveats are on the screen whatever the verdict says.
    ///
    /// This used to be `aSupportedScenarioStillShowsItsCaveats`, and it opened
    /// with `#expect(!supported.isEmpty)` — so demoting the page's one green
    /// tick turned it red, not because the rule broke but because the rule was
    /// written around a particular scenario being supported.
    ///
    /// The rule is stronger without that: a caveat is not a footnote attached to
    /// a pass, it is what remains true underneath any answer. `.partial` is the
    /// case that needs it most — a half answer reads as the good half.
    @Test func everyScenarioShowsItsCaveatsWhateverTheVerdict() {
        let text = Self.labelText(in: Self.screen().view).joined(separator: "\n")
        for scenario in PresentationScenario.all where !scenario.caveats.isEmpty {
            for caveat in scenario.caveats {
                #expect(text.contains(caveat.localizedDescription),
                        "\(scenario.id) is on screen and the screen omits \(caveat)")
            }
        }
        // The zero-knowledge scenarios must not be caveat-free.
        for scenario in PresentationScenario.all where scenario.path == .zeroKnowledge {
            #expect(!scenario.caveats.isEmpty,
                    "\(scenario.id) is answered with a proof and carries no caveats at all")
        }
    }

    /// A build with neither path shows neither a tick nor a half-tick.
    ///
    /// Not a badge beside the verdict: this screen's own header says the word,
    /// the colour and the `actually` sentence are the three carriers, so a
    /// verdict left standing with a note next to it is still the verdict.
    @Test func aGatedBuildDoesNotShowAnAnswerItCannotGive() {
        let screen = CapabilityViewController(paths: BuildPaths(credential: false,
                                                                zeroKnowledge: false))
        screen.loadViewIfNeeded()
        let text = Self.labelText(in: screen.view).joined(separator: "\n")

        #expect(!text.contains(CapabilityViewController.headline(for: .supported)))
        #expect(!text.contains(CapabilityViewController.headline(for: .partial(actually: ""))))
        #expect(text.contains(CapabilityViewController.headline(for: .unsupported(blockedBy: ""))))

        // And no `.partial` sentence survives, which is the one that states a
        // capability in the holder's own language.
        for scenario in PresentationScenario.all {
            guard case .partial(let actually) = scenario.support else { continue }
            #expect(!text.contains(actually),
                    "a build with no paths still tells the reader what \(scenario.id) shows")
        }
    }

    /// Neither path may be described as anonymous or unlinkable.
    ///
    /// Both descriptions were wrong once and were corrected: the credential path
    /// carries the cardholder's certificate and their name is its Subject CN;
    /// the ZK path has one nullifier per person because `bondsAppID` is a single
    /// constant. This is a wording guard, and it is here rather than in a review
    /// checklist because wording is what drifts.
    @Test func neitherPathIsDescribedAsAnonymous() {
        for path in [PresentationPath.credential, .zeroKnowledge] {
            let described = CapabilityViewController.pathDescription(path)
            #expect(!described.localizedCaseInsensitiveContains("anonymous"),
                    "\(path) is described as anonymous: \(described)")
            #expect(!described.localizedCaseInsensitiveContains("unlinkable"),
                    "\(path) is described as unlinkable: \(described)")
        }
        // And the credential path has to say the name travels, because that is
        // the single most surprising thing about it — asserted against both
        // spellings, because the app ships in Chinese and a test that only knew
        // the English one would be green precisely while the string was
        // untranslated.
        let credential = CapabilityViewController.pathDescription(.credential)
        #expect(credential.contains("姓名") || credential.localizedCaseInsensitiveContains("name"),
                "the credential path must say the holder's name travels: \(credential)")
    }
}

/// The nested boxes on the capability page must be visible against the card
/// they sit in.
///
/// # The defect this pins
///
/// `caveatGroup` and `card` paint `.secondarySystemGroupedBackground`, which is
/// correct for their other thirteen call sites: those sit on a screen-level
/// stack that is `.systemGroupedBackground`. The capability page reused them one
/// level deeper, inside a comparison card that is *itself*
/// `.secondarySystemGroupedBackground` — so the boxes were the same colour as
/// their parent, at 1.00:1.
///
/// What was lost is not decoration. Under 「What a checker can rely on:」 and
/// 「What it cannot establish:」 the items are deliberately the same weight and
/// the same black, because the comparison is the point. The grey 12pt subtitle
/// was therefore the only thing saying which list was the negative one, and
/// 「it carries a number unique to this card that every checker sees」 reads as a
/// feature to anybody who skipped it.
@MainActor
struct NestedGroupGroundTests {

    /// Light **and** dark, because a same-colour bug can hide in one of them.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theNestedGroundDiffersFromTheCardItSitsOn(style: UIUserInterfaceStyle) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let ground = PresentationUI.nestedGroupBackground.resolvedColor(with: traits)
        let card = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits)
        #expect(ground != card,
                "a nested box is the same colour as its parent card in \(style == .light ? "light" : "dark") mode")
    }

    /// The durable half: a sixth box added to this page must not silently
    /// inherit the flat ground.
    ///
    /// Pinned at the source rather than the hierarchy because the failure is
    /// somebody adding a call, and a hierarchy walk only sees the calls that
    /// exist. Both helpers default `nested` to false, so forgetting it is the
    /// quiet outcome.
    @Test func everyGroupOnThisPageDeclaresItselfNested() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("backupTW/ViewController/CapabilityViewController.swift"),
                                encoding: .utf8)
        let calls = ["PresentationUI.caveatGroup(", "PresentationUI.card("]
        var found = 0
        for call in calls {
            var searched = source[...]
            while let start = searched.range(of: call) {
                // The call runs to its closing paren; every one here is written
                // across lines ending in `))`.
                let tail = searched[start.upperBound...]
                let end = tail.range(of: "))") ?? tail.startIndex..<tail.startIndex
                let body = tail[..<end.lowerBound]
                found += 1
                #expect(body.contains("nested: true"),
                        "a \(call) on the capability page takes the flat ground: \(body.prefix(120))")
                searched = tail[end.lowerBound...]
            }
        }
        // Six since 2d-3 added 「In this version」 to the comparison cards. The
        // number is here so a seventh box is looked at rather than counted; this
        // is the one time it has fired, and the box it caught was correct.
        #expect(found == 6, "expected 6 nested boxes on this page, walked \(found) — the page changed shape")
    }

    /// On this page the subtitle is the negative word, so it is body-black.
    @Test func theSubtitleThatSaysWhichListIsWhichIsNotGrey() throws {
        let group = PresentationUI.caveatGroup(subtitle: "What it cannot establish:",
                                               messages: ["a"], nested: true)
        let subtitle = try #require((group as? UIStackView)?.arrangedSubviews.first as? UILabel)
        #expect(subtitle.textColor == .label)
    }
}
