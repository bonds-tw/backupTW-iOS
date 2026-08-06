//
//  SPSecrets.swift
//  backupTW
//
//  The development-only path for supplying TW FidO SP credentials to the
//  device. Everything in this file is inside a single `#if DEBUG`, so none of
//  it exists in a distribution build.
//

import Foundation

// Why the whole file is one guarded region rather than a guard around each
// declaration: the property we need is "no part of the local-credential path
// survives into an archive", and that is only cheap to audit if the guard is a
// file boundary. A reviewer checks two lines — the `#if` below and the `#endif`
// at the end — instead of re-deriving reachability for every declaration.
//
// Consequence worth knowing before it surprises you: a gitignored
// `Secrets.swift` that assigns `SPSecrets.development` will *fail to compile*
// in a release build, because `SPSecrets` does not exist there. That is the
// intended failure. Before this guard, the same file compiled fine and
// `xcodebuild archive` baked the base64 AES key into the binary as a string
// constant, where `strings` on the IPA would hand it to anyone. Keep the
// contents of your `Secrets.swift` inside `#if DEBUG` too and the archive build
// stays green.
#if DEBUG

/// Development-only credential source.
///
/// Resolution order:
/// 1. `injected` — defaults to `SPSecrets.development`, which a gitignored
///    `backupTW/TWFidO/Secrets.swift` may assign.
/// 2. `TWFIDO_SP_SERVICE_ID` / `TWFIDO_SP_AES_KEY` environment variables, set
///    on the Run action of the Xcode scheme.
/// 3. Throws `notConfigured` — a missing key must be a loud failure, never a
///    silent fallback to some placeholder that produces checksums the server
///    rejects with no clue as to why.
struct DevelopmentSPCredentialProvider: SPCredentialProviding {

    private let injected: SPCredentials?
    private let environment: [String: String]

    /// `injected` is a parameter, not a read of `SPSecrets.development` inside
    /// `credentials()`, so tests can exercise the injection branch without
    /// writing to a global. Swift Testing runs suites in parallel: a test that
    /// assigned `SPSecrets.development` would race every other test that builds
    /// a provider and expects `notConfigured`.
    init(injected: SPCredentials? = SPSecrets.development,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.injected = injected
        self.environment = environment
    }

    func credentials() async throws -> SPCredentials {
        if let injected {
            return injected
        }
        guard let serviceID = environment["TWFIDO_SP_SERVICE_ID"],
              let aesKeyBase64 = environment["TWFIDO_SP_AES_KEY"],
              !serviceID.isEmpty, !aesKeyBase64.isEmpty else {
            throw SPCredentialError.notConfigured
        }
        return SPCredentials(serviceID: serviceID, aesKeyBase64: aesKeyBase64)
    }
}

/// Injection slot for locally supplied credentials.
///
/// Nothing in tracked code assigns this, which is the point: a fresh checkout
/// compiles and the TW FidO flow simply reports `notConfigured`. Two ways to
/// fill it:
///
/// - **Environment variables (preferred, no file at all).** Set
///   `TWFIDO_SP_SERVICE_ID` and `TWFIDO_SP_AES_KEY` on the Run action of your
///   Xcode scheme. Scheme environment is not written into the built product, so
///   there is nothing to leak and nothing to gitignore.
/// - **A gitignored `backupTW/TWFidO/Secrets.swift`.** The synchronized folder
///   auto-adds every `.swift` file under `backupTW/` to the target, so that file
///   *must* be in `.gitignore` before it is created (it is, as `Secrets.swift`),
///   and its body *must* sit inside `#if DEBUG` — see the note at the top of
///   this file.
///
/// Mutable global state is a deliberate concession, and it is now a narrow one:
/// it exists only in debug builds, and the only reader is the default argument
/// of `DevelopmentSPCredentialProvider.init`. Tests pass credentials through
/// that parameter instead.
enum SPSecrets {
    static var development: SPCredentials?
}

#endif
