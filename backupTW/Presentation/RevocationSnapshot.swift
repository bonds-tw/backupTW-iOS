//
//  RevocationSnapshot.swift
//  backupTW
//
//  Checking a cardholder certificate against a revocation snapshot, offline.
//

import Foundation

// MARK: - Why this is possible now, when the roadmap says it is not
//
// The roadmap records this as blocked, and the note it gives is accurate about
// the thing it was written about: tying a *zero-knowledge proof* to a snapshot
// needs the proof's `smt_root` public input, and those signals cannot cross the
// iOS FFI (see `ZKPublicInputs`, and privacy-ethereum/zkID#105).
//
// The card-signed credential path has no such problem. The verifier is holding
// the cardholder's certificate — it travels inside `MOICASignedCredential` —
// and MOICA's revocation tree is keyed on certificate serial numbers
// (moica-revocation-smt's `GET /proof/{issuerId}/{sn}`, README lines 78-94).
// `OpenACSwift` already exposes `createSmtProofFromGz` and `verifySmtProof`, and
// `CircuitAssets` already downloads `g3-tree-snapshot.json.gz`. Nothing was
// missing except the code between them.
//
// # The line this must not cross
//
// What a device can establish offline is: **this serial is, or is not, in the
// snapshot this device holds** — and that snapshot declares when it was made.
// What it cannot establish is that the snapshot is the authentic current one.
// That needs the root published on-chain, which is a network call and therefore
// not available in the situation this app exists for. `CircuitAssets` says the
// same thing from the other side: the snapshot is deliberately not pinned by
// digest, because it is regenerated twice a day and fixity is the wrong
// property for it.
//
// So the sentence a screen may say is 「在這支手機上這份 <日期> 的撤銷名單裡，
// 這張憑證沒有被列為撤銷」 — with the date, and with the provenance caveat.
// Never 「未被撤銷」 unqualified.

/// What a revocation snapshot says about itself.
struct RevocationSnapshotInfo: Equatable, Sendable {

    /// The tree root the snapshot declares, `0x`-prefixed hex.
    let root: String

    /// The CRL the snapshot was built from, as `YYYYMMDDHH`.
    ///
    /// Upstream's own freshness marker, carried in the snapshot rather than
    /// derived from the file's timestamp — a file copied between devices keeps
    /// its mtime from the copy, and a verifier deciding how stale its list is
    /// must not be told the answer by the filesystem.
    let crlNumber: Int

    /// How many certificates the tree holds. Reported because a snapshot that
    /// suddenly has far fewer entries than the last one is worth noticing.
    let entryCount: Int

    /// `crlNumber` read as a moment, or nil if it is not in the documented
    /// `YYYYMMDDHH` shape.
    var generatedAt: Date? {
        let text = String(crlNumber)
        guard text.count == 10,
              let year = Int(text.prefix(4)),
              let month = Int(text.dropFirst(4).prefix(2)),
              let day = Int(text.dropFirst(6).prefix(2)),
              let hour = Int(text.dropFirst(8).prefix(2)),
              (1 ... 12).contains(month), (1 ... 31).contains(day), (0 ... 23).contains(hour) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        guard let date = ROCDate.taipeiCalendar.date(from: components) else { return nil }

        // `Calendar.date(from:)` is lenient: February 30th becomes March 2nd
        // rather than nothing. A verifier that told someone their revocation
        // list was made on a day it was not would be worse than one that admits
        // it cannot say, so a value that does not survive the round trip is
        // treated as unreadable.
        let roundTrip = ROCDate.taipeiCalendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard roundTrip.year == year, roundTrip.month == month,
              roundTrip.day == day, roundTrip.hour == hour else {
            return nil
        }
        return date
    }

    /// Parses the metadata out of a decompressed snapshot.
    ///
    /// Reads only the three scalar fields and never the `nodes` array, which is
    /// hundreds of megabytes decompressed. `JSONDecoder` on a struct with three
    /// properties still walks the whole document, so this is a deliberate
    /// scan rather than a decode — measured on the published G3 snapshot, the
    /// three fields sit in the first hundred bytes, and reading them must not
    /// cost the array.
    static func parse(metadataFrom json: Data) -> RevocationSnapshotInfo? {
        // The header is ASCII and short. Anything past it is the node array and
        // is irrelevant here.
        let head = json.prefix(4096)
        guard let text = String(data: head, encoding: .utf8) else { return nil }

        func number(_ key: String) -> Int? {
            guard let range = text.range(of: "\"\(key)\"") else { return nil }
            let rest = text[range.upperBound...].drop { $0 == ":" || $0 == " " }
            let digits = rest.prefix { $0.isNumber }
            return Int(digits)
        }

        guard let rootRange = text.range(of: "\"root\"") else { return nil }
        let afterRoot = text[rootRange.upperBound...]
        guard let open = afterRoot.firstIndex(of: "\""),
              let close = afterRoot[afterRoot.index(after: open)...].firstIndex(of: "\"") else {
            return nil
        }
        let root = String(afterRoot[afterRoot.index(after: open) ..< close])
        guard root.hasPrefix("0x"), root.count > 2,
              root.dropFirst(2).allSatisfy({ $0.isHexDigit }),
              let crlNumber = number("crlNumber"),
              let count = number("count") else {
            return nil
        }
        return RevocationSnapshotInfo(root: root, crlNumber: crlNumber, entryCount: count)
    }
}

// MARK: - The verdict

/// What checking one certificate against one snapshot established.
enum RevocationStatus: Equatable, Sendable {

    /// The serial is in the tree. The certificate is revoked according to this
    /// snapshot.
    case revoked(snapshot: RevocationSnapshotInfo)

    /// The serial is absent from the tree, proven by a non-membership proof
    /// that verifies against the root the snapshot declares.
    case notRevokedInThisSnapshot(snapshot: RevocationSnapshotInfo)

    /// This device holds no snapshot, so nothing was checked. Distinct from
    /// `notRevokedInThisSnapshot` in the only way that matters: one is an
    /// answer and the other is the absence of one, and a screen that rendered
    /// them alike would turn "we did not look" into "we looked and it is fine".
    case notChecked(reason: NotCheckedReason)

    enum NotCheckedReason: Equatable, Sendable {
        /// No snapshot on this device.
        case snapshotUnavailable
        /// A snapshot exists and could not be read or used.
        case snapshotUnusable
        /// A proof came back that does not verify against the snapshot's own
        /// declared root. The list this device holds is not internally
        /// consistent, and no answer derived from it can be trusted.
        case proofDidNotVerify

        /// The credential was signed by the holder's own device, so there is no
        /// certificate whose revocation anyone could look up — and no authority
        /// that would publish an answer if there were. Kept apart from
        /// `snapshotUnavailable` because a missing list is something a user can
        /// fix and this is not.
        case noCertificateToCheck
    }

    /// The snapshot an answer came from, or nil when there was no answer.
    ///
    /// Lets a screen show *which* list said so — the caveat text promises a
    /// date, and a date the checker cannot see is not a date.
    var snapshot: RevocationSnapshotInfo? {
        switch self {
        case .revoked(let info), .notRevokedInThisSnapshot(let info): return info
        case .notChecked: return nil
        }
    }
}

// MARK: - The check

/// Produces (non-)membership proofs from a compressed snapshot.
///
/// A protocol so the decision logic below can be tested without the OpenAC
/// static library, which the test target deliberately does not link — the same
/// arrangement `OpenACVerification` documents at length.
protocol RevocationProofProviding: Sendable {

    /// - Parameters:
    ///   - snapshot: the still-compressed `.json.gz` bytes.
    ///   - serialNumberHex: the certificate serial, hex, no `0x`.
    /// - Returns: the proof, or nil when one could not be produced.
    func proof(inSnapshot snapshot: Data, forSerialNumberHex serialNumberHex: String)
        -> (root: String, isMember: Bool, verifies: Bool)?
}

enum RevocationCheck {

    /// Checks one certificate against one snapshot.
    ///
    /// Three things have to line up before an answer is given, and the middle
    /// one is the easiest to leave out:
    ///
    ///   1. the snapshot's metadata is readable;
    ///   2. the proof verifies **against the root the snapshot declares** — not
    ///      against the root the proof itself reports, which would be circular
    ///      and would accept any internally consistent forgery;
    ///   3. the proof's own root matches that same declared root, so the proof
    ///      and the metadata describe one tree rather than two.
    static func status(serialNumberHex: String,
                       snapshot: Data?,
                       provider: any RevocationProofProviding) -> RevocationStatus {
        guard let snapshot, !snapshot.isEmpty else {
            return .notChecked(reason: .snapshotUnavailable)
        }
        // Only the header, never the tree. The published G3 snapshot is 27 MB
        // compressed and expands past 500 MB; inflating it here to read three
        // scalars would cost more than the proof that follows. `decompressPrefix`
        // stops as soon as it has enough, which also means it never reaches the
        // trailing CRC — these bytes are unauthenticated, and the integrity that
        // matters comes from the proof checked against the root below.
        guard let header = try? GzipDecoder.decompressPrefix(snapshot, maxBytes: 4096),
              let info = RevocationSnapshotInfo.parse(metadataFrom: header) else {
            return .notChecked(reason: .snapshotUnusable)
        }
        guard let result = provider.proof(inSnapshot: snapshot,
                                          forSerialNumberHex: serialNumberHex) else {
            return .notChecked(reason: .snapshotUnusable)
        }
        guard result.verifies, result.root.lowercased() == info.root.lowercased() else {
            return .notChecked(reason: .proofDidNotVerify)
        }
        return result.isMember ? .revoked(snapshot: info)
                               : .notRevokedInThisSnapshot(snapshot: info)
    }
}

// MARK: - What the verifier is handed

/// How `OfflineVerifier` asks about one serial number.
///
/// A value rather than a protocol because there is exactly one question, and
/// because the default has to be the *honest* one: a verifier constructed
/// without a snapshot must report that it did not look, never that it looked and
/// found nothing. `unavailable` is that default, and it is what every caller
/// that has not opted in gets.
struct RevocationLookup: Sendable {

    let status: @Sendable (_ serialNumberHex: String) -> RevocationStatus

    init(status: @escaping @Sendable (_ serialNumberHex: String) -> RevocationStatus) {
        self.status = status
    }

    /// No list on this device.
    static let unavailable = RevocationLookup { _ in .notChecked(reason: .snapshotUnavailable) }

    /// Reads the snapshot installed at `url` and proves against it.
    ///
    /// The file is memory-mapped rather than read: the published snapshot is
    /// 27 MB compressed, and a verifier that allocated that on every scan would
    /// spend more on the read than on the proof.
    static func snapshot(at url: URL,
                         provider: any RevocationProofProviding) -> RevocationLookup {
        RevocationLookup { serialNumberHex in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return .notChecked(reason: .snapshotUnavailable)
            }
            return RevocationCheck.status(serialNumberHex: serialNumberHex,
                                          snapshot: data,
                                          provider: provider)
        }
    }
}
