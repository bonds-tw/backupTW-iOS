//
//  CredentialCollection.swift
//  backupTW
//
//  One place that runs a collection, so the two entry points cannot drift.
//

import Foundation
import os

/// Coordinates one OID4VCI collection from a parsed offer link.
///
/// # Why this is not on `SceneDelegate`
///
/// A credential offer reaches this app two ways: the OS routing a
/// `openid-credential-offer://` / `modadigitalwallet://` deep link to
/// `SceneDelegate`, and the holder scanning a QR from inside the app (the
/// official flow's step 2 — 「使用數位憑證皮夾 App 掃描 QR-Code，來加入卡片」).
/// Both must fetch the same trust list, run the same two gates, and mint the
/// same one-key-per-card. A copy of that in each place is a copy that drifts —
/// the exact failure `HolderKeyring` and `CardInventory` were written to avoid,
/// arrived at from the UI side. So the sequence lives here once.
enum CredentialCollection {

    /// Runs a collection and returns a human-facing outcome line.
    ///
    /// Returns rather than presents: the caller owns a view hierarchy this type
    /// does not, and a scan screen dismisses to a different place than a
    /// deep-link launch. The string is already localized. On failure it is a
    /// person-facing sentence from `UserFacingError` — what happened and what to
    /// do — never the error's own `description`, which used to put a Swift type
    /// name on screen.
    ///
    /// The raw error is still logged for a developer; only the screen is
    /// translated. The measurement value of the exact case (which gate, which
    /// status) lives in the log, not in front of the cardholder.
    @MainActor
    static func run(from link: CredentialOfferLink) async -> String {
        do {
            var trustList = try await TrustListFetcher(session: .shared).fetchAll()
            #if DEBUG
            // DEBUG only: let a development build collect from the demo sandbox,
            // whose issuer host is not on the production trust list
            // (docs/m52-live-collection-2026-08-26.md §七). Compiled out of
            // Release entirely — a shipped wallet trusts the production list.
            trustList.append(.sandboxDemo)
            #endif
            let registryVerifier = TWDIWOnChainVerifier(session: .shared)
            let collector = OID4VCICollector(session: .shared,
                                             trustList: trustList,
                                             verifyRegistry: { issuers in
                                                 var results = await registryVerifier.verify(issuers)
                                                 #if DEBUG
                                                 // The demo registry is deliberately a separate trust domain
                                                 // with no production Arbitrum row. Keep the exception explicit,
                                                 // honest, and compiled out of Release.
                                                 for issuer in issuers where issuer.did == TWDIWIssuer.sandboxDemo.did {
                                                     results[issuer.did] = .developmentSandbox
                                                 }
                                                 #endif
                                                 return results
                                             },
                                             keyring: .app(),
                                             store: try CredentialStore())
            let receipt = try await collector.collect(from: link)
            return String(format: NSLocalizedString("Stored as %@.", comment: "collection success"),
                          receipt.storedID)
        } catch {
            log.error("collection failed: \(String(describing: error), privacy: .public)")
            return UserFacingError.collectionMessage(for: error)
        }
    }

    private static let log = Logger(subsystem: "tw.bonds.backupTW", category: "collection")
}
