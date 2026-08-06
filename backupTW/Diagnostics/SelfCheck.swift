//
//  SelfCheck.swift
//  backupTW
//

import Foundation

/// Runs the checks that only a real device can answer, and says in plain words
/// what each result means.
///
/// The alternative was a written procedure: plug in the phone, read seven
/// values off a screen, know which ones are supposed to be which. That asks the
/// person verifying to already understand what they are verifying, which is
/// backwards — the checks exist precisely because the guarantees are not
/// self-evident. So the device performs them and reports a verdict.
///
/// Two rules shape what is in here. Every check has to be able to *fail* — a
/// check that cannot distinguish a working build from a broken one is
/// decoration. And nothing may touch the user's real identity or credentials:
/// the erase check works on a throwaway key, because a diagnostic that destroys
/// what it is inspecting cannot be run twice.
enum SelfCheck {

    enum Verdict {
        case passed
        case failed
        /// True but not a pass or a fail — context for reading the others.
        case informational
    }

    struct Result {
        let title: String
        let verdict: Verdict
        let detail: String
        /// What a failure would mean, in the terms the project cares about.
        let consequence: String?
    }

    /// A tag that is never the real one, so creating and destroying it cannot
    /// disturb the identity the user actually presents.
    private static let probeTag = "tw.bonds.backupTW.selfcheck.probe"

    static func runAll() -> [Result] {
        [
            hardwareCheck(),
            signingKeyCheck(),
            identityResetCheck(),
            credentialProtectionCheck(),
            backupExclusionCheck(),
            plaintextResidueCheck(),
            callbackSchemeCheck(),
        ]
    }

    // MARK: - Checks

    /// Reported first because it decides how to read the next one. An Apple
    /// silicon simulator does vend an Enclave, so "Secure Enclave" on its own
    /// does not prove you are on a phone.
    private static func hardwareCheck() -> Result {
        let available = DeviceKey.secureEnclaveIsAvailable
        return Result(
            title: NSLocalizedString("This device has a Secure Enclave", comment: ""),
            verdict: .informational,
            detail: available
                ? NSLocalizedString("Yes", comment: "")
                : NSLocalizedString("No — software keys are the only option here", comment: ""),
            consequence: nil)
    }

    private static func signingKeyCheck() -> Result {
        let backing = try? DeviceKey.storedKeyBacking()
        switch backing {
        case .some(.secureEnclave):
            return Result(
                title: NSLocalizedString("Your signing key is in hardware", comment: ""),
                verdict: .passed,
                detail: NSLocalizedString("Secure Enclave", comment: ""),
                consequence: nil)
        case .some(.keychain):
            // Only a defect where an Enclave exists and was not used.
            let hasEnclave = DeviceKey.secureEnclaveIsAvailable
            return Result(
                title: NSLocalizedString("Your signing key is in hardware", comment: ""),
                verdict: hasEnclave ? .failed : .informational,
                detail: NSLocalizedString("Stored in the Keychain, not the Secure Enclave", comment: ""),
                consequence: hasEnclave
                    ? NSLocalizedString("This device has a Secure Enclave but the key was not put in it. Anyone who can read the Keychain could sign credentials as you.", comment: "")
                    : NSLocalizedString("Expected here — there is no Secure Enclave to use.", comment: ""))
        case .none:
            return Result(
                title: NSLocalizedString("Your signing key is in hardware", comment: ""),
                verdict: .informational,
                detail: NSLocalizedString("No key yet — create a document first", comment: ""),
                consequence: nil)
        }
    }

    /// The one that matters most, and the one a simulator cannot answer:
    /// `simctl uninstall` does not reliably clear its Keychain, while on a real
    /// device Keychain items outlive app deletion.
    ///
    /// Uses a throwaway tag. Destroying the user's real identity to prove that
    /// destroying identities works would be a poor trade.
    private static func identityResetCheck() -> Result {
        let title = NSLocalizedString("Erasing really gives you a new identity", comment: "")
        let consequence = NSLocalizedString("If erasing kept your old identifier, anyone you showed a document to before could recognise you again afterwards.", comment: "")
        do {
            try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil)
            let first = try DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)
            let before = try DIDKey.did(fromP256PublicKeyX963: first.publicKeyX963)

            try DeviceKey.deleteKey(tag: probeTag, installRecord: nil)
            let second = try DeviceKey.loadOrCreate(tag: probeTag, installRecord: nil)
            let after = try DIDKey.did(fromP256PublicKeyX963: second.publicKeyX963)

            try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil)

            return Result(title: title,
                          verdict: before == after ? .failed : .passed,
                          detail: before == after
                            ? NSLocalizedString("The identifier survived being deleted", comment: "")
                            : NSLocalizedString("A fresh identifier was issued", comment: ""),
                          consequence: before == after ? consequence : nil)
        } catch {
            try? DeviceKey.deleteKey(tag: probeTag, installRecord: nil)
            return Result(title: title, verdict: .failed,
                          detail: error.localizedDescription, consequence: consequence)
        }
    }

    /// Read back off the filesystem. Echoing the value passed at write time
    /// would pass on a simulator, where protection is a no-op.
    private static func credentialProtectionCheck() -> Result {
        let title = NSLocalizedString("Your documents are encrypted at rest", comment: "")
        guard let store = try? CredentialStore(), let id = (try? store.allIDs())?.first else {
            return Result(title: title, verdict: .informational,
                          detail: NSLocalizedString("No documents yet — create one first", comment: ""),
                          consequence: nil)
        }
        let file = store.directory.appendingPathComponent(id)
        let actual = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.protectionKey]
            as? FileProtectionType
        return Result(
            title: title,
            verdict: actual == .completeUnlessOpen ? .passed : .failed,
            detail: actual?.rawValue ?? NSLocalizedString("No protection reported", comment: ""),
            consequence: actual == .completeUnlessOpen ? nil
                : NSLocalizedString("Your document could be readable from a copy of the device's storage.", comment: ""))
    }

    private static func backupExclusionCheck() -> Result {
        let title = NSLocalizedString("Your documents stay off iCloud", comment: "")
        guard let store = try? CredentialStore() else {
            return Result(title: title, verdict: .failed,
                          detail: NSLocalizedString("Storage unavailable", comment: ""), consequence: nil)
        }
        let excluded = (try? store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup
        return Result(
            title: title,
            verdict: excluded == true ? .passed : .failed,
            detail: excluded == true
                ? NSLocalizedString("Excluded from backup", comment: "")
                : NSLocalizedString("Not excluded", comment: ""),
            consequence: excluded == true ? nil
                : NSLocalizedString("Your identity documents would be copied into every iCloud backup.", comment: ""))
    }

    /// Documents used to hold the household-registration PDF, and was published
    /// to the Files app. Both are fixed; this is the check that they stay fixed.
    private static func plaintextResidueCheck() -> Result {
        let title = NSLocalizedString("No readable copies left lying around", comment: "")
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: documents.path)
        else {
            return Result(title: title, verdict: .informational,
                          detail: NSLocalizedString("Could not read", comment: ""), consequence: nil)
        }
        return Result(
            title: title,
            verdict: contents.isEmpty ? .passed : .failed,
            detail: contents.isEmpty
                ? NSLocalizedString("Nothing left over", comment: "")
                : String(format: NSLocalizedString("%d file(s) left over: %@", comment: ""),
                         contents.count, contents.prefix(3).joined(separator: ", ")),
            consequence: contents.isEmpty ? nil
                : NSLocalizedString("These are the plain documents your credentials came from. Deleting your credentials would not remove them.", comment: ""))
    }

    /// The scheme lives in Info.plist and in the router as two separate strings.
    /// If they drift, the callback silently stops working.
    private static func callbackSchemeCheck() -> Result {
        let title = NSLocalizedString("Returning from 行動自然人憑證 works", comment: "")
        let declared = (Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]])?
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 } ?? []
        let matches = declared.contains(MOICACallbackRouter.scheme)
        return Result(
            title: title,
            verdict: matches ? .passed : .failed,
            detail: matches ? "\(MOICACallbackRouter.scheme)://"
                : NSLocalizedString("Registered scheme does not match the one the app listens for", comment: ""),
            consequence: matches ? nil
                : NSLocalizedString("Signing would complete but never return to this app.", comment: ""))
    }

    // MARK: - Report

    /// Plain text, so a run can be pasted somewhere rather than described.
    static func report(_ results: [Result]) -> String {
        results.map { result in
            let mark: String
            switch result.verdict {
            case .passed: mark = "PASS"
            case .failed: mark = "FAIL"
            case .informational: mark = "INFO"
            }
            var line = "[\(mark)] \(result.title)\n       \(result.detail)"
            if let consequence = result.consequence {
                line += "\n       → \(consequence)"
            }
            return line
        }
        .joined(separator: "\n")
    }
}
