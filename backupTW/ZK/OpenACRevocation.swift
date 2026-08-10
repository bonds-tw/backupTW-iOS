//
//  OpenACRevocation.swift
//  backupTW
//
//  The two OpenACSwift SMT calls, and nothing else.
//

import Foundation
import OpenACSwift

// MARK: - Why this is its own file
//
// Same reason `OpenACVerification` is: the test target links the app but **not**
// the OpenACSwift package, so every mention of an OpenACSwift type has to stay
// behind a file boundary the tests do not compile. `RevocationCheck` takes a
// `RevocationProofProviding` so its decisions can be driven by a stub; this file
// is the one implementation that talks to the library.

/// Builds SMT proofs from the downloaded snapshot.
struct OpenACRevocationProofProvider: RevocationProofProviding {

    func proof(inSnapshot snapshot: Data, forSerialNumberHex serialNumberHex: String)
        -> (root: String, isMember: Bool, verifies: Bool)? {
        // The key is the certificate serial number as hex. Upstream accepts it
        // with or without `0x` and caps it at 32 hex characters — a serial wider
        // than the tree's 128-bit depth is rejected rather than truncated, which
        // is the behaviour to preserve: a truncated serial would prove something
        // about a *different* certificate.
        let key = serialNumberHex.hasPrefix("0x") ? String(serialNumberHex.dropFirst(2))
                                                  : serialNumberHex
        guard key.count <= 32, !key.isEmpty, key.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        guard let proof = try? OpenACSwift.createSmtProofFromGz(gzData: snapshot, keyHex: key) else {
            return nil
        }
        // Verified against the proof's own root here, and against the
        // *snapshot's declared* root by `RevocationCheck`. Both are needed and
        // they catch different things: this one says the sibling path hashes up
        // to the root it claims, the other says that root is the tree the
        // snapshot says it is.
        let verifies = OpenACSwift.verifySmtProof(proof: proof, expectedRoot: proof.root)
        return (root: proof.root, isMember: proof.membership, verifies: verifies)
    }
}
