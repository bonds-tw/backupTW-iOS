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
    private let zkDirectory: URL
    private let store: CredentialStore
    private let scratch: MyDataScratch
    private let vaultArchive: MyDataVaultArchive
    private let officialDocumentInbox: OfficialDocumentInboxArchive

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
        // Never `CircuitAssets.defaultDirectory()`: that is the real one, and a
        // test that swept it would delete the 950 MB of proving keys belonging
        // to whoever is running the suite.
        zkDirectory = root.appendingPathComponent("ZKCircuitAssets", isDirectory: true)

        keyTag = "tw.bonds.backupTW.tests.localDataEraser.\(id)"
        defaultsSuiteName = "tw.bonds.backupTW.tests.localDataEraser.\(id)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!

        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zkDirectory.appendingPathComponent("keys"),
                                                withIntermediateDirectories: true)
        store = try CredentialStore(directory: root.appendingPathComponent("Credentials",
                                                                           isDirectory: true))
        scratch = MyDataScratch(directory: scratchDirectory)
        vaultArchive = try MyDataVaultArchive(directory: root.appendingPathComponent("MyDataVaultArchive",
                                                                                     isDirectory: true))
        officialDocumentInbox = try OfficialDocumentInboxArchive(
            directory: root.appendingPathComponent("OfficialDocumentInbox", isDirectory: true))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? DeviceKey.deleteKey(tag: keyTag, installRecord: defaults)
        UserDefaults.standard.removeSuite(named: defaultsSuiteName)
    }

    private func makeEraser(
        credentials: CredentialStoring? = nil,
        appAttestRecordEraser: (() throws -> Void)? = nil
    ) -> LocalDataEraser {
        LocalDataEraser(credentials: credentials ?? store,
                        scratch: scratch,
                        vaultArchive: vaultArchive,
                        officialDocumentInbox: officialDocumentInbox,
                        documentsDirectory: documents,
                        zkWorkingDirectory: zkDirectory,
                        keyTag: keyTag,
                        installRecord: defaults,
                        appAttestRecordEraser: appAttestRecordEraser)
    }

    /// Leaves the working directory exactly as a proof run killed by jetsam
    /// leaves it: the cardholder's certificate expanded into circuit limbs, the
    /// witness, the public instance carrying the nullifier, the proof, and the
    /// public circuit material that was there before any of it.
    private func writeProofRunResidue() throws {
        for name in ZKProver.inputFilenames {
            try Data("the holder's certificate, in limbs".utf8)
                .write(to: zkDirectory.appendingPathComponent(name))
        }
        for name in ZKProver.witnessFilenames {
            try Data("every private wire in the circuit".utf8)
                .write(to: zkDirectory.appendingPathComponent(name))
        }
        for name in ZKProver.instanceFilenames {
            try Data("public inputs, nullifier included".utf8)
                .write(to: zkDirectory.appendingPathComponent(name))
        }
        for name in ZKProver.proofFilenames {
            try Data("the proof".utf8).write(to: zkDirectory.appendingPathComponent(name))
        }
        // Public circuit material: a GitHub release, identical on every device.
        try Data("662 MB of Groth16".utf8)
            .write(to: zkDirectory.appendingPathComponent("keys/cert_chain_rs4096_proving.key"))
        try Data([0x1f, 0x8b, 0x08, 0x00])
            .write(to: zkDirectory.appendingPathComponent(ZKProver.revocationSnapshotFilename))
        try Data([0x30, 0x82, 0x06, 0x67])
            .write(to: zkDirectory.appendingPathComponent(CircuitAssets.issuerCertificateFilename))
    }

    private func zkFileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: zkDirectory.appendingPathComponent(relativePath).path)
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

    /// A vault document keeps its raw MyData original as evidence (保險箱原檔先儲存),
    /// which is the most sensitive plaintext the app keeps *on purpose*. The erase
    /// button's promise is that nothing is left, so that original has to go too —
    /// `LocalDataEraser`'s own rule is that any new on-disk identity data is swept
    /// here the day it is written.
    @Test func erasingEverythingTakesTheVaultOriginalsToo() throws {
        let src = root.appendingPathComponent("income-source.zip")
        try Data("PK the raw income record".utf8).write(to: src)
        try vaultArchive.store(originalAt: src, id: "mydata-income", fileExtension: "zip")
        #expect(vaultArchive.has(id: "mydata-income"))

        // `try?`: on a host without the Keychain entitlement the identity half of the
        // erase throws, but the eraser attempts every location regardless — the vault
        // purge still runs, which is exactly what this test is about.
        try? makeEraser().eraseEverything()

        #expect(!vaultArchive.has(id: "mydata-income"))
    }

    @Test func erasingEverythingTakesTheOfficialDocumentInboxToo() throws {
        let consent = OfficialDocumentInboxConsent(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), nonce: "erase-me")
        try officialDocumentInbox.store(OfficialDocumentInboxReceipt(
            consent: consent,
            certificate: "certificate",
            signature: "signature",
            recordedAt: Date(timeIntervalSince1970: 1_800_000_001)))
        try officialDocumentInbox.importSynthetic(OfficialDocumentSyntheticFixture.make())
        #expect(try officialDocumentInbox.receipt() != nil)
        #expect(try officialDocumentInbox.packages().count == 1)

        // The Keychain half may be unavailable on a host process, but every file
        // location still receives its erase attempt.
        try? makeEraser().eraseEverything()

        #expect(!FileManager.default.fileExists(atPath: officialDocumentInbox.directory.path))
    }

    @Test func erasingTwiceInARowIsFine() throws {
        try store.save(jws: Self.sampleJWS, id: "nationalID")

        try makeEraser().eraseEverything()
        try makeEraser().eraseEverything()

        #expect(try store.allIDs().isEmpty)
    }

    @Test func erasingEverythingAlsoForgetsTheAppAttestInstallationRecord() throws {
        final class Probe: @unchecked Sendable {
            var calls = 0
        }
        let probe = Probe()

        try makeEraser(appAttestRecordEraser: { probe.calls += 1 }).eraseEverything()

        #expect(probe.calls == 1)
    }

    // MARK: - The ZK working directory

    /// The reported defect, as the sequence that produces it: a proof run is
    /// killed by jetsam during the ~2 GB proving step, so `ZKProver.prove`'s
    /// `defer` never runs; the user relaunches, taps 「清除所有本機資料」, and is
    /// told it is done. Before this, every one of these files was still there —
    /// the certificate in limbs, the 62 MB witness, and the instance carrying
    /// the nullifier — because `eraseEverything()` swept three locations and did
    /// not know this one existed.
    ///
    /// The instance is the one that would be easiest to argue about, and it goes
    /// for the same reason the device key goes: the nullifier is a stable
    /// pseudonym for this holder at this relying party, so leaving it behind
    /// leaves the linkage the button exists to break.
    @Test func erasingEverythingSweepsWhatAKilledProofRunLeftBehind() throws {
        try writeProofRunResidue()

        try makeEraser().eraseEverything()

        for name in LocalDataEraser.proofArtifactFilenames {
            #expect(!zkFileExists(name), "\(name) survived an erase that reported success")
        }
        // Named individually as well, so that a future `proofArtifactFilenames`
        // that quietly lost a list cannot make the loop above vacuous.
        #expect(!zkFileExists("cert_chain_rs4096_input.json"))
        #expect(!zkFileExists("keys/cert_chain_rs4096_witness.bin"))
        #expect(!zkFileExists("keys/cert_chain_rs4096_instance.bin"))
    }

    /// The other half of the same promise. The proving keys are 950 MB of public
    /// Groth16 material from a GitHub release, identical on every device and
    /// about nobody; the snapshot and MOICA-G3 are public too. Erasing them
    /// would be a surprise costing the user a re-download, and it is not what
    /// the button says it does.
    @Test func theProofSweepLeavesThePublicCircuitMaterialAlone() throws {
        try writeProofRunResidue()

        try makeEraser().eraseEverything()

        #expect(zkFileExists("keys/cert_chain_rs4096_proving.key"))
        #expect(zkFileExists(ZKProver.revocationSnapshotFilename))
        #expect(zkFileExists(CircuitAssets.issuerCertificateFilename))
    }

    /// Callable on its own, because the caller it most deserves is app launch —
    /// the residue of the run that was killed exists from that moment, not from
    /// whenever the user next opens Settings. Also idempotent: finding nothing
    /// to delete is not a failure to delete it.
    @Test func theProofSweepStandsAloneAndDoesNotMindRunningTwice() throws {
        try writeProofRunResidue()

        try makeEraser().eraseProofResidue()
        try makeEraser().eraseProofResidue()

        for name in LocalDataEraser.proofArtifactFilenames {
            #expect(!zkFileExists(name), "\(name) survived a standalone sweep")
        }
        // Only the proof residue: this call is not the erase button, and the
        // credentials are not its business.
        #expect(zkFileExists("keys/cert_chain_rs4096_proving.key"))
    }

    /// A witness that could not be unlinked has to reach the sentence the user
    /// reads. `ZKProver.discardSecretArtifacts` is `try?` because it is cleanup
    /// around a proof; here the next thing that happens is an alert saying the
    /// data is gone, so silence would be the same false promise in a new place.
    ///
    /// Skipped as root, which can unlink through a directory it has no write
    /// permission on and would therefore see no failure to report.
    @Test(.enabled(if: getuid() != 0))
    func aWitnessThatCouldNotBeUnlinkedIsReportedRatherThanCalledSuccess() throws {
        try writeProofRunResidue()
        let keys = zkDirectory.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: keys.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: keys.path)
        }

        // Asserted on the sweep itself rather than on `eraseEverything()`, so
        // that a Keychain failure on the host cannot make this pass without the
        // witness having anything to do with it.
        let eraser = makeEraser()
        #expect(throws: (any Error).self) {
            try eraser.eraseProofResidue()
        }

        // The unlinkable file stops nothing: the input JSON sits at the root of
        // the working directory, is deletable, and is gone. Same rule as the
        // credential-store refusal below — every location gets its attempt.
        #expect(!zkFileExists("cert_chain_rs4096_input.json"))
        #expect(zkFileExists("keys/cert_chain_rs4096_witness.bin"),
                "the premise of this test is that this one could not be deleted")
    }

    // MARK: - Partial failure

    private struct StubbornStore: CredentialStoring {
        struct Failure: Error {}
        func save(jws: String, id: String) throws { throw Failure() }
        func load(id: String) throws -> String? { throw Failure() }
        func allIDs() throws -> [String] { throw Failure() }
        func delete(id: String) throws { throw Failure() }
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
