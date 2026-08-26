//
//  DemoOfferGateReproTests.swift
//  backupTWTests
//
//  Reproducing a real-device refusal: a demo card scanned on 2026-08-26 was
//  refused with organisationMismatch, though its issuer host matches the demo
//  sandbox entry. This pins down where in parse→gate1→gate2 it actually breaks.
//

import Foundation
import Testing
@testable import backupTW

@Suite("實機 demo 領卡被拒的重現")
struct DemoOfferGateReproTests {

    // The literal QR string the official demo encodes — note the CR+LF the
    // deep link carries right after `credential_offer?`.
    static let scannedQR = "modadigitalwallet://credential_offer?\r\ncredential_offer_uri=https%3A%2F%2Fissuer-oid4vci.wallet.gov.tw%2Fapi%2Fissuer%2F00000000%2Fcredential-offer-object%3Fnonce%3Dcc14447d-aaef-4594-ae80-d337676d8553%26sub%3D4f1e21bfcef6859a9d8bba75b23b25ef8a8f62b9bc5ac064d089651264"

    // The offer body the demo returns (visitor card, same shape as driving licence).
    static let offerJSON = Data("""
    {"grants":{"urn:ietf:params:oauth:grant-type:pre-authorized_code":{"pre-authorized_code":"X"}},
     "credential_configuration_ids":["00000000_vpms_20250605"],
     "credential_issuer":"https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/"}
    """.utf8)

    @Test func step1_theScannedQRParses() throws {
        // The QR frames its query with a CR+LF after `credential_offer?`. A
        // plain `URL(string:)` + `parse(_:)` reads the parameter name as
        // `\r\ncredential_offer_uri` and rejects the card; `parse(scanned:)`
        // strips the framing first. This is the regression guard for the
        // driving-licence card that would not scan on device 2026-08-26.
        let link = try CredentialOfferLink.parse(scanned: Self.scannedQR)
        guard case .byReference(let fetchURL) = link else {
            Issue.record("parsed to \(link), not byReference")
            return
        }
        #expect(fetchURL.contains("issuer-oid4vci.wallet.gov.tw"))
        #expect(!fetchURL.contains("\r"))
        #expect(!fetchURL.contains("\n"))
    }

    /// The plain-URL path still fails on the CR+LF, which is why the scan entry
    /// must use `parse(scanned:)` — kept so the reason the string entry exists
    /// cannot be quietly removed.
    @Test func theRawURLPathIsWhatBreaks() {
        let url = URL(string: Self.scannedQR)
        // Either URL(string:) rejected it, or parse cannot find the uri in it.
        if let url {
            #expect(throws: CredentialOfferError.self) {
                _ = try CredentialOfferLink.parse(url)
            }
        }
    }

    @Test func step2_gate1AuthorisesTheFetchURL() throws {
        let fetchURL = "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/credential-offer-object?nonce=x&sub=y"
        let verdict = IssuerAuthorization.authorise(fetchURL: fetchURL, against: [.sandboxDemo])
        guard case .allowed(let issuers, _) = verdict else {
            Issue.record("gate 1 refused: \(verdict)")
            return
        }
        #expect(issuers.count == 1)
    }

    @Test func step3_gate2ConfirmsTheOfferIssuer() throws {
        let offer = try CredentialOffer.parse(json: Self.offerJSON)
        let result = IssuerAuthorization.confirm(credentialIssuer: offer.credentialIssuer,
                                                 matched: [.sandboxDemo])
        switch result {
        case .success: break
        case .failure(let refusal):
            Issue.record("gate 2 refused: \(refusal) — credentialIssuer=\(offer.credentialIssuer)")
        }
    }
}
