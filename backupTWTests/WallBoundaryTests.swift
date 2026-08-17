//
//  WallBoundaryTests.swift
//  backupTWTests
//
//  The properties the wall path rests on, pinned where prose cannot drift.
//

import Foundation
import Testing
@testable import backupTW

/// # Why these are separate from the behaviour tests
///
/// Everything here is a claim this project makes *about itself* — what the
/// request contains, what the copy may say, what the app promises about staying
/// offline. Each one is true today by construction, and each one would stop
/// being true through an edit nobody would flag in review.
struct WallBoundaryTests {

    // MARK: - What leaves the phone

    /// Three fields. Not "at least three".
    ///
    /// Set equality, four lines, and what it is guarding against is two years
    /// away: somebody adding a device identifier, a locale, an app version, a
    /// "just for debugging" field. Each of those is individually reasonable and
    /// all of them are a per-signer handle on a wall built to have none.
    @Test func theBodyHasExactlyThreeFields() throws {
        let submission = try Self.stubSubmission()
        let body = try submission.body(challengeToken: "abc.123.def")
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["challenge", "certChainProof", "userSigProof"])
    }

    /// Standard base64, not base64url.
    ///
    /// Go's `encoding/json` decodes `[]byte` with `StdEncoding` and rejects the
    /// URL-safe alphabet outright. The fixture is chosen to produce both `+` and
    /// `/`, because a test using bytes that happen to avoid them would pass
    /// against either alphabet and prove nothing.
    @Test func theProofFieldsAreStandardBase64NotBase64URL() throws {
        let submission = try Self.stubSubmission(bytes: Data([0xFB, 0xFF, 0xBF, 0x3E, 0x3F]))
        for encoded in [submission.certChainProof, submission.userSigProof] {
            #expect(encoded.contains("+") || encoded.contains("/"),
                    "the fixture does not exercise the alphabet difference")
            #expect(!encoded.contains("-") && !encoded.contains("_"),
                    "base64url would be rejected by Go's encoding/json")
            #expect(Data(base64Encoded: encoded) != nil)
        }
    }

    /// The two `*_instance.bin` files are not sent.
    ///
    /// Because Go's request struct has no fields for them — **not** because
    /// sending them would disclose more. That correction is in
    /// `WallSubmission`'s own docs and this test checks the shape, not the myth.
    @Test func theSubmissionCarriesNoInstanceFiles() {
        for name in WallSubmission.artifactNames {
            #expect(!name.contains("instance"),
                    "\(name) is an instance file and the Go struct has no field for it")
        }
        #expect(WallSubmission.artifactNames.count == 2)
    }

    /// Derived from the prover, so the two cannot drift.
    @Test func theArtifactNamesAgreeWithTheProver() {
        #expect(WallSubmission.artifactNames
                == ZKProver.proofFilenames.map { ($0 as NSString).lastPathComponent })
    }

    // MARK: - What the copy may not say

    /// Words this flow is not entitled to.
    ///
    /// The list is not stylistic. Every entry is a claim the system cannot
    /// support: the proof carries two constant numbers, the wall cannot delete
    /// what it cannot identify, v1 checks no revocation, and the signature very
    /// much does leave the phone.
    ///
    /// `不會離開這支手機` is on the list in the exact shape of a sentence this
    /// app already had to correct once — the camera permission string promised
    /// nothing would be uploaded, in a build that was about to publish to a
    /// public page.
    @Test(arguments: WallDisclosure.allCases)
    func noDisclosureOverClaims(_ disclosure: WallDisclosure) {
        let forbidden = ["完全匿名", "anonymous", "無法追蹤", "追查不到",
                         "可以刪除", "可以撤回", "未被撤銷", "不會離開這支手機"]
        let text = disclosure.message
        for word in forbidden {
            #expect(!text.contains(word),
                    "\(disclosure) claims 「\(word)」, which this system cannot support")
        }
    }

    /// The sharpest disclosure has to keep its sharpest word.
    ///
    /// Its whole job is the distinction between a promise and a property, and
    /// that distinction lives in one clause. A rewrite that smoothed it out
    /// would leave a sentence that reads reassuring and says nothing.
    @Test func theOperatorDisclosureStillSaysItIsOnlyAPromise() {
        let text = WallDisclosure.nullifierReachesTheOperator.message
        #expect(text.contains("promise") || text.contains("承諾"),
                "the promise-versus-property distinction has been smoothed away")
    }

    /// The one the app cannot mitigate must keep naming 內政部.
    ///
    /// It is the only disclosure about a party the person cannot opt out of, and
    /// a generic rewrite ("the issuer may be able to correlate") would leave
    /// them unable to tell who.
    @Test func theIssuerCorrelationDisclosureNamesWho() {
        #expect(WallDisclosure.issuerKnowsWhenYouAsked.message.contains("內政部"))
    }

    // MARK: - The claim the whole app rests on

    /// Signing the wall must not touch Bluetooth.
    ///
    /// `NSBluetoothAlwaysUsageDescription` says 「全程不連任何伺服器」 — scoped
    /// to presentation, and true there. This flow contacts a server on purpose,
    /// so the two must never meet: if the wall path ever used the radio, that
    /// permission string would become false in the App Store dialogue.
    @Test func theWallPathNamesNoBluetoothType() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("backupTW/Wall")
        var scanned = 0
        for url in try FileManager.default.contentsOfDirectory(at: root,
                                                               includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" {
            scanned += 1
            let source = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for symbol in ["CBCentralManager", "CBPeripheralManager", "BluetoothLink",
                           "import CoreBluetooth"] {
                #expect(!source.contains(symbol),
                        "\(url.lastPathComponent) reaches for \(symbol)")
            }
        }
        #expect(scanned >= 5, "only \(scanned) wall files scanned — the walk is not finding them")
    }

    /// The Bluetooth permission string keeps its promise, and the camera one
    /// keeps its corrected scope.
    ///
    /// The camera string used to say 「不會將任何影像**或資料**上傳」 with
    /// 「全程」 in front of it and nothing tying it back to the camera. In a
    /// build that can publish to a public wall that sentence is false, and it
    /// appears in the App Store permission dialogue — the least context-rich
    /// screen this app has.
    @Test func thePermissionStringsStayTrueOfABuildThatCanPublish() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("backupTW/Info.plist")
        let source = String(decoding: try Data(contentsOf: plist), as: UTF8.self)
        #expect(!source.contains("不會將任何影像或資料上傳"),
                "the camera string promises no data is uploaded, in a build that publishes")
        #expect(source.contains("不會將任何影像上傳"))
        // The Bluetooth string's claim is scoped to presentation and stays.
        #expect(source.contains("全程不連任何伺服器"))
    }

    // MARK: - Fixtures

    private static func stubSubmission(bytes: Data = Data([1, 2, 3, 4])) throws -> WallSubmission {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in WallSubmission.artifactNames {
            try bytes.write(to: directory.appendingPathComponent(name))
        }
        let metrics = ProofMetrics(proveMilliseconds: 1, proofByteCount: UInt64(bytes.count))
        return try WallSubmission(readingFrom: ZKProofBundle(
            certificateChain: metrics,
            userSignature: metrics,
            caveats: [],
            proofDirectory: directory))
    }
}

/// Every ending a person can reach has to say three things.
struct WallCopyTests {

    private static let everyError: [WallError] = [
        .hostDoesNotExist, .offline, .unreadableReply, .unavailable, .rateLimited,
        .budgetSpent, .challengeUnusable, .challengeAlreadyUsed, .verifierUnavailable,
        .refused, .unknownWhetherPublished, .proofTooLarge(bytes: 9_000_000),
        .cannotProveInThisBuild,
    ]

    /// No silent branch. A failure with no sentence is a spinner that stops.
    @Test func everyFailureHasATitleAndABody() {
        for error in Self.everyError {
            for cost in [WallRetryCost.resend, .startOver, .mightDuplicate, .none] {
                let message = WallCopy.message(for: WallFailure(error, retryCost: cost,
                                                                publication: .unknown))
                #expect(!message.title.isEmpty, "\(error) has no title")
                #expect(!message.body.isEmpty, "\(error) at \(cost) has no body")
            }
        }
    }

    /// **A retry that might duplicate is never offered as a button.**
    ///
    /// Pressing it may add a second signature to a public wall and send another
    /// 身分證統一編號 to 內政部. That is not a decision to hand somebody behind a
    /// one-word label — the body says what is unknown, and they choose.
    @Test func nothingThatMightDuplicateGetsARetryButton() {
        for error in Self.everyError {
            let message = WallCopy.message(for: WallFailure(error, retryCost: .mightDuplicate,
                                                            publication: .unknown))
            #expect(message.retryLabel == nil,
                    "\(error) offers a retry button that may publish twice")
        }
    }

    /// The other direction of the same invariant, which nothing asserted.
    ///
    /// `nothingThatMightDuplicateGetsARetryButton` above is one-way: it stops a
    /// duplicate-risking outcome from getting a button. Nothing stopped a
    /// zero-cost outcome from being denied one — and `.hostDoesNotExist` was
    /// exactly that, hard-coding `retryLabel: nil` over a `retryCost` of
    /// `.resend` that `WallResponseReaderTests` asserts by name. It also skipped
    /// `WallCopy.body(for:)`, so 「nothing was used up — the same proof can go
    /// again」 was suppressed along with the button.
    /// Six branches refuse a retry whatever the cost says, and each has a reason
    /// that survives being handed `.resend`:
    ///
    /// - `.unavailable` — whoever runs the wall switched it off; the same answer
    ///   is waiting.
    /// - `.challengeAlreadyUsed` — the nonce is spent; a resend cannot unspend it.
    /// - `.refused` — the wall checked the proof and said no.
    /// - `.unknownWhetherPublished` — a retry may publish a second time.
    /// - `.proofTooLarge` — the bytes will be the same bytes.
    /// - `.cannotProveInThisBuild` — nothing was ever asked for.
    ///
    /// `.hostDoesNotExist` was a seventh and did not belong: it was not an
    /// editorial judgement, it was a sentence copied from a plan written while
    /// the compiled-in host did not exist. Everything outside this list must
    /// honour `retryCost`.
    @Test func onlyTheSixBranchesWithAReasonRefuseAFreeRetry() {
        let deliberatelySilent: Set<String> = [
            "unavailable", "challengeAlreadyUsed", "refused",
            "unknownWhetherPublished", "proofTooLarge", "cannotProveInThisBuild",
        ]
        for error in Self.everyError {
            let name = String(describing: error).prefix { $0 != "(" }
            let message = WallCopy.message(for: WallFailure(error, retryCost: .resend,
                                                            publication: .nothingWasPublished))
            if deliberatelySilent.contains(String(name)) {
                #expect(message.retryLabel == nil,
                        "\(error) is on the deliberate-silence list and now offers a button — decide which")
            } else {
                #expect(message.retryLabel != nil,
                        "\(error) costs nothing to retry and offers no way to")
            }
        }
    }

    /// ⚠️ `.hostDoesNotExist` must not blame the reader's network *or* clear it.
    ///
    /// The compiled-in host resolves, so this branch is reachable only through a
    /// name lookup failing on the reader's side — which is what the sentence
    /// 「this is an address setting in this version of the app, **not your
    /// network**」 denied. It was written while the compiled-in host was
    /// `wall.bonds.tw`, which did not exist; the host was settled fifteen
    /// minutes before this file was written and the sentence came along
    /// unchanged.
    @Test func theHostBranchDoesNotRuleOutTheOnlyThingItCanMean() {
        let message = WallCopy.message(for: WallFailure(.hostDoesNotExist, retryCost: .resend,
                                                        publication: .nothingWasPublished))
        for denial in ["not your network", "不是你的網路"] where message.body.contains(denial) {
            Issue.record("the DNS branch denies DNS: \(message.body)")
        }
        #expect(message.retryLabel != nil)
        // And the cost sentence is back.
        #expect(message.body.contains("go again") || message.body.contains("再送一次"),
                "the branch still suppresses 「nothing was used up」: \(message.body)")
    }

    /// The button is named after its cost, not "try again".
    @Test func theRetryButtonSaysWhatItCosts() {
        let resend = WallCopy.message(for: WallFailure(.rateLimited, retryCost: .resend,
                                                       publication: .nothingWasPublished))
        let over = WallCopy.message(for: WallFailure(.verifierUnavailable, retryCost: .startOver,
                                                     publication: .nothingWasPublished))
        #expect(resend.retryLabel != over.retryLabel,
                "resending the same proof and starting over read as the same action")
    }

    /// ⚠️ The `challengeUnusable` body must not assert expiry.
    ///
    /// The Worker returns the same string for a malformed token, a bad MAC and
    /// an expired one — and this app has already checked the format when parsing
    /// and the remaining time on a monotonic clock before sending. So expiry is
    /// the one cause it has ruled out, and asserting it would be guessing wrong
    /// in the only branch that has to guess.
    @Test func theUnusableChallengeMessageDoesNotAssertACause() {
        let body = WallCopy.message(for: WallFailure(.challengeUnusable, retryCost: .startOver,
                                                     publication: .nothingWasPublished)).body
        #expect(body.contains("may") || body.contains("可能"),
                "the message asserts a cause it cannot know")
    }

    /// The refusal message must not blame the card.
    ///
    /// The wall's checks are a strict superset of this phone's, so "passed here,
    /// refused there" is the expected symptom of a `WALL_APP_ID` mismatch — and
    /// this sentence is the only place that misconfiguration surfaces to a human.
    @Test func aRefusalAfterALocalPassBlamesTheSettingsNotTheCard() {
        let passed = WallCopy.refusal(selfCheckPassedHere: true).body
        #expect(passed.contains("settings") || passed.contains("設定"))
        #expect(passed.contains("nothing wrong with your card") || passed.contains("不代表你的卡片有問題"))

        let notChecked = WallCopy.refusal(selfCheckPassedHere: nil).body
        #expect(passed != notChecked, "both refusal variants say the same thing")
    }

    /// Every sentence reaches a Chinese reader.
    @Test func everyFailureSentenceIsTranslated() {
        for error in Self.everyError {
            let message = WallCopy.message(for: WallFailure(error, retryCost: .resend,
                                                            publication: .nothingWasPublished))
            for text in [message.title, message.body] {
                let hasHan = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                #expect(hasHan, "untranslated wall message for \(error): \(text)")
            }
        }
    }
}
