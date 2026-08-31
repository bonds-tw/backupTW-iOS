//
//  ConvenienceStorePickupTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

@Suite("超商取貨正式服務")
struct ConvenienceStorePickupTests {

    @Test func officialCatalogueShapeKeepsTheVerifierModule() throws {
        let body = Data(#"""
        {
          "code":"0","message":"SUCCESS","data":{"vpItems":[
            {"vpUid":"23060248_tfmdw_pickup","name":"全家便利商店包裹取貨","verifierModuleUrl":"https://23060248.wallet.gov.tw/oid4vp","logoUrl":null},
            {"vpUid":"22555003_711pickup","name":"統一超商包裹取貨","verifierModuleUrl":"https://22555003.wallet.gov.tw/oid4vp","logoUrl":"https://22555003.wallet.gov.tw/logo.png"},
            {"vpUid":"broken","name":"缺少端點","verifierModuleUrl":null,"logoUrl":null}
          ]}}
        """#.utf8)

        let scenarios = try ConvenienceStorePickupCatalog.scenarios(from: body)
        #expect(scenarios.count == 2)
        let sevenEleven = try #require(scenarios.first {
            $0.vpUid == ConvenienceStorePickupCatalog.sevenElevenVPUID
        })
        #expect(sevenEleven.name == "統一超商包裹取貨")
        #expect(sevenEleven.verifierModuleURL == "https://22555003.wallet.gov.tw/oid4vp")
    }

    @Test func startResponseKeepsTransactionAndAuthorizeLink() throws {
        let link = "modadigitalwallet://authorize?client_id=did:key:zTest&request_uri=https%3A%2F%2F22555003.wallet.gov.tw%2Frequest%2Fopaque"
        let body = try JSONSerialization.data(withJSONObject: [
            "code": "0",
            "message": "SUCCESS",
            "data": ["transactionId": "transaction-not-logged", "deepLink": link],
        ])

        let parsed = try ConvenienceStorePickupClient.parseStart(body)
        #expect(parsed.transactionID == "transaction-not-logged")
        #expect(parsed.deepLink == link)
    }

    @Test func signedCredentialURLBecomesTheDisplayedSerial() {
        #expect(ConvenienceStorePickupClient.credentialSerial(
            from: "https://issuer-vc.wallet.gov.tw/api/credential/39d60715-e90c-402a-98aa-test")
            == "39d60715-e90c-402a-98aa-test")
        #expect(ConvenienceStorePickupClient.credentialSerial(from: "") == nil)
    }

    @Test func verifierPNGAndLifetimeAreTheOnlyBarcodeSource() throws {
        // A complete 1×1 PNG. The model keeps these exact verifier bytes; it
        // never re-encodes disclosed claims into a local QR image.
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let body = try JSONSerialization.data(withJSONObject: [
            "code": "0",
            "data": [
                "qrcode": "data:image/png;base64," + png.base64EncodedString(),
                "totptimeout": "300",
            ],
        ])
        let generated = Date(timeIntervalSince1970: 1_800_000_000)
        let barcode = try ConvenienceStorePickupClient.parseBarcode(body, now: generated)

        #expect(barcode.imageData == png)
        #expect(barcode.lifetime == 300)
        #expect(barcode.generatedAt == generated)
    }

    @Test func aNonPNGOrServerRefusalIsNeverShownAsABarcode() throws {
        let textImage = Data("not a png".utf8).base64EncodedString()
        let malformed = try JSONSerialization.data(withJSONObject: [
            "code": "0",
            "data": ["qrcode": "data:image/png;base64," + textImage, "totptimeout": "300"],
        ])
        #expect(throws: ConvenienceStorePickupError.invalidBarcodeImage) {
            _ = try ConvenienceStorePickupClient.parseBarcode(malformed, now: Date())
        }

        let refused = try JSONSerialization.data(withJSONObject: ["code": "4021", "message": "refused"])
        #expect(throws: ConvenienceStorePickupError.serverCode("4021")) {
            _ = try ConvenienceStorePickupClient.parseStart(refused)
        }
    }
}
