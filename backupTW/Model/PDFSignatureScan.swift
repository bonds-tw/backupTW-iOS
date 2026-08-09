//
//  PDFSignatureScan.swift
//  backupTW
//
//  Does the MyData PDF carry a document-level signature, or not?
//

import Foundation

/// What a scan of a PDF's signature dictionaries found.
///
/// # Why this exists
///
/// The whole credential architecture rests on one sentence that nobody has ever
/// checked. The roadmap says MyData delivers "欄位事實（無文件級簽章）" — field
/// facts with no document-level signature — and *because* of that, this app
/// re-signs those fields with the device key and calls the result a credential.
/// A self-issued credential is a self-attestation: it proves this phone said
/// these values, and nothing about whether they are true.
///
/// If that sentence is wrong — if 內政部 actually signs the PDF — then the data
/// already carries an authoritative trust root, `zkpdf` can prove statements
/// about it without disclosing it, and the self-signing detour is not just
/// unnecessary but actively weaker than what was already in the download.
///
/// That is too large a fork to leave resting on an assertion, so the app
/// measures it. The answer costs one pass over bytes we already hold in memory.
///
/// # What this does not do
///
/// It does **not** validate the signature: no chain building, no digest check,
/// no revocation. Finding a signature dictionary means the document claims to be
/// signed, which is exactly the question being asked here — "is there anything
/// to work with" — and nothing more. `isSigned` must never be rendered as 「已驗證」.
struct PDFSignatureScan: Equatable, Sendable {

    /// A signature dictionary is present.
    let isSigned: Bool

    /// The `/SubFilter` values found, e.g. `adbe.pkcs7.detached`,
    /// `ETSI.CAdES.detached`. Empty when unsigned. Reported because it decides
    /// which verifier a future implementation would need — and because
    /// `zkpdf`'s validator handles PKCS#7 RSA-SHA256 specifically.
    let subFilters: [String]

    /// How many signature dictionaries were seen. More than one is normal for a
    /// document signed and then countersigned.
    let signatureCount: Int

    /// True when a `/ByteRange` was found, i.e. the signature covers a span of
    /// the file rather than being an empty placeholder that a form left behind.
    let hasByteRange: Bool

    static let unsigned = PDFSignatureScan(isSigned: false, subFilters: [],
                                           signatureCount: 0, hasByteRange: false)

    /// Scans raw PDF bytes for signature dictionaries.
    ///
    /// Byte scanning rather than PDFKit because PDFKit exposes no signature API
    /// at all on iOS — there is no property to ask. The markers looked for are
    /// the ones the PDF specification requires a signature dictionary to carry,
    /// so a document that has one cannot hide from this, and a document that has
    /// none cannot accidentally match: `/ByteRange` and `/SubFilter` do not
    /// appear outside signature and encryption dictionaries.
    ///
    /// Deliberately tolerant of whitespace. A PDF writer may emit `/Type/Sig`,
    /// `/Type /Sig` or `/Type  /Sig`, and matching only the spaced form would
    /// report a signed document as unsigned — the failure direction that would
    /// quietly confirm the assumption this is here to test.
    static func scan(_ data: Data) -> PDFSignatureScan {
        // Latin-1 rather than UTF-8: PDF bodies are byte soup with binary
        // streams, and UTF-8 decoding fails outright on the first invalid
        // sequence — which would report every real PDF as unsigned.
        guard let text = String(data: data, encoding: .isoLatin1) else {
            return .unsigned
        }

        let signatureCount = countOccurrences(of: #"/Type\s*/Sig\b"#, in: text)
        let hasByteRange = countOccurrences(of: #"/ByteRange\s*\["#, in: text) > 0
        let subFilters = matches(of: #"/SubFilter\s*/([A-Za-z0-9._\-]+)"#, in: text)

        // A `/ByteRange` with no `/Type /Sig` still means a signature: some
        // writers omit the `/Type` key, which is optional in the spec. Treating
        // the strict form as the only evidence would under-report.
        let isSigned = signatureCount > 0 || hasByteRange

        return PDFSignatureScan(isSigned: isSigned,
                                subFilters: Array(Set(subFilters)).sorted(),
                                signatureCount: max(signatureCount, hasByteRange ? 1 : 0),
                                hasByteRange: hasByteRange)
    }

    /// A one-line answer fit for the diagnostics screen and for pasting into a
    /// message to PSE.
    var summary: String {
        guard isSigned else {
            return NSLocalizedString(
                "No document-level signature found.", comment: "PDF signature scan")
        }
        let filters = subFilters.isEmpty ? "?" : subFilters.joined(separator: ", ")
        return String(format: NSLocalizedString(
            "Signed — %d signature(s), SubFilter %@", comment: "PDF signature scan"),
            signatureCount, filters)
    }

    // MARK: - Recording the answer

    /// `UserDefaults`, because what is stored is a fact about the *format* of a
    /// government download — four values describing an envelope — and not one
    /// byte of anybody's household record. Putting it in `CredentialStore`
    /// alongside protected credentials would imply it needs protecting, and
    /// implying that about a boolean makes the classification meaningless where
    /// it matters.
    private static let defaultsKey = "tw.bonds.backupTW.myDataPDFSignatureScan"

    static func record(_ scan: PDFSignatureScan, into defaults: UserDefaults = .standard) {
        defaults.set([
            "isSigned": scan.isSigned,
            "subFilters": scan.subFilters,
            "signatureCount": scan.signatureCount,
            "hasByteRange": scan.hasByteRange
        ] as [String: Any], forKey: defaultsKey)
    }

    /// The last scan, or nil if no MyData download has been parsed on this
    /// device. Nil is a real answer — "not measured yet" — and the diagnostics
    /// screen renders it as such rather than as "unsigned".
    static func lastRecorded(in defaults: UserDefaults = .standard) -> PDFSignatureScan? {
        guard let stored = defaults.dictionary(forKey: defaultsKey),
              let isSigned = stored["isSigned"] as? Bool else { return nil }
        return PDFSignatureScan(
            isSigned: isSigned,
            subFilters: stored["subFilters"] as? [String] ?? [],
            signatureCount: stored["signatureCount"] as? Int ?? 0,
            hasByteRange: stored["hasByteRange"] as? Bool ?? false)
    }

    // MARK: - Regex helpers

    private static func countOccurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            }
    }
}
