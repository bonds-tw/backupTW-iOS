//
//  AgePredicateCircuitAssets.swift
//  backupTW
//
//  Immutable runtime files for the OpenAC age-predicate profile. Downloads use
//  the app's existing resumable, pinned CircuitAssets implementation; this file
//  only defines the independently reviewable manifest and holder/checker split.
//

import Foundation

enum AgePredicateAssetRole: Sendable {
    case prover
    case verifier
}

enum AgePredicateCircuitAssetCatalog {
    static let releaseTag = "openac-age-v1"

    private static let release = URL(
        string: "https://github.com/bonds-tw/backupTW-iOS/releases/download/\(releaseTag)")!

    private static func asset(name: String,
                              remoteFilename: String,
                              localFilename: String,
                              compressedByteCount: Int64,
                              installedByteCount: Int64,
                              compressedSHA256: String,
                              installedSHA256: String) -> CircuitAsset {
        CircuitAsset(
            name: name,
            remoteURL: release.appendingPathComponent(remoteFilename),
            localFilename: localFilename,
            sha256: compressedSHA256,
            compressedByteCount: compressedByteCount,
            installedByteCount: installedByteCount,
            installedSHA256: installedSHA256)
    }

    // Filled only from the release-gate vector's generated manifest. Both the
    // compressed transport and the exact bytes opened by the native verifier
    // are pinned so a republished GitHub asset cannot silently change policy.
    static let jwtR1CS = asset(
        name: "openac_age_jwt_r1cs",
        remoteFilename: "jwt_2k.r1cs.gz",
        localFilename: "circom/build/jwt/jwt_js/jwt.r1cs",
        compressedByteCount: 28_202_219,
        installedByteCount: 374_342_852,
        compressedSHA256: "efb45ed790e81fb6e1e3947f3749ee6ee1b3f03c069fff0227bd7ccb94d974a6",
        installedSHA256: "d4f8b34dfd454234872a34f47ea486545cb4d989c41ed75f856268718251dc6a")

    static let showR1CS = asset(
        name: "openac_age_show_r1cs",
        remoteFilename: "show.r1cs.gz",
        localFilename: "circom/build/show/show_js/show.r1cs",
        compressedByteCount: 590_365,
        installedByteCount: 4_017_428,
        compressedSHA256: "20d785277560fa96309832926bd7efc927e3976c0385b3e2bcae455ad4ad8c7d",
        installedSHA256: "3809e70502fa90f2038760da5f1399a1e3eb17923e5af872edf3dfa0b7d37a9a")

    static let prepareProvingKey = asset(
        name: "openac_age_prepare_proving",
        remoteFilename: "prepare_proving.key.gz",
        localFilename: "circom/keys/prepare_proving.key",
        compressedByteCount: 23_609_142,
        installedByteCount: 431_866_474,
        compressedSHA256: "3b45f8b1c24e5e82fc2462ed819a73fab0167dcce303e15e272fc6f99e44a277",
        installedSHA256: "853657d2e701215a65c5d97ab3cf5640e9aa8379ac6d106b7c82dc9b9d078e79")

    static let prepareVerifyingKey = asset(
        name: "openac_age_prepare_verifying",
        remoteFilename: "prepare_verifying.key.gz",
        localFilename: "circom/keys/prepare_verifying.key",
        compressedByteCount: 23_609_093,
        installedByteCount: 431_866_442,
        compressedSHA256: "d84ef20b28f0dd26b836022fc023424592d476a80b54d9ab80d51e43f698ee6a",
        installedSHA256: "9b45cc7462a236b1056d21c19e1e4dfc2cf52fd20538d43fbe072d9ed106e9d6")

    static let showProvingKey = asset(
        name: "openac_age_show_proving",
        remoteFilename: "show_proving.key.gz",
        localFilename: "circom/keys/show_proving.key",
        compressedByteCount: 575_666,
        installedByteCount: 4_862_778,
        compressedSHA256: "fa34e2cefe8da70476843f0a7037e249c7b1cf13c5c26a3f09a268393de61223",
        installedSHA256: "809f24ca6ee003b684e2282b77f5a47279528edee7654a3801770a2ffca67831")

    static let showVerifyingKey = asset(
        name: "openac_age_show_verifying",
        remoteFilename: "show_verifying.key.gz",
        localFilename: "circom/keys/show_verifying.key",
        compressedByteCount: 575_630,
        installedByteCount: 4_862_746,
        compressedSHA256: "b6daa9cefd23d27ce80bd182ced987caa1a4eeb91083fc6ceafbeb1210dfbad0",
        installedSHA256: "f0c447a9757d182e8aa23083bc3dba5a9a22f3e0fcbb344724568cc3c83352d8")

    /// A phone producing a proof needs the two constraints and both key pairs.
    /// Keeping the verifying keys here also lets it fail closed by checking its
    /// own newly created linked proof before anything is sent.
    static let proverAssets = [jwtR1CS, showR1CS,
                               prepareProvingKey, prepareVerifyingKey,
                               showProvingKey, showVerifyingKey]

    /// The iPad opens only public verification keys. It never downloads the
    /// holder's R1CS or proving keys merely to check a received proof.
    static let verifierAssets = [prepareVerifyingKey, showVerifyingKey]

    static func assets(for role: AgePredicateAssetRole) -> [CircuitAsset] {
        switch role {
        case .prover: proverAssets
        case .verifier: verifierAssets
        }
    }

    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return base.appendingPathComponent("OpenACAge-v1", isDirectory: true)
    }
}

actor AgePredicateCircuitAssetPreparer {
    typealias Progress = @Sendable (Double) -> Void

    private let directory: URL

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? AgePredicateCircuitAssetCatalog.defaultDirectory()
    }

    /// Returns the `documentsPath` expected by the Mopro mobile binding.
    func prepare(_ role: AgePredicateAssetRole,
                 allowDownloads: Bool = true,
                 progress: @escaping Progress = { _ in }) async throws -> URL {
        let assets = AgePredicateCircuitAssetCatalog.assets(for: role)
        let store = CircuitAssets.makeNetworkStore(directory: directory, assets: assets)
        let inspections = await store.inspectInstalledAssets()
        let needed = inspections.filter { !$0.integrity.isValid }
        if needed.isEmpty {
            progress(1)
            return directory.appendingPathComponent("circom", isDirectory: true)
        }

        // Once a local request is being answered, missing/corrupt material must
        // never trigger a repair download in the middle of an offline check.
        guard allowDownloads else { throw AgePredicateProofError.offlineAssetsMissing }

        let total = max(Int64(1), needed.reduce(0) { $0 + max(Int64(1), $1.asset.compressedByteCount) })
        var completed: Int64 = 0
        for inspection in needed {
            let asset = inspection.asset
            if inspection.integrity.needsRepair {
                let isolated = CircuitAssets.makeNetworkStore(directory: directory, assets: [asset])
                try await isolated.deleteAll()
            }
            let weight = max(Int64(1), asset.compressedByteCount)
            let completedBeforeAsset = completed
            _ = try await store.download(asset) { fraction in
                progress((Double(completedBeforeAsset) + Double(weight) * fraction) / Double(total))
            }
            completed += weight
            progress(Double(completed) / Double(total))
        }

        let final = await store.inspectInstalledAssets()
        guard final.allSatisfy(\.integrity.isValid) else {
            throw AgePredicateProofError.nativeEngineUnavailable
        }
        return directory.appendingPathComponent("circom", isDirectory: true)
    }
}
