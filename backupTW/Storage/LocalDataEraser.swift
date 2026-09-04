//
//  LocalDataEraser.swift
//  backupTW
//

import Foundation

/// The single place "delete everything I have on this phone" is implemented.
///
/// It exists because `CredentialStore.deleteAll()` was quietly not that. It
/// erases the issued credentials, which is the part the app is proud of, and
/// leaves untouched the plaintext that produced them: the MyData zip and the
/// household-registration PDF unpacked from it. A user who taps the button and
/// is told their data is gone would still be carrying their full household
/// record — name, national ID number, address, everyone they live with — in the
/// clear. A deletion promise that is 90% true is worse than no promise, because
/// the user acts on it.
///
/// So the promise is kept in one type, and every location that has ever held
/// this data is swept from here. Anything added later that writes identity data
/// to disk belongs in `eraseEverything()` on the same day it is written.
///
/// **That rule was broken once already, by the ZK working directory.** Proving
/// writes the holder's certificate — expanded into circuit limbs, serial number
/// and all — plus a 62 MB witness holding every private wire, into Application
/// Support, and this type did not know the directory existed. The path that
/// makes it more than a tidiness point: proving peaks around two gigabytes, a
/// 4 GB iPhone kills the app for it, and a killed process never reaches
/// `ZKProver.prove`'s `defer`. So the realistic sequence is a jetsam kill, a
/// relaunch, a tap on 「清除所有本機資料」, an alert saying it is done, and every
/// one of those files still on disk. See `proofArtifactFilenames`.
///
/// **That includes the device key.** The Secure Enclave key is not a file, so it
/// is easy to forget when thinking about "data on disk", and forgetting it
/// defeats the erase: the key alone re-derives the same `did:key` on the next
/// launch, so a user who erased everything and re-onboarded hands a verifier the
/// identifier they used before. Every future presentation stays linkable to the
/// history they believed they had destroyed. `CredentialStore.deleteAll()`
/// deliberately does *not* touch the key — see `IdentityReset` for why the
/// routine "clear my credentials" case must be able to keep its identifier — but
/// this type is the other request, the one whose name promises there is nothing
/// left, so here the identity goes too.
struct LocalDataEraser {

    /// Left over from the versions that downloaded into Documents. See
    /// `eraseLegacyPlaintext(in:)`.
    private static let legacyResidueExtensions: Set<String> = ["zip", "pdf"]

    /// Everything one proof run leaves in the ZK working directory that came
    /// from the cardholder.
    ///
    /// Composed from `ZKProver`'s own four lists rather than restated, so a file
    /// added there cannot quietly stop being erased here — which is the whole
    /// reason those lists are not `private`.
    ///
    /// All four, not only the two `ZKProver.discardSecretArtifacts()` removes:
    ///
    ///   * the input JSONs are the holder's certificate expanded into circuit
    ///     limbs, serial number included;
    ///   * the witnesses are the assignment of every private wire in the
    ///     circuit — about 62 MB of it for `certChainRS4096`;
    ///   * the instances carry the nullifier, which is a *stable pseudonym* for
    ///     this holder at this relying party. Leaving it behind leaves exactly
    ///     the linkage the erase button exists to break, which is the same
    ///     reason the device key goes;
    ///   * the proofs are the deliverable, and a deliverable minted from a
    ///     certificate the user has just asked to be forgotten is not a thing to
    ///     keep.
    ///
    /// Deliberately **absent**: the two proving keys, the revocation snapshot
    /// and `MOICA-G3.cer`. Those are public circuit material from a GitHub
    /// release, identical on every device and about nobody, and silently
    /// deleting ~950 MB the user would have to download again is a different
    /// promise from the one this button makes.
    static var proofArtifactFilenames: [String] {
        ZKProver.inputFilenames + ZKProver.witnessFilenames
            + ZKProver.instanceFilenames + ZKProver.proofFilenames
    }

    private let credentials: CredentialStoring
    private let scratch: MyDataScratch
    /// The vault originals kept as evidence (保險箱原檔先儲存). This store holds the
    /// most sensitive plaintext the app keeps *on purpose*, so "erase everything"
    /// must take it too — `nil` only when Application Support cannot be resolved,
    /// the same condition under which nothing was ever written there.
    private let vaultArchive: MyDataVaultArchive?
    /// Prototype consent and, later, original government envelopes plus delivery
    /// evidence. A new on-disk identity surface belongs in the erase promise on
    /// the same day it is introduced.
    private let officialDocumentInbox: OfficialDocumentInboxArchive?
    private let documentsDirectory: URL?
    /// Where `ZKProver` works. `nil` only when Application Support cannot be
    /// resolved at all — the same condition under which nothing was ever written
    /// there.
    private let zkWorkingDirectory: URL?
    private let keyTag: String
    private let installRecord: UserDefaults?
    /// Optional in injected/test instances so a test can never sweep the real
    /// app-wide Keychain namespace. The production initializer supplies both.
    private let holderKeyring: HolderKeyring?
    private let walletIdentityTag: String?
    /// The App Attest private key is Apple-managed and has no delete API, but
    /// the local key ID is what lets this installation reuse it. Removing that
    /// record ensures the next UAT/signing action creates a new installation
    /// key instead of silently preserving linkage after "erase everything".
    private let appAttestRecordEraser: (() throws -> Void)?
    /// The optional MyData autofill profile contains the two identity values the
    /// user explicitly asked this phone to remember. It is a Keychain item and
    /// therefore has to be named here; deleting files alone cannot reach it.
    private let myDataProfileEraser: (() throws -> Void)?
    /// Slow-request continuation metadata contains no identity values, but an
    /// erase must also stop the app saying that an old request is still pending.
    private let pendingRequestEraser: (() -> Void)?

    /// `keyTag` and `installRecord` are injectable for the same reason the
    /// directories are: the Keychain is a process-wide namespace, so a test that
    /// used the defaults would destroy the real device key of whoever ran it.
    init(credentials: CredentialStoring,
         scratch: MyDataScratch = MyDataScratch(),
         vaultArchive: MyDataVaultArchive? = try? MyDataVaultArchive(),
         officialDocumentInbox: OfficialDocumentInboxArchive? = try? OfficialDocumentInboxArchive(),
         documentsDirectory: URL? = FileManager.default.urls(for: .documentDirectory,
                                                             in: .userDomainMask).first,
         zkWorkingDirectory: URL? = try? CircuitAssets.defaultDirectory(),
         keyTag: String = DeviceKey.defaultTag,
         installRecord: UserDefaults? = .standard,
         holderKeyring: HolderKeyring? = nil,
         walletIdentityTag: String? = nil,
         appAttestRecordEraser: (() throws -> Void)? = nil,
         myDataProfileEraser: (() throws -> Void)? = nil,
         pendingRequestEraser: (() -> Void)? = nil) {
        self.credentials = credentials
        self.scratch = scratch
        self.vaultArchive = vaultArchive
        self.officialDocumentInbox = officialDocumentInbox
        self.documentsDirectory = documentsDirectory
        self.zkWorkingDirectory = zkWorkingDirectory
        self.keyTag = keyTag
        self.installRecord = installRecord
        self.holderKeyring = holderKeyring
        self.walletIdentityTag = walletIdentityTag
        self.appAttestRecordEraser = appAttestRecordEraser
        self.myDataProfileEraser = myDataProfileEraser
        self.pendingRequestEraser = pendingRequestEraser
    }

    /// The app's own wiring: the real store, in the real locations.
    init() throws {
        self.init(credentials: try CredentialStore(),
                  holderKeyring: .app(),
                  walletIdentityTag: WalletIdentity.keyTag,
                  appAttestRecordEraser: KeychainAppAttestKeyRecordStore.deleteDefaultRecord,
                  myDataProfileEraser: MyDataAutofillProfileStore.delete,
                  pendingRequestEraser: { MyDataPendingRequestStore.clear() })
    }

    /// Erases everything, then reports the first thing that went wrong.
    ///
    /// The order is the user's mental model — identity and credentials, then the
    /// leftovers they never knew about — and not a risk ranking, because the
    /// whole thing is a handful of `unlink` calls and there is no meaningful
    /// window in which the process dies between two of them. The one ordering
    /// that *is* load-bearing lives inside `IdentityReset.perform`: the key is
    /// destroyed before the credentials it signed, so an interrupted erase can
    /// never leave the silent state where the files are gone and the identifier
    /// quietly comes back.
    ///
    /// Deliberately not `try` on each step in sequence. If deleting the
    /// credentials fails — the device is locked, a file is busy — stopping there
    /// would leave the plaintext PDF on disk *and* tell the user the erase
    /// failed, which is the worst combination: they believe some of their data
    /// survived, and the most sensitive part of it actually did. Every location
    /// gets its attempt regardless, and the caller still learns that the erase
    /// was not clean.
    func eraseEverything() throws {
        var firstFailure: Error?

        func attempt(_ work: () throws -> Void) {
            do { try work() } catch { firstFailure = firstFailure ?? error }
        }

        // Not `credentials.deleteAll()`: that leaves the device key, and the key
        // is what makes the next DID the same DID. `IdentityReset` sweeps the
        // credentials itself, key first, and reports the Keychain failure in
        // preference to the file one — because the Keychain failure is the one
        // that means the identity outlived the erase.
        // Credential-specific keys and the app installation DID are independent
        // from the legacy key `IdentityReset` knows. All must go before files or
        // an interrupted erase would leave a living identity behind.
        attempt { _ = try holderKeyring?.destroyAll() }
        attempt { try appAttestRecordEraser?() }
        attempt { try myDataProfileEraser?() }
        pendingRequestEraser?()
        if let walletIdentityTag, walletIdentityTag != keyTag {
            attempt { try DeviceKey.deleteKey(tag: walletIdentityTag,
                                              installRecord: installRecord) }
        }
        attempt { try IdentityReset.perform(credentialStore: credentials,
                                            keyTag: keyTag,
                                            installRecord: installRecord) }
        attempt { try scratch.purge() }
        attempt { try vaultArchive?.purge() }
        attempt { try officialDocumentInbox?.purge() }
        attempt { try eraseProofResidue() }
        // Issuer-level, not personal — but 「erase all local data」 means all.
        IssuerNameBook.erase()
        if let documentsDirectory {
            attempt { try eraseLegacyPlaintext(in: documentsDirectory) }
        }

        if let firstFailure { throw firstFailure }
    }

    /// Removes what a proof run leaves in the ZK working directory.
    ///
    /// Its own method, and internal rather than private, because there is a
    /// second caller this deserves that does not exist yet: app launch. A run
    /// killed by jetsam during the ~2 GB proving step never reaches
    /// `ZKProver.prove`'s `defer`, and today nothing clears what it left until
    /// either the next proof starts or the user erases everything. A sweep on
    /// the first launch after that kill is a two-line hook in the app delegate
    /// and it is not written here because this change does not own that file.
    ///
    /// Failures are reported rather than swallowed — unlike
    /// `ZKProver.discardSecretArtifacts`, which is best-effort cleanup around a
    /// proof. Here the caller is about to tell someone their data is gone, and a
    /// witness that could not be unlinked has to reach that sentence.
    func eraseProofResidue() throws {
        guard let zkWorkingDirectory else { return }
        let fileManager = FileManager.default
        var firstFailure: Error?

        for name in Self.proofArtifactFilenames {
            let url = zkWorkingDirectory.appendingPathComponent(name)
            // Checked first so that "this run never produced a witness" is not
            // reported as a failure to delete one.
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do { try fileManager.removeItem(at: url) } catch { firstFailure = firstFailure ?? error }
        }

        if let firstFailure { throw firstFailure }
    }

    /// Sweeps the residue that earlier versions of the app left in Documents.
    ///
    /// Until this release the MyData download, the directory it unpacked into
    /// and the decrypted PDF were all written to Documents and never deleted.
    /// Those files are on the devices of everyone who has used the app so far,
    /// and nothing else in the new code will ever go looking for them, so the
    /// erase button has to.
    ///
    /// Only `.zip` and `.pdf` are removed, plus any directory those files leave
    /// empty (the unpacked archive's folder). Sweeping Documents wholesale would
    /// be simpler and would guarantee no residue survives — but `Info.plist` used
    /// to set `UISupportsDocumentBrowser`, so a user could have put their own
    /// files in there through the Files app, and silently deleting someone's
    /// unrelated documents is not a thing an erase button may do. The two
    /// extensions cover everything the app itself is known to have written.
    private func eraseLegacyPlaintext(in documents: URL) throws {
        let fileManager = FileManager.default
        guard let walk = fileManager.enumerator(at: documents,
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: []) else { return }

        var firstFailure: Error?
        var directories: [URL] = []

        for case let url as URL in walk {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            if isDirectory == true {
                directories.append(url)
                continue
            }
            guard Self.legacyResidueExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            do { try fileManager.removeItem(at: url) } catch { firstFailure = firstFailure ?? error }
        }

        // Deepest first, so that a folder holding only the PDF is empty by the
        // time we look at it and goes too. A folder that still has something in
        // it is left alone — it holds something we did not put there.
        for url in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let contents = try? fileManager.contentsOfDirectory(atPath: url.path)
            guard contents?.isEmpty == true else { continue }
            try? fileManager.removeItem(at: url)
        }

        if let firstFailure { throw firstFailure }
    }
}
