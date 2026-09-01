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

enum MyDataImportContinuation: Equatable {
    case dismiss
    case keepPersonalDocumentsOpen(savedCount: Int)
}

/// State for one official MyData web session. It deliberately knows nothing
/// about cookies or certificate assertions; it only decides whether the screen
/// stays open after the app has safely archived a download.
struct MyDataWebImportSession {
    private(set) var savedCount = 0

    mutating func didStoreDocument(of type: MyDataDocumentType) -> MyDataImportContinuation {
        guard type.keepsWebSessionOpenAfterImport else { return .dismiss }
        savedCount += 1
        return .keepPersonalDocumentsOpen(savedCount: savedCount)
    }
}

class MyDataWebViewController : UIViewController {

    private enum FlowStage {
        case details, certificate, returning, waiting, personalDocuments, downloaded
    }
    private var flowStage: FlowStage = .details

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
    private var archiveKnownType: MyDataDocumentType?
    private var openedCertificateApp = false
    private var importSession = MyDataWebImportSession()
    private let guideView = MyDataFlowGuideView()

    private var progressObservation: NSKeyValueObservation?
    private lazy var progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.tintColor = .systemBlue
        return progressView
    }()
    private lazy var webview: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Make the boundary explicit: MyData's own cookies may continue inside
        // its normal persistent website store, but no certificate assertion or
        // downloaded document is copied out of the government-controlled flow.
        // This cannot bypass a new verification required by MyData; it only lets
        // one Personal documents sign-in serve several completed downloads.
        configuration.websiteDataStore = .default()
        let webview = WKWebView(frame: .zero, configuration: configuration)
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

        // A previous run that was killed mid-flow — before the download finished,
        // or while the password alert was up — can have left a zip or a decrypted
        // PDF behind. Opening this screen is the last moment at which those can
        // still be nobody's business, so clear them before adding more.
        try? scratch.purge()

        guideView.onPersonalDocuments = { [weak self] in self?.openPersonalDocuments() }
        guideView.onClose = { [weak self] in self?.dismiss(animated: true) }
        updateGuide(.details)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

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
        // Foreground notifications also arrive after opening Share sheets,
        // Personal documents, and system alerts. Only the exact certificate
        // hand-off is allowed to advance step 2 to step 3.
        guard openedCertificateApp, flowStage == .certificate else { return }
        openedCertificateApp = false
        updateGuide(.returning)
    }

    private func openPersonalDocuments() {
        updateGuide(.personalDocuments)
        guard let url = URL(string: "https://mydata.nat.gov.tw/signin") else { return }
        webview.load(URLRequest(url: url))
    }

    private func updateGuide(_ stage: FlowStage, detail: String? = nil) {
        flowStage = stage
        let content: (MyDataFlowStep, String, String, Bool, Bool)
        switch stage {
        case .details:
            content = (.details,
                       NSLocalizedString("Fill in MyData details", comment: "MyData web guide"),
                       detail ?? NSLocalizedString("Fill in the official page. Saved details are filled only here.", comment: "MyData web guide"),
                       documentType.entryMode == .personalDocuments, false)
        case .certificate:
            content = (.certificate,
                       NSLocalizedString("Approve in 行動自然人憑證", comment: "MyData web guide"),
                       NSLocalizedString("Complete the request there, then return to Bonds.", comment: "MyData web guide"), false, false)
        case .returning:
            content = (.returnToBonds,
                       NSLocalizedString("Continue in Bonds", comment: "MyData web guide"),
                       NSLocalizedString("You are back. MyData will continue on the page below.", comment: "MyData web guide"), false, false)
        case .waiting:
            let wait = documentType.estimatedMinutes.map {
                String(format: NSLocalizedString("MyData estimates about %lld minutes. You may leave now and return from Personal documents after the notification.", comment: "MyData waiting guide"), Int64($0))
            } ?? NSLocalizedString("You may leave now and return from Personal documents after MyData's notification.", comment: "MyData waiting guide")
            content = (.download,
                       NSLocalizedString("Wait for MyData", comment: "MyData web guide"), wait, true, false)
        case .personalDocuments:
            content = (.download,
                       NSLocalizedString("Download from Personal documents", comment: "MyData web guide"),
                       detail ?? NSLocalizedString("Open the completed document and download it here.", comment: "MyData web guide"), false, false)
        case .downloaded:
            content = (.download,
                       NSLocalizedString("Saving to the data vault", comment: "MyData web guide"),
                       NSLocalizedString("Bonds is checking the file and keeping the PDF when the archive contains one.", comment: "MyData web guide"), false, true)
        }
        guideView.configure(step: content.0, title: content.1, detail: content.2,
                            showsPersonalDocuments: content.3, completed: content.4)
    }

    /// Never autofill a subframe or a lookalike domain. The native Keychain values
    /// only enter JavaScript after this exact top-level origin check.
    private func autofillRememberedDetailsIfPossible(_ webView: WKWebView) {
        guard webView.url?.scheme == "https", webView.url?.host?.lowercased() == "mydata.nat.gov.tw",
              let profile = MyDataAutofillProfileStore.load() else { return }
        webView.evaluateJavaScript(MyDataAutofillScript.script(for: profile)) { [weak self] result, _ in
            guard let count = (result as? NSNumber)?.intValue, count > 0 else { return }
            let detail = String(format: NSLocalizedString("Filled %lld saved field(s) on the official MyData page.", comment: "MyData autofill result"), Int64(count))
            guard self?.flowStage == .details else { return }
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
            archiveKnownType = MyDataDocumentRegistry.knownDocument(in: suggestedFilename)
            archiveDisplayName = archiveKnownType?.title
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
                // A file reached through Personal documents gets the registered
                // stable slot whenever its official filename identifies it. This
                // fixes both the generic title and duplicate copies of the same
                // income document. Unknown MyData files still receive an opaque,
                // local UUID and never inherit a server-controlled path/name.
                let id: String
                if documentType.id == MyDataDocumentRegistry.personalDocuments.id {
                    id = archiveKnownType?.id ?? "mydata-file-\(UUID().uuidString.lowercased())"
                } else {
                    id = documentType.id
                }
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
                // When an inbox filename identifies a known document, clear the
                // pending request for that document rather than the generic inbox.
                MyDataPendingRequestStore.resolve(documentID: id)
                completion(.vaultDocument(entry))
                switch importSession.didStoreDocument(of: documentType) {
                case .keepPersonalDocumentsOpen(let savedCount):
                    let detail = String(format: NSLocalizedString(
                        "%lld file(s) saved. Keep this screen open and download another completed file.",
                        comment: "MyData multi-file import result"),
                        Int64(savedCount))
                    updateGuide(.personalDocuments, detail: detail)
                case .dismiss:
                    dismiss(animated: true)
                }
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
        archiveKnownType = nil
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
                        self.completion(.nationalID(nationalIDModel))
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

/// A small persistent guide above the government page. It does not infer that a
/// signature or download succeeded; it only says which hand-off the holder is in
/// and keeps the official Personal documents continuation one tap away.
private final class MyDataFlowGuideView: UIView {
    var onPersonalDocuments: (() -> Void)?
    var onClose: (() -> Void)?

    private let progress = MyDataFlowProgressView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let personalDocumentsButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2

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

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel, personalDocumentsButton])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(9, after: detailLabel)
        progress.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        addSubview(text)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            progress.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            text.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 9),
            text.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant:
                                                ceil(titleLabel.font.lineHeight * 2)),
            detailLabel.heightAnchor.constraint(greaterThanOrEqualToConstant:
                                                 ceil(detailLabel.font.lineHeight * 2)),
            personalDocumentsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        accessibilityIdentifier = "mydata.web.guide"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(step: MyDataFlowStep, title: String, detail: String,
                   showsPersonalDocuments: Bool, completed: Bool) {
        progress.configure(current: step, completed: completed)
        titleLabel.text = title
        detailLabel.text = detail
        // Preserve the action row's height in every stage. Collapsing an arranged
        // subview moved the WKWebView's top edge by ~40pt whenever the flow
        // advanced, which looked like the government page itself jumped.
        personalDocumentsButton.alpha = showsPersonalDocuments ? 1 : 0
        personalDocumentsButton.isUserInteractionEnabled = showsPersonalDocuments
        personalDocumentsButton.accessibilityElementsHidden = !showsPersonalDocuments
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
