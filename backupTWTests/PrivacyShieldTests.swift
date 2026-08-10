//
//  PrivacyShieldTests.swift
//  backupTWTests
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// The app-switcher snapshot, which is the one leak in this app that nobody can
/// see happening.
///
/// Everything else here fails loudly: a wrong signature is refused on screen, a
/// stale request is a warning a person reads. This one writes a third party's
/// name, ID number and household address into `Library/SplashBoard/Snapshots` on
/// somebody else's phone, silently, and the app looks identical whether the
/// defence is working or not. So it gets tests at both ends — that the screens
/// declare themselves, and that a declared screen is actually painted over — and
/// one that renders the window the way the system does and looks at the pixels.
@MainActor
struct PrivacyShieldTests {

    // MARK: - The screens declare themselves

    /// The defect, stated as a test. Before the fix neither screen conformed to
    /// anything, `sceneWillResignActive` was empty, and a checker's phone kept a
    /// readable picture of somebody else's national ID until the card was swiped
    /// away.
    @Test func theScreensThatShowIdentityDataDeclareThemselvesShielded() {
        let result: UIViewController = VerificationResultViewController(outcome: .verified(Self.presentation()))
        let holder: UIViewController = PresentCredentialViewController(holder: HolderPresentation(store: StubStore()))
        let scanner: UIViewController = QRScanningViewController(title: "t", prompt: "p") { _ in .stop }

        for screen in [result, holder, scanner] {
            let shielded = screen as? PrivacyShieldedScreen
            #expect(shielded != nil, "\(type(of: screen)) does not declare itself shielded")
            #expect(shielded?.needsPrivacyShield == true)
        }
    }

    /// The scaffolding this file leans on is real: a screen may say no, and the
    /// shield has to believe it. Without this test, `needsPrivacyShield` could be
    /// ignored entirely and every other test here would still pass.
    @Test func aScreenThatSaysItIsNotSensitiveIsNotCovered() throws {
        let window = Self.window(showing: OptionalScreen(needsPrivacyShield: false))
        try #require(window.rootViewController?.viewIfLoaded?.window != nil,
                     "the root view is not in the window, so this test proves nothing")

        #expect(!PrivacyShield.hasShieldedContent(in: window))

        let shield = PrivacyShield()
        shield.coverIfNeeded(window)
        #expect(!shield.isCovering)
    }

    @Test func anOrdinaryScreenIsNotCovered() throws {
        let window = Self.window(showing: UIViewController())
        try #require(window.rootViewController?.viewIfLoaded?.window != nil)

        #expect(!PrivacyShield.hasShieldedContent(in: window))
    }

    // MARK: - Finding it

    /// The real hierarchy: tab bar, navigation controller, result screen on top.
    /// A shield that only looked at `window.rootViewController` would find a
    /// `UITabBarController` and conclude there was nothing to hide.
    @Test func findsAShieldedScreenInsideTheAppsOwnContainers() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let tabs = UITabBarController()
        tabs.viewControllers = [navigation]
        let window = Self.window(showing: tabs)

        #expect(!PrivacyShield.hasShieldedContent(in: window))

        navigation.pushViewController(VerificationResultViewController(outcome: .verified(Self.presentation())),
                                      animated: false)
        window.layoutIfNeeded()

        #expect(PrivacyShield.hasShieldedContent(in: window))
    }

    /// A shielded screen that was built but never put on screen is not in the
    /// picture, so it is not a reason to cover. The opposite behaviour would be
    /// safe but useless: every window would be covered forever once one of these
    /// had been allocated.
    @Test func aShieldedScreenThatIsNotOnScreenIsNotAReasonToCover() throws {
        let window = Self.window(showing: UIViewController())
        let unattached = VerificationResultViewController(outcome: .verified(Self.presentation()))
        unattached.loadViewIfNeeded()

        #expect(!PrivacyShield.hasShieldedContent(in: window))
    }

    // MARK: - Covering

    @Test func coversTheWholeWindowAndUncoversItAgain() throws {
        let window = Self.window(showing: VerificationResultViewController(outcome: .verified(Self.presentation())))
        try #require(window.rootViewController?.viewIfLoaded?.window != nil)
        let shield = PrivacyShield()

        shield.coverIfNeeded(window)
        #expect(shield.isCovering)
        let cover = try #require(window.subviews.last)
        // Topmost, full-bounds and opaque are the three properties that make the
        // system's picture safe. Any one of them missing and the snapshot still
        // has the data in it.
        #expect(cover.frame == window.bounds)
        #expect(cover.backgroundColor?.cgColor.alpha == 1)

        shield.uncover()
        #expect(!shield.isCovering)
        #expect(!window.subviews.contains(cover))
    }

    /// `sceneWillResignActive` can fire twice without an intervening
    /// `sceneDidBecomeActive` — a Control Centre pull during a phone call. Two
    /// covers would mean `uncover()` leaves one behind, and the app comes back to
    /// a permanently blank screen.
    @Test func coveringTwiceLeavesOneCoverAndUncoveringOnceRemovesIt() throws {
        let window = Self.window(showing: VerificationResultViewController(outcome: .verified(Self.presentation())))
        try #require(window.rootViewController?.viewIfLoaded?.window != nil)
        let before = window.subviews.count
        let shield = PrivacyShield()

        shield.coverIfNeeded(window)
        shield.coverIfNeeded(window)
        #expect(window.subviews.count == before + 1)

        shield.uncover()
        #expect(window.subviews.count == before)
    }

    @Test func uncoveringWithoutHavingCoveredDoesNothing() {
        let shield = PrivacyShield()
        shield.uncover()
        #expect(!shield.isCovering)
    }

    // MARK: - What the system would actually photograph

    /// The end-to-end statement, made against pixels rather than against view
    /// objects: render the window the way `UIScene`'s snapshot does, and the row
    /// that had somebody's ID number on it is a flat rectangle afterwards.
    ///
    /// Every other test here would still pass if the cover were transparent, or
    /// were inserted below the content, or drew nothing.
    @Test func theIDNumberIsNotInTheRenderedWindowOnceCovered() throws {
        let window = Self.window(showing: VerificationResultViewController(outcome: .verified(Self.presentation())))
        try #require(window.rootViewController?.viewIfLoaded?.window != nil)

        let label = try #require(Self.label(withText: Self.unifiedNo, in: window),
                                 "the result screen is not showing the ID number, so this test proves nothing")
        let row = Int(label.convert(label.bounds, to: window).midY.rounded())

        let exposed = try #require(Self.pixelRow(row, of: Self.render(window)))
        #expect(Set(exposed).count > 1, "nothing was drawn on the row the ID number is on")

        PrivacyShield().coverIfNeeded(window)

        let covered = try #require(Self.pixelRow(row, of: Self.render(window)))
        #expect(Set(covered).count == 1,
                "the row the ID number was on is still not uniform, so something is showing through")
        #expect(covered != exposed)
    }

    // MARK: - Fixtures

    private static let unifiedNo = "A123456789"

    private static func presentation() -> VerifiedPresentation {
        VerifiedPresentation(holder: "did:key:zDnaerDaTF5BXEavCrfRZEk316dpbLsfPDZ3WJ5hRTPFU2169",
                             cardholderName: nil,
                             cardholderNameWasChecked: false,
                             withheldClaimCount: 0,
                             credentialTypes: ["VerifiableCredential", "NationalIDCredential"],
                             claims: [DisclosedClaim(term: "name", value: "王小明"),
                                      DisclosedClaim(term: "unifiedNo", value: unifiedNo),
                                      DisclosedClaim(term: "birthdate", value: "1980-01-01"),
                                      DisclosedClaim(term: "addressOfHousehold", value: "臺北市中正區徐州路 5 號")],
                             validFrom: Date(timeIntervalSince1970: 1_754_400_000),
                             validUntil: nil,
                             presentedAt: Date(timeIntervalSince1970: 1_754_400_000),
                             caveats: [.noNetworkQuery])
    }

    /// A screen that adopts the protocol and then declines. Exists only so the
    /// `needsPrivacyShield` branch has something to exercise it.
    private final class OptionalScreen: UIViewController, PrivacyShieldedScreen {
        let needsPrivacyShield: Bool
        init(needsPrivacyShield: Bool) {
            self.needsPrivacyShield = needsPrivacyShield
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
    }

    private struct StubStore: CredentialStoring {
        func save(jws: String, id: String) throws {}
        func load(id: String) throws -> String? { nil }
        func allIDs() throws -> [String] { ["urn:test:credential"] }
        func deleteAll() throws {}
    }

    private static func window(showing root: UIViewController) -> UIWindow {
        // A plain iPhone-shaped window rather than the host app's: these tests
        // must not depend on which device the runner picked, and must not disturb
        // the app they are hosted in.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private static func label(withText text: String, in root: UIView) -> UILabel? {
        if let label = root as? UILabel, label.text == text { return label }
        for subview in root.subviews {
            if let found = Self.label(withText: text, in: subview) { return found }
        }
        return nil
    }

    /// What the system's snapshot machinery does: draw the window's layer into a
    /// bitmap. Scale 1 so a point is a pixel and a row index means what it says.
    private static func render(_ window: UIWindow) -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
    }

    /// One horizontal row of the rendered window, as packed RGBA.
    ///
    /// The backing store is allocated rather than borrowed from a Swift `Array`:
    /// a `CGContext` built over an array's buffer outlives the
    /// `withUnsafeMutableBytes` call that produced the pointer, which is the kind
    /// of test-only undefined behaviour that shows up as an unrelated flake.
    private static func pixelRow(_ y: Int, of image: UIImage) -> [UInt32]? {
        guard let cgImage = image.cgImage, y >= 0, y < cgImage.height else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let storage = calloc(width * height, 4) else { return nil }
        defer { free(storage) }
        guard let context = CGContext(data: storage,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = storage.assumingMemoryBound(to: UInt32.self)
        return (0 ..< width).map { pixels[y * width + $0] }
    }
}
