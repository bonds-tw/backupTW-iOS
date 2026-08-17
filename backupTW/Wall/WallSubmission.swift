//
//  WallSubmission.swift
//  backupTW
//
//  The two files that go to the wall, and nothing else.
//

import Foundation

/// A proof, encoded for the wall.
///
/// # The single initialiser is the security boundary
///
/// It takes a `ZKProofBundle` and nothing else. Not `Data`, not a path, not a
/// `VerifiablePresentation`, not a `MOICASignedCredential`, not a `StoredCard`.
///
/// That is deliberate and it is the point of the type. The holder's X.509
/// certificate carries their legal name in the Subject CN, and this app holds
/// several other objects that would serialise happily into a request body. A
/// call site that could reach for one of them is a call site where a code
/// review is the only thing standing between a person and their name on a
/// public wall. Making it **not compile** is stronger than making it reviewed.
struct WallSubmission: Equatable, Sendable {

    /// Standard base64, with padding.
    ///
    /// Go's `encoding/json` decodes `[]byte` with `base64.StdEncoding`, so the
    /// URL-safe alphabet is rejected outright. Held as `String` rather than
    /// letting `JSONEncoder` choose, because its default is correct here and a
    /// default nobody has read is a default nobody will notice changing.
    let certChainProof: String
    let userSigProof: String

    /// What the encoded body will weigh. Checked before anything is sent.
    let encodedByteCount: Int

    /// Derived from the prover, never restated.
    ///
    /// `ZKProver.proofFilenames` carries a `keys/` prefix and
    /// `ZKProofBundle.proofDirectory` already ends in `keys`, so the names are
    /// taken apart rather than duplicated — two lists of filenames is how the
    /// prover and the sender start disagreeing about which files exist.
    static let artifactNames = ZKProver.proofFilenames.map {
        ($0 as NSString).lastPathComponent
    }

    /// # Why the two `*_instance.bin` files are not sent
    ///
    /// Because the Go request struct has no fields for them. That is the whole
    /// reason, and it is worth being precise because the *plausible* reason is
    /// false:
    ///
    /// ⚠️ Sending the instances would **not** expose more public signals.
    /// `linkverify` writes only the two proof files into its temporary keys
    /// directory; the public signals — nullifier, `pk_commit`, packed app id,
    /// challenge, the issuer modulus limbs, the SMT root — are pulled out of the
    /// proof bytes by the FFI. **All of them cross Cloudflare's edge and enter
    /// Cloud Run's memory either way.**
    ///
    /// Believing otherwise would make somebody later underestimate what this
    /// request discloses, which is why the correction is written here rather
    /// than left as an unstated assumption. What omitting them actually saves is
    /// about 103 KB and one opportunity to send the wrong file.
    static let maximumEncodedBytes = 1_500_000

    enum Failure: Error, Equatable {
        case artifactMissing(String)
        case tooLarge(bytes: Int)
    }

    /// Reads the two proof files out of a finished run.
    init(readingFrom bundle: ZKProofBundle) throws {
        var encoded: [String] = []
        for name in Self.artifactNames {
            let url = bundle.proofDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                throw Failure.artifactMissing(name)
            }
            encoded.append(data.base64EncodedString())
        }
        certChainProof = encoded[0]
        userSigProof = encoded[1]
        encodedByteCount = encoded.reduce(0) { $0 + $1.utf8.count }

        // # Refused here, not by the wall
        //
        // This is not about bandwidth. Go answers 413 above 2 MiB, the Worker
        // collapses every non-2xx from the verifier into `verifier-unavailable`
        // — and that branch has already **spent the challenge**. Refusing
        // locally keeps it, so the person is not charged a fresh round trip to
        // 內政部 for a proof that was never going to be accepted.
        //
        // A real proof is 190,798 bytes raw, about 254 KB encoded. The ceiling
        // is roughly six times that: generous enough to survive a change in
        // proof size, small enough to still be a limit.
        guard encodedByteCount <= Self.maximumEncodedBytes else {
            throw Failure.tooLarge(bytes: encodedByteCount)
        }
    }

    /// The request body.
    ///
    /// The challenge token goes back **exactly as it arrived**. Nothing here
    /// reassembles it, and no field carries anything about the signer — adding
    /// one would be the change to argue about, which is why the body is built in
    /// one place with a fixed set of keys rather than from a dictionary
    /// somebody could extend.
    func body(challengeToken: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "challenge": challengeToken,
                "certChainProof": certChainProof,
                "userSigProof": userSigProof,
            ],
            options: [.sortedKeys])
    }
}
