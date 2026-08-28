//
//  StoredCardSourceTests.swift
//  backupTWTests
//
//  The rule that decides which reader a stored document goes to.
//

import Foundation
import Testing
@testable import backupTW

@Suite("儲存的卡片是哪一種")
struct StoredCardSourceTests {

    private static let jws = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJkaWQ6a2V5OnpEbiJ9.c2ln"

    @Test func aSelfIssuedCompactJWSIsRecognised() {
        #expect(StoredCardSource.source(of: Self.jws) == .selfIssued)
    }

    @Test func aSelfIssuedJSONDocumentIsRecognised() {
        #expect(StoredCardSource.source(of: #"{"credential":"…","proof":{}}"#) == .selfIssued)
    }

    @Test func aTWDIWSDJWTIsRecognised() {
        let disclosure = "WyJhOFNHY1VKY2RYTW1aM2VTVVM2eERRIiwibmFtZSIsIumZs-etseeOsiJd"
        #expect(StoredCardSource.source(of: "\(Self.jws)~\(disclosure)~") == .twdiw)
    }

    /// Production emits a trailing `~` even when nothing is disclosed, and that
    /// shape has to be recognised — it is what a card with every field withheld
    /// looks like.
    @Test func aTWDIWCredentialWithNoDisclosuresIsStillTWDIW() {
        #expect(StoredCardSource.source(of: "\(Self.jws)~") == .twdiw)
    }

    /// **The defect this type exists to stop.**
    ///
    /// The self-issued id is `national-id`; a TWDIW identifier derived from a
    /// credential configuration begins with a digit, and digits sort before
    /// letters. Taking `allIDs().first` therefore picks the TWDIW card the
    /// moment one exists — and the card-signed presentation path cannot build a
    /// presentation from an SD-JWT, so the holder gets a refusal about a
    /// document they never chose to show.
    @Test func presentationPicksTheSelfIssuedCardEvenWhenATWDIWCardSortsFirst() throws {
        let store = InMemoryCredentialStore()
        try store.save(jws: "\(Self.jws)~", id: "00000000_demo_drivinglicense_202504251418")
        try store.save(jws: Self.jws, id: "national-id")

        // The premise: the TWDIW identifier really does come first.
        #expect(try store.allIDs().sorted().first == "00000000_demo_drivinglicense_202504251418")

        let holder = HolderPresentation(store: store, loadKey: { nil })
        #expect(try holder.storedCredentialID() == "national-id")
    }

    /// And with only a TWDIW card, this path has nothing it can present —
    /// reported as "none", not as the wrong card.
    @Test func presentationHasNothingToShowWhenOnlyATWDIWCardIsStored() throws {
        let store = InMemoryCredentialStore()
        try store.save(jws: "\(Self.jws)~", id: "00000000_demo_drivinglicense_202504251418")
        let holder = HolderPresentation(store: store, loadKey: { nil })
        #expect(try holder.storedCredentialID() == nil)
    }

    /// A tilde inside a self-issued document does not make it a TWDIW card. The
    /// leading segment has to be a JWS as well.
    @Test func aTildeInsideADocumentIsNotTheSignal() {
        #expect(StoredCardSource.source(of: #"{"note":"a~b"}"#) == .selfIssued)
        #expect(StoredCardSource.source(of: "not-a-jws~something") == .unrecognised)
    }

    /// A damaged TWDIW card must not be routed to the self-issued reader, which
    /// would describe it as "not a valid credential" — a sentence about the
    /// wrong document.
    @Test func aDamagedTWDIWCardIsNotReportedAsAnInvalidSelfIssuedOne() {
        let truncated = "\(Self.jws)~WyJhOFNH"
        #expect(StoredCardSource.source(of: truncated) == .twdiw)
    }

    /// Shape only. A card whose signature is wrong is still a TWDIW card, and
    /// the reader that checks signatures is the one entitled to say so.
    @Test func routingDoesNotVerifyAnything() {
        let badSignature = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.AAAA~"
        #expect(StoredCardSource.source(of: badSignature) == .twdiw)
    }

    @Test func emptyAndJunkAreUnrecognised() {
        #expect(StoredCardSource.source(of: "") == .unrecognised)
        #expect(StoredCardSource.source(of: "hello") == .unrecognised)
        #expect(StoredCardSource.source(of: "a.b") == .unrecognised)
        #expect(StoredCardSource.source(of: "a..c") == .unrecognised)
    }
}

/// A store that never touches the filesystem, so these tests cannot be affected
/// by — or affect — a real credential directory.
private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { items.keys.sorted() }
    func delete(id: String) throws { items.removeValue(forKey: id) }
    func deleteAll() throws { items.removeAll() }
}
