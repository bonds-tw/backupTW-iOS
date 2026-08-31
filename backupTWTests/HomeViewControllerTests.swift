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

    private func tempVault() throws -> MyDataVaultArchive {
        try MyDataVaultArchive(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeVaultTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func source(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func tempOfficialDocumentInbox() throws -> OfficialDocumentInboxArchive {
        try OfficialDocumentInboxArchive(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeOfficialDocumentTests-\(UUID().uuidString)",
                                    isDirectory: true))
    }

    private func mountedHome(store: CredentialStoring,
                             archive: MyDataVaultArchive,
                             officialDocuments: OfficialDocumentInboxArchive? = nil)
        -> (HomeViewController, UINavigationController, UIWindow) {
        let officialDocuments = officialDocuments ?? (try? tempOfficialDocumentInbox())
        let controller = HomeViewController(
            makeStore: { store },
            makeVaultArchive: { archive },
            makeOfficialDocumentInbox: { officialDocuments })
        let navigation = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        window.layoutIfNeeded()
        return (controller, navigation, window)
    }

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

    // MARK: - Which cards may be deleted

    /// A dictionary-backed stand-in, so the eligibility rule can be tested against
    /// a known stored card without touching the host's real Application Support.
    private final class MemoryStore: CredentialStoring, @unchecked Sendable {
        private var items: [String: String] = [:]
        func save(jws: String, id: String) throws { items[id] = jws }
        func load(id: String) throws -> String? { items[id] }
        func allIDs() throws -> [String] { Array(items.keys).sorted() }
        func delete(id: String) throws { items.removeValue(forKey: id) }
        func deleteAll() throws { items.removeAll() }
    }

    @Test func anArchivedMyDataOriginalAppearsAndOpensItsOwnDetail() throws {
        let store = MemoryStore()
        let archive = try tempVault()
        try archive.store(originalAt: try source("income"),
                          id: "mydata-income", fileExtension: "pdf")
        let (controller, navigation, _) = mountedHome(store: store, archive: archive)

        // National ID / government / MyData. The first MyData item is the stored
        // original; the second is the import-another control.
        #expect(controller.collectionView.numberOfItems(inSection: 2) == 2)
        controller.collectionView(controller.collectionView,
                                  didSelectItemAt: IndexPath(item: 0, section: 2))
        #expect(navigation.topViewController is MyDataVaultDocumentViewController)
        #expect(!(navigation.topViewController is StoredCredentialViewController))
    }

    @Test func theEmptyVaultOpensTheDocumentPickerNotNationalIDOnboarding() throws {
        let store = MemoryStore()
        let archive = try tempVault()
        let (controller, _, _) = mountedHome(store: store, archive: archive)

        controller.collectionView(controller.collectionView,
                                  didSelectItemAt: IndexPath(item: 0, section: 2))

        #expect(controller.presentedViewController is UIAlertController)
        #expect(!(controller.presentedViewController is UINavigationController))
    }

    @Test func officialDocumentsAreASeparateSectionBelowTheMyDataVault() throws {
        let store = MemoryStore()
        let archive = try tempVault()
        let inbox = try tempOfficialDocumentInbox()
        let (controller, navigation, _) = mountedHome(
            store: store, archive: archive, officialDocuments: inbox)

        #expect(controller.collectionView.numberOfSections == 4)
        #expect(controller.collectionView.numberOfItems(inSection: 3) == 1)
        controller.collectionView(controller.collectionView,
                                  didSelectItemAt: IndexPath(item: 0, section: 3))
        #expect(navigation.topViewController is OfficialDocumentInboxViewController)
    }

    /// The 「刪除卡片」 menu is offered on a face that stands for a stored file and
    /// withheld on the synthetic faces — the rule `deletableCard(forCardID:in:)`
    /// encodes and the context-menu delegate reads.
    ///
    /// `cardRows` is built exactly as `HomeViewController.buildContent` builds it,
    /// so this exercises the same map the running screen keys on.
    @Test func onlyStoredCardsAreDeletable() throws {
        let store = MemoryStore()
        // A stored credential under a real id. Its bytes need not parse: a
        // listed-but-unreadable card is still a real stored file, and still one a
        // holder must be able to remove — so this is the case, not a shortcut past it.
        try store.save(jws: "not-a-parseable-credential", id: "gov-card-1")
        let rows = CardInventory.rows(from: store)
        let cardRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // The stored card: a menu, and it targets that exact row.
        #expect(HomeViewController.deletableCard(forCardID: "gov-card-1", in: cardRows)?.id == "gov-card-1")

        // The synthetic faces: no menu. None of these ids is a key in `cardRows`,
        // because none of them is a stored file — deleting one would have nothing
        // to remove, and must never reach the store.
        #expect(HomeViewController.deletableCard(
            forCardID: HomeViewController.CardID.vault, in: cardRows) == nil)
        #expect(HomeViewController.deletableCard(
            forCardID: HomeViewController.CardID.nationalIDPlaceholder, in: cardRows) == nil)
        #expect(HomeViewController.deletableCard(
            forCardID: HomeViewController.CardID.unreadableStore(in: "government"), in: cardRows) == nil)
        #expect(HomeViewController.deletableCard(
            forCardID: HomeViewController.CardID.unreadableStore(in: "national-id"), in: cardRows) == nil)
    }
}
