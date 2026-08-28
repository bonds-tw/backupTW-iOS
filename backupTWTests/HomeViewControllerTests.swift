//
//  HomeViewControllerTests.swift
//  backupTWTests
//
//  The home screen builds its card groups without tripping the duplicate-identity
//  trap a diffable data source terminates on.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

@MainActor
struct HomeViewControllerTests {

    /// Loading the view runs the whole snapshot build — three sections, the
    /// invite-to-create ID card, the empty-government CTA, and the MyData vault —
    /// against whatever the real (fresh) store holds. It must open, not trap:
    /// every card carries a unique identifier, which is the property this covers.
    @Test func theHomeScreenLoadsWithoutTrappingOnIdentities() {
        let controller = HomeViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        controller.loadViewIfNeeded()
        // A second appearance re-applies the snapshot; a diff against the first is
        // exactly where a duplicated identity would surface.
        controller.viewWillAppear(false)
        controller.viewWillAppear(false)
        #expect(controller.view != nil)
    }
}
