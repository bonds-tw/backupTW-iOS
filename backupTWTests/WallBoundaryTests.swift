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
