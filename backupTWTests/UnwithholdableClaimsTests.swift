//
//  UnwithholdableClaimsTests.swift
//  backupTWTests
//
//  The one field the holder is not offered a choice about, and why.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// The defect these pin down was live, and it was the worst kind this project
/// can ship: a control that did nothing.
///
/// The holder's screen offered a switch for 姓名 and promised 「沒有勾的欄位不會
/// 送出」. Turning it off removed the `name` disclosure — and the name went
/// anyway, inside `proof.certificate`, because the checker cannot verify a
/// signature without the certificate and an X.509 Subject CN *is* the
/// cardholder's legal name. The checker's screen then printed it, above the line
/// saying how many fields had been held back.
///
/// The fix is not architectural, because the leak is not a bug. X.509 has no
/// selective disclosure: the CA's signature covers the whole TBSCertificate, so
/// a certificate with the name stripped does not verify. What was wrong was the
/// screen, and what these tests protect is the screen telling the truth.
struct UnwithholdableClaimsTests {

    private static let keyTag = "tw.bonds.backupTW.tests.unwithholdable"

    private static let everyClaim = ["nationality", "unifiedNo", "name", "birthdate",
                                     AgePredicate.claimName, "addressOfHousehold"]

    /// The case a screen test would not reach, and the one that matters: the
    /// holder ticks nothing at all, and the name is disclosed regardless.
    @Test func tickingNothingStillDisclosesTheNameThatCannotBeHidden() throws {
        let disclosing = try #require(PresentCredentialViewController.claimsToDisclose(
            chosen: [], offered: Self.everyClaim))

        #expect(disclosing == ["name"])
    }

    /// Adding, never subtracting. A holder who ticked three fields gets those
    /// three plus the one they were never offered — not a set silently replaced.
    @Test func theForcedClaimIsAddedToWhateverWasChosen() throws {
        let disclosing = try #require(PresentCredentialViewController.claimsToDisclose(
            chosen: ["unifiedNo", AgePredicate.claimName], offered: Self.everyClaim))

        #expect(Set(disclosing) == ["unifiedNo", AgePredicate.claimName, "name"])
    }

    /// Ticking it explicitly must not produce it twice — `disclosing` is a list,
    /// and a duplicate would reach `SelectiveDisclosure.reveal` as two
    /// disclosures of one claim.
    @Test func choosingItExplicitlyChangesNothing() throws {
        let withIt = try #require(PresentCredentialViewController.claimsToDisclose(
            chosen: ["name", "unifiedNo"], offered: Self.everyClaim))
        let withoutIt = try #require(PresentCredentialViewController.claimsToDisclose(
            chosen: ["unifiedNo"], offered: Self.everyClaim))

        #expect(withIt == withoutIt)
        #expect(withIt.filter { $0 == "name" }.count == 1)
    }

    /// A credential with nothing to withhold — one issued before selective
    /// disclosure existed — discloses everything, and `nil` is how that is said.
    /// Forcing a claim into an empty offer would name a claim the credential does
    /// not commit to, and `reveal` refuses uncommitted disclosures.
    @Test func anOlderCredentialWithNoChoicesStillMeansEverything() {
        #expect(PresentCredentialViewController.claimsToDisclose(chosen: [], offered: []) == nil)
        #expect(PresentCredentialViewController.claimsToDisclose(chosen: ["name"], offered: []) == nil)
    }

    /// The forcing is driven by what the credential actually offers, not by the
    /// constant. A future credential shape with no `name` claim must not have one
    /// invented for it.
    @Test func aClaimTheCredentialDoesNotHaveIsNotInvented() throws {
        let disclosing = try #require(PresentCredentialViewController.claimsToDisclose(
            chosen: ["nationality"], offered: ["nationality", "unifiedNo"]))

        #expect(disclosing == ["nationality"])
    }

    /// The list is deliberately short, and every entry on it costs the holder a
    /// choice. Anything added here needs the same evidence `name` has: the value
    /// provably leaves the device by another route.
    @Test func onlyTheNameIsTakenAwayAsAChoice() {
        #expect(PresentCredentialViewController.cannotBeWithheld == ["name"])
    }

    /// The screen and the presentation layer must not be able to disagree. The
    /// screen removes the switch; the presentation layer is what actually decides
    /// what leaves, and it is the one that has to hold.
    @Test func theScreenAndThePresentationLayerAgreeOnWhatCannotBeWithheld() {
        #expect(PresentCredentialViewController.cannotBeWithheld
                == VerifiablePresentation.claimsThatCannotBeWithheld)
    }

    /// **The bug this file exists to stop, caught on a real phone.**
    ///
    /// The forcing lived only in the view controller. A debug affordance called
    /// `HolderPresentation.frames(answering:disclosing:)` directly, asked to
    /// disclose nothing, and got exactly that — so the checker's result screen
    /// said 「對方沒有出示姓名，所以無法核對上面那張憑證是不是同一個人的」 while
    /// printing the name off the certificate two lines above it.
    ///
    /// A guarantee enforced by one caller is not a guarantee. This asserts it
    /// where every caller has to go through.
    @Test func askingToDiscloseNothingStillDisclosesTheNameAtThePresentationLayer() throws {
        defer { try? DeviceKey.deleteKey(tag: Self.keyTag) }
        let key = try DeviceKey.loadOrCreate(tag: Self.keyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)

        let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                    unifiedNo: "A123456789",
                                    name: "王小明",
                                    birthdate: "民國 083年03月06日",
                                    addressOfHousehold: "臺北市中正區重慶南路一段122號")
        let issuedAt = Date(timeIntervalSince1970: 1_786_000_000)
        let (credential, disclosures) = VerifiableCredential.selectivelyDisclosableNationalID(
            model, issuerDID: did, validFrom: issuedAt)
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential)
        let envelope = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: try cardSignature(over: Data(tbs.utf8)).base64EncodedString()),
            disclosures: disclosures.map { $0.encoded })

        let request = try PresentationRequest(challenge: "Q0hBTExFTkdFLTAwMDAwMA",
                                              purpose: "撤銷檢查測試",
                                              createdAt: issuedAt,
                                              audience: nil)
        // Straight to the presentation layer, bypassing the screen entirely —
        // which is precisely what the debug button did on the phone.
        let jws = try VerifiablePresentation.create(credentialJWS: try envelope.serialized(),
                                                    request: request,
                                                    signedBy: key,
                                                    holderDID: did,
                                                    disclosing: [],
                                                    createdAt: issuedAt)

        let verified = try MOICASignedCredential
            .parse(try Self.envelopeSerialization(inPresentation: jws))
            .verify(signedBy: try X509Certificate.parse(base64DER: holderCertificateDER))

        #expect(verified.claims["name"] == "王小明")
        #expect(verified.cardholderNameWasChecked,
                "the checker was shown a name with nothing tying it to the document")
        #expect(verified.withheldClaimCount == 5)
    }

    private static func envelopeSerialization(inPresentation jws: String) throws -> String {
        let segments = jws.components(separatedBy: ".")
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let object = try JSONSerialization.jsonObject(
            with: try #require(Data(base64Encoded: base64))) as? [String: Any]
        let array = try #require(object?["verifiableCredential"] as? [Any])
        let first = try #require(array.first as? [String: Any])
        let identifier = try #require(first["id"] as? String)
        return try #require(EnvelopedVerifiableCredential(
            context: "", id: identifier, type: "").moicaSignedSerialization)
    }

    /// The screen must not say the old sentence again.
    ///
    /// Asserted on the Chinese, because that is what the holder reads — and
    /// because the previous version of a wording test in this repo passed only
    /// while the string was untranslated.
    @Test func theHoldersScreenNoLongerPromisesTheNameCanBeHeldBack() throws {
        let chinese = try #require(Self.chinese(for:
            "Showing this document always reveals your name, because it is written into the certificate that signs it. The same certificate goes to every checker, so any two of them can tell it was the same person."))

        #expect(chinese.contains("姓名"))
        #expect(chinese.contains("憑證"))
    }

    private static func chinese(for englishKey: String) -> String? {
        guard let path = Bundle(for: PresentCredentialViewController.self)
                  .path(forResource: "zh-Hant", ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let sentinel = "__no-translation__"
        let value = bundle.localizedString(forKey: englishKey, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }
}
