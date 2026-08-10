//
//  ZKProofPackage.swift
//  backupTW
//
//  The four files a ZK proof consists of, as one thing that can be handed over.
//

import Foundation

/// A proof, packaged so that somebody other than the device that made it can
/// check it.
///
/// # Why this is a file and not a QR code
///
/// `VerifiablePresentation` travels by QR because a card-signed credential JWS is
/// about 7.4 KB and `QRTransport` can chunk that across about fourteen frames
/// (`PresentationFrameCountTests`). A ZK proof cannot. Measured on 2026-08-08 by `VerifierCostSpike`, against real proofs
/// generated from upstream's own circuit inputs:
///
///     cert_chain_rs4096_proof.bin       113,055 bytes
///     user_sig_rs2048_proof.bin          77,743 bytes
///     cert_chain_rs4096_instance.bin     68,967 bytes
///     user_sig_rs2048_instance.bin       34,151 bytes
///     ────────────────────────────────────────────
///                                       293,916 bytes
///
/// That is not a QR payload at any frame size. Divided by version 40's ceiling of
/// 2,953 bytes it comes to 100 frames, which is the figure this comment used to
/// give and the source of the roadmap's 「約 100 張」 — but 2,953 is not the number
/// that applies. `QRTransport` pins symbols at 89 modules and error-correction
/// level Q so they survive being read off a phone screen, which leaves 364 bytes
/// per frame: **about 808 frames**. In practice it never gets that far, because
/// `QRTransport.frames(for:)` refuses any payload over 64 KB and this one is four
/// and a half times that — it is rejected outright rather than sharded. Even the
/// optimistic 100 frames, at a realistic five per second, is twenty seconds of
/// holding two phones still with no recovery for a dropped frame. So this format exists to be carried by something else — a
/// file, AirDrop, and eventually the Wi-Fi Aware or BLE transport M3 still owes.
///
/// The instances are in here because they are not optional decoration: they are
/// the public inputs, and `verifyCertChainRs4096` cannot run without them. A
/// package containing only the two proofs would be unverifiable, and would look
/// like a package.
///
/// # What travels and what deliberately does not
///
/// The two `*_input.json` witness files are **not** here, and must never be:
/// they contain the cardholder's certificate, RSA signature and public key —
/// the values the proof exists to keep hidden. `ZKProver.discardSecretArtifacts`
/// deletes them after proving for the same reason. If a future change makes this
/// type walk a directory rather than name its files, that change must keep
/// naming them, or the app will hand a verifier the very material it is
/// promising not to disclose.
struct ZKProofPackage: Codable, Equatable {

    /// The artifact names, in the order upstream's verifier looks for them.
    /// Deliberately the same strings as `ZKProver.proofFilenames` and
    /// `.instanceFilenames`, and checked against them by a test — two lists that
    /// have to agree and are written down twice is a bug waiting for a rename.
    static let artifactNames = [
        "cert_chain_rs4096_proof.bin",
        "user_sig_rs2048_proof.bin",
        "cert_chain_rs4096_instance.bin",
        "user_sig_rs2048_instance.bin"
    ]

    /// Bumped when the meaning of any field changes. A verifier that does not
    /// recognise the version refuses rather than guessing: a ZK proof read under
    /// the wrong assumptions is not a proof.
    ///
    /// Version 2 (2026-08-11) added `nullifierSharedAcrossVerifiers` to the
    /// caveat vocabulary. Reading stays backward-compatible — see
    /// `supportedVersions` — because a v1 package's six caveats mean today what
    /// they meant then. Writing is always the current version, so an *old* build
    /// handed a v2 package refuses it, which is the right direction to fail: it
    /// cannot display the caveat the package carries, and a caveat it cannot
    /// display is a caveat nobody reads.
    static let currentVersion = 2

    /// Versions this build can read. A range rather than an equality so that
    /// adding vocabulary does not orphan every proof exported before the bump.
    static let supportedVersions = 1...2

    let version: Int

    /// Artifact name → contents. A dictionary rather than four fields so that
    /// `artifactNames` stays the single place the set is defined.
    let artifacts: [String: Data]

    /// Everything this proof does *not* establish, carried with it.
    ///
    /// Copied from the producing `ZKProofBundle` rather than recomputed by the
    /// verifier, because several of them are facts about how the proof was made
    /// — whether the challenge came from a verifier, for instance — that are not
    /// recoverable from the artifacts. A verifier that dropped them would render
    /// a bare green tick for a proof carrying six named limitations.
    let caveats: [ProofCaveat]

    /// What the *producing* device said when it checked its own work.
    ///
    /// Advisory only, and labelled as such wherever it is shown. It is a claim
    /// by the party being checked, so it can be a lie; it is carried because
    /// "the holder's phone also could not verify this" is worth knowing when a
    /// verification fails here.
    let producerSelfCheckPassed: Bool

    enum PackagingError: Error, Equatable {
        case missingArtifact(String)
        case unsupportedVersion(Int)
        case artifactTooLarge(name: String, bytes: Int)
    }

    /// A ceiling on any single artifact, so a malicious package cannot ask this
    /// device to allocate its way into a jetsam kill before anything is checked.
    /// Ten times the largest artifact measured; generous enough that a change in
    /// circuit size does not trip it, small enough to be a limit.
    static let maximumArtifactBytes = 2_000_000

    // MARK: - Producing

    /// Reads the four artifacts out of the directory `ZKProver` left them in.
    init(readingFrom bundle: ZKProofBundle) throws {
        var artifacts: [String: Data] = [:]
        for name in Self.artifactNames {
            let url = bundle.proofDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                throw PackagingError.missingArtifact(name)
            }
            artifacts[name] = data
        }
        self.version = Self.currentVersion
        self.artifacts = artifacts
        self.caveats = bundle.caveats
        self.producerSelfCheckPassed = bundle.selfCheck.isConfirmed
    }

    // MARK: - Consuming

    /// Checks the envelope before anything expensive happens.
    ///
    /// Called by the verifier *before* it writes anything to disk or loads a
    /// gigabyte of keys, so a truncated or oversized package costs a parse and
    /// not a minute.
    func validate() throws {
        guard Self.supportedVersions.contains(version) else {
            throw PackagingError.unsupportedVersion(version)
        }
        for name in Self.artifactNames {
            guard let data = artifacts[name] else {
                throw PackagingError.missingArtifact(name)
            }
            guard data.count <= Self.maximumArtifactBytes else {
                throw PackagingError.artifactTooLarge(name: name, bytes: data.count)
            }
        }
    }

    /// Lays the artifacts out where upstream's verifier expects to find them:
    /// a `keys/` subdirectory of the path handed to `verify*`.
    ///
    /// Written with `.completeUnlessOpen` for the same reason `CredentialStore`
    /// uses it. A proof is not as sensitive as the certificate behind it, but it
    /// is somebody's identity document sitting in a verifier's scratch space,
    /// and the default protection class is readable on a locked seized phone.
    func write(into directory: URL) throws {
        let keys = directory.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(
            at: keys, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        for name in Self.artifactNames {
            guard let data = artifacts[name] else {
                throw PackagingError.missingArtifact(name)
            }
            try data.write(to: keys.appendingPathComponent(name),
                           options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    var totalByteCount: Int {
        artifacts.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Wire form

    /// JSON, because the payload is already ~294 KB of incompressible proof data
    /// and the base64 overhead is a third of that rather than the whole cost. A
    /// binary container would save ~98 KB and cost a hand-written parser on the
    /// side that reads untrusted input, which is the wrong trade here.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> ZKProofPackage {
        let package = try JSONDecoder().decode(ZKProofPackage.self, from: data)
        try package.validate()
        return package
    }
}
