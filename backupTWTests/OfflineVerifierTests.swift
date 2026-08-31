//
//  OfflineVerifierTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// The verifier is the only place in this app where a wrong answer is worse than
/// no answer: a false accept hands a stranger someone else's identity at a
/// counter, and a false reject turns a person away on the worst day of their
/// life. So every check it makes has a test that fails if that check is deleted,
/// and the fixtures are built from raw JSON rather than by calling the presenter,
/// so a defect in one module cannot be cancelled out by the same defect in the
/// other.
///
/// Two tests deliberately break that rule and go through the real presenter
/// (`readsWhatThePresentationTypeItselfEncodes` and
/// `readsAPresentationFromTheRealSigningPath`), because the failure those catch
/// is the one hand-built fixtures cannot: this verifier and
/// `VerifiablePresentation` agreeing with themselves and not with each other.
struct OfflineVerifierTests {

    // MARK: - Verified

    @Test func verifiesAPresentationMadeForThisRequest() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(by: holder, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(verified.holder == holder.did)
        #expect(verified.credentialTypes == ["VerifiableCredential", "NationalIDCredential"])
        #expect(verified.presentedAt == Fixture.presentedAt)
        #expect(verified.validFrom == Fixture.issuedAt)
        #expect(verified.validUntil == nil)
    }

    /// Hand-built fixtures prove this verifier is self-consistent. This proves it
    /// against the bytes `VerifiablePresentation`'s own `Codable` conformance
    /// emits — the field spellings, the enveloped credential, the context array.
    /// Rename a field on either side and this is the test that goes red, instead
    /// of the whole feature failing in a queue with `challengeMismatch`, which
    /// reads as "this person is replaying an old code".
    @Test func readsWhatThePresentationTypeItselfEncodes() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder)

        let presentation = VerifiablePresentation(
            context: [.url(VerifiableCredential.credentialsV2Context),
                      .definitions(VerifiablePresentation.presentationTermDefinitions)],
            type: [VerifiablePresentation.baseType],
            holder: holder.did,
            verifiableCredential: [.enveloping(compactJWS: credential)],
            challenge: request.challenge,
            audience: request.audience,
            purpose: request.purpose,
            created: VerifiableCredential.timestamp(from: Fixture.presentedAt))

        // The presenter's own encoder is private, so its options are restated
        // rather than borrowed. They are load-bearing on both sides — `sortedKeys`
        // is what makes the signed bytes reproducible — so if they ever diverge,
        // the signature check below is what notices.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header: [String: String] = ["alg": "ES256", "typ": "vp+jwt", "cty": "vp",
                                        "kid": try VerifiableCredential.verificationMethodID(for: holder.did)]
        let signingInput = Fixture.base64URL(try encoder.encode(header))
            + "." + Fixture.base64URL(try encoder.encode(presentation))
        let signature = try holder.key.signature(for: Data(signingInput.utf8))
        let jws = signingInput + "." + Fixture.base64URL(signature.rawRepresentation)

        let outcome = OfflineVerifier.verify(presentationJWS: jws, against: request, now: Fixture.presentedAt)
        #expect(outcome.isVerified, "failed with \(String(describing: outcome.failure))")
    }

    /// The whole pipeline, end to end: a credential signed by a real `DeviceKey`,
    /// presented by `VerifiablePresentation.create`, read back here. Needs a
    /// keychain, so it disables itself the way `VerifiableCredentialTests` does
    /// rather than reporting an environment problem as a defect.
    @Test(.enabled(if: OfflineVerifierTests.deviceKeyIsAvailable))
    func readsAPresentationFromTheRealSigningPath() throws {
        defer { try? DeviceKey.deleteKey(tag: Self.deviceKeyTag) }
        let key = try DeviceKey.loadOrCreate(tag: Self.deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)

        let credential = VerifiableCredential.nationalID(Fixture.model,
                                                                   issuerDID: did,
                                                                   validFrom: Fixture.issuedAt)
        let credentialJWS = try credential.jwsCompactSerialization(signedBy: key, issuerDID: did)

        let request = try Fixture.request()
        let presentation = try VerifiablePresentation.create(credentialJWS: credentialJWS,
                                                             request: request,
                                                             signedBy: key,
                                                             holderDID: did,
                                                             createdAt: Fixture.presentedAt)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        let verified = try #require(outcome.verified, "failed with \(String(describing: outcome.failure))")
        #expect(verified.holder == did)
        #expect(verified.claims.contains(DisclosedClaim(term: "unifiedNo", value: "A123456789")))
    }

    /// The DID is reported once, as `holder`. Repeating it among the disclosed
    /// fields would present a correlatable identifier as though the holder had
    /// chosen to show it as a claim.
    @Test func disclosedClaimsOmitTheDIDAndAreOrderedForReading() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(by: holder, request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(verified.claims.map(\.term) == ["name", "birthdate", "unifiedNo", "addressOfHousehold", "nationality"])
        #expect(!verified.claims.contains { $0.term == "id" })
        #expect(!verified.claims.contains { $0.value == holder.did })
    }

    /// A field this build has never heard of still has to be shown: the holder
    /// disclosed it, and understating what changed hands is the failure mode that
    /// matters here.
    @Test func showsFieldsThisBuildDoesNotKnowAbout() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            guard var subject = payload["credentialSubject"] as? [String: Any] else { return }
            subject["bloodType"] = "O"
            payload["credentialSubject"] = subject
        }
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(by: holder,
                                                                                       carrying: credential,
                                                                                       request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(verified.claims.contains(DisclosedClaim(term: "bloodType", value: "O")))
        // Known terms keep their reading order; the unknown one goes last rather
        // than being interleaved somewhere arbitrary.
        #expect(verified.claims.last == DisclosedClaim(term: "bloodType", value: "O"))
    }

    // MARK: - What a green tick does not say

    /// The requirement from the brief: a verified result must carry the fact that
    /// revocation was not checked, so the UI cannot render an unconditional tick.
    @Test func aVerifiedResultSaysRevocationWasNotChecked() throws {
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(verified.caveats.contains(.revocationNotChecked))
    }

    /// The other three a verifier could otherwise read a guarantee into: that
    /// nothing was reported anywhere, that no authority attested the contents,
    /// and that the identifier they just received is the same one this holder
    /// shows everybody.
    @Test func aVerifiedResultIsHonestAboutWhatItDoesNotProve() throws {
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(verified.caveats.contains(.noNetworkQuery))
        #expect(verified.caveats.contains(.selfIssuedByTheHolder))
        #expect(verified.caveats.contains(.identifierIsLinkable))
        #expect(verified.caveats.contains(.noExpiryAsserted))
    }

    /// The relay, which this design does not close and did not disclose.
    ///
    /// This file's own documentation had said for as long as it existed that an
    /// undetectable relay 「is what `VerificationCaveat.verifierNotAuthenticated`
    /// is for」, and no such case existed: `VerificationCaveat` had six, none of
    /// them this. So every successful check told the person doing the checking
    /// five true things about what it could not establish and stayed silent about
    /// the sixth — that the reply may have been fetched from a holder somewhere
    /// else and handed over by whoever is standing there. A false tick on the
    /// disclosure list is worse than a missing one, because the list is what a
    /// verifier reads *instead of* the cryptography.
    ///
    /// Unconditional, so this asserts on the plainest possible success: if any
    /// verified result can reach a screen without this sentence, the disclosure
    /// is back to being decorative.
    @Test func aVerifiedResultSaysTheCheckerCouldNotBeAuthenticated() throws {
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(verified.caveats.contains(.verifierNotAuthenticated))
    }

    /// Binding the presentation to a named audience does not close the relay —
    /// Mallory relays the audience too — so the sentence must survive the case a
    /// reader would most expect to suppress it.
    @Test func theRelayDisclosureSurvivesAPresentationBoundToThisVerifier() throws {
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(!verified.caveats.contains(.notBoundToThisVerifier))
        #expect(verified.caveats.contains(.verifierNotAuthenticated))
    }

    /// Every caveat has to reach a screen, so every caveat needs text. A case
    /// added without one would otherwise ship as an empty row.
    @Test func everyCaveatAndFailureHasSomethingToShowAHuman() {
        for caveat in VerificationCaveat.allCases {
            #expect(!caveat.message.isEmpty, "\(caveat) has no message")
        }
        for failure in Self.everyFailure {
            #expect(!failure.message.isEmpty, "\(failure) has no message")
            #expect(failure.errorDescription == failure.message)
        }
    }

    /// The no-expiry caveat is a statement about this credential, not a constant.
    @Test func doesNotClaimAnExpiryIsMissingWhenTheCredentialCarriesOne() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validUntil"] = VerifiableCredential.timestamp(from: Fixture.presentedAt.addingTimeInterval(3600))
        }
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(by: holder,
                                                                                       carrying: credential,
                                                                                       request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(!verified.caveats.contains(.noExpiryAsserted))
        #expect(verified.validUntil == Fixture.presentedAt.addingTimeInterval(3600))
    }

    /// A verifier with no identifier of its own — the 里長 with a spare iPad — is
    /// served, and told that the reply is not tied to them.
    @Test func noticesWhenThePresentationIsNotBoundToThisVerifier() throws {
        let holder = try Party()
        let request = try PresentationRequest.generate(purpose: Fixture.purpose, now: Fixture.presentedAt)
        #expect(request.audience == nil)

        let presentation = try Fixture.presentation(by: holder, request: request) { payload in
            payload.removeValue(forKey: "audience")
        }
        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(verified.caveats.contains(.notBoundToThisVerifier))
    }

    @Test func doesNotClaimAnUnboundPresentationWhenBothSidesNamedTheSameVerifier() throws {
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified)
        #expect(!verified.caveats.contains(.notBoundToThisVerifier))
    }

    // MARK: - Replay

    /// The defect this exists for: a presentation photographed at one counter and
    /// shown at the next one.
    @Test func rejectsAPresentationAnsweringAnotherChallenge() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)

        let somebodyElsesRequest = try Fixture.request()
        #expect(somebodyElsesRequest.challenge != request.challenge)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: somebodyElsesRequest,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .challengeMismatch)
    }

    /// **This test documents a gap rather than a guarantee.** `verify` is pure: it
    /// compares the challenge and remembers nothing, so the same presentation
    /// verifies as often as it is shown. Consuming each challenge exactly once —
    /// on failure as well as success — expiring it, and persisting the used set
    /// across a relaunch belongs to the caller that owns the pending-challenge
    /// store. If that behaviour is ever moved in here, this test is the one that
    /// has to be deleted deliberately, which is the point of it.
    @Test func verifyingTwiceDoesNotConsumeTheChallenge() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)

        let first = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        let second = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)

        #expect(first.isVerified)
        #expect(first == second)
    }

    @Test func rejectsAPresentationMadeForAnotherVerifier() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request) { payload in
            payload["audience"] = "urn:bonds-tw:verifier:somebody-else"
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .audienceMismatch)
    }

    /// The relay `PresentationRequest` names: Mallory passes a genuine challenge
    /// to the holder under a purpose of her own, then hands the reply back. The
    /// holder signed Mallory's sentence, so the verifier who minted the challenge
    /// sees a purpose that is not the one it asked for.
    @Test func rejectsAReplyWhoseHolderWasToldADifferentReason() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request) { payload in
            payload["purpose"] = "免費發放物資登記"
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .purposeMismatch)
    }

    // MARK: - Holder binding

    /// A credential file copied off somebody else's phone, presented with a
    /// signature from the thief's own key. Both signatures are genuine; the
    /// document is about the wrong person.
    @Test func rejectsACredentialAboutSomeoneOtherThanThePresenter() throws {
        let holder = try Party()
        let victim = try Party()
        let request = try Fixture.request()

        let stolen = try Fixture.credential(issuedBy: victim)
        let presentation = try Fixture.presentation(by: holder, carrying: stolen, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialNotBoundToPresenter)
    }

    /// Subject and presenter agree, but a third party signed the credential.
    /// There is no trust list to evaluate that issuer against, so it is refused
    /// rather than displayed as verified.
    @Test func rejectsACredentialIssuedByAThirdParty() throws {
        let holder = try Party()
        let authority = try Party()
        let request = try Fixture.request()

        let credential = try Fixture.credential(issuedBy: authority, about: holder.did)
        let presentation = try Fixture.presentation(by: holder, carrying: credential, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialIssuerIsNotTheSubject)
    }

    // MARK: - Signatures

    @Test func rejectsAPresentationSignedByAnotherKey() throws {
        let holder = try Party()
        let forger = try Party()
        let request = try Fixture.request()

        let presentation = try Fixture.presentation(by: holder, request: request, signedBy: forger)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationSignatureInvalid)
    }

    /// `kid` is attacker-controlled. A verifier that resolved it would check the
    /// forger's signature against the forger's key — which passes — and then
    /// display the victim's fields.
    @Test func doesNotTakeTheSigningKeyFromTheHeaderKeyID() throws {
        let victim = try Party()
        let forger = try Party()
        let request = try Fixture.request()

        let presentation = try Fixture.presentation(
            by: victim,
            request: request,
            signedBy: forger,
            headerOverrides: ["kid": try VerifiableCredential.verificationMethodID(for: forger.did)])

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationKeyIDMismatch)
    }

    /// One character of the holder's data, changed after signing.
    @Test(arguments: ["name", "birthdate", "unifiedNo", "addressOfHousehold", "nationality"])
    func rejectsATamperedCredential(field: String) throws {
        let holder = try Party()
        let request = try Fixture.request()

        let credential = try Fixture.credential(issuedBy: holder)
        let tampered = try Fixture.rewritingPayload(of: credential) { payload in
            guard var subject = payload["credentialSubject"] as? [String: Any] else { return }
            subject[field] = "改過了"
            payload["credentialSubject"] = subject
        }
        let presentation = try Fixture.presentation(by: holder, carrying: tampered, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialSignatureInvalid)
    }

    /// The presentation's own signature is fine; the credential inside is not.
    /// Checking only the outer one would accept this.
    @Test func rejectsAValidPresentationCarryingAnInvalidCredential() throws {
        let holder = try Party()
        let forger = try Party()
        let request = try Fixture.request()

        // Names the holder as issuer, signed by somebody else.
        let credential = try Fixture.credential(issuedBy: holder, signedBy: forger)
        let presentation = try Fixture.presentation(by: holder, carrying: credential, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialSignatureInvalid)
    }

    /// JOSE ES256 is a fixed-width 64-byte `r ‖ s`. Anything else — a DER blob, a
    /// truncation — must be refused rather than fed to CryptoKit.
    @Test func rejectsASignatureOfTheWrongLength() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)
        let segments = presentation.components(separatedBy: ".")
        let truncated = segments[0] + "." + segments[1] + "." + Fixture.base64URL(Data(repeating: 0x41, count: 32))

        let outcome = OfflineVerifier.verify(presentationJWS: truncated, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationSignatureInvalid)
    }

    /// `alg` is never used to *choose* an algorithm — ES256 is hardcoded — but it
    /// is refused loudly so the failure reads as "this app cannot check that"
    /// rather than as an accusation.
    @Test(arguments: ["none", "HS256", "RS256", "ES384"])
    func rejectsAlgorithmsOtherThanES256(algorithm: String) throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request, headerOverrides: ["alg": algorithm])

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .unsupportedSignatureAlgorithm(declared: algorithm))
    }

    // MARK: - Domain separation

    /// JOSE has no `proofPurpose`, so `typ` is the only thing separating a
    /// signature made to assert facts from one made to prove live possession.
    /// Without this check, anyone holding a copy of the credential file could
    /// present it as though they had answered the challenge.
    @Test func rejectsTheStoredCredentialShownInPlaceOfAPresentation() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder)

        let outcome = OfflineVerifier.verify(presentationJWS: credential, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationIsNotAPresentation(declaredType: "vc+jwt"))
    }

    @Test func rejectsAPresentationNestedWhereTheCredentialShouldBe() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let notACredential = try Fixture.credential(issuedBy: holder, headerOverrides: ["typ": "vp+jwt"])
        let presentation = try Fixture.presentation(by: holder, carrying: notACredential, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialIsNotACredential(declaredType: "vp+jwt"))
    }

    @Test func rejectsABodyThatIsNotAPresentation() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request) { payload in
            payload["type"] = ["VerifiableCredential"]
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationIsNotAPresentation(declaredType: "VerifiableCredential"))
    }

    // MARK: - Freshness

    @Test func rejectsAPresentationOlderThanTheWindow() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)
        let late = Fixture.presentedAt.addingTimeInterval(OfflineVerifier.maximumPresentationAge + 1)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: late)
        #expect(outcome.isTooOld, "got \(String(describing: outcome.failure))")
    }

    /// The other side of the boundary, so a change to the window has to be
    /// deliberate rather than a silent widening.
    @Test func acceptsAPresentationAtTheEdgeOfTheWindow() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)
        let late = Fixture.presentedAt.addingTimeInterval(OfflineVerifier.maximumPresentationAge)

        #expect(OfflineVerifier.verify(presentationJWS: presentation, against: request, now: late).isVerified)
    }

    /// A presentation dated ahead of us can only be clock error, and the message
    /// has to say so rather than accuse anyone.
    @Test func rejectsAPresentationDatedBeyondTheClockSkew() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)
        let early = Fixture.presentedAt.addingTimeInterval(-(OfflineVerifier.maximumClockSkew + 1))

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: early)
        #expect(outcome.isFromTheFuture, "got \(String(describing: outcome.failure))")
    }

    /// A phone that was dead through an earthquake comes back with a drifted
    /// clock. Refusing it would fail exactly the person this app is for.
    @Test func toleratesASmallClockDifference() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)
        let early = Fixture.presentedAt.addingTimeInterval(-OfflineVerifier.maximumClockSkew)

        #expect(OfflineVerifier.verify(presentationJWS: presentation, against: request, now: early).isVerified)
    }

    @Test func rejectsAPresentationWithNoTimestamp() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request) { payload in
            payload.removeValue(forKey: "created")
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationTimestampUnreadable)
    }

    /// Accepted although this app never writes them: refusing a timestamp for
    /// being *more* precise would be a compatibility failure dressed up as a
    /// validity failure.
    @Test func acceptsATimestampWithFractionalSeconds() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request) { payload in
            payload["created"] = "2025-08-05T14:20:00.250Z"
        }

        #expect(OfflineVerifier.verify(presentationJWS: presentation,
                                       against: request,
                                       now: Fixture.presentedAt).isVerified)
    }

    // MARK: - Credential validity

    @Test func rejectsACredentialThatIsNotValidYet() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validFrom"] = VerifiableCredential.timestamp(from: Fixture.presentedAt.addingTimeInterval(3600))
        }

        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(by: holder,
                                                                                       carrying: credential,
                                                                                       request: request),
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialNotYetValid)
    }

    /// This app issues no `validUntil`, so nothing produces this today. Ignoring
    /// one that a stricter issuer does include would make this a verifier that
    /// accepts expired documents.
    @Test func rejectsAnExpiredCredential() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validUntil"] = VerifiableCredential.timestamp(from: Fixture.presentedAt.addingTimeInterval(-3600))
        }

        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(by: holder,
                                                                                       carrying: credential,
                                                                                       request: request),
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialExpired)
    }

    @Test func rejectsACredentialWhoseValidityCannotBeRead() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validFrom"] = "民國114年8月5日"
        }

        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(by: holder,
                                                                                       carrying: credential,
                                                                                       request: request),
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialValidityUnreadable)
    }

    // MARK: - The envelope

    @Test func rejectsAPresentationCarryingNoCredential() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request) { payload in
            payload.removeValue(forKey: "verifiableCredential")
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialMissing)
    }

    /// The mistake VC 2.0 §4.12 exists to prevent: a compact JWS dropped into the
    /// array as a bare string. It still verifies as JOSE and the credential
    /// disappears on expansion, so it has to be refused here.
    @Test func rejectsABareCredentialStringInPlaceOfAnEnvelope() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder)
        let presentation = try Fixture.presentation(by: holder, carrying: credential, request: request) { payload in
            payload["verifiableCredential"] = [credential]
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialNotEnveloped)
    }

    /// The seam left for ZK selective disclosure. When a proof arrives in this
    /// envelope it must be refused legibly rather than handed to a JWS parser and
    /// reported as a malformed credential.
    @Test func rejectsAnEnvelopeCarryingSomeOtherMediaType() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(by: holder, request: request) { payload in
            payload["verifiableCredential"] = [["@context": VerifiableCredential.credentialsV2Context,
                                                "id": "data:application/zk-sd+cbor,gaNoZWxsbw",
                                                "type": "EnvelopedVerifiableCredential"]]
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialNotEnveloped)
    }

    /// Verifying the first and showing it as "the" document would silently ignore
    /// whatever else the holder handed over.
    @Test func rejectsAPresentationCarryingMoreThanOneCredential() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder)
        let envelope: [String: Any] = ["@context": VerifiableCredential.credentialsV2Context,
                                       "id": EnvelopedVerifiableCredential.compactJWSPrefix + credential,
                                       "type": "EnvelopedVerifiableCredential"]
        let presentation = try Fixture.presentation(by: holder, carrying: credential, request: request) { payload in
            payload["verifiableCredential"] = [envelope, envelope]
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationCarriesMultipleCredentials(count: 2))
    }

    // MARK: - Where the signed fields live

    /// The header is as signed as the body, and is where a value is safe from
    /// JSON-LD expansion dropping it. A presenter that puts it there is read
    /// correctly rather than reported as a replay.
    @Test func readsSignedFieldsFromTheProtectedHeader() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(
            request: request,
            headerOverrides: ["challenge": request.challenge,
                              "created": VerifiableCredential.timestamp(from: Fixture.presentedAt)]) { payload in
            payload.removeValue(forKey: "challenge")
            payload.removeValue(forKey: "created")
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.isVerified, "failed with \(String(describing: outcome.failure))")
    }

    /// Both copies are signed, so this is a confused presenter rather than
    /// tampering — but resolving it by preferring one would let a document show
    /// one challenge to a JOSE reader and another to a JSON-LD one.
    @Test func rejectsAFieldThatDisagreesWithItsCopyInTheHeader() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request,
                                                    headerOverrides: ["challenge": "a-completely-different-value"])

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationFieldsDisagree(field: "challenge"))
    }

    // MARK: - Malformed input

    /// None of these may crash, and none may verify. The input arrives from a
    /// stranger's screen via a camera, so "we never generate that" is not a
    /// reason it cannot appear.
    @Test(arguments: [
        "",
        ".",
        "..",
        "...",
        "a.b",
        "a.b.c.d",
        "🎏.🎏.🎏",
        "e30.e30.e30",                                          // {} in all three segments
        "eyJhbGciOiJFUzI1NiJ9.e30",                             // two segments
        "eyJhbGciOiJFUzI1NiIsInR5cCI6InZwK2p3dCJ9.W10.AAAA",    // body is a JSON array
        "eyJhbGciOiJFUzI1NiIsInR5cCI6InZwK2p3dCJ9.IiI.AAAA",    // body is a JSON string
        "e30.e30.e30\u{0}",
    ])
    func rejectsMalformedInputWithoutCrashing(input: String) throws {
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: input, against: request, now: Fixture.presentedAt)
        #expect(!outcome.isVerified)
        #expect(outcome.failure != nil)
    }

    /// Base conversion on an unbounded string is how a scanned QR becomes a hang.
    /// Nothing here should take measurable time.
    @Test func rejectsAVeryLongInputPromptly() throws {
        let request = try Fixture.request()
        let padding = String(repeating: "A", count: 200_000)
        for input in [padding, padding + "." + padding + "." + padding] {
            #expect(!OfflineVerifier.verify(presentationJWS: input, against: request, now: Fixture.presentedAt).isVerified)
        }
    }

    /// A scanner or a pasteboard adding a newline must not produce an
    /// unexplainable refusal at the counter.
    @Test func toleratesSurroundingWhitespace() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)

        for padded in ["\n" + presentation, presentation + "\n", "  " + presentation + " \r\n"] {
            #expect(OfflineVerifier.verify(presentationJWS: padded, against: request, now: Fixture.presentedAt).isVerified)
        }
    }

    /// base64url has no `+`, `/` or `=`. Accepting the standard alphabet would
    /// carry a mangled serialization far enough to fail as "signature invalid",
    /// which is the least informative refusal available.
    @Test func rejectsStandardBase64InPlaceOfBase64URL() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)
        let segments = presentation.components(separatedBy: ".")
        let padded = segments[0] + "." + segments[1] + "." + segments[2] + "=="

        let outcome = OfflineVerifier.verify(presentationJWS: padded, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationIsNotAJWS)
    }

    /// A holder identifier that is not a resolvable `did:key` is a different
    /// failure from a bad signature, and the person at the counter is owed the
    /// difference.
    @Test(arguments: ["", "did:web:example.gov", "did:key:", "did:key:zNOTAKEY", "did:key:mAQID"])
    func rejectsAnUnusableHolderIdentifier(did: String) throws {
        let holder = try Party()
        let request = try Fixture.request()
        // `kid` is dropped so the key-ID check does not fire first and report the
        // wrong reason.
        let presentation = try Fixture.presentation(by: holder,
                                                    request: request,
                                                    removingHeaderFields: ["kid"]) { payload in
            payload["holder"] = did
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .holderIdentifierUnusable || outcome.failure == .presentationUnreadable,
                "got \(String(describing: outcome.failure)) for \(did)")
    }

    /// A credential this build cannot model is not a forged one. The signature is
    /// checked first, and the refusal says "fields this app does not understand"
    /// rather than making an accusation.
    @Test func separatesAnUnreadableCredentialFromAForgedOne() throws {
        let holder = try Party()
        let request = try Fixture.request()
        // `credentialSubject` is `[String: String]` in this build, so a nested
        // object is well-formed JSON that `VerifiableCredential` cannot decode.
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            guard var subject = payload["credentialSubject"] as? [String: Any] else { return }
            subject["addressOfHousehold"] = ["city": "臺北市"]
            payload["credentialSubject"] = subject
        }
        let presentation = try Fixture.presentation(by: holder, carrying: credential, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialUnreadable)
    }

    // MARK: - Fixtures

    private static let deviceKeyTag = "tw.bonds.backupTW.tests.offlineVerifier"

    /// Signing through `DeviceKey` needs a real keychain, and a Secure Enclave is
    /// simply absent on some simulators. Both are environment problems rather
    /// than defects, so the one test that needs it disables itself instead of
    /// reporting red.
    static let deviceKeyIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.offlineVerifier.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag)) != nil
    }()

    /// Every case, so `everyCaveatAndFailureHasSomethingToShowAHuman` fails when
    /// one is added without text. `VerificationFailure` cannot be `CaseIterable`
    /// — several cases carry associated values — so the list is written out, and
    /// the `switch` in `message` is what makes forgetting to add one here
    /// survivable: the compiler catches the missing message, this catches the
    /// empty one.
    /// Every `VerificationFailure`, built by walking a chain the compiler checks.
    ///
    /// This used to be a hand-written array, and it rotted exactly the way a
    /// hand-written array does: four cases were added for card-signed
    /// credentials and none of them reached this list, so the test above — the
    /// one that guarantees every failure has something to say to a human — went
    /// on passing while covering none of them. A test that cannot fail for the
    /// thing you just added is worse than no test, because the green tick is
    /// read as coverage.
    ///
    /// `VerificationFailure` has associated values, so it cannot be
    /// `CaseIterable`. What replaces that is the switch below: it must be
    /// exhaustive to compile, and each arm names the next case, so adding a case
    /// without threading it into the chain is a build error rather than a
    /// quietly narrower test.
    private static var everyFailure: [VerificationFailure] {
        var all: [VerificationFailure] = []
        var current: VerificationFailure? = .presentationIsNotAJWS
        while let failure = current {
            all.append(failure)
            current = next(after: failure)
        }
        return all
    }

    private static func next(after failure: VerificationFailure) -> VerificationFailure? {
        switch failure {
        case .presentationIsNotAJWS: return .presentationUnreadable
        case .presentationUnreadable: return .presentationFieldsDisagree(field: "challenge")
        case .presentationFieldsDisagree: return .presentationFieldIsNotText(field: "challenge")
        case .presentationFieldIsNotText: return .presentationIsNotAPresentation(declaredType: "vc+jwt")
        case .presentationIsNotAPresentation: return .unsupportedSignatureAlgorithm(declared: "none")
        case .unsupportedSignatureAlgorithm: return .holderIdentifierUnusable
        case .holderIdentifierUnusable: return .presentationKeyIDMismatch
        case .presentationKeyIDMismatch: return .presentationSignatureInvalid
        case .presentationSignatureInvalid: return .credentialMissing
        case .credentialMissing: return .presentationCarriesMultipleCredentials(count: 2)
        case .presentationCarriesMultipleCredentials: return .credentialNotEnveloped
        case .credentialNotEnveloped: return .credentialIsNotAJWS
        case .credentialIsNotAJWS: return .credentialIsNotACredential(declaredType: "vp+jwt")
        case .credentialIsNotACredential: return .issuerIdentifierUnusable
        case .issuerIdentifierUnusable: return .credentialKeyIDMismatch
        case .credentialKeyIDMismatch: return .credentialSignatureInvalid
        case .credentialSignatureInvalid: return .credentialUnreadable
        case .credentialUnreadable: return .credentialNotBoundToPresenter
        case .credentialNotBoundToPresenter: return .credentialIssuerIsNotTheSubject
        case .credentialIssuerIsNotTheSubject: return .challengeMismatch
        case .challengeMismatch: return .purposeMismatch
        case .purposeMismatch: return .audienceMismatch
        case .audienceMismatch: return .presentationTimestampUnreadable
        case .presentationTimestampUnreadable: return .presentationTooOld(age: 600)
        case .presentationTooOld: return .presentationDatedInTheFuture(skew: 600)
        case .presentationDatedInTheFuture: return .credentialValidityUnreadable
        case .credentialValidityUnreadable: return .credentialNotYetValid
        case .credentialNotYetValid: return .credentialExpired
        case .credentialExpired: return .cardSignatureInvalid
        case .cardSignatureInvalid: return .cardholderIsNotTheSubject
        case .cardholderIsNotTheSubject: return .cardholderCertificateUnusable
        case .cardholderCertificateUnusable: return .cardholderCertificateRevoked
        case .cardholderCertificateRevoked: return .trustAnchorUnavailable
        case .trustAnchorUnavailable:
            return .deviceClockPrecedesCertificate(validFrom: Date(timeIntervalSince1970: 1_654_560_000))
        case .deviceClockPrecedesCertificate: return nil
        }
    }
}

// MARK: - When revocation gets asked about
//
// Here rather than in `RevocationVerificationTests` because it needs `Fixture`,
// which is file-private on purpose. What that file covers is the decision a
// revocation answer produces; what this covers is whether the question is put at
// all — and to whom.

struct RevocationLookupOrderTests {

    /// Records every serial it is asked about, so a test can assert on the
    /// questions that were *not* asked.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        private let answer: RevocationStatus

        init(answering answer: RevocationStatus) { self.answer = answer }

        var questions: [String] {
            lock.lock(); defer { lock.unlock() }
            return asked
        }

        var lookup: RevocationLookup {
            RevocationLookup { [self] serial in
                lock.lock(); asked.append(serial); lock.unlock()
                return answer
            }
        }
    }

    private static let revoked = RevocationStatus.revoked(
        snapshot: RevocationSnapshotInfo(root: "0xa2ed", crlNumber: 2_026_050_323, entryCount: 1))

    /// A device-signed credential has no certificate, so there is nothing whose
    /// revocation anyone could look up. The lookup must not be consulted with
    /// some substitute identifier — and the answer must be `noCertificateToCheck`
    /// rather than a silent pass.
    @Test func aDeviceSignedCredentialAsksNobodyAnything() throws {
        let spy = Spy(answering: Self.revoked)
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt,
                                             revocation: spy.lookup)

        // The spy answers `revoked`, so anything that consulted it would have
        // been refused. Passing is the assertion.
        let verified = try #require(outcome.verified)
        #expect(spy.questions.isEmpty, "a device-signed credential has no certificate to look up")
        #expect(verified.revocation == .notChecked(reason: .noCertificateToCheck))
        #expect(verified.caveats.contains(.revocationNotChecked))
        #expect(!verified.caveats.contains(.revocationCheckedInLocalSnapshotOnly))
    }

    /// The ordering property. A serial read off a certificate whose signature has
    /// not been checked is a serial the *presenter* chose, and looking it up
    /// would answer a question about a document this verifier has not yet agreed
    /// is genuine.
    @Test func nothingIsLookedUpForAPresentationThatFailsItsChecks() throws {
        let spy = Spy(answering: Self.revoked)
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request, signedBy: try Party())

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt,
                                             revocation: spy.lookup)

        #expect(outcome.failure == .presentationSignatureInvalid)
        #expect(spy.questions.isEmpty, "a serial was looked up for a presentation that never verified")
    }

    /// The default has to be the honest one: a verifier built without a snapshot
    /// reports that nothing was checked rather than skipping the step in silence.
    @Test func aVerifierWithNoSnapshotSaysSoRatherThanSayingNothing() throws {
        let request = try Fixture.request()
        let verified = try #require(OfflineVerifier.verify(
            presentationJWS: try Fixture.presentation(request: request),
            against: request,
            now: Fixture.presentedAt).verified)

        #expect(verified.caveats.contains(.revocationNotChecked))
    }
}

// MARK: - Test doubles

/// One participant: a P-256 key and the DID it derives to.
///
/// CryptoKit rather than `DeviceKey` because the verifier only ever sees public
/// keys and signatures, and a fixture that needed a keychain would make every
/// test here skippable on the machines where they matter most.
private struct Party {
    let key: P256.Signing.PrivateKey
    let did: String

    init() throws {
        key = P256.Signing.PrivateKey()
        did = try DIDKey.did(fromP256PublicKeyX963: key.publicKey.x963Representation)
    }
}

/// Builds presentations from raw JSON.
///
/// Deliberately not built by calling `VerifiablePresentation.create`: a fixture
/// that shares the presenter's code cannot catch the two of them agreeing on a
/// wrong shape, and — more practically — most of these tests need to produce
/// documents the presenter would refuse to make.
private enum Fixture {

    static let issuedAt = Date(timeIntervalSince1970: 1_754_400_000)
    static let presentedAt = issuedAt.addingTimeInterval(3600)
    static let purpose = "里長辦公室核對受災戶身分"
    static let audience = "urn:bonds-tw:verifier:9f3a1c"

    static let model = NationalIDModel(nationality: "中華民國（臺灣）",
                                       unifiedNo: "A123456789",
                                       name: "王小明",
                                       birthdate: "0700101",
                                       addressOfHousehold: "臺北市中正區重慶南路一段122號")

    static func request() throws -> PresentationRequest {
        try PresentationRequest.generate(purpose: purpose, audience: audience, now: presentedAt)
    }

    // MARK: Credential

    /// The header is adjusted with plain values and the body with a closure, so
    /// that the body closure is the only function-typed parameter and a trailing
    /// closure at a call site binds to it unambiguously.
    static func credential(issuedBy issuer: Party,
                           about subject: String? = nil,
                           signedBy signer: Party? = nil,
                           headerOverrides: [String: Any] = [:],
                           removingHeaderFields: [String] = [],
                           _ mutateBody: (inout [String: Any]) -> Void = { _ in }) throws -> String {
        var payload: [String: Any] = [
            "@context": [VerifiableCredential.credentialsV2Context,
                         ["@protected": true,
                          "NationalIDCredential": VerifiableCredential.termNamespace + "NationalIDCredential",
                          "nationality": VerifiableCredential.termNamespace + "nationality",
                          "unifiedNo": VerifiableCredential.termNamespace + "unifiedNo",
                          "birthdate": VerifiableCredential.termNamespace + "birthdate",
                          "addressOfHousehold": VerifiableCredential.termNamespace + "addressOfHousehold"]],
            "type": ["VerifiableCredential", "NationalIDCredential"],
            "issuer": issuer.did,
            "validFrom": VerifiableCredential.timestamp(from: issuedAt),
            "credentialSubject": ["id": subject ?? issuer.did,
                                  "nationality": "中華民國（臺灣）",
                                  "unifiedNo": "A123456789",
                                  "name": "王小明",
                                  "birthdate": "0700101",
                                  "addressOfHousehold": "臺北市中正區重慶南路一段122號"],
        ]
        mutateBody(&payload)

        var header: [String: Any] = ["alg": "ES256",
                                     "typ": "vc+jwt",
                                     "cty": "vc",
                                     "kid": try VerifiableCredential.verificationMethodID(for: issuer.did)]
        for (field, value) in headerOverrides { header[field] = value }
        for field in removingHeaderFields { header.removeValue(forKey: field) }

        return try jws(header: header, payload: payload, signedBy: (signer ?? issuer).key)
    }

    // MARK: Presentation

    static func presentation(by holder: Party? = nil,
                             carrying credentialJWS: String? = nil,
                             request: PresentationRequest,
                             created: Date = presentedAt,
                             signedBy signer: Party? = nil,
                             headerOverrides: [String: Any] = [:],
                             removingHeaderFields: [String] = [],
                             _ mutateBody: (inout [String: Any]) -> Void = { _ in }) throws -> String {
        let holder = try holder ?? Party()
        let credentialJWS = try credentialJWS ?? credential(issuedBy: holder)

        var payload: [String: Any] = [
            "@context": [VerifiableCredential.credentialsV2Context,
                         ["@protected": true,
                          "challenge": VerifiableCredential.termNamespace + "challenge",
                          "audience": VerifiableCredential.termNamespace + "audience",
                          "purpose": VerifiableCredential.termNamespace + "purpose",
                          "created": VerifiableCredential.termNamespace + "created"]],
            "type": [VerifiablePresentation.baseType],
            "holder": holder.did,
            "verifiableCredential": [["@context": VerifiableCredential.credentialsV2Context,
                                      "id": EnvelopedVerifiableCredential.compactJWSPrefix + credentialJWS,
                                      "type": EnvelopedVerifiableCredential.typeName]],
            "challenge": request.challenge,
            "purpose": request.purpose,
            "created": VerifiableCredential.timestamp(from: created),
        ]
        if let audience = request.audience { payload["audience"] = audience }
        mutateBody(&payload)

        var header: [String: Any] = ["alg": "ES256",
                                     "typ": "vp+jwt",
                                     "cty": "vp",
                                     "kid": try VerifiableCredential.verificationMethodID(for: holder.did)]
        for (field, value) in headerOverrides { header[field] = value }
        for field in removingHeaderFields { header.removeValue(forKey: field) }

        return try jws(header: header, payload: payload, signedBy: (signer ?? holder).key)
    }

    // MARK: JOSE

    /// Rewrites a signed payload and keeps the original signature — how a
    /// tampered document is made.
    static func rewritingPayload(of jws: String,
                                 _ mutate: (inout [String: Any]) -> Void) throws -> String {
        let segments = jws.components(separatedBy: ".")
        let payloadData = try #require(base64URLDecoded(segments[1]))
        var payload = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        mutate(&payload)
        let rewritten = try JSONSerialization.data(withJSONObject: payload,
                                                   options: [.sortedKeys, .withoutEscapingSlashes])
        return segments[0] + "." + base64URL(rewritten) + "." + segments[2]
    }

    static func jws(header: [String: Any],
                    payload: [String: Any],
                    signedBy key: P256.Signing.PrivateKey) throws -> String {
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        let signingInput = base64URL(headerData) + "." + base64URL(payloadData)
        // `signature(for:)` on a `DataProtocol` hashes the message itself, which
        // is what `DeviceKey` does with `.ecdsaSignatureMessageX962SHA256`.
        // Pre-hashing here would produce signatures the real signer never makes.
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    /// Written out rather than borrowed from the production helpers: a test that
    /// checks an encoder against its own inverse passes on any self-consistent
    /// alphabet, including a wrong one.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecoded(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}

private extension VerificationOutcome {

    /// `VerificationFailure` is `Equatable`, but these two carry a measured
    /// interval, and pinning an exact `TimeInterval` would make a test fail for a
    /// reason unrelated to the behaviour it names.
    var isTooOld: Bool {
        if case .rejected(.presentationTooOld) = self { return true }
        return false
    }

    var isFromTheFuture: Bool {
        if case .rejected(.presentationDatedInTheFuture) = self { return true }
        return false
    }
}

// MARK: - No phone home

/// Records every request the URL loading system is asked to handle, and handles
/// none of them.
///
/// ⚠️ What this can and cannot see, measured rather than assumed: a globally
/// registered `URLProtocol` is consulted for `URLSession.shared` and **not** for
/// a session built from its own `URLSessionConfiguration`. So this catches the
/// realistic regression — somebody adding a revocation lookup or a DID resolve
/// with `URLSession.shared` — and would miss a verifier that constructed its own
/// session. `theVerifierSourceNamesNoNetworkingAPI` is what covers that gap, and
/// the two are only meaningful together.
///
/// The same measurement is why this does not flake: the other suites in this
/// bundle that do network work (`TWFidOClientTests`, `CircuitAssetsTests`) both
/// use sessions with their own `protocolClasses`, so their traffic is invisible
/// here even when they run in parallel.
private final class NetworkCanary: URLProtocol {

    private static let lock = NSLock()
    private static var observed: [String] = []

    static func reset() {
        lock.lock()
        observed = []
        lock.unlock()
    }

    static var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        observed.append(request.url?.absoluteString ?? "(no url)")
        lock.unlock()
        // Recorded, never handled: returning true would make this canary the
        // network stack for the whole bundle.
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Whitepaper §5.2's 「不打電話回家」 is invisible from the outside — a verifier
/// that phones home still verifies correctly — so it needs its own tests.
///
/// Serialized because the canary is a process-wide registration and these two
/// tests share it.
@Suite(.serialized)
struct OfflineVerifierNetworkTests {

    /// Proves the instrument works. Without this, `verifyingMakesNoNetworkRequest`
    /// would pass just as happily against a canary that observes nothing at all,
    /// which is the most comfortable kind of broken test.
    @Test func theCanaryObservesRequestsThatAreActuallyMade() async {
        NetworkCanary.reset()
        URLProtocol.registerClass(NetworkCanary.self)
        defer { URLProtocol.unregisterClass(NetworkCanary.self) }

        // Discard port on loopback: refused immediately, never leaves the device,
        // and `canInit` fires before any connection is attempted — so this is not
        // a network test even on a runner with no network.
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:9/canary")!)
        probe.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: probe)

        #expect(!NetworkCanary.requests.isEmpty,
                "the canary saw nothing, so it cannot prove anything about the verifier")
    }

    @Test func verifyingMakesNoNetworkRequest() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let accepted = try Fixture.presentation(by: holder, request: request)
        // A DID that a resolver would have to fetch, and a signature that fails:
        // both are paths where a "let me just check" call is tempting.
        let rejected = try Fixture.presentation(by: holder, request: request, signedBy: try Party())
        let unresolvable = try Fixture.presentation(by: holder,
                                                    request: request,
                                                    removingHeaderFields: ["kid"]) { payload in
            payload["holder"] = "did:web:mydata.nat.gov.tw"
        }

        NetworkCanary.reset()
        URLProtocol.registerClass(NetworkCanary.self)
        defer { URLProtocol.unregisterClass(NetworkCanary.self) }

        for presentation in [accepted, rejected, unresolvable] {
            _ = OfflineVerifier.verify(presentationJWS: presentation, against: request, now: Fixture.presentedAt)
        }

        #expect(NetworkCanary.requests.isEmpty,
                "verification reached the network: \(NetworkCanary.requests)")
    }

    /// The structural half. Reads the verifier's own source, because the canary
    /// only sees `URLSession.shared` and the property being defended is stronger
    /// than that: *nothing* in this file may reach the network by any route.
    @Test func theVerifierSourceNamesNoNetworkingAPI() throws {
        let source = try Self.verifierSource()

        // Not an exhaustive list of ways to open a socket — it cannot be. It is
        // the list of things somebody would plausibly reach for while adding a
        // revocation check or a DID resolution, which is the regression that
        // would actually happen.
        for symbol in ["URLSession", "URLRequest", "URLConnection", "NSURLConnection",
                       "NWConnection", "NWPathMonitor", "CFStream", "CFSocket",
                       "getaddrinfo", "dataTask", "downloadTask", "https://bonds.tw/api"] {
            #expect(!source.contains(symbol), "OfflineVerifier.swift mentions \(symbol)")
        }

        for module in ["import Network", "import CFNetwork", "import SystemConfiguration"] {
            #expect(!source.contains(module), "OfflineVerifier.swift has \(module)")
        }
    }

    /// Located from this test file rather than from the bundle: the source is not
    /// a build product, so there is nowhere else to get it. A moved or renamed
    /// file throws here instead of quietly reporting a pass over an empty string.
    /// # The same question, asked of every file instead of one
    ///
    /// `theVerifierSourceNamesNoNetworkingAPI` reads one hard-coded path, so it
    /// silently skips **every file written after it** — and `NetworkCanary`
    /// cannot cover the gap, because a `URLProtocol` only sees sessions that
    /// registered it and all four of this app's real network call sites build
    /// their own `URLSessionConfiguration`. Source scanning is the only
    /// mechanism that actually holds.
    ///
    /// So this walks `backupTW/` and requires every file that can open a socket
    /// to be on a list somebody wrote down. The list is **matched by exact
    /// path**, not by substring: `contains("CircuitAssets")` would also permit a
    /// future `CircuitAssetsPrefetcher.swift` that nobody agreed to.
    ///
    /// Adding a file here is meant to be uncomfortable. This app's claim is that
    /// checking somebody's document reaches nothing, and each new entry is one
    /// more place that claim depends on a reviewer having been careful.
    @Test func onlyTheNamedFilesCanReachTheNetwork() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backupTW")

        let mayOpenASocket: Set<String> = [
            // Downloads ~2 GB of circuit material, on an explicit tap.
            "ZK/CircuitAssets.swift",
            // Builds the signer that talks to TW FidO.
            "ZK/ZKProofRunWiring.swift",
            // The TW FidO client itself.
            "TWFidO/TWFidOClient.swift",
            // Issuance: the MyData round trip.
            "Model/CredentialIssuance.swift",
            // The MyData web view. A browser is a network client by definition.
            "ViewController/MyDataWebViewController.swift",
            // The Lennon Wall. **The first entry added after this list existed,
            // and the first one that publishes rather than fetches** — every
            // other line here downloads something the holder asked for; this one
            // puts a signature on a public page.
            //
            // It earned its place the intended way: the scan failed on the
            // commit that introduced the file, and adding it was a deliberate
            // act rather than something that slipped in behind a green suite.
            "Wall/WallConfiguration.swift",
            // OID4VCI collection: the TWDIW round trip, on an explicit deep
            // link the holder opened. Nothing here runs while a document is
            // being checked, and every URL it contacts passed
            // `IssuerAuthorization`'s gates before the first request left.
            "TWDIW/OID4VCICollection.swift",
            // The trust list those gates compare against, fetched from the
            // registry at collection time. Also caught by this scan on the
            // commit that introduced it, which is the list working.
            "TWDIW/TrustListFetcher.swift",
            // The trust screen independently checks each API entry's claimed
            // registry transaction against Arbitrum. It runs only when the
            // holder opens Settings › Trust, never during offline checking.
            "TWDIW/TWDIWOnChainVerifier.swift",
            // OID4VP presentation: posts the signed vp_token back to the
            // verifier's response_uri, on an explicit user action, only after
            // the request object's signature and its response_uri host both
            // passed. Nothing here runs while a document is being checked.
            "TWDIW/OID4VPResponse.swift",
            // OID4VP request fetch: GETs the verifier's request object from a
            // scanned request_uri, on an explicit scan, after the request_uri
            // host passed the trust gate. Fetches a signed ask, publishes
            // nothing.
            "TWDIW/OID4VPRequestFetcher.swift",
            // Static card-application resolve: GETs the 201i endpoint on
            // `frontend.wallet.gov.tw` to turn a scanned 「要申請的卡」 QR into the
            // issuer page URL, on an explicit scan. Fetches which card is being
            // applied for; publishes nothing, mints nothing. The deep link the
            // resolved page later returns still passes `IssuerAuthorization`'s
            // gates before a credential is issued. Caught by this scan on the
            // commit that introduced it — the list working.
            "TWDIW/ModaServiceURLResolver.swift",
            // The 「申請新卡」 catalogue fetch: GETs the apply/vcList endpoint on
            // `frontend.wallet.gov.tw` to list which telecom 門號電子卡 a holder can
            // start, on an explicit tap. Fetches which cards exist; publishes
            // nothing, mints nothing. The carrier's own app later returns the
            // `modadigitalwallet://credential_offer` deep link, which still passes
            // `IssuerAuthorization`'s gates. Nothing here runs while a document is
            // being checked. Caught by this scan on the commit that introduced it —
            // the list working.
            "TWDIW/TelecomCardCatalog.swift",
            // The embedded issuer web view where a holder finishes an application
            // the card cannot hand over up front (電信卡 verifies the line, 駕照驗證卡
            // logs in to 監理服務網). A browser is a network client by definition,
            // like `MyDataWebViewController`. Nothing it shows or returns is
            // trusted to issue: the `modadigitalwallet://credential_offer` deep
            // link it hands back goes through the same gates as a scanned offer.
            "ViewController/WebCollectViewController.swift",
        ]

        // The same list as the single-file test, plus `import Network`. Not
        // exhaustive — it cannot be — but it is what somebody reaches for while
        // adding "just one check".
        let symbols = ["URLSession", "URLRequest", "NSURLConnection", "NWConnection",
                       "NWPathMonitor", "CFStream", "CFSocket", "getaddrinfo",
                       "dataTask", "downloadTask", "WKWebView", "import Network"]

        let enumerator = FileManager.default.enumerator(at: root,
                                                        includingPropertiesForKeys: nil)
        var scanned = 0
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !mayOpenASocket.contains(relative) else { continue }
            scanned += 1
            let source = Self.codeOnly(String(decoding: try Data(contentsOf: url), as: UTF8.self))
            if let found = symbols.first(where: { source.contains($0) }) {
                offenders.append("\(relative) mentions \(found)")
            }
        }

        // Without this the test passes loudly while walking an empty directory,
        // which is exactly how a path-based check dies.
        #expect(scanned > 40, "only \(scanned) files scanned — the walk is not finding the source")
        #expect(offenders.isEmpty,
                "files reached the network without being on the list:\n\(offenders.joined(separator: "\n"))")
    }

    /// Every entry on the allowlist must still exist.
    ///
    /// A renamed file would leave a stale entry that permits nothing and hides
    /// nothing — harmless — but it would also mean the *new* name is being
    /// scanned, which is the good outcome arrived at by luck. Better to be told.
    @Test func theAllowlistHasNoStaleEntries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("backupTW")
        for relative in ["ZK/CircuitAssets.swift", "ZK/ZKProofRunWiring.swift",
                         "TWFidO/TWFidOClient.swift", "Model/CredentialIssuance.swift",
                         "ViewController/MyDataWebViewController.swift",
                         "Wall/WallConfiguration.swift"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path),
                    "the allowlist names \(relative), which no longer exists")
        }
    }

    /// Strips comments, because prose about an API is not a use of it.
    ///
    /// The first run of this scan failed on `ZKProofViewController.swift`, which
    /// mentions `URLSession` **in a doc comment** explaining what
    /// `TWFidOClient` does with one. The file opens no sockets.
    ///
    /// This is the third time in this project a check has been broken by text
    /// describing it — the Worker's 「exactly one `.bind('citizen')`」 invariant
    /// did it twice, both times because the sentence asserting the property
    /// contained the string the property was about. The lesson each time is the
    /// same: **a check that reads source has to read code, or it forbids
    /// explaining itself.** A codebase whose comments carry the reasoning would
    /// be forced to stop carrying it.
    ///
    /// Whole-line comments only, which is what this codebase writes. A trailing
    /// comment on a line of code still trips the scan, and that is the right way
    /// round for a canary: a false positive costs a sentence being reworded, a
    /// false negative costs the property this app is built on.
    private static func codeOnly(_ source: String) -> String {
        var kept: [Substring] = []
        var inBlockComment = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private static func verifierSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)   // …/backupTWTests/OfflineVerifierTests.swift
            .deletingLastPathComponent()             // …/backupTWTests
            .deletingLastPathComponent()             // …/
            .appendingPathComponent("backupTW/Presentation/OfflineVerifier.swift")
        let data = try Data(contentsOf: url)
        let source = String(decoding: data, as: UTF8.self)
        // Guards against reading something that is not the file we meant.
        try #require(source.contains("enum OfflineVerifier"), "did not find the verifier at \(url.path)")
        return source
    }
}

/// The defect underneath one of the defects: a disclosure that existed only in
/// prose.
///
/// `OfflineVerifier`'s own documentation had said, for as long as it existed, that
/// an undetectable relay 「is what `VerificationCaveat.verifierNotAuthenticated` is
/// for」 — and no such case existed. The enum had six, none of them that one. So
/// the file read like a design that had thought about relays and disclosed the
/// limit, while every verified result on every screen stayed silent about it.
///
/// A comment naming a case reads to the next person exactly like a commitment
/// that the case is emitted and drawn. Nothing in a compiler checks a sentence, so
/// this does: the same instrument `OfflineVerifierNetworkTests` uses to read the
/// verifier's source, pointed at whether its documentation is telling the truth.
struct OfflineVerifierDisclosureTests {

    @Test func everyCaveatNamedInTheVerifiersDocumentationExists() throws {
        let source = try Self.verifierSource()
        let real = Set(VerificationCaveat.allCases.map { String(describing: $0) })

        var named: Set<String> = []
        for reference in source.components(separatedBy: "VerificationCaveat.").dropFirst() {
            let name = String(reference.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            if !name.isEmpty { named.insert(name) }
        }

        #expect(!named.isEmpty, "no `VerificationCaveat.…` references found, so this test proves nothing")
        for name in named.sorted() {
            #expect(real.contains(name),
                    "OfflineVerifier.swift documents VerificationCaveat.\(name), which does not exist")
        }
    }

    /// Read from the checkout rather than the bundle, for the reason
    /// `OfflineVerifierNetworkTests` gives: source is not a build product. Kept
    /// separate from that suite's copy so neither test file's rearrangement can
    /// silently disarm the other.
    private static func verifierSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backupTW/Presentation/OfflineVerifier.swift")
        let source = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        try #require(source.contains("enum VerificationCaveat"), "did not find the caveats at \(url.path)")
        return source
    }
}
