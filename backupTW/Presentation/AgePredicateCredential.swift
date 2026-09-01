//
//  AgePredicateCredential.swift
//  backupTW
//

import CryptoKit
import Foundation

struct AgePredicateCredentialMaterial {
    let sdJWT: String
    let issuerDID: String
    let issuerPublicKeyX963: Data
    let holderKey: DeviceKey
}

/// Selects the requested stored card and, for the self-issued path, creates the
/// narrow SD-JWT profile the official OpenAC circuit consumes. That derivative
/// is deliberately described as self-asserted: hiding a field does not add a
/// government attestation that the original MyData PDF never carried.
struct AgePredicateCredentialProvider {
    private let holder: HolderPresentation
    private let trustLookup: OfflineIssuerTrustLookup

    init(holder: HolderPresentation,
         trustLookup: OfflineIssuerTrustLookup = .installed()) {
        self.holder = holder
        self.trustLookup = trustLookup
    }

    func material(for source: PresentationCredentialSource,
                  now: Date = Date()) throws -> AgePredicateCredentialMaterial {
        let stored = try holder.predicateCredentialMaterial(for: source)
        switch source {
        case .twdiw:
            let credential = try TWDIWCredentialReader.read(stored.serialized, now: now)
            guard trustLookup.find(credential.issuerDID) != nil else {
                throw AgePredicateProofError.credentialIsNotTrusted
            }
            let issuer = try JWKDIDKey.p256PublicKey(fromDID: credential.issuerDID)
            guard issuer.x963Representation.count == 65 else {
                throw AgePredicateProofError.credentialIsNotTrusted
            }
            return AgePredicateCredentialMaterial(sdJWT: stored.serialized,
                                                  issuerDID: credential.issuerDID,
                                                  issuerPublicKeyX963: issuer.x963Representation,
                                                  holderKey: stored.key)
        case .selfIssued:
            let derivative = try SelfIssuedMyDataAgeCredential.issue(
                stored: stored.serialized, signedBy: stored.key, now: now)
            return AgePredicateCredentialMaterial(sdJWT: derivative.sdJWT,
                                                  issuerDID: derivative.issuerDID,
                                                  issuerPublicKeyX963: stored.key.publicKeyX963,
                                                  holderKey: stored.key)
        }
    }
}

enum SelfIssuedMyDataAgeCredential {
    struct Issued {
        let sdJWT: String
        let issuerDID: String
    }

    static func issue(stored: String,
                      signedBy key: DeviceKey,
                      now: Date) throws -> Issued {
        let envelope = try MOICASignedCredential.parse(stored)
        let credential = try envelope.credential()
        // The derivative must be issued by the same per-card key the stored
        // credential names. The provider normally establishes this while
        // resolving the card, but keeping the check here closes the lower-level
        // API against an accidentally mismatched key.
        guard let subjectDID = credential.credentialSubject["id"],
              let subjectKey = try? DIDKey.p256PublicKey(fromDID: subjectDID),
              subjectKey.x963Representation == key.publicKeyX963 else {
            throw AgePredicateProofError.malformedPackage
        }
        let opened = try SelectiveDisclosure.reveal(
            disclosures: envelope.disclosures,
            committedDigests: credential.sd ?? [])
        // Older self-issued cards stored their fields in the clear; current
        // cards keep disclosures outside the signed payload. Both are local
        // MyData derivatives and both can safely become a *self-asserted* age
        // credential, so the migration path accepts either exact source.
        let rawBirth = opened.first(where: { $0.name == "birthdate" })?.value
            ?? credential.credentialSubject["birthdate"]
        guard let rawBirth,
              let birth = normalizedBirthDate(rawBirth) else {
            throw AgePredicateProofError.noBirthDate
        }

        let disclosure = Disclosure(claimName: "birthdate", claimValue: birth)
        let issuerDID = try JWKDIDKey.did(fromP256PublicKeyX963: key.publicKeyX963)
        let coordinates = key.publicKeyX963.dropFirst()
        guard coordinates.count == 64 else { throw AgePredicateProofError.malformedPackage }
        let x = Data(coordinates.prefix(32)).base64URLEncodedString()
        let y = Data(coordinates.dropFirst(32)).base64URLEncodedString()
        let issuedAt = UInt64(max(0, floor(now.timeIntervalSince1970)))

        let header: [String: Any] = [
            "alg": "ES256",
            "typ": "vc+sd-jwt",
        ]
        let payload: [String: Any] = [
            "iss": issuerDID,
            "sub": issuerDID,
            "iat": issuedAt,
            "nbf": issuedAt,
            "exp": issuedAt + 300,
            "cnf": ["jwk": ["kty": "EC", "crv": "P-256", "x": x, "y": y]],
            "vc": [
                "@context": ["https://www.w3.org/2018/credentials/v1"],
                "type": ["VerifiableCredential", "SelfIssuedMyDataAgeCredential"],
                "credentialSubject": [
                    "id": issuerDID,
                    "_sd_alg": "sha-256",
                    "_sd": [disclosure.digest],
                ],
            ],
        ]
        let encodedHeader = try base64URL(header)
        let encodedPayload = try base64URL(payload)
        let signingInput = encodedHeader + "." + encodedPayload
        let signature = try key.signature(for: Data(signingInput.utf8))
        return Issued(sdJWT: signingInput + "." + signature.base64URLEncodedString()
                      + "~" + disclosure.encoded + "~",
                      issuerDID: issuerDID)
    }

    /// Converts the two MyData shapes this app has observed into the circuit's
    /// seven-digit ROC_DATE representation. No guessed or partially parsed date
    /// is ever handed to the prover.
    static func normalizedBirthDate(_ raw: String) -> String? {
        let transformed = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        let digits = transformed.filter(\.isNumber)
        let roc: ROCDate
        if digits.count == 7,
           let year = Int(digits.prefix(3)),
           let month = Int(digits.dropFirst(3).prefix(2)),
           let day = Int(digits.suffix(2)) {
            roc = ROCDate(year: year, month: month, day: day)
        } else if let parsed = ROCDate.parse(transformed) {
            roc = parsed
        } else {
            return nil
        }
        guard roc.year > 0,
              let date = ROCDate.taipeiCalendar.date(from: DateComponents(
                year: roc.gregorianYear, month: roc.month, day: roc.day)) else {
            return nil
        }
        let roundTrip = ROCDate.taipeiCalendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == roc.gregorianYear,
              roundTrip.month == roc.month,
              roundTrip.day == roc.day else { return nil }
        return String(format: "%03d%02d%02d", roc.year, roc.month, roc.day)
    }

    private static func base64URL(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        return data.base64URLEncodedString()
    }
}
