//
//  CopyGuideTests.swift
//  backupTWTests
//
//  The copy rules of docs/design-system.md §11, held by a test — this repo's
//  standing discipline is that a writing rule without a test is a writing rule
//  the next merge repeals (`WallCopy` and `UntrustedText` establish the
//  pattern; this extends it to the whole catalogue).
//

import Foundation
import Testing
@testable import backupTW

/// Walks every built zh-Hant sentence and holds the vocabulary, punctuation and
/// length rules the 2026-09-01 copy audit wrote down.
struct CopyGuideTests {

    /// Every zh-Hant key→value pair, from the built resources — the same
    /// artefact a reader's phone ships, not the source file.
    private static let chineseStrings: [String: String] = {
        guard let chinese = LocalizationCoverageTests.chinese,
              let url = chinese.url(forResource: "Localizable", withExtension: "strings"),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String] else {
            return [:]
        }
        return dictionary
    }()

    @Test func theCatalogueLoaded() {
        // Every rule below passes vacuously on an empty dictionary, so the
        // loading itself is the first assertion.
        #expect(Self.chineseStrings.count > 500)
    }

    /// 對人說「你」(§11.1 rule 3). The catalogue held exactly one 「您」 when the
    /// audit ran; it was fixed the same day, and this keeps it at zero.
    @Test func theAppSaysYouInformally() {
        let offenders = Self.chineseStrings.filter { $0.value.contains("您") }
        #expect(offenders.isEmpty, "「您」 found in: \(offenders.keys.sorted())")
    }

    /// 中文句子用全形逗號 (§11.3). Eleven half-width commas hid in the card-error
    /// copy for a month because nothing was looking.
    @Test func chineseSentencesUseFullWidthCommas() {
        let pattern = try! NSRegularExpression(pattern: "[\\u4E00-\\u9FFF、-〿！-｠],")
        let offenders = Self.chineseStrings.filter { _, value in
            pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        #expect(offenders.isEmpty, "half-width comma after a CJK glyph in: \(offenders.keys.sorted())")
    }

    /// App 自稱統一「這個 App」；服務名統一 bonds.tw (§11.2).
    @Test func theAppNamesItselfOneWay() {
        for needle in ["本 App", "這支 App", "bonds-tw"] {
            let offenders = Self.chineseStrings.filter { $0.value.contains(needle) }
            #expect(offenders.isEmpty, "「\(needle)」 found in: \(offenders.keys.sorted())")
        }
    }

    /// 文字牆預算 (§11.1 rule 1): a sentence a general reader must take in has
    /// no business being longer than ~90 characters — past that it is a
    /// paragraph wearing a label's clothes, and the fix is a two-layer split.
    ///
    /// The allowlist is the walls knowingly left standing, all developer-only
    /// paths (`#if DEBUG` rows with operational instructions). Adding a new
    /// long sentence means either splitting it or arguing it onto this list by
    /// name — never silently.
    @Test func noNewTextWalls() {
        let allowed: Set<String> = [
            // 公文匣 G2C sandbox consent — a DEBUG-only operational instruction.
            "This creates a non-routable address beginning with G2C-SANDBOX-NOT-ROUTABLE and receives one repository-owned test document. The sender key, recipient key and confirmation all stay in this development build. No government service is contacted, and no legal delivery is created.",
            // 實體卡測試列 — a DEBUG-only pairing instruction for a Mac-side script.
            "Keep this iPhone unlocked and connected to the Mac. In the backupTW-iOS repository, run ./scripts/physical-card-consent.sh --device mashbean14 within 15 minutes. Insert the card and enter its PIN only at the hidden terminal prompt. When the helper finishes, return here and tap the physical-card row again.",
        ]
        let offenders = Self.chineseStrings.filter { key, value in
            value.count > 90 && !allowed.contains(key)
        }
        #expect(offenders.isEmpty,
                "text walls over 90 characters: \(offenders.map { "\($0.key) (\($0.value.count))" }.sorted())")
    }
}
