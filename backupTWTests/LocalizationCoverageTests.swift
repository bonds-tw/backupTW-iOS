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
    static let chinese: Bundle? = {
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
    /// The Chinese for a sentence, or nil when there is none. Sibling of
    /// `readableInChinese`, shared with `VerifierTerminologyTests`.
    static func chineseValue(for message: String) -> String? {
        guard let chinese else { return nil }
        let value = chinese.localizedString(forKey: message, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    /// Every refusal sentence, walked rather than listed.
    static var allFailureMessages: [String] { everyFailure.map(\.message) }

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

    /// What signing a public wall discloses.
    ///
    /// Added with the strings rather than after them — the b-1 lesson from the
    /// 2026-08-13 audit, where a whole screen's argument shipped in English
    /// because the coverage test enumerated every type except that one.
    ///
    /// These are the sentences somebody reads while deciding whether to publish
    /// something they cannot take back, which makes an untranslated one worse
    /// here than almost anywhere else in the app.
    @Test(arguments: WallDisclosure.allCases)
    func everyWallDisclosureReachesAChineseReader(_ disclosure: WallDisclosure) {
        #expect(Self.readableInChinese(disclosure.message),
                "untranslated wall disclosure: \(disclosure)")
    }

    /// The reading order must contain every case.
    ///
    /// A screen that renders `inReadingOrder` would silently drop any case left
    /// out of it — and the case most likely to be forgotten is the one added
    /// last, which here is the one about 內政部 being able to line up two lists.
    @Test func theReadingOrderLeavesNothingOut() {
        #expect(Set(WallDisclosure.inReadingOrder) == Set(WallDisclosure.allCases))
        #expect(WallDisclosure.inReadingOrder.count == WallDisclosure.allCases.count,
                "a disclosure appears twice in the reading order")
    }

    /// The capability screen, which this suite did not cover — b-1 of the
    /// 2026-08-13 audit.
    ///
    /// Four strings shipped in English while every line around them was in
    /// Chinese, and this file was green the whole time: it covered
    /// `VerificationCaveat`, `VerificationFailure` and `ProofCaveat`, and
    /// `PresentationScenario` was **the one type over**. Exactly the omission the
    /// header of this file describes, repeated one enum later.
    ///
    /// It matters more here than almost anywhere. That screen's only reason to
    /// exist is stopping `.partial` from being read as `.supported`, and
    /// `.partial` carries its whole argument in the `actually` sentence — the one
    /// that was in English.
    @Test(arguments: PresentationScenario.all)
    func everyScenarioReachesAChineseReader(_ scenario: PresentationScenario) {
        #expect(Self.readableInChinese(scenario.request),
                "untranslated scenario request: \(scenario.id)")
        switch scenario.support {
        case .supported:
            break
        case .partial(let actually):
            #expect(Self.readableInChinese(actually),
                    "untranslated 'what it actually shows': \(scenario.id)")
        case .unsupported(let blockedBy):
            #expect(Self.readableInChinese(blockedBy),
                    "untranslated 'what would have to change': \(scenario.id)")
        }
    }

    /// The verdict words themselves.
    ///
    /// `headline(for:)` is the sentence that decides whether a reader rounds
    /// `.partial` up, and it is deliberately not 「部分通過」 — 「做得到一半」 is a
    /// different answer rather than a qualified version of the same one. That
    /// distinction only survives if the Chinese exists.
    @Test func everyVerdictHeadlineReachesAChineseReader() {
        for support: ScenarioSupport in [.supported,
                                         .partial(actually: ""),
                                         .unsupported(blockedBy: "")] {
            let headline = CapabilityViewController.headline(for: support)
            #expect(Self.readableInChinese(headline), "untranslated headline: \(headline)")
        }
    }

    /// And the two path descriptions, which are where a reader learns that the
    /// credential path shows their name and the zero-knowledge path shows the
    /// same duplicate-detection number to everybody.
    @Test(arguments: [PresentationPath.credential, PresentationPath.zeroKnowledge])
    func everyPathDescriptionReachesAChineseReader(_ path: PresentationPath) {
        #expect(Self.readableInChinese(CapabilityViewController.pathDescription(path)),
                "untranslated path description: \(path)")
    }

    /// # The type-walk has a hole, and this is the shape of it
    ///
    /// Every sentence checked above is reached by walking a *type*:
    /// `VerificationCaveat`, `VerificationFailure`, `ProofCaveat`,
    /// `WallDisclosure`, `PresentationScenario`. Two sentences live on a struct
    /// and a view controller instead, and nothing enumerated could reach them —
    /// so they were the only two `NSLocalizedString` literals in the whole app
    /// with no catalog entry at all, and they shipped in English.
    ///
    /// Their neighbours in the same `switch` were translated. In one `if/else`,
    /// the true branch was Chinese and the false branch fell back to the English
    /// key. That false branch is 「this file only *looks* signed」 — the one
    /// sentence whose misreading this file's own comment says sends the work
    /// down the wrong path for weeks.
    ///
    /// This is the first round's `b-1`, one type later: that fix added the keys
    /// and a walk, and the walk never became a rule. So this walks the four flag
    /// combinations rather than the two sentences, which closes the branch
    /// instead of the instance.
    @Test("PDF 掃描結果的四種旗標組合，每一句都要有中文")
    func everyPDFScanSummaryReachesAChineseReader() {
        let scans = [
            PDFSignatureScan(isSigned: false, hasSignatureBytes: false,
                             subFilters: [], signatureCount: 0, hasByteRange: false),
            // The expensive one: prepared for signing, never signed. Measured on
            // a real interrupted run — 2,206 bytes of `/Contents`, not one
            // non-zero digit.
            PDFSignatureScan(isSigned: true, hasSignatureBytes: false,
                             subFilters: [], signatureCount: 1, hasByteRange: true),
            PDFSignatureScan(isSigned: true, hasSignatureBytes: true,
                             subFilters: ["adbe.pkcs7.detached"], signatureCount: 1,
                             hasByteRange: true),
            PDFSignatureScan(isSigned: true, hasSignatureBytes: true,
                             subFilters: [], signatureCount: 2, hasByteRange: true),
        ]
        for scan in scans {
            #expect(Self.readableInChinese(scan.summary),
                    "untranslated PDF scan summary: \(scan.summary)")
        }
    }

    /// The fingerprint verdict is the sentence that tells a holder whether the
    /// original is still the one they imported. Translating only the green path
    /// would hide the state that actually needs attention.
    @Test func everyMyDataVaultIntegrityStateReachesAChineseReader() {
        let states: [MyDataVaultArchive.Integrity] = [
            .verified, .mismatch, .metadataMissing, .fileMissing,
        ]
        for state in states {
            let message = MyDataVaultDocumentViewController.integrityMessage(state)
            #expect(Self.readableInChinese(message),
                    "untranslated MyData vault integrity state: \(message)")
        }
        for error in [MyDataVaultPreviewError.originalMissing,
                      .unsupportedFormat("ZIP"), .noPDF] {
            let message = error.localizedDescription
            #expect(Self.readableInChinese(message),
                    "untranslated MyData vault preview error: \(message)")
        }
    }

    /// Same construction as `OfflineVerifierTests.everyFailure`, and for the same
    /// reason: `VerificationFailure` has associated values so it cannot be
    /// `CaseIterable`, and a hand-written list silently stops covering the case
    /// somebody adds next. The switch must be exhaustive to compile.
    static var everyFailure: [VerificationFailure] {
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
        case .trustAnchorUnavailable:
            return .deviceClockPrecedesCertificate(validFrom: Date(timeIntervalSince1970: 1_654_560_000))
        case .deviceClockPrecedesCertificate: return nil
        }
    }
}

/// 查驗端的每一句話都叫它「證件」。「文件」只留給 MyData 的原始檔與 PDF 的
/// document-level 術語。
///
/// # 為什麼這條要有測試
///
/// 第一輪的 `d-6` 標記為已修，實際上 sweep 只碰了七個字串、其中三個是文件→證件。
/// `d-6` 自己在「現況」欄裡逐字引用的那兩句話，一個位元組都沒改。最尖銳的一對是
/// 同一個 switch 裡相鄰的兩個 case，一個寫證件、一個寫文件。
///
/// 英文那側是一致的（全部 "this document"），所以這個分裂完全是在譯文裡產生的，
/// 而讀者最可能的誤讀是「文件」與「證件」是兩樣不同的東西——查驗方正在找的是哪
/// 一樣，就變成不明的了。
///
/// 沒有測試的話，這條會第三次以同樣的形狀回來。
@Suite("查驗端的用詞")
struct VerifierTerminologyTests {

    private static func chineseText(_ message: String) -> String {
        // Same two-way lookup as `readableInChinese`: either the run is
        // localized and this already came back in Chinese, or we look it up.
        if message.range(of: "\\p{Han}", options: .regularExpression) != nil { return message }
        return LocalizationCoverageTests.chineseValue(for: message) ?? message
    }

    @Test("查驗端的但書、群組標題與拒絕理由都不說「文件」")
    func nothingTheCheckerReadsCallsItADocument() {
        var sentences: [String] = VerificationCaveat.allCases.map(\.message)
        sentences += VerificationCaveat.Group.allCases.map(\.subtitle)
        sentences += LocalizationCoverageTests.allFailureMessages

        for sentence in sentences {
            let chinese = Self.chineseText(sentence)
            // ⚠️ 非空洞性：如果查不到中文，`chineseText` 會回傳英文，而英文裡永遠
            // 沒有「文件」——那樣這支測試會以全綠通過，理由卻是它什麼都沒看到。
            #expect(chinese.range(of: "\\p{Han}", options: .regularExpression) != nil,
                    "查不到中文，這一條的斷言等於沒有斷言：\(sentence)")
            #expect(!chinese.contains("文件"),
                    "查驗端出口說「文件」：\(chinese)")
        }
    }
}
