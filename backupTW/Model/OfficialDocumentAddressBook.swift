//
//  OfficialDocumentAddressBook.swift
//  backupTW
//
//  Public G2B2C address-book evidence. Directory membership is deliberately
//  kept separate from per-delivery sender authentication.
//

import CryptoKit
import Foundation

enum OfficialDocumentAddressBookError: Error, Equatable {
    case componentTooLarge
    case invalidUTF8
    case malformedCSV(row: Int)
    case unexpectedHeader
    case duplicateOrganizationID(String)
    case inactiveOrganization(String)
    case senderNotListed(String)
    case senderNameMismatch(expected: String, actual: String)
}

struct OfficialDocumentAddressBookRecord: Equatable, Sendable {
    let organizationID: String
    let organizationName: String
    let statusCode: String
    let updatedAtText: String
}

/// Evidence that an EN sender name and identifier appeared in one exact public
/// address-book snapshot. It is not evidence that the sender created, signed or
/// transported a particular package.
struct OfficialDocumentDirectoryEvidence: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable {
        case activeDirectoryListingOnly
    }

    let scope: Scope
    let organizationID: String
    let organizationName: String
    let recordUpdatedAtText: String
    let directorySHA256: String
    let checkedAt: Date
}

struct OfficialDocumentAddressBookSnapshot: Equatable, Sendable {
    static let sourceURL = URL(
        string: "https://www.good.nat.gov.tw/regcenter/pub/addressbook/file/all_active_utf8.csv")!

    private static let maximumBytes = 5 * 1_024 * 1_024
    private static let maximumRows = 100_000
    private static let expectedHeader = ["ORGID", "ORGNAME", "STATUSCODE", "UPDATETIME"]

    let source: URL
    let checkedAt: Date
    let sha256: String
    let records: [String: OfficialDocumentAddressBookRecord]

    init(data: Data,
         source: URL = Self.sourceURL,
         checkedAt: Date = Date()) throws {
        guard data.count <= Self.maximumBytes else {
            throw OfficialDocumentAddressBookError.componentTooLarge
        }
        let rows = try Self.parseCSV(data)
        guard let first = rows.first else {
            throw OfficialDocumentAddressBookError.unexpectedHeader
        }
        var header = first
        if !header.isEmpty {
            header[0] = header[0].replacingOccurrences(of: "\u{feff}", with: "")
        }
        guard header == Self.expectedHeader else {
            throw OfficialDocumentAddressBookError.unexpectedHeader
        }
        guard rows.count - 1 <= Self.maximumRows else {
            throw OfficialDocumentAddressBookError.componentTooLarge
        }

        var records: [String: OfficialDocumentAddressBookRecord] = [:]
        for (offset, row) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2
            guard row.count == Self.expectedHeader.count else {
                throw OfficialDocumentAddressBookError.malformedCSV(row: rowNumber)
            }
            let organizationID = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let organizationName = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let statusCode = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let updatedAtText = row[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !organizationID.isEmpty,
                  organizationID.utf8.count <= 64,
                  organizationID.utf8.allSatisfy({ byte in
                      (0x30...0x39).contains(byte) ||
                          (0x41...0x5a).contains(byte) ||
                          (0x61...0x7a).contains(byte) || byte == 0x2d || byte == 0x5f
                  }),
                  !organizationName.isEmpty,
                  organizationName.utf8.count <= 512,
                  !updatedAtText.isEmpty,
                  updatedAtText.utf8.count <= 64 else {
                throw OfficialDocumentAddressBookError.malformedCSV(row: rowNumber)
            }
            // The government file currently includes T, D and F records even
            // though its filename says `all_active`. Preserve the published
            // status here and require T only when a sender claim is checked.
            guard ["T", "D", "F"].contains(statusCode) else {
                throw OfficialDocumentAddressBookError.malformedCSV(row: rowNumber)
            }
            guard records[organizationID] == nil else {
                throw OfficialDocumentAddressBookError.duplicateOrganizationID(organizationID)
            }
            records[organizationID] = OfficialDocumentAddressBookRecord(
                organizationID: organizationID,
                organizationName: organizationName,
                statusCode: statusCode,
                updatedAtText: updatedAtText)
        }
        guard !records.isEmpty else {
            throw OfficialDocumentAddressBookError.unexpectedHeader
        }

        self.source = source
        self.checkedAt = checkedAt
        self.sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        self.records = records
    }

    func evidence(for sender: OfficialDocumentPackage.Party) throws
        -> OfficialDocumentDirectoryEvidence {
        guard let record = records[sender.organizationID] else {
            throw OfficialDocumentAddressBookError.senderNotListed(sender.organizationID)
        }
        guard record.statusCode == "T" else {
            throw OfficialDocumentAddressBookError.inactiveOrganization(sender.organizationID)
        }
        guard record.organizationName == sender.organizationName else {
            throw OfficialDocumentAddressBookError.senderNameMismatch(
                expected: record.organizationName,
                actual: sender.organizationName)
        }
        return OfficialDocumentDirectoryEvidence(
            scope: .activeDirectoryListingOnly,
            organizationID: record.organizationID,
            organizationName: record.organizationName,
            recordUpdatedAtText: record.updatedAtText,
            directorySHA256: sha256,
            checkedAt: checkedAt)
    }

    /// RFC 4180-shaped parser with a strict four-column schema above. Parsing
    /// bytes instead of splitting on commas preserves quoted organization names
    /// and rejects unterminated quotes or data after a closing quote.
    private static func parseCSV(_ data: Data) throws -> [[String]] {
        let bytes = Array(data)
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var closedQuote = false
        var index = 0

        func decodeField(rowNumber: Int) throws -> String {
            guard let value = String(bytes: field, encoding: .utf8) else {
                throw OfficialDocumentAddressBookError.invalidUTF8
            }
            return value
        }

        func finishField(rowNumber: Int) throws {
            row.append(try decodeField(rowNumber: rowNumber))
            field.removeAll(keepingCapacity: true)
            closedQuote = false
        }

        func finishRow() throws {
            try finishField(rowNumber: rows.count + 1)
            if row.count == 1, row[0].isEmpty {
                row.removeAll(keepingCapacity: true)
                return
            }
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 0x22 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        field.append(0x22)
                        index += 2
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else {
                    field.append(byte)
                }
                index += 1
                continue
            }

            if closedQuote, byte != 0x2c, byte != 0x0a, byte != 0x0d {
                throw OfficialDocumentAddressBookError.malformedCSV(row: rows.count + 1)
            }
            switch byte {
            case 0x22:
                guard field.isEmpty, !closedQuote else {
                    throw OfficialDocumentAddressBookError.malformedCSV(row: rows.count + 1)
                }
                quoted = true
            case 0x2c:
                try finishField(rowNumber: rows.count + 1)
            case 0x0a:
                try finishRow()
            case 0x0d:
                if index + 1 >= bytes.count || bytes[index + 1] != 0x0a {
                    try finishRow()
                }
            default:
                field.append(byte)
            }
            index += 1
        }

        guard !quoted else {
            throw OfficialDocumentAddressBookError.malformedCSV(row: rows.count + 1)
        }
        if !field.isEmpty || !row.isEmpty || closedQuote {
            try finishRow()
        }
        return rows
    }
}
