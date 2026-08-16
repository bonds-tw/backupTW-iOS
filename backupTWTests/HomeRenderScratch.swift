//
//  HomeRenderScratch.swift
//  backupTWTests
//
//  Scratch: renders the home screen with cards in the store so it can be
//  looked at. Not a product test.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@MainActor
struct HomeRenderScratch {

    private static let outputDirectory = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-mashbean-Developer/5aa5c792-8047-4b33-86a4-2be22684042e/scratchpad/home-shots",
        isDirectory: true)

    /// Disabled by default, and for a second reason beyond the one on
    /// `CapabilityRenderScratch`: this one **writes into the real credential
    /// store** and empties it afterwards. That is harmless in a simulator whose
    /// store starts empty, and it is exactly what you do not want running by
    /// surprise. `HomeViewController` builds its own `CredentialStore()`, so
    /// there is nothing to inject — seeing the real screen means seeding the
    /// real store.
    @Test(.disabled("visual review; enable when changing the home screen"))
    func renderHomeScreen() throws {
        let store = try CredentialStore()
        defer { try? store.deleteAll() }

        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "00000000_demo_drivinglicense_202504251418")
        try store.save(jws: "not a credential at all", id: "zz-damaged")

        let controller = HomeViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()

        try? FileManager.default.createDirectory(at: Self.outputDirectory,
                                                 withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: format)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        if let data = image.pngData() {
            try? data.write(to: Self.outputDirectory.appendingPathComponent("home.png"))
        }

        var lines: [String] = []
        func walk(_ view: UIView, depth: Int) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                lines.append(String(repeating: "  ", count: depth)
                             + "[\(Int(label.font.pointSize))pt] " + text)
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(window, depth: 0)
        print("=== home screen ===")
        print(lines.joined(separator: "\n"))
    }
}
