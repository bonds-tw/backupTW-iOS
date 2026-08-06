//
//  TWFidOConfiguration.swift
//  backupTW
//
//  Endpoint selection and SP credential supply for 內政部行動自然人憑證 (TW FidO).
//

import Foundation

// MARK: - Configuration

/// Which TW FidO deployment we talk to, plus the relying-party identifier we
/// ask the card holder to sign.
///
/// `appID` is not a secret and not a nonce: it is the fixed 31-character
/// relying-party namespace that the zkID circuit hashes together with the RSA
/// signature to derive a per-holder nullifier. Change it and every credential
/// ever issued under the old value becomes unlinkable to the new one, so it is
/// pinned here rather than passed in per call.
struct TWFidOConfiguration {

    /// Relying-party namespace, 31 lowercase hex characters.
    let appID: String

    /// Origin of the FidO SP API. Paths are appended by `TWFidOClient`.
    let baseURL: URL

    /// bonds-tw's namespace: the first 31 hex characters of
    /// SHA-256("tw.bonds.backupTW"). The circuit's field element only has room
    /// for 31 characters, which is why this is a truncated digest and not the
    /// bundle identifier itself.
    static let bondsAppID = "55349ff540392a077ca3dcc9bbda4c3"

    static let production = TWFidOConfiguration(
        appID: bondsAppID,
        // Force-unwrap of a literal that is exercised by every client test; a
        // typo here fails on first launch rather than silently at signing time.
        baseURL: URL(string: "https://fidoapi.moi.gov.tw")!)

    static let uat = TWFidOConfiguration(
        appID: bondsAppID,
        baseURL: URL(string: "https://fido-test.moi.gov.tw")!)
}

// MARK: - Credentials

/// The pair the SP API authenticates us with: a service identifier sent in
/// clear, and the AES-256 key every `sp_checksum` is derived from.
struct SPCredentials {

    let serviceID: String

    /// Base64 of exactly 32 raw bytes. Kept as base64 rather than `Data`
    /// because that is the form 內政部 hands it over in, and re-encoding it by
    /// hand is a place to introduce a transcription error.
    let aesKeyBase64: String
}

/// Supplies the SP credentials.
///
/// ⚠️ The AES key must never be compiled into the shipping binary. It is a
/// symmetric key shared with 內政部: whoever holds it can mint a valid
/// `sp_checksum` for *our* service ID and impersonate bonds-tw against the FidO
/// API — `requestAthOrSignPush` with any `id_num` it likes, i.e. a signing
/// prompt pushed to an arbitrary card holder in our name. `strings` on an IPA
/// is enough to lift it, so "obfuscate it" is not a mitigation either.
///
/// The privacy-ethereum reference app ships the key inside the app. That is a
/// proof-of-concept shortcut and we deliberately do not copy it.
///
/// **Production shape.** The key stays on a bonds-tw backend and never reaches
/// a device:
///
/// 1. The app asks *our* backend to start a signing request (`id_num`, hint,
///    transport).
/// 2. The backend holds `sp_service_id` and the AES key, computes
///    `sp_checksum`, calls 內政部's ATH-01/ATH-03, and returns only the
///    resulting `sp_ticket` (plus, for app-to-app, the deep link).
/// 3. The app opens the deep link or polls our backend for the result. It never
///    holds a key and so cannot mint a checksum for our service ID even if the
///    device is fully compromised.
///
/// A conforming implementation of this protocol is therefore *not* the
/// production seam: production replaces `TWFidOClient`'s local
/// `SPChecksum.compute` with that backend round trip. This protocol exists so
/// development and tests can run against the real API before that backend
/// exists, and so the key never reaches source control.
///
/// `async` because the eventual production path is a network round trip.
protocol SPCredentialProviding {
    func credentials() async throws -> SPCredentials
}

enum SPCredentialError: Error, Equatable {
    /// No credentials configured on this machine. Only reachable from the
    /// debug-only `DevelopmentSPCredentialProvider`; a distribution build has
    /// no code path that could read local credentials at all.
    case notConfigured

    /// Something asked a build that has no credential backend to produce SP
    /// credentials.
    ///
    /// Distinct from `notConfigured` because the two want opposite responses:
    /// `notConfigured` means "set up your machine", `requiresBackend` means
    /// "this build is never supposed to hold the key — route the request
    /// through the bonds-tw backend". Collapsing them would invite someone to
    /// fix a release-build failure by adding a key to the app.
    case requiresBackend
}

/// Deliberately `CustomStringConvertible` rather than `LocalizedError`: neither
/// case is a condition a card holder can act on or should ever see. They
/// describe a machine that was never set up, or a build shipped without the
/// backend that is supposed to hold the key. The audience is whoever reads the
/// log, so the text names the fix instead of apologising.
extension SPCredentialError: CustomStringConvertible, CustomDebugStringConvertible {

    var description: String {
        switch self {
        case .notConfigured:
            return """
                No TW FidO SP credentials on this machine. Set \
                TWFIDO_SP_SERVICE_ID and TWFIDO_SP_AES_KEY on the Run action of \
                the Xcode scheme. Debug builds only — a distribution build \
                cannot read them by design.
                """
        case .requiresBackend:
            return """
                TW FidO SP credentials are unavailable in this build by design: \
                the SP AES key must never ship inside the app. sp_checksum must \
                be computed by the bonds-tw backend, which returns a signed \
                sp_ticket for the app to use.
                """
        }
    }

    var debugDescription: String { description }
}

/// The credential source a distribution build gets — and, because every other
/// implementation in this target lives behind `#if DEBUG`, the only one that
/// exists there. It always throws.
///
/// Throwing rather than returning empty strings is the whole point: empty
/// credentials would produce a well-formed `sp_checksum` over an empty service
/// ID, which 內政部 rejects with a generic error code and no hint that the app
/// was built without a key.
struct UnavailableSPCredentialProvider: SPCredentialProviding {

    func credentials() async throws -> SPCredentials {
        throw SPCredentialError.requiresBackend
    }
}

/// Picks the credential source for the build we are in, so no call site has to
/// (and so no call site can reach for the development provider by name and have
/// it silently survive into an archive).
///
/// The `#if DEBUG` is load-bearing and its premise was verified rather than
/// assumed: the project defines `SWIFT_ACTIVE_COMPILATION_CONDITIONS =
/// "DEBUG $(inherited)"` in the Debug configuration only. Release sets it
/// nowhere — not at project level, not on either target — so
/// `DevelopmentSPCredentialProvider` and `SPSecrets` are not merely unused in a
/// release build, they are not compiled into it. If anyone ever adds `DEBUG` to
/// the Release configuration, that change is what breaks this guarantee.
enum SPCredentialSource {

    static func makeDefault() -> SPCredentialProviding {
        #if DEBUG
        return DevelopmentSPCredentialProvider()
        #else
        return UnavailableSPCredentialProvider()
        #endif
    }
}
