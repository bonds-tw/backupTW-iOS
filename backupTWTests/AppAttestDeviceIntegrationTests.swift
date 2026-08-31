//
//  AppAttestDeviceIntegrationTests.swift
//  backupTWTests
//

import XCTest
@testable import backupTW

/// Opt-in physical-device coverage for Apple's real App Attest service.
/// CI and simulator runs skip this test; the host app must carry a development
/// entitlement and the command must point at the reviewed development Worker.
final class AppAttestDeviceIntegrationTests: XCTestCase {

    func testDevelopmentRegistrationAndRepeatedAssertion() async throws {
        guard ProcessInfo.processInfo.environment["APP_ATTEST_DEVICE_UAT"] == "1" else {
            throw XCTSkip("Physical-device UAT; set TEST_RUNNER_APP_ATTEST_DEVICE_UAT=1 to run it.")
        }

        let configuration = try SigningBrokerEndpointConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://signing-dev.mashbean.net")))
        let check = SigningBrokerAppAttestUATCheck(
            endpointHost: XCTUnwrap(configuration.baseURL.host),
            transport: AppAttestSigningBrokerTransport(configuration: configuration))

        do {
            try await check.run()
            try await check.run()
        } catch {
            XCTFail("Physical-device App Attest failed: \(AppAttestUATReport.safeErrorCode(error))")
            throw error
        }
    }
}
