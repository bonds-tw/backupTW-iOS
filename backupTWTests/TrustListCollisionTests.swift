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
