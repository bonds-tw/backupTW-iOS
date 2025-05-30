//
//  ViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/5/30.
//

import UIKit
import WebKit
import Zip
import PDFKit

class ViewController : UIViewController {

    private lazy var webview: WKWebView = {
        let webview = WKWebView()
        webview.navigationDelegate = self
        webview.allowsBackForwardNavigationGestures = true
        return webview
    }()

    private lazy var latestFilename: String = {
        return ""
    }()

    override func loadView() {
        view = webview
    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // 行動自然人憑證 CHTNpc_PROD
        let mobilemoicaURLScheme = "mobilemoica://"
        let mobilemoicaURL = URL(string: mobilemoicaURLScheme)!
        if !UIApplication.shared.canOpenURL(mobilemoicaURL) {
            let alert = UIAlertController(
                title: "事前準備",
                message: "請先申辦行動自然人憑證",
                preferredStyle: .alert)
            let confirm = UIAlertAction(title: "前往申辦指南", style: .default) { _ in
                let mobilemoicaOnboarding = "https://fido.moi.gov.tw/pt/teaching"
                let mobilemoicaOnboardingURL = URL(string: mobilemoicaOnboarding)!
                UIApplication.shared.open(mobilemoicaOnboardingURL)
            }
            alert.addAction(confirm)
            self.present(alert, animated: true)
            return
        }

        reloadWebViewToMobilemoica()
    }

    private func reloadWebViewToMobilemoica() {
        let urlString = "https://mydata.nat.gov.tw/personal/detail/API.idPhotoRev"
        let url = URL(string: urlString)!
        webview.load(URLRequest(url: url))
    }
}

extension ViewController : WKNavigationDelegate {

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

extension ViewController : WKDownloadDelegate {

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        if let url = FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask).first {
            latestFilename = suggestedFilename
            return URL(string: suggestedFilename, relativeTo: url)
        }
        return nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = UIAlertController(
            title: "錯誤",
            message: error.localizedDescription,
            preferredStyle: .alert)
        let confirm = UIAlertAction(title: "確認", style: .default, handler: nil)
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
                title: "錯誤",
                message: "下載成功，但後續處理錯誤",
                preferredStyle: .alert)
            let confirm = UIAlertAction(title: "確認", style: .default, handler: nil)
            alert.addAction(confirm)
            self.present(alert, animated: true)
            return
        }
        // dealing with the encrypted PDF
        unzipWithPassword(of: pdf, didFail: false)
    }

    private func unzipWithPassword(of pdf: PDFDocument, didFail: Bool) {
        let title = didFail ?
        "解壓縮失敗（密碼錯誤），請輸入正確的身分證字號"
        :
        "請輸入身分證字號（解壓縮密碼）"
        let alert = UIAlertController(
            title: title,
            message: "僅用於此次解壓縮，絕不另作他用",
            preferredStyle: .alert)
        let confirm = UIAlertAction(title: "下一步", style: .default) { _ in
            guard let passwordTextField = alert.textFields?.first,
                  let password = passwordTextField.text
            else {
                return
            }
            let success = pdf.unlock(withPassword: password)
            if success {
                self.parseUnencryptedPDF(pdf)
            } else {
                self.unzipWithPassword(of: pdf, didFail: true)
            }
        }
        alert.addTextField { textField in
            textField.placeholder = "輸入身分證字號"
        }
        alert.addAction(confirm)
        self.present(alert, animated: true)
    }

    private func parseUnencryptedPDF(_ pdf: PDFDocument) {
        // expected only one page
        guard
            let firstPage = pdf.page(at: 0),
            let pdfText = firstPage.string
        else {
            return
        }
        let alert = UIAlertController(
            title: "戶政國民身分證資料",
            message: pdfText,
            preferredStyle: .alert)
        let confirm = UIAlertAction(title: "確認", style: .default)
        alert.addAction(confirm)
        self.present(alert, animated: true)
    }
}
