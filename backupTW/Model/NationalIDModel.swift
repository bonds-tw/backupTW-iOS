//
//  NationalIDModel.swift
//  backupTW
//
//  Created by Denken Chen on 2025/8/14.
//

import Foundation

struct NationalIDModel {
    let nationality: String?
    let unifiedNo: String?
    let name: String?
    let birthdate: String?
    let addressOfHousehold: String?
}

extension NationalIDModel {

    /// Parses the national ID data downloaded from MyData.
    ///
    /// The layout has already shifted once — addresses turned out to span
    /// multiple lines — so fields are located by their label rather than by a
    /// fixed line index, and every lookup yields nil instead of trapping. A
    /// document we don't recognise has to surface as a processing error the
    /// user can retry, not as a crash on the one flow that currently works.
    static func parse(fromPDFText text: String) -> NationalIDModel? {
        let lines = text.components(separatedBy: "\n")

        let unifiedNo = value(of: "統號", in: lines)
        let name = value(of: "姓名", in: lines)
        let birthdate = value(of: "出生日期", in: lines)

        // If none of the three single-line fields are present this isn't the
        // document we were expecting — decrypting with the right password can
        // still hand us the wrong file.
        guard unifiedNo != nil || name != nil || birthdate != nil else {
            return nil
        }

        return NationalIDModel(nationality: "中華民國（臺灣）",
                               unifiedNo: unifiedNo,
                               name: name,
                               birthdate: birthdate,
                               addressOfHousehold: addressOfHousehold(in: lines))
    }

    // MARK: - Field extraction

    /// Both the full-width and half-width colon appear in the same document.
    private static func valueAfterLabel(_ label: String, in fragment: String) -> String? {
        guard let labelRange = fragment.range(of: label) else { return nil }
        let remainder = fragment[labelRange.upperBound...]
        guard let separator = remainder.firstIndex(where: { $0 == "：" || $0 == ":" }) else {
            return nil
        }
        let value = remainder[remainder.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func value(of label: String, in lines: [String]) -> String? {
        for line in lines {
            // A single line can carry two fields, e.g. "統號：A123456789 姓名:王小明".
            for fragment in line.components(separatedBy: " ") where fragment.contains(label) {
                if let value = valueAfterLabel(label, in: fragment) {
                    return value
                }
            }
            if let value = valueAfterLabel(label, in: line) {
                return value
            }
        }
        return nil
    }

    /// The address label carries the first segment; any remaining lines are
    /// continuations of it. The final component is an artifact of splitting the
    /// page text and is dropped.
    private static func addressOfHousehold(in lines: [String]) -> String? {
        guard let labelIndex = lines.firstIndex(where: { $0.contains("戶籍地址") }) else {
            return nil
        }

        var segments: [String] = []
        if let head = valueAfterLabel("戶籍地址", in: lines[labelIndex]) {
            segments.append(head)
        }

        let continuationStart = labelIndex + 1
        let continuationEnd = max(continuationStart, lines.count - 1)
        segments.append(contentsOf: lines[continuationStart..<continuationEnd]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })

        let address = segments.joined()
        return address.isEmpty ? nil : address
    }
}
