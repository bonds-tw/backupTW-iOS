//
//  VerificationRunRecord.swift
//  backupTW
//
//  Privacy-safe timings from real presentation and proof runs.
//

import Darwin
import Foundation

/// A monotonic clock shared by every verification flow.
///
/// Wall-clock `Date` is useful for saying when a run happened, but it can jump
/// while a run is in progress. Durations therefore use uptime nanoseconds and
/// saturate at zero if a caller ever supplies an inverted pair.
enum VerificationClock {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000_000
    }
}

/// One measurement that may safely be retained and copied into a test report.
///
/// The closed enums are intentional. There is nowhere to put a DID, claim,
/// verifier URL, request ID, or credential serial number, so adding timing does
/// not quietly create a second personal-data store.
struct VerificationRunRecord: Codable, Hashable, Identifiable {

    enum Flow: String, Codable {
        case offlinePresentation
        case oid4vpPresentation
        case zeroKnowledgeProofCreation
        case zeroKnowledgeProofVerification
    }

    enum Role: String, Codable {
        case holder
        case verifier
    }

    enum CredentialKind: String, Codable {
        case selfIssued
        case governmentWallet
        case mobileCertificate
    }

    enum Transport: String, Codable {
        case qr
        case bluetooth
        case https
        case file
        case local
    }

    let id: UUID
    let recordedAt: Date
    let flow: Flow
    let role: Role
    let credentialKind: CredentialKind
    let transport: Transport

    /// nil means this device never reached a verdict.
    let succeeded: Bool?

    /// Request retrieval or proof construction, depending on the flow.
    let preparationMilliseconds: UInt64?

    /// Request shown until a complete payload arrived. It deliberately includes
    /// the human scan/display step and must not be described as radio speed.
    let transportMilliseconds: UInt64?

    /// Local cryptographic verification where that number can be isolated.
    let verificationMilliseconds: UInt64?

    /// The user-observable interval for the operation being measured.
    let endToEndMilliseconds: UInt64?

    let deviceModel: String
    let osVersion: String
    let appVersion: String?
    let appBuild: String?

    init(id: UUID = UUID(),
         recordedAt: Date = Date(),
         flow: Flow,
         role: Role,
         credentialKind: CredentialKind,
         transport: Transport,
         succeeded: Bool?,
         preparationMilliseconds: UInt64? = nil,
         transportMilliseconds: UInt64? = nil,
         verificationMilliseconds: UInt64? = nil,
         endToEndMilliseconds: UInt64? = nil,
         deviceModel: String = Self.currentDeviceModel(),
         osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
         appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         appBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        self.id = id
        self.recordedAt = recordedAt
        self.flow = flow
        self.role = role
        self.credentialKind = credentialKind
        self.transport = transport
        self.succeeded = succeeded
        self.preparationMilliseconds = preparationMilliseconds
        self.transportMilliseconds = transportMilliseconds
        self.verificationMilliseconds = verificationMilliseconds
        self.endToEndMilliseconds = endToEndMilliseconds
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    private static func currentDeviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

/// Stores a small rolling history for Diagnostics and the field-test report.
///
/// The directory is excluded from backup and the file uses the same protection
/// class as credentials. The schema itself contains no personal data; these are
/// defence-in-depth properties, not an excuse to put claims here later.
final class VerificationRunStore {

    static let shared = VerificationRunStore()
    static let maximumRecordCount = 100

    private let fileURL: URL?
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil,
                                                       create: true)
            self.fileURL = support?
                .appendingPathComponent("Diagnostics", isDirectory: true)
                .appendingPathComponent("verification-runs.json")
        }
    }

    func records() -> [VerificationRunRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    func append(_ record: VerificationRunRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { throw StorageError.applicationSupportUnavailable }

        var records = loadUnlocked()
        records.append(record)
        if records.count > Self.maximumRecordCount {
            records.removeFirst(records.count - Self.maximumRecordCount)
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(excluded)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func loadUnlocked() -> [VerificationRunRecord] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([VerificationRunRecord].self, from: data)) ?? []
    }

    private enum StorageError: Error {
        case applicationSupportUnavailable
    }
}
