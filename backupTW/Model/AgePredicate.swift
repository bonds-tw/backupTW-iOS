//
//  AgePredicate.swift
//  backupTW
//
//  Turning a 民國 birthdate into an age predicate that can be shown on its own.
//

import Foundation

// MARK: - Why a predicate is a claim rather than a circuit
//
// The scenario table used to say 滿 18 歲 could not be done. That was true of
// the *circuits* — `generateCertChainRs4096Input` takes a certificate chain and
// an RSA signature, and there is no date among their inputs — and it was written
// as though it were true of the app. It is the same conflation the project has
// made before: "the current architecture cannot" written as "this cannot".
//
// Two things landed since: the credential's fields are signed by the holder's
// 自然人憑證 (`MOICASignedCredential`), and `SelectiveDisclosure` lets a holder
// reveal one claim while withholding the rest. Together they answer the question
// without any circuit:
//
//   1. at issuance the birthdate is in hand, so the predicate is derived then
//      and carried as its own claim;
//   2. the card signs the whole credential, so the predicate inherits exactly
//      the authority the raw date has — no more, no less;
//   3. the holder discloses the predicate and withholds the date.
//
// What this is not: zero knowledge. The disclosure carries the app's subject
// identifier, so `VerificationCaveat.identifierIsLinkable` still applies, and
// two verifiers can still tell they saw the same person. It is minimal
// disclosure of the *field*, which is a different and weaker property than
// unlinkability — and the screen must not blur them.

/// A 民國 (Republic of China) calendar date, as MyData writes it.
///
/// # The format, and how much of it has been seen
///
/// Measured against exactly **one** real MyData download (2026-08-09):
/// `民國 083年03月06日`. Everything below tolerates what that sample implies —
/// an optional 民國 prefix, optional spaces, zero-padded fields — and nothing
/// beyond it is claimed. A string this cannot read yields `nil`, and the caller
/// is required to treat that as "no age claim", never as "under age".
///
/// The project's own hand-written parsing fixtures use `0700101`, a bare digit
/// run, which the real download does not look like. That is recorded here rather
/// than quietly reconciled: those fixtures were invented, this sample was
/// measured, and a third format may yet turn up.
struct ROCDate: Equatable, Sendable {

    /// 民國 year. Year 1 is 1912 CE.
    let year: Int
    let month: Int
    let day: Int

    /// 民國 1 is 1912, so the offset is 1911.
    static let gregorianOffset = 1911

    var gregorianYear: Int { year + Self.gregorianOffset }

    /// Parses the form MyData writes, or `nil`.
    ///
    /// Deliberately strict about the *shape* and lenient about spacing: a
    /// government export changing 「民國 083年」 to 「民國83年」 is a formatting
    /// difference, while a string with no 年/月/日 markers is a different format
    /// that this has not seen and must not guess at.
    static func parse(_ raw: String) -> ROCDate? {
        // Full-width digits appear in some government exports; normalising them
        // is a transliteration, not an interpretation.
        let normalized = raw
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: " ", with: "")
            ?? raw

        guard let yearRange = normalized.range(of: "年"),
              let monthRange = normalized.range(of: "月"),
              let dayRange = normalized.range(of: "日"),
              yearRange.lowerBound < monthRange.lowerBound,
              monthRange.lowerBound < dayRange.lowerBound else {
            return nil
        }

        let yearText = normalized[normalized.startIndex ..< yearRange.lowerBound]
            .replacingOccurrences(of: "民國", with: "")
        let monthText = normalized[yearRange.upperBound ..< monthRange.lowerBound]
        let dayText = normalized[monthRange.upperBound ..< dayRange.lowerBound]

        guard let year = Int(yearText), let month = Int(monthText), let day = Int(dayText),
              year > 0, (1 ... 12).contains(month), (1 ... 31).contains(day) else {
            return nil
        }
        return ROCDate(year: year, month: month, day: day)
    }

    /// The Gregorian date this denotes, in the calendar the device reasons in.
    ///
    /// Taipei time, not the device's zone: a birthdate on a household record is
    /// a civil date in Taiwan, and evaluating it in whatever zone the phone
    /// happens to be in would move the boundary by a day for a holder abroad —
    /// which is precisely the holder this app exists for.
    func date(in calendar: Calendar = ROCDate.taipeiCalendar) -> Date? {
        var components = DateComponents()
        components.year = gregorianYear
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    static let taipeiCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .gmt
        return calendar
    }()
}

// MARK: - The predicate

/// Whether a holder had reached a given age on a given day.
enum AgePredicate {

    /// The age of majority the credential carries a claim about.
    static let majority = 18

    /// The claim name. Named for *when* it was true, because that is the whole
    /// of its meaning.
    ///
    /// A bare `isOver18` would be a trap in one direction: `false` on a
    /// credential issued three years ago says nothing about today, and a
    /// verifier reading it as "this person is a minor" would be wrong through no
    /// fault of their own. Spelling the issuance time into the name means the
    /// false case reads correctly, and the true case is still sound today —
    /// nobody gets younger.
    static let claimName = "over18AtIssuance"

    /// Derives the claim, or `nil` when the birthdate is not one this build can
    /// read.
    ///
    /// `nil` rather than `"false"`, and the difference is the whole safety
    /// property: an unparseable date means *unknown*, and emitting `false` for
    /// unknown would be asserting somebody is a minor because our parser did not
    /// recognise their record.
    static func claimValue(birthdate raw: String?, asOf now: Date) -> String? {
        guard let raw, let roc = ROCDate.parse(raw), let born = roc.date() else { return nil }
        return reached(majority, bornOn: born, asOf: now) ? "true" : "false"
    }

    /// Whether someone born on `born` had reached `age` by `now`.
    ///
    /// Uses calendar year arithmetic rather than a day count, because the
    /// boundary is a birthday and not 18 × 365.25 days: leap years make those
    /// differ, and the day they differ on is somebody's birthday.
    static func reached(_ age: Int, bornOn born: Date, asOf now: Date) -> Bool {
        let calendar = ROCDate.taipeiCalendar
        guard let boundary = calendar.date(byAdding: .year, value: age, to: born) else {
            return false
        }
        // The predicate turns true *on* the birthday, not the day after.
        return calendar.startOfDay(for: boundary) <= calendar.startOfDay(for: now)
    }
}
