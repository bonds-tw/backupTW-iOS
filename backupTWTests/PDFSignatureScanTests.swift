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

    // MARK: - 簽章欄位存在 ≠ 簽了

    /// The expensive false positive, and the reason `hasSignatureBytes` exists.
    ///
    /// Signing writes the placeholder first — a real `/ByteRange`, a `/Contents`
    /// padded with zeros — and fills in the CMS afterwards. Interrupt it, or ship
    /// a template that was only ever prepared for signing, and every marker this
    /// scan looks for is present with no signature behind it. Measured on a real
    /// interrupted signing run: 2,206 bytes of `/Contents`, all zeros.
    @Test("補零的 /Contents 是佔位符，不是簽章")
    func zeroFilledContentsIsNotASignature() {
        let scan = PDFSignatureScan.scan(Self.pdf("""
        9 0 obj << /Type /Sig /SubFilter /adbe.pkcs7.detached
        /ByteRange [0 840 3000 1200] /Contents <\(String(repeating: "0", count: 512))> >> endobj
        """))
        #expect(scan.isSigned, "簽章字典確實在")
        #expect(!scan.hasSignatureBytes, "但裡面沒有 CMS，不能當成簽了")
        #expect(!scan.summary.contains("Signed"))
    }

    @Test("有非零內容才算真的有簽章位元組")
    func nonZeroContentsCounts() {
        let scan = PDFSignatureScan.scan(Self.pdf("""
        9 0 obj << /Type /Sig /ByteRange [0 840 3000 1200]
        /Contents <308205BB06092A864886F70D010702> >> endobj
        """))
        #expect(scan.hasSignatureBytes)
    }

    /// `/ByteRange [` is a byte sequence, not a structure, and it reads the same
    /// wherever it appears — an uncompressed content stream, an attachment, a
    /// document that merely discusses signatures. Scanning alone cannot tell
    /// those from the real key; the `/Contents` check is what does.
    @Test("內文提到 ByteRange 不會被當成簽章")
    func textMentioningByteRangeIsNotASignature() {
        let scan = PDFSignatureScan.scan(Self.pdf("""
        4 0 obj << /Length 46 >>
        stream
        BT (簽章長這樣：/ByteRange [0 1 2 3] /Type /Sig) Tj ET
        endstream
        endobj
        """))
        #expect(!scan.hasSignatureBytes, "沒有 /Contents，就沒有東西可以驗")
    }

    /// A signature field with no `/V` — what a blank form carries.
    @Test("空白的簽章欄位不算簽了")
    func emptySignatureFieldIsUnsigned() {
        let scan = PDFSignatureScan.scan(Self.pdf(
            "7 0 obj << /FT /Sig /T (Signature1) /Ff 0 >> endobj"))
        #expect(!scan.isSigned)
        #expect(!scan.hasSignatureBytes)
    }

    /// Reading back a record written before this check existed must not
    /// resurrect the false positive it was added to catch.
    @Test("舊格式的紀錄要當成沒量過，不能猜")
    func recordWithoutSignatureBytesIsDiscarded() {
        let defaults = UserDefaults(suiteName: "PDFSignatureScanTests.legacy")!
        defaults.removePersistentDomain(forName: "PDFSignatureScanTests.legacy")
        defaults.set(["isSigned": true, "subFilters": ["adbe.pkcs7.detached"],
                      "signatureCount": 1, "hasByteRange": true] as [String: Any],
                     forKey: "tw.bonds.backupTW.myDataPDFSignatureScan")
        #expect(PDFSignatureScan.lastRecorded(in: defaults) == nil)
    }

    @Test("新格式的紀錄可以完整讀回來")
    func recordRoundTrips() {
        let defaults = UserDefaults(suiteName: "PDFSignatureScanTests.roundTrip")!
        defaults.removePersistentDomain(forName: "PDFSignatureScanTests.roundTrip")
        let scan = PDFSignatureScan.scan(Self.pdf("""
        9 0 obj << /Type /Sig /SubFilter /ETSI.CAdES.detached
        /ByteRange [0 8 9 10] /Contents <3082AB> >> endobj
        """))
        PDFSignatureScan.record(scan, into: defaults)
        #expect(PDFSignatureScan.lastRecorded(in: defaults) == scan)
    }
}
