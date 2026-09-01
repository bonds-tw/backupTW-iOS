//
//  MyDataAutofillProfileTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

struct MyDataAutofillProfileTests {

    @Test func validatesAndNormalizesTheTwoRememberedValues() throws {
        let gregorian = try MyDataAutofillProfile(
            nationalIDNumber: " a123456789 ", birthDate: "1988/01/01")
        #expect(gregorian.nationalIDNumber == "A123456789")
        #expect(gregorian.birthDate == "19880101")

        let roc = try MyDataAutofillProfile(
            nationalIDNumber: "A123456789", birthDate: "0770101")
        #expect(roc.birthDate == "19880101")
    }

    @Test func refusesInvalidIdentityAndCalendarValues() {
        #expect(throws: MyDataAutofillProfile.ValidationError.invalidNationalID) {
            try MyDataAutofillProfile(nationalIDNumber: "A123456788", birthDate: "19880101")
        }
        #expect(throws: MyDataAutofillProfile.ValidationError.invalidBirthDate) {
            try MyDataAutofillProfile(nationalIDNumber: "A123456789", birthDate: "19880231")
        }
    }

    @Test func autofillScriptTargetsRecognisedEmptyInputsOnly() throws {
        let profile = try MyDataAutofillProfile(
            nationalIDNumber: "A123456789", birthDate: "19880101")
        let script = MyDataAutofillScript.script(for: profile)
        #expect(script.contains("A123456789"))
        #expect(script.contains("19880101"))
        #expect(script.contains("if (!value || input.value) continue"))
        #expect(script.contains("input.dispatchEvent(new Event('change'"))
    }
}
