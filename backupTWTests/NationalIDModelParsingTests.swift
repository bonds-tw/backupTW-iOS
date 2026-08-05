//
//  NationalIDModelParsingTests.swift
//  backupTWTests
//

import Testing
@testable import backupTW

/// The MyData PDF is the only government integration that currently works end
/// to end, and its layout has already changed under us once. These cover the
/// shapes the old index-based parser trapped on.
struct NationalIDModelParsingTests {

    /// Single-line address, both separators, two fields sharing a line.
    private static let singleLineAddress = """
    國民身分證資料
    統號：A123456789 姓名:王小明
    出生日期:0700101
    性別:男
    父:王大明
    母:陳小美
    戶籍地址:臺北市中正區重慶南路一段122號
    備註
    """

    /// The layout that prompted commit 60d9a05.
    private static let multiLineAddress = """
    國民身分證資料
    統號：A123456789 姓名:王小明
    出生日期:0700101
    性別:男
    父:王大明
    母:陳小美
    戶籍地址:臺北市中正區
    重慶南路一段
    122號
    備註
    """

    @Test func parsesSingleLineAddress() throws {
        let model = try #require(NationalIDModel.parse(fromPDFText: Self.singleLineAddress))
        #expect(model.unifiedNo == "A123456789")
        #expect(model.name == "王小明")
        #expect(model.birthdate == "0700101")
        #expect(model.addressOfHousehold == "臺北市中正區重慶南路一段122號")
        #expect(model.nationality == "中華民國（臺灣）")
    }

    @Test func parsesMultiLineAddress() throws {
        let model = try #require(NationalIDModel.parse(fromPDFText: Self.multiLineAddress))
        #expect(model.unifiedNo == "A123456789")
        #expect(model.name == "王小明")
        #expect(model.addressOfHousehold == "臺北市中正區重慶南路一段122號")
    }

    // MARK: - Inputs that used to crash

    /// `parts[1]`, `parts[6]` and the `7...lastIndex` range all trapped when the
    /// document was shorter than the layout assumed.
    @Test(arguments: [
        "",
        "國民身分證資料",
        "國民身分證資料\n統號：A123456789 姓名:王小明",
        "國民身分證資料\n統號：A123456789 姓名:王小明\n出生日期:0700101",
    ])
    func shortDocumentsDoNotTrap(text: String) {
        // The contract is only "does not crash" — some of these legitimately
        // have nothing to parse.
        _ = NationalIDModel.parse(fromPDFText: text)
    }

    @Test func labelWithoutSeparatorDoesNotTrap() {
        let model = NationalIDModel.parse(fromPDFText: """
        國民身分證資料
        統號 姓名
        出生日期
        戶籍地址
        備註
        """)
        #expect(model == nil)
    }

    @Test func unrelatedDocumentIsRejected() {
        let model = NationalIDModel.parse(fromPDFText: """
        勞工保險投保資料
        投保單位:某某公司
        投保日期:1100101
        """)
        #expect(model == nil)
    }

    // MARK: - Tolerance

    @Test func toleratesReorderedFields() throws {
        let model = try #require(NationalIDModel.parse(fromPDFText: """
        國民身分證資料
        出生日期:0700101
        姓名:王小明
        統號：A123456789
        戶籍地址:高雄市鹽埕區
        備註
        """))
        #expect(model.unifiedNo == "A123456789")
        #expect(model.name == "王小明")
        #expect(model.birthdate == "0700101")
        #expect(model.addressOfHousehold == "高雄市鹽埕區")
    }

    @Test func missingAddressStillParsesOtherFields() throws {
        let model = try #require(NationalIDModel.parse(fromPDFText: """
        國民身分證資料
        統號：A123456789 姓名:王小明
        出生日期:0700101
        備註
        """))
        #expect(model.unifiedNo == "A123456789")
        #expect(model.addressOfHousehold == nil)
    }

    @Test func toleratesFullWidthColonOnEveryField() throws {
        let model = try #require(NationalIDModel.parse(fromPDFText: """
        國民身分證資料
        統號：A123456789 姓名：王小明
        出生日期：0700101
        戶籍地址：臺中市西區
        備註
        """))
        #expect(model.name == "王小明")
        #expect(model.birthdate == "0700101")
        #expect(model.addressOfHousehold == "臺中市西區")
    }
}
