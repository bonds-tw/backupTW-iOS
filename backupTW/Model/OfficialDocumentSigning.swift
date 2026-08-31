//
//  OfficialDocumentSigning.swift
//  backupTW
//

import Foundation
import UIKit

enum OfficialDocumentSigningError: Error, Equatable {
    case identityNumberMissing
    case certificateAppUnavailable
    case signingUnavailable(message: String)
    case timedOut
    case resultUnreachable
    case signingFailed(message: String)
    case receiptRejected(message: String)
}

extension OfficialDocumentSigningError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .identityNumberMissing:
            return NSLocalizedString("Enter your ID number to ask 行動自然人憑證 for this signature.", comment: "official document inbox")
        case .certificateAppUnavailable:
            return NSLocalizedString("The 行動自然人憑證 app isn't installed on this device.", comment: "")
        case .signingUnavailable(let message), .signingFailed(let message), .receiptRejected(let message):
            return message
        case .timedOut:
            return NSLocalizedString("The signing request expired before it was approved.", comment: "")
        case .resultUnreachable:
            return NSLocalizedString("Your signature may have gone through, but the result could not be fetched. Check this device's connection and try again.", comment: "")
        }
    }
}

/// Runs the same TW FidO app-to-app hand-off, callback wake-up and authenticated
/// result polling used elsewhere in 有備而來, but with a domain-separated
/// official-document consent target.
struct OfficialDocumentSigning {
    typealias ReceiptFactory = @Sendable (
        OfficialDocumentInboxConsent, TWFidOSignResult, Date
    ) throws -> OfficialDocumentInboxReceipt

    let session: any TWFidOSignSession
    let callbacks: any TWFidOCallbackWaiting
    let open: @Sendable (URL) async -> Bool
    let hint: String
    let timeLimit: Int
    let pollInterval: TimeInterval
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let makeReceipt: ReceiptFactory

    init(session: any TWFidOSignSession,
         callbacks: any TWFidOCallbackWaiting = MOICACallbackRouter.shared,
         open: @escaping @Sendable (URL) async -> Bool,
         hint: String = NSLocalizedString("Sign the electronic official document inbox pilot consent", comment: "official document inbox"),
         timeLimit: Int = 600,
         pollInterval: TimeInterval = 4,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         },
         makeReceipt: @escaping ReceiptFactory = { consent, result, now in
             try OfficialDocumentInboxReceipt.issue(consent: consent,
                                                    signResult: result,
                                                    now: now)
         }) {
        self.session = session
        self.callbacks = callbacks
        self.open = open
        self.hint = hint
        self.timeLimit = timeLimit
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
        self.makeReceipt = makeReceipt
    }

    func sign(consent: OfficialDocumentInboxConsent,
              idNumber: String) async throws -> OfficialDocumentInboxReceipt {
        let idNumber = idNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idNumber.isEmpty else { throw OfficialDocumentSigningError.identityNumberMissing }

        let started: (ticket: TWFidOTicket, deepLink: URL)
        do {
            started = try await session.begin(idNumber: idNumber,
                                              hint: hint,
                                              signing: .officialDocumentConsent(consent.signingDescriptor),
                                              timeLimit: timeLimit)
        } catch let error as SPCredentialError {
            throw OfficialDocumentSigningError.signingUnavailable(message: Self.credentialMessage(error))
        } catch {
            throw OfficialDocumentSigningError.signingFailed(message: Self.message(for: error))
        }

        guard await open(started.deepLink) else {
            throw OfficialDocumentSigningError.certificateAppUnavailable
        }

        let result = try await awaitResult(
            ticket: started.ticket,
            deadline: now().addingTimeInterval(TimeInterval(timeLimit)))
        do {
            return try makeReceipt(consent, result, now())
        } catch {
            throw OfficialDocumentSigningError.receiptRejected(message: Self.message(for: error))
        }
    }

    private func awaitResult(ticket: TWFidOTicket,
                             deadline: Date) async throws -> TWFidOSignResult {
        var sawTransportFailure = false
        while true {
            try Task.checkCancellation()
            do {
                if let result = try await session.poll(ticket: ticket) { return result }
            } catch let error as SPCredentialError {
                throw OfficialDocumentSigningError.signingUnavailable(message: Self.credentialMessage(error))
            } catch let error where isTransientSignPollFailure(error) {
                sawTransportFailure = true
            } catch {
                throw OfficialDocumentSigningError.signingFailed(message: Self.message(for: error))
            }

            guard now() < deadline else {
                throw sawTransportFailure ? OfficialDocumentSigningError.resultUnreachable
                                          : OfficialDocumentSigningError.timedOut
            }

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

    private static func credentialMessage(_ error: SPCredentialError) -> String {
        switch error {
        case .notConfigured:
            return NSLocalizedString("This build has no credentials for the digital certificate service, so it can't request a signature.", comment: "")
        case .requiresBackend:
            return NSLocalizedString("Signing has to go through the bonds-tw server, which this build can't reach.", comment: "")
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? NSLocalizedString("The digital certificate service could not be reached.", comment: "")
    }
}

enum OfficialDocumentSigningAssembly {
    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func make() -> OfficialDocumentSigning? {
        #if DEBUG
        guard let returnURL = URL(string: "\(MOICACallbackRouter.scheme)://twfido-official-documents") else {
            return nil
        }
        let client = TWFidOClient(configuration: .production,
                                  credentials: DevelopmentSPCredentialProvider())
        return OfficialDocumentSigning(
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
