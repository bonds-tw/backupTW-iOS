//
//  SelectiveDisclosureIssuanceTests.swift
//  backupTWTests
//
//  A card-signed credential whose claims can be withheld one at a time.
//

import Foundation
import Testing
@testable import backupTW

struct SelectiveDisclosureIssuanceTests {

    private static let subjectDID = "did:key:zDnaerDaTF5BXEavCrfRZEk316dpbLsfPDZ3WJ5hRTPFU2169"
    private static let issuedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private static let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                               unifiedNo: "A123456789",
                                               name: "王小明",
                                               birthdate: "民國 083年03月06日",
                                               addressOfHousehold: "臺北市中正區重慶南路一段122號")

    private func issued() -> (credential: VerifiableCredential, disclosures: [Disclosure]) {
        VerifiableCredential.selectivelyDisclosableNationalID(Self.model,
                                                              issuerDID: Self.subjectDID,
                                                              validFrom: Self.issuedAt)
    }

    private func holderCertificate() throws -> X509Certificate {
        try X509Certificate.parse(base64DER: holderCertificateDER)
    }

    /// Builds the envelope the way issuance does, with a chosen subset of the
    /// disclosures — which is exactly what presenting a subset produces.
    private func sign(_ credential: VerifiableCredential,
                      disclosing: [Disclosure]) throws -> MOICASignedCredential {
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential)
        return MOICASignedCredential(
            payload: VerifiableCredential.base64URLEncoded(bytes),
            proof: MOICACredentialProof(
                tbsConstruction: MOICACredentialProof.payloadDigestHexConstruction,
                certificate: holderCertificateDER,
                signature: try cardSignature(over: Data(tbs.utf8)).base64EncodedString()),
            disclosures: disclosing.map(\.encoded))
    }

    // MARK: What issuance commits to

    /// No factual claim may be left in the clear. One that was would be a claim
    /// the holder can never withhold, which is the property this whole change
    /// exists to give them.
    @Test func onlyTheSubjectIdentifierIsLeftInTheClear() {
        let (credential, disclosures) = issued()

        #expect(credential.credentialSubject.keys.sorted() == ["id"])
        #expect(credential.sd?.count == disclosures.count)
        #expect(disclosures.contains { $0.claimName == "unifiedNo" })
        #expect(disclosures.contains { $0.claimName == AgePredicate.claimName })
    }

    /// The digest array is sorted, so position says nothing about which claim a
    /// digest belongs to. Unsorted, a verifier holding one disclosure could work
    /// out what the withheld ones are from where they sit.
    @Test func theCommittedDigestsAreSorted() {
        let (credential, _) = issued()
        let digests = credential.sd ?? []

        #expect(digests == digests.sorted())
        #expect(Set(digests).count == digests.count, "a repeated digest would collapse two claims into one")
    }

    // MARK: Withholding

    /// The point of the exercise: hand over only the age predicate, and the
    /// signature still verifies over a payload that never contained a birthdate.
    @Test func theAgePredicateAloneVerifies() throws {
        let (credential, disclosures) = issued()
        let ageOnly = try #require(disclosures.first { $0.claimName == AgePredicate.claimName })

        let verified = try sign(credential, disclosing: [ageOnly])
            .verify(signedBy: try holderCertificate())

        #expect(verified.claims == [AgePredicate.claimName: "true"])
        #expect(verified.withheldClaimCount == disclosures.count - 1)
        // Nothing about the date reached the verifier.
        #expect(verified.claims["birthdate"] == nil)
        #expect(verified.claims["unifiedNo"] == nil)
    }

    /// Withholding `name` is allowed and it costs the cardholder cross-check.
    /// The verifier must be told that, not left to assume the name was
    /// confirmed because a name appears on screen from the certificate.
    @Test func withholdingTheNameSkipsTheBindingRatherThanFailingIt() throws {
        let (credential, disclosures) = issued()
        let ageOnly = try #require(disclosures.first { $0.claimName == AgePredicate.claimName })

        let verified = try sign(credential, disclosing: [ageOnly])
            .verify(signedBy: try holderCertificate())

        #expect(verified.cardholderNameWasChecked == false)
        // The certificate still names somebody — that is not the same as having
        // checked them against the document.
        #expect(verified.cardholderName == "王小明")
    }

    /// And when the name *is* disclosed, the cross-check runs and is recorded.
    @Test func disclosingTheNameRunsTheBinding() throws {
        let (credential, disclosures) = issued()
        let name = try #require(disclosures.first { $0.claimName == "name" })

        let verified = try sign(credential, disclosing: [name])
            .verify(signedBy: try holderCertificate())

        #expect(verified.cardholderNameWasChecked)
        #expect(verified.claims["name"] == "王小明")
    }

    /// A disclosed name that is not the cardholder's is still refused, exactly
    /// as it was before disclosures existed.
    @Test func aDisclosedNameThatIsNotTheCardholdersIsRefused() throws {
        let (credential, disclosures) = issued()
        let name = try #require(disclosures.first { $0.claimName == "name" })
        let other = try X509Certificate.parse(base64DER: otherCardholderCertificateDER)

        #expect(throws: MOICASignedCredentialError.cardholderNameDiffersFromSubject) {
            try self.sign(credential, disclosing: [name]).verify(signedBy: other)
        }
    }

    /// Handing over everything is still a valid choice, and the count of
    /// withheld claims is then zero rather than absent.
    @Test func disclosingEverythingWithholdsNothing() throws {
        let (credential, disclosures) = issued()

        let verified = try sign(credential, disclosing: disclosures)
            .verify(signedBy: try holderCertificate())

        #expect(verified.withheldClaimCount == 0)
        #expect(verified.claims["unifiedNo"] == "A123456789")
        #expect(verified.claims["birthdate"] == "民國 083年03月06日")
        #expect(verified.cardholderNameWasChecked)
    }

    // MARK: What a holder must not be able to do

    /// The check the whole scheme rests on: a holder cannot add a claim the card
    /// never committed to. Without it a credential would assert whatever its
    /// holder felt like.
    @Test func aDisclosureTheCardNeverCommittedToIsRefused() throws {
        let (credential, disclosures) = issued()
        let name = try #require(disclosures.first { $0.claimName == "name" })
        let forged = Disclosure(claimName: "occupation", claimValue: "內政部長")

        #expect(throws: MOICASignedCredentialError.disclosureNotCommitted) {
            try self.sign(credential, disclosing: [name, forged])
                .verify(signedBy: try self.holderCertificate())
        }
    }

    /// And the refusal is total: one forged disclosure invalidates the set
    /// rather than being dropped from it. A document that can be partly believed
    /// is one a screen has to explain, and there is no honest explanation of
    /// "some of these are real".
    @Test func oneForgedDisclosureInvalidatesTheHonestOnesToo() throws {
        let (credential, disclosures) = issued()
        let forged = Disclosure(claimName: AgePredicate.claimName, claimValue: "true")

        // A *different* salt for a claim that genuinely exists: same name, same
        // value, digest the card never signed.
        #expect(throws: MOICASignedCredentialError.disclosureNotCommitted) {
            try self.sign(credential, disclosing: disclosures + [forged])
                .verify(signedBy: try self.holderCertificate())
        }
    }

    // MARK: The holder's own screen

    /// The holder sees their whole document. Withholding is a decision made at
    /// presentation; a screen that showed them digests would be hiding their own
    /// record from them.
    @Test func theHoldersOwnScreenRevealsEverything() throws {
        let (credential, disclosures) = issued()
        let store = InMemoryStore()
        try store.save(jws: try sign(credential, disclosing: disclosures).serialized(),
                       id: StoredNationalID.credentialID)

        let stored = try #require(StoredNationalID.load(from: store))
        let keys = Set(stored.claims.map(\.key))

        #expect(keys.contains("unifiedNo"))
        #expect(keys.contains("birthdate"))
        #expect(keys.contains(AgePredicate.claimName))
        #expect(stored.isCardSigned)
    }
}

/// Minimal store so the holder-screen test does not touch the real one.
private final class InMemoryStore: CredentialStoring {
    private var items: [String: String] = [:]
    func save(jws: String, id: String) throws { items[id] = jws }
    func load(id: String) throws -> String? { items[id] }
    func allIDs() throws -> [String] { Array(items.keys).sorted() }
    func deleteAll() throws { items.removeAll() }
}
