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

        guard
            let archiveURL = archiveURL,
            let pdfData = try? scratch.pdfData(fromArchiveAt: archiveURL),
            // From `Data`, not from the URL: the document keeps working after the
            // file is deleted, which is what lets the purge happen now rather than
            // after the user has typed their ID number into the alert below.
            let pdf = PDFDocument(data: pdfData),
            pdf.isEncrypted
        else {
            presentAlert(message: NSLocalizedString("Successfully downloaded but processing error", comment: ""))
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
        // dealing with the encrypted PDF
        unzipWithPassword(of: pdf, didFail: false)
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
                        self.presentAlert(message: NSLocalizedString("Successfully downloaded but processing error", comment: ""))
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
