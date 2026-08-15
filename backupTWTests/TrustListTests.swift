//
//  TrustListTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

@Suite("信任清單")
struct TrustListTests {

    private static func list(entries: [TrustList.Entry]? = nil,
                             version: Int = TrustList.currentVersion) -> TrustList {
        TrustList(version: version,
                  publishedAt: "2026-08-09T00:00:00Z",
                  entries: entries ?? [
                    TrustList.Entry(id: "did:key:zPrimary", displayName: "內政部憑證管理中心",
                                    note: "MOICA-G3", isMirror: false),
                    TrustList.Entry(id: "did:key:zMirror", displayName: "境外鏡像簽發者",
                                    note: "緊急期備援", isMirror: true)
                  ])
    }

    /// The digest has to be over a canonical form, not over "the file as it
    /// arrived". Two verifiers who obtained the same list by different routes
    /// must compute the same value, or comparing commitments proves nothing.
    @Test("發佈順序不影響承諾值")
    func commitmentIsIndependentOfEntryOrder() {
        let forwards = Self.list()
        let backwards = TrustList(version: forwards.version,
                                  publishedAt: forwards.publishedAt,
                                  entries: forwards.entries.reversed())
        #expect(forwards.commitment == backwards.commitment)
    }

    /// A list that could be relabelled without changing its digest would let
    /// somebody rename an issuer to impersonate another while still matching a
    /// published value.
    @Test("改了顯示名稱，承諾值就會變")
    func renamingAnIssuerChangesTheCommitment() {
        let original = Self.list()
        let renamed = TrustList(
            version: original.version,
            publishedAt: original.publishedAt,
            entries: original.entries.map {
                $0.id == "did:key:zMirror"
                    ? TrustList.Entry(id: $0.id, displayName: "內政部憑證管理中心",
                                      note: $0.note, isMirror: $0.isMirror)
                    : $0
            })
        #expect(original.commitment != renamed.commitment)
    }

    /// Promoting a mirror to primary is exactly the change an attacker would
    /// want to make silently.
    @Test("把鏡像改成主要簽發者，承諾值就會變")
    func promotingAMirrorChangesTheCommitment() {
        let original = Self.list()
        let promoted = TrustList(
            version: original.version,
            publishedAt: original.publishedAt,
            entries: original.entries.map {
                TrustList.Entry(id: $0.id, displayName: $0.displayName,
                                note: $0.note, isMirror: false)
            })
        #expect(original.commitment != promoted.commitment)
    }

    @Test("承諾值不符就拒絕，並說出兩邊各是什麼")
    func refusesAMismatchedCommitment() {
        let list = Self.list()
        #expect(throws: TrustList.TrustListError.commitmentMismatch(
            expected: "deadbeef", actual: list.commitment)) {
            try list.validate(expectedCommitment: "deadbeef")
        }
        #expect(throws: Never.self) {
            try list.validate(expectedCommitment: list.commitment)
        }
        // Case is not a difference: a hex digest differing only in case is the
        // same digest, and refusing it would be a false alarm during exactly the
        // emergency this list is for.
        #expect(throws: Never.self) {
            try list.validate(expectedCommitment: list.commitment.uppercased())
        }
    }

    /// Two entries for one issuer can disagree about `isMirror`, and which one
    /// wins would then depend on iteration order.
    @Test("同一個簽發者出現兩次就拒收")
    func refusesDuplicateIssuers() {
        let entry = TrustList.Entry(id: "did:key:zSame", displayName: "甲",
                                    note: "", isMirror: false)
        let clash = TrustList.Entry(id: "did:key:zSame", displayName: "乙",
                                    note: "", isMirror: true)
        #expect(throws: TrustList.TrustListError.duplicateIssuer("did:key:zSame")) {
            try Self.list(entries: [entry, clash]).validate()
        }
    }

    @Test("空清單與不認得的版本都拒收，不猜")
    func refusesEmptyAndUnknownVersions() {
        #expect(throws: TrustList.TrustListError.empty) {
            try Self.list(entries: []).validate()
        }
        #expect(throws: TrustList.TrustListError.unsupportedVersion(99)) {
            try Self.list(version: 99).validate()
        }
    }

    @Test("可以來回轉換，且解出來就已經驗過")
    func roundTripsAndValidatesOnDecode() throws {
        let list = Self.list()
        let decoded = try TrustList.decoded(from: try list.encoded(),
                                            expectedCommitment: list.commitment).list
        #expect(decoded == list)
        #expect(decoded.trusts("did:key:zMirror"))
        #expect(!decoded.trusts("did:key:zNobody"))
        #expect(decoded.entry(for: "did:key:zMirror")?.isMirror == true)
    }

    /// A decode that produced an unvalidated list would leave a window in which
    /// something could ask it a question before anyone checked it.
    @Test("承諾值不符時，decoded 不會回傳一份清單")
    func decodingRefusesAMismatchedCommitment() throws {
        let data = try Self.list().encoded()
        #expect(throws: (any Error).self) {
            _ = try TrustList.decoded(from: data, expectedCommitment: "00").list
        }
    }

    /// The canonical form is meant to be reproducible by hand, on a machine with
    /// no JSON canonicaliser, by someone checking a published digest.
    @Test("正規形式是人看得懂、手抄得出來的")
    func canonicalFormIsLegible() {
        let text = Self.list().canonicalForm
        // The header carries the entry count as well as the version, and this
        // assertion moved when it was added. See `TrustListCollisionTests`: a
        // row used to be smuggleable through a `note`, and the count is the
        // half of the fix that makes such a thing visible in the digest even if
        // the delimiter check is ever weakened. Legible by hand is unaffected —
        // a person copying this out counts the rows, which they were going to
        // read anyway.
        #expect(text.hasPrefix("bonds.tw/trust-list/v1/2\n2026-08-09T00:00:00Z\n"))
        #expect(text.hasSuffix("end\n"))
        #expect(text.contains("did:key:zMirror\tmirror\t境外鏡像簽發者\t緊急期備援"))
        #expect(text.hasSuffix("\n"))
    }
}
