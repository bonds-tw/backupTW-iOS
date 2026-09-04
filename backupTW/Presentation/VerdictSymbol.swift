//
//  VerdictSymbol.swift
//  backupTW
//
//  What a verdict glyph says out loud.
//

import UIKit

/// The spoken form of the tick-or-warning symbols the self-check screens use.
///
/// # Why this exists rather than a literal at each call site
///
/// Both `DiagnosticsViewController` and `ZKProofViewController` build these
/// glyphs with a helper whose comment says the verdict must be "readable as
/// something other than the colour of a glyph" — and both then set only
/// `accessibilityIdentifier`, which is a UI-test hook that VoiceOver never
/// reads. So the element stopped the cursor and said nothing, which is worse
/// than not being an element at all: the reader knows something is there and
/// cannot find out what.
///
/// Two copies of a symbol-to-sentence table is how the two screens end up
/// describing the same glyph differently, so there is one, here, with a test.
enum VerdictSymbol {

    static let passing = "checkmark.circle.fill"
    static let warning = "exclamationmark.triangle.fill"
    /// The verdict-card forms (design system §9.2): seals for the pass/fail
    /// judgement a checker reads at a counter, the triangle shared with the
    /// self-check warnings.
    static let sealPassing = "checkmark.seal.fill"
    static let sealRefused = "xmark.seal.fill"

    /// What VoiceOver should say. Not the symbol's own name, which is English
    /// API vocabulary, and not "green tick", which describes the drawing rather
    /// than the finding.
    static func spokenLabel(for systemName: String) -> String {
        switch systemName {
        case passing, sealPassing: return NSLocalizedString("Passed", comment: "Spoken form of the self-check tick")
        case warning: return NSLocalizedString("Needs attention", comment: "Spoken form of the self-check warning")
        case sealRefused: return NSLocalizedString("Refused", comment: "Spoken form of the verdict refusal")
        default:
            // A glyph this table does not know must not be silent. Returning the
            // raw name is poor speech and is still strictly better than a stop
            // with nothing to hear, and it is loud enough that whoever adds the
            // next symbol notices.
            return systemName
        }
    }

    /// A glyph built to be both seen and heard.
    ///
    /// `preferredSymbolConfiguration` is the other half: without it the symbol
    /// is drawn at a fixed size next to text that scales, so at AX5 the verdict
    /// is a speck beside its own sentence.
    static func view(_ systemName: String, _ colour: UIColor) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: systemName))
        view.tintColor = colour
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        view.isAccessibilityElement = true
        // Identifier for the tests, label for the person. They are different
        // audiences and were previously served by one string that only one of
        // them could hear.
        view.accessibilityIdentifier = systemName
        view.accessibilityLabel = spokenLabel(for: systemName)
        return view
    }
}
