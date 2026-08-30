//
//  MyDataDocumentType.swift
//  backupTW
//
//  The registry of documents this app can hold via MyData. Today the national ID
//  (entry #0) is the only one wired end-to-end; the vault entries are the shape
//  the 資料保險箱 will fill as each one's MyData item path and parser are added
//  (see the Group D plan — the path per document must be discovered on a real
//  MyData account and tested on-device). This file is the single place that knows
//  「which documents exist」, so the vault UI, classification, and (later) the
//  fetch/issue pipeline all agree.
//

import Foundation

/// One kind of document the vault can hold. `myDataItemPath == nil` means the
/// document is known to the app but its MyData fetch is not wired yet.
struct MyDataDocumentType: Equatable {
    /// Stable storage id / slug. The national ID keeps its historical id.
    let id: String
    /// The credential's `type[1]`, so a stored blob can be classified back to a
    /// document kind after decoding.
    let vcType: String
    /// Display title (財力證明, 勞保投保資料, …).
    let title: String
    /// SF Symbol for the card face / list row.
    let systemImage: String
    /// The MyData item path the webview loads to fetch this document, e.g.
    /// 「personal/detail/API.idPhotoRev」 for the national ID. `nil` until
    /// discovered on a real MyData account.
    let myDataItemPath: String?
}

enum MyDataDocumentRegistry {

    /// Entry #0 — the self-issued national ID. Its id is the historical constant
    /// so nothing about the existing flow changes.
    static let nationalID = MyDataDocumentType(
        id: StoredNationalID.credentialID,
        vcType: "NationalIDCredential",
        title: NSLocalizedString("National ID", comment: "document type"),
        systemImage: "person.text.rectangle.fill",
        myDataItemPath: "personal/detail/API.idPhotoRev")

    /// The documents the 資料保險箱 is being built to hold. Paths were discovered on
    /// mydata.nat.gov.tw itself (the item detail URL is `personal/detail/API.<code>`,
    /// the same shape as the national ID's `API.idPhotoRev`); a `nil` path means the
    /// document has no MyData counterpart to fetch from.
    static let vaultDocuments: [MyDataDocumentType] = [
        // 個人所得資料 · 財政部財政資訊中心
        MyDataDocumentType(id: "mydata-income", vcType: "IncomeCredential",
                           title: NSLocalizedString("Income / financial proof", comment: "document type"),
                           systemImage: "banknote.fill", myDataItemPath: "personal/detail/API.syWqjr4flJ"),
        // 被保險人投保資料（勞保／就保／災保）· 勞動部勞工保險局
        MyDataDocumentType(id: "mydata-labor-insurance", vcType: "LaborInsuranceCredential",
                           title: NSLocalizedString("Labor insurance record", comment: "document type"),
                           systemImage: "shield.lefthalf.filled", myDataItemPath: "personal/detail/API.UZQkKbsOpz"),
        // 學歷／學位證明 dropped on purpose: it is not a MyData item (verified against
        // MyData's own /rest/inquiry/docs — 0 of 141 match 畢業/學位/學歷); 教育部's
        // degree verification runs through depart.moe.edu.tw, a separate integration.
        // 個人投退保資料（健保）· 衛生福利部中央健康保險署
        MyDataDocumentType(id: "mydata-health-insurance", vcType: "HealthInsuranceCredential",
                           title: NSLocalizedString("Health insurance record", comment: "document type"),
                           systemImage: "cross.case.fill", myDataItemPath: "personal/detail/API.zH584wn59r"),
    ]

    static let all: [MyDataDocumentType] = [nationalID] + vaultDocuments

    static func lookup(id: String) -> MyDataDocumentType? { all.first { $0.id == id } }
    static func lookup(vcType: String) -> MyDataDocumentType? { all.first { $0.vcType == vcType } }

    /// A stored self-issued document that belongs in the vault (i.e. any registered
    /// document that is not the national ID). Keyed by id so it needs no decode.
    static func isVaultDocument(id: String) -> Bool { vaultDocuments.contains { $0.id == id } }
}
