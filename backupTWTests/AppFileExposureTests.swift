//
//  AppFileExposureTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// Asserts on the shipped `Info.plist`, because whether the app's files are
/// visible to the outside world is decided there and nowhere in Swift.
///
/// These read `Bundle.main`, which under a hosted test bundle is the app itself.
struct AppFileExposureTests {

    /// `UISupportsDocumentBrowser` published the app's Documents directory to the
    /// Files app: "我的 iPhone → Bond", where anything inside could be opened,
    /// copied or AirDropped by whoever was holding the unlocked phone. For the
    /// years this app was downloading household-registration PDFs into that
    /// directory, that was the whole household record, one long-press from
    /// leaving the device.
    ///
    /// Nothing in the app ever used the browser: no `UIDocument`, no document
    /// picker, no exported document types. The key was the Xcode template's.
    @Test func theAppDoesNotPublishItsFilesToTheFilesApp() throws {
        let info = try #require(Bundle.main.infoDictionary)
        // Anchor first: if this is not the app's own Info.plist then the
        // assertions below would pass by reading the wrong bundle.
        #expect(info["CFBundleDisplayName"] as? String == "Bond")

        #expect(!info.keys.contains("UISupportsDocumentBrowser"))
        // The other two routes to the same exposure, so that closing one door
        // does not just move the problem next to it.
        #expect(!info.keys.contains("UIFileSharingEnabled"))
        #expect(!info.keys.contains("LSSupportsOpeningDocumentsInPlace"))
    }

    /// The two entries that do earn their place: querying whether 行動自然人憑證
    /// is installed, and the scheme it calls back on. Removing the document
    /// browser key must not take these with it — the MyData flow is dead without
    /// them, and a plist edit is easy to over-apply.
    @Test func theURLSchemesTheMyDataFlowDependsOnAreStillDeclared() throws {
        let info = try #require(Bundle.main.infoDictionary)

        #expect(info["LSApplicationQueriesSchemes"] as? [String] == ["mobilemoica"])

        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try #require(urlTypes.first?["CFBundleURLSchemes"] as? [String])
        #expect(schemes == ["backuptw"])
    }

    /// The plist and the router hold the same scheme in two places, and nothing
    /// in the toolchain relates them. If they drift, the system still launches
    /// the app on the callback and the router silently declines every URL — the
    /// exact symptom of not having written the router at all.
    @Test func theRegisteredSchemeIsTheOneTheRouterListensFor() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try #require(urlTypes.first?["CFBundleURLSchemes"] as? [String])
        #expect(schemes.contains(MOICACallbackRouter.scheme))
    }
}
