//
//  WalletCardMask.swift
//  backupTW
//
//  Masking a sensitive value for a glanceable card face.
//
//  # Why this is its own pure function
//
//  The home screen is the most over-the-shoulder-readable surface in the app —
//  the exact reasoning `CardInventory` gives for keeping claim *values* off the
//  list entirely. The wallet card faces now show a little more than the list did
//  (a name, a masked number) because a card that showed nothing would not be a
//  card. That makes the masking the load-bearing part: a 統一編號, a 駕照號碼 or a
//  門號 must **never** appear in full on this surface, and "never" is a claim you
//  can only keep if it is one small function with tests around it, not a format
//  string scattered through a view.
//
//  So the rule lives here, alone, and `WalletCardFactory` calls it. The full
//  value is only ever shown on the detail screens, behind their existing
//  two-step reveal.
//

import Foundation

/// Turns a sensitive identifier into its masked display form.
enum WalletCardMask {

    /// The character stood in for each hidden position. Matches the design's
    /// solid dot rather than an asterisk.
    static let dot: Character = "●"

    /// Keeps the first `leading` and last `trailing` characters, replacing
    /// everything between them with `dot`. e.g. `A234567890` → `A2●●●●●●●0`.
    ///
    /// # The one invariant this must never break
    ///
    /// The result must never reveal the whole value. So when the value is too
    /// short to keep both ends without the kept ends *being* the whole value
    /// (`count <= leading + trailing`), every character is masked instead — a
    /// four-digit value does not get "show the first two and last one and mask
    /// the single middle one", which would be three of four characters in the
    /// clear. Better to show four dots than to leak a short number.
    ///
    /// Counted in `Character`, so a value with combining marks or non-ASCII
    /// digits is measured the way a reader sees it.
    static func masked(_ raw: String, leading: Int = 2, trailing: Int = 1) -> String {
        let characters = Array(raw)
        let count = characters.count
        guard count > 0 else { return "" }

        // Too short to keep any real value in the clear: mask the whole thing.
        guard count > leading + trailing else {
            return String(repeating: dot, count: count)
        }

        let head = String(characters.prefix(leading))
        let tail = String(characters.suffix(trailing))
        let hidden = String(repeating: dot, count: count - leading - trailing)
        return head + hidden + tail
    }

    /// The character stood in for each hidden character of a *name*. A hollow
    /// circle (U+3007 〇), the conventional Chinese redaction glyph, so a masked
    /// name reads as a name with characters withheld rather than as a number.
    static let nameDot: Character = "〇"

    /// Masks a personal name for a glanceable card face: keeps the **surname**
    /// (the first character) and replaces every following character with `〇`.
    /// 王小明 → 王〇〇, 王明 → 王〇.
    ///
    /// # Why the card now masks the name too
    ///
    /// Phase 1 shipped the name in full because a document cannot withhold it —
    /// but that argument is about the *detail* screen, where the holder has
    /// deliberately opened the card. The home screen is the over-the-shoulder
    /// surface, and a full name there is as identifying as the number beside it.
    /// So the card face keeps only enough to recognise *which* of your own cards
    /// this is (the surname), and the full name stays behind the detail screen's
    /// existing reveal, exactly like the 統一編號.
    ///
    /// # The same invariant as `masked`: never show the whole value
    ///
    /// A one-character name is masked entirely (→ 〇), because keeping "the first
    /// character" of a single-character name would be keeping all of it. Better a
    /// lone 〇 than a name shown whole on the one surface this file exists to keep
    /// it off. Counted in `Character` so a surname built from combining scalars is
    /// treated as the one glyph a reader sees.
    static func maskedName(_ raw: String) -> String {
        let characters = Array(raw)
        let count = characters.count
        guard count > 0 else { return "" }
        // One character is the whole name: mask it rather than reveal it.
        guard count > 1 else { return String(nameDot) }
        return String(characters.prefix(1)) + String(repeating: nameDot, count: count - 1)
    }

    /// Whether a claim key names a sensitive *identifier* — the value picked as a
    /// card's primary number and run through `masked`. Names are deliberately
    /// *not* here: a name is not an identifier number, and it has its own
    /// display treatment (`maskedName`, surname kept). Keeping it out of this set
    /// is why a `name` claim is never chosen as the masked primary. Everything
    /// that is a number, an ID, a phone or a date of birth is.
    ///
    /// Matched case-insensitively on substrings so a variant key (`id_number`,
    /// `nationalId`, `unifiedNo`, `msisdn`, `mobile_no`, `roc_birthday`) is
    /// caught without a table that has to be complete to be safe. When in doubt
    /// this errs toward masking: an over-masked non-sensitive field is a cosmetic
    /// loss, an under-masked ID number is the failure this whole file exists to
    /// prevent.
    static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        let needles = ["id_number", "idnumber", "unifiedno", "unified_no", "nationalid",
                       "national_id", "serialnumber", "serial_no", "license", "licence",
                       "phone", "mobile", "msisdn", "tel", "birth", "dob", "passport"]
        return needles.contains { lowered.contains($0) }
    }
}
