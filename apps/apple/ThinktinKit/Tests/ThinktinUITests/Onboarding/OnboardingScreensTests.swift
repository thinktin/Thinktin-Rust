import SwiftUI
import Testing
import ThinktinKit

@testable import ThinktinUI

/// 上手引导（WBS 12.17）的界面：新账号、演示账号（只差通知）在浅色中文、深色英文、大字号下都能布局；每一步的卡片。
@MainActor
@Suite("上手引导的界面")
struct OnboardingScreensTests {
    private static func client(empty: Bool) -> MockClient {
        var state = DemoData.state()
        if empty {
            state.instances = []
            state.credentials = []
        }
        return MockClient(state: state, stepDelay: 0)
    }

    @Test("新账号、演示账号都能布局")
    func screens() {
        for empty in [true, false] {
            hostAndLayout(OnboardingDestination(route: .onboarding).previewShell(client: Self.client(empty: empty)))
            hostAndLayout(
                OnboardingDestination(route: .onboarding).previewShell(
                    .english, scheme: .dark, client: Self.client(empty: empty)))
            hostAndLayout(
                OnboardingDestination(route: .onboarding).previewShell(client: Self.client(empty: empty))
                    .dynamicTypeSize(.accessibility3))
        }
    }

    @Test("每一步的卡片：做完、当前、还没到、拒绝过通知")
    func cards() {
        for step in OnboardingStep.allCases {
            for (done, current) in [(true, false), (false, true), (false, false)] {
                let card = OnboardingStepCard(
                    step: step, isDone: done, isCurrent: current, isBusy: false, denied: step == .notifications
                ) {}
                hostAndLayout(card.previewShell())
                hostAndLayout(card.previewShell(.english, scheme: .dark))
            }
        }
    }
}
