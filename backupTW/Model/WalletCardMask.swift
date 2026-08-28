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

    /// Whether a claim key names something that must be masked before it reaches
    /// a card face. Names are deliberately *not* here — a name cannot be withheld
    /// from a document that carries it, so masking it would be a false promise
    /// (see `CardCapability.selfIssued`). Everything that is a number, an ID, a
    /// phone or a date of birth is.
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
