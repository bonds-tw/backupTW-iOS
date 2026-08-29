//
//  MyDataVaultTests.swift
//  backupTWTests
//
//  Group C (field label directory) + Group D foundation (document registry and
//  vault classification): the pure logic behind 設定 › 信任 › 欄位對照表 and the
//  資料保險箱 listing self-issued MyData documents.
//

import Foundation
import Testing
@testable import backupTW

private final class MemStore: CredentialStoring, @unchecked Sendable {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { items.keys.sorted() }
    func delete(id: String) throws { items.removeValue(forKey: id) }
    func deleteAll() throws { items.removeAll() }
}

struct FieldLabelDirectoryTests {

    @Test func mapsCommonMachineKeysToTheAppsWords() {
        // Other issuers' keys resolve to the app's own words (case-insensitively).
        #expect(StoredNationalID.label(for: "id_number") == NSLocalizedString("ID number", comment: ""))
        #expect(StoredNationalID.label(for: "ADDRESS") == NSLocalizedString("Address", comment: ""))
        #expect(StoredNationalID.label(for: "msisdn") == NSLocalizedString("Mobile number", comment: ""))
        #expect(StoredNationalID.label(for: "license_number") == NSLocalizedString("Licence number", comment: ""))
    }

    @Test func nationalIDsOwnExactKeysStillWin() {
        #expect(StoredNationalID.label(for: "unifiedNo") == NSLocalizedString("ID number", comment: ""))
        #expect(StoredNationalID.label(for: "addressOfHousehold") == NSLocalizedString("Household address", comment: ""))
    }

    @Test func unknownKeyIsReturnedUnchanged() {
        // The security contract: a key the app does not know is handed back as-is,
        // so `ClaimLabel` frames it as 「declared by their document」, not the app's word.
        #expect(StoredNationalID.label(for: "totally_made_up_field") == "totally_made_up_field")
    }

    @Test func aFieldMerelyContainingAKnownKeyIsNotMislabelled() {
        // Exact match, not substring — 「notid_number」 is not an ID number.
        #expect(StoredNationalID.label(for: "notid_number") == "notid_number")
    }
}

struct MyDataDocumentRegistryTests {

    @Test func classifiesVaultDocumentsVsTheNationalID() {
        #expect(MyDataDocumentRegistry.isVaultDocument(id: "mydata-income"))
        #expect(!MyDataDocumentRegistry.isVaultDocument(id: StoredNationalID.credentialID))
        #expect(!MyDataDocumentRegistry.isVaultDocument(id: "some-twdiw-card"))
    }

    @Test func looksUpByIdAndVcType() {
        #expect(MyDataDocumentRegistry.lookup(id: "mydata-income")?.vcType == "IncomeCredential")
        #expect(MyDataDocumentRegistry.lookup(vcType: "NationalIDCredential")?.id == StoredNationalID.credentialID)
        #expect(MyDataDocumentRegistry.nationalID.myDataItemPath != nil)   // the one wired document
        #expect(MyDataDocumentRegistry.vaultDocuments.allSatisfy { $0.myDataItemPath == nil }) // not yet wired
    }
}

struct VaultClassificationTests {

    @Test func aStoredVaultDocumentGetsItsDocumentTypeRow() throws {
        let store = MemStore()
        try store.save(jws: "{\"vct\":\"IncomeCredential\"}", id: "mydata-income")
        let rows = CardInventory.rows(from: store)
        let row = try #require(rows.first { $0.id == "mydata-income" })
        #expect(row.source == .selfIssued)
        #expect(row.title == MyDataDocumentRegistry.lookup(id: "mydata-income")?.title)
        #expect(row.state == .usable)
    }
}
