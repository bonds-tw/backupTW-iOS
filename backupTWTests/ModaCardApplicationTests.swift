//
//  ModaCardApplicationTests.swift
//  backupTWTests
//
//  The static 「要申請的卡」 QR is recognised for exactly what it is — and an
//  ordinary credential offer is never mistaken for one.
//

import Testing
@testable import backupTW

/// # Why the miss cases matter as much as the hit
///
/// `ModaCardApplication.parse` runs *before* `CredentialOfferLink.parse` in the
/// scan loop. If it returned non-nil for anything but the static card-application
/// shape, a real `modadigitalwallet://credential_offer` link would be swallowed
/// here and never reach the issuer gates. So the nil cases below are the security
/// boundary, not filler: a plain offer, a random URL, and an off-domain look-alike
/// must all fall through.
struct ModaCardApplicationTests {

    @Test func recognisesTheStaticCardApplicationQR() {
        let scanned = "https://frontend.wallet.gov.tw/api/moda/qrcode?mode=vc&vcUid=ABC"
        let parsed = ModaCardApplication.parse(scanned: scanned)
        #expect(parsed?.vcUid == "ABC")
        #expect(parsed?.mode == "vc")
    }

    /// The official QR framing has been measured wrapping raw CR/LF into the query;
    /// a scanner hands on camera bytes, so the parser must strip them exactly as
    /// `CredentialOfferLink.parse` does. Without stripping, `URLComponents` reads
    /// the parameter after the newline with `\n` glued to its name and the card
    /// misses.
    @Test func stripsCarriageReturnAndNewlineFraming() {
        let scanned = "https://frontend.wallet.gov.tw/api/moda/qrcode?\r\nmode=vc&vcUid=ABC\n"
        let parsed = ModaCardApplication.parse(scanned: scanned)
        #expect(parsed?.vcUid == "ABC")
        #expect(parsed?.mode == "vc")
    }

    /// Staging/UAT siblings under the same registrable domain are admitted by the
    /// host *suffix* match.
    @Test func admitsSiblingHostsUnderTheSameDomain() {
        let scanned = "https://frontend-uat.wallet.gov.tw/api/moda/qrcode?mode=vc&vcUid=XYZ"
        #expect(ModaCardApplication.parse(scanned: scanned)?.vcUid == "XYZ")
    }

    /// The whole point of running first: an actual offer link must not be caught
    /// here. It has to reach `CredentialOfferLink` and the gates.
    @Test func doesNotSwallowARealCredentialOffer() {
        let offer = "modadigitalwallet://credential_offer?credential_offer_uri=https%3A%2F%2Fissuer.example%2Foffer"
        #expect(ModaCardApplication.parse(scanned: offer) == nil)
    }

    @Test func doesNotSwallowAStandardOpenIDOffer() {
        let offer = "openid-credential-offer://?credential_offer_uri=https%3A%2F%2Fissuer.example%2Foffer"
        #expect(ModaCardApplication.parse(scanned: offer) == nil)
    }

    @Test func rejectsARandomURL() {
        #expect(ModaCardApplication.parse(scanned: "https://example.com/foo?mode=vc&vcUid=ABC") == nil)
    }

    /// Right host, path and query, but plaintext `http` — never a legitimate card
    /// application, and matching it would resolve the vcUid over the clear.
    @Test func rejectsPlaintextHTTP() {
        let scanned = "http://frontend.wallet.gov.tw/api/moda/qrcode?mode=vc&vcUid=ABC"
        #expect(ModaCardApplication.parse(scanned: scanned) == nil)
    }

    /// The leading dot on the suffix is what stops an attacker registering
    /// `notwallet.gov.tw` and matching.
    @Test func rejectsALookAlikeDomain() {
        let scanned = "https://frontend.notwallet.gov.tw/api/moda/qrcode?mode=vc&vcUid=ABC"
        #expect(ModaCardApplication.parse(scanned: scanned) == nil)
    }

    /// Right host and path, but the wrong endpoint — the `vcqrcode` relay page the
    /// offer parser unwraps — must not match here (exact path).
    @Test func rejectsTheRelayEndpoint() {
        let scanned = "https://frontend.wallet.gov.tw/api/moda/vcqrcode?mode=vc&vcUid=ABC"
        #expect(ModaCardApplication.parse(scanned: scanned) == nil)
    }

    /// A malformed QR — missing `vcUid`, or an empty one — is a miss, not a guess,
    /// so it falls through rather than resolving a blank identity.
    @Test func rejectsMissingOrEmptyValues() {
        #expect(ModaCardApplication.parse(scanned: "https://frontend.wallet.gov.tw/api/moda/qrcode?mode=vc") == nil)
        #expect(ModaCardApplication.parse(scanned: "https://frontend.wallet.gov.tw/api/moda/qrcode?mode=vc&vcUid=") == nil)
        #expect(ModaCardApplication.parse(scanned: "https://frontend.wallet.gov.tw/api/moda/qrcode?vcUid=ABC") == nil)
    }

    @Test func rejectsNonURLGarbage() {
        #expect(ModaCardApplication.parse(scanned: "not a url at all") == nil)
    }
}
