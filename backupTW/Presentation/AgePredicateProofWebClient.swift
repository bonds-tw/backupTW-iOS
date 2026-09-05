//
//  AgePredicateProofWebClient.swift
//  backupTW
//
//  The one HTTPS call in the private age-proof flow, kept in its own file so
//  the network allowlist names exactly the code that opens a socket.
//

import Foundation

/// Posts a package to the website named in the request.
///
/// The URL was allow-listed when the request was decoded and is checked again
/// here, because this is the line that opens a socket. A refusal from the
/// website (HTTP 4xx with a readable body) is surfaced as `webRejected` with
/// the website's own words; anything else that is not a 2xx verdict is a
/// network failure the holder can retry.
struct AgePredicateProofWebClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func submit(_ package: AgePredicateProofPackage,
                to url: URL) async throws -> AgePredicateProofWebOutcome {
        guard AgePredicateProofRequest.isTrustedResponseURL(url) else {
            throw AgePredicateProofError.untrustedResponseHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try package.encoded()
        request.timeoutInterval = 90

        let started = VerificationClock.now()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AgePredicateProofError.network }
        let roundTrip = VerificationClock.milliseconds(from: started, to: VerificationClock.now())
        guard let http = response as? HTTPURLResponse else { throw AgePredicateProofError.network }

        if let verdict = try? AgePredicateProofWebVerdict.decode(from: data) {
            return AgePredicateProofWebOutcome(verdict: verdict, roundTripMilliseconds: roundTrip)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let reason = UntrustedText(body, limit: 200).text
            throw AgePredicateProofError.webRejected(reason.isEmpty ? "HTTP \(http.statusCode)" : reason)
        }
        throw AgePredicateProofError.webResponseUnreadable
    }
}
