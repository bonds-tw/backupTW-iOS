//
//  VerificationRunRecordTests.swift
//  backupTWTests
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@Suite("驗證時間紀錄")
struct VerificationRunRecordTests {

    @Test func monotonicDurationsNeverUnderflow() {
        #expect(VerificationClock.milliseconds(from: 1_000_000, to: 6_500_000) == 5)
        #expect(VerificationClock.milliseconds(from: 9, to: 8) == 0)
    }

    @Test func storeRoundTripsAndKeepsTheLatestFullFieldTestHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VerificationRunStore(fileURL: directory.appendingPathComponent("runs.json"))

        for index in 0..<505 {
            try store.append(Self.record(id: UUID(), milliseconds: UInt64(index)))
        }

        let records = store.records()
        #expect(records.count == 500)
        #expect(records.first?.endToEndMilliseconds == 5)
        #expect(records.last?.endToEndMilliseconds == 504)
    }

    @Test func matrixCellsAreInferredWithoutCredentialContents() {
        let cases: [(VerificationRunRecord.Flow,
                     VerificationRunRecord.CredentialKind,
                     VerificationRunRecord.Transport,
                     VerificationRunRecord.MatrixCell)] = [
            (.offlinePresentation, .selfIssued, .local, .a1),
            (.disclosedAgePresentation, .selfIssued, .bluetooth, .s2),
            (.disclosedAgePresentation, .governmentWallet, .bluetooth, .s1),
            (.oid4vpPresentation, .governmentWallet, .https, .a2),
            (.zeroKnowledgeProofVerification, .mobileCertificate, .local, .a3),
            (.oid4vpPresentation, .selfIssued, .https, .g1),
            (.offlinePresentation, .governmentWallet, .local, .g2),
            (.privateAgeProof, .governmentWallet, .bluetooth, .g3),
            (.privateAgeProof, .selfIssued, .bluetooth, .g4),
            (.privateAgeProof, .governmentWallet, .local, .g3),
            // The same proof posted to the web verifier is its own cell, so the
            // matrix can put it beside the website's SD-JWT-VC run.
            (.privateAgeProof, .governmentWallet, .https, .w1),
            (.privateAgeProof, .selfIssued, .https, .w2),
        ]
        for (flow, kind, transport, expected) in cases {
            let record = VerificationRunRecord(flow: flow, role: .verifier,
                                               credentialKind: kind, transport: transport,
                                               succeeded: true)
            #expect(record.matrixCell == expected)
        }
    }

    @Test func webComparisonPairsTheLatestSuccessfulRunsPerCardFamily() {
        func run(_ flow: VerificationRunRecord.Flow,
                 _ kind: VerificationRunRecord.CredentialKind,
                 _ transport: VerificationRunRecord.Transport,
                 succeeded: Bool,
                 endToEnd: UInt64) -> VerificationRunRecord {
            VerificationRunRecord(flow: flow, role: .holder, credentialKind: kind,
                                  transport: transport, succeeded: succeeded,
                                  endToEndMilliseconds: endToEnd)
        }
        let records = [
            run(.oid4vpPresentation, .governmentWallet, .https, succeeded: true, endToEnd: 4_000),
            run(.oid4vpPresentation, .governmentWallet, .https, succeeded: true, endToEnd: 5_000),
            run(.oid4vpPresentation, .governmentWallet, .https, succeeded: false, endToEnd: 9_000),
            run(.privateAgeProof, .governmentWallet, .bluetooth, succeeded: true, endToEnd: 30_000),
            run(.privateAgeProof, .governmentWallet, .https, succeeded: true, endToEnd: 26_000),
            run(.privateAgeProof, .selfIssued, .https, succeeded: true, endToEnd: 24_000),
        ]
        let comparisons = VerificationRunComparison.latest(in: records)
        #expect(comparisons.count == 2)
        let government = try? #require(comparisons.first { $0.credentialKind == .governmentWallet })
        #expect(government?.sdJWT?.endToEndMilliseconds == 5_000)
        #expect(government?.zeroKnowledge?.endToEndMilliseconds == 26_000)
        #expect(government?.endToEndDifferenceMilliseconds == 21_000)
        let selfIssued = comparisons.first { $0.credentialKind == .selfIssued }
        #expect(selfIssued?.sdJWT == nil)
        #expect(selfIssued?.zeroKnowledge?.endToEndMilliseconds == 24_000)
        #expect(selfIssued?.endToEndDifferenceMilliseconds == nil)
        #expect(VerificationRunComparison.latest(in: []).isEmpty)
    }

    @Test func correlationTokenIsShortAndDoesNotRetainTheRequestIdentifier() {
        let request = "A request identifier that must not be retained"
        let token = VerificationRunRecord.correlationToken(for: request)
        #expect(token.count == 16)
        #expect(!token.contains(request))
        #expect(token == VerificationRunRecord.correlationToken(for: request))
    }

    @Test func persistedSchemaHasNoPlaceForCredentialContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("runs.json")
        let store = VerificationRunStore(fileURL: file)
        try store.append(Self.record(id: UUID(), milliseconds: 321))

        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(!json.contains("did:key"))
        #expect(!json.contains("credentialSubject"))
        #expect(!json.contains("response_uri"))
        #expect(!json.contains("session"))
    }

    @Test func bluetoothDiagnosticsKeepOnlyTheLatestStatePerRole() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BluetoothLinkDiagnosticStore(
            fileURL: directory.appendingPathComponent("bluetooth-link.json"))

        try store.record(role: .holder, state: .starting,
                         now: Date(timeIntervalSince1970: 1))
        try store.record(role: .holder, state: .transferring(fraction: 0.63),
                         now: Date(timeIntervalSince1970: 2))
        try store.record(role: .verifier, state: .waiting,
                         now: Date(timeIntervalSince1970: 3))

        let records = store.records()
        #expect(records.count == 2)
        #expect(records[0].role == .holder)
        #expect(records[0].phase == .transferring)
        #expect(records[0].progressPercent == 50)
        #expect(records[1].role == .verifier)
        #expect(records[1].phase == .waiting)
    }

    @Test func bluetoothDiagnosticsNeverPersistTheTransferredPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bluetooth-link.json")
        let store = BluetoothLinkDiagnosticStore(fileURL: file)
        let privatePayload = Data("did:key:zPrivate credentialSubject response_uri".utf8)

        try store.record(role: .verifier, state: .finished(payload: privatePayload))

        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(!json.contains("did:key"))
        #expect(!json.contains("credentialSubject"))
        #expect(!json.contains("response_uri"))
        #expect(store.records().first?.phase == .finished)
        #expect(store.records().first?.progressPercent == 100)
    }

    private static func record(id: UUID, milliseconds: UInt64) -> VerificationRunRecord {
        VerificationRunRecord(id: id,
                              recordedAt: Date(timeIntervalSince1970: 1),
                              flow: .offlinePresentation,
                              role: .verifier,
                              credentialKind: .selfIssued,
                              transport: .bluetooth,
                              succeeded: true,
                              transportMilliseconds: milliseconds / 2,
                              verificationMilliseconds: milliseconds / 2,
                              endToEndMilliseconds: milliseconds,
                              deviceModel: "test-device",
                              osVersion: "test-os",
                              appVersion: "1",
                              appBuild: "1")
    }
}

@MainActor
@Suite("驗證結果計時畫面")
struct VerificationTimingScreenTests {

    @Test func timingAppearsNearTheVerdictWithAllThreeOfflineMeasures() throws {
        let timing = VerificationRunRecord(
            flow: .offlinePresentation,
            role: .verifier,
            credentialKind: .selfIssued,
            transport: .bluetooth,
            succeeded: nil,
            transportMilliseconds: 1_500,
            verificationMilliseconds: 250,
            endToEndMilliseconds: 1_750,
            deviceModel: "test-device",
            osVersion: "test-os")
        let screen = VerificationResultViewController(outcome: nil, timing: timing)
        screen.loadViewIfNeeded()
        screen.view.layoutIfNeeded()

        let card = try #require(Self.find(identifier: "verificationResult.timing", in: screen.view))
        let text = Self.labels(in: card).compactMap(\.text).joined(separator: "\n")
        #expect(text.contains("1.50"))
        #expect(text.contains("0.25"))
        #expect(text.contains("1.75"))
    }

    private static func find(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap { find(identifier: identifier, in: $0) }.first
    }

    private static func labels(in root: UIView) -> [UILabel] {
        (root as? UILabel).map { [$0] } ?? root.subviews.flatMap(labels)
    }
}
