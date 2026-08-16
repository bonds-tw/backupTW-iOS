//
//  KeychainEnumerationMeasurement.swift
//  backupTWTests
//
//  Measuring the assumption the whole per-card key design rests on.
//

import CryptoKit
import Foundation
import Security
import Testing
@testable import backupTW

/// # What is being measured, and why it is a gate rather than a detail
///
/// The per-card key design replaces `IdentityReset`'s single known tag with a
/// **Keychain enumeration**: ask the Keychain what keys this app has, and delete
/// everything in the namespace. That is the right shape — a remembered list
/// drifts, and a key missing from the list can never be deleted while the user
/// believes it is gone. This project has shipped that exact defect once already
/// ("身分活得比抹除久", M1).
///
/// But the enumeration rests on an assumption nobody has measured:
///
/// > `SecItemCopyMatching` with `kSecMatchLimitAll` returns Secure Enclave keys,
/// > and their attributes come back carrying `kSecAttrApplicationTag` and
/// > `kSecAttrCreationDate`.
///
/// The existing code has never issued such a query — `DeviceKey.loadPrivateKey`
/// is always `kSecMatchLimitOne` with an exact tag match. Token-backed items are
/// well known to carry a different attribute set from ordinary keychain items,
/// and **missing one key is silent**: the sweep deletes nothing, the re-check
/// finds nothing, verification passes, and the user is told everything is gone.
///
/// So: measure, then write. This file is the measurement. It prints its findings
/// rather than only asserting them, because the numbers decide the design and a
/// green tick would not carry them.
///
/// ⚠️ **On the simulator there is no Secure Enclave**, so the interesting half of
/// this cannot be answered there. The suite says which environment it ran in and
/// refuses to let a simulator run stand in for the answer.
@Suite("Keychain 列舉：一卡一金鑰的前提")
struct KeychainEnumerationMeasurement {

    /// A namespace nothing else uses, so the sweep in this file cannot touch a
    /// real identity even if every assumption below turns out wrong.
    static let namespace = "tw.bonds.backupTW.measurement."

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: - The query under test

    /// Everything this app can see, with attributes and references.
    ///
    /// No `kSecAttrApplicationTag` in the query: the Keychain only does equality
    /// on that attribute, so prefix filtering has to happen in-process. Whether
    /// the attribute even comes back is one of the things being measured.
    private static func enumerateAll() -> (status: OSStatus, items: [[String: Any]]) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return (status, [])
        }
        return (status, items)
    }

    private static func tag(of item: [String: Any]) -> String? {
        guard let data = item[kSecAttrApplicationTag as String] as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func makeKey(tag: String, secureEnclave: Bool) throws -> SecKey {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        if secureEnclave {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .privateKeyUsage, &accessError) else {
                throw MeasurementError.accessControl
            }
            privateAttributes.removeValue(forKey: kSecAttrAccessible as String)
            privateAttributes[kSecAttrAccessControl as String] = access
        }
        attributes[kSecPrivateKeyAttrs as String] = privateAttributes

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MeasurementError.creation(String(describing: error?.takeRetainedValue()))
        }
        return key
    }

    private static func deleteEverythingInNamespace() -> Int {
        let (_, items) = enumerateAll()
        var deleted = 0
        for item in items where (tag(of: item) ?? "").hasPrefix(namespace) {
            guard let reference = item[kSecValueRef as String] else { continue }
            if SecItemDelete([kSecValueRef as String: reference] as CFDictionary) == errSecSuccess {
                deleted += 1
            }
        }
        return deleted
    }

    enum MeasurementError: Error { case accessControl, creation(String) }

    // MARK: - The measurement

    @Test func measureWhatEnumerationCanSee() throws {
        _ = Self.deleteEverythingInNamespace()

        var report: [String] = []
        report.append("環境：\(Self.isSimulator ? "模擬器（無 Secure Enclave）" : "實機")")

        let softwareTag = Self.namespace + "software"
        let enclaveTag = Self.namespace + "enclave"

        _ = try Self.makeKey(tag: softwareTag, secureEnclave: false)
        report.append("software 金鑰：建立成功")

        var enclaveCreated = false
        do {
            _ = try Self.makeKey(tag: enclaveTag, secureEnclave: true)
            enclaveCreated = true
            report.append("Secure Enclave 金鑰：建立成功")
        } catch {
            report.append("Secure Enclave 金鑰：建立失敗（\(error)）")
        }

        let (status, items) = Self.enumerateAll()
        report.append("SecItemCopyMatching(kSecMatchLimitAll) → OSStatus \(status)，共 \(items.count) 個 item")

        let ours = items.filter { (Self.tag(of: $0) ?? "").hasPrefix(Self.namespace) }
        report.append("其中屬於本次量測命名空間的：\(ours.count)")

        // The three questions.
        var sawSoftware = false, sawEnclave = false
        for item in ours {
            let itemTag = Self.tag(of: item) ?? "(tag 讀不出來)"
            let created = item[kSecAttrCreationDate as String] as? Date
            let tokenID = item[kSecAttrTokenID as String] as? String
            let backing = tokenID == (kSecAttrTokenIDSecureEnclave as String) ? "SecureEnclave" : "keychain"
            if itemTag == softwareTag { sawSoftware = true }
            if itemTag == enclaveTag { sawEnclave = true }
            report.append("  · tag=\(itemTag)  backing=\(backing)  "
                          + "kSecAttrCreationDate=\(created.map(String.init(describing:)) ?? "nil")  "
                          + "kSecAttrTokenID=\(tokenID ?? "nil")")
        }

        report.append("問題一：列舉看得到 software 金鑰嗎？ → \(sawSoftware ? "看得到" : "看不到")")
        report.append("問題二：列舉看得到 Secure Enclave 金鑰嗎？ → "
                      + (enclaveCreated ? (sawEnclave ? "看得到" : "❌ 看不到") : "（沒建成，無法回答）"))
        let tagsReadable = ours.allSatisfy { Self.tag(of: $0) != nil }
        let datesPresent = ours.allSatisfy { $0[kSecAttrCreationDate as String] != nil }
        report.append("問題三：attributes 帶得回 tag 嗎？ → \(tagsReadable ? "全部帶得回" : "❌ 有的帶不回")")
        report.append("問題四：attributes 帶得回 kSecAttrCreationDate 嗎？ → "
                      + (datesPresent ? "全部帶得回" : "❌ 有的帶不回"))

        let swept = Self.deleteEverythingInNamespace()
        let (_, after) = Self.enumerateAll()
        let leftovers = after.filter { (Self.tag(of: $0) ?? "").hasPrefix(Self.namespace) }.count
        report.append("問題五：用 kSecValueRef 刪得掉嗎？ → 刪掉 \(swept) 把，掃完剩 \(leftovers) 把")

        print("""

        ========== Keychain 列舉量測 ==========
        \(report.joined(separator: "\n"))
        ======================================

        """)

        // Assertions, so a regression is a failure rather than a paragraph
        // nobody reads. The Secure Enclave half is only asserted where an
        // enclave exists.
        #expect(status == errSecSuccess)
        #expect(sawSoftware, "列舉看不到自己剛建的 software 金鑰")
        #expect(tagsReadable, "有 item 的 kSecAttrApplicationTag 讀不出來")
        #expect(leftovers == 0, "掃完之後命名空間裡還有殘留")
        if enclaveCreated {
            #expect(sawEnclave, "列舉看不到 Secure Enclave 金鑰——一卡一金鑰的抹除會靜默漏掉它")
        }
    }

    /// The measurement above is only worth something on hardware. This makes the
    /// gap loud instead of letting a green simulator run be mistaken for an
    /// answer.
    @Test func aSimulatorRunDoesNotAnswerTheSecureEnclaveQuestion() {
        if Self.isSimulator {
            print("⚠️ 這一輪在模擬器上跑，Secure Enclave 那一半沒有被回答。實機重跑才算數。")
        }
        #expect(Bool(true))
    }
}
