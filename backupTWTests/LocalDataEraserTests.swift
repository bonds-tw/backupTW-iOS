//
//  LocalDataEraserTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// Each test gets its own `root` standing in for the app container: a
/// credentials directory, a scratch directory and a Documents directory, none of
/// them the real ones.
///
/// The eraser itself is built inside each test rather than stored, because it
/// holds a `CredentialStoring` existential and the suite has to stay sendable.
/// `@unchecked Sendable` because of the `UserDefaults` suite: it is not `Sendable`,
/// but this instance is created and torn down by one test and never shared.
final class LocalDataEraserTests: @unchecked Sendable {

    /// Same probe the DeviceKey suite uses: a host without the Keychain
    /// entitlement cannot exercise the identity half of the erase, and a test
    /// that silently "passed" there would be worse than one that says it did not
    /// run.
    static let keychainIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.localDataEraser.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)) != nil
    }()

    private static let sampleJWS = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJkaWQ6a2V5OnoifQ.c2ln"
    private static let pdfBytes = Data("%PDF-1.4 pretend household registration".utf8)

    private let root: URL
    private let documents: URL
    private let scratchDirectory: URL
    private let store: CredentialStore
    private let scratch: MyDataScratch

    /// Per-instance so parallel tests cannot erase each other's key, and so none
    /// of them can touch `DeviceKey.defaultTag` — the real key belonging to
    /// whoever is running the suite.
    private let keyTag: String
    private let defaults: UserDefaults
    private let defaultsSuiteName: String

    init() throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDataEraserTests-\(id)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        scratchDirectory = root.appendingPathComponent("MyDataScratch", isDirectory: true)

        keyTag = "tw.bonds.backupTW.tests.localDataEraser.\(id)"
        defaultsSuiteName = "tw.bonds.backupTW.tests.localDataEraser.\(id)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!

        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        store = try CredentialStore(directory: root.appendingPathComponent("Credentials",
                                                                           isDirectory: true))
        scratch = MyDataScratch(directory: scratchDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? DeviceKey.deleteKey(tag: keyTag, installRecord: defaults)
        UserDefaults.standard.removeSuite(named: defaultsSuiteName)
    }

    private func makeEraser(credentials: CredentialStoring? = nil) -> LocalDataEraser {
        LocalDataEraser(credentials: credentials ?? store,
                        scratch: scratch,
                        documentsDirectory: documents,
                        keyTag: keyTag,
                        installRecord: defaults)
    }

    // MARK: - The whole sweep

    /// The defect: `CredentialStore.deleteAll()` was the entire implementation of
    /// "delete my credentials", and it cannot see the plaintext the credential
    /// was made from. Tapping the button left the user's full household
    /// registration — in the clear — on disk.
    @Test func erasingTakesTheCredentialsTheScratchFilesAndTheLegacyPlaintextTogether() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        // Scratch residue: a download that never got unpacked, and a folder that
        // did, holding the decrypted PDF.
        let archive = try scratch.downloadDestination()
        try Data("PK".utf8).write(to: archive)
        let unpacked = scratchDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Self.pdfBytes.write(to: unpacked.appendingPathComponent("household.pdf"))

        // Documents residue, from the versions that downloaded there.
        try Data("PK".utf8).write(to: documents.appendingPathComponent("download.zip"))
        try Self.pdfBytes.write(to: documents.appendingPathComponent("戶籍謄本.pdf"))
        let legacyUnzip = documents.appendingPathComponent("MyDataDownload", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyUnzip, withIntermediateDirectories: true)
        try Self.pdfBytes.write(to: legacyUnzip.appendingPathComponent("household.pdf"))

        try makeEraser().eraseEverything()

        #expect(try store.allIDs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratchDirectory.path))
        // Including the folder the PDF was unpacked into, which is now empty.
        #expect(try FileManager.default.contentsOfDirectory(atPath: documents.path).isEmpty)
    }

    /// The defect this test exists for: `eraseEverything()` swept the files and
    /// left the Secure Enclave key, so the next launch re-derived the *same*
    /// `did:key`. Nothing on screen said so — the credentials really were gone —
    /// but a verifier who saw this holder before the erase and again after is
    /// handed the identical identifier, which is precisely the linkage the user
    /// pressed the button to break.
    ///
    /// Asserted at the DID rather than the raw key, because the DID is what
    /// actually leaves the device and therefore what "unlinkable" has to mean.
    @Test(.enabled(if: LocalDataEraserTests.keychainIsAvailable))
    func erasingEverythingAlsoDestroysTheIdentityThatWouldOutliveIt() throws {
        let before = try DeviceKey.loadOrCreate(tag: keyTag, installRecord: defaults)
        let didBefore = try DIDKey.did(fromP256PublicKeyX963: before.publicKeyX963)
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        try makeEraser().eraseEverything()

        // Gone, not merely unreferenced: a key still in the Keychain is a key the
        // next `loadOrCreate` adopts.
        #expect(try DeviceKey.storedKeyBacking(tag: keyTag) == nil)

        let after = try DeviceKey.loadOrCreate(tag: keyTag, installRecord: defaults)
        let didAfter = try DIDKey.did(fromP256PublicKeyX963: after.publicKeyX963)
        #expect(didAfter != didBefore,
                "re-onboarding after an erase must not present the previous identifier")
    }

    @Test func erasingTwiceInARowIsFine() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        try makeEraser().eraseEverything()
        try makeEraser().eraseEverything()

        #expect(try store.allIDs().isEmpty)
    }

    // MARK: - Partial failure

    private struct StubbornStore: CredentialStoring {
        struct Failure: Error {}
        func save(jws: String, id: String) throws { throw Failure() }
        func load(id: String) throws -> String? { throw Failure() }
        func allIDs() throws -> [String] { throw Failure() }
        func deleteAll() throws { throw Failure() }
    }

    /// The order matters and so does not stopping. If the credential files cannot
    /// be removed — device locked, file busy — bailing out there would leave the
    /// *plaintext* PDF on disk and simultaneously tell the user the erase failed,
    /// so they would believe the worst-protected copy was the one that survived.
    /// It is. Every location gets its attempt; the failure is still reported.
    @Test func thePlaintextIsStillErasedWhenTheCredentialStoreRefuses() throws {
        let archive = try scratch.downloadDestination()
        try Data("PK".utf8).write(to: archive)
        try Self.pdfBytes.write(to: documents.appendingPathComponent("戶籍謄本.pdf"))

        let eraser = makeEraser(credentials: StubbornStore())
        #expect(throws: StubbornStore.Failure.self) {
            try eraser.eraseEverything()
        }

        #expect(!FileManager.default.fileExists(atPath: scratchDirectory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: documents.path).isEmpty)
    }

    // MARK: - What the legacy sweep must not touch

    /// The Documents sweep exists for residue this app wrote. It runs over a
    /// directory that `UISupportsDocumentBrowser` used to expose to the Files
    /// app, so a user may have put their own things in there, and an erase button
    /// that quietly deletes someone's unrelated files is its own incident.
    @Test func theLegacySweepLeavesFilesThisAppNeverWroteAlone() throws {
        try Data("my notes".utf8).write(to: documents.appendingPathComponent("notes.txt"))
        let mixed = documents.appendingPathComponent("mixed", isDirectory: true)
        try FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
        try Self.pdfBytes.write(to: mixed.appendingPathComponent("household.pdf"))
        try Data("keep me".utf8).write(to: mixed.appendingPathComponent("keep.txt"))

        try makeEraser().eraseEverything()

        #expect(try FileManager.default.contentsOfDirectory(atPath: documents.path).sorted()
            == ["mixed", "notes.txt"])
        // The PDF went; the folder stayed, because something else is still in it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: mixed.path) == ["keep.txt"])
    }
}
