//
//  TextContrastTests.swift
//  backupTWTests
//
//  The measurement, so a comment cannot claim the opposite of it again.
//

import Testing
import UIKit
@testable import backupTW

/// # Why this is a test and not a comment
///
/// `PresentationUI.footnote`'s comment said 「`.secondaryLabel` is 60% and clears
/// [WCAG AA]」. It does not. The correct number was already written down in the
/// same file, 85 lines away, in `caveatGroup`'s comment — one `UIColor`, two
/// comments, opposite claims, and the wrong one was the one every new screen
/// read before reaching for the style.
///
/// A number that only exists in prose drifts. This computes it.
@MainActor
struct TextContrastTests {

    /// WCAG 2.x relative luminance and contrast ratio.
    private static func luminance(_ colour: UIColor, _ style: UIUserInterfaceStyle) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Composites `ink` over `ground` first — the label colours are translucent,
    /// and a ratio computed without compositing is not the one on screen.
    private static func ratio(_ ink: UIColor, on ground: UIColor,
                              _ style: UIUserInterfaceStyle) -> CGFloat {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var ir: CGFloat = 0, ig: CGFloat = 0, ib: CGFloat = 0, ia: CGFloat = 0
        ink.resolvedColor(with: traits).getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
        var gr: CGFloat = 0, gg: CGFloat = 0, gb: CGFloat = 0, ga: CGFloat = 0
        ground.resolvedColor(with: traits).getRed(&gr, green: &gg, blue: &gb, alpha: &ga)
        let composited = UIColor(red: ir * ia + gr * (1 - ia),
                                 green: ig * ia + gg * (1 - ia),
                                 blue: ib * ia + gb * (1 - ia), alpha: 1)
        let a = luminance(composited, style), b = luminance(ground, style)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static let grounds: [UIColor] = [.systemGroupedBackground,
                                             .secondarySystemGroupedBackground,
                                             .tertiarySystemGroupedBackground]

    /// The claim the old comment made, checked.
    @Test func secondaryLabelDoesNotPassAAForBodyTextInLightMode() {
        for ground in Self.grounds {
            let measured = Self.ratio(.secondaryLabel, on: ground, .light)
            #expect(measured < 4.5,
                    "the old comment may have become true — .secondaryLabel now measures \(measured)")
        }
    }

    /// And the colour these helpers use now does pass, in both modes.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theTextHelpersClearAAOnEveryGroupedBackground(style: UIUserInterfaceStyle) {
        for ground in Self.grounds {
            let measured = Self.ratio(.label, on: ground, style)
            #expect(measured >= 4.5, "label ink measures \(measured) on \(ground)")
        }
    }

    /// The helpers themselves, so a later edit cannot quietly put the ink back.
    @Test func theSentenceHelpersUseFullInk() {
        #expect(PresentationUI.footnote("x").textColor == .label)
        #expect(PresentationUI.body("x").textColor == .label)
        #expect(PresentationUI.mitigation("x").textColor == .label)
    }

    /// `.tertiaryLabel` is the one the original comment got right, and nothing
    /// in the app may reach for it for text.
    @Test func nothingDrawsSentencesInTertiaryInk() {
        let measured = Self.ratio(.tertiaryLabel, on: .systemGroupedBackground, .light)
        #expect(measured < 3.0, "tertiary ink measures \(measured) — the comment's premise changed")
        for helper in [PresentationUI.footnote("x"), PresentationUI.body("x")] {
            #expect(helper.textColor != .tertiaryLabel)
        }
    }

    /// The verdict card's spec (design system §9.2): `.label` ink over the
    /// semantic colour at 0.14 alpha, composited over each grouped ground.
    /// The spec exists because the bare coloured *text* it replaced measured
    /// 1.99:1; this holds the replacement to AA in both modes for all three
    /// verdict colours.
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func theVerdictFillKeepsLabelInkAtAA(style: UIUserInterfaceStyle) {
        for semantic in [Bonds.Color.Verdict.pass, Bonds.Color.Verdict.caution, Bonds.Color.Verdict.fail] {
            for ground in Self.grounds {
                let traits = UITraitCollection(userInterfaceStyle: style)
                var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
                Bonds.Color.Verdict.fill(semantic).resolvedColor(with: traits)
                    .getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
                var gr: CGFloat = 0, gg: CGFloat = 0, gb: CGFloat = 0, ga: CGFloat = 0
                ground.resolvedColor(with: traits).getRed(&gr, green: &gg, blue: &gb, alpha: &ga)
                let fill = UIColor(red: fr * fa + gr * (1 - fa),
                                   green: fg * fa + gg * (1 - fa),
                                   blue: fb * fa + gb * (1 - fa), alpha: 1)
                let measured = Self.ratio(.label, on: fill, style)
                #expect(measured >= 4.5,
                        "label on \(semantic)-tinted fill measures \(measured) in \(style == .light ? "light" : "dark")")
            }
        }
    }

    /// The card palette's own inks, measured against the faces they sit on —
    /// the card faces are exempt from dark mode, not from being readable.
    @Test func theCardFacesKeepTheirInkReadable() {
        // 紙質卡：油墨與標籤在紙底上。
        #expect(Self.ratio(Bonds.CardPalette.paperInk, on: Bonds.CardPalette.paperBottom, .light) >= 4.5)
        #expect(Self.ratio(Bonds.CardPalette.paperLabel, on: Bonds.CardPalette.paperBottom, .light) >= 4.5)
        // 保險箱石墨卡：主字與弱字在最淺的石墨階上。
        #expect(Self.ratio(Bonds.CardPalette.vaultInk, on: Bonds.CardPalette.graphite[0], .light) >= 4.5)
        #expect(Self.ratio(Bonds.CardPalette.vaultMuted, on: Bonds.CardPalette.graphite[0], .light) >= 3.0,
                "vault muted ink is caption-scale; 3:1 is its floor")
    }
}
