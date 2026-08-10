//
//  LocalizationCoverageTests.swift
//  backupTWTests
//
//  Every sentence a checker reads has to be in a language they read.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// This exists because it caught a real omission the moment it was written.
///
/// Three strings had just been added to the verifier's result screen — the
/// revocation caveat, the revoked-certificate refusal, and the snapshot's date —
/// and none of them had a `zh-Hant` entry. Nothing failed. The app builds, the
/// suite passes, and a checker in Taiwan reads the qualification on a green tick
/// in English while every line around it is in Chinese.
///
/// That is worse than a missing feature. The whole argument of
/// `VerifiedResultSection.order` is that the caveats sit where they cannot be
/// pushed off the screen; a caveat nobody can read has been pushed off the
/// screen by other means.
struct LocalizationCoverageTests {

    /// The app's Traditional Chinese resources, as built.
    private static let chinese: Bundle? = {
        let app = Bundle(for: VerifierViewController.self)
        guard let path = app.path(forResource: "zh-Hant", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    private static let sentinel = "__no-translation__"

    /// True when this sentence reaches a Chinese reader in Chinese.
    ///
    /// Two ways that can be so, because the test process's own locale is not
    /// something to depend on. Either `message` already came back in Chinese —
    /// the run is localized and the lookup happened upstairs — or it came back as
    /// the English key, in which case the key has to be findable in `zh-Hant`.
    /// An untranslated string fails both ways round, which is the point.
    private static func readableInChinese(_ message: String) -> Bool {
        let hasHan = message.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
        if hasHan { return true }
        guard let chinese else { return false }
        return chinese.localizedString(forKey: message, value: sentinel, table: nil) != sentinel
    }

    @Test func theAppShipsChineseAtAll() {
        // If this fails, everything below is vacuously true and would stay green
        // while the app shipped in English.
        #expect(Self.chinese != nil, "no zh-Hant.lproj in the built app")
    }

    /// The qualifications on a green tick.
    @Test(arguments: VerificationCaveat.allCases)
    func everyCaveatReachesAChineseReader(_ caveat: VerificationCaveat) {
        #expect(Self.readableInChinese(caveat.message),
                "untranslated caveat: \(caveat)")
    }

    /// And the refusals, which is where somebody is being turned away and most
    /// needs to understand why.
    @Test func everyRefusalReachesAChineseReader() {
        for failure in Self.everyFailure {
            #expect(Self.readableInChinese(failure.message),
                    "untranslated failure: \(failure)")
        }
    }

    /// The ZK screen draws `ProofCaveat.allCases` in full — every qualification a
    /// proof carries, none of them collapsed behind a disclosure arrow. This
    /// suite covered `VerificationCaveat` and not this one, which is the same
    /// omission one enum over.
    @Test(arguments: ProofCaveat.allCases)
    func everyProofCaveatReachesAChineseReader(_ caveat: ProofCaveat) {
        #expect(Self.readableInChinese(caveat.localizedDescription),
                "untranslated proof caveat: \(caveat)")
    }

    /// Same construction as `OfflineVerifierTests.everyFailure`, and for the same
    /// reason: `VerificationFailure` has associated values so it cannot be
    /// `CaseIterable`, and a hand-written list silently stops covering the case
    /// somebody adds next. The switch must be exhaustive to compile.
    private static var everyFailure: [VerificationFailure] {
        var all: [VerificationFailure] = []
        var current: VerificationFailure? = .presentationIsNotAJWS
        while let failure = current {
            all.append(failure)
            current = next(after: failure)
        }
        return all
    }

    private static func next(after failure: VerificationFailure) -> VerificationFailure? {
        switch failure {
        case .presentationIsNotAJWS: return .presentationUnreadable
        case .presentationUnreadable: return .presentationFieldsDisagree(field: "challenge")
        case .presentationFieldsDisagree: return .presentationFieldIsNotText(field: "challenge")
        case .presentationFieldIsNotText: return .presentationIsNotAPresentation(declaredType: "vc+jwt")
        case .presentationIsNotAPresentation: return .unsupportedSignatureAlgorithm(declared: "none")
        case .unsupportedSignatureAlgorithm: return .holderIdentifierUnusable
        case .holderIdentifierUnusable: return .presentationKeyIDMismatch
        case .presentationKeyIDMismatch: return .presentationSignatureInvalid
        case .presentationSignatureInvalid: return .credentialMissing
        case .credentialMissing: return .presentationCarriesMultipleCredentials(count: 2)
        case .presentationCarriesMultipleCredentials: return .credentialNotEnveloped
        case .credentialNotEnveloped: return .credentialIsNotAJWS
        case .credentialIsNotAJWS: return .credentialIsNotACredential(declaredType: "vp+jwt")
        case .credentialIsNotACredential: return .issuerIdentifierUnusable
        case .issuerIdentifierUnusable: return .credentialKeyIDMismatch
        case .credentialKeyIDMismatch: return .credentialSignatureInvalid
        case .credentialSignatureInvalid: return .credentialUnreadable
        case .credentialUnreadable: return .credentialNotBoundToPresenter
        case .credentialNotBoundToPresenter: return .credentialIssuerIsNotTheSubject
        case .credentialIssuerIsNotTheSubject: return .challengeMismatch
        case .challengeMismatch: return .purposeMismatch
        case .purposeMismatch: return .audienceMismatch
        case .audienceMismatch: return .presentationTimestampUnreadable
        case .presentationTimestampUnreadable: return .presentationTooOld(age: 600)
        case .presentationTooOld: return .presentationDatedInTheFuture(skew: 600)
        case .presentationDatedInTheFuture: return .credentialValidityUnreadable
        case .credentialValidityUnreadable: return .credentialNotYetValid
        case .credentialNotYetValid: return .credentialExpired
        case .credentialExpired: return .cardSignatureInvalid
        case .cardSignatureInvalid: return .cardholderIsNotTheSubject
        case .cardholderIsNotTheSubject: return .cardholderCertificateUnusable
        case .cardholderCertificateUnusable: return .cardholderCertificateRevoked
        case .cardholderCertificateRevoked: return .trustAnchorUnavailable
        case .trustAnchorUnavailable: return nil
        }
    }
}
