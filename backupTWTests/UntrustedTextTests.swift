//
//  UntrustedTextTests.swift
//  backupTWTests
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// The two attacks below were run against a real build before this type existed:
/// a credential self-signed with the attacker's own key, carrying a hand-built
/// `credentialSubject`, presented to the verifier screen. Both passed
/// `OfflineVerifier` — correctly, because they *are* validly signed — and the
/// verifier screen then drew their contents as though the app had written them.
///
/// So these are not tests of a string function. They are tests that the one
/// thing this app sells — that a checker can believe what is on the screen —
/// survives contact with a stranger's document.
struct UntrustedTextTests {

    /// Verbatim from the review. A right-to-left override, a real-looking name,
    /// a pop directional formatting, two newlines, and a sentence claiming the
    /// Ministry of the Interior issued the document and checked it live. Drawn
    /// at body size under the green tick, in this app's own card style.
    private static let forgedName =
        "\u{202E}王小明\u{202C}\n\n✅ 本文件由內政部核發並經即時查驗"

    // MARK: - The forged name

    @Test func aForgedNameCannotOpenALineOfItsOwn() {
        let shown = UntrustedText.value(Self.forgedName)

        // The whole attack rests on getting onto a second line, where a sentence
        // stops looking like the tail of a name and starts looking like a field.
        #expect(shown.text.components(separatedBy: .newlines).count == 1)
        #expect(!shown.text.contains("\n"))
        // Nothing that can reorder, hide, or break what is around it survives.
        #expect(shown.text.unicodeScalars.allSatisfy { !UntrustedText.unsafeScalars.contains($0) })
        // Not silently laundered into clean-looking text: the checker sees that
        // something was taken out, and the screen says so in words.
        #expect(shown.containedControlCharacters)
        #expect(shown.text.contains("\u{FFFD}"))
        // And the part that might be somebody's actual name is still there.
        #expect(shown.text.contains("王小明"))
    }

    @Test func aRightToLeftOverrideDoesNotSurvive() {
        let shown = UntrustedText.value("\u{202E}gnp.eciov")
        #expect(!shown.text.unicodeScalars.contains("\u{202E}"))
        #expect(shown.containedControlCharacters)
    }

    /// Every code point the brief named, one at a time, so a regression names
    /// itself instead of arriving as "the forged name test broke".
    @Test(arguments: [0x202A, 0x202B, 0x202C, 0x202D, 0x202E,   // embeddings, overrides
                      0x2066, 0x2067, 0x2068, 0x2069,           // isolates
                      0x200B, 0x200E, 0x200F, 0xFEFF,           // zero-width, marks, BOM
                      0x0000, 0x0009, 0x001B, 0x007F, 0x0085,   // Cc
                      0x2028, 0x2029])                          // Zl and Zp — see below
    func everyRewritingCodePointIsRemoved(_ value: Int) throws {
        let scalar = try #require(Unicode.Scalar(UInt32(value)))
        let shown = UntrustedText.value("王" + String(scalar) + "明")
        #expect(shown.containedControlCharacters)
        #expect(!shown.text.unicodeScalars.contains(scalar))
        #expect(shown.text == "王\u{FFFD}明")
    }

    /// The reason this type does not simply use `CharacterSet.controlCharacters`
    /// the way `PresentationRequest.init` does.
    ///
    /// U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are categories Zl
    /// and Zp, not Cc or Cf, so `.controlCharacters` does not contain them —
    /// verified on this toolchain. A `UILabel` with `numberOfLines = 0` breaks a
    /// line on both of them exactly as it does on `\n`, which is the entire
    /// mechanism of the forged name above. This test fails if anybody
    /// "simplifies" `unsafeScalars` back to `.controlCharacters`.
    @Test func theTwoSeparatorsFoundationDoesNotCallControlCharacters() throws {
        for value in [0x2028, 0x2029] {
            let scalar = try #require(Unicode.Scalar(UInt32(value)))
            #expect(!CharacterSet.controlCharacters.contains(scalar))
            #expect(UntrustedText.unsafeScalars.contains(scalar))
        }
    }

    /// One marker per run, not per scalar. A value padded with five hundred
    /// zero-width spaces must not become five hundred replacement glyphs — that
    /// would hand the attacker the screen-filling attack back through the
    /// defence against it.
    @Test func aRunOfInvisibleCharactersCollapsesToOneMarker() {
        let padded = "王" + String(repeating: "\u{200B}", count: 500) + "明"
        let shown = UntrustedText.value(padded)
        #expect(shown.text == "王\u{FFFD}明")
        #expect(!shown.wasTruncated)
    }

    // MARK: - Length

    /// The other half of the review's measurement: a single `name` of twenty
    /// thousand characters, which used to be drawn in full.
    @Test func aTwentyThousandCharacterNameIsCutAndSaysSo() {
        let shown = UntrustedText.value(String(repeating: "測", count: 20_000))
        #expect(shown.wasTruncated)
        #expect(shown.text.count == UntrustedText.maximumValueLength + 1)
        #expect(shown.text.hasSuffix("…"))
    }

    /// Counted in what a reader sees. A byte or scalar limit would let 120
    /// Chinese characters — 360 bytes — through as though they were 120
    /// characters of English, or cut a name in the middle of a grapheme.
    @Test func theLimitCountsCharactersNotBytes() {
        let exactly = String(repeating: "測", count: UntrustedText.maximumValueLength)
        #expect(!UntrustedText.value(exactly).wasTruncated)
        #expect(UntrustedText.value(exactly + "測").wasTruncated)
    }

    // MARK: - Not over-reaching

    /// The failure mode on the other side: a sanitizer that mangles the real
    /// document is a verifier that refuses honest people. Every field this app
    /// issues has to come through untouched.
    @Test(arguments: ["王小明",
                      "臺北市中正區重慶南路一段122號",
                      "A123456789",
                      "0700101",
                      "中華民國（臺灣）",
                      "臺北市 中正區",          // an ordinary space survives
                      "O'Brien-Smith, Ana"])
    func anHonestFieldIsUnchanged(_ raw: String) {
        let shown = UntrustedText.value(raw)
        #expect(shown.text == raw)
        #expect(!shown.wasTruncated)
        #expect(!shown.containedControlCharacters)
    }

    /// Whitespace collapses to nothing so the screen can substitute its own
    /// 「（空白）」 rather than drawing a card with an invisible body, which reads
    /// as a rendering bug and hides that a field was disclosed at all.
    @Test func aValueOfOnlySpacesIsEmpty() {
        #expect(UntrustedText.value("   ").isEmpty)
        #expect(!UntrustedText.value("   王   ").isEmpty)
        #expect(UntrustedText.value("   王   ").text == "王")
    }

    // MARK: - Naming a field

    /// The second half of the measured attack: an unknown term used as a card
    /// title, in the same style as this build's own 「姓名」 and 「統一編號」.
    @Test func aFieldNameTheDocumentInventedIsNeverThisAppsOwnHeading() throws {
        guard case .declaredByTheDocument(let term) = ClaimLabel.label(for: "zzz_official") else {
            Issue.record("an unknown term must be marked as the document's own word")
            return
        }
        #expect(term.text == "zzz_official")

        // And the reviewer's actual payload, which was chosen to read as a
        // government endorsement the moment it is used as a heading.
        guard case .declaredByTheDocument = ClaimLabel.label(for: "内政部戶政司 已驗證") else {
            Issue.record("an unknown term must be marked as the document's own word")
            return
        }
    }

    @Test(arguments: ["name", "birthdate", "unifiedNo", "addressOfHousehold", "nationality"])
    func aTermThisBuildKnowsGetsThisAppsOwnWord(_ term: String) {
        #expect(isKnown(ClaimLabel.label(for: term)))
    }

    /// A field this app issues and signs must never be drawn as a stranger's.
    ///
    /// `over18AtIssuance` used to fall through to `.declaredByTheDocument`, so
    /// the app's own signed predicate appeared in the quotation style built to
    /// flag terms like `zzz_official`. The cost is not cosmetic: that style
    /// works because it is rare, and a checker who sees the app apply it to the
    /// app's own fields stops reading it as a warning.
    ///
    /// Referenced through `AgePredicate.claimName` rather than the literal, so
    /// that renaming the claim cannot leave this passing against a key nothing
    /// emits.
    @Test func theAppsOwnAgePredicateIsNotDressedAsAStrangersField() {
        #expect(isKnown(ClaimLabel.label(for: AgePredicate.claimName)))
    }

    /// The two sides of the app must call it the same thing.
    ///
    /// The holder sees this field through `StoredNationalID.displayKey` and the
    /// checker through `ClaimLabel`. Two independent tables naming one claim is
    /// how they drift — and the drift would show up as the holder and the
    /// checker reading different words off the same signed byte.
    @Test(arguments: ["name", "birthdate", "unifiedNo", "addressOfHousehold",
                      "nationality", AgePredicate.claimName])
    func theHolderAndTheCheckerNameEveryFieldIdentically(_ key: String) throws {
        guard case .known(let checkerWord) = ClaimLabel.label(for: key) else {
            Issue.record("\(key) is not a known term on the checker's side")
            return
        }
        // The defect this replaces: the holder ticked a switch labelled
        // 「身分證字號」 and the checker's screen said 「統一編號」 — the same
        // signed byte under two names, in a flow whose whole purpose is that
        // both people are looking at the same thing.
        #expect(checkerWord == StoredNationalID.label(for: key))
    }

    /// The checker's table must not quietly grow its own entries again.
    ///
    /// `ClaimLabel` delegates now, so this holds by construction — and that is
    /// exactly why it is worth a test: the next person who adds a `case` here
    /// to fix one screen's wording would reintroduce the split without anything
    /// failing.
    @Test func theCheckerHasNoTableOfItsOwn() {
        for key in ["nationality", "unifiedNo", "name", "birthdate",
                    "addressOfHousehold", AgePredicate.claimName, "zzz_unknown"] {
            let shared = StoredNationalID.label(for: key)
            switch ClaimLabel.label(for: key) {
            case .known(let word):
                #expect(word == shared)
            case .declaredByTheDocument:
                // Only for keys the shared table does not know, which it signals
                // by handing the key straight back.
                #expect(shared == key, "\(key) is known to the holder but not to the checker")
            }
        }
    }

    /// A field *name* is untrusted text too, and it is drawn inside a heading —
    /// the one place on the screen a checker reads as authoritative. It gets the
    /// same treatment as a value, on a tighter budget.
    @Test func aFieldNameIsSanitizedAndBounded() throws {
        guard case .declaredByTheDocument(let term) = ClaimLabel.label(for: "姓名\u{202E}\n偽造") else {
            Issue.record("expected an unknown term")
            return
        }
        #expect(!term.text.contains("\n"))
        #expect(term.text.unicodeScalars.allSatisfy { !UntrustedText.unsafeScalars.contains($0) })

        guard case .declaredByTheDocument(let long) = ClaimLabel.label(for: String(repeating: "測", count: 400)) else {
            Issue.record("expected an unknown term")
            return
        }
        #expect(long.wasTruncated)
        #expect(long.text.count == UntrustedText.maximumTermLength + 1)
    }

    // MARK: - How many rows

    /// The measured attack: forty fields of two hundred characters each, which
    /// produced forty-five cards ahead of the caveat block.
    @Test func fortyFieldsAreCappedAndTheOverflowIsStatedRatherThanDropped() {
        let claims = (0..<40).map {
            DisclosedClaim(term: "field\($0)", value: String(repeating: "測", count: 200))
        }
        let presentable = PresentableClaims(claims)

        #expect(presentable.rows.count == PresentableClaims.maximumRows)
        #expect(presentable.hiddenCount == 40 - PresentableClaims.maximumRows)

        // Silent truncation would be its own defect — how much the holder handed
        // over is a fact about their privacy that the checker is entitled to.
        #expect(presentable.hiddenCount > 0)

        // What the screen can be made to draw is now bounded by this app rather
        // than by the other device. Eight thousand characters became at most
        // twelve rows of a hundred and twenty-one.
        let drawn = presentable.rows.reduce(0) { $0 + $1.value.text.count }
        #expect(drawn <= PresentableClaims.maximumRows * (UntrustedText.maximumValueLength + 1))
        #expect(drawn < 40 * 200)
    }

    /// A real credential is nowhere near the cap, and nothing about it is
    /// hidden, reordered or rewritten on the way to the screen.
    @Test func aRealCredentialLosesNothing() {
        let claims = [DisclosedClaim(term: "name", value: "王小明"),
                      DisclosedClaim(term: "birthdate", value: "0700101"),
                      DisclosedClaim(term: "unifiedNo", value: "A123456789"),
                      DisclosedClaim(term: "addressOfHousehold", value: "臺北市中正區重慶南路一段122號"),
                      DisclosedClaim(term: "nationality", value: "中華民國（臺灣）")]
        let presentable = PresentableClaims(claims)

        #expect(presentable.hiddenCount == 0)
        #expect(presentable.rows.count == claims.count)
        #expect(presentable.rows.map(\.value.text) == claims.map(\.value))
        #expect(presentable.rows.allSatisfy { isKnown($0.label) })
    }

    /// A credential from a newer build with a couple of fields this one has
    /// never met still shows all of them.
    @Test func aFieldFromANewerCredentialIsStillShown() {
        let claims = [DisclosedClaim(term: "name", value: "王小明"),
                      DisclosedClaim(term: "bloodType", value: "O")]
        let presentable = PresentableClaims(claims)
        #expect(presentable.rows.count == 2)
        #expect(presentable.hiddenCount == 0)
        #expect(presentable.rows.last?.value.text == "O")
    }

    // MARK: - Where the blocks go

    /// The arrangement, asserted on the array `buildVerified` actually iterates.
    ///
    /// Before the fix the disclosed fields were drawn between the verdict and
    /// the caveats, so the other device decided how far down the caveats went —
    /// forty long fields put them entirely below the scroll, leaving a first
    /// screen of a green tick over a wall of official-looking rows. Capping the
    /// list narrows that; only ordering closes it.
    @Test func theCaveatsAreDrawnBeforeAnythingTheOtherDeviceSupplied() throws {
        let order = VerifiedResultSection.order
        let verdict = try #require(order.firstIndex(of: .verdict))
        let caveats = try #require(order.firstIndex(of: .whatThisCheckDidNotEstablish))
        let claims = try #require(order.firstIndex(of: .whatTheyDisclosed))

        #expect(verdict < caveats)
        #expect(caveats < claims)
    }

    /// A section that exists but has no place in `order` is a block that is
    /// never drawn; one that appears twice is drawn twice. Both are silent.
    @Test func everySectionHasExactlyOnePlaceInTheOrder() {
        #expect(VerifiedResultSection.order.count == VerifiedResultSection.allCases.count)
        #expect(Set(VerifiedResultSection.order) == Set(VerifiedResultSection.allCases))
    }

    // MARK: - Helpers

    private func isKnown(_ label: ClaimLabel) -> Bool {
        if case .known = label { return true }
        return false
    }
}

/// The same two attacks, measured where the reviewer measured them: on the
/// labels the screen actually builds.
///
/// Everything above tests the seam. These test that the screen *goes through*
/// it — a `buildVerified` that quietly went back to `PresentationUI.card(title:
/// claim.term, body: claim.value)` would leave every test in the suite above
/// passing while restoring the defect in full.
@MainActor
struct VerifiedResultScreenTests {

    /// Verbatim from the review: a self-signed credential whose `name` carries a
    /// bidirectional override and a forged 「內政部核發」 line, and an invented
    /// field name written to read as a government endorsement.
    private static func forged(fieldCount: Int = 1,
                               cardholderName: String? = nil) -> VerifiedPresentation {
        var claims = [
            DisclosedClaim(term: "name",
                           value: "\u{202E}王小明\u{202C}\n\n✅ 本文件由內政部核發並經即時查驗"),
            DisclosedClaim(term: "zzz_official", value: "内政部戶政司 已驗證"),
        ]
        claims += (0..<max(0, fieldCount - claims.count)).map {
            DisclosedClaim(term: "field\($0)", value: String(repeating: "測", count: 200))
        }
        return VerifiedPresentation(holder: "did:key:zDnaeTest",
                                    cardholderName: cardholderName,
                                    cardholderNameWasChecked: cardholderName != nil,
                                    withheldClaimCount: 0,
                                    credentialTypes: ["VerifiableCredential"],
                                    claims: claims,
                                    validFrom: Date(timeIntervalSince1970: 1_754_000_000),
                                    validUntil: nil,
                                    presentedAt: Date(timeIntervalSince1970: 1_754_400_000),
                                    caveats: VerificationCaveat.allCases,
                                    revocation: .notChecked(reason: .snapshotUnavailable))
    }

    /// In drawing order, which for a vertical `UIStackView` is reading order.
    private static func drawnText(_ presentation: VerifiedPresentation) -> [String] {
        let screen = VerificationResultViewController(outcome: .verified(presentation))
        screen.loadViewIfNeeded()

        var found: [String] = []
        func walk(_ view: UIView) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                found.append(text)
            }
            view.subviews.forEach(walk)
        }
        walk(screen.view)
        return found
    }

    /// The defect as a single assertion: nothing the other device sent can be
    /// drawn on a line of its own, so it cannot look like a field this app is
    /// asserting.
    @Test func noLabelOnTheScreenCarriesTextTheDocumentCouldBreakALineIn() {
        for text in Self.drawnText(Self.forged()) {
            #expect(text.components(separatedBy: .newlines).count == 1,
                    "a label wraps a line break the document supplied: \(text.debugDescription)")
            #expect(text.unicodeScalars.allSatisfy { !UntrustedText.unsafeScalars.contains($0) },
                    "a label carries a rewriting code point: \(text.debugDescription)")
        }
    }

    /// The ordering, measured rather than asserted about a constant. Before the
    /// fix the first caveat was drawn after every field; forty of them put it
    /// off the bottom of the screen entirely.
    @Test func theCaveatsAreBuiltBeforeAnythingTheDocumentSupplied() throws {
        let presentation = Self.forged(fieldCount: 40)
        let drawn = Self.drawnText(presentation)

        // The verdict card no longer spells its emoji into the label text — it
        // is an SF Symbol beside the sentence (design system §9.2) — so the
        // verdict is located by its sentence, which is stable and localised
        // through the same key the screen uses.
        let verdictText = NSLocalizedString(
            "They signed this check with the key in their phone", comment: "")
        let verdict = try #require(drawn.firstIndex { $0.contains(verdictText) },
                                   "the verdict is not on the screen")
        let firstCaveat = try #require(drawn.firstIndex { $0.contains(presentation.caveats[0].message) },
                                       "no caveat is on the screen")
        let lastCaveat = try #require(drawn.lastIndex { drawnText in
            presentation.caveats.contains { drawnText.contains($0.message) }
        }, "no caveat is on the screen")
        let firstClaim = try #require(drawn.firstIndex { $0.contains("王小明") },
                                      "the disclosed name is not on the screen")

        #expect(verdict < firstCaveat)
        #expect(lastCaveat < firstClaim)
    }

    /// Forty fields no longer produce forty rows, and the difference is stated
    /// on the screen rather than swallowed.
    @Test func aFloodOfFieldsIsCappedAndTheRemainderIsNamed() {
        let drawn = Self.drawnText(Self.forged(fieldCount: 40))
        let hidden = 40 - PresentableClaims.maximumRows

        #expect(!drawn.contains { $0.contains("field\(40 - PresentableClaims.maximumRows)") },
                "a field past the cap was drawn")
        #expect(drawn.contains {
            $0.contains(String(format: NSLocalizedString("This document disclosed %d more field(s) that are not shown here.",
                                                         comment: ""), hidden))
        }, "the screen does not say how many fields it left out")
    }

    /// The honest case still reads as an ID card: every field, in order, whole.
    @Test func aRealCredentialIsDrawnInFull() {
        let presentation = VerifiedPresentation(
            holder: "did:key:zDnaeTest",
            cardholderName: "王小明",
            cardholderNameWasChecked: true,
            withheldClaimCount: 0,
            credentialTypes: ["VerifiableCredential"],
            claims: [DisclosedClaim(term: "name", value: "王小明"),
                     DisclosedClaim(term: "unifiedNo", value: "A123456789"),
                     DisclosedClaim(term: "addressOfHousehold", value: "臺北市中正區重慶南路一段122號")],
            validFrom: Date(timeIntervalSince1970: 1_754_000_000),
            validUntil: nil,
            presentedAt: Date(timeIntervalSince1970: 1_754_400_000),
            caveats: VerificationCaveat.allCases,
            revocation: .notChecked(reason: .snapshotUnavailable))
        let drawn = Self.drawnText(presentation)

        for value in ["王小明", "A123456789", "臺北市中正區重慶南路一段122號"] {
            #expect(drawn.contains(value), "\(value) is not on the screen")
        }
    }

    // MARK: The revocation list's own date

    /// The caveat promises the checker that the list has a date. A date the
    /// checker cannot see is not a date, and the difference between this
    /// morning's list and a fortnight-old one is the difference between two
    /// materially different answers.
    @Test func aListThatWasConsultedSaysWhenItWasMade() {
        let drawn = Self.drawnText(Self.checked(against: RevocationSnapshotInfo(
            root: "0xa2ed", crlNumber: 2_026_050_323, entryCount: 115_584)))

        #expect(drawn.contains { $0.contains(VerificationCaveat.revocationCheckedInLocalSnapshotOnly.message) })
        // 2026-05-03 23:00 Asia/Taipei. Asserted through the year and the day
        // rather than a whole formatted string, because the formatter follows
        // the checker's locale and this test must not pin it to one.
        #expect(drawn.contains { $0.contains("2026") && $0.contains("3") },
                "the screen does not say when the revocation list was made")
    }

    /// And when nothing was consulted there is no date to show — a date beside
    /// 「無法確認是否已被撤銷」 would read as though something had been checked.
    @Test func aListThatWasNotConsultedShowsNoDate() {
        let drawn = Self.drawnText(Self.forged())

        // Matched on the rendered string rather than an English fragment: this
        // app ships in Chinese, so an English needle would find nothing and the
        // test would pass no matter what the screen drew.
        let dateLine = String(format: NSLocalizedString("That list was made on %@.",
                                                        comment: "Date of the revocation snapshot used"),
                              "")
        let stem = String(dateLine.prefix(while: { $0 != "." && $0 != "。" }))
        #expect(!stem.isEmpty)
        #expect(!drawn.contains { $0.contains(stem) },
                "a snapshot date was drawn for a check that never consulted a list")
    }

    private static func checked(against snapshot: RevocationSnapshotInfo) -> VerifiedPresentation {
        VerifiedPresentation(holder: "did:key:zDnaeTest",
                             cardholderName: "王小明",
                             cardholderNameWasChecked: true,
                             withheldClaimCount: 0,
                             credentialTypes: ["VerifiableCredential"],
                             claims: [DisclosedClaim(term: "name", value: "王小明")],
                             validFrom: Date(timeIntervalSince1970: 1_754_000_000),
                             validUntil: nil,
                             presentedAt: Date(timeIntervalSince1970: 1_754_400_000),
                             caveats: [.noNetworkQuery, .revocationCheckedInLocalSnapshotOnly],
                             revocation: .notRevokedInThisSnapshot(snapshot: snapshot))
    }

    // MARK: Who signed

    private static func whoSignedSentence(_ name: String) -> String {
        String(format: NSLocalizedString("The certificate that signed these details was issued by the government certification authority to “%@”. That names the signer — it does not mean the government checked the details below.",
                                         comment: ""), name)
    }

    /// A card-signed credential names its signer on the screen, and the section
    /// is positioned where the ordering invariant allows it: after every caveat,
    /// before anything the document disclosed.
    @Test func theSigningCardholderIsNamedAfterTheCaveatsAndBeforeTheFields() throws {
        let presentation = Self.forged(fieldCount: 3, cardholderName: "王小明")
        let drawn = Self.drawnText(presentation)

        let who = try #require(drawn.firstIndex(of: Self.whoSignedSentence("王小明")),
                               "the signer's name is not on the screen")
        let lastCaveat = try #require(drawn.lastIndex { drawnText in
            presentation.caveats.contains { drawnText.contains($0.message) }
        })
        let firstClaim = try #require(drawn.firstIndex { $0.contains("field0") || $0.contains("王小明") && $0 != Self.whoSignedSentence("王小明") })

        #expect(lastCaveat < who)
        #expect(who < firstClaim)
    }

    /// A device-signed credential draws no signer section at all — the
    /// `selfIssuedByTheHolder` caveat already covers it, and an empty heading
    /// would suggest a signer this document does not have.
    @Test func aDeviceSignedCredentialHasNoWhoSignedSection() {
        let drawn = Self.drawnText(Self.forged())

        #expect(!drawn.contains(NSLocalizedString("Who signed", comment: "")))
    }

    /// The name is certificate bytes off the other device, so it goes through
    /// the same laundering as every claim: no line breaks, no rewriting code
    /// points, bounded length. "It passed verification" is not an exemption —
    /// the DN parser accepts any DirectoryString a CA might have encoded.
    @Test func aHostileCardholderNameIsSanitizedBeforeDrawing() {
        let hostile = "\u{202E}王小明\u{202C}\n✅ 內政部已核實本文件"
        let drawn = Self.drawnText(Self.forged(cardholderName: hostile))

        for text in drawn {
            #expect(text.components(separatedBy: .newlines).count == 1,
                    "a label wraps a line break the certificate supplied: \(text.debugDescription)")
            #expect(text.unicodeScalars.allSatisfy { !UntrustedText.unsafeScalars.contains($0) },
                    "a label carries a rewriting code point: \(text.debugDescription)")
        }
        // And the section is present — sanitization must not become omission.
        #expect(drawn.contains(NSLocalizedString("Who signed", comment: "")))
    }
}
