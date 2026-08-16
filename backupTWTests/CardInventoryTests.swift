//
//  CardInventoryTests.swift
//  backupTWTests
//
//  The three ways a card list goes quietly wrong.
//

import Foundation
import Testing
@testable import backupTW

struct CardInventoryTests {

    // MARK: - A card in the store is a row on the screen, whatever state it is in

    @Test("a card this build cannot read is still listed")
    func unreadableCardIsStillARow() throws {
        let store = InventoryStore()
        try store.save(jws: "this is not a credential", id: "mystery")

        let rows = CardInventory.rows(from: store)

        // The failure being guarded against is a `compactMap`: a clean list, and
        // a card the holder collected that is simply not on screen.
        #expect(rows.count == 1)
        #expect(rows[0].id == "mystery")
        #expect(rows[0].state == .unreadable)
    }

    @Test("a card whose signature does not verify is listed, not hidden")
    func unverifiableCardIsStillARow() throws {
        let store = InventoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.resignedByAStranger(), id: "stranger-signed")

        let rows = CardInventory.rows(from: store)

        #expect(rows.count == 1)
        #expect(rows[0].source == .twdiw)
        #expect(rows[0].state == .unreadable)
    }

    @Test("an expired card is shown as expired rather than dropped")
    func expiredCardIsShown() throws {
        let store = InventoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "licence")

        // The fixture's `exp` is in 2035; ask from 2040.
        let rows = CardInventory.rows(from: store,
                                      now: Date(timeIntervalSince1970: 2_209_000_000))

        #expect(rows.count == 1)
        #expect(rows[0].state == .expired)
    }

    @Test("a card with no expiry says so instead of printing the substituted date")
    func missingExpiryIsNotDressedUpAsADate() throws {
        let store = InventoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.withoutExpiry(), id: "no-exp")

        let rows = CardInventory.rows(from: store)

        #expect(rows.count == 1)
        #expect(rows[0].state == .usable)
        // `.distantFuture` formats as a year in the fifth millennium. Whatever
        // the row says, it must not have turned a claim the issuer never made
        // into a date on a screen.
        #expect(!rows[0].detail.contains("4001"))
        #expect(!rows[0].detail.contains("4002"))
    }

    // MARK: - Order

    @Test("our own document leads, whatever order the store hands them back in")
    func selfIssuedSortsFirst() throws {
        let store = InventoryStore()
        let fixture = TWDIWFixture()
        // This identifier is the one from `StoredCardSource`'s note: it begins
        // with a digit, so it sorts before `national-id` in every plain sort.
        try store.save(jws: fixture.serialized, id: "00000000_demo_drivinglicense_202504251418")
        try store.save(jws: #"{"credentialSubject":{"name":"x"},"issuer":"did:key:z","validFrom":"2026-01-01T00:00:00Z"}"#,
                       id: StoredNationalID.credentialID)

        let rows = CardInventory.rows(from: store)

        #expect(rows.count == 2)
        #expect(rows[0].source == .selfIssued)
        #expect(rows[1].source == .twdiw)
    }

    // MARK: - What may not appear on a glanceable screen

    @Test("no disclosed claim value reaches the list")
    func claimValuesStayOffTheHomeScreen() throws {
        let store = InventoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "licence")

        let rows = CardInventory.rows(from: store)
        let visible = rows.map { $0.title + " " + $0.detail }.joined(separator: " ")

        // The fixture's disclosures are TWDIW's own published sample person.
        for value in ["陳筱玲", "A234567890", "0570605"] {
            #expect(!visible.contains(value), "a claim value reached the card list: \(value)")
        }
        // The card's *kind* is expected to be there — that is what a wallet is.
        #expect(visible.contains(CardInventory.readableType(TWDIWFixture.credentialType)))
    }

    @Test("every row carries the capability it belongs to")
    func rowsCarryTheirCapability() throws {
        let store = InventoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "licence")

        let rows = CardInventory.rows(from: store)

        // The link the milestone exists for: a row on the home screen can reach
        // the honest account of what its kind cannot do.
        #expect(rows[0].capability == .twdiw)
        #expect(rows[0].capability?.limits.isEmpty == false)
    }

    // MARK: - The type string, which is the only name a card has offline

    @Test("the issuer code and the issuance timestamp come off")
    func readableTypeStripsWhatTheHolderCannotUse() {
        #expect(CardInventory.readableType("00000000_demo_drivinglicense_202504251418")
                == "demo_drivinglicense")
    }

    @Test(arguments: [
        // Two segments only — nothing to strip without guessing which is which.
        "demo_drivinglicense",
        // No leading digit run and no trailing timestamp.
        "moi_household_registration",
        // A trailing number that is not a timestamp shape.
        "issuer_card_v2",
        // Digits in the middle, which say nothing about the ends.
        "issuer_2024_card_edition",
    ])
    func aTypeThatDoesNotHaveTheShapeIsLeftAlone(_ raw: String) {
        #expect(CardInventory.readableType(raw) == raw)
    }

    @Test("stripping never returns nothing")
    func strippingNeverEmptiesTheName() {
        // Both ends match and there is nothing in between. Returning "" here
        // would put a nameless row on the screen, which is worse than the raw
        // string this exists to improve on.
        #expect(CardInventory.readableType("00000000__202504251418")
                == "00000000__202504251418")
    }

    @Test("an empty store lists nothing at all")
    func emptyStoreIsEmpty() {
        #expect(CardInventory.rows(from: InventoryStore()).isEmpty)
    }
}

/// A store that never touches the filesystem.
///
/// `allIDs()` deliberately returns insertion order rather than a sorted list:
/// sorting here would do `CardInventory`'s job for it and quietly pass the one
/// test that exists to check the ordering.
private final class InventoryStore: CredentialStoring, @unchecked Sendable {
    private var order: [String] = []
    private var items: [String: String] = [:]

    func save(jws: String, id: String) throws {
        if items[id] == nil { order.append(id) }
        items[id] = jws
    }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { order }
    func deleteAll() throws { order.removeAll(); items.removeAll() }
}
