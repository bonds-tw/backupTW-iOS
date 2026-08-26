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
