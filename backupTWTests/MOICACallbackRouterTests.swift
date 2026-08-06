//
//  MOICACallbackRouterTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// The scheme was registered before anything listened on it, so these cover the
/// gap that made a callback indistinguishable from silence — plus the fact that
/// any app on the device can open our scheme with whatever it likes.
struct MOICACallbackRouterTests {

    private func callbackURL(returnValue: String) -> URL {
        let encoded = Data(returnValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "backuptw://callback?rtn_val=\(encoded)")!
    }

    @Test func aMatchingCallbackEndsTheWait() async {
        let router = MOICACallbackRouter()
        let transaction = "TXN-match"

        async let waited: Void = router.waitForCallback(transactionID: transaction)
        // Let the waiter register before delivering, otherwise the callback
        // arrives first and the test would pass without exercising anything.
        while await router.pendingCount() == 0 { await Task.yield() }

        let matched = await router.handle(callbackURL(returnValue: transaction))
        await waited

        #expect(matched)
        #expect(await router.pendingCount() == 0)
    }

    @Test func aCallbackForSomeoneElsesTransactionIsIgnored() async {
        let router = MOICACallbackRouter()
        async let waited: Void = router.waitForCallback(transactionID: "TXN-ours")
        while await router.pendingCount() == 0 { await Task.yield() }

        #expect(await router.handle(callbackURL(returnValue: "TXN-theirs")) == false)
        // Ours is still waiting: a stranger's callback must not release it.
        #expect(await router.pendingCount() == 1)

        _ = await router.handle(callbackURL(returnValue: "TXN-ours"))
        await waited
    }

    @Test func aCallbackWithNothingPendingIsDiscarded() async {
        let router = MOICACallbackRouter()
        #expect(await router.handle(callbackURL(returnValue: "TXN-unsolicited")) == false)
        #expect(await router.pendingCount() == 0)
    }

    /// Any app can open `backuptw://`. Malformed input must be rejected rather
    /// than crashing or matching something.
    @Test(arguments: [
        "backuptw://callback",
        "backuptw://callback?rtn_val=",
        "backuptw://callback?rtn_val=!!!not-base64!!!",
        "backuptw://callback?other=TXN-x",
        "https://example.com/callback?rtn_val=VFhOLXg",
        "mobilemoica://callback?rtn_val=VFhOLXg",
    ])
    func hostileOrUnrelatedURLsDoNotMatch(raw: String) async {
        let router = MOICACallbackRouter()
        async let waited: Void = router.waitForCallback(transactionID: "TXN-x")
        while await router.pendingCount() == 0 { await Task.yield() }

        #expect(await router.handle(URL(string: raw)!) == false)
        #expect(await router.pendingCount() == 1)

        await router.cancelWait(transactionID: "TXN-x")
        await waited
    }

    /// `rtn_val` travels base64url-encoded, so a transaction id containing
    /// characters that differ between base64 and base64url must survive.
    @Test func base64URLValuesRoundTrip() async {
        let router = MOICACallbackRouter()
        // Chosen so standard base64 yields '+' and '/', which base64url replaces.
        let transaction = "TXN-\u{00FF}\u{00FE}?~"
        async let waited: Void = router.waitForCallback(transactionID: transaction)
        while await router.pendingCount() == 0 { await Task.yield() }

        #expect(await router.handle(callbackURL(returnValue: transaction)))
        await waited
    }

    @Test func cancellingAWaitReleasesIt() async {
        let router = MOICACallbackRouter()
        async let waited: Void = router.waitForCallback(transactionID: "TXN-cancel")
        while await router.pendingCount() == 0 { await Task.yield() }

        await router.cancelWait(transactionID: "TXN-cancel")
        await waited
        #expect(await router.pendingCount() == 0)
    }

    /// A second wait on the same id must not strand the first continuation.
    @Test func replacingAWaiterReleasesTheOldOne() async {
        let router = MOICACallbackRouter()
        async let first: Void = router.waitForCallback(transactionID: "TXN-dup")
        while await router.pendingCount() == 0 { await Task.yield() }

        async let second: Void = router.waitForCallback(transactionID: "TXN-dup")
        // The first is resumed by the replacement; if it were dropped instead,
        // this await would hang and the test would time out.
        await first

        _ = await router.handle(callbackURL(returnValue: "TXN-dup"))
        await second
        #expect(await router.pendingCount() == 0)
    }
}
