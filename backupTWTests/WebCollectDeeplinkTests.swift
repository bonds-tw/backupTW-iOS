//
//  WebCollectDeeplinkTests.swift
//  backupTWTests
//
//  Pulling the offer deep link out of a `mobile` script-message body — the exact
//  string the issuer page posts, in a form `CredentialOfferLink.parse` can read.
//

import Testing
@testable import backupTW

/// The issuer page's script-message path (`window.webkit.messageHandlers.mobile.
/// postMessage({data:{deeplink,type}})`) is one of the two ways an offer comes
/// back. `WebCollectViewController.deeplink(inScriptMessageBody:)` is the pure part
/// of that path — the body-shape parsing — split out so it can be tested without a
/// live `WKWebView` or a JavaScript bridge. `message.body` arrives as a Foundation
/// dictionary, so that is what these feed it.
@MainActor
struct WebCollectDeeplinkTests {

    /// The whole point: the extracted string is exactly what the offer parser
    /// accepts, end to end.
    @Test func extractsADeeplinkTheOfferParserAccepts() throws {
        let body: [String: Any] = [
            "data": [
                "deeplink": "modadigitalwallet://credential_offer?credential_offer_uri=https%3A%2F%2Fissuer-oid4vci.wallet.gov.tw%2Fapi%2Fissuer%2F00000000%2Foffer",
                "type": "webview",
            ],
        ]
        let extracted = try #require(WebCollectViewController.deeplink(inScriptMessageBody: body))

        // The handoff contract: the string must parse as a by-reference offer link,
        // the same as a scanned QR.
        let link = try CredentialOfferLink.parse(scanned: extracted)
        #expect(link == .byReference(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/offer"))
    }

    /// Handed on verbatim: the official deep link has been measured carrying a CR+LF
    /// inside its query, and only the raw bytes survive to be stripped later by
    /// `CredentialOfferLink.parse`. Extraction must not round-trip through `URL`.
    @Test func handsTheStringOnVerbatim() throws {
        let raw = "modadigitalwallet://credential_offer?\r\ncredential_offer_uri=https%3A%2F%2Fa"
        let body: [String: Any] = ["data": ["deeplink": raw, "type": "webview"]]
        #expect(WebCollectViewController.deeplink(inScriptMessageBody: body) == raw)
    }

    @Test func returnsNilWhenThereIsNoDataObject() {
        #expect(WebCollectViewController.deeplink(inScriptMessageBody: ["type": "webview"]) == nil)
    }

    @Test func returnsNilWhenTheDeeplinkIsMissing() {
        let body: [String: Any] = ["data": ["type": "webview"]]
        #expect(WebCollectViewController.deeplink(inScriptMessageBody: body) == nil)
    }

    @Test func returnsNilForAnEmptyDeeplink() {
        let body: [String: Any] = ["data": ["deeplink": "", "type": "webview"]]
        #expect(WebCollectViewController.deeplink(inScriptMessageBody: body) == nil)
    }

    @Test func returnsNilForANonObjectBody() {
        #expect(WebCollectViewController.deeplink(inScriptMessageBody: "modadigitalwallet://x") == nil)
    }
}
