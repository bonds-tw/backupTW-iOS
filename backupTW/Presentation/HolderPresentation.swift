//
//  HolderPresentation.swift
//  backupTW
//

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

    private let store: CredentialStoring

    /// Injected, and the injection is the point: production must pass
    /// `DeviceKey.load`, never `DeviceKey.loadOrCreate`. `loadOrCreate` on this
    /// path can *generate a new identity* when the install marker is missing, and
    /// it would do it at the counter, immediately before
    /// `VerifiablePresentation.create` refuses the credential it just orphaned.
    /// Having one visible seam means the wrong call is a diff rather than a line
    /// buried in a view controller.
    private let loadKey: () throws -> DeviceKey?

    init(store: CredentialStoring, loadKey: @escaping () throws -> DeviceKey? = { try DeviceKey.load() }) {
        self.store = store
        self.loadKey = loadKey
    }

    /// The credential this device would present, or `nil` if it holds none.
    ///
    /// One credential is all this app issues, so there is no chooser and this
    /// takes the first identifier in `allIDs()`'s sorted order. When a second
    /// credential type arrives, the honest change is a picker — not a different
    /// rule here for which one is silently the important one.
    func storedCredentialID() throws -> String? {
        try store.allIDs().first
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
    func disclosableClaims() throws -> [(name: String, value: String)] {
        guard let credentialID = try storedCredentialID(),
              let stored = try store.load(id: credentialID),
              let envelope = try? MOICASignedCredential.parse(stored),
              let committed = try? envelope.credential().sd,
              let revealed = try? SelectiveDisclosure.reveal(disclosures: envelope.disclosures,
                                                             committedDigests: committed) else {
            return []
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
        guard let credentialID = try storedCredentialID(),
              let credentialJWS = try store.load(id: credentialID) else {
            throw HolderPresentationError.noCredentialStored
        }
        guard let key = try loadKey() else {
            throw HolderPresentationError.identityUnavailable
        }

        // Derived from the key rather than remembered, so the DID and the
        // signature cannot disagree. `VerifiablePresentation.create` checks the
        // same thing again from the other direction; that is not redundancy, it
        // is the check that catches a caller passing a stale DID it cached.
        let holderDID = try DIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)

        let jws = try VerifiablePresentation.create(credentialJWS: credentialJWS,
                                                    request: request,
                                                    signedBy: key,
                                                    holderDID: holderDID,
                                                    disclosing: disclosing,
                                                    createdAt: now)
        // UTF-8 bytes, not the string: `QRTransport` deflates and base45-encodes
        // whatever it is handed and never looks inside, which is what lets a ZK
        // proof object replace this line unchanged.
        return try QRTransport.frames(for: Data(jws.utf8))
    }
}
