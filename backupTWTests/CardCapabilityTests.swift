//
//  CardCapabilityTests.swift
//  backupTWTests
//
//  Three trust models on one screen, and the sentence none of them may contain.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@Suite("三種卡的能力對照")
struct CardCapabilityTests {

    /// Every kind carries limits. A card with an empty `limits` array would read
    /// as "nothing to declare", and none of the three is in that position — the
    /// comparison exists precisely because all three give something up.
    @Test(arguments: CardCapability.all)
    func everyKindDeclaresWhatItCannotDo(_ card: CardCapability) {
        #expect(!card.limits.isEmpty, "\(card.id) claims no limits")
        #expect(!card.proves.isEmpty, "\(card.id) claims to prove nothing")
    }

    /// **The forbidden claim.**
    ///
    /// Per-credential keys sever one link — between cards — and nothing else. A
    /// TWDIW credential's `cnf.jwk` is fixed by its issuer and seen by every
    /// verifier forever; its `statusListIndex` is unique per card and sits
    /// outside the disclosure envelope; and the name on the card joins two
    /// documents before any key does. So no card face may promise that holding
    /// one hides the others.
    ///
    /// Asserted against the shipping Chinese as well as the English keys,
    /// because a claim that only appears after translation is still a claim.
    @Test func noKindClaimsToBeUnlinkableFromTheOthers() {
        let forbidden = ["不可連結", "無法連結", "unlinkable", "cannot be linked", "無法被連結"]
        for card in CardCapability.all {
            for line in [card.name, card.origin] + card.proves + card.limits {
                let shipped = NSLocalizedString(line, comment: "")
                for phrase in forbidden {
                    #expect(!line.lowercased().contains(phrase.lowercased()),
                            "\(card.id) promises unlinkability: \(line)")
                    #expect(!shipped.lowercased().contains(phrase.lowercased()),
                            "\(card.id) promises unlinkability once translated: \(shipped)")
                }
            }
        }
    }

    /// # These assert the *shipping* string, not the English key
    ///
    /// The first version of these two compared against English substrings and
    /// failed immediately — because `NSLocalizedString` runs at initialisation
    /// and `limits` therefore already holds Chinese. That is the same defect
    /// this project has been bitten by before: a test that matches the English
    /// key is green exactly while the translation is missing, and turns red the
    /// moment somebody supplies it.
    ///
    /// So the expectation is obtained through the same localization call the
    /// production code makes. Locale-independent, and it still fails if the
    /// claim is deleted or reworded — which is the whole job.

    /// The one about the name has to survive. It is the finding this app had to
    /// correct itself about, and the correction lives in a sentence somebody can
    /// delete.
    @Test func theSelfIssuedCardStillSaysTheNameCannotBeWithheld() {
        let claim = NSLocalizedString(
            "Your name is always visible. It is written inside the certificate that signs the document, and the checker needs that certificate to check the signature — so no switch can withhold it.",
            comment: "")
        #expect(CardCapability.selfIssued.limits.contains(claim))
    }

    /// And the two TWDIW ones that were measured rather than assumed: no
    /// identity-assurance signal, revocation that cannot be checked offline, and
    /// the per-card number that no disclosure switch covers.
    @Test func theGovernmentCardDeclaresEveryMeasuredLimit() {
        let expected = [
            "It does not say how carefully your identity was checked. A card issued after a counter check and one issued from a web form look the same.",
            "Whether it has been cancelled can only be known online, and the list that says so is vouched for by nothing this phone can check offline.",
            "It carries a number unique to this card that every checker sees, whichever fields you withhold.",
        ].map { NSLocalizedString($0, comment: "") }
        for claim in expected {
            #expect(CardCapability.twdiw.limits.contains(claim), "missing limit: \(claim)")
        }
    }

    /// Ours first. The comparison only means anything to a reader who already
    /// knows what the offline card does — put the government card first and the
    /// limits below it read as complaints about somebody else.
    @Test func theOfflineCardIsReadFirst() {
        #expect(CardCapability.all.first?.id == "self-issued")
        #expect(CardCapability.all.last?.id == "twdiw")
    }

    @Test func theIdentifiersAreDistinct() {
        #expect(Set(CardCapability.all.map(\.id)).count == CardCapability.all.count)
    }
}

/// The lesson from b-1, applied before the strings could ship untranslated:
/// `LocalizationCoverageTests` covered three types and not the fourth, so the
/// capability screen was in English while everything around it was not. This
/// suite exists so the same gap cannot open one type later.
@Suite("能力對照的中文覆蓋")
struct CardCapabilityLocalizationTests {

    private static let chinese: Bundle? = {
        let app = Bundle(for: VerifierViewController.self)
        guard let path = app.path(forResource: "zh-Hant", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    private static let sentinel = "__no-translation__"

    private static func readableInChinese(_ message: String) -> Bool {
        let hasHan = message.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
        if hasHan { return true }
        guard let chinese else { return false }
        return chinese.localizedString(forKey: message, value: sentinel, table: nil) != sentinel
    }

    @Test(arguments: CardCapability.all)
    func everyLineReachesAChineseReader(_ card: CardCapability) {
        for line in [card.name, card.origin] + card.proves + card.limits {
            #expect(Self.readableInChinese(line), "untranslated on \(card.id): \(line)")
        }
    }
}
