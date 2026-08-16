//
//  UntrustedText.swift
//  backupTW
//

import Foundation

/// Text that arrived inside a stranger's document, prepared for a screen.
///
/// # Why this exists
///
/// `OfflineVerifier` answers one question — were these bytes signed by the key
/// the presenter's `did:key` names — and it answers it correctly. It does not,
/// and cannot, say anything about whether the *contents* are true. That is the
/// whole point of `VerificationCaveat.selfIssuedByTheHolder`: anybody can
/// generate a P-256 key, self-issue a credential saying whatever they like, and
/// present it. It will verify, because it *is* validly signed. It is signed by
/// a stranger.
///
/// So every string in `VerifiedPresentation.claims` is attacker-chosen, exactly
/// as much as `PresentationRequest.purpose` is — and `PresentationRequest.init`
/// has stripped control characters out of `purpose` since it was written,
/// calling it 「a display-integrity check, not tidiness」. The same threat came
/// down the claims path unfiltered until a review put
/// `name = "\u{202E}王小明\u{202C}\n\n✅ 本文件由內政部核發並經即時查驗"` through the
/// verifier and watched the second line render, at body size, in the app's own
/// card style, as though the app were saying it.
///
/// # What is taken out, and why a marker is left behind
///
/// Every Unicode scalar Foundation calls a control or format character — Cc and
/// Cf, which is U+0000–U+001F, U+007F–U+009F, the bidirectional embeddings and
/// overrides U+202A–U+202E, the isolates U+2066–U+2069, U+200E/U+200F, U+200B
/// and U+FEFF — **plus** U+2028 and U+2029, which are categories Zl and Zp and
/// are therefore *not* in `CharacterSet.controlCharacters` despite breaking a
/// line in a `UILabel` exactly the way `\n` does. `.controlCharacters` alone was
/// verified insufficient on this toolchain, which is why the union below is not
/// belt-and-braces.
///
/// They are replaced rather than dropped, because a value that had a
/// right-to-left override in it is a value somebody built by hand, and a
/// verifier is entitled to see that something was there. One `U+FFFD` per
/// *run* rather than per scalar: the marker's job is to say 「something was
/// removed here」, not to count, and a value padded with five hundred zero-width
/// spaces should not become five hundred replacement glyphs — that would be a
/// denial-of-display attack this type had handed the attacker itself.
///
/// # What is deliberately *not* taken out
///
/// Ordinary characters that happen to look like this app's own chrome — ✅, •,
/// 「內政部」. Chasing those is unwinnable (✔️, ☑️, 🟢, 【核發】…) and every
/// character removed is a character of somebody's real name that this app
/// refused to show. The defence is framing, not filtering: `ClaimLabel` keeps
/// the app's own words in front of anything the document supplied, and the
/// verifier screen draws claim values behind a quotation rule that nothing the
/// app asserts ever has. A ✅ inside a quoted value is visibly a quoted ✅.
///
/// Combining marks (Mn) are also left alone — a stack of them is ugly rather
/// than deceptive, it is clipped by the card it sits in, and the length cap
/// below bounds how many can arrive.
struct UntrustedText: Equatable {

    /// Safe to hand to a `UILabel`: no line breaks, no bidirectional overrides,
    /// no zero-width padding, and no longer than the limit it was built with.
    let text: String

    /// The source was longer than the limit and `text` is a prefix of it. The
    /// screen says so in words — an ellipsis on its own could be part of a value.
    let wasTruncated: Bool

    /// At least one scalar was replaced by `marker`.
    let containedControlCharacters: Bool

    var isEmpty: Bool { text.isEmpty }

    /// U+FFFD REPLACEMENT CHARACTER, which is what it is for.
    static let marker: Unicode.Scalar = "\u{FFFD}"

    /// Cc and Cf, plus the two separators `CharacterSet.controlCharacters`
    /// leaves out. See the type documentation.
    static let unsafeScalars: CharacterSet = CharacterSet.controlCharacters.union(.newlines)

    /// The longest field *value* the result screen will draw.
    ///
    /// The longest field this app issues is a 戶籍地址, around thirty characters;
    /// 120 leaves room for an address with a 之 and a 樓 and a village name, and
    /// for a future field this build has not met. It is not a guess at what is
    /// reasonable so much as a bound on what one row can cost: an attacker's
    /// 20 000-character `name` used to be drawn in full.
    static let maximumValueLength = 120

    /// The longest field *name*. A JSON key longer than this is not a name, it
    /// is a payload wearing one.
    static let maximumTermLength = 40

    init(_ raw: String, limit: Int) {
        var kept = String.UnicodeScalarView()
        var replaced = false
        var insideRun = false
        for scalar in raw.unicodeScalars {
            if Self.unsafeScalars.contains(scalar) {
                replaced = true
                if !insideRun {
                    kept.append(Self.marker)
                    insideRun = true
                }
            } else {
                insideRun = false
                kept.append(scalar)
            }
        }

        // Trimmed *after* stripping, and only of plain whitespace: a marker that
        // ended up at either end is exactly the thing worth seeing, so it must
        // not be trimmed away, while an ordinary trailing space is noise.
        let sanitized = String(kept).trimmingCharacters(in: .whitespaces)

        // Counted in `Character`, not scalars or bytes: the limit is about how
        // much screen a value can take, and that is what a reader perceives.
        if sanitized.count > limit {
            text = String(sanitized.prefix(limit)) + "…"
            wasTruncated = true
        } else {
            text = sanitized
            wasTruncated = false
        }
        containedControlCharacters = replaced
    }

    static func value(_ raw: String) -> UntrustedText {
        UntrustedText(raw, limit: maximumValueLength)
    }

    static func term(_ raw: String) -> UntrustedText {
        UntrustedText(raw, limit: maximumTermLength)
    }
}

// MARK: - Naming a field

/// How a disclosed field gets a heading.
///
/// The distinction is the fix, not a convenience. `DisclosedClaim.term` is the
/// credential's own JSON key, chosen by whoever signed the credential — so a
/// stranger could name a field `內政部戶政司 已驗證` and, until this type existed,
/// that string was set as a card title in the identical style to this build's
/// own 「姓名」 and 「統一編號」. The screen had no way to tell the checker which of
/// the two headings the app stood behind.
///
/// So a term this build knows becomes the app's own localized noun, and a term
/// it does not know is never allowed to be a heading on its own: it is quoted
/// inside a sentence the app wrote. Putting the app's words *first* also
/// survives the bidirectional algorithm, which is worth being explicit about —
/// stripping U+202E is not sufficient on its own, because a run of strong
/// right-to-left letters reorders without any control character at all. A
/// leading CJK (strong L) prefix fixes the paragraph direction, so a hostile
/// run can rearrange itself and nothing else.
enum ClaimLabel: Equatable {

    /// This build knows the term. The text is the app's own words and carries
    /// the app's authority, which is what a heading looks like it carries.
    case known(String)

    /// A term this build has never seen. Never dropped — silently hiding a
    /// field a newer credential disclosed would understate what the holder
    /// handed over, which is a privacy failure rather than a safe default — and
    /// never presented as though this app named it.
    case declaredByTheDocument(UntrustedText)

    static func label(for term: String) -> ClaimLabel {
        switch term {
        case "name": return .known(NSLocalizedString("Name", comment: ""))
        case "birthdate": return .known(NSLocalizedString("Birth date", comment: ""))
        case "unifiedNo": return .known(NSLocalizedString("Unified No.", comment: ""))
        case "addressOfHousehold": return .known(NSLocalizedString("Address of household", comment: ""))
        case "nationality": return .known(NSLocalizedString("Nationality", comment: ""))
        // The age predicate is a field **this app issues and signs**, and until
        // it was listed here it fell through to `.declaredByTheDocument` — so
        // it was drawn in the quotation style built specifically to flag a term
        // a stranger chose, next to a bare `true`.
        //
        // That is worse than ugly. The whole value of that style is that it is
        // rare: a 里長 who sees the app's own fields wearing it learns that the
        // app "does that a lot", and the next time it appears on something
        // genuinely suspicious it will not register. Dressing our own field as
        // untrusted spends the signal that protects against untrusted ones.
        //
        // Same key and same wording as the holder's side
        // (`StoredNationalID.displayKey`), named for when it was true — "Over
        // 18" alone would read as a claim about today. The *value* stays
        // untranslated `true`: it is the credential's literal, and this is a
        // heading fix, not a value fix.
        case AgePredicate.claimName:
            return .known(NSLocalizedString("Had turned 18 when issued", comment: ""))
        default: return .declaredByTheDocument(.term(term))
        }
    }
}

/// One row of the disclosed-fields list, with both halves already sanitized.
struct PresentableClaim: Equatable {
    let label: ClaimLabel
    let value: UntrustedText
}

/// The disclosed-fields list as the screen will draw it: bounded, and honest
/// about the bound.
///
/// A credential this app issues has five fields. A presentation carrying forty
/// of them is not a newer credential, it is somebody filling the screen — and
/// the measured attack did exactly that, 40 fields of 200 characters each,
/// which pushed the caveat block far enough down that the first screen was a
/// green tick above a wall of official-looking rows.
///
/// The cap is twelve rather than five so that a genuinely newer credential
/// still shows everything, and the overflow is *stated* rather than dropped:
/// how many fields the holder handed over is a fact about the holder's privacy,
/// and a verifier who cannot see them all should at least be told there were
/// more. That count is drawn at the end of the list, where a reader who has run
/// out of rows is looking.
struct PresentableClaims: Equatable {

    let rows: [PresentableClaim]

    /// How many were disclosed and not drawn. Zero in every honest case.
    let hiddenCount: Int

    static let maximumRows = 12

    init(_ claims: [DisclosedClaim]) {
        rows = claims.prefix(Self.maximumRows).map {
            PresentableClaim(label: .label(for: $0.term), value: .value($0.value))
        }
        hiddenCount = max(0, claims.count - Self.maximumRows)
    }
}

// MARK: - Where the blocks go

/// The blocks of the verified-result screen, in the order they are drawn.
///
/// This is data rather than the order of statements in a function body so that
/// it can be asserted on. The arrangement is a security property — see `order`
/// — and a security property that only exists as the sequence of four
/// `addArrangedSubview` calls is one that the next edit to that function
/// silently repeals.
enum VerifiedResultSection: Hashable, CaseIterable {
    case verdict
    case whatThisCheckDidNotEstablish
    /// Only drawn for a card-signed credential; contributes nothing otherwise.
    case whoSigned
    case whatTheyDisclosed
    case whenItWasSigned
}

extension VerifiedResultSection {

    /// Caveats above the disclosed fields, and that ordering is the fix.
    ///
    /// It used to be the other way round, on the stated reasoning that the
    /// caveats were 「above the fold on any phone with fewer than five claims」.
    /// The fields are a stranger's bytes, so the stranger decides how many there
    /// are and how long each one is — which makes 「fewer than five」 not an
    /// assumption about credentials but a request to the attacker. Forty fields
    /// of two hundred characters put the entire caveat block below the scroll.
    ///
    /// Capping the list (`PresentableClaims.maximumRows`) narrows that but
    /// cannot close it: twelve rows of a hundred and twenty characters is still
    /// several screens, and at the accessibility text sizes this app exists for
    /// it is several more. Only ordering makes the guarantee independent of what
    /// the other device sent.
    ///
    /// The cost is real and was weighed: a verifier's actual task is to read the
    /// name and the number, and they now scroll to reach them. That is the right
    /// trade twice over. It is the *only* arrangement an attacker cannot affect;
    /// and it is the order the sentence is in — 「通過」, then what 「通過」 does not
    /// mean, then what they said. Reading the data first and the qualifications
    /// afterwards is how a checker comes away believing the government said it.
    ///
    /// The rejected alternative was a pinned banner carrying two of the caveats
    /// above a scrolling list. It restores a bare tick in miniature: whichever
    /// caveats did not fit the banner become the ones nobody read, and choosing
    /// which of 「未查撤銷」 and 「自簽」 matters less is not a choice this project
    /// gets to make on a verifier's behalf. It also costs the most vertical
    /// space at exactly the text sizes where there is least.
    ///
    /// What this still does not buy is that a caveat was *read*. Nothing inside
    /// a scroll view can.
    /// `whoSigned` sits *after* the caveats, and that placement is a security
    /// decision, not a layout one. The cardholder's name comes off the
    /// certificate the other device presented — verified, but still their
    /// bytes — and the invariant this ordering exists to keep is that nothing
    /// the other device supplied can get between the verdict and the caveats.
    /// It sits *before* the disclosed fields because it is the app's own
    /// sentence about who signed, which outranks quoted claims.
    static let order: [VerifiedResultSection] = [
        .verdict,
        .whatThisCheckDidNotEstablish,
        .whoSigned,
        .whatTheyDisclosed,
        .whenItWasSigned,
    ]
}
