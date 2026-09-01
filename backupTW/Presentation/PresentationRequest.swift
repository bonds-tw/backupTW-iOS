//
//  PresentationRequest.swift
//  backupTW
//

import Foundation
import Security

/// Errors raised while building or reading a presentation request.
///
/// Like `VerifiableCredentialError`, no case carries the offending text. A
/// request arrives from a stranger's screen and its `purpose` is whatever that
/// stranger typed; echoing it into a log or a crash report would put attacker
/// controlled text somewhere nobody is reading carefully.
enum PresentationRequestError: Error, Equatable {
    /// The system CSPRNG refused. Deliberately fatal rather than falling back —
    /// see `generate(purpose:now:)`.
    case randomnessUnavailable
    /// Not the JSON object this format is, or not UTF-8 at all.
    case malformedEncoding
    /// A request written by a newer version of this protocol.
    case unsupportedVersion(Int)
    /// Absent, empty, over-long, or containing characters that are not
    /// base64url — see `challengeAlphabet`.
    case malformedChallenge
    /// A request that tells the holder nothing about who is asking.
    case emptyPurpose
    case purposeTooLong
    /// Control or format characters, including the bidirectional overrides that
    /// let supplied text rearrange the app's own words around it.
    case purposeContainsControlCharacters
    /// Present but empty, over-long, or carrying control characters. Absent is
    /// fine — see `audience`.
    case malformedAudience
}

/// Which locally stored credential family the verifier is asking to inspect.
///
/// This is part of the request instead of a holder-side guess. A wallet can
/// contain both a card signed by its owner and an SD-JWT issued by a government
/// issuer; silently choosing whichever filename sorts first is both surprising
/// and a type-confusion risk. The verifier names the family, then the holder can
/// make an informed disclosure decision for that family.
enum PresentationCredentialSource: String, Codable, CaseIterable, Equatable, Sendable {
    case selfIssued = "s"
    case twdiw = "g"
}

/// What a verifier hands to a holder to start an offline presentation.
///
/// **Direction of travel.** The verifier generates this and shows it (a QR on
/// their screen, a printout, anything that carries a short string); the holder's
/// device reads it and answers with a `VerifiablePresentation`. Two-stage
/// engagement is borrowed from ISO 18013-5, where the QR carries the handshake
/// rather than the data: it keeps the *credential* out of the verifier's QR, and
/// it is what makes a fresh challenge possible at all.
///
/// **Everything in here is untrusted.** The holder's device did not write this
/// object; a person standing in front of the holder did. `purpose` in particular
/// is free text that will be shown to a human next to this app's own warnings,
/// so it is length-bounded and stripped of anything that can reorder what is
/// around it. Nothing in this type authenticates the verifier — an offline
/// verifier has no identity this app can check, exactly as ISO 18013-5's reader
/// authentication is optional and usually absent. A request that says 「內政部
/// 查驗」 is a claim, not a fact, and the UI must not present it as one.
///
/// **What `audience` is worth, which is less than it looks.** RFC 9901 and
/// OID4VP bind a presentation to a named audience so verifier A cannot replay it
/// at verifier B. Most of that job is already done by the challenge: each
/// verifier accepts only challenges it minted itself and holds in its own
/// pending set, so a presentation built for A's challenge is refused by B for
/// the simpler reason that B never issued it. `audience` is optional here
/// because a 里長 with a spare iPad has no stable identifier and inventing one
/// per launch would make the field meaningless.
///
/// What none of it stops, and what should be said out loud rather than designed
/// around: a relay. Mallory can take a genuine challenge from verifier V, show
/// it to the holder under any `purpose` she likes, and hand the reply back to V
/// — and an `audience` of V is exactly what she wants the holder to sign.
/// Closing that needs the verifier to authenticate itself (18013-5's
/// ReaderAuth), which needs a trust root this project does not have offline. It
/// is out of scope, not solved.
struct PresentationRequest: Equatable {

    /// The wire format this app writes and accepts.
    ///
    /// Present so that the first incompatible change surfaces as "this app is
    /// too old" rather than as a decode error, or worse, as a request that
    /// half-parses. The ZK path in particular will need to say *which* proof it
    /// wants, and that request will not be readable by this version.
    static let version = 2

    /// Version 1 did not carry a credential source. It meant the only flow that
    /// existed at the time: the self-issued document. Keep accepting it with
    /// that exact meaning so an older verifier does not become a request for a
    /// newly installed government card by accident.
    static let legacyVersion = 1

    /// The verifier's freshness value, base64url. Replay protection rests
    /// entirely on this being unpredictable and consumed exactly once.
    let challenge: String

    /// Human-readable, verifier-supplied, and shown to the holder before they
    /// agree to present. Untrusted; see the type documentation.
    let purpose: String

    /// A stable identifier for this verifier, e.g.
    /// `urn:bonds-tw:verifier:<uuid>`, echoed into the presentation so
    /// `OfflineVerifier` can bind the reply to itself.
    ///
    /// `nil` rather than `""` when the verifier has none: the verifier reports
    /// an unbound presentation as a caveat the user is shown, and an empty
    /// string would sail through an equality check while saying nothing.
    /// ⚠️ Unauthenticated by construction — anyone can claim any audience.
    let audience: String?

    /// The verifier's clock when the request was made.
    ///
    /// Advisory, and deliberately not part of any decision `OfflineVerifier`
    /// makes — it compares the *presentation's* `created` against its own clock
    /// and never against this field, because two drifting clocks compared to
    /// each other produce false refusals in exactly the setting this app is for:
    /// a borrowed iPad in a 里長辦公室 that has been off for a week. The proof
    /// that a presentation came after the request is the challenge, not the
    /// timestamps.
    ///
    /// It is here so the holder can be shown a request that is obviously stale,
    /// and so a verifier can expire its own pending entries.
    ///
    /// Truncated to whole seconds by `init`, for the reason
    /// `VerifiableCredential.timestamp(from:)` drops fractional seconds: two
    /// `Date`s a microsecond apart are the same instant here, and the value has
    /// to survive an encode/decode round trip unchanged.
    let createdAt: Date

    /// A one-time BLE service identifier the holder should advertise under, or
    /// nil when this verifier is only offering the camera.
    ///
    /// This is the *engagement* half of ISO 18013-5's device retrieval, arrived
    /// at the same way that standard arrives at it: the code already on screen
    /// is the only channel the two devices share before they share a radio, so
    /// it is the natural place to say 「find me here」.
    ///
    /// **Freshly generated per request, never a fixed identifier.** A constant
    /// service UUID would make every holder's phone broadcast the same
    /// well-known value to any receiver in range — a beacon saying 「somebody
    /// with a national ID wallet is standing here」, readable by people who are
    /// not being shown anything. The value is random, it lives as long as the
    /// challenge does, and it is unlinkable to the next one.
    let linkServiceID: UUID?

    /// The credential family the verifier is asking for.
    let credentialSource: PresentationCredentialSource

    // MARK: - Limits

    /// 16 bytes = 128 bits, base64url to 22 characters.
    ///
    /// NIST SP 800-63B sets the floor at 64 bits; RFC 9901 §9.3 recommends 128
    /// for the random part of a key-binding nonce. The floor is not the target,
    /// and the eleven extra characters cost nothing here — the request travels
    /// in its own small QR, and it is the *response* carrying the credential
    /// that is up against the scanning budget.
    static let challengeByteCount = 16

    /// Generous enough for another implementation's longer nonce, bounded so a
    /// hostile request cannot make the holder's device hold or draw an
    /// unbounded string.
    static let maximumChallengeLength = 64

    /// A sentence or two. Chinese costs three UTF-8 bytes per character and this
    /// string is echoed into the signed presentation, so the cap is also a size
    /// budget: 100 characters is up to 300 bytes there, before base64url.
    static let maximumPurposeLength = 100

    /// A URN or a domain, not a sentence.
    static let maximumAudienceLength = 128

    /// base64url's unreserved alphabet (RFC 4648 §5), which is also what OID4VP
    /// requires of a `nonce`: ASCII and URL-safe, so the value survives being
    /// carried in a QR, a URL, or a JSON string without escaping.
    static let challengeAlphabet = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// Scalars a stranger's string may not contain, because of what they do to
    /// a screen rather than because they are unusual.
    ///
    /// `CharacterSet.controlCharacters` is Cc and Cf: U+0000–U+001F,
    /// U+007F–U+009F, U+200E/U+200F, the U+202A–U+202E embeddings and
    /// overrides, the U+2066–U+2069 isolates, U+200B and U+FEFF. That set was
    /// used alone here, under a comment asserting it was sufficient.
    ///
    /// It is not. U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are
    /// categories Zl and Zp, so they are *absent* from `.controlCharacters`,
    /// and a `UILabel` with `numberOfLines = 0` breaks on them exactly as it
    /// does on `\n`. That was not theoretical: a purpose of
    /// `"臨櫃身分查驗\u{2028}✅ 內政部已核准"` was put through the real
    /// confirmation screen and the second half rendered on its own line, in the
    /// app's own style, on the screen where the holder decides whether to hand
    /// over their identity. `.newlines` supplies the two, and matches the union
    /// `UntrustedText.unsafeScalars` already uses on the verifier's side — the
    /// same threat arrives on both screens and should not be answered by two
    /// different sets.
    static let displayUnsafeScalars: CharacterSet = CharacterSet.controlCharacters.union(.newlines)

    // MARK: - Building

    /// The only initialiser, and it validates, so an invalid request cannot
    /// exist in memory — a check that lived only in the decoder would be absent
    /// for a request this app built itself.
    init(challenge: String,
         purpose: String,
         createdAt: Date,
         audience: String? = nil,
         linkServiceID: UUID? = nil,
         credentialSource: PresentationCredentialSource = .selfIssued) throws {
        guard !challenge.isEmpty,
              challenge.count <= Self.maximumChallengeLength,
              challenge.rangeOfCharacter(from: Self.challengeAlphabet.inverted) == nil else {
            throw PresentationRequestError.malformedChallenge
        }

        // Trimmed before the emptiness test: a purpose of three spaces tells the
        // holder exactly as much as an absent one.
        let trimmedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPurpose.isEmpty else {
            throw PresentationRequestError.emptyPurpose
        }
        guard trimmedPurpose.count <= Self.maximumPurposeLength else {
            throw PresentationRequestError.purposeTooLong
        }
        // A display-integrity check, not tidiness: `purpose` is a stranger's
        // string drawn on the screen where the holder decides whether to hand
        // over their identity. A right-to-left override inside it can visually
        // reorder the app's own text around it, and a line break lets it walk
        // out of its card and stand on a line of its own.
        //
        // See `Self.displayUnsafeScalars` for why `.controlCharacters` alone —
        // which this guard used, under a comment claiming it was sufficient —
        // is not.
        guard trimmedPurpose.rangeOfCharacter(from: Self.displayUnsafeScalars) == nil else {
            throw PresentationRequestError.purposeContainsControlCharacters
        }

        // Absent is a legitimate state, so only a *present* audience is checked.
        // Trimmed to nil rather than kept as whitespace: a verifier that sent
        // spaces has no identifier, and carrying one that only looks present
        // would suppress the "not bound to this verifier" caveat the holder is
        // entitled to see.
        //
        // Blank collapses to nil instead of throwing, which is the deliberate
        // direction: the field is optional, so refusing the whole request over
        // it would take down an otherwise valid check, and the lenient result is
        // also the *less* privileged one — an unbound presentation is what the
        // verifier reports a caveat about. Content that could not have been
        // meant (over-long, control characters) still throws.
        var checkedAudience: String?
        if let audience = audience {
            let trimmed = audience.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard trimmed.count <= Self.maximumAudienceLength,
                      trimmed.rangeOfCharacter(from: Self.displayUnsafeScalars) == nil else {
                    throw PresentationRequestError.malformedAudience
                }
                checkedAudience = trimmed
            }
        }

        self.challenge = challenge
        self.purpose = trimmedPurpose
        self.audience = checkedAudience
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.linkServiceID = linkServiceID
        self.credentialSource = credentialSource
    }

    /// Mints a request with a fresh challenge. Verifier side.
    ///
    /// `SecRandomCopyBytes` failing is reported rather than worked around. Every
    /// obvious fallback — `arc4random`, `Int.random`, the clock — produces a
    /// challenge that still *looks* like a challenge while the replay defence
    /// silently stops existing, and a verifier that cannot make a random number
    /// should stop, not carry on quietly.
    static func generate(purpose: String,
                         audience: String? = nil,
                         credentialSource: PresentationCredentialSource = .selfIssued,
                         now: Date = Date()) throws -> PresentationRequest {
        var bytes = [UInt8](repeating: 0, count: challengeByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PresentationRequestError.randomnessUnavailable
        }
        return try PresentationRequest(challenge: VerifiableCredential.base64URLEncoded(Data(bytes)),
                                       purpose: purpose,
                                       createdAt: now,
                                       audience: audience,
                                       // Minted with the challenge and thrown
                                       // away with it. `UUID()` is the system
                                       // CSPRNG, the same source as the bytes
                                       // above.
                                       linkServiceID: UUID(),
                                       credentialSource: credentialSource)
    }
}

// MARK: - Transport

extension PresentationRequest: Codable {

    /// Single-letter keys.
    ///
    /// The request is not signed, so these names are a wire contract between the
    /// two devices rather than part of any signature — they can be short without
    /// costing reproducibility. `v` is read first and is the reason the other
    /// three can ever change.
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case challenge = "c"
        case purpose = "p"
        case createdAt = "t"
        case audience = "a"
        case linkServiceID = "b"
        case credentialSource = "k"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Version first: a newer request must be reported as such, not as
        // whichever field happens to be missing from it.
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version || version == Self.legacyVersion else {
            throw PresentationRequestError.unsupportedVersion(version)
        }

        let challenge = try container.decode(String.self, forKey: .challenge)
        let purpose = try container.decode(String.self, forKey: .purpose)
        let createdAt = try container.decode(Int.self, forKey: .createdAt)
        let audience = try container.decodeIfPresent(String.self, forKey: .audience)
        // Absent means 「this verifier is not offering a radio」, which every
        // request built before this field existed also means. Decoded as a
        // string and rejected if it is not a UUID, rather than trusted: it
        // arrives from a stranger and goes on to name a service to advertise.
        let linkServiceID = try container.decodeIfPresent(String.self, forKey: .linkServiceID)
            .map { text -> UUID in
                guard let uuid = UUID(uuidString: text) else {
                    throw PresentationRequestError.malformedEncoding
                }
                return uuid
            }
        let credentialSource: PresentationCredentialSource
        if version == Self.legacyVersion {
            // A v1 sender did not know government-card offline presentation.
            // Ignore an injected `k` and retain v1's only defined meaning.
            credentialSource = .selfIssued
        } else {
            credentialSource = try container.decode(PresentationCredentialSource.self,
                                                    forKey: .credentialSource)
        }

        // Straight through the validating initialiser: a request that arrived
        // over the air is the one that most needs the checks.
        try self.init(challenge: challenge,
                      purpose: purpose,
                      createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                      audience: audience,
                      linkServiceID: linkServiceID,
                      credentialSource: credentialSource)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(challenge, forKey: .challenge)
        try container.encode(purpose, forKey: .purpose)
        // Omitted rather than written as null when the verifier has no
        // identifier: `null` and "absent" have to decode to the same request,
        // and the shorter one is also the one that keeps the QR smaller.
        try container.encodeIfPresent(audience, forKey: .audience)
        // Uppercase hyphenated, which is what `UUID.uuidString` produces and
        // what `CBUUID` reads back — 36 characters in a code that is otherwise
        // about a hundred, and omitted entirely when there is no radio on offer.
        try container.encodeIfPresent(linkServiceID?.uuidString, forKey: .linkServiceID)
        try container.encode(credentialSource, forKey: .credentialSource)
        // Whole seconds since the epoch. An ISO-8601 string would be three times
        // the bytes and would drag a formatter and a timezone into a value whose
        // only job is to be compared with another instant.
        try container.encode(Int(createdAt.timeIntervalSince1970), forKey: .createdAt)
    }

    /// The exact text to put in the verifier's QR.
    ///
    /// Plain UTF-8 JSON rather than base64 or a compressed blob, and that choice
    /// is about the far end: `AVMetadataMachineReadableCodeObject.stringValue`
    /// is nil for any payload that is not a string, and a scanner that has to
    /// fall back to `CIQRCodeDescriptor.errorCorrectedPayload` is then holding a
    /// raw bit stream complete with QR mode and character-count headers that are
    /// not even byte-aligned above version 9. Staying printable deletes that
    /// entire code path. The request is around a hundred bytes either way.
    func encodedForTransport() throws -> String {
        let encoder = JSONEncoder()
        // Same reasoning as the credential's canonical encoder: Swift seeds
        // dictionary and container ordering per process, and a request that
        // encodes differently on each launch cannot be compared in a test or
        // deduplicated by a verifier.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PresentationRequestError.malformedEncoding
        }
        return text
    }

    /// Reads what a scanner handed back.
    ///
    /// `JSONDecoder`'s own errors are collapsed into `.malformedEncoding` unless
    /// they are already one of ours: a `DecodingError` naming a coding key is a
    /// developer's diagnostic, and this input came from a stranger.
    static func decode(_ text: String) throws -> PresentationRequest {
        guard let data = text.data(using: .utf8) else {
            throw PresentationRequestError.malformedEncoding
        }
        do {
            return try JSONDecoder().decode(PresentationRequest.self, from: data)
        } catch let error as PresentationRequestError {
            throw error
        } catch {
            throw PresentationRequestError.malformedEncoding
        }
    }
}

extension PresentationRequestError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .randomnessUnavailable:
            return NSLocalizedString("This device could not create a verification request.", comment: "")
        case .malformedEncoding, .unsupportedVersion, .malformedChallenge,
             .emptyPurpose, .purposeTooLong, .purposeContainsControlCharacters,
             .malformedAudience:
            // One sentence for every way a scanned request can be wrong. The
            // holder cannot act on the difference between "the nonce had a
            // space in it" and "the JSON was truncated"; both mean "ask them to
            // show it again".
            return NSLocalizedString("This request could not be read.", comment: "")
        }
    }
}
