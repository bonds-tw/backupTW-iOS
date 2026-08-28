//
//  CredentialStoreTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// Every test runs against its own throwaway directory. Nothing here ever
/// constructs `CredentialStore()` with the default location — that would write
/// into the test host's real Application Support directory and leave credentials
/// behind after the run.
///
/// A `final class` suite rather than a struct so `deinit` can clean up; Swift
/// Testing makes a fresh instance per test, so the sandbox is per-test too.
final class CredentialStoreTests: Sendable {

    private static let storeFolderName = "Credentials"
    private static let sampleJWS = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJkaWQ6a2V5OnoifQ.c2ln"

    /// The store lives one level inside `root` so that "did anything escape?"
    /// can be answered by listing `root`, which only this test writes to.
    private let root: URL
    private let directory: URL
    private let store: CredentialStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialStoreTests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent(Self.storeFolderName, isDirectory: true)
        store = try CredentialStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Round trip

    @Test func savesAndLoadsBackTheSameString() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")
        #expect(try store.load(id: "nationalID") == Self.sampleJWS)
    }

    @Test func loadReturnsNilForAnIdentifierNeverSaved() throws {
        #expect(try store.load(id: "nationalID") == nil)
    }

    /// The credential has to survive the process, not just the instance.
    @Test func aSecondStoreSeesWhatTheFirstWrote() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        let reopened = try CredentialStore(directory: directory)
        #expect(try reopened.load(id: "nationalID") == Self.sampleJWS)
        #expect(try reopened.allIDs() == ["nationalID"])
    }

    /// Identifiers are not restricted to ASCII, so the encoding has to be
    /// byte-exact rather than lossy.
    @Test(arguments: [
        "nationalID",
        "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv",
        "身分證",
        "a b\tc",
        "🪪",
    ])
    func identifiersRoundTripVerbatim(id: String) throws {
        try store.save(jws: Self.sampleJWS, id: id)
        #expect(try store.load(id: id) == Self.sampleJWS)
        #expect(try store.allIDs() == [id])
    }

    // MARK: - Overwrite

    @Test func savingTheSameIdentifierTwiceReplacesTheCredential() throws {
        try store.save(jws: "first.credential.signature", id: "nationalID")
        try store.save(jws: "second.credential.signature", id: "nationalID")

        #expect(try store.load(id: "nationalID") == "second.credential.signature")
        #expect(try store.allIDs() == ["nationalID"])
        // One identifier must mean one file, not a second copy of the old one
        // lingering next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    // MARK: - allIDs

    @Test func allIDsIsEmptyForAFreshStore() throws {
        #expect(try store.allIDs().isEmpty)
    }

    @Test func allIDsReportsEverySavedIdentifier() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")
        try store.save(jws: Self.sampleJWS, id: "driverLicense")
        try store.save(jws: Self.sampleJWS, id: "健保卡")

        #expect(try store.allIDs() == ["driverLicense", "nationalID", "健保卡"].sorted())
    }

    /// A file we did not write must not become a phantom credential.
    @Test func allIDsIgnoresForeignFiles() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")
        try Data("notes".utf8).write(to: directory.appendingPathComponent("README.txt"))
        try Data("notes".utf8).write(to: directory.appendingPathComponent("nothex.jws"))
        try Data("notes".utf8).write(to: directory.appendingPathComponent("6E6F7455.jws"))

        #expect(try store.allIDs() == ["nationalID"])
    }

    // MARK: - deleteAll

    @Test func deleteAllRemovesEveryCredentialAndItsFile() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")
        try store.save(jws: Self.sampleJWS, id: "driverLicense")
        // A leftover from an interrupted atomic write; the sweep must take it too.
        try Data("half written".utf8).write(to: directory.appendingPathComponent(".tmp-leftover"))

        try store.deleteAll()

        #expect(try store.allIDs().isEmpty)
        #expect(try store.load(id: "nationalID") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// "Delete everything" is a button the user can press mid-session, so the
    /// store has to keep working afterwards.
    @Test func theStoreIsStillUsableAfterDeleteAll() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")
        try store.deleteAll()
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        #expect(try store.load(id: "nationalID") == Self.sampleJWS)
    }

    @Test func deleteAllOnAnEmptyStoreSucceeds() throws {
        try store.deleteAll()
        #expect(try store.allIDs().isEmpty)
    }

    // MARK: - delete(id:)

    /// The property that separates this from `deleteAll`: removing one card must
    /// leave every other card exactly where it was. A holder clearing a stray
    /// demo card cannot be made to lose their national ID beside it.
    @Test func deleteRemovesOnlyTheNamedCredential() throws {
        try store.save(jws: "national.credential.signature", id: "nationalID")
        try store.save(jws: "license.credential.signature", id: "driverLicense")

        try store.delete(id: "driverLicense")

        #expect(try store.load(id: "driverLicense") == nil)
        // The other card is untouched — same bytes, still listed.
        #expect(try store.load(id: "nationalID") == "national.credential.signature")
        #expect(try store.allIDs() == ["nationalID"])
        // Exactly one file remains: the deleted card left no residue and the
        // survivor was not rewritten.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    /// A deleted card stops being listed and stops loading — the two questions the
    /// home screen asks after a delete.
    @Test func deleteMakesAllIDsAndLoadForgetTheCredential() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")
        #expect(try store.allIDs() == ["nationalID"])

        try store.delete(id: "nationalID")

        #expect(try store.allIDs().isEmpty)
        #expect(try store.load(id: "nationalID") == nil)
    }

    /// Idempotent by contract: deleting an id with no file is success, not an
    /// error. A card already gone — removed on another screen, or a double tap —
    /// must read as 「it is gone」, which is what was asked.
    @Test func deletingAnIdentifierThatWasNeverSavedDoesNotThrow() throws {
        // Never-saved, and — to prove it is not merely emptiness that is tolerated
        // — a second real card present that must survive the no-op.
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        try store.delete(id: "neverSaved")

        #expect(try store.allIDs() == ["nationalID"])
    }

    @Test func deletingFromAnEmptyStoreSucceeds() throws {
        try store.delete(id: "nationalID")
        #expect(try store.allIDs().isEmpty)
    }

    /// Deleting once then again is the same as deleting once — the second call
    /// meets an absent file and treats it as done.
    @Test func deletingTheSameCredentialTwiceIsHarmless() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        try store.delete(id: "nationalID")
        try store.delete(id: "nationalID")

        #expect(try store.load(id: "nationalID") == nil)
    }

    /// `delete` addresses the exact file `save` wrote, through the same
    /// hex-encoding, so an identifier that is not usable as a file name fails at
    /// the call site rather than removing something unexpected.
    @Test func deleteRejectsAnEmptyIdentifier() {
        #expect(throws: CredentialStoreError.invalidIdentifier) {
            try self.store.delete(id: "")
        }
    }

    /// The store must keep working after a single delete, exactly as after
    /// `deleteAll` — the same identifier can be saved again.
    @Test func theStoreIsStillUsableAfterASingleDelete() throws {
        try store.save(jws: "first", id: "nationalID")
        try store.delete(id: "nationalID")
        try store.save(jws: "second", id: "nationalID")

        #expect(try store.load(id: "nationalID") == "second")
    }

    // MARK: - Hostile identifiers

    /// None of these may produce a file outside `directory`, and all of them
    /// must still round-trip — sanitising that silently rewrites an identifier
    /// would be its own bug.
    @Test(arguments: [
        "../../etc/passwd",
        "../escape",
        "..",
        ".",
        "/etc/passwd",
        "nested/child",
        "....//....//escape",
        "~/escape",
        "%2e%2e%2fescape",
        "\u{0}truncated",
        "..\\windows",
    ])
    func hostileIdentifiersCannotEscapeTheDirectory(id: String) throws {
        try store.save(jws: Self.sampleJWS, id: id)

        // Nothing appeared beside the store directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [Self.storeFolderName])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("etc").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("nested").path))

        // Exactly one file, named from the hex alphabet only — a separator is
        // not representable in that alphabet, which is what makes traversal
        // impossible rather than merely filtered.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 1)
        let name = try #require(names.first)
        #expect(name.hasSuffix(".jws"))
        #expect(name.dropLast(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })

        #expect(try store.load(id: id) == Self.sampleJWS)
        #expect(try store.allIDs() == [id])
    }

    @Test func emptyIdentifierIsRejected() {
        #expect(throws: CredentialStoreError.invalidIdentifier) {
            try self.store.save(jws: Self.sampleJWS, id: "")
        }
        #expect(throws: CredentialStoreError.invalidIdentifier) {
            _ = try self.store.load(id: "")
        }
    }

    @Test func overlongIdentifierIsRejectedRatherThanTruncated() {
        // 126 bytes: one past what a 255-byte file name can carry once hexed.
        let id = String(repeating: "a", count: 126)
        #expect(throws: CredentialStoreError.invalidIdentifier) {
            try self.store.save(jws: Self.sampleJWS, id: id)
        }
    }

    @Test func identifierAtTheLengthLimitIsAccepted() throws {
        let id = String(repeating: "a", count: 125)
        try store.save(jws: Self.sampleJWS, id: id)
        #expect(try store.load(id: id) == Self.sampleJWS)
    }

    // MARK: - Damaged storage

    /// A file that is not UTF-8 cannot be the JWS we wrote. It must not be
    /// reported as "no such credential", or the UI would tell the user to
    /// re-issue something that is actually sitting right there, damaged.
    @Test func unreadableBytesSurfaceAsAnErrorNotAsAbsence() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        let name = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        try Data([0xff, 0xfe, 0xff]).write(to: directory.appendingPathComponent(name))

        #expect(throws: CredentialStoreError.corruptedCredential(id: "nationalID")) {
            _ = try self.store.load(id: "nationalID")
        }
    }

    // MARK: - Backup exclusion

    /// The whole premise of the app is that an identity credential does not
    /// leave the phone; an iCloud backup would be exactly that.
    @Test func theDirectoryIsExcludedFromBackup() throws {
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func backupExclusionIsReappliedAfterDeleteAll() throws {
        try store.deleteAll()

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
