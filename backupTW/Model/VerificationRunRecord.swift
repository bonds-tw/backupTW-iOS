//
//  VerificationRunRecord.swift
//  backupTW
//
//  Privacy-safe timings from real presentation and proof runs.
//

import Darwin
import CryptoKit
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
        case disclosedAgePresentation
        case oid4vpPresentation
        case privateAgeProof
        case zeroKnowledgeProofCreation
        case zeroKnowledgeProofVerification
    }

    /// The executable cells in the field-test matrix. N1 is deliberately absent:
    /// fully-offline OIDC4VP direct_post is a protocol boundary, not a run.
    enum MatrixCell: String, Codable, CaseIterable {
        case a1 = "A1"
        case a2 = "A2"
        case a3 = "A3"
        case g1 = "G1"
        case g2 = "G2"
        case g3 = "G3"
        case g4 = "G4"
        /// The private age proof posted to the web verifier (verifier.mashbean.net/zkp):
        /// W1 from a government card, W2 from the self-issued MyData document.
        /// The SD-JWT-VC counterparts over the same website are A2 and G1.
        case w1 = "W1"
        case w2 = "W2"
        case s1 = "S1" // Government SD-JWT age disclosure over BLE
        case s2 = "S2" // MyData national-ID age derivative over BLE
    }

    enum RunTemperature: String, Codable {
        case cold
        case warm
    }

    enum AuthenticationObservation: String, Codable {
        /// A successful device-owner authentication happened after the previous
        /// recorded run in this app process. The policy may have used biometrics
        /// or the device passcode; the app cannot truthfully distinguish them.
        case promptedSincePreviousRun
        /// The process was already inside its ten-minute authenticated session.
        case gracePeriod
        /// The app was launched by test automation without LocalAuthentication.
        case automationBypass
        case unknown
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

    /// Automatically inferred from flow and credential family. Optional so a
    /// build can still read timing files written by the previous schema.
    let matrixCell: MatrixCell?

    /// A random identifier for this app process plus an ordinal make cold/warm
    /// reproducible without a UI switch. Neither value identifies a person.
    let processSessionID: UUID?
    let processRunOrdinal: Int?
    let runTemperature: RunTemperature?
    let authenticationObservation: AuthenticationObservation?

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

    /// OpenAC exposes Prepare and Show separately. Keeping both avoids reducing
    /// the new age proof to one opaque wall-clock number.
    let proofPrepareMilliseconds: UInt64?
    let proofShowMilliseconds: UInt64?
    let proofPrepareWasCached: Bool?
    /// Serialized bytes received or sent, excluding BLE framing.
    let payloadBytes: UInt64?

    /// A short SHA-256 prefix over a one-time BLE service or OIDC state. It lets
    /// the iPhone and iPad logs be paired without retaining the request ID,
    /// nonce, service UUID, DID, URL, or any credential content.
    let correlationToken: String?

    /// True only when the holder's visual QR fallback actually became visible.
    let qrFallbackWasVisible: Bool?

    /// Performance context captured automatically at the moment of persistence.
    let lowPowerModeEnabled: Bool?
    let thermalState: String?

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
         matrixCell: MatrixCell? = nil,
         succeeded: Bool?,
         preparationMilliseconds: UInt64? = nil,
         transportMilliseconds: UInt64? = nil,
         verificationMilliseconds: UInt64? = nil,
         endToEndMilliseconds: UInt64? = nil,
         proofPrepareMilliseconds: UInt64? = nil,
         proofShowMilliseconds: UInt64? = nil,
         proofPrepareWasCached: Bool? = nil,
         payloadBytes: UInt64? = nil,
         correlationToken: String? = nil,
         qrFallbackWasVisible: Bool? = nil,
         processSessionID: UUID? = nil,
         processRunOrdinal: Int? = nil,
         runTemperature: RunTemperature? = nil,
         authenticationObservation: AuthenticationObservation? = nil,
         lowPowerModeEnabled: Bool? = nil,
         thermalState: String? = nil,
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
        self.matrixCell = matrixCell ?? Self.inferMatrixCell(flow: flow,
                                                              credentialKind: credentialKind,
                                                              transport: transport)
        self.succeeded = succeeded
        self.preparationMilliseconds = preparationMilliseconds
        self.transportMilliseconds = transportMilliseconds
        self.verificationMilliseconds = verificationMilliseconds
        self.endToEndMilliseconds = endToEndMilliseconds
        self.proofPrepareMilliseconds = proofPrepareMilliseconds
        self.proofShowMilliseconds = proofShowMilliseconds
        self.proofPrepareWasCached = proofPrepareWasCached
        self.payloadBytes = payloadBytes
        self.correlationToken = correlationToken
        self.qrFallbackWasVisible = qrFallbackWasVisible
        self.processSessionID = processSessionID
        self.processRunOrdinal = processRunOrdinal
        self.runTemperature = runTemperature
        self.authenticationObservation = authenticationObservation
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    static func correlationToken(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func inferMatrixCell(flow: Flow,
                                        credentialKind: CredentialKind,
                                        transport: Transport) -> MatrixCell? {
        switch (flow, credentialKind) {
        case (.disclosedAgePresentation, .governmentWallet): return .s1
        case (.disclosedAgePresentation, .selfIssued): return .s2
        case (.offlinePresentation, .selfIssued): return .a1
        case (.offlinePresentation, .governmentWallet): return .g2
        case (.oid4vpPresentation, .governmentWallet): return .a2
        case (.oid4vpPresentation, .selfIssued): return .g1
        case (.privateAgeProof, .governmentWallet): return transport == .https ? .w1 : .g3
        case (.privateAgeProof, .selfIssued): return transport == .https ? .w2 : .g4
        case (.zeroKnowledgeProofCreation, .mobileCertificate),
             (.zeroKnowledgeProofVerification, .mobileCertificate): return .a3
        default: return nil
        }
    }

    fileprivate func addingRuntime(_ runtime: VerificationRunRuntime.Metadata) -> Self {
        Self(id: id,
             recordedAt: recordedAt,
             flow: flow,
             role: role,
             credentialKind: credentialKind,
             transport: transport,
             matrixCell: matrixCell,
             succeeded: succeeded,
             preparationMilliseconds: preparationMilliseconds,
             transportMilliseconds: transportMilliseconds,
             verificationMilliseconds: verificationMilliseconds,
             endToEndMilliseconds: endToEndMilliseconds,
             proofPrepareMilliseconds: proofPrepareMilliseconds,
             proofShowMilliseconds: proofShowMilliseconds,
             proofPrepareWasCached: proofPrepareWasCached,
             payloadBytes: payloadBytes,
             correlationToken: correlationToken,
             qrFallbackWasVisible: qrFallbackWasVisible,
             processSessionID: processSessionID ?? runtime.sessionID,
             processRunOrdinal: processRunOrdinal ?? runtime.ordinal,
             runTemperature: runTemperature ?? runtime.temperature,
             authenticationObservation: authenticationObservation ?? runtime.authentication,
             lowPowerModeEnabled: lowPowerModeEnabled ?? runtime.lowPowerModeEnabled,
             thermalState: thermalState ?? runtime.thermalState,
             deviceModel: deviceModel,
             osVersion: osVersion,
             appVersion: appVersion,
             appBuild: appBuild)
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

/// The comparison the web field test exists to make: the same website checking
/// a selectively disclosed SD-JWT-VC presentation (A2 / G1) and a zero-knowledge
/// age proof (W1 / W2) from the same kind of card, on this phone.
///
/// Latest successful run of each, per card family. A median would need a
/// sample the phone does not have; the matrix report over collected logs does
/// the statistics, this only puts two measured runs side by side.
struct VerificationRunComparison: Equatable {
    let credentialKind: VerificationRunRecord.CredentialKind
    /// Latest successful online OIDC4VP presentation over HTTPS.
    let sdJWT: VerificationRunRecord?
    /// Latest successful private age proof posted to the web verifier.
    let zeroKnowledge: VerificationRunRecord?

    /// Positive when the zero-knowledge path took longer end to end.
    var endToEndDifferenceMilliseconds: Int64? {
        guard let sd = sdJWT?.endToEndMilliseconds,
              let zk = zeroKnowledge?.endToEndMilliseconds else { return nil }
        return Int64(zk) - Int64(sd)
    }

    static func latest(in records: [VerificationRunRecord]) -> [VerificationRunComparison] {
        [VerificationRunRecord.CredentialKind.governmentWallet, .selfIssued].compactMap { kind in
            let sd = records.last {
                $0.flow == .oid4vpPresentation && $0.credentialKind == kind
                    && $0.transport == .https && $0.succeeded == true
            }
            let zk = records.last {
                $0.flow == .privateAgeProof && $0.credentialKind == kind
                    && $0.transport == .https && $0.succeeded == true
            }
            guard sd != nil || zk != nil else { return nil }
            return VerificationRunComparison(credentialKind: kind, sdJWT: sd, zeroKnowledge: zk)
        }
    }
}

/// Process-local context added to every persisted run. It has no UI and does not
/// survive an app termination: that lifetime is exactly what makes ordinal 1 a
/// cold process run and later ordinals warm runs.
final class VerificationRunRuntime {

    struct Metadata {
        let sessionID: UUID
        let ordinal: Int
        let temperature: VerificationRunRecord.RunTemperature
        let authentication: VerificationRunRecord.AuthenticationObservation
        let lowPowerModeEnabled: Bool
        let thermalState: String
    }

    static let shared = VerificationRunRuntime()

    private let lock = NSLock()
    private let sessionID = UUID()
    private var ordinal = 0
    private var authenticationGeneration = 0
    private var consumedAuthenticationGeneration = 0
    private var automationAuthentication = false

    func recordDeviceOwnerAuthentication(automationBypass: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        authenticationGeneration += 1
        automationAuthentication = automationBypass
    }

    func nextMetadata() -> Metadata {
        lock.lock()
        defer { lock.unlock() }
        ordinal += 1
        let hasFreshAuthentication = authenticationGeneration > consumedAuthenticationGeneration
        let authentication: VerificationRunRecord.AuthenticationObservation
        if hasFreshAuthentication {
            authentication = automationAuthentication ? .automationBypass : .promptedSincePreviousRun
            consumedAuthenticationGeneration = authenticationGeneration
        } else if authenticationGeneration > 0 {
            authentication = .gracePeriod
        } else {
            authentication = .unknown
        }
        return Metadata(sessionID: sessionID,
                        ordinal: ordinal,
                        temperature: ordinal == 1 ? .cold : .warm,
                        authentication: authentication,
                        lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        thermalState: Self.thermalName(ProcessInfo.processInfo.thermalState))
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
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
    static let maximumRecordCount = 500

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
        records.append(record.addingRuntime(VerificationRunRuntime.shared.nextMetadata()))
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
        // These records contain only closed enums and timings. Unlike a
        // credential, keeping them readable after the first device unlock lets
        // devicectl collect a finished field test without asking the user to
        // open Diagnostics or copy anything from either device.
        try encoder.encode(records).write(to: fileURL,
                                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

/// The last Bluetooth transport state seen by each side of a check.
///
/// Timing tells us that a successful run used QR, but it cannot tell us why the
/// radio did not win the race. This record deliberately contains no service
/// UUID, peer identifier, payload, DID, claim, request or error-domain dump. It
/// keeps only the role, a coarse state and (while moving) a 25% progress bucket,
/// which is enough to distinguish 「Bluetooth was off」, 「both phones waited but
/// never found each other」 and 「the link broke halfway through」 on real devices.
struct BluetoothLinkDiagnosticRecord: Codable, Hashable {

    enum Role: String, Codable, CaseIterable {
        case holder
        case verifier
    }

    enum Phase: String, Codable {
        case starting
        case waiting
        case transferring
        case finished
        case unavailable
        case failed
    }

    let recordedAt: Date
    let role: Role
    let phase: Phase
    let progressPercent: Int?
    /// Already-human-readable and bounded before persistence; nil for ordinary
    /// lifecycle states. The raw `Error`, service UUID and peer never enter it.
    let detail: String?
}

/// A two-row, privacy-safe snapshot used by Diagnostics during device tests.
///
/// There is one record per role rather than an event log. A transfer can emit a
/// state callback for every frame; retaining all of them would add I/O and still
/// not answer the field-test question any better than the latest state does.
final class BluetoothLinkDiagnosticStore {

    static let shared = BluetoothLinkDiagnosticStore()

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
                .appendingPathComponent("bluetooth-link.json")
        }
    }

    func records() -> [BluetoothLinkDiagnosticRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Self.ordered(loadUnlocked())
    }

    func record(role: BluetoothLinkDiagnosticRecord.Role,
                state: BluetoothLinkState,
                now: Date = Date()) throws {
        let phase: BluetoothLinkDiagnosticRecord.Phase
        let progress: Int?
        let detail: String?
        switch state {
        case .starting:
            phase = .starting
            progress = nil
            detail = nil
        case .waiting:
            phase = .waiting
            progress = nil
            detail = nil
        case .transferring(let fraction):
            phase = .transferring
            // Four checkpoints are enough to show where a link stopped. The
            // clamp also keeps a malformed callback from escaping 0...100.
            let clamped = min(max(fraction, 0), 1)
            progress = min(Int(clamped * 4) * 25, 100)
            detail = nil
        case .finished:
            phase = .finished
            progress = 100
            detail = nil
        case .unavailable(let reason):
            phase = .unavailable
            progress = nil
            detail = String(reason.prefix(500))
        case .failed(let reason):
            phase = .failed
            progress = nil
            detail = String(reason.prefix(500))
        }

        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { throw StorageError.applicationSupportUnavailable }

        var current = loadUnlocked()
        if let previous = current.first(where: { $0.role == role }),
           previous.phase == phase,
           previous.progressPercent == progress,
           previous.detail == detail {
            return
        }
        current.removeAll { $0.role == role }
        current.append(BluetoothLinkDiagnosticRecord(recordedAt: now,
                                                     role: role,
                                                     phase: phase,
                                                     progressPercent: progress,
                                                     detail: detail))

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
        try encoder.encode(Self.ordered(current))
            .write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func loadUnlocked() -> [BluetoothLinkDiagnosticRecord] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BluetoothLinkDiagnosticRecord].self, from: data)) ?? []
    }

    private static func ordered(_ records: [BluetoothLinkDiagnosticRecord])
        -> [BluetoothLinkDiagnosticRecord] {
        BluetoothLinkDiagnosticRecord.Role.allCases.compactMap { role in
            records.first { $0.role == role }
        }
    }

    private enum StorageError: Error {
        case applicationSupportUnavailable
    }
}
