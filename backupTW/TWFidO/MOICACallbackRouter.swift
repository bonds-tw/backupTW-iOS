//
//  MOICACallbackRouter.swift
//  backupTW
//

import Foundation

/// Receives the `backuptw://` return leg of the TW FidO App-to-App flow.
///
/// The scheme was registered in `Info.plist` before anything listened on it,
/// which is the failure worth naming: a registered scheme makes the system
/// launch this app on the callback and then do nothing at all, which looks
/// identical to the deep link never firing. Registration is not a closed loop.
///
/// What comes back is only a wake-up. MOICA returns the `rtn_val` we sent and
/// nothing else of value — the signature itself is fetched from
/// `getAthOrSignResult`, authenticated by `idp_checksum`. So this type has one
/// job: decide whether an inbound URL is *our* pending request, and if so let
/// the waiting caller stop polling early. Anything that arrives while nothing
/// is pending is discarded.
///
/// That distinction matters for more than tidiness. Any app on the device can
/// register `backuptw://` too and open it with arbitrary parameters, so an
/// inbound URL is untrusted input, not a result. Treating it as a signal to
/// re-check the server — rather than as the answer — means a forged callback
/// can at worst cause one extra authenticated request.
actor MOICACallbackRouter {

    static let shared = MOICACallbackRouter()

    /// The scheme registered in `Info.plist` under `CFBundleURLTypes`.
    static let scheme = "backuptw"

    private var pending: [String: CheckedContinuation<Void, Never>] = [:]

    /// `rtn_val` is sent base64url-encoded, so it comes back encoded too.
    private static func decodedReturnValue(from url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "rtn_val" })?.value,
              !raw.isEmpty
        else {
            return nil
        }
        var padded = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url drops padding; Data(base64Encoded:) requires it.
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    /// Suspends until the callback for `transactionID` arrives, or until the
    /// caller's own timeout wins — whichever is first. There is deliberately no
    /// timeout here: this is a shortcut past polling, not a replacement for it,
    /// and a callback that never comes must not be the thing that decides the
    /// flow has failed. The user may complete the signature and return via the
    /// app switcher rather than the deep link, in which case polling is the
    /// only path that ever completes.
    func waitForCallback(transactionID: String) async {
        await withCheckedContinuation { continuation in
            // Replacing an existing waiter would strand it forever, so the older
            // one is resumed rather than dropped.
            if let stale = pending.removeValue(forKey: transactionID) {
                stale.resume()
            }
            pending[transactionID] = continuation
        }
    }

    /// Call from `scene(_:openURLContexts:)`.
    ///
    /// Returns whether the URL matched something we were waiting for, so the
    /// caller can tell a real callback from an unrelated launch.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.scheme,
              let transactionID = Self.decodedReturnValue(from: url),
              let continuation = pending.removeValue(forKey: transactionID)
        else {
            return false
        }
        continuation.resume()
        return true
    }

    /// Abandons a wait whose flow ended some other way, so the continuation is
    /// not held for the lifetime of the process.
    func cancelWait(transactionID: String) {
        pending.removeValue(forKey: transactionID)?.resume()
    }

    /// Test seam.
    func pendingCount() -> Int { pending.count }
}
