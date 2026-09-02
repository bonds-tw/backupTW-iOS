//
//  OID4VPRequest.swift
//  backupTW
//
//  A verifier asked for a presentation. What exactly did it ask for, and did
//  it really sign the ask?
//

import CryptoKit
import Foundation

enum OID4VPRequestError: Error, Equatable {
    /// Not an `…://authorize?…` link, or missing `client_id` / `request_uri`.
    case notAnAuthorizeLink
    /// The request object is not a three-part compact JWS.
    case malformedRequestObject
    /// `client_id` is not a `did:key` this app can take a P-256 key from.
    case clientIDNotAResolvableDID
    /// The request object's signature does not verify against the key in
    /// `client_id`. Measured shape: header `typ: oauth-authz-req+jwt`, signed
    /// with the verifier's key; `client_id` is the DID that key lives in.
    case signatureInvalid
    /// A field the response cannot be built without is missing.
    case missingField(String)
    /// `response_mode` is not `direct_post`. The other modes send the token
    /// back a different way this app has not built; naming it beats a generic
    /// failure three steps later.
    case unsupportedResponseMode(String)
    /// `response_uri`'s host is not one this wallet will post a signed token to
    /// — the verifier equivalent of the issuer trust-list gate.
    case responseURINotTrusted(host: String)
    /// The `request_uri` the QR pointed at is not a host this wallet will
    /// fetch from. Checked **before** the GET, because the fetch itself leaves
    /// the device — the same "gate before the first request" rule as the
    /// issuer offer's `authorise(fetchURL:)`.
    case requestURINotTrusted(host: String)
    /// The network failed fetching the request object.
    case network
    /// The server answered the request-object fetch with a non-2xx status.
    case badStatus(Int)
}

/// The `openid4vp` / `modadigitalwallet://authorize` link a verifier shows,
/// carrying either the request object inline or a `request_uri` to fetch it.
enum OID4VPAuthorizeLink: Equatable {
    case byReference(clientID: String, requestURI: String)
    case byValue(clientID: String, requestObject: String)

    private static let schemes: Set<String> = ["openid4vp", "modadigitalwallet"]

    /// Reads the link from a **scanned string**, tolerating the framing a QR
    /// carries. The credential-offer deep link was measured to embed a CR+LF
    /// after its `?`; the authorize form shares the scheme and host convention,
    /// so it is normalised the same way — bytes off a camera are not a URL the OS
    /// built. See `CredentialOfferLink.parse(scanned:)`.
    static func parse(scanned: String) throws -> OID4VPAuthorizeLink {
        let cleaned = scanned
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: cleaned) else {
            throw OID4VPRequestError.notAnAuthorizeLink
        }
        return try parse(url)
    }

    /// Reads the link. Like `CredentialOfferLink`, this only says which form it
    /// is; it does not fetch, verify, or trust anything.
    static func parse(_ url: URL) throws -> OID4VPAuthorizeLink {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else {
            throw OID4VPRequestError.notAnAuthorizeLink
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OID4VPRequestError.notAnAuthorizeLink
        }
        // `modadigitalwallet://authorize?…` puts `authorize` in the host slot,
        // the same way its credential-offer form puts `credential_offer` there.
        if let host = components.host, !host.isEmpty, host != "authorize" {
            throw OID4VPRequestError.notAnAuthorizeLink
        }
        let items = components.queryItems ?? []
        guard let clientID = items.first(where: { $0.name == "client_id" })?.value,
              !clientID.isEmpty else {
            throw OID4VPRequestError.notAnAuthorizeLink
        }
        if let uri = items.first(where: { $0.name == "request_uri" })?.value, !uri.isEmpty {
            return .byReference(clientID: clientID, requestURI: uri)
        }
        if let obj = items.first(where: { $0.name == "request" })?.value, !obj.isEmpty {
            return .byValue(clientID: clientID, requestObject: obj)
        }
        throw OID4VPRequestError.notAnAuthorizeLink
    }
}

/// One field the verifier asked to see, from an input descriptor's constraints.
struct OID4VPRequestedField: Equatable {
    /// The JSONPath the descriptor named, e.g. `$.credentialSubject.name`.
    let path: String

    /// The claim name at the end of the path, when the path is a simple
    /// `$.credentialSubject.<name>`. `nil` for paths like `$.type` that select
    /// something other than a disclosable claim.
    var claimName: String? {
        let prefix = "$.credentialSubject."
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        return name.contains(".") ? nil : name
    }
}

/// One alternative named by a DIF presentation definition.
///
/// The production convenience-store request does not ask for one fixed card. It
/// names the three carriers once for the 「姓名」 group and once again for the
/// 「末五碼」 group. Keeping the descriptor boundary is therefore protocol data,
/// not UI decoration: the response must echo the descriptor id that matches the
/// carrier actually held, for each selected group.
struct OID4VPInputDescriptor: Equatable {
    let id: String
    let credentialType: String?
    let requestedFields: [OID4VPRequestedField]
    let groups: [String]
    let credentialName: String?
    let issuerName: String?
}

/// How a verifier combines descriptor groups. TWDIW currently emits DIF
/// `pick` requirements with `max: 1` for each convenience-store field group.
struct OID4VPSubmissionRequirement: Equatable {
    let name: String?
    let rule: String
    let from: String
    let count: Int?
    let min: Int?
    let max: Int?
}

/// A verified presentation request, reduced to what building a response needs.
struct OID4VPRequest: Equatable {

    /// Where the signed `vp_token` is posted back. **Verified**: the request
    /// object it came in was signed by `clientID`'s key.
    let responseURI: String

    /// The verifier's identifier, a `did:key`. Its key verified the request.
    let clientID: String

    /// Binds this exchange. The `vp_token` must carry it, or a captured token
    /// could be replayed to the same verifier.
    let nonce: String

    /// Echoed back in the response so the verifier can match it to its session.
    let state: String

    /// Every credential alternative and its own claims/group membership.
    let inputDescriptors: [OID4VPInputDescriptor]

    /// The group-selection rules. Empty is the legacy one-descriptor form.
    let submissionRequirements: [OID4VPSubmissionRequirement]

    /// `presentation_definition.id`, echoed into the submission so the verifier
    /// can tie the response to the request it sent.
    let definitionID: String

    /// Compatibility views for the original one-descriptor request. Callers that
    /// build a response use `inputDescriptors`, never these conveniences.
    var credentialType: String? { inputDescriptors.first?.credentialType }
    var inputDescriptorID: String { inputDescriptors.first?.id ?? "" }

    /// Unique fields in verifier order. A field such as `name` appears once even
    /// when several carrier alternatives each request it.
    var requestedFields: [OID4VPRequestedField] {
        var seen = Set<String>()
        return inputDescriptors.flatMap(\.requestedFields).filter { seen.insert($0.path).inserted }
    }

    /// Verifies a request object and reduces it.
    ///
    /// - Parameters:
    ///   - compactJWS: the `oauth-authz-req+jwt` fetched from `request_uri`.
    ///   - clientID: the `did:key` from the authorize link; its embedded key
    ///     must have signed `compactJWS`.
    ///   - trustedResponseHosts: hosts this wallet will post a token to. The
    ///     `response_uri` inside the request must be one of them — a verifier
    ///     naming a `response_uri` off this list is refused before anything is
    ///     signed, the same discipline as the issuer gate in M5.2.
    static func verify(compactJWS: String,
                       clientID: String,
                       trustedResponseHosts: Set<String>) throws -> OID4VPRequest {
        let parts = compactJWS.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw OID4VPRequestError.malformedRequestObject }

        // The signing key comes from client_id, not from the header's `kid`
        // (measured: `kid` is the opaque string `verifier-did`). Same rule as
        // TWDIWCredentialReader — the key is named by the value being checked,
        // so it must be the caller's `client_id`, resolved as a did:key.
        let key: P256.Signing.PublicKey
        do { key = try JWKDIDKey.p256PublicKey(fromDID: clientID) }
        catch {
            // Fall back to the other did:key spelling this app issues.
            guard let k = try? DIDKey.p256PublicKey(fromDID: clientID) else {
                throw OID4VPRequestError.clientIDNotAResolvableDID
            }
            key = k
        }
        guard let signature = Data(base64URLEncoded: parts[2]),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            throw OID4VPRequestError.malformedRequestObject
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(ecdsa, for: signingInput) else {
            throw OID4VPRequestError.signatureInvalid
        }

        guard let payloadData = Data(base64URLEncoded: parts[1]),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw OID4VPRequestError.malformedRequestObject
        }

        if let mode = payload["response_mode"] as? String, mode != "direct_post" {
            throw OID4VPRequestError.unsupportedResponseMode(mode)
        }
        guard let responseURI = payload["response_uri"] as? String, !responseURI.isEmpty else {
            throw OID4VPRequestError.missingField("response_uri")
        }
        // The gate: a signed token is about to be addressable here, so the host
        // must be one we chose to trust — not one the request chose for us.
        guard case .success(let host) = IssuerAuthorization.normalisedHost(of: responseURI),
              trustedResponseHosts.contains(host) else {
            let host = (try? IssuerAuthorization.normalisedHost(of: responseURI).get()) ?? responseURI
            throw OID4VPRequestError.responseURINotTrusted(host: host)
        }
        guard let nonce = payload["nonce"] as? String, !nonce.isEmpty else {
            throw OID4VPRequestError.missingField("nonce")
        }
        guard let state = payload["state"] as? String, !state.isEmpty else {
            throw OID4VPRequestError.missingField("state")
        }

        let definition = payload["presentation_definition"] as? [String: Any]
        guard let definitionID = definition?["id"] as? String else {
            throw OID4VPRequestError.missingField("presentation_definition.id")
        }
        let rawDescriptors = definition?["input_descriptors"] as? [[String: Any]] ?? []
        guard !rawDescriptors.isEmpty else {
            throw OID4VPRequestError.missingField("input_descriptors[0].id")
        }

        var descriptors: [OID4VPInputDescriptor] = []
        for (index, descriptor) in rawDescriptors.enumerated() {
            guard let descriptorID = descriptor["id"] as? String, !descriptorID.isEmpty else {
                throw OID4VPRequestError.missingField("input_descriptors[\(index)].id")
            }
            var credentialType: String?
            var fields: [OID4VPRequestedField] = []
            let constraintFields = (descriptor["constraints"] as? [String: Any])?["fields"] as? [[String: Any]] ?? []
            for field in constraintFields {
                let paths = field["path"] as? [String] ?? []
                for path in paths {
                    if path == "$.type" {
                        // The type constraint carries the required card type in
                        // its `contains.const`.
                        if let filter = field["filter"] as? [String: Any],
                           let contains = filter["contains"] as? [String: Any],
                           let const = contains["const"] as? String {
                            credentialType = const
                        }
                    } else {
                        fields.append(OID4VPRequestedField(path: path))
                    }
                }
            }
            var credentialName: String?
            var issuerName: String?
            if let nameJSON = descriptor["name"] as? String,
               let nameData = nameJSON.data(using: .utf8),
               let names = try? JSONSerialization.jsonObject(with: nameData) as? [String: Any] {
                credentialName = names["vc_name"] as? String
                issuerName = names["org_tw_name"] as? String
            }
            descriptors.append(OID4VPInputDescriptor(
                id: descriptorID,
                credentialType: credentialType,
                requestedFields: fields,
                groups: descriptor["group"] as? [String] ?? [],
                credentialName: credentialName,
                issuerName: issuerName))
        }

        let rawRequirements = definition?["submission_requirements"] as? [[String: Any]] ?? []
        let requirements = rawRequirements.compactMap { raw -> OID4VPSubmissionRequirement? in
            guard let rule = raw["rule"] as? String,
                  let from = raw["from"] as? String,
                  !rule.isEmpty, !from.isEmpty else { return nil }
            return OID4VPSubmissionRequirement(name: raw["name"] as? String,
                                                rule: rule,
                                                from: from,
                                                count: raw["count"] as? Int,
                                                min: raw["min"] as? Int,
                                                max: raw["max"] as? Int)
        }

        return OID4VPRequest(responseURI: responseURI,
                             clientID: clientID,
                             nonce: nonce,
                             state: state,
                             inputDescriptors: descriptors,
                             submissionRequirements: requirements,
                             definitionID: definitionID)
    }
}
