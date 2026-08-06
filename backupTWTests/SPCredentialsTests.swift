//
//  SPCredentialsTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// The SP AES key is a symmetric secret shared with 內政部: whoever holds it can
/// mint a valid `sp_checksum` for bonds-tw's service ID and push a signing
/// prompt to any national ID number it likes. So the property under test is not
/// "the app handles a missing key gracefully" but "a distribution build has no
/// way to hold the key at all".
///
/// **Limits of what a test can prove here, stated up front.** The Test action of
/// the shared scheme builds with the Debug configuration, so this bundle is
/// always compiled with `DEBUG` defined. There is no way from inside it to
/// execute the app target compiled the way an archive compiles it. The guarantee
/// is therefore split in two, and the halves are covered by different means:
///
/// - *Behaviour:* `UnavailableSPCredentialProvider` — the implementation a
///   release build resolves to — is compiled unconditionally, so its refusal is
///   directly executable here.
/// - *Absence:* that the development path is not merely unused in a release
///   build but not compiled into it is enforced by the compiler, not by any
///   runtime assertion. `developmentInjectionPathIsEntirelyBehindADebugGuard`
///   checks it at the source level instead, which is the closest a Debug-built
///   test bundle can get. The end-to-end check stays manual and belongs to
///   release: `strings "$APP" | grep -c "$SP_SERVICE_ID"` on the archived binary
///   must print 0.
///
/// Nothing here writes `SPSecrets.development`. Swift Testing runs suites in
/// parallel and `TWFidOClientTests` builds providers that expect
/// `notConfigured`, so a test that assigned the global would make that suite
/// fail at random. The injection slot is reached through the `init` parameter
/// instead — which is why it is a parameter.
struct SPCredentialsTests {

    // MARK: - Release-path behaviour

    /// The regression test for the defect. Reproduces the exact situation the
    /// guard exists for — a developer's gitignored `Secrets.swift` is sitting in
    /// the working tree, so credentials *are* available locally — and asserts
    /// that the provider a distribution build resolves to still refuses.
    ///
    /// Before the fix there was no such provider: `DevelopmentSPCredentialProvider`
    /// was the only implementation and it was compiled into every configuration,
    /// so this scenario returned the key from a release archive exactly as the
    /// first half of this test shows it returning it in a debug build.
    @Test func distributionProviderRefusesEvenWhenLocalSecretsExist() async throws {
        #if DEBUG
        // Establish that the value really would be handed out. Without this the
        // assertion below could pass for the wrong reason — a provider that
        // refuses because the fixture is unusable rather than because it holds
        // no door to a local secret.
        let local = SPCredentials(serviceID: "SP-LOCAL-DEV",
                                  aesKeyBase64: Data(repeating: 0x2A, count: 32).base64EncodedString())
        let development = DevelopmentSPCredentialProvider(injected: local, environment: [:])
        let handedOut = try await development.credentials()
        #expect(handedOut.aesKeyBase64 == local.aesKeyBase64)
        #endif

        // Same machine, same secret on disk, the release-path provider: refuses.
        // It takes neither an injection slot nor an environment, so no argument
        // exists that could make it succeed.
        await #expect(throws: SPCredentialError.requiresBackend) {
            _ = try await UnavailableSPCredentialProvider().credentials()
        }
    }

    /// Refusing must mean throwing. Returning `SPCredentials(serviceID: "",
    /// aesKeyBase64: "")` would still produce a well-formed request that 內政部
    /// rejects with a generic error code, and the report would blame the network
    /// rather than the missing backend.
    @Test func distributionProviderNeverReturnsPlaceholderCredentials() async {
        var returnedSomething = false
        do {
            _ = try await UnavailableSPCredentialProvider().credentials()
            returnedSomething = true
        } catch {
            #expect(error as? SPCredentialError == .requiresBackend)
        }
        #expect(returnedSomething == false)
    }

    /// The two failures want opposite responses — "set up your machine" versus
    /// "this build must never hold the key". If they compared equal, the obvious
    /// way to stop a release build throwing would be to give it a key.
    @Test func backendRefusalIsDistinguishableFromAnUnconfiguredMachine() {
        #expect(SPCredentialError.requiresBackend != SPCredentialError.notConfigured)
    }

    /// An error with no description surfaces as "The operation couldn't be
    /// completed. (backupTW.SPCredentialError error 1.)", which sends whoever
    /// reads the log looking in the wrong place. The message has to name where
    /// the credential is supposed to come from: our own backend.
    @Test func backendRefusalExplainsWhereCredentialsMustComeFrom() {
        let message = String(describing: SPCredentialError.requiresBackend)

        #expect(message.localizedCaseInsensitiveContains("backend"))
        #expect(message.localizedCaseInsensitiveContains("sp_ticket"))
        // Names the thing that must not happen, so nobody "fixes" the failure by
        // embedding a key.
        #expect(message.localizedCaseInsensitiveContains("never ship"))
    }

    @Test func unconfiguredMachineMessagePointsAtTheSchemeVariables() {
        let message = String(describing: SPCredentialError.notConfigured)

        #expect(message.contains("TWFIDO_SP_SERVICE_ID"))
        #expect(message.contains("TWFIDO_SP_AES_KEY"))
    }

    // MARK: - Which provider a build resolves to

    /// `SPCredentialSource.makeDefault()` is the single place the choice is
    /// made, so it is the single place a mistake could hide.
    ///
    /// Only the `DEBUG` branch executes in a normal test run; the `#else` branch
    /// is compiled and checked only when this bundle is built for Release, which
    /// the shared scheme's Test action does not do. It is written out anyway so
    /// that building the tests for Release is a meaningful thing to do when
    /// auditing this guarantee.
    @Test func defaultProviderMatchesTheBuildConfiguration() {
        let provider = SPCredentialSource.makeDefault()

        #if DEBUG
        #expect(provider is DevelopmentSPCredentialProvider)
        #else
        #expect(provider is UnavailableSPCredentialProvider)
        #endif
    }

    // MARK: - Source-level guard

    /// The compile-time half of the guarantee: the local-credential path lives
    /// behind `#if DEBUG` and the region covers the whole file.
    ///
    /// Reading source text is an unusual thing for a unit test to do, and it is
    /// here because the alternative is not checking at all — a Debug-built
    /// bundle cannot observe the absence of code from a Release build. It reads
    /// the working tree through `#filePath`, which holds because these tests run
    /// in a simulator on the machine that compiled them; a build-here/run-there
    /// arrangement would want this as a build-phase script instead.
    @Test func developmentInjectionPathIsEntirelyBehindADebugGuard() throws {
        let guarded = Self.repositoryRoot().appendingPathComponent("backupTW/TWFidO/SPSecrets.swift")
        let source = try #require(try? String(contentsOf: guarded, encoding: .utf8),
                                  "Expected the debug-only credential path at \(guarded.path)")

        // Guards against passing vacuously over a file that no longer holds what
        // it is supposed to hold.
        #expect(source.contains("struct DevelopmentSPCredentialProvider"))
        #expect(source.contains("enum SPSecrets"))

        let significant = Self.significantLines(of: source)
        #expect(significant.first == "#if DEBUG")
        #expect(significant.last == "#endif")
        // Exactly one region, so no declaration can sit after an early `#endif`.
        #expect(significant.filter { $0.hasPrefix("#if") }.count == 1)
        #expect(significant.filter { $0.hasPrefix("#endif") }.count == 1)
    }

    /// The same declarations must not reappear somewhere unguarded. Scans the
    /// whole app target rather than only the file the defect was found in,
    /// because the next copy of it will be in a different file.
    @Test func noOtherAppSourceDeclaresTheDevelopmentCredentialPath() throws {
        let appSources = Self.repositoryRoot().appendingPathComponent("backupTW")
        let files = try #require(FileManager.default.enumerator(at: appSources,
                                                               includingPropertiesForKeys: nil))

        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            guard url.lastPathComponent != "SPSecrets.swift",
                  // A developer's own untracked Secrets.swift is gitignored and
                  // not ours to police from here.
                  url.lastPathComponent != "Secrets.swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }

            // Declarations only. Doc comments in TWFidOConfiguration.swift name
            // both types on purpose, and `SPCredentialSource.makeDefault()`
            // constructs the development provider inside its own `#if DEBUG`.
            let declarations = Self.significantLines(of: source)
                .filter { $0.contains("struct DevelopmentSPCredentialProvider")
                    || $0.contains("enum SPSecrets") }
            if !declarations.isEmpty {
                offenders.append(url.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty, "Unguarded development credential path in \(offenders)")
    }

    // MARK: - Development path (debug builds only)

    #if DEBUG

    /// Pins the resolution order after the injection slot became an `init`
    /// parameter: an explicitly supplied credential wins over the environment,
    /// so a developer with both configured gets the one they last edited by hand
    /// rather than a stale scheme variable.
    @Test func injectedCredentialsWinOverTheEnvironment() async throws {
        let injected = SPCredentials(serviceID: "SP-INJECTED", aesKeyBase64: "AAAA")
        let provider = DevelopmentSPCredentialProvider(
            injected: injected,
            environment: ["TWFIDO_SP_SERVICE_ID": "SP-ENV", "TWFIDO_SP_AES_KEY": "BBBB"])

        let credentials = try await provider.credentials()

        #expect(credentials.serviceID == "SP-INJECTED")
    }

    /// With neither source configured the failure is `notConfigured`, not
    /// `requiresBackend`: this machine is fixable, and the build is not what is
    /// wrong. `injected: nil` is passed explicitly so the result does not depend
    /// on whether the developer running the suite has a local `Secrets.swift`.
    @Test func emptyDevelopmentEnvironmentReportsAnUnconfiguredMachine() async {
        let provider = DevelopmentSPCredentialProvider(injected: nil, environment: [:])

        await #expect(throws: SPCredentialError.notConfigured) {
            _ = try await provider.credentials()
        }
    }

    #endif

    // MARK: - Helpers

    /// `#filePath` is this file inside `backupTWTests/`, so the repository root
    /// is its parent's parent.
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Lines that carry code: no blanks, no whole-line comments, no imports.
    /// Enough to tell a declaration from a mention of one in prose, which is all
    /// the guard checks need. It is not a parser and does not pretend to be.
    private static func significantLines(of source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("//")
                    && !line.hasPrefix("import ")
            }
    }
}
