import Foundation
import Testing
@testable import backupTW

struct AppAttestUATReportTests {
    @Test func copiedReportContainsOnlyTheReviewedDiagnosticVocabulary() {
        let report = AppAttestUATReport(
            outcome: .failed(code: "server_assertion_invalid"),
            endpointHost: "signing-uat.mashbean.net",
            appVersion: "1.0 (1)",
            systemVersion: "26.0",
            checkedAt: Date(timeIntervalSince1970: 1_788_134_400))

        #expect(report.copyText.contains("result=FAIL"))
        #expect(report.copyText.contains("error_code=server_assertion_invalid"))
        #expect(report.copyText.contains("identity_data_sent=false"))
        #expect(report.copyText.contains("signing_started=false"))
        #expect(!report.copyText.contains("key_id"))
        #expect(!report.copyText.contains("challenge"))
        #expect(!report.copyText.contains("assertion_object"))
    }

    @Test func unexpectedErrorsCannotPutTheirDescriptionOnTheClipboard() {
        struct SensitiveError: LocalizedError {
            var errorDescription: String? { "A123456789 secret-attestation" }
        }
        #expect(AppAttestUATReport.safeErrorCode(SensitiveError()) == "unexpected_error")
        #expect(AppAttestUATReport.safeErrorCode(URLError(.timedOut)) == "network_unavailable")
        #expect(AppAttestUATReport.safeErrorCode(
            SigningBrokerClientError.server(code: "BAD secret", retryable: false)) == "invalid_response")
    }
}
