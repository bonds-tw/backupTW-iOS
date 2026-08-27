//
//  OID4VPPresentation.swift
//  backupTW
//
//  One place that runs an online presentation, so the scan entry and any deep
//  link cannot drift — the same shape as CredentialCollection for collection.
//

import Foundation
import os

/// Coordinates one OID4VP presentation, from the verifier's scanned request to
/// the posted `vp_token`.
///
/// # Why two calls, not one
///
/// Collection is one shot: a scanned offer becomes a stored card with nothing to
/// ask the holder. A presentation is not — between reading what the verifier
/// wants and sending anything, the holder chooses **which** of the requested
/// claims to reveal, and that choice is the whole point of this wallet. So the
/// flow is split: `request(from:)` fetches and verifies what was asked and hands
/// it to a screen; `respond(to:disclosing:)` sends exactly the holder's
/// selection. Nothing is signed or posted until the second call.
///
/// # What is trusted
///
/// The fetcher will only pull a request object from, and post a token to, a host
/// on `trustedHosts`. That set is the TWDIW organisations' own hosts, taken from
/// the same trust list collection uses — a verifier naming a `response_uri` off
/// that list is refused before anything is signed, the discipline the issuer
/// gate keeps in the other direction.
enum OID4VPPresentation {

    /// The result of reading a verifier's request: either the verified request to
    /// disclose against, or a person-facing reason it could not be read.
    ///
    /// Not `Result`, whose `Failure` must be an `Error` — the failure here is
    /// already the sentence the holder should see, not an error to translate
    /// again at the call site.
    enum RequestOutcome {
        case ready(OID4VPRequest)
        case failed(String)
    }

    /// Fetches and verifies the verifier's request, or returns a person-facing
    /// reason it could not.
    ///
    /// The `OID4VPRequest` is what the disclosure screen reads to show who is
    /// asking and for what. A failure here is before any disclosure decision, so
    /// nothing of the holder's has moved.
    @MainActor
    static func request(from scanned: String) async -> RequestOutcome {
        guard let link = try? OID4VPAuthorizeLink.parse(scanned: scanned) else {
            return .failed(UserFacingError.presentationMessage(for: OID4VPRequestError.notAnAuthorizeLink))
        }
        do {
            let fetcher = OID4VPRequestFetcher(session: .shared,
                                               trustedHosts: try await verifierHosts())
            return .ready(try await fetcher.fetch(link))
        } catch {
            log.error("VP request failed: \(String(describing: error), privacy: .public)")
            return .failed(UserFacingError.presentationMessage(for: error))
        }
    }

    /// Discloses exactly `chosenClaims`, signs the token with the matching card's
    /// key, posts it, and returns a person-facing outcome line.
    @MainActor
    static func respond(to request: OID4VPRequest, disclosing chosenClaims: Set<String>) async -> String {
        do {
            let responder = OID4VPResponder(session: .shared,
                                            store: try CredentialStore(),
                                            keyring: .app())
            _ = try await responder.respond(to: request, disclosing: chosenClaims)
            return NSLocalizedString("Presented. The verifier has your answer.",
                                     comment: "presentation success")
        } catch {
            log.error("VP response failed: \(String(describing: error), privacy: .public)")
            return UserFacingError.presentationMessage(for: error)
        }
    }

    /// The hosts a request object may be fetched from and a token posted to: the
    /// TWDIW organisations' own hosts. Built from the same trust list collection
    /// fetches, so the two directions cannot disagree about who is real.
    private static func verifierHosts() async throws -> Set<String> {
        var list = try await TrustListFetcher(session: .shared).fetchAll()
        #if DEBUG
        // DEBUG only: a development build talks to the demo verifier, whose host
        // is not on the production list — the mirror of the sandbox issuer
        // collection appends (docs/m52-live-collection-2026-08-26.md §七).
        list.append(.sandboxDemo)
        #endif
        return Set(list.flatMap { issuer in
            [issuer.issuerMetadataBaseURL, issuer.serviceBaseURL]
                .compactMap { $0 }
                .compactMap { URL(string: $0)?.host?.lowercased() }
        })
    }

    private static let log = Logger(subsystem: "tw.bonds.backupTW", category: "presentation")
}
