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
        if let serviceID = environment["TWFIDO_SP_SERVICE_ID"],
           let aesKeyBase64 = environment["TWFIDO_SP_AES_KEY"],
           !serviceID.isEmpty, !aesKeyBase64.isEmpty {
            return SPCredentials(serviceID: serviceID, aesKeyBase64: aesKeyBase64)
        }
        if let dropped = Self.droppedCredentials() {
            return dropped
        }
        throw SPCredentialError.notConfigured
    }

    /// Credentials a developer dropped into this app's own container.
    ///
    /// # Why this exists — it is the difference between a usable build and a
    /// screen that always says "no credentials"
    ///
    /// Scheme environment variables reach the app **only when Xcode or
    /// `devicectl` launches it with them**. Tapping the icon does not, so on a
    /// real phone every TW FidO screen reported 「this build has no credentials」
    /// for anyone who launched the app the way people launch apps — measured on
    /// device, repeatedly, and it is what made the ZK screen look broken.
    ///
    /// The alternatives were both worse. Compiling the key in through
    /// `Secrets.swift` puts a shared AES key inside `~/Developer/`, against the
    /// workspace's own rule that keys live in `~/.config/secrets/`, and one
    /// mistake away from an archive. Living with terminal-only launches makes
    /// the feature untestable by the person who most needs to test it.
    ///
    /// A file in the app's own Data container is neither: it is not in the
    /// repository, not in the binary, not in a backup (the containing directory
    /// is `Application Support`, which this app already excludes), and it
    /// survives however the app is launched. Dropping it is one command:
    ///
    /// ```
    /// source ~/.config/secrets/twfido-sim.env
    /// printf '{"serviceID":"%s","aesKeyBase64":"%s"}' "$FIDO_SP_SERVICE_ID" "$FIDO_AES_KEY_BASE64" \
    ///   > "$(xcrun simctl get_app_container <udid> tw.bonds.backupTW data)/Library/Application Support/twfido-sp.json"
    /// ```
    ///
    /// On a device the same file goes in via `devicectl device copy` — or the
    /// env-var launch, which still works and is still the option that leaves
    /// nothing behind.
    ///
    /// ⚠️ It is a *development* affordance and the whole file is inside
    /// `#if DEBUG`, so it does not exist in a distribution build. Production
    /// remains what `SPCredentialProviding` documents: the key never reaches a
    /// device, and `sp_checksum` is computed by the bonds-tw backend.
    /// - Parameter directory: where to look. Injectable for the same reason
    ///   `CredentialStore` takes one: tests run in parallel, and two tests
    ///   sharing one real Application Support path race on a single file —
    ///   which is how this function's own first test suite managed to fail
    ///   against correct code.
    static func droppedCredentials(in directory: URL? = nil) -> SPCredentials? {
        guard let support = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                                       in: .userDomainMask,
                                                                       appropriateFor: nil,
                                                                       create: false)) else {
            return nil
        }
        let url = support.appendingPathComponent(droppedCredentialsFilename)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DroppedSPCredentials.self, from: data),
              !decoded.serviceID.isEmpty, !decoded.aesKeyBase64.isEmpty else {
            return nil
        }
        return SPCredentials(serviceID: decoded.serviceID, aesKeyBase64: decoded.aesKeyBase64)
    }

    static let droppedCredentialsFilename = "twfido-sp.json"

    private struct DroppedSPCredentials: Decodable {
        let serviceID: String
        let aesKeyBase64: String
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
