//
//  StoredNationalIDTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

@Suite("讀回自己存的證件")
struct StoredNationalIDTests {

    private final class FakeStore: CredentialStoring, @unchecked Sendable {
        var items: [String: String] = [:]
        func save(jws: String, id: String) throws { items[id] = jws }
        func load(id: String) throws -> String? { items[id] }
        func allIDs() throws -> [String] { Array(items.keys) }
        func deleteAll() throws { items.removeAll() }
    }

    private static func storeHoldingCredential(
        subject: [String: String] = ["nationality": "中華民國",
                                     "unifiedNo": "A123456789",
                                     "name": "王小明",
                                     "birthdate": "1990-01-01",
                                     "addressOfHousehold": "臺北市中正區某路 1 號"]
    ) throws -> FakeStore {
        let key = try DeviceKey.loadOrCreate()
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let model = NationalIDModel(nationality: subject["nationality"],
                                    unifiedNo: subject["unifiedNo"],
                                    name: subject["name"],
                                    birthdate: subject["birthdate"],
                                    addressOfHousehold: subject["addressOfHousehold"])
        let credential = VerifiableCredential.nationalID(model, issuerDID: did,
                                                                   validFrom: Date())
        let store = FakeStore()
        try store.save(jws: credential.jwsCompactSerialization(signedBy: key, issuerDID: did),
                       id: StoredNationalID.credentialID)
        return store
    }

    /// The same fields, but stored the way the app writes them now: a
    /// `MOICASignedCredential` envelope rather than a compact JWS. The signature
    /// is a throwaway one — `StoredNationalID` deliberately does not verify, so
    /// what matters here is only that the envelope is the shape it parses.
    private static func storeHoldingCardSignedCredential() throws -> FakeStore {
        let key = try DeviceKey.loadOrCreate()
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let model = NationalIDModel(nationality: "中華民國",
                                    unifiedNo: "A123456789",
                                    name: "王小明",
                                    birthdate: "1990-01-01",
                                    addressOfHousehold: "臺北市中正區某路 1 號")
        let credential = VerifiableCredential.nationalID(model, issuerDID: did, validFrom: Date())
        let (digest, bytes) = try MOICASignedCredential.toBeSigned(for: credential)
        let envelope = MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: try cardSignature(over: Data(digest.utf8)).base64EncodedString()))

        let store = FakeStore()
        try store.save(jws: try envelope.serialized(), id: StoredNationalID.credentialID)
        return store
    }

    /// The defect this whole type exists for: the credential was saved and then
    /// no screen a user could reach ever read it back, so finishing the MyData
    /// flow left the app looking exactly as it had before.
    @Test(.enabled(if: DeviceKeyAvailability.isAvailable))
    func readsBackWhatTheMyDataFlowStored() throws {
        let stored = try #require(StoredNationalID.load(from: try Self.storeHoldingCredential()))
        #expect(stored.claims.count == 5)
        #expect(stored.claims.first?.key == "nationality", "顯示順序沒有照身分證的讀法排")
        #expect(stored.claims.map(\.key).contains("unifiedNo"))
        #expect(!stored.issuerDID.isEmpty)
        // The subject identifier is not a personal field. Listing it between
        // 姓名 and 戶籍地址 would present the one value that makes two
        // presentations linkable as though it were another detail about the
        // person — backwards from what identifierIsLinkable warns about.
        #expect(!stored.claims.map(\.key).contains("id"),
                "把 did 當成欄位顯示了：\(stored.claims.map(\.key))")
        #expect(!stored.claims.contains { $0.value.hasPrefix("did:key:") })
    }

    @Test("沒有存過就回 nil，而不是空殼")
    func emptyStoreYieldsNil() {
        #expect(StoredNationalID.load(from: FakeStore()) == nil)
    }

    /// A credential from a future build carrying a field this one has never
    /// heard of must still show that field. Dropping it would mean the holder
    /// seeing fewer fields than they hold, with no sign anything was omitted.
    @Test(.enabled(if: DeviceKeyAvailability.isAvailable))
    func showsFieldsThisBuildDoesNotKnowHowToOrder() throws {
        let store = try Self.storeHoldingCredential()
        // 手動塞一個這個 build 不認得的欄位進 payload
        let jws = try #require(try store.load(id: StoredNationalID.credentialID))
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var padded = parts[1].replacingOccurrences(of: "-", with: "+")
                             .replacingOccurrences(of: "_", with: "/")
        if padded.count % 4 > 0 { padded += String(repeating: "=", count: 4 - padded.count % 4) }
        let payloadData = try #require(Data(base64Encoded: padded))
        let parsed = try JSONSerialization.jsonObject(with: payloadData)
        var object = try #require(parsed as? [String: Any])
        var subject = try #require(object["credentialSubject"] as? [String: String])
        subject["somethingNew"] = "未來的欄位"
        object["credentialSubject"] = subject
        let repacked = try JSONSerialization.data(withJSONObject: object)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try store.save(jws: "\(parts[0]).\(repacked).\(parts[2])", id: StoredNationalID.credentialID)

        let stored = try #require(StoredNationalID.load(from: store))
        #expect(stored.claims.map(\.key).contains("somethingNew"),
                "不認得的欄位被丟掉了：\(stored.claims.map(\.key))")
    }

    /// Which envelope the file is has to survive being read back, because it is
    /// the only thing that decides what the holder's own screen tells them their
    /// document is worth. Both forms decode to indistinguishable credentials —
    /// the device DID is the subject identifier in each — so losing the flag
    /// here is not recoverable further up.
    @Test(.enabled(if: DeviceKeyAvailability.isAvailable))
    func aDeviceSignedCredentialIsReportedAsDeviceSigned() throws {
        let stored = try #require(StoredNationalID.load(from: try Self.storeHoldingCredential()))
        #expect(stored.isCardSigned == false)
    }

    @Test(.enabled(if: DeviceKeyAvailability.isAvailable))
    func aCardSignedCredentialIsReportedAsCardSigned() throws {
        let stored = try #require(StoredNationalID.load(from: try Self.storeHoldingCardSignedCredential()))

        #expect(stored.isCardSigned)
        // And the fields still read back, so the flag is not being bought by
        // silently failing to decode the newer envelope.
        #expect(stored.claims.count == 5)
    }

    /// `validFrom` is a string in the credential. A build that cannot parse it
    /// must show the raw value, never quietly substitute a plausible date.
    @Test("看不懂的時間格式顯示原字串，不會擅自代換")
    func unparseableDateFallsBackToRaw() {
        let stored = StoredNationalID(issuerDID: "did:key:z…",
                                      isCardSigned: false,
                                      validFromRaw: "民國 115 年 8 月 9 日",
                                      validFrom: nil,
                                      claims: [])
        #expect(stored.createdDescription() == "民國 115 年 8 月 9 日")
    }
}

enum DeviceKeyAvailability {
    /// The Keychain needs entitlements; a build signed with them has them and
    /// one without them fails with -34018. Same gate the eraser tests use.
    static var isAvailable: Bool { (try? DeviceKey.loadOrCreate()) != nil }
}

// MARK: - What the holder reads for a predicate claim

/// The age predicate is stored as the string the card signed — "true" — and
/// that token leaked straight onto the holder's screens (photographed on
/// device, 2026-08-11). A person reads a word.
struct HolderFacingValueTests {

    /// Locale-immune assertions: mapped means "not the raw token", never a
    /// comparison against one language's word — this repo has twice shipped
    /// wording tests that were only green while a string was untranslated.
    @Test func thePredicateTokenIsMappedToAWord() {
        let yes = StoredNationalID.displayValue(for: AgePredicate.claimName, value: "true")
        let no = StoredNationalID.displayValue(for: AgePredicate.claimName, value: "false")

        #expect(yes != "true")
        #expect(no != "false")
        #expect(!yes.isEmpty && !no.isEmpty)
        #expect(yes != no)
    }

    /// Anything the mapping does not recognise passes through untouched — a
    /// forged or future value must surface as itself, not as this app's word.
    @Test func anUnknownPredicateValuePassesThroughVerbatim() {
        #expect(StoredNationalID.displayValue(for: AgePredicate.claimName, value: "maybe") == "maybe")
    }

    /// Every other claim is a person's own record and is never rewritten.
    @Test(arguments: [("name", "王小明"), ("unifiedNo", "A123456789"),
                      ("birthdate", "民國 083年03月06日")])
    func ordinaryClaimsAreNeverRewritten(_ pair: (String, String)) {
        #expect(StoredNationalID.displayValue(for: pair.0, value: pair.1) == pair.1)
    }
}
