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
        // The scan closure is handed to the scanner's initialiser, so it cannot
        // name the scanner directly; the box closes the loop so the closure can
        // put 「collecting…」 into the banner once a code locks.
        final class ScannerRef { weak var scanner: QRScanningViewController? }
        let ref = ScannerRef()

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
                // A valid QR for a *different* job is named, not ignored — a
                // silent scanner over a real code reads as a broken scanner
                // (design system §10.3). Presentation requests and ZK pairing
                // codes are the ones a holder plausibly meets here.
                if (try? OID4VPAuthorizeLink.parse(scanned: scanned)) != nil
                    || (try? PresentationRequest.decode(scanned)) != nil {
                    return .keepScanning(status: NSLocalizedString(
                        "That is a checker's QR for presenting, not a card to collect. Use 使用 ▸ 出示我的證件.",
                        comment: "Scanned a presentation request while collecting"))
                }
                if (try? ZKLinkEngagement.decode(from: scanned)) != nil {
                    return .keepScanning(status: NSLocalizedString(
                        "That is the code for sending a zero-knowledge proof, not for showing a document.",
                        comment: "Scanned the other kind of code"))
                }
                // Anything else — silent, because this fires once per video
                // frame. `parse(scanned:)` tolerates the CR+LF the official
                // deep link frames its query with; a plain `URL(string:)` here
                // would drop the real card.
                return .keepScanning(status: nil)
            }
            latch.fired = true
            // The camera freezes on its last frame after `.stop`; without this
            // sentence the whole token-exchange wait looked like a hang.
            ref.scanner?.showWorking(NSLocalizedString(
                "Collecting the card…", comment: "collect in progress"))
            Task { @MainActor in
                let outcome = await CredentialCollection.run(from: link)
                present(outcome: outcome, on: navigationController)
            }
            return .stop
        }
        ref.scanner = scanner
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

    /// A resolve failure or web-collect precondition — always an alert.
    @MainActor
    private static func present(outcome: String, on navigationController: UINavigationController?) {
        present(outcome: .failed(message: outcome), on: navigationController)
    }

    /// Shows the outcome where the user is looking.
    ///
    /// Success and failure used to share one identical alert, with the message
    /// text as the only difference — the app's single reward moment rendered as
    /// its most bureaucratic control. A success now *lands*: the scanner pops,
    /// the home tab comes forward with the new card in the wallet, the success
    /// buzz fires, and VoiceOver announces the arrival. Only failure still gets
    /// an alert, because failure needs to be read.
    @MainActor
    private static func present(outcome: CredentialCollection.Outcome,
                                on navigationController: UINavigationController?) {
        navigationController?.popViewController(animated: true)

        switch outcome {
        case .stored:
            Bonds.Haptic.delivered()
            navigationController?.tabBarController?.selectedIndex = 0
            UIAccessibility.post(notification: .announcement, argument: NSLocalizedString(
                "Card added to your wallet.", comment: "collection success announcement"))
        case .failed(let message):
            let alert = UIAlertController(
                title: NSLocalizedString("Digital wallet card collection", comment: ""),
                message: message,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            var presenter: UIViewController? = navigationController
            while let presented = presenter?.presentedViewController { presenter = presented }
            (presenter ?? navigationController?.topViewController)?.present(alert, animated: true)
        }
    }
}
