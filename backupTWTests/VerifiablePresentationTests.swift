//
//  VerifiablePresentationTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// The request and the presentation are the two things that cross the gap
/// between a holder's phone and a stranger's scanner, so both are compatibility
/// surfaces and neither can be changed quietly. These pin the wire shapes, the
/// validation that keeps hostile text out of the holder's screen, and the one
/// property the whole scheme rests on: that the verifier's challenge is inside
/// what the device signed.
struct VerifiablePresentationTests {

    private static let fullModel = NationalIDModel(nationality: "中華民國（臺灣）",
                                                   unifiedNo: "A123456789",
                                                   name: "王小明",
                                                   birthdate: "0700101",
                                                   addressOfHousehold: "臺北市中正區重慶南路一段122號")

    /// The W3C-CCG P-256 test vector: a syntactically valid did:key that is
    /// certainly not this device's, which is what the mismatch tests need.
    private static let otherDID = "did:key:zDnaerx9CtbPJ1q36T5Ln5wYt3MQYeGRG5ehnPAmxcf5mDZpv"

    private static let issuedAt = Date(timeIntervalSince1970: 1_754_400_000)
    private static let createdAt = Date(timeIntervalSince1970: 1_754_500_000)

    private static let deviceKeyTag = "tw.bonds.backupTW.tests.verifiablePresentation"

    /// Signing needs a real keychain item, which a test bundle does not always
    /// get. Same gate as the credential tests: an environment problem should not
    /// report as a defect.
    static let deviceKeyIsAvailable: Bool = {
        let probeTag = "tw.bonds.backupTW.tests.verifiablePresentation.probe"
        defer { try? DeviceKey.deleteKey(tag: probeTag) }
        return (try? DeviceKey.loadOrCreate(tag: probeTag)) != nil
    }()

    // MARK: - Request: challenge

    /// 128 bits, because the replay defence is the only thing standing between a
    /// captured presentation and its reuse. 16 bytes base64url to 22 characters
    /// with no padding.
    @Test func generatedChallengeCarries128BitsOfBase64URL() throws {
        let request = try PresentationRequest.generate(purpose: "里長辦公室核對身分")

        #expect(request.challenge.count == 22)
        #expect(request.challenge.rangeOfCharacter(from: PresentationRequest.challengeAlphabet.inverted) == nil)
        #expect(!request.challenge.contains("="))
    }

    /// A challenge that repeats is not a challenge. This would fail if the
    /// generator ever fell back to a counter, a timestamp, or a constant.
    @Test func generatedChallengesDoNotRepeat() throws {
        var seen: Set<String> = []
        for _ in 0..<64 {
            seen.insert(try PresentationRequest.generate(purpose: "查驗").challenge)
        }
        #expect(seen.count == 64)
    }

    /// A challenge outside base64url would need escaping in the QR, in the JSON,
    /// or in a URL, and the version that survived escaping is not the version the
    /// verifier is holding in its pending set.
    @Test(arguments: ["", " ", "abc def", "abc+def", "abc/def", "abc=", "abc\"def", "挑戰",
                      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
    func rejectsChallengesThatAreNotBase64URL(challenge: String) {
        #expect(throws: PresentationRequestError.malformedChallenge) {
            _ = try PresentationRequest(challenge: challenge, purpose: "查驗", createdAt: Self.issuedAt)
        }
    }

    // MARK: - Request: purpose

    /// The purpose is the only thing telling the holder who is asking and why.
    /// A blank one means they are being asked to present blind.
    @Test(arguments: ["", "   ", "\n\t "])
    func rejectsAPurposeThatTellsTheHolderNothing(purpose: String) {
        #expect(throws: PresentationRequestError.emptyPurpose) {
            _ = try PresentationRequest(challenge: "abcd", purpose: purpose, createdAt: Self.issuedAt)
        }
    }

    @Test func rejectsAPurposeLongerThanTheCap() {
        let tooLong = String(repeating: "查", count: PresentationRequest.maximumPurposeLength + 1)
        #expect(throws: PresentationRequestError.purposeTooLong) {
            _ = try PresentationRequest(challenge: "abcd", purpose: tooLong, createdAt: Self.issuedAt)
        }
    }

    @Test func acceptsAPurposeExactlyAtTheCap() throws {
        let atCap = String(repeating: "查", count: PresentationRequest.maximumPurposeLength)
        let request = try PresentationRequest(challenge: "abcd", purpose: atCap, createdAt: Self.issuedAt)
        #expect(request.purpose.count == PresentationRequest.maximumPurposeLength)
    }

    /// The verifier writes this text and the holder's device draws it next to the
    /// app's own warnings. `U+202E` reverses everything after it, the isolates
    /// and embeddings reorder runs, and a newline pushes whatever follows out of
    /// a label — all of which let supplied text rearrange words the app wrote.
    @Test(arguments: ["核對\n身分", "核對\u{202E}身分", "核對\u{0000}身分",
                      "核對\u{200B}身分", "核對\u{2066}身分", "核對\u{200F}身分",
                      "核對\u{2028}身分", "核對\u{2029}身分"])
    func rejectsAPurposeCarryingControlOrBidiCharacters(purpose: String) {
        #expect(throws: PresentationRequestError.purposeContainsControlCharacters) {
            _ = try PresentationRequest(challenge: "abcd", purpose: purpose, createdAt: Self.issuedAt)
        }
    }

    /// The two separators Foundation does not call control characters.
    ///
    /// U+2028 and U+2029 are categories Zl and Zp, so they are absent from
    /// `CharacterSet.controlCharacters` — which this validation used on its own,
    /// under a comment asserting that one set was sufficient. A `UILabel` with
    /// `numberOfLines = 0` breaks on them exactly as it does on `\n`, so the
    /// measured attack `"臨櫃身分查驗\u{2028}✅ 內政部已核准"` rendered its second
    /// half on a line of its own, in the app's own style, on the screen where
    /// the holder decides whether to hand over their identity.
    ///
    /// This test pins the gap rather than the outcome: anyone who simplifies
    /// `displayUnsafeScalars` back to `.controlCharacters` sees the first two
    /// expectations disagree and the last two fail.
    @Test func theTwoSeparatorsFoundationDoesNotCallControlCharacters() {
        for separator in ["\u{2028}", "\u{2029}"] {
            #expect(separator.rangeOfCharacter(from: .controlCharacters) == nil,
                    "Foundation now calls \(separator.unicodeScalars.first!) a control character; the union in displayUnsafeScalars may no longer be load-bearing")
            #expect(separator.rangeOfCharacter(from: PresentationRequest.displayUnsafeScalars) != nil)
        }

        #expect(throws: PresentationRequestError.purposeContainsControlCharacters) {
            _ = try PresentationRequest(challenge: "abcd",
                                        purpose: "臨櫃身分查驗\u{2028}✅ 內政部已核准",
                                        createdAt: Self.issuedAt)
        }
        // The audience is drawn on the same screen and was checked with the same
        // insufficient set.
        #expect(throws: PresentationRequestError.malformedAudience) {
            _ = try PresentationRequest(challenge: "abcd",
                                        purpose: "核對身分",
                                        createdAt: Self.issuedAt,
                                        audience: "里長辦公室\u{2029}✅ 內政部")
        }
    }

    @Test func trimsSurroundingWhitespaceFromThePurpose() throws {
        let request = try PresentationRequest(challenge: "abcd",
                                              purpose: "  里長辦公室核對身分  ",
                                              createdAt: Self.issuedAt)
        #expect(request.purpose == "里長辦公室核對身分")
    }

    // MARK: - Request: audience

    /// A 里長 with a borrowed iPad has no stable identifier, and inventing one
    /// per launch would make the field meaningless — so absent is a legitimate
    /// answer, and it has to stay absent rather than become an empty string that
    /// an equality check would accept.
    @Test(arguments: [nil, "", "   ", "\n"] as [String?])
    func treatsAnAbsentOrBlankAudienceAsNoAudience(audience: String?) throws {
        let request = try PresentationRequest(challenge: "abcd", purpose: "查驗",
                                              createdAt: Self.issuedAt, audience: audience)
        #expect(request.audience == nil)
    }

    @Test func trimsAndKeepsAnAudienceThatWasGiven() throws {
        let request = try PresentationRequest(challenge: "abcd", purpose: "查驗",
                                              createdAt: Self.issuedAt,
                                              audience: "  urn:bonds-tw:verifier:6f3a  ")
        #expect(request.audience == "urn:bonds-tw:verifier:6f3a")
    }

    /// Same reasoning as `purpose`: it is verifier-supplied text that ends up in
    /// a signed document and, in a caveat, on the holder's screen.
    @Test(arguments: ["urn:\u{202E}bonds", "urn:bonds\u{0000}verifier",
                      String(repeating: "u", count: PresentationRequest.maximumAudienceLength + 1)])
    func rejectsAnAudienceThatIsOverlongOrCarriesControlCharacters(audience: String) {
        #expect(throws: PresentationRequestError.malformedAudience) {
            _ = try PresentationRequest(challenge: "abcd", purpose: "查驗",
                                        createdAt: Self.issuedAt, audience: audience)
        }
    }

    // MARK: - Request: transport

    /// `null` and "absent" have to decode to the same request, so the encoder
    /// omits the key rather than writing null — otherwise a request would stop
    /// equalling itself across a round trip.
    @Test func carriesTheAudienceThroughTransportAndOmitsItWhenAbsent() throws {
        let named = try PresentationRequest(challenge: "abcd", purpose: "查驗",
                                            createdAt: Self.issuedAt,
                                            audience: "urn:bonds-tw:verifier:6f3a")
        let namedText = try named.encodedForTransport()
        #expect(namedText.contains("\"a\":\"urn:bonds-tw:verifier:6f3a\""))
        #expect(try PresentationRequest.decode(namedText) == named)

        let anonymous = try PresentationRequest(challenge: "abcd", purpose: "查驗",
                                                createdAt: Self.issuedAt)
        let anonymousText = try anonymous.encodedForTransport()
        #expect(!anonymousText.contains("\"a\""))
        #expect(try PresentationRequest.decode(anonymousText) == anonymous)
        // An explicit null must land in the same place as an omitted key.
        #expect(try PresentationRequest.decode("{\"a\":null,\"c\":\"abcd\",\"p\":\"查驗\",\"t\":1754400000,\"v\":1}")
                == anonymous)
    }

    @Test func roundTripsThroughItsTransportEncoding() throws {
        let request = try PresentationRequest.generate(purpose: "里長辦公室核對受災戶身分",
                                                       now: Self.issuedAt)
        let decoded = try PresentationRequest.decode(request.encodedForTransport())
        #expect(decoded == request)
    }

    /// Not for the signature's sake — the request is unsigned — but so that the
    /// same request cannot become two different QR codes, and so a verifier can
    /// compare or deduplicate what it issued.
    @Test func transportEncodingIsDeterministic() throws {
        let request = try PresentationRequest.generate(purpose: "查驗", now: Self.issuedAt)
        let first = try request.encodedForTransport()
        for _ in 0..<32 {
            #expect(try request.encodedForTransport() == first)
        }
    }

    /// Short keys, epoch seconds, and small enough that the verifier's QR is a
    /// low version that scans from across a desk. The response is the one under
    /// pressure; this side has room to spare and should keep it.
    @Test func transportEncodingIsCompactAndPrintable() throws {
        let request = try PresentationRequest.generate(purpose: "里長辦公室核對受災戶身分",
                                                       now: Self.issuedAt)
        let text = try request.encodedForTransport()
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let json = try #require(object as? [String: Any])

        // `b` is the one-time BLE service identifier — a generated request
        // always offers the radio, and a decoded one from an older build may
        // not, which is why the field is optional in the type and present here.
        #expect(Set(json.keys) == ["v", "c", "p", "t", "b"])
        #expect(json["v"] as? Int == 1)
        #expect(json["t"] as? Int == Int(Self.issuedAt.timeIntervalSince1970))
        #expect(UUID(uuidString: try #require(json["b"] as? String)) != nil)

        // The budget, and what engagement cost. A 36-character UUID plus its key
        // and quotes adds about 44 bytes to a request that was around 120, and
        // the ceiling that matters is QR version 10 at error correction level M
        // — 213 bytes — because that is the code a phone reads from half a metre
        // away. Still inside it, with the margin now stated rather than assumed.
        #expect(text.utf8.count < 200, "request grew to \(text.utf8.count) bytes; QR version 10 @ M holds 213")
        // Printable UTF-8 keeps `AVMetadataMachineReadableCodeObject.stringValue`
        // non-nil, so the scanner never has to decode the raw QR bit stream.
        #expect(String(data: Data(text.utf8), encoding: .utf8) == text)
    }

    /// The wire carries whole seconds. If the in-memory value kept the
    /// fractional part, a request would stop being equal to itself after a round
    /// trip and every comparison against a stored copy would fail.
    @Test func createdAtIsTruncatedToWholeSeconds() throws {
        let fractional = Date(timeIntervalSince1970: 1_754_400_000.75)
        let request = try PresentationRequest(challenge: "abcd", purpose: "查驗", createdAt: fractional)

        #expect(request.createdAt.timeIntervalSince1970 == 1_754_400_000)
        #expect(try PresentationRequest.decode(request.encodedForTransport()) == request)
    }

    /// A request from a newer protocol has to say so. Reading the version last
    /// would report whichever field that version happened to rename instead.
    @Test func rejectsRequestsFromANewerProtocolVersion() {
        let text = "{\"c\":\"abcd\",\"p\":\"查驗\",\"t\":1754400000,\"v\":2}"
        #expect(throws: PresentationRequestError.unsupportedVersion(2)) {
            _ = try PresentationRequest.decode(text)
        }
    }

    @Test(arguments: ["", "not json", "{}", "[1,2,3]",
                      "{\"v\":1,\"c\":\"abcd\"}",
                      "{\"v\":1,\"c\":\"abcd\",\"p\":\"查驗\"}",
                      "{\"v\":1,\"c\":\"abcd\",\"p\":\"查驗\",\"t\":\"2025-08-05\"}"])
    func rejectsMalformedTransportText(text: String) {
        #expect(throws: PresentationRequestError.malformedEncoding) {
            _ = try PresentationRequest.decode(text)
        }
    }

    /// The decoder must not be a way around the initialiser's checks — a hostile
    /// request is precisely the one that arrives encoded.
    @Test func decodedRequestsGoThroughTheSameValidation() {
        #expect(throws: PresentationRequestError.malformedChallenge) {
            _ = try PresentationRequest.decode("{\"c\":\"\",\"p\":\"查驗\",\"t\":1754400000,\"v\":1}")
        }
        #expect(throws: PresentationRequestError.purposeContainsControlCharacters) {
            _ = try PresentationRequest.decode("{\"c\":\"abcd\",\"p\":\"核對\\u202e身分\",\"t\":1754400000,\"v\":1}")
        }
    }

    // MARK: - Presentation: JWS shape

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func compactSerializationHasThreeSegments() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let segments = try fixture.presentation().components(separatedBy: ".")
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { !$0.isEmpty })
    }

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func everySegmentIsUnpaddedBase64URL() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let alphabet = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for segment in try fixture.presentation().components(separatedBy: ".") {
            #expect(!segment.contains("="))
            #expect(!segment.contains("+"))
            #expect(!segment.contains("/"))
            #expect(segment.rangeOfCharacter(from: alphabet.inverted) == nil)
        }
    }

    /// `typ` is the whole of the domain separation between a credential and a
    /// presentation: JOSE has no `proofPurpose`, both are signed by the same key,
    /// and a verifier that skips this check would accept an assertion signature
    /// as proof that the holder is present right now.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func headerDeclaresES256AndSeparatesItselfFromACredential() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let header = try Self.headerObject(of: fixture.presentation())
        #expect(header["alg"] as? String == "ES256")
        #expect(header["typ"] as? String == "vp+jwt")
        #expect(header["cty"] as? String == "vp")
        #expect(header["kid"] as? String == fixture.did + "#"
                + fixture.did.replacingOccurrences(of: "did:key:", with: ""))

        // The same key signed the credential under a different `typ`; if these
        // ever coincide the two documents become interchangeable.
        let credentialHeader = try Self.headerObject(of: fixture.credentialJWS)
        #expect(credentialHeader["typ"] as? String != header["typ"] as? String)
    }

    // MARK: - Presentation: payload shape

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func payloadIsAVerifiablePresentationHeldByThisDevice() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let payload = try Self.payloadObject(of: fixture.presentation())
        let context = try #require(payload["@context"] as? [Any])

        #expect(payload["context"] == nil)
        #expect(context.first as? String == VerifiableCredential.credentialsV2Context)
        #expect(payload["type"] as? [String] == ["VerifiablePresentation"])
        #expect(payload["holder"] as? String == fixture.did)
    }

    /// The credential's bytes are its signature's subject, so the envelope has to
    /// carry the string it was handed and not a re-serialisation of it. It also
    /// has to be a node rather than a bare string: a compact JWS dropped straight
    /// into `verifiableCredential` produces a document that verifies and then
    /// loses its credential on expansion.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func credentialIsEnvelopedWithItsBytesIntact() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let payload = try Self.payloadObject(of: fixture.presentation())
        let credentials = try #require(payload["verifiableCredential"] as? [Any])
        #expect(credentials.count == 1)

        let envelope = try #require(credentials.first as? [String: Any])
        #expect(envelope["type"] as? String == "EnvelopedVerifiableCredential")
        #expect(envelope["@context"] as? String == VerifiableCredential.credentialsV2Context)
        #expect(envelope["id"] as? String == "data:application/vc+jwt," + fixture.credentialJWS)

        let decoded = EnvelopedVerifiableCredential.enveloping(compactJWS: fixture.credentialJWS)
        #expect(decoded.compactJWS == fixture.credentialJWS)
    }

    /// An envelope carrying some other media type — which is what a ZK proof
    /// would look like from here — must not be mistaken for a JWS.
    @Test func envelopeReportsNoJWSForAnotherMediaType() {
        let envelope = EnvelopedVerifiableCredential(context: VerifiableCredential.credentialsV2Context,
                                                     id: "data:application/vp+sd-jwt,abc",
                                                     type: EnvelopedVerifiableCredential.typeName)
        #expect(envelope.compactJWS == nil)
    }

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func carriesTheChallengeAndPurposeTheVerifierAsked() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let payload = try Self.payloadObject(of: fixture.presentation())
        #expect(payload["challenge"] as? String == fixture.request.challenge)
        // The purpose is echoed so the signed document records what the holder
        // was told, rather than only what they were asked.
        #expect(payload["purpose"] as? String == fixture.request.purpose)
        // `OfflineVerifier` reads this to confirm the reply was made for it, and
        // reports an unbound presentation as a caveat when it is absent.
        #expect(payload["audience"] as? String == "urn:bonds-tw:verifier:test")
    }

    /// Absent, not null and not empty. A verifier with no stable identifier —
    /// a 里長 with a spare iPad — has to produce a presentation the verifier
    /// side can recognise as unbound, and `"audience": ""` would instead sail
    /// through an equality check against an equally empty expectation.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func omitsTheAudienceWhenTheVerifierNamedNone() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let anonymous = try PresentationRequest(challenge: fixture.request.challenge,
                                                purpose: fixture.request.purpose,
                                                createdAt: Self.issuedAt)
        let jws = try VerifiablePresentation.create(credentialJWS: fixture.credentialJWS,
                                                    request: anonymous,
                                                    signedBy: fixture.key,
                                                    holderDID: fixture.did,
                                                    createdAt: Self.createdAt)
        let payload = try Self.payloadObject(of: jws)
        #expect(payload["audience"] == nil)
        #expect(payload.index(forKey: "audience") == nil)
    }

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func createdIsUTCWithoutFractionalSeconds() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let payload = try Self.payloadObject(of: fixture.presentation())
        let stamp = try #require(payload["created"] as? String)
        #expect(stamp == "2025-08-06T17:06:40Z")
        #expect(stamp.hasSuffix("Z"))
        #expect(!stamp.contains("."))
    }

    // MARK: - Presentation: JSON-LD terms

    /// The credential's context exists because JSON-LD expansion drops undefined
    /// terms *silently*. The same trap is here, and worse: the term that would
    /// vanish is the challenge, so expansion would yield a perfectly valid
    /// presentation with no replay defence in it.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func everyTermThePresentationUsesResolvesToAnIRI() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let payload = try Self.payloadObject(of: fixture.presentation())
        let definitions = try Self.embeddedContext(in: payload)

        for term in payload.keys where term != "@context" {
            if VerifiablePresentation.v2DefinedPresentationTerms.contains(term) { continue }
            let iri = try #require(definitions[term] as? String, "\(term) has no term definition")
            #expect(iri.contains("://"), "\(term) must map to an absolute IRI")
        }

        let types = try #require(payload["type"] as? [String])
        for type in types where !VerifiablePresentation.v2DefinedPresentationTerms.contains(type) {
            let iri = try #require(definitions[type] as? String, "type \(type) has no term definition")
            #expect(iri.contains("://"), "\(type) must map to an absolute IRI")
        }
    }

    /// Guards the allowlist the test above leans on: adding a term here is how an
    /// undefined term starts looking defined.
    @Test func onlyTermsTheV2ContextDeclaresAreExemptFromDefinition() {
        #expect(VerifiablePresentation.v2DefinedPresentationTerms
                == ["id", "type", "holder", "verifiableCredential",
                    "VerifiablePresentation", "EnvelopedVerifiableCredential"])
    }

    /// Redefining a `@protected` v2 term is an expansion *error*, which takes the
    /// whole presentation down rather than one field. Every name below is
    /// protected at the **top level**, which is the only level this document has.
    ///
    /// `challenge` is deliberately **not** in this list, and `created` is not
    /// either, although both are v2 terms — they are declared inside `proof`'s
    /// *type-scoped* context, which never comes into range for a document that
    /// has no `proof`. Defining them at the top level is therefore legal, and
    /// `VerifiablePresentation.presentationTermDefinitions` does define them, for
    /// the reason spelled out there: `OfflineVerifier` reads `challenge`,
    /// `audience`, `purpose` and `created`, and a presenter whose field names its
    /// own verifier cannot find is a worse defect than a hazard that needs a
    /// nesting nobody writes. `embeddedContextIsProtectedAndNamesTheBondsTerms`
    /// pins that decision from the other side; listing `challenge` here as well
    /// would make the two tests contradict each other, which is what they did.
    ///
    /// `domain` stays because it is in the same proof-scoped position and we do
    /// *not* define it — so it is a live guard against acquiring one by accident,
    /// rather than a contradiction of a shipped choice.
    @Test(arguments: ["id", "type", "holder", "verifiableCredential", "proof",
                      "domain", "validFrom", "validUntil",
                      "credentialStatus", "VerifiablePresentation",
                      "EnvelopedVerifiableCredential"])
    func embeddedContextDoesNotRedefineProtectedV2Terms(term: String) {
        #expect(VerifiablePresentation.presentationTermDefinitions.terms[term] == nil)
    }

    @Test func embeddedContextIsProtectedAndNamesTheBondsTerms() {
        let definitions = VerifiablePresentation.presentationTermDefinitions
        #expect(definitions.isProtected)
        #expect(definitions.terms["challenge"] == "https://bonds.tw/ns/credentials#challenge")
        #expect(definitions.terms["audience"] == "https://bonds.tw/ns/credentials#audience")
        #expect(definitions.terms["purpose"] == "https://bonds.tw/ns/credentials#purpose")
        #expect(definitions.terms["created"] == "https://bonds.tw/ns/credentials#created")
    }

    // MARK: - Presentation: the signature

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func presentationVerifiesAgainstTheDeviceKey() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        #expect(try Self.signatureIsValid(fixture.presentation(), key: fixture.key))
    }

    /// **The property the whole scheme rests on.** If the challenge were outside
    /// the signature — in a sibling field, in an unsigned wrapper, in the QR but
    /// not the payload — a presentation captured once could be replayed forever.
    /// This rebuilds the signing input with a different challenge and shows the
    /// signature stops verifying.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func changingTheChallengeInvalidatesTheSignature() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let jws = try fixture.presentation()
        let segments = jws.components(separatedBy: ".")
        let original = try Self.decodedPresentation(of: jws)

        // Re-encoding the untouched presentation has to reproduce the signed
        // bytes exactly — otherwise the tamper below would "fail to verify" for
        // the uninteresting reason that our encoder differs from the signer's,
        // and this test would pass while proving nothing.
        #expect(try Self.signingInput(header: segments[0], presentation: original) == segments[0] + "." + segments[1])

        let tampered = VerifiablePresentation(context: original.context,
                                              type: original.type,
                                              holder: original.holder,
                                              verifiableCredential: original.verifiableCredential,
                                              challenge: "AAAAAAAAAAAAAAAAAAAAAA",
                                              audience: original.audience,
                                              purpose: original.purpose,
                                              created: original.created)
        #expect(tampered.challenge != original.challenge)

        let publicKey = try P256.Signing.PublicKey(x963Representation: fixture.key.publicKeyX963)
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try #require(Self.base64URLDecoded(segments[2])))
        let tamperedInput = try Self.signingInput(header: segments[0], presentation: tampered)

        #expect(!publicKey.isValidSignature(signature, for: Data(tamperedInput.utf8)))
    }

    /// The same guarantee from the other direction: two requests that differ only
    /// in the challenge must not produce the same bytes to sign.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func differentChallengesProduceDifferentSigningInputs() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let other = try PresentationRequest(challenge: "AAAAAAAAAAAAAAAAAAAAAA",
                                            purpose: fixture.request.purpose,
                                            createdAt: Self.issuedAt)
        let second = try VerifiablePresentation.create(credentialJWS: fixture.credentialJWS,
                                                       request: other,
                                                       signedBy: fixture.key,
                                                       holderDID: fixture.did,
                                                       createdAt: Self.createdAt)

        let first = try fixture.presentation().components(separatedBy: ".")
        #expect(first[1] != second.components(separatedBy: ".")[1])
    }

    /// ES256 randomises the signature, so the third segment legitimately changes
    /// between calls — but the two segments that get signed must not, or nobody
    /// can re-derive the signing input from the decoded presentation.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func signingTwiceProducesTheSameSigningInput() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let first = try fixture.presentation().components(separatedBy: ".")
        let second = try fixture.presentation().components(separatedBy: ".")
        #expect(first[0] == second[0])
        #expect(first[1] == second[1])
    }

    /// A verifier decodes the payload into this type and re-encodes it to rebuild
    /// the signing input. If that round trip is not byte-exact the presentation
    /// is unverifiable by anyone but its author.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func payloadRoundTripsIntoTheModelAndBackToTheSameBytes() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let segments = try fixture.presentation().components(separatedBy: ".")
        let decoded = try Self.decodedPresentation(of: segments.joined(separator: "."))

        #expect(decoded.holder == fixture.did)
        #expect(decoded.challenge == fixture.request.challenge)
        #expect(decoded.verifiableCredential.first?.compactJWS == fixture.credentialJWS)
        #expect(VerifiableCredential.base64URLEncoded(try Self.canonicalEncoder.encode(decoded))
                == segments[1])
    }

    // MARK: - Presentation: refusals

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable),
          arguments: ["", "did:key:", "did:web:example.gov", "zDnaerx9CtbPJ1q36T5"])
    func rejectsAHolderIdentifierThatIsNotADIDKey(did: String) throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        #expect(throws: VerifiablePresentationError.unsupportedHolderDID) {
            _ = try VerifiablePresentation.create(credentialJWS: fixture.credentialJWS,
                                                  request: fixture.request,
                                                  signedBy: fixture.key,
                                                  holderDID: did)
        }
    }

    /// The device identity rotates — deliberately via `IdentityReset`, and
    /// accidentally when a crash loses the install marker. Presenting under a DID
    /// the signing key no longer derives to would produce a document that fails
    /// at the counter with nothing to explain it.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func rejectsAHolderIdentifierThisKeyDoesNotDeriveTo() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        #expect(throws: VerifiablePresentationError.holderKeyMismatch) {
            _ = try VerifiablePresentation.create(credentialJWS: fixture.credentialJWS,
                                                  request: fixture.request,
                                                  signedBy: fixture.key,
                                                  holderDID: Self.otherDID)
        }
    }

    /// Holder binding. A credential is a self-contained signed file, so anyone
    /// holding a copy could wrap it in a presentation signed by their own key;
    /// the subject check is what turns "somebody holds a key" into "the subject
    /// of these claims is here".
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func rejectsACredentialIssuedToSomebodyElse() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        // Same issuer — this device — but the claims are about another subject.
        let foreign = VerifiableCredential(
            context: [.url(VerifiableCredential.credentialsV2Context),
                      .definitions(VerifiableCredential.nationalIDTermDefinitions)],
            type: [VerifiableCredential.baseType, VerifiableCredential.nationalIDType],
            issuer: fixture.did,
            validFrom: VerifiableCredential.timestamp(from: Self.issuedAt),
            credentialSubject: ["id": Self.otherDID, "unifiedNo": "A123456789"],
            sd: nil)
        let foreignJWS = try foreign.jwsCompactSerialization(signedBy: fixture.key,
                                                             issuerDID: fixture.did)

        #expect(throws: VerifiablePresentationError.credentialSubjectMismatch) {
            _ = try VerifiablePresentation.create(credentialJWS: foreignJWS,
                                                  request: fixture.request,
                                                  signedBy: fixture.key,
                                                  holderDID: fixture.did)
        }
    }

    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable),
          arguments: ["", "abc", "abc.def", "abc.def.ghi.jkl", "abc..ghi",
                      "abc.!!!!.ghi",
                      // Valid base64url that is not JSON.
                      "abc.aGVsbG8.ghi",
                      // JSON with no `credentialSubject`.
                      "abc.eyJhIjoxfQ.ghi",
                      // `credentialSubject` with no `id`.
                      "abc.eyJjcmVkZW50aWFsU3ViamVjdCI6eyJuYW1lIjoiWCJ9fQ.ghi"])
    func rejectsACredentialItCannotReadASubjectFrom(jws: String) throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        #expect(throws: VerifiablePresentationError.malformedCredential) {
            _ = try VerifiablePresentation.create(credentialJWS: jws,
                                                  request: fixture.request,
                                                  signedBy: fixture.key,
                                                  holderDID: fixture.did)
        }
    }

    // MARK: - Presentation: size

    /// **This test asserts a defect, on purpose.**
    ///
    /// A presentation of the national-ID credential measures 3076 bytes with an
    /// audience named, 3022 without. QR version 40 at error correction level L —
    /// the largest single code that exists —
    /// holds 2953, and `CIQRCodeGenerator` reports the overflow by returning nil
    /// rather than throwing. So this format cannot be shown as a QR code at all,
    /// and the usable ceiling is lower still: about 400–780 bytes at a
    /// comfortable scanning distance on the oldest supported phone.
    ///
    /// It is written as a passing expectation so the number is measured on every
    /// run instead of remembered from a comment. When the CBOR carrier lands, or
    /// if anything shrinks this below the ceiling, **this test goes red and is
    /// meant to** — whoever does it should come here, delete it, and replace it
    /// with a real budget. The upper bound catches the other direction: a field
    /// added carelessly to a document already over capacity.
    @Test(.enabled(if: VerifiablePresentationTests.deviceKeyIsAvailable))
    func presentationExceedsTheCapacityOfASingleQRCode() throws {
        let fixture = try Self.fixture()
        defer { Self.tearDownKey() }

        let size = try fixture.presentation().utf8.count
        #expect(size > 2953,
                "measured \(size) bytes — if this now fits in one code, the QR path can be reconsidered")
        // Raised from 3200 to 3400 on 2026-08-10, deliberately and once: the
        // 滿 18 歲 predicate added ~123 bytes (its term IRI in the context plus
        // the claim itself), taking this fixture from ~3078 to a measured 3201.
        // The tripwire is doing its job — this is a document already past one
        // code's capacity and it grew — so the trade is recorded rather than
        // absorbed: one line that answers an age question without disclosing a
        // birthdate, against ~4% more bytes on a path that already needs
        // multiple frames.
        //
        // ⚠️ This fixture is the *legacy* device-signed presentation. What ships
        // now is card-signed and roughly twice this — bounded by
        // `CardSignedPresentationTests.aCardSignedPresentationIsAboutTwiceTheSizeOfADeviceSignedOne`,
        // which is the number to watch if frame count ever starts hurting.
        #expect(size < 3400,
                "measured \(size) bytes; nothing should be added to a document already over capacity")
    }

    // MARK: - Helpers

    private struct Fixture {
        let key: DeviceKey
        let did: String
        let credentialJWS: String
        let request: PresentationRequest

        /// Fixed `createdAt` so the signed bytes are reproducible.
        func presentation() throws -> String {
            try VerifiablePresentation.create(credentialJWS: credentialJWS,
                                              request: request,
                                              signedBy: key,
                                              holderDID: did,
                                              createdAt: VerifiablePresentationTests.createdAt)
        }
    }

    private static func fixture() throws -> Fixture {
        let key = try DeviceKey.loadOrCreate(tag: deviceKeyTag)
        let did = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let credential = VerifiableCredential.nationalID(fullModel,
                                                                   issuerDID: did,
                                                                   validFrom: issuedAt)
        let request = try PresentationRequest(challenge: "Q0hBTExFTkdFLTAwMDAwMA",
                                              purpose: "里長辦公室核對受災戶身分",
                                              createdAt: issuedAt,
                                              audience: "urn:bonds-tw:verifier:test")
        return Fixture(key: key,
                       did: did,
                       credentialJWS: try credential.jwsCompactSerialization(signedBy: key,
                                                                             issuerDID: did),
                       request: request)
    }

    private static func tearDownKey() {
        try? DeviceKey.deleteKey(tag: deviceKeyTag)
    }

    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func signingInput(header: String, presentation: VerifiablePresentation) throws -> String {
        header + "." + VerifiableCredential.base64URLEncoded(try canonicalEncoder.encode(presentation))
    }

    private static func decodedPresentation(of jws: String) throws -> VerifiablePresentation {
        let payload = try #require(base64URLDecoded(jws.components(separatedBy: ".")[1]))
        return try JSONDecoder().decode(VerifiablePresentation.self, from: payload)
    }

    private static func signatureIsValid(_ jws: String, key: DeviceKey) throws -> Bool {
        let segments = jws.components(separatedBy: ".")
        let publicKey = try P256.Signing.PublicKey(x963Representation: key.publicKeyX963)
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try #require(base64URLDecoded(segments[2])))
        // `DeviceKey` signs with `.ecdsaSignatureMessageX962SHA256`, which hashes
        // internally, so the message goes in whole. Handing `Data(SHA256.hash(…))`
        // to this overload would hash the digest again and quietly never verify.
        return publicKey.isValidSignature(signature,
                                          for: Data(segments[0..<2].joined(separator: ".").utf8))
    }

    private static func headerObject(of jws: String) throws -> [String: Any] {
        try jsonObject(atSegment: 0, of: jws)
    }

    private static func payloadObject(of jws: String) throws -> [String: Any] {
        try jsonObject(atSegment: 1, of: jws)
    }

    private static func jsonObject(atSegment index: Int, of jws: String) throws -> [String: Any] {
        let data = try #require(base64URLDecoded(jws.components(separatedBy: ".")[index]))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The inline term-definition object: the `@context` entry that is an object
    /// rather than a URL.
    private static func embeddedContext(in payload: [String: Any]) throws -> [String: Any] {
        let context = try #require(payload["@context"] as? [Any])
        return try #require(context.compactMap { $0 as? [String: Any] }.first,
                            "@context carries no inline definitions")
    }

    /// Spelled out rather than reusing the production helper: a test that checks
    /// an encoder against its own inverse passes on any self-consistent alphabet,
    /// including a wrong one.
    private static func base64URLDecoded(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}
