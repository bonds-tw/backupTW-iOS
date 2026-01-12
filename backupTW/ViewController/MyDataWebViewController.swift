//
//  MyDataWebViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/5/30.
//

import UIKit
import WebKit
import Zip
import PDFKit

class MyDataWebViewController : UIViewController {

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

    private lazy var latestFilename: String = {
        return ""
    }()

    init(completion: @escaping ((NationalIDModel) -> Void)) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = webview
    }

    override func viewDidLoad() {
        super.viewDidLoad()

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
        let urlString = "https://mydata.nat.gov.tw/personal/detail/API.idPhotoRev"
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

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        if let url = FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask).first {
            latestFilename = suggestedFilename
            return URL(string: suggestedFilename, relativeTo: url)
        }
        return nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = UIAlertController(
            title: NSLocalizedString("Error", comment: ""),
            message: error.localizedDescription,
            preferredStyle: .alert)
        let confirm = UIAlertAction(
            title: NSLocalizedString("Confirm", comment: ""),
            style: .default, handler: nil)
        alert.addAction(confirm)
        self.present(alert, animated: true)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard
            let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask).first,
            let filePath = URL(string: latestFilename, relativeTo: documentDirectory),
            let unzipDirectory = try? Zip.quickUnzipFile(filePath),
            let contentsOfDirectory = try? FileManager.default.contentsOfDirectory(at: unzipDirectory, includingPropertiesForKeys: nil),
            let expectedPDFURL = contentsOfDirectory.first,
            expectedPDFURL.pathExtension.lowercased() == "pdf",
            let pdf = PDFDocument(url: expectedPDFURL),
            pdf.isEncrypted
        else {
            let alert = UIAlertController(
                title: NSLocalizedString("Error", comment: ""),
                message: NSLocalizedString("Successfully downloaded but processing error", comment: ""),
                preferredStyle: .alert)
            let confirm = UIAlertAction(
                title: NSLocalizedString("Confirm", comment: ""),
                style: .default, handler: nil)
            alert.addAction(confirm)
            self.present(alert, animated: true)
            return
        }
        // dealing with the encrypted PDF
        unzipWithPassword(of: pdf, didFail: false)
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
        let confirm = UIAlertAction(
            title: NSLocalizedString("Continue", comment: ""),
            style: .default) { _ in
                guard let passwordTextField = alert.textFields?.first,
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
                        let alert = UIAlertController(
                            title: NSLocalizedString("Error", comment: ""),
                            message: NSLocalizedString("Successfully downloaded but processing error", comment: ""),
                            preferredStyle: .alert)
                        let confirm = UIAlertAction(
                            title: NSLocalizedString("Confirm", comment: ""),
                            style: .default, handler: nil)
                        alert.addAction(confirm)
                        self.present(alert, animated: true)
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
        let parts = pdfText.components(separatedBy: "\n")
        let line1 = parts[1].components(separatedBy: " ")
        let field1 = line1[0].components(separatedBy: "：")
        let unifiedNo: String?
        if field1[0] == "統號" {
            unifiedNo = field1[1]
        } else {
            unifiedNo = nil
        }
        let field2 = line1[1].components(separatedBy: ":")
        let name: String?
        if field2[0] == "姓名" {
            name = field2[1]
        } else {
            name = nil
        }
        let line2 = parts[2].components(separatedBy: " ")
        let field3 = line2[0].components(separatedBy: ":")
        let birthdate: String?
        if field3[0] == "出生日期" {
            birthdate = field3[1]
        } else {
            birthdate = nil
        }
        let line6 = parts[6].replacingOccurrences(of: "\n", with: "").components(separatedBy: ":")
        var addressOfHousehold = ""
        if line6[0] == "戶籍地址" {
            addressOfHousehold = line6[1]
        }
        let lastIndex = parts.count - 1
        for index in 7...lastIndex {
            if index != lastIndex {
                addressOfHousehold += parts[index]
            }
        }
        return NationalIDModel(nationality: "中華民國（臺灣）", unifiedNo: unifiedNo, name: name, birthdate: birthdate, addressOfHousehold: addressOfHousehold)
    }
}
