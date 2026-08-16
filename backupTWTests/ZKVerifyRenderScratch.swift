//
//  ZKVerifyRenderScratch.swift
//  backupTWTests
//
//  Scratch: renders the ZK result screen so the caveat ordering can be seen.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@MainActor
struct ZKVerifyRenderScratch {

    private static let outputDirectory = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-mashbean-Developer/5aa5c792-8047-4b33-86a4-2be22684042e/scratchpad/zkverify-shots",
        isDirectory: true)

    /// Disabled by default. Enable when changing this screen's layout — b-2 and
    /// b-5 were both "the text is all present and in the wrong place", which is
    /// a class of defect no assertion in this suite would have caught.
    @Test(.disabled("visual review; enable when changing the ZK result screen"))
    func renderVerdictWithCaveats() throws {
        let controller = ZKVerifyViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()

        // Drive it to the state that matters: a verdict plus the full caveat
        // set. The waiting state is not the one that was broken.
        controller.showForReview(
            status: "這支手機查驗過了，通過",
            detail: "憑證鏈：通過\n簽章：通過\n兩段證明互相扣住：通過\n耗時 8.4 秒 · 389 KB",
            caveats: ProofCaveat.allCases.map(\.localizedDescription),
            verdict: true)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        try? FileManager.default.createDirectory(at: Self.outputDirectory,
                                                 withIntermediateDirectories: true)

        guard let scrollView = controller.view.subviews.compactMap({ $0 as? UIScrollView }).first else {
            Issue.record("no scroll view")
            return
        }
        let total = scrollView.contentSize.height
        let page = window.bounds.height
        var offset: CGFloat = 0
        var index = 0
        while offset < total, index < 10 {
            scrollView.contentOffset = CGPoint(x: 0, y: offset)
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: format)
            let image = renderer.image { context in window.layer.render(in: context.cgContext) }
            if let data = image.pngData() {
                try? data.write(to: Self.outputDirectory
                    .appendingPathComponent(String(format: "page-%02d.png", index)))
            }
            offset += page
            index += 1
        }

        // Where each label sits, which is the whole question: the verdict and
        // the caveats have to be above the fold, not below a dead QR code.
        var lines: [String] = []
        func walk(_ view: UIView) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                let top = Int(label.convert(label.bounds, to: window).minY)
                lines.append("y=\(top)  [\(Int(label.font.pointSize))pt] \(text.prefix(70))")
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        print("=== ZK verify: \(Int(total))pt tall, \(index) pages, window height \(Int(page)) ===")
        print(lines.joined(separator: "\n"))
    }
}
