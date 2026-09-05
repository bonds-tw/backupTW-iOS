import CryptoKit
import Foundation
import Testing
@testable import backupTW

@Suite(.serialized)
struct SDJWTAgePresentationTests {
    let now = Date(timeIntervalSince1970: 1_788_600_000)

    private func material() throws -> AgePredicateCredentialMaterial {
        let key = try DeviceKey.loadOrCreate(tag: "tw.bonds.tests.offline-age", installRecord: nil)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let model = NationalIDModel(nationality: "fixture", unifiedNo: "A123456789", name: "Test",
                                    birthdate: "0830306", addressOfHousehold: "fixture")
        let (vc, disclosures) = VerifiableCredential.selectivelyDisclosableNationalID(model, issuerDID: did, validFrom: now)
        // Synthetic MyData envelope. Only the derivative is used by these tests;
        // this dummy MOICA signature is not government-attestation evidence.
        let envelope = MOICASignedCredential(payload: VerifiableCredential.base64URLEncoded(try vc.canonicalBytes()),
            proof: MOICACredentialProof(tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                                        certificate: Data([1]).base64EncodedString(),
                                        signature: Data(repeating: 0, count: 256).base64EncodedString()),
            disclosures: disclosures.map(\.encoded))
        let issued = try SelfIssuedMyDataAgeCredential.issue(stored: envelope.serialized(), signedBy: key, now: now)
        return AgePredicateCredentialMaterial(sdJWT: issued.sdJWT, issuerDID: issued.issuerDID,
            issuerPublicKeyX963: key.publicKeyX963, holderKey: key, cacheKey: "synthetic")
    }

    @Test(.enabled(if: DeviceKeyAvailability.isAvailable))
    func genuineSignaturesVerifyLocallyButWrongRequestTamperingAndExpiryFail() throws {
        defer { try? DeviceKey.deleteKey(tag: "tw.bonds.tests.offline-age", installRecord: nil) }
        let material = try material()
        let request = try AgePredicateProofRequest(purpose: "test", credentialSource: .selfIssued,
                                                   discloseBirthdate: true, now: now)
        let data = try SDJWTAgePresentation.create(material: material, request: request, now: now)
        #expect(try SDJWTAgePresentation.verify(data, request: request, trust: .unavailable, now: now))
        let other = try AgePredicateProofRequest(purpose: "test", credentialSource: .selfIssued,
                                                 discloseBirthdate: true, now: now)
        #expect(throws: (any Error).self) {
            try SDJWTAgePresentation.verify(data, request: other, trust: .unavailable, now: now)
        }
        #expect(throws: (any Error).self) {
            try SDJWTAgePresentation.verify(data, request: request, trust: .unavailable, now: now.addingTimeInterval(301))
        }
        var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        let presentation = try #require(envelope["presentation"])
        // Change a signature byte, not merely unused base64 padding bits.
        var segments = presentation.components(separatedBy: ".")
        var signature = try #require(Data(base64URLEncoded: segments.removeLast()))
        signature[0] ^= 1
        envelope["presentation"] = segments.joined(separator: ".") + "." + signature.base64URLEncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: (any Error).self) {
            try SDJWTAgePresentation.verify(tampered, request: request, trust: .unavailable, now: now)
        }
    }

    @Test(.enabled(if: DeviceKeyAvailability.isAvailable))
    func governmentSourceRequiresIndependentTrustAndUnderageIsNotSuccess() throws {
        defer { try? DeviceKey.deleteKey(tag: "tw.bonds.tests.offline-age", installRecord: nil) }
        let material = try material()
        let government = try AgePredicateProofRequest(purpose: "test", credentialSource: .twdiw,
                                                       discloseBirthdate: true, now: now)
        let data = try SDJWTAgePresentation.create(material: material, request: government, now: now)
        #expect(throws: AgePredicateProofError.credentialIsNotTrusted) {
            try SDJWTAgePresentation.verify(data, request: government, trust: .unavailable, now: now)
        }
        let older = try AgePredicateProofRequest(purpose: "test", credentialSource: .selfIssued,
                                                  minimumAge: 100, discloseBirthdate: true, now: now)
        let olderData = try SDJWTAgePresentation.create(material: material, request: older, now: now)
        #expect(try !SDJWTAgePresentation.verify(olderData, request: older, trust: .unavailable, now: now))
    }

    @Test func formatCannotBeSilentlyDowngradedOrPostedToTheWeb() throws {
        let sd = try AgePredicateProofRequest(purpose: "test", credentialSource: .selfIssued,
                                               discloseBirthdate: true, now: now)
        #expect(try AgePredicateProofRequest.decode(from: sd.encodedForTransport(), now: now).disclosesBirthdate)
        #expect(sd.version == 2)
        #expect(throws: AgePredicateProofError.statementMismatch) {
            try AgePredicateProofPackage(request: sd, claimName: "birthdate", claimFormat: 3,
                issuerDID: "did:key:fixture", prepareProof: Data([1]), showProof: Data([2]),
                prepareMilliseconds: 1, showMilliseconds: 1)
        }
        #expect(throws: AgePredicateProofError.malformedRequest) {
            try AgePredicateProofRequest(purpose: "test", credentialSource: .selfIssued,
                responseURL: URL(string: "https://verifier.mashbean.net/api/zkp/response/test")!,
                discloseBirthdate: true, now: now)
        }
    }

    @Test(arguments: ["0830231", "0000000", "2000-02-31", "0000-01-01", "2000-1-01", "2000-01-0a"])
    func malformedDatesAreNeverNormalised(_ value: String) {
        #expect(throws: AgePredicateProofError.noBirthDate) { try SDJWTAgePresentation.dateValue(value) }
    }

    @Test func sameCivilDateHasSameCutoffAcrossFormats() throws {
        #expect(try SDJWTAgePresentation.dateValue("0830306") == SDJWTAgePresentation.dateValue("1994-03-06"))
    }
}
