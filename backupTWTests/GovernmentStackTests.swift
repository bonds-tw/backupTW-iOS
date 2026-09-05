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
        // The hero is the LAST item: the pile and the expanded list read in the
        // same top-to-bottom order, so expanding never flips the stack over
        // (使用者回報 2026-09-02; Apple Wallet keeps the order).
        let (controller, _) = home(try seeded(3))
        let peek1 = try frame(controller, item: 0)
        let peek2 = try frame(controller, item: 1)
        let hero = try frame(controller, item: 2)
        // Every card is a FULL card (same height), not a clipped strip.
        #expect(hero.height > 200)
        #expect(abs(peek1.height - hero.height) < 1)
        #expect(abs(peek2.height - hero.height) < 1)
        // The pile reads in item order: peeks descend, hero at the bottom
        // (largest minY), overlapping — not a spaced list.
        #expect(peek1.minY < peek2.minY)
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
        let first = try frame(controller, item: 0)
        let second = try frame(controller, item: 1)
        let hero = try frame(controller, item: 2)
        // Expanded: the same top-to-bottom order as the pile, spread out with no
        // overlap — the front card (hero, last item) stays at the bottom instead
        // of teleporting to the top.
        #expect(first.minY < second.minY)
        #expect(second.minY >= first.maxY)
        #expect(hero.minY >= second.maxY)
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
        // group is collapsed again — the last item is the hero at the bottom,
        // overlapping the peek above it.
        try fill(store, count: 3)
        controller.viewWillAppear(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        #expect(try frame(controller, item: 2).minY > frame(controller, item: 1).minY)      // hero at the bottom
        #expect(try frame(controller, item: 1).maxY > frame(controller, item: 2).minY)      // overlapping: collapsed
    }

    @Test func myDataDocumentsUseTheSameCollapsedAndExpandedInteraction() throws {
        let (controller, window) = try myDataHome(count: 3)
        let collapsedPeek = try myDataFrame(controller, item: 0)
        let collapsedHero = try myDataFrame(controller, item: 2)
        #expect(collapsedHero.minY > collapsedPeek.minY)
        #expect(collapsedPeek.maxY > collapsedHero.minY)

        controller.collectionView(controller.collectionView,
                                  didSelectItemAt: IndexPath(item: 0, section: 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        // Same order spread out: the hero (last item) stays at the bottom.
        let expandedFirst = try myDataFrame(controller, item: 0)
        let expandedSecond = try myDataFrame(controller, item: 1)
        let expandedHero = try myDataFrame(controller, item: 2)
        #expect(expandedFirst.minY < expandedSecond.minY)
        #expect(expandedSecond.minY >= expandedFirst.maxY)
        #expect(expandedHero.minY >= expandedSecond.maxY)
    }

    @Test func disabledAnimationsNeverLeaveTheCollectionLocked() throws {
        let (controller, window) = home(try seeded(3))
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        controller.setGovernmentStackExpanded(true, animated: true)
        #expect(controller.collectionView.isUserInteractionEnabled)
        withExtendedLifetime(window) {}
    }
}
