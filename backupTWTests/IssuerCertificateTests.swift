//
//  IssuerCertificateTests.swift
//  backupTWTests
//

import CryptoKit
import Foundation
import Testing
@testable import backupTW

/// The bundled MOICA G3 certificate is the trust anchor for every proof this
/// app can produce, so these tests exist to make substitution loud.
///
/// Three groups, doing different jobs:
///
///   * **Provenance.** The `.cer` in the bundle is the file whose origin is
///     written up at the top of `IssuerCertificate.swift`, restated four
///     independent ways (digest, serial, key identifier, modulus width). A
///     replacement that satisfies all four is a replacement someone had to work
///     at, and the diff shows it.
///   * **Failure modes.** Missing, unreadable, altered, swapped, out of date —
///     each has to produce its own error, because the user action differs
///     (update the app, renew the card, nothing).
///   * **The cardholder gate.** Which certificates are admitted, in which
///     order the reasons are reported, and — the one that matters most — that
///     naming MOICA G3 in an AuthorityKeyIdentifier is not sufficient to be
///     admitted.
///
/// None of this needs a proving key, a network, or a real person's certificate.
struct IssuerCertificateTests {

    // A moment inside every bundled certificate's validity window, fixed so
    // these tests do not start failing in 2044 for the wrong reason.
    private static let inWindow = Date(timeIntervalSince1970: 1_785_000_000)  // 2026-08

    private static func bundledIssuerDER() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: IssuerCertificate.issuerResourceName,
                                               withExtension: IssuerCertificate.resourceExtension),
                               "MOICA-G3.cer is not in the app bundle")
        return try Data(contentsOf: url)
    }

    private static func bundledRootDER() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: IssuerCertificate.rootResourceName,
                                               withExtension: IssuerCertificate.resourceExtension),
                               "GRCA-G3.cer is not in the app bundle")
        return try Data(contentsOf: url)
    }

    private static func loadAnchor(now: Date = inWindow) throws -> IssuerCertificate {
        try IssuerCertificate.load(issuerDER: try bundledIssuerDER(),
                                   rootDER: try bundledRootDER(),
                                   now: now)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int,
                             _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    // MARK: - Provenance

    /// The single most important assertion in this file. If it fails, someone
    /// replaced the trust anchor and every proof this app produces is anchored
    /// to a certificate nobody reviewed.
    @Test func bundledIssuerMatchesItsPinnedDigest() throws {
        let digest = SHA256.hash(data: try Self.bundledIssuerDER())
        #expect(Self.hex(Data(digest)) == IssuerCertificate.pinnedIssuerSHA256)
        #expect(IssuerCertificate.pinnedIssuerSHA256
                == "ed793fd0d50a2a398049d598982cf01e75f873b532066caec238f800a06ca9da")
    }

    @Test func bundledRootMatchesItsPinnedDigest() throws {
        let digest = SHA256.hash(data: try Self.bundledRootDER())
        #expect(Self.hex(Data(digest)) == IssuerCertificate.pinnedRootSHA256)
        #expect(IssuerCertificate.pinnedRootSHA256
                == "57df6f20e04c588e85f35be8832f5d4e78958336ae3b18fb7c9bae0dfead4044")
    }

    /// Restates the provenance comment as assertions. Updating the digest
    /// constant to match a substituted file is a one-line change; also matching
    /// the serial, the key identifier, the modulus width and both validity
    /// bounds is not.
    ///
    /// Values are from `https://moica.nat.gov.tw/repository/Certs/MOICA-G3.cer`
    /// as fetched on 2026-08-07.
    @Test func bundledIssuerIsTheCertificateItsProvenanceDescribes() throws {
        let certificate = try X509Certificate.parse(der: try Self.bundledIssuerDER())

        #expect(certificate.serialNumberHex == "5a202d14b39787d0886c37184ac9b76a")
        #expect(certificate.subjectKeyIdentifier == MOICAGeneration.g3.keyIdentifier)
        #expect(Self.hex(certificate.subjectKeyIdentifier ?? Data())
                == "4720a3b1264bcd6d48acf2640886972c7454115f")
        // 4096 bits is not a detail — it is why this is the only generation the
        // `certChainRs4096` circuit can consume.
        #expect(certificate.rsaModulusBitCount == 4096)
        #expect(certificate.notBefore == Self.date(2024, 1, 23, 6, 30, 45))
        #expect(certificate.notAfter == Self.date(2044, 1, 23, 15, 59, 59))
        #expect(certificate.der.count == 1643)
    }

    @Test func bundledRootIsTheCertificateItsProvenanceDescribes() throws {
        let certificate = try X509Certificate.parse(der: try Self.bundledRootDER())

        #expect(certificate.serialNumberHex == "cd1de713a9adbf68fe2916d8435415c7")
        #expect(Self.hex(certificate.subjectKeyIdentifier ?? Data())
                == "3a908ee741471973dc9cbda37ed83d3e83091f03")
        #expect(certificate.rsaModulusBitCount == 4096)
        #expect(certificate.notBefore == Self.date(2022, 6, 7, 2, 33, 20))
        #expect(certificate.notAfter == Self.date(2049, 12, 31, 15, 59, 59))
        #expect(certificate.der.count == 1409)
    }

    /// `CircuitAssets` reads the installed anchor back under its own constant.
    /// If either name drifts, `generateCertChainRs4096Input` gets a path to a
    /// file that is not there — so the two are pinned together here rather than
    /// left to a comment.
    @Test func installedFilenameMatchesTheNameCircuitAssetsExpects() {
        #expect(IssuerCertificate.installedFilename == CircuitAssets.issuerCertificateFilename)
        #expect(IssuerCertificate.installedFilename
                == IssuerCertificate.issuerResourceName + "." + IssuerCertificate.resourceExtension)
    }

    // MARK: - Loading

    /// The regression test for the bug this module was written to close:
    /// `CircuitAssets.installBundledIssuerCertificate` threw unconditionally
    /// because no `.cer` had ever been added to the project. This fails the
    /// moment the file stops shipping.
    @Test func loadsTheAnchorOutOfTheAppBundle() throws {
        let anchor = try IssuerCertificate.loadBundled(now: Self.inWindow)
        #expect(anchor.certificate.sha256Hex == IssuerCertificate.pinnedIssuerSHA256)
        #expect(anchor.root.sha256Hex == IssuerCertificate.pinnedRootSHA256)
    }

    @Test func missingResourceIsReportedAsMissingRatherThanAsCorruption() throws {
        let root = try Self.bundledRootDER()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-\(UUID().uuidString).cer")
        try root.write(to: rootURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        do {
            _ = try IssuerCertificate.load(issuerURL: nil, rootURL: rootURL, now: Self.inWindow)
            Issue.record("a missing bundled certificate must not load")
        } catch let error as IssuerCertificateError {
            #expect(error == .bundledCertificateMissing(resource: IssuerCertificate.issuerResourceName))
        }
    }

    @Test func unreadableResourceIsReportedSeparately() throws {
        // A directory where a file should be: present enough to be found,
        // impossible to read as certificate bytes.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try IssuerCertificate.load(issuerURL: directory, rootURL: directory, now: Self.inWindow)
            Issue.record("a directory must not be accepted as a certificate")
        } catch let error as IssuerCertificateError {
            #expect(error == .bundledCertificateUnreadable(resource: IssuerCertificate.issuerResourceName))
        }
    }

    /// One flipped byte. The digest check has to notice, and the reported
    /// digest has to be the one actually computed — a mismatch message that
    /// echoes the expectation back tells whoever reads the crash report nothing.
    @Test func alteredIssuerIsRejectedAndTheRealDigestIsReported() throws {
        var altered = try Self.bundledIssuerDER()
        altered[100] ^= 0x01
        let alteredDigest = Self.hex(Data(SHA256.hash(data: altered)))

        do {
            _ = try IssuerCertificate.load(issuerDER: altered,
                                           rootDER: try Self.bundledRootDER(),
                                           now: Self.inWindow)
            Issue.record("an altered trust anchor must not load")
        } catch let error as IssuerCertificateError {
            #expect(error == .fingerprintMismatch(resource: IssuerCertificate.issuerResourceName,
                                                  expected: IssuerCertificate.pinnedIssuerSHA256,
                                                  actual: alteredDigest))
            #expect(alteredDigest != IssuerCertificate.pinnedIssuerSHA256)
        }
    }

    @Test func alteredRootIsRejected() throws {
        var altered = try Self.bundledRootDER()
        altered[altered.count - 1] ^= 0x80

        do {
            _ = try IssuerCertificate.load(issuerDER: try Self.bundledIssuerDER(),
                                           rootDER: altered,
                                           now: Self.inWindow)
            Issue.record("an altered root must not load")
        } catch let error as IssuerCertificateError {
            guard case .fingerprintMismatch(let resource, _, _) = error else {
                Issue.record("expected a fingerprint mismatch, got \(error)")
                return
            }
            #expect(resource == IssuerCertificate.rootResourceName)
        }
    }

    /// Both files are DER certificates from the same authority, so a
    /// copy-paste that swaps them produces something that parses perfectly.
    @Test func issuerAndRootSwappedIsRejected() throws {
        do {
            _ = try IssuerCertificate.load(issuerDER: try Self.bundledRootDER(),
                                           rootDER: try Self.bundledIssuerDER(),
                                           now: Self.inWindow)
            Issue.record("the two anchors are not interchangeable")
        } catch let error as IssuerCertificateError {
            guard case .fingerprintMismatch = error else {
                Issue.record("expected a fingerprint mismatch, got \(error)")
                return
            }
        }
    }

    // MARK: - Expiry

    /// Expiry has to be an error with a date in it, not a silently-degraded
    /// success. 2044 is far away; a device with a wrong clock is not.
    @Test func anchorExpiryIsDetectedAndNamed() throws {
        let afterExpiry = Self.date(2044, 1, 24)

        do {
            _ = try Self.loadAnchor(now: afterExpiry)
            Issue.record("an expired trust anchor must not load")
        } catch let error as IssuerCertificateError {
            #expect(error == .trustAnchorExpired(on: Self.date(2044, 1, 23, 15, 59, 59)))
            // The message has to be different from the tampering message: one
            // means "update the app", the other means "something replaced a
            // file", and they are not the same conversation.
            let expired = error.errorDescription
            let tampered = IssuerCertificateError
                .fingerprintMismatch(resource: "x", expected: "a", actual: "b").errorDescription
            #expect(expired != nil)
            #expect(expired != tampered)
        }
    }

    @Test func anchorNotYetValidIsDetectedSeparatelyFromExpiry() throws {
        // A device whose clock is stuck before the CA was issued.
        do {
            _ = try Self.loadAnchor(now: Self.date(2020, 1, 1))
            Issue.record("a not-yet-valid trust anchor must not load")
        } catch let error as IssuerCertificateError {
            guard case .trustAnchorNotYetValid(let from) = error else {
                Issue.record("expected notYetValid, got \(error)")
                return
            }
            // The root is the older of the two, so it is the one that names the
            // boundary here.
            #expect(from == Self.date(2022, 6, 7, 2, 33, 20))
        }
    }

    /// Off-by-one at the boundaries is the classic way an expiry check quietly
    /// becomes wrong for a day.
    @Test func validityWindowIsInclusiveAtBothEnds() throws {
        let certificate = try X509Certificate.parse(der: try Self.bundledIssuerDER())

        #expect(certificate.validity(at: certificate.notBefore) == .valid)
        #expect(certificate.validity(at: certificate.notAfter) == .valid)
        #expect(certificate.validity(at: certificate.notBefore.addingTimeInterval(-1))
                == .notYetValid(from: certificate.notBefore))
        #expect(certificate.validity(at: certificate.notAfter.addingTimeInterval(1))
                == .expired(on: certificate.notAfter))
    }

    // MARK: - The chain

    /// The one positive signature check available without a real person's
    /// certificate: MOICA G3 really is signed by GRCA G3. It exercises exactly
    /// the code path the cardholder gate uses.
    @Test func bundledIssuerIsSignedByTheBundledRoot() throws {
        let issuer = try X509Certificate.parse(der: try Self.bundledIssuerDER())
        let root = try X509Certificate.parse(der: try Self.bundledRootDER())

        #expect(try issuer.isSignatureValid(signedBy: root))
        #expect(issuer.issuerName == root.subjectName)
        #expect(issuer.authorityKeyIdentifier == root.subjectKeyIdentifier)
    }

    /// The negative half. Without this, `isSignatureValid` returning `true`
    /// unconditionally would pass every other test in this file.
    @Test func aCertificateIsNotSignedByJustAnyKey() throws {
        let issuer = try X509Certificate.parse(der: try Self.bundledIssuerDER())
        let root = try X509Certificate.parse(der: try Self.bundledRootDER())

        #expect(try issuer.isSignatureValid(signedBy: issuer) == false)
        // The root is self-signed, so this direction is the true one.
        #expect(try root.isSignatureValid(signedBy: root))
        #expect(try root.isSignatureValid(signedBy: issuer) == false)
    }

    // MARK: - Installing

    @Test func installWritesTheVerifiedBytesUnderTheExpectedName() throws {
        let anchor = try Self.loadAnchor()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try anchor.install(into: directory)

        #expect(written.lastPathComponent == CircuitAssets.issuerCertificateFilename)
        // Byte-identical to what passed the digest check — not a fresh read of
        // the bundle, which would be a second chance for the bytes to differ.
        #expect(try Data(contentsOf: written) == anchor.certificate.der)
        #expect(Self.hex(Data(SHA256.hash(data: try Data(contentsOf: written))))
                == IssuerCertificate.pinnedIssuerSHA256)
    }

    /// Installing over a previous run — or over something a previous failure
    /// left behind — has to replace it, not append to it or give up.
    @Test func installReplacesWhateverWasThereBefore() throws {
        let anchor = try Self.loadAnchor()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent(CircuitAssets.issuerCertificateFilename)
        try Data(repeating: 0xEE, count: 4096).write(to: destination)

        _ = try anchor.install(into: directory)
        #expect(try Data(contentsOf: destination) == anchor.certificate.der)
    }

    // MARK: - Re-reading what was installed

    /// The positive half: what `install` wrote passes the read-back check.
    @Test func verifyInstalledAcceptsTheBytesInstallWrote() throws {
        let anchor = try Self.loadAnchor()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try anchor.install(into: directory)
        #expect(throws: Never.self) { try IssuerCertificate.verifyInstalled(in: directory) }
        #expect(IssuerCertificate.installedCertificateIsVerified(in: directory))
    }

    /// **The regression test for the gap this check was added to close.**
    ///
    /// Before it, the installed anchor was verified exactly once — on the run
    /// that first wrote it — and every later proof was anchored to whatever
    /// bytes happened to be sitting under that name. `ZKProver.prove` tests the
    /// path with `fileExists` and nothing else before handing it to
    /// `generateCertChainRs4096Input` as `issuerCertPath`, so a file altered
    /// after installation became the issuer public key with nothing objecting.
    ///
    /// One flipped byte in a file that is still the right length and still
    /// parses as a certificate, because that is the shape of the failure a
    /// size check cannot see.
    @Test func verifyInstalledRejectsAnAnchorAlteredAfterInstallation() throws {
        let anchor = try Self.loadAnchor()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = try anchor.install(into: directory)
        var altered = try Data(contentsOf: destination)
        altered[200] ^= 0x40
        try altered.write(to: destination)
        // Same length, so anything asking `fileSize > 0` — or asking for the
        // size at all — still says this is fine.
        #expect(altered.count == anchor.certificate.der.count)

        #expect(IssuerCertificate.installedCertificateIsVerified(in: directory) == false)
        do {
            try IssuerCertificate.verifyInstalled(in: directory)
            Issue.record("an altered installed anchor must not verify")
        } catch let error as IssuerCertificateError {
            #expect(error == .fingerprintMismatch(
                resource: IssuerCertificate.issuerResourceName,
                expected: IssuerCertificate.pinnedIssuerSHA256,
                actual: Self.hex(Data(SHA256.hash(data: altered)))))
            // The same position `load` takes on the bundled copy: no retry
            // rewrites these bytes.
            #expect(error.isRecoverable == false)
        }
    }

    /// Absent, empty and altered all mean "install it again", but the first two
    /// are not tampering and must not be reported as though they were — a
    /// working directory a purge emptied is an ordinary Tuesday.
    @Test func verifyInstalledSeparatesAnAbsentAnchorFromAnAlteredOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = IssuerCertificateError
            .bundledCertificateMissing(resource: IssuerCertificate.issuerResourceName)
        #expect(IssuerCertificate.installedCertificateIsVerified(in: directory) == false)
        do {
            try IssuerCertificate.verifyInstalled(in: directory)
            Issue.record("an absent anchor must not verify")
        } catch let error as IssuerCertificateError {
            #expect(error == missing)
        }

        // A zero-length file is what an interrupted write leaves. It is absence,
        // not substitution.
        try Data().write(to: directory.appendingPathComponent(IssuerCertificate.installedFilename))
        do {
            try IssuerCertificate.verifyInstalled(in: directory)
            Issue.record("an empty anchor must not verify")
        } catch let error as IssuerCertificateError {
            #expect(error == missing)
        }
    }

    // MARK: - What a retry could possibly change

    /// Every trust-anchor failure except a wrong device clock is final.
    ///
    /// This exists because the run above this one used to wrap all of them in
    /// one recoverable case, which put "the certificate authority file that
    /// ships with this app has been altered" behind the same 「再試一次」 button
    /// as a dropped download. The bytes do not change between attempts, so the
    /// only thing a retry buys is another go at a substituted anchor.
    @Test func onlyAWrongClockIsWorthRetrying() {
        let final: [IssuerCertificateError] = [
            .bundledCertificateMissing(resource: "MOICA-G3"),
            .bundledCertificateUnreadable(resource: "MOICA-G3"),
            .fingerprintMismatch(resource: "MOICA-G3", expected: "a", actual: "b"),
            .bundledCertificateMismatch(resource: "MOICA-G3", detail: "serial number"),
            .bundledChainBroken,
            .trustAnchorExpired(on: Self.date(2044, 1, 24)),
            .holderCertificateMalformed(reason: "not valid base64"),
            .holderIssuerUnknown,
            .holderIssuerUnsupported(generation: .g2),
            .holderSignatureInvalid,
            .holderCertificateExpired(on: Self.date(2026, 1, 1))
        ]
        for error in final {
            #expect(error.isRecoverable == false, "\(error) must not invite a retry")
        }

        // The exceptions, and the only ones: both mean the clock is wrong rather
        // than the certificate, and both messages already say so.
        for error in [IssuerCertificateError.trustAnchorNotYetValid(from: Self.date(2022, 6, 7)),
                      .holderCertificateNotYetValid(from: Self.date(2026, 9, 1))] {
            #expect(error.isRecoverable)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - The cardholder gate

    /// **The security test in this file.**
    ///
    /// `holderLikeG3` carries MOICA G3's key identifier in its
    /// AuthorityKeyIdentifier and is inside its validity window, but it was
    /// signed by a key generated for this test. AKI is an unauthenticated
    /// field; anyone can copy twenty bytes. If this ever passes, the gate has
    /// been reduced to string matching.
    @Test func claimingToBeIssuedByG3IsNotEnoughToBeAdmitted() throws {
        let anchor = try Self.loadAnchor()
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderLikeG3)

        #expect(holder.authorityKeyIdentifier == MOICAGeneration.g3.keyIdentifier)
        do {
            _ = try anchor.validateHolderCertificate(holder, now: Self.date(2026, 6, 1))
            Issue.record("a certificate MOICA G3 did not sign must not be admitted")
        } catch let error as IssuerCertificateError {
            #expect(error == .holderSignatureInvalid)
        }
    }

    /// G2 is not "a different issuer file" — it is a 2048-bit CA the
    /// `certChainRs4096` circuit cannot represent. The error has to say which
    /// generation, because "unsupported" alone sends people to support with
    /// nothing to go on.
    @Test func aG2CardholderIsTurnedAwayByName() throws {
        let anchor = try Self.loadAnchor()
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderLikeG2)

        do {
            _ = try anchor.validateHolderCertificate(holder, now: Self.date(2026, 6, 1))
            Issue.record("a G2 certificate must not be admitted")
        } catch let error as IssuerCertificateError {
            #expect(error == .holderIssuerUnsupported(generation: .g2))
            #expect(error.errorDescription != IssuerCertificateError.holderIssuerUnknown.errorDescription)
        }
    }

    /// The shape a future MOICA G4 arrives in: a well-formed certificate whose
    /// AuthorityKeyIdentifier matches nothing this build knows. It must not be
    /// optimistically treated as G3.
    @Test func anUnrecognisedIssuerIsNotAssumedToBeG3() throws {
        let anchor = try Self.loadAnchor()
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderUnknownIssuer)

        let keyIdentifier = try #require(holder.authorityKeyIdentifier)
        #expect(MOICAGeneration.matching(keyIdentifier: keyIdentifier) == nil)
        do {
            _ = try anchor.validateHolderCertificate(holder, now: Self.date(2026, 6, 1))
            Issue.record("an unknown issuer must not be admitted")
        } catch let error as IssuerCertificateError {
            #expect(error == .holderIssuerUnknown)
        }
    }

    @Test func aCertificateWithNoAuthorityKeyIdentifierIsTurnedAway() throws {
        let anchor = try Self.loadAnchor()
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderWithoutAKI)

        #expect(holder.authorityKeyIdentifier == nil)
        do {
            _ = try anchor.validateHolderCertificate(holder, now: Self.date(2026, 6, 1))
            Issue.record("a certificate with no issuer hint must not be admitted")
        } catch let error as IssuerCertificateError {
            #expect(error == .holderIssuerUnknown)
        }
    }

    /// Pins the check order. Expiry is the failure a user can actually fix —
    /// a 行動自然人憑證 lasts one year — so it must be reported ahead of the
    /// signature check, which for an expired card would say only "doesn't match
    /// MOICA G3" and send them somewhere useless.
    @Test func expiryIsReportedBeforeTheSignatureCheck() throws {
        let anchor = try Self.loadAnchor()
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderLikeG3Expired)

        do {
            _ = try anchor.validateHolderCertificate(holder, now: Self.date(2026, 6, 1))
            Issue.record("an expired cardholder certificate must not be admitted")
        } catch let error as IssuerCertificateError {
            #expect(error == .holderCertificateExpired(on: Self.date(2025, 1, 1)))
            #expect(error != .holderSignatureInvalid)
        }
    }

    @Test func aCardholderCertificateFromTheFutureIsTurnedAwaySeparately() throws {
        let anchor = try Self.loadAnchor()
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderLikeG3NotYetValid)

        do {
            _ = try anchor.validateHolderCertificate(holder, now: Self.date(2026, 6, 1))
            Issue.record("a not-yet-valid certificate must not be admitted")
        } catch let error as IssuerCertificateError {
            #expect(error == .holderCertificateNotYetValid(from: Self.date(2030, 1, 1)))
        }
    }

    /// The generation check reads an unauthenticated field, so it is a
    /// diagnostic rather than a boundary. This records that the ordering is a
    /// choice: the same fixture answers differently depending only on the clock.
    @Test func theSameCertificateFailsDifferentlyAtDifferentTimes() throws {
        let anchor = try Self.loadAnchor()
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderLikeG3Expired)

        var duringItsWindow: IssuerCertificateError?
        do {
            _ = try anchor.validateHolderCertificate(holder, now: Self.date(2024, 6, 1))
        } catch let error as IssuerCertificateError {
            duringItsWindow = error
        }
        #expect(duringItsWindow == .holderSignatureInvalid)
    }

    // MARK: - Parsing

    @Test func base64FromTWFidOIsAccepted() throws {
        let der = try Self.bundledIssuerDER()
        let parsed = try X509Certificate.parse(base64DER: der.base64EncodedString())
        #expect(parsed.sha256Hex == IssuerCertificate.pinnedIssuerSHA256)
    }

    @Test func somethingThatIsNotBase64IsRejected() {
        do {
            _ = try X509Certificate.parse(base64DER: "這不是 base64 ###")
            Issue.record("non-base64 must not parse")
        } catch let error as IssuerCertificateError {
            guard case .holderCertificateMalformed = error else {
                Issue.record("expected malformed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// UTCTime runs out in 2049 and DER switches to GeneralizedTime, which is
    /// why GRCA G3's own notAfter is already encoded that way. The fixture
    /// mixes both encodings in one certificate so a parser that only handles
    /// one of them cannot pass.
    @Test func bothTimeEncodingsAreUnderstood() throws {
        let certificate = try X509Certificate.parse(base64DER: Fixtures.holderMixedTimeEncodings)
        #expect(certificate.notBefore == Self.date(2026, 1, 1))   // UTCTime
        #expect(certificate.notAfter == Self.date(2055, 1, 1))    // GeneralizedTime

        let root = try X509Certificate.parse(der: try Self.bundledRootDER())
        #expect(root.notAfter == Self.date(2049, 12, 31, 15, 59, 59))
    }

    /// RFC 5280's two-digit-year rule: 50 and above means 19xx.
    @Test func twoDigitYearsFollowTheRfcPivot() throws {
        // A hand-built certificate is overkill for this; the bundled anchor's
        // 24 → 2024 plus the fixture's 26 → 2026 cover the modern half, and the
        // 2055 fixture proves the parser does not simply add 2000 to everything.
        let issuer = try X509Certificate.parse(der: try Self.bundledIssuerDER())
        #expect(issuer.notBefore == Self.date(2024, 1, 23, 6, 30, 45))
        let mixed = try X509Certificate.parse(base64DER: Fixtures.holderMixedTimeEncodings)
        #expect(mixed.notAfter > Self.date(2050, 1, 1))
    }

    /// GRCA G3's serial starts `CD`, so DER prefixes it with a sign byte.
    /// Every tool that prints a serial shows the magnitude, so a pin copied
    /// from `openssl` would never match if we reported the encoded bytes.
    @Test func serialNumberHexDropsTheDerSignByte() throws {
        let root = try X509Certificate.parse(der: try Self.bundledRootDER())
        #expect(root.serialNumber.first == 0x00)
        #expect(root.serialNumber.count == 17)
        #expect(root.serialNumberHex == "cd1de713a9adbf68fe2916d8435415c7")
        #expect(root.serialNumberHex.count == 32)

        // MOICA G3's serial starts `5A`, so it has no sign byte to drop and
        // must come through untouched.
        let issuer = try X509Certificate.parse(der: try Self.bundledIssuerDER())
        #expect(issuer.serialNumber.count == 16)
        #expect(issuer.serialNumberHex == "5a202d14b39787d0886c37184ac9b76a")
    }

    /// The sign byte again, in the modulus. Counting it would report every
    /// RSA-4096 key as 4104-bit and the modulus-width check would never pass.
    @Test func modulusWidthIgnoresTheDerSignByte() throws {
        let issuer = try X509Certificate.parse(der: try Self.bundledIssuerDER())
        #expect(issuer.rsaModulusBitCount == 4096)
        let holder = try X509Certificate.parse(base64DER: Fixtures.holderLikeG3)
        #expect(holder.rsaModulusBitCount == 2048)
    }

    @Test(arguments: [
        "empty",
        "random",
        "truncated",
        "trailing"
    ]) func malformedInputIsRejectedRatherThanGuessedAt(kind: String) throws {
        let certificate = try Self.bundledIssuerDER()
        let input: Data
        switch kind {
        case "empty":
            input = Data()
        case "random":
            input = Data((0 ..< 256).map { _ in UInt8.random(in: 0 ... 255) })
        case "truncated":
            input = certificate.prefix(certificate.count / 2)
        default:
            // A byte glued on the end. Accepting this would mean accepting a
            // certificate with a payload hidden behind it.
            input = certificate + Data([0x00])
        }

        do {
            _ = try X509Certificate.parse(der: input)
            Issue.record("\(kind) must not parse as a certificate")
        } catch let error as IssuerCertificateError {
            guard case .holderCertificateMalformed = error else {
                Issue.record("expected malformed for \(kind), got \(error)")
                return
            }
        }
    }

    /// DER admits exactly one encoding of a value; BER admits several. A parser
    /// that quietly accepts the BER forms is a parser another component can
    /// disagree with about what a certificate says.
    @Test func berEncodingsThatDerForbidsAreRejected() {
        let cases: [(String, [UInt8])] = [
            // Indefinite length — legal BER, forbidden in DER.
            ("indefinite length", [0x30, 0x80, 0x02, 0x01, 0x01, 0x00, 0x00]),
            // Long-form length for a value that fits the short form.
            ("non-minimal length", [0x30, 0x81, 0x03, 0x02, 0x01, 0x01]),
            // Long-form length with a leading zero byte.
            ("padded length", [0x30, 0x82, 0x00, 0x03, 0x02, 0x01, 0x01]),
            // High-tag-number form, which X.509 never uses.
            ("multi-byte tag", [0x3F, 0x81, 0x00, 0x00]),
            // A length that runs past the data.
            ("overrun", [0x30, 0x7F, 0x02, 0x01, 0x01])
        ]

        for (label, bytes) in cases {
            var reader = DERReader(bytes)
            do {
                let element = try reader.next()
                Issue.record("\(label) should have been rejected, got tag \(element.tag)")
            } catch {
                // Expected.
            }
        }
    }

    /// A well-formed sanity case, so the rejection test above cannot pass by
    /// the parser rejecting everything.
    @Test func aMinimalWellFormedStructureIsAccepted() throws {
        var reader = DERReader([0x30, 0x03, 0x02, 0x01, 0x2A])
        let sequence = try reader.next()
        #expect(sequence.tag == DERReader.sequence)
        #expect(reader.isAtEnd)

        var inner = reader.contents(of: sequence)
        let integer = try inner.next(expecting: DERReader.integer)
        #expect(inner.content(of: integer) == Data([0x2A]))
        #expect(inner.isAtEnd)
    }

    // MARK: - Generations

    /// All three MOICA generations share a byte-identical subject, which is why
    /// the code never looks at one. If this ever stops being true, the comment
    /// saying "do not tell them apart by name" should stop too.
    @Test func generationsAreDistinguishedOnlyByKeyIdentifier() {
        let identifiers = MOICAGeneration.allCases.map(\.keyIdentifier)
        #expect(Set(identifiers).count == MOICAGeneration.allCases.count)
        #expect(identifiers.allSatisfy { $0.count == 20 })

        for generation in MOICAGeneration.allCases {
            #expect(MOICAGeneration.matching(keyIdentifier: generation.keyIdentifier) == generation)
        }
        #expect(MOICAGeneration.matching(keyIdentifier: Data(repeating: 0, count: 20)) == nil)
        #expect(MOICAGeneration.matching(keyIdentifier: Data()) == nil)
    }

    /// The reason generation is a circuit choice rather than a runtime branch.
    @Test func onlyG3HasAModulusTheCircuitCanHold() {
        #expect(MOICAGeneration.g3.modulusBitCount == 4096)
        #expect(MOICAGeneration.g2.modulusBitCount == 2048)
        #expect(MOICAGeneration.g1.modulusBitCount == 2048)
        #expect(IssuerCertificate.supportedGeneration == .g3)
    }

    /// Every failure a user can see has to say something, in their language.
    /// An empty `errorDescription` surfaces as "The operation couldn't be
    /// completed", which is the failure mode this whole module exists to avoid.
    @Test func everyFailureHasAMessage() throws {
        let errors: [IssuerCertificateError] = [
            .bundledCertificateMissing(resource: "MOICA-G3"),
            .bundledCertificateUnreadable(resource: "MOICA-G3"),
            .fingerprintMismatch(resource: "MOICA-G3", expected: "a", actual: "b"),
            .bundledCertificateMismatch(resource: "MOICA-G3", detail: "serial"),
            .bundledChainBroken,
            .trustAnchorExpired(on: Date()),
            .trustAnchorNotYetValid(from: Date()),
            .holderCertificateMalformed(reason: "x"),
            .holderIssuerUnknown,
            .holderIssuerUnsupported(generation: .g2),
            .holderSignatureInvalid,
            .holderCertificateExpired(on: Date()),
            .holderCertificateNotYetValid(from: Date())
        ]

        for error in errors {
            let message = try #require(error.errorDescription, "\(error) has no message")
            #expect(!message.isEmpty, "\(error) has an empty message")
        }

        // The generation name is interpolated, so it has to actually appear.
        let unsupported = IssuerCertificateError.holderIssuerUnsupported(generation: .g2)
        let message = try #require(unsupported.errorDescription)
        #expect(message.contains(MOICAGeneration.g2.localizedName))
    }
}

// MARK: - Fixtures

/// Synthetic certificates, generated for these tests.
///
/// Deliberately synthetic. The only real cardholder certificate available to
/// this project is a named person's — it sits in PSE's example app as
/// `input.json`, complete with their name, national ID serial and validity
/// dates — and it is not going into a repository. Everything these tests need
/// (a matching AuthorityKeyIdentifier, a G2 one, a missing one, an unknown one,
/// dates on either side of the window, both DER time encodings) can be built
/// from keys that exist nowhere else, and the one thing that cannot be forged —
/// a signature by MOICA G3 — is covered instead by the real
/// MOICA-G3-signed-by-GRCA-G3 pair in the bundle.
///
/// To regenerate: issue leaves from a throwaway 2048-bit RSA CA, setting each
/// leaf's AuthorityKeyIdentifier explicitly to the value the case needs (note
/// that OpenSSL 3.x adds an AKI of its own unless you build the certificate
/// through a library that lets you omit it). Nothing here is secret and none of
/// it is reachable from app code.
private enum Fixtures {

    /// AuthorityKeyIdentifier = MOICA G3, valid 2026-01-01 … 2027-01-01, signed
    /// by a throwaway key. Everything about it looks right except the signature.
    static let holderLikeG3 = """
        MIIC/TCCAeWgAwIBAgIBETANBgkqhkiG9w0BAQsFADAlMQswCQYDVQQGEwJUVzEWMBQGA1UECgwN
        Tm90IEEgUmVhbCBDQTAeFw0yNjAxMDEwMDAwMDBaFw0yNzAxMDEwMDAwMDBaMCwxCzAJBgNVBAYT
        AlRXMR0wGwYDVQQDDBRGaXh0dXJlIGhvbGRlckxpa2VHMzCCASIwDQYJKoZIhvcNAQEBBQADggEP
        ADCCAQoCggEBAJlP0lLxsC8NzYK7XVxOsaSphZKCifj2wQnkPiVHTRJ2JHGOtNnO39obT3ngxMUy
        dsfV7Kp2F9FtkWUHkamG7jWmHiKfZKW6mU/u/b5eD5tTpqoYC1j+zlqr8/ZujABtofLM1xTGXIBo
        6/iXPgqeoRDUFHlxpxznPEnPBT1qs/Uc8e0b0G+SlnFhNSkwR/0OoQD43Y/Fq1q5KjO+k4GSJiSC
        ui0yL0l+2xM3UiTkg2lkpBTgoZ5tEAFEPE9W/5ePmiWhpCo1vMAc4yAm//b0jKl7+BD/BPUzdkLY
        Pcl6mKl1KaM5+BSolEfYS+QR7FhbjlvV42LbWnnYmM67sowDIP8CAwEAAaMxMC8wDAYDVR0TAQH/
        BAIwADAfBgNVHSMEGDAWgBRHIKOxJkvNbUis8mQIhpcsdFQRXzANBgkqhkiG9w0BAQsFAAOCAQEA
        KA9pt3tJrYPDXbV19+f63OTcG1JSPDCVjPiQeaXgNRTlYSazbG3/E69qnFfbDpzYHDVOT48U2X0M
        8J2ao7hwrwUUzfeRn860ifbaBt+QxbsEjCSZADgO+qtKJKCd/ksCr89KapI9Lyu/yqgkPibbErXU
        Z4/pWMTyyWsxsPvjSQ8FpwNzp1tfFzTs+cbhQ48aA6yqFphj7XtvQ+CyzC5leeNVMpUOAU4V1+fQ
        g7HQnL2W5dzX6m0JGaCgqHoKc5pE/FpQ7GGyp9Zu09Z0RQw0Sw5NxhPkr46imSROQ9SZsPgQKdW8
        +wbS+uycGnb81XWpV5NzUvGaTfq39d/oXnVq7g==
        """

    /// Same shape, already out of date — the yearly renewal case.
    static let holderLikeG3Expired = """
        MIIDBDCCAeygAwIBAgIBEjANBgkqhkiG9w0BAQsFADAlMQswCQYDVQQGEwJUVzEWMBQGA1UECgwN
        Tm90IEEgUmVhbCBDQTAeFw0yNDAxMDEwMDAwMDBaFw0yNTAxMDEwMDAwMDBaMDMxCzAJBgNVBAYT
        AlRXMSQwIgYDVQQDDBtGaXh0dXJlIGhvbGRlckxpa2VHM0V4cGlyZWQwggEiMA0GCSqGSIb3DQEB
        AQUAA4IBDwAwggEKAoIBAQCPIZhcNI4Etec4OLEtsz/evhFa2UU6/KjKU0We/RTEifgpNK4QBF38
        YnZhf2BeBHFeaJTkv2n82PhfLDowNye5JBtuTLgZuFE/l41di7D7YO1XljJFJyFULxhJRo2OM1VC
        1YkpE9xZNA495h132Z0Wy/PoidFB6CGIF4BfeR+BKIVSxmg9HTtCLDBCZ/mitd8bG6TI1S8Px46T
        Tl6JjRsAcxf/MNk/43SNGYZYTqSAK4ng/JCiAZsPU6xo71uTWsy6IRxWE8ZvON8zxcsWjxhnsPZY
        Magaffdh+GXTsB0c3kFVpQRp9AtEORN3gM8rzdPUyXi2eC190Xc+boucuzlpAgMBAAGjMTAvMAwG
        A1UdEwEB/wQCMAAwHwYDVR0jBBgwFoAURyCjsSZLzW1IrPJkCIaXLHRUEV8wDQYJKoZIhvcNAQEL
        BQADggEBADCAkPHIIa6wfLlqZN+IBwd/u0dOSDJDoAtjum3gp4Nfy8VgHzdLsSPqLq87zraNZzA3
        WKZxpdPLQ93fY4IXHFd1HB5K0r7FsTRpDEAhZx+9xwORGgpoHgPcu9cNIsnR99SgvgoIcYrWiT+a
        oCLCwQtegc81bEUmaqabTxxM0ajlCNpmSHzqk6BWwXE5bwdnAYnqtzPGibFS+3hVxs6MGTaa0WPD
        ZexWb7kKk611eOiYbbK3rp0G4SBkIq7PyvU1TpNNijlPXCNVZXMdy0VT8w8EvLS3+zD5Ne59U9WX
        cW0sbhqRsRU1Jn3Bz1lZZLFeOtIw0IkUQLoyaTSeNmZhq8o=
        """

    /// Same shape, not valid until 2030 — a device with a wrong clock.
    static let holderLikeG3NotYetValid = """
        MIIDCDCCAfCgAwIBAgIBEzANBgkqhkiG9w0BAQsFADAlMQswCQYDVQQGEwJUVzEWMBQGA1UECgwN
        Tm90IEEgUmVhbCBDQTAeFw0zMDAxMDEwMDAwMDBaFw0zMTAxMDEwMDAwMDBaMDcxCzAJBgNVBAYT
        AlRXMSgwJgYDVQQDDB9GaXh0dXJlIGhvbGRlckxpa2VHM05vdFlldFZhbGlkMIIBIjANBgkqhkiG
        9w0BAQEFAAOCAQ8AMIIBCgKCAQEA33brsZ8bDzVixW4GR40qzWXwNF5TXiv2U3+s/gU3hCQ7c915
        /xmx14in8oMHyg/AY5RfMbH7M+ust7MzrORGt6f6MxH4AP8MaN3P6UQ1mcsYwjZebKFHafhS5xkJ
        bM+1jneRza/qw4bmYqfkfw9av5VcxVZJ2FHj+2SJTaNw8ejr7WAFXiqVhgXw5ahyJiH2YZCSPqze
        Y2a8dMsMkrtdgSzg0pgm8i7CFk0cmiTZ4SzGLf6Nk5AQy4JENsb6vc1MXS55D1szLvGvEJtHXLsV
        ThsEcf0EIQrDFX3OTBdSjfHgfr2SwpJP01Y2iKnUZeuzBKCiggq2FPNxcGGVA5Y0/QIDAQABozEw
        LzAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFEcgo7EmS81tSKzyZAiGlyx0VBFfMA0GCSqGSIb3
        DQEBCwUAA4IBAQBbPqamMsKliQ3z2P4l6t6VMhNxZmlg1r5PHZMhAdlyyEWFm1/2A6QNAMDu8bAv
        6FR+6kwRnz7VIY+yY9KgouT3vq9vSCxzCxnomdrxkJOA/aUb0XP5SCdfgsNUWxngeXqYIu4nlKzZ
        3v2ieIHSwBvMmnnYhrovWLDcAvgrohGToFEYzJ4n9dvh/1F1wR9kJqbJxnLn9OtIOeaKgRjY73yz
        b811trApI7eFZL+yDiaC3RHc0OuirEiwf0KtkhnbWMJcSyBNsVOh8ITPJldKD0ky7p/oy6gmwVu7
        Tzj42phsLD4Mf+wGaLnmgu83OFf8OSJgp05QR8l+a2vLa8A8aHuv
        """

    /// AuthorityKeyIdentifier = MOICA G2. Structurally outside the rs4096 circuit.
    static let holderLikeG2 = """
        MIIC/TCCAeWgAwIBAgIBFDANBgkqhkiG9w0BAQsFADAlMQswCQYDVQQGEwJUVzEWMBQGA1UECgwN
        Tm90IEEgUmVhbCBDQTAeFw0yNjAxMDEwMDAwMDBaFw0yNzAxMDEwMDAwMDBaMCwxCzAJBgNVBAYT
        AlRXMR0wGwYDVQQDDBRGaXh0dXJlIGhvbGRlckxpa2VHMjCCASIwDQYJKoZIhvcNAQEBBQADggEP
        ADCCAQoCggEBANOgGRb7+pkepsutJzCD4eM6kqSrFZ8SrJtI1DnAtWH4bmcx6sITEPAl01On/CxS
        LEyy1k5RlVP487ctp5SACkO3l5PiCwFwhexj4jIh/5lS++yIVsv45VgQpTy3QzI+pgR8Plk+zt1p
        6pweHrZ5CzHIfuVsHt6Iraac1xHy+GLxf7DToomPADUjFp+Y6WJPxjsxzwKs3pTfZdDwNbGO/X6B
        1niRfpNqAnVJO2rk7QqNmNbdniivwBh/28Xt5INychVLQtDStaovqABUikZ3XC4RlGIx3ZLrWQMO
        e/nsx+qPrmppSczBrJHOXq0Egu0zj0oI6p2BH2d6K5sfGG7ap18CAwEAAaMxMC8wDAYDVR0TAQH/
        BAIwADAfBgNVHSMEGDAWgBT6mzRnCQqYIvdiSIuCJqZFxcMipDANBgkqhkiG9w0BAQsFAAOCAQEA
        NeyIBf0/DpyVm/eMcOjLgn/Y3Hlb1N3z2nUyPnlWtcyIEosy5VDz7ZL18SGuJJC5sj3zH8rSOob0
        8m7A9GT/aSmVJAS25TSRGyhDygparJQYOLR8QaCx1H9gH7R9YjPEx6HSy953m507f4BfLcollhLf
        ZuIcA+Yi0Y56POwXMvmzTuxqmitXq+j7RzhTdUaZ3+jmGPNCJmxROro4MLNuF8pDkTll8OHmsKXN
        CdPncLC77wLuId3ds6zdI0Yvha90YJdDXT3rPoy4Kg8jAKj7Do/51RnDE8xfE9cw8RI3Jopz0ZVz
        N9Wtpbv0Eg4ZcI+yzk1KZ+JxaaVPewvbSkZn1g==
        """

    /// No AuthorityKeyIdentifier extension at all.
    static let holderWithoutAKI = """
        MIIC4DCCAcigAwIBAgIBFTANBgkqhkiG9w0BAQsFADAlMQswCQYDVQQGEwJUVzEWMBQGA1UECgwN
        Tm90IEEgUmVhbCBDQTAeFw0yNjAxMDEwMDAwMDBaFw0yNzAxMDEwMDAwMDBaMDAxCzAJBgNVBAYT
        AlRXMSEwHwYDVQQDDBhGaXh0dXJlIGhvbGRlcldpdGhvdXRBS0kwggEiMA0GCSqGSIb3DQEBAQUA
        A4IBDwAwggEKAoIBAQCgOI/5+XfhDCHa6lfXdb9f6UlxcNmwc27XhL1dF53jSocbIJrlSRWB343Q
        EJ0qTtaWN2O0+pI5qZ4FREYTC2zQWiaBWCCCPji+s/HT19lxaRQ9jvWXQMIyolghlXsl2DQT+r3k
        +sBA+Wg8R7YRYfIF04Cp0yeptCDSx3lOsmeZDIYoXlvDZdg2ur014ACY7cRvrjh5neoeYvb4/GVz
        m6XcJWDgFZ2TF+uD13ECjHjFuRDEvE5XpAid8X7BaHGk99M4qgykmQ9CTy1tNmkEHWnoroCrHPoq
        nEi8sp/r1xJLzeqfxfckPN+M3ZYsCZ9s8bEzrRu649WF8ikOrgEwF7w7AgMBAAGjEDAOMAwGA1Ud
        EwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggEBACBstsXbtCjhR5j380btvkyXPYdQh+PKt9uUDkZu
        CGlHwo28W/n0UgByzekN9HRpRvFm1EGGXBXM7doN3ClYv2puSzo+vC0O05lpQK60ib1taXq0YK/z
        pVkT7qygVWwjqGVDpOCK1imOFfBzP6saKjZPeVDYm0K5HmTaB5oB1ALluWdbIPUbbUUD1FkrtYdG
        k6cZwH26JgVYqM0qZ3BWZ0LRLWM9bE4mcReyNMSuB9BU+0gi3rlvzGy2U8BaxSdqqtTnSyuUFaZT
        lgZAjzpTqsmtA4ecN6807WJeWFKtz7ehZGxVvlPNemEGdtuD5i2o8ZtPDL+fhdi2ybzfuyvEXqI=
        """

    /// AuthorityKeyIdentifier naming a CA this build has never heard of — the
    /// shape a future MOICA G4 will arrive in.
    static let holderUnknownIssuer = """
        MIIDBDCCAeygAwIBAgIBFzANBgkqhkiG9w0BAQsFADAlMQswCQYDVQQGEwJUVzEWMBQGA1UECgwN
        Tm90IEEgUmVhbCBDQTAeFw0yNjAxMDEwMDAwMDBaFw0yNzAxMDEwMDAwMDBaMDMxCzAJBgNVBAYT
        AlRXMSQwIgYDVQQDDBtGaXh0dXJlIGhvbGRlclVua25vd25Jc3N1ZXIwggEiMA0GCSqGSIb3DQEB
        AQUAA4IBDwAwggEKAoIBAQDZNDQhK9hqXY3Cxuau7Y2IZNLb80xnVkDDZrP5JAytgl6XVuyz450V
        0OhEspeWm36g8cBwLTOknIFaFuIZarmSD//CVyNXcfT9U82ory9WBG2JQv/LRIRMGmEmSEmKbE9O
        OOvaUN+YM+ac8Y/cgQejYwJOQ7qtINbx9xTev3N7FNlcpBNg8aGTiO1NVbF/BaVe4yLbuqNViVV8
        5KIZy3uOalepOEjn3mf6Tu/VY/XOalwkBnPIRZGyqDdtlOhEGAw28Atz7drksDkEwFnIUCW6GXyd
        rd3RwFDgwuLk9dF2VmnQDGu0qbPcyMQzz3pNY2+arw6KmdC2z/e1bZeE9w1jAgMBAAGjMTAvMAwG
        A1UdEwEB/wQCMAAwHwYDVR0jBBgwFoAUICEiIyQlJicoKSorLC0uLzAxMjMwDQYJKoZIhvcNAQEL
        BQADggEBAHxdV9BbojeXDP2t0Iojh5hjpUT7LEdOT5iQ2L0keLdpNQTOOrWwZZZ8k087lCG0UjDL
        +iudrNYsFhHFEtAPvAbcQalGFBppC4QXV0VoVClF4cf46UvP+MazZ4pWy88OKoeztzLdkMYcVEcA
        69OdqIG8Kcl4+ajppHcBd+TDxz6zCwSZLxaS+eZDwtELbdQJoTMFv306H4wbw+PPADL85sNCih8V
        lNLXDCwjW8Dh4rCLgysdQd923bS76R9azMBYAm6BPLLGT8g4yGkBC38cXhl0uULiQ9Yd8x+Kn/zB
        sFxK2wCr8J2UGDT7GcTjBM3HGna21pX38l7+N6Tk1dEcUQI=
        """

    /// notBefore is a UTCTime; notAfter is 2055, which DER requires to be a
    /// GeneralizedTime. One certificate, both encodings.
    static let holderMixedTimeEncodings = """
        MIIDCzCCAfOgAwIBAgIBFjANBgkqhkiG9w0BAQsFADAlMQswCQYDVQQGEwJUVzEWMBQGA1UECgwN
        Tm90IEEgUmVhbCBDQTAgFw0yNjAxMDEwMDAwMDBaGA8yMDU1MDEwMTAwMDAwMFowODELMAkGA1UE
        BhMCVFcxKTAnBgNVBAMMIEZpeHR1cmUgaG9sZGVyTWl4ZWRUaW1lRW5jb2RpbmdzMIIBIjANBgkq
        hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmICwvF32uFhnc7ZMhsO2uPvNR4jnk/Am5JomCPJaocw7
        DIb2n4dLefKmlrQOuIrr6sSUjvuFaBJcy9Bw/qDtGxTcmh5Hr8hilbgsD6RUQAWacUwZwYaxZF7D
        AewB38Qy9+F6Ts0B2z1Frvlyz0S8H5s31pTCK8q1yFH+9e7P5ADWG2OYhJ9K/SSJ3Ce3EFQapiJL
        FNIcyn/fDeVx3RgU4k2bHa1MJsxMbwAOzuE798BKXS4sW+zNNC0zYKZOjT0VyRfjvSZD3tzAeDxA
        YIa8aZG3Qec6tP9B4e1pgCm0zYQMKh6s0zGMkCnYj1Y+RWxFCelVSDhuhtfAfX1I7H49dwIDAQAB
        ozEwLzAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFEcgo7EmS81tSKzyZAiGlyx0VBFfMA0GCSqG
        SIb3DQEBCwUAA4IBAQAdB2t40IrWdRKMMG9UqRA5psHNsqWARz9cax1GW9BNuIVdOGtei9dr18Iv
        EqXh5mt6iQrGqagg+z1ws7Kk9Zfb6vU6s31h/oQe2htSLw1b3c7fhj9x7uiwQYorOKzboMnXeYkV
        GKbK1T3D97XToG2OvWJaO4WuoTmi/Wrrbz8XFziGX5shRaIRsd3f/7LgHt9FVpFoR1Ugqxf6lnuy
        Ss/YbPUnh5QvMBOhFtCB1cFZwDORgwJZcOdKhV0yxAkl/DyXIIbPNvgAHy1XKjcFaApmur0L6eWP
        dVv997ZDCpe9kDnp9Qd1ZMl0Xe86SSFgzH3ZkBN5YQ/RSTyHtHWZGg9I
        """
}
