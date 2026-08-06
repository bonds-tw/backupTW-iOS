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

    private let credentials: CredentialStoring
    private let scratch: MyDataScratch
    private let documentsDirectory: URL?
    private let keyTag: String
    private let installRecord: UserDefaults?

    /// `keyTag` and `installRecord` are injectable for the same reason the
    /// directories are: the Keychain is a process-wide namespace, so a test that
    /// used the defaults would destroy the real device key of whoever ran it.
    init(credentials: CredentialStoring,
         scratch: MyDataScratch = MyDataScratch(),
         documentsDirectory: URL? = FileManager.default.urls(for: .documentDirectory,
                                                             in: .userDomainMask).first,
         keyTag: String = DeviceKey.defaultTag,
         installRecord: UserDefaults? = .standard) {
        self.credentials = credentials
        self.scratch = scratch
        self.documentsDirectory = documentsDirectory
        self.keyTag = keyTag
        self.installRecord = installRecord
    }

    /// The app's own wiring: the real store, in the real locations.
    init() throws {
        self.init(credentials: try CredentialStore())
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
        attempt { try IdentityReset.perform(credentialStore: credentials,
                                            keyTag: keyTag,
                                            installRecord: installRecord) }
        attempt { try scratch.purge() }
        if let documentsDirectory {
            attempt { try eraseLegacyPlaintext(in: documentsDirectory) }
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
