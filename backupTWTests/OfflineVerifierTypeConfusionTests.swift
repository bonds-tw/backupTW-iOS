//
//  OfflineVerifierTypeConfusionTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// The three bypasses that all came out of one line of thinking: `as? String`
/// answers `nil` for a field nobody wrote *and* for a field holding `12345`, and
/// `OfflineVerifier` is full of places that quite correctly tolerate an omission.
///
/// Each of those tolerances was therefore a switch the side being checked could
/// flip, by changing a value's **type** rather than its content — which is the
/// part that makes these worth their own file. Every one of them has a sibling in
/// `OfflineVerifierTests` proving that writing the *wrong string* is caught. The
/// document that gets through is the one that writes the wrong *kind of thing*,
/// or nothing at all.
///
/// The standard these are held to is not "did the signature check run". It is
/// what the screen said. `"validUntil": 1` did not merely pass: it passed
/// carrying 「本文件未載明有效期限」 above a document that had named an expiry in
/// 1970. A verifier at a counter reads that sentence and hands back an ID. So the
/// assertions here go after the caveats and the outcome together, because a
/// presentation that verifies while the screen states something false is the same
/// defect as a forged signature, wearing better clothes.
struct OfflineVerifierTypeConfusionTests {

    // MARK: - (1) An expiry the verifier was told did not exist

    /// The attack verbatim: `"validUntil": 1` — an expiry a second after the
    /// epoch, written as a JSON number.
    ///
    /// `as? String` read it as `nil`, which is indistinguishable from a
    /// credential that names no expiry, so the comparison was skipped, the
    /// document verified, and the result carried `.noExpiryAsserted`. Two
    /// failures in one: the expiry check turned off, and a false sentence put on
    /// the verifier's screen to explain why nothing was shown about expiry.
    @Test func rejectsAnExpiryWrittenAsANumberRatherThanReadingItAsAbsent() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validUntil"] = 1
        }

        let outcome = OfflineVerifier.verify(
            presentationJWS: try Fixture.presentation(by: holder, carrying: credential, request: request),
            against: request,
            now: Fixture.presentedAt)

        #expect(outcome.failure == .credentialValidityUnreadable)
        // The display half, asserted separately from the outcome: even a future
        // refactor that decided to accept this must never be able to accompany it
        // with 「本文件未載明有效期限」, because that is the lie the verifier acts on.
        #expect(outcome.verified?.caveats.contains(.noExpiryAsserted) != true)
        #expect(outcome.verified?.validUntil == nil)
    }

    /// Every shape a hostile presenter can put where the expiry belongs, not just
    /// the number from the report. `null` is in the list on purpose: it is the
    /// spelling somebody reaches for when told that numbers are refused, and
    /// treating it as absence would reopen the hole under a new name.
    @Test(arguments: NotAString.allCases)
    func rejectsAnExpiryOfAnyTypeThatIsNotText(shape: NotAString) throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validUntil"] = shape.jsonValue
        }

        let outcome = OfflineVerifier.verify(
            presentationJWS: try Fixture.presentation(by: holder, carrying: credential, request: request),
            against: request,
            now: Fixture.presentedAt)

        #expect(outcome.failure == .credentialValidityUnreadable, "\(shape) got through")
        #expect(outcome.verified?.caveats.contains(.noExpiryAsserted) != true)
    }

    /// The other side of the rule, and the reason absence cannot simply be
    /// refused: this app issues no `validUntil` at all, so the ordinary credential
    /// has to keep verifying and keep saying so.
    @Test func stillSaysNoExpiryWasStatedWhenTheCredentialGenuinelyStatesNone() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder)

        let outcome = OfflineVerifier.verify(
            presentationJWS: try Fixture.presentation(by: holder, carrying: credential, request: request),
            against: request,
            now: Fixture.presentedAt)

        let verified = try #require(outcome.verified, "failed with \(String(describing: outcome.failure))")
        #expect(verified.validUntil == nil)
        #expect(verified.caveats.contains(.noExpiryAsserted))
    }

    /// An expiry that is text is still read, parsed and honoured. Guards the
    /// refactor itself: a three-state read that never returns the string would
    /// pass every rejection test above and quietly stop enforcing expiry.
    @Test func stillHonoursAnExpiryWrittenAsText() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let expiry = Fixture.presentedAt.addingTimeInterval(3600)
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validUntil"] = VerifiableCredential.timestamp(from: expiry)
        }

        let outcome = OfflineVerifier.verify(
            presentationJWS: try Fixture.presentation(by: holder, carrying: credential, request: request),
            against: request,
            now: Fixture.presentedAt)

        let verified = try #require(outcome.verified, "failed with \(String(describing: outcome.failure))")
        #expect(verified.validUntil == expiry)
        #expect(!verified.caveats.contains(.noExpiryAsserted))
    }

    /// And an expiry that is text but not a date still lands where it always did.
    /// The wrong-type path was folded into this failure rather than beside it, so
    /// this is the test that notices if the fold went the other way.
    @Test func stillRejectsAnExpiryWrittenAsTextThatIsNotADate() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let credential = try Fixture.credential(issuedBy: holder) { payload in
            payload["validUntil"] = "民國115年8月5日"
        }

        let outcome = OfflineVerifier.verify(
            presentationJWS: try Fixture.presentation(by: holder, carrying: credential, request: request),
            against: request,
            now: Fixture.presentedAt)

        #expect(outcome.failure == .credentialValidityUnreadable)
    }

    // MARK: - (2) A lock the presenting side could pick by deleting it

    /// 寫錯會被抓，刪掉就沒事. The verifier named itself in the request; the
    /// presentation simply did not carry an `audience`, and the whole comparison
    /// was skipped because it required *both* sides to be present before it
    /// compared anything.
    ///
    /// A check the side being checked can switch off is not a check. This is the
    /// same document that is rejected the moment it names the wrong verifier.
    @Test func rejectsAPresentationThatOmitsTheAudienceThisVerifierAskedFor() throws {
        let request = try Fixture.request()
        try #require(request.audience != nil, "this test is meaningless without a verifier identifier")

        let presentation = try Fixture.presentation(request: request) { payload in
            payload.removeValue(forKey: "audience")
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .audienceMismatch)
    }

    /// Deleting the field from the body while leaving it out of the header too —
    /// stated separately from the test above because `signedField` reads both
    /// places, and a fix that only looked at the body would pass one and not the
    /// other.
    @Test func rejectsAPresentationWithNoAudienceInEitherLocation() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request,
                                                    removingHeaderFields: ["audience"]) { payload in
            payload.removeValue(forKey: "audience")
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .audienceMismatch)
    }

    /// The 里長 with a spare iPad and no stable identifier of their own. This is
    /// why absence cannot just be refused everywhere, and it is the case the old
    /// comment was actually describing.
    @Test func stillServesAVerifierThatNamedNoAudienceAndSaysTheReplyIsUnbound() throws {
        let request = try PresentationRequest.generate(purpose: Fixture.purpose, now: Fixture.presentedAt)
        try #require(request.audience == nil)

        let presentation = try Fixture.presentation(request: request)
        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified, "failed with \(String(describing: outcome.failure))")
        #expect(verified.caveats.contains(.notBoundToThisVerifier))
    }

    /// The asymmetry runs one way only. A presentation that names an audience
    /// this verifier never asked for is not refused — there is nothing to compare
    /// it against — but it is not counted as binding either, because the verifier
    /// cannot confirm that the name is theirs.
    @Test func doesNotTreatAnAudienceTheVerifierNeverAskedForAsBinding() throws {
        let request = try PresentationRequest.generate(purpose: Fixture.purpose, now: Fixture.presentedAt)
        let presentation = try Fixture.presentation(request: request) { payload in
            payload["audience"] = "urn:bonds-tw:verifier:somebody-else"
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified, "failed with \(String(describing: outcome.failure))")
        #expect(verified.caveats.contains(.notBoundToThisVerifier))
    }

    /// The case that always worked, kept so the restructured guard cannot lose it
    /// while making omission fail.
    @Test func stillRejectsAPresentationNamingAnotherVerifier() throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request) { payload in
            payload["audience"] = "urn:bonds-tw:verifier:somebody-else"
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .audienceMismatch)
    }

    /// And a matching audience still binds, so `.notBoundToThisVerifier` stays a
    /// statement about this presentation rather than a constant.
    @Test func stillBindsWhenBothSidesNameTheSameVerifier() throws {
        let request = try Fixture.request()
        let outcome = OfflineVerifier.verify(presentationJWS: try Fixture.presentation(request: request),
                                             against: request,
                                             now: Fixture.presentedAt)

        let verified = try #require(outcome.verified, "failed with \(String(describing: outcome.failure))")
        #expect(!verified.caveats.contains(.notBoundToThisVerifier))
    }

    // MARK: - (3) One value to a JOSE reader, another to a JSON-LD reader

    /// Exactly what `presentationFieldsDisagree` was written to stop, achieved by
    /// making one of the two copies unreadable instead of different: the header
    /// carries the genuine value, the body carries a number.
    ///
    /// `as? String` returned `nil` for the body copy, the disagreement check saw
    /// only one value and had nothing to compare, and `fromBody ?? fromHeader`
    /// handed back the genuine one. A JSON-LD toolchain reading the body would
    /// have seen `12345`; this verifier saw the challenge it minted. Both
    /// documents are signed, and they say different things.
    @Test(arguments: Fixture.signedFields, NotAString.allCases)
    func rejectsABodyFieldThatIsNotTextEvenWhenTheHeaderLooksRight(field: String,
                                                                  shape: NotAString) throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(
            request: request,
            headerOverrides: [field: Fixture.genuineValue(of: field, in: request)]) { payload in
            payload[field] = shape.jsonValue
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationFieldIsNotText(field: field),
                "\(field) as \(shape) got \(String(describing: outcome.failure))")
    }

    /// The mirror image, because the fallback runs in both directions: the body
    /// carries the genuine value and the header carries the number. Left
    /// unchecked, this is the same trick aimed at whichever reader prefers the
    /// protected header.
    @Test(arguments: Fixture.signedFields, NotAString.allCases)
    func rejectsAHeaderFieldThatIsNotTextEvenWhenTheBodyLooksRight(field: String,
                                                                  shape: NotAString) throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request,
                                                    headerOverrides: [field: shape.jsonValue])

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationFieldIsNotText(field: field),
                "\(field) as \(shape) got \(String(describing: outcome.failure))")
    }

    /// Absence is not what is being refused. A presenter that puts a field only in
    /// the protected header — where JSON-LD expansion cannot drop it — is still
    /// read, which is the whole reason the fallback exists.
    @Test(arguments: Fixture.signedFields)
    func stillReadsAFieldCarriedOnlyInTheProtectedHeader(field: String) throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(
            request: request,
            headerOverrides: [field: Fixture.genuineValue(of: field, in: request)]) { payload in
            payload.removeValue(forKey: field)
        }

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.isVerified, "\(field) failed with \(String(describing: outcome.failure))")
    }

    /// And two genuinely different strings still produce the original refusal
    /// rather than being swallowed by the new one.
    @Test(arguments: Fixture.signedFields)
    func stillRejectsTwoTextCopiesThatDisagree(field: String) throws {
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(request: request,
                                                    headerOverrides: [field: "something-else-entirely"])

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationFieldsDisagree(field: field),
                "\(field) got \(String(describing: outcome.failure))")
    }

    // MARK: - The same conflation in `kid`

    /// Not a bypass on its own — the signature check downstream still has to pass,
    /// so this document is refused either way. It is here because it was the last
    /// `as? String` in the file that read a *present* value as an omission, and a
    /// rule with one exception left in it is a rule the next reader copies wrong.
    ///
    /// What changes is which refusal: the key-ID check now runs and names the
    /// mismatch, instead of being skipped so that the failure surfaces one step
    /// later as a bad signature.
    @Test func rejectsAPresentationKeyIDThatIsNotText() throws {
        let victim = try Party()
        let forger = try Party()
        let request = try Fixture.request()

        let presentation = try Fixture.presentation(by: victim,
                                                    request: request,
                                                    signedBy: forger,
                                                    headerOverrides: ["kid": 1])

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .presentationKeyIDMismatch)
    }

    @Test func rejectsACredentialKeyIDThatIsNotText() throws {
        let holder = try Party()
        let forger = try Party()
        let request = try Fixture.request()

        let credential = try Fixture.credential(issuedBy: holder,
                                                signedBy: forger,
                                                headerOverrides: ["kid": 1])
        let presentation = try Fixture.presentation(by: holder, carrying: credential, request: request)

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.failure == .credentialKeyIDMismatch)
    }

    /// An absent `kid` is still allowed. It is optional in JOSE and the signing
    /// key never comes from it, so a presenter that omits it has claimed nothing
    /// — refusing that would be the false-reject twin of the defect above.
    @Test func stillAcceptsAPresentationWithNoKeyIDAtAll() throws {
        let holder = try Party()
        let request = try Fixture.request()
        let presentation = try Fixture.presentation(by: holder,
                                                    request: request,
                                                    removingHeaderFields: ["kid"])

        let outcome = OfflineVerifier.verify(presentationJWS: presentation,
                                             against: request,
                                             now: Fixture.presentedAt)
        #expect(outcome.isVerified, "failed with \(String(describing: outcome.failure))")
    }

    // MARK: - The new refusal has to be sayable

    /// `OfflineVerifierTests.everyCaveatAndFailureHasSomethingToShowAHuman` walks
    /// a hand-written list of cases, so a case added later is not covered by it
    /// until somebody remembers to extend that list. This is the cover for the one
    /// added here: a refusal with no text ships as a blank row on the screen the
    /// whole app exists to make trustworthy.
    @Test(arguments: Fixture.signedFields)
    func theNewRefusalHasSomethingToShowAHuman(field: String) {
        let failure = VerificationFailure.presentationFieldIsNotText(field: field)
        #expect(!failure.message.isEmpty)
        #expect(failure.errorDescription == failure.message)
        // The field name is our own vocabulary rather than the holder's data, but
        // the rule in `VerificationFailure` is that no message interpolates its
        // associated value, and a message that varied per field would be the first
        // step towards one that did.
        #expect(failure.message == VerificationFailure.presentationFieldIsNotText(field: "challenge").message)
    }

    // MARK: - Test doubles

    /// What a hostile presenter can put where a string belongs.
    ///
    /// An enum rather than `[Any]`, because `@Test(arguments:)` needs its
    /// arguments `Sendable` and `Any` is not. Each case is a distinct JSON type,
    /// so a fix that special-cased numbers and forgot booleans fails here.
    enum NotAString: CaseIterable, Sendable, CustomStringConvertible {
        case number
        case negativeNumber
        case boolean
        case list
        case object
        case null

        /// Everything here has to survive `JSONSerialization.data(withJSONObject:)`,
        /// which is what makes these documents real rather than hypothetical: they
        /// are well-formed JSON, correctly signed, and refused on their contents.
        var jsonValue: Any {
            switch self {
            case .number: return 1
            case .negativeNumber: return -1
            case .boolean: return true
            case .list: return ["2099-01-01T00:00:00Z"]
            case .object: return ["@value": "2099-01-01T00:00:00Z"]
            case .null: return NSNull()
            }
        }

        var description: String {
            switch self {
            case .number: return "1"
            case .negativeNumber: return "-1"
            case .boolean: return "true"
            case .list: return "[…]"
            case .object: return "{…}"
            case .null: return "null"
            }
        }
    }

    /// One participant: a P-256 key and the DID it derives to.
    ///
    /// CryptoKit rather than `DeviceKey`, for the reason `OfflineVerifierTests`
    /// gives: the verifier only ever sees public keys and signatures, and a
    /// fixture that needed a keychain would make every test here skippable on the
    /// machines where they matter most.
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
    /// Nested inside the suite rather than shared with `OfflineVerifierTests`,
    /// whose equivalent is file-private. Duplicated deliberately for one more
    /// reason than access control: these tests need bodies whose members are the
    /// *wrong JSON type*, which a fixture built out of Swift's `Codable` types
    /// cannot express at all — a `String?` property has no way to hold `12345`.
    /// Only a `[String: Any]` handed to `JSONSerialization` can produce the
    /// documents under test here.
    private enum Fixture {

        static let issuedAt = Date(timeIntervalSince1970: 1_754_400_000)
        static let presentedAt = issuedAt.addingTimeInterval(3600)
        static let purpose = "里長辦公室核對受災戶身分"
        static let audience = "urn:bonds-tw:verifier:9f3a1c"

        /// The four the verifier reads out of a presentation, and the four the
        /// report found were all reachable by the same trick.
        static let signedFields = ["challenge", "audience", "purpose", "created"]

        static func request() throws -> PresentationRequest {
            try PresentationRequest.generate(purpose: purpose, audience: audience, now: presentedAt)
        }

        /// The value a well-behaved presenter would write for `field`, so a test
        /// can put the genuine thing in one location and the attack in the other.
        static func genuineValue(of field: String, in request: PresentationRequest) -> String {
            switch field {
            case "challenge": return request.challenge
            case "audience": return request.audience ?? ""
            case "purpose": return request.purpose
            default: return VerifiableCredential.timestamp(from: presentedAt)
            }
        }

        // MARK: Credential

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

        static func jws(header: [String: Any],
                        payload: [String: Any],
                        signedBy key: P256.Signing.PrivateKey) throws -> String {
            let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            let payloadData = try JSONSerialization.data(withJSONObject: payload,
                                                         options: [.sortedKeys, .withoutEscapingSlashes])
            let signingInput = base64URL(headerData) + "." + base64URL(payloadData)
            // `signature(for:)` on a `DataProtocol` hashes the message itself,
            // matching what `DeviceKey` does with
            // `.ecdsaSignatureMessageX962SHA256`. Pre-hashing here would produce
            // signatures the real signer never makes, and every test in this file
            // would then be exercising the signature check instead of the one it
            // names.
            let signature = try key.signature(for: Data(signingInput.utf8))
            return signingInput + "." + base64URL(signature.rawRepresentation)
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }
}
