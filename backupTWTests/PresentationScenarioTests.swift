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

    /// An age predicate is not provable here, and the reason has to travel with
    /// the refusal — otherwise the next person to read it assumes it is a to-do
    /// rather than a property of the circuits.
    @Test("滿 18 歲被標為做不到，而且說得出為什麼")
    func ageIsUnsupportedWithAReason() throws {
        guard case .unsupported(let reason) = PresentationScenario.ageOver18.support else {
            Issue.record("滿 18 歲不該被標成做得到——電路的輸入裡沒有日期")
            return
        }
        #expect(reason.count > 40, "拒絕的理由太短，讀的人無從判斷這是待辦還是性質")
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
