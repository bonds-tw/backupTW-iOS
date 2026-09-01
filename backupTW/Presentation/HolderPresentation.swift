//
//  HolderPresentation.swift
//  backupTW
//

import CryptoKit
import Foundation

enum HolderPresentationError: Error, Equatable {
    /// Nothing to present — the device has never issued a credential, or the
    /// user erased everything.
    case noCredentialStored
    /// No device key belongs to this install, so nothing can be signed. Distinct
    /// from `noCredentialStored`: a credential without its key is the identity
    /// reset case, and the user is told to create the document again rather than
    /// that they never had one.
    case identityUnavailable
}

extension HolderPresentationError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .noCredentialStored:
            return NSLocalizedString("There is no document on this device to show yet.", comment: "")
        case .identityUnavailable:
            return NSLocalizedString("This document was created under an identifier this device no longer has.",
                                     comment: "")
        }
    }
}

/// The holder's side of an offline check: take the verifier's request, sign a
/// presentation of the stored credential, and shard it into scannable frames.
///
/// Three moving parts that were written separately (`CredentialStore`,
/// `VerifiablePresentation`, `QRTransport`) meet here, and the joins are where
/// the mistakes are, so they are made once in a type that can be driven by a
/// test rather than three times inside view controllers that cannot.
///
/// # ⚠️ Every presentation this builds carries the same identifier
///
/// The credential's `issuer`, its `credentialSubject.id` and the presentation's
/// `holder` are one `did:key`, and a `did:key` is the public key written out —
/// so it is the same string on the tenth check as on the first. Two verifiers
/// comparing notes can prove they saw the same person; one verifier can count
/// visits. That is a miss against the whitepaper's unlinkability floor, it is
/// not fixed anywhere below this line, and the screen that calls this **must say
/// so before the user presents**, not after. See `VerifiablePresentation` for
/// why (ZK selective disclosure, blocked upstream on licensing) and for the seam
/// left open so it can be swapped in without touching the transport or the
/// scanner.
struct HolderPresentation {

    struct PredicateCredentialMaterial {
        let serialized: String
        let key: DeviceKey
    }

    private let store: CredentialStoring

    /// Injected, and the injection is the point: production must pass
    /// `DeviceKey.load`, never `DeviceKey.loadOrCreate`. `loadOrCreate` on this
    /// path can *generate a new identity* when the install marker is missing, and
    /// it would do it at the counter, immediately before
    /// `VerifiablePresentation.create` refuses the credential it just orphaned.
    /// Having one visible seam means the wrong call is a diff rather than a line
    /// buried in a view controller.
    private let loadKey: (String) throws -> DeviceKey?

    /// Production resolves the key from the DID inside the stored credential.
    /// This covers both new per-card keys and the legacy app key without a
    /// second credential-to-key lookup table that could drift.
    init(store: CredentialStoring) {
        self.store = store
        let keyring = HolderKeyring.app()
        self.loadKey = { serialized in
            try Self.key(for: serialized, in: keyring)
        }
    }

    /// Injectable keyring for proving that a credential selects its own key.
    init(store: CredentialStoring, keyring: HolderKeyring) {
        self.store = store
        self.loadKey = { serialized in
            try Self.key(for: serialized, in: keyring)
        }
    }

    /// Test seam for refusal and holder-binding cases that deliberately supply
    /// a key unrelated to the app Keychain.
    init(store: CredentialStoring, loadKey: @escaping () throws -> DeviceKey?) {
        self.store = store
        self.loadKey = { _ in try loadKey() }
    }

    /// The credential this device would present, or `nil` if it holds none.
    ///
    /// # Selected by kind, not by sort order
    ///
    /// This used to be `store.allIDs().first`, with a note saying a picker was
    /// the honest change once a second credential type arrived. The second type
    /// is arriving, and taking the first identifier turns out not to be a
    /// neutral placeholder but a **wrong** answer waiting to be triggered: the
    /// self-issued document's id is `national-id`, a TWDIW identifier derived
    /// from its credential configuration starts with a digit, and digits sort
    /// before letters. The first TWDIW card to land would silently become the
    /// document this device presents.
    ///
    /// And it would not fail cleanly. This path builds a
    /// `VerifiablePresentation` over this app's own format; handed an SD-JWT it
    /// produces a refusal about a document the holder never chose to show.
    ///
    /// So the rule is now what it always meant: **this path presents the
    /// self-issued document.** TWDIW cards are presented over OID4VP, which is a
    /// different flow and not this function's business. A picker is still the
    /// right answer for two self-issued documents; that is a smaller and much
    /// later problem than the one this fixes.
    func storedCredentialID(for source: PresentationCredentialSource = .selfIssued) throws -> String? {
        for id in try store.allIDs() {
            guard let serialized = try store.load(id: id) else { continue }
            let storedSource = StoredCardSource.source(of: serialized)
            if (source == .selfIssued && storedSource == .selfIssued)
                || (source == .twdiw && storedSource == .twdiw) { return id }
        }
        return nil
    }

    /// Builds the answer to `request` and shards it for display.
    ///
    /// Returns the frames rather than one string because the presentation does
    /// not fit in a single QR code and cannot be made to — see
    /// `VerifiablePresentation`'s size note. A caller with one frame and a caller
    /// with six run the same code path; only the carousel notices.
    ///
    /// - Parameter now: the holder's clock, stamped into the signed document as
    ///   `created`. Injectable so the signed bytes are reproducible in a test.
    /// The claims the stored credential can disclose, in reading order.
    ///
    /// Empty for a credential issued before selective disclosure: those carry
    /// their claims in the clear and the holder has no choice to make, which the
    /// screen has to say rather than present as an empty list of options.
    func disclosableClaims(for source: PresentationCredentialSource = .selfIssued) throws -> [(name: String, value: String)] {
        guard let credentialID = try storedCredentialID(for: source),
              let stored = try store.load(id: credentialID) else { return [] }
        let revealed: [(name: String, value: String)]
        switch source {
        case .selfIssued:
            guard let envelope = try? MOICASignedCredential.parse(stored),
                  let committed = try? envelope.credential().sd,
                  let disclosures = try? SelectiveDisclosure.reveal(disclosures: envelope.disclosures,
                                                                    committedDigests: committed) else { return [] }
            revealed = disclosures
        case .twdiw:
            guard let credential = try? TWDIWCredentialReader.read(stored) else { return [] }
            revealed = credential.disclosedClaims
        }
        let order = StoredNationalID.displayOrder
        return revealed.sorted {
            (order.firstIndex(of: $0.name) ?? order.count,
             $0.name) < (order.firstIndex(of: $1.name) ?? order.count, $1.name)
        }
    }

    /// - Parameter disclosing: the claim names to hand over. `nil` discloses
    ///   everything, which is what a credential with nothing to withhold does
    ///   anyway; an empty array discloses nothing but the subject identifier,
    ///   which is a legitimate answer to "prove you hold a document".
    func frames(answering request: PresentationRequest,
                disclosing: [String]? = nil,
                now: Date = Date()) throws -> [String] {
        // UTF-8 bytes, not the string: `QRTransport` deflates and base45-encodes
        // whatever it is handed and never looks inside, which is what lets a ZK
        // proof object replace this line unchanged.
        try QRTransport.frames(for: try presentation(answering: request,
                                                     disclosing: disclosing,
                                                     now: now))
    }

    /// The signed presentation itself.
    ///
    /// `frames(answering:)` shards this for a camera; `LinkTransport` shards the
    /// same bytes for a radio. One signing path, two shardings — two
    /// presentations answering one challenge would be two chances to be
    /// replayed, and the verifier's single-use rule would refuse the second
    /// anyway.
    func presentation(answering request: PresentationRequest,
                      disclosing: [String]? = nil,
                      now: Date = Date()) throws -> Data {
        guard let credentialID = try storedCredentialID(for: request.credentialSource),
              let credentialJWS = try store.load(id: credentialID) else {
            throw HolderPresentationError.noCredentialStored
        }
        guard let key = try loadKey(credentialJWS) else {
            throw HolderPresentationError.identityUnavailable
        }

        let jws: String
        switch request.credentialSource {
        case .selfIssued:
            // The app's own historical p256-pub DID spelling.
            let holderDID = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
            jws = try VerifiablePresentation.create(credentialJWS: credentialJWS,
                                                     request: request,
                                                     signedBy: key,
                                                     holderDID: holderDID,
                                                     disclosing: disclosing,
                                                     createdAt: now)
        case .twdiw:
            let credential = try TWDIWCredentialReader.read(credentialJWS, now: now)
            guard credential.holderKey.x963Representation == key.publicKeyX963 else {
                throw HolderPresentationError.identityUnavailable
            }
            // TWDIW uses the jwk_jcs-pub did:key spelling. Preserve the subject
            // DID the issuer signed rather than changing the same key into this
            // app's shorter p256-pub spelling.
            let holderDID = credential.subjectDID
            let chosen = Set(disclosing ?? credential.disclosedClaims.map(\.name))
            let serialized = OID4VPResponder.reserialise(credential, disclosing: chosen)
            jws = try VerifiablePresentation.create(
                enveloping: .enveloping(sdJWT: serialized),
                request: request,
                signedBy: key,
                holderDID: holderDID,
                createdAt: now)
        }
        return Data(jws.utf8)
    }

    /// The same stored bytes and per-card key used by ordinary presentation,
    /// exposed as one indivisible value for the field-proof pipeline. Resolving
    /// by the public key inside the credential avoids a second identifier-to-key
    /// table that could drift.
    func predicateCredentialMaterial(for source: PresentationCredentialSource)
        throws -> PredicateCredentialMaterial {
        guard let credentialID = try storedCredentialID(for: source),
              let serialized = try store.load(id: credentialID) else {
            throw HolderPresentationError.noCredentialStored
        }
        guard let key = try loadKey(serialized) else {
            throw HolderPresentationError.identityUnavailable
        }
        return PredicateCredentialMaterial(serialized: serialized, key: key)
    }

    private static func key(for serialized: String,
                            in keyring: HolderKeyring) throws -> DeviceKey? {
        if let credential = try? TWDIWCredentialReader.read(serialized) {
            return try? keyring.key(matchingPublicKeyX963: credential.holderKey.x963Representation)
        }
        let credential: VerifiableCredential?
        if let envelope = try? MOICASignedCredential.parse(serialized) {
            credential = try? envelope.credential()
        } else {
            let segments = serialized.split(separator: ".", omittingEmptySubsequences: false)
            if segments.count == 3,
               let payload = MOICASignedCredential.base64URLDecoded(String(segments[1])) {
                credential = try? JSONDecoder().decode(VerifiableCredential.self, from: payload)
            } else {
                credential = nil
            }
        }
        guard let did = credential?.credentialSubject["id"],
              let publicKey = try? DIDKey.p256PublicKey(fromDID: did) else { return nil }
        return try? keyring.key(matchingPublicKeyX963: publicKey.x963Representation)
    }
}
