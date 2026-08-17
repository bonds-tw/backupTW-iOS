//
//  LinkVocabularyTests.swift
//  backupTWTests
//
//  The transport does not get to decide what the bytes are called, or who is
//  being told to scan.
//

import Testing
@testable import backupTW

/// # Two phones, two instructions, nobody moving
///
/// One sentence lived in `BluetoothLink` and reached both paths: 「The other phone
/// disconnected before the whole **proof** had been sent. Ask **them** to scan
/// the code again.」
///
/// The noun was wrong on the credential path, which sends a document — and the
/// same object made the mirror mistake, calling a proof 「this document」 on the
/// zero-knowledge send screen.
///
/// The direction was wrong on the zero-knowledge path, where the *checker* draws
/// the pairing code and the *holder* scans it. So the holder — the only person
/// with a scanner in that exchange — was told to ask the other side to scan,
/// while the checker's own screen said 「ask them to scan the code above」.
///
/// The window is real: `LinkCollector.progress` is nil until the first frame and
/// the checker's disconnect handler only speaks when it is non-nil, so a
/// disconnect after subscribing and before frame 0 left one side silent and the
/// other reading somebody else's instruction. It is also the step with no
/// fallback — 400 KB is 824 QR frames at roughly 453 seconds, and `QRTransport`
/// refuses anything over 64 KB.
struct LinkVocabularyTests {

    private static let all: [(String, LinkVocabulary)] = [
        ("credential", .credential), ("proof", .zeroKnowledgeProof),
    ]

    /// The defect that made this type: one string on two screens.
    @Test func noSentenceIsSharedBetweenTheTwoPayloadKinds() {
        let credential = [LinkVocabulary.credential.couldNotPrepare,
                          LinkVocabulary.credential.sendInterrupted,
                          LinkVocabulary.credential.receiveInterrupted]
        let proof = [LinkVocabulary.zeroKnowledgeProof.couldNotPrepare,
                     LinkVocabulary.zeroKnowledgeProof.sendInterrupted,
                     LinkVocabulary.zeroKnowledgeProof.receiveInterrupted]
        #expect(Set(credential).isDisjoint(with: Set(proof)),
                "a sentence is shown on both payload kinds again")
    }

    /// The noun, in whichever language ships.
    @Test func eachKindIsCalledWhatItIs() {
        for sentence in [LinkVocabulary.credential.couldNotPrepare,
                         LinkVocabulary.credential.sendInterrupted,
                         LinkVocabulary.credential.receiveInterrupted] {
            #expect(!sentence.contains("proof") && !sentence.contains("證明"),
                    "the credential path calls its payload a proof: \(sentence)")
        }
        for sentence in [LinkVocabulary.zeroKnowledgeProof.couldNotPrepare,
                         LinkVocabulary.zeroKnowledgeProof.sendInterrupted,
                         LinkVocabulary.zeroKnowledgeProof.receiveInterrupted] {
            #expect(!sentence.contains("document") && !sentence.contains("證件"),
                    "the proof path calls its payload a document: \(sentence)")
        }
    }

    /// The direction. On the zero-knowledge path the person reading the send
    /// failure is the one holding the scanner, so the instruction is to them.
    @Test func theHolderOfTheScannerIsTheOneToldToScan() {
        let sending = LinkVocabulary.zeroKnowledgeProof.sendInterrupted
        for wrong in ["Ask them to scan", "請他重新掃描", "請對方掃描"] where sending.contains(wrong) {
            Issue.record("the zero-knowledge sender is told to ask the other side to scan: \(sending)")
        }
        #expect(sending.contains("Scan the pairing code") || sending.contains("重新掃描他畫面上的配對碼"),
                "the sender is not told to scan: \(sending)")
    }

    /// And on the credential path the fallback that really exists is named.
    @Test func theCredentialPathPointsAtTheCarouselThatIsStillTurning() {
        for sentence in [LinkVocabulary.credential.sendInterrupted,
                         LinkVocabulary.credential.receiveInterrupted] {
            #expect(sentence.contains("codes") || sentence.contains("條碼"),
                    "the credential path forgets it still has a working fallback: \(sentence)")
        }
    }
}
