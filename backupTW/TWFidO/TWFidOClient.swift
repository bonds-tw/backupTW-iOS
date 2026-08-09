//
//  TWFidOClient.swift
//  backupTW
//
//  Talks to the TW FidO SP API (內政部行動自然人憑證) for the SIGN operation.
//

import CryptoKit
import Foundation

// MARK: - Requests and responses

/// What the cardholder's 自然人憑證 key is asked to sign.
///
/// # Why this is an enum and not a `String`
///
/// The two values below look alike — both are lowercase hex — and swapping them
/// fails silently in opposite directions, so the type refuses to let a call site
/// leave its intent implicit.
///
/// - `relyingPartyIdentifier` is a **constant**. The zkID circuit hashes it
///   together with the cardholder's key to derive the nullifier, and a verifier
///   establishes that a proof is Sybil-resistant by pinning this public input to
///   the identifier it expects. Signing anything else here yields a proof that
///   generates successfully and verifies against nothing.
/// - `credentialTBS` is **per credential**. It binds the cardholder's
///   signature to a specific set of MyData field facts, which is the whole point
///   of issuing under 行憑 rather than under the device key.
///
/// # Why one signature cannot serve both
///
/// The circuit's `tbs` is one field element and so caps at 31 characters — see
/// `ProvingInputs.relyingPartyIdentifierLength`. A SHA-256 digest truncated to
/// 31 hex characters is 124 bits, which leaves **62-bit collision resistance**,
/// and the party we are binding here is the one with the incentive to break it:
/// the holder supplies the MyData document, so they can grind two field sets to
/// a common truncated digest, have the card sign the honest one, and present the
/// forged one under the same signature. 2⁶² digests is hours of commodity
/// hardware. So the credential digest goes to 內政部 at full length and does not
/// enter the circuit, and the holding proof keeps signing the constant.
///
/// The cost of that split is worth naming rather than discovering later: in the
/// ZK path the certificate is a private witness, so a verifier receiving a proof
/// **cannot** check that its holder is the cardholder who signed the credential.
/// Binding the two is what `MOICASignedCredential` gives the disclosed path, and
/// it is exactly what the ZK path still lacks.
enum TWFidOSigningTarget: Equatable, Sendable {

    /// The 31-character relying-party namespace — `TWFidOConfiguration.appID`.
    case relyingPartyIdentifier(String)

    /// A credential's complete TBS from `MOICASignedCredential.toBeSigned(for:)`
    /// — the `bonds-tw-credential-v1:` domain prefix and the digest, already
    /// joined.
    ///
    /// Named for what it carries, not `credentialDigest`, because the
    /// distinction is load-bearing: a caller who passes the bare digest here
    /// produces a signature that generates fine and verifies against nothing.
    /// The prefix is what stops a signature some *other* honest service obtained
    /// over a 64-hex-character value from doubling as a credential proof.
    case credentialTBS(String)

    /// The TBS itself. `sign_data` is this string, base64-wrapped — the wrapping
    /// is what `tbs_encoding: "base64"` describes, and it is not part of what
    /// the key signs.
    var toBeSigned: String {
        switch self {
        case .relyingPartyIdentifier(let identifier): return identifier
        case .credentialTBS(let tbs): return tbs
        }
    }
}

/// One request for the holder to sign, with their 自然人憑證, whatever
/// `signing` names.
struct TWFidOSignRequest {

    /// 身分證統一編號. Sent to 內政部 because the API is keyed on it, and never
    /// logged, never persisted by this layer, never echoed into an error.
    let idNumber: String

    /// Shown to the holder inside the 行動自然人憑證 app while they approve.
    /// User-visible: callers must pass an `NSLocalizedString`, not a literal.
    let hint: String

    /// Push transport only — the 裝置別名 the holder gave one bound device.
    /// `nil` fans the push out to every device they have bound. Ignored by the
    /// app-to-app transport, which has no push target.
    let deviceAlias: String?

    /// Seconds the ticket stays valid, 30–600 per the spec.
    ///
    /// Goes on the wire as a JSON number: the spec's field table types
    /// `time_limit` as Integer and the official JAVA sample posts
    /// `formBody.put("time_limit", 600)`.
    ///
    /// Range-checked by `TWFidOClient` before anything is sent — see
    /// `TWFidOClient.allowedTimeLimits`.
    let timeLimit: Int

    /// What the card is asked to put its signature over.
    ///
    /// No default value on purpose. This used to be implicit — the client always
    /// signed `app_id` — and that implicitness is what let the MyData fields be
    /// signed by nothing but the device's own key while a 內政部 signature over
    /// an unrelated constant sat beside them, bound to them by nothing at all.
    let signing: TWFidOSigningTarget

    init(idNumber: String,
         hint: String,
         signing: TWFidOSigningTarget,
         deviceAlias: String? = nil,
         timeLimit: Int = 600) {
        self.idNumber = idNumber
        self.hint = hint
        self.signing = signing
        self.deviceAlias = deviceAlias
        self.timeLimit = timeLimit
    }
}

/// An issued `sp_ticket`, with the two identifiers unpacked from it.
///
/// The transport handed us only the opaque string, but polling for the result
/// needs `transaction_id` and `sp_ticket_id`, both of which live inside the
/// ticket's own payload — so decoding is mandatory, not a debug convenience.
struct TWFidOTicket: Equatable {
    let spTicket: String
    let transactionID: String
    let spTicketID: String
}

/// The signature material, once the holder has approved.
struct TWFidOSignResult: Equatable {

    /// Base64 DER of the **holder's** certificate. The issuing CA (MOICA G3) is
    /// bundled with the app separately — feeding this where the issuer is
    /// expected is the classic way to break proof generation.
    let cert: String

    /// Base64 PKCS#1 signature over our `app_id`.
    let signedResponse: String

    /// The server's hash of the ID number. Nothing downstream consumes it, but
    /// it is covered by `idp_checksum`, so it is carried through rather than
    /// dropped: the value we verified and the value we hand on have to be the
    /// same one.
    let hashedIDNumber: String
}

/// Equatable so tests can pin the exact case. Every payload here is a code or a
/// field name — nothing that identifies a holder.
enum TWFidOError: Error, Equatable {
    /// Response was not HTTP, or the body was not the documented envelope.
    case invalidResponse
    case httpStatus(Int)
    /// A terminal `error_code` from the SP API.
    case server(code: String, message: String?)
    /// `sp_ticket` was not `base64url(payload).base64url(digest)` carrying the
    /// two identifiers we need.
    case malformedTicket(String)
    /// `error_code` was "0" but a field the caller depends on was absent.
    case missingResultField(String)
    /// The return URL could not be expressed in a deep link.
    case invalidReturnURL
    /// The result carried an `idp_checksum` that does not authenticate it: it
    /// did not open under our SP AES key, or it opened but covers a different
    /// response. Either way the body is not evidence of anything 內政部 said.
    case unauthenticatedResult
    /// `time_limit` outside the 30–600 seconds the spec allows. Carries the
    /// offending value because this is a caller bug and the number is the whole
    /// diagnosis; it is not holder data.
    case invalidTimeLimit(Int)
}

extension TWFidOError: LocalizedError {

    /// Deliberately generic. The server's own `error_message` is not shown:
    /// it is Chinese-or-English by server whim, and surfacing it verbatim
    /// invites echoing whatever the API decides to include. The code is kept so
    /// a support report can identify the failure.
    var errorDescription: String? {
        switch self {
        case .invalidResponse, .missingResultField, .malformedTicket:
            return NSLocalizedString("The digital certificate service returned an unexpected response.",
                                     comment: "")
        case .httpStatus:
            return NSLocalizedString("Could not reach the digital certificate service.", comment: "")
        case .server(let code, _):
            let format = NSLocalizedString("The digital certificate service refused the request (%@).",
                                           comment: "")
            return String(format: format, code)
        case .invalidReturnURL:
            return NSLocalizedString("The digital certificate service returned an unexpected response.",
                                     comment: "")
        case .unauthenticatedResult:
            // Deliberately the same sentence as `.invalidResponse`. A failed
            // integrity check and a malformed body are the same thing to the
            // holder — "we cannot trust what came back" — and a distinct message
            // would tell whoever produced the body which check it tripped.
            return NSLocalizedString("The digital certificate service returned an unexpected response.",
                                     comment: "")
        case .invalidTimeLimit:
            // Reachable only from a caller bug, so there is nothing useful to
            // tell the holder. Reuses an existing catalog entry rather than
            // adding a key to a string catalog this change does not own.
            return NSLocalizedString("The document could not be signed on this device.", comment: "")
        }
    }
}

// MARK: - Client

struct TWFidOClient {

    let configuration: TWFidOConfiguration
    private let credentialProvider: SPCredentialProviding

    /// Internal rather than private so a test can assert what a
    /// default-initialised client actually ended up talking through.
    let session: URLSession

    init(configuration: TWFidOConfiguration,
         credentials: SPCredentialProviding,
         session: URLSession = TWFidOClient.privateSession) {
        self.configuration = configuration
        self.credentialProvider = credentials
        self.session = session
    }

    /// The transport this client uses unless a caller supplies one.
    ///
    /// **Not `URLSession.shared`.** An ATH-02 response body carries `cert` — the
    /// holder's X.509 certificate, the disclosure the whole ZK route exists to
    /// avoid — and `hashed_id_num`, a stable per-person correlator. The shared
    /// session uses the shared `URLCache`, which is backed by a file inside the
    /// app container; a response the server happens to mark cacheable would be
    /// written to disk and outlive the flow that fetched it, where a device
    /// backup or a file-level compromise picks it up. An ephemeral configuration
    /// keeps cache, cookies and credentials in memory only, and clearing
    /// `urlCache` removes even that.
    ///
    /// One shared instance rather than one per client: a `URLSession` per caller
    /// leaks connection pools, and nothing in this configuration varies.
    static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        // Belt and braces for a session that has no cache to read from anyway;
        // it also means the policy is right if this configuration is ever
        // copied somewhere that does.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// What the spec allows for `time_limit`.
    static let allowedTimeLimits: ClosedRange<Int> = 30...600

    // MARK: Push (ATH-03)

    /// Asks 內政部 to push a signing prompt to the holder's bound device(s).
    func requestSignPush(_ request: TWFidOSignRequest) async throws -> TWFidOTicket {
        try Self.validate(request)
        let sp = try await credentialProvider.credentials()
        let transactionID = Self.newTransactionID()
        let signData = Self.signData(for: request.signing)

        let payload: String
        if let alias = request.deviceAlias {
            payload = SPChecksum.pushPayload(transactionID: transactionID,
                                             spServiceID: sp.serviceID,
                                             idNumber: request.idNumber,
                                             deviceAlias: alias,
                                             opCode: TWFidOWire.opCode,
                                             hint: request.hint,
                                             signData: signData)
        } else {
            payload = SPChecksum.pushPayload(transactionID: transactionID,
                                             spServiceID: sp.serviceID,
                                             idNumber: request.idNumber,
                                             opCode: TWFidOWire.opCode,
                                             hint: request.hint,
                                             signData: signData)
        }

        let body = SignRequestBody(
            transactionID: transactionID,
            spServiceID: sp.serviceID,
            spChecksum: try SPChecksum.compute(payload: payload,
                                               aesKeyBase64: sp.aesKeyBase64),
            idNumber: request.idNumber,
            opCode: TWFidOWire.opCode,
            // Push carries no op_mode at all — not even "PUSH". It is absent
            // from the checksum payload and absent from the body; adding it is
            // the difference between a prompt appearing on the holder's phone
            // and a rejection.
            opMode: nil,
            hint: request.hint,
            timeLimit: request.timeLimit,
            deviceUserDefDesc: request.deviceAlias,
            signInfo: SignInfo(signData: signData))

        return try await issueTicket(path: TWFidOWire.Path.push, body: body)
    }

    // MARK: App-to-app (ATH-01)

    /// Issues a ticket and the deep link that hands control to the
    /// 行動自然人憑證 app.
    ///
    /// `returnURL` must be a scheme this app has registered in
    /// `CFBundleURLTypes`, or the holder signs and never comes back.
    /// `request.deviceAlias` is ignored here.
    func requestSignAppToApp(_ request: TWFidOSignRequest,
                             returnURL: URL) async throws -> (ticket: TWFidOTicket, deepLink: URL) {
        try Self.validate(request)
        let sp = try await credentialProvider.credentials()
        let transactionID = Self.newTransactionID()
        let signData = Self.signData(for: request.signing)

        let payload = SPChecksum.appToAppPayload(transactionID: transactionID,
                                                 spServiceID: sp.serviceID,
                                                 idNumber: request.idNumber,
                                                 opCode: TWFidOWire.opCode,
                                                 opMode: TWFidOWire.appToAppOpMode,
                                                 hint: request.hint,
                                                 signData: signData)

        let body = SignRequestBody(
            transactionID: transactionID,
            spServiceID: sp.serviceID,
            spChecksum: try SPChecksum.compute(payload: payload,
                                               aesKeyBase64: sp.aesKeyBase64),
            idNumber: request.idNumber,
            opCode: TWFidOWire.opCode,
            opMode: TWFidOWire.appToAppOpMode,
            hint: request.hint,
            timeLimit: request.timeLimit,
            deviceUserDefDesc: nil,
            signInfo: SignInfo(signData: signData))

        let ticket = try await issueTicket(path: TWFidOWire.Path.appToApp, body: body)
        return (ticket, try Self.deepLink(ticket: ticket, returnURL: returnURL))
    }

    // MARK: Preconditions

    /// Everything that can be known to be wrong before the request is built.
    ///
    /// The ordering is the point: this runs before `credentials()` and before
    /// any body exists. A request body carries 身分證統一編號 in the clear, and
    /// the server's answer to an out-of-range `time_limit` is a rejection *after*
    /// it has already received the number. A caller bug must not be paid for
    /// with a disclosure, and the resulting error should name the actual
    /// problem instead of arriving as an opaque server code.
    private static func validate(_ request: TWFidOSignRequest) throws {
        guard allowedTimeLimits.contains(request.timeLimit) else {
            throw TWFidOError.invalidTimeLimit(request.timeLimit)
        }
    }

    // MARK: Result (ATH-02)

    /// One poll. Returns `nil` while the holder has not finished — the caller
    /// owns the retry cadence (the spec asks for at least 4 seconds between
    /// attempts) and, more importantly, owns the deadline. There is no timeout
    /// here on purpose: a client that loops forever outlives the ticket's own
    /// `time_limit` and leaves the UI wedged with nothing to cancel.
    func fetchResult(for ticket: TWFidOTicket) async throws -> TWFidOSignResult? {
        let sp = try await credentialProvider.credentials()
        let payload = SPChecksum.resultPayload(transactionID: ticket.transactionID,
                                               spServiceID: sp.serviceID,
                                               spTicketID: ticket.spTicketID)
        let body = ResultRequestBody(
            transactionID: ticket.transactionID,
            spServiceID: sp.serviceID,
            spChecksum: try SPChecksum.compute(payload: payload,
                                               aesKeyBase64: sp.aesKeyBase64),
            spTicketID: ticket.spTicketID)

        let envelope: APIEnvelope<SignResultPayload> = try await post(path: TWFidOWire.Path.result,
                                                                      body: body)

        guard envelope.errorCode == "0" else {
            if Self.isPending(errorCode: envelope.errorCode) { return nil }
            throw TWFidOError.server(code: envelope.errorCode, message: envelope.errorMessage)
        }

        guard let result = envelope.result else {
            throw TWFidOError.missingResultField("result")
        }

        // Authenticate the body before reading anything out of it.
        //
        // Nothing else in this response establishes where it came from. TLS says
        // we reached the host we dialled; it says nothing about the *content*
        // being a real MOICA outcome, and every intermediary that can put a body
        // in front of this method — a proxy, a debug rewrite, a stale mock left
        // in a build, a compromised base URL — gets believed without this check.
        // `idp_checksum` is the response-side counterpart of the `sp_checksum`
        // we send: derived from the SP AES key that only 內政部 and we hold, so
        // opening it is what turns "a JSON body arrived" into "內政部 said this".
        //
        // hashed_id_num degrades to empty when absent (below), so it is read
        // here in the same degraded form the server itself would have hashed —
        // the checksum is over what the server sent, not over what we wish it
        // had sent.
        guard let idpChecksum = result.idpChecksum, !idpChecksum.isEmpty else {
            // Kept distinct from a *failed* check: a deployment that never emits
            // the field is an operational problem worth naming, and a support
            // report should not have to guess which of the two happened.
            throw TWFidOError.missingResultField("idp_checksum")
        }
        try IDPChecksum.verify(
            idpChecksum,
            payload: IDPChecksum.payload(transactionID: ticket.transactionID,
                                         errorCode: envelope.errorCode,
                                         hashedIDNumber: result.hashedIDNum ?? "",
                                         signedResponse: result.signedResponse ?? ""),
            aesKeyBase64: sp.aesKeyBase64)

        guard let cert = result.cert, !cert.isEmpty else {
            throw TWFidOError.missingResultField("cert")
        }
        guard let signedResponse = result.signedResponse, !signedResponse.isEmpty else {
            throw TWFidOError.missingResultField("signed_response")
        }
        // hashed_id_num is documented but nothing downstream reads it. Failing
        // an otherwise complete signature over a field we ignore would be the
        // wrong trade, so it degrades to empty instead of throwing.
        return TWFidOSignResult(cert: cert,
                                signedResponse: signedResponse,
                                hashedIDNumber: result.hashedIDNum ?? "")
    }

    /// Terminal-vs-pending classification. The API sometimes prefixes the code
    /// with the operation ("SP-API-ATH-02-…") and sometimes appends a
    /// colon-separated explanation, so both forms are normalised before the
    /// lookup.
    static func isPending(errorCode: String) -> Bool {
        let head = errorCode
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        return TWFidOWire.pendingErrorCodes.contains(head)
    }

    // MARK: - Transport

    private func issueTicket<Body: Encodable>(path: String, body: Body) async throws -> TWFidOTicket {
        let envelope: APIEnvelope<SPTicketPayload> = try await post(path: path, body: body)
        guard envelope.errorCode == "0" else {
            throw TWFidOError.server(code: envelope.errorCode, message: envelope.errorMessage)
        }
        guard let spTicket = envelope.result?.spTicket, !spTicket.isEmpty else {
            throw TWFidOError.missingResultField("sp_ticket")
        }
        return try Self.parseTicket(spTicket)
    }

    private func post<Body: Encodable, Payload: Decodable>(path: String,
                                                           body: Body) async throws -> APIEnvelope<Payload> {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Set on the request as well as on `privateSession`, because a caller
        // may inject a session of its own and an ATH-02 body is not something
        // that should ever be served from, or written to, a cache. The
        // `…AndRemoteCacheData` variant is documented as unimplemented, so this
        // is the strongest policy that actually does anything.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(body)

        // Nothing about this request is logged. The body carries the national ID
        // in clear and the checksum that authenticates us; both would land in
        // the device console, which is readable off-device.
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TWFidOError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw TWFidOError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(APIEnvelope<Payload>.self, from: data)
        } catch {
            throw TWFidOError.invalidResponse
        }
    }

    // MARK: - Ticket

    /// `sp_ticket` is `base64url(payload) "." base64url(digest)`. Split on the
    /// **last** dot: the digest is a single trailing segment, but nothing
    /// promises the payload segment is dot-free.
    static func parseTicket(_ spTicket: String) throws -> TWFidOTicket {
        guard let separator = spTicket.lastIndex(of: ".") else {
            throw TWFidOError.malformedTicket("missing '.' separator")
        }
        let encodedPayload = String(spTicket[spTicket.startIndex..<separator])
        guard let payloadData = base64URLDecoded(encodedPayload) else {
            throw TWFidOError.malformedTicket("payload is not base64url")
        }
        guard let payload = try? JSONDecoder().decode(SPTicketClaims.self, from: payloadData) else {
            throw TWFidOError.malformedTicket("payload is not the expected JSON")
        }
        return TWFidOTicket(spTicket: spTicket,
                            transactionID: payload.transactionID,
                            spTicketID: payload.spTicketID)
    }

    // MARK: - Deep link

    /// `mobilemoica://moica.moi.gov.tw/a2a/verifySign?…`
    ///
    /// Built by hand rather than through `URLComponents.queryItems` because
    /// that percent-encodes `=` but leaves `+` and `/` raw. `rtn_url` is
    /// standard base64, so both can appear — and if the receiving side
    /// form-decodes, a `+` becomes a space, the base64 decode fails, and the
    /// holder signs successfully but never gets back to us. Silent, and only
    /// for return URLs whose base64 happens to contain those characters.
    static func deepLink(ticket: TWFidOTicket, returnURL: URL) throws -> URL {
        let returnURLBase64 = Data(returnURL.absoluteString.utf8).base64EncodedString()

        // rtn_val comes back to us untouched. Any app can register our URL
        // scheme, so the callback handler should check this against the ticket
        // it is expecting; the transaction ID is already inside sp_ticket in
        // this same URL, so using it here discloses nothing new.
        //
        // base64url, not the bare UUID. The parameter is defined as base64url
        // (and `scripts/twfido-sign.mjs` encodes it that way), and a raw UUID is
        // the worst possible violation of that: `-` is a legal base64url
        // character and a 36-character string is a legal length, so a receiver
        // decodes it without complaint into 27 meaningless bytes. What comes
        // back on the callback then never matches the transaction we are waiting
        // for, and the app-to-app return leg stalls with no error raised
        // anywhere — the holder signs, and nothing happens.
        let returnValue = base64URLEncodedString(Data(ticket.transactionID.utf8))

        let query = [
            "sp_ticket=" + percentEncoded(ticket.spTicket),
            "rtn_url=" + percentEncoded(returnURLBase64),
            "rtn_val=" + percentEncoded(returnValue),
        ].joined(separator: "&")

        var components = URLComponents()
        components.scheme = "mobilemoica"
        components.host = "moica.moi.gov.tw"
        components.path = "/a2a/verifySign"
        components.percentEncodedQuery = query

        guard let url = components.url else {
            throw TWFidOError.invalidReturnURL
        }
        return url
    }

    /// Unreserved characters only (RFC 3986 §2.3). Anything else is escaped,
    /// which is always valid and removes every question about how the receiver
    /// decodes the query.
    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Helpers

    private static func newTransactionID() -> String {
        UUID().uuidString
    }

    /// `sign_data` is the base64 of the TBS. `tbs_encoding: "base64"` refers to
    /// this wrapping only — what the card's key covers is
    /// `SHA-256(target.toBeSigned)`, so every consumer downstream (the circuit's
    /// `tbs`, `MOICASignedCredential`'s digest check) wants the string unwrapped.
    ///
    /// Internal rather than private so a test can pin the wrapping without
    /// reaching through a request body: getting this one step wrong produces a
    /// signature that is well-formed and verifies against nothing.
    static func signData(for target: TWFidOSigningTarget) -> String {
        Data(target.toBeSigned.utf8).base64EncodedString()
    }
}

// MARK: - Wire format

/// Values fixed by the SIGN flow. File scope because both `TWFidOClient` and
/// the request bodies need them, and a `private` member of the client would not
/// be visible to a sibling type even in the same file.
private enum TWFidOWire {

    /// SIGN, not ATH: we need the holder's RSA signature over `app_id`, not a
    /// bare authentication assertion.
    static let opCode = "SIGN"
    static let appToAppOpMode = "APP2APP"

    /// PKCS#1 produces the bare RSA signature the zkID circuit consumes. PKCS#7
    /// and CMS wrap it in a structure the circuit cannot parse, so this is a
    /// constraint, not a preference.
    static let signType = "PKCS#1"

    /// Describes how `sign_data` is wrapped, not what the holder signs.
    static let tbsEncoding = "base64"
    static let hashAlgorithm = "SHA256"

    enum Path {
        static let push = "moise/sp/requestAthOrSignPush"
        static let appToApp = "moise/sp/getSpTicket"
        static let result = "moise/sp/getAthOrSignResult"
    }

    /// `error_code` values that mean "the holder has not finished yet", not
    /// "this failed". `SPTKTID_TXNLOG_NF` appears when we poll before the
    /// server has written its transaction-log row — a race, not a failure, and
    /// treating it as terminal aborts flows that were about to succeed.
    static let pendingErrorCodes: Set<String> = [
        "20002",
        "20003",
        "SP-API-ATH-02-SPTKTID_TXNLOG_NF",
        "SPTKTID_TXNLOG_NF",
    ]
}

private struct SignInfo: Encodable {
    let signData: String
    let signType = TWFidOWire.signType
    let tbsEncoding = TWFidOWire.tbsEncoding
    let hashAlgorithm = TWFidOWire.hashAlgorithm

    enum CodingKeys: String, CodingKey {
        case signData = "sign_data"
        case signType = "sign_type"
        case tbsEncoding = "tbs_encoding"
        case hashAlgorithm = "hash_algorithm"
    }
}

private struct SignRequestBody: Encodable {
    let transactionID: String
    let spServiceID: String
    let spChecksum: String
    let idNumber: String
    let opCode: String
    /// Absent for push. Synthesised encoding omits nil optionals, which is
    /// exactly the required behaviour for this key and for
    /// `device_user_def_desc`.
    let opMode: String?
    let hint: String
    /// Integer, not a string. The spec's field table types `time_limit` as
    /// Integer and the official JAVA sample posts `formBody.put("time_limit",
    /// 600)`; quoting it was this client's own invention.
    let timeLimit: Int
    let deviceUserDefDesc: String?
    let signInfo: SignInfo

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case spServiceID = "sp_service_id"
        case spChecksum = "sp_checksum"
        case idNumber = "id_num"
        case opCode = "op_code"
        case opMode = "op_mode"
        case hint
        case timeLimit = "time_limit"
        case deviceUserDefDesc = "device_user_def_desc"
        case signInfo = "sign_info"
    }
}

private struct ResultRequestBody: Encodable {
    let transactionID: String
    let spServiceID: String
    let spChecksum: String
    let spTicketID: String

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case spServiceID = "sp_service_id"
        case spChecksum = "sp_checksum"
        case spTicketID = "sp_ticket_id"
    }
}

/// `{ error_code, error_message, result }`.
///
/// `error_code` is documented as a string but arrives as a bare number in some
/// deployments, so both are accepted rather than failing the whole response.
private struct APIEnvelope<Result: Decodable>: Decodable {
    let errorCode: String
    let errorMessage: String?
    let result: Result?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let code = try? container.decode(String.self, forKey: .errorCode) {
            errorCode = code
        } else if let code = try? container.decode(Int.self, forKey: .errorCode) {
            errorCode = String(code)
        } else {
            errorCode = ""
        }
        errorMessage = try? container.decode(String.self, forKey: .errorMessage)
        result = try? container.decode(Result.self, forKey: .result)
    }
}

private struct SPTicketPayload: Decodable {
    let spTicket: String

    enum CodingKeys: String, CodingKey {
        case spTicket = "sp_ticket"
    }
}

private struct SignResultPayload: Decodable {
    let hashedIDNum: String?
    let signedResponse: String?
    let cert: String?
    /// The response's own integrity/origin field. Optional at the decoding layer
    /// only so that a body missing it produces a named error instead of a
    /// decoding failure that reads as "malformed JSON".
    let idpChecksum: String?

    enum CodingKeys: String, CodingKey {
        case hashedIDNum = "hashed_id_num"
        case signedResponse = "signed_response"
        case cert
        case idpChecksum = "idp_checksum"
    }
}

/// The claims carried inside `sp_ticket`'s payload segment.
private struct SPTicketClaims: Decodable {
    let transactionID: String
    let spTicketID: String

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case spTicketID = "sp_ticket_id"
    }
}

// MARK: - idp_checksum

/// Verification of `idp_checksum`, the response-side counterpart of
/// `sp_checksum`.
///
/// It lives here rather than beside `SPChecksum`'s four request-side payload
/// builders only because that file is outside this change; the payload order
/// below belongs next to them and should move when that file is next touched.
private enum IDPChecksum {

    /// ATH-02: `transaction_id ‖ error_code ‖ hashed_id_num ‖ signed_response`.
    ///
    /// `cert` is *not* covered — the spec leaves the certificate outside the
    /// checksum. That is survivable rather than fine: `signed_response` is
    /// covered, and a signature only verifies under the public key of the
    /// certificate that actually produced it, which proof generation checks
    /// against the bundled MOICA G3 issuer. A substituted `cert` therefore fails
    /// later instead of never — but it does fail late, which is worth knowing
    /// when reading a proving error.
    static func payload(transactionID: String,
                        errorCode: String,
                        hashedIDNumber: String,
                        signedResponse: String) -> String {
        transactionID + errorCode + hashedIDNumber + signedResponse
    }

    /// `idp_checksum` is built exactly like `sp_checksum` and from the same key:
    /// `hex(IV ‖ AES-256-GCM(lowercase hex of SHA-256(payload)) ‖ tag)`.
    ///
    /// It is checked by *opening* the box rather than by recomputing and
    /// comparing strings — GCM is randomised, so two honest checksums over the
    /// same payload never match byte for byte. Two things then have to hold, and
    /// they catch different attacks:
    ///
    /// - the box opens under our SP AES key. Only 內政部 and this app can
    ///   produce one, which is the origin authentication;
    /// - the plaintext equals the digest of *this* response. Otherwise a
    ///   checksum lifted from an earlier genuine response — a different holder's
    ///   completed signature, say — would authenticate a swapped body.
    static func verify(_ checksum: String, payload: String, aesKeyBase64: String) throws {
        // Unreachable in practice: `fetchResult` computes an `sp_checksum` from
        // this same key before it posts, so a bad key has already thrown. Kept
        // so this stays correct if it is ever called on its own.
        guard let keyData = Data(base64Encoded: aesKeyBase64), keyData.count == 32 else {
            throw SPChecksumError.invalidAESKey
        }
        guard let combined = hexDecoded(checksum),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let opened = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else {
            throw TWFidOError.unauthenticatedResult
        }
        guard opened == Data(lowercaseHexString(SHA256.hash(data: Data(payload.utf8))).utf8) else {
            throw TWFidOError.unauthenticatedResult
        }
    }
}

// MARK: - Hex

private let hexDigits: [Character] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
]

/// Lowercase, no separators — the form the SP API's checksums are written in.
///
/// A file-scope function rather than an extension on `Data`, for the same reason
/// `SPChecksum` keeps its own: a shared extension becomes an invalid
/// redeclaration the moment a second module in this app adds one.
private func lowercaseHexString<Bytes: Sequence>(_ bytes: Bytes) -> String
where Bytes.Element == UInt8 {
    var out = String()
    out.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0x0F)])
    }
    return out
}

/// Strict on purpose: an odd length or anything outside ASCII hex returns nil
/// rather than a best-effort prefix. The caller decides whether a response is
/// authentic from this, so "decoded most of it" must not read as success.
/// `UInt8(_:radix:)` alone would accept a leading `+`, which is why the alphabet
/// is checked first.
private func hexDecoded(_ string: String) -> Data? {
    guard string.count % 2 == 0,
          string.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
        return nil
    }
    var data = Data(capacity: string.count / 2)
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

// MARK: - base64url

/// Unpadded base64url, which is what the deep link's `rtn_val` is defined as and
/// what `scripts/twfido-sign.mjs` produces with `Buffer.toString("base64url")`.
private func base64URLEncodedString(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// base64url, padding optional — the ticket's payload segment carries none.
///
/// A free function rather than an initialiser on `Data` so it cannot become an
/// invalid redeclaration when another module in this app adds its own base64url
/// helper.
private func base64URLDecoded(_ string: String) -> Data? {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64)
}
