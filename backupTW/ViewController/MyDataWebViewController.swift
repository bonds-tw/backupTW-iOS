//
//  MyDataWebViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/5/30.
//

import UIKit
import WebKit
import PDFKit

enum MyDataImportResult {
    case nationalID(NationalIDModel)
    case vaultDocument(MyDataVaultArchive.Entry)
}

class MyDataWebViewController : UIViewController {

    private enum FlowStage {
        case details, certificate, returning, waiting, personalDocuments, downloaded
    }

    /// Owns every file this flow creates, outside Documents and outside backups,
    /// and is emptied the moment the PDF has been read. See `MyDataScratch`.
    private let scratch = MyDataScratch()
    /// The zip we told WKDownload to write, so `downloadDidFinish` knows what to
    /// unpack. Nil whenever nothing is in flight.
    private var archiveURL: URL?
    /// Metadata only. The server-supplied filename never becomes a local path;
    /// a short alphanumeric suffix is retained so the vault can reopen the raw
    /// original with the right parser later.
    private var archiveFileExtension = ""
    /// Used only as display metadata after a successful import; never used as a
    /// path and never shown when it does not match a known registry title.
    private var archiveDisplayName: String?
    private var openedCertificateApp = false
    private let guideView = MyDataFlowGuideView()

    private var progressObservation: NSKeyValueObservation?
    private lazy var progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.tintColor = .tintColor
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
    private let completion: ((MyDataImportResult) -> Void)
    /// Which document this run fetches. Its `myDataItemPath` chooses the entry URL
    /// (`personal/detail/API.idPhotoRev` for the national ID, `…API.syWqjr4flJ` for
    /// income, …); its `id` decides whether the original is archived. The fetch/auth
    /// machinery is identical across items — only the entry URL and archiving differ.
    private let documentType: MyDataDocumentType

    /// Where a **vault** document's raw original is kept (保險箱原檔先儲存). Lazy so
    /// the national-ID flow, which never archives, does not create the directory.
    private lazy var vaultArchive = try? MyDataVaultArchive()

    private var itemPath: String {
        documentType.myDataItemPath
            ?? MyDataDocumentRegistry.nationalID.myDataItemPath
            ?? "personal/detail/API.idPhotoRev"
    }

    init(documentType: MyDataDocumentType, completion: @escaping ((MyDataImportResult) -> Void)) {
        self.documentType = documentType
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
        let root = UIView()
        root.backgroundColor = .systemBackground
        guideView.translatesAutoresizingMaskIntoConstraints = false
        webview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(guideView)
        root.addSubview(webview)
        NSLayoutConstraint.activate([
            guideView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            guideView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            guideView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webview.topAnchor.constraint(equalTo: guideView.bottomAnchor),
            webview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webview.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Pushed onto the wizard's navigation stack, whose bar prefers large
        // titles: without `.never` the bar reserved a large-title's worth of
        // empty black above the guide (回報 2026-09-02). The compact title names
        // the document; the guide bar below carries the step.
        title = documentType.title
        navigationItem.largeTitleDisplayMode = .never

        // A previous run that was killed mid-flow — before the download finished,
        // or while the password alert was up — can have left a zip or a decrypted
        // PDF behind. Opening this screen is the last moment at which those can
        // still be nobody's business, so clear them before adding more.
        try? scratch.purge()

        guideView.onPersonalDocuments = { [weak self] in self?.openPersonalDocuments() }
        guideView.onClose = { [weak self] in self?.closeFlow() }
        updateGuide(.details)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        progressObservation = webview.observe(\.estimatedProgress, options: [.new]) { webview, change in
            guard let progress = change.newValue else { return }
            if progress >= 1.0 {
                UIView.animate(withDuration: Bonds.Motion.standard, animations: {
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
            progressView.topAnchor.constraint(equalTo: webview.topAnchor),
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

    @objc private func appDidBecomeActive() {
        guard openedCertificateApp else { return }
        updateGuide(.returning)
    }

    private func openPersonalDocuments() {
        updateGuide(.personalDocuments)
        guard let url = URL(string: "https://mydata.nat.gov.tw/signin") else { return }
        webview.load(URLRequest(url: url))
    }

    private func updateGuide(_ stage: FlowStage, detail: String? = nil) {
        let content: (String, String, Bool)
        switch stage {
        case .details:
            content = (NSLocalizedString("Step 1 of 4 · MyData details", comment: "MyData web guide"),
                       detail ?? NSLocalizedString("Fill in the official page. Saved details are filled only here.", comment: "MyData web guide"),
                       documentType.entryMode == .personalDocuments)
        case .certificate:
            content = (NSLocalizedString("Step 2 of 4 · Approve the signature", comment: "MyData web guide"),
                       NSLocalizedString("Complete the request in 行動自然人憑證, then come back to Bonds.", comment: "MyData web guide"), false)
        case .returning:
            content = (NSLocalizedString("Step 3 of 4 · Back in Bonds", comment: "MyData web guide"),
                       NSLocalizedString("Keep this page open while MyData finishes the verification.", comment: "MyData web guide"), false)
        case .waiting:
            let wait = documentType.estimatedMinutes.map {
                String(format: NSLocalizedString("MyData estimates about %lld minutes. You may leave now and return from Personal documents after the notification.", comment: "MyData waiting guide"), Int64($0))
            } ?? NSLocalizedString("You may leave now and return from Personal documents after MyData's notification.", comment: "MyData waiting guide")
            content = (NSLocalizedString("Step 4 of 4 · Waiting for MyData", comment: "MyData web guide"), wait, true)
        case .personalDocuments:
            content = (NSLocalizedString("MyData · Personal documents", comment: "MyData web guide"),
                       NSLocalizedString("Sign in, open Personal documents, then download the completed file here.", comment: "MyData web guide"), true)
        case .downloaded:
            content = (NSLocalizedString("Downloaded · sealing in the vault", comment: "MyData web guide"),
                       NSLocalizedString("Bonds is checking the file and keeping the PDF when the archive contains one.", comment: "MyData web guide"), false)
        }
        guideView.configure(title: content.0, detail: content.1,
                            showsPersonalDocuments: content.2)
    }

    /// Never autofill a subframe or a lookalike domain. The native Keychain values
    /// only enter JavaScript after this exact top-level origin check.
    private func autofillRememberedDetailsIfPossible(_ webView: WKWebView) {
        guard webView.url?.scheme == "https", webView.url?.host?.lowercased() == "mydata.nat.gov.tw",
              let profile = MyDataAutofillProfileStore.load() else { return }
        webView.evaluateJavaScript(MyDataAutofillScript.script(for: profile)) { [weak self] result, _ in
            guard let count = (result as? NSNumber)?.intValue, count > 0 else { return }
            let detail = String(format: NSLocalizedString("Filled %lld saved field(s) on the official MyData page.", comment: "MyData autofill result"), Int64(count))
            self?.updateGuide(.details, detail: detail)
        }
    }
}

extension MyDataWebViewController : WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.range(of: "attachment", options: .caseInsensitive) != nil {
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
            openedCertificateApp = true
            updateGuide(.certificate)
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        autofillRememberedDetailsIfPossible(webView)
        guard webView.url?.host?.lowercased() == "mydata.nat.gov.tw" else { return }
        let script = """
        (() => {
          const text = document.body?.innerText || '';
          return {
            verified: text.includes('已驗證您的身分'),
            wait: text.includes('無須在此頁面等待') && text.includes('個人文件')
          };
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let state = result as? [String: Any],
                  state["verified"] as? Bool == true,
                  state["wait"] as? Bool == true else { return }
            MyDataPendingRequestStore.remember(documentID: self.documentType.id)
            self.updateGuide(.waiting)
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
            archiveFileExtension = Self.safeFileExtension(suggestedFilename: suggestedFilename,
                                                          mimeType: response.mimeType)
            archiveDisplayName = Self.knownDisplayName(suggestedFilename: suggestedFilename)
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
        updateGuide(.downloaded)
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

        // A vault document is the original file, not a national-ID-shaped VC.
        // Store it under its own document id and finish here: feeding an income,
        // insurance or property PDF into `NationalIDModel.parse` is what made the
        // UI show 身分證 fields under every MyData item and could mint the wrong
        // credential if a coincidental label matched.
        if documentType.id != MyDataDocumentRegistry.nationalID.id {
            do {
                guard let vaultArchive else { throw CocoaError(.fileNoSuchFile) }
                let id = documentType.id == MyDataDocumentRegistry.personalDocuments.id
                    ? "mydata-file-\(UUID().uuidString.lowercased())"
                    : documentType.id
                let displayName = documentType.entryMode == .personalDocuments
                    ? (archiveDisplayName ?? (documentType.id == MyDataDocumentRegistry.personalDocuments.id
                        ? NSLocalizedString("MyData document", comment: "generic MyData document")
                        : documentType.title))
                    : documentType.title
                let entry: MyDataVaultArchive.Entry
                if archiveFileExtension == "pdf" {
                    let data = try Data(contentsOf: archiveURL)
                    guard PDFDocument(data: data) != nil else { throw MyDataScratchError.noPDFInArchive }
                    entry = try vaultArchive.store(data: data, id: id,
                                                   fileExtension: "pdf", displayName: displayName)
                } else if archiveFileExtension == "zip" {
                    // Reject zip-slip before either extracting or retaining an
                    // archive. If it contains a PDF, keep that PDF — not the ZIP
                    // transport wrapper. A safe CSV-only archive remains original.
                    try MyDataScratch.rejectUnsafeEntries(inArchiveAt: archiveURL)
                    if let pdfData = try? scratch.pdfData(fromArchiveAt: archiveURL),
                       PDFDocument(data: pdfData) != nil {
                        entry = try vaultArchive.store(data: pdfData, id: id,
                                                       fileExtension: "pdf", displayName: displayName)
                    } else {
                        entry = try vaultArchive.store(originalAt: archiveURL, id: id,
                                                       fileExtension: "zip", displayName: displayName)
                    }
                } else {
                    entry = try vaultArchive.store(originalAt: archiveURL, id: id,
                                                   fileExtension: archiveFileExtension,
                                                   displayName: displayName)
                }
                MyDataPendingRequestStore.resolve(documentID: documentType.id)
                completion(.vaultDocument(entry))
                closeFlow()
            } catch {
                presentProcessingError(detail: nil)
            }
            return
        }

        // From `Data`, not from the URL: the document keeps working after the file
        // is deleted, which is what lets the purge happen now rather than after the
        // user has typed their ID number into the alert below.
        let pdfData: Data
        do {
            pdfData = try scratch.pdfData(fromArchiveAt: archiveURL)
        } catch {
            // The national ID arrives as a PDF inside a zip. On DEBUG we say
            // which unexpected shape arrived — structure only, never content.
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
            completion(.nationalID(model))
            closeFlow()
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

    private static func safeFileExtension(suggestedFilename: String,
                                          mimeType: String?) -> String {
        let suffix = URL(fileURLWithPath: suggestedFilename).pathExtension.lowercased()
        if !suffix.isEmpty, suffix.utf8.count <= 10,
           suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return suffix
        }
        switch mimeType?.lowercased() {
        case "application/zip", "application/x-zip-compressed": return "zip"
        case "application/pdf": return "pdf"
        case "application/json": return "json"
        default: return ""
        }
    }

    /// The document's display name, from the download's suggested filename.
    ///
    /// The first cut allowed only pre-localised registry titles through and gave
    /// everything else the neutral 「MyData document」 — on the grounds that a
    /// filename can contain the holder's name. In practice that renamed every
    /// real personal document (「114年度綜合所得稅各類所得資料清單.pdf」) into an
    /// unidentifiable generic card, and a pile of cards all named 「MyData 文件」
    /// defeats the vault (回報 2026-09-02). The risk was also mis-weighed: this
    /// is the holder's own wallet, whose ID card face already shows their name
    /// in full — a document title on the same surface adds nothing.
    ///
    /// A registry match still wins (canonical beats verbatim); otherwise the
    /// filename is kept, minus its extension, laundered through `UntrustedText`
    /// so a server-supplied string cannot carry rewriting code points or
    /// unbounded length onto a glanceable surface.
    private static func knownDisplayName(suggestedFilename: String) -> String? {
        if let known = MyDataDocumentRegistry.vaultDocuments.first(where: { type in
            suggestedFilename.localizedCaseInsensitiveContains(type.title)
        })?.title {
            return known
        }
        let stem = (suggestedFilename as NSString).deletingPathExtension
        let cleaned = UntrustedText.term(stem).text
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleaned
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
        archiveDisplayName = nil
        try? scratch.purge()
    }

    /// Leaves the web step: pops when this screen was pushed onto the wizard's
    /// navigation stack (the flattened flow), falls back to a modal dismissal
    /// for any presenter that still presents it.
    private func closeFlow() {
        if let nav = navigationController, nav.viewControllers.contains(self),
           nav.viewControllers.first !== self {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func presentAlert(message: String) {
        let alert = UIAlertController(
            title: NSLocalizedString("Error", comment: ""),
            message: message,
            preferredStyle: .alert)
        let confirm = UIAlertAction(
            title: NSLocalizedString("OK", comment: ""),
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
                        self.completion(.nationalID(nationalIDModel))
                        self.closeFlow()
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

/// A small persistent guide above the government page. It does not infer that a
/// signature or download succeeded; it only says which hand-off the holder is in
/// and keeps the official Personal documents continuation one tap away.
private final class MyDataFlowGuideView: UIView {
    var onPersonalDocuments: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let personalDocumentsButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        var personal = UIButton.Configuration.tinted()
        personal.title = NSLocalizedString("Personal documents", comment: "MyData continuation button")
        personal.image = UIImage(systemName: "folder")
        personal.imagePadding = 5
        personal.cornerStyle = .capsule
        personalDocumentsButton.configuration = personal
        personalDocumentsButton.addTarget(self, action: #selector(personalDocumentsTapped),
                                           for: .touchUpInside)

        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark")
        closeButton.configuration = close
        closeButton.accessibilityLabel = NSLocalizedString("Close", comment: "")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        // Two rows, not one (回報 2026-09-02): title and subtitle beside two
        // buttons left the capsule squeezed into a two-line pill and the text
        // in a four-line wad. Row one gives the step title the full width with
        // the close control; row two pairs the explanation with the one action
        // it explains. Buttons never compress — text wraps instead.
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = Bonds.Space.s
        let detailRow = UIStackView(arrangedSubviews: [detailLabel, personalDocumentsButton])
        detailRow.axis = .horizontal
        detailRow.alignment = .center
        detailRow.spacing = Bonds.Space.m
        let rows = UIStackView(arrangedSubviews: [titleRow, detailRow])
        rows.axis = .vertical
        rows.spacing = Bonds.Space.xs
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: Bonds.Space.s),
            rows.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Bonds.Space.s),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        personalDocumentsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        personalDocumentsButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, detail: String, showsPersonalDocuments: Bool) {
        titleLabel.text = title
        detailLabel.text = detail
        personalDocumentsButton.isHidden = !showsPersonalDocuments
        titleLabel.accessibilityLabel = "\(title). \(detail)"
    }

    @objc private func personalDocumentsTapped() { onPersonalDocuments?() }
    @objc private func closeTapped() { onClose?() }
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
