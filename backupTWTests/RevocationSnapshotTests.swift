//
//  RevocationSnapshotTests.swift
//  backupTWTests
//
//  Deciding revocation from a snapshot, and refusing to when it cannot be done.
//

import Foundation
import Testing
@testable import backupTW

// MARK: - Fixtures
//
// The metadata header is written in the shape the published snapshot uses,
// measured on `moica-revocation-smt`'s own checked-in fixture
// (`go-zkid-verifier/rust/tests/data/outdated-g3-tree-snapshot.json.gz`,
// gunzipped): `{"version":1,"root":"0x…","count":115584,"depth":128,
// "crlNumber":2026050323,"nodes":[…]}`.

private func snapshotJSON(root: String = "0xa2ed" + String(repeating: "0", count: 60),
                          count: Int = 115_584,
                          crlNumber: Int = 2_026_050_323,
                          trailingNodes: Int = 3) -> Data {
    let nodes = (0 ..< trailingNodes).map { _ in "\"0x00\"" }.joined(separator: ",")
    let json = """
    {"version":1,"root":"\(root)","count":\(count),"depth":128,\
    "crlNumber":\(crlNumber),"nodes":[\(nodes)]}
    """
    return Data(json.utf8)
}

/// Answers whatever the test tells it to, so the decision logic is what is
/// under test rather than the SMT library.
private struct StubProofProvider: RevocationProofProviding {
    var root: String
    var isMember: Bool
    var verifies: Bool = true
    var returnsNothing: Bool = false

    func proof(inSnapshot snapshot: Data, forSerialNumberHex serialNumberHex: String)
        -> (root: String, isMember: Bool, verifies: Bool)? {
        returnsNothing ? nil : (root: root, isMember: isMember, verifies: verifies)
    }
}

// MARK: - Metadata

struct RevocationSnapshotInfoTests {

    @Test func readsTheHeaderTheSnapshotActuallyWrites() throws {
        let info = try #require(RevocationSnapshotInfo.parse(metadataFrom: snapshotJSON()))

        #expect(info.root == "0xa2ed" + String(repeating: "0", count: 60))
        #expect(info.crlNumber == 2_026_050_323)
        #expect(info.entryCount == 115_584)
    }

    /// The freshness marker is the snapshot's own, not the file's. A snapshot
    /// copied between devices carries the copy's mtime, and a verifier deciding
    /// how stale its list is must not be told by the filesystem.
    @Test func theCRLNumberReadsAsAMoment() throws {
        let info = try #require(RevocationSnapshotInfo.parse(metadataFrom:
            snapshotJSON(crlNumber: 2_026_050_323)))
        let generated = try #require(info.generatedAt)

        let parts = ROCDate.taipeiCalendar.dateComponents([.year, .month, .day, .hour],
                                                          from: generated)
        #expect(parts.year == 2026)
        #expect(parts.month == 5)
        #expect(parts.day == 3)
        #expect(parts.hour == 23)
    }

    /// Either the shape is wrong or a component is out of range. Both mean "this
    /// build cannot say when the list was made", which is a different statement
    /// from a wrong date — and the last case is the one that would otherwise
    /// become one: `Calendar` turns February 30th into March 2nd rather than
    /// nothing, so a snapshot with a malformed number would be reported as made
    /// on a real day it was not.
    @Test(arguments: [1, 999, 20_260_503_231, 2_026_139_923, 2_026_053_223, 2_026_023_023])
    func aCRLNumberOutsideTheDocumentedShapeYieldsNoDate(_ crl: Int) throws {
        let info = try #require(RevocationSnapshotInfo.parse(metadataFrom:
            snapshotJSON(crlNumber: crl)))

        #expect(info.generatedAt == nil)
    }

    /// Only the header is read. The node array is hundreds of megabytes
    /// decompressed and reading the metadata must not cost it.
    @Test func onlyTheHeaderIsRead() throws {
        // A header followed by a node array far past the 4 KB window.
        let big = snapshotJSON(trailingNodes: 5_000)
        #expect(big.count > 4096)

        let info = try #require(RevocationSnapshotInfo.parse(metadataFrom: big))
        #expect(info.crlNumber == 2_026_050_323)
    }

    @Test(arguments: ["{}", "{\"root\":\"nothex\",\"count\":1,\"crlNumber\":1}",
                      "{\"root\":\"0xab\",\"count\":1}", "not json at all"])
    func aHeaderThatIsNotOneIsRefused(_ raw: String) {
        #expect(RevocationSnapshotInfo.parse(metadataFrom: Data(raw.utf8)) == nil)
    }
}

// MARK: - The verdict

struct RevocationCheckTests {

    private static let root = "0xa2ed" + String(repeating: "0", count: 60)

    /// The check is handed compressed bytes, so the fixture has to be real gzip.
    private func gzipped(_ data: Data) -> Data { TestGzip.stored(data) }

    /// The ordinary answer, and the one a screen must qualify: absent from
    /// *this* snapshot, with the snapshot's own date attached.
    @Test func anAbsentSerialIsNotRevokedInThisSnapshot() throws {
        let status = RevocationCheck.status(
            serialNumberHex: "100048210dd2df2e128096a9282b5ec5",
            snapshot: gzipped(snapshotJSON()),
            provider: StubProofProvider(root: Self.root, isMember: false))

        guard case .notRevokedInThisSnapshot(let info) = status else {
            Issue.record("expected a non-membership answer, got \(status)")
            return
        }
        #expect(info.crlNumber == 2_026_050_323)
    }

    @Test func aPresentSerialIsRevoked() throws {
        let status = RevocationCheck.status(
            serialNumberHex: "100048210dd2df2e128096a9282b5ec5",
            snapshot: gzipped(snapshotJSON()),
            provider: StubProofProvider(root: Self.root, isMember: true))

        guard case .revoked = status else {
            Issue.record("expected a membership answer, got \(status)")
            return
        }
    }

    /// The published G3 snapshot is 27 MB compressed and expands past half a
    /// gigabyte. An implementation that inflates the whole thing to read three
    /// scalars does not merely run slowly — it exceeds the in-memory ceiling and
    /// fails, which arrives at the screen as "unusable" for a snapshot that is
    /// perfectly good. Two megabytes is enough to catch that; the real file
    /// would not fit in a test.
    @Test func aSnapshotFarLargerThanAnyBufferStillYieldsItsHeader() {
        let large = snapshotJSON(trailingNodes: 300_000)
        #expect(large.count > 2_000_000)

        let status = RevocationCheck.status(
            serialNumberHex: "100048210dd2df2e128096a9282b5ec5",
            snapshot: gzipped(large),
            provider: StubProofProvider(root: Self.root, isMember: false))

        guard case .notRevokedInThisSnapshot(let info) = status else {
            Issue.record("a large snapshot was rejected, got \(status)")
            return
        }
        #expect(info.crlNumber == 2_026_050_323)
    }

    /// No snapshot is not the same as a clean answer, and this is the case a
    /// screen is most likely to render alike. One is "we looked and it is not
    /// listed"; the other is "we did not look".
    @Test func noSnapshotIsNotCheckedRatherThanNotRevoked() {
        let status = RevocationCheck.status(serialNumberHex: "ab",
                                            snapshot: nil,
                                            provider: StubProofProvider(root: Self.root, isMember: false))

        #expect(status == .notChecked(reason: .snapshotUnavailable))
    }

    /// The proof must verify against the root the **snapshot** declares. Taking
    /// the proof's own word for its root is circular and would accept any
    /// internally consistent forgery.
    @Test func aProofAgainstADifferentRootIsRefused() throws {
        let status = RevocationCheck.status(
            serialNumberHex: "ab",
            snapshot: gzipped(snapshotJSON()),
            provider: StubProofProvider(root: "0xdead" + String(repeating: "0", count: 60),
                                        isMember: false))

        #expect(status == .notChecked(reason: .proofDidNotVerify))
    }

    /// A proof whose sibling path does not hash to its own claimed root is
    /// refused too — the two checks catch different things and both are needed.
    @Test func aProofThatDoesNotVerifyIsRefused() throws {
        let status = RevocationCheck.status(
            serialNumberHex: "ab",
            snapshot: gzipped(snapshotJSON()),
            provider: StubProofProvider(root: Self.root, isMember: false, verifies: false))

        #expect(status == .notChecked(reason: .proofDidNotVerify))
    }

    /// A snapshot that cannot produce a proof at all reads as unusable, never
    /// as an answer.
    @Test func aSnapshotThatYieldsNoProofIsUnusable() throws {
        let status = RevocationCheck.status(
            serialNumberHex: "ab",
            snapshot: gzipped(snapshotJSON()),
            provider: StubProofProvider(root: Self.root, isMember: false, returnsNothing: true))

        #expect(status == .notChecked(reason: .snapshotUnusable))
    }

    @Test func bytesThatAreNotASnapshotAreUnusable() {
        let status = RevocationCheck.status(
            serialNumberHex: "ab",
            snapshot: Data("not gzip".utf8),
            provider: StubProofProvider(root: Self.root, isMember: false))

        #expect(status == .notChecked(reason: .snapshotUnusable))
    }
}
