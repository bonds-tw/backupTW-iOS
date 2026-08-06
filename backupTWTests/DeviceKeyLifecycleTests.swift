//
//  DeviceKeyLifecycleTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// The device key *is* the identity: `did:key` is a transformation of its public
/// key and nothing else. So the questions these ask are not really about key
/// management, they are the unlinkability claim in §5.2 restated as code — can
/// the holder stop being this identifier, and does the app ever keep being one
/// identifier when it promised not to.
///
/// A `final class` so `deinit` can clean up, and every test works under a tag and
/// a defaults suite unique to its own instance: Swift Testing runs tests in
/// parallel, and the Keychain is a single process-wide namespace that would
/// otherwise let two tests delete each other's keys.
///
/// `@unchecked` because `UserDefaults` is not `Sendable`. Held anyway rather
/// than rebuilt per use, since the suite has to be the *same* object a test
/// writes to and `deinit` tears down; the instance never leaves the one test
/// that owns it, which is the guarantee the compiler cannot see.
final class DeviceKeyLifecycleTests: @unchecked Sendable {

    private let tag: String
    /// Stands in for the app container's Preferences — the store iOS destroys
    /// along with the app. A fresh suite is a fresh install.
    private let installRecordName: String
    private let installRecord: UserDefaults
    private let root: URL

    init() throws {
        let unique = UUID().uuidString
        tag = "tw.bonds.backupTW.tests.deviceKeyLifecycle.\(unique)"
        installRecordName = "tw.bonds.backupTW.tests.install.\(unique)"
        installRecord = try #require(UserDefaults(suiteName: installRecordName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceKeyLifecycleTests-\(unique)", isDirectory: true)
    }

    deinit {
        try? DeviceKey.deleteKey(tag: tag, installRecord: installRecord)
        UserDefaults.standard.removePersistentDomain(forName: installRecordName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Generating a key needs a reachable Keychain, which a test bundle does not
    /// always have (`errSecMissingEntitlement`). That is an environment problem,
    /// not a defect, so the tests that need one disable themselves rather than
    /// report red. Same reasoning as `VerifiableCredentialTests`.
    static let keychainIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.deviceKeyLifecycle.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)) != nil
    }()

    private func store() throws -> CredentialStore {
        try CredentialStore(directory: root.appendingPathComponent("Credentials", isDirectory: true))
    }

    // MARK: - Rotation

    /// The property the user is actually promised: after a reset they are a
    /// different holder. Public key inequality is the strongest form of the
    /// claim, because the DID is a pure function of these bytes — equal keys
    /// would mean an equal DID with no further argument needed.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func deletingTheKeyMakesTheNextIdentityADifferentOne() throws {
        let first = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        try DeviceKey.deleteKey(tag: tag, installRecord: installRecord)
        let second = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        #expect(first.publicKeyX963 != second.publicKeyX963)
        #expect(try DIDKey.did(fromP256PublicKeyX963: first.publicKeyX963)
                != DIDKey.did(fromP256PublicKeyX963: second.publicKeyX963))
    }

    /// The other half, and the reason rotation cannot simply be "always
    /// regenerate": within one install the key has to be stable, or every
    /// relaunch invalidates the credential the user is standing in a queue
    /// holding.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func loadingWithoutDeletingReturnsTheSameKey() throws {
        let first = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        let second = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        #expect(first.publicKeyX963 == second.publicKeyX963)
    }

    /// Signatures, not just bytes: two keys could in principle share a public
    /// encoding path and differ in use. Verifying the *first* key's signature
    /// against the *second* key's public key must fail, which is what "a verifier
    /// cannot link these two presentations" means operationally.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func aRotatedKeyCannotProduceSignaturesTheOldIdentityWouldHaveMade() throws {
        let message = Data("presentation".utf8)

        let first = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        let firstSignature = try first.signature(for: message)

        try DeviceKey.deleteKey(tag: tag, installRecord: installRecord)
        let second = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        let secondPublicKey = try P256.Signing.PublicKey(x963Representation: second.publicKeyX963)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: firstSignature)
        #expect(!secondPublicKey.isValidSignature(signature, for: message))

        let firstPublicKey = try P256.Signing.PublicKey(x963Representation: first.publicKeyX963)
        #expect(firstPublicKey.isValidSignature(signature, for: message))
    }

    // MARK: - Reinstall

    /// The headline defect. A Keychain item outlives the app that wrote it, so
    /// deleting the app and reinstalling used to hand the new install the old
    /// private key and therefore the old DID — an identity the user could not
    /// shed short of erasing the device.
    ///
    /// The reinstall is simulated the way iOS performs it: the Keychain item
    /// stays exactly where it was, and the app container — here, the defaults
    /// suite — is replaced by an empty one.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func reinstallingTheAppDoesNotResurrectThePreviousIdentity() throws {
        let beforeDeletion = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        let reinstalledName = installRecordName + ".reinstalled"
        let reinstalled = try #require(UserDefaults(suiteName: reinstalledName))
        defer { UserDefaults.standard.removePersistentDomain(forName: reinstalledName) }

        let afterReinstall = try DeviceKey.loadOrCreate(tag: tag, installRecord: reinstalled)

        #expect(afterReinstall.publicKeyX963 != beforeDeletion.publicKeyX963)
    }

    /// …and having adopted a new key, it must then behave like any other install:
    /// stable across relaunches rather than minting an identity per launch.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func theKeyMintedAfterAReinstallIsItselfStable() throws {
        _ = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        let reinstalledName = installRecordName + ".reinstalled"
        let reinstalled = try #require(UserDefaults(suiteName: reinstalledName))
        defer { UserDefaults.standard.removePersistentDomain(forName: reinstalledName) }

        let first = try DeviceKey.loadOrCreate(tag: tag, installRecord: reinstalled)
        let second = try DeviceKey.loadOrCreate(tag: tag, installRecord: reinstalled)

        #expect(first.publicKeyX963 == second.publicKeyX963)
    }

    /// The escape hatch has to keep working: a caller that opts out of the
    /// install check gets the raw Keychain semantics, which is what the signing
    /// tests want when they manage their own key lifetime.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func optingOutOfTheInstallCheckAdoptsWhateverTheKeychainHolds() throws {
        let first = try DeviceKey.loadOrCreate(tag: tag, installRecord: nil)
        let second = try DeviceKey.loadOrCreate(tag: tag, installRecord: nil)

        #expect(first.publicKeyX963 == second.publicKeyX963)
    }

    // MARK: - IdentityReset

    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func resetRemovesTheCredentialsAndTheIdentityBehindThem() throws {
        let store = try store()
        let before = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        try store.save(jws: "eyJhbGciOiJFUzI1NiJ9.e30.c2ln", id: "nationalID")

        try IdentityReset.perform(credentialStore: store,
                                  keyTag: tag,
                                  installRecord: installRecord)

        #expect(try store.allIDs().isEmpty)
        #expect(try DeviceKey.storedKeyBacking(tag: tag) == nil)

        let after = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        #expect(after.publicKeyX963 != before.publicKeyX963)
    }

    /// A user who taps reset twice, or resets before ever onboarding, gets a
    /// success both times — there is no state in which "make me nobody" is a
    /// failure because nothing was there.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func resetIsIdempotentAndSucceedsOnAnUntouchedDevice() throws {
        let store = try store()

        try IdentityReset.perform(credentialStore: store, keyTag: tag, installRecord: installRecord)
        _ = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        try IdentityReset.perform(credentialStore: store, keyTag: tag, installRecord: installRecord)
        try IdentityReset.perform(credentialStore: store, keyTag: tag, installRecord: installRecord)

        #expect(try store.allIDs().isEmpty)
        #expect(try DeviceKey.storedKeyBacking(tag: tag) == nil)
    }

    /// The store survives its own wipe, so the app is usable immediately after a
    /// reset rather than only after a relaunch.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func theStoreIsStillWritableAfterAReset() throws {
        let store = try store()
        try IdentityReset.perform(credentialStore: store, keyTag: tag, installRecord: installRecord)

        try store.save(jws: "eyJhbGciOiJFUzI1NiJ9.e30.c2ln", id: "nationalID")
        #expect(try store.load(id: "nationalID") != nil)
    }

    /// Pins the ordering decision, by observing it from inside the store rather
    /// than inferring it from the end state — both orders leave the same wreckage
    /// afterwards, so only a snapshot taken mid-reset can tell them apart.
    ///
    /// Key first is what makes an interrupted reset a *visible* half-state
    /// (credentials left under a DID this device can no longer sign for) instead
    /// of an invisible one (an empty store in front of a living identity, which
    /// is indistinguishable from a fresh install and re-links the user on their
    /// next onboarding).
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func theKeyIsDestroyedBeforeTheCredentialsAndAFailedSweepIsReported() throws {
        let store = FailingStore(keyTag: tag)
        _ = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        #expect(throws: FailingStore.Failure.self) {
            try IdentityReset.perform(credentialStore: store,
                                      keyTag: tag,
                                      installRecord: installRecord)
        }

        // The sweep ran, and by the time it ran the identity was already gone.
        #expect(store.keyExistedWhenCleared == false)
        #expect(try DeviceKey.storedKeyBacking(tag: tag) == nil)
    }

    /// The boundary, stated as a test so that folding the key deletion into
    /// `deleteAll()` fails here rather than silently changing what every routine
    /// clear-out does.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func clearingCredentialsAloneKeepsTheIdentity() throws {
        let store = try store()
        let before = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        try store.save(jws: "eyJhbGciOiJFUzI1NiJ9.e30.c2ln", id: "nationalID")

        try store.deleteAll()

        #expect(try store.allIDs().isEmpty)
        let after = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)
        #expect(after.publicKeyX963 == before.publicKeyX963)
    }

    // MARK: - Backing

    /// The gap that made the software fallback invisible: issuance creates the
    /// key inside a background closure and drops the instance, so anything that
    /// wants to report on the key later has to be able to ask without holding
    /// one.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func theBackingOfAnExistingKeyCanBeQueriedWithoutHoldingIt() throws {
        #expect(try DeviceKey.storedKeyBacking(tag: tag) == nil)

        let key = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        #expect(try DeviceKey.storedKeyBacking(tag: tag) == key.backing)
        #expect(try DeviceKey.storedKeyHasUnexpectedSoftwareBacking(tag: tag)
                == key.hasUnexpectedSoftwareBacking)
    }

    /// Asking for the backing must not be what creates the key — a Settings
    /// screen reading this before onboarding would otherwise mint an identity
    /// for a user who never asked for one.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func queryingTheBackingDoesNotCreateAKey() throws {
        #expect(try DeviceKey.storedKeyBacking(tag: tag) == nil)
        #expect(try DeviceKey.storedKeyHasUnexpectedSoftwareBacking(tag: tag) == false)
        #expect(try DeviceKey.storedKeyBacking(tag: tag) == nil)
    }

    /// A device with no Enclave has nothing to warn about, so the warning must
    /// not fire on the simulator — a flag that is always on is a flag nobody
    /// reads.
    @Test(.enabled(if: DeviceKeyLifecycleTests.keychainIsAvailable))
    func softwareBackingIsOnlyFlaggedWhereAnEnclaveExists() throws {
        let key = try DeviceKey.loadOrCreate(tag: tag, installRecord: installRecord)

        if DeviceKey.secureEnclaveIsAvailable {
            // On hardware this is the assertion that catches a silent downgrade:
            // an Enclave that exists and was not used is a fault, not a
            // supported configuration.
            #expect(key.isHardwareBacked)
            #expect(!key.hasUnexpectedSoftwareBacking)
        } else {
            #expect(!key.isHardwareBacked)
            #expect(!key.hasUnexpectedSoftwareBacking)
        }
    }
}

/// A store whose wipe always fails, for the half-reset case. It also records
/// what the Keychain looked like at the moment it was asked to clear, which is
/// the only vantage point from which the reset's ordering is observable.
private final class FailingStore: CredentialStoring, @unchecked Sendable {
    struct Failure: Error {}

    /// `nil` until `deleteAll` runs, so "the sweep never happened" and "the sweep
    /// happened and the key was gone" stay distinguishable.
    private(set) var keyExistedWhenCleared: Bool?

    private let keyTag: String

    init(keyTag: String) {
        self.keyTag = keyTag
    }

    func save(jws: String, id: String) throws {}
    func load(id: String) throws -> String? { nil }
    func allIDs() throws -> [String] { [] }

    func deleteAll() throws {
        let backing = try? DeviceKey.storedKeyBacking(tag: keyTag)
        keyExistedWhenCleared = (backing ?? nil) != nil
        throw Failure()
    }
}
