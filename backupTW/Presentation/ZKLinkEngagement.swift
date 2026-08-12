//
//  ZKLinkEngagement.swift
//  backupTW
//
//  An address, not a challenge. The distinction is the whole point of this file.
//

import Foundation

/// What the ZK verifier's screen puts in a QR code so a holder's phone can find
/// it over Bluetooth.
///
/// # Why this is not a `PresentationRequest`
///
/// The obvious implementation reuses `PresentationRequest`: it already carries a
/// `linkServiceID`, it is already drawn as a QR by the other verifier screen, and
/// the two flows would then look the same. They would look the same, and one of
/// them would be lying.
///
/// `PresentationRequest`'s reason for existing is its `challenge` — a fresh
/// random value the holder's signature has to cover, so that a presentation
/// photographed off somebody's screen cannot be handed back to the same reader.
/// `OfflineVerifier` compares it, `VerifierSession` spends it exactly once, and
/// the whole replay story rests on that one field.
///
/// **This type had a wrong reason for omitting one, and the wrong reason is
/// corrected here rather than deleted.** The first version of this comment said
/// 「a ZK proof cannot answer a challenge」. That is false. `ZKProver` takes a
/// challenge, it enters the circuit as a public input, and
/// `go-zkid-verifier`'s `ParsedInputs` reads it back out alongside `nullifier`,
/// `app_id` and `smt_root`. `ProofCaveat.challengeNotBoundToVerifier` exists
/// precisely because a *verifier-supplied* challenge is the better case that
/// this app is not achieving — a caveat that would make no sense if the thing
/// were impossible.
///
/// The true reasons are two, and they are narrower:
///
/// **1. This app proves before it knows who is asking.** Producing a proof needs
/// the cardholder's card, a round trip to 內政部, about two gigabytes of circuit
/// material and minutes of CPU. The ZK screen therefore proves first and hands
/// the finished package over afterwards — so at the moment this code is scanned,
/// the proof already exists and its challenge was minted by the holder's own
/// device. There is no verifier challenge for it to have answered. Putting one
/// in this QR would name a value nothing downstream could compare it to.
///
/// **2. Even bound, it would prove less than the card-signed path's does.**
/// `ProofCaveat.signatureMaterialIsReplayable`: TW FidO's SIGN flow signs
/// `base64(UTF8(app_id))`, a constant, so `(cert, signed_response)` mints a
/// valid proof for **any** challenge, forever, with no cardholder present. A
/// bound challenge would establish that *this proof object* was made after the
/// checker asked — real, and worth having — but not that the cardholder was
/// there. Those are different claims and a screen must not merge them.
///
/// So: no challenge here, because the flow that would supply it does not exist
/// yet — not because the mechanism does not. If proving ever becomes cheap
/// enough to do after engagement, this type should grow a challenge and the
/// verifier should compare it, and that is a real improvement rather than a
/// theoretical one. Until then the screen says the code is an address, which is
/// what it is.
///
/// What it *is* for: telling the holder's phone which Bluetooth service to look
/// for, and telling the holder what the checker says the check is for. Both are
/// real, and neither is a security claim.
///
/// # Why the identifier is per-exchange anyway
///
/// A fresh `UUID` each time, even though nothing here is a secret. A verifier
/// that advertised a fixed identifier would be a beacon: any phone in the room
/// could recognise 「that counter」 across visits, and the holder's phone would
/// broadcast a stable identifier of its own by answering. Unlinkability is
/// already lost on the ZK path in a worse way — the nullifier is the same value
/// for every checker (`ProofCaveat.nullifierSharedAcrossVerifiers`) — but that is
/// a reason to stop adding to the pile, not a reason to stop caring.
struct ZKLinkEngagement: Equatable {

    /// Bumped if the meaning of a field changes. A reader that does not
    /// recognise the version refuses rather than guessing.
    static let currentVersion = 1

    /// How long a code stays worth scanning.
    ///
    /// Not a security boundary — there is nothing here to protect — but a screen
    /// left open on a counter overnight should not still be advertising a
    /// service nobody is listening on. Matched to `PresentationRequest`'s
    /// lifetime so the two screens age out together and neither reads as the
    /// more permissive one.
    static let lifetime: TimeInterval = VerifierSession.pendingRequestLifetime

    let version: Int

    /// The Bluetooth service the verifier is scanning for.
    let serviceID: UUID

    /// What the checker says this check is for, shown to the holder before they
    /// send anything. Echoed nowhere and compared to nothing — unlike the
    /// card-signed path, where `purpose` travels inside the signed presentation
    /// and `OfflineVerifier` checks it. Here it is a courtesy, and calling it
    /// anything more would be the same mistake as inventing a challenge.
    let purpose: String

    let createdAt: Date

    init(serviceID: UUID, purpose: String, createdAt: Date = Date()) {
        self.version = Self.currentVersion
        self.serviceID = serviceID
        self.purpose = purpose
        self.createdAt = createdAt
    }

    /// True while the code is still worth scanning.
    func isCurrent(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        // Negative ages are a clock difference between two devices, not a
        // forgery — nothing here is signed, so there is nothing to forge. A
        // holder whose clock runs slow should still be able to scan.
        return age <= Self.lifetime
    }
}

// MARK: - Wire format

extension ZKLinkEngagement {

    /// Single-letter keys, and the same letters `PresentationRequest` uses for
    /// the fields they share. A QR code drawn at 89 modules holds a few hundred
    /// bytes; every byte spent on a key name is a byte not spent on error
    /// correction.
    private enum Key: String {
        case version = "v"
        case serviceID = "b"
        case purpose = "p"
        case createdAt = "t"
        /// Never written here. Read only so that a `PresentationRequest` can be
        /// recognised and refused — see `DecodingFailure.isACardSignedRequest`.
        case challenge = "c"
    }

    enum DecodingFailure: Error, Equatable {
        case notJSON
        case missingField(String)
        case unsupportedVersion(Int)
        /// Present and not a UUID. Distinguished from missing so a mangled scan
        /// and a code from a different app report differently.
        case malformedServiceID(String)
        /// The code was a `PresentationRequest` — the other verifier screen's.
        ///
        /// **This case exists because a test caught the alternative.** The two
        /// formats share `v`, `b`, `p` and `t`; the only structural difference is
        /// that a request also carries `c`, its challenge. A decoder that ignored
        /// unknown keys — which this one did — accepted a card-signed request
        /// happily, dropped the challenge on the floor, and connected. The holder
        /// would then send a 400 KB ZK package to a screen waiting for an 8 KB
        /// signed presentation, which refuses it as `presentationIsNotAJWS`
        /// *after* spending the challenge on it.
        ///
        /// Failing safe is not the same as failing legibly. Two codes that look
        /// alike and mean different things have to be told apart at the point of
        /// reading, and the holder deserves 「that is the code for the other kind
        /// of check」 rather than a transfer that completes and is then refused
        /// for a reason naming neither screen.
        case isACardSignedRequest
    }

    /// Compact JSON, sorted keys, no escaped slashes — byte-identical for the
    /// same input on every run, which is what makes the QR reproducible in tests.
    func encodedForTransport() throws -> String {
        let object: [String: Any] = [
            Key.version.rawValue: version,
            Key.serviceID.rawValue: serviceID.uuidString,
            Key.purpose.rawValue: purpose,
            Key.createdAt.rawValue: Int(createdAt.timeIntervalSince1970),
        ]
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads one back, refusing anything it does not fully understand.
    ///
    /// Every failure is distinguishable, because a camera pointed at a counter
    /// sees a lot of QR codes that are not this one, and 「that was some other
    /// code」 has to be told apart from 「that was ours and it was broken」.
    static func decode(from text: String) throws -> ZKLinkEngagement {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingFailure.notJSON
        }
        // Checked before anything else, so that a card-signed request is named
        // as one rather than being reported for whichever of its fields this
        // format happens to disagree with first.
        guard object[Key.challenge.rawValue] == nil else {
            throw DecodingFailure.isACardSignedRequest
        }
        guard let version = object[Key.version.rawValue] as? Int else {
            throw DecodingFailure.missingField(Key.version.rawValue)
        }
        guard version == currentVersion else {
            throw DecodingFailure.unsupportedVersion(version)
        }
        guard let identifier = object[Key.serviceID.rawValue] as? String else {
            throw DecodingFailure.missingField(Key.serviceID.rawValue)
        }
        guard let serviceID = UUID(uuidString: identifier) else {
            throw DecodingFailure.malformedServiceID(identifier)
        }
        guard let purpose = object[Key.purpose.rawValue] as? String else {
            throw DecodingFailure.missingField(Key.purpose.rawValue)
        }
        guard let seconds = object[Key.createdAt.rawValue] as? Int else {
            throw DecodingFailure.missingField(Key.createdAt.rawValue)
        }
        return ZKLinkEngagement(serviceID: serviceID,
                                purpose: purpose,
                                createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
