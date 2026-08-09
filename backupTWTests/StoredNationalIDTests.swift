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

    /// `validFrom` is a string in the credential. A build that cannot parse it
    /// must show the raw value, never quietly substitute a plausible date.
    @Test("看不懂的時間格式顯示原字串，不會擅自代換")
    func unparseableDateFallsBackToRaw() {
        let stored = StoredNationalID(issuerDID: "did:key:z…",
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
