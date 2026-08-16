//
//  CapabilityRenderScratch.swift
//  backupTWTests
//
//  Scratch: renders the capability screen so it can be looked at.
//  Not a product test — delete after the review.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@MainActor
struct CapabilityRenderScratch {

    private static let outputDirectory = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-mashbean-Developer/5aa5c792-8047-4b33-86a4-2be22684042e/scratchpad/capability-shots",
        isDirectory: true)

    /// Disabled by default: it writes five PNGs and adds a second to every run.
    ///
    /// Kept rather than deleted because the review it supports is not a one-off
    /// — the next change to this screen needs the same loop, and reconstructing
    /// it costs more than the line below. Enable by removing `.disabled`.
    @Test(.disabled("visual review; enable when changing the capability screen"))
    func renderCapabilityScreen() {
        let controller = CapabilityViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        controller.loadViewIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()

        try? FileManager.default.createDirectory(at: Self.outputDirectory,
                                                 withIntermediateDirectories: true)

        // The screen is far taller than the window, so it is paged: resizing the
        // window renders blank (learned the hard way), and a single capture of a
        // scroll view only shows the first screenful.
        guard let scrollView = controller.view.subviews.compactMap({ $0 as? UIScrollView }).first else {
            Issue.record("no scroll view on the capability screen")
            return
        }
        let total = scrollView.contentSize.height
        let page = window.bounds.height
        var offset: CGFloat = 0
        var index = 0
        while offset < total, index < 12 {
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

        // The text, which is what actually matters here.
        var lines: [String] = []
        func walk(_ view: UIView, depth: Int) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                lines.append(String(repeating: "  ", count: depth)
                             + "[\(Int(label.font.pointSize))pt] " + text)
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(window, depth: 0)
        print("=== capability screen: \(Int(total))pt tall, \(index) pages ===")
        print(lines.joined(separator: "\n"))
    }
}
