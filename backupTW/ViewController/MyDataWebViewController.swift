//
//  MyDataWebViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/5/30.
//

import UIKit
import WebKit
import PDFKit

class MyDataWebViewController : UIViewController {

    /// Owns every file this flow creates, outside Documents and outside backups,
    /// and is emptied the moment the PDF has been read. See `MyDataScratch`.
    private let scratch = MyDataScratch()
    /// The zip we told WKDownload to write, so `downloadDidFinish` knows what to
    /// unpack. Nil whenever nothing is in flight.
    private var archiveURL: URL?

    private var progressObservation: NSKeyValueObservation?
    private lazy var progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.tintColor = .systemBlue
        return progressView
    }()
    private lazy var webview: WKWebView = {
        let webview = WKWebView()
        webview.navigationDelegate = self
        // The identity-verification step (TWCA 自然人憑證 middleware, and the idpaas
        // libraries behind it) drives the user with native `alert()` — dozens of
        // call sites across twcaCryptoLib / CheckAndLoad / r_common. WKWebView shows
        // none of those without a `WKUIDelegate`, so the flow silently freezes at
        // 「請選擇身分驗證」. This is what lets those panels appear.
        webview.uiDelegate = self
        webview.allowsBackForwardNavigationGestures = true
        return webview
    }()
    private let completion: ((NationalIDModel) -> Void)
    /// Which MyData item to open, e.g. `personal/detail/API.idPhotoRev` for the
    /// national ID or `personal/detail/API.syWqjr4flJ` for the income record. The
    /// fetch/auth machinery is identical across items — only the entry URL differs.
    private let itemPath: String

    init(itemPath: String, completion: @escaping ((NationalIDModel) -> Void)) {
        self.itemPath = itemPath
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The backstop for the exit the code below cannot see: the user swiping the
    /// sheet away, or the app being backgrounded and killed, part-way through the
    /// download. Every other path purges explicitly; this one catches the rest,
    /// because a household-registration PDF outliving the screen that fetched it
    /// is the failure this whole class is arranged to prevent.
    deinit {
        try? scratch.purge()
    }

    override func loadView() {
        view = webview
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // A previous run that was killed mid-flow — before the download finished,
        // or while the password alert was up — can have left a zip or a decrypted
        // PDF behind. Opening this screen is the last moment at which those can
        // still be nobody's business, so clear them before adding more.
        try? scratch.purge()

        progressObservation = webview.observe(\.estimatedProgress, options: [.new]) { webview, change in
            guard let progress = change.newValue else { return }
            if progress >= 1.0 {
                UIView.animate(withDuration: 0.3, animations: {
                    self.progressView.alpha = 0
                }, completion: { _ in
                    self.progressView.setProgress(0, animated: false) // Reset for next load
                })
            } else {
                self.progressView.alpha = 1
            }
            self.progressView.setProgress(Float(progress), animated: true)
        }

        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2)
        ])

        reloadWebViewToMobilemoica()
    }

    private func reloadWebViewToMobilemoica() {
        let urlString = "https://mydata.nat.gov.tw/\(itemPath)"
        let url = URL(string: urlString)!
        webview.load(URLRequest(url: url))
    }
}

extension MyDataWebViewController : WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.canShowMIMEType,
           let response = navigationResponse.response as? HTTPURLResponse,
           let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           contentType.range(of: "attachment", options: .caseInsensitive) != nil {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if let scheme = url.scheme,
           scheme == "mobilemoica",
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        if url.absoluteString == "https://mydata.nat.gov.tw/inquiry/docs" {
            // The webpage may be redirected to homepage of MyData. Reload the webview to Mobilemoica in case the user needs to start over.
            reloadWebViewToMobilemoica()
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
}

extension MyDataWebViewController : WKDownloadDelegate {

    /// `suggestedFilename` is ignored, and that is the point: it comes from the
    /// response's `Content-Disposition`, so it is chosen by the far end of the
    /// connection rather than by us, and the previous version of this method fed
    /// it straight into a path under Documents. `MyDataScratch` picks both the
    /// directory (not Documents, not backed up) and the name (a UUID, so no
    /// server-supplied string ever reaches the filesystem).
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        do {
            let destination = try scratch.downloadDestination()
            archiveURL = destination
            return destination
        } catch {
            archiveURL = nil
            // Returning nil cancels the download without calling back, so this is
            // our only chance to say anything about it.
            presentAlert(message: NSLocalizedString("Successfully downloaded but processing error", comment: ""))
            return nil
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // A failed download still leaves a partial file behind.
        discardDownloadedFiles()
        presentAlert(message: error.localizedDescription)
    }

    func downloadDidFinish(_ download: WKDownload) {
        // Everything below this line touches the user's household registration in
        // the clear. The `defer` is what makes that acceptable: it runs on the
        // success path, on every `guard` failure, and on a throw from inside the
        // unzip, so there is no exit from this method that leaves the zip, the
        // unpacked directory or the PDF on disk.
        defer { discardDownloadedFiles() }

        guard let archiveURL else {
            presentProcessingError(detail: nil)
            return
        }

        // From `Data`, not from the URL: the document keeps working after the file
        // is deleted, which is what lets the purge happen now rather than after the
        // user has typed their ID number into the alert below.
        let pdfData: Data
        do {
            pdfData = try scratch.pdfData(fromArchiveAt: archiveURL)
        } catch {
            // The national ID arrives as a PDF inside a zip. A vault document that
            // arrives in some other shape (not a zip, or a zip of a CSV) lands here;
            // on DEBUG we say which shape — structure only, never content — so its
            // own handling can be written.
            var detail: String?
            #if DEBUG
            detail = "pdfData: \(error) · " + scratch.debugArchiveShape(ofArchiveAt: archiveURL)
            #endif
            presentProcessingError(detail: detail)
            return
        }

        guard let pdf = PDFDocument(data: pdfData) else {
            var detail: String?
            #if DEBUG
            detail = "archive held a non-PDF (\(pdfData.count)B)"
            #endif
            presentProcessingError(detail: detail)
            return
        }

        // Recorded here and nowhere else, because this is the only moment the
        // bytes exist: `defer { discardDownloadedFiles() }` above deletes them
        // on the way out, and the document is deliberately built from `Data` so
        // that the purge can happen before the user types their ID number.
        //
        // What it settles is not small. This app re-signs the MyData fields with
        // the device key and calls the result a credential, and the only
        // justification for that detour is the claim that the download carries
        // no document-level signature. Nobody had checked. If it turns out to be
        // signed, the data already has an authoritative trust root and the
        // self-signing is weaker than what arrived.
        //
        // Only the scan result is kept — four values that describe the envelope.
        // No page text, no field, nothing from the document itself.
        PDFSignatureScan.record(PDFSignatureScan.scan(pdfData))

        if pdf.isEncrypted {
            // National ID (and any document delivered encrypted): unlock with the
            // ID number, then parse.
            unzipWithPassword(of: pdf, didFail: false)
        } else if let model = parseUnencryptedPDF(pdf) {
            // Some MyData documents deliver an *unencrypted* PDF — parse it straight
            // away, no password prompt.
            completion(model)
            dismiss(animated: true)
        } else {
            // Unencrypted, but the national-ID-shaped parser found none of its
            // fields — i.e. a different document whose own parser does not exist yet.
            var detail: String?
            #if DEBUG
            detail = "unencrypted PDF, parse=nil, pages=\(pdf.pageCount)"
            #endif
            presentProcessingError(detail: detail)
        }
    }

    /// The download completed but the bytes were not the national-ID shape. Release
    /// builds show only the plain message; DEBUG builds append a structure-only
    /// detail (never a field value) so a new document's format can be identified.
    private func presentProcessingError(detail: String?) {
        let base = NSLocalizedString("Successfully downloaded but processing error", comment: "")
        presentAlert(message: detail.map { "\(base)\n\n[DEBUG] \($0)" } ?? base)
    }

    /// Drops the whole scratch directory and forgets what was in it.
    private func discardDownloadedFiles() {
        archiveURL = nil
        try? scratch.purge()
    }

    private func presentAlert(message: String) {
        let alert = UIAlertController(
            title: NSLocalizedString("Error", comment: ""),
            message: message,
            preferredStyle: .alert)
        let confirm = UIAlertAction(
            title: NSLocalizedString("Confirm", comment: ""),
            style: .default, handler: nil)
        alert.addAction(confirm)
        self.present(alert, animated: true)
    }

    private func unzipWithPassword(of pdf: PDFDocument, didFail: Bool) {
        let title = didFail ?
        NSLocalizedString("Unzipping failed (wrong password). Please enter the correct National ID number.", comment: "")
        :
        NSLocalizedString("Please enter the National ID number (unzipping password)", comment: "")
        let alert = UIAlertController(
            title: title,
            message: NSLocalizedString("For this unzipping only, not to be used for any other purpose.", comment: ""),
            preferredStyle: .alert)
        // `[weak alert, weak self]`, and both halves matter.
        //
        // The closure used to capture `alert` strongly, and `addAction` puts the
        // closure on the alert — a cycle. Measured: after dismissal
        // `alertStillAlive = true` and `fieldText = A123456789`. So the
        // 身分證統一編號 stayed in memory for the life of the process, under a
        // message that says 「僅供本次解壓縮使用，絕不另作他用」. A wrong password
        // recurses, so each mistake left another one behind.
        //
        // The strong `self` was the second half and cost more: it kept this
        // controller — and with it a `WKWebView` logged in to
        // mydata.nat.gov.tw — alive to process exit, so the
        // `deinit { try? scratch.purge() }` backstop never ran.
        //
        // Same shape as `ZKProofViewController.makeIDNumberPrompt`, which had
        // this fixed already; this path was simply never revisited.
        let confirm = UIAlertAction(
            title: NSLocalizedString("Continue", comment: ""),
            style: .default) { [weak alert, weak self] _ in
                guard let self,
                      let passwordTextField = alert?.textFields?.first,
                      let password = passwordTextField.text
                else {
                    return
                }
                let success = pdf.unlock(withPassword: password)
                if success {
                    if let nationalIDModel = self.parseUnencryptedPDF(pdf) {
                        self.completion(nationalIDModel)
                        self.dismiss(animated: true)
                    } else {
                        // Unlocked, but not the national-ID layout — an encrypted
                        // document whose own parser does not exist yet.
                        var detail: String?
                        #if DEBUG
                        detail = "decrypted PDF, parse=nil, pages=\(pdf.pageCount)"
                        #endif
                        self.presentProcessingError(detail: detail)
                    }
                } else {
                    self.unzipWithPassword(of: pdf, didFail: true)
                }
            }
        alert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Input National ID number (unzipping password)", comment: "")
        }
        alert.addAction(confirm)
        self.present(alert, animated: true)
    }

    private func parseUnencryptedPDF(_ pdf: PDFDocument) -> NationalIDModel? {
        // expected only one page
        guard
            let firstPage = pdf.page(at: 0),
            let pdfText = firstPage.string
        else {
            return nil
        }
        return NationalIDModel.parse(fromPDFText: pdfText)
    }
}

// MARK: - JavaScript dialogs (WKUIDelegate)

/// The MyData 身分驗證 flow speaks to the user through native `alert()` /
/// `confirm()` / `prompt()`. WKWebView presents none of these unless the host
/// implements `WKUIDelegate` — and a `confirm`/`prompt` that never returns leaves
/// the page's JavaScript blocked. So every panel is bridged to a `UIAlertController`,
/// and the golden rule is that each completion handler is called **exactly once**:
/// on the button tap, or immediately if there is nowhere to present.
extension MyDataWebViewController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
                continuation.resume()
            })
            presentDialog(alert) { continuation.resume() }
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
                continuation.resume(returning: true)
            })
            // No presenter → the safe default for a confirm is「no」.
            presentDialog(alert) { continuation.resume(returning: false) }
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text)
            })
            presentDialog(alert) { continuation.resume(returning: defaultText) }
        }
    }

    /// Presents on the topmost controller — the download-password alert can already
    /// be up — and, if there is genuinely nowhere to present, runs `fallback` so the
    /// web content is never left waiting on a handler that will not be called.
    private func presentDialog(_ alert: UIAlertController, fallback: @escaping () -> Void) {
        guard viewIfLoaded?.window != nil else { fallback(); return }
        var presenter: UIViewController = self
        while let next = presenter.presentedViewController, !next.isBeingDismissed {
            presenter = next
        }
        presenter.present(alert, animated: true)
    }
}
