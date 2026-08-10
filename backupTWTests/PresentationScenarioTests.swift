//
//  PresentationScenarioTests.swift
//  backupTWTests
//

import Testing
@testable import backupTW

@Suite("示範場景的能力宣告")
struct PresentationScenarioTests {

    /// The demo is where a hedge is least welcome and a green tick is most
    /// persuasive, so the claim that only one of the three scenarios is fully
    /// supported is pinned. If a later change makes two of them `.supported`,
    /// that should be because the circuits changed — and this test failing is
    /// the prompt to check which.
    @Test("三個場景裡只有一個是完全成立的")
    func onlyOneScenarioIsFullySupported() {
        let supported = PresentationScenario.all.filter { $0.support.isSupported }
        #expect(supported.map(\.id) == ["was-taiwanese"],
                "完全成立的場景變了：\(supported.map(\.id))")
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
