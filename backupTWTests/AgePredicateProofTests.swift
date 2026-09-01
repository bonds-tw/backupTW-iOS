//
//  AgePredicateProofTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

struct AgePredicateProofRequestTests {

    private static let now = ROCDate.taipeiCalendar.date(
        from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!

    @Test func requestRoundTripsWithVerifierNonceAndBirthdayCutoff() throws {
        let request = try AgePredicateProofRequest(
            purpose: "超商確認已滿 18 歲",
            credentialSource: .twdiw,
            now: Self.now)
        let decoded = try AgePredicateProofRequest.decode(
            from: request.encodedForTransport(), now: Self.now.addingTimeInterval(30))

        #expect(decoded == request)
        #expect(decoded.cutoffDate == "2008-09-01")
        #expect(try decoded.cutoffValue(claimFormat: 2) == 20_080_901)
        #expect(try decoded.cutoffValue(claimFormat: 3) == 970_901)
        #expect(Data(base64URLEncoded: decoded.nonce)?.count == 32)
    }

    @Test func expiredRequestIsRefused() throws {
        let request = try AgePredicateProofRequest(
            purpose: "確認年齡", credentialSource: .selfIssued, now: Self.now)
        #expect(throws: AgePredicateProofError.staleRequest) {
            try AgePredicateProofRequest.decode(
                from: request.encodedForTransport(),
                now: Self.now.addingTimeInterval(AgePredicateProofRequest.lifetime + 1))
        }
    }

    @Test func requestCreatedFarInTheFutureIsRefused() throws {
        let request = try AgePredicateProofRequest(
            purpose: "確認年齡", credentialSource: .twdiw, now: Self.now)
        #expect(throws: AgePredicateProofError.staleRequest) {
            try AgePredicateProofRequest.decode(
                from: request.encodedForTransport(),
                now: Self.now.addingTimeInterval(-61))
        }
    }

    @Test func impossiblePrintedCutoffIsRefusedRatherThanNormalised() throws {
        let request = try AgePredicateProofRequest(
            purpose: "確認年齡", credentialSource: .selfIssued, now: Self.now)
        var object = try #require(JSONSerialization.jsonObject(
            with: Data(request.encodedForTransport().utf8)) as? [String: Any])
        object["d"] = "2008-02-31"
        let altered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: AgePredicateProofError.malformedRequest) {
            try AgePredicateProofRequest.decode(from: String(decoding: altered, as: UTF8.self),
                                                now: Self.now)
        }
    }

    @Test func packageIsBoundToTheExactRequestAndSource() throws {
        let request = try AgePredicateProofRequest(
            purpose: "確認年齡", credentialSource: .twdiw, now: Self.now)
        let package = try AgePredicateProofPackage(
            request: request, claimName: "birthdate", claimFormat: 2,
            issuerDID: "did:key:zIssuer", prepareProof: Data([1, 2]),
            showProof: Data([3, 4]), prepareMilliseconds: 1200,
            showMilliseconds: 700, createdAt: Self.now)
        let decoded = try AgePredicateProofPackage.decoded(from: package.encoded())
        try decoded.validate(answering: request)

        let other = try AgePredicateProofRequest(
            purpose: "確認年齡", credentialSource: .selfIssued, now: Self.now)
        #expect(throws: AgePredicateProofError.sourceMismatch) {
            try decoded.validate(answering: other)
        }
    }

    @Test func arbitraryDateFieldCannotBeRelabelledAsBirthdate() throws {
        let request = try AgePredicateProofRequest(
            purpose: "確認年齡", credentialSource: .twdiw, now: Self.now)
        #expect(throws: AgePredicateProofError.statementMismatch) {
            _ = try AgePredicateProofPackage(
                request: request,
                claimName: "membership_started_at",
                claimFormat: 2,
                issuerDID: "did:key:zIssuer",
                prepareProof: Data([1]),
                showProof: Data([2]),
                prepareMilliseconds: 1,
                showMilliseconds: 1,
                createdAt: Self.now)
        }
    }

    @Test func oversizedProofArtifactIsRefusedBeforeNativeParsing() throws {
        let request = try AgePredicateProofRequest(
            purpose: "確認年齡", credentialSource: .selfIssued, now: Self.now)
        #expect(throws: AgePredicateProofError.malformedPackage) {
            _ = try AgePredicateProofPackage(
                request: request,
                claimName: "birthdate",
                claimFormat: 2,
                issuerDID: "did:key:zIssuer",
                prepareProof: Data(repeating: 0, count: AgePredicateProofPackage.maximumArtifactBytes + 1),
                showProof: Data([2]),
                prepareMilliseconds: 1,
                showMilliseconds: 1,
                createdAt: Self.now)
        }
    }
}

struct SelfIssuedMyDataAgeCredentialTests {

    private static let keyTag = "tw.bonds.backupTW.tests.age-predicate"
    private static let now = ROCDate.taipeiCalendar.date(
        from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!

    @Test(arguments: [
        ("民國 083年03月06日", "0830306"),
        ("0830306", "0830306"),
        ("０８３０３０６", "0830306"),
    ])
    func normalisesObservedAndStoredROCShapes(_ raw: String, _ expected: String) {
        #expect(SelfIssuedMyDataAgeCredential.normalizedBirthDate(raw) == expected)
    }

    @Test(arguments: ["0830231", "民國 083年02月31日", "1994-03-06", "", "0000101"])
    func refusesInvalidOrGuessedDates(_ raw: String) {
        #expect(SelfIssuedMyDataAgeCredential.normalizedBirthDate(raw) == nil)
    }

    @Test(.enabled(if: DeviceKeyAvailability.isAvailable))
    func derivativeContainsOnlyCommittedBirthdateAndIsSignedByTheCardKey() throws {
        try? DeviceKey.deleteKey(tag: Self.keyTag, installRecord: nil)
        defer { try? DeviceKey.deleteKey(tag: Self.keyTag, installRecord: nil) }
        let key = try DeviceKey.loadOrCreate(tag: Self.keyTag, installRecord: nil)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let model = NationalIDModel(
            nationality: "中華民國（臺灣）", unifiedNo: "A123456789", name: "王小明",
            birthdate: "民國 083年03月06日", addressOfHousehold: "臺北市中正區")
        let (credential, disclosures) = VerifiableCredential.selectivelyDisclosableNationalID(
            model, issuerDID: did, validFrom: Self.now)
        let envelope = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(try credential.canonicalBytes()),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: Data([1]).base64EncodedString(),
                signature: Data(repeating: 0, count: 256).base64EncodedString()),
            disclosures: disclosures.map(\.encoded))

        let issued = try SelfIssuedMyDataAgeCredential.issue(
            stored: envelope.serialized(), signedBy: key, now: Self.now)
        let parsed = try TWDIWCredentialReader.read(issued.sdJWT, now: Self.now)

        #expect(parsed.issuerDID == issued.issuerDID)
        #expect(parsed.holderKey.x963Representation == key.publicKeyX963)
        #expect(parsed.disclosedClaims.count == 1)
        #expect(parsed.disclosedClaims.first?.name == "birthdate")
        #expect(parsed.disclosedClaims.first?.value == "0830306")
        #expect(parsed.credentialType == "SelfIssuedMyDataAgeCredential")
    }
}

struct AgePredicateCircuitAssetCatalogTests {

    @Test func everyRuntimeFileHasIndependentTransportAndInstalledPins() {
        let assets = AgePredicateCircuitAssetCatalog.proverAssets
        #expect(Set(assets.map(\.name)).count == assets.count)
        #expect(Set(assets.map(\.localFilename)).count == assets.count)
        for asset in assets {
            #expect(asset.remoteURL.absoluteString.contains(
                "/releases/download/\(AgePredicateCircuitAssetCatalog.releaseTag)/"))
            #expect(asset.compressedByteCount > 0)
            #expect(asset.installedByteCount > 0)
            #expect(asset.sha256?.count == 64)
            #expect(asset.installedSHA256?.count == 64)
            #expect(asset.sha256?.allSatisfy(\.isHexDigit) == true)
            #expect(asset.installedSHA256?.allSatisfy(\.isHexDigit) == true)
        }
    }

    @Test func checkerDownloadsOnlyPublicVerifyingKeys() {
        let names = Set(AgePredicateCircuitAssetCatalog.verifierAssets.map(\.name))
        #expect(names == ["openac_age_prepare_verifying", "openac_age_show_verifying"])
        #expect(AgePredicateCircuitAssetCatalog.verifierAssets.allSatisfy {
            $0.localFilename.hasSuffix("_verifying.key")
        })
    }
}
