//
//  MyDataPendingRequestStore.swift
//  backupTW
//

import Foundation

/// Only continuation metadata — never an ID number, birthday, filename or
/// downloaded field. It lets a two-hour request outlive the web view that began
/// it and points the holder back to MyData's own 個人文件 inbox.
struct MyDataPendingRequest: Codable, Equatable {
    let documentID: String
    let requestedAt: Date
}

enum MyDataPendingRequestStore {
    private static let key = "mydata.pendingRequests.v1"

    static func all(defaults: UserDefaults = .standard, now: Date = Date()) -> [MyDataPendingRequest] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MyDataPendingRequest].self, from: data) else {
            return []
        }
        // MyData says unclaimed fetched data is removed after eight hours. Do
        // not keep telling the holder an expired continuation is waiting.
        return decoded.filter { now.timeIntervalSince($0.requestedAt) < 8 * 60 * 60 }
    }

    static func remember(documentID: String, defaults: UserDefaults = .standard,
                         now: Date = Date()) {
        var requests = all(defaults: defaults, now: now)
        requests.removeAll { $0.documentID == documentID }
        requests.append(MyDataPendingRequest(documentID: documentID, requestedAt: now))
        if let data = try? JSONEncoder().encode(requests) { defaults.set(data, forKey: key) }
    }

    static func resolve(documentID: String, defaults: UserDefaults = .standard,
                        now: Date = Date()) {
        let requests = all(defaults: defaults, now: now)
            .filter { $0.documentID != documentID }
        if requests.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(requests) { defaults.set(data, forKey: key) }
    }

    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
