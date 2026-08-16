//
//  VerdictSymbolTests.swift
//  backupTWTests
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@MainActor
struct VerdictSymbolTests {

    /// The defect this type exists to fix: an element VoiceOver stops on and
    /// then has nothing to say about.
    @Test(arguments: [VerdictSymbol.passing, VerdictSymbol.warning])
    func aVerdictGlyphSaysSomething(_ name: String) {
        let view = VerdictSymbol.view(name, .systemGreen)
        #expect(view.isAccessibilityElement)
        let label = view.accessibilityLabel ?? ""
        #expect(!label.isEmpty, "\(name) stops the cursor and says nothing")
        // The identifier is the UI tests' hook and is English API vocabulary.
        // If the label is just that, nothing was gained.
        #expect(label != name, "the spoken label is the symbol's API name")
    }

    /// Identifier and label serve different audiences and must both survive.
    /// They were previously one string, which only the tests could hear.
    @Test func theTestHookAndTheSpokenLabelBothSurvive() {
        let view = VerdictSymbol.view(VerdictSymbol.passing, .systemGreen)
        #expect(view.accessibilityIdentifier == VerdictSymbol.passing)
        #expect(view.accessibilityLabel == VerdictSymbol.spokenLabel(for: VerdictSymbol.passing))
    }

    /// A glyph nobody added to the table must not go silent.
    @Test func anUnknownSymbolFallsBackLoudlyRatherThanSilently() {
        #expect(VerdictSymbol.spokenLabel(for: "bolt.fill") == "bolt.fill")
        #expect(!VerdictSymbol.view("bolt.fill", .systemGray).accessibilityLabel!.isEmpty)
    }

    /// The other half of the fix: a verdict drawn at a fixed size beside text
    /// that scales is a speck at AX5.
    @Test func theGlyphScalesWithTheTextBesideIt() {
        #expect(VerdictSymbol.view(VerdictSymbol.passing, .systemGreen)
                    .preferredSymbolConfiguration != nil)
    }

    /// The two verdicts must not read the same. They are drawn in different
    /// colours, and colour is exactly what a VoiceOver user does not get.
    @Test func passingAndWarningDoNotSoundAlike() {
        #expect(VerdictSymbol.spokenLabel(for: VerdictSymbol.passing)
                != VerdictSymbol.spokenLabel(for: VerdictSymbol.warning))
    }
}
