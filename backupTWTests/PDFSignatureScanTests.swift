//
//  PDFSignatureScanTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

@Suite("MyData PDF 是否帶文件級簽章")
struct PDFSignatureScanTests {

    private static func pdf(_ body: String) -> Data {
        Data("%PDF-1.7\n\(body)\n%%EOF".utf8)
    }

    @Test("沒有簽章字典就報沒有")
    func plainDocumentIsUnsigned() {
        let scan = PDFSignatureScan.scan(Self.pdf("""
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        """))
        #expect(!scan.isSigned)
        #expect(scan.signatureCount == 0)
        #expect(scan.subFilters.isEmpty)
    }

    /// The spacing variants matter more than they look. A writer emitting
    /// `/Type/Sig` with no space is entirely legal, and matching only the
    /// spaced form would report a signed document as unsigned — the one failure
    /// direction that would quietly confirm the assumption this type exists to
    /// test.
    @Test("空白排列的各種寫法都要抓到")
    func toleratesWhitespaceVariants() {
        for spelling in ["/Type/Sig", "/Type /Sig", "/Type  /Sig", "/Type\n/Sig"] {
            let scan = PDFSignatureScan.scan(Self.pdf("9 0 obj << \(spelling) >> endobj"))
            #expect(scan.isSigned, "沒抓到：\(spelling)")
        }
    }

    @Test("讀得出 SubFilter，因為它決定要用哪種驗章器")
    func reportsSubFilter() {
        let scan = PDFSignatureScan.scan(Self.pdf("""
        9 0 obj << /Type /Sig /SubFilter /adbe.pkcs7.detached
        /ByteRange [0 840 960 1200] /Contents <308006> >> endobj
        """))
        #expect(scan.isSigned)
        #expect(scan.subFilters == ["adbe.pkcs7.detached"])
        #expect(scan.hasByteRange)
        #expect(scan.summary.contains("adbe.pkcs7.detached"))
    }

    /// `/Type` is optional in the spec, so a `/ByteRange` alone is still a
    /// signature. Under-reporting here would produce a false "unsigned".
    @Test("只有 ByteRange、沒有 Type/Sig，仍算簽了")
    func byteRangeAloneCounts() {
        let scan = PDFSignatureScan.scan(Self.pdf("9 0 obj << /ByteRange [0 1 2 3] >> endobj"))
        #expect(scan.isSigned)
        #expect(scan.signatureCount == 1)
    }

    /// Real PDFs are byte soup. A scanner that gave up on the first invalid
    /// UTF-8 sequence would report every genuine document as unsigned.
    @Test("二進位串流不會讓掃描放棄")
    func survivesBinaryStreams() {
        var data = Data("%PDF-1.7\n5 0 obj << /Type /Sig /SubFilter /ETSI.CAdES.detached >> endobj\nstream\n".utf8)
        data.append(Data((0...255).map { UInt8($0) }))   // 保證含非法 UTF-8 序列
        data.append(Data("\nendstream\n%%EOF".utf8))
        let scan = PDFSignatureScan.scan(data)
        #expect(scan.isSigned)
        #expect(scan.subFilters == ["ETSI.CAdES.detached"])
    }

    /// `isSigned` says a signature is *present*, never that it is *valid*.
    @Test("摘要文字不會宣稱已驗證")
    func summaryNeverClaimsVerified() {
        let scan = PDFSignatureScan.scan(Self.pdf("9 0 obj << /Type /Sig >> endobj"))
        for forbidden in ["已驗證", "verified", "valid", "有效"] {
            #expect(!scan.summary.lowercased().contains(forbidden.lowercased()),
                    "摘要宣稱了驗證結果：\(scan.summary)")
        }
    }
}
