import Testing
import ThinktinKit

@testable import ThinktinUI

/// 状态点的颜色规则（docs/ios.md 第 4 节）和状态名。
@Suite("状态点")
struct StatusAppearanceTests {
    @Test("运行状态的色调")
    func runStateTones() {
        let expected: [RunState: StatusTone] = [
            .queued: .neutral, .starting: .neutral, .running: .active,
            .waitingApproval: .waiting, .waitingDevice: .waiting, .waitingQuota: .waiting, .waitingChildren: .waiting,
            .backoff: .neutral, .succeeded: .success, .failed: .failure, .cancelled: .muted,
        ]
        #expect(Set(expected.keys) == Set(RunState.knownCases))
        for (state, tone) in expected {
            #expect(state.statusAppearance.tone == tone, "\(state)")
        }
        #expect(RunState.unknown("paused_by_admin").statusAppearance.tone == .neutral)
    }

    @Test("等待类状态都用警告色，和 RunState.isWaiting 一致")
    func waitingMatchesModel() {
        for state in RunState.knownCases {
            #expect((state.statusAppearance.tone == .waiting) == state.isWaiting, "\(state)")
        }
    }

    @Test("只有正在进行的状态在动")
    func pulsing() {
        #expect(RunState.knownCases.filter(\.statusAppearance.pulses) == [.starting, .running])
        #expect(InstanceState.knownCases.filter(\.statusAppearance.pulses) == [.provisioning, .running])
        #expect(InstanceState.knownCases.filter(\.statusAppearance.isHollow) == [.archived])
    }

    @Test("实例状态的色调")
    func instanceStateTones() {
        let expected: [InstanceState: StatusTone] = [
            .provisioning: .neutral, .running: .active, .paused: .muted, .archived: .muted, .deleted: .muted,
        ]
        #expect(Set(expected.keys) == Set(InstanceState.knownCases))
        for (state, tone) in expected {
            #expect(state.statusAppearance.tone == tone, "\(state)")
        }
        #expect(InstanceState.unknown("migrating").statusAppearance.tone == .neutral)
    }

    @Test("状态名：中英文都有，同一语言里不重复", arguments: DisplayLanguage.allCases)
    func names(_ language: DisplayLanguage) {
        let runNames = RunState.knownCases.map { $0.localizedName(language) }
        #expect(runNames.allSatisfy { !$0.isEmpty })
        #expect(Set(runNames).count == runNames.count)
        let instanceNames = InstanceState.knownCases.map { $0.localizedName(language) }
        #expect(instanceNames.allSatisfy { !$0.isEmpty })
        #expect(Set(instanceNames).count == instanceNames.count)
    }

    @Test("中文状态名")
    func chineseNames() {
        #expect(RunState.running.localizedName(.chinese) == "运行中")
        #expect(RunState.waitingQuota.localizedName(.chinese) == "等待 key")
        #expect(InstanceState.archived.localizedName(.chinese) == "已归档")
        #expect(RunState.unknown("x").localizedName(.english) == "Unknown")
    }
}
