//
//  IssuerAuthorizationTests.swift
//  backupTWTests
//
//  A URL arrived in a QR code. May we contact it?
//

import Foundation
import Testing
@testable import backupTW

@Suite("領卡對象是不是清單上的人")
struct IssuerAuthorizationTests {

    static let sandbox = TWDIWIssuer(
        did: "did:key:z2dmzD81…sandbox",
        displayName: "數位憑證皮夾沙盒",
        displayNameEnglish: "Taiwan Digital Identity Wallet Sandbox",
        taxID: "00000000",
        issuerMetadataBaseURL: "https://issuer-oid4vci.wallet.gov.tw",
        serviceBaseURL: nil,
        reportsOnChainAnchor: true)

    static let moda = TWDIWIssuer(
        did: "did:key:z2dmzD81…moda",
        displayName: "行政院-數位發展部",
        displayNameEnglish: "Ministry of Digital Affairs",
        taxID: "2-16-886-101-20003-20082",
        issuerMetadataBaseURL: nil,
        serviceBaseURL: "https://moda.wallet.gov.tw",
        reportsOnChainAnchor: true)

    static let list = [sandbox, moda]

    // MARK: The ordinary case

    @Test func aHostOnTheListIsAllowed() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/credential-offer-object?nonce=abc&sub=def",
            against: Self.list)
        guard case .allowed(let issuers, let host) = verdict else {
            Issue.record("a real issuer was refused: \(verdict)")
            return
        }
        #expect(issuers == [Self.sandbox])
        #expect(host == "issuer-oid4vci.wallet.gov.tw")
    }

    @Test func aHostThatIsNotOnTheListIsRefused() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://wallet.example.tw/api/issuer/1/credential-offer-object",
            against: Self.list)
        #expect(verdict == .refused(.notOnTheTrustList(host: "wallet.example.tw")))
    }

    // MARK: The attacks prefix matching would let through

    /// **The reason this is not `hasPrefix`.**
    ///
    /// `https://issuer-oid4vci.wallet.gov.tw.evil.tw/` has the trusted base as a
    /// literal string prefix. Compared as hosts it is a different host, and
    /// nothing about it is close.
    @Test func aSuffixedLookalikeHostIsRefused() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw.evil.tw/api/issuer/00000000/",
            against: Self.list)
        #expect(verdict == .refused(.notOnTheTrustList(host: "issuer-oid4vci.wallet.gov.tw.evil.tw")))
    }

    /// `https://issuer-oid4vci.wallet.gov.tw@evil.tw/` reads, to a person
    /// glancing at it, as the government host. The host is `evil.tw`.
    @Test func userInfoIsRefusedRatherThanParsedAround() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw@evil.tw/api/",
            against: Self.list)
        #expect(verdict == .refused(.containsUserInfo))
    }

    /// A trailing dot is a legal absolute DNS name resolving to the same place,
    /// and a different string. Two spellings of one host is the thing this
    /// comparison must not have, so it is refused rather than folded.
    @Test func aTrailingDotHostIsRefused() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw./api/",
            against: Self.list)
        #expect(verdict == .refused(.hostNotPlainASCII))
    }

    @Test func caseInTheHostDoesNotMatter() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://Issuer-OID4VCI.Wallet.GOV.TW/api/",
            against: Self.list)
        guard case .allowed(_, let host) = verdict else {
            Issue.record("case-folding refused a real host")
            return
        }
        #expect(host == "issuer-oid4vci.wallet.gov.tw")
    }

    @Test func plainHTTPIsRefused() {
        #expect(IssuerAuthorization.authorise(
            fetchURL: "http://issuer-oid4vci.wallet.gov.tw/api/",
            against: Self.list) == .refused(.notHTTPS))
    }

    @Test func anExplicitOddPortIsRefused() {
        #expect(IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw:8443/api/",
            against: Self.list) == .refused(.unexpectedPort(8443)))
    }

    /// 443 spelled out is the same endpoint, and refusing it would be pedantry
    /// aimed at somebody honest.
    @Test func port443SpelledOutIsFine() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw:443/api/",
            against: Self.list)
        guard case .allowed = verdict else {
            Issue.record("explicit :443 was refused")
            return
        }
    }

    @Test func percentEncodedDotsAreRefused() {
        #expect(IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/%2e%2e/elsewhere",
            against: Self.list) == .refused(.pathNotNormalised))
    }

    @Test func aNonASCIIHostIsRefusedNotFolded() {
        let verdict = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw.台灣/api/",
            against: Self.list)
        // Either refusal is defensible; what must not happen is a match.
        guard case .refused = verdict else {
            Issue.record("a Unicode host matched a trusted one")
            return
        }
    }

    // MARK: Gate 2

    /// The offer must name an issuer from the same organisation as the URL it
    /// arrived from. Fetching from one host and being told to collect from
    /// another is exactly the redirection this gate exists to catch.
    @Test func anOfferNamingADifferentOrganisationIsRefused() {
        guard case .allowed(let matched, _) = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/credential-offer-object",
            against: Self.list) else {
            Issue.record("gate 1 refused a real issuer")
            return
        }
        let confirmed = IssuerAuthorization.confirm(
            credentialIssuer: "https://moda.wallet.gov.tw/api/issuer/9/",
            matched: matched)
        #expect(confirmed == .failure(.organisationMismatch))
    }

    @Test func anOfferNamingTheSameOrganisationIsConfirmed() {
        guard case .allowed(let matched, _) = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/credential-offer-object",
            against: Self.list) else {
            Issue.record("gate 1 refused a real issuer")
            return
        }
        #expect(IssuerAuthorization.confirm(
            credentialIssuer: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/",
            matched: matched) == .success(Self.sandbox))
    }

    /// Ambiguity is refused rather than resolved by array order. A wallet that
    /// picked one would be inventing the name it then shows the user.
    @Test func aHostBelongingToTwoOrganisationsIsRefusedNotGuessed() {
        let twin = TWDIWIssuer(did: "did:key:z2dmzD81…twin", displayName: "另一個機關",
                               displayNameEnglish: "Another Agency", taxID: "11111111",
                               issuerMetadataBaseURL: "https://issuer-oid4vci.wallet.gov.tw",
                               serviceBaseURL: nil, reportsOnChainAnchor: true)
        let list = [Self.sandbox, twin]
        guard case .allowed(let matched, _) = IssuerAuthorization.authorise(
            fetchURL: "https://issuer-oid4vci.wallet.gov.tw/api/", against: list) else {
            Issue.record("gate 1 refused")
            return
        }
        #expect(matched.count == 2)
        #expect(IssuerAuthorization.confirm(
            credentialIssuer: "https://issuer-oid4vci.wallet.gov.tw/api/issuer/00000000/",
            matched: matched) == .failure(.organisationMismatch))
    }

    /// **We sign over our own bytes.** Once the host is agreed there is nothing
    /// to gain from carrying the candidate's spelling forward, and something to
    /// lose: the proof JWT's `aud` would be a string an attacker influenced.
    @Test func theBaseURLUsedAfterwardsComesFromTheListNotTheOffer() {
        #expect(IssuerAuthorization.canonicalIssuerBase(for: Self.sandbox)
                == "https://issuer-oid4vci.wallet.gov.tw")
        #expect(IssuerAuthorization.canonicalIssuerBase(for: Self.moda)
                == "https://moda.wallet.gov.tw")
    }

    // MARK: Reading the list

    @Test func aListPageIsParsed() throws {
        let json = Data("""
        {"msg":"執行成功","code":"0","data":{"count":2,"dids":[
          {"id":"did:key:zA","orgType":1,"orgGroupDetail":{"name":"政府部門"},
           "org":{"name":"行政院-數位發展部","name_en":"Ministry of Digital Affairs",
                  "taxId":"2-16-886-101-20003-20082","serviceBaseURL":"https://moda.wallet.gov.tw"},
           "onChainHistory":[{"net":"arbitrum"}]},
          {"id":"did:key:zB","orgType":1,"orgGroupDetail":{"name":"政府部門"},
           "org":{"name":"中國醫藥大學","name_en":"China Medical University",
                  "taxId":"2-16-886-111-100557","serviceBaseURL":"https://52005408.wallet.gov.tw",
                  "issuerMetadataBaseURL":null},
           "onChainHistory":[]}
        ]}}
        """.utf8)
        let issuers = try TWDIWIssuer.page(from: json)
        #expect(issuers.count == 2)
        #expect(issuers[0].displayName == "行政院-數位發展部")
        #expect(issuers[0].reportsOnChainAnchor)
        // The real entry with no anchor and no issuer metadata URL, kept as a
        // fixture because it is the shape a strict parser would drop.
        #expect(!issuers[1].reportsOnChainAnchor)
        #expect(issuers[1].issuerMetadataBaseURL == nil)
    }

    /// The single-object response shape is live too — `GET /api/did/<did>`
    /// returns the entry directly at `data` rather than in a `dids` array.
    @Test func theSingleEntryResponseShapeIsAlsoParsed() throws {
        let json = Data("""
        {"msg":"執行成功","code":"0","data":{"id":"did:key:zA",
          "org":{"name":"數位憑證皮夾沙盒","taxId":"00000000",
                 "issuerMetadataBaseURL":"https://issuer-oid4vci.wallet.gov.tw"},
          "onChainHistory":[{"net":"arbitrum_testnet"}]}}
        """.utf8)
        let issuers = try TWDIWIssuer.page(from: json)
        #expect(issuers.count == 1)
        #expect(issuers[0].taxID == "00000000")
    }

    /// An empty page is how enumeration knows to stop, so it must parse as empty
    /// rather than throw.
    @Test func anEmptyPageIsEmptyNotAnError() throws {
        let json = Data(#"{"msg":"執行成功","code":"0","data":{"count":20,"dids":[]}}"#.utf8)
        #expect(try TWDIWIssuer.page(from: json).isEmpty)
    }
}
