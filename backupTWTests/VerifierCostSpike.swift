//
//  VerifierCostSpike.swift
//  backupTWTests
//
//  Measures what a *verifier* pays, as opposed to what a holder pays.
//

import Foundation
import Testing
import OpenACSwift

@testable import backupTW

/// What it costs to check somebody else's proof, and whether all three checks
/// are needed to do it.
///
/// # Why this is a spike and not a test
///
/// It needs the real 968 MB of verifying keys and takes minutes, so it is gated
/// on an environment variable and never runs in CI. It asserts almost nothing;
/// its output is the measurement. It lives in the repo rather than in a
/// scratch file because the numbers it produces decide the shape of M4, and a
/// number nobody can reproduce is a number nobody should design against.
///
/// # What it is trying to settle
///
/// M2 measured the holder: prove 6.34 s + 2.13 s. The verifier's side came out
/// *slower* — 6.44 + 2.19 + 7.06 ≈ 15.7 s — which inverts the assumption M3 was
/// written under. Before designing a verifier app around a 16-second wait, two
/// things are worth knowing:
///
///   1. **Is it I/O or compute?** Already answered outside this file: reading
///      all 968 MB cold, bypassing the page cache, takes 0.59 s on this Mac's
///      SSD (1637 MB/s). Even at a third of that speed on iPhone flash the
///      transfer is under two seconds, so ~14 s of the 15.7 s is computation.
///      Preloading the keys cannot fix it, and holding them resident is not
///      available on a phone anyway.
///
///   2. **Are all three calls needed?** `linkVerify`'s own doc comment says it
///      verifies "proofs for cert_chain_rs4096 and user_sig_rs2048 circuits" —
///      both — while `verifyCertChainRs4096` and `verifyUserSigRs2048` each name
///      one. If `linkVerify` subsumes them, a verifier can drop 8.6 s of the
///      15.7 s without weakening anything. That is not a shortcut; it is
///      declining to do the same work twice.
///
/// # The trap this is written to avoid
///
/// "Corrupting a proof makes `linkVerify` fail" does **not** establish
/// subsumption. A mangled buffer can fail a length check or a deserialisation
/// step without any cryptography running, which would prove only that the file
/// is unreadable. So the corruption here is applied to bytes in the middle of
/// the proof, the individual verify is run *first* to confirm it now rejects,
/// and the interesting case is recorded separately from the uninteresting one:
/// a `throw` and a `false` are not the same answer, and upstream returns the
/// interesting answer by throwing (see `OpenACProofVerifier.timed`).
@Suite(.serialized)
struct VerifierCostSpike {

    /// A directory holding `keys/` with all four real keys, the two circuit
    /// input JSONs, and `MOICA-G3.cer`. Assembled by hand; see the file header.
    static var workingDirectory: String? {
        ProcessInfo.processInfo.environment["ZK_BENCH_DIR"]
    }

    static var isAvailable: Bool {
        guard let directory = workingDirectory else { return false }
        let needed = ["keys/cert_chain_rs4096_proving.key",
                      "keys/user_sig_rs2048_proving.key",
                      "keys/cert_chain_rs4096_verifying.key",
                      "keys/user_sig_rs2048_verifying.key",
                      "cert_chain_rs4096_input.json",
                      "user_sig_rs2048_input.json"]
        return needed.allSatisfy {
            FileManager.default.fileExists(
                atPath: (directory as NSString).appendingPathComponent($0))
        }
    }

    private static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    /// One check, reported the way upstream actually answers.
    ///
    /// `true`, `false` and "threw" are three different outcomes and the whole
    /// point of `OpenACProofVerifier` is that upstream uses the third one to
    /// mean "no". Collapsing them here would reproduce the bug this project has
    /// already fixed twice.
    private enum Answer: CustomStringConvertible {
        case yes(Double)
        case no(Double)
        case threw(String, Double)

        var description: String {
            switch self {
            case .yes(let t): return String(format: "true   %.2fs", t)
            case .no(let t): return String(format: "FALSE  %.2fs", t)
            case .threw(let m, let t): return String(format: "THREW  %.2fs  %@", t, m)
            }
        }

        var isAcceptance: Bool { if case .yes = self { return true }; return false }
        var duration: Double {
            switch self { case .yes(let t), .no(let t), .threw(_, let t): return t }
        }
    }

    private static func ask(_ name: String,
                            _ call: (String) throws -> Bool,
                            _ directory: String) -> Answer {
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        }
        do {
            let ok = try call(directory)
            return ok ? .yes(elapsed()) : .no(elapsed())
        } catch {
            return .threw(String(describing: error).prefix(60).description, elapsed())
        }
    }

    @Test(.enabled(if: VerifierCostSpike.isAvailable),
          .timeLimit(.minutes(10)))
    func whatAVerifierPays() async throws {
        let directory = try #require(Self.workingDirectory)
        let proofPath = (directory as NSString)
            .appendingPathComponent("keys/cert_chain_rs4096_proof.bin")
        let userProofPath = (directory as NSString)
            .appendingPathComponent("keys/user_sig_rs2048_proof.bin")

        print("\n════════ 驗證端成本 spike ════════")

        // MARK: Produce something to check

        var certResult: ProofResult!
        var userResult: ProofResult!
        let certProve = try Self.seconds { certResult = try proveCertChainRs4096(documentsPath: directory) }
        let userProve = try Self.seconds { userResult = try proveUserSigRs2048(documentsPath: directory) }
        print(String(format: "prove   cert %.2fs · user %.2fs · 合計 %.2fs",
                     certProve, userProve, certProve + userProve))

        let original = try Data(contentsOf: URL(fileURLWithPath: proofPath))
        let userOriginal = try Data(contentsOf: URL(fileURLWithPath: userProofPath))

        // Upstream's reported size and the size on disk are printed side by
        // side deliberately. `ProofMetrics.proofByteCount` is what this app
        // records and shows, but what a verifier has to be handed is the file —
        // and if those two numbers disagree, every transport estimate built on
        // the reported one is wrong. QR is the transport M3 already built, and
        // its ceiling is ~2,953 bytes per frame.
        print("proof   cert 回報 \(certResult.proofSizeBytes) bytes · 檔案 \(original.count) bytes")
        print("proof   user 回報 \(userResult.proofSizeBytes) bytes · 檔案 \(userOriginal.count) bytes")

        // The verifier needs the public inputs too, so they are part of the
        // payload whether or not anything has been counting them.
        var payload = original.count + userOriginal.count
        for name in ["keys/cert_chain_rs4096_instance.bin", "keys/user_sig_rs2048_instance.bin"] {
            let path = (directory as NSString).appendingPathComponent(name)
            let size = (try? Data(contentsOf: URL(fileURLWithPath: path)).count) ?? 0
            payload += size
            print("instance \(name.replacingOccurrences(of: "keys/", with: "")) \(size) bytes")
        }
        print(String(format: "要送到查驗方手上的總量 %d bytes ≈ %.0f 個 QR frame（每張上限 2,953）",
                     payload, (Double(payload) / 2953).rounded(.up)))

        // MARK: Cost, twice — the second pass is warm

        // `linkVerify` is *expected to reject* here, and that is not a defect in
        // this spike. Upstream's two committed test vectors carry different
        // `pkBlind` values — 3885… in the cert-chain input, 1170… in the
        // user-sig input — so they are two unrelated proofs, not one holder's
        // linked pair. Both individual checks accept them; only `linkVerify`
        // notices. That is the negative control M2 was looking for, arriving
        // for free: it shows `linkVerify` establishes something the other two
        // cannot, so it can never be dropped in favour of them.
        for pass in ["cold", "warm"] {
            let cert = Self.ask("cert", verifyCertChainRs4096, directory)
            let user = Self.ask("user", verifyUserSigRs2048, directory)
            let link = Self.ask("link", linkVerify, directory)
            print(String(format: "verify(%@)  cert %@ · user %@ · link %@ · 合計 %.2fs",
                         pass, "\(cert)", "\(user)", "\(link)",
                         cert.duration + user.duration + link.duration))
            #expect(cert.isAcceptance && user.isAcceptance,
                    "each proof is individually valid")
            #expect(!link.isAcceptance,
                    "upstream's vectors are an unlinked pair; a linkVerify that accepted them would mean the link check establishes nothing")
        }

        // MARK: Does linkVerify subsume the other two?

        // Corrupt the middle of each proof in turn. The individual check is run
        // first: if it still accepts, the corruption landed somewhere unused and
        // the linkVerify answer below would say nothing.
        for (label, path, pristine, individual) in [
            ("cert_chain", proofPath, original, verifyCertChainRs4096),
            ("user_sig", userProofPath, userOriginal, verifyUserSigRs2048)
        ] as [(String, String, Data, (String) throws -> Bool)] {
            var damaged = pristine
            let middle = damaged.count / 2
            damaged[middle] ^= 0xFF
            damaged[middle + 1] ^= 0xFF
            try damaged.write(to: URL(fileURLWithPath: path))

            let own = Self.ask(label, individual, directory)
            let link = Self.ask("link", linkVerify, directory)
            print("損壞 \(label): 自身檢查 \(own)  |  linkVerify \(link)")
            if own.isAcceptance {
                print("   ⚠️ 自身檢查仍接受——這次損壞沒打到會被檢查的位元組，linkVerify 的答案不具參考性")
            } else if !link.isAcceptance {
                print("   → linkVerify 也抓到了：這一項的個別檢查是重複的")
            } else {
                print("   → linkVerify 沒抓到：個別檢查不可省")
            }

            try pristine.write(to: URL(fileURLWithPath: path))
        }

        // Restored, so the suite leaves the directory as it found it.
        #expect(Self.ask("cert", verifyCertChainRs4096, directory).isAcceptance)
        #expect(Self.ask("user", verifyUserSigRs2048, directory).isAcceptance)
        print("════════════════════════════════\n")
    }
}

