//
//  MyDataPendingRequestStoreTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

struct MyDataPendingRequestStoreTests {

    private func defaults() -> (UserDefaults, String) {
        let suite = "tw.bonds.backupTW.tests.mydata.pending.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func remembersResolvesAndExpiresContinuationMetadata() {
        let (defaults, suite) = defaults()
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        MyDataPendingRequestStore.remember(documentID: "mydata-income",
                                           defaults: defaults, now: start)
        #expect(MyDataPendingRequestStore.all(defaults: defaults,
                                              now: start.addingTimeInterval(2 * 60 * 60)).map(\.documentID)
                == ["mydata-income"])

        #expect(MyDataPendingRequestStore.all(defaults: defaults,
                                              now: start.addingTimeInterval(8 * 60 * 60)).isEmpty)

        MyDataPendingRequestStore.remember(documentID: "mydata-income",
                                           defaults: defaults, now: start)
        MyDataPendingRequestStore.resolve(documentID: "mydata-income",
                                          defaults: defaults, now: start)
        #expect(MyDataPendingRequestStore.all(defaults: defaults, now: start).isEmpty)
    }

    @Test func rememberingTheSameTypeReplacesItsOldTimestamp() {
        let (defaults, suite) = defaults()
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        MyDataPendingRequestStore.remember(documentID: "mydata-income",
                                           defaults: defaults, now: start)
        MyDataPendingRequestStore.remember(documentID: "mydata-income",
                                           defaults: defaults, now: start.addingTimeInterval(60))

        let values = MyDataPendingRequestStore.all(defaults: defaults, now: start.addingTimeInterval(60))
        #expect(values.count == 1)
        #expect(values.first?.requestedAt == start.addingTimeInterval(60))
    }
}
