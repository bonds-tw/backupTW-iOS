//
//  OfficialDocumentPackage.swift
//  backupTW
//
//  A deliberately narrow EN / DI / ESW ingestion boundary.
//

import CryptoKit
import Foundation

enum OfficialDocumentPackageError: Error, Equatable {
    case componentTooLarge(String)
    case unsafeXML(String)
    case malformedXML(String)
    case unexpectedRoot(expected: String, actual: String)
    case missingEnvelopeField(String)
    case invalidApplicationID
    case missingFileReference(String)
    case unsupportedHashAlgorithm(String)
    case malformedHash(String)
    case hashMismatch(String)
    case noDocumentContent
}

extension OfficialDocumentPackageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .componentTooLarge:
            return NSLocalizedString("The test package is larger than this prototype accepts.", comment: "official document inbox")
        case .unsafeXML, .malformedXML, .unexpectedRoot:
            return NSLocalizedString("The electronic official document XML could not be safely read.", comment: "official document inbox")
        case .missingEnvelopeField, .invalidApplicationID, .missingFileReference,
             .unsupportedHashAlgorithm, .malformedHash:
            return NSLocalizedString("The electronic official document envelope is incomplete or unsupported.", comment: "official document inbox")
        case .hashMismatch:
            return NSLocalizedString("A file does not match the SHA-256 fingerprint listed in the envelope, so the package was not stored.", comment: "official document inbox")
        case .noDocumentContent:
            return NSLocalizedString("The envelope contains no readable document or encrypted switch file.", comment: "official document inbox")
        }
    }
}

/// Raw components crossing the exchange boundary. They are retained byte for
/// byte by `OfficialDocumentInboxArchive`; the parsed model below is an index,
/// never a replacement for the source files.
struct OfficialDocumentImportPayload: Equatable, Sendable {
    struct Component: Equatable, Sendable {
        let filename: String
        let data: Data
    }

    let envelope: Component
    let document: Component?
    let encryptedSwitch: Component?
    let receivedAt: Date
}

struct OfficialDocumentPackage: Codable, Equatable, Sendable {
    enum Environment: String, Codable, Sendable {
        /// This package was built inside a Debug/test harness. It was never
        /// delivered by a government exchange service.
        case syntheticFixtureOnly
    }

    enum LocalState: String, Codable, Sendable {
        /// Local UI state only. It is not a statutory receipt state.
        case unread
        case viewedLocally
    }

    enum ContentAvailability: String, Codable, Sendable {
        /// A synthetic DI is available for parser and UI testing. An ESW may be
        /// present beside it, but no claim is made that this is a sendable G2C
        /// package.
        case syntheticReadable
        /// The EN/ESW boundary was understood, but no DI can be opened until a
        /// real exchange/decryption contract exists.
        case encryptedContentUnavailable
    }

    enum SourceAuthentication: String, Codable, Sendable {
        /// Hash integrity is not sender authentication. The prototype has no
        /// official address book, exchange signature, or receipt channel.
        case notVerifiedSynthetic
    }

    struct Party: Codable, Equatable, Sendable {
        let organizationID: String
        let organizationName: String
    }

    struct FileReference: Codable, Equatable, Sendable {
        let filename: String
        let algorithm: String
        let digest: String
        let note: String?
    }

    struct Envelope: Codable, Equatable, Sendable {
        let sender: Party
        let serviceID: String
        let applicationID: String
        let subject: String
        let expiresAtText: String?
        let files: [FileReference]
    }

    struct Document: Codable, Equatable, Sendable {
        let type: String
        let senderName: String
        let dateText: String
        let number: String
        let priority: String
        let subject: String
        let bodyText: String?
    }

    struct EncryptedSwitch: Codable, Equatable, Sendable {
        /// Recipient card identifiers and ciphertext stay only in the protected
        /// raw ESW. The index records capability, not identity material.
        let recipientCount: Int
        let method: String
        let mimeType: String
    }

    struct IntegrityEvidence: Codable, Equatable, Sendable {
        let algorithm: String
        let envelopeDigest: String
        let documentDigest: String?
        let encryptedSwitchDigest: String?
        let checkedAt: Date
    }

    let id: String
    let environment: Environment
    let envelope: Envelope
    let document: Document?
    let encryptedSwitch: EncryptedSwitch?
    let contentAvailability: ContentAvailability
    let sourceAuthentication: SourceAuthentication
    let integrity: IntegrityEvidence
    let receivedAt: Date
    let localState: LocalState
    let viewedAt: Date?

    func markingViewed(at date: Date) -> Self {
        guard localState == .unread else { return self }
        return Self(id: id,
                    environment: environment,
                    envelope: envelope,
                    document: document,
                    encryptedSwitch: encryptedSwitch,
                    contentAvailability: contentAvailability,
                    sourceAuthentication: sourceAuthentication,
                    integrity: integrity,
                    receivedAt: receivedAt,
                    localState: .viewedLocally,
                    viewedAt: date)
    }
}

enum OfficialDocumentPackageParser {
    private static let maximumComponentBytes = 2 * 1_024 * 1_024

    /// Parses only the subset needed to exercise the holder-side product. It
    /// does not claim complete DTD validation and therefore accepts only a
    /// synthetic environment. Real G2C ingestion must add official schema,
    /// address-book, signature and transport validation before calling storage.
    static func parseSynthetic(_ payload: OfficialDocumentImportPayload,
                               checkedAt: Date = Date()) throws -> OfficialDocumentPackage {
        let envelopeXML = try ParsedXML(payload.envelope, expectedRoot: "g2b2c-envelope",
                                        maximumBytes: maximumComponentBytes)
        let senderID = try required(envelopeXML.firstValue(endingIn: ["senderinfo", "object", "orgid"]),
                                    field: "sender orgid")
        let senderName = try required(envelopeXML.firstValue(endingIn: ["senderinfo", "object", "orgname"]),
                                      field: "sender orgname")
        let serviceID = try required(envelopeXML.firstValue(endingIn: ["serviceid"]),
                                     field: "serviceid")
        let applicationID = try required(envelopeXML.firstValue(endingIn: ["applicationid"]),
                                         field: "applicationid")
        guard applicationID.utf8.count <= 128,
              !applicationID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OfficialDocumentPackageError.invalidApplicationID
        }
        let subject = try required(envelopeXML.firstValue(endingIn: ["subject"]), field: "subject")
        let references = try envelopeXML.fileReferences()

        var document: OfficialDocumentPackage.Document?
        var documentDigest: String?
        if let component = payload.document {
            let digest = try verify(component, against: references)
            let xml = try ParsedXML(component, expectedRoot: nil,
                                    maximumBytes: maximumComponentBytes)
            documentDigest = digest
            document = OfficialDocumentPackage.Document(
                type: xml.rootName,
                senderName: xml.firstValue(endingIn: ["發文機關", "全銜"]) ?? senderName,
                dateText: xml.firstValue(endingIn: ["發文日期"]) ?? "",
                number: xml.firstValue(endingIn: ["發文字號"]) ?? "",
                priority: xml.firstValue(endingIn: ["速別"]) ?? "",
                subject: xml.firstValue(endingIn: ["主旨"]) ?? subject,
                bodyText: xml.firstValue(endingIn: ["說明"]))
        }

        var encryptedSwitch: OfficialDocumentPackage.EncryptedSwitch?
        var encryptedSwitchDigest: String?
        if let component = payload.encryptedSwitch {
            let digest = try verify(component, against: references)
            let xml = try ParsedXML(component, expectedRoot: "g2b2c-encrypt-list",
                                    maximumBytes: maximumComponentBytes)
            encryptedSwitchDigest = digest
            encryptedSwitch = OfficialDocumentPackage.EncryptedSwitch(
                recipientCount: xml.count(elementsEndingIn: ["cardlist"]),
                method: xml.firstAttribute(endingIn: ["EncryptedData"], named: "Method") ?? "",
                mimeType: xml.firstAttribute(endingIn: ["EncryptedData"], named: "MimeType") ?? "")
        }

        guard document != nil || encryptedSwitch != nil else {
            throw OfficialDocumentPackageError.noDocumentContent
        }

        let envelopeDigest = sha256(payload.envelope.data)
        return OfficialDocumentPackage(
            id: "synthetic:\(applicationID)",
            environment: .syntheticFixtureOnly,
            envelope: .init(sender: .init(organizationID: senderID,
                                          organizationName: senderName),
                            serviceID: serviceID,
                            applicationID: applicationID,
                            subject: subject,
                            expiresAtText: envelopeXML.firstValue(endingIn: ["expiredate"]),
                            files: references),
            document: document,
            encryptedSwitch: encryptedSwitch,
            contentAvailability: document == nil ? .encryptedContentUnavailable : .syntheticReadable,
            sourceAuthentication: .notVerifiedSynthetic,
            integrity: .init(algorithm: "SHA-256",
                             envelopeDigest: envelopeDigest,
                             documentDigest: documentDigest,
                             encryptedSwitchDigest: encryptedSwitchDigest,
                             checkedAt: checkedAt),
            receivedAt: payload.receivedAt,
            localState: .unread,
            viewedAt: nil)
    }

    private static func required(_ value: String?, field: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw OfficialDocumentPackageError.missingEnvelopeField(field)
        }
        return value
    }

    private static func verify(_ component: OfficialDocumentImportPayload.Component,
                               against references: [OfficialDocumentPackage.FileReference]) throws -> String {
        guard let reference = references.first(where: { $0.filename == component.filename }) else {
            throw OfficialDocumentPackageError.missingFileReference(component.filename)
        }
        let algorithm = reference.algorithm.lowercased().replacingOccurrences(of: "-", with: "")
        guard algorithm == "sha256" else {
            throw OfficialDocumentPackageError.unsupportedHashAlgorithm(reference.algorithm)
        }
        let expected = reference.digest.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard expected.count == 64,
              expected.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw OfficialDocumentPackageError.malformedHash(component.filename)
        }
        let actual = sha256(component.data)
        guard actual == expected else { throw OfficialDocumentPackageError.hashMismatch(component.filename) }
        return actual
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A non-validating XML reader with external entities disabled and internal
/// entity declarations refused. It indexes text by full element path so the
/// sender's `orgid` cannot be confused with a receiver's `orgid`.
private final class ParsedXML: NSObject, XMLParserDelegate {
    private struct Frame {
        let name: String
        var text = ""
    }

    private struct FileBuilder {
        var filename = ""
        var algorithm = ""
        var digest = ""
        var note: String?
    }

    let rootName: String
    private var stack: [Frame] = []
    private var values: [String: [String]] = [:]
    private var attributes: [String: [[String: String]]] = [:]
    private var elementCounts: [String: Int] = [:]
    private var currentFile: FileBuilder?
    private var parsedFiles: [FileBuilder] = []
    private var failure: Error?

    init(_ component: OfficialDocumentImportPayload.Component,
         expectedRoot: String?,
         maximumBytes: Int) throws {
        guard component.data.count <= maximumBytes else {
            throw OfficialDocumentPackageError.componentTooLarge(component.filename)
        }
        if let utf8 = String(data: component.data, encoding: .utf8),
           utf8.range(of: "<!ENTITY", options: .caseInsensitive) != nil {
            throw OfficialDocumentPackageError.unsafeXML(component.filename)
        }

        let parser = XMLParser(data: component.data)
        parser.shouldResolveExternalEntities = false
        var capturedRoot = ""
        let rootCapture = RootCapturingDelegate { capturedRoot = $0 }
        parser.delegate = rootCapture
        guard parser.parse(), !capturedRoot.isEmpty else {
            throw OfficialDocumentPackageError.malformedXML(component.filename)
        }
        if let expectedRoot, capturedRoot != expectedRoot {
            throw OfficialDocumentPackageError.unexpectedRoot(expected: expectedRoot,
                                                               actual: capturedRoot)
        }
        rootName = capturedRoot
        super.init()

        let indexingParser = XMLParser(data: component.data)
        indexingParser.shouldResolveExternalEntities = false
        indexingParser.delegate = self
        guard indexingParser.parse(), failure == nil else {
            throw failure ?? OfficialDocumentPackageError.malformedXML(component.filename)
        }
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        stack.append(Frame(name: elementName))
        if elementName == "file" {
            currentFile = FileBuilder()
        } else if elementName == "hash", currentFile != nil {
            currentFile?.algorithm = attributeDict["algorithm"] ?? ""
        }
        let path = stack.map(\.name).joined(separator: "/")
        attributes[path, default: []].append(attributeDict)
        elementCounts[path, default: 0] += 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in stack.indices { stack[index].text += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let frame = stack.last, frame.name == elementName else {
            failure = OfficialDocumentPackageError.malformedXML(elementName)
            parser.abortParsing()
            return
        }
        let path = stack.map(\.name).joined(separator: "/")
        let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if !text.isEmpty { values[path, default: []].append(text) }
        if currentFile != nil {
            switch elementName {
            case "filename":
                currentFile?.filename = text
            case "hash":
                currentFile?.digest = text
            case "note":
                currentFile?.note = text.isEmpty ? nil : text
            case "file":
                if let currentFile { parsedFiles.append(currentFile) }
                currentFile = nil
            default:
                break
            }
        }
        stack.removeLast()
    }

    func firstValue(endingIn suffix: [String]) -> String? {
        let ending = suffix.joined(separator: "/")
        return values.first(where: { key, _ in key == ending || key.hasSuffix("/" + ending) })?
            .value.first
    }

    func firstAttribute(endingIn suffix: [String], named name: String) -> String? {
        let ending = suffix.joined(separator: "/")
        return attributes.first(where: { key, _ in key == ending || key.hasSuffix("/" + ending) })?
            .value.first?[name]
    }

    func count(elementsEndingIn suffix: [String]) -> Int {
        let ending = suffix.joined(separator: "/")
        return elementCounts.filter { key, _ in key == ending || key.hasSuffix("/" + ending) }
            .values.reduce(0, +)
    }

    func fileReferences() throws -> [OfficialDocumentPackage.FileReference] {
        guard !parsedFiles.isEmpty,
              parsedFiles.allSatisfy({ !$0.filename.isEmpty && !$0.digest.isEmpty }) else {
            throw OfficialDocumentPackageError.missingEnvelopeField("filelist")
        }
        return parsedFiles.map { file in
            OfficialDocumentPackage.FileReference(
                filename: file.filename,
                algorithm: file.algorithm,
                digest: file.digest,
                note: file.note)
        }
    }
}

private final class RootCapturingDelegate: NSObject, XMLParserDelegate {
    private let capture: (String) -> Void
    private var didCapture = false

    init(capture: @escaping (String) -> Void) { self.capture = capture }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard !didCapture else { return }
        didCapture = true
        capture(elementName)
    }
}

#if DEBUG
enum OfficialDocumentSyntheticFixture {
    static func make(applicationID: String = "SYNTHETIC-20260831-0001",
                     subject: String = "合成測試：防災演練通知",
                     receivedAt: Date = Date()) -> OfficialDocumentImportPayload {
        let document = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <函>
          <發文機關><全銜>電子公文接收站合成測試機關</全銜></發文機關>
          <發文日期>中華民國115年8月31日</發文日期>
          <發文字號>合成測試字第0001號</發文字號>
          <速別>普通件</速別>
          <主旨><文字>\(subject)</文字></主旨>
          <說明><段落><文字>這是有備而來的本機合成資料，不是政府機關送達的正式公文。</文字></段落></說明>
        </函>
        """.utf8)
        let encryptedSwitch = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <g2b2c-encrypt-list>
          <receivercardlist><receiverobject><orgid>SYNTHETIC</orgid>
            <cardlist type="GCA"><cardnum>SYNTHETIC-ONLY</cardnum>
              <EncryptedData Method="RSA" MimeType="base64"><CipherData>U1lOVEhFVElD</CipherData></EncryptedData>
            </cardlist>
          </receiverobject></receivercardlist>
        </g2b2c-encrypt-list>
        """.utf8)
        let documentHash = OfficialDocumentPackageParser.sha256(document)
        let encryptedSwitchHash = OfficialDocumentPackageParser.sha256(encryptedSwitch)
        let envelope = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <g2b2c-envelope>
          <senderinfo><object type="addressbook">
            <orgid>SYNTHETIC-AGENCY</orgid><unitid></unitid>
            <orgname>電子公文接收站合成測試機關</orgname>
          </object></senderinfo>
          <receiverlist><object type="addressbook">
            <orgid>SYNTHETIC-RECIPIENT</orgid><orgname>合成測試收件者</orgname>
          </object></receiverlist>
          <serviceid>SYNTHETIC-G2C</serviceid>
          <applicationid>\(applicationID)</applicationid>
          <subject>\(subject)</subject>
          <expiredate>2026-09-30 23:59:59</expiredate>
          <filelist><others>
            <file needsig="true"><filename>synthetic.di</filename><hash algorithm="SHA256">\(documentHash)</hash><note>合成 DI 本文</note></file>
            <file needsig="true"><filename>synthetic.esw</filename><hash algorithm="SHA256">\(encryptedSwitchHash)</hash><note>合成 ESW 邊界資料</note></file>
          </others></filelist>
        </g2b2c-envelope>
        """.utf8)
        return OfficialDocumentImportPayload(
            envelope: .init(filename: "synthetic.en", data: envelope),
            document: .init(filename: "synthetic.di", data: document),
            encryptedSwitch: .init(filename: "synthetic.esw", data: encryptedSwitch),
            receivedAt: receivedAt)
    }
}
#endif
