//
//  SceneDelegate.swift
//  backupTW
//
//  Created by Denken Chen on 2025/5/30.
//

import UIKit

// MARK: - Screens the system must not photograph

/// A screen whose contents must not be left in the app switcher.
///
/// # The leak
///
/// iOS photographs every scene on the way out of the foreground — Home gesture,
/// app switcher, an incoming call — and writes the image under
/// `Library/SplashBoard/Snapshots`, where it stays until the app is relaunched or
/// the card is swiped away. For most apps that is a nicety. Here the pictures are
/// a third person's name, ID number, date of birth and household address sitting
/// on the *checker's* phone, and the holder's entire signed credential drawn as a
/// QR code — a snapshot of which is not a picture of the credential, it is the
/// credential, readable straight back out of the image by any scanner.
///
/// So 「查驗完不留任何東西」 — the promise the whole offline design exists to keep,
/// and the reason `OfflineVerifier` will not open a socket — was false on disk.
/// A's identity data ended up in B's filesystem, and anybody who picked up B's
/// unlocked phone and opened the app switcher could read it. This project already
/// names a screenshot as a leak channel, in `OfflineVerifier` and in
/// `MyDataOnboardViewController`, and had applied the lesson only to error
/// strings. It is the same channel; the difference is that the system takes this
/// one whether anybody asked for it or not.
///
/// # Why a protocol and not a list of classes
///
/// A list in the scene delegate is a list the next screen does not get added to,
/// and it moves the judgement — "is there identity data on this screen?" — as far
/// as possible from the code that knows the answer. A screen declares its own
/// risk; `PrivacyShield` never names a view controller type.
@MainActor
protocol PrivacyShieldedScreen: AnyObject {

    /// `true` while this screen has something on it that must not reach a
    /// snapshot.
    ///
    /// Defaults to `true`: adopting the protocol is already the declaration, and
    /// a screen that has to opt in twice is a screen somebody forgets to finish.
    /// Overridable for a screen whose stages genuinely differ — but override it
    /// downwards only where the safe stage is certain, because the cost of
    /// covering a harmless screen is a grey rectangle in the app switcher, and
    /// the cost of the other mistake is somebody's household address on a
    /// stranger's disk.
    var needsPrivacyShield: Bool { get }
}

extension PrivacyShieldedScreen {
    var needsPrivacyShield: Bool { true }
}

// MARK: - Which screens are shielded

// ⚠️ Each of these belongs in the file that owns the screen, next to the code
// that draws the sensitive thing — that is the point of the protocol, and a
// conformance beside the drawing is one a person editing the drawing will see.
// They are gathered here because the change that introduced the shield was
// scoped to this file and could not edit theirs. Moving them is a three-line
// commit and should be the first one after this.

/// Draws every field the holder disclosed: name, ID number, date of birth,
/// household address. The worst thing in this app to leave in a snapshot, because
/// it is the one screen whose contents belong to somebody who is not holding the
/// phone and will never know the picture was taken.
extension VerificationResultViewController: PrivacyShieldedScreen {}

/// Draws the holder's whole signed credential as a QR code.
///
/// Shielded in every stage rather than only while the codes are up. The stages
/// that carry nothing are a button and two sentences, so covering them costs
/// nothing, and a condition here would have to be re-derived correctly every time
/// the stage machine changes — by somebody editing a different file.
extension PresentCredentialViewController: PrivacyShieldedScreen {}

/// The camera preview freezes on its last frame when the capture session is
/// interrupted, and on the checker's side that last frame is the holder's
/// document code filling the viewfinder. Not named in the report this fix came
/// from; it is the same defect, one screen over.
extension QRScanningViewController: PrivacyShieldedScreen {}

/// Draws 國籍／統一編號／姓名／出生日期／戶籍地址 and then, in the same flow,
/// hands the person to 行動自然人憑證 — which is precisely the moment iOS takes
/// its app-switcher snapshot. Five identity fields, bare, into the screenshot
/// the system keeps.
extension MyDataOnboardViewController: PrivacyShieldedScreen {}

/// The other one. Its own comment said 「app-switcher snapshot is already
/// handled by `PrivacyShield`」 — a statement about itself that was false,
/// because it was not on this list.
extension StoredCredentialViewController: PrivacyShieldedScreen {}

/// Draws a government card's disclosed fields — a name, a national ID number, a
/// date of birth. The same over-the-shoulder surface as the holder's own ID
/// screen, so it gets the same shield: the fields are revealed on request, but
/// once revealed they must not be left in the app-switcher snapshot either. On
/// the list from the moment the screen exists, not the moment the fields are
/// shown — a condition here would have to be re-derived every time the reveal
/// logic changes, by somebody editing a different file.
extension GovernmentCardViewController: PrivacyShieldedScreen {}

// MARK: - The shield

/// Covers the window while the app is not in front, if anything on it said it
/// needed covering.
///
/// A type rather than four lines in the delegate, so that both halves — deciding,
/// and covering — can be driven by a test. Neither is observable once shipped:
/// the snapshot is written into a container no debugger shows and read back by an
/// app switcher nobody inspects, so a shield that silently stopped working looks
/// exactly like one that works.
@MainActor
final class PrivacyShield {

    /// The view currently over the window, if any. Held rather than found again
    /// by tag: a tag is a number two features can pick, and this view must be
    /// removed exactly and only by whoever installed it.
    private var coverView: UIView?

    var isCovering: Bool { coverView != nil }

    init() {}

    /// Installs the cover if the window is showing something shielded.
    ///
    /// Call from `sceneWillResignActive`, the last callback that runs *before*
    /// the system takes its picture. `sceneDidEnterBackground` is too late — by
    /// then the photograph exists — and that ordering is the whole reason this is
    /// not in the more obvious place.
    func coverIfNeeded(_ window: UIWindow?) {
        guard let window, coverView == nil, Self.hasShieldedContent(in: window) else { return }
        let cover = Self.makeCover(for: window)
        window.addSubview(cover)
        // Laid out synchronously. The cover has one frame in which to exist — the
        // one the system captures — and a subview added without a layout pass is
        // a subview that has not been drawn yet.
        window.layoutIfNeeded()
        coverView = cover
    }

    /// Call from `sceneDidBecomeActive` rather than `sceneWillEnterForeground`:
    /// the app switcher shows the live view during the return animation, so
    /// uncovering at the earlier callback would put the data back on screen while
    /// the card is still on the switcher.
    func uncover() {
        coverView?.removeFromSuperview()
        coverView = nil
    }

    /// Whether any screen currently in `window` declared itself shielded.
    ///
    /// Asks UIKit what is actually attached to the window instead of walking
    /// `topViewController` / `selectedViewController` per container class. Two
    /// reasons, both about being wrong in the safe direction: a screen inside a
    /// container this file has never heard of is still found, and during a push or
    /// an interactive pop *both* views are attached — which is exactly the moment
    /// the hand brushing the left edge of the screen is also the hand reaching for
    /// the Home gesture.
    ///
    /// A view controller that exists but is not on screen — the one underneath in
    /// a navigation stack, whose view UIKit has already detached — correctly does
    /// not count. It is not in the picture, so covering for it would be covering
    /// for nothing.
    static func hasShieldedContent(in window: UIWindow) -> Bool {
        var pending: [UIViewController] = [window.rootViewController].compactMap { $0 }
        while let controller = pending.popLast() {
            if let screen = controller as? PrivacyShieldedScreen,
               screen.needsPrivacyShield,
               controller.viewIfLoaded?.window != nil {
                return true
            }
            pending.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController {
                pending.append(presented)
            }
        }
        return false
    }

    /// Opaque, not a blur.
    ///
    /// A blurred screenshot is still a screenshot: this is a still image on disk
    /// that somebody can sharpen at leisure, and the length and shape of a name or
    /// an ID number survive most blurs. There is nothing to gain by leaving the
    /// data visible-but-pretty, so the cover says what it is instead — which also
    /// makes a shield that fired look deliberate rather than like a crash.
    private static func makeCover(for window: UIWindow) -> UIView {
        let cover = UIView(frame: window.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .systemBackground

        let symbol = UIImageView(image: UIImage(systemName: "eye.slash.fill"))
        symbol.tintColor = .secondaryLabel
        symbol.contentMode = .scaleAspectFit

        let title = UILabel()
        title.text = NSLocalizedString("Hidden while this app is not in front",
                                       comment: "App switcher privacy cover")
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0

        let detail = UILabel()
        detail.text = NSLocalizedString("So the details on this screen are not left behind in the app switcher.",
                                        comment: "App switcher privacy cover")
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [symbol, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(stack)
        NSLayoutConstraint.activate([
            symbol.heightAnchor.constraint(equalToConstant: 32),
            stack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: cover.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cover.trailingAnchor, constant: -32),
        ])
        return cover
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    private let privacyShield = PrivacyShield()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let window = UIWindow(windowScene: windowScene)

        // Creating the tab bar. Two tabs: 「首頁」 (what you hold) and 「使用」
        // (what you can do). Settings is no longer a tab — it moved to a gear in
        // the top-right of both, presented modally, so the tab bar carries only
        // the two halves of the wallet's day-to-day and the actions have a home of
        // their own rather than trailing the cards on the first screen.
        let tabBarController = UITabBarController()
        let homeViewController = HomeViewController()
        let useViewController = UseViewController()
        // Set here, not in `UseViewController.viewDidLoad`, for the same reason
        // the old Settings tab was: a `tabBarItem` set in `viewDidLoad` does not
        // appear until that tab is first selected, because a non-selected tab's
        // view is not loaded yet. The first tab (Home) gets away with setting its
        // own in `viewDidLoad` only because it loads at launch. `qrcode.viewfinder`
        // reads as a document shown as a scannable code — what this tab is for.
        useViewController.tabBarItem = UITabBarItem(
            title: NSLocalizedString("Use", comment: ""),
            image: UIImage(systemName: "qrcode.viewfinder"),
            selectedImage: nil)
        tabBarController.viewControllers = [
            UINavigationController(rootViewController: homeViewController),
            UINavigationController(rootViewController: useViewController)
        ]

        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        self.window = window
    }

    /// The `backuptw://` return leg of the TW FidO App-to-App flow, and the
    /// `openid-credential-offer://` entry of the TWDIW collection flow.
    ///
    /// Without this the registered schemes still launch the app and then do
    /// nothing, which is indistinguishable from the deep link never firing.
    /// Inbound URLs are untrusted — any app can open our schemes — so the
    /// FidO router only uses them to shorten a wait it already started, and
    /// the credential offer goes through `IssuerAuthorization`'s gates before
    /// a single request leaves the device.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            let url = context.url
            if let link = try? CredentialOfferLink.parse(url) {
                collectCredential(from: link)
                continue
            }
            Task { await MOICACallbackRouter.shared.handle(url) }
        }
    }

    /// Runs one collection from a deep link and tells the user how it ended.
    ///
    /// The sequence itself lives in `CredentialCollection`, shared with the
    /// in-app scan entry point so the two cannot drift; this method only owns
    /// where the resulting alert is presented from a scene launch.
    private func collectCredential(from link: CredentialOfferLink) {
        Task { @MainActor in
            let outcome = await CredentialCollection.run(from: link)
            let alert = UIAlertController(
                title: NSLocalizedString("Digital wallet card collection", comment: ""),
                message: outcome,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""),
                                          style: .default))
            var presenter = window?.rootViewController
            while let presented = presenter?.presentedViewController { presenter = presented }
            presenter?.present(alert, animated: true)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        privacyShield.uncover()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Also fires for a transient interruption — an incoming call, Control
        // Centre pulled down — and covering for those too is the right trade:
        // `sceneDidBecomeActive` puts the screen back within the same
        // interaction, and this callback cannot tell an interruption from the
        // Home gesture that ends with a snapshot on disk.
        privacyShield.coverIfNeeded(window)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Save data, release shared resources, and store enough scene-specific
        // state to restore the scene later. The privacy cover is deliberately
        // *not* installed here: the system has already taken its snapshot by the
        // time this runs. See `PrivacyShield.coverIfNeeded`.
    }
}
