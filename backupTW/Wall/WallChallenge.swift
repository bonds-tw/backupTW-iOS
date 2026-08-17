//
//  WallChallenge.swift
//  backupTW
//
//  A number the wall issued, and how long it is still worth using.
//

import Foundation

/// A challenge fetched from the wall, with the clock that decides whether it is
/// still worth spending a proof on.
struct WallChallenge: Equatable, Sendable {

    /// Sent back **byte for byte**. This app never takes it apart.
    ///
    /// The token is `<nonce>.<expiry>.<mac>` and the wall recomputes everything
    /// it needs from the nonce it signed. A client that split it and sent the
    /// pieces would be inviting the wall to compare the client's number against
    /// the client's number — which is the shape that looks like it saves a
    /// parse and checks nothing.
    let token: String

    /// Always `.fromVerifier`, and only this initialiser can decide that.
    ///
    /// The distinction is the whole reason `ProofChallenge` is an enum: a proof
    /// built on a self-minted number carries
    /// `ProofCaveat.challengeNotBoundToVerifier` for ever afterwards. Signing
    /// the wall is the first flow in this app where the challenge genuinely
    /// comes from the party doing the checking, so it is the first flow that
    /// can honestly drop that caveat — and the honesty of that depends entirely
    /// on this value not being constructible any other way.
    let proofChallenge: ProofChallenge

    /// How long the token had left when it arrived.
    let ttlAtIssue: TimeInterval

    /// When it arrived, on a clock that cannot be moved.
    ///
    /// # Why not `Date`
    ///
    /// The expiry inside the token is wall-clock milliseconds, and comparing it
    /// against `Date()` compares the wall's clock with the phone's. Those
    /// disagree routinely — this app already ships two screens' worth of copy
    /// about exactly that (`presentationDatedInTheFuture`) — and here the
    /// disagreement is expensive in one specific direction: a phone running
    /// slow believes a dead challenge is alive, spends a 身分證統一編號
    /// disclosure and several seconds of proving on it, and is refused.
    ///
    /// `ContinuousClock` measures elapsed time and keeps counting while the
    /// device sleeps. It cannot be set, so nothing the user or the network does
    /// to the calendar moves it.
    let anchor: ContinuousClock.Instant

    /// Below this, do not start: proving takes seconds and the person is about
    /// to be asked for their ID number.
    static let minimumUsableToStart: TimeInterval = 900

    /// Below this, do not submit. A proof arriving with a nearly-dead challenge
    /// is refused after the cost has already been paid.
    static let minimumUsableToSubmit: TimeInterval = 300

    /// Seconds left, from the monotonic clock only.
    func secondsRemaining(now: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = TimeInterval((now - anchor).components.seconds)
        return max(0, ttlAtIssue - elapsed)
    }

    func isWorthStarting(now: ContinuousClock.Instant) -> Bool {
        secondsRemaining(now: now) >= Self.minimumUsableToStart
    }

    func isWorthSubmitting(now: ContinuousClock.Instant) -> Bool {
        secondsRemaining(now: now) >= Self.minimumUsableToSubmit
    }
}

/// Reads the wall's challenge response.
///
/// Separate from the networking so the parsing rules can be tested against
/// bytes, which is where every one of them is decided.
enum WallChallengeReader {

    enum Failure: Error, Equatable {
        case notJSON
        case missingToken
        case malformedToken
        case missingDecimal
        /// The wall's decimal and the token's nonce disagree.
        case decimalDoesNotMatchToken
        case alreadyExpired
    }

    /// The token's shape, as the Worker emits it: 48 lowercase hex, a
    /// millisecond expiry, 64 lowercase hex of HMAC.
    private static func parts(of token: String) -> (nonce: String, expiry: Int)? {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let nonce = String(pieces[0]), expiry = String(pieces[1]), mac = String(pieces[2])
        guard nonce.count == 48, nonce.allSatisfy(\.isHexDigitLowercase),
              mac.count == 64, mac.allSatisfy(\.isHexDigitLowercase),
              let milliseconds = Int(expiry), milliseconds > 0 else { return nil }
        return (nonce, milliseconds)
    }

    /// # The decimal is checked, not trusted
    ///
    /// The wall sends `decimal` so this app does not have to reimplement
    /// big-endian-hex-to-decimal and disagree about it. But taking it on trust
    /// would mean the number entering the circuit came from the response body
    /// rather than from the token — so a tampered response could put one value
    /// in the proof while the wall verified against another, and the failure
    /// would look like a broken card.
    ///
    /// So it is recomputed here and compared. Cheap, and it turns a whole class
    /// of confusing failure into one named branch.
    static func read(_ body: Data,
                     receivedAt: ContinuousClock.Instant,
                     serverDate: Date?) -> Result<WallChallenge, Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(.notJSON)
        }
        guard let token = object["token"] as? String ?? object["challenge"] as? String else {
            return .failure(.missingToken)
        }
        guard let (nonce, expiryMilliseconds) = parts(of: token) else {
            return .failure(.malformedToken)
        }
        guard let decimal = object["decimal"] as? String else {
            return .failure(.missingDecimal)
        }
        guard decimal == Self.decimal(fromHex: nonce) else {
            return .failure(.decimalDoesNotMatchToken)
        }

        // The only place a wall-clock date is read, and it is the **server's**,
        // taken from the `Date` header rather than from this device. Without a
        // header there is nothing to anchor against, so the full TTL is assumed
        // — erring towards a shorter usable life is not possible here, and
        // erring towards a longer one is caught by the wall refusing.
        let now = serverDate ?? Date(timeIntervalSince1970: TimeInterval(expiryMilliseconds) / 1000 - 1800)
        let ttl = TimeInterval(expiryMilliseconds) / 1000 - now.timeIntervalSince1970
        guard ttl > 0 else { return .failure(.alreadyExpired) }

        return .success(WallChallenge(
            token: token,
            proofChallenge: .fromVerifier(Self.base64URL(fromHex: nonce)),
            ttlAtIssue: ttl,
            anchor: receivedAt))
    }

    /// Big-endian hex to decimal, without a bignum library.
    static func decimal(fromHex hex: String) -> String {
        var digits: [UInt8] = [0]
        for character in hex {
            guard let value = character.hexDigitValue else { return "" }
            var carry = value
            for index in digits.indices {
                let product = Int(digits[index]) * 16 + carry
                digits[index] = UInt8(product % 10)
                carry = product / 10
            }
            while carry > 0 {
                digits.append(UInt8(carry % 10))
                carry /= 10
            }
        }
        return String(digits.reversed().map { Character(String($0)) })
    }

    /// The circuit takes the challenge as base64url of the raw bytes, which is
    /// what `ProofChallenge` carries everywhere else in this app.
    static func base64URL(fromHex hex: String) -> String {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, hex.index(after: index) < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return VerifiableCredential.base64URLEncoded(Data(bytes))
    }
}

private extension Character {
    /// Lowercase only, because that is what the Worker emits.
    ///
    /// Accepting uppercase would not break the arithmetic — `hexDigitValue`
    /// handles both. It would mean this app quietly accepts a token no Worker of
    /// ours ever wrote, and a client that shrugs at a message from the wrong
    /// author is a client with one fewer thing it can notice.
    var isHexDigitLowercase: Bool { isHexDigit && !isUppercase }
}
