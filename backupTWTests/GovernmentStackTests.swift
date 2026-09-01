//
//  GovernmentStackTests.swift
//  backupTWTests
//
//  Phase 2c 疊卡. Drives the home screen against an in-memory store (injected, so
//  the device store is never touched) and reads the collection view's layout
//  attributes to assert the collapsed stack (full cards overlapping, hero tucked at
//  the bottom), the tap→expand toggle, and — the two review fixes — that the resting
//  state resets when the group drops below two cards.
//

import Foundation
import Testing
import UIKit
@testable import backupTW

/// A minimal in-memory `CredentialStoring`, so the home screen can be seeded with
/// government cards without writing the real on-disk store (which would race the
/// other tests that build `HomeViewController()` on the default location).
private final class SeededStore: CredentialStoring, @unchecked Sendable {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { items.keys.sorted() }
    func delete(id: String) throws { items.removeValue(forKey: id) }
    func deleteAll() throws { items.removeAll() }
}

@MainActor
struct GovernmentStackTests {

    /// Government is section 1 (national ID / government / MyData).
    private static let governmentSection = 1

    private func fill(_ store: SeededStore, count: Int) throws {
        try store.deleteAll()
        for i in 0..<count {
            try store.save(jws: TWDIWFixture().serialized,
                           id: "0000000\(i)_demo_drivinglicense_20250425")
        }
    }

    private func seeded(_ count: Int) throws -> SeededStore {
        let store = SeededStore()
        try fill(store, count: count)
        return store
    }

    private func home(_ store: SeededStore) -> (HomeViewController, UIWindow) {
        let controller = HomeViewController(makeStore: { store })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func frame(_ controller: HomeViewController, item: Int) throws -> CGRect {
        try #require(controller.collectionView.layoutAttributesForItem(
            at: IndexPath(item: item, section: Self.governmentSection))?.frame)
    }

    private func myDataHome(count: Int) throws -> (HomeViewController, UIWindow) {
        let store = SeededStore()
        let archive = try MyDataVaultArchive(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDataStackTests-\(UUID().uuidString)", isDirectory: true))
        for index in 0..<count {
            try archive.store(data: Data("%PDF-\(index)".utf8),
                              id: "mydata-file-\(index)", fileExtension: "pdf",
                              displayName: "MyData 文件 \(index + 1)")
        }
        let controller = HomeViewController(makeStore: { store }, makeVaultArchive: { archive })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func myDataFrame(_ controller: HomeViewController, item: Int) throws -> CGRect {
        try #require(controller.collectionView.layoutAttributesForItem(
            at: IndexPath(item: item, section: 2))?.frame)
    }

    @Test func collapsedStackTucksTheHeroUnderFullOverlappingCards() throws {
        let (controller, _) = home(try seeded(3))
        let hero = try frame(controller, item: 0)
        let peek1 = try frame(controller, item: 1)
        let peek2 = try frame(controller, item: 2)
        // Every card is a FULL card (same height), not a clipped strip.
        #expect(hero.height > 200)
        #expect(abs(peek1.height - hero.height) < 1)
        #expect(abs(peek2.height - hero.height) < 1)
        // The hero sits at the BOTTOM of the pile (largest minY) and the cards
        // overlap — the hero starts well before a peek ends.
        #expect(hero.minY > peek1.minY)
        #expect(hero.minY > peek2.minY)
        #expect(peek1.maxY > hero.minY)                     // overlap, not a spaced list
        #expect(hero.minY - peek1.minY < hero.height)       // compact: tucked, not one-per-row
    }

    @Test func aSingleGovernmentCardDoesNotStack() throws {
        let (controller, _) = home(try seeded(1))
        #expect(try frame(controller, item: 0).height > 200)
    }

    @Test func tappingTheCollapsedStackExpandsToSpacedCards() throws {
        let (controller, window) = home(try seeded(3))
        controller.collectionView(controller.collectionView,
                                  didSelectItemAt: IndexPath(item: 0, section: Self.governmentSection))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        let hero = try frame(controller, item: 0)
        let peek1 = try frame(controller, item: 1)
        // Expanded: the first card is back on top and the second is below it with a
        // gap — no overlap.
        #expect(hero.minY < peek1.minY)
        #expect(peek1.minY >= hero.maxY)
    }

    @Test func restingStateResetsWhenTheGroupDropsBelowTwoCards() throws {
        let store = try seeded(3)
        let (controller, window) = home(store)

        controller.setGovernmentStackExpanded(true, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        #expect(try frame(controller, item: 0).minY < frame(controller, item: 1).minY)  // expanded

        // Drop to one card and rebuild: no longer stackable.
        try fill(store, count: 1)
        controller.viewWillAppear(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()

        // Repopulate to three and rebuild: because the resting state reset, the
        // group is collapsed again — hero tucked below the peeks.
        try fill(store, count: 3)
        controller.viewWillAppear(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        #expect(try frame(controller, item: 0).minY > frame(controller, item: 1).minY)  // collapsed again
    }

    @Test func myDataDocumentsUseTheSameCollapsedAndExpandedInteraction() throws {
        let (controller, window) = try myDataHome(count: 3)
        let collapsedHero = try myDataFrame(controller, item: 0)
        let collapsedPeek = try myDataFrame(controller, item: 1)
        #expect(collapsedHero.minY > collapsedPeek.minY)
        #expect(collapsedPeek.maxY > collapsedHero.minY)

        controller.collectionView(controller.collectionView,
                                  didSelectItemAt: IndexPath(item: 0, section: 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        let expandedHero = try myDataFrame(controller, item: 0)
        let expandedSecond = try myDataFrame(controller, item: 1)
        #expect(expandedHero.minY < expandedSecond.minY)
        #expect(expandedSecond.minY >= expandedHero.maxY)
    }

    /// The collapsed MyData stack now uses the same 60pt rhythm as government
    /// card. The document name therefore belongs inside that strip, not in the
    /// lower metadata area that the next card obscures.
    @Test func myDataCardNameFitsInsideTheCollapsedPeek() throws {
        let card = WalletCardView(frame: CGRect(x: 0, y: 0, width: 354, height: 354 / 1.9))
        card.configure(.vault(VaultCard(
            title: "個人所得資料",
            message: "PDF · 2026/9/1 匯入",
            status: "已儲存原始檔",
            systemImage: "banknote.fill")))
        card.setNeedsLayout()
        card.layoutIfNeeded()

        let title = try #require(findView(identifier: "wallet.vault.title", in: card) as? UILabel)
        let titleFrame = title.convert(title.bounds, to: card)
        #expect(titleFrame.minY >= 0)
        #expect(titleFrame.maxY <= 60,
                "MyData title must remain visible in the collapsed 60pt peek; frame was \(titleFrame)")
    }

    @Test func myDataAndGovernmentStacksShareTheSameCollapsedSpacing() throws {
        let (government, _) = home(try seeded(3))
        let governmentGap = abs(try frame(government, item: 2).minY
                                - frame(government, item: 1).minY)
        let (myData, _) = try myDataHome(count: 3)
        let myDataGap = abs(try myDataFrame(myData, item: 2).minY
                            - myDataFrame(myData, item: 1).minY)
        #expect(abs(governmentGap - 60) < 1)
        #expect(abs(myDataGap - governmentGap) < 1)
    }

    @Test func continuityTransformMapsTheNewFrameBackToTheOldViewportFrame() {
        let old = CGRect(x: 16, y: 412, width: 358, height: 220)
        let final = CGRect(x: 16, y: 292, width: 358, height: 220)
        let transform = HomeViewController.stackContinuityTransform(oldFrame: old,
                                                                     finalFrame: final)
        #expect(abs(final.applying(transform).minY - old.minY) < 0.001)
        #expect(abs(final.applying(transform).minX - old.minX) < 0.001)
    }

    @Test func disabledAnimationsNeverLeaveTheCollectionLocked() throws {
        let (controller, window) = home(try seeded(3))
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        controller.setGovernmentStackExpanded(true, animated: true)
        #expect(controller.collectionView.isUserInteractionEnabled)
        withExtendedLifetime(window) {}
    }

    private func findView(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap { findView(identifier: identifier, in: $0) }.first
    }
}
