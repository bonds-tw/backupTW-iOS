//
//  UserFacingError.swift
//  backupTW
//
//  The one place an error becomes a sentence a person can act on.
//

import Foundation

/// Translates the errors a card collection can throw into text for the person
/// holding the phone.
///
/// # Why this exists
///
/// The collection alert used to show `String(describing: error)` — the Swift
/// enum's own description, type name and all. Measured on device, a refused
/// scan read literally:
///
///     refused(backupTW.IssuerAuthorization.Refusal.notOnTheTrustList(host: …))
///
/// To the cardholder that is noise that says only "this app broke and does not
/// know why" — when in fact the code knew exactly what happened (a gate stopped
/// an untrusted issuer, which is the app working). The gap was a missing layer
/// of translation, not missing information.
///
/// # The contract every message here keeps
///
/// - It names **what happened** and **what to do next**, in that order.
/// - It never contains a type name, a module name, or a Swift case label.
/// - Where a bare number genuinely helps a person get unstuck — an HTTP status
///   they can quote to a helpdesk — it is kept, because that is information, not
///   an implementation detail leaking out.
///
/// Anything this translator does not recognise falls back to a plain sentence
/// rather than to the raw error, so a new error case added upstream degrades to
/// "please try again", never to a type name on screen.
enum UserFacingError {

    /// A message for any error reaching the card-collection alert.
    static func collectionMessage(for error: Error) -> String {
        switch error {
        case let e as OID4VCICollectionError: return message(for: e)
        case let e as IssuerAuthorization.Refusal: return message(for: e)
        case let e as CredentialOfferError: return message(for: e)
        case let e as TrustListFetcherError: return message(for: e)
        case is CredentialStoreError:
            return NSLocalizedString(
                "This phone could not save the card. It most often means the phone is out of space — free some up and try again.",
                comment: "collection error: store")
        default:
            return NSLocalizedString("Collecting the card did not work. Please try again.",
                                     comment: "collection error: unknown")
        }
    }

    /// A message for a failure while removing one stored card at the holder's
    /// request from the home screen.
    ///
    /// `CredentialStore.delete` throws in two shapes and neither is the holder's
    /// doing: an unusable identifier (a programming error) or a filesystem error
    /// (most often the volume being busy or full). What matters to the person is
    /// the same in both cases and is the one thing this says: the card is still
    /// on the phone, so they do not walk away believing it is gone. No type name,
    /// what-happened then what-to-do — the contract every message here keeps.
    static func deletionMessage(for error: Error) -> String {
        NSLocalizedString(
            "This card could not be removed, so it is still on this phone. This most often means the phone's storage is busy or full — try again in a moment.",
            comment: "card deletion error")
    }

    /// A message for a failure while resolving a static card-application QR — the
    /// step that turns 「要申請的卡」 into the issuer page a holder finishes on,
    /// before any webview opens.
    static func cardApplicationMessage(for error: Error) -> String {
        switch error {
        case let e as ModaServiceURLResolverError: return message(for: e)
        default:
            return NSLocalizedString("Opening this card's application did not work. Please try again.",
                                     comment: "card application error: unknown")
        }
    }

    /// A message for a failure while loading the 「申請新卡」 catalogue — the step
    /// that lists which telecom 門號電子卡 a holder can start, before any carrier
    /// app opens.
    static func telecomCatalogMessage(for error: Error) -> String {
        switch error {
        case let e as TelecomCardCatalogError: return message(for: e)
        default:
            return NSLocalizedString("Loading the list of phone-number cards did not work. Please try again.",
                                     comment: "telecom catalog error: unknown")
        }
    }

    private static func message(for error: TelecomCardCatalogError) -> String {
        switch error {
        case .network:
            return NSLocalizedString("Could not reach the card service. Check your connection and try again.",
                                     comment: "telecom catalog error: network")
        case .badStatus(let code, _):
            // The body is captured on the error for the log; the holder sees the
            // number they could quote, not the server's raw reply.
            return String(format: NSLocalizedString(
                "The card service could not list the cards (it returned %d). Please try again later.",
                comment: "telecom catalog error: bad status"), code)
        case .malformedResponse, .badURL:
            return NSLocalizedString("The list of phone-number cards could not be read, so nothing was started.",
                                     comment: "telecom catalog error: malformed")
        }
    }

    private static func message(for error: ModaServiceURLResolverError) -> String {
        switch error {
        case .network:
            return NSLocalizedString("Could not reach the card service. Check your connection and try again.",
                                     comment: "card application error: network")
        case .badStatus(let code, _):
            // The body is captured on the error for the log; the holder sees the
            // number they could quote, not the server's raw reply.
            return String(format: NSLocalizedString(
                "The card service could not open this application (it returned %d). Please try again later.",
                comment: "card application error: bad status"), code)
        case .malformedResponse, .badURL:
            return NSLocalizedString("This card's application could not be opened, so nothing was started.",
                                     comment: "card application error: malformed")
        }
    }

    /// A message for the official convenience-store barcode flow. It may fail
    /// while loading the scenario, presenting the telecom card, or asking the
    /// verifier for its encrypted PNG, so all three families are translated in
    /// one place for the two screens that run the flow.
    static func pickupMessage(for error: Error) -> String {
        switch error {
        case let e as ConvenienceStorePickupError:
            switch e {
            case .network:
                return NSLocalizedString("Could not reach the pickup service. Check your connection and try again.",
                                         comment: "pickup error: network")
            case .badStatus(let code):
                return String(format: NSLocalizedString(
                    "The pickup service could not create a barcode (it returned %d). Please try again.",
                    comment: "pickup error: bad status"), code)
            case .scenarioUnavailable:
                return NSLocalizedString("7-ELEVEN pickup is not available in the official service list right now. Please try again later.",
                                         comment: "pickup error: unavailable")
            case .trustEvidenceUnavailable:
                return NSLocalizedString("The app could not compare the trust-list API with the current Arbitrum record, so no credential was presented. Please try again later.",
                                         comment: "pickup error: trust evidence unavailable")
            case .untrustedService, .unexpectedRequest:
                return NSLocalizedString("The pickup request did not match the trusted 7-ELEVEN service, so no credential was presented.",
                                         comment: "pickup error: trust mismatch")
            case .serverCode(let code):
                return String(format: NSLocalizedString(
                    "The pickup service refused this request (code %@). Make a fresh barcode and try again.",
                    comment: "pickup error: server code"), code)
            case .malformedResponse, .invalidBarcodeImage:
                return NSLocalizedString("The pickup service returned a barcode the app could not read. Please try again.",
                                         comment: "pickup error: malformed")
            }
        case is OID4VPRequestError, is OID4VPResponseError, is TrustListFetcherError:
            return presentationMessage(for: error)
        default:
            return NSLocalizedString("Creating the pickup barcode did not work. Please try again.",
                                     comment: "pickup error: unknown")
        }
    }

    /// A message for any error reaching the presentation flow — reading the
    /// verifier's request, or sending the answer.
    static func presentationMessage(for error: Error) -> String {
        switch error {
        case let e as OID4VPRequestError: return message(for: e)
        case let e as OID4VPResponseError: return message(for: e)
        case let e as TrustListFetcherError: return message(for: e)
        default:
            return NSLocalizedString("Presenting did not work. Please try again.",
                                     comment: "presentation error: unknown")
        }
    }

    // MARK: - Presentation request

    private static func message(for error: OID4VPRequestError) -> String {
        switch error {
        case .notAnAuthorizeLink:
            return NSLocalizedString("This QR code is not a request to present a credential.",
                                     comment: "vp request error: not an authorize link")
        case .responseURINotTrusted, .requestURINotTrusted:
            return NSLocalizedString("This request points to an address the app does not trust, so nothing was presented.",
                                     comment: "vp request error: untrusted host")
        case .unsupportedResponseMode:
            return NSLocalizedString("This way of presenting is not supported yet.",
                                     comment: "vp request error: unsupported mode")
        case .network:
            return NSLocalizedString("Could not reach the verifier. Check your connection and try again.",
                                     comment: "vp request error: network")
        case .badStatus(let code):
            return String(format: NSLocalizedString(
                "Could not read the verifier's request (it returned %d). Ask for a fresh QR code and try again.",
                comment: "vp request error: bad status"), code)
        case .malformedRequestObject, .clientIDNotAResolvableDID, .signatureInvalid, .missingField:
            // All mean the same to a person: the request could not be trusted,
            // so — as with the issuer gate — nothing of theirs was signed or sent.
            return NSLocalizedString("The verifier's request could not be verified, so nothing was presented — for your safety.",
                                     comment: "vp request error: unverifiable")
        }
    }

    // MARK: - Presentation response

    private static func message(for error: OID4VPResponseError) -> String {
        switch error {
        case .noMatchingCredential:
            return NSLocalizedString("Your wallet has no credential of the kind this verifier asked for.",
                                     comment: "vp response error: no matching card")
        case .requestedClaimNotAvailable:
            return NSLocalizedString("None of the matching cards on this phone carries one of the fields the verifier requested, so nothing was presented.",
                                     comment: "vp response error: claim not available")
        case .holderKeyUnavailable:
            return NSLocalizedString("This phone could not find the card's key, so it could not be presented.",
                                     comment: "vp response error: key")
        case .network:
            return NSLocalizedString("Could not reach the verifier. Check your connection and try again.",
                                     comment: "vp response error: network")
        case .badStatus(let code, let body):
            let base = String(format: NSLocalizedString(
                "Presenting did not succeed (the verifier's system returned %d). Ask for a fresh QR code and try again.",
                comment: "vp response error: bad status"), code)
            #if DEBUG
            // A development build shows what the verifier actually said, so a
            // refusal can be read off its own words — the same lever that
            // settled the collection 400. Compiled out of Release entirely.
            if let body, !body.isEmpty { return base + "\n\n[debug] " + String(body.prefix(900)) }
            #endif
            return base
        }
    }

    // MARK: - Collection

    private static func message(for error: OID4VCICollectionError) -> String {
        switch error {
        case .refused(let refusal):
            return message(for: refusal)
        case .network:
            return NSLocalizedString("Could not reach the issuer. Check your connection and try again.",
                                     comment: "collection error: network")
        case .badStatus(_, let code):
            // The status number is kept — it is what a person quotes when they
            // ask for help, and it is not a type name.
            return String(format: NSLocalizedString(
                "Collecting the card did not succeed (the issuer's system returned %d). Go back to the official page, make a fresh QR code, and try again.",
                comment: "collection error: bad status"), code)
        case .malformedResponse:
            return NSLocalizedString("The issuer's reply could not be read. Please try again in a moment.",
                                     comment: "collection error: malformed")
        case .missingField:
            return NSLocalizedString("The issuer's reply was incomplete. Please try again in a moment.",
                                     comment: "collection error: missing field")
        case .credentialEndpointHostMismatch:
            return NSLocalizedString("This QR code points to mismatched addresses, so nothing was collected — for your safety.",
                                     comment: "collection error: endpoint mismatch")
        case .issuedCredentialDoesNotVerify:
            return NSLocalizedString("The card that came back could not be verified, so it was not saved.",
                                     comment: "collection error: does not verify")
        case .credentialNotBoundToOurKey:
            return NSLocalizedString("The card that came back is not tied to this phone, so it was not saved.",
                                     comment: "collection error: not bound")
        case .keyUnavailable:
            return NSLocalizedString("This phone could not create a secure key for the card. Please try again.",
                                     comment: "collection error: key")
        }
    }

    // MARK: - Gate

    private static func message(for refusal: IssuerAuthorization.Refusal) -> String {
        switch refusal {
        case .notOnTheTrustList:
            return NSLocalizedString("This QR code is not from a trusted card issuer, so no card was added.",
                                     comment: "gate error: not on trust list")
        case .trustRecordNotAnchored:
            return NSLocalizedString(
                "The issuer's official trust-list entry has no blockchain record, so the app did not contact it. Try again after the issuer fixes its registration.",
                comment: "gate error: no blockchain anchor")
        case .trustRecordMismatch:
            return NSLocalizedString(
                "The official trust-list API and blockchain record do not match, so the app did not contact this issuer. Try again later or report the mismatch.",
                comment: "gate error: API and chain mismatch")
        case .trustVerificationUnavailable:
            return NSLocalizedString(
                "The app could not check this issuer's blockchain record, so it did not contact the issuer. Check your connection and try again.",
                comment: "gate error: blockchain unavailable")
        case .organisationMismatch:
            return NSLocalizedString("This QR code's issuer information does not match, so nothing was collected — for your safety.",
                                     comment: "gate error: org mismatch")
        case .notHTTPS, .unusableHost, .containsUserInfo, .unexpectedPort,
             .hostNotPlainASCII, .pathNotNormalised:
            // Every one of these is "the address in this QR is not one we will
            // contact". A person does not need to know which rule tripped — only
            // that the app declined for safety.
            return NSLocalizedString("This QR code's address looks unsafe, so the app did not connect to it.",
                                     comment: "gate error: bad address")
        }
    }

    // MARK: - Offer parsing

    private static func message(for error: CredentialOfferError) -> String {
        // The whole family means the same thing to a person: what was scanned is
        // not a collectable card.
        NSLocalizedString("This QR code is not a card you can collect.",
                          comment: "offer error: not collectable")
    }

    // MARK: - Trust list

    private static func message(for error: TrustListFetcherError) -> String {
        NSLocalizedString("Could not load the list of trusted issuers. Check your connection and try again.",
                          comment: "trust list error")
    }
}
