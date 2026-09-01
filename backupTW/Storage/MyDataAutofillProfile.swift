//
//  MyDataAutofillProfile.swift
//  backupTW
//
//  Explicit, on-device-only help for the two values MyData asks for repeatedly.
//

import Foundation
import Security

struct MyDataAutofillProfile: Codable, Equatable, Sendable {
    let nationalIDNumber: String
    /// Gregorian yyyyMMdd, matching MyData's current sign-in hint.
    let birthDate: String

    init(nationalIDNumber: String, birthDate: String) throws {
        let id = nationalIDNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValidTaiwanID(id) else { throw ValidationError.invalidNationalID }
        guard let birth = Self.normalizedBirthDate(birthDate) else {
            throw ValidationError.invalidBirthDate
        }
        self.nationalIDNumber = id
        self.birthDate = birth
    }

    enum ValidationError: LocalizedError {
        case invalidNationalID, invalidBirthDate

        var errorDescription: String? {
            switch self {
            case .invalidNationalID:
                return NSLocalizedString("Enter a valid Taiwan national ID number.", comment: "MyData profile validation")
            case .invalidBirthDate:
                return NSLocalizedString("Enter the birth date as YYYYMMDD, for example 19880101.", comment: "MyData profile validation")
            }
        }
    }

    static func isValidTaiwanID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[0] >= 65, bytes[0] <= 90,
              bytes[1] == 49 || bytes[1] == 50,
              bytes.dropFirst(2).allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return false }
        let codes = [10, 11, 12, 13, 14, 15, 16, 17, 34, 18, 19, 20, 21,
                     22, 35, 23, 24, 25, 26, 27, 28, 29, 32, 30, 31, 33]
        let code = codes[Int(bytes[0] - 65)]
        var sum = code / 10 + (code % 10) * 9
        for index in 1...8 { sum += Int(bytes[index] - 48) * (9 - index) }
        sum += Int(bytes[9] - 48)
        return sum.isMultiple(of: 10)
    }

    static func normalizedBirthDate(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        let gregorian: String
        if digits.count == 7, let rocYear = Int(digits.prefix(3)) {
            gregorian = String(format: "%04d%@", rocYear + 1911, String(digits.dropFirst(3)))
        } else if digits.count == 8 {
            gregorian = digits
        } else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        formatter.isLenient = false
        guard let date = formatter.date(from: gregorian), date <= Date() else { return nil }
        return formatter.string(from: date)
    }
}

enum MyDataAutofillProfileStore {
    private static let service = "tw.bonds.backupTW.mydata-autofill"
    private static let account = "holder"

    static func load() -> MyDataAutofillProfile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(MyDataAutofillProfile.self, from: data)
    }

    static func save(_ profile: MyDataAutofillProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.status(updated) }
        var add = key
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private enum KeychainError: Error { case status(OSStatus) }
}

/// A script rather than browser password storage: it only ever runs after Swift
/// has verified the top-level host is exactly MyData's official host. It fills
/// recognised identity/birthday inputs and emits normal input/change events so
/// the site's own validation remains in charge.
enum MyDataAutofillScript {
    static func script(for profile: MyDataAutofillProfile) -> String {
        let id = quoted(profile.nationalIDNumber)
        let birth = quoted(profile.birthDate)
        return """
        (() => {
          const values = { id: \(id), birth: \(birth) };
          let filled = 0;
          for (const input of document.querySelectorAll('input')) {
            if (input.disabled || input.readOnly || ['hidden','password','file'].includes(input.type)) continue;
            const labels = input.labels ? Array.from(input.labels).map(label => label.innerText) : [];
            const field = input.closest('.form-group, .form-item, .field, .row');
            const fieldLabel = field?.querySelector('label')?.innerText || '';
            const hint = [input.id, input.name, input.placeholder, input.getAttribute('aria-label'), ...labels, fieldLabel]
              .filter(Boolean).join(' ').toLowerCase();
            let value = null;
            if (/生日|出生|birth|yyyy.?mm.?dd|19880101|0770101/.test(hint)) value = values.birth;
            else if (/身分證|身分證字號|national.?id|citizen.?id|pid/.test(hint)) value = values.id;
            if (!value || input.value) continue;
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
            setter ? setter.call(input, value) : (input.value = value);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            filled++;
          }
          return filled;
        })();
        """
    }

    private static func quoted(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
