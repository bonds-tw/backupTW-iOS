//
//  SelectiveDisclosure.swift
//  backupTW
//
//  Showing one field without showing the rest.
//

import Foundation
import CryptoKit

/// One hidden claim and the secret needed to reveal it, in the SD-JWT shape.
///
/// The wire form is `base64url(JSON([salt, name, value]))`, and the digest that
/// goes in the credential is taken over **that string**, not over the decoded
/// array. Digesting the decoded form would make the value depend on this
/// build's JSON encoder — key order, spacing, escaping — and two
/// implementations that disagree about any of those would compute different
/// digests for the same disclosure. The encoded string is the thing both sides
/// actually hold, so it is the thing both sides digest.
struct Disclosure: Equatable, Sendable {

    let salt: String
    let claimName: String
    let claimValue: String

    /// `base64url(JSON([salt, name, value]))`.
    let encoded: String

    /// `base64url(SHA-256(encoded))` — what appears in the credential's `_sd`.
    var digest: String {
        Self.digest(of: encoded)
    }

    static func digest(of encoded: String) -> String {
        Data(SHA256.hash(data: Data(encoded.utf8))).base64URLEncodedString()
    }

    /// # Why the salt is 128 bits and not, say, a counter
    ///
    /// Without a salt, a digest over `["nationality", "中華民國"]` is a digest
    /// over a value drawn from a domain of maybe a dozen possibilities, and a
    /// verifier who received *no* nationality disclosure could still recover it
    /// by hashing every candidate until one matched an entry in `_sd`. The same
    /// argument is far worse for `birthdate`: about 40,000 plausible dates, a
    /// rounding error to brute force.
    ///
    /// So every disclosure gets its own 128 bits from the system CSPRNG. Reusing
    /// one salt across claims would also let a verifier confirm that two
    /// credentials came from the same issuance, which is the linkability this
    /// app already carries one caveat about and does not need a second source of.
    init(claimName: String, claimValue: String, salt: String? = nil) {
        let salt = salt ?? Self.randomSalt()
        self.salt = salt
        self.claimName = claimName
        self.claimValue = claimValue

        // Hand-built rather than `JSONEncoder`: the array form is fixed by
        // SD-JWT and the escaping has to be predictable, because the digest is
        // over these exact bytes.
        let array: [String] = [salt, claimName, claimValue]
        let data = (try? JSONSerialization.data(withJSONObject: array,
                                                options: [.withoutEscapingSlashes]))
            ?? Data("[]".utf8)
        self.encoded = data.base64URLEncodedString()
    }

    /// Rebuilds a disclosure from the wire, refusing anything that is not
    /// exactly a three-element array of strings.
    ///
    /// Strict on purpose: a disclosure carrying a nested object or a number
    /// would be a different shape than the one whose digest the issuer
    /// committed to, and accepting it would mean the verifier and the issuer
    /// disagree about what was disclosed.
    init?(encoded: String) {
        guard let data = Data(base64URLEncoded: encoded),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count == 3,
              let salt = array[0] as? String,
              let name = array[1] as? String,
              let value = array[2] as? String,
              !salt.isEmpty, !name.isEmpty else { return nil }
        self.salt = salt
        self.claimName = name
        self.claimValue = value
        self.encoded = encoded
    }

    private static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        // `SecRandomCopyBytes` rather than `Int.random`: this is the value that
        // stops a verifier brute-forcing an undisclosed claim, so it has to come
        // from the system CSPRNG and not from a generator seeded for speed.
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

/// Splits a set of claims into commitments the issuer signs and disclosures the
/// holder keeps, then puts them back together for a verifier.
enum SelectiveDisclosure {

    enum DisclosureError: Error, Equatable {
        /// A disclosure arrived whose digest is not among the ones the issuer
        /// committed to. The holder is trying to add a claim.
        case undisclosedDigest(String)
        /// The same claim name arrived twice.
        case duplicateClaim(String)
        /// A disclosure string that is not a valid three-element array.
        case malformedDisclosure(String)
    }

    /// Turns claims into (`_sd` digests, disclosures).
    ///
    /// The digest array is **sorted**, and that is a security property rather
    /// than tidiness. Left in claim order, position would leak which digest
    /// belongs to which field: a verifier receiving only the second entry's
    /// disclosure would learn that the first, undisclosed one is whatever the
    /// issuer always puts first. Sorting by the digest — a value with no
    /// relationship to the claim name — destroys that correspondence.
    static func commit(_ claims: [(name: String, value: String)])
        -> (digests: [String], disclosures: [Disclosure]) {
        let disclosures = claims.map { Disclosure(claimName: $0.name, claimValue: $0.value) }
        return (disclosures.map(\.digest).sorted(), disclosures)
    }

    /// Verifies a set of presented disclosures against the issuer's committed
    /// digests, and returns the claims they reveal.
    ///
    /// Every disclosure must match a committed digest. A holder who could
    /// present a disclosure the issuer never committed to could assert anything
    /// — the entire value of the credential rests on this check.
    ///
    /// The reverse is deliberately *not* an error: committed digests with no
    /// matching disclosure are the whole point. Those are the claims being
    /// withheld, and a verifier that demanded all of them would have abolished
    /// selective disclosure while appearing to implement it.
    static func reveal(disclosures encodedDisclosures: [String],
                       committedDigests: [String]) throws -> [(name: String, value: String)] {
        let committed = Set(committedDigests)
        var seen = Set<String>()
        var claims: [(name: String, value: String)] = []

        for encoded in encodedDisclosures {
            guard let disclosure = Disclosure(encoded: encoded) else {
                throw DisclosureError.malformedDisclosure(encoded)
            }
            let digest = disclosure.digest
            guard committed.contains(digest) else {
                throw DisclosureError.undisclosedDigest(digest)
            }
            guard seen.insert(disclosure.claimName).inserted else {
                // Two disclosures for one claim name can carry different values,
                // and which one wins would depend on iteration order.
                throw DisclosureError.duplicateClaim(disclosure.claimName)
            }
            claims.append((name: disclosure.claimName, value: disclosure.claimValue))
        }
        return claims
    }

    /// How many claims were held back — the number a screen should show so the
    /// verifier knows the presentation is partial.
    ///
    /// A verifier looking at three fields cannot otherwise tell whether that is
    /// the whole credential or three of eight, and "this is everything" is a
    /// materially different statement from "this is what they chose to show".
    static func withheldCount(committedDigests: [String], revealed: Int) -> Int {
        max(0, committedDigests.count - revealed)
    }
}

// MARK: - base64url

extension Data {

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}
