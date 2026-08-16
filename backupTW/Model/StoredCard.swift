//
//  StoredCard.swift
//  backupTW
//
//  Which kind of document a stored credential is.
//

import Foundation

/// Where a credential in `CredentialStore` came from.
///
/// # Why this has to exist before anything else in M5
///
/// `CredentialStore.save(jws:id:)` takes an arbitrary string. Today that is a
/// self-issued document; a TWDIW card would be `<jwt>~<d1>~<d2>~…~`. Nothing in
/// the store distinguishes them, so every reader has to work it out — and the
/// two obvious ways of working it out are both wrong:
///
/// - **By identifier.** `HolderPresentation` used to take
///   `store.allIDs().first`, which is fine while there is one card and becomes a
///   silent defect the moment there are two. The self-issued card's id is
///   `national-id`; a TWDIW identifier derived from its credential
///   configuration begins with a digit (`00000000_demo_drivinglicense_…`), and
///   digits sort before letters. **The first TWDIW card to land would quietly
///   become the document this device presents**, and `VerifiablePresentation`
///   would then refuse a document it never had a way to build.
/// - **By trying one parser and falling back.** Whichever is tried first decides
///   what the user is told. A damaged TWDIW card parsed as a self-issued one is
///   reported as "not a valid credential" — a sentence about the wrong document.
///
/// So the rule is written down once, here, as a pure function over the bytes.
enum StoredCardSource: String, Equatable, Sendable {

    /// Issued by this app to its holder, signed with their digital certificate.
    case selfIssued

    /// Issued through OID4VCI by an issuer in 台灣數位憑證皮夾.
    case twdiw

    /// Neither shape. Not an error here — a caller decides whether an
    /// unrecognised card is a refusal or a row that says "this app cannot read
    /// this". Returning a case rather than throwing keeps that decision at the
    /// place that knows what the user was doing.
    case unrecognised

    /// # The rule
    ///
    /// A TWDIW credential is an SD-JWT: a JWS, then `~`, then zero or more
    /// disclosures, and it always ends in `~` even when nothing is disclosed.
    /// **The `~` is the whole signal** — and it has to be, because the issuer
    /// metadata that is supposed to announce the format says `jwt_vc_json` for
    /// all 882 configurations in production and never mentions SD-JWT at all
    /// (measured 2026-08-16). There is nothing else to go on.
    ///
    /// Requiring the leading segment to be a three-part JWT as well means a
    /// self-issued document that merely happens to contain a tilde — inside a
    /// note, say — is not mistaken for one.
    static func source(of serialized: String) -> StoredCardSource {
        guard !serialized.isEmpty else { return .unrecognised }

        // JSON is settled by the first byte, and it has to be settled *before*
        // the tilde is consulted: a self-issued document is stored as the
        // credential's JSON, and a tilde inside a note or an address makes
        // `contains("~")` true without the document being an SD-JWT. Testing the
        // tilde first classified `{"note":"a~b"}` as unrecognised — caught by the
        // test of exactly that string, which is why it is there.
        if serialized.hasPrefix("{") { return .selfIssued }

        if serialized.contains("~") {
            let leading = serialized.prefix(while: { $0 != "~" })
            return isCompactJWS(String(leading)) ? .twdiw : .unrecognised
        }

        // The other self-issued shape: a bare compact JWS, from before documents
        // were stored as JSON.
        return isCompactJWS(serialized) ? .selfIssued : .unrecognised
    }

    /// Three non-empty base64url segments separated by dots.
    ///
    /// Deliberately does not decode: this is a shape test used to route a
    /// document to the right reader, and a reader that has not run yet is the
    /// one entitled to say the contents are wrong. Doing the work twice would
    /// also mean a card whose signature fails gets routed to `unrecognised` and
    /// reported as an unreadable file rather than as a document that did not
    /// verify.
    private static func isCompactJWS(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
    }
}
