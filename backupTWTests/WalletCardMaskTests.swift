//
//  WalletCardMaskTests.swift
//  backupTWTests
//
//  The one promise a card face makes: a full 統一編號 / 駕照號碼 / 門號 / 生日
//  never reaches a glanceable surface. It is a pure function, so it is tested as
//  one.
//

import Foundation
import Testing
@testable import backupTW

struct WalletCardMaskTests {

    // MARK: - The shape the design asks for

    @Test("a national ID number keeps its first two and last one, masks the rest")
    func idNumberMask() {
        // TWDIW's own published sample person's id_number.
        #expect(WalletCardMask.masked("A234567890") == "A2●●●●●●●0")
        // The design's illustrative 王小明 number is the same 2 + 7 + 1 shape.
        #expect(WalletCardMask.masked("A123456788") == "A1●●●●●●●8")
    }

    @Test("a driving-licence number is masked the same way and never shown whole")
    func licenceNumberMask() {
        let raw = "L123456785"
        let masked = WalletCardMask.masked(raw)
        #expect(masked == "L1●●●●●●●5")
        #expect(!masked.contains("23456"))
        #expect(masked != raw)
    }

    @Test("a phone number is masked and never shown whole")
    func phoneNumberMask() {
        let raw = "0912345678"
        let masked = WalletCardMask.masked(raw)
        // 2 + n + 1, so the subscriber digits in the middle are gone.
        #expect(masked == "09●●●●●●●8")
        #expect(!masked.contains("34567"))
        #expect(masked != raw)
    }

    // MARK: - The invariant: never reveal the whole value

    @Test("a value too short to keep both ends is masked entirely")
    func shortValueIsFullyMasked() {
        // leading + trailing == count would otherwise show every character.
        #expect(WalletCardMask.masked("ABC") == "●●●")
        #expect(WalletCardMask.masked("12") == "●●")
        #expect(WalletCardMask.masked("7") == "●")
        // The kept-ends must not equal the source for any short value.
        for raw in ["A1", "AB2", "1234"] where raw.count <= 3 {
            #expect(WalletCardMask.masked(raw) != raw)
        }
    }

    @Test("an empty value stays empty")
    func emptyStaysEmpty() {
        #expect(WalletCardMask.masked("") == "")
    }

    @Test("the middle is always fully hidden for a long value")
    func middleIsFullyHidden() {
        let masked = WalletCardMask.masked("A234567890")
        let middle = masked.dropFirst(2).dropLast(1)
        #expect(middle.allSatisfy { $0 == WalletCardMask.dot })
    }

    // MARK: - Which keys are sensitive

    @Test(arguments: ["id_number", "unifiedNo", "nationalId", "roc_birthday",
                      "birthdate", "msisdn", "mobile_no", "phone", "licenseNumber",
                      "passportNo"])
    func sensitiveKeysAreCaught(_ key: String) {
        #expect(WalletCardMask.isSensitiveKey(key))
    }

    @Test(arguments: ["name", "nationality", "gender", "car_type", "issuer"])
    func nonSensitiveKeysAreNot(_ key: String) {
        // A name in particular must never be treated as maskable — a document
        // cannot withhold it, so pretending to would be a false promise.
        #expect(!WalletCardMask.isSensitiveKey(key))
    }
}
