//
//  AgePredicatePrepareCacheTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

struct AgePredicatePrepareCacheTests {

    private static func temporaryCache() throws -> (AgePredicatePrepareCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (try AgePredicatePrepareCache(directory: directory), directory)
    }

    private static func sampleState(claimName: String = "birthdate",
                                    format: UInt8 = 3) -> AgePredicatePreparedState {
        AgePredicatePreparedState(
            claimName: claimName, claimFormat: format,
            prepareProof: Data("proof".utf8),
            prepareInstance: Data("instance".utf8),
            prepareWitness: Data("witness-with-a-birth-date".utf8))
    }

    @Test func keyIsStablePerCredentialAndHidesItsContent() {
        let credential = "eyJ...national-id...~disclosure~"
        let a = AgePredicatePrepareCache.key(source: .selfIssued, storedCredential: credential)
        let b = AgePredicatePrepareCache.key(source: .selfIssued, storedCredential: credential)
        #expect(a == b, "same card must map to the same key so the cache can hit")
        #expect(a.count == 64, "SHA-256 hex")
        #expect(!a.contains("national-id"), "the key must not carry credential content")
        // A different card, and the same bytes under a different source, are
        // different cache entries.
        #expect(a != AgePredicatePrepareCache.key(source: .selfIssued, storedCredential: credential + "x"))
        #expect(a != AgePredicatePrepareCache.key(source: .twdiw, storedCredential: credential))
    }

    @Test func storeThenLoadRoundTripsEveryArtifact() throws {
        let (cache, directory) = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "a".repeated(64)
        try cache.store(key: key, Self.sampleState())

        let loaded = try #require(cache.load(key: key))
        #expect(loaded == Self.sampleState())
        #expect(loaded.claimName == "birthdate")
        #expect(loaded.claimFormat == 3)
    }

    @Test func loadIsNilForAnUnknownKey() throws {
        let (cache, directory) = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(cache.load(key: "b".repeated(64)) == nil)
    }

    @Test func removeDropsOneEntryAndPurgeClearsAll() throws {
        let (cache, directory) = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "c".repeated(64)
        let second = "d".repeated(64)
        try cache.store(key: first, Self.sampleState())
        try cache.store(key: second, Self.sampleState())

        cache.remove(key: first)
        #expect(cache.load(key: first) == nil)
        #expect(cache.load(key: second) != nil)

        try cache.purgeAll()
        #expect(cache.load(key: second) == nil)
    }

    @Test func evictionKeepsAtMostTheLimit() throws {
        let (cache, directory) = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        // One more than the limit, each a distinct 64-hex key.
        let keys = (0...AgePredicatePrepareCache.maximumEntries).map {
            String(format: "%064x", $0)
        }
        for key in keys {
            try cache.store(key: key, Self.sampleState())
        }
        let surviving = keys.filter { cache.load(key: $0) != nil }
        #expect(surviving.count <= AgePredicatePrepareCache.maximumEntries)
        // The most recently stored one is never the one evicted.
        #expect(cache.load(key: keys.last!) != nil)
    }

    @Test func aStoredWitnessNeverAppearsUnderItsPlaintextInAManifest() throws {
        let (cache, directory) = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "e".repeated(64)
        try cache.store(key: key, Self.sampleState())
        // The manifest holds only claim metadata, not the witness bytes.
        let manifest = try String(
            contentsOf: directory.appendingPathComponent(key).appendingPathComponent("manifest.json"),
            encoding: .utf8)
        #expect(!manifest.contains("birth-date"))
    }
}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
