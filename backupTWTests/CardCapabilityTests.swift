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

/// # Nothing here could catch `limits` telling a lie, and one was telling one
///
/// `selfIssued.limits` said the card carries no national ID number. It does —
/// `VerifiableCredential.nationalIDClaims` sets `unifiedNo`, and issuance
/// refuses without one. The sentence was true of the *certificate* and was
/// written about the *card*.
///
/// Every other test in this file checks shape: that limits exist, that they are
/// translated, that nothing claims unlinkability. None of them compares a
/// sentence against what the credential actually contains, which is the only
/// check that would have caught it.
struct CardCapabilityHonestyTests {

    /// A field the card carries must not appear in a sentence that denies it.
    ///
    /// Keyed off the real claim keys rather than a hand-written list, so a new
    /// field added to the credential is covered the day it is added.
    @Test func noLimitDeniesAFieldTheCardActuallyCarries() {
        let model = NationalIDModel(nationality: "中華民國",
                                    unifiedNo: "A123456789",
                                    name: "王小明",
                                    birthdate: "0700101",
                                    addressOfHousehold: "臺北市中正區")
        let carried = VerifiableCredential.nationalIDClaims(model, validFrom: Date())

        // The English names a limit sentence would use for each key it must not
        // deny. Deliberately not derived from `StoredNationalID.label` — this
        // test is about the prose, and the prose is written in whole sentences.
        let denials: [String: [String]] = [
            "unifiedNo": ["carries no national ID number", "不帶身分證統一編號",
                          "does not carry a national ID number"],
            "addressOfHousehold": ["carries no address", "不帶戶籍地址"],
            "birthdate": ["carries no date of birth", "不帶出生年月日"],
        ]

        for (key, phrases) in denials where carried[key] != nil {
            for limit in CardCapability.selfIssued.limits {
                for phrase in phrases {
                    #expect(!limit.contains(phrase),
                            "the card carries \(key), and a limit denies it: \(limit)")
                }
            }
        }
    }

    /// The one field that genuinely cannot be withheld must stay named.
    ///
    /// `name` is inside the signing certificate's Subject CN, so no switch can
    /// hold it back — that is the finding this app had to correct itself about
    /// once already, and dropping it would be reverting that correction.
    @Test func theLimitThatCannotBeWithheldIsStillNamed() {
        let joined = CardCapability.selfIssued.limits.joined()
        #expect(joined.contains("name") || joined.contains("姓名"),
                "the name-is-always-visible limit has gone")
    }

    /// A limit that names a field must be talking about the card, not the
    /// certificate — the two are different objects and the confusion between
    /// them is what produced the defect.
    @Test func theCardsLimitsDoNotBorrowTheCertificatesProperties() {
        for limit in CardCapability.selfIssued.limits where limit.contains("憑證") {
            // Mentioning the certificate is fine — the name limit has to. What
            // is not fine is deriving a claim about the card's *contents* from
            // it without saying which object is meant.
            #expect(limit.contains("姓名") || limit.contains("簽章"),
                    "a limit reasons from the certificate without saying so: \(limit)")
        }
    }
}

/// The zero-knowledge card's limits must be the caveats, not a subset of them.
///
/// They were two sentences against six unconditional `ProofCaveat` cases, and
/// the four dropped included the two `ZKProver`'s own ordering comment calls
/// the ones that decide what this project can claim at all.
///
/// It also read beside the government card, which *does* declare a revocation
/// limit — so the comparison implied the zero-knowledge card did not have that
/// problem. It is strictly worse: no date field in the circuit, and an
/// unanchored revocation root.
struct ZeroKnowledgeLimitsTests {

    @Test func theLimitsAreEveryUnconditionalCaveat() {
        #expect(Set(CardCapability.zeroKnowledge.limits)
                == Set(ProofCaveat.unconditional.map(\.localizedDescription)))
        #expect(CardCapability.zeroKnowledge.limits.count >= 6,
                "only \(CardCapability.zeroKnowledge.limits.count) limits — the list has been trimmed again")
    }

    /// The two the prover's own comment singles out must be present by name.
    @Test func theTwoThatDecideWhatCanBeClaimedArePresent() {
        let joined = CardCapability.zeroKnowledge.limits.joined()
        for caveat in [ProofCaveat.signatureMaterialIsReplayable,
                       ProofCaveat.nullifierSharedAcrossVerifiers] {
            #expect(joined.contains(caveat.localizedDescription),
                    "missing the caveat that decides what this project can claim: \(caveat)")
        }
    }

    /// The proof does not establish that **you** are holding the card.
    ///
    /// The signing material is a bearer token that never expires, so anybody who
    /// has held it once can make this proof with the holder absent. A sentence
    /// whose subject is the reader claims presence the proof cannot support.
    @Test func theProvesSentenceDoesNotClaimTheReaderIsPresent() {
        let joined = CardCapability.zeroKnowledge.proves.joined()
        #expect(!joined.contains("you hold") && !joined.contains("你持有"),
                "the proof claims the reader is holding the card: \(joined)")
    }
}

/// The comparison page must not present a card this build cannot touch as if it
/// were on the same footing as the one that works.
///
/// # The defect
///
/// `twdiw.proves` said 「only the fields you switch on, **the same way as your
/// own document**」. Behind the self-issued card's version of that claim there is
/// a real `UISwitch` on a working screen; behind this one there is nothing —
/// OID4VP is milestone M5.4, and the whole repo's mention of it is three
/// comments and a plan. `comparisonCard(for:)` draws no verdict and no badge, so
/// the two cards were rendered in identical visual language on a page titled
/// 「what this app can prove」.
struct CardBuildNoteTests {

    @Test func theGovernmentCardSaysThisBuildCannotShowIt() throws {
        let note = try #require(CardCapability.twdiw.buildNote(in: .complete),
                                "the card this build has no path for carries no note")
        #expect(!note.isEmpty)
    }

    /// The note is not filed under `limits`, which is about the format forever.
    @Test func theBuildNoteIsNotSmuggledIntoTheFormatsLimits() {
        for card in CardCapability.all {
            let note = card.buildNote(in: .complete)
            #expect(note == nil || !card.limits.contains(note!))
            // Three measured limits on the government card, all about the card
            // itself. A fourth appearing here means the app-level fact was
            // filed as a property of the format.
            #expect(!card.limits.contains { $0.contains("這個版本") || $0.contains("This version") },
                    "\(card.id) files a fact about this build as a property of the card")
        }
    }

    /// The two cards this build *does* have get their note from the same
    /// switches every other screen reads.
    @Test func theOtherTwoCardsFollowTheBuildSwitches() {
        let none = BuildPaths(credential: false, zeroKnowledge: false)
        #expect(CardCapability.selfIssued.buildNote(in: .complete) == nil)
        #expect(CardCapability.zeroKnowledge.buildNote(in: .complete) == nil)
        #expect(CardCapability.selfIssued.buildNote(in: none) != nil)
        #expect(CardCapability.zeroKnowledge.buildNote(in: none) != nil)
    }

    /// No claim on this page may point at the working path to borrow its
    /// credibility.
    @Test func theGovernmentCardDoesNotCompareItselfToTheWorkingPath() {
        let joined = CardCapability.twdiw.proves.joined()
        for equation in ["the same way as your own document", "跟你自己那份文件一樣"] {
            #expect(!joined.contains(equation),
                    "the card with no path claims parity with the one that works")
        }
    }
}
