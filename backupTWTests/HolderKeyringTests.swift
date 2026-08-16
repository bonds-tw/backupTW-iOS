//
//  HolderKeyringTests.swift
//  backupTWTests
//
//  One key per card, and being able to find and destroy all of them.
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// Each test gets its own namespace under `…tests.`, because Swift Testing runs
/// concurrently and `destroyAll()` is a sweep. A shared namespace would mean one
/// test deleting another's keys — the reason the production namespace is a
/// separate string rather than a blacklist entry.
@Suite("一卡一金鑰")
struct HolderKeyringTests {

    private static func makeKeyring(legacy: [String] = []) -> HolderKeyring {
        HolderKeyring(namespace: "tw.bonds.backupTW.tests.\(UUID().uuidString).",
                      legacyTags: legacy,
                      installID: "install1",
                      legacyInstallRecord: nil)
    }

    @Test func aNewKeyIsFoundByItsOwnPublicKey() throws {
        let keyring = Self.makeKeyring()
        defer { try? keyring.destroyAll() }

        let key = try keyring.newKey()
        let found = try keyring.key(matchingPublicKeyX963: key.publicKeyX963)
        #expect(found.publicKeyX963 == key.publicKeyX963)
    }

    /// **The property the whole thing is for.** Two cards, two keys, and nothing
    /// shared between them.
    @Test func twoCardsGetTwoDifferentKeys() throws {
        let keyring = Self.makeKeyring()
        defer { try? keyring.destroyAll() }

        let first = try keyring.newKey()
        let second = try keyring.newKey()
        #expect(first.publicKeyX963 != second.publicKeyX963)
        #expect(try keyring.entries().count == 2)
    }

    /// The tag carries no card type, no issuer, no credential identifier —
    /// `kSecAttrApplicationTag` is readable metadata, so a descriptive tag would
    /// announce what the owner holds.
    @Test func theTagIsOpaque() throws {
        let keyring = Self.makeKeyring()
        defer { try? keyring.destroyAll() }

        _ = try keyring.newKey()
        let tag = try #require(try keyring.entries().first?.tag)
        let handle = tag.replacingOccurrences(of: keyring.namespace, with: "")
            .replacingOccurrences(of: "\(keyring.installID).", with: "")
        #expect(handle.count == 32)
        #expect(handle.allSatisfy { $0.isHexDigit })
        // Nothing describing the card may appear anywhere in the tag.
        for leak in ["drivinglicense", "twdiw", "national-id", "issuer", "00000000"] {
            #expect(!tag.lowercased().contains(leak))
        }
    }

    /// Two keyrings with different install IDs do not see each other's keys as
    /// theirs, matching `DeviceKey`'s existing marker behaviour: a key an app
    /// deletion orphaned must not be resurrected.
    @Test func aKeyFromAnotherInstallIsNotClaimed() throws {
        let namespace = "tw.bonds.backupTW.tests.\(UUID().uuidString)."
        let first = HolderKeyring(namespace: namespace, legacyTags: [], installID: "install1",
                                  legacyInstallRecord: nil)
        let second = HolderKeyring(namespace: namespace, legacyTags: [], installID: "install2",
                                   legacyInstallRecord: nil)
        defer { try? first.destroyAll() }

        let key = try first.newKey()
        // Visible to both, claimed by only one.
        #expect(try second.entries().count == 1)
        #expect(try second.entries().first?.belongsToThisInstall == false)
        #expect(throws: HolderKeyringError.noKeyForCredential) {
            try second.key(matchingPublicKeyX963: key.publicKeyX963)
        }
    }

    // MARK: Erasure

    @Test func destroyingRemovesEveryKeyInTheNamespace() throws {
        let keyring = Self.makeKeyring()
        _ = try keyring.newKey()
        _ = try keyring.newKey()
        _ = try keyring.newKey()

        #expect(try keyring.destroyAll() == 3)
        #expect(try keyring.entries().isEmpty)
    }

    /// **The legacy key survives.** It signed a credential that is already in
    /// somebody's wallet and has already been presented; rotating it would make
    /// the verifier's record disagree with the device, and this app's own
    /// holder-binding check would then refuse this app's own card.
    @Test func theLegacyKeyIsNotSweptAway() throws {
        let legacyTag = "tw.bonds.backupTW.tests.legacy.\(UUID().uuidString)"
        let legacy = try DeviceKey.loadOrCreate(tag: legacyTag, installRecord: nil)
        defer { try? DeviceKey.deleteKey(tag: legacyTag, installRecord: nil) }

        let keyring = Self.makeKeyring(legacy: [legacyTag])
        _ = try keyring.newKey()

        #expect(try keyring.destroyAll() == 1)
        let survivors = try keyring.entries()
        #expect(survivors.count == 1)
        #expect(survivors.first?.isLegacy == true)
        #expect(survivors.first?.publicKeyX963 == legacy.publicKeyX963)
    }

    /// And it is still reachable afterwards, which is the point of sparing it.
    @Test func theLegacyKeyStillSignsAfterAnErasure() throws {
        let legacyTag = "tw.bonds.backupTW.tests.legacy.\(UUID().uuidString)"
        let legacy = try DeviceKey.loadOrCreate(tag: legacyTag, installRecord: nil)
        defer { try? DeviceKey.deleteKey(tag: legacyTag, installRecord: nil) }

        let keyring = Self.makeKeyring(legacy: [legacyTag])
        try keyring.destroyAll()

        let found = try keyring.key(matchingPublicKeyX963: legacy.publicKeyX963)
        #expect(found.publicKeyX963 == legacy.publicKeyX963)
    }

    /// A namespace with nothing in it sweeps cleanly rather than erroring — an
    /// erase button that fails when there is nothing to erase teaches people to
    /// distrust it.
    @Test func sweepingAnEmptyNamespaceSucceeds() throws {
        let keyring = Self.makeKeyring()
        #expect(try keyring.destroyAll() == 0)
    }

    // MARK: Residue

    /// The diagnostics probe and test keys must **not** count as residue. The
    /// self-check builds probe keys and any interruption leaves one behind, so
    /// counting them would produce a permanently red row that the diagnostics
    /// screen created itself and the user cannot clear — and a check that always
    /// fails teaches people to ignore checks.
    @Test func theSelfCheckProbeIsNotResidue() throws {
        let keyring = Self.makeKeyring()
        defer { try? keyring.destroyAll() }

        let probeTag = "tw.bonds.backupTW.selfcheck.\(UUID().uuidString)"
        _ = try DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)
        defer { try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil) }

        _ = try keyring.newKey()
        #expect(!(try keyring.residueTags().contains(probeTag)))
    }

    /// A key under this app's prefix that no rule claims is reported, not
    /// deleted. Deleting would need an uninjectable delete-by-class that a
    /// misconfigured test could point at a real credential key.
    @Test func anUnclaimedKeyIsCountedAndLeftAlone() throws {
        let keyring = Self.makeKeyring()
        defer { try? keyring.destroyAll() }

        let strayTag = "tw.bonds.backupTW.stray.\(UUID().uuidString)"
        #expect(!(try keyring.residueTags().contains(strayTag)))
        _ = try DeviceKey.loadOrCreate(tag: strayTag, installRecord: nil)
        defer { try? DeviceKey.deleteKey(tag: strayTag, installRecord: nil) }

        // Membership, not a count: these tests run concurrently and another
        // test's sweep moves any total between two reads.
        #expect(try keyring.residueTags().contains(strayTag))
        try keyring.destroyAll()
        // Still there: reported, not swept.
        #expect(try keyring.residueTags().contains(strayTag))
    }

    // MARK: What this does not claim

    /// Documentation, as a test. A credential's `cnf.jwk` is fixed by the issuer
    /// at collection and is the same key every verifier sees, so per-credential
    /// keys sever cross-card linkage and nothing else. This asserts the shape of
    /// that fact: one card, one key, every presentation.
    @Test func oneCardKeepsOneKeyForever() throws {
        let keyring = Self.makeKeyring()
        defer { try? keyring.destroyAll() }

        let key = try keyring.newKey()
        for _ in 0..<3 {
            let each = try keyring.key(matchingPublicKeyX963: key.publicKeyX963)
            #expect(each.publicKeyX963 == key.publicKeyX963)
        }
    }
}
