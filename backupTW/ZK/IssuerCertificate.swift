//
//  IssuerCertificate.swift
//  backupTW
//

import CryptoKit
import Foundation
import Security

// MARK: - Provenance
//
// Two certificates ship in the app bundle next to this file. They are the trust
// anchor for every zero-knowledge proof this app produces, so their origin is
// recorded here in enough detail that the next person can re-derive it from
// scratch without trusting this comment.
//
// ## backupTW/ZK/MOICA-G3.cer — 內政部憑證管理中心 (MOICA), third generation
//
//   source     https://moica.nat.gov.tw/repository/Certs/MOICA-G3.cer
//   format     raw DER, 1643 bytes (no PEM armour, no trailing bytes)
//   sha256     ed793fd0d50a2a398049d598982cf01e75f873b532066caec238f800a06ca9da
//   subject    C=TW, O=行政院, OU=內政部憑證管理中心
//   issuer     C=TW, O=行政院, CN=Government Root Certification Authority - G3
//   serial     5A202D14B39787D0886C37184AC9B76A
//   key        RSA 4096, e=65537
//   validity   2024-01-23T06:30:45Z … 2044-01-23T15:59:59Z
//   SKI        47:20:A3:B1:26:4B:CD:6D:48:AC:F2:64:08:86:97:2C:74:54:11:5F
//
// ## backupTW/ZK/GRCA-G3.cer — Government Root Certification Authority G3
//
//   source     https://grca.nat.gov.tw/repository/Certs/GRCAG3.crt
//   format     raw DER, 1409 bytes
//   sha256     57df6f20e04c588e85f35be8832f5d4e78958336ae3b18fb7c9bae0dfead4044
//   subject    C=TW, O=行政院, CN=Government Root Certification Authority - G3
//   self-signed, RSA 4096, 2022-06-07T02:33:20Z … 2049-12-31T15:59:59Z
//   SKI        3A:90:8E:E7:41:47:19:73:DC:9C:BD:A3:7E:D8:3D:3E:83:09:1F:03
//
// ## How these bytes were checked, on 2026-08-07
//
// Both files were fetched over HTTPS from the two government hosts above and
// hashed; the digests are the ones written here. The MOICA file was compared
// byte-for-byte against two further copies and matched all three ways:
//
//   * https://grca.nat.gov.tw/repository/Certs/MOICA3.cer — the same
//     certificate published by the root CA rather than the sub-CA, in PEM.
//     Its *file* hash is different (49999c40…), because PEM armour is
//     different bytes; decoded to DER it is identical. Pin the DER, never a
//     PEM file's digest.
//   * the copy vendored in PSE's example app
//     (openac-taiwan-citizen-digital-certificate-ios-example) — identical, so
//     nothing is lost by taking ours from the government instead, and our copy
//     carries none of PSE's licensing uncertainty.
//
// `openssl verify` confirms MOICA-G3 is signed by GRCA-G3, which `loadBundled`
// re-checks on device.
//
// ⚠️ What was **not** achieved, and should not be claimed: there is no
// out-of-band government publication of these fingerprints to compare against.
// The GRCA CPS does not print certificate digests, and the GRCA "CA
// Certificates Distribution" page describes the out-of-band distribution
// *method* without listing any values. Nor does Apple help — no GRCA
// certificate is in the macOS or iOS system trust store, so the OS cannot
// vouch for this chain either. The strongest statement supported by evidence
// is: *these bytes were served by three separate WebPKI-authenticated
// government paths and are internally consistent as a signed chain.* That is
// not the same as a fingerprint published by 內政部 through a second channel.
//
// TODO(trust-anchor): obtain an out-of-band confirmation of
// ed793fd0…a9da — a signed 內政部 publication, a printed CPS fingerprint, or a
// value read off a physical 自然人憑證 IC card — and record it here. Until
// then this anchor rests on TLS to *.nat.gov.tw.
//
// ## Why bundled rather than downloaded
//
// Fetching a trust anchor over the network to decide which certificates to
// trust is circular. It is also pointless here: upstream's "refresh" path
// re-checks whatever it downloads against a compile-time constant, so the
// network can only ever hand back the bytes already compiled in. A real
// generation change (a future G4) needs a new pin, which needs an app release
// either way. Downloading would buy no update capability and would add a
// failure mode — no signal, no proof — to a feature whose entire point is
// working offline. 1.6 KB in the bundle, pinned, and auditable by anyone with
// `shasum`.
//
// ## Licensing, stated honestly
//
// These certificates are government-published public documents and are not
// covered by any PSE licence. That matters because the surrounding stack is
// unclear: `privacy-ethereum/zkID` carries an MIT LICENSE, but
// `openac-rsa-x509-swift`, `go-zkid-verifier`, `moica-revocation-smt` and the
// iOS example app still had **no LICENSE file at all** when checked on
// 2026-08-07. We are proceeding on PSE's written statement that the terms are
// MIT. Do not restate that as "upstream is MIT" — it is a promise, not a file.

// MARK: - Generations

/// Which generation of 內政部憑證管理中心 signed a certificate.
///
/// **Do not try to tell these apart by distinguished name.** All three
/// generations share the byte-identical subject `C=TW, O=行政院,
/// OU=內政部憑證管理中心` — there is not even a CN to differ. The only field
/// that separates them is the key identifier, which is why these constants
/// exist.
///
/// Values were read from the certificates published at
/// `https://moica.nat.gov.tw/repository/Certs/{MOICA,MOICA2,MOICA-G3}.cer`
/// on 2026-08-07.
enum MOICAGeneration: Sendable, Equatable, CaseIterable {

    /// RSA-2048, issued 2003, **expired 2023-04-21**.
    case g1
    /// RSA-2048, valid until 2034-01-02. Still issuing as far as we can tell,
    /// and still has its own revocation tree published upstream.
    case g2
    /// RSA-4096, valid until 2044-01-23. The only generation this app supports.
    case g3

    /// The CA's SubjectKeyIdentifier, which appears verbatim as the
    /// AuthorityKeyIdentifier of every certificate it signs.
    var keyIdentifier: Data {
        switch self {
        case .g1:
            return Data([0xB6, 0x20, 0xC8, 0xCF, 0xBE, 0x51, 0x8A, 0xA4, 0x54, 0xB9,
                         0x78, 0xD3, 0x04, 0xD1, 0x0A, 0xB2, 0xCC, 0x7E, 0x2F, 0x46])
        case .g2:
            return Data([0xFA, 0x9B, 0x34, 0x67, 0x09, 0x0A, 0x98, 0x22, 0xF7, 0x62,
                         0x48, 0x8B, 0x82, 0x26, 0xA6, 0x45, 0xC5, 0xC3, 0x22, 0xA4])
        case .g3:
            return Data([0x47, 0x20, 0xA3, 0xB1, 0x26, 0x4B, 0xCD, 0x6D, 0x48, 0xAC,
                         0xF2, 0x64, 0x08, 0x86, 0x97, 0x2C, 0x74, 0x54, 0x11, 0x5F])
        }
    }

    /// RSA modulus width of the CA's own key.
    ///
    /// This is what makes generation a *circuit* choice rather than a runtime
    /// branch: `certChainRs4096` carries a 34-limb (4096-bit) issuer modulus
    /// and cannot represent a 2048-bit one. A G2 cardholder does not need a
    /// different issuer file, they need a different circuit — which this app
    /// does not have.
    var modulusBitCount: Int {
        switch self {
        case .g1, .g2: return 2048
        case .g3: return 4096
        }
    }

    var localizedName: String {
        switch self {
        case .g1: return NSLocalizedString("MOICA generation 1", comment: "Certificate authority name")
        case .g2: return NSLocalizedString("MOICA generation 2", comment: "Certificate authority name")
        case .g3: return NSLocalizedString("MOICA generation 3", comment: "Certificate authority name")
        }
    }

    /// Which generation signed a certificate carrying this AuthorityKeyIdentifier.
    ///
    /// `nil` means "not one we know about" — a future G4, or a certificate from
    /// somewhere else entirely. Treat that as unsupported, never as "probably fine".
    static func matching(keyIdentifier: Data) -> MOICAGeneration? {
        allCases.first { $0.keyIdentifier == keyIdentifier }
    }
}

// MARK: - Errors

enum IssuerCertificateError: LocalizedError, Equatable {

    /// The bundled `.cer` is not in the app bundle. Almost always a build
    /// configuration problem rather than anything at runtime.
    case bundledCertificateMissing(resource: String)
    /// The bundled file exists but could not be read off disk.
    case bundledCertificateUnreadable(resource: String)
    /// The bundled file is not the bytes this build was written against. No
    /// retry helps and nothing here is damaged — someone replaced the file.
    case fingerprintMismatch(resource: String, expected: String, actual: String)
    /// The bundled anchor parses but is not the certificate the pins describe
    /// (wrong serial, wrong key identifier, wrong modulus width). Distinct from
    /// `fingerprintMismatch` because it catches the case where the digest
    /// constant was updated to match a substituted file but the rest was not.
    case bundledCertificateMismatch(resource: String, detail: String)
    /// The bundled anchor is not signed by the bundled government root.
    case bundledChainBroken
    /// The anchor's own validity window has passed. 2044 for MOICA G3 — far
    /// away, but a device with a wrong clock reaches it today.
    case trustAnchorExpired(on: Date)
    case trustAnchorNotYetValid(from: Date)

    /// The cardholder certificate could not be parsed at all.
    case holderCertificateMalformed(reason: String)
    /// The cardholder certificate has no AuthorityKeyIdentifier, so there is
    /// nothing to match a generation against.
    case holderIssuerUnknown
    /// The cardholder certificate names a CA we recognise but cannot prove for.
    case holderIssuerUnsupported(generation: MOICAGeneration)
    /// The cardholder certificate's AKI says G3 but its signature does not
    /// verify under the G3 key.
    case holderSignatureInvalid
    case holderCertificateExpired(on: Date)
    case holderCertificateNotYetValid(from: Date)

    /// Whether trying the same thing again could produce a different answer.
    ///
    /// Almost nothing here is recoverable, and that is the point of stating it
    /// as a property rather than leaving each caller to guess. A trust anchor
    /// that failed its pin, its identity checks or its chain failed them over a
    /// fixed sequence of bytes: there is no retry that rewrites those bytes, so
    /// offering 「再試一次」 invites the holder to keep tapping at a substituted
    /// certificate. That is the opposite of what a caller should do, which is
    /// stop.
    ///
    /// The two exceptions are the two not-yet-valid cases. Both mean "this
    /// device's clock says a certificate that is in date is not", and correcting
    /// the clock and trying again is exactly the fix — the message already says
    /// so.
    var isRecoverable: Bool {
        switch self {
        case .trustAnchorNotYetValid, .holderCertificateNotYetValid:
            return true
        case .bundledCertificateMissing, .bundledCertificateUnreadable, .fingerprintMismatch,
             .bundledCertificateMismatch, .bundledChainBroken, .trustAnchorExpired,
             .holderCertificateMalformed, .holderIssuerUnknown, .holderIssuerUnsupported,
             .holderSignatureInvalid, .holderCertificateExpired:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .bundledCertificateMissing:
            return NSLocalizedString("The certificate authority file that ships with this app is missing.",
                                     comment: "")
        case .bundledCertificateUnreadable:
            return NSLocalizedString("The certificate authority file that ships with this app couldn't be read.",
                                     comment: "")
        case .fingerprintMismatch, .bundledCertificateMismatch, .bundledChainBroken:
            // Deliberately not "try again". Nothing is damaged and no retry
            // changes the bytes; the honest reading is that the file this app
            // ships with is not the one it was built against.
            return NSLocalizedString(
                "The certificate authority file that ships with this app has been altered, so it won't be used.",
                comment: "")
        case .trustAnchorExpired(let date):
            return String(format: NSLocalizedString(
                "The certificate authority that ships with this app expired on %@. Please update the app.",
                comment: ""), Self.format(date))
        case .trustAnchorNotYetValid(let date):
            return String(format: NSLocalizedString(
                "The certificate authority that ships with this app isn't valid until %@. Check your device's date and time.",
                comment: ""), Self.format(date))
        case .holderCertificateMalformed:
            return NSLocalizedString("Your citizen certificate couldn't be read.", comment: "")
        case .holderIssuerUnknown:
            return NSLocalizedString(
                "This app can't tell which authority issued your citizen certificate. Only certificates from MOICA G3 are supported.",
                comment: "")
        case .holderIssuerUnsupported(let generation):
            return String(format: NSLocalizedString(
                "Your citizen certificate was issued by %@, which this version can't prove. Only certificates from MOICA G3 are supported.",
                comment: ""), generation.localizedName)
        case .holderSignatureInvalid:
            return NSLocalizedString("Your citizen certificate doesn't match the signature of MOICA G3.",
                                     comment: "")
        case .holderCertificateExpired(let date):
            return String(format: NSLocalizedString(
                "Your citizen certificate expired on %@. Renew it before generating a proof.",
                comment: ""), Self.format(date))
        case .holderCertificateNotYetValid(let date):
            return String(format: NSLocalizedString(
                "Your citizen certificate isn't valid until %@. Check your device's date and time.",
                comment: ""), Self.format(date))
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Minimal DER reader

/// One tag-length-value element, addressed by absolute offsets into the
/// certificate's byte array so the exact bytes a signature covers can be
/// recovered without re-encoding anything.
struct DERElement: Equatable {
    let tag: UInt8
    let headerRange: Range<Int>
    let contentRange: Range<Int>

    /// Header plus content — the element as it appears on the wire.
    var range: Range<Int> { headerRange.lowerBound ..< contentRange.upperBound }
}

/// A cursor over DER.
///
/// **Why hand-rolled.** Security.framework will happily parse a certificate on
/// iOS but will not tell you what is inside one: `SecCertificateCopyValues`,
/// the call that returns validity dates and extensions, is macOS-only. Every
/// field this module needs — notAfter, the Subject/Authority Key Identifier
/// extensions, the RSA modulus width, and the raw `tbsCertificate` bytes a
/// signature covers — is in the part iOS does not expose. Pulling in a full
/// ASN.1 library for that would be a larger dependency than the problem.
///
/// It decodes only the shapes X.509 actually uses and rejects everything else
/// rather than guessing. In particular it enforces the DER rules that BER
/// relaxes — definite, minimally-encoded lengths — because a parser that
/// accepts two encodings of the same value is a parser two components can
/// disagree about.
struct DERReader {

    private let bytes: [UInt8]
    private var cursor: Int
    private let limit: Int

    init(_ bytes: [UInt8]) {
        self.init(bytes, from: 0, to: bytes.count)
    }

    private init(_ bytes: [UInt8], from: Int, to: Int) {
        self.bytes = bytes
        self.cursor = from
        self.limit = to
    }

    // Tags this parser knows. Anything else is rejected by name at the call site.
    static let boolean: UInt8 = 0x01
    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let octetString: UInt8 = 0x04
    static let objectIdentifier: UInt8 = 0x06
    static let utcTime: UInt8 = 0x17
    static let generalizedTime: UInt8 = 0x18
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
    /// `[0] EXPLICIT` — the TBSCertificate version field.
    static let contextExplicit0: UInt8 = 0xA0
    /// `[3] EXPLICIT` — the TBSCertificate extensions field.
    static let contextExplicit3: UInt8 = 0xA3
    /// `[0] IMPLICIT` primitive — AuthorityKeyIdentifier's keyIdentifier.
    static let contextPrimitive0: UInt8 = 0x80

    var isAtEnd: Bool { cursor >= limit }

    mutating func next() throws -> DERElement {
        guard cursor < limit else {
            throw DERReader.failure("ran out of data where an element was expected")
        }
        let start = cursor
        let tag = bytes[cursor]
        cursor += 1

        // High-tag-number form. X.509 never uses it, and supporting it would
        // mean supporting tags this parser has no meaning for.
        guard tag & 0x1F != 0x1F else {
            throw DERReader.failure("multi-byte tag")
        }
        guard cursor < limit else {
            throw DERReader.failure("truncated length")
        }

        var length = 0
        let first = bytes[cursor]
        cursor += 1
        if first < 0x80 {
            length = Int(first)
        } else {
            let byteCount = Int(first & 0x7F)
            // 0x80 alone is BER's indefinite length. DER forbids it, and
            // accepting it would mean guessing where the element ends.
            guard byteCount > 0 else {
                throw DERReader.failure("indefinite length")
            }
            // Four bytes is 4 GB; nothing here is remotely that size, and the
            // cap keeps the shift below from overflowing.
            guard byteCount <= 4 else {
                throw DERReader.failure("length field too wide")
            }
            guard cursor + byteCount <= limit else {
                throw DERReader.failure("truncated length")
            }
            guard bytes[cursor] != 0 else {
                throw DERReader.failure("non-minimal length encoding")
            }
            for _ in 0 ..< byteCount {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
            // DER requires the shortest encoding: anything under 128 must have
            // used the short form.
            guard length >= 0x80 else {
                throw DERReader.failure("non-minimal length encoding")
            }
        }

        guard length <= limit - cursor else {
            throw DERReader.failure("element runs past the end of its container")
        }
        let element = DERElement(tag: tag,
                                 headerRange: start ..< cursor,
                                 contentRange: cursor ..< (cursor + length))
        cursor += length
        return element
    }

    mutating func next(expecting tag: UInt8) throws -> DERElement {
        let element = try next()
        guard element.tag == tag else {
            throw DERReader.failure(String(format: "expected tag 0x%02X, found 0x%02X", tag, element.tag))
        }
        return element
    }

    /// A reader over an element's contents. Independent of this reader's cursor.
    func contents(of element: DERElement) -> DERReader {
        DERReader(bytes, from: element.contentRange.lowerBound, to: element.contentRange.upperBound)
    }

    func data(_ range: Range<Int>) -> Data {
        Data(bytes[range])
    }

    func content(of element: DERElement) -> Data {
        Data(bytes[element.contentRange])
    }

    /// Everything an element occupies on the wire — what a signature covers.
    func encoded(_ element: DERElement) -> Data {
        Data(bytes[element.range])
    }

    /// A BIT STRING's payload with the leading unused-bit count removed.
    ///
    /// Everything X.509 puts in a BIT STRING here (signatures, public keys) is
    /// whole bytes, so a non-zero unused-bit count means something is wrong
    /// rather than something needing shifting.
    func bitStringPayload(_ element: DERElement) throws -> Data {
        guard element.tag == DERReader.bitString else {
            throw DERReader.failure("expected a BIT STRING")
        }
        let raw = content(of: element)
        guard let unusedBits = raw.first else {
            throw DERReader.failure("empty BIT STRING")
        }
        guard unusedBits == 0 else {
            throw DERReader.failure("BIT STRING is not a whole number of bytes")
        }
        return raw.dropFirst()
    }

    static func failure(_ reason: String) -> IssuerCertificateError {
        .holderCertificateMalformed(reason: reason)
    }
}

// MARK: - Certificate

/// How a certificate's validity window looks at a given moment.
enum CertificateValidity: Equatable {
    case valid
    case notYetValid(from: Date)
    case expired(on: Date)
}

/// The parts of an X.509 certificate this app has to reason about.
///
/// Deliberately not a general-purpose certificate type. It carries what the ZK
/// pipeline and the trust-anchor checks need and nothing more.
struct X509Certificate: Equatable, Sendable {

    /// The certificate exactly as it arrived.
    let der: Data
    /// The `tbsCertificate` element including its own header — the bytes the
    /// issuer signed. Sliced out rather than re-encoded, because re-encoding a
    /// structure to verify a signature over it is how signature checks come to
    /// pass on things that were never signed.
    let tbsCertificate: Data
    /// OID of the outer `signatureAlgorithm`, as raw DER content bytes.
    let signatureAlgorithmOID: Data
    let signature: Data
    /// Serial number content bytes, big-endian, as encoded.
    let serialNumber: Data
    let issuerName: Data
    let subjectName: Data
    let notBefore: Date
    let notAfter: Date
    /// `SubjectPublicKeyInfo` in full.
    let subjectPublicKeyInfo: Data
    /// The PKCS#1 `RSAPublicKey` inside the SPKI, if the key is RSA. This is
    /// the encoding `SecKeyCreateWithData` wants; SPKI is not.
    let rsaPublicKey: Data?
    let rsaModulusBitCount: Int?
    let subjectKeyIdentifier: Data?
    let authorityKeyIdentifier: Data?

    /// Lowercase hex SHA-256 of the whole certificate — the value a reader can
    /// reproduce with `shasum -a 256`.
    var sha256Hex: String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex of the serial number's magnitude.
    ///
    /// DER INTEGERs are signed, so a serial whose leading byte has the high bit
    /// set is encoded with an extra `0x00` in front — GRCA G3's `CD1D…` is one.
    /// Every tool that prints a serial (openssl, Keychain Access, the CRL)
    /// shows the magnitude, so a pin written from one of those would never
    /// match the encoded bytes. DER's minimal-encoding rule means there is at
    /// most one such byte, and only before a byte ≥ 0x80, so dropping it under
    /// exactly that condition is lossless rather than a guess.
    var serialNumberHex: String {
        var magnitude = serialNumber
        if magnitude.count > 1, magnitude.first == 0x00,
           let second = magnitude.dropFirst().first, second >= 0x80 {
            magnitude = magnitude.dropFirst()
        }
        return magnitude.map { String(format: "%02x", $0) }.joined()
    }

    func validity(at date: Date) -> CertificateValidity {
        if date < notBefore { return .notYetValid(from: notBefore) }
        if date > notAfter { return .expired(on: notAfter) }
        return .valid
    }

    // MARK: Parsing

    static func parse(der: Data) throws -> X509Certificate {
        let bytes = [UInt8](der)
        var root = DERReader(bytes)
        let certificate = try root.next(expecting: DERReader.sequence)
        guard root.isAtEnd else {
            throw DERReader.failure("trailing bytes after the certificate")
        }

        var top = root.contents(of: certificate)
        let tbs = try top.next(expecting: DERReader.sequence)
        let outerAlgorithm = try top.next(expecting: DERReader.sequence)
        let signatureBits = try top.next(expecting: DERReader.bitString)
        guard top.isAtEnd else {
            throw DERReader.failure("trailing bytes inside the certificate")
        }

        var fields = root.contents(of: tbs)
        var element = try fields.next()
        if element.tag == DERReader.contextExplicit0 {
            // version [0] EXPLICIT — present on every v3 certificate.
            element = try fields.next()
        }
        guard element.tag == DERReader.integer else {
            throw DERReader.failure("expected a serial number")
        }
        let serialNumber = fields.content(of: element)

        let innerAlgorithm = try fields.next(expecting: DERReader.sequence)
        let issuer = try fields.next(expecting: DERReader.sequence)
        let validity = try fields.next(expecting: DERReader.sequence)
        let subject = try fields.next(expecting: DERReader.sequence)
        let spki = try fields.next(expecting: DERReader.sequence)

        // RFC 5280 §4.1.1.2: the AlgorithmIdentifier inside the signed body and
        // the one outside it must agree. They are signed and unsigned copies of
        // the same claim, so a mismatch means someone edited the unsigned one.
        let outerOID = try algorithmOID(in: outerAlgorithm, reader: root)
        let innerOID = try algorithmOID(in: innerAlgorithm, reader: root)
        guard outerOID == innerOID else {
            throw DERReader.failure("signature algorithm inside and outside the signed body disagree")
        }

        var validityReader = root.contents(of: validity)
        let notBeforeElement = try validityReader.next()
        let notBefore = try time(from: notBeforeElement, reader: validityReader)
        let notAfterElement = try validityReader.next()
        let notAfter = try time(from: notAfterElement, reader: validityReader)
        guard validityReader.isAtEnd else {
            throw DERReader.failure("unexpected extra field in the validity window")
        }

        var subjectKeyIdentifier: Data?
        var authorityKeyIdentifier: Data?
        while !fields.isAtEnd {
            let optional = try fields.next()
            guard optional.tag == DERReader.contextExplicit3 else {
                // [1] and [2] are the deprecated unique identifiers. Skipped
                // rather than rejected: they are legal, just meaningless here.
                continue
            }
            var wrapper = root.contents(of: optional)
            let list = try wrapper.next(expecting: DERReader.sequence)
            var extensions = root.contents(of: list)
            while !extensions.isAtEnd {
                let extensionElement = try extensions.next(expecting: DERReader.sequence)
                var parts = root.contents(of: extensionElement)
                let oid = try parts.next(expecting: DERReader.objectIdentifier)
                var value = try parts.next()
                if value.tag == DERReader.boolean {
                    // criticality flag, present only when true
                    value = try parts.next()
                }
                guard value.tag == DERReader.octetString else {
                    throw DERReader.failure("extension value is not an OCTET STRING")
                }
                let oidBytes = parts.content(of: oid)
                if oidBytes == Data([0x55, 0x1D, 0x0E]) {           // 2.5.29.14 SKI
                    var inner = root.contents(of: value)
                    let keyID = try inner.next(expecting: DERReader.octetString)
                    subjectKeyIdentifier = inner.content(of: keyID)
                } else if oidBytes == Data([0x55, 0x1D, 0x23]) {    // 2.5.29.35 AKI
                    var inner = root.contents(of: value)
                    let sequence = try inner.next(expecting: DERReader.sequence)
                    var members = root.contents(of: sequence)
                    while !members.isAtEnd {
                        let member = try members.next()
                        if member.tag == DERReader.contextPrimitive0 {
                            authorityKeyIdentifier = members.content(of: member)
                            break
                        }
                    }
                }
            }
        }

        let (rsaPublicKey, modulusBits) = try rsaKey(in: spki, reader: root)

        return X509Certificate(
            der: der,
            tbsCertificate: root.encoded(tbs),
            signatureAlgorithmOID: outerOID,
            signature: try root.bitStringPayload(signatureBits),
            serialNumber: serialNumber,
            issuerName: root.encoded(issuer),
            subjectName: root.encoded(subject),
            notBefore: notBefore,
            notAfter: notAfter,
            subjectPublicKeyInfo: root.encoded(spki),
            rsaPublicKey: rsaPublicKey,
            rsaModulusBitCount: modulusBits,
            subjectKeyIdentifier: subjectKeyIdentifier,
            authorityKeyIdentifier: authorityKeyIdentifier)
    }

    static func parse(base64DER: String) throws -> X509Certificate {
        // TW FidO hands back standard base64 of the DER. Reject anything that
        // is not exactly that rather than trying base64url as a fallback: a
        // silent re-interpretation here becomes a proof that never verifies,
        // hours later, with nothing pointing back to this line.
        guard let der = Data(base64Encoded: base64DER, options: [.ignoreUnknownCharacters]) else {
            throw IssuerCertificateError.holderCertificateMalformed(reason: "not valid base64")
        }
        return try parse(der: der)
    }

    private static func algorithmOID(in element: DERElement, reader: DERReader) throws -> Data {
        var sequence = reader.contents(of: element)
        let oid = try sequence.next(expecting: DERReader.objectIdentifier)
        return sequence.content(of: oid)
    }

    private static func time(from element: DERElement, reader: DERReader) throws -> Date {
        let text = String(decoding: reader.content(of: element), as: UTF8.self)
        var year = 0
        var rest = ""
        switch element.tag {
        case DERReader.utcTime:
            // YYMMDDHHMMSSZ. RFC 5280 mandates seconds and the Z suffix, and
            // reads YY >= 50 as 19xx — a rule that has been "obviously fine for
            // another 20 years" since 1988.
            guard text.count == 13, text.hasSuffix("Z"),
                  let twoDigit = Int(text.prefix(2)) else {
                throw DERReader.failure("malformed UTCTime")
            }
            year = twoDigit >= 50 ? 1900 + twoDigit : 2000 + twoDigit
            rest = String(text.dropFirst(2).dropLast())
        case DERReader.generalizedTime:
            // YYYYMMDDHHMMSSZ. Required past 2049, which is where GRCA G3's own
            // notAfter sits, so this branch is not hypothetical.
            guard text.count == 15, text.hasSuffix("Z"),
                  let fourDigit = Int(text.prefix(4)) else {
                throw DERReader.failure("malformed GeneralizedTime")
            }
            year = fourDigit
            rest = String(text.dropFirst(4).dropLast())
        default:
            throw DERReader.failure("expected a time")
        }

        let digits = Array(rest)
        guard digits.count == 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw DERReader.failure("malformed time")
        }
        func pair(_ index: Int) -> Int { Int(String(digits[index ... index + 1])) ?? 0 }

        var components = DateComponents()
        components.year = year
        components.month = pair(0)
        components.day = pair(2)
        components.hour = pair(4)
        components.minute = pair(6)
        components.second = pair(8)

        var calendar = Calendar(identifier: .gregorian)
        // A fixed calendar and zone, never the device's: a user in a
        // non-Gregorian locale must not get a different notAfter.
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = calendar.date(from: components) else {
            throw DERReader.failure("time is not a real date")
        }
        return date
    }

    /// Pulls the PKCS#1 `RSAPublicKey` out of a SubjectPublicKeyInfo and
    /// measures the modulus.
    ///
    /// Returns `(nil, nil)` for non-RSA keys rather than throwing — a
    /// certificate with an EC key is a perfectly well-formed certificate, it is
    /// just not one this pipeline can use, and that judgement belongs to the
    /// caller that knows what it needs.
    private static func rsaKey(in spki: DERElement, reader: DERReader) throws -> (Data?, Int?) {
        var outer = reader.contents(of: spki)
        let algorithm = try outer.next(expecting: DERReader.sequence)
        let keyBits = try outer.next(expecting: DERReader.bitString)

        // 1.2.840.113549.1.1.1 rsaEncryption
        let rsaEncryption = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        guard try algorithmOID(in: algorithm, reader: reader) == rsaEncryption else {
            return (nil, nil)
        }

        let pkcs1 = try reader.bitStringPayload(keyBits)
        var keyReader = DERReader([UInt8](pkcs1))
        let sequence = try keyReader.next(expecting: DERReader.sequence)
        var members = keyReader.contents(of: sequence)
        let modulus = try members.next(expecting: DERReader.integer)
        _ = try members.next(expecting: DERReader.integer)   // publicExponent
        guard members.isAtEnd else {
            throw DERReader.failure("unexpected extra field in the RSA public key")
        }

        // DER INTEGERs are signed, so a modulus with the top bit set carries a
        // leading 0x00. Counting it would report 2056-bit keys as 2064-bit.
        var magnitude = members.content(of: modulus)
        while magnitude.first == 0 { magnitude = magnitude.dropFirst() }
        guard let leadingByte = magnitude.first else {
            throw DERReader.failure("RSA modulus is zero")
        }
        let bitCount = (magnitude.count - 1) * 8 + (8 - leadingByte.leadingZeroBitCount)
        return (pkcs1, bitCount)
    }

    // MARK: Signature

    /// Whether this certificate's signature verifies under `issuer`'s public key.
    ///
    /// This is only the arithmetic. It says nothing about whether `issuer` is
    /// allowed to sign, is in date, or is the CA you meant — those are the
    /// caller's checks, and they are made in `IssuerCertificate`.
    func isSignatureValid(signedBy issuer: X509Certificate) throws -> Bool {
        guard let pkcs1 = issuer.rsaPublicKey, let bitCount = issuer.rsaModulusBitCount else {
            throw IssuerCertificateError.holderCertificateMalformed(reason: "issuer key is not RSA")
        }
        guard let algorithm = Self.secKeyAlgorithm(forSignatureOID: signatureAlgorithmOID) else {
            throw IssuerCertificateError.holderCertificateMalformed(
                reason: "unsupported signature algorithm")
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: bitCount
        ]
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData,
                                             attributes as CFDictionary,
                                             &creationError) else {
            creationError?.release()
            throw IssuerCertificateError.holderCertificateMalformed(
                reason: "issuer key could not be loaded")
        }

        var verifyError: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(key,
                                             algorithm,
                                             tbsCertificate as CFData,
                                             signature as CFData,
                                             &verifyError)
        // A failed verification reports an error as well as `false`; it is the
        // expected outcome for a wrong certificate, not something to surface.
        verifyError?.release()
        return verified
    }

    /// SHA-1 is absent on purpose. MOICA G3 signs with SHA-256 and nothing in
    /// this pipeline needs to accept a weaker digest; a certificate presenting
    /// one is rejected as unsupported rather than verified.
    private static func secKeyAlgorithm(forSignatureOID oid: Data) -> SecKeyAlgorithm? {
        switch [UInt8](oid) {
        case [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]:
            return .rsaSignatureMessagePKCS1v15SHA256
        case [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C]:
            return .rsaSignatureMessagePKCS1v15SHA384
        case [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D]:
            return .rsaSignatureMessagePKCS1v15SHA512
        default:
            return nil
        }
    }
}

// MARK: - The trust anchor

/// The bundled 內政部憑證管理中心 G3 certificate, loaded and checked.
///
/// This is the file `generateCertChainRs4096Input` receives as `issuerCertPath`
/// — the *issuer*, never the cardholder's own certificate, which arrives from
/// TW FidO as `result.cert` and goes in as `certb64`. Swapping the two produces
/// a proof that generates successfully and never verifies.
struct IssuerCertificate {

    /// Must match `CircuitAssets.issuerCertificateFilename`, since that is the
    /// name the working directory is read back under. A test pins the two
    /// together so a rename in either place fails loudly.
    static let installedFilename = "MOICA-G3.cer"

    static let issuerResourceName = "MOICA-G3"
    static let rootResourceName = "GRCA-G3"
    static let resourceExtension = "cer"

    /// See the provenance block at the top of this file for how these were
    /// obtained and what they do and do not prove.
    static let pinnedIssuerSHA256 = "ed793fd0d50a2a398049d598982cf01e75f873b532066caec238f800a06ca9da"
    static let pinnedRootSHA256 = "57df6f20e04c588e85f35be8832f5d4e78958336ae3b18fb7c9bae0dfead4044"
    static let pinnedIssuerSerialNumberHex = "5a202d14b39787d0886c37184ac9b76a"
    static let pinnedRootSerialNumberHex = "cd1de713a9adbf68fe2916d8435415c7"

    /// The generation this build can produce proofs for. Not a preference — the
    /// `certChainRs4096` circuit has a 4096-bit issuer modulus baked into its
    /// constraint system.
    static let supportedGeneration: MOICAGeneration = .g3

    let certificate: X509Certificate
    let root: X509Certificate

    var der: Data { certificate.der }

    // MARK: Loading

    static func loadBundled(from bundle: Bundle = .main, now: Date = Date()) throws -> IssuerCertificate {
        try load(issuerURL: bundle.url(forResource: issuerResourceName, withExtension: resourceExtension),
                 rootURL: bundle.url(forResource: rootResourceName, withExtension: resourceExtension),
                 now: now)
    }

    /// The seam the tests use. `nil` URLs stand in for "not in the bundle",
    /// which is otherwise only reproducible by building a broken app.
    static func load(issuerURL: URL?, rootURL: URL?, now: Date) throws -> IssuerCertificate {
        let issuerData = try read(issuerURL, resource: issuerResourceName)
        let rootData = try read(rootURL, resource: rootResourceName)
        return try load(issuerDER: issuerData, rootDER: rootData, now: now)
    }

    static func load(issuerDER: Data, rootDER: Data, now: Date) throws -> IssuerCertificate {
        try checkFingerprint(issuerDER, expected: pinnedIssuerSHA256, resource: issuerResourceName)
        try checkFingerprint(rootDER, expected: pinnedRootSHA256, resource: rootResourceName)

        // `DERReader` reports every parse failure as `holderCertificateMalformed`,
        // because that is what nearly all of them are. Here it would be a lie —
        // and a user told "your citizen certificate couldn't be read" when the
        // app's own bundle is broken will go and renew a perfectly good card.
        let issuer = try parseBundled(issuerDER, resource: issuerResourceName)
        let root = try parseBundled(rootDER, resource: rootResourceName)

        // The digest pin above already fixes these bytes, so on its own this
        // block is redundant. It is here for the case the pin does not cover:
        // someone swapping the file *and* updating the constant in the same
        // commit. Restating the identity in four independent ways makes that a
        // conspicuous diff rather than a one-line one.
        try checkIdentity(issuer,
                          resource: issuerResourceName,
                          serialNumberHex: pinnedIssuerSerialNumberHex,
                          keyIdentifier: supportedGeneration.keyIdentifier,
                          modulusBitCount: supportedGeneration.modulusBitCount)
        try checkIdentity(root,
                          resource: rootResourceName,
                          serialNumberHex: pinnedRootSerialNumberHex,
                          keyIdentifier: nil,
                          modulusBitCount: 4096)

        // The issuing CA's subject is byte-identical across G1/G2/G3, so this
        // proves only that the file is *a* MOICA certificate. The key
        // identifier check above is what establishes which one.
        guard issuer.issuerName == root.subjectName else {
            throw IssuerCertificateError.bundledChainBroken
        }
        guard try issuer.isSignatureValid(signedBy: root) else {
            throw IssuerCertificateError.bundledChainBroken
        }

        // Both anchors are checked, because a chain is only as in-date as its
        // weakest link and the root outlives the sub-CA by five years.
        for certificate in [root, issuer] {
            switch certificate.validity(at: now) {
            case .valid:
                break
            case .expired(let date):
                throw IssuerCertificateError.trustAnchorExpired(on: date)
            case .notYetValid(let date):
                throw IssuerCertificateError.trustAnchorNotYetValid(from: date)
            }
        }

        return IssuerCertificate(certificate: issuer, root: root)
    }

    private static func read(_ url: URL?, resource: String) throws -> Data {
        guard let url else {
            throw IssuerCertificateError.bundledCertificateMissing(resource: resource)
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw IssuerCertificateError.bundledCertificateUnreadable(resource: resource)
        }
        return data
    }

    private static func parseBundled(_ der: Data, resource: String) throws -> X509Certificate {
        do {
            return try X509Certificate.parse(der: der)
        } catch let error as IssuerCertificateError {
            let detail: String
            if case .holderCertificateMalformed(let reason) = error {
                detail = reason
            } else {
                detail = String(describing: error)
            }
            throw IssuerCertificateError.bundledCertificateMismatch(resource: resource, detail: detail)
        }
    }

    private static func checkFingerprint(_ data: Data, expected: String, resource: String) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw IssuerCertificateError.fingerprintMismatch(resource: resource,
                                                             expected: expected,
                                                             actual: actual)
        }
    }

    private static func checkIdentity(_ certificate: X509Certificate,
                                      resource: String,
                                      serialNumberHex: String,
                                      keyIdentifier: Data?,
                                      modulusBitCount: Int) throws {
        guard certificate.serialNumberHex == serialNumberHex else {
            throw IssuerCertificateError.bundledCertificateMismatch(
                resource: resource,
                detail: "serial number \(certificate.serialNumberHex)")
        }
        if let keyIdentifier {
            guard certificate.subjectKeyIdentifier == keyIdentifier else {
                throw IssuerCertificateError.bundledCertificateMismatch(
                    resource: resource, detail: "subject key identifier")
            }
        }
        guard certificate.rsaModulusBitCount == modulusBitCount else {
            throw IssuerCertificateError.bundledCertificateMismatch(
                resource: resource,
                detail: "RSA modulus is \(certificate.rsaModulusBitCount.map { String($0) } ?? "not RSA") bits")
        }
    }

    // MARK: Installing

    /// Writes the anchor into the working directory that `documentsPath` points
    /// at, under the name `generateCertChainRs4096Input` will look for.
    ///
    /// Writes the bytes already held and already verified rather than copying
    /// the file again. The difference matters: a second read of the bundle is a
    /// second chance for the bytes to differ from the ones that passed the
    /// digest check, and a copy is exactly the operation that would not notice.
    @discardableResult
    func install(into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(Self.installedFilename)
        try certificate.der.write(to: destination, options: .atomic)
        return destination
    }

    /// Re-reads the installed anchor and checks it against the pin. Throws if it
    /// is absent, empty, or not the bytes this build was written against.
    ///
    /// # Why the installed copy is checked again rather than trusted once
    ///
    /// `install(into:)` writes bytes `loadBundled` verified, so at the instant
    /// it returns the file is beyond question. What is not beyond question is
    /// the file a *later* run finds under that name. The working directory is
    /// ordinary application-container storage — a restore, a half-rolled-back
    /// backup, a filesystem fault, or write access to the container on a
    /// jailbroken device can all leave different bytes there — and nothing
    /// downstream would notice. `ZKProver.prove` checks only that the path
    /// exists before handing it to `generateCertChainRs4096Input` as
    /// `issuerCertPath`, which is the issuer public key every proof is anchored
    /// to. Verifying the anchor exactly once, on the install that happened
    /// months ago, is not verifying it.
    ///
    /// There is no trade-off to make: this hashes 1,643 bytes against a proof
    /// measured in tens of seconds and roughly two gigabytes of memory.
    ///
    /// **The digest alone is sufficient here, and that is not a shortcut.** This
    /// file is only ever written by `install(into:)`, which writes precisely
    /// what `load(issuerDER:rootDER:now:)` accepted — the pin, the identity
    /// restated over serial number, key identifier and modulus width, and the
    /// signature by GRCA-G3. A file whose SHA-256 equals `pinnedIssuerSHA256`
    /// *is* that byte sequence, so re-parsing it would re-derive an answer the
    /// digest has already fixed. The one thing a digest cannot re-check is the
    /// validity window, which is a function of the clock rather than of the
    /// bytes; `loadBundled` checks it on the install path, and the circuit
    /// checks no dates either way (see the closing note in this file).
    static func verifyInstalled(in directory: URL) throws {
        let url = directory.appendingPathComponent(installedFilename)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            // Absent and unreadable are the same instruction to the caller —
            // install it again — and this is not the path where a build
            // configuration problem is diagnosed.
            throw IssuerCertificateError.bundledCertificateMissing(resource: issuerResourceName)
        }
        try checkFingerprint(data, expected: pinnedIssuerSHA256, resource: issuerResourceName)
    }

    /// `verifyInstalled(in:)` asked as a question.
    ///
    /// For the readiness plan, where absent and altered lead to the same place:
    /// the anchor has to be written again from the bundle before anything is
    /// proven, and the plan has one row that says so.
    static func installedCertificateIsVerified(in directory: URL) -> Bool {
        do {
            try verifyInstalled(in: directory)
            return true
        } catch {
            return false
        }
    }

    // MARK: Admitting a cardholder certificate

    /// Decides whether a cardholder certificate can be proven by this build,
    /// and returns it parsed if so.
    ///
    /// Runs before anything expensive. Without it the first sign that a G2
    /// cardholder is unsupported is a proof that generates in a few seconds and
    /// then fails verification somewhere else entirely, with nothing to say why.
    ///
    /// Checks run in the order a user can act on:
    ///
    ///   1. **Which CA issued it**, from the AuthorityKeyIdentifier. Nothing to
    ///      be done about a wrong answer, but the message can at least be true.
    ///   2. **Whether it is in date.** The common case by a wide margin — a
    ///      行動自然人憑證 lasts one year — and the only one with an action
    ///      attached.
    ///   3. **Whether the signature holds.** Last because it is the case no
    ///      user can do anything about, and because reaching it means the two
    ///      cheap explanations are already ruled out.
    ///
    /// Note that steps 1 and 2 read unauthenticated fields, so their answers
    /// are diagnostics rather than security decisions: a forged certificate can
    /// claim any date it likes. Nothing is trusted until step 3 — and the ZK
    /// circuit re-derives the same signature check anyway. What this method
    /// buys is a legible failure, not a security boundary.
    @discardableResult
    func validateHolderCertificate(_ holder: X509Certificate,
                                   now: Date = Date()) throws -> X509Certificate {
        guard let authorityKeyIdentifier = holder.authorityKeyIdentifier else {
            throw IssuerCertificateError.holderIssuerUnknown
        }
        guard let generation = MOICAGeneration.matching(keyIdentifier: authorityKeyIdentifier) else {
            // Not one of the three we know. Most likely a future G4, in which
            // case the honest answer is that this build predates it.
            throw IssuerCertificateError.holderIssuerUnknown
        }
        guard generation == Self.supportedGeneration else {
            throw IssuerCertificateError.holderIssuerUnsupported(generation: generation)
        }

        switch holder.validity(at: now) {
        case .valid:
            break
        case .expired(let date):
            throw IssuerCertificateError.holderCertificateExpired(on: date)
        case .notYetValid(let date):
            throw IssuerCertificateError.holderCertificateNotYetValid(from: date)
        }

        // Written as a plain `Bool` rather than comparing an `Optional<Bool>`:
        // an unsupported algorithm and a wrong signature are both "this cannot
        // be proven", and the user-facing answer is the same either way.
        let signatureHolds = (try? holder.isSignatureValid(signedBy: certificate)) ?? false
        guard signatureHolds else {
            throw IssuerCertificateError.holderSignatureInvalid
        }
        return holder
    }

    /// Convenience for the shape TW FidO actually returns: `result.cert`, a
    /// base64 DER string.
    @discardableResult
    func validateHolderCertificate(base64DER: String,
                                   now: Date = Date()) throws -> X509Certificate {
        try validateHolderCertificate(try X509Certificate.parse(base64DER: base64DER), now: now)
    }

    // MARK: What this anchor does not establish
    //
    // Worth stating next to the code rather than in a design document, because
    // the gap is invisible from here:
    //
    // * **The circuit checks no dates.** `generateCertChainRs4096Input` emits
    //   an issuer modulus, an issuer signature, a serial number and an SMT
    //   witness — and not one validity field. An expired cardholder
    //   certificate, and an expired CA, both still produce a mathematically
    //   valid proof. The proposition a passing proof establishes is "this
    //   certificate was signed by MOICA G3 and its serial is absent from the
    //   revocation tree", *not* "this certificate is valid today". The Swift
    //   side is where in-date is decided; upstream's Go verifier does it when
    //   loading the issuer, and going offline is exactly what removes that.
    //
    // * **Revocation is only as fresh as the snapshot**, and the snapshot's
    //   real trust anchor — the SMT root published on-chain — is not checked
    //   anywhere in this app yet. See the note on `CircuitAssets.required`.
    //   Do not let UI copy say "not revoked".
    //
    // * **Nothing here makes a holder unique.** `linkVerify` runs on device,
    //   which is what makes offline verification possible at all, but nullifier
    //   de-duplication needs a shared record and there is no such thing
    //   offline. "A real person" is in reach; "a real person, once" is not, and
    //   must not be implied.
}
