import Foundation
import Testing

@testable import ThinktinKit

// 12.3 的命名（商标要求）和文案。

@Suite("Agent 目录的命名与文案")
struct AgentsTextTests {
    @Test("Claude 一律叫 Claude Agent，不叫 Claude Code")
    func claudeNaming() {
        let claudeCode = AgentsFixture.agent("claude", name: "Claude Code")
        #expect(AgentsText.displayName(of: claudeCode) == "Claude Agent")
        #expect(AgentsText.displayName(agentID: "claude") == "Claude Agent")
        // 别的 agent 名字里写了 Claude Code 的也换掉。
        let wrapper = AgentsFixture.agent("helper", name: "My claude code helper")
        #expect(AgentsText.displayName(of: wrapper) == "My Claude Agent helper")
        // 演示目录里的名字原样（服务端已经叫 Claude Agent）。
        #expect(DemoData.agents.map(AgentsText.displayName(of:)) == ["Claude Agent", "Codex", "Hermes Agent"])
    }

    @Test("没有名字时按 id 认，认不出的用 id")
    func fallbackNames() {
        #expect(AgentsText.displayName(agentID: "codex") == "Codex")
        #expect(AgentsText.displayName(agentID: "openclaw", serverName: "  ") == "OpenClaw")
        #expect(AgentsText.displayName(agentID: "mystery") == "mystery")
        #expect(AgentsText.displayName(agentID: "mystery", serverName: " Mystery Agent ") == "Mystery Agent")
    }

    @Test("出处说明：Claude 写 Agent SDK，Codex 写“使用 OpenAI Codex”，别的没有")
    func bylines() {
        #expect(AgentsText.byline(of: "codex", language: .chinese) == "使用 OpenAI Codex")
        #expect(AgentsText.byline(of: "codex", language: .english) == "Uses OpenAI Codex")
        let claude = AgentsText.byline(of: "claude", language: .chinese) ?? ""
        #expect(claude.contains("Claude Agent SDK"))
        #expect(!claude.contains("Claude Code"))
        #expect(AgentsText.byline(of: "hermes") == nil)
    }

    @Test("头像用名字的第一个字，不用对方的标志")
    func monogram() {
        #expect(AgentsText.monogram(of: "写作助手") == "写")
        #expect(AgentsText.monogram(of: " codex") == "C")
        #expect(AgentsText.monogram(of: "") == "?")
    }

    @Test("版本、许可证、接入方式、协议、地区的显示名")
    func labels() {
        #expect(AgentsText.versionLabel("0.90.0") == "v0.90.0")
        #expect(AgentsText.versionLabel("nightly") == "nightly")

        #expect(AgentsText.licenseName("MIT") == "MIT")
        #expect(AgentsText.licenseName(nil, language: .chinese) == "未注明许可证")
        #expect(AgentsText.licenseName("", language: .english) == "License not specified")
        #expect(AgentsText.licenseName("LicenseRef-Anthropic-Commercial", language: .chinese).contains("专有"))
        #expect(AgentsText.licenseName("LicenseRef-Acme", language: .english) == "Proprietary license")
        #expect(AgentsText.isProprietary("LicenseRef-Anthropic-Commercial"))
        #expect(!AgentsText.isProprietary("Apache-2.0"))
        #expect(!AgentsText.isProprietary(nil))

        #expect(AgentsText.harnessName("acp", language: .chinese) == "ACP 适配器")
        #expect(AgentsText.harnessName("cli", language: .english) == "Command line")
        #expect(AgentsText.harnessName("grpc") == "grpc")
        #expect(AgentsText.harnessDetail("acp") != nil)
        #expect(AgentsText.harnessDetail("grpc") == nil)
        // 接入方式的说明里不出现 Claude Code。
        for language in DisplayLanguage.allCases {
            for harness in ["acp", "cli"] {
                #expect(!(AgentsText.harnessDetail(harness, language: language) ?? "").contains("Claude Code"))
            }
        }

        #expect(AgentsText.protocolName(.anthropic) == "Anthropic Messages")
        #expect(AgentsText.protocolName(.responses) == "OpenAI Responses")
        #expect(AgentsText.protocolName(.unknown("gemini")) == "gemini")
        #expect(AgentsText.siteName("cn", language: .chinese) == "中国大陆")
        #expect(AgentsText.siteName("mars") == "mars")
        #expect(AgentsText.list(["a", "b"], language: .chinese) == "a、b")
        #expect(AgentsText.list(["a", "b"], language: .english) == "a, b")
    }

    @Test("每个实例状态都有中英文说明")
    func stateExplanations() {
        for state in InstanceState.knownCases + [.unknown("frozen")] {
            let zh = AgentsText.stateExplanation(state, language: .chinese)
            let en = AgentsText.stateExplanation(state, language: .english)
            #expect(!zh.isEmpty && !en.isEmpty && zh != en)
        }
        #expect(AgentsText.stateExplanation(.archived, language: .chinese).contains("重建"))
        #expect(AgentsText.stateExplanation(.paused, language: .english).contains("snapshot"))
    }

    @Test("agent 建的计划带 AI 生成标识，用户建的不带")
    func aiLabelRule() {
        var plan = AgentsFixture.pipelinePlan
        #expect(AgentsText.isAIGenerated(plan))
        plan.createdBy = .user
        #expect(!AgentsText.isAIGenerated(plan))
    }

    @Test("实例名字：去掉首尾空白后 1 到 64 个字符（按 Unicode 标量数）")
    func nameRule() {
        #expect(InstanceNameRule.problem("   ") == .empty)
        #expect(InstanceNameRule.problem(" 写作助手 ") == nil)
        #expect(InstanceNameRule.problem(String(repeating: "a", count: 64)) == nil)
        #expect(InstanceNameRule.problem(String(repeating: "a", count: 65)) == .tooLong(max: 64))
        // 32 个带肤色的表情是 32 个字、64 个标量：刚好；33 个超了。
        #expect(InstanceNameRule.problem(String(repeating: "👍🏽", count: 32)) == nil)
        #expect(InstanceNameRule.problem(String(repeating: "👍🏽", count: 33)) == .tooLong(max: 64))
        #expect(InstanceNameRule.normalized("  a b \n") == "a b")
        #expect(InstanceNameProblem.empty.message(.chinese) != InstanceNameProblem.empty.message(.english))
        #expect(InstanceNameProblem.tooLong(max: 64).message(.chinese).contains("64"))
    }
}
