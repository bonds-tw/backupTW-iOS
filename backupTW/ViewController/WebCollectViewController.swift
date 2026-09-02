//
//  WebCollectViewController.swift
//  backupTW
//
//  The issuer's own page, embedded — where a holder finishes an application the
//  card cannot hand over up front (電信卡 verifies the line's number, 駕照驗證卡
//  logs in to 監理服務網), and the credential offer it produces is caught and run
//  through the same gates as any other.
//

import UIKit
import WebKit

/// Hosts the issuer service page in a `WKWebView` and catches the credential
/// offer it hands back, two ways the page can send one.
///
/// # The two return paths, and why both are here
///
/// Measured off the official app (`AddCertificateWebViewViewModel.handleScriptMessage`
/// and `BaseWebViewViewModel.decidePolicy`), the issuer page delivers its
/// `modadigitalwallet://credential_offer?…` deep link by **either**:
///
/// 1. a script message — `window.webkit.messageHandlers.mobile.postMessage(
///    {data:{deeplink:"modadigitalwallet://…", type:"webview"}})`, or
/// 2. navigating to the `modadigitalwallet:` URL, which `decidePolicyFor` cancels
///    and reads.
///
/// A given page uses one; which one is the page's choice, not ours, so both are
/// wired. Because both can fire for a single application, `didCapture` is a
/// one-shot latch: the first deep link seen — from whichever path — locks out the
/// other, so an offer is never collected twice.
///
/// # What this screen is NOT trusted to do
///
/// It is a browser pointed at a URL the resolve step produced. Nothing it shows
/// or sends back is trusted to mint a credential. The captured deep link goes
/// through `CredentialOfferLink.parse` and `CredentialCollection.run` — the same
/// `IssuerAuthorization` gates as a scanned QR — so a page that hands back an
/// offer naming an issuer not on the trust list is refused exactly as a malicious
/// QR would be. This class adds a network surface, not a trust exception.
@MainActor
final class WebCollectViewController: UIViewController {

    // MARK: - Deep-link extraction (pure, testable)

    /// The `deeplink` string inside a `mobile` script-message body, or `nil`.
    ///
    /// Pulled out as a pure function so the body-shape parsing — the part that
    /// turns `{data:{deeplink,type}}` into a string `CredentialOfferLink.parse`
    /// can read — is unit-tested without a live `WKWebView` or a JavaScript bridge.
    ///
    /// The string is returned verbatim (not through `URL` and back), because the
    /// official deep link carries a CR+LF inside its query that only survives if
    /// the raw bytes are handed on untouched; `CredentialOfferLink.parse(scanned:)`
    /// is what strips that framing, exactly as it does for a scanned QR.
    static func deeplink(inScriptMessageBody body: Any) -> String? {
        guard let root = body as? [String: Any],
              let data = root["data"] as? [String: Any],
              let deeplink = data["deeplink"] as? String,
              !deeplink.isEmpty
        else { return nil }
        return deeplink
    }

    // MARK: - Configuration

    /// The `mobile` handler name the issuer page posts to. Matches the official
    /// `WebScriptMessage.mobile`.
    private static let scriptMessageName = "mobile"

    /// ⚠️ Impersonation hook — OFF by default, and deliberately so.
    ///
    /// The official app appends `ModaDigitalWalletApp/<version> iOS` to the
    /// WKWebView User-Agent (`Config.webViewFormate`, `WKWebView+Extension`).
    /// Setting it makes this third-party wallet *claim to be the official app* to
    /// the issuer's server. The user has decided not to do that for now, so the
    /// default is the stock WKWebView UA and nothing is spoofed.
    ///
    /// Flip this to `true` only if an issuer page is found to gate its flow on that
    /// UA — and only after deciding, separately and explicitly, that impersonating
    /// the official app to that server is acceptable. The one line it controls is
    /// in `configuredWebView()`.
    private static let spoofOfficialAppUserAgent = false

    // MARK: - State

    private let initialURL: URL
    private let cardName: String?

    /// One-shot latch. Set the instant a deep link is captured from either path,
    /// after which every further script message and navigation is ignored — the
    /// script handler and `decidePolicyFor` can both fire for one application, and
    /// two collections from one offer is the bug this prevents.
    private var didCapture = false

    /// `WKUserContentController` **strongly** retains a script-message handler, so
    /// adding `self` directly would be a retain cycle that outlives the screen (and
    /// keeps a logged-in webview alive — the exact leak `MyDataWebViewController`
    /// documents). This proxy is what the content controller retains; it points back
    /// **weakly**, so nothing keeps this controller alive and it deallocates
    /// normally (taking its webview with it). `viewWillDisappear` also removes the
    /// registration on the ordinary path, but the weak link is what makes the
    /// teardown safe even if that is skipped — a nonisolated `deinit` cannot touch
    /// the MainActor-isolated webview to do it, so the weak proxy carries that job.
    private let scriptProxy = WeakScriptMessageProxy()

    private lazy var webView: WKWebView = configuredWebView()

    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    // MARK: - Init

    /// - Parameters:
    ///   - url: the `issuerServiceUrl` from the 201i response.
    ///   - cardName: the card's display name, used only for the screen title.
    init(url: URL, cardName: String?) {
        self.initialURL = url
        self.cardName = cardName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = cardName
        // A holder who changes their mind mid-application needs a way out that is
        // not "complete the issuer flow". Installed only when presented inside a
        // navigation controller (the scan entry wraps it in one); a future push
        // presentation would get the system back button instead.
        if navigationController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closeTapped))
        }
        webView.load(URLRequest(url: initialURL))
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Ordinary teardown: remove the handler while the screen still owns it, so
        // the content controller stops retaining the proxy the moment the screen
        // leaves. Safe to call more than once, and harmless if never called — the
        // weak proxy already prevents the retain cycle either way.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.scriptMessageName)
    }

    // MARK: - Web view construction

    private func configuredWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A fresh, in-memory session per collection: the issuer's 門號驗證 /
        // 監理服務網 login cookie lives only as long as this webview and never
        // touches disk. A wallet has no reason to retain a government or telecom
        // sign-in across launches, and not doing so means a second person on the
        // phone cannot resume the first person's issuer session.
        configuration.websiteDataStore = .nonPersistent()
        scriptProxy.target = self
        configuration.userContentController.add(scriptProxy, name: Self.scriptMessageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        // The impersonation hook. Stock UA unless the flag above is deliberately
        // turned on — see `spoofOfficialAppUserAgent`.
        if Self.spoofOfficialAppUserAgent {
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
            webView.customUserAgent = (webView.value(forKey: "userAgent") as? String).map {
                $0 + " ModaDigitalWalletApp/\(version) iOS"
            }
        }
        return webView
    }

    // MARK: - Capture → collect

    /// Called from either return path. Idempotent by the `didCapture` latch.
    private func capture(deeplink: String) {
        guard !didCapture else { return }
        didCapture = true

        loadingIndicator.startAnimating()
        Task { @MainActor in
            defer { loadingIndicator.stopAnimating() }
            guard let link = try? CredentialOfferLink.parse(scanned: deeplink) else {
                // The page returned something in the offer slot that is not an
                // offer. Report it plainly; do not silently swallow, because the
                // holder just finished a flow expecting a card.
                presentResultAndDismiss(
                    NSLocalizedString("The page did not return a valid card to add.",
                                      comment: "webview collect: not an offer"))
                return
            }
            // The gates live inside `CredentialCollection.run`; nothing here can
            // skip them. An offer naming an untrusted issuer is refused here just
            // as it is from a scanned QR.
            let outcome = await CredentialCollection.run(from: link)
            if outcome.isSuccess { Bonds.Haptic.delivered() }
            presentResultAndDismiss(outcome.message)
        }
    }

    private func presentResultAndDismiss(_ message: String) {
        let alert = UIAlertController(
            title: NSLocalizedString("Digital wallet card collection", comment: ""),
            message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""),
                                      style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    /// The official app's `connectionFailed`: a load that never arrives is a dead
    /// end, so say why and leave rather than sit on a blank page.
    private func presentConnectionFailed() {
        // Do not report a connection failure once an offer is already in hand — a
        // `modadigitalwallet:` navigation is cancelled by us, which can surface as
        // a provisional-navigation failure that is not actually a broken link.
        guard !didCapture else { return }
        let alert = UIAlertController(
            title: NSLocalizedString("Connection failed", comment: "webview collect: connection failed title"),
            message: NSLocalizedString("The issuer's page could not be reached. Check your connection and try again.",
                                       comment: "webview collect: connection failed body"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""),
                                      style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == Self.scriptMessageName,
              let deeplink = Self.deeplink(inScriptMessageBody: message.body) else { return }
        capture(deeplink: deeplink)
    }
}

// MARK: - Navigation delegate

extension WebCollectViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        switch scheme {
        case "modadigitalwallet":
            // The offer, delivered by navigation. Latch it *before* cancelling:
            // cancelling can surface as `didFailProvisionalNavigation`, and
            // `capture` setting `didCapture` first is what tells that handler this
            // was our own doing rather than a real failure to report.
            capture(deeplink: url.absoluteString)
            decisionHandler(.cancel)
        case "mailto":
            // Official parity: a `mailto:` link is opened in the system mail app,
            // not treated as an offer. Cancel the in-webview navigation and hand it
            // off. No collection.
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        default:
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadingIndicator.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimating()
        presentConnectionFailed()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimating()
        presentConnectionFailed()
    }
}

// MARK: - Privacy shield

/// The issuer page is where the holder types the sensitive part of the
/// application — a phone number and its verification, or a 監理服務網 login. That
/// must not be left in the app-switcher snapshot, the same channel
/// `MyDataWebViewController`'s flow and every ID screen are shielded from.
extension WebCollectViewController: PrivacyShieldedScreen {}

// MARK: - Weak script-message proxy

/// Breaks the retain cycle `WKUserContentController.add(_:name:)` would otherwise
/// create: the content controller strongly retains its handler, so a controller
/// that registered itself would be kept alive by the very webview it owns. This
/// proxy is what gets retained; it points back **weakly**.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebCollectViewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.handleScriptMessage(message)
    }
}
