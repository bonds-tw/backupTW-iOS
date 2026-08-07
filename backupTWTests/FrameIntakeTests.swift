//
//  FrameIntakeTests.swift
//  backupTWTests
//

import Foundation
import Testing
@testable import backupTW

/// The checker's scanning loop, at the layer where a `FrameCollector` meets a
/// camera pointed at a queue of people.
///
/// `QRTransportTests` owns the collector's own rules and is deliberately not
/// repeated here. What is here is the one thing the collector cannot decide for
/// itself: which of its refusals mean "this is a different document now" and are
/// therefore recoverable by starting over.
///
/// The case that motivated the file is `recoversWhenTheDocumentInFrontOfTheCameraChanges`.
/// Without a reset on `frameFromAnotherPresentation`, the collector that took a
/// single frame from the person who has already walked away refuses every frame
/// of everyone behind them, permanently, while the screen advises the one action
/// — 「請對方從第一張重新出示」 — that cannot possibly clear it. That is a scanner
/// that looks like it is working and is not, which is the failure mode this app
/// can least afford at a counter.
struct FrameIntakeTests {

    // MARK: - Fixtures

    /// Deterministic bytes DEFLATE cannot shrink, so payload size maps straight
    /// onto frame count and a failure is reproducible. Seeded LCG, multiplier
    /// and increment from Numerical Recipes.
    private static func incompressible(_ count: Int, seed: UInt32) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
    }

    /// A multi-frame document. 1200 incompressible bytes is comfortably more
    /// than one frame holds, which is what makes the interleaving below
    /// realistic — the single-frame case cannot reproduce it.
    private static func document(seed: UInt32) throws -> (payload: Data, frames: [String]) {
        let payload = incompressible(1200, seed: seed)
        return (payload, try QRTransport.frames(for: payload))
    }

    /// Rewrites the frame-count field in place. The two digits sit immediately
    /// before the header's final separator, derived from `headerLength` rather
    /// than hardcoded so this breaks loudly if the wire format moves.
    private static func rewritingFrameCount(_ frame: String, to count: String) -> String {
        var characters = Array(frame)
        let digits = Array(count)
        characters[QRTransport.headerLength - 3] = digits[0]
        characters[QRTransport.headerLength - 2] = digits[1]
        return String(characters)
    }

    // MARK: - Changing documents mid-scan

    /// The reported defect, in the order it happens at a counter: one frame from
    /// the person in front, then the whole of the next person's document.
    ///
    /// The measured behaviour before the fix was that *every* frame of B threw,
    /// for as long as B was shown — replaying the entire carousel any number of
    /// times could not complete it.
    @Test func recoversWhenTheDocumentInFrontOfTheCameraChanges() throws {
        let a = try Self.document(seed: 0x1234_5678)
        let b = try Self.document(seed: 0x0BAD_C0DE)
        #expect(a.frames.count > 1)
        #expect(b.frames.count > 1)
        #expect(a.payload != b.payload)

        let collector = FrameCollector()
        #expect(FrameIntake.accept(a.frames[0], into: collector)
                == .progress(FrameCollector.Progress(received: 1, total: a.frames.count)))

        var completed: Data?
        for frame in b.frames {
            if case .payload(let data) = FrameIntake.accept(frame, into: collector) { completed = data }
        }
        #expect(completed == b.payload)
    }

    /// The count on screen has to start climbing on the *first* frame of the new
    /// document, not on the carousel's next pass. A frame that is dropped rather
    /// than re-offered leaves 「已讀取 0／3 張」 sitting there for another two
    /// seconds, which is where a verifier decides the app is broken.
    @Test func theFrameThatChangedTheDocumentIsCountedRatherThanDropped() throws {
        let a = try Self.document(seed: 0x1111_1111)
        let b = try Self.document(seed: 0x2222_2222)

        let collector = FrameCollector()
        _ = FrameIntake.accept(a.frames[0], into: collector)

        #expect(FrameIntake.accept(b.frames[0], into: collector)
                == .progress(FrameCollector.Progress(received: 1, total: b.frames.count)))
    }

    /// Half of A, then all of B. The partial collection is discarded rather than
    /// merged — merging chunks from two documents is what the digest check exists
    /// to catch, and it must never get the chance.
    @Test func doesNotMixTheDocumentItWasHoldingIntoTheOneItFinishes() throws {
        let a = try Self.document(seed: 0x3333_3333)
        let b = try Self.document(seed: 0x4444_4444)

        let collector = FrameCollector()
        for frame in a.frames.dropLast() {
            _ = FrameIntake.accept(frame, into: collector)
        }

        var completed: Data?
        for frame in b.frames {
            if case .payload(let data) = FrameIntake.accept(frame, into: collector) { completed = data }
        }
        #expect(completed == b.payload)
        #expect(completed != a.payload)
    }

    /// Same identifier, disagreeing header. Unlike the case above this is either
    /// a truncated-digest collision or an edited frame, and it wedged the
    /// collector in exactly the same way.
    @Test func recoversFromAFrameWhoseHeaderDisagreesWithTheOnesHeld() throws {
        let a = try Self.document(seed: 0x5555_5555)
        #expect(a.frames.count > 1)

        let collector = FrameCollector()
        _ = FrameIntake.accept(a.frames[0], into: collector)

        let miscounted = Self.rewritingFrameCount(a.frames[1], to: "99")
        #expect(FrameIntake.accept(miscounted, into: collector)
                == .progress(FrameCollector.Progress(received: 1, total: 99)))
    }

    // MARK: - What must *not* restart a scan

    /// A restart is cheap but not free: it costs the verifier a whole pass of the
    /// carousel. Anything that is merely *noise* has to leave the collection
    /// alone, and at a counter there is a great deal of noise.
    @Test(arguments: ["WIFI:S=counter;T=WPA;P=hunter2;;",
                      "https://gov.tw",
                      "BTWVP2:U:A1B2C3D4E5:00:01:BB8"])
    func aCodeThatIsNotOurCurrentDocumentDoesNotDiscardProgress(_ noise: String) throws {
        let a = try Self.document(seed: 0x6666_6666)

        let collector = FrameCollector()
        _ = FrameIntake.accept(a.frames[0], into: collector)
        _ = FrameIntake.accept(noise, into: collector)

        #expect(FrameIntake.accept(a.frames[1], into: collector)
                == .progress(FrameCollector.Progress(received: 2, total: a.frames.count)))
    }

    /// A chunk that will not decode is a smudge, a fold, or a glare — not a
    /// different document. It gets a sentence and keeps what is in hand.
    @Test func aChunkThatWillNotDecodeIsReportedWithoutDiscardingProgress() throws {
        let a = try Self.document(seed: 0x7777_7777)

        let collector = FrameCollector()
        _ = FrameIntake.accept(a.frames[0], into: collector)

        // A base45 group past 0xFFFF: right scheme, right shape, impossible value.
        #expect(FrameIntake.accept("BTWVP1:U:A1B2C3D4E5:00:01:00X", into: collector) == .unreadable)

        #expect(FrameIntake.accept(a.frames[1], into: collector)
                == .progress(FrameCollector.Progress(received: 2, total: a.frames.count)))
    }

    /// Foreign codes fire once per video frame. They must be silent, or the
    /// status line strobes for the entire scan.
    @Test func aForeignCodeSaysNothingAtAll() throws {
        #expect(FrameIntake.accept("WIFI:S=counter;T=WPA;P=hunter2;;", into: FrameCollector()) == .ignored)
    }

    /// The same code, dozens of times a second, for as long as it is held up.
    @Test func repeatsOfAFrameAlreadyHeldDoNotMoveTheCount() throws {
        let a = try Self.document(seed: 0x8888_8888)

        let collector = FrameCollector()
        for _ in 0..<8 {
            #expect(FrameIntake.accept(a.frames[0], into: collector)
                    == .progress(FrameCollector.Progress(received: 1, total: a.frames.count)))
        }
    }

    // MARK: - The ordinary path

    @Test func handsBackThePayloadOnTheLastFrame() throws {
        let a = try Self.document(seed: 0x9999_9999)

        let collector = FrameCollector()
        var results: [ScannedFrame] = []
        for frame in a.frames {
            results.append(FrameIntake.accept(frame, into: collector))
        }
        #expect(results.dropLast().allSatisfy { if case .progress = $0 { return true } else { return false } })
        #expect(results.last == .payload(a.payload))
    }

    /// The holder cannot know the scan succeeded, so the carousel plays on. Late
    /// frames keep answering with the payload rather than turning a finished
    /// check into an error.
    @Test func keepsAnsweringWhileTheCarouselPlaysOn() throws {
        let a = try Self.document(seed: 0xAAAA_AAAA)

        let collector = FrameCollector()
        for frame in a.frames { _ = FrameIntake.accept(frame, into: collector) }

        for frame in a.frames {
            #expect(FrameIntake.accept(frame, into: collector) == .payload(a.payload))
        }
    }
}
