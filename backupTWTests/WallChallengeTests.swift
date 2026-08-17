//
//  WallChallengeTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

struct WallChallengeTests {

    /// 24 bytes of nonce, as the Worker mints them.
    private static let nonce = "0102030405060708090a0b0c0d0e0f101112131415161718"

    /// `BigInt('0x' + nonce).toString(10)` — the Worker's own line, evaluated.
    ///
    /// This constant is the contract. Two codebases compute this number
    /// independently, they must agree exactly, and nothing in either one would
    /// notice if they stopped: the wall would simply refuse every proof, and it
    /// would look like the person's card was bad.
    /// ⚠️ Not hand-computed. The first version of this constant was, and it was
    /// wrong — which would have made the test agree with the bug instead of with
    /// the Worker. Produced by running the Worker's own line:
    ///
    ///     node -e "console.log(BigInt('0x…').toString(10))"
    ///
    /// and cross-checked against Python's arbitrary-precision `int(n, 16)`.
    private static let decimal =
        "24712618904405848143667237098672243022256101403810731800"

    private static func token(expiresAtMilliseconds: Int) -> String {
        "\(nonce).\(expiresAtMilliseconds).\(String(repeating: "a", count: 64))"
    }

    private static func body(_ token: String, decimal: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["challenge": token, "decimal": decimal])
    }

    // MARK: - The number that has to match the Worker

    @Test func theDecimalMatchesTheWorkersOwnConversion() {
        #expect(WallChallengeReader.decimal(fromHex: Self.nonce) == Self.decimal)
    }

    @Test(arguments: [("00", "0"), ("01", "1"), ("0f", "15"), ("10", "16"),
                      ("ff", "255"), ("0100", "256"), ("ffff", "65535")])
    func theConversionIsBigEndianAndUnsigned(_ pair: (hex: String, decimal: String)) {
        #expect(WallChallengeReader.decimal(fromHex: pair.hex) == pair.decimal)
    }

    /// A leading zero byte must not vanish. `0x00ff` is 255, and a conversion
    /// that dropped the byte instead of the value would still say 255 here — so
    /// the base64url side is checked too, where the byte is visible.
    @Test func aLeadingZeroByteSurvivesIntoTheCircuitEncoding() {
        #expect(WallChallengeReader.decimal(fromHex: "00ff") == "255")
        let encoded = WallChallengeReader.base64URL(fromHex: "00ff")
        #expect(Data(base64URLEncoded: encoded) == Data([0x00, 0xFF]))
    }

    // MARK: - Reading the response

    @Test func awellFormedResponseBecomesAVerifierBoundChallenge() throws {
        let expiry = Int(Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000)
        let result = WallChallengeReader.read(
            Self.body(Self.token(expiresAtMilliseconds: expiry), decimal: Self.decimal),
            receivedAt: .now,
            serverDate: Date())

        let challenge = try #require(try? result.get())
        // The single most important assertion in this file. A proof built on a
        // holder-generated challenge carries
        // `challengeNotBoundToVerifier` for ever, and the wall's entire claim is
        // that its challenge came from the wall.
        #expect(challenge.proofChallenge.boundToVerifier)
        #expect(challenge.token == Self.token(expiresAtMilliseconds: expiry))
    }

    /// The wall's own number is not taken on trust.
    ///
    /// A tampered response could otherwise put one value into the circuit while
    /// the wall verified against another — and the failure would arrive looking
    /// like a bad card rather than like a bad reply.
    @Test func aDecimalThatDisagreesWithTheTokenIsRefused() {
        let expiry = Int(Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000)
        let result = WallChallengeReader.read(
            Self.body(Self.token(expiresAtMilliseconds: expiry), decimal: "999"),
            receivedAt: .now,
            serverDate: Date())
        #expect(result == .failure(.decimalDoesNotMatchToken))
    }

    @Test(arguments: [
        // Not three parts.
        "deadbeef",
        // Nonce too short.
        "0102.1800000000000.aaaa",
        // Uppercase hex: valid arithmetic, but no Worker of ours wrote it.
        "0102030405060708090A0B0C0D0E0F101112131415161718.1800000000000."
            + String(repeating: "a", count: 64),
    ])
    func aTokenThisWallWouldNotHaveWrittenIsRefused(_ token: String) {
        let result = WallChallengeReader.read(
            Self.body(token, decimal: Self.decimal), receivedAt: .now, serverDate: Date())
        #expect(result == .failure(.malformedToken))
    }

    @Test func anExpiredTokenIsRefusedBeforeAnythingIsSpent() {
        let expiry = Int(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        let result = WallChallengeReader.read(
            Self.body(Self.token(expiresAtMilliseconds: expiry), decimal: Self.decimal),
            receivedAt: .now,
            serverDate: Date())
        #expect(result == .failure(.alreadyExpired))
    }

    @Test func aPageInsteadOfJSONIsNamedRatherThanGuessedAt() {
        let html = Data("<!DOCTYPE html><html><body>hello</body></html>".utf8)
        #expect(WallChallengeReader.read(html, receivedAt: .now, serverDate: Date())
                == .failure(.notJSON))
    }

    // MARK: - The clock

    /// The freshness gates run on elapsed time, never on the calendar.
    ///
    /// A phone whose clock is slow would otherwise believe a dead challenge is
    /// alive, and pay for that belief with a 身分證統一編號 disclosure to 內政部
    /// and several seconds of proving before the wall refuses it.
    @Test func freshnessIsMeasuredOnAClockNobodyCanSet() {
        let anchor = ContinuousClock.now
        let challenge = WallChallenge(token: "t", proofChallenge: .fromVerifier("x"),
                                      ttlAtIssue: 1800, anchor: anchor)

        #expect(challenge.secondsRemaining(now: anchor) == 1800)
        #expect(challenge.isWorthStarting(now: anchor))

        let later = anchor.advanced(by: .seconds(1000))
        #expect(challenge.secondsRemaining(now: later) == 800)
        // 800 < 900: too little left to be worth asking for an ID number.
        #expect(!challenge.isWorthStarting(now: later))
        // 800 >= 300: a proof already made is still worth submitting.
        #expect(challenge.isWorthSubmitting(now: later))

        let muchLater = anchor.advanced(by: .seconds(1700))
        #expect(!challenge.isWorthSubmitting(now: muchLater))
        #expect(challenge.secondsRemaining(now: anchor.advanced(by: .seconds(9999))) == 0)
    }

    /// The two thresholds must stay ordered, or the flow can refuse to submit a
    /// proof it was willing to start.
    @Test func startingIsStricterThanSubmitting() {
        #expect(WallChallenge.minimumUsableToStart > WallChallenge.minimumUsableToSubmit)
    }
}

struct WallConfigurationTests {

    /// The cookie jar `.ephemeral` still keeps.
    ///
    /// Cloudflare sets `__cf_bm` on Workers responses. Stored at challenge time
    /// and returned at submit time, it ties the two calls together — across a
    /// network change, which is exactly when the link would otherwise be lost.
    /// Three settings, all asserted, because any one of them alone leaves a jar.
    @Test func theSessionKeepsNoCookiesBetweenTheTwoCalls() {
        let configuration = WallConfiguration.makeSessionConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
    }

    /// Low Data Mode must not stop somebody signing. 254 KB is not the 950 MB
    /// download that `CircuitAssets` refuses on purpose.
    @Test func lowDataModeCanStillSign() {
        #expect(WallConfiguration.makeSessionConfiguration().allowsConstrainedNetworkAccess)
    }

    /// The client must not give up before the servers do, or every slow success
    /// becomes a permanent "we do not know" — and this app's rule for that is
    /// that it cannot promise nothing was published.
    @Test func theClientIsTheLastToGiveUp() {
        // Verifier `WriteTimeout` 120 s < Worker subrequest 150 s < this.
        #expect(WallConfiguration.submitRequestTimeout > 150)
        #expect(WallConfiguration.submitResourceTimeout > WallConfiguration.submitRequestTimeout)
    }

    @Test func theWallIsReachedOverTLSOnTheProjectsOwnDomain() {
        #expect(WallConfiguration.baseURL.scheme == "https")
        #expect(WallConfiguration.baseURL.host == "bonds.tw")
        // Not a personal workers.dev subdomain: this string ships inside a
        // binary that cannot be corrected on a phone that does not update.
        #expect(!WallConfiguration.baseURL.absoluteString.contains("workers.dev"))
    }

    @Test func everyPathStaysUnderTheBase() throws {
        for path in [WallConfiguration.Path.read,
                     WallConfiguration.Path.challenge,
                     WallConfiguration.Path.signZK] {
            let url = try #require(WallConfiguration.url(for: path))
            #expect(url.absoluteString.hasPrefix(WallConfiguration.baseURL.absoluteString))
        }
    }
}
