//
//  TrustList.swift
//  backupTW
//
//  Who a verifier is willing to believe, and how that set can change in an
//  emergency without anybody being able to change it quietly.
//

import Foundation
import CryptoKit

/// The set of issuers a verifier accepts, as a document that can be carried
/// offline and pinned by its digest.
///
/// # What this is for
///
/// Whitepaper §5.2 asks for the ability to **switch to a mirror issuer in an
/// emergency**. That requirement is easy to state and easy to implement badly:
/// the naive version is a list the app fetches at launch, which is a list an
/// attacker can swap during exactly the emergency it exists for, and which does
/// not work at all offline — the condition the whole project is built around.
///
/// So the shape here is deliberately not a fetch. It is a document with a
/// **commitment value**: a digest over the canonical serialisation, which can be
/// published anywhere — a repo, a newspaper, an on-chain root — and compared
/// byte for byte on a phone that has no network. Anchoring that digest on-chain
/// is a later step, and this type is written so that step changes nothing here:
/// it adds a source for `expectedCommitment`, not a new format.
///
/// # Why the commitment is over a canonical form
///
/// Two verifiers holding what they believe is the same list must compute the
/// same digest, or the comparison is worthless. JSON does not give that for free
/// — key order and whitespace vary by encoder — so the digest is taken over a
/// canonical serialisation defined here rather than over "the file as it
/// arrived". A list that round-trips to different bytes is a list two honest
/// parties can disagree about.
///
/// # What this does not do
///
/// It does not sign anything, and it deliberately carries no signature field.
/// A signature would raise the question "signed by whom", and the answer during
/// a constitutional emergency — when the issuing authority may be the party that
/// has become unavailable or untrustworthy — is exactly what nobody can agree
/// on in advance. A digest published in many places is a weaker claim that
/// survives that argument: it says "this is the list I am using", and lets the
/// people relying on it check they are using the same one.
struct TrustList: Equatable, Sendable {

    /// One accepted issuer.
    struct Entry: Equatable, Sendable, Codable {

        /// The issuer's identifier. A `did:key` for a device- or mirror-issued
        /// credential; for MOICA the RSA modulus is what actually gets checked,
        /// and this is the label a person reads.
        let id: String

        /// What a human should see. Never rendered from `id`: a screen showing
        /// a bare DID during an emergency asks someone to make a trust decision
        /// about a string they cannot evaluate.
        let displayName: String

        /// Why this issuer is on the list. Present so that a list which has
        /// grown over time can be audited by reading it.
        let note: String

        /// Whether this entry is a mirror standing in for an unavailable
        /// primary issuer, rather than a primary issuer itself.
        let isMirror: Bool
    }

    /// Bumped when the meaning of any field changes; an unrecognised version is
    /// refused rather than guessed at.
    static let currentVersion = 1

    let version: Int

    /// When this list was published, as an ISO 8601 string. Kept as the string
    /// the publisher wrote so the digest is over what they published, not over
    /// this build's re-rendering of it.
    let publishedAt: String

    let entries: [Entry]

    enum TrustListError: Error, Equatable {
        case unsupportedVersion(Int)
        case commitmentMismatch(expected: String, actual: String)
        case duplicateIssuer(String)
        case empty
        /// A field contained one of the two characters the canonical form uses
        /// to separate things.
        ///
        /// **This is the fix for a collision that worked.** The canonical form
        /// joins fields with tab and rows with newline, and nothing used to
        /// forbid either inside a field — so a `note`, which exists to be
        /// written by a human and is therefore the field most likely to arrive
        /// through a pull request, could carry `"\n" + a whole forged row`:
        ///
        ///     A: one entry,  note = "MOICA G3\ndid:key:zZEvil\tmirror\t…\t…"
        ///     B: two entries, the second being did:key:zZEvil as a mirror
        ///
        /// Byte-identical canonical forms, one commitment
        /// (`114cfd428ce4…`, reproduced 2026-08-13), and `A.trusts("did:key:zZEvil")`
        /// is false while `B.trusts(…)` is true. Both pass
        /// `validate(expectedCommitment:)`. Publishing a commitment for A would
        /// have been publishing an attestation whose human reading and machine
        /// reading differ — the worst possible thing to put in a newspaper.
        ///
        /// Refusing the two delimiters is what makes the encoding injective,
        /// and refusing is chosen over escaping because the format's other job
        /// is to be reproducible by hand on a machine with no tooling.
        case fieldContainsDelimiter(field: String)
        /// A field long enough to make the whole document unwieldy.
        case fieldTooLong(field: String, bytes: Int)
        /// An identifier outside printable ASCII, or empty. See
        /// `allowedInIdentifier`.
        case identifierNotPrintableASCII(String)
        /// The bytes parsed, but they are not the bytes this build emits for
        /// what they parsed to — duplicate keys, unknown keys, or different
        /// formatting. See `decoded(from:)`.
        case notCanonicalJSON
    }

    /// Everything that may never appear inside a value.
    ///
    /// The two delimiters, plus the rest of C0/C1 and the bidirectional
    /// overrides. `\r` is here because a file that made a round trip through a
    /// Windows editor would otherwise change its own digest; the overrides are
    /// here for the same reason `UntrustedText` strips them — a value that can
    /// reorder the line it is printed on can make a human read a different list
    /// from the one the machine hashed, and this format's whole job is that
    /// those two readings agree.
    private static let forbidden: CharacterSet = {
        // **What this set actually is, measured rather than described.**
        //
        // An adversarial pass swept all 0x110000 scalars against it and reported
        // two things worth writing down. First, `CharacterSet.controlCharacters`
        // on this platform is **Cc ∪ Cf — 235 scalars, not the 74 of C0 and C1**,
        // which an earlier version of this comment claimed. The extra 161 are
        // the format characters, and they are the ones that matter: ZWSP, the
        // word joiners, U+00AD, U+061C, U+FEFF and the whole U+E0000 tag block
        // are all in Cf and all already refused. The comment was underselling
        // the code, which is the safer direction to be wrong in and still wrong.
        //
        // Second, `rangeOfCharacter(from:)` matches on **scalars, not
        // Characters** — verified against CRLF as a single Character, a ZWJ
        // family emoji, and an astral tag sequence, all caught. So a forbidden
        // scalar cannot hide inside a grapheme cluster.
        //
        // What the set does **not** cover on its own is the two that matter most
        // here.
        //
        // **U+2028 LINE SEPARATOR is category Zl and U+2029 is Zp.** Neither is a
        // control character, so both passed — and every line-splitter on the
        // machine treats them as line breaks: Foundation's `enumerateLines`,
        // `CharacterSet.newlines`, Swift's `Character.isNewline`, CoreText when
        // it draws a label, and Python's `splitlines`. An adversarial pass built
        // the document that follows from that, and it is the worst shape this
        // format has:
        //
        //     note = "MOICA G3\u{2028}did:key:zBackup<wide spaces>…\u{2028}end"
        //
        // The published bytes then read, to a human and to a Python verifier, as
        // a two-entry list ending at `end` whose second issuer is `zBackup`,
        // while the app trusts `zZEvil` on a line *after* the terminator. Header
        // count and terminator both agree with the false reading — every check
        // the format gave a reader to perform passes.
        //
        // **This repository had already found this exact gap and fixed it, in
        // `UntrustedText`, on the display path.** The lesson existed and was
        // written down; it just had not been carried across to the path where
        // the bytes are hashed rather than drawn. `.newlines` is what carries it.
        var set = CharacterSet.controlCharacters.union(.newlines)
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")  // LRE…RLO
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")  // LRI…PDI
        return set
    }()

    /// What an `id` may contain: printable ASCII, and nothing else.
    ///
    /// Not decoration. Sorting is what decides row order and therefore the
    /// digest, and Swift's `String.<` is normalisation-aware: measured
    /// 2026-08-13, `["e\u{0301}x", "éa"]` sorts as `[éa, éx]` in Swift and
    /// `[éx, éa]` by UTF-8 bytes, because Swift compares the *characters* while
    /// the bytes put `e` (0x65) before `Ã©` (0xC3 0xA9). On ASCII, Latin-1 and
    /// CJK the two agree — so the hazard is narrow, and narrow is worse: it
    /// waits for the first identifier somebody pastes in a decomposed form.
    ///
    /// Two implementations that sort differently compute different commitments
    /// for the same list, which is a legitimate emergency rotation failing
    /// across a whole fleet, in a way indistinguishable from an attack.
    /// Restricting `id` removes the case, and `canonicalForm` sorts by bytes
    /// anyway so that the guarantee does not rest on the restriction alone.
    private static let allowedInIdentifier: CharacterSet = {
        CharacterSet(charactersIn: UnicodeScalar(0x21)...UnicodeScalar(0x7E))
    }()

    /// A ceiling per field, so a list cannot be made enormous by one value.
    private static let maximumFieldLength = 512

    // MARK: - Commitment

    /// SHA-256 over the canonical serialisation, lowercase hex.
    ///
    /// This is the value that gets published, printed, read aloud on the radio,
    /// or eventually anchored on-chain. It is over the canonical form rather
    /// than over the received bytes precisely so that "the same list" means the
    /// same thing to two people who obtained it by different routes.
    var commitment: String {
        SHA256.hash(data: Data(canonicalForm.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes the digest is taken over.
    ///
    /// Line-oriented and explicit rather than JSON: the property that matters is
    /// that two implementations agree byte for byte, and a format a person can
    /// reproduce by hand — including on a machine that has no JSON canonicaliser
    /// — is a format that can be checked when it matters. Entries are sorted by
    /// `id` so that publication order cannot change the digest.
    var canonicalForm: String {
        // The entry count is in the header, so a row cannot be smuggled in or
        // out without the digest moving even if some future field escapes the
        // delimiter check. Belt as well as braces: the check below is what makes
        // the encoding injective, and this is what makes a failure of that check
        // visible rather than silent.
        var lines = ["bonds.tw/trust-list/v\(version)/\(entries.count)", publishedAt]
        // Sorted by UTF-8 bytes, explicitly, rather than by `String.<` — see
        // `allowedInIdentifier` for the measurement. A second implementation in
        // Python, Go or on paper sorts bytes; this has to agree with it.
        for entry in entries.sorted(by: { Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }) {
            // Tab-separated, and the fields that feed the digest are only the
            // ones that carry meaning for a trust decision. `displayName` and
            // `note` are included too: a list that could be relabelled without
            // changing its digest would let somebody rename an issuer to
            // impersonate another while still matching a published value.
            lines.append([entry.id,
                          entry.isMirror ? "mirror" : "primary",
                          entry.displayName,
                          entry.note].joined(separator: "\t"))
        }
        // An explicit terminator, so a truncated file is not a shorter list
        // with a different-but-valid digest — it is a file that does not parse.
        lines.append("end")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Checks the list is well formed and, when an expected commitment is
    /// supplied, that it is the list that was published.
    ///
    /// `expectedCommitment` is optional and its absence is **not** a pass: it
    /// means "nobody told this device which list to expect", and the caller has
    /// to render that as the weaker statement it is. Making it non-optional
    /// would have been stricter but would have made the type unusable in the
    /// state every device starts in.
    /// Where a validated list's authority came from.
    ///
    /// # Why this is a return value and not a comment
    ///
    /// `validate(expectedCommitment:)` used to return `Void`, and its
    /// documentation said that a missing expectation 「is **not** a pass: it
    /// means 'nobody told this device which list to expect'」. That sentence was
    /// correct and it was enforced by nothing. A caller could write
    /// `try list.validate()` and carry on as though the list had been confirmed,
    /// and the compiler would agree with them.
    ///
    /// This project's own rule is that a guarantee enforced by one caller is not
    /// a guarantee. So the distinction moves into the type: every caller now has
    /// to look at what came back, and a screen that says 「已確認」 has to have a
    /// value in its hand that says so.
    ///
    /// # Only cases that can actually be produced
    ///
    /// Two, deliberately. There is no `pinnedInBinary` yet because there is no
    /// pinned commitment yet, and no `walkedFromPinned` because there is no
    /// chain to walk. A case with no producing path is an invitation to somebody
    /// to add one later without the review that should come with it — and when
    /// those paths do land, adding the case will break every `switch` that
    /// consumes this, which is exactly the audit worth being forced into.
    enum Provenance: Equatable {
        /// The list matched a commitment the caller supplied. Where the caller
        /// got that value is the caller's business and is *not* established
        /// here — matching a value somebody typed in proves the list is the one
        /// they meant, and nothing about whether they meant the right one.
        case matchedSuppliedExpectation(commitment: String)
        /// Well formed, and nobody said which list to expect. **Not a pass.**
        case unconfirmed
    }

    @discardableResult
    func validate(expectedCommitment: String? = nil) throws -> Provenance {
        guard version == Self.currentVersion else {
            throw TrustListError.unsupportedVersion(version)
        }
        guard !entries.isEmpty else { throw TrustListError.empty }

        // Checked before anything else that reads a field, and checked on every
        // field including the ones that look like metadata: `publishedAt` is a
        // string somebody types, and nobody audits it as though it carried
        // trust.
        func check(_ name: String, _ value: String) throws {
            guard value.rangeOfCharacter(from: Self.forbidden) == nil else {
                throw TrustListError.fieldContainsDelimiter(field: name)
            }
            guard value.utf8.count <= Self.maximumFieldLength else {
                throw TrustListError.fieldTooLong(field: name, bytes: value.utf8.count)
            }
        }
        try check("publishedAt", publishedAt)
        for entry in entries {
            try check("id of \(entry.id)", entry.id)
            try check("displayName of \(entry.id)", entry.displayName)
            try check("note of \(entry.id)", entry.note)
            // Non-empty first: `allSatisfy` over nothing is vacuously true, so
            // an empty identifier used to sail through and `trusts("")` answered
            // yes — a credential whose issuer field is missing or empty would
            // have been on the list.
            guard !entry.id.isEmpty else {
                throw TrustListError.identifierNotPrintableASCII(entry.id)
            }
            guard entry.id.unicodeScalars.allSatisfy(Self.allowedInIdentifier.contains) else {
                throw TrustListError.identifierNotPrintableASCII(entry.id)
            }
        }

        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(entry.id).inserted else {
                // Two entries for one issuer is not a harmless duplicate: they
                // can disagree about `isMirror`, and which one wins would then
                // depend on iteration order.
                throw TrustListError.duplicateIssuer(entry.id)
            }
        }

        if let expectedCommitment {
            let actual = commitment
            // Constant-time-ish: these are public values so timing does not
            // matter here, but the comparison is lowercased on both sides
            // because a hex digest that differs only in case is the same digest
            // and refusing it would be a false alarm.
            guard actual.lowercased() == expectedCommitment.lowercased() else {
                throw TrustListError.commitmentMismatch(expected: expectedCommitment,
                                                        actual: actual)
            }
            return .matchedSuppliedExpectation(commitment: actual)
        }
        return .unconfirmed
    }

    // MARK: - Asking

    func entry(for issuer: String) -> Entry? {
        entries.first { $0.id == issuer }
    }

    /// Whether this list names `issuer`.
    ///
    /// Compared by UTF-8 bytes rather than by Swift string equality, which is
    /// Unicode canonical equivalence — so `entry(for:)` would answer yes to an
    /// identifier that is *equivalent to* a listed one without being the same
    /// bytes, while `canonicalForm` hashed only the bytes. Equality and
    /// serialisation disagreeing is precisely what this format exists to
    /// prevent, and `allowedInIdentifier` already makes the case unreachable by
    /// restricting identifiers to printable ASCII.
    ///
    /// Belt and braces on purpose: the restriction is enforced in `validate()`,
    /// and an unvalidated list can still be asked this question.
    func trusts(_ issuer: String) -> Bool {
        let wanted = Array(issuer.utf8)
        return entries.contains { Array($0.id.utf8) == wanted }
    }

    // MARK: - Wire form

    private struct Wire: Codable {
        let version: Int
        let publishedAt: String
        let entries: [Entry]
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(Wire(version: version,
                                       publishedAt: publishedAt,
                                       entries: entries))
    }

    /// Decodes and validates in one step, so there is no window in which an
    /// unvalidated list exists and could be asked a question.
    ///
    /// # The published bytes must be exactly the bytes this type would emit
    ///
    /// Decoding alone is not enough, and this is the second thing an adversarial
    /// pass found. The commitment is computed from the *parsed* fields, so
    /// anything in the JSON that the parse does not model is invisible to it —
    /// and two readers do not have to agree on what the parse is:
    ///
    ///   * **Duplicate keys.** Measured 2026-08-13: given
    ///     `{"publishedAt":"A","publishedAt":"B"}`, Foundation's `JSONDecoder`
    ///     takes **A** and Python's `json` takes **B**. Every other mainstream
    ///     parser follows the last-wins reading. So one published file has two
    ///     commitments depending on who reads it, which is precisely the
    ///     disagreement between two honest parties this format exists to prevent.
    ///   * **Unknown keys.** A `"note"` at the top level, or an extra field on an
    ///     entry, is silently discarded — so a reviewer can read a
    ///     trust-relevant annotation in the published file that no digest covers.
    ///
    /// Both close with one rule: **re-encode the parse and require it to equal
    /// the input, byte for byte.** A document with duplicate keys does not
    /// survive it, nor does one carrying anything this build does not model. The
    /// cost is that a published list has to be exactly what `encoded()` emits —
    /// sorted keys, pretty-printed — which for a commitment-pinned document is a
    /// property rather than a restriction.
    static func decoded(from data: Data,
                        expectedCommitment: String? = nil) throws -> (list: TrustList,
                                                                      provenance: Provenance) {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let list = TrustList(version: wire.version,
                             publishedAt: wire.publishedAt,
                             entries: wire.entries)
        let provenance = try list.validate(expectedCommitment: expectedCommitment)
        guard try list.encoded() == data else {
            throw TrustListError.notCanonicalJSON
        }
        // Returned as a pair rather than stashed on the list, so that a caller
        // cannot hold a `TrustList` and forget how it was confirmed. The value
        // travels with the thing it is a fact about.
        return (list, provenance)
    }
}
