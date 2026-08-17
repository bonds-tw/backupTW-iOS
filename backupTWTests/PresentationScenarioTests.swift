//
//  PresentationScenarioTests.swift
//  backupTWTests
//

import Testing
@testable import backupTW

@Suite("示範場景的能力宣告")
struct PresentationScenarioTests {

    /// # This test used to hold the bug in place
    ///
    /// It asserted `supported.map(\.id) == ["was-taiwanese"]` — the page's one
    /// green tick — and its comment said a change here "should be because the
    /// circuits changed". The circuits never claimed it. `wasTaiwanese`'s
    /// request has 「你」 as its subject, while the first caveat it carries says
    /// the signing material never changes and never expires, so anybody who has
    /// held it once can make the same proof with the holder absent.
    ///
    /// So the rule replaces the roll-call. A scenario whose caveats say the
    /// proof can be made without the holder cannot answer a request about the
    /// holder as stated. Pinning the rule instead of the list means a fourth
    /// scenario is checked the day it is written.
    @Test("宣稱完全成立的場景，不能同時帶著『不必你在場』的但書")
    func nothingClaimsMoreThanItsOwnCaveatsAllow() {
        for scenario in PresentationScenario.all where scenario.support.isSupported {
            #expect(!scenario.caveats.contains(.signatureMaterialIsReplayable),
                    "\(scenario.id) 說完全做得到，但它自己的但書說不必持卡人在場")
        }
    }

    /// And, as of today, that leaves none of them fully supported.
    ///
    /// Recorded separately from the rule above so the two failures read
    /// differently: this one turning red means the table gained a full answer,
    /// which is news worth reading rather than a regression.
    @Test("目前三個場景沒有一個是完全成立的")
    func noScenarioIsFullySupportedToday() {
        let supported = PresentationScenario.all.filter { $0.support.isSupported }
        #expect(supported.isEmpty, "有場景升級成完全成立了：\(supported.map(\.id))")
    }

    /// The gate, at the table level.
    ///
    /// Both factories are `#if DEBUG`, so a shipped build has neither path — and
    /// until now the table did not ask. Tests all run with `DEBUG` set, which is
    /// exactly why `support(in:)` takes the paths rather than reading them.
    @Test("這個 build 沒有的路徑，答案一律降成做不到")
    func aPathThisBuildLacksCannotAnswerAnything() {
        let none = BuildPaths(credential: false, zeroKnowledge: false)
        for scenario in PresentationScenario.all {
            guard case .unsupported(let blockedBy) = scenario.support(in: none) else {
                Issue.record("\(scenario.id) 仍宣稱做得到，但這個 build 沒有那條路")
                continue
            }
            #expect(!blockedBy.isEmpty)
        }
        // And the ungated table is untouched by the gate.
        for scenario in PresentationScenario.all {
            #expect(scenario.support(in: .complete) == scenario.support)
        }
    }

    /// Each path is gated by its own switch, not by both together.
    @Test("兩條路各自由自己的開關擋")
    func eachPathIsGatedByItsOwnSwitch() {
        let zkOnly = BuildPaths(credential: false, zeroKnowledge: true)
        #expect(PresentationScenario.wasTaiwanese.support(in: zkOnly)
                == PresentationScenario.wasTaiwanese.support)
        guard case .unsupported = PresentationScenario.ageOver18.support(in: zkOnly) else {
            Issue.record("憑證那條路沒被自己的開關擋下")
            return
        }
    }

    /// 滿 18 歲 is answerable on the credential path, and this test is a
    /// correction of its own earlier self.
    ///
    /// It used to assert `.unsupported`, on the reasoning that the circuits take
    /// no date — which is true, and which is a fact about the *circuits*. The
    /// test encoded the conflation along with the claim, so the wrong answer had
    /// a green tick holding it in place. The predicate is derived at issuance,
    /// signed by the card with every other field, and disclosed on its own.
    ///
    /// It stays `.partial` rather than `.supported` because the remaining gap is
    /// real: the presentation carries a linkable identifier, so this is minimal
    /// disclosure of the field and not anonymity.
    @Test("滿 18 歲做得到，但要說清楚不是匿名")
    func ageIsPartiallySupportedAndSaysWhy() throws {
        guard case .partial(let actually) = PresentationScenario.ageOver18.support else {
            Issue.record("滿 18 歲現在做得到——發證時推導、行憑簽、選擇性揭露")
            return
        }
        #expect(actually.count > 40, "說明太短，讀的人無從判斷剩下的限制是什麼")
        // The one thing this scenario must not let a reader forget.
        #expect(actually.contains("同一個人") || actually.lowercased().contains("same person"),
                "沒講到可連結性，就會被讀成匿名")
    }

    /// The "and only once" half is the part a demo would quietly drop.
    @Test("真人且唯一只承認做到一半")
    func uniquenessIsOnlyPartial() throws {
        guard case .partial(let actually) = PresentationScenario.uniquePerson.support else {
            Issue.record("唯一性不是離線做得到的事——noGlobalUniqueness")
            return
        }
        #expect(!actually.isEmpty)
    }

    /// Every scenario answered by a proof carries the full unconditional set.
    /// A scenario that quietly shortened the list would be the same defect as a
    /// screen that hid a caveat.
    @Test("凡是走 ZK 的場景都帶著全部無條件 caveat")
    func zkScenariosCarryEveryUnconditionalCaveat() {
        for scenario in PresentationScenario.all where scenario.path == .zeroKnowledge {
            for caveat in ProofCaveat.unconditional {
                #expect(scenario.caveats.contains(caveat),
                        "\(scenario.id) 少了 \(caveat.rawValue)")
            }
        }
    }
}
