//
//  OfflineVerifier.swift
//  backupTW
//

import CryptoKit
import Foundation

// MARK: - What the verifier can say

/// Something true about a verified presentation that a green tick does not say
/// on its own.
///
/// These are not warnings in the "something went wrong" sense — every one is
/// attached to a presentation that passed every check. They exist because a bare
/// 「驗證通過」 lets a verifier read guarantees into the result that this design
/// does not provide, and the person being checked has no way to correct that
/// impression. Whitepaper §5.2 buys 「不打電話回家」 at a price, and the price has
/// to be visible on the same screen as the benefit.
///
/// `VerifiedPresentation` carries the list rather than exposing a boolean the
/// caller could quietly ignore.
enum VerificationCaveat: Equatable, CaseIterable {

    /// The property the whole offline design exists to obtain. Stated first
    /// because it is what a verifier *gains*, and a screen listing only the
    /// costs would mislead as badly as one listing only the benefits.
    case noNetworkQuery

    /// The cost of the line above. Nothing on this device knows whether the
    /// holder revoked this document ten minutes ago, and for a self-issued
    /// credential there is no authority that *could* publish an answer.
    case revocationNotChecked

    /// The issuer is the holder's own device. A verifier who reads a valid
    /// signature as "the government says this is true" has misread it: this is
    /// the 「本人可驗」 half of §5.2 with 「資料可驗」 still missing.
    ///
    /// Carried only by credentials issued before the card-signing change. Newer
    /// ones carry `assertedByCardholder` instead, which is a weaker warning
    /// because the document is genuinely better evidence.
    case selfIssuedByTheHolder

    /// The fields were signed with the holder's 自然人憑證 — a certificate
    /// 內政部 issued to that person — and **not** endorsed by 內政部 as correct.
    ///
    /// The distinction is the whole sentence and it is easy to lose. What the
    /// signature establishes is 「這位持卡人主張這些值」: a named cardholder,
    /// whose certificate chains to MOICA G3, put their key over exactly these
    /// fields. What it does not establish is that the values came from a
    /// government record — the app read them out of a MyData download, and that
    /// download carries no signature of its own (measured 2026-08-09). A screen
    /// that compresses this to 「政府認證」 is telling a verifier something the
    /// evidence does not support.
    case assertedByCardholder

    /// The `did:key` in this presentation is the same one the holder shows
    /// everybody, every time — it is `holder`, the credential's `issuer`, and
    /// its `credentialSubject.id`, all the same 57 characters. Two verifiers
    /// comparing notes can prove they saw the same person; one verifier can
    /// count visits. This is the unlinkability floor the whitepaper sets and
    /// this version does not clear, so it is stated rather than hidden.
    case identifierIsLinkable

    /// Nothing in this check establishes that the person holding out the phone
    /// is the one who answered it.
    ///
    /// This app cannot authenticate a verifier — offline there is no trust root
    /// to authenticate one against — so `PresentationRequest`'s relay is open by
    /// construction: Mallory takes this device's challenge, shows it to a holder
    /// somewhere else under any `purpose` she likes, and brings the reply back
    /// here. Every cryptographic check in `OfflineVerifier` passes on that
    /// reply, because every one of them is true: a real key signed a real
    /// challenge over a real credential. What is false is the thing a verifier
    /// actually concludes from a green tick — that the document belongs to the
    /// person standing there.
    ///
    /// Unconditional, because the limitation is unconditional. There is no
    /// evidence this build could gather that would let it drop the sentence, and
    /// a caveat that appears only when the app *suspects* something would be
    /// read as an accusation on the days it appeared and as an all-clear on the
    /// days it did not.
    case verifierNotAuthenticated

    /// The credential names no expiry. Together with `revocationNotChecked`
    /// that means nothing in the document bounds how long it stays acceptable;
    /// the judgement is the verifier's, and they can only make it if told.
    case noExpiryAsserted

    /// Nothing in this presentation names *this* verifier, so the same bytes
    /// would satisfy another one. Raised when either side omitted an audience.
    ///
    /// The challenge is still the primary defence and it is verifier-specific:
    /// another verifier rejects this reply because it never minted that
    /// challenge. What is missing is the second lock — and note that even when
    /// it is present it is unauthenticated, since anyone can claim any audience.
    /// See `OfflineVerifier` on the relay this does and does not close.
    case notBoundToThisVerifier
}

extension VerificationCaveat {

    /// Shown to the person doing the checking, so it says what it means rather
    /// than naming the mechanism.
    var message: String {
        switch self {
        case .noNetworkQuery:
            return NSLocalizedString("This check was made offline. Nothing was sent to any server.",
                                     comment: "Shown alongside a successful offline verification")
        case .revocationNotChecked:
            return NSLocalizedString("Whether this document has been revoked cannot be checked offline.",
                                     comment: "Shown alongside a successful offline verification")
        case .selfIssuedByTheHolder:
            return NSLocalizedString("This document was issued by the holder's own device, not by a government authority.",
                                     comment: "Shown alongside a successful offline verification")
        case .assertedByCardholder:
            // Names who asserted and who did not. "Signed with a government
            // certificate" alone would be read as "the government checked
            // this", which is the one reading that is wrong.
            return NSLocalizedString("The holder signed these details with their own government-issued certificate. That confirms who is making the claim, not that the government has confirmed the details.",
                                     comment: "Shown alongside a successful offline verification")
        case .identifierIsLinkable:
            return NSLocalizedString("This document shows the same identifier every time it is presented, so different checkers can tell it is the same person.",
                                     comment: "Shown alongside a successful offline verification")
        case .verifierNotAuthenticated:
            // Says what a relay *looks like* rather than naming one. A verifier
            // who is told 「無法偵測中繼攻擊」 has been given a word, not a fact
            // they can act on; a verifier who is told the answer may have come
            // from somewhere else knows to look at the person as well as the
            // screen.
            return NSLocalizedString("This check cannot confirm that the person in front of you is the one who answered it. The answer may have been obtained somewhere else and passed on.",
                                     comment: "Shown alongside a successful offline verification")
        case .noExpiryAsserted:
            return NSLocalizedString("This document does not state an expiry date.",
                                     comment: "Shown alongside a successful offline verification")
        case .notBoundToThisVerifier:
            return NSLocalizedString("This presentation is not tied to this checker specifically.",
                                     comment: "Shown alongside a successful offline verification")
        }
    }
}

/// Why a presentation was refused.
///
/// One case per thing that can be wrong, deliberately. Collapsing them into a
/// single 「無效」 would leave the person at the counter unable to tell a phone
/// with a wrong clock from a forged document, and would leave us unable to tell
/// a broken presenter from an attack. The associated values are diagnostics for
/// tests and logs; `message` is what a human sees and it never interpolates them
/// — an error string is exactly how a DID or a holder's data reaches a log or a
/// screenshot, which is the leak `VerifiableCredentialError` and
/// `PresentationRequestError` both refuse.
enum VerificationFailure: Error, Equatable {

    // MARK: Structure

    /// Not three non-empty base64url segments separated by dots.
    case presentationIsNotAJWS
    /// The segments decode, but the header or the body is not a JSON object.
    case presentationUnreadable
    /// The same field appears in both the protected header and the body with two
    /// different values. Both are signed, so this is not tampering — it is a
    /// presenter that cannot decide what it is claiming, and guessing which copy
    /// it meant is not a verifier's job. Refusing also stops a presenter showing
    /// one challenge to a JOSE reader and another to a JSON-LD one.
    case presentationFieldsDisagree(field: String)
    /// A field that can only be text arrived holding a number, a boolean, a
    /// list, an object or `null`.
    ///
    /// Refused rather than read as absent, which is what `as? String` does: it
    /// answers `nil` to both, so every check downstream of one treats an
    /// attacker-chosen value as an omission. That is exactly how a presentation
    /// carrying `"challenge": 12345` in its body and the genuine challenge in
    /// its header walked past `presentationFieldsDisagree` — the two copies
    /// never appeared to disagree, because one of them had been read as absent.
    /// See `OfflineVerifier.text(_:in:whenNotText:)`.
    case presentationFieldIsNotText(field: String)
    /// `typ` is not `vp+jwt`, or the body is not a `VerifiablePresentation`.
    /// This is what stops a stored credential being replayed as though it were a
    /// live presentation — JOSE has no `proofPurpose`, so `typ` is the entire
    /// domain separation between a signature made to assert and one made to
    /// prove presence.
    case presentationIsNotAPresentation(declaredType: String?)
    /// The JWS declares something other than ES256 — `none` included.
    case unsupportedSignatureAlgorithm(declared: String?)

    // MARK: Holder

    /// `holder` is absent, is not a `did:key:`, or does not decode to a P-256
    /// public key.
    case holderIdentifierUnusable
    /// The header's `kid` names a key other than the one `holder` resolves to.
    /// A forger who signs with their own key while naming somebody else in
    /// `holder` produces exactly this, which is why `kid` is never the source of
    /// the key.
    case presentationKeyIDMismatch
    /// The presentation is not signed by the key its `holder` DID names.
    case presentationSignatureInvalid

    // MARK: Credential

    case credentialMissing
    /// More than one credential. Verifying the first and displaying it as "the"
    /// document would silently ignore the rest.
    case presentationCarriesMultipleCredentials(count: Int)
    /// Not an `EnvelopedVerifiableCredential` carrying a
    /// `data:application/vc+jwt,…` identifier. A ZK proof will arrive here as a
    /// different media type, and it must be refused legibly rather than parsed
    /// as a JWS.
    case credentialNotEnveloped
    case credentialIsNotAJWS
    /// `typ` is not `vc+jwt` — the other half of the domain separation.
    case credentialIsNotACredential(declaredType: String?)
    case issuerIdentifierUnusable
    case credentialKeyIDMismatch
    /// The credential is not signed by the key its `issuer` DID names. A single
    /// altered character anywhere in the credential lands here.
    case credentialSignatureInvalid
    /// The signature checked out, but the credential uses a shape this build
    /// does not model. Kept apart from `credentialSignatureInvalid` on purpose:
    /// "I cannot read this" and "this is forged" are different accusations, and
    /// only one of them is about the holder.
    case credentialUnreadable
    /// The credential is about somebody other than the presenter. Without this
    /// check the challenge would only prove that *someone* holds *a* key.
    case credentialNotBoundToPresenter
    /// The credential was issued by a third party. There is no trust list on
    /// this device to evaluate one against, and showing an unevaluated issuer as
    /// verified would be a lie, so it is refused until there is one.
    case credentialIssuerIsNotTheSubject

    // MARK: Freshness

    /// Not the challenge this verifier just minted: a replay, or an answer to
    /// somebody else's request.
    case challengeMismatch
    /// The holder answered a different question. See `OfflineVerifier` — this is
    /// the check that catches a relay which alters what the holder was told.
    case purposeMismatch
    /// The presentation names a different verifier.
    case audienceMismatch
    case presentationTimestampUnreadable
    case presentationTooOld(age: TimeInterval)
    case presentationDatedInTheFuture(skew: TimeInterval)

    // MARK: Validity

    case credentialValidityUnreadable
    case credentialNotYetValid
    case credentialExpired

    // MARK: Card-signed credentials

    /// The card signature does not cover these fields — the document was altered
    /// after the cardholder signed it, or the signature is not theirs.
    case cardSignatureInvalid

    /// The certificate that signed names a different person from the one the
    /// document describes.
    case cardholderIsNotTheSubject

    /// The signing certificate is not one this build can check: an older MOICA
    /// generation, out of date, or not signed by 內政部憑證管理中心 at all.
    case cardholderCertificateUnusable

    /// This build's own bundled MOICA certificate could not be loaded.
    ///
    /// Kept apart from every failure above because it is the only one that is
    /// *this app's* fault. Reporting it as a bad document would send somebody to
    /// renew a card that is perfectly fine.
    case trustAnchorUnavailable
}

extension VerificationFailure {

    /// Several cases share a sentence, deliberately. A verifier needs to know
    /// what to *do* next, and "ask them to show it again" or "this is not our QR
    /// code" covers a family of internal causes that are only distinguishable to
    /// us.
    var message: String {
        switch self {
        case .presentationIsNotAJWS, .presentationUnreadable, .presentationFieldsDisagree,
             .presentationFieldIsNotText,
             .credentialMissing, .credentialNotEnveloped, .credentialIsNotAJWS,
             .presentationTimestampUnreadable:
            return NSLocalizedString("This code is not a document presented by this app.",
                                     comment: "Offline verification failure")
        case .presentationIsNotAPresentation, .credentialIsNotACredential:
            return NSLocalizedString("This is a stored document rather than a presentation made for this check.",
                                     comment: "Offline verification failure")
        case .presentationCarriesMultipleCredentials:
            return NSLocalizedString("This presentation carries more than one document, which this app cannot check yet.",
                                     comment: "Offline verification failure")
        case .unsupportedSignatureAlgorithm:
            return NSLocalizedString("This document is signed in a way this app cannot check.",
                                     comment: "Offline verification failure")
        case .holderIdentifierUnusable, .issuerIdentifierUnusable:
            return NSLocalizedString("This document's identifier is not one this app can check.",
                                     comment: "Offline verification failure")
        case .presentationKeyIDMismatch, .credentialKeyIDMismatch:
            return NSLocalizedString("This document names one signer but is signed under another.",
                                     comment: "Offline verification failure")
        case .presentationSignatureInvalid:
            return NSLocalizedString("The signature on this presentation is not valid.",
                                     comment: "Offline verification failure")
        case .credentialSignatureInvalid, .cardSignatureInvalid:
            return NSLocalizedString("The signature on this document is not valid; its contents may have been altered.",
                                     comment: "Offline verification failure")
        case .cardholderIsNotTheSubject:
            return NSLocalizedString("This document was signed by a different person from the one it describes.",
                                     comment: "Offline verification failure")
        case .cardholderCertificateUnusable:
            // Names the likeliest cause, because it is the only one with an
            // action attached: a 自然人憑證 lasts a year and lapsing is ordinary.
            return NSLocalizedString("The digital certificate that signed this document cannot be checked — most often because it has expired.",
                                     comment: "Offline verification failure")
        case .trustAnchorUnavailable:
            return NSLocalizedString("This app cannot check government certificates right now. This is a problem with the app, not with the document.",
                                     comment: "Offline verification failure")
        case .credentialUnreadable:
            return NSLocalizedString("This document uses fields this app does not understand.",
                                     comment: "Offline verification failure")
        case .credentialNotBoundToPresenter:
            return NSLocalizedString("This document belongs to someone other than the person presenting it.",
                                     comment: "Offline verification failure")
        case .credentialIssuerIsNotTheSubject:
            return NSLocalizedString("This document was issued by someone this app has no way to check.",
                                     comment: "Offline verification failure")
        case .challengeMismatch:
            return NSLocalizedString("This presentation answers a different check, so it may be a copy of an earlier one.",
                                     comment: "Offline verification failure")
        case .purposeMismatch:
            return NSLocalizedString("The holder was shown a different reason for this check than the one you asked for.",
                                     comment: "Offline verification failure")
        case .audienceMismatch:
            return NSLocalizedString("This presentation was made for a different checker.",
                                     comment: "Offline verification failure")
        case .presentationTooOld:
            return NSLocalizedString("This presentation has expired. Ask for it to be shown again.",
                                     comment: "Offline verification failure")
        case .presentationDatedInTheFuture:
            return NSLocalizedString("The other device's clock is too far off for this to be checked.",
                                     comment: "Offline verification failure")
        case .credentialValidityUnreadable:
            return NSLocalizedString("This document does not say when it becomes valid.",
                                     comment: "Offline verification failure")
        case .credentialNotYetValid:
            return NSLocalizedString("This document is not valid yet.",
                                     comment: "Offline verification failure")
        case .credentialExpired:
            return NSLocalizedString("This document has expired.",
                                     comment: "Offline verification failure")
        }
    }
}

extension VerificationFailure: LocalizedError {
    var errorDescription: String? { message }
}

/// One field the holder disclosed, ready for display.
///
/// `term` is the credential's own key (`unifiedNo`, `birthdate`, …) rather than
/// a localized label: this type says *what was disclosed*, and the UI owns how
/// to name it. A term this build has never seen still arrives here — silently
/// dropping a field a future credential added would understate what the holder
/// just handed over.
struct DisclosedClaim: Equatable {
    let term: String
    let value: String
}

/// Everything a verifier learned, including what they did not.
struct VerifiedPresentation: Equatable {

    /// The presenter's `did:key`, which is also the credential's issuer and
    /// subject. Read `VerificationCaveat.identifierIsLinkable` before showing,
    /// logging or storing it.
    let holder: String

    /// The name on the certificate that signed the credential's fields, or nil
    /// for a device-signed credential — where nobody's name is on the signature
    /// at all.
    ///
    /// This is the one string on the result screen that is *stronger* than the
    /// quoted claims: verification checked that the certificate carrying it
    /// chains to MOICA G3 and that it equals the credential's own `name`. It is
    /// still bytes the other device supplied — the certificate travels in the
    /// presentation — so a screen must draw it under the same `UntrustedText`
    /// discipline as everything else from that side, and must never let it sit
    /// between the verdict and the caveats.
    let cardholderName: String?

    let credentialTypes: [String]

    /// Ordered for reading, not in the order the credential serialized them.
    let claims: [DisclosedClaim]

    let validFrom: Date
    /// `nil` when the credential asserts none, which is every credential this
    /// app currently issues.
    let validUntil: Date?

    /// When the holder signed, by the holder's clock.
    let presentedAt: Date

    let caveats: [VerificationCaveat]
}

/// The result of one check. Two cases only — a verifier standing in front of a
/// person is entitled to a yes or a no — with everything the UI needs to be
/// honest about either hanging off the case it belongs to.
enum VerificationOutcome: Equatable {
    case verified(VerifiedPresentation)
    case rejected(VerificationFailure)
}

extension VerificationOutcome {

    var isVerified: Bool {
        switch self {
        case .verified: return true
        case .rejected: return false
        }
    }

    var verified: VerifiedPresentation? {
        switch self {
        case .verified(let presentation): return presentation
        case .rejected: return nil
        }
    }

    var failure: VerificationFailure? {
        switch self {
        case .verified: return nil
        case .rejected(let failure): return failure
        }
    }
}

// MARK: - The verifier

/// Checks a `VerifiablePresentation` entirely on this device.
///
/// # No phone home (whitepaper §5.2)
///
/// Nothing in this file opens a socket, and nothing it calls does either —
/// CryptoKit, `DIDKey`, and Foundation's JSON and date parsing are the whole
/// dependency list. That is not a concession to bad signal in a 里長辦公室; it is
/// the property being bought. A verifier that resolved a DID document, fetched a
/// status list or pinged an analytics endpoint would hand somebody a log of who
/// was checked, where and when — the surveillance §5.2 refuses, and one that
/// would survive having perfectly good signal. `OfflineVerifierTests` guards this
/// with a canary on the URL loading system *and* a check of this file's own text,
/// because the defect is invisible from the outside: a verifier that phones home
/// still verifies correctly.
///
/// # What a verified result actually proves
///
/// That the device presenting holds the private key its `did:key` names, that it
/// signed *this* verifier's challenge, and that the credential inside was signed
/// by that same key and is unaltered. That is 「本人可驗」. It is **not** evidence
/// that any authority attested the contents — the credential is self-issued, and
/// `VerificationCaveat.selfIssuedByTheHolder` exists so a screen cannot quietly
/// imply otherwise.
///
/// # Revocation is not checked, and cannot be
///
/// Offline there is no status list to consult, and for a self-issued credential
/// there is no authority that could publish one: the only party able to revoke is
/// the holder, and a holder whose phone was taken is not the one presenting it.
/// Rather than carry a status field that would always read "not revoked" — a
/// green tick backed by nothing — every verified result carries
/// `VerificationCaveat.revocationNotChecked`. The place a real answer will go is
/// the credential's `credentialStatus`, once the MOICA / TW FidO path supplies an
/// issuer with the standing to revoke.
///
/// # Replay: this type does half of it
///
/// `verify` is a pure function. It compares the presented challenge against the
/// one in the request and remembers nothing, so the *same* presentation verifies
/// twice. The other half — minting each challenge once, consuming it the moment a
/// presentation is checked **whether it passed or failed**, expiring it on a
/// timer, and persisting the used set across a relaunch — belongs to the caller
/// that owns the pending-challenge store.
/// `verifyingTwiceDoesNotConsumeTheChallenge` pins this contract so nobody reads
/// the absence of that behaviour as a bug someone already fixed.
///
/// # Relay: partly closed, and not by the challenge
///
/// `PresentationRequest` names the open attack: Mallory takes a genuine challenge
/// from verifier V, shows it to the holder under any `purpose` she likes, and
/// hands the reply back to V. Checking that `presentationPurpose` equals the
/// purpose *this* verifier asked for closes the variant where Mallory changes what
/// the holder was told — the holder signs Mallory's sentence, and V refuses it.
/// A relay that passes the purpose through verbatim remains undetectable, which is
/// what `VerificationCaveat.verifierNotAuthenticated` is for: it rides on every
/// verified result, so the one thing this design cannot check is said on the same
/// screen as the tick rather than only in this comment. That the sentence had to
/// be added — the caveat named here did not exist for as long as this paragraph
/// did — is the reason to distrust any disclosure that lives only in prose.
///
/// # The format this reads
///
/// A compact JWS, exactly what `VerifiablePresentation.create` produces:
///
/// ```text
/// header   { "alg": "ES256", "typ": "vp+jwt", "cty": "vp", "kid": "did:key:zDn…#zDn…" }
/// payload  {
///   "@context": ["https://www.w3.org/ns/credentials/v2", { …presentation terms… }],
///   "type": ["VerifiablePresentation"],
///   "holder": "did:key:zDn…",
///   "verifiableCredential": [{
///     "@context": "https://www.w3.org/ns/credentials/v2",
///     "id": "data:application/vc+jwt,<the credential's own compact JWS>",
///     "type": "EnvelopedVerifiableCredential"
///   }],
///   "challenge": "<the verifier's challenge, verbatim>",
///   "audience": "<the verifier's identifier, when it gave one>",
///   "purpose": "<what the holder was told they were agreeing to>",
///   "created": "2026-08-07T04:05:06Z"
/// }
/// ```
///
/// `challenge`, `audience`, `purpose` and `created` are read from the body,
/// falling back to the protected header. Both locations are inside the
/// signature, so neither is weaker: the header is where a value is safe from
/// JSON-LD expansion silently discarding a term the v2 context does not define,
/// and the body is where a generic VC toolchain looks. Carrying the same field
/// in *both* places with different values is refused rather than resolved.
///
/// The credential travels *enveloped* — the exact JWS string that was signed,
/// never re-serialized — for two reasons. Its signature covers particular bytes,
/// and making verification depend on reproducing another build's serializer is
/// how offline checking starts failing on credentials issued by a slightly
/// different version. And its inline `@context`
/// (`VerifiableCredential.nationalIDTermDefinitions`) stays inside its own
/// signature, where JSON-LD expansion of the presentation cannot reach past a
/// `data:` URI and drop it.
///
/// # Deliberately not checked
///
/// **The presentation's `@context`.** This verifier does not run JSON-LD
/// expansion, so the context decides nothing here, and rejecting on it would be a
/// conformance test wearing a security check's clothes. Keeping the presentation
/// expandable is the presenter's obligation and its tests'.
///
/// **`PresentationRequest.createdAt` against `presentedAt`.** Two drifting clocks
/// compared to each other produce false refusals, and the comparison buys nothing:
/// a presentation minted before the request existed cannot contain a challenge
/// that did not exist either. The challenge is the ordering proof.
enum OfflineVerifier {

    /// How long after signing a presentation stays acceptable.
    ///
    /// Five minutes is measured from the far end of the flow rather than off a
    /// clock: the holder has to unlock the phone (credentials are stored
    /// `.completeUnlessOpen`, so a Face ID or passcode is unavoidable), find the
    /// document, and hold a screen still enough to be scanned — possibly with a
    /// cracked screen, in a queue, being helped by somebody else. Much tighter
    /// fails the people this app is for. Much longer is a replay window for
    /// whoever photographed the QR over a shoulder, since the presentation is a
    /// bearer token until the caller consumes the challenge.
    static let maximumPresentationAge: TimeInterval = 5 * 60

    /// How far ahead of us the holder's clock may be.
    ///
    /// Asymmetric with the window above because the two measure different
    /// things. A presentation dated in the past may be old *or* stale-by-attack,
    /// so that tolerance is a security budget. A presentation dated in the future
    /// can only be clock error — nobody signs ahead of time — so this one is an
    /// equipment budget, and two minutes covers a phone that was dead through an
    /// earthquake and came back drifted. Beyond that the honest answer is "that
    /// device's clock is wrong", which is what `presentationDatedInTheFuture`
    /// lets the UI say instead of accusing somebody of forgery.
    static let maximumClockSkew: TimeInterval = 2 * 60

    /// Checks `presentationJWS` against the request this verifier issued.
    ///
    /// - Parameter request: the request whose challenge this verifier minted and
    ///   is still holding. Passing a request the verifier did not generate turns
    ///   the replay defence off — see the type documentation for the half of it
    ///   the caller owns.
    /// - Parameter now: injected so the freshness window is testable at all;
    ///   production callers take the default.
    /// - Returns: never throws. Every way this can go wrong is a
    ///   `VerificationFailure` carrying something to show the person at the
    ///   counter.
    static func verify(presentationJWS: String,
                       against request: PresentationRequest,
                       now: Date = Date()) -> VerificationOutcome {
        do {
            return .verified(try check(presentationJWS, against: request, now: now))
        } catch let failure as VerificationFailure {
            return .rejected(failure)
        } catch {
            // Nothing below throws anything else today. The catch-all is here so
            // that a throwing call added later fails closed, rather than escaping
            // as an unhandled error or being restructured into a "verified" path.
            return .rejected(.presentationUnreadable)
        }
    }

    // MARK: - The check itself

    /// The order is load-bearing.
    ///
    /// Signatures are checked before anything is believed about the contents, so
    /// a forged document can never be reported as "expired" or "shown for the
    /// wrong purpose" — statements that concede it was genuine. Holder binding
    /// comes next, because a challenge answered by the wrong person proves
    /// nothing. Only then do freshness and validity run, on a document already
    /// known to be authentic and about the presenter.
    private static func check(_ presentationJWS: String,
                              against request: PresentationRequest,
                              now: Date) throws -> VerifiedPresentation {

        // 1. Structure, and the domain separation that stops a stored credential
        //    passing as a live presentation.
        let presentation = try CompactJWS(serialization: presentationJWS,
                                          structureFailure: .presentationIsNotAJWS,
                                          contentFailure: .presentationUnreadable)
        let declaredType = presentation.header["typ"] as? String
        guard declaredType == presentationMediaType else {
            throw VerificationFailure.presentationIsNotAPresentation(declaredType: declaredType)
        }
        let bodyTypes = typeList(presentation.payload["type"])
        guard bodyTypes.contains(VerifiablePresentation.baseType) else {
            throw VerificationFailure.presentationIsNotAPresentation(declaredType: bodyTypes.first)
        }
        try requireES256(presentation)

        // 2. The holder's key comes from the signed body, never from `kid`.
        //    `kid` is attacker-chosen: resolve it and a forger signs with their
        //    own key, names the victim in `holder`, and the victim's fields are
        //    what gets displayed under a signature that checks out.
        guard let holder = presentation.payload["holder"] as? String, !holder.isEmpty else {
            throw VerificationFailure.presentationUnreadable
        }
        let holderKey = try publicKey(for: holder, whenUnusable: .holderIdentifierUnusable)
        try requireKeyID(in: presentation.header,
                         toMatch: holder,
                         whenMismatched: .presentationKeyIDMismatch)
        try requireSignature(on: presentation, by: holderKey, whenInvalid: .presentationSignatureInvalid)

        // 3. The credential, checked under whichever mechanism secured it, over
        //    the bytes that arrived — it is never re-serialized on the way in.
        //    Which mechanism is decided by the envelope's media type, never by
        //    looking at the bytes: a document that could be steered into the
        //    weaker of two verifiers is the whole type-confusion class.
        let credential: CheckedCredential
        switch try envelopedCredential(in: presentation.payload) {
        case .deviceSigned(let jws):
            credential = try checkDeviceSigned(jws)
        case .cardSigned(let envelope):
            credential = try checkCardSigned(envelope, now: now)
        }
        let issuer = credential.issuer

        // 4. Holder binding. Both signatures can be perfectly valid on a
        //    credential about somebody else — a copied credential file plus a
        //    presentation signed by the thief's own key looks exactly like that —
        //    so the subject has to be the presenter. Compared against
        //    `credentialSubject.id` rather than `issuer` because the subject is
        //    who the claims are about, which stays correct on the day these are
        //    issued by MOICA instead of by the device.
        guard let subject = (credential.payload["credentialSubject"] as? [String: Any])?["id"] as? String else {
            throw VerificationFailure.credentialUnreadable
        }
        guard subject == holder else {
            throw VerificationFailure.credentialNotBoundToPresenter
        }
        guard issuer == subject else {
            throw VerificationFailure.credentialIssuerIsNotTheSubject
        }

        // 5. Freshness. See the type documentation for the half of the replay
        //    defence the caller owns, and for what the purpose check does and
        //    does not close.
        guard try signedField(challengeField, of: presentation) == request.challenge else {
            // Plain equality: the challenge is a value this verifier generated
            // and displayed in a QR code, so there is no secret here for a timing
            // side channel to leak.
            throw VerificationFailure.challengeMismatch
        }
        guard try signedField(purposeField, of: presentation) == request.purpose else {
            throw VerificationFailure.purposeMismatch
        }

        // A missing audience is a caveat rather than a refusal only when *this*
        // verifier has no identifier to be named by: `PresentationRequest.audience`
        // is optional because a 里長 with a spare iPad has no stable one, and
        // refusing them would be refusing the deployment this is for.
        //
        // Once the verifier has named itself, silence is refused exactly like a
        // wrong name. The previous shape required both sides to be present before
        // it compared anything, so a presenter that wrote the wrong audience was
        // caught and a presenter that omitted the field entirely was waved
        // through — a lock the side being checked could pick by deleting it. The
        // asymmetry only runs one way: an audience this verifier never asked for
        // still cannot be confirmed, so it stays a caveat rather than becoming a
        // second thing to match.
        let presentedAudience = try signedField(audienceField, of: presentation)
        var audienceIsBound = false
        if let expected = request.audience {
            guard let actual = presentedAudience, actual == expected else {
                throw VerificationFailure.audienceMismatch
            }
            audienceIsBound = true
        }

        guard let createdText = try signedField(createdField, of: presentation),
              let presentedAt = date(from: createdText) else {
            throw VerificationFailure.presentationTimestampUnreadable
        }
        let age = now.timeIntervalSince(presentedAt)
        guard age <= maximumPresentationAge else {
            throw VerificationFailure.presentationTooOld(age: age)
        }
        guard -age <= maximumClockSkew else {
            throw VerificationFailure.presentationDatedInTheFuture(skew: -age)
        }

        // 6. Only now decode for display. Signature first, reading second: a
        //    credential from another implementation may use shapes this build
        //    cannot model — `credentialSubject` is `[String: String]` here — and
        //    "I cannot read this" must not be reported as "this is forged".
        let decoded: VerifiableCredential
        do {
            decoded = try JSONDecoder().decode(VerifiableCredential.self, from: credential.payloadData)
        } catch {
            throw VerificationFailure.credentialUnreadable
        }

        guard let validFrom = date(from: decoded.validFrom) else {
            throw VerificationFailure.credentialValidityUnreadable
        }
        guard validFrom.timeIntervalSince(now) <= maximumClockSkew else {
            throw VerificationFailure.credentialNotYetValid
        }

        // Read off the raw payload because `VerifiableCredential` does not model
        // `validUntil` — this app issues none. Honouring one that a future issuer
        // does include is the safe direction; ignoring it would make this a
        // verifier that accepts expired documents from a stricter issuer.
        //
        // Read through `text` rather than `as? String` because the two ways of
        // being unreadable have to land in the same place. `"validUntil": 1` is a
        // credential that expired in 1970, and `as? String` made it
        // indistinguishable from a credential that named no expiry at all: the
        // comparison below was skipped *and* `.noExpiryAsserted` was appended, so
        // the screen told the verifier 「本文件未載明有效期限」 about a document
        // that had said the opposite. A false sentence on that screen is the
        // whole failure — nobody at a counter reads the signature.
        //
        // VC 2.0 spells `validUntil` as an XSD `dateTimeStamp`, so a number here
        // is not a JWT-style epoch this verifier should learn to read; it is a
        // document this build cannot evaluate, and saying so is the only honest
        // answer available.
        var validUntil: Date?
        if let validUntilText = try text("validUntil",
                                         in: credential.payload,
                                         whenNotText: .credentialValidityUnreadable) {
            guard let parsed = date(from: validUntilText) else {
                throw VerificationFailure.credentialValidityUnreadable
            }
            guard now.timeIntervalSince(parsed) <= maximumClockSkew else {
                throw VerificationFailure.credentialExpired
            }
            validUntil = parsed
        }

        var caveats: [VerificationCaveat] = [.noNetworkQuery,
                                             .revocationNotChecked,
                                             // Which of the two appears is the
                                             // only place the securing mechanism
                                             // reaches the screen, and they say
                                             // materially different things: one
                                             // means the phone vouched for these
                                             // fields, the other means a named
                                             // cardholder did.
                                             credential.cardholderName == nil
                                                 ? .selfIssuedByTheHolder
                                                 : .assertedByCardholder,
                                             .identifierIsLinkable,
                                             // Unconditional for the same reason
                                             // `revocationNotChecked` is: this
                                             // build cannot authenticate a
                                             // verifier at all, so there is no
                                             // presentation about which the
                                             // sentence would be untrue.
                                             .verifierNotAuthenticated]
        if validUntil == nil { caveats.append(.noExpiryAsserted) }
        if !audienceIsBound { caveats.append(.notBoundToThisVerifier) }

        return VerifiedPresentation(holder: holder,
                                    cardholderName: credential.cardholderName,
                                    credentialTypes: decoded.type,
                                    claims: disclosedClaims(from: decoded.credentialSubject),
                                    validFrom: validFrom,
                                    validUntil: validUntil,
                                    presentedAt: presentedAt,
                                    caveats: caveats)
    }

    // MARK: - Steps

    /// ES256 is the only algorithm this app signs with, and it is hardcoded on
    /// this side too — the header is never consulted to *choose* an algorithm,
    /// which is the classic JWS confusion attack. `alg` is read only for the
    /// error message: "signed in a way this app cannot check" is actionable,
    /// "signature invalid" is not.
    private static func requireES256(_ jws: CompactJWS) throws {
        let declared = jws.header["alg"] as? String
        guard declared == "ES256" else {
            throw VerificationFailure.unsupportedSignatureAlgorithm(declared: declared)
        }
    }

    private static func publicKey(for did: String,
                                  whenUnusable failure: VerificationFailure) throws -> P256.Signing.PublicKey {
        do {
            return try DIDKey.p256PublicKey(fromDID: did)
        } catch {
            // `DIDKeyError` distinguishes a wrong curve from a corrupt string,
            // which is useful to us and not to the person at the counter; it is
            // dropped here rather than widening this type with a diagnostic
            // nobody acts on.
            throw failure
        }
    }

    /// An absent `kid` is allowed — it is optional in JOSE, and a presenter that
    /// omits it has claimed nothing. A *wrong* one is refused: the only ways to
    /// produce one are a broken signer, or a forger who set it to the key they
    /// actually hold.
    ///
    /// Which is why the header is handed over whole rather than pre-flattened
    /// with `as? String`. RFC 7515 §4.1.4 makes `kid` a string, so a `kid`
    /// holding a number is not a presenter that omitted one — and reading it as
    /// an omission would let the check be switched off by changing the value's
    /// *type* instead of matching it. This one is not independently exploitable,
    /// since the signature check downstream still has to pass; it is here so the
    /// rule holds without exception in a file where the next reader will copy
    /// whatever line they land on.
    private static func requireKeyID(in header: [String: Any],
                                     toMatch did: String,
                                     whenMismatched failure: VerificationFailure) throws {
        guard let keyID = try text("kid", in: header, whenNotText: failure) else { return }
        guard let expected = try? VerifiableCredential.verificationMethodID(for: did),
              keyID == expected else {
            throw failure
        }
    }

    private static func requireSignature(on jws: CompactJWS,
                                         by key: P256.Signing.PublicKey,
                                         whenInvalid failure: VerificationFailure) throws {
        // JOSE ES256 is a fixed-width 64-byte `r ‖ s`; a DER signature arrives at
        // some other length. This guard is deliberately redundant — CryptoKit
        // rejects any other length from `rawRepresentation:` and the refusal
        // below is identical either way, which a mutation of this line confirms —
        // and it is kept because the length is a requirement of the format rather
        // than an implementation detail of whoever parses it next.
        guard jws.signature.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: jws.signature),
              // The message, not a digest. `isValidSignature(_:for:)` hashes
              // whatever `DataProtocol` it is handed, which matches the signing
              // side (`SecKeyCreateSignature` with
              // `.ecdsaSignatureMessageX962SHA256`, whose docstring says the same).
              // Passing `Data(SHA256.hash(of:))` here would select this very
              // overload, hash the digest a second time, and fail every signature
              // with no diagnostic at all.
              key.isValidSignature(signature, for: jws.signingInput) else {
            throw failure
        }
    }

    /// Which securing mechanism the presented credential arrived under.
    ///
    /// Decided from the envelope's media type and nowhere else. Sniffing the
    /// bytes would mean a document could be steered into whichever verifier is
    /// weaker for it, which is the classic shape of a type-confusion bug — and
    /// this file already has a test suite named after that class.
    enum EnvelopedCredential {
        case deviceSigned(compactJWS: String)
        case cardSigned(MOICASignedCredential)
    }

    /// What a credential turned out to be, once its own signature was checked.
    ///
    /// Both branches produce this so that everything downstream — holder
    /// binding, validity windows, display — is written once and cannot drift
    /// between the two.
    private struct CheckedCredential {
        let payload: [String: Any]
        let payloadData: Data
        let issuer: String
        /// The cardholder's name from the certificate, or nil for a
        /// device-signed credential. Its presence is what decides which caveat
        /// the verifier reports.
        let cardholderName: String?
    }

    /// Pulls the credential out of the presentation without re-encoding it.
    private static func envelopedCredential(in payload: [String: Any]) throws -> EnvelopedCredential {
        let entries: [Any]
        if let array = payload["verifiableCredential"] as? [Any] {
            entries = array
        } else if let single = payload["verifiableCredential"] {
            entries = [single]
        } else {
            throw VerificationFailure.credentialMissing
        }

        guard let first = entries.first else {
            throw VerificationFailure.credentialMissing
        }
        guard entries.count == 1 else {
            throw VerificationFailure.presentationCarriesMultipleCredentials(count: entries.count)
        }
        guard let envelope = first as? [String: Any],
              typeList(envelope["type"]).contains(EnvelopedVerifiableCredential.typeName),
              let identifier = envelope["id"] as? String else {
            throw VerificationFailure.credentialNotEnveloped
        }

        if identifier.hasPrefix(EnvelopedVerifiableCredential.compactJWSPrefix) {
            return .deviceSigned(
                compactJWS: String(identifier.dropFirst(
                    EnvelopedVerifiableCredential.compactJWSPrefix.count)))
        }
        if identifier.hasPrefix(EnvelopedVerifiableCredential.moicaSignedPrefix) {
            let encoded = String(identifier.dropFirst(
                EnvelopedVerifiableCredential.moicaSignedPrefix.count))
            guard let data = Data(base64Encoded: encoded),
                  let serialized = String(data: data, encoding: .utf8),
                  let signed = try? MOICASignedCredential.parse(serialized) else {
                throw VerificationFailure.credentialUnreadable
            }
            return .cardSigned(signed)
        }
        // An envelope carrying a media type this build does not know — a ZK
        // proof, one day — is refused here rather than fed to the wrong parser.
        throw VerificationFailure.credentialNotEnveloped
    }

    /// The older path: a credential secured by the device's own ES256 key.
    private static func checkDeviceSigned(_ jws: String) throws -> CheckedCredential {
        let credential = try CompactJWS(serialization: jws,
                                        structureFailure: .credentialIsNotAJWS,
                                        contentFailure: .credentialUnreadable)
        let credentialType = credential.header["typ"] as? String
        guard credentialType == credentialMediaType else {
            throw VerificationFailure.credentialIsNotACredential(declaredType: credentialType)
        }
        try requireES256(credential)

        guard let issuer = credential.payload["issuer"] as? String, !issuer.isEmpty else {
            throw VerificationFailure.credentialUnreadable
        }
        let issuerKey = try publicKey(for: issuer, whenUnusable: .issuerIdentifierUnusable)
        try requireKeyID(in: credential.header,
                         toMatch: issuer,
                         whenMismatched: .credentialKeyIDMismatch)
        try requireSignature(on: credential, by: issuerKey, whenInvalid: .credentialSignatureInvalid)

        return CheckedCredential(payload: credential.payload,
                                 payloadData: credential.payloadData,
                                 issuer: issuer,
                                 cardholderName: nil)
    }

    /// The current path: the fields were signed with the holder's 自然人憑證.
    ///
    /// The failure cases are kept apart rather than collapsed into one "invalid"
    /// because they send the holder to different places. An expired certificate
    /// means "go and renew your card"; a name mismatch means the document
    /// contradicts itself; a bad signature means it was altered. Reporting all
    /// three as the same sentence is how a verifier ends up telling somebody
    /// their document is forged when their card simply lapsed.
    private static func checkCardSigned(_ envelope: MOICASignedCredential,
                                        now: Date) throws -> CheckedCredential {
        let anchor: IssuerCertificate
        do {
            anchor = try IssuerCertificate.loadBundled(now: now)
        } catch {
            // The bundled trust anchor is unusable, which is this build's fault
            // and not the presenter's. Distinguished so a support report does
            // not send somebody to renew a perfectly good card.
            throw VerificationFailure.trustAnchorUnavailable
        }

        let verified: MOICACredentialVerification
        do {
            verified = try envelope.verify(against: anchor, now: now)
        } catch let error as MOICASignedCredentialError {
            switch error {
            case .cardholderNameDiffersFromSubject, .cardholderNameMissing, .credentialNameMissing:
                throw VerificationFailure.cardholderIsNotTheSubject
            case .malformedPayload, .unsupportedProofConstruction, .malformedSignature:
                throw VerificationFailure.credentialUnreadable
            case .signatureInvalid, .disclosureNotCommitted:
                // A disclosure the card never committed to is a holder adding a
                // claim, which is the same accusation as an altered payload and
                // deserves the same sentence.
                throw VerificationFailure.cardSignatureInvalid
            }
        } catch {
            // Everything `IssuerCertificate` raises: wrong generation, expired,
            // not signed by MOICA G3.
            throw VerificationFailure.cardholderCertificateUnusable
        }

        let payloadData = try envelope.payloadBytes()
        guard let object = try? JSONSerialization.jsonObject(with: payloadData),
              let payload = object as? [String: Any],
              let issuer = payload["issuer"] as? String, !issuer.isEmpty else {
            throw VerificationFailure.credentialUnreadable
        }

        return CheckedCredential(payload: payload,
                                 payloadData: payloadData,
                                 issuer: issuer,
                                 cardholderName: verified.cardholderName)
    }

    /// Reads a field from the body, falling back to the protected header.
    ///
    /// Both are covered by the signature, so this is not a trust decision — it is
    /// tolerance for where a presenter chose to put a value that JSON-LD
    /// expansion would drop from the body and JOSE convention would put in the
    /// header. Disagreement between the two is refused rather than resolved.
    private static func signedField(_ name: String, of jws: CompactJWS) throws -> String? {
        let notText = VerificationFailure.presentationFieldIsNotText(field: name)
        let fromBody = try text(name, in: jws.payload, whenNotText: notText)
        let fromHeader = try text(name, in: jws.header, whenNotText: notText)
        if let fromBody, let fromHeader, fromBody != fromHeader {
            throw VerificationFailure.presentationFieldsDisagree(field: name)
        }
        return fromBody ?? fromHeader
    }

    /// Reads a JSON member that can only be text, distinguishing *absent* from
    /// *present and not text*.
    ///
    /// Three answers where `as? String` gives two, and the missing third is the
    /// one attacks are built out of. `as? String` returns `nil` both for a field
    /// nobody wrote and for a field holding `12345`, so every caller downstream
    /// of one reads a value the presenter chose as a value the presenter omitted
    /// — and omissions are, correctly, tolerated all over this file. Type
    /// confusion turns each of those tolerances into a switch the side being
    /// checked can flip.
    ///
    /// Absence therefore stays `nil`, because several of these fields really are
    /// optional and refusing them would refuse honest presenters. Anything
    /// present that is not a string throws, because a presenter that meant text
    /// wrote text: what remains is a broken signer or somebody relying on the
    /// difference, and a verifier that guesses between those two is no longer
    /// telling the person at the counter anything they can act on.
    ///
    /// `null` throws with the rest. JSON distinguishes "absent" from "present
    /// and null", nothing this app signs ever emits the latter — `String?`
    /// encodes through `encodeIfPresent` — and folding it into absence would
    /// hand back the exact hole this closes under a different spelling.
    ///
    /// The failure is a parameter because the same confusion means different
    /// things in different places: an unreadable `validUntil` is a statement
    /// about the *credential*, not about the presentation carrying it.
    private static func text(_ name: String,
                             in object: [String: Any],
                             whenNotText failure: VerificationFailure) throws -> String? {
        guard let value = object[name] else { return nil }
        guard let text = value as? String else { throw failure }
        return text
    }

    // MARK: - Display

    /// The order a person reads an ID card in, which is neither the order the
    /// credential serializes in (`.sortedKeys`, so alphabetical) nor the order
    /// the MyData PDF prints.
    private static let claimDisplayOrder = ["name", "birthdate", "unifiedNo", "addressOfHousehold", "nationality"]

    private static func disclosedClaims(from subject: [String: String]) -> [DisclosedClaim] {
        var remaining = subject
        // `id` is the holder's DID, already reported as `holder`. Listing it
        // among the claims would present a correlatable identifier as though it
        // were one of the fields the holder chose to disclose.
        remaining.removeValue(forKey: "id")

        var claims = claimDisplayOrder.compactMap { term in
            remaining.removeValue(forKey: term).map { DisclosedClaim(term: term, value: $0) }
        }
        // Anything this build has not heard of goes last, in a stable order, so a
        // credential from a newer version still shows everything it disclosed.
        claims.append(contentsOf: remaining.sorted { $0.key < $1.key }
            .map { DisclosedClaim(term: $0.key, value: $0.value) })
        return claims
    }

    // MARK: - Vocabulary

    private static let presentationMediaType = "vp+jwt"
    private static let credentialMediaType = "vc+jwt"

    /// The four fields this verifier reads out of a presentation, spelled
    /// exactly as `VerifiablePresentation`'s `CodingKeys` write them.
    ///
    /// Gathered here rather than inlined at their use sites because they are the
    /// one hard coupling between this file and the presenter: rename a field
    /// there and every check in step 5 silently starts reading `nil`, which
    /// surfaces as `challengeMismatch` — an accusation of replay — rather than
    /// as the version mismatch it is. Four constants in one place is what makes
    /// that a three-line correction instead of a hunt.
    private static let challengeField = "challenge"
    private static let audienceField = "audience"
    private static let purposeField = "purpose"
    private static let createdField = "created"

    // MARK: - Primitives

    /// JSON-LD allows a single string wherever a list of types is expected.
    private static func typeList(_ value: Any?) -> [String] {
        if let single = value as? String { return [single] }
        if let many = value as? [Any] { return many.compactMap { $0 as? String } }
        return []
    }

    /// XSD 1.1 `dateTimeStamp`, the format `VerifiableCredential.timestamp(from:)`
    /// writes. Fractional seconds are accepted although we never emit them:
    /// refusing a timestamp for being *more* precise would be a compatibility
    /// failure dressed up as a validity failure.
    ///
    /// A fresh formatter per call — `ISO8601DateFormatter` is a reference type
    /// whose options are mutable state, and verification can run off the main
    /// thread.
    private static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

// MARK: - Compact JWS

/// A parsed compact JWS that keeps the bytes which were actually signed.
///
/// Header and body stay as `[String: Any]` rather than becoming modelled types
/// on purpose: this is a document from another device, and the verifier has to be
/// able to say "the signature is fine but I do not understand the contents"
/// (`credentialUnreadable`) instead of failing to parse and reporting something
/// that sounds like an accusation.
private struct CompactJWS {

    let header: [String: Any]
    let payload: [String: Any]
    /// The undecoded body, for a typed decode once the signature has been checked.
    let payloadData: Data
    /// `BASE64URL(header) || "." || BASE64URL(payload)`, exactly as received.
    let signingInput: Data
    let signature: Data

    init(serialization: String,
         structureFailure: VerificationFailure,
         contentFailure: VerificationFailure) throws {
        // Scanners and pasteboards routinely add a trailing newline; failing on
        // one would produce an unexplainable refusal at the counter. Nothing is
        // smuggled past the signature by allowing it, because the trimmed
        // segments are what the signing input is rebuilt from below.
        let trimmed = serialization.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.components(separatedBy: ".")
        guard segments.count == 3,
              let headerData = Self.base64URLDecoded(segments[0]),
              let payloadData = Self.base64URLDecoded(segments[1]),
              let signature = Self.base64URLDecoded(segments[2]) else {
            throw structureFailure
        }

        let headerJSON = try? JSONSerialization.jsonObject(with: headerData)
        let payloadJSON = try? JSONSerialization.jsonObject(with: payloadData)
        guard let header = headerJSON as? [String: Any],
              let payload = payloadJSON as? [String: Any] else {
            throw contentFailure
        }

        self.header = header
        self.payload = payload
        self.payloadData = payloadData
        self.signature = signature
        // Rebuilt from the received segments rather than by re-encoding the
        // decoded JSON. Re-encoding would make verification depend on
        // reproducing the presenter's serializer byte for byte, and the first
        // credential issued by a build with different `JSONEncoder` options would
        // then fail to verify with no way to tell why.
        self.signingInput = Data((segments[0] + "." + segments[1]).utf8)
    }

    /// base64url, unpadded, strict.
    ///
    /// The standard alphabet's characters are refused rather than quietly
    /// accepted: `+`, `/` and `=` cannot appear in a compact JWS, and a decoder
    /// that takes them anyway carries a mangled serialization far enough to fail
    /// later as "signature invalid" — the least informative refusal available.
    private static func base64URLDecoded(_ segment: String) -> Data? {
        guard !segment.isEmpty,
              !segment.contains(where: { $0 == "+" || $0 == "/" || $0 == "=" }) else {
            return nil
        }
        var standard = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}
