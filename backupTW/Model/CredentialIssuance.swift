//
//  CredentialIssuance.swift
//  backupTW
//
//  Turning parsed MyData fields into a credential the cardholder has signed.
//

import Foundation
import UIKit

// MARK: - Errors

enum CredentialIssuanceError: Error, Equatable {

    /// The MyData document carried no 身分證統一編號, so there is no `id_num`
    /// to key the SIGN request on and nothing to send.
    case identityNumberMissing

    /// The MyData document carried no name. Refused at issuance rather than at
    /// presentation: without a name there is nothing to bind the cardholder to,
    /// so the resulting credential would be one this app's own verifier rejects.
    case nameMissing

    /// 行動自然人憑證 is not installed, so the deep link went nowhere.
    case certificateAppUnavailable

    /// This build cannot authenticate to the SP API at all.
    case signingUnavailable(message: String)

    /// The holder did not finish within the ticket's own `time_limit`.
    case timedOut

    /// The SP API refused, or the round trip failed.
    case signingFailed(message: String)

    /// A signature came back and the credential it produced does not verify.
    /// Checked here so the failure lands on the screen that created it rather
    /// than at a counter, offline, in front of a stranger.
    case issuedCredentialDoesNotVerify
}

extension CredentialIssuanceError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .identityNumberMissing, .nameMissing:
            return NSLocalizedString("The downloaded document is missing details this app needs, so it cannot be signed.",
                                     comment: "")
        case .certificateAppUnavailable:
            return NSLocalizedString("The 行動自然人憑證 app isn't installed on this device.", comment: "")
        case .signingUnavailable(let message), .signingFailed(let message):
            return message
        case .timedOut:
            return NSLocalizedString("The signing request expired before it was approved.", comment: "")
        case .issuedCredentialDoesNotVerify:
            return NSLocalizedString("The signature that came back does not match the document, so nothing was saved.",
                                     comment: "")
        }
    }
}

// MARK: - Issuance

/// Runs the 行動自然人憑證 round trip that turns MyData fields into a signed
/// credential.
///
/// # Why this is not inside the view controller
///
/// The flow is a network round trip, a hand-off to another app, a callback on a
/// URL scheme, and a polling loop with a deadline — four things that can each
/// fail differently, none of which need a screen. Keeping them here means the
/// deadline, the refusal to save an unverifiable credential, and the ordering of
/// the two 內政部 calls can be driven by a test; the screen only reports.
///
/// # What the holder is agreeing to
///
/// The prompt they see in 行動自然人憑證 is `hint`. They are signing a digest,
/// which is not something a person can inspect, so the hint is the only place
/// the purpose is stated — it is user-visible text and must stay one.
struct CredentialIssuance {

    let session: any TWFidOSignSession
    let callbacks: any TWFidOCallbackWaiting
    let open: @Sendable (URL) async -> Bool
    let hint: String
    let timeLimit: Int
    let pollInterval: TimeInterval
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Injected so a test can drive everything except the one step that needs a
    /// certificate 內政部 actually signed.
    let anchor: @Sendable () throws -> IssuerCertificate

    init(session: any TWFidOSignSession,
         callbacks: any TWFidOCallbackWaiting = MOICACallbackRouter.shared,
         open: @escaping @Sendable (URL) async -> Bool,
         hint: String = NSLocalizedString("Sign your national ID details", comment: ""),
         timeLimit: Int = 600,
         pollInterval: TimeInterval = 4,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         },
         anchor: @escaping @Sendable () throws -> IssuerCertificate = {
             try IssuerCertificate.loadBundled()
         }) {
        self.session = session
        self.callbacks = callbacks
        self.open = open
        self.hint = hint
        self.timeLimit = timeLimit
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
        self.anchor = anchor
    }

    /// Builds the credential, has the card sign it, and returns the envelope.
    ///
    /// The order is the point and it is not the obvious one. The credential is
    /// assembled *first*, and the exact bytes it serialises to are what the
    /// digest covers and what the envelope carries — the same `Data`, never
    /// re-derived. Building it again after the signature came back would
    /// reproduce the same fields through a second serialization, and any
    /// difference between the two, down to a key order, is a credential that
    /// fails to verify with nothing on screen to explain why.
    func issue(_ model: NationalIDModel,
               subjectDID: String) async throws -> MOICASignedCredential {
        guard let idNumber = model.unifiedNo, !idNumber.isEmpty else {
            throw CredentialIssuanceError.identityNumberMissing
        }
        // The value is not needed here — `MOICASignedCredential` reads it back
        // out of the credential when it binds the cardholder — only its
        // presence, and only before anything is sent.
        guard model.name?.isEmpty == false else {
            throw CredentialIssuanceError.nameMissing
        }

        let credential = VerifiableCredential.nationalID(model,
                                                         issuerDID: subjectDID,
                                                         validFrom: now())
        let (tbs, bytes) = try MOICASignedCredential.toBeSigned(for: credential)

        let started: (ticket: TWFidOTicket, deepLink: URL)
        do {
            started = try await session.begin(idNumber: idNumber,
                                              hint: hint,
                                              signing: .credentialTBS(tbs),
                                              timeLimit: timeLimit)
        } catch let error as SPCredentialError {
            throw CredentialIssuanceError.signingUnavailable(message: error.description)
        } catch {
            throw CredentialIssuanceError.signingFailed(message: Self.message(for: error))
        }

        guard await open(started.deepLink) else {
            throw CredentialIssuanceError.certificateAppUnavailable
        }

        let result = try await awaitResult(ticket: started.ticket,
                                           deadline: now().addingTimeInterval(TimeInterval(timeLimit)))

        // Loaded outside the block below so that "this build's trust anchor is
        // broken" cannot be reported as "the signature does not match the
        // document" — one is our fault and the other accuses the holder.
        let trustAnchor: IssuerCertificate
        do {
            trustAnchor = try anchor()
        } catch {
            throw CredentialIssuanceError.signingFailed(message: Self.message(for: error))
        }

        do {
            return try MOICASignedCredential.issue(credential: credential,
                                                   payloadBytes: bytes,
                                                   signResult: result,
                                                   anchor: trustAnchor,
                                                   now: now())
        } catch let error as IssuerCertificateError {
            // Worth its own sentence: an expired or G2 card is the common case
            // and the holder can act on it.
            throw CredentialIssuanceError.signingFailed(message: error.localizedDescription)
        } catch {
            throw CredentialIssuanceError.issuedCredentialDoesNotVerify
        }
    }

    /// Polls until the holder approves, the ticket expires, or the task is
    /// cancelled.
    ///
    /// The `backuptw://` callback is raced against each sleep only to shorten
    /// the wait — never treated as the answer. Any app on the device can open
    /// our scheme, so it is a hint that polling again is worthwhile; the
    /// signature itself always arrives through an `idp_checksum`-authenticated
    /// ATH-02 response. `cancelWait` runs on every exit because the router parks
    /// the continuation in a dictionary and nothing else would resume it.
    private func awaitResult(ticket: TWFidOTicket, deadline: Date) async throws -> TWFidOSignResult {
        while true {
            try Task.checkCancellation()
            do {
                if let result = try await session.poll(ticket: ticket) {
                    return result
                }
            } catch let error as SPCredentialError {
                throw CredentialIssuanceError.signingUnavailable(message: error.description)
            } catch {
                throw CredentialIssuanceError.signingFailed(message: Self.message(for: error))
            }

            guard now() < deadline else { throw CredentialIssuanceError.timedOut }

            let callbacks = self.callbacks
            let sleep = self.sleep
            let interval = self.pollInterval
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await sleep(interval) }
                group.addTask { await callbacks.waitForCallback(transactionID: ticket.transactionID) }
                await group.next()
                await callbacks.cancelWait(transactionID: ticket.transactionID)
                group.cancelAll()
            }
        }
    }

    /// Never `String(describing:)` on an arbitrary error: the SP layer's errors
    /// are built not to carry holder data, but a Foundation `URLError` reaching
    /// this path would interpolate a URL, and this one has an ID number in the
    /// body it described.
    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? NSLocalizedString("The digital certificate service could not be reached.", comment: "")
    }
}

// MARK: - Assembly

/// Builds the production issuer.
///
/// A separate type rather than a convenience initialiser, for the same reason
/// `ZKProofRunAssembly` is one: this is the single place that knows about
/// `#if DEBUG`. The SP credential provider exists only in a debug build, and a
/// release build has no code path that could produce one — see `SPSecrets.swift`.
/// Keeping that fact in the assembly means `CredentialIssuance` stays testable
/// without a preprocessor.
enum CredentialIssuanceAssembly {

    /// `nil` when this build cannot reach TW FidO at all, so the screen can say
    /// so before the holder waits for a prompt that will never arrive.
    static func make() -> CredentialIssuance? {
        #if DEBUG
        guard let returnURL = URL(string: "\(MOICACallbackRouter.scheme)://twfido-sign") else {
            return nil
        }
        let client = TWFidOClient(configuration: .production,
                                  credentials: DevelopmentSPCredentialProvider())
        return CredentialIssuance(
            session: LiveTWFidOSignSession(client: client, returnURL: returnURL),
            open: { url in
                await MainActor.run { UIApplication.shared.canOpenURL(url) }
                    ? await UIApplication.shared.open(url)
                    : false
            })
        #else
        return nil
        #endif
    }
}
