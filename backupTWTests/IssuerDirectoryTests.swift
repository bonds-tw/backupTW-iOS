//
//  IssuerDirectoryTests.swift
//  backupTWTests
//
//  The curated type→issuer table: a readable name for a card whose trust gates
//  have already been passed, and an honest fallback for one it does not know.
//  A pure function, so it is tested as one.
//

import Foundation
import Testing
@testable import backupTW

struct IssuerDirectoryTests {

    // MARK: - Curated real-issuer mappings

    @Test("a real driving licence is the 公路局 駕照電子卡 on the 數發部 trust list")
    func drivingLicence() {
        let d = IssuerDirectory.describe(credentialType: "10000001_drivinglicense_202504251418",
                                         issuerDID: "did:key:zReal")
        #expect(d.issuerName == "交通部公路局")
        #expect(d.cardKind == "駕照電子卡")
        #expect(d.trustSource == "數位發展部信任清單")
    }

    @Test("the 駕照 substring is matched too, case-insensitively")
    func drivingLicenceChinese() {
        let d = IssuerDirectory.describe(credentialType: "10000001_DrivingLicense_x",
                                         issuerDID: "did:key:zReal")
        #expect(d.issuerName == "交通部公路局")
    }

    @Test("Taiwan Mobile issues a 門號電子卡")
    func taiwanMobile() {
        for type in ["30000001_twmdiwvc_202504251418", "30000001_twm_mobile_x"] {
            let d = IssuerDirectory.describe(credentialType: type, issuerDID: "did:key:zReal")
            #expect(d.issuerName == "台灣大哥大", "type: \(type)")
            #expect(d.cardKind == "門號電子卡")
            #expect(d.trustSource == "數位發展部信任清單")
        }
    }

    @Test("Far EasTone issues a 門號電子卡")
    func farEasTone() {
        let d = IssuerDirectory.describe(credentialType: "40000001_fet_mobile_x",
                                         issuerDID: "did:key:zReal")
        #expect(d.issuerName == "遠傳電信")
        #expect(d.cardKind == "門號電子卡")
    }

    @Test("Chunghwa Telecom issues a 門號電子卡")
    func chunghwa() {
        for type in ["50000001_chtme_202504251418", "50000001_cht_mobile_x"] {
            let d = IssuerDirectory.describe(credentialType: type, issuerDID: "did:key:zReal")
            #expect(d.issuerName == "中華電信", "type: \(type)")
            #expect(d.cardKind == "門號電子卡")
        }
    }

    /// The live 公路局 card's type spells it `driverlicense` (not `drivinglicense`),
    /// e.g. `2-16-886-101-20003-20008-20082_driverlicense_car_1211`. It must map
    /// to 交通部公路局 / 駕照電子卡, not fall through to the unknown DID fallback.
    @Test("the live driverlicense card maps to 公路局")
    func liveDriverLicence() {
        let d = IssuerDirectory.describe(
            credentialType: "2-16-886-101-20003-20008-20082_driverlicense_car_1211",
            issuerDID: "did:key:zReal")
        #expect(d.issuerName == "交通部公路局")
        #expect(d.cardKind == "駕照電子卡")
        #expect(d.trustSource == "數位發展部信任清單")
    }

    @Test("a 數位發展部 partner card is named as 數發部, kind 夥伴卡")
    func modaPartner() {
        let d = IssuerDirectory.describe(credentialType: "60000001_moda_partner_202504251418",
                                         issuerDID: "did:key:zReal")
        #expect(d.issuerName == "數位發展部")
        #expect(d.cardKind == "夥伴卡")
        #expect(d.trustSource == "數位發展部信任清單")
    }

    // MARK: - Sandbox honesty (runs before any card-type rule)

    @Test("a demo driving licence is the sandbox, never a real 公路局 card")
    func demoDrivingIsSandbox() {
        // Contains `drivinglicense`, but `demo` wins — a test card must not be
        // dressed up as a real issuer. This is the production demo fixture's type.
        let type = "00000000_demo_drivinglicense_202504251418"
        let d = IssuerDirectory.describe(credentialType: type, issuerDID: "did:key:zTest")
        #expect(d.issuerName == "沙盒系統")
        // Issuer is honestly the sandbox, but the kind still reads for what the
        // card is — a demo 駕照 is a 駕照電子卡.
        #expect(d.cardKind == "駕照電子卡")
        #expect(d.trustSource == "沙盒/測試")
    }

    @Test("a sandbox issuer DID is spotted even when the type looks real")
    func sandboxByIssuer() {
        let d = IssuerDirectory.describe(credentialType: "10000001_drivinglicense_x",
                                         issuerDID: "did:web:sandbox.wallet.gov.tw")
        #expect(d.issuerName == "沙盒系統")
        #expect(d.trustSource == "沙盒/測試")
    }

    @Test(arguments: ["10000001_example_card_x", "10000001_DEMO_thing_x"])
    func exampleAndDemoAreSandbox(_ type: String) {
        #expect(IssuerDirectory.describe(credentialType: type, issuerDID: "did:key:z").issuerName == "沙盒系統")
    }

    // MARK: - Honest fallback for the unknown

    @Test("a type this table does not know falls back to the truncated DID and says so")
    func unknownFallsBackHonestly() {
        let did = "did:key:z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuBV8xRoAnwWsdvktH"
        let d = IssuerDirectory.describe(credentialType: "70000001_library_card_202504251418",
                                         issuerDID: did)
        // No invented name: the fallback name is drawn from the DID itself.
        #expect(d.issuerName != "交通部公路局")
        #expect(d.issuerName.hasPrefix("did:key:z6Mk"))
        #expect(d.issuerName.contains("…"))
        #expect(d.cardKind == CardInventory.readableType("70000001_library_card_202504251418"))
        #expect(d.trustSource == "未列於對照表")
    }

    @Test("a short unknown DID is returned whole rather than truncated to nonsense")
    func shortUnknownDIDKeptWhole() {
        let d = IssuerDirectory.describe(credentialType: "70000001_library_card_x",
                                         issuerDID: "did:key:zShort")
        #expect(d.issuerName == "did:key:zShort")
        #expect(!d.issuerName.contains("…"))
    }
}
