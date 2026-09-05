//
//  AgePredicatePrepareCache.swift
//  backupTW
//
//  The reusable half of an OpenAC age proof, kept between presentations.
//

import CryptoKit
import Foundation

/// The precomputed Prepare state OpenAC is designed to reuse.
///
/// # Why this exists
///
/// An age proof is two proofs. **Prepare** checks the issuer's signature over
/// the credential and commits to the hidden witness; it depends only on the
/// card, not on who is asking. **Show** answers the verifier's nonce and cutoff.
/// The zkID paper is explicit that Prepare is meant to run once per credential
/// and be stored — "a reusable precomputed state is produced and stored" — after
/// which each presentation only re-randomises that state (`reblind`) and runs
/// the cheap Show circuit. Measured on the paper's iPhone 17: Prepare prove
/// 2,102 ms and its key setup 3,499 ms, against a Prepare reblind of 884 ms and
/// a whole Show of ~115 ms. So caching Prepare turns a repeat proof from the
/// order of ten seconds into the order of one.
///
/// # Why the stored bytes are as sensitive as the credential
///
/// `prepareWitness` is the circuit witness: it carries the cardholder's device
/// key and the **normalized birth date** among its shared values. It is exactly
/// what `ZKProver` deletes after a MOICA proof and what the proof exists to keep
/// off the wire. So it is written with the same protection class as
/// `CredentialStore` and excluded from backup, and — the rule this file lives
/// under — its directory is removed by `LocalDataEraser.eraseEverything()` and
/// when the credential it was derived from is deleted. A prepared state that
/// outlived its card would be a birth date outliving the document it came from.
struct AgePredicatePreparedState: Equatable {
    /// Bumped if the on-disk layout or the artifact set changes. A reader that
    /// does not recognise the version rebuilds rather than trusting stale bytes.
    static let version = 1

    let claimName: String
    let claimFormat: UInt8

    /// The three artifacts `prove_jwt` leaves in `keys/`, captured **before**
    /// any reblind so every later presentation reblinds a fresh, independent
    /// randomisation from the same base. Order matters to nobody; names do.
    let prepareProof: Data
    let prepareInstance: Data
    /// ⚠️ Secret. Device key + birth date. Never packaged, never logged.
    let prepareWitness: Data

    static let artifactNames = [
        "prepare_proof.bin",
        "prepare_instance.bin",
        "prepare_witness.bin",
    ]
}

/// File-backed store of prepared states, one directory per credential.
///
/// Not an actor: its only caller is `OpenACAgePredicateProofEngine`, which is an
/// actor and serialises access. Keeping it a plain value keeps the engine's
/// reasoning about ordering in one place.
struct AgePredicatePrepareCache {

    /// A card or two, not a history. Old entries are evicted oldest-first so a
    /// wallet that has held many cards does not accumulate birth-date-bearing
    /// witnesses for cards it no longer has.
    static let maximumEntries = 8

    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? Self.defaultDirectory()
        try fileManager.createDirectory(
            at: self.directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = self.directory
        try? mutable.setResourceValues(values)
    }

    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("OpenACAgePrepared-v1", isDirectory: true)
    }

    /// A stable, non-reversible key for the credential a prepared state belongs
    /// to. Stable is the point: for a self-issued MyData card the proved SD-JWT
    /// is re-minted with a fresh timestamp each call, so the key is taken from
    /// the *stored* credential and the source, not from the ephemeral
    /// derivative — otherwise the cache would never hit. A hash so the directory
    /// name carries no credential content.
    static func key(source: PresentationCredentialSource, storedCredential: String) -> String {
        let material = Data((source.rawValue + ":").utf8) + Data(storedCredential.utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reading

    func load(key: String) -> AgePredicatePreparedState? {
        let entry = entryDirectory(for: key)
        guard let manifestData = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.version == AgePredicatePreparedState.version else {
            return nil
        }
        var artifacts: [String: Data] = [:]
        for name in AgePredicatePreparedState.artifactNames {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent(name)) else {
                return nil
            }
            artifacts[name] = data
        }
        // A read touches the entry, so eviction can be recency-aware without a
        // separate access log. Best-effort: a failure here only affects which
        // entry is dropped first, never correctness.
        try? touch(entry)
        return AgePredicatePreparedState(
            claimName: manifest.claimName,
            claimFormat: manifest.claimFormat,
            prepareProof: artifacts["prepare_proof.bin"]!,
            prepareInstance: artifacts["prepare_instance.bin"]!,
            prepareWitness: artifacts["prepare_witness.bin"]!)
    }

    // MARK: - Writing

    func store(key: String, _ state: AgePredicatePreparedState) throws {
        let entry = entryDirectory(for: key)
        // Written to a sibling then moved, so a crash mid-write never leaves a
        // half-populated entry that `load` would trust.
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        defer { try? fileManager.removeItem(at: staging) }

        let artifacts = [
            ("prepare_proof.bin", state.prepareProof),
            ("prepare_instance.bin", state.prepareInstance),
            ("prepare_witness.bin", state.prepareWitness),
        ]
        for (name, data) in artifacts {
            try data.write(to: staging.appendingPathComponent(name),
                           options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        let manifest = Manifest(version: AgePredicatePreparedState.version,
                                claimName: state.claimName,
                                claimFormat: state.claimFormat,
                                createdAt: Date())
        try JSONEncoder().encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: [.atomic, .completeFileProtectionUnlessOpen])

        if fileManager.fileExists(atPath: entry.path) {
            try fileManager.removeItem(at: entry)
        }
        try fileManager.moveItem(at: staging, to: entry)
        try? evictBeyondLimit()
    }

    /// Removes one entry. Used when a self-check rejects a cached state, which
    /// means the base is stale or corrupt and must not be tried again.
    func remove(key: String) {
        try? fileManager.removeItem(at: entryDirectory(for: key))
    }

    /// Removes every prepared state. Called when a credential is deleted and by
    /// `LocalDataEraser` — see the type's note on why this is not optional.
    func purgeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    // MARK: - Internals

    private func entryDirectory(for key: String) -> URL {
        // The key is already 64 hex chars from SHA-256; safe as a path segment.
        directory.appendingPathComponent(key, isDirectory: true)
    }

    private func touch(_ entry: URL) throws {
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
    }

    private func evictBeyondLimit() throws {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("staging-") } ?? []
        guard entries.count > Self.maximumEntries else { return }
        let byAge = entries.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }
        for entry in byAge.prefix(entries.count - Self.maximumEntries) {
            try? fileManager.removeItem(at: entry)
        }
    }

    private struct Manifest: Codable {
        let version: Int
        let claimName: String
        let claimFormat: UInt8
        let createdAt: Date
    }
}
