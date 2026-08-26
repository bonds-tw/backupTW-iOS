//
//  UserFacingErrorTests.swift
//  backupTWTests
//
//  The collection alert must never show a person a Swift type name again.
//

import Foundation
import Testing
@testable import backupTW

@Suite("領卡失敗的字是給人看的,不是給 debugger 看的")
struct UserFacingErrorTests {

    /// Every error that can reach the collection alert, one representative of
    /// each case. Not `CaseIterable` — several carry associated values — so the
    /// list is spelled out, and a new upstream case that is added without a
    /// mapping falls through to the generic sentence rather than to its type
    /// name, which the forbidden-token test below would still catch if it did.
    static let everyReachableError: [Error] = [
        // Gate refusals
        IssuerAuthorization.Refusal.notOnTheTrustList(host: "issuer-sandbox.wallet.gov.tw.evil.tw"),
        IssuerAuthorization.Refusal.organisationMismatch,
        IssuerAuthorization.Refusal.notHTTPS,
        IssuerAuthorization.Refusal.unusableHost,
        IssuerAuthorization.Refusal.containsUserInfo,
        IssuerAuthorization.Refusal.unexpectedPort(8080),
        IssuerAuthorization.Refusal.hostNotPlainASCII,
        IssuerAuthorization.Refusal.pathNotNormalised,
        // Collection
        OID4VCICollectionError.refused(.notOnTheTrustList(host: "evil.tw")),
        OID4VCICollectionError.network(step: .token),
        OID4VCICollectionError.badStatus(step: .token, code: 400),
        OID4VCICollectionError.malformedResponse(step: .credential),
        OID4VCICollectionError.missingField(step: .token, field: "access_token"),
        OID4VCICollectionError.credentialEndpointHostMismatch,
        OID4VCICollectionError.issuedCredentialDoesNotVerify,
        OID4VCICollectionError.credentialNotBoundToOurKey,
        OID4VCICollectionError.keyUnavailable,
        // Offer parsing
        CredentialOfferError.notACredentialOffer,
        CredentialOfferError.ambiguousOfferForm,
        CredentialOfferError.noPreAuthorizedGrant,
        // Trust list
        TrustListFetcherError.network,
        TrustListFetcherError.badStatus(500),
        TrustListFetcherError.emptyList,
        // Store
        CredentialStoreError.invalidIdentifier,
        // Something entirely unmapped
        URLError(.timedOut),
    ]

    /// Substrings that would betray an implementation detail on screen. If any
    /// message contains one, the translation layer let a type name through.
    static let forbidden = [
        "backupTW", "OID4VCI", "IssuerAuthorization", "Refusal", "CredentialOffer",
        "TrustListFetcher", "CredentialStore", "URLError", "Optional(", "Error.",
        "notOnTheTrustList", "badStatus", "(step:", "(host:",
    ]

    @Test(arguments: everyReachableError)
    func noMessageLeaksATypeName(_ error: Error) {
        let message = UserFacingError.collectionMessage(for: error)
        #expect(!message.isEmpty)
        for token in Self.forbidden {
            #expect(!message.contains(token),
                    "message leaked \"\(token)\": \(message)")
        }
    }

    @Test func theTrustGateSpeaksOfTrustNotOfHosts() {
        let message = UserFacingError.collectionMessage(
            for: OID4VCICollectionError.refused(.notOnTheTrustList(host: "evil.tw")))
        // Says why in a word a person owns; does not echo the attacker's host.
        #expect(message.contains("可信任") || message.lowercased().contains("trusted"))
        #expect(!message.contains("evil.tw"))
    }

    @Test func aBadStatusKeepsTheNumberAPersonWouldQuote() {
        let message = UserFacingError.collectionMessage(
            for: OID4VCICollectionError.badStatus(step: .token, code: 400))
        // The number is information a helpdesk can use; the step label is not.
        #expect(message.contains("400"))
        #expect(!message.contains("token"))
        #expect(!message.contains("step"))
    }

    @Test func anUnmappedErrorDegradesToASentenceNotAType() {
        let message = UserFacingError.collectionMessage(for: URLError(.timedOut))
        #expect(!message.isEmpty)
        #expect(!message.contains("URLError"))
        #expect(!message.contains("Code"))
    }
}
