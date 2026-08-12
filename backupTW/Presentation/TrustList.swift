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
        /// An identifier outside printable ASCII. See `allowedInIdentifier`.
        case identifierNotPrintableASCII(String)
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
        var set = CharacterSet.controlCharacters          // C0 and C1
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
    func validate(expectedCommitment: String? = nil) throws {
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
        }
    }

    // MARK: - Asking

    func entry(for issuer: String) -> Entry? {
        entries.first { $0.id == issuer }
    }

    func trusts(_ issuer: String) -> Bool {
        entry(for: issuer) != nil
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
    static func decoded(from data: Data, expectedCommitment: String? = nil) throws -> TrustList {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let list = TrustList(version: wire.version,
                             publishedAt: wire.publishedAt,
                             entries: wire.entries)
        try list.validate(expectedCommitment: expectedCommitment)
        return list
    }
}
