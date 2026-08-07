//
//  OpenACVerification.swift
//  backupTW
//
//  The three OpenACSwift verification calls, and nothing else.
//

import Foundation
import OpenACSwift

// MARK: - Why this is its own file
//
// `ZKProofRun.swift` deliberately does not `import OpenACSwift`. The test target
// links the app but **not** the package (`project.pbxproj` adds the OpenACSwift
// product dependency to the `backupTW` target's Frameworks phase only), so every
// mention of an OpenACSwift type has to stay inside a function body or a private
// type — the same pattern `ProvingBenchmark.OpenACBenchmarkRunner` and
// `ZKProver.OpenACProofBackend` already follow. Keeping the import on the far
// side of a file boundary makes that property auditable at a glance instead of
// by reading every declaration in a 600-line file.
//
// The error message is dropped here for the reason `ProofBackendFailure`
// documents at length: `ZkProofError.errorDescription` is `String(reflecting:
// self)`, so the Rust `msg:` travels wherever the error does, on a path whose
// input is a cardholder certificate.

extension OpenACProofVerifier {

    /// Verifies `cert_chain_rs4096` against `keys/cert_chain_rs4096_verifying.key`.
    static func verifyCertificateChain(documentsPath: String) throws -> Bool {
        do {
            return try OpenACSwift.verifyCertChainRs4096(documentsPath: documentsPath)
        } catch {
            throw ProofBackendFailure(error)
        }
    }

    static func verifyUserSignature(documentsPath: String) throws -> Bool {
        do {
            return try OpenACSwift.verifyUserSigRs2048(documentsPath: documentsPath)
        } catch {
            throw ProofBackendFailure(error)
        }
    }

    /// The one that matters for the whitepaper's offline story: it checks both
    /// proofs *and* that they belong together, entirely on this device, with no
    /// server in the loop.
    ///
    /// ⚠️ It still does not make a nullifier unique. Rejecting a nullifier that
    /// has been seen before needs a record shared between everyone who might see
    /// it, and offline there is none. `ProofCaveat.noGlobalUniqueness` is on
    /// every bundle for this reason and must not be dropped from any screen that
    /// reports this call returning `true`.
    static func linkVerify(documentsPath: String) throws -> Bool {
        do {
            return try OpenACSwift.linkVerify(documentsPath: documentsPath)
        } catch {
            throw ProofBackendFailure(error)
        }
    }
}
