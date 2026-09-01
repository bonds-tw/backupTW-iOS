//
//  AgePredicateProof.swift
//  backupTW
//
//  Verifier-first, field-level zero-knowledge proof protocol.
//

import CryptoKit
import Foundation
import Security
#if canImport(OpenACAgeSwift)
import OpenACAgeSwift
#endif

enum AgePredicateProofError: Error, Equatable, LocalizedError {
    case randomnessUnavailable
    case malformedRequest
    case unsupportedVersion(Int)
    case staleRequest
    case purposeInvalid
    case sourceMismatch
    case statementMismatch
    case malformedPackage
    case noBirthDate
    case credentialIsNotTrusted
    case proofCreationFailed
    case proofRejected
    case nativeEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .randomnessUnavailable:
            return NSLocalizedString("A secure one-time request could not be created.", comment: "age proof")
        case .malformedRequest:
            return NSLocalizedString("This is not a field-proof request this app can read.", comment: "age proof")
        case .unsupportedVersion:
            return NSLocalizedString("This field proof was made by a newer version of the app.", comment: "age proof")
        case .staleRequest:
            return NSLocalizedString("This field-proof request has expired. Ask the checker to make a new one.", comment: "age proof")
        case .purposeInvalid:
            return NSLocalizedString("The checker did not provide a safe, readable purpose for this request.", comment: "age proof")
        case .sourceMismatch, .statementMismatch:
            return NSLocalizedString("The returned proof does not answer this checker's exact request.", comment: "age proof")
        case .malformedPackage:
            return NSLocalizedString("The received field proof is incomplete or damaged.", comment: "age proof")
        case .noBirthDate:
            return NSLocalizedString("This card has no supported date-of-birth field to prove from.", comment: "age proof")
        case .credentialIsNotTrusted:
            return NSLocalizedString("This government card does not have the independently saved API and blockchain trust evidence required for this proof.", comment: "age proof")
        case .proofCreationFailed:
            return NSLocalizedString("A private age proof could not be created from this card.", comment: "age proof")
        case .proofRejected:
            return NSLocalizedString("The zero-knowledge proof did not verify.", comment: "age proof")
        case .nativeEngineUnavailable:
            return NSLocalizedString("This build does not include the field-proof engine.", comment: "age proof")
        }
    }
}

/// A verifier-generated request. Unlike the older MOICA holding-proof flow,
/// this nonce exists before proving and is checked as a public circuit input.
struct AgePredicateProofRequest: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let lifetime: TimeInterval = VerifierSession.pendingRequestLifetime
    static let nonceByteCount = 32

    let version: Int
    let serviceID: UUID
    let nonce: String
    let purpose: String
    let credentialSource: PresentationCredentialSource
    /// Gregorian civil date in Taiwan, `YYYY-MM-DD`. The proof establishes that
    /// the hidden birth date is at or before this value.
    let cutoffDate: String
    let minimumAge: Int
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case serviceID = "b"
        case nonce = "c"
        case purpose = "p"
        case credentialSource = "s"
        case cutoffDate = "d"
        case minimumAge = "a"
        case createdAt = "t"
    }

    init(serviceID: UUID = UUID(),
         purpose: String,
         credentialSource: PresentationCredentialSource,
         minimumAge: Int = AgePredicate.majority,
         now: Date = Date()) throws {
        let cleanPurpose = UntrustedText(purpose, limit: PresentationRequest.maximumPurposeLength)
        guard !cleanPurpose.isEmpty,
              !cleanPurpose.wasTruncated,
              !cleanPurpose.containedControlCharacters else {
            throw AgePredicateProofError.purposeInvalid
        }
        guard (1...120).contains(minimumAge),
              let cutoff = ROCDate.taipeiCalendar.date(byAdding: .year, value: -minimumAge,
                                                       to: ROCDate.taipeiCalendar.startOfDay(for: now)) else {
            throw AgePredicateProofError.malformedRequest
        }
        var random = [UInt8](repeating: 0, count: Self.nonceByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw AgePredicateProofError.randomnessUnavailable
        }
        version = Self.currentVersion
        self.serviceID = serviceID
        nonce = Data(random).base64URLEncodedString()
        self.purpose = cleanPurpose.text
        self.credentialSource = credentialSource
        cutoffDate = Self.dateString(cutoff)
        self.minimumAge = minimumAge
        createdAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    }

    private init(version: Int, serviceID: UUID, nonce: String, purpose: String,
                 credentialSource: PresentationCredentialSource, cutoffDate: String,
                 minimumAge: Int, createdAt: Date) {
        self.version = version
        self.serviceID = serviceID
        self.nonce = nonce
        self.purpose = purpose
        self.credentialSource = credentialSource
        self.cutoffDate = cutoffDate
        self.minimumAge = minimumAge
        self.createdAt = createdAt
    }

    func encodedForTransport() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(from text: String, now: Date = Date()) throws -> AgePredicateProofRequest {
        guard let data = text.data(using: .utf8) else { throw AgePredicateProofError.malformedRequest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded: AgePredicateProofRequest
        do { decoded = try decoder.decode(AgePredicateProofRequest.self, from: data) }
        catch { throw AgePredicateProofError.malformedRequest }
        guard decoded.version == currentVersion else {
            throw AgePredicateProofError.unsupportedVersion(decoded.version)
        }
        guard Data(base64URLEncoded: decoded.nonce)?.count == nonceByteCount,
              (1...120).contains(decoded.minimumAge),
              cutoffComponents(decoded.cutoffDate) != nil else {
            throw AgePredicateProofError.malformedRequest
        }
        let clean = UntrustedText(decoded.purpose, limit: PresentationRequest.maximumPurposeLength)
        guard clean.text == decoded.purpose, !clean.isEmpty,
              !clean.wasTruncated, !clean.containedControlCharacters else {
            throw AgePredicateProofError.purposeInvalid
        }
        // Permit a small amount of clock skew, but never let a verifier mint a
        // request far in the future and thereby extend the one-time window.
        let age = now.timeIntervalSince(decoded.createdAt)
        guard age >= -60, age <= lifetime else {
            throw AgePredicateProofError.staleRequest
        }
        return decoded
    }

    /// Circuit literal for the credential's declared normalization format.
    func cutoffValue(claimFormat: UInt8) throws -> UInt64 {
        guard let parts = Self.cutoffComponents(cutoffDate) else {
            throw AgePredicateProofError.malformedRequest
        }
        switch claimFormat {
        case 2:
            return UInt64(parts.year * 10_000 + parts.month * 100 + parts.day)
        case 3:
            let rocYear = parts.year - ROCDate.gregorianOffset
            guard rocYear > 0 else { throw AgePredicateProofError.malformedRequest }
            return UInt64(rocYear * 10_000 + parts.month * 100 + parts.day)
        default:
            throw AgePredicateProofError.statementMismatch
        }
    }

    private static func cutoffComponents(_ value: String) -> (year: Int, month: Int, day: Int)? {
        let fields = value.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              let date = ROCDate.taipeiCalendar.date(
                from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        // Calendar normalises impossible dates (for example 2026-02-31) unless
        // the components are compared after parsing. A verifier must never ask
        // the circuit to prove a statement whose printed cutoff and numeric
        // public input name different days.
        let roundTrip = ROCDate.taipeiCalendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return (year, month, day)
    }

    private static func dateString(_ date: Date) -> String {
        let components = ROCDate.taipeiCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0,
                      components.month ?? 0, components.day ?? 0)
    }
}

/// Only proof objects and verifier-checkable public metadata travel. The SD-JWT,
/// disclosure, birth date, witness and proving keys never leave the holder.
struct AgePredicateProofPackage: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumArtifactBytes = 2_000_000
    static let supportedBirthClaimNames: Set<String> = [
        "roc_birthday", "birthdate", "birthday", "date_of_birth", "birth_date", "出生日期",
    ]

    let version: Int
    let requestNonce: String
    let credentialSource: PresentationCredentialSource
    let claimName: String
    let claimFormat: UInt8
    let cutoffDate: String
    let minimumAge: Int
    let issuerDID: String
    let prepareProof: Data
    let showProof: Data
    let prepareMilliseconds: UInt64
    let showMilliseconds: UInt64
    let createdAt: Date

    init(request: AgePredicateProofRequest,
         claimName: String,
         claimFormat: UInt8,
         issuerDID: String,
         prepareProof: Data,
         showProof: Data,
         prepareMilliseconds: UInt64,
         showMilliseconds: UInt64,
         createdAt: Date = Date()) throws {
        version = Self.currentVersion
        requestNonce = request.nonce
        credentialSource = request.credentialSource
        self.claimName = claimName
        self.claimFormat = claimFormat
        cutoffDate = request.cutoffDate
        minimumAge = request.minimumAge
        self.issuerDID = issuerDID
        self.prepareProof = prepareProof
        self.showProof = showProof
        self.prepareMilliseconds = prepareMilliseconds
        self.showMilliseconds = showMilliseconds
        self.createdAt = createdAt
        try validate(answering: request)
    }

    func validate(answering request: AgePredicateProofRequest) throws {
        guard version == Self.currentVersion else {
            throw AgePredicateProofError.unsupportedVersion(version)
        }
        guard requestNonce == request.nonce,
              credentialSource == request.credentialSource else {
            throw AgePredicateProofError.sourceMismatch
        }
        guard cutoffDate == request.cutoffDate,
              minimumAge == request.minimumAge,
              [UInt8(2), UInt8(3)].contains(claimFormat),
              Self.supportedBirthClaimNames.contains(claimName),
              claimName.utf8.count <= 31,
              issuerDID.hasPrefix("did:key:"), issuerDID.utf8.count <= 300 else {
            throw AgePredicateProofError.statementMismatch
        }
        guard !prepareProof.isEmpty, !showProof.isEmpty,
              prepareProof.count <= Self.maximumArtifactBytes,
              showProof.count <= Self.maximumArtifactBytes else {
            throw AgePredicateProofError.malformedPackage
        }
        _ = try request.cutoffValue(claimFormat: claimFormat)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> AgePredicateProofPackage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(AgePredicateProofPackage.self, from: data) }
        catch { throw AgePredicateProofError.malformedPackage }
    }
}

struct AgePredicateProofTiming: Equatable, Sendable {
    let prepareMilliseconds: UInt64
    let showMilliseconds: UInt64
    let verifyMilliseconds: UInt64
}

/// Dependency boundary around the official OpenAC/Mopro native binding.
protocol AgePredicateProofEngine: Sendable {
    func prepareVerificationAssets(
        assetProgress: @escaping @Sendable (Double) -> Void) async throws

    func prove(request: AgePredicateProofRequest,
               credential: String,
               issuerDID: String,
               issuerPublicKeyX963: Data,
               holder: DeviceKey,
               assetProgress: @escaping @Sendable (Double) -> Void) async throws -> AgePredicateProofPackage

    func verify(package: AgePredicateProofPackage,
                request: AgePredicateProofRequest,
                expectedIssuerPublicKeyX963: Data,
                assetProgress: @escaping @Sendable (Double) -> Void) async throws -> AgePredicateProofTiming
}

enum AgePredicateProofEngineAssembly {
    static func make() -> any AgePredicateProofEngine {
        OpenACAgePredicateProofEngine()
    }
}

#if canImport(OpenACAgeSwift)
/// Serialises the official Mopro binding. Each operation has an isolated
/// scratch tree, but the generated witness calculator is a native library and
/// must not be assumed re-entrant merely because Swift can schedule two tasks.
actor OpenACAgePredicateProofEngine: AgePredicateProofEngine {
    private let assets: AgePredicateCircuitAssetPreparer?
    private let fileManager = FileManager.default

    init() {
        assets = try? AgePredicateCircuitAssetPreparer()
    }

    func prepareVerificationAssets(
        assetProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let assets else { throw AgePredicateProofError.nativeEngineUnavailable }
        _ = try await assets.prepare(.verifier, progress: assetProgress)
    }

    func prove(request: AgePredicateProofRequest,
               credential: String,
               issuerDID: String,
               issuerPublicKeyX963: Data,
               holder: DeviceKey,
               assetProgress: @escaping @Sendable (Double) -> Void) async throws -> AgePredicateProofPackage {
        guard let assets else { throw AgePredicateProofError.nativeEngineUnavailable }
        let installed = try await assets.prepare(.prover, progress: assetProgress)
        let scratch = try makeScratch(installedCircom: installed, role: .prover)
        defer { try? fileManager.removeItem(at: scratch.root) }
        let path = scratch.documents.path
        let issuer = try Self.coordinates(issuerPublicKeyX963)

        do {
            let clock = ContinuousClock()
            let prepareStarted = clock.now
            let prepared = try createAgePrepareInput(
                documentsPath: path,
                sdJwt: credential,
                issuerKeyX: issuer.x,
                issuerKeyY: issuer.y)
            _ = try proveJwt(documentsPath: path)
            var prepareMilliseconds = Self.milliseconds(prepareStarted.duration(to: clock.now))

            let holderSignature = try holder.signature(for: Data(request.nonce.utf8))
            let showStarted = clock.now
            try createAgeShowInput(
                documentsPath: path,
                nonce: request.nonce,
                deviceSignature: holderSignature.base64URLEncodedString(),
                claimName: prepared.claimName,
                claimFormat: prepared.claimFormat,
                cutoff: try request.cutoffValue(claimFormat: prepared.claimFormat))
            _ = try proveShow(documentsPath: path)
            var showMilliseconds = Self.milliseconds(showStarted.duration(to: clock.now))

            let prepareReblindStarted = clock.now
            _ = try generateSharedBlinds(documentsPath: path)
            _ = try reblindJwt(documentsPath: path)
            prepareMilliseconds += Self.milliseconds(prepareReblindStarted.duration(to: clock.now))
            let showReblindStarted = clock.now
            _ = try reblindShow(documentsPath: path)
            showMilliseconds += Self.milliseconds(showReblindStarted.duration(to: clock.now))

            // A holder never sends a proof it cannot itself check against the
            // exact issuer key and verifier statement.
            let accepted = try verifyAgePresentation(
                documentsPath: path,
                nonce: request.nonce,
                claimName: prepared.claimName,
                claimFormat: prepared.claimFormat,
                cutoff: try request.cutoffValue(claimFormat: prepared.claimFormat),
                expectedIssuerKeyX: issuer.x,
                expectedIssuerKeyY: issuer.y)
            guard accepted else { throw AgePredicateProofError.proofRejected }

            let keyDirectory = scratch.documents.appendingPathComponent("keys", isDirectory: true)
            let prepareProof = try Data(
                contentsOf: keyDirectory.appendingPathComponent("prepare_proof.bin"),
                options: .mappedIfSafe)
            let showProof = try Data(
                contentsOf: keyDirectory.appendingPathComponent("show_proof.bin"),
                options: .mappedIfSafe)
            return try AgePredicateProofPackage(
                request: request,
                claimName: prepared.claimName,
                claimFormat: prepared.claimFormat,
                issuerDID: issuerDID,
                prepareProof: Data(prepareProof),
                showProof: Data(showProof),
                prepareMilliseconds: prepareMilliseconds,
                showMilliseconds: showMilliseconds)
        } catch let error as AgePredicateProofError {
            throw error
        } catch {
            throw AgePredicateProofError.proofCreationFailed
        }
    }

    func verify(package: AgePredicateProofPackage,
                request: AgePredicateProofRequest,
                expectedIssuerPublicKeyX963: Data,
                assetProgress: @escaping @Sendable (Double) -> Void) async throws -> AgePredicateProofTiming {
        try package.validate(answering: request)
        guard let assets else { throw AgePredicateProofError.nativeEngineUnavailable }
        let installed = try await assets.prepare(.verifier, progress: assetProgress)
        let scratch = try makeScratch(installedCircom: installed, role: .verifier)
        defer { try? fileManager.removeItem(at: scratch.root) }
        let keyDirectory = scratch.documents.appendingPathComponent("keys", isDirectory: true)
        try package.prepareProof.write(
            to: keyDirectory.appendingPathComponent("prepare_proof.bin"), options: .atomic)
        try package.showProof.write(
            to: keyDirectory.appendingPathComponent("show_proof.bin"), options: .atomic)
        let issuer = try Self.coordinates(expectedIssuerPublicKeyX963)

        do {
            let clock = ContinuousClock()
            let started = clock.now
            let accepted = try verifyAgePresentation(
                documentsPath: scratch.documents.path,
                nonce: request.nonce,
                claimName: package.claimName,
                claimFormat: package.claimFormat,
                cutoff: try request.cutoffValue(claimFormat: package.claimFormat),
                expectedIssuerKeyX: issuer.x,
                expectedIssuerKeyY: issuer.y)
            let milliseconds = Self.milliseconds(started.duration(to: clock.now))
            guard accepted else { throw AgePredicateProofError.proofRejected }
            return AgePredicateProofTiming(
                prepareMilliseconds: package.prepareMilliseconds,
                showMilliseconds: package.showMilliseconds,
                verifyMilliseconds: milliseconds)
        } catch let error as AgePredicateProofError {
            throw error
        } catch {
            throw AgePredicateProofError.proofRejected
        }
    }

    private struct Scratch {
        let root: URL
        let documents: URL
    }

    private func makeScratch(installedCircom: URL,
                             role: AgePredicateAssetRole) throws -> Scratch {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("OpenACAgeProof-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("circom", isDirectory: true)
        try CircuitAssets.prepareDirectories(at: documents, fileManager: fileManager)
        let relativePaths: [String]
        switch role {
        case .prover:
            relativePaths = [
                "build/jwt/jwt_js/jwt.r1cs",
                "build/show/show_js/show.r1cs",
                "keys/prepare_proving.key",
                "keys/prepare_verifying.key",
                "keys/show_proving.key",
                "keys/show_verifying.key",
            ]
        case .verifier:
            relativePaths = [
                "keys/prepare_verifying.key",
                "keys/show_verifying.key",
            ]
        }
        do {
            for relativePath in relativePaths {
                let source = installedCircom.appendingPathComponent(relativePath)
                let destination = documents.appendingPathComponent(relativePath)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw AgePredicateProofError.nativeEngineUnavailable
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
            }
            return Scratch(root: root, documents: documents)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private static func coordinates(_ x963: Data) throws -> (x: String, y: String) {
        guard x963.count == 65, x963.first == 0x04 else {
            throw AgePredicateProofError.statementMismatch
        }
        return (Data(x963[1..<33]).base64URLEncodedString(),
                Data(x963[33..<65]).base64URLEncodedString())
    }

    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(Int64(0), components.seconds))
        let attoseconds = UInt64(max(Int64(0), components.attoseconds))
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
#else
/// Fail closed when a damaged or intentionally slim build omits the native
/// package. No preview or simulator path returns a fabricated proof.
struct OpenACAgePredicateProofEngine: AgePredicateProofEngine {
    func prepareVerificationAssets(
        assetProgress: @escaping @Sendable (Double) -> Void) async throws {
        throw AgePredicateProofError.nativeEngineUnavailable
    }

    func prove(request: AgePredicateProofRequest,
               credential: String,
               issuerDID: String,
               issuerPublicKeyX963: Data,
               holder: DeviceKey,
               assetProgress: @escaping @Sendable (Double) -> Void) async throws -> AgePredicateProofPackage {
        throw AgePredicateProofError.nativeEngineUnavailable
    }

    func verify(package: AgePredicateProofPackage,
                request: AgePredicateProofRequest,
                expectedIssuerPublicKeyX963: Data,
                assetProgress: @escaping @Sendable (Double) -> Void) async throws -> AgePredicateProofTiming {
        throw AgePredicateProofError.nativeEngineUnavailable
    }
}
#endif
