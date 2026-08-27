//
//  ScanToPresentViewController.swift
//  backupTW
//
//  Scanning a verifier's QR to present a credential online — the other half of
//  the wallet from ScanToCollect.
//

import UIKit

/// Drives the QR scanner for the online presentation flow: the holder points the
/// camera at a verifier's request QR, the request is fetched and verified, and
/// the holder is taken to the one screen where they choose what to reveal.
///
/// # Why the outcome is a pushed screen, not an alert
///
/// Collection ends in an alert because there is nothing to decide — the card is
/// stored or it is not. A presentation has a decision in the middle, so a
/// successful scan does not finish anything; it hands `DiscloseFieldsViewController`
/// the verified request and lets the holder narrow it. Only a scan that fails
/// before there is anything to decide ends in an alert here.
enum ScanToPresent {

    /// Pushes a scanner configured to present. The first QR that parses as an
    /// authorize request stops the camera and fetches the request; every other
    /// code in the viewfinder is ignored in silence.
    @MainActor
    static func begin(on navigationController: UINavigationController?) {
        final class Latch { var fired = false }
        let latch = Latch()

        let scanner = QRScanningViewController(
            title: NSLocalizedString("Scan a verifier's QR", comment: "present by scan"),
            prompt: NSLocalizedString("Point the camera at the QR the verifier is showing.", comment: ""),
            allowsPhotoImport: true
        ) { [weak navigationController] scanned in
            guard !latch.fired else { return .stop }
            // Filter non-requests in silence, the same as the collect scanner —
            // this closure fires once per video frame.
            guard (try? OID4VPAuthorizeLink.parse(scanned: scanned)) != nil else {
                return .keepScanning(status: nil)
            }
            latch.fired = true
            Task { @MainActor in
                switch await OID4VPPresentation.request(from: scanned) {
                case .ready(let request):
                    push(request: request, on: navigationController)
                case .failed(let message):
                    present(outcome: message, on: navigationController)
                }
            }
            return .stop
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

    /// Replaces the (stopped) scanner with the disclosure screen, so Back from
    /// there returns to the list rather than to a dead camera.
    @MainActor
    private static func push(request: OID4VPRequest, on navigationController: UINavigationController?) {
        guard let navigationController else { return }
        var stack = navigationController.viewControllers
        if stack.last is QRScanningViewController { stack.removeLast() }
        stack.append(DiscloseFieldsViewController(request: request))
        navigationController.setViewControllers(stack, animated: true)
    }

    /// A scan that could not become a request pops back and says why.
    @MainActor
    private static func present(outcome: String, on navigationController: UINavigationController?) {
        navigationController?.popViewController(animated: true)
        let alert = UIAlertController(title: NSLocalizedString("Present a credential", comment: ""),
                                      message: outcome, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))

        var presenter: UIViewController? = navigationController
        while let presented = presenter?.presentedViewController { presenter = presented }
        (presenter ?? navigationController?.topViewController)?.present(alert, animated: true)
    }
}
