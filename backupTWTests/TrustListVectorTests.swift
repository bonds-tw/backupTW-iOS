//
//  TrustListVectorTests.swift
//  backupTWTests
//
//  Does a second implementation actually agree?
//

import Foundation
import Testing
@testable import backupTW

/// # The property the format exists for, checked instead of asserted
///
/// `canonicalForm`'s own documentation says the point is that "two
/// implementations agree byte for byte", and that a person should be able to
/// reproduce it by hand on a machine with no tooling. Until this file existed,
/// **no test involved a second implementation** — every check compared Swift
/// against Swift, which agrees with itself by construction.
///
/// That matters more here than almost anywhere else in this app. The commitment
/// is meant to be printed in a newspaper, read on the radio, or eventually put
/// on a chain, and then checked by somebody who obtained the list another way.
/// If a Python or Go reimplementation produces different bytes, the published
/// value is worthless *and nothing in this suite would say so*.
///
/// The expected values below were produced by an independent implementation
/// written from the prose — not from the Swift — and then hashed. The procedure
/// is in the comment on `expectedCommitment` so it can be repeated.
struct TrustListVectorTests {

    /// Deliberately awkward, in four specific ways.
    ///
    /// - **Two ids whose byte order and Unicode order could differ**, so the
    ///   sort is actually exercised. `zA` sorts before `zB` either way, but the
    ///   entries are *supplied* in the opposite order, so a build that forgot to
    ///   sort produces a different digest.
    /// - **CJK in `displayName`**, so any implementation that measured or
    ///   ordered by anything other than UTF-8 bytes diverges.
    /// - **An empty `note`**, because a trailing empty field is exactly what a
    ///   naive `join` or a strip-trailing-whitespace step eats.
    /// - **A mirror and a primary**, so the boolean's spelling is pinned.
    private static let list = TrustList(
        version: 1,
        publishedAt: "2026-08-18",
        entries: [
            TrustList.Entry(id: "did:key:zB", displayName: "內政部憑證管理中心",
                            note: "", isMirror: false),
            TrustList.Entry(id: "did:key:zA", displayName: "鏡像",
                            note: "備援", isMirror: true),
        ])

    /// Byte for byte, from the second implementation.
    private static let expectedCanonicalForm =
        "bonds.tw/trust-list/v1/2\n"
        + "2026-08-18\n"
        + "did:key:zA\tmirror\t鏡像\t備援\n"
        + "did:key:zB\tprimary\t內政部憑證管理中心\t\n"
        + "end\n"

    /// SHA-256 of the above.
    ///
    /// ⚠️ **Not computed by this codebase.** Produced by writing the format out
    /// again in Python from its written description and hashing the result:
    ///
    ///     lines = [f"bonds.tw/trust-list/v{v}/{len(entries)}", published_at]
    ///     for e in sorted(entries, key=lambda e: e["id"].encode("utf-8")): …
    ///     hashlib.sha256(("\n".join(lines) + "\n").encode("utf-8")).hexdigest()
    ///
    /// A constant this codebase generated would make the test agree with
    /// whatever this codebase does, which is the failure mode the whole file is
    /// written against. (The same mistake was made and caught once already, on
    /// the wall's decimal challenge constant.)
    private static let expectedCommitment =
        "79b81ee31af4d43bbc8815ba8e900417fb2bf2ae8726ffc60a388eb8fc2bc802"

    @Test func aSecondImplementationProducesTheSameBytes() {
        #expect(Self.list.canonicalForm == Self.expectedCanonicalForm)
    }

    @Test func aSecondImplementationProducesTheSameCommitment() {
        #expect(Self.list.commitment == Self.expectedCommitment)
    }

    /// Supplying the entries in the other order must not move the digest.
    ///
    /// This is what the sort is *for*: publication order is an accident of
    /// whoever assembled the file, and a digest that moved with it could not be
    /// published in advance.
    @Test func publicationOrderDoesNotMoveTheDigest() {
        let reversed = TrustList(version: Self.list.version,
                                 publishedAt: Self.list.publishedAt,
                                 entries: Self.list.entries.reversed())
        #expect(reversed.commitment == Self.expectedCommitment)
    }

    /// The trailing empty field survives.
    ///
    /// `did:key:zB` has an empty `note`, so its line ends in a tab. An
    /// implementation that trimmed trailing whitespace — or a text editor that
    /// did it on the way through — produces a different digest, and this is the
    /// difference that would be invisible on screen.
    @Test func aTrailingEmptyFieldIsPartOfTheDigest() {
        #expect(Self.list.canonicalForm.contains("內政部憑證管理中心\t\n"),
                "the empty note was trimmed, so the digest no longer matches a byte-exact reader")
    }

    /// A one-character change anywhere moves the commitment.
    ///
    /// Not a property of SHA-256 being tested — a property of every field
    /// actually reaching the digest. `note` and `displayName` are included on
    /// purpose: a list that could be relabelled without moving its commitment
    /// would let somebody rename an issuer to impersonate another while still
    /// matching a published value.
    @Test(arguments: ["displayName", "note", "id", "isMirror"])
    func everyFieldReachesTheDigest(_ field: String) {
        let original = Self.list.entries[0]
        let edited: TrustList.Entry
        switch field {
        case "displayName":
            edited = TrustList.Entry(id: original.id, displayName: original.displayName + "股份有限公司",
                                     note: original.note, isMirror: original.isMirror)
        case "note":
            edited = TrustList.Entry(id: original.id, displayName: original.displayName,
                                     note: "x", isMirror: original.isMirror)
        case "id":
            edited = TrustList.Entry(id: original.id + "x", displayName: original.displayName,
                                     note: original.note, isMirror: original.isMirror)
        default:
            edited = TrustList.Entry(id: original.id, displayName: original.displayName,
                                     note: original.note, isMirror: !original.isMirror)
        }
        let changed = TrustList(version: Self.list.version,
                                publishedAt: Self.list.publishedAt,
                                entries: [edited, Self.list.entries[1]])
        #expect(changed.commitment != Self.expectedCommitment,
                "\(field) does not reach the digest, so it can be changed after publication")
    }

    /// The entry count is in the header, so removing a row cannot produce
    /// another valid-looking list.
    @Test func theHeaderCarriesTheEntryCount() {
        #expect(Self.list.canonicalForm.hasPrefix("bonds.tw/trust-list/v1/2\n"))
        let one = TrustList(version: 1, publishedAt: Self.list.publishedAt,
                            entries: [Self.list.entries[0]])
        #expect(one.canonicalForm.hasPrefix("bonds.tw/trust-list/v1/1\n"))
    }
}
