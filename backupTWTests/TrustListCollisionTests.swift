//
//  TrustListCollisionTests.swift
//  backupTWTests
//
//  The commitment has to name exactly one list. It did not.
//

import Foundation
import Testing
@testable import backupTW

/// # The property the existing tests were not testing
///
/// `TrustListTests` checks that *particular changes* move the commitment —
/// renaming an issuer, promoting a mirror. Those are useful and they were all
/// green while the encoding was forgeable, because they ask "does this edit
/// change the digest" and never "can two different lists share one".
///
/// Injectivity is the security property. A commitment is worth publishing only
/// if it names one list, and this file is where that is asserted.
///
/// The collision below was found by a research pass on 2026-08-13 and
/// reproduced before the fix: `canonicalForm` joined fields with tab and rows
/// with newline and forbade neither inside a field, so one `note` could carry a
/// whole forged row. `note` is the field most likely to arrive through a pull
/// request — its documentation says it exists so a list "can be audited by
/// reading it".
struct TrustListCollisionTests {

    /// The forged row, spelled the way it appeared in the reproduction.
    private static let forgedRow =
        "did:key:zZEvil\tmirror\t內政部憑證管理中心（緊急換發）\t依 §5.2 啟用"

    /// One entry whose `note` smuggles a second row in after it.
    ///
    /// The identifiers matter: rows are sorted by `id`, so the smuggled row only
    /// lands where the forgery needs it when it sorts *after* its host. The
    /// first attempt at reproducing this used ids in the wrong order and saw no
    /// collision, which is a good illustration of how narrowly one can miss a
    /// real defect.
    private static var smuggler: TrustList {
        TrustList(version: TrustList.currentVersion,
                  publishedAt: "2026-08-09",
                  entries: [TrustList.Entry(id: "did:key:zAMOICA",
                                            displayName: "內政部憑證管理中心",
                                            note: "MOICA G3\n" + forgedRow,
                                            isMirror: false)])
    }

    /// The same bytes, honestly spelled: two entries, the second a mirror.
    private static var expanded: TrustList {
        TrustList(version: TrustList.currentVersion,
                  publishedAt: "2026-08-09",
                  entries: [
                    TrustList.Entry(id: "did:key:zAMOICA",
                                    displayName: "內政部憑證管理中心",
                                    note: "MOICA G3",
                                    isMirror: false),
                    TrustList.Entry(id: "did:key:zZEvil",
                                    displayName: "內政部憑證管理中心（緊急換發）",
                                    note: "依 §5.2 啟用",
                                    isMirror: true),
                  ])
    }

    /// The two lists disagree about the only thing a trust list is for.
    @Test func theTwoListsDisagreeAboutWhoIsTrusted() {
        #expect(!Self.smuggler.trusts("did:key:zZEvil"))
        #expect(Self.expanded.trusts("did:key:zZEvil"))
    }

    /// **The fix.** A field carrying a delimiter is refused, so the smuggling
    /// list cannot be validated and therefore can never be published under a
    /// commitment anybody compares.
    @Test func aFieldCarryingADelimiterIsRefused() {
        #expect(throws: TrustList.TrustListError.self) {
            try Self.smuggler.validate()
        }
    }

    /// And refused specifically for the reason that is true, because
    /// "unsupportedVersion" or "empty" here would send whoever hit it looking in
    /// the wrong place.
    @Test func theRefusalNamesTheFieldAndTheReason() {
        do {
            try Self.smuggler.validate()
            Issue.record("the smuggling list validated")
        } catch let error as TrustList.TrustListError {
            guard case .fieldContainsDelimiter(let field) = error else {
                Issue.record("refused for the wrong reason: \(error)")
                return
            }
            #expect(field.contains("note"))
            #expect(field.contains("did:key:zAMOICA"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// Even setting the refusal aside, the two no longer share a digest.
    ///
    /// Asserted separately because the two defences are independent and either
    /// could be removed by a future edit believing the other covers it. The
    /// entry count in the header is what carries this one.
    @Test func theTwoListsNoLongerShareACommitment() {
        #expect(Self.smuggler.commitment != Self.expanded.commitment)
        #expect(Self.smuggler.canonicalForm != Self.expanded.canonicalForm)
    }

    /// `publishedAt` is a field somebody types and nobody audits as though it
    /// carried trust. It is joined into the canonical form exactly like the
    /// others, so it can smuggle exactly like the others.
    @Test func publishedAtCannotSmuggleEither() {
        let list = TrustList(version: TrustList.currentVersion,
                             publishedAt: "2026-08-09\n" + Self.forgedRow,
                             entries: [TrustList.Entry(id: "did:key:zAMOICA",
                                                       displayName: "內政部憑證管理中心",
                                                       note: "MOICA G3",
                                                       isMirror: false)])
        #expect(throws: TrustList.TrustListError.self) { try list.validate() }
    }

    /// A carriage return is refused too. Not a forgery this time — a file that
    /// made a round trip through a Windows editor would otherwise change its own
    /// digest, and a list whose commitment depends on which machine last saved
    /// it is a list two honest parties can disagree about.
    @Test func aCarriageReturnIsRefusedAsWell() {
        let list = TrustList(version: TrustList.currentVersion,
                             publishedAt: "2026-08-09",
                             entries: [TrustList.Entry(id: "did:key:zAMOICA",
                                                       displayName: "內政部憑證管理中心\r",
                                                       note: "MOICA G3",
                                                       isMirror: false)])
        #expect(throws: TrustList.TrustListError.self) { try list.validate() }
    }

    /// The ordinary case still works. A fix that refused everything would pass
    /// every test above.
    @Test func anHonestListStillValidates() throws {
        try Self.expanded.validate()
        try Self.expanded.validate(expectedCommitment: Self.expanded.commitment)
    }
}

/// # Injectivity as a property, not as a list of remembered attacks
///
/// The collision above was found by reasoning about the format. These check the
/// property directly, because the next collision will not be the one anybody
/// thought of.
@Suite("正規形式的單射性")
struct TrustListInjectivityTests {

    private static func entry(_ id: String, _ name: String, _ note: String,
                              mirror: Bool = false) -> TrustList.Entry {
        TrustList.Entry(id: id, displayName: name, note: note, isMirror: mirror)
    }

    private static func list(_ entries: [TrustList.Entry],
                             publishedAt: String = "2026-08-09") -> TrustList {
        TrustList(version: TrustList.currentVersion, publishedAt: publishedAt, entries: entries)
    }

    /// **The property.** Parse the canonical form back into rows and require
    /// that it says exactly what went in. A format that round-trips cannot have
    /// two inputs sharing an output.
    @Test func theCanonicalFormRoundTrips() throws {
        let original = Self.list([
            Self.entry("did:key:zAlpha", "內政部憑證管理中心", "G3 錨"),
            Self.entry("did:key:zBeta", "境外鏡像簽發者", "緊急期備援", mirror: true),
            Self.entry("did:key:z-punctuation_.~", "邊界值", "可列印 ASCII 的兩端 !~"),
        ])
        try original.validate()

        let lines = original.canonicalForm.split(separator: "\n", omittingEmptySubsequences: false)
        // header, publishedAt, N rows, "end", and the trailing empty piece the
        // final newline leaves behind.
        #expect(lines.first == "bonds.tw/trust-list/v1/3")
        #expect(lines.dropLast().last == "end")

        let rowLines: [Substring] = Array(lines.dropFirst(2).dropLast(2))
        let rows: [[Substring]] = rowLines.map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false)
        }
        #expect(rows.count == original.entries.count)
        for row in rows { #expect(row.count == 4, "a row lost or gained a field: \(row)") }

        let recovered = rows.map {
            TrustList.Entry(id: String($0[0]), displayName: String($0[2]),
                            note: String($0[3]), isMirror: $0[1] == "mirror")
        }
        // Compared as sets: row order is the format's business, not the caller's.
        #expect(Set(recovered.map(\.id)) == Set(original.entries.map(\.id)))
        #expect(Self.list(recovered).commitment == original.commitment)
    }

    /// Rows are ordered by UTF-8 bytes, not by Swift's collation.
    ///
    /// The two agree on ASCII, Latin-1 and CJK — measured — and disagree when
    /// normalisation is involved, which is exactly the case a restricted `id`
    /// no longer admits. Both defences are asserted because either could be
    /// removed by an edit believing the other covers it.
    @Test func rowsAreOrderedByBytes() throws {
        let list = Self.list([Self.entry("did:key:za", "a", ""),
                              Self.entry("did:key:zZ", "z", ""),
                              Self.entry("did:key:z_", "u", "")])
        try list.validate()
        let bodyLines: [Substring] = Array(list.canonicalForm.split(separator: "\n").dropFirst(2).dropLast())
        let ids: [String] = bodyLines.map { line in
            String(line.split(separator: "\t")[0])
        }
        #expect(ids == ["did:key:zZ", "did:key:z_", "did:key:za"],
                "row order is not UTF-8 byte order: \(ids)")
    }

    /// An identifier outside printable ASCII is refused, so the normalisation
    /// hazard cannot enter through the field that decides row order.
    @Test func anIdentifierOutsidePrintableASCIIIsRefused() {
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([Self.entry("did:key:z內政部", "x", "")]).validate()
        }
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([Self.entry("did:key:ze\u{0301}", "x", "")]).validate()
        }
    }

    /// Bidirectional overrides are refused everywhere. A value that can reorder
    /// the line it is printed on makes a human read a different list from the
    /// one the machine hashed — which is the exact failure this format exists to
    /// prevent, arriving through presentation rather than through parsing.
    @Test func bidirectionalOverridesAreRefused() {
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([Self.entry("did:key:zA", "內政部\u{202E}憑證管理中心", "")]).validate()
        }
    }

    /// A field cannot be made unbounded.
    @Test func anEnormousFieldIsRefused() {
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([Self.entry("did:key:zA", "x", String(repeating: "n", count: 600))]).validate()
        }
    }

    /// Truncation is a parse failure, not a shorter list with a valid digest.
    @Test func theCanonicalFormIsExplicitlyTerminated() throws {
        let list = Self.list([Self.entry("did:key:zA", "x", "")])
        try list.validate()
        #expect(list.canonicalForm.hasSuffix("\nend\n"))
    }
}

/// # What an adversarial pass found after the first fix
///
/// Four independent attackers were pointed at canonical form v2. Fifteen
/// findings survived their own verification pass; these are the three graded
/// high, each reproduced here from the construction the attacker supplied.
///
/// All three share a shape worth naming: none of them is a hash collision. They
/// are **disagreements about what the published bytes say** — between the app
/// and a human, or between the app and any other parser. A commitment is a
/// promise that one value names one list, and a list only has one meaning if
/// every reader recovers the same one.
@Suite("對抗式審查抓到的三個 high")
@MainActor
struct TrustListAdversarialTests {

    private static func list(_ entries: [TrustList.Entry],
                             publishedAt: String = "2026-08-09") -> TrustList {
        TrustList(version: TrustList.currentVersion, publishedAt: publishedAt, entries: entries)
    }

    /// **U+2028 LINE SEPARATOR is category Zl, so it is not a control character.**
    ///
    /// It passed `CharacterSet.controlCharacters` while every line-splitter on
    /// the machine — Foundation, the Swift stdlib, CoreText, Python — treats it
    /// as a line break. A `note` carrying one plus a forged row and a second
    /// `end` produces a document whose header count and terminator both agree
    /// with a reading that names a different issuer from the one the app trusts.
    @Test func aLineSeparatorCannotEnterAField() {
        let forged = "MOICA G3\u{2028}did:key:zBackup\u{3000}primary\u{3000}備援\u{3000}x\u{2028}end"
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([TrustList.Entry(id: "did:key:zAMOICA", displayName: "內政部憑證管理中心",
                                           note: forged, isMirror: false)]).validate()
        }
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([TrustList.Entry(id: "did:key:zA", displayName: "x",
                                           note: "a\u{2029}b", isMirror: false)]).validate()
        }
    }

    /// **Duplicate JSON keys: Foundation takes the first, everyone else the last.**
    ///
    /// Measured, not assumed: `{"publishedAt":"A","publishedAt":"B"}` decodes to
    /// `A` under `JSONDecoder` and to `B` under Python's `json`. One file, two
    /// readings, therefore two commitments — the exact disagreement between two
    /// honest parties that the canonical form exists to make impossible.
    @Test func aDocumentWithDuplicateKeysIsRefused() throws {
        let honest = Self.list([TrustList.Entry(id: "did:key:zA", displayName: "內政部憑證管理中心",
                                                note: "G3", isMirror: false)])
        let bytes = try honest.encoded()
        let text = try #require(String(data: bytes, encoding: .utf8))
        // A second `publishedAt`, inserted after the first.
        let doubled = text.replacingOccurrences(
            of: "\"publishedAt\" : \"2026-08-09\"",
            with: "\"publishedAt\" : \"2026-08-09\",\n  \"publishedAt\" : \"2099-01-01\"")
        #expect(doubled != text, "the fixture's formatting changed; this test is no longer testing anything")

        #expect(throws: (any Error).self) {
            try TrustList.decoded(from: Data(doubled.utf8))
        }
    }

    /// **The commitment covers only the fields this build models**, so anything
    /// else in the published JSON is readable by a reviewer and invisible to the
    /// digest. Re-encoding and comparing bytes is what closes it.
    @Test func aDocumentCarryingUnmodelledFieldsIsRefused() throws {
        let honest = Self.list([TrustList.Entry(id: "did:key:zA", displayName: "內政部憑證管理中心",
                                                note: "G3", isMirror: false)])
        let text = try #require(String(data: try honest.encoded(), encoding: .utf8))
        let annotated = text.replacingOccurrences(
            of: "\"version\" : 1",
            with: "\"authority\" : \"依行政院 2026-08 函示啟用\",\n  \"version\" : 1")

        #expect(throws: (any Error).self) {
            try TrustList.decoded(from: Data(annotated.utf8))
        }
    }

    /// An honest document still round-trips. A fix that refused everything would
    /// pass all three tests above.
    @Test func anHonestDocumentStillDecodes() throws {
        let honest = Self.list([TrustList.Entry(id: "did:key:zA", displayName: "內政部憑證管理中心",
                                                note: "G3", isMirror: false)])
        let decoded = try TrustList.decoded(from: try honest.encoded(),
                                            expectedCommitment: honest.commitment).list
        #expect(decoded == honest)
    }

    /// An empty identifier used to validate, because `allSatisfy` over nothing is
    /// vacuously true — and `trusts("")` then answered yes, so a credential whose
    /// issuer field is empty was on the list.
    @Test func anEmptyIdentifierIsRefused() {
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([TrustList.Entry(id: "", displayName: "x", note: "", isMirror: false)]).validate()
        }
    }
}

/// The medium and low findings from the same adversarial pass, closed.
@Suite("對抗式審查的其餘發現")
struct TrustListRemainingFindingsTests {

    private static func list(_ entries: [TrustList.Entry]) -> TrustList {
        TrustList(version: TrustList.currentVersion, publishedAt: "2026-08-09", entries: entries)
    }

    /// `trusts` compares bytes, not Swift strings.
    ///
    /// Swift's `==` is Unicode canonical equivalence, so a decomposed spelling
    /// of a listed identifier used to answer yes while hashing to different
    /// bytes. Identifiers are now printable ASCII so the case cannot be
    /// constructed through `validate()` — this asks the question directly, of a
    /// list that was never validated, because nothing stops a caller doing that.
    @Test func membershipIsAnsweredOnBytes() {
        let list = Self.list([TrustList.Entry(id: "did:key:zé", displayName: "x",
                                              note: "", isMirror: false)])
        // Precomposed on the list, decomposed in the question. Swift says these
        // two strings are equal; their bytes are not.
        #expect("did:key:z\u{00E9}" == "did:key:ze\u{0301}")
        #expect(list.trusts("did:key:z\u{00E9}"))
        #expect(!list.trusts("did:key:ze\u{0301}"),
                "membership answered on canonical equivalence rather than bytes")
    }

    /// `version` in the JSON can be spelled in ways that decode to the same
    /// integer — `1.0`, `1e0` — and the canonical form's header would then be
    /// reproducible from the parse but not from the file.
    ///
    /// Closed by the round-trip rule rather than by a spelling check: re-encoding
    /// the parse emits `1`, which is not the bytes that arrived.
    @Test func aNonIntegralVersionSpellingIsRefused() throws {
        let honest = Self.list([TrustList.Entry(id: "did:key:zA", displayName: "x",
                                                note: "", isMirror: false)])
        let text = try #require(String(data: try honest.encoded(), encoding: .utf8))
        let respelled = text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 1.0")
        #expect(respelled != text)
        #expect(throws: (any Error).self) {
            try TrustList.decoded(from: Data(respelled.utf8))
        }
    }

    /// The forbidden set really does cover the format characters the comment now
    /// claims it covers. Asserted rather than described, because the previous
    /// version of that comment was wrong about its own set.
    @Test func formatCharactersAreRefused() {
        for scalar in ["\u{200B}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{061C}"] {
            #expect(throws: TrustList.TrustListError.self) {
                try Self.list([TrustList.Entry(id: "did:key:zA", displayName: "內政部\(scalar)",
                                               note: "", isMirror: false)]).validate()
            }
        }
    }

    /// A forbidden scalar inside a grapheme cluster is caught, because
    /// `rangeOfCharacter(from:)` matches scalars rather than Characters.
    @Test func aForbiddenScalarCannotHideInsideAGraphemeCluster() {
        // CRLF is one Character and two scalars.
        #expect("\r\n".count == 1)
        #expect(throws: TrustList.TrustListError.self) {
            try Self.list([TrustList.Entry(id: "did:key:zA", displayName: "x\r\ny",
                                           note: "", isMirror: false)]).validate()
        }
    }
}

/// `Provenance` — 「沒有預期值不算通過」從註解變成型別
@Suite("來源")
struct TrustListProvenanceTests {

    private static func list() -> TrustList {
        TrustList(version: TrustList.currentVersion,
                  publishedAt: "2026-08-09",
                  entries: [TrustList.Entry(id: "did:key:zA", displayName: "內政部憑證管理中心",
                                            note: "G3", isMirror: false)])
    }

    /// **The point of the type.** Validating without an expectation is well
    /// formed and unconfirmed, and now a caller has to look at that rather than
    /// read a comment about it.
    @Test func validatingWithoutAnExpectationIsUnconfirmed() throws {
        #expect(try Self.list().validate() == .unconfirmed)
    }

    @Test func matchingASuppliedExpectationSaysSo() throws {
        let list = Self.list()
        #expect(try list.validate(expectedCommitment: list.commitment)
                == .matchedSuppliedExpectation(commitment: list.commitment))
    }

    /// The provenance travels out of `decoded` with the list, so a caller cannot
    /// end up holding one without the other.
    @Test func decodingCarriesTheProvenance() throws {
        let list = Self.list()
        let bytes = try list.encoded()

        let unconfirmed = try TrustList.decoded(from: bytes)
        #expect(unconfirmed.provenance == .unconfirmed)

        let confirmed = try TrustList.decoded(from: bytes, expectedCommitment: list.commitment)
        #expect(confirmed.provenance == .matchedSuppliedExpectation(commitment: list.commitment))
    }

    /// Matching a value somebody typed proves the list is the one they meant,
    /// and nothing about whether they meant the right one. Asserted so that the
    /// case name is never quietly upgraded to something like `.trusted`.
    @Test func theConfirmedCaseIsNamedAfterWhatItActuallyEstablishes() {
        let provenance = TrustList.Provenance.matchedSuppliedExpectation(commitment: "abc")
        #expect(String(describing: provenance).contains("Supplied"),
                "the case was renamed to something that claims more than it establishes")
    }
}
