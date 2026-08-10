//
//  VerifiablePresentation.swift
//  backupTW
//

import Foundation

/// Errors raised while building a presentation.
///
/// No case carries the DID, the challenge, or any part of the credential, for
/// the reason `VerifiableCredentialError` gives: these values are exactly the
/// correlatable identifiers this project is trying not to leak, and an error is
/// the most likely thing to end up in a log.
enum VerifiablePresentationError: Error, Equatable {
    /// The holder identifier is not a `did:key:` DID.
    case unsupportedHolderDID
    /// The signing key does not derive to `holderDID`. Usually means the device
    /// identity was reset since the credential was issued.
    case holderKeyMismatch
    /// The signing key exists but no DID could be derived from it at all.
    case holderKeyUnusable
    /// The stored credential is not a three-segment compact JWS, or its payload
    /// is not a credential object with a subject identifier.
    case malformedCredential
    /// The credential names a subject other than the holder presenting it.
    case credentialSubjectMismatch
    /// `DeviceKey` returned something that is not a 64-byte `r ‖ s` pair.
    case malformedSignature
}

/// A W3C Verifiable Presentation 2.0, secured as a compact JWS.
///
/// # What a verifier learns, and what it does not
///
/// The presentation proves one thing: *the device holding this key is here now,
/// and it answered this verifier's challenge*. The credential it carries is
/// still the self-issued document `VerifiableCredential` describes — signed by
/// the same device, attested by no authority — so a valid presentation of a
/// valid credential says nothing at all about whether the national ID data in it
/// is true. 「本人可驗」 without 「資料可驗」. Any screen that renders a green
/// tick here is lying to its user.
///
/// Three further things a verifier cannot learn offline, which the UI has to
/// state rather than imply by omission: whether the credential was revoked
/// (there is no revocation for a self-issued document, and nothing is
/// contacted); whether the holder is the person the data describes (only that
/// they hold the key); and whether the *verifier* is who they said they were
/// (see `PresentationRequest`).
///
/// # ⚠️ Every presentation is linkable to every other one
///
/// `holder` is this device's `did:key`, the credential inside repeats it as
/// `issuer` and as `credentialSubject.id`, and a `did:key` *is* the public key —
/// so it is the same 57-character string every single time. Two verifiers who
/// compare notes can prove they saw the same person; one verifier can count
/// visits. This is a direct miss against the whitepaper §5.2 unlinkability
/// floor, and no amount of re-encoding fixes it: compression, CBOR and QR
/// splitting all preserve that identifier exactly.
///
/// What would fix it is ZK selective disclosure, which is not integrated because
/// the upstream circuit library (OpenACSwift) ships without a licence and cannot
/// be taken as a dependency. Until then this must be said in the holder-facing
/// UI *before* they present, not discovered afterwards. Do not let the next
/// person reading this file believe the problem is solved.
///
/// # The seam left for that fix
///
/// `verifiableCredential` is an array of `EnvelopedVerifiableCredential`, and an
/// enveloped credential is an opaque `data:` URL that names its own media type.
/// Swapping `application/vc+jwt` for a proof format changes one string and one
/// media type; the challenge, the holder binding, the signing path, the
/// transport and the scanner all stay exactly as they are. That is the whole
/// reason the credential is enveloped rather than inlined as JSON.
///
/// # ⚠️ Size: too large for one QR code, and that is not a detail
///
/// Measured, not estimated — but note *when*. The figures this paragraph gave for
/// a long time (a 1,386-byte credential JWS, a 3,022-byte presentation) were
/// measured on the device-signed credential this app issued before the
/// cardholder's 自然人憑證 started signing. They were quoted for years after that
/// stopped being the shipping shape.
///
/// Measured on what actually ships, 2026-08-10: a card-signed, selectively
/// disclosable national-ID presentation is about **7,400 bytes** of compact JWS.
/// Roughly 90% of that is the enveloped credential, and inside it the certificate
/// alone accounts for about 2,000 — the DER is 861 bytes in this repo's test
/// fixture and each of the three base64 layers costs it another third. A real
/// MOICA certificate is larger again (the two in `backupTW/ZK/` are 1,643 and
/// 1,409 bytes), so a presentation made with a real card is bigger than anything
/// measurable here.
///
/// The largest QR code that exists — version 40 at error correction level L —
/// holds 2,953 bytes, and `CIQRCodeGenerator` reports the overflow by returning
/// nil, not by throwing. But that ceiling is the wrong target and quoting it has
/// caused real confusion: dividing a payload by 2,953 is where the claim that
/// this takes 「約 3 個 QR frame」 came from. Decoding needs roughly 4 pixels per
/// module at a comfortable 15–25 cm on the oldest supported phone, and version 40
/// gives 2.4, so `QRTransport` pins symbols at 89 modules and level Q instead —
/// which leaves 364 bytes per frame. That is the number that decides how many
/// frames there are, and it makes today's payload about **fourteen**. See
/// `PresentationFrameCountTests`.
///
/// `QRTransport` closes the gap by splitting the presentation across animated
/// frames, which is the right call for a screen-to-screen handoff and is what
/// makes offline presentation work today. What it cannot do is put this on
/// paper, and §5.3's scenarios — a 里長 with a printout, a border desk with a
/// dead phone — include paper. That is the cost being paid, and it is being paid
/// because of the format chosen here, not because of anything in the transport.
///
/// Nothing inside JOSE closes a 4× gap. Compression measures ~800 bytes on the
/// credential alone. The RFC 9901 concatenation form
/// (`<credential JWS>~<presentation JWS>`, which avoids the second base64url
/// pass) measures around 2500 bytes — inside the single-code ceiling, still far
/// outside the usable range, and it gives up the self-contained W3C document
/// shape to get there. What actually closes it is a CBOR/COSE_Sign1 carrier at
/// roughly 300 bytes, which wins by dropping the embedded JSON-LD context and
/// both base64 layers rather than by squeezing them — a single static code, on
/// paper, at a version that scans.
///
/// So this type is the JOSE carrier: correct, interoperable, byte-preserving,
/// and the right thing to keep for storage and for any verifier that speaks
/// VC-JOSE-COSE. It should not be shrunk into fitting one code either — a
/// presentation that squeaks under 2953 bytes produces a dense version-40 image
/// that scans nowhere, which is worse than a blank screen because it looks like
/// it works. `presentationExceedsTheCapacityOfASingleQRCode` pins the
/// measurement.
struct VerifiablePresentation: Codable, Equatable {

    /// Ordered set; the v2 URL has to be the first element per VC 2.0 §4.1.
    let context: [JSONLDContextEntry]
    /// Must contain `VerifiablePresentation`.
    let type: [String]
    /// The DID of the device presenting, which is also the credential's subject.
    let holder: String
    /// Enveloped credentials — see `EnvelopedVerifiableCredential`.
    let verifiableCredential: [EnvelopedVerifiableCredential]
    /// Echoed verbatim from the verifier's `PresentationRequest`.
    let challenge: String
    /// The verifier's own identifier, when it gave one. Absent rather than empty
    /// when it did not, because `OfflineVerifier` reports "not bound to this
    /// verifier" as a caveat and an empty string would satisfy a naive equality
    /// check instead.
    let audience: String?
    /// Echoed from the request, so the signed document records what the holder
    /// was told they were agreeing to.
    let purpose: String
    /// XSD 1.1 `dateTimeStamp`, from the *holder's* clock. Named `created`
    /// because that is the field `OfflineVerifier` reads and the name Data
    /// Integrity uses for the same instant.
    let created: String

    /// `@context` cannot be spelled as a Swift property name.
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case type
        case holder
        case verifiableCredential
        case challenge
        case audience
        case purpose
        case created
    }

    // MARK: - Vocabulary

    static let baseType = "VerifiablePresentation"

    /// The inline `@context` object for the terms v2 does not define.
    ///
    /// **The same defect as the credential's, one level up.** The v2 context is
    /// `@protected` and declares no `@vocab`, so a top-level term it has never
    /// heard of has no IRI and JSON-LD expansion drops it *silently* while the
    /// JWS still verifies. For the credential that meant a national ID with no
    /// national ID in it; here it would mean a presentation whose challenge
    /// vanishes — the replay defence gone from the document, with a valid
    /// signature over what is left.
    ///
    /// **The one caveat in these names.** v2 does define `challenge` and
    /// `created`, but only inside the type-scoped context of `proof`, which is
    /// Data Integrity's mechanism and not the one in use here. At the top level
    /// of a presentation they are undefined, so defining them is legal — but if
    /// a document ever nests this object under a `proof`, that scope comes into
    /// range and the definitions below become redefinitions of `@protected`
    /// terms, which is an expansion *error* taking the whole document down
    /// rather than one field. Names of our own (`presentationChallenge`) would
    /// have been immune. These names were chosen anyway because `OfflineVerifier`
    /// reads `challenge`, `audience` and `created`, and a presenter whose field
    /// names its own verifier cannot find is a worse defect than a hazard that
    /// needs a nesting nobody writes.
    ///
    /// **Why not the JOSE header.** Putting the nonce in the protected header
    /// would be smaller and equally signed, and `OfflineVerifier` accepts either
    /// location. It was rejected for two reasons: a private header parameter is
    /// invisible to any verifier that does not know to look for it, so the
    /// replay defence would be silently absent rather than loudly missing; and
    /// this codebase already solved this exact problem once, in
    /// `VerifiableCredential.nationalIDTermDefinitions`, and two mechanisms for
    /// the same job is how one of them rots. Writing a field in *both* places is
    /// not a hedge — `OfflineVerifier` refuses a document whose two copies
    /// disagree, so it is one more way to be wrong.
    static let presentationTermDefinitions = JSONLDTermDefinitions(
        isProtected: true,
        terms: [
            "challenge": VerifiableCredential.termNamespace + "challenge",
            "audience": VerifiableCredential.termNamespace + "audience",
            "purpose": VerifiableCredential.termNamespace + "purpose",
            "created": VerifiableCredential.termNamespace + "created",
        ])

    /// Terms this presentation uses that the v2 context already declares, and
    /// which must therefore *not* appear above. Kept beside the definitions
    /// because the two lists have to stay disjoint, and pinned by a test because
    /// widening it is the one edit that makes an undefined term look defined.
    static let v2DefinedPresentationTerms: Set<String> = [
        "id", "type", "holder", "verifiableCredential",
        "VerifiablePresentation", "EnvelopedVerifiableCredential",
    ]
}

// MARK: - Enveloped credential

/// A credential that is already secured by its own JOSE envelope, referenced
/// from a presentation.
///
/// VC 2.0 §4.12 is easy to get wrong here and the failure is quiet: a compact
/// JWS is a *string*, and dropping that string straight into the
/// `verifiableCredential` array produces a document that still verifies and
/// still looks right, but whose credential disappears the moment anyone expands
/// it — the array expects nodes, not opaque strings. The wrapper is what makes
/// it a node.
///
/// The bytes matter as much as the shape. `id` holds the credential's compact
/// JWS **exactly as it was signed**; re-serialising the credential to embed it
/// would produce different bytes and an unverifiable signature, which is why
/// this type carries a string it never parses.
struct EnvelopedVerifiableCredential: Codable, Equatable {

    /// Carried even though the enclosing presentation already declares v2.
    /// JSON-LD would inherit it, but VC 2.0's own example spells it out, and an
    /// enveloped credential that is lifted out of a presentation and handled on
    /// its own then remains a complete document.
    let context: String
    /// `data:application/vc+jwt,<compact JWS>`.
    let id: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id
        case type
    }

    static let typeName = "EnvelopedVerifiableCredential"

    /// The media type registered by VC-JOSE-COSE for a credential secured with a
    /// compact JWS. No percent-encoding is needed after the comma because a
    /// compact JWS is base64url and dots — all of them legal in a `data:` URL.
    static let compactJWSPrefix = "data:application/vc+jwt,"

    /// A credential secured by the cardholder's 自然人憑證 rather than by a
    /// JOSE signature.
    ///
    /// Its own media type, not a variant of `vc+jwt`, and that is the load-bearing
    /// part. The envelope verifies under entirely different rules — an RSA
    /// signature over a digest, checked against a certificate that has to chain
    /// to MOICA G3 — so a verifier that reached for a JOSE library on seeing it
    /// would be wrong in the one direction that matters. An unrecognised media
    /// type is refused; a mislabelled one would be checked with the wrong
    /// machinery.
    ///
    /// `;base64,` because the envelope is JSON and a bare data URI would have to
    /// percent-encode the braces and quotes.
    static let moicaSignedPrefix = "data:application/vc+moica;base64,"

    static func enveloping(compactJWS jws: String) -> EnvelopedVerifiableCredential {
        EnvelopedVerifiableCredential(context: VerifiableCredential.credentialsV2Context,
                                      id: compactJWSPrefix + jws,
                                      type: typeName)
    }

    static func enveloping(moicaSigned serialized: String) -> EnvelopedVerifiableCredential {
        EnvelopedVerifiableCredential(
            context: VerifiableCredential.credentialsV2Context,
            id: moicaSignedPrefix + Data(serialized.utf8).base64EncodedString(),
            type: typeName)
    }

    /// The credential's original bytes, or `nil` if this envelope carries some
    /// other media type — which is what a future ZK proof would look like from
    /// here, and is a case a verifier has to handle rather than force-unwrap.
    var compactJWS: String? {
        guard id.hasPrefix(Self.compactJWSPrefix) else { return nil }
        return String(id.dropFirst(Self.compactJWSPrefix.count))
    }

    /// The card-signed envelope's serialization, or `nil` for any other media
    /// type.
    var moicaSignedSerialization: String? {
        guard id.hasPrefix(Self.moicaSignedPrefix) else { return nil }
        let encoded = String(id.dropFirst(Self.moicaSignedPrefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Building

extension VerifiablePresentation {

    /// Builds and signs a presentation of one stored credential.
    ///
    /// - Parameters:
    ///   - credentialJWS: The credential exactly as `CredentialStore` returned
    ///     it. Never re-encoded — see `EnvelopedVerifiableCredential`.
    ///   - request: The verifier's request. Its challenge is what makes the
    ///     signature mean "now" rather than "at some point".
    ///   - key: The device key. **Must already exist**: callers must not reach
    ///     for `DeviceKey.loadOrCreate` on this path, because a missing install
    ///     marker makes that call *generate a new identity*, and it would do so
    ///     at the counter, one line before the mismatch check below rejects the
    ///     credential it just orphaned.
    ///   - holderDID: What the caller believes this device's DID is. Checked
    ///     against the key rather than trusted, so a caller holding a stale DID
    ///     is told so instead of producing a presentation that fails at the far
    ///     end with no explanation.
    ///   - createdAt: Injectable so the signed bytes are reproducible in a
    ///     test; the default is what production uses.
    static func create(credentialJWS: String,
                       request: PresentationRequest,
                       signedBy key: DeviceKey,
                       holderDID: String,
                       disclosing: [String]? = nil,
                       createdAt: Date = Date()) throws -> String {
        // Checked before the key comparison so that a DID that is not a did:key
        // is reported as such. Reversing these two would make the shape error
        // unreachable, since a DID derived from a key is always a did:key.
        let keyID: String
        do {
            keyID = try VerifiableCredential.verificationMethodID(for: holderDID)
        } catch {
            throw VerifiablePresentationError.unsupportedHolderDID
        }

        let derivedDID: String
        do {
            derivedDID = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        } catch {
            throw VerifiablePresentationError.holderKeyUnusable
        }
        guard derivedDID == holderDID else {
            throw VerifiablePresentationError.holderKeyMismatch
        }

        // Holder binding. Without this the challenge proves only that *somebody*
        // holds *a* key: the credential is a self-contained signed file, so
        // anyone who obtains a copy could present it alongside a signature from
        // their own key. Compared against `credentialSubject.id` rather than
        // `issuer` because the subject is who the claims are about — which stays
        // correct on the day these credentials are issued by MOICA rather than
        // by the device itself.
        //
        // The stored credential may be either form. A card-signed envelope is
        // what this app issues now; a compact JWS is what it used to, and one is
        // still on disk for anyone who onboarded before that change. Refusing to
        // present the older one would take a working document away from the
        // people most likely to be relying on it, so both are enveloped here and
        // the *verifier* is where the difference in what they establish shows up.
        let enveloped: EnvelopedVerifiableCredential
        if var cardSigned = try? MOICASignedCredential.parse(credentialJWS) {
            guard try cardSigned.credential().credentialSubject["id"] == holderDID else {
                throw VerifiablePresentationError.credentialSubjectMismatch
            }
            // Withholding is *subtraction* and nothing else: the disclosures the
            // holder keeps back are simply not copied into what leaves the
            // device. The payload and its signature are untouched, which is the
            // property the whole scheme is built on — a verifier checks each
            // disclosure it receives against a digest the card signed, and never
            // notices the absence of the others except as a count.
            if let disclosing {
                let chosen = Set(disclosing)
                cardSigned.disclosures = cardSigned.disclosures.filter { encoded in
                    Disclosure(encoded: encoded).map { chosen.contains($0.claimName) } ?? false
                }
            }
            enveloped = .enveloping(moicaSigned: try cardSigned.serialized())
        } else {
            guard try subjectIdentifier(ofCredential: credentialJWS) == holderDID else {
                throw VerifiablePresentationError.credentialSubjectMismatch
            }
            enveloped = .enveloping(compactJWS: credentialJWS)
        }

        let presentation = VerifiablePresentation(
            context: [.url(VerifiableCredential.credentialsV2Context),
                      .definitions(presentationTermDefinitions)],
            type: [baseType],
            holder: holderDID,
            verifiableCredential: [enveloped],
            challenge: request.challenge,
            audience: request.audience,
            purpose: request.purpose,
            created: VerifiableCredential.timestamp(from: createdAt))

        let header: [String: String] = [
            "alg": "ES256",
            // VC-JOSE-COSE's media type for a secured presentation. `typ` is
            // also the only thing separating this from a credential signed by
            // the same key for a different purpose: JOSE has no `proofPurpose`,
            // so a verifier MUST check it. A credential accepted as a
            // presentation would be a signature made for an assertion being
            // read as proof of live possession.
            "typ": "vp+jwt",
            "cty": "vp",
            "kid": keyID,
        ]

        let encoder = canonicalEncoder
        let headerData = try encoder.encode(header)
        let payloadData = try encoder.encode(presentation)

        // The bytes that were base64url-encoded are the bytes that get signed;
        // re-encoding to verify would risk a different serialization.
        let signingInput = VerifiableCredential.base64URLEncoded(headerData)
            + "." + VerifiableCredential.base64URLEncoded(payloadData)
        let signature = try key.signature(for: Data(signingInput.utf8))

        guard signature.count == 64 else {
            throw VerifiablePresentationError.malformedSignature
        }

        return signingInput + "." + VerifiableCredential.base64URLEncoded(signature)
    }

    /// Reads `credentialSubject.id` out of a compact JWS without verifying it.
    ///
    /// Deliberately `JSONSerialization` rather than decoding into
    /// `VerifiableCredential`: that type models only the credentials this app
    /// issues — `credentialSubject` is `[String: String]`, and the inline
    /// context understands only two term-definition shapes — so a credential
    /// from another implementation would throw here and be reported as
    /// malformed when it is merely unfamiliar. Only one field is needed, so only
    /// one field is read.
    ///
    /// Not verifying is intentional. The credential came from this device's own
    /// protected store, this device signed it, and re-verifying it here would
    /// duplicate the job that belongs to the verifier — who has to do it anyway,
    /// and who is the only party for whom the answer means anything.
    static func subjectIdentifier(ofCredential jws: String) throws -> String {
        let segments = jws.components(separatedBy: ".")
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else {
            throw VerifiablePresentationError.malformedCredential
        }
        guard let payloadData = base64URLDecoded(segments[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData),
              let payload = object as? [String: Any],
              let subject = payload["credentialSubject"] as? [String: Any],
              let identifier = subject["id"] as? String,
              !identifier.isEmpty else {
            throw VerifiablePresentationError.malformedCredential
        }
        return identifier
    }

    /// A fresh encoder per call: `JSONEncoder` is a reference type and signing
    /// can happen off the main thread. `sortedKeys` is load-bearing for the same
    /// reason it is on the credential — Swift seeds dictionary ordering per
    /// process, and the signature covers the encoded bytes.
    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Written out here rather than borrowed from the credential's encoder,
    /// because base64url without padding is not what `Data(base64Encoded:)`
    /// accepts: the alphabet differs and the `=` run is absent.
    private static func base64URLDecoded(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}

extension VerifiablePresentationError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .holderKeyMismatch, .credentialSubjectMismatch:
            // The one case a user can act on: re-create the document. It happens
            // after an identity reset, and after the accidental rotation that a
            // crash between key generation and the install marker's flush can
            // cause — so it is a real state on real devices, not a theoretical
            // one.
            return NSLocalizedString("This document was created under an identifier this device no longer has.",
                                     comment: "")
        case .malformedCredential:
            return NSLocalizedString("A stored credential is damaged and cannot be read.", comment: "")
        case .unsupportedHolderDID, .holderKeyUnusable, .malformedSignature:
            return NSLocalizedString("This document could not be signed on this device.", comment: "")
        }
    }
}
