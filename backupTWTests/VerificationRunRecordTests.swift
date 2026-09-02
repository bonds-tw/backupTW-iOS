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

    @Test func storeRoundTripsAndKeepsOnlyTheLatestHundred() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VerificationRunStore(fileURL: directory.appendingPathComponent("runs.json"))

        for index in 0..<105 {
            try store.append(Self.record(id: UUID(), milliseconds: UInt64(index)))
        }

        let records = store.records()
        #expect(records.count == 100)
        #expect(records.first?.endToEndMilliseconds == 5)
        #expect(records.last?.endToEndMilliseconds == 104)
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
