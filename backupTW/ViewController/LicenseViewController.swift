//
//  LicenseViewController.swift
//  backupTW
//
//  Created by Denken Chen on 2025/8/12.
//

import UIKit

class LicenseViewController: UIViewController {

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Without a title the navigation bar over the licence text was blank,
        // and so was the next screen's back button.
        title = NSLocalizedString("License", comment: "")
    }

    override func loadView() {
        view = textView
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        textView.alwaysBounceVertical = true
        textView.isEditable = false
        // Tappable links (repos), selectable text, otherwise read-only.
        textView.isSelectable = true
        textView.dataDetectorTypes = [.link]
        let mit = { (holder: String) in """
            The MIT License (MIT)

            \(holder)

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """ }

        textView.text = """
            有備而來 (Bonds)
            https://github.com/mashbean/backupTW-iOS

            這個 App 使用下列開源元件，謹此致謝：

            ————————————————————————————

            openac-rsa-x509-swift
            https://github.com/privacy-ethereum/openac-rsa-x509-swift
            (雙授權 MIT / Apache-2.0,此處採 MIT)

            \(mit("Copyright (c) 2026 Ethereum Foundation"))

            ————————————————————————————

            Zip
            https://github.com/marmelroy/Zip

            \(mit("Copyright (c) 2015 Roy Marmelstein"))
            """
    }
}
