//
//  GovernmentCardViewControllerTests.swift
//  backupTWTests
//
//  Opening a collected government card so its contents are actually visible —
//  and failing honestly, never fatally, when it cannot be read.
//

import Foundation
import Testing
@testable import backupTW

@Suite("政府皮夾卡片詳情頁")
struct GovernmentCardViewControllerTests {

    // MARK: - Reading a stored card by its id

    /// The whole point of the screen: a TWDIW card sitting in the store, keyed
    /// by the id its row carries, decodes into something with fields to show.
    @Test func readsAStoredTWDIWCardByItsID() throws {
        let store = MemoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "licence")

        let content = GovernmentCardViewController.read(id: "licence", from: store)

        guard case let .card(credential) = content else {
            Issue.record("a well-formed stored card did not read as a card: \(content)")
            return
        }
        #expect(credential.credentialType == TWDIWFixture.credentialType)
        #expect(Set(credential.disclosedClaims.map(\.name))
                == ["name", "id_number", "roc_birthday"])
    }

    /// An id with nothing behind it is "no longer stored", not a crash and not a
    /// pretend-empty card.
    @Test func aMissingCardIsUnreadableRatherThanFatal() {
        let content = GovernmentCardViewController.read(id: "not-there", from: MemoryStore())
        guard case .unreadable = content else {
            Issue.record("a missing card did not read as unreadable: \(content)")
            return
        }
    }

    /// A card whose signature does not verify is not opened as though it were
    /// fine — and the reason it gives is the honest one that cannot claim to
    /// tell a damaged file from a re-signed one apart.
    @Test func aStrangerSignedCardIsUnreadableWithTheHonestReason() throws {
        let store = MemoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.resignedByAStranger(), id: "stranger")

        let content = GovernmentCardViewController.read(id: "stranger", from: store)

        guard case let .unreadable(reason) = content else {
            Issue.record("a stranger-signed card was opened as a valid card: \(content)")
            return
        }
        #expect(reason == GovernmentCardViewController.message(for: .signatureInvalid))
    }

    /// A `nil` store — the real one refusing to construct — is the honest
    /// "cannot be read right now", never a force-unwrap.
    @Test func aStoreThatWillNotOpenIsUnreadable() {
        let content = GovernmentCardViewController.read(id: "licence", from: nil)
        guard case .unreadable = content else {
            Issue.record("a nil store did not read as unreadable: \(content)")
            return
        }
    }

    // MARK: - Field labels

    /// A term this build shares with the holder's own ID gets the app's own
    /// noun, from the single shared table — not a label reinvented here.
    @Test func aKnownFieldUsesTheSharedLabel() {
        #expect(GovernmentCardViewController.fieldHeading(for: "name")
                == StoredNationalID.label(for: "name"))
    }

    /// A driving-licence field this build has never met is shown as the
    /// document's own key, quoted inside the app's sentence — not given a
    /// Chinese label invented for it. The raw term survives into the heading.
    @Test func anUnknownFieldQuotesTheDocumentsOwnKey() {
        let heading = GovernmentCardViewController.fieldHeading(for: "controlnumber")
        #expect(heading.contains("controlnumber"))
        // And it is not simply the raw key masquerading as an app-authored
        // label: the app's framing is wrapped around it.
        #expect(heading != "controlnumber")
    }

    // MARK: - The screen itself

    /// Constructing the screen with a real stored card and loading its view
    /// runs the whole data-source build without crashing.
    @MainActor
    @Test func theScreenLoadsForAStoredCard() throws {
        let store = MemoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "licence")

        let vc = GovernmentCardViewController(id: "licence", store: store)
        // Forces `viewDidLoad`, which reads the store and applies the snapshot.
        _ = vc.view
        #expect(vc.title == CardCapability.twdiw.name)
    }

    /// And the unreadable path renders too — the screen a holder reaches by
    /// tapping a card that will not decode must open, not fall over.
    @MainActor
    @Test func theScreenLoadsForAnUnreadableCard() throws {
        let store = MemoryStore()
        try store.save(jws: "this is not a credential", id: "mystery")

        let vc = GovernmentCardViewController(id: "mystery", store: store)
        // Forcing the view load builds the unreadable-state list; it must open,
        // not trap.
        #expect(vc.view != nil)
    }
}

/// A store that never touches the filesystem.
private final class MemoryStore: CredentialStoring, @unchecked Sendable {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { Array(items.keys) }
    func deleteAll() throws { items.removeAll() }
}
