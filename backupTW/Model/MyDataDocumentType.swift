//
//  MyDataDocumentType.swift
//  backupTW
//
//  The registry of documents this app can hold via MyData. The national ID
//  (entry #0) is parsed and turned into its own signed credential; the remaining
//  entries retain the original file in the on-device vault. Their real MyData
//  paths are wired, while real-account/on-device format validation remains the
//  release gate. This is the single place that knows which documents exist, so
//  the picker, archive inventory and detail screen agree.
//

import Foundation

/// One kind of document the vault can hold. `myDataItemPath == nil` means the
/// document is known to the app but its MyData fetch is not wired yet.
struct MyDataDocumentType: Equatable {
    enum EntryMode: Equatable {
        /// Open one known MyData item directly.
        case directItem
        /// Resume the official 「個人專區／個人文件」 flow. The downloaded file
        /// may be any item MyData offers, rather than one in our small shortcut
        /// catalogue.
        case personalDocuments
    }

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
    /// A slow document does not belong to the lifetime of one web view. This is
    /// shown before the request starts and used to offer the personal-documents
    /// continuation rather than an indefinite spinner.
    let estimatedMinutes: Int?
    let entryMode: EntryMode

    /// Direct item pages finish after one requested document. The Personal
    /// documents inbox is different: once the holder has signed in, keep that
    /// same official web session open so several already-completed files can be
    /// downloaded without signing in to the inbox again.
    var keepsWebSessionOpenAfterImport: Bool { entryMode == .personalDocuments }

    init(id: String, vcType: String, title: String, systemImage: String,
         myDataItemPath: String?, estimatedMinutes: Int? = nil,
         entryMode: EntryMode = .directItem) {
        self.id = id
        self.vcType = vcType
        self.title = title
        self.systemImage = systemImage
        self.myDataItemPath = myDataItemPath
        self.estimatedMinutes = estimatedMinutes
        self.entryMode = entryMode
    }
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

    /// The durable continuation for slow and unlisted documents. MyData's own
    /// FAQ says completed files live in 個人專區／個人文件; starting at sign-in is
    /// more stable than guessing an authenticated internal route.
    static let personalDocuments = MyDataDocumentType(
        id: "mydata-personal-documents",
        vcType: "",
        title: NSLocalizedString("MyData personal documents", comment: "MyData continuation"),
        systemImage: "folder.fill",
        myDataItemPath: "signin",
        entryMode: .personalDocuments)

    /// Re-download an arbitrary document into the same vault slot. Its title is
    /// metadata chosen by this app, never a server-provided path component.
    static func personalDocuments(replacing id: String, title: String) -> MyDataDocumentType {
        MyDataDocumentType(id: id, vcType: "", title: title,
                           systemImage: "folder.fill", myDataItemPath: "signin",
                           entryMode: .personalDocuments)
    }

    /// The documents the 資料保險箱 is being built to hold. Paths were discovered on
    /// mydata.nat.gov.tw itself (the item detail URL is `personal/detail/API.<code>`,
    /// the same shape as the national ID's `API.idPhotoRev`); a `nil` path means the
    /// document has no MyData counterpart to fetch from.
    static let vaultDocuments: [MyDataDocumentType] = [
        // 個人所得資料 · 財政部財政資訊中心
        MyDataDocumentType(id: "mydata-income", vcType: "IncomeCredential",
                           title: NSLocalizedString("Income / financial proof", comment: "document type"),
                           systemImage: "banknote.fill", myDataItemPath: "personal/detail/API.syWqjr4flJ",
                           estimatedMinutes: 120),
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
        // 保費繳納紀錄（健保）· 衛生福利部中央健康保險署. Health belongs in the vault
        // as *data*, never as a 健保卡 card — the physical/virtual card is not a route
        // a third-party wallet can take (see the feasibility assessment).
        MyDataDocumentType(id: "mydata-nhi-premium", vcType: "HealthPremiumCredential",
                           title: NSLocalizedString("Health insurance premium payments", comment: "document type"),
                           systemImage: "dollarsign.circle.fill", myDataItemPath: "personal/detail/API.1qIr0nM0BT"),
        // 綜合所得稅納稅證明書 · 財政部財政資訊中心 — the 納稅證明 people use for visas/loans.
        MyDataDocumentType(id: "mydata-tax-cert", vcType: "TaxPaymentCredential",
                           title: NSLocalizedString("Tax payment certificate", comment: "document type"),
                           systemImage: "checkmark.seal.fill", myDataItemPath: "personal/detail/API.TeV2Md7SIx"),
        // 勞工提繳異動資料 · 勞動部勞工保險局 — new-scheme labor-pension *contributions*
        // (month wage, employer/self rates, effective date). Note: MyData carries the
        // contribution history, NOT the account balance (that needs 勞保局 e-services).
        MyDataDocumentType(id: "mydata-labor-pension", vcType: "LaborPensionCredential",
                           title: NSLocalizedString("Labor pension record", comment: "document type"),
                           systemImage: "chart.line.uptrend.xyaxis", myDataItemPath: "personal/detail/API.yqkllwwTYl"),
        // 地籍及實價資料 · 內政部地政司 — owner, parcel/building no., share, area, present
        // value, encumbrances. MyData has no item literally named 登記謄本; this is it.
        MyDataDocumentType(id: "mydata-land", vcType: "LandRegistryCredential",
                           title: NSLocalizedString("Property record", comment: "document type"),
                           systemImage: "house.fill", myDataItemPath: "personal/detail/API.KvvyRZSc5K"),
        // 現戶全戶戶籍資料 · 內政部戶政司 — the full household record (個人記事＋全戶記事),
        // distinct from the national ID's idPhotoRev.
        MyDataDocumentType(id: "mydata-household", vcType: "HouseholdCredential",
                           title: NSLocalizedString("Household registration", comment: "document type"),
                           systemImage: "person.2.fill", myDataItemPath: "personal/detail/API.UDauDOLyZg"),
    ]

    static let all: [MyDataDocumentType] = [nationalID] + vaultDocuments

    static func lookup(id: String) -> MyDataDocumentType? { all.first { $0.id == id } }
    static func lookup(vcType: String) -> MyDataDocumentType? { all.first { $0.vcType == vcType } }

    /// Resolves MyData's official filename or first-page heading to a known local
    /// type. We never keep or display the whole server filename because it may
    /// include the holder's name. Matching is intentionally bounded to these
    /// government document phrases, and the returned title is our localisation.
    static func knownDocument(in text: String) -> MyDataDocumentType? {
        let patterns: [(String, [String])] = [
            ("mydata-income", ["個人所得資料表", "個人所得資料", "所得資料表", "syWqjr4flJ"]),
            ("mydata-labor-insurance", ["被保險人投保資料", "勞保投保", "就保投保", "災保投保", "UZQkKbsOpz"]),
            ("mydata-health-insurance", ["個人投退保資料", "健保投退保", "zH584wn59r"]),
            ("mydata-nhi-premium", ["保費繳納紀錄", "健保保費", "1qIr0nM0BT"]),
            ("mydata-tax-cert", ["綜合所得稅納稅證明", "納稅證明", "TeV2Md7SIx"]),
            ("mydata-labor-pension", ["勞工提繳異動資料", "勞退提繳", "提繳異動", "yqkllwwTYl"]),
            ("mydata-land", ["地籍及實價資料", "地籍資料", "實價資料", "KvvyRZSc5K"]),
            ("mydata-household", ["現戶全戶戶籍資料", "全戶戶籍", "戶籍資料", "UDauDOLyZg"]),
        ]
        return patterns.lazy.compactMap { id, keywords -> MyDataDocumentType? in
            guard keywords.contains(where: { text.localizedCaseInsensitiveContains($0) }) else {
                return nil
            }
            return lookup(id: id)
        }.first ?? vaultDocuments.first(where: {
            text.localizedCaseInsensitiveContains($0.title)
        })
    }

    /// A stored self-issued document that belongs in the vault (i.e. any registered
    /// document that is not the national ID). Keyed by id so it needs no decode.
    static func isVaultDocument(id: String) -> Bool { vaultDocuments.contains { $0.id == id } }
}
