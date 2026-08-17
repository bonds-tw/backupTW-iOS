//
//  ZKLinkSendCopyTests.swift
//  backupTWTests
//
//  A sentence that is written, translated, positioned — and never drawn.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// # The defect
///
/// `buildInterface()` set `detailLabel.text` to 「%@ · nothing is sent anywhere
/// else, and nothing is kept afterwards」, and `viewDidLoad` called `startLink()`
/// immediately after, overwriting the same label in the same runloop with the
/// duration estimate. `show(.starting)` wrote it a third time. Three assignments
/// to one label, no state that ever put the first back — so the sentence was not
/// briefly visible, it was never visible.
///
/// It went out while the estimate went in: the note asking for the estimate
/// described this screen as 「four lines of text」, so it was written into the
/// fourth line rather than added as a fifth. The line count did not change.
@MainActor
struct ZKLinkSendCopyTests {

    private static func text(of controller: UIViewController) -> String {
        func walk(_ view: UIView) -> [String] {
            var found: [String] = []
            for subview in view.subviews {
                if let label = subview as? UILabel, let text = label.text { found.append(text) }
                found.append(contentsOf: walk(subview))
            }
            return found
        }
        return walk(controller.view).joined(separator: "\n")
    }

    private static func screen() -> ZKLinkSendViewController {
        let controller = ZKLinkSendViewController(
            payload: Data(count: 398_181),
            engagement: ZKLinkEngagement(serviceID: UUID(), purpose: "Identity check"))
        controller.loadViewIfNeeded()
        return controller
    }

    /// Both sentences, at once, after the radio has started.
    @Test func thePrivacySentenceSurvivesTheEstimate() {
        let text = Self.text(of: Self.screen())
        #expect(text.contains("nothing is kept afterwards") || text.contains("事後也不會留下"),
                "the privacy sentence is not on screen: \(text)")
        #expect(text.contains("Keep this screen open") || text.contains("請保持這個畫面開著"),
                "the estimate is not on screen: \(text)")
    }

    /// And through every state the radio reports, since it was a state
    /// transition that ate it.
    @Test func noRadioStateOverwritesThePrivacySentence() {
        let screen = Self.screen()
        for state: BluetoothLinkState in [.starting, .waiting, .transferring(fraction: 0.5),
                                          .failed(reason: "x")] {
            screen.showForReview(state)
            let text = Self.text(of: screen)
            #expect(text.contains("nothing is kept afterwards") || text.contains("事後也不會留下"),
                    "\(state) overwrote the privacy sentence")
        }
    }
}
