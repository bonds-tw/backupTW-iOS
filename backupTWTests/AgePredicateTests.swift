//
//  AgePredicateTests.swift
//  backupTWTests
//
//  Deriving 「滿 18 歲」 from a 民國 birthdate, and refusing to guess.
//

import Foundation
import Testing
@testable import backupTW

struct ROCDateTests {

    /// The one format that has actually been seen: a real MyData download,
    /// 2026-08-09, rendered by the app as `民國 083年03月06日`.
    @Test func parsesTheFormatMyDataActuallyWrites() throws {
        let date = try #require(ROCDate.parse("民國 083年03月06日"))

        #expect(date.year == 83)
        #expect(date.month == 3)
        #expect(date.day == 6)
        #expect(date.gregorianYear == 1994)
    }

    /// Spacing and the 民國 prefix are formatting; the 年/月/日 markers are the
    /// format. Tolerating the first is not guessing, tolerating the absence of
    /// the second would be.
    @Test(arguments: ["民國83年3月6日", "民國 83 年 3 月 6 日", "83年03月06日", " 民國083年03月06日 "])
    func toleratesSpacingAndAnOptionalPrefix(_ raw: String) throws {
        let date = try #require(ROCDate.parse(raw))
        #expect(date.gregorianYear == 1994)
        #expect((date.month, date.day) == (3, 6))
    }

    /// The project's own parsing fixtures use `0700101` — a bare digit run that
    /// the real download does not look like. Whatever it is, it is not a format
    /// this can read, and reading it *by guessing* a YYYMMDD layout is how a
    /// wrong birthday becomes a wrong age.
    @Test(arguments: ["0700101", "", "民國", "1994-03-06", "民國 年 月 日", "民國 83年13月06日"])
    func refusesAnythingItHasNotSeen(_ raw: String) {
        #expect(ROCDate.parse(raw) == nil, "\(raw.debugDescription) should not parse")
    }

    /// 民國 1 is 1912. Off by one here shifts every age by a year.
    @Test func theEpochIsFixedAt1911() throws {
        let first = try #require(ROCDate.parse("民國 001年01月01日"))
        #expect(first.gregorianYear == 1912)
    }
}

struct AgePredicateTests {

    private static func taipei(_ year: Int, _ month: Int, _ day: Int) -> Date {
        ROCDate.taipeiCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The boundary is the birthday itself, not the day after. Off by one here
    /// refuses a legitimate adult on the one day they are most likely to be
    /// asked.
    @Test func thePredicateTurnsTrueOnTheBirthdayItself() {
        let born = Self.taipei(1994, 3, 6)

        #expect(AgePredicate.reached(18, bornOn: born, asOf: Self.taipei(2012, 3, 5)) == false)
        #expect(AgePredicate.reached(18, bornOn: born, asOf: Self.taipei(2012, 3, 6)))
        #expect(AgePredicate.reached(18, bornOn: born, asOf: Self.taipei(2012, 3, 7)))
    }

    /// Calendar years, not 18 × 365.25 days. The two differ, and the day they
    /// differ on is somebody's birthday.
    ///
    /// A leap-day birth reaches majority on **28 February** in a non-leap year,
    /// not 1 March. That is what `Calendar` does — measured, after this test
    /// first asserted 1 March and was wrong — and it is also the conventional
    /// reading here: 民法 §124 counts age from the day of birth, and the
    /// established treatment of a 2/29 birthday in a common year is the last day
    /// of February. Rounding the other way would refuse a legitimate adult for
    /// one day every four years, and only ever people born on 29 February.
    @Test func aLeapDayBirthdayReachesMajorityOnTheLastDayOfFebruary() {
        let born = Self.taipei(2000, 2, 29)

        #expect(AgePredicate.reached(18, bornOn: born, asOf: Self.taipei(2018, 2, 27)) == false)
        #expect(AgePredicate.reached(18, bornOn: born, asOf: Self.taipei(2018, 2, 28)))
        #expect(AgePredicate.reached(18, bornOn: born, asOf: Self.taipei(2018, 3, 1)))
    }

    /// The time of day must not decide it. Evaluated at 23:00 on the birthday in
    /// a zone west of Taipei, a naive comparison flips the answer.
    @Test func theAnswerDoesNotDependOnTheHour() {
        let born = Self.taipei(1994, 3, 6)
        let calendar = ROCDate.taipeiCalendar
        let morning = calendar.date(from: DateComponents(year: 2012, month: 3, day: 6, hour: 0, minute: 1))!
        let night = calendar.date(from: DateComponents(year: 2012, month: 3, day: 6, hour: 23, minute: 59))!

        #expect(AgePredicate.reached(18, bornOn: born, asOf: morning))
        #expect(AgePredicate.reached(18, bornOn: born, asOf: night))
    }

    // MARK: The claim

    @Test func anAdultsClaimIsTrueAndAMinorsIsFalse() {
        let now = Self.taipei(2026, 8, 10)

        #expect(AgePredicate.claimValue(birthdate: "民國 083年03月06日", asOf: now) == "true")
        #expect(AgePredicate.claimValue(birthdate: "民國 110年03月06日", asOf: now) == "false")
    }

    /// An unreadable birthdate means *unknown*, and unknown must not become
    /// "false" — that would be asserting somebody is a minor because the parser
    /// did not recognise their record.
    @Test(arguments: [nil, "", "0700101", "not a date"])
    func anUnreadableBirthdateYieldsNoClaimRatherThanFalse(_ raw: String?) {
        #expect(AgePredicate.claimValue(birthdate: raw, asOf: Self.taipei(2026, 8, 10)) == nil)
    }

    // MARK: In the credential

    private static func model(birthdate: String?) -> NationalIDModel {
        NationalIDModel(nationality: "中華民國（臺灣）",
                        unifiedNo: "A123456789",
                        name: "王小明",
                        birthdate: birthdate,
                        addressOfHousehold: "臺北市中正區重慶南路一段122號")
    }

    /// The credential carries the predicate *alongside* the date, not instead of
    /// it. Replacing the date would make the document less useful than the card
    /// it backs up; carrying both is what lets selective disclosure choose.
    @Test func theCredentialCarriesBothThePredicateAndTheDate() {
        let credential = VerifiableCredential.nationalID(Self.model(birthdate: "民國 083年03月06日"),
                                                          issuerDID: "did:key:zTest",
                                                          validFrom: Self.taipei(2026, 8, 10))

        #expect(credential.credentialSubject[AgePredicate.claimName] == "true")
        #expect(credential.credentialSubject["birthdate"] == "民國 083年03月06日")
    }

    /// No claim at all when the date cannot be read — the credential is still
    /// issued, it simply makes no assertion about age.
    @Test func anUnreadableDateLeavesTheClaimOutOfTheCredential() {
        let credential = VerifiableCredential.nationalID(Self.model(birthdate: "0700101"),
                                                          issuerDID: "did:key:zTest",
                                                          validFrom: Self.taipei(2026, 8, 10))

        #expect(credential.credentialSubject[AgePredicate.claimName] == nil)
        #expect(credential.credentialSubject["birthdate"] == "0700101")
    }

    /// The term needs an IRI or JSON-LD expansion drops it silently — the same
    /// defect that once produced a national-ID credential containing no national
    /// ID, and the reason `nationalIDTermDefinitions` exists.
    @Test func thePredicateTermIsDefinedInTheContext() {
        #expect(VerifiableCredential.nationalIDTermDefinitions.terms[AgePredicate.claimName]
                == VerifiableCredential.termNamespace + AgePredicate.claimName)
    }

    /// It can be shown on its own: committed with every other claim, revealed
    /// alone, and the date stays behind as a withheld digest.
    @Test func thePredicateCanBeRevealedWithoutTheDate() throws {
        let credential = VerifiableCredential.nationalID(Self.model(birthdate: "民國 083年03月06日"),
                                                          issuerDID: "did:key:zTest",
                                                          validFrom: Self.taipei(2026, 8, 10))
        let claims = credential.credentialSubject
            .filter { $0.key != "id" }
            .map { (name: $0.key, value: $0.value) }
        let (digests, disclosures) = SelectiveDisclosure.commit(claims)

        let ageOnly = try #require(disclosures.first { $0.claimName == AgePredicate.claimName })
        let revealed = try SelectiveDisclosure.reveal(disclosures: [ageOnly.encoded],
                                                      committedDigests: digests)

        #expect(revealed.count == 1)
        #expect(revealed.first?.name == AgePredicate.claimName)
        #expect(revealed.first?.value == "true")
        // And the verifier is told how much was held back rather than being left
        // to assume this is the whole document.
        #expect(SelectiveDisclosure.withheldCount(committedDigests: digests, revealed: 1)
                == claims.count - 1)
    }

    /// The scenario table must not still say this is impossible.
    @Test func theScenarioTableNoLongerCallsThisUnsupported() {
        let scenario = PresentationScenario.ageOver18

        #expect(scenario.path == .credential)
        if case .unsupported = scenario.support {
            Issue.record("滿 18 歲 is still recorded as unsupported")
        }
    }
}
