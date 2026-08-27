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
            prompt: NSLocalizedString("Point the camera at the QR from 數位憑證皮夾.", comment: ""),
            // A dense offer — a driving licence's — would not scan off another
            // screen; picking a screenshot of the same code decodes it at full
            // fidelity through the same path.
            allowsPhotoImport: true
        ) { [weak navigationController] scanned in
            guard !latch.fired else { return .stop }
            // Try the static 「要申請的卡」 QR *first*, before the offer parser.
            // Some 皮夾夥伴卡 cannot hand over a credential up front (電信卡 verifies
            // the line, 駕照驗證卡 logs in to 監理服務網); their QR is a plain https
            // URL that only names the card, and the deep link comes later out of the
            // issuer's own page. `ModaCardApplication.parse` returns non-nil for
            // exactly that shape and nil for everything else — so a real offer is
            // never swallowed here; it falls straight through to the branch below and
            // collects the way it always did.
            if let application = ModaCardApplication.parse(scanned: scanned) {
                latch.fired = true
                Task { @MainActor in
                    await beginWebCollect(vcUid: application.vcUid,
                                          mode: application.mode,
                                          on: navigationController)
                }
                return .stop
            }
            guard let link = try? CredentialOfferLink.parse(scanned: scanned) else {
                // Not a credential offer — any other QR that wandered in. Silent,
                // because this fires once per video frame. `parse(scanned:)`
                // tolerates the CR+LF the official deep link frames its query
                // with; a plain `URL(string:)` here would drop the real card.
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

    /// Resolves a static card-application QR and opens where the holder finishes
    /// it: the system browser (`type == 1`) or an embedded webview.
    ///
    /// The resolve step (`ModaServiceURLResolver`) turns the scanned card identity
    /// into the issuer's own page URL; that page is *not* trusted to issue anything
    /// — whatever `modadigitalwallet://credential_offer` deep link it hands back
    /// goes through `WebCollectViewController` → `CredentialCollection.run` and both
    /// `IssuerAuthorization` gates, exactly like a scanned offer. This method owns
    /// only the resolve + where-to-open decision; the collection lives where it
    /// always did.
    @MainActor
    private static func beginWebCollect(vcUid: String,
                                        mode: String,
                                        on navigationController: UINavigationController?) async {
        let response: DwModa201iResponse
        do {
            response = try await ModaServiceURLResolver.resolve(vcUid: vcUid, mode: mode)
        } catch {
            // Same person-facing treatment as a collection failure: a translated
            // sentence, never the Swift error. Popping first puts the alert on the
            // list, not on a camera that has stopped.
            present(outcome: UserFacingError.cardApplicationMessage(for: error),
                    on: navigationController)
            return
        }

        guard let urlString = response.issuerServiceUrl,
              let url = URL(string: urlString) else {
            present(outcome: UserFacingError.cardApplicationMessage(
                for: ModaServiceURLResolverError.malformedResponse), on: navigationController)
            return
        }

        // Official mapping: `isInside = type == 1 ? false : true`. `type == 1` means
        // the issuer flow wants a full browser (its own cookies, a login it will not
        // do inside an app webview), so hand it to the OS; anything else finishes
        // embedded.
        if response.type == 1 {
            navigationController?.popViewController(animated: true)
            // Explicit options/completion form: inside this async function the bare
            // `open(_:)` resolves to the awaitable overload, and there is nothing to
            // await on.
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        navigationController?.popViewController(animated: true)
        let webCollect = WebCollectViewController(url: url, cardName: response.name)
        // Wrapped in its own navigation controller so the embedded flow has a title
        // bar and a close button (`WebCollectViewController` installs the button when
        // it finds itself inside a nav). Presented modally, not pushed, because it
        // owns a full webview session that should tear down as one when dismissed.
        let nav = UINavigationController(rootViewController: webCollect)
        nav.modalPresentationStyle = .fullScreen

        var presenter: UIViewController? = navigationController
        while let presented = presenter?.presentedViewController { presenter = presented }
        (presenter ?? navigationController?.topViewController)?.present(nav, animated: true)
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
