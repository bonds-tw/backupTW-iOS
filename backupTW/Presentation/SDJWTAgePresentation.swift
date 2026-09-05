import CryptoKit
import Foundation

/// Experimental local transport of TWDIW-profile SD-JWT + RFC 9901 KB-JWT.
/// It discloses the birth date and signed metadata; it is not a ZK proof.
enum SDJWTAgePresentation {
    private struct Envelope: Codable {
        let format: String
        let presentation: String
    }

    static func audience(for request: AgePredicateProofRequest) throws -> String {
        "urn:bonds:offline-age:" + Data(SHA256.hash(data: Data(try request.encodedForTransport().utf8)))
            .base64URLEncodedString()
    }

    static func create(material: AgePredicateCredentialMaterial,
                       request: AgePredicateProofRequest, now: Date = Date()) throws -> Data {
        guard request.disclosesBirthdate else { throw AgePredicateProofError.statementMismatch }
        try request.validateFreshness(now: now)
        let credential = try TWDIWCredentialReader.read(material.sdJWT, now: now)
        guard credential.holderKey.x963Representation == material.holderKey.publicKeyX963 else {
            throw AgePredicateProofError.proofRejected
        }
        let birth = try birthClaim(in: credential)
        let sdJWT = OID4VPResponder.reserialise(credential, disclosing: [birth.name])
        let input = try encode(["alg": "ES256", "typ": "kb+jwt"]) + "." + encode([
            "nonce": request.nonce, "aud": audience(for: request),
            "iat": floor(now.timeIntervalSince1970),
            "sd_hash": Data(SHA256.hash(data: Data(sdJWT.utf8))).base64URLEncodedString(),
        ])
        let signature = try material.holderKey.signature(for: Data(input.utf8))
        let envelope = Envelope(format: "bonds-sd-jwt-age-v1", presentation:
            sdJWT + input + "." + signature.base64URLEncodedString())
        return try JSONEncoder().encode(envelope)
    }

    /// Pure, local verification. No URLSession, key fetching, or status query.
    /// Returns the age predicate; a false predicate is a failed age check even
    /// when the signatures are valid. Nothing from the credential is persisted.
    static func verify(_ data: Data, request: AgePredicateProofRequest,
                       trust: OfflineIssuerTrustLookup, now: Date = Date()) throws -> Bool {
        guard request.disclosesBirthdate, data.count <= 128_000 else {
            throw AgePredicateProofError.malformedPackage
        }
        try request.validateFreshness(now: now)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == "bonds-sd-jwt-age-v1",
              let boundary = envelope.presentation.lastIndex(of: "~") else {
            throw AgePredicateProofError.malformedPackage
        }
        let sdJWT = String(envelope.presentation[...boundary])
        let kb = String(envelope.presentation[envelope.presentation.index(after: boundary)...])
        let credential = try TWDIWCredentialReader.read(sdJWT, now: now)
        let jwt = sdJWT.split(separator: "~")[0].split(separator: ".", omittingEmptySubsequences: false)
        guard jwt.count == 3 else { throw AgePredicateProofError.malformedPackage }
        let claims = try object(String(jwt[1]))
        guard let expires = number(claims["exp"]), expires > now.timeIntervalSince1970,
              let notBefore = number(claims["nbf"]), notBefore <= now.timeIntervalSince1970 + 60 else {
            throw AgePredicateProofError.proofRejected
        }
        switch request.credentialSource {
        case .twdiw:
            guard trust.find(credential.issuerDID) != nil else {
                throw AgePredicateProofError.credentialIsNotTrusted
            }
        case .selfIssued:
            guard credential.credentialType == "SelfIssuedMyDataAgeCredential",
                  let issuer = try? JWKDIDKey.p256PublicKey(fromDID: credential.issuerDID),
                  issuer.x963Representation == credential.holderKey.x963Representation else {
                throw AgePredicateProofError.sourceMismatch
            }
        }
        let segments = kb.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3 else { throw AgePredicateProofError.malformedPackage }
        let header = try object(segments[0]), body = try object(segments[1])
        guard header["alg"] as? String == "ES256", header["typ"] as? String == "kb+jwt",
              body["nonce"] as? String == request.nonce,
              body["aud"] as? String == (try audience(for: request)),
              body["sd_hash"] as? String == Data(SHA256.hash(data: Data(sdJWT.utf8))).base64URLEncodedString(),
              let issuedAt = number(body["iat"]),
              issuedAt >= request.createdAt.timeIntervalSince1970 - 60,
              issuedAt <= now.timeIntervalSince1970 + 60,
              let bytes = Data(base64URLEncoded: segments[2]),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: bytes),
              credential.holderKey.isValidSignature(signature, for: Data((segments[0] + "." + segments[1]).utf8)) else {
            throw AgePredicateProofError.proofRejected
        }
        let birth = try birthClaim(in: credential)
        guard credential.disclosedClaims.count == 1 else { throw AgePredicateProofError.statementMismatch }
        return try dateValue(birth.value) <= request.cutoffValue(claimFormat: 2)
    }

    private static func birthClaim(in credential: TWDIWCredential) throws -> (name: String, value: String) {
        let matches = credential.disclosedClaims.filter { AgePredicateProofPackage.supportedBirthClaimNames.contains($0.name) }
        guard matches.count == 1, let match = matches.first else { throw AgePredicateProofError.noBirthDate }
        _ = try dateValue(match.value)
        return match
    }

    static func dateValue(_ value: String) throws -> UInt64 {
        let year: Int, month: Int, day: Int
        if value.utf8.count == 7, value.utf8.allSatisfy({ (48...57).contains($0) }) {
            year = Int(value.prefix(3))! + 1911
            month = Int(value.dropFirst(3).prefix(2))!
            day = Int(value.suffix(2))!
        } else if value.utf8.count == 10 {
            let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
                  pieces.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]) else {
                throw AgePredicateProofError.noBirthDate
            }
            (year, month, day) = (y, m, d)
        } else { throw AgePredicateProofError.noBirthDate }
        let calendar = ROCDate.taipeiCalendar
        let parts = DateComponents(year: year, month: month, day: day)
        guard year > 0, let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: date) == parts else {
            throw AgePredicateProofError.noBirthDate
        }
        return UInt64(year * 10_000 + month * 100 + day)
    }

    private static func encode(_ value: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]).base64URLEncodedString()
    }
    private static func object(_ value: String) throws -> [String: Any] {
        guard let data = Data(base64URLEncoded: value),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgePredicateProofError.malformedPackage
        }
        return value
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
