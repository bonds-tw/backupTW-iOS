//
//  ScanToCollectViewController.swift
//  backupTW
//
//  Scanning an official QR to add a card — the entry the wallet was missing.
//

import UIKit

/// Drives the QR scanner for the collection flow: the holder points the camera
/// at 數位憑證皮夾's 「皮夾夥伴卡」 QR (the official step 2), and a credential
/// offer it carries is run through the same gates and collector as a deep link.
///
/// # Why a coordinator and not logic on `HomeViewController`
///
/// `HomeViewController` already routes taps for cards, MyData, presentation and
/// verification; adding an async collection with its own alert would put a
/// fourth concern with a different lifetime on a screen whose job is to list.
/// This type owns exactly the scan→parse→collect→report loop and nothing else,
/// and it reuses `QRScanningViewController` (which records nothing) and
/// `CredentialCollection` (the one place the sequence lives).
enum ScanToCollect {

    /// Pushes a scanner configured to collect. The first QR that parses as a
    /// credential offer stops the camera and runs one collection; every other
    /// code in the viewfinder is ignored in silence, because a camera pointed at
    /// the world sees many.
    @MainActor
    static func begin(on navigationController: UINavigationController?) {
        // A box so the escaping scan closure can flip a one-shot latch. Two
        // whole payloads must not each start a collection — the same reason the
        // verifier closes its camera on the first payload.
        final class Latch { var fired = false }
        let latch = Latch()

        let scanner = QRScanningViewController(
            title: NSLocalizedString("Scan a card's QR", comment: "collect by scan"),
            prompt: NSLocalizedString("Point the camera at the QR from 數位憑證皮夾.", comment: "")
        ) { [weak navigationController] scanned in
            guard !latch.fired else { return .stop }
            guard let url = URL(string: scanned),
                  let link = try? CredentialOfferLink.parse(url) else {
                // Not a credential offer — any other QR that wandered in. Silent,
                // because this fires once per video frame.
                return .keepScanning(status: nil)
            }
            latch.fired = true
            Task { @MainActor in
                let outcome = await CredentialCollection.run(from: link)
                present(outcome: outcome, on: navigationController)
            }
            return .stop
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

    /// Pops the scanner and shows the outcome where the user is looking.
    @MainActor
    private static func present(outcome: String, on navigationController: UINavigationController?) {
        // Back to the list first: the alert belongs to the home screen, not to a
        // camera that has already stopped. Popping before presenting also means
        // the result is read on the screen that now shows the new card row.
        navigationController?.popViewController(animated: true)
        let alert = UIAlertController(
            title: NSLocalizedString("Digital wallet card collection", comment: ""),
            message: outcome,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))

        var presenter: UIViewController? = navigationController
        while let presented = presenter?.presentedViewController { presenter = presented }
        (presenter ?? navigationController?.topViewController)?.present(alert, animated: true)
    }
}
