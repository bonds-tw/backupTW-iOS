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

    /// A signature dictionary is present — which is **not** the same as the
    /// document being signed. See `hasSignatureBytes`, which is the one that
    /// decides anything.
    let isSigned: Bool

    /// A `/Contents` hex string was found holding at least one non-zero digit,
    /// i.e. there is a CMS blob to hand a verifier.
    ///
    /// This is the distinction the first version of this type missed, and it
    /// missed it in the expensive direction. A document *prepared* for signing
    /// carries a real `/ByteRange` and a `/Contents` padded out with zeros,
    /// waiting for a signature that may never be written back — an interrupted
    /// signing run, or a template shipped ready-to-sign. Every marker this scan
    /// looks for is present; the signature is not. Reported as signed, that
    /// document sends the credential design down the `zkpdf` path to verify a
    /// few kilobytes of nothing.
    ///
    /// Checked against a signing run stopped after the placeholder was written:
    /// 2,206 bytes of `/Contents`, not one non-zero digit among them.
    let hasSignatureBytes: Bool

    /// The `/SubFilter` values found, e.g. `adbe.pkcs7.detached`,
    /// `ETSI.CAdES.detached`. Empty when unsigned. Reported because it decides
    /// which verifier a future implementation would need — and because
    /// `zkpdf`'s validator handles PKCS#7 RSA-SHA256 specifically.
    let subFilters: [String]

    /// How many signature dictionaries were seen. More than one is normal for a
    /// document signed and then countersigned.
    let signatureCount: Int

    /// True when a `/ByteRange` was found, i.e. something declared which span of
    /// the file a signature would cover.
    ///
    /// This used to be described as the thing that tells a real signature from a
    /// placeholder a form left behind. It is not: the placeholder is written
    /// with a real `/ByteRange` and gets its `/Contents` filled in afterwards,
    /// so the two are indistinguishable here. `hasSignatureBytes` is the one
    /// that separates them.
    let hasByteRange: Bool

    static let unsigned = PDFSignatureScan(isSigned: false, hasSignatureBytes: false,
                                           subFilters: [], signatureCount: 0,
                                           hasByteRange: false)

    /// Scans raw PDF bytes for signature dictionaries.
    ///
    /// Byte scanning rather than PDFKit because PDFKit exposes no signature API
    /// at all on iOS — there is no property to ask. The markers looked for are
    /// the ones the PDF specification requires a signature dictionary to carry.
    ///
    /// Two things this cannot do, both measured rather than assumed:
    ///
    /// - **It matches text as readily as structure.** `/ByteRange [` appearing
    ///   inside an uncompressed content stream, an embedded file or a document
    ///   that merely *discusses* signatures reads exactly like the real key.
    ///   `hasSignatureBytes` is what separates the two.
    /// - **It cannot see inside a compressed `/ObjStm`.** A signature dictionary
    ///   packed into one would be invisible here. No signer produces that,
    ///   because `/Contents` has to sit at a literal file offset for
    ///   `/ByteRange` to exclude it — a document repacked that way was measured
    ///   at `CONTIGUOUS_BLOCK_FROM_START` coverage, i.e. no longer valid. Worth
    ///   knowing, not worth defending against.
    ///
    /// Scanning works on the still-encrypted download because the standard
    /// security handler encrypts strings and streams, not name objects or
    /// dictionary structure — verified against RC4-128 and AES-256 copies.
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

        // A signature's `/Contents` is a hex string. A placeholder is that same
        // string filled with zeros, so length proves nothing and only a non-zero
        // digit does. `/Contents` on a page is an indirect reference rather than
        // a hex string, so requiring the `<` keeps page content out of this.
        let hasSignatureBytes = matches(of: #"/Contents\s*<([0-9A-Fa-f\s]*)>"#, in: text)
            .contains { $0.contains { $0 != "0" && !$0.isWhitespace } }

        return PDFSignatureScan(isSigned: isSigned,
                                hasSignatureBytes: hasSignatureBytes,
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
        // Said plainly, because this is the case that would otherwise be read as
        // "signed" and spend weeks of the wrong work.
        guard hasSignatureBytes else {
            return NSLocalizedString(
                "A signature field is present but empty — no signature was ever written into it.",
                comment: "PDF signature scan")
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
            "hasSignatureBytes": scan.hasSignatureBytes,
            "subFilters": scan.subFilters,
            "signatureCount": scan.signatureCount,
            "hasByteRange": scan.hasByteRange
        ] as [String: Any], forKey: defaultsKey)
    }

    /// The last scan, or nil if no MyData download has been parsed on this
    /// device. Nil is a real answer — "not measured yet" — and the diagnostics
    /// screen renders it as such rather than as "unsigned".
    ///
    /// A record written before `hasSignatureBytes` existed is also nil. It could
    /// be read back with the field defaulted, but both defaults lie: `false`
    /// turns a genuine signature into "empty field", `true` restores the very
    /// false positive this measurement was added to catch. The download takes a
    /// minute to repeat and the answer decides the architecture, so the stale
    /// reading is dropped and the screen asks for a fresh one.
    static func lastRecorded(in defaults: UserDefaults = .standard) -> PDFSignatureScan? {
        guard let stored = defaults.dictionary(forKey: defaultsKey),
              let isSigned = stored["isSigned"] as? Bool,
              let hasSignatureBytes = stored["hasSignatureBytes"] as? Bool else { return nil }
        return PDFSignatureScan(
            isSigned: isSigned,
            hasSignatureBytes: hasSignatureBytes,
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
