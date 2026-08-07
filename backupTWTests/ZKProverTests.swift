//
//  ZKProverTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

// MARK: - Orchestration

/// A real proof needs 950 MB of proving key on disk and about two gigabytes of
/// memory to use it. None of that can happen here, and none of it needs to: the
/// things that go wrong in this module are ordering, misclassified failures, and
/// the cardholder's certificate being left on disk after it stopped being
/// needed. All three are above the `ProofBackend` seam, which is why the seam is
/// there.
///
/// Serialised for a reason that is not cosmetic: `ZKProver` funnels every
/// backend call through one process-wide serial queue, so a test that parks a
/// fake inside `generateInputs` would park every other test's proof behind it.
@Suite(.serialized)
struct ZKProverTests {

    // MARK: Ordering and results

    /// The contract in one test: inputs first, then the certificate-chain
    /// circuit, then the signature circuit, with both results reported rather
    /// than summed away.
    @Test func provesBothCircuitsInOrderAndReportsEachSeparately() async throws {
        let fixture = try Fixture()
        let bundle = try await fixture.prover().prove(fixture.inputs)

        #expect(fixture.backend.calls == ["generateInputs", "cert_chain_rs4096", "user_sig_rs2048"])
        #expect(bundle.certificateChain == FakeProofBackend.Plan.defaultCertificateChain)
        #expect(bundle.userSignature == FakeProofBackend.Plan.defaultUserSignature)
        #expect(bundle.totalProveMilliseconds == 36_000)
        #expect(bundle.totalProofByteCount == 19_134)
        #expect(bundle.proofDirectory == fixture.directory.appendingPathComponent("keys",
                                                                                 isDirectory: true))
    }

    // MARK: Readiness — the recoverable half

    /// The distinction this whole error type exists for. Someone who has not
    /// finished an 82 MB download must not be told their certificate is broken.
    @Test func refusesBeforeTouchingTheBackendWhenAnAssetIsMissing() async throws {
        let fixture = try Fixture(readiness: ZKAssetReadiness(missing: ["Certificate revocation snapshot"],
                                                              stale: []))
        await #expect(throws: ZKProofError.assetsNotReady(missing: ["Certificate revocation snapshot"],
                                                          stale: [])) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(fixture.backend.calls.isEmpty)
    }

    /// A stale snapshot is worse than a missing one — everything says ready and
    /// the proof is refused at the counter — so it is refused just as hard.
    @Test func treatsAStaleSnapshotAsSeriouslyAsAMissingOne() async throws {
        let fixture = try Fixture(readiness: ZKAssetReadiness(missing: [],
                                                              stale: ["Certificate revocation snapshot"]))
        await #expect(throws: ZKProofError.assetsNotReady(missing: [],
                                                          stale: ["Certificate revocation snapshot"])) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(fixture.backend.calls.isEmpty)
    }

    /// The machine-readable form of "go and finish preparing" versus "this will
    /// fail again". A screen that shows the same button for both is the bug.
    @Test func separatesAnUnpreparedInstallFromAProofThatActuallyFailed() {
        #expect(ZKProofError.assetsNotReady(missing: ["x"], stale: []).isRecoverable)
        #expect(ZKProofError.issuerCertificateMissing.isRecoverable)
        #expect(ZKProofError.revocationSnapshotMissing.isRecoverable)

        #expect(!ZKProofError.proofFailed(circuit: .certificateChain,
                                          reason: .proofGenerationFailed).isRecoverable)
        #expect(!ZKProofError.revocationCheckDegraded.isRecoverable)
        #expect(!ZKProofError.inputsRejected(.certificateEmpty).isRecoverable)
        #expect(!ZKProofError.workingDirectoryUnavailable.isRecoverable)
    }

    /// `MOICA-G3.cer` ships in the app bundle and is copied into the working
    /// directory by the preparation flow. Until that has happened, the library
    /// would fail on a path — which is a sentence nobody can act on.
    @Test func refusesWhenTheBundledIssuerCertificateWasNeverInstalled() async throws {
        let fixture = try Fixture(installIssuerCertificate: false)
        await #expect(throws: ZKProofError.issuerCertificateMissing) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(fixture.backend.calls.isEmpty)
    }

    @Test func refusesWhenTheRevocationSnapshotIsNotOnDisk() async throws {
        let fixture = try Fixture(installSnapshot: false)
        await #expect(throws: ZKProofError.revocationSnapshotMissing) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(fixture.backend.calls.isEmpty)
    }

    /// The other half of the readiness question: what the prover must *not* be
    /// asked for.
    ///
    /// `ZKProver`'s readiness is whatever its `CircuitAssets` store lists, and
    /// the production wiring used to hand it the store that also carries the two
    /// verifying keys — 968 MB installed that `prove` never opens. The result was
    /// `assetsNotReady` naming files the prover cannot read, on a device where
    /// everything a proof needs was already on disk. That is not a wait: a phone
    /// with 1.2 GB free cannot hold both halves, so no retry ever clears it and
    /// the 950 MB already downloaded produces nothing.
    @Test func provesOnceTheProvingAssetsAreInstalled() async throws {
        let fixture = try Fixture()
        for asset in CircuitAssetPreparer.provingAssets {
            try fixture.write(asset.localFilename, Data([0x01]))
        }

        let store = CircuitAssetPreparer.makeProvingStore(directory: fixture.directory)
        let bundle = try await ZKProver(assets: store, backend: fixture.backend)
            .prove(fixture.inputs)

        #expect(fixture.backend.calls == ["generateInputs", "cert_chain_rs4096", "user_sig_rs2048"])
        #expect(bundle.totalProveMilliseconds == 36_000)

        // The same directory through the download store: the verifying keys are
        // genuinely absent, and it still says so. The fix is not "pretend they
        // are there", it is "stop asking the prover about them".
        let download = CircuitAssetPreparer.makeStore(directory: fixture.directory)
        let outstanding = await download.missingAssets()
        #expect(outstanding.map(\.name)
                == CircuitAssetPreparer.verificationAssets.map(\.name))
    }

    // MARK: Failure classification

    /// Two circuits, two proving keys, two failure modes. "Proof failed" without
    /// naming which one leaves nothing to investigate.
    @Test func namesTheCircuitThatFailed() async throws {
        let first = try Fixture(plan: .init(certChainFailure: .proofGenerationFailed))
        await #expect(throws: ZKProofError.proofFailed(circuit: .certificateChain,
                                                       reason: .proofGenerationFailed)) {
            _ = try await first.prover().prove(first.inputs)
        }
        // The second circuit is never reached once the first has failed.
        #expect(first.backend.calls == ["generateInputs", "cert_chain_rs4096"])

        let second = try Fixture(plan: .init(userSigFailure: .invalidInput))
        await #expect(throws: ZKProofError.proofFailed(circuit: .userSignature,
                                                       reason: .invalidInput)) {
            _ = try await second.prover().prove(second.inputs)
        }
        #expect(second.backend.calls == ["generateInputs", "cert_chain_rs4096", "user_sig_rs2048"])
    }

    /// Assembling the circuit input needs no proving key; proving needs 950 MB
    /// of one. Reporting both as "the proof failed" hides which half of the
    /// pipeline is broken.
    @Test func keepsInputGenerationFailuresApartFromProofFailures() async throws {
        let fixture = try Fixture(plan: .init(generateFailure: .invalidInput))
        await #expect(throws: ZKProofError.inputGenerationFailed(.invalidInput)) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(fixture.backend.calls == ["generateInputs"])
    }

    /// A file that disappeared between the readiness check and the call — a
    /// purge, a snapshot deleted to reclaim space — is a download away from
    /// working, so it must not be reported as a broken certificate even though
    /// it surfaced from inside the backend.
    @Test func treatsAFileThatVanishedMidRunAsRecoverable() async throws {
        let fixture = try Fixture(plan: .init(generateFailure: .fileNotFound))
        do {
            _ = try await fixture.prover().prove(fixture.inputs)
            Issue.record("a missing file was not reported")
        } catch let error as ZKProofError {
            #expect(error == .inputGenerationFailed(.fileNotFound))
            #expect(error.isRecoverable)
        }
    }

    /// The seam has to be total. A Rust panic through UniFFI, or any backend
    /// with its own error type, must arrive as a classified `ZKProofError` and
    /// not escape as a raw `Error` the UI has no case for.
    @Test func classifiesAnUnrecognisedBackendErrorRatherThanLettingItEscape() async throws {
        let fixture = try Fixture(plan: .init(certChainThrowsForeignError: true))
        await #expect(throws: ZKProofError.proofFailed(circuit: .certificateChain,
                                                       reason: .unknown)) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
    }

    /// `generateCertChainRs4096Input` returns a path string that `prove*` never
    /// reads, so the only thing worth believing is the two files being there.
    @Test func refusesWhenTheInputsWereNotActuallyWritten() async throws {
        let fixture = try Fixture(plan: .init(writesInputFiles: false))
        await #expect(throws: ZKProofError.inputsNotWritten(
            missing: ["cert_chain_rs4096_input.json", "user_sig_rs2048_input.json"])) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(fixture.backend.calls == ["generateInputs"])
    }

    // MARK: The revocation check that fails silently

    /// The worst available failure mode, so it gets its own error and its own
    /// sentence: passing no snapshot — or a snapshot the library ignored —
    /// produces an empty-tree witness with `smtRoot == "0"`. The circuit is
    /// satisfied, the proof generates, it verifies locally, and every verifier
    /// comparing against the real on-chain root refuses it.
    @Test func refusesAProofWhoseRevocationWitnessIsAnEmptyTree() async throws {
        let fixture = try Fixture(plan: .init(revocationRoot: "0"))
        await #expect(throws: ZKProofError.revocationCheckDegraded) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        // Nothing was proved: thirty seconds and two gigabytes not spent on a
        // proof that was going to be rejected.
        #expect(fixture.backend.calls == ["generateInputs"])
    }

    /// "We could not confirm the revocation check happened" gets the same answer
    /// as "it did not". Treating an unreadable input as a pass is how the check
    /// quietly stops existing.
    @Test func refusesWhenTheRevocationRootCannotBeReadAtAll() async throws {
        let fixture = try Fixture(plan: .init(inputFileContents: Data("not json".utf8)))
        await #expect(throws: ZKProofError.revocationCheckDegraded) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
    }

    // MARK: Arguments — the four that are easy to get wrong

    /// Upstream's README parameter table says to pass `nil` here. That line is
    /// stale — the usage example twelve lines above it passes the snapshot path,
    /// and the Rust side builds the non-membership proof itself. Passing `nil`
    /// does not fail, it degrades, which is why this is pinned.
    @Test func alwaysSuppliesTheRevocationSnapshotPathAndNeverNil() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prover().prove(fixture.inputs)

        let recorded = try #require(fixture.backend.recorded)
        #expect(recorded.revocationSnapshotPath
                == fixture.directory.appendingPathComponent("g3-tree-snapshot.json.gz").path)
    }

    /// `tbs` is the 31-character relying-party identifier as an ASCII string.
    /// The same value goes to TW FidO base64-encoded, and passing that encoding
    /// here yields a proof that generates successfully and verifies against
    /// nothing.
    @Test func passesTheRelyingPartyIdentifierRawAndNotItsBase64Form() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prover().prove(fixture.inputs)

        let recorded = try #require(fixture.backend.recorded)
        #expect(recorded.relyingPartyIdentifier == TWFidOConfiguration.bondsAppID)
        #expect(recorded.relyingPartyIdentifier.count == 31)
        #expect(recorded.relyingPartyIdentifier
                != Data(TWFidOConfiguration.bondsAppID.utf8).base64EncodedString())
    }

    /// The holder's certificate goes in as `certb64`; the issuer arrives as a
    /// separate file path. The reference app calls its copy of the former
    /// `athIssuerCert`, which is the invitation to swap them.
    @Test func keepsTheHolderCertificateAndTheIssuerInTheirOwnSlots() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prover().prove(fixture.inputs)

        let recorded = try #require(fixture.backend.recorded)
        #expect(recorded.certificateBase64 == fixture.inputs.certificateBase64)
        #expect(recorded.signedResponse == fixture.inputs.signedResponse)
        #expect(recorded.issuerCertificatePath
                == fixture.directory.appendingPathComponent("MOICA-G3.cer").path)
    }

    /// `outputDir` has to equal the `documentsPath` handed to `prove*`, because
    /// `prove*` re-derives the input file names from it rather than taking the
    /// path `generateCertChainRs4096Input` returns.
    @Test func writesTheCircuitInputsWhereProveWillLookForThem() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prover().prove(fixture.inputs)

        let recorded = try #require(fixture.backend.recorded)
        #expect(recorded.outputDirectory == fixture.directory.path)
        #expect(fixture.backend.provedDocumentsPaths == [fixture.directory.path,
                                                         fixture.directory.path])
    }

    /// Decimal, not base64url. Circom reads field elements as decimal strings,
    /// and handing this the challenge unchanged binds the proof to a different
    /// number than the verifier issued.
    @Test func handsTheChallengeOverAsADecimalFieldElement() async throws {
        let challenge = ProofChallenge.fromVerifier(Fixture.base64URL(Data(repeating: 0xFF, count: 16)))
        let fixture = try Fixture(challenge: challenge)
        _ = try await fixture.prover().prove(fixture.inputs)

        let recorded = try #require(fixture.backend.recorded)
        #expect(recorded.challenge == "340282366920938463463374607431768211455")
    }

    // MARK: The cardholder's material must not outlive the proof

    /// The input JSON is the holder's certificate expanded into circuit limbs.
    /// Its job ends the moment both proofs exist.
    @Test func deletesTheCircuitInputsAfterASuccessfulProof() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prover().prove(fixture.inputs)

        for name in ZKProver.inputFilenames {
            #expect(!fixture.exists(name), "\(name) survived a successful proof")
        }
    }

    /// The path that matters more, because it is the one a `defer` is easy to
    /// get wrong on: the inputs were written, the proof failed, and the
    /// certificate is still sitting in the working directory.
    @Test func deletesTheCircuitInputsAfterAFailedProof() async throws {
        let fixture = try Fixture(plan: .init(userSigFailure: .proofGenerationFailed))
        await #expect(throws: ZKProofError.self) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }

        for name in ZKProver.inputFilenames {
            #expect(!fixture.exists(name), "\(name) survived a failed proof")
        }
    }

    /// **The one that would be easiest to miss.** A witness is the assignment of
    /// every wire in the circuit — the private inputs included, about 62 MB of
    /// them for `certChainRS4096`. A zero-knowledge proof beside a file that
    /// discloses everything it was hiding is not zero-knowledge.
    @Test func deletesTheWitnessesThatHoldThePrivateInputs() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prover().prove(fixture.inputs)

        // The fake wrote them, so their absence is the prover's doing.
        #expect(fixture.backend.wroteWitnesses)
        for name in ZKProver.witnessFilenames {
            #expect(!fixture.exists(name), "\(name) survived — the witness is the secret")
        }
    }

    /// The other half of the same rule: the proof and its public inputs are the
    /// deliverable and reveal nothing, so they stay.
    @Test func keepsTheProofAndItsPublicInputs() async throws {
        let fixture = try Fixture()
        _ = try await fixture.prover().prove(fixture.inputs)

        for name in ZKProver.proofFilenames + ZKProver.instanceFilenames {
            #expect(fixture.exists(name), "\(name) was deleted — that is the result")
        }
    }

    /// If proving fails, the previous run's proof must not be left where this
    /// run's was going to be, looking current. Cleared on the way in rather than
    /// on the way out, because the way out is the path that just failed.
    @Test func clearsAnEarlierRunsProofBeforeStartingANewOne() async throws {
        let fixture = try Fixture(plan: .init(generateFailure: .invalidInput))
        try fixture.write("keys/cert_chain_rs4096_proof.bin", Data("last week's proof".utf8))

        await #expect(throws: ZKProofError.self) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(!fixture.exists("keys/cert_chain_rs4096_proof.bin"))
    }

    /// A run killed by jetsam halfway through leaves the certificate on disk.
    /// The next attempt clears it even when that attempt refuses immediately —
    /// otherwise the material sits there until something else happens to
    /// succeed.
    @Test func clearsLeftoverInputsEvenWhenItRefusesBeforeProving() async throws {
        let fixture = try Fixture(readiness: ZKAssetReadiness(missing: ["Signature proving key"],
                                                              stale: []))
        try fixture.write("cert_chain_rs4096_input.json", Data("a certificate, expanded".utf8))

        await #expect(throws: ZKProofError.self) {
            _ = try await fixture.prover().prove(fixture.inputs)
        }
        #expect(!fixture.exists("cert_chain_rs4096_input.json"))
    }

    /// The directory the certificate is about to be written into is excluded
    /// from iCloud backup, re-asserted on every proof rather than once at
    /// install — a restore or a purge can recreate it without the flag.
    @Test func excludesTheWorkingDirectoryFromBackupBeforeWritingTheCertificate() async throws {
        let fixture = try Fixture()
        // The fixture creates the directory plainly, so the exclusion below can
        // only have come from `prove`.
        let before = try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(before.isExcludedFromBackup != true)

        _ = try await fixture.prover().prove(fixture.inputs)

        let after = try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(after.isExcludedFromBackup == true)
    }

    // MARK: One at a time

    /// Proving peaks around two gigabytes, which is at or above the jetsam
    /// ceiling on a 4 GB iPhone, and upstream documents a heap-corruption crash
    /// when two RS4096 witnesses are generated in one process. A double tap must
    /// be refused, not queued.
    @Test func refusesASecondProofWhileOneIsStillRunning() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try Fixture(plan: .init(gate: gate))
        let prover = fixture.prover()
        let inputs = fixture.inputs

        let first = Task { try await prover.prove(inputs) }
        // Wait for the fake to be parked inside `generateInputs`. Bounded so a
        // regression here fails the test rather than hanging the suite.
        var spins = 0
        while fixture.backend.calls.isEmpty && spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        #expect(fixture.backend.calls == ["generateInputs"])

        await #expect(throws: ZKProofError.alreadyProving) {
            _ = try await prover.prove(fixture.inputs)
        }

        gate.signal()
        _ = try await first.value
    }

    /// …and the flag is released, so the next attempt is not refused forever.
    @Test func allowsAnotherProofOnceTheFirstHasFinished() async throws {
        let fixture = try Fixture()
        let prover = fixture.prover()
        _ = try await prover.prove(fixture.inputs)
        _ = try await prover.prove(fixture.inputs)
        #expect(fixture.backend.calls.count == 6)
    }

    // MARK: Caveats

    /// Five of these are properties of the design, not of a run, so they are on
    /// every proof this app produces. A screen that wants to say 「已驗證」 has
    /// to walk past them.
    ///
    /// Order is pinned as well as membership, because it is the order they are
    /// drawn in and the two that decide what this project may claim at all are
    /// first on purpose.
    @Test func everyProofCarriesTheFiveUnconditionalCaveats() async throws {
        let fixture = try Fixture(challenge: .fromVerifier(Fixture.verifierChallenge))
        let bundle = try await fixture.prover().prove(fixture.inputs)

        #expect(bundle.caveats == [.signatureMaterialIsReplayable,
                                   .idNumberDisclosedToIssuer,
                                   .noGlobalUniqueness,
                                   .certificateExpiryNotProven,
                                   .revocationRootNotAnchored])
        // Same list, from the definition the screen and the report read.
        #expect(bundle.caveats == ProofCaveat.unconditional)
    }

    /// **The signing material is a bearer token that never expires.**
    ///
    /// TW FidO's SIGN flow signs `sign_data = base64(app_id)` — a constant — and
    /// not the challenge, so `result.signed_response` is the same 256 bytes
    /// every time. Anyone holding `(cert, signed_response)` can mint a valid
    /// proof for any future challenge, on any device, with no cardholder
    /// present; and 內政部 is in that set, because ATH-02 returns both fields.
    /// The RSA signature is a circuit witness, so replaying it never requires
    /// disclosing it.
    ///
    /// Nothing below this line can fix that — it is what the flow is — so the
    /// only honest response is to say it on **every** proof, including the ones
    /// where a verifier supplied the challenge and everything else looks
    /// strongest.
    @Test func everyProofSaysItsSigningMaterialCanBeReplayedByWhoeverHasIt() async throws {
        for challenge in [ProofChallenge.fromVerifier(Fixture.verifierChallenge),
                          try ProofChallenge.generate()] {
            let fixture = try Fixture(challenge: challenge)
            let bundle = try await fixture.prover().prove(fixture.inputs)
            #expect(bundle.caveats.contains(.signatureMaterialIsReplayable))
        }
    }

    /// **The minimal disclosure is against the verifier, and only the verifier.**
    ///
    /// Every proof begins with a SIGN request whose body carries `id_num` — the
    /// raw 身分證統一編號, not a hash — alongside `sp_service_id` and
    /// `sign_info.sign_data`. That is a complete audit trail of who proved what,
    /// when, and for which relying party, held by the issuer, before the proof
    /// exists. 「不會顯示你的身分證字號」 with no "to whom" is read as "nobody
    /// knows", which is the one reading that is false.
    @Test func everyProofSaysTheIdNumberWasDisclosedToTheIssuer() async throws {
        for challenge in [ProofChallenge.fromVerifier(Fixture.verifierChallenge),
                          try ProofChallenge.generate()] {
            let fixture = try Fixture(challenge: challenge)
            let bundle = try await fixture.prover().prove(fixture.inputs)
            #expect(bundle.caveats.contains(.idNumberDisclosedToIssuer))
        }
    }

    /// Exactly one caveat is a property of a run rather than of the design, and
    /// `caveats(for:)` may not drop any of the others on any input. This is the
    /// assertion that stops a future conditional from quietly shortening the
    /// list on the path where the result looks best.
    @Test func neverDropsAnUnconditionalCaveatWhateverTheChallenge() throws {
        let challenges = [ProofChallenge.fromVerifier(Fixture.verifierChallenge),
                          .holderGenerated(Fixture.verifierChallenge),
                          try ProofChallenge.generate()]
        for challenge in challenges {
            let caveats = ZKProver.caveats(for: challenge)
            for caveat in ProofCaveat.unconditional {
                #expect(caveats.contains(caveat), "\(caveat.rawValue) was dropped")
            }
        }
        #expect(!ProofCaveat.challengeNotBoundToVerifier.isUnconditional)
        #expect(ProofCaveat.unconditional.count == ProofCaveat.allCases.count - 1)
    }

    /// Nullifier de-duplication needs a shared record and there is none offline,
    /// so "a real person" holds and "a real person, once" does not. This is the
    /// assertion that stops that becoming a footnote.
    @Test func neverClaimsGlobalUniqueness() async throws {
        let holderMinted = try ProofChallenge.generate()
        for challenge in [ProofChallenge.fromVerifier(Fixture.verifierChallenge), holderMinted] {
            let fixture = try Fixture(challenge: challenge)
            let bundle = try await fixture.prover().prove(fixture.inputs)
            #expect(bundle.caveats.contains(.noGlobalUniqueness))
        }
    }

    /// A challenge the holder minted proves nothing about freshness to anybody
    /// else, so the proof carries a replay caveat. One the verifier supplied
    /// does not.
    @Test func marksAHolderMintedChallengeAsUnboundAndAVerifierOneAsBound() async throws {
        let holder = try Fixture(challenge: ProofChallenge.generate())
        let holderBundle = try await holder.prover().prove(holder.inputs)
        #expect(holderBundle.caveats.contains(.challengeNotBoundToVerifier))

        let verifier = try Fixture(challenge: .fromVerifier(Fixture.verifierChallenge))
        let verifierBundle = try await verifier.prover().prove(verifier.inputs)
        #expect(!verifierBundle.caveats.contains(.challengeNotBoundToVerifier))
    }

    /// Six limitations, six sentences. A copy-paste that gives two caveats the
    /// same text silently deletes one of them from every screen.
    @Test func everyCaveatHasItsOwnSentence() {
        let sentences = ProofCaveat.allCases.map(\.localizedDescription)
        let allPresent = sentences.allSatisfy { !$0.isEmpty }
        #expect(Set(sentences).count == ProofCaveat.allCases.count)
        #expect(allPresent)
    }
}

// MARK: - Inputs

struct ProvingInputsTests {

    // MARK: The certificate

    @Test func refusesAnAbsentCertificate() {
        #expect(throws: ProvingInputError.certificateEmpty) {
            _ = try ProvingInputs(certificateBase64: "",
                                  signedResponse: Fixture.signature(),
                                  challenge: .fromVerifier(Fixture.verifierChallenge))
        }
    }

    @Test func refusesACertificateThatIsNotBase64() {
        #expect(throws: ProvingInputError.certificateNotBase64) {
            _ = try ProvingInputs(certificateBase64: "not base64 at all!!",
                                  signedResponse: Fixture.signature(),
                                  challenge: .fromVerifier(Fixture.verifierChallenge))
        }
    }

    /// Every X.509 certificate is a DER `SEQUENCE`, so the first byte is 0x30.
    /// This is the cheap structural check that catches the swap the reference
    /// app's `athIssuerCert` naming invites — the signature, or the issuer,
    /// passed where the holder's certificate belongs.
    @Test func refusesSomethingThatDecodesButIsNotACertificate() {
        let notACertificate = (Data([0x31, 0x82, 0x01, 0x00]) + Data(repeating: 0, count: 60))
            .base64EncodedString()
        #expect(throws: ProvingInputError.certificateNotDER) {
            _ = try ProvingInputs(certificateBase64: notACertificate,
                                  signedResponse: Fixture.signature(),
                                  challenge: .fromVerifier(Fixture.verifierChallenge))
        }
    }

    // MARK: The signature

    /// The holder's 自然人憑證 is RSA-2048, so a PKCS#1 signature is exactly 256
    /// bytes and `userSigRS2048` reads it as 17 × 121-bit limbs. Anything else
    /// produces an unreadable `InvalidInput` from Rust after the argument has
    /// already been accepted — this is the line that says so by name.
    @Test func refusesASignatureThatIsNotTheRsa2048Length() throws {
        for byteCount in [0, 128, 255, 257, 512] {
            #expect(throws: ProvingInputError.signedResponseWrongLength(byteCount: byteCount),
                    "length \(byteCount)") {
                _ = try ProvingInputs(certificateBase64: Fixture.certificate(),
                                      signedResponse: Fixture.signature(byteCount: byteCount),
                                      challenge: .fromVerifier(Fixture.verifierChallenge))
            }
        }
    }

    @Test func acceptsAPkcs1SignatureOfExactly256Bytes() throws {
        let inputs = try ProvingInputs(certificateBase64: Fixture.certificate(),
                                       signedResponse: Fixture.signature(),
                                       challenge: .fromVerifier(Fixture.verifierChallenge))
        #expect(inputs.signedResponse == Fixture.signature())
    }

    @Test func refusesASignatureThatIsNotBase64() {
        #expect(throws: ProvingInputError.signedResponseNotBase64) {
            _ = try ProvingInputs(certificateBase64: Fixture.certificate(),
                                  signedResponse: "%%%",
                                  challenge: .fromVerifier(Fixture.verifierChallenge))
        }
    }

    // MARK: The relying-party identifier

    /// 31 lowercase hex characters — the circuit's field element has room for no
    /// more, which is why `bondsAppID` is a truncated digest.
    @Test func refusesARelyingPartyIdentifierThatIsNotThe31CharacterForm() {
        let rejected = [
            "",
            "55349ff540392a077ca3dcc9bbda4c",       // 30
            "55349ff540392a077ca3dcc9bbda4c33",     // 32
            "55349FF540392A077CA3DCC9BBDA4C3",      // uppercase
            "55349ff540392a077ca3dcc9bbda4cz",      // not hex
            Data(TWFidOConfiguration.bondsAppID.utf8).base64EncodedString()
        ]
        for identifier in rejected {
            #expect(throws: ProvingInputError.relyingPartyIdentifierMalformed,
                    "\(identifier.count) characters") {
                _ = try ProvingInputs(certificateBase64: Fixture.certificate(),
                                      signedResponse: Fixture.signature(),
                                      relyingPartyIdentifier: identifier,
                                      challenge: .fromVerifier(Fixture.verifierChallenge))
            }
        }
    }

    @Test func defaultsToTheBondsRelyingPartyIdentifier() throws {
        let inputs = try ProvingInputs(certificateBase64: Fixture.certificate(),
                                       signedResponse: Fixture.signature(),
                                       challenge: .fromVerifier(Fixture.verifierChallenge))
        #expect(inputs.relyingPartyIdentifier == TWFidOConfiguration.bondsAppID)
    }

    // MARK: The challenge

    /// Circom inputs are decimal strings. The reference server returns `"123"`
    /// and upstream's own test passes a 37-digit number.
    @Test func convertsAChallengeToADecimalFieldElement() throws {
        let vectors: [(Data, String)] = [
            (Data(repeating: 0xFF, count: 16), "340282366920938463463374607431768211455"),
            (Data([0, 0, 0, 0, 0, 0, 1, 0]), "256"),
            (Data([0x01] + [UInt8](repeating: 0, count: 15)),
             "1329227995784915872903807060280344576"),
            (Data(repeating: 0xFF, count: 31),
             "452312848583266388373324160190187140051835877600158453279131187530910662655")
        ]
        for (bytes, expected) in vectors {
            let challenge = ProofChallenge.fromVerifier(Fixture.base64URL(bytes))
            #expect(try challenge.fieldElement() == expected)
        }
    }

    /// NIST SP 800-63B's floor for a nonce. Below it the replay defence is
    /// decoration, and a proof bound to a one-byte challenge would look exactly
    /// like a proof bound to a real one.
    @Test func refusesAChallengeWithTooLittleEntropy() {
        #expect(throws: ProvingInputError.challengeTooShort(byteCount: 4)) {
            _ = try ProofChallenge.fromVerifier(Fixture.base64URL(Data([0, 0, 0, 1]))).fieldElement()
        }
    }

    /// 31 bytes is the widest value guaranteed to be a valid BN254 scalar
    /// without a modular reduction. A longer one could be folded in — SHA-256
    /// truncated is the obvious way — but that transform has to be agreed with
    /// whoever checks the proof, so this refuses rather than inventing one.
    ///
    /// ⚠️ `PresentationRequest` allows up to 64 base64url characters (48 bytes),
    /// so a foreign verifier's longer nonce is a request this app can read and
    /// cannot answer with a proof. That gap is real and this test pins it.
    @Test func refusesAChallengeTooWideForTheScalarField() {
        #expect(throws: ProvingInputError.challengeTooLarge(byteCount: 32)) {
            _ = try ProofChallenge
                .fromVerifier(Fixture.base64URL(Data(repeating: 0x11, count: 32)))
                .fieldElement()
        }
    }

    /// Strict base64url. A challenge that half-decodes becomes a *different*
    /// number and the proof binds to that one.
    @Test func refusesAChallengeThatIsNotBase64url() {
        for malformed in ["", "AAAA+AAAAAAA", "AAAA/AAAAAAA", "AAAAAAAAAAA="] {
            #expect(throws: ProvingInputError.challengeMalformed, "\(malformed)") {
                _ = try ProofChallenge.fromVerifier(malformed).fieldElement()
            }
        }
    }

    /// Where the challenge came from travels with it, so a call site cannot pick
    /// the unbound one while the screen claims the bound one.
    @Test func remembersWhetherTheVerifierSuppliedTheChallenge() throws {
        let generated = try ProofChallenge.generate()
        #expect(ProofChallenge.fromVerifier(Fixture.verifierChallenge).boundToVerifier)
        #expect(!ProofChallenge.holderGenerated(Fixture.verifierChallenge).boundToVerifier)
        #expect(!generated.boundToVerifier)
    }

    /// A generated challenge is 16 bytes, matching what a verifier mints, and is
    /// usable as a field element without further work.
    @Test func generatesAChallengeThatIsAlreadyAValidFieldElement() throws {
        let challenge = try ProofChallenge.generate()
        let element = try challenge.fieldElement()
        let second = try ProofChallenge.generate()
        let allDigits = element.allSatisfy { $0.isNumber }
        #expect(!element.isEmpty)
        #expect(allDigits)
        #expect(second.base64URL != challenge.base64URL)
    }

    /// The real call shape: a verifier's `PresentationRequest` on one side, the
    /// 行動自然人憑證 round trip on the other.
    @Test func acceptsAChallengeTakenStraightFromAPresentationRequest() throws {
        let request = try PresentationRequest.generate(purpose: "臨櫃身分查驗")
        let result = TWFidOSignResult(cert: Fixture.certificate(),
                                      signedResponse: Fixture.signature(),
                                      hashedIDNumber: "d0d0deadbeef")
        let inputs = try ProvingInputs(signResult: result,
                                       challenge: .fromVerifier(request.challenge))

        let element = try inputs.challengeFieldElement()
        #expect(inputs.certificateBase64 == result.cert)
        #expect(inputs.signedResponse == result.signedResponse)
        #expect(inputs.challenge.boundToVerifier)
        #expect(!element.isEmpty)
    }

    // MARK: Redaction

    /// `print(inputs)`, `String(reflecting:)`, `dump` and `%@` all reach for one
    /// of these two, and the synthesised versions print every stored property —
    /// which here is a national-ID certificate and a signature over it.
    @Test func keepsTheCardholderMaterialOutOfItsOwnDescription() throws {
        let result = TWFidOSignResult(cert: Fixture.certificate(),
                                      signedResponse: Fixture.signature(),
                                      hashedIDNumber: "d0d0deadbeef")
        let inputs = try ProvingInputs(signResult: result,
                                       challenge: .fromVerifier(Fixture.verifierChallenge))

        for rendering in ["\(inputs)", String(reflecting: inputs), String(describing: inputs)] {
            #expect(!rendering.contains(result.cert))
            #expect(!rendering.contains(result.signedResponse))
            #expect(!rendering.contains(result.hashedIDNumber))
            // Something useful is still said, so redaction does not push people
            // back towards printing the fields individually.
            #expect(rendering.contains("redacted"))
        }
    }
}

// MARK: - Fake backend

/// Stands in for OpenACSwift. Records what it was asked for, produces the files
/// the real one produces, and fails on demand.
private final class FakeProofBackend: ProofBackend, @unchecked Sendable {

    struct Recorded: Equatable {
        let certificateBase64: String
        let signedResponse: String
        let relyingPartyIdentifier: String
        let issuerCertificatePath: String
        let revocationSnapshotPath: String?
        let outputDirectory: String
        let challenge: String
    }

    /// Everything a test might want to change, in one value so the fake itself
    /// has no mutable configuration to race on.
    ///
    /// Every property carries an explicit default so the synthesised memberwise
    /// initialiser gives every parameter one, and a test can name only the knob
    /// it cares about.
    struct Plan {
        var generateFailure: ProofBackendFailure? = nil
        var certChainFailure: ProofBackendFailure? = nil
        var userSigFailure: ProofBackendFailure? = nil
        /// Throws something that is not a `ProofBackendFailure` or a
        /// `ZkProofError`, i.e. what a Rust panic looks like from here.
        var certChainThrowsForeignError = false
        var writesInputFiles = true
        var revocationRoot = "1833847592037465028374651029384756102938475610293847561029384756102"
        /// Overrides the generated `cert_chain_rs4096_input.json` body wholesale.
        var inputFileContents: Data? = nil
        var certificateChain = Plan.defaultCertificateChain
        var userSignature = Plan.defaultUserSignature
        /// Held during `generateInputs`, so a test can observe a proof in flight.
        var gate: DispatchSemaphore? = nil

        static let defaultCertificateChain = ProofMetrics(proveMilliseconds: 31_000,
                                                          proofByteCount: 12_345)
        static let defaultUserSignature = ProofMetrics(proveMilliseconds: 5_000,
                                                       proofByteCount: 6_789)
    }

    private struct ForeignError: Error {}

    private let plan: Plan
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _recorded: Recorded?
    private var _provedDocumentsPaths: [String] = []
    private var _wroteWitnesses = false

    init(plan: Plan) {
        self.plan = plan
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var recorded: Recorded? {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    var provedDocumentsPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _provedDocumentsPaths
    }

    var wroteWitnesses: Bool {
        lock.lock(); defer { lock.unlock() }
        return _wroteWitnesses
    }

    func generateInputs(certificateBase64: String,
                        signedResponse: String,
                        relyingPartyIdentifier: String,
                        issuerCertificatePath: String,
                        revocationSnapshotPath: String?,
                        outputDirectory: String,
                        challenge: String) throws {
        lock.lock()
        _calls.append("generateInputs")
        _recorded = Recorded(certificateBase64: certificateBase64,
                             signedResponse: signedResponse,
                             relyingPartyIdentifier: relyingPartyIdentifier,
                             issuerCertificatePath: issuerCertificatePath,
                             revocationSnapshotPath: revocationSnapshotPath,
                             outputDirectory: outputDirectory,
                             challenge: challenge)
        lock.unlock()

        plan.gate?.wait()

        if let failure = plan.generateFailure { throw failure }
        guard plan.writesInputFiles else { return }

        let directory = URL(fileURLWithPath: outputDirectory)
        // The real file carries the cardholder's certificate expanded into
        // limbs; carrying it verbatim here is what makes the deletion tests mean
        // something.
        let certChain = plan.inputFileContents ?? Self.encode([
            "smtRoot": plan.revocationRoot,
            "smtIsOld0": "1",
            "certb64": certificateBase64
        ])
        try certChain.write(to: directory.appendingPathComponent("cert_chain_rs4096_input.json"))
        try Self.encode(["challenge": challenge, "signedResponse": signedResponse])
            .write(to: directory.appendingPathComponent("user_sig_rs2048_input.json"))
    }

    func proveCertificateChain(documentsPath: String) throws -> ProofMetrics {
        try record(circuit: "cert_chain_rs4096", documentsPath: documentsPath)
        if plan.certChainThrowsForeignError { throw ForeignError() }
        if let failure = plan.certChainFailure { throw failure }
        return plan.certificateChain
    }

    func proveUserSignature(documentsPath: String) throws -> ProofMetrics {
        try record(circuit: "user_sig_rs2048", documentsPath: documentsPath)
        if let failure = plan.userSigFailure { throw failure }
        return plan.userSignature
    }

    /// Writes what the real prover writes: proof, public instance, and the
    /// witness that must not survive.
    private func record(circuit: String, documentsPath: String) throws {
        lock.lock()
        _calls.append(circuit)
        _provedDocumentsPaths.append(documentsPath)
        _wroteWitnesses = true
        lock.unlock()

        let keys = URL(fileURLWithPath: documentsPath).appendingPathComponent("keys",
                                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try Data("proof".utf8).write(to: keys.appendingPathComponent("\(circuit)_proof.bin"))
        try Data("instance".utf8).write(to: keys.appendingPathComponent("\(circuit)_instance.bin"))
        try Data("every private input, in the clear".utf8)
            .write(to: keys.appendingPathComponent("\(circuit)_witness.bin"))
    }

    private static func encode(_ object: [String: String]) -> Data {
        // Force-tries over a dictionary of strings built in this file.
        try! JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - Fixture

/// A throwaway working directory prepared the way the readiness flow leaves it,
/// plus a prover wired to a fake.
///
/// A class rather than a struct so `deinit` can take the directory away again;
/// Swift Testing builds a fresh instance per `@Test`, so each one is isolated.
private final class Fixture: @unchecked Sendable {

    let directory: URL
    let backend: FakeProofBackend
    let inputs: ProvingInputs
    private let readiness: ZKAssetReadiness

    /// A stand-in for a verifier's nonce: 16 bytes, base64url, as
    /// `PresentationRequest` mints them.
    static let verifierChallenge = Fixture.base64URL(Data((1...16).map { UInt8($0) }))

    init(plan: FakeProofBackend.Plan = .init(),
         readiness: ZKAssetReadiness = .ready,
         installIssuerCertificate: Bool = true,
         installSnapshot: Bool = true,
         challenge: ProofChallenge = .fromVerifier(Fixture.verifierChallenge)) throws {

        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZKProverTests-\(UUID().uuidString)", isDirectory: true)
        // Created plainly and without the backup exclusion, so that anything
        // asserted about protection afterwards came from `ZKProver`.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("keys"),
                                                withIntermediateDirectories: true)

        if installIssuerCertificate {
            try Data([0x30, 0x82, 0x06, 0x67]).write(to: directory
                .appendingPathComponent(CircuitAssets.issuerCertificateFilename))
        }
        if installSnapshot {
            try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: directory
                .appendingPathComponent(ZKProver.revocationSnapshotFilename))
        }

        backend = FakeProofBackend(plan: plan)
        self.readiness = readiness
        inputs = try ProvingInputs(certificateBase64: Fixture.certificate(),
                                   signedResponse: Fixture.signature(),
                                   challenge: challenge)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func prover() -> ZKProver {
        let readiness = self.readiness
        return ZKProver(workingDirectory: directory,
                        readiness: { readiness },
                        backend: backend)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
    }

    func write(_ relativePath: String, _ data: Data) throws {
        try data.write(to: directory.appendingPathComponent(relativePath))
    }

    // MARK: Material

    /// A DER `SEQUENCE` header and filler. Nothing real: every check this module
    /// performs on the certificate is structural, and a genuine 行動自然人憑證
    /// carries a living person's name and 身分證統一編號, which has no business
    /// in a test fixture.
    static func certificate() -> String {
        (Data([0x30, 0x82, 0x01, 0x00]) + Data(repeating: 0xA5, count: 60)).base64EncodedString()
    }

    /// PKCS#1 over RSA-2048 is exactly 256 bytes.
    static func signature(byteCount: Int = 256) -> String {
        Data(repeating: 0xAB, count: byteCount).base64EncodedString()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
