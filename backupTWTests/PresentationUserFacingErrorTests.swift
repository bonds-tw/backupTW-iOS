//
//  PresentationUserFacingErrorTests.swift
//  backupTWTests
//
//  The presentation flow's errors must reach the holder as sentences, never as
//  a Swift type or case name — the same contract collection's messages keep.
//

import Foundation
import Testing
@testable import backupTW

@Suite("出示錯誤翻譯成人話")
struct PresentationUserFacingErrorTests {

    private func isClean(_ message: String) -> Bool {
        !message.isEmpty
            && !message.contains("OID4VP")
            && !message.contains("Error")
            && !message.contains("(")   // no `case(payload)` leaking through
    }

    @Test func everyRequestErrorBecomesASentence() {
        let errors: [OID4VPRequestError] = [
            .notAnAuthorizeLink, .malformedRequestObject, .clientIDNotAResolvableDID,
            .signatureInvalid, .missingField("state"), .unsupportedResponseMode("query"),
            .responseURINotTrusted(host: "evil.example"), .requestURINotTrusted(host: "evil.example"),
            .network, .badStatus(500),
        ]
        for error in errors {
            #expect(isClean(UserFacingError.presentationMessage(for: error)),
                    "leaked for \(error)")
        }
    }

    @Test func everyResponseErrorBecomesASentence() {
        let errors: [OID4VPResponseError] = [
            .noMatchingCredential, .requestedClaimNotAvailable("name"),
            .holderKeyUnavailable, .network, .badStatus(400),
        ]
        for error in errors {
            #expect(isClean(UserFacingError.presentationMessage(for: error)),
                    "leaked for \(error)")
        }
    }

    /// The bad-status number is kept for a person to quote to a helpdesk — it is
    /// information, not an implementation detail, the same as collection's.
    @Test func theBadStatusNumberIsKept() {
        #expect(UserFacingError.presentationMessage(for: OID4VPResponseError.badStatus(503)).contains("503"))
        #expect(UserFacingError.presentationMessage(for: OID4VPRequestError.badStatus(404)).contains("404"))
    }

    /// A stranger error type still degrades to a sentence, never a type name.
    @Test func anUnknownErrorStillDegradesToASentence() {
        struct Weird: Error {}
        #expect(isClean(UserFacingError.presentationMessage(for: Weird())))
    }
}
