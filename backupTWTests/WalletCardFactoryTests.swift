//
//  WalletCardFactoryTests.swift
//  backupTWTests
//
//  Turning stored credentials into card faces without ever letting a full
//  sensitive value onto the glanceable surface.
//

import Foundation
import Testing
@testable import backupTW

struct WalletCardFactoryTests {

    // MARK: - National ID face

    /// The self-issued document's face shows the name in full, and masks the
    /// 統一編號 — the full number never appears anywhere on the card.
    @Test func nationalIDFaceMasksTheUnifiedNumber() throws {
        let store = FactoryStore()
        try store.save(jws: Self.selfIssuedJWS(name: "王小明",
                                               unifiedNo: "A123456789",
                                               birthdate: "0800101",
                                               nationality: "中華民國"),
                       id: StoredNationalID.credentialID)
        let row = CardInventoryRow(id: StoredNationalID.credentialID, source: .selfIssued,
                                   capability: .selfIssued, title: "x", detail: "y", state: .usable)

        let content = WalletCardFactory.nationalIDContent(row: row, store: store)
        guard case let .nationalID(card) = content else {
            Issue.record("self-issued row did not become a national ID face: \(content)")
            return
        }

        // The name is masked to the surname on the face; the full name lives
        // only behind the detail screen's reveal.
        #expect(card.holderName == "王〇〇")
        #expect(card.idValueMasked == "A1●●●●●●●9")
        // Self-issued cards say plainly that only the holder vouches for them.
        #expect(card.trustSource == "行動自然人憑證 · 本人自簽")

        // The full number, full name, and full birthdate are nowhere on the face.
        let everything = Self.allStrings(of: card)
        #expect(!everything.contains("A123456789"), "the full 統一編號 reached the card face")
        #expect(!everything.contains("王小明"), "the full name reached the card face")
        #expect(!everything.contains("0800101"), "the full birthdate reached the card face")
    }

    /// The flip side lists the fuller field set — including the 戶籍地址 the front
    /// never shows — and every one of those values is masked. This is the back's
    /// sibling to `nationalIDFaceMasksTheUnifiedNumber`: the same over-the-shoulder
    /// surface, the same iron rule, now for the field that `isSensitiveKey` does
    /// not name (an address is not an identifier *number*).
    @Test func nationalIDBackMasksEveryField() throws {
        let store = FactoryStore()
        try store.save(jws: Self.selfIssuedJWS(name: "王小明",
                                               unifiedNo: "A123456789",
                                               birthdate: "0800101",
                                               nationality: "中華民國",
                                               addressOfHousehold: "臺北市中正區重慶南路一段122號"),
                       id: StoredNationalID.credentialID)
        let row = CardInventoryRow(id: StoredNationalID.credentialID, source: .selfIssued,
                                   capability: .selfIssued, title: "x", detail: "y", state: .usable)

        let content = WalletCardFactory.nationalIDContent(row: row, store: store)
        guard case let .nationalID(card) = content else {
            Issue.record("self-issued row did not become a national ID face: \(content)")
            return
        }

        // A real back exists (this is what makes the card flippable) and carries
        // the household address row the front omits.
        #expect(!card.backFields.isEmpty, "a stored national ID must have a flip side")
        let backValues = card.backFields.map(\.value).joined(separator: "\u{1}")
        #expect(backValues.contains("〇"), "the name on the back must be masked")

        // No full sensitive value — number, name, birthdate, or the full household
        // address — anywhere on the card, front or back.
        let everything = Self.allStrings(of: card)
        for leak in ["A123456789", "王小明", "0800101", "臺北市中正區重慶南路一段122號"] {
            #expect(!everything.contains(leak), "a full sensitive value reached the card: \(leak)")
        }
    }

    /// With no self-issued document, the face is the invite-to-create card: a
    /// title and a prompt, no number. It has no flip side, which is what keeps it
    /// tapping through to onboarding rather than turning.
    @Test func nationalIDPlaceholderHasNoBack() {
        guard case let .nationalID(card) =
                WalletCardFactory.nationalIDContent(row: nil, store: FactoryStore()) else {
            Issue.record("expected a placeholder national ID face")
            return
        }
        #expect(card.backFields.isEmpty)
    }

    /// With no self-issued document, the face is the invite-to-create card: a
    /// title and a prompt, no number.
    @Test func nationalIDPlaceholderWhenNothingStored() {
        let content = WalletCardFactory.nationalIDContent(row: nil, store: FactoryStore())
        guard case let .nationalID(card) = content else {
            Issue.record("expected a placeholder national ID face: \(content)")
            return
        }
        #expect(card.placeholderMessage != nil)
        #expect(card.idValueMasked == nil)
        #expect(card.holderName.isEmpty)
    }

    // MARK: - Government credential face

    /// A collected licence's face never carries the disclosed id_number in full,
    /// and shows the holder's name.
    @Test func credentialFaceMasksTheIdentifier() throws {
        let store = FactoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "licence")
        let row = CardInventoryRow(id: "licence", source: .twdiw, capability: .twdiw,
                                   title: "x", detail: "y", state: .usable)

        let content = WalletCardFactory.credentialContent(row: row, store: store)
        guard case let .credential(card) = content else {
            Issue.record("a well-formed licence did not become a credential face: \(content)")
            return
        }

        // TWDIW's own published sample person — masked to the surname on the face.
        #expect(card.holderName == "陳〇〇")
        #expect(card.primaryMasked == WalletCardMask.masked("A234567890"))

        let everything = Self.allStrings(of: card)
        for leak in ["A234567890", "0570605", "陳筱玲"] {
            #expect(!everything.contains(leak), "a full disclosed value reached the card face: \(leak)")
        }
        // The demo fixture is a sandbox card, so its issuer is named honestly as
        // 沙盒系統 rather than dressed up as a real 公路局 licence — but its kind
        // still reads for what it is, a 駕照電子卡.
        #expect(card.kind == "駕照電子卡")
        #expect(card.issuer == "沙盒系統")
        #expect(card.trustSource == "沙盒/測試")
    }

    /// The credential's flip side lists every disclosed claim, and not one of them
    /// appears in full — the same leak check as the front, now over the back's
    /// fuller list. Sibling to `credentialFaceMasksTheIdentifier`.
    @Test func credentialBackMasksEveryDisclosedClaim() throws {
        let store = FactoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.serialized, id: "licence")
        let row = CardInventoryRow(id: "licence", source: .twdiw, capability: .twdiw,
                                   title: "x", detail: "y", state: .usable)

        let content = WalletCardFactory.credentialContent(row: row, store: store)
        guard case let .credential(card) = content else {
            Issue.record("a well-formed licence did not become a credential face: \(content)")
            return
        }

        // A real credential is always flippable: it has a back listing its
        // disclosed fields (name, id_number, roc_birthday from the fixture).
        #expect(!card.backFields.isEmpty, "a credential must have a flip side")

        let everything = Self.allStrings(of: card)
        for leak in ["A234567890", "0570605", "陳筱玲"] {
            #expect(!everything.contains(leak),
                    "a full disclosed value reached the card face (front or back): \(leak)")
        }
        // The masked forms *are* present on the back, so it is showing the fields,
        // just never in the clear.
        let backValues = card.backFields.map(\.value).joined(separator: "\u{1}")
        #expect(backValues.contains(WalletCardMask.masked("A234567890")))
        #expect(backValues.contains("陳〇〇"))
    }

    /// A driving licence is tinted green; the tint is chosen from the type, and
    /// a colour asserts nothing so this may key off it.
    @Test func drivingLicenceIsGreen() {
        #expect(WalletCardFactory.tint(forCredentialType: TWDIWFixture.credentialType,
                                       issuer: "did:key:z") == .green)
    }

    @Test func telecomIsMagenta() {
        #expect(WalletCardFactory.tint(forCredentialType: "00000000_mobile_number_202504251418",
                                       issuer: "did:key:z") == .magenta)
    }

    @Test func anUnknownKindIsNeutral() {
        #expect(WalletCardFactory.tint(forCredentialType: "00000000_library_card_202504251418",
                                       issuer: "did:key:z") == .neutral)
    }

    /// A card whose signature does not verify becomes a neutral unreadable face,
    /// never a credential face pretending it is fine.
    @Test func aStrangerSignedCardIsUnreadable() throws {
        let store = FactoryStore()
        let fixture = TWDIWFixture()
        try store.save(jws: fixture.resignedByAStranger(), id: "stranger")
        let row = CardInventoryRow(id: "stranger", source: .twdiw, capability: .twdiw,
                                   title: "x", detail: "y", state: .unreadable)

        let content = WalletCardFactory.credentialContent(row: row, store: store)
        guard case .unreadable = content else {
            Issue.record("a stranger-signed card became a credential face: \(content)")
            return
        }
    }

    /// An unrecognised blob is an honest neutral face, with no guess at what it is.
    @Test func anUnrecognisedCardIsUnreadable() {
        let row = CardInventoryRow(id: "mystery", source: .unrecognised, capability: nil,
                                   title: "x", detail: "y", state: .unreadable)
        let content = WalletCardFactory.credentialContent(row: row, store: FactoryStore())
        guard case .unreadable = content else {
            Issue.record("an unrecognised card was not unreadable: \(content)")
            return
        }
    }

    // MARK: - Vault

    @Test func vaultCardStatesNothingIsKept() {
        guard case let .vault(card) = WalletCardFactory.vaultContent() else {
            Issue.record("vault content was not a vault card")
            return
        }
        #expect(!card.title.isEmpty)
        #expect(!card.message.isEmpty)
        #expect(!card.status.isEmpty)
    }

    // MARK: - Fixtures

    /// Every display string on a national ID face — **front and back** — so a leak
    /// check covers the flip side too, which shows the fuller field list.
    private static func allStrings(of card: NationalIDCard) -> String {
        var parts = [card.title, card.holderName, card.idLabel ?? "", card.idValueMasked ?? "",
                     card.placeholderMessage ?? "", card.trustSource]
        parts += card.fields.flatMap { [$0.label, $0.value] }
        parts += card.backFields.flatMap { [$0.label, $0.value] }
        return parts.joined(separator: "\u{1}")
    }

    /// Every display string on a credential face — **front and back** — for a leak
    /// check that includes the flip side's disclosed-field list.
    private static func allStrings(of card: CredentialCard) -> String {
        var parts = [card.kind, card.kindEnglish ?? "", card.issuer,
                     card.holderName ?? "", card.primaryMasked ?? "", card.trustSource]
        parts += [card.leftField, card.rightField].compactMap { $0 }.flatMap { [$0.label, $0.value] }
        parts += card.backFields.flatMap { [$0.label, $0.value] }
        return parts.joined(separator: "\u{1}")
    }

    /// A device-signed self-issued national ID as it sits in the store: a compact
    /// JWS whose payload is the `VerifiableCredential`. The signature is not
    /// checked on the holder's own read path, so a placeholder segment is fine.
    private static func selfIssuedJWS(name: String, unifiedNo: String,
                                      birthdate: String, nationality: String,
                                      addressOfHousehold: String? = nil) -> String {
        var subject = ["id": "did:key:zTest", "name": name, "unifiedNo": unifiedNo,
                       "birthdate": birthdate, "nationality": nationality]
        if let addressOfHousehold { subject["addressOfHousehold"] = addressOfHousehold }
        let credential = VerifiableCredential(
            context: [.url(VerifiableCredential.credentialsV2Context)],
            type: [VerifiableCredential.baseType, VerifiableCredential.nationalIDType],
            issuer: "did:key:zTest",
            validFrom: "2026-01-01T00:00:00Z",
            credentialSubject: subject,
            sd: nil)
        let payload = (try? JSONEncoder().encode(credential)) ?? Data()
        return "e30." + VerifiableCredential.base64URLEncoded(payload) + ".sig"
    }
}

/// A store that never touches the filesystem.
private final class FactoryStore: CredentialStoring, @unchecked Sendable {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { Array(items.keys) }
    func delete(id: String) throws { items.removeValue(forKey: id) }
    func deleteAll() throws { items.removeAll() }
}
