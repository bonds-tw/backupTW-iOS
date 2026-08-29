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
    static let displayOrder = ["nationality", "unifiedNo", "name", "birthdate",
                               AgePredicate.claimName, "addressOfHousehold"]

    let issuerDID: String

    /// Whether the stored file is a `MOICASignedCredential` rather than the
    /// older device-signed compact JWS.
    ///
    /// Carried because the holder's own screen has to say who signed, and the
    /// two answers are opposite. `issuerDID` cannot stand in for it: it is the
    /// device's `did:key` in *both* forms — the subject identifier the holder
    /// presents under, which is a separate thing from what secured the document.
    /// Reading the envelope is the only way to tell, and `decodePayload` already
    /// has to do it, so the answer travels rather than being recomputed.
    let isCardSigned: Bool

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
        // The raw string only reaches a screen when it failed to parse as a
        // date — which is exactly when it might be anything at all. A stored
        // credential file is this device's own, but "our own disk" and
        // "trusted for layout" are different claims: a `validFrom` carrying a
        // newline or a bidi override would rearrange the home screen. Same
        // pipe as every other unparseable string, no bespoke filtering.
        guard let validFrom else { return UntrustedText.value(validFromRaw).text }
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = style == .medium ? .none : .short
        return formatter.string(from: validFrom)
    }

    static func == (a: StoredNationalID, b: StoredNationalID) -> Bool {
        a.issuerDID == b.issuerDID && a.validFromRaw == b.validFromRaw
            // Two documents carrying identical fields but secured differently
            // are not the same document — one is vouched for by a cardholder's
            // certificate and the other by nothing but this phone.
            && a.isCardSigned == b.isCardSigned
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
              let decoded = decodePayload(of: jws) else { return nil }
        let credential = decoded.credential

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
                                isCardSigned: decoded.isCardSigned,
                                validFromRaw: credential.validFrom,
                                validFrom: parser.date(from: credential.validFrom),
                                claims: ordered + extras)
    }

    /// Pulls the credential out of whichever envelope `CredentialStore` holds.
    ///
    /// Both forms are read, and that is not indecision: a credential issued
    /// before the card-signing change is still on disk for anyone who onboarded
    /// then, and the home screen going blank for them would look exactly like
    /// the defect this type was written to fix.
    ///
    /// Hand-rolled rather than routed through `OfflineVerifier`, which decodes a
    /// *presentation* — a different envelope with a different shape. Reusing it
    /// would have meant constructing a fake presentation around a credential in
    /// order to read the credential.
    /// Returns which envelope it was as well as what was inside it. The two
    /// travel together because the caller needs both and only this function can
    /// tell them apart — a card-signed credential and a device-signed one decode
    /// to indistinguishable `VerifiableCredential`s, since the device DID is the
    /// subject identifier in both.
    private static func decodePayload(of stored: String)
        -> (credential: VerifiableCredential, isCardSigned: Bool)? {
        if let cardSigned = try? MOICASignedCredential.parse(stored) {
            // Not verified here, for the reason `load` gives above: this is the
            // holder's own device reading the holder's own file back to them.
            guard var credential = try? cardSigned.credential() else { return nil }
            // The holder sees everything: they hold every disclosure, and a
            // screen that showed them digests would be hiding their own document
            // from them. Withholding is a decision made at presentation, not a
            // property of the file.
            if let committed = credential.sd,
               let revealed = try? SelectiveDisclosure.reveal(disclosures: cardSigned.disclosures,
                                                              committedDigests: committed) {
                credential = VerifiableCredential(
                    context: credential.context,
                    type: credential.type,
                    issuer: credential.issuer,
                    validFrom: credential.validFrom,
                    credentialSubject: credential.credentialSubject
                        .merging(Dictionary(revealed.map { ($0.name, $0.value) }) { a, _ in a }) { a, _ in a },
                    sd: committed)
            }
            return (credential, true)
        }
        let segments = stored.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = base64URLDecoded(String(segments[1])),
              let credential = try? JSONDecoder().decode(VerifiableCredential.self, from: payload) else {
            return nil
        }
        return (credential, false)
    }

    private static func base64URLDecoded(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        // base64url drops the padding; Foundation's decoder requires it.
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    /// The value a *holder* should see for a claim.
    ///
    /// One special case: the age predicate is stored as the strings "true" /
    /// "false" because that is what the card signed, and the raw token leaked
    /// straight onto the holder’s own screens (「發證時已滿 18 歲 / true」,
    /// photographed on device 2026-08-11). A person reads 「是」.
    ///
    /// Holder-facing only. The verifier’s result screen quotes the document’s
    /// own bytes under its 「原樣引述」 discipline and must keep showing the
    /// literal value — translating there would put this app’s words in the
    /// document’s mouth.
    static func displayValue(for key: String, value: String) -> String {
        guard key == AgePredicate.claimName else { return value }
        switch value {
        case "true": return NSLocalizedString("Yes", comment: "Holder-facing value of the over-18 claim")
        case "false": return NSLocalizedString("No", comment: "Holder-facing value of the over-18 claim")
        default: return value
        }
    }

    /// The label a person should see for a claim key.
    static func label(for key: String) -> String {
        switch key {
        case "nationality": return NSLocalizedString("Nationality", comment: "")
        case "unifiedNo": return NSLocalizedString("ID number", comment: "")
        case "name": return NSLocalizedString("Name", comment: "")
        case "birthdate": return NSLocalizedString("Date of birth", comment: "")
        case "addressOfHousehold": return NSLocalizedString("Household address", comment: "")
        case AgePredicate.claimName:
            // Named for when it was true. "Over 18" alone would read as a
            // statement about today, and on a credential issued years ago the
            // false case would then be a lie by omission of its own timestamp.
            return NSLocalizedString("Had turned 18 when issued", comment: "")
        default: break
        }
        // Keys from *other* issuers' cards (government, telecom) — the ones this
        // app did not mint. Matched case-insensitively against the curated table
        // below (the same one 設定 › 信任 › 欄位對照表 lists), so 「id_number」 reads as
        // 身分證字號 rather than a raw machine key. Anything not in the table still
        // falls through to the key itself, which `ClaimLabel` frames as 「declared by
        // their document」 rather than this app's own word.
        let lowered = key.lowercased()
        if let hit = fieldLabelTable.first(where: { $0.keys.contains(lowered) }) {
            return hit.label
        }
        return key
    }

    /// Curated 「other issuers' machine key → the app's own words」 table, matched
    /// case-insensitively and **exactly** (not by substring, so a key that merely
    /// contains one of these is not mislabelled). Shown in 設定 › 信任 › 欄位對照表 and
    /// used by `label(for:)`; the sample key is the first of each row.
    static let fieldLabelTable: [(keys: [String], label: String)] = [
        (["id_number", "idnumber", "national_id", "nationalid"], NSLocalizedString("ID number", comment: "field label")),
        (["name", "full_name", "fullname"], NSLocalizedString("Name", comment: "field label")),
        (["address", "addr", "住址", "地址", "戶籍地址"], NSLocalizedString("Address", comment: "field label")),
        (["birthday", "birthdate", "roc_birthday", "dob", "dateofbirth"], NSLocalizedString("Date of birth", comment: "field label")),
        (["gender", "sex"], NSLocalizedString("Gender", comment: "field label")),
        (["nationality"], NSLocalizedString("Nationality", comment: "field label")),
        (["license_number", "licence_number", "licenseno", "licence_no"], NSLocalizedString("Licence number", comment: "field label")),
        (["controlnumber", "control_number"], NSLocalizedString("Control number", comment: "field label; the driving-licence 管轄編號")),
        // The real 公路局 driving-licence disclosed a bare `type` for the vehicle
        // class (value 「普通小型車」). It is generic enough to collide in theory,
        // but the driving licence is the only card in this ecosystem that carries
        // it, and a reader is far better served by 車輛類別 than the raw key.
        (["vehicle_type", "car_type", "license_class", "class", "type"], NSLocalizedString("Vehicle class", comment: "field label")),
        (["msisdn", "mobile", "phone", "phone_number", "mobile_number"], NSLocalizedString("Mobile number", comment: "field label")),
        (["phone_number_last3", "phonel3"], NSLocalizedString("Mobile number (last 3)", comment: "field label; convenience-store pickup card")),
        (["carrier", "telecom", "operator"], NSLocalizedString("Carrier", comment: "field label")),
        // `gDate` is the driving-licence issue date (民國 date, e.g. 1020701).
        (["issue_date", "issuedate", "valid_from", "validfrom", "gdate"], NSLocalizedString("Valid from", comment: "field label")),
        (["expiry", "expiration", "valid_until", "validuntil", "expires", "expiry_date"], NSLocalizedString("Valid until", comment: "field label")),
    ]
}
