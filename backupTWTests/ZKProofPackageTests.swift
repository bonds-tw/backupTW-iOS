//
//  ZKProofPackageTests.swift
//  backupTWTests
//

import Foundation
import Testing

@testable import backupTW

@Suite("ZK 證明封裝")
struct ZKProofPackageTests {

    private static func makeBundle(in directory: URL,
                                   artifacts: [String: Data]? = nil,
                                   caveats: [ProofCaveat] = ProofCaveat.unconditional,
                                   selfCheck: ZKSelfCheck = .notPerformed(missing: []))
        throws -> ZKProofBundle {
        let keys = directory.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        let contents = artifacts ?? Dictionary(
            uniqueKeysWithValues: ZKProofPackage.artifactNames.map {
                ($0, Data("\($0) contents".utf8))
            })
        for (name, data) in contents {
            try data.write(to: keys.appendingPathComponent(name))
        }
        return ZKProofBundle(
            certificateChain: ProofMetrics(proveMilliseconds: 6_340, proofByteCount: 113_055),
            userSignature: ProofMetrics(proveMilliseconds: 2_130, proofByteCount: 77_743),
            caveats: caveats,
            proofDirectory: keys,
            selfCheck: selfCheck)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zkpkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The four names have to match `ZKProver`'s two lists exactly, because
    /// upstream resolves them by name from the documents path. Written down
    /// twice, they would drift on the first rename — so this is the test that
    /// makes the duplication safe rather than a comment asking nicely.
    @Test("封裝的檔名與 ZKProver 寫出的檔名一致")
    func artifactNamesMatchTheProver() {
        let fromProver = (ZKProver.proofFilenames + ZKProver.instanceFilenames)
            .map { ($0 as NSString).lastPathComponent }
        #expect(Set(ZKProofPackage.artifactNames) == Set(fromProver))
    }

    @Test("完整的一包可以來回轉換")
    func roundTrips() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try Self.makeBundle(in: directory)
        let package = try ZKProofPackage(readingFrom: bundle)
        let decoded = try ZKProofPackage.decoded(from: package.encoded())

        #expect(decoded == package)
        #expect(decoded.artifacts.count == 4)
        #expect(decoded.caveats == ProofCaveat.unconditional)
    }

    /// The witness files carry the certificate, the RSA signature and the public
    /// key — the values the proof exists to hide. Handing them to a verifier
    /// would defeat the entire feature while looking like it worked, so this is
    /// pinned rather than left to the fact that nobody wrote the code to do it.
    @Test("見證檔案永遠不會被打包出去")
    func neverPackagesTheWitness() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try Self.makeBundle(in: directory)
        // The witnesses as `prove` would have left them, had they not been
        // discarded — sitting in the same directory the packager reads.
        for name in ["cert_chain_rs4096_input.json", "user_sig_rs2048_input.json"] {
            try Data("SECRET WITNESS".utf8)
                .write(to: bundle.proofDirectory.appendingPathComponent(name))
        }

        let package = try ZKProofPackage(readingFrom: bundle)
        let wire = try package.encoded()

        #expect(package.artifacts.count == 4)
        #expect(!package.artifacts.keys.contains { $0.hasSuffix(".json") })
        #expect(!String(decoding: wire, as: UTF8.self)
            .contains(Data("SECRET WITNESS".utf8).base64EncodedString()))
    }

    @Test("缺少任何一個檔案就不能成包")
    func refusesAnIncompletePackage() throws {
        for omitted in ZKProofPackage.artifactNames {
            let directory = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            var artifacts = Dictionary(
                uniqueKeysWithValues: ZKProofPackage.artifactNames.map {
                    ($0, Data("\($0)".utf8))
                })
            artifacts.removeValue(forKey: omitted)
            let bundle = try Self.makeBundle(in: directory, artifacts: artifacts)

            #expect(throws: ZKProofPackage.PackagingError.missingArtifact(omitted)) {
                _ = try ZKProofPackage(readingFrom: bundle)
            }
        }
    }

    /// A package holding only the two proofs is unverifiable — `verify*` cannot
    /// run without the public inputs — but it would still look like a package.
    @Test("只有 proof、沒有 instance 的一包會被拒絕")
    func instancesAreNotOptional() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try Self.makeBundle(in: directory)
        let package = try ZKProofPackage(readingFrom: bundle)
        var artifacts = package.artifacts
        artifacts.removeValue(forKey: "cert_chain_rs4096_instance.bin")

        let crippled = try JSONEncoder().encode(
            ZKProofPackageFixture(version: package.version,
                                  artifacts: artifacts,
                                  caveats: package.caveats,
                                  producerSelfCheckPassed: package.producerSelfCheckPassed))
        #expect(throws: ZKProofPackage.PackagingError
            .missingArtifact("cert_chain_rs4096_instance.bin")) {
            _ = try ZKProofPackage.decoded(from: crippled)
        }
    }

    /// 使用者已經匯出過 v1 的 .zkproof（實機，2026-08-10）。版本 bump 到 2 的那天，
    /// 那些檔案必須照樣讀得進來——加字彙不應該讓舊證明變成孤兒。反方向則要拒絕：
    /// 舊 build 讀 v2 會失敗，那是對的，因為它顯示不了新的 caveat。
    @Test("v1 封包在 v2 的讀取端仍然有效")
    func stillReadsVersionOnePackages() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = try ZKProofPackage(readingFrom: try Self.makeBundle(in: directory))
        // A v1 package as an old build wrote it: version 1, the six caveats that
        // existed then.
        let vintage = try JSONEncoder().encode(
            ZKProofPackageFixture(version: 1,
                                  artifacts: package.artifacts,
                                  caveats: [.signatureMaterialIsReplayable,
                                            .idNumberDisclosedToIssuer,
                                            .noGlobalUniqueness,
                                            .certificateExpiryNotProven,
                                            .revocationRootNotAnchored],
                                  producerSelfCheckPassed: package.producerSelfCheckPassed))

        let decoded = try ZKProofPackage.decoded(from: vintage)
        try decoded.validate()
        #expect(decoded.version == 1)
        #expect(!decoded.caveats.contains(.nullifierSharedAcrossVerifiers))
    }

    @Test("寫出去的一律是現行版本")
    func alwaysWritesTheCurrentVersion() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = try ZKProofPackage(readingFrom: try Self.makeBundle(in: directory))
        #expect(package.version == ZKProofPackage.currentVersion)
        #expect(package.version == 2)
    }

    @Test("不認得的版本一律拒絕，不猜")
    func refusesAnUnknownVersion() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = try ZKProofPackage(readingFrom: try Self.makeBundle(in: directory))
        let future = try JSONEncoder().encode(
            ZKProofPackageFixture(version: 99,
                                  artifacts: package.artifacts,
                                  caveats: package.caveats,
                                  producerSelfCheckPassed: package.producerSelfCheckPassed))
        #expect(throws: ZKProofPackage.PackagingError.unsupportedVersion(99)) {
            _ = try ZKProofPackage.decoded(from: future)
        }
    }

    /// An unknown caveat must break decoding rather than be dropped. Dropping it
    /// would show a *cleaner* verdict than the evidence supports, which is the
    /// one direction of error `ProofCaveat` exists to prevent.
    @Test("不認得的 caveat 會讓整包解不開，而不是被悄悄丟掉")
    func refusesAnUnknownCaveat() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = try ZKProofPackage(readingFrom: try Self.makeBundle(in: directory))
        var json = try JSONSerialization.jsonObject(with: package.encoded()) as! [String: Any]
        json["caveats"] = ["somethingThisBuildHasNeverHeardOf"]
        let tampered = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: (any Error).self) {
            _ = try ZKProofPackage.decoded(from: tampered)
        }
    }

    @Test("過大的檔案在做任何昂貴的事之前就被擋下")
    func refusesAnOversizedArtifact() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var artifacts = Dictionary(
            uniqueKeysWithValues: ZKProofPackage.artifactNames.map { ($0, Data("x".utf8)) })
        let huge = Data(count: ZKProofPackage.maximumArtifactBytes + 1)
        artifacts["cert_chain_rs4096_proof.bin"] = huge
        let bundle = try Self.makeBundle(in: directory, artifacts: artifacts)
        let package = try ZKProofPackage(readingFrom: bundle)

        #expect(throws: ZKProofPackage.PackagingError.artifactTooLarge(
            name: "cert_chain_rs4096_proof.bin",
            bytes: ZKProofPackage.maximumArtifactBytes + 1)) {
            try package.validate()
        }
    }

    @Test("寫進查驗方的暫存目錄時，四個檔案都落在 keys/ 底下")
    func writesWhereUpstreamLooks() throws {
        let source = try Self.temporaryDirectory()
        let destination = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let package = try ZKProofPackage(readingFrom: try Self.makeBundle(in: source))
        try package.write(into: destination)

        for name in ZKProofPackage.artifactNames {
            let url = destination.appendingPathComponent("keys").appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name) 沒寫出來")

            // Data Protection is a no-op on the simulator's filesystem — the
            // attribute simply is not reported — so asserting it here would be a
            // test that passes for the wrong reason on the only machine CI has.
            // Relaxing it to "whatever the filesystem says" would be worse: it
            // would go green on a device that had lost the protection entirely.
            // So the claim is made only where it can be true, and the device
            // answer is read off the Diagnostics screen, which exists for
            // precisely the three facts a simulator cannot settle.
            #if !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen,
                    "\(name) 少了檔案保護")
            #endif
        }
    }

    /// The producing device's self-check travels, and travels as *advisory*.
    @Test("持證方自檢的結果會跟著走，但只是自述")
    func carriesTheProducerSelfCheck() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let passed = try ZKProofPackage(readingFrom: try Self.makeBundle(
            in: directory, selfCheck: .passed(ZKVerificationOutcome(
                certificateChainValid: true, userSignatureValid: true, linked: true,
                certificateChainMilliseconds: 1, userSignatureMilliseconds: 1,
                linkMilliseconds: 1))))
        #expect(passed.producerSelfCheckPassed)

        let notChecked = try ZKProofPackage(
            readingFrom: try Self.makeBundle(in: directory, selfCheck: .inconclusive))
        #expect(!notChecked.producerSelfCheckPassed)
    }
}

/// Mirrors `ZKProofPackage`'s wire shape so a test can build a *malformed* one.
/// The real type validates in `decoded(from:)`, which is exactly what these
/// tests need to exercise, so they cannot go through it to produce the input.
private struct ZKProofPackageFixture: Encodable {
    let version: Int
    let artifacts: [String: Data]
    let caveats: [ProofCaveat]
    let producerSelfCheckPassed: Bool
}
