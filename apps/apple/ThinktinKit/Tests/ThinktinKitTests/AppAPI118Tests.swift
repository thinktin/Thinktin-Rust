import Foundation
import Testing

@testable import ThinktinKit

// 11.8（client-core 补漏）带来的模型和 MockClient 的新方法：等待原因码、模型协议、agent 的介绍与许可说明、
// 跨实例的运行列表、缓存往前翻、Accept-Language、版本太老的标记。规则照 crates/client-core/src/ffi.rs 的注释、
// crates/gateway/src/routes/runs.rs 和 crates/proto/src/domain.rs。

private let writer = DemoData.writerID
private let reviewer = DemoData.reviewerID

private func makeClient(signedIn: Bool = true) -> MockClient {
    MockClient(state: DemoData.state(signedIn: signedIn), stepDelay: 0, autoReply: false)
}

/// 抛出的错误归成几类（只关心是哪一类）。
private enum Failure: Equatable {
    case api(APIErrorCode)
    case invalidArgument
    case other(ClientError)
}

private func failure(_ body: () async throws -> Void) async -> Failure? {
    do {
        try await body()
        return nil
    } catch let e as ClientError {
        switch e {
        case .api(_, let code, _, _): return .api(code)
        case .invalidArgument: return .invalidArgument
        default: return .other(e)
        }
    } catch {
        return .other(.internal(message: "\(error)"))
    }
}

// MARK: - 模型

@Suite("11.8 的模型：等待原因码、模型协议、agent 介绍")
struct Models118Tests {
    @Test("RunWaitCode：取值和服务端的 wait_code 一致；不认识的原样保留；哪些要换 key、哪些自己会好")
    func waitCodes() {
        let raw = RunWaitCode.knownCases.map(\.rawValue)
        #expect(raw == ["invalid", "no_balance", "unavailable", "rate_limited", "overloaded", "device_offline"])
        for code in RunWaitCode.knownCases {
            #expect(RunWaitCode(rawValue: code.rawValue) == code)
        }
        #expect(RunWaitCode(rawValue: "future_thing") == .unknown("future_thing"))
        #expect(!RunWaitCode(rawValue: "future_thing").isKnown)

        #expect(RunWaitCode.knownCases.filter(\.needsKeyAction) == [.invalid, .noBalance, .unavailable])
        #expect(RunWaitCode.knownCases.filter(\.isTransient) == [.rateLimited, .overloaded])
        #expect(!RunWaitCode.deviceOffline.needsKeyAction && !RunWaitCode.deviceOffline.isTransient)
        #expect(!RunWaitCode.unknown("x").needsKeyAction && !RunWaitCode.unknown("x").isTransient)

        #expect(RunState.knownCases.filter { RunWaitCode.applies(to: $0) } == [.waitingDevice, .waitingQuota])
    }

    @Test("run.state 的载荷：wait_code 解出来；没有这个键（老的服务端）、不认识的值都不报错；编码用 snake_case")
    func runStatePayload() throws {
        let p = try decode(RunStatePayload.self, #"{"state":"waiting_quota","reason":"欠费","wait_code":"no_balance"}"#)
        #expect(p == RunStatePayload(state: .waitingQuota, reason: "欠费", waitCode: .noBalance))
        let old = try decode(RunStatePayload.self, #"{"state":"waiting_quota","reason":"x","attempt":2}"#)
        #expect(old.waitCode == nil)
        #expect(old.attempt == 2)
        let future = try decode(RunStatePayload.self, #"{"state":"waiting_quota","wait_code":"solar_flare"}"#)
        #expect(future.waitCode == .unknown("solar_flare"))

        #expect(try jsonString(p) == #"{"reason":"欠费","state":"waiting_quota","wait_code":"no_balance"}"#)
        #expect(try jsonString(RunStatePayload(state: .running)) == #"{"state":"running"}"#)

        var events = Events()
        let e = events.add(.runState, Fixture.runA, ["state": "waiting_device", "wait_code": "device_offline"])
        #expect(e.runStatePayload?.waitCode == .deviceOffline)
        guard case .runState(let parsed) = e.payload else {
            Issue.record("应该解析成 runState")
            return
        }
        #expect(parsed.waitCode == .deviceOffline)
    }

    @Test("Run：waitCode 默认 nil，构造器可以给")
    func runWaitCode() {
        #expect(Fixture.run(Fixture.runA).waitCode == nil)
        let run = Run(
            id: Fixture.runA, instanceID: Fixture.instanceID, prompt: "p", state: .waitingQuota,
            createdAt: Fixture.now, waitCode: .invalid)
        #expect(run.waitCode == .invalid)
    }

    @Test("ModelProtocol：三种协议的名字和 VendorInfo.protocols 同一套；顺序是界面上的顺序")
    func modelProtocols() {
        #expect(ModelProtocol.knownCases.map(\.rawValue) == ["anthropic", "chat", "responses"])
        #expect(ModelProtocol(rawValue: "gemini") == .unknown("gemini"))
        let vendor = VendorInfo(id: "v", name: "V", protocols: ["chat", "gemini"], models: [])
        #expect(vendor.modelProtocols == [.chat, .unknown("gemini")])
    }

    @Test("选 key：key 要支持 agent 的 activeProtocol；两边有一边没给协议（老的服务端）时不拦")
    func credentialFiltering() {
        let anthropicOnly = Credential(
            id: "c1", vendor: "anthropic", label: "", last4: "abcd", createdAt: Fixture.now,
            protocols: [.anthropic, .chat])
        let legacy = Credential(id: "c2", vendor: "x", label: "", last4: "abcd", createdAt: Fixture.now)
        #expect(legacy.protocols.isEmpty)

        #expect(anthropicOnly.supports(.anthropic))
        #expect(anthropicOnly.supports(.chat))
        #expect(!anthropicOnly.supports(.responses))
        #expect(!anthropicOnly.supports(.unknown("gemini")))
        #expect(anthropicOnly.supports(nil))
        #expect(legacy.supports(.responses))

        let codex = DemoData.agents.first { $0.id == DemoData.codexAgentID }!
        let claude = DemoData.agents.first { $0.id == DemoData.claudeAgentID }!
        #expect(codex.activeProtocol == .responses)
        #expect(!codex.canUse(anthropicOnly))
        #expect(claude.canUse(anthropicOnly))
        #expect(codex.canUse(legacy))
        let oldAgent = AgentInfo(id: "old", name: "Old", version: "1", defaultHarness: "acp")
        #expect(oldAgent.activeProtocol == nil)
        #expect(oldAgent.canUse(anthropicOnly))
    }

    @Test("AgentInfo：新字段默认空；上游地址只认 https")
    func agentInfo() {
        let bare = AgentInfo(id: "a", name: "A", version: "1", defaultHarness: "acp")
        #expect(bare.description.isEmpty)
        #expect(bare.upstream.isEmpty)
        #expect(bare.licenseNote == nil)
        #expect(bare.protocols.isEmpty)
        #expect(bare.upstreamURL == nil)

        var agent = bare
        agent.upstream = "https://github.com/NousResearch/hermes-agent"
        #expect(agent.upstreamURL?.host == "github.com")
        for bad in ["http://github.com/x", "github.com/x", "javascript:alert(1)", "https://", "  "] {
            agent.upstream = bad
            #expect(agent.upstreamURL == nil, "\(bad)")
        }
    }

    @Test("新 key 能用哪些协议：预置厂商按厂商，自定义地址按配了哪几个地址")
    func expectedProtocols() {
        let vendors = DemoData.vendors
        let preset = NewCredential(vendor: "openai", label: "", apiKey: "sk-12345678")
        #expect(preset.expectedProtocols(vendors: vendors) == [.chat, .responses])
        let custom = NewCredential(
            vendor: NewCredential.customVendor, label: "", apiKey: "sk-12345678", openaiBase: "https://llm.example/v1",
            responsesBase: "https://llm.example/v1")
        #expect(custom.expectedProtocols(vendors: vendors) == [.chat, .responses])
        let anthropic = NewCredential(
            vendor: NewCredential.customVendor, label: "", apiKey: "sk-12345678",
            anthropicBase: "https://llm.example/anthropic")
        #expect(anthropic.expectedProtocols(vendors: vendors) == [.anthropic])
    }

    @Test("RunFilter：预设、条件和服务端的查询一致（没结束包括认不出的状态）、页大小夹到 1…200")
    func runFilter() {
        #expect(RunFilter.all == RunFilter())
        #expect(RunFilter.active == RunFilter(activeOnly: true))
        #expect(RunFilter.plan("p1") == RunFilter(planID: "p1", rootsOnly: true))
        #expect(RunFilter.plan("p1", rootsOnly: false) == RunFilter(planID: "p1"))

        let root = Fixture.run(Fixture.runA, state: .running, planID: "p1")
        var step = Fixture.run(Fixture.runB, state: .succeeded, planID: "p1", stepKey: "build")
        step.parentRunID = Fixture.runA
        let other = Fixture.run("run-c", state: .unknown("hibernating"))
        #expect([root, step, other].filter(RunFilter.all.matches).count == 3)
        #expect([root, step, other].filter(RunFilter.active.matches).map(\.id) == [Fixture.runA, "run-c"])
        #expect([root, step, other].filter(RunFilter.plan("p1").matches).map(\.id) == [Fixture.runA])
        #expect(
            [root, step, other].filter(RunFilter.plan("p1", rootsOnly: false).matches).map(\.id) == [
                Fixture.runA, Fixture.runB,
            ])
        #expect([root, step, other].filter(RunFilter(rootsOnly: true).matches).map(\.id) == [Fixture.runA, "run-c"])
        #expect(
            [root, step, other].filter(RunFilter(planID: "p1", activeOnly: true).matches).map(\.id) == [Fixture.runA])

        #expect(RunFilter.clampedLimit(0) == 1)
        #expect(RunFilter.clampedLimit(-5) == 1)
        #expect(RunFilter.clampedLimit(50) == 50)
        #expect(RunFilter.clampedLimit(10_000) == RunFilter.maxLimit)
    }
}

// MARK: - Accept-Language

@Suite("Accept-Language（11.8）：拼请求头、校验、认语言")
struct AcceptLanguageTests {
    @Test("header(tags:)：q 值递减、_ 换成 -、跳过不像标签的、最多 10 个")
    func header() {
        #expect(AcceptLanguage.header(tags: ["zh-Hans-CN", "en-US", "en"]) == "zh-Hans-CN, en-US;q=0.9, en;q=0.8")
        #expect(AcceptLanguage.header(tags: [" en_US ", "", "中文", "x y", "zh;q=1", "ja"]) == "en-US, ja;q=0.9")
        #expect(AcceptLanguage.header(tags: []) == "")
        #expect(AcceptLanguage.header(tags: [String(repeating: "a", count: 36), "fr"]) == "fr")
        #expect(AcceptLanguage.header(tags: [String(repeating: "a", count: 35)]) == String(repeating: "a", count: 35))
        let many = (0..<12).map { "l\($0)" }
        let parts = AcceptLanguage.header(tags: many).components(separatedBy: ", ")
        #expect(parts.count == AcceptLanguage.maxTags)
        #expect(parts.first == "l0")
        #expect(parts.last == "l9;q=0.1")
        // 放不进 256 字节的后面几个不要（和 client-core 一样，结果总能交给 setAcceptLanguage）。
        let long = (0..<10).map { String(format: "t%02d", $0) + String(repeating: "x", count: 32) }
        let trimmed = AcceptLanguage.header(tags: long)
        #expect(trimmed.utf8.count <= AcceptLanguage.maxLength)
        #expect(trimmed.components(separatedBy: ", ").count == 6)
        #expect(trimmed.hasPrefix("t00"))
        #expect(throws: Never.self) { try AcceptLanguage.validated(trimmed) }
    }

    @Test("header(for:)：App 里选的语言排第一，后面跟系统的")
    func headerForDisplayLanguage() {
        #expect(AcceptLanguage.header(for: .english, systemTags: ["zh-Hans-CN"]) == "en, zh-Hans-CN;q=0.9")
        #expect(AcceptLanguage.header(for: .chinese, systemTags: ["en-US"]) == "zh-CN, en-US;q=0.9")
        #expect(UserLocale(acceptLanguage: AcceptLanguage.header(for: .english, systemTags: ["zh-Hans-CN"])) == .en)
    }

    @Test("validated：去掉空白、空的当作不带；太长、有控制字符抛 invalidArgument；非 ASCII 和制表符可以")
    func validated() throws {
        #expect(try AcceptLanguage.validated(nil) == nil)
        #expect(try AcceptLanguage.validated("   ") == nil)
        #expect(try AcceptLanguage.validated(" en-US, zh;q=0.8 ") == "en-US, zh;q=0.8")
        #expect(try AcceptLanguage.validated("en,\tzh") == "en,\tzh")
        #expect(try AcceptLanguage.validated("中文") == "中文")
        let max = String(repeating: "a", count: AcceptLanguage.maxLength)
        #expect(try AcceptLanguage.validated(max) == max)
        for bad in [max + "a", "en\nX-Injected: 1", "en\u{7F}", "en\u{0}"] {
            let error = #expect(throws: ClientError.self, "\(bad.debugDescription)") {
                try AcceptLanguage.validated(bad)
            }
            guard case .invalidArgument? = error else {
                Issue.record("应该是 invalidArgument：\(String(describing: error))")
                continue
            }
        }
    }

    @Test("UserLocale(acceptLanguage:)：和服务端 Locale::from_accept_language 的用例一致")
    func userLocaleFromHeader() {
        let cases: [(String, UserLocale?)] = [
            ("en-US,en;q=0.9,zh-CN;q=0.8", .en),
            ("zh-Hans-CN;q=0.5, en;q=0.7", .en),
            ("ja-JP, zh-TW;q=0.9", .zhCN),
            ("en;q=0, zh", .zhCN),
            ("ja, ko;q=0.8", nil),
            ("en;q=abc", nil),
            ("", nil),
            // q 相同的按出现顺序。
            ("zh;q=0.5, en;q=0.5", .zhCN),
            ("en_GB", .en),
        ]
        for (header, want) in cases {
            #expect(UserLocale(acceptLanguage: header) == want, "\(header)")
        }
    }
}

// MARK: - MockClient

@Suite("MockClient：跨实例的运行列表（11.8）")
struct MockListRunsTests {
    @Test("全部：跨实例、新的在前")
    func all() async throws {
        let client = makeClient()
        let runs = try await client.listRuns(filter: .all, before: nil, limit: 50)
        #expect(
            runs.map(\.id) == [
                DemoData.postRunID, DemoData.publishRunID, DemoData.digestRunID, DemoData.reviewRunID,
                DemoData.weeklyRunID,
            ])
        #expect(Set(runs.map(\.instanceID)) == [writer, reviewer])
        #expect(try await client.listRuns() == runs)
    }

    @Test("只要没结束的：取消之后就不在里面了")
    func activeOnly() async throws {
        let client = makeClient()
        let active = try await client.listRuns(filter: .active, limit: 50)
        #expect(active.map(\.id) == [DemoData.postRunID, DemoData.publishRunID])
        #expect(active.allSatisfy { $0.state.isActive })

        _ = try await client.cancelRun(DemoData.publishRunID)
        #expect(try await client.listRuns(filter: .active, limit: 50).map(\.id) == [DemoData.postRunID])
    }

    @Test("按计划、只要根运行：流水线的步骤（别的实例上、有父运行）只在 rootsOnly 为 false 时出现")
    func planAndRoots() async throws {
        let client = makeClient()
        let now = Date()
        let root = Run(
            id: "0192f3a0-0000-7000-8000-00000000f001", kind: .pipeline, instanceID: writer,
            planID: DemoData.digestPlanID, source: .plan, prompt: "流水线", state: .waitingChildren, createdAt: now)
        let step = Run(
            id: "0192f3a0-0000-7000-8000-00000000f002", instanceID: reviewer, planID: DemoData.digestPlanID,
            parentRunID: root.id, rootRunID: root.id, stepKey: "review", source: .pipeline, prompt: "审查",
            state: .running, createdAt: now.addingTimeInterval(1))
        client.update { $0.runs += [root, step] }

        let history = try await client.listRuns(filter: .plan(DemoData.digestPlanID), limit: 50)
        #expect(history.map(\.id) == [root.id, DemoData.digestRunID])
        let withSteps = try await client.listRuns(filter: .plan(DemoData.digestPlanID, rootsOnly: false), limit: 50)
        #expect(withSteps.map(\.id) == [step.id, root.id, DemoData.digestRunID])
        #expect(Set(withSteps.map(\.instanceID)) == [writer, reviewer])
        let activeRoots = try await client.listRuns(filter: RunFilter(activeOnly: true, rootsOnly: true), limit: 50)
        #expect(activeRoots.map(\.id) == [root.id, DemoData.postRunID, DemoData.publishRunID])

        // 不存在的计划（或者别人的）：空列表，不报错。
        #expect(try await client.listRuns(filter: .plan("0192f3a0-0000-7000-8000-00000000ffff"), limit: 50).isEmpty)
    }

    @Test("翻页：before 是上一页最后一个；页不重叠、拼起来是全部；游标自己结束了也照样用；找不到的游标是空页")
    func paging() async throws {
        let client = makeClient()
        let all = try await client.listRuns(filter: .all, limit: 50)
        var pages: [[Run]] = []
        var before: RunID?
        while true {
            let page = try await client.listRuns(filter: .all, before: before, limit: 2)
            if page.isEmpty { break }
            #expect(page.count <= 2)
            pages.append(page)
            before = page.last?.id
        }
        #expect(pages.map(\.count) == [2, 2, 1])
        #expect(pages.flatMap { $0 } == all)

        // “进行中”第一页的最后一个随后结束了：拿它当游标照样能翻到后面的（不会从头再来）。
        let first = try await client.listRuns(filter: .active, limit: 1)
        #expect(first.map(\.id) == [DemoData.postRunID])
        _ = try await client.cancelRun(DemoData.postRunID)
        let next = try await client.listRuns(filter: .active, before: DemoData.postRunID, limit: 1)
        #expect(next.map(\.id) == [DemoData.publishRunID])

        #expect(try await client.listRuns(filter: .all, before: "no-such-run", limit: 10).isEmpty)
    }

    @Test("limit 夹到 1…200；没登录抛 signedOut")
    func limitsAndAuth() async throws {
        let client = makeClient()
        #expect(try await client.listRuns(filter: .all, limit: 0).count == 1)
        #expect(try await client.listRuns(filter: .all, limit: -3).count == 1)
        client.update { s in
            s.runs = (0..<250).map { i in
                Run(
                    id: RunID("r\(i)"), instanceID: writer, prompt: "第 \(i) 个", state: .succeeded,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(i)))
            }
        }
        let page = try await client.listRuns(filter: .all, limit: 1000)
        #expect(page.count == RunFilter.maxLimit)
        #expect(page.first?.id == "r249")

        let signedOut = makeClient(signedIn: false)
        #expect(await failure { _ = try await signedOut.listRuns(filter: .all, limit: 10) } == .other(.signedOut))
    }

    @Test("等待原因码：run.state 带 wait_code 时写进运行；换到别的状态清掉")
    func waitCodeFollowsRunState() async throws {
        let client = makeClient()
        let run = DemoData.publishRunID
        client.emit(
            .runState, payload: ["state": "waiting_quota", "reason": "key 欠费", "wait_code": "no_balance"], runID: run,
            instanceID: reviewer)
        let waiting = try await client.getRun(run)
        #expect(waiting.state == .waitingQuota)
        #expect(waiting.waitCode == .noBalance)
        #expect(try await client.listRuns(filter: .active, limit: 50).first { $0.id == run }?.waitCode == .noBalance)

        // 别的状态里给了也不留（服务端只在等 key、等电脑时给）。
        client.emit(.runState, payload: ["state": "running", "wait_code": "invalid"], runID: run, instanceID: reviewer)
        #expect(try await client.getRun(run).waitCode == nil)
        client.emit(
            .runState, payload: ["state": "waiting_device", "wait_code": "device_offline"], runID: run,
            instanceID: reviewer)
        #expect(try await client.getRun(run).waitCode == .deviceOffline)
        client.emit(.runState, payload: ["state": "waiting_quota"], runID: run, instanceID: reviewer)
        #expect(try await client.getRun(run).waitCode == nil)
    }
}

@Suite("MockClient：缓存往前翻（11.8）")
struct MockCachedEventsBeforeTests {
    @Test("nil 拿最后一屏，旧的在前；往上翻传最小的序号；到头了是空的")
    func pagesBackwards() throws {
        let client = makeClient()
        let all = client.state.events[writer] ?? []
        try #require(all.count >= 5)

        let last = try client.cachedEventsBefore(instanceID: writer, beforeSeq: nil, limit: 3)
        #expect(last == Array(all.suffix(3)))
        #expect(try client.latestCachedEvents(instanceID: writer, limit: 3) == last)
        #expect(last.map(\.seq) == last.map(\.seq).sorted())

        var collected = last
        var cursor = last.first?.seq
        while let before = cursor {
            let page = try client.cachedEventsBefore(instanceID: writer, beforeSeq: before, limit: 3)
            if page.isEmpty { break }
            #expect(page.allSatisfy { $0.seq < before })
            collected = page + collected
            cursor = page.first?.seq
        }
        #expect(collected == all)
        #expect(try client.cachedEventsBefore(instanceID: writer, beforeSeq: all.first!.seq, limit: 10).isEmpty)
    }

    @Test("limit 为 0、不认识的实例：空；没登录：空（缓存只给登录了的用户）")
    func edges() async throws {
        let client = makeClient()
        #expect(try client.cachedEventsBefore(instanceID: writer, beforeSeq: nil, limit: 0).isEmpty)
        #expect(try client.cachedEventsBefore(instanceID: "nope", beforeSeq: nil, limit: 10).isEmpty)
        try await client.logout()
        #expect(try client.cachedEventsBefore(instanceID: writer, beforeSeq: nil, limit: 10).isEmpty)
    }
}

@Suite("MockClient：请求语言和版本太老（11.8）")
struct MockLanguageAndUpgradeTests {
    @Test("setAcceptLanguage：存去掉空白的值；空的当作不带；不合法的抛 invalidArgument，原来的值不变")
    func setAcceptLanguage() async throws {
        let client = makeClient()
        #expect(client.state.acceptLanguage == nil)
        try client.setAcceptLanguage(" en-US, zh-CN;q=0.9 ")
        #expect(client.state.acceptLanguage == "en-US, zh-CN;q=0.9")
        #expect(await failure { try client.setAcceptLanguage("en\r\nX: y") } == .invalidArgument)
        #expect(client.state.acceptLanguage == "en-US, zh-CN;q=0.9")
        try client.setAcceptLanguage("")
        #expect(client.state.acceptLanguage == nil)
        // 不联网：没登录也能设。
        let signedOut = makeClient(signedIn: false)
        try signedOut.setAcceptLanguage("en")
        #expect(signedOut.state.acceptLanguage == "en")

        // 按界面语言设：选的语言排第一，服务端认出来的就是它。
        try client.setAcceptLanguage(for: .english)
        #expect(client.state.acceptLanguage?.hasPrefix("en") == true)
        #expect(client.state.requestLocale == .en)
        try client.setAcceptLanguage(for: .chinese)
        #expect(client.state.acceptLanguage?.hasPrefix("zh-CN") == true)
        #expect(client.state.requestLocale == .zhCN)
    }

    @Test("agent 目录按请求语言给介绍和许可说明：英文时换成英文，中文或不带时是中文")
    func agentTexts() async throws {
        let client = makeClient()
        let zh = try await client.agents()
        let claudeZH = try #require(zh.first { $0.id == DemoData.claudeAgentID })
        #expect(claudeZH.description.contains("通用 agent"))
        #expect(claudeZH.licenseNote?.contains("专有软件") == true)
        #expect(claudeZH.upstreamURL != nil)
        #expect(zh.allSatisfy { !$0.description.isEmpty && $0.activeProtocol != nil })

        try client.setAcceptLanguage(AcceptLanguage.header(for: .english, systemTags: ["zh-Hans-CN"]))
        let en = try await client.agents()
        let claudeEN = try #require(en.first { $0.id == DemoData.claudeAgentID })
        #expect(claudeEN.description.hasPrefix("General-purpose agent"))
        #expect(claudeEN.licenseNote?.contains("proprietary") == true)
        // 只换文案，别的不变。
        #expect(en.map(\.id) == zh.map(\.id))
        #expect(en.map(\.protocols) == zh.map(\.protocols))
        #expect(en.first { $0.id == DemoData.codexAgentID }?.licenseNote == nil)

        try client.setAcceptLanguage("zh-Hans-CN, en;q=0.9")
        #expect(try await client.agents() == zh)
    }

    @Test("新用户登录：语言按 Accept-Language 定；老用户不变")
    func newUserLocale() async throws {
        let client = makeClient(signedIn: false)
        try client.setAcceptLanguage("en-US, zh;q=0.5")
        // 演示用户是老用户（同一个手机号）：语言不变。
        let old = try await client.login(phone: "+8613800138000", code: "123456")
        #expect(!old.isNewUser)
        #expect(old.user.locale == .zhCN)
        try await client.logout()
        let new = try await client.login(phone: "+8613900139000", code: "123456")
        #expect(new.isNewUser)
        #expect(new.user.locale == .en)

        // 认不出的语言：不改（服务端按中文）。
        let other = makeClient(signedIn: false)
        try other.setAcceptLanguage("ja-JP")
        let user = try await other.login(phone: "+8613700137000", code: "123456").user
        #expect(user.locale == .zhCN)
    }

    @Test("upgradeRequired：任何调用抛过 upgradeRequired 后一直是 true；之后的订阅直接以 upgradeRequired 结束", .timeLimit(.minutes(1)))
    func upgradeRequired() async throws {
        let client = makeClient()
        #expect(!client.upgradeRequired())
        client.failNext(with: .network(message: "offline"))
        _ = await failure { _ = try await client.me() }
        #expect(!client.upgradeRequired())

        client.failNext(with: .upgradeRequired)
        #expect(await failure { _ = try await client.instances() } == .other(.upgradeRequired))
        #expect(client.upgradeRequired())
        // 之后的调用照常（只是标记一直在）。
        _ = try await client.me()
        #expect(client.upgradeRequired())

        var statuses: [StreamStatus] = []
        var events = 0
        for await element in try client.events(instanceID: writer) {
            switch element {
            case .status(let s): statuses.append(s)
            case .event: events += 1
            case .reset: break
            }
        }
        #expect(statuses == [.upgradeRequired])
        #expect(events == 0)

        // 带 upgrade_required 错误码的接口错误也算。
        let other = makeClient()
        other.failNext(with: .api(status: 426, code: .upgradeRequired, message: "too old", retryAfterSecs: nil))
        _ = await failure { _ = try await other.agents() }
        #expect(other.upgradeRequired())
    }

    @Test("预览升级页：直接设 isUpgradeRequired")
    func presetFlag() {
        let state = MockState(user: User(id: "u", phone: "", createdAt: Fixture.now), isUpgradeRequired: true)
        #expect(MockClient(state: state).upgradeRequired())
    }

    @Test("注销账号：请求语言和版本标记留着（是这台客户端的，不是账号的）")
    func eraseKeepsClientSettings() async throws {
        let client = makeClient()
        try client.setAcceptLanguage("en")
        try await client.sendSelfCode(purpose: .deleteAccount)
        try await client.deleteAccount(code: "123456")
        #expect(client.state.acceptLanguage == "en")
        #expect(!client.state.isUpgradeRequired)
    }
}

@Suite("MockClient：key 的协议（11.8）")
struct MockCredentialProtocolTests {
    @Test("演示 key 带协议；新加的 key 按厂商或配了的地址算")
    func protocols() async throws {
        let client = makeClient()
        let demo = try await client.credentials()
        #expect(demo.allSatisfy { !$0.protocols.isEmpty })
        let claudeKey = try #require(demo.first { $0.id == DemoData.claudeCredentialID })
        #expect(claudeKey.protocols == [.anthropic, .chat])

        let preset = try await client.addCredential(
            NewCredential(vendor: "openai", label: "", apiKey: "sk-openai-1234"))
        #expect(preset.protocols == [.chat, .responses])
        let custom = try await client.addCredential(
            NewCredential(
                vendor: NewCredential.customVendor, label: "自建", apiKey: "sk-custom-5678",
                anthropicBase: "https://llm.example/anthropic"))
        #expect(custom.protocols == [.anthropic])

        let agents = try await client.agents()
        let codex = try #require(agents.first { $0.id == DemoData.codexAgentID })
        #expect(!codex.canUse(custom))
        #expect(codex.canUse(preset))
    }
}
