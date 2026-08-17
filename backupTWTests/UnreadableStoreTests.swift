//
//  UnreadableStoreTests.swift
//  backupTWTests
//
//  A store that would not open is not a phone with no documents.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// # The substitution
///
/// `CredentialStore.init` gates on two *write*-side actions — `createDirectory`
/// and the iCloud-exclusion `setResourceValues` — so an intact, readable
/// document becomes 「there is nothing on this phone」 because a backup-exclusion
/// xattr could not be written. `try? … ?? []` did that at the two places that
/// read the store for display.
///
/// The store's own next layer refuses exactly this substitution and says why:
/// reporting an unreadable file as 「you have no document」 sends somebody to
/// apply again for one they already have. `CardInventory` says reading decides
/// what a row *says*, never whether it exists. Both disciplines were bypassed
/// one level above them.
///
/// And the route the old screens recommended could not work: issuance saves
/// through the same constructor. So the advice cost a second 戶籍謄本 and a
/// second 身分證統一編號, and then failed.
@MainActor
struct UnreadableStoreTests {

    private static func labels(in view: UIView) -> [String] {
        var found: [String] = []
        for subview in view.subviews {
            if let label = subview as? UILabel, let text = label.text { found.append(text) }
            found.append(contentsOf: labels(in: subview))
        }
        return found
    }

    /// The presentation screen says it is about this phone, and offers no route
    /// that costs identity data again.
    @Test func theShowScreenDoesNotTellYouToMakeAnotherOne() {
        let screen = PresentCredentialViewController(
            holder: HolderPresentation(store: EmptyCredentialStore()), storeIsReadable: false)
        screen.loadViewIfNeeded()
        let text = Self.labels(in: screen.view).joined(separator: "\n")

        #expect(!text.isEmpty)
        // Not the empty-phone screen.
        for empty in ["No document to show yet", "還沒有可以出示的證件",
                      "Create a valid document from the home screen first", "回首頁"] {
            #expect(!text.contains(empty),
                    "an unreadable store is being drawn as an empty phone: \(text)")
        }
        // And it is about this phone.
        #expect(text.contains("this phone") || text.contains("這支手機"),
                "the screen never says the problem is this phone: \(text)")
    }

    /// The same screen with a genuinely empty store keeps its own wording.
    @Test func anEmptyPhoneStillGetsTheEmptyPhoneScreen() {
        let screen = PresentCredentialViewController(
            holder: HolderPresentation(store: EmptyCredentialStore()), storeIsReadable: true)
        screen.loadViewIfNeeded()
        let text = Self.labels(in: screen.view).joined(separator: "\n")
        #expect(text.contains("No document to show yet") || text.contains("還沒有可以出示的證件"),
                "the empty case lost its own screen: \(text)")
    }
}
