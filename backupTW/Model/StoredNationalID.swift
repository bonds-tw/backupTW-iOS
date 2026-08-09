//
//  StoredNationalID.swift
//  backupTW
//
//  Reading back the credential this device issued to itself.
//

import Foundation

/// The national-ID credential as it exists on disk, decoded for display.
///
/// # Why this type had to be written
///
/// The credential was being saved and then never read by anything a user could
/// see. `CredentialStore` had exactly three readers — the presentation screen,
/// the diagnostics screen, and the eraser — and the home screen, which is the
/// only place most people will ever look, read nothing at all. So the MyData
/// flow ended like this: five fields appear in a sheet, the sheet is dismissed,
/// and the app looks precisely as it did before. The document was there the
/// whole time; nothing surfaced it.
///
/// That is worse than a cosmetic gap. This app's one promise is 備份我的身分證件,
/// and a person who completes that flow and sees no trace of it afterwards has
/// been given every reason to believe it failed — and the reasonable response to
/// believing it failed is to run it again, which means fetching the household
/// record from MyData a second time for nothing.
struct StoredNationalID: Equatable {

    /// The identifier `MyDataOnboardViewController` saves under. Internal rather
    /// than private to that screen because a credential only one screen can find
    /// is how this defect happened in the first place.
    static let credentialID = "national-id"

    /// Ordered for reading, not in the order the credential serialised them.
    /// The order is deliberate: what the document *is*, then who it is about,
    /// then where — the order a person reads an ID card in.
    static let displayOrder = ["nationality", "unifiedNo", "name", "birthdate", "addressOfHousehold"]

    let issuerDID: String

    /// As the credential stores it — an ISO 8601 string, not a `Date`.
    let validFromRaw: String

    /// Parsed, or nil when the stored string is not one this build understands.
    /// Kept alongside the raw value rather than replacing it: a credential
    /// issued by a future version with a format this build cannot read should
    /// still display *something* truthful, not a silently substituted "now".
    let validFrom: Date?

    let claims: [(key: String, value: String)]

    /// What to put on screen for the creation time.
    func createdDescription(style: DateFormatter.Style = .medium) -> String {
        guard let validFrom else { return validFromRaw }
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = style == .medium ? .none : .short
        return formatter.string(from: validFrom)
    }

    static func == (a: StoredNationalID, b: StoredNationalID) -> Bool {
        a.issuerDID == b.issuerDID && a.validFromRaw == b.validFromRaw
            && a.claims.map(\.key) == b.claims.map(\.key)
            && a.claims.map(\.value) == b.claims.map(\.value)
    }

    /// Loads and decodes, or nil when there is nothing stored.
    ///
    /// Signature verification is deliberately **not** performed here. This is
    /// the holder's own device reading the holder's own file to show it back to
    /// them; there is no adversary in that loop, and a failed check here would
    /// only mean the file was damaged — which shows up as a decode failure
    /// anyway. Verification is `OfflineVerifier`'s job, and it happens where it
    /// matters: when somebody else is being asked to believe this.
    static func load(from store: CredentialStoring? = try? CredentialStore()) -> StoredNationalID? {
        guard let store,
              let jws = try? store.load(id: credentialID),
              let credential = decodePayload(of: jws) else { return nil }

        let ordered = displayOrder.compactMap { key -> (key: String, value: String)? in
            guard let value = credential.credentialSubject[key], !value.isEmpty else { return nil }
            return (key: key, value: value)
        }
        // Anything the credential carries that this build does not know how to
        // order still gets shown. Dropping it would mean a newer credential
        // silently displaying fewer fields than it holds.
        //
        // `id` is the exception, and not an arbitrary one. It is the *subject
        // identifier* — this device's own `did:key` — not a fact about the
        // person. Listing it between 姓名 and 戶籍地址 would present the one value
        // in the document that makes two presentations linkable as though it
        // were another personal detail, which is precisely backwards: it is the
        // thing `VerificationCaveat.identifierIsLinkable` exists to warn about.
        let extras = credential.credentialSubject
            .filter { $0.key != "id" && !displayOrder.contains($0.key) && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return StoredNationalID(issuerDID: credential.issuer,
                                validFromRaw: credential.validFrom,
                                validFrom: parser.date(from: credential.validFrom),
                                claims: ordered + extras)
    }

    /// Pulls the credential out of the middle segment of a compact JWS.
    ///
    /// Hand-rolled rather than routed through `OfflineVerifier`, which decodes a
    /// *presentation* — a different envelope with a different shape. Reusing it
    /// would have meant constructing a fake presentation around a credential in
    /// order to read the credential.
    private static func decodePayload(of jws: String) -> VerifiableCredential? {
        let segments = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = base64URLDecoded(String(segments[1])) else { return nil }
        return try? JSONDecoder().decode(VerifiableCredential.self, from: payload)
    }

    private static func base64URLDecoded(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        // base64url drops the padding; Foundation's decoder requires it.
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    /// The label a person should see for a claim key.
    static func label(for key: String) -> String {
        switch key {
        case "nationality": return NSLocalizedString("Nationality", comment: "")
        case "unifiedNo": return NSLocalizedString("ID number", comment: "")
        case "name": return NSLocalizedString("Name", comment: "")
        case "birthdate": return NSLocalizedString("Date of birth", comment: "")
        case "addressOfHousehold": return NSLocalizedString("Household address", comment: "")
        default: return key
        }
    }
}
