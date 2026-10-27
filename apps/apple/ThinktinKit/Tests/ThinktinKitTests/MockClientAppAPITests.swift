import Foundation
import Testing

@testable import ThinktinKit

// MockClient 上 11.7（App 接口补齐）、10.6（实时活动）、5.5（内容举报）新加的方法：每个方法至少一个用例，
// 规则和服务端一致（没登录 signedOut、找不到 not_found、状态不对 conflict、参数不对 invalid，
// client-core 发请求前就拒的是 invalidArgument）。

private let writer = DemoData.writerID
private let reviewer = DemoData.reviewerID

private func makeClient(signedIn: Bool = true) -> MockClient {
    MockClient(state: DemoData.state(signedIn: signedIn), stepDelay: 0, autoReply: false)
}

/// 抛出的错误：api 错误的错误码，`invalidArgument` 记成 nil 以外的专门标记。
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

/// 32 个字符的十六进制令牌，`seed` 不同令牌不同。
private func hexToken(_ seed: UInt8) -> String {
    LiveActivityToken.hex(Data(repeating: seed, count: 16))
}

// MARK: - 账号

@Suite("MockClient：昵称与注销（11.7）")
struct MockProfileTests {
    @Test("改昵称：给了就改，nil 清掉（显示打码的手机号），空串和太长的不行")
    func updateProfile() async throws {
        let client = makeClient()
        #expect(try await client.updateProfile(displayName: "李四").displayName == "李四")
        #expect(try await client.me().displayName == "李四")
        let cleared = try await client.updateProfile(displayName: nil)
        #expect(cleared.displayName == nil)
        #expect(cleared.nameForDisplay == "138****8000")
        #expect(await failure { _ = try await client.updateProfile(displayName: "") } == .api(.invalid))
        let long = String(repeating: "名", count: User.maxDisplayNameLength + 1)
        #expect(await failure { _ = try await client.updateProfile(displayName: long) } == .api(.invalid))
        #expect(
            try await client.updateProfile(displayName: String(repeating: "名", count: 64)).displayName?.count == 64)
    }

    @Test("注销账号：先发验证码；成功后登录状态和缓存一起清掉，事件流收到 signedOut", .timeLimit(.minutes(1)))
    func deleteAccount() async throws {
        let client = makeClient()
        // 没发过验证码、验证码不对：不行。
        #expect(await failure { try await client.deleteAccount(code: "123456") } == .api(.invalid))
        try await client.sendSelfCode(purpose: .changePhone)
        #expect(await failure { try await client.deleteAccount(code: "123456") } == .api(.invalid))
        try await client.sendSelfCode(purpose: .deleteAccount)
        #expect(await failure { try await client.deleteAccount(code: "000000") } == .api(.invalid))
        #expect(client.signedIn())

        let stream = try client.events(instanceID: writer, afterSeq: client.state.lastSeq(of: writer))
        let statuses = Task { () -> [StreamStatus] in
            var out: [StreamStatus] = []
            for await element in stream {
                if case .status(let s) = element { out.append(s) }
            }
            return out
        }

        try await client.deleteAccount(code: "123456")
        #expect(!client.signedIn())
        #expect(await statuses.value.last == .signedOut)
        await #expect(throws: ClientError.signedOut) { try await client.me() }
        // 缓存类方法返回空。
        #expect(try client.cachedInstances().isEmpty)
        #expect(try client.cachedRuns(instanceID: writer, limit: 10).isEmpty)
        #expect(try client.cachedInbox(before: nil, limit: 10).isEmpty)
        #expect(try client.cachedUnread() == 0)
        #expect(try client.cachedEvents(instanceID: writer, afterSeq: 0, limit: 10).isEmpty)
        #expect(client.state.devices.isEmpty)
        #expect(client.state.teams.isEmpty)
        #expect(client.state.liveActivityStartToken == nil)

        // 同一个手机号再登录是新用户：目录还在，自己的东西都没了，这台设备重新登记。
        let again = try await client.login(phone: "+8613800138000", code: "123456")
        #expect(again.isNewUser)
        #expect(again.user.id != DemoData.userID)
        #expect(try await client.agents().count == 3)
        #expect(try await client.instances().isEmpty)
        #expect(try await client.devices().map(\.id) == [DemoData.deviceID])
        // 用过的验证码不能再用。
        #expect(await failure { try await client.deleteAccount(code: "123456") } == .api(.invalid))
    }

    @Test("没登录时抛 signedOut")
    func requiresSession() async {
        let client = makeClient(signedIn: false)
        await #expect(throws: ClientError.signedOut) { try await client.updateProfile(displayName: "x") }
        await #expect(throws: ClientError.signedOut) { try await client.sendSelfCode(purpose: .deleteAccount) }
        await #expect(throws: ClientError.signedOut) { try await client.devices() }
        await #expect(throws: ClientError.signedOut) { try await client.teams() }
        await #expect(throws: ClientError.signedOut) { try await client.reports() }
        await #expect(throws: ClientError.signedOut) { try await client.endLiveActivity(runID: DemoData.postRunID) }
    }
}

// MARK: - 登录设备与设备消息

@Suite("MockClient：登录设备（11.7）")
struct MockDeviceTests {
    @Test("列表：最近活跃的在前，只有这台是当前设备，手机不算在线")
    func list() async throws {
        let client = makeClient()
        let devices = try await client.devices()
        #expect(devices.map(\.id) == [DemoData.deviceID, DemoData.macDeviceID, DemoData.iPadDeviceID])
        #expect(devices.filter(\.isCurrent).map(\.id) == [DemoData.deviceID])
        #expect(devices.filter(\.isOnline).map(\.id) == [DemoData.macDeviceID])
        // 状态里乱标的也按会话和平台算。
        client.update { s in
            for i in s.devices.indices {
                s.devices[i].isCurrent = true
                s.devices[i].isOnline = true
            }
        }
        let fixed = try await client.devices()
        #expect(fixed.filter(\.isCurrent).count == 1)
        #expect(fixed.filter(\.isOnline).map(\.id) == [DemoData.macDeviceID])
    }

    @Test("吊销：别的设备从列表里去掉；当前这台等于退出登录；不存在的 not_found")
    func revoke() async throws {
        let client = makeClient()
        try await client.revokeDevice(DemoData.iPadDeviceID)
        #expect(try await client.devices().map(\.id) == [DemoData.deviceID, DemoData.macDeviceID])
        #expect(await failure { try await client.revokeDevice(DemoData.iPadDeviceID) } == .api(.notFound))

        try await client.setLiveActivityStartToken(hexToken(1))
        try await client.revokeDevice(DemoData.deviceID)
        #expect(!client.signedIn())
        #expect(client.state.liveActivityStartToken == nil)
        await #expect(throws: ClientError.signedOut) { try await client.devices() }

        // 再登录：这台重新登记，带上推送通道。
        _ = try await client.login(
            phone: "+8613800138000", code: "123456", push: .apns(deviceToken: Data([1, 2, 3])))
        let current = try #require(try await client.devices().first { $0.isCurrent })
        #expect(current.id == DemoData.deviceID)
        #expect(current.pushChannel == .apns)
    }

    @Test("退出登录：服务端吊销这台，实时活动一起清掉")
    func logout() async throws {
        let client = makeClient()
        try await client.registerLiveActivity(runID: DemoData.publishRunID, token: hexToken(2))
        try await client.logout()
        #expect(!client.state.devices.contains { $0.id == DemoData.deviceID })
        #expect(client.state.liveActivities.isEmpty)
    }
}

@Suite("MockClient：设备消息（14.1）")
struct MockDeviceMessageTests {
    @Test("发给电脑：手机能发的种类、记下收发双方和有效期")
    func send() async throws {
        let client = makeClient()
        let sent = try await client.sendDeviceMessage(
            to: DemoData.macDeviceID, kind: .pairResponse, bodyJSON: #"{"nonce":"n1"}"#)
        #expect(sent.fromDeviceID == DemoData.deviceID)
        #expect(sent.toDeviceID == DemoData.macDeviceID)
        #expect(sent.kind == .pairResponse)
        #expect(sent.body?["nonce"]?.stringValue == "n1")
        #expect(sent.expiresAt == sent.createdAt.addingTimeInterval(DeviceMessage.timeToLive))
        #expect(client.state.deviceMessages.contains(sent))
        // 便捷方法：内容给 JSONValue。
        let decision = try await client.sendDeviceMessage(
            to: DemoData.macDeviceID, kind: .approvalDecision, body: ["approve": true])
        #expect(decision.body?["approve"]?.boolValue == true)
        // 发出去的不在自己的收件里。
        #expect(try await client.deviceMessages().isEmpty)
    }

    @Test("校验：发给自己、方向不对、对方不存在、内容不是 JSON、太大、种类不认识")
    func validation() async {
        let client = makeClient()
        let mac = DemoData.macDeviceID
        #expect(
            await failure {
                _ = try await client.sendDeviceMessage(to: DemoData.deviceID, kind: .capability, bodyJSON: "{}")
            }
                == .api(.invalid))
        // 手机发给手机。
        #expect(
            await failure {
                _ = try await client.sendDeviceMessage(to: DemoData.iPadDeviceID, kind: .capability, bodyJSON: "{}")
            } == .api(.invalid))
        // 电脑才能发的种类。
        #expect(
            await failure { _ = try await client.sendDeviceMessage(to: mac, kind: .approvalRequest, bodyJSON: "{}") }
                == .api(.invalid))
        #expect(
            await failure { _ = try await client.sendDeviceMessage(to: "missing", kind: .capability, bodyJSON: "{}") }
                == .api(.notFound))
        #expect(
            await failure { _ = try await client.sendDeviceMessage(to: mac, kind: .capability, bodyJSON: "not json") }
                == .invalidArgument)
        #expect(
            await failure {
                _ = try await client.sendDeviceMessage(to: mac, kind: .unknown("screen_share"), bodyJSON: "{}")
            } == .invalidArgument)
        let huge = "\"" + String(repeating: "x", count: DeviceMessage.maxBodyBytes) + "\""
        #expect(
            await failure { _ = try await client.sendDeviceMessage(to: mac, kind: .capability, bodyJSON: huge) }
                == .api(.invalid))
        #expect(client.state.deviceMessages.isEmpty)
    }

    @Test("收件：发给这台、没过期的，按发出的顺序；确认后不再返回")
    func receiveAndAck() async throws {
        let client = makeClient()
        let now = Date()
        let first = client.deliverDeviceMessage(
            from: DemoData.macDeviceID, kind: .pairConfirm, body: ["step": 1], at: now.addingTimeInterval(-60))
        let second = client.deliverDeviceMessage(
            from: DemoData.macDeviceID, kind: .approvalRequest, body: ["step": 2], at: now.addingTimeInterval(-30))
        // 过期的、发给别人的不返回。
        client.deliverDeviceMessage(
            from: DemoData.macDeviceID, kind: .approvalRequest,
            at: now.addingTimeInterval(-DeviceMessage.timeToLive - 1))
        _ = try await client.sendDeviceMessage(to: DemoData.macDeviceID, kind: .capability, bodyJSON: "{}")

        #expect(try await client.deviceMessages().map(\.id) == [first.id, second.id])
        #expect(await failure { _ = try await client.ackDeviceMessages(ids: []) } == .api(.invalid))
        let tooMany = (0...DeviceMessage.maxAckCount).map { DeviceMessageID("m\($0)") }
        #expect(await failure { _ = try await client.ackDeviceMessages(ids: tooMany) } == .api(.invalid))
        #expect(try await client.ackDeviceMessages(ids: [first.id, "unknown"]) == 1)
        #expect(try await client.deviceMessages().map(\.id) == [second.id])
        #expect(try await client.ackDeviceMessages(ids: [first.id]) == 0, "收下过的不再算")
    }

    @Test("吊销电脑：它的消息一起丢掉")
    func revokeDropsMessages() async throws {
        let client = makeClient()
        client.deliverDeviceMessage(from: DemoData.macDeviceID, kind: .pairConfirm)
        _ = try await client.sendDeviceMessage(to: DemoData.macDeviceID, kind: .pairResponse, bodyJSON: "{}")
        try await client.revokeDevice(DemoData.macDeviceID)
        #expect(client.state.deviceMessages.isEmpty)
        #expect(try await client.deviceMessages().isEmpty)
    }
}

// MARK: - 实时活动

@Suite("MockClient：实时活动（10.6）")
struct MockLiveActivityTests {
    @Test("登记：换令牌重发一次，同一个令牌不重发；关掉后同一个令牌不重新打开")
    func registerAndEnd() async throws {
        let client = makeClient()
        let run = DemoData.publishRunID
        try await client.registerLiveActivity(runID: run, token: hexToken(1))
        #expect(client.state.liveActivities[run]?.pushCount == 1)
        try await client.registerLiveActivity(runID: run, token: hexToken(1))
        #expect(client.state.liveActivities[run]?.pushCount == 1, "同一个令牌再登记不重发")
        try await client.registerLiveActivity(runID: run, token: Data(repeating: 2, count: 16))
        #expect(client.state.liveActivities[run]?.token == hexToken(2))
        #expect(client.state.liveActivities[run]?.pushCount == 2, "换了令牌马上重发一次")

        try await client.endLiveActivity(runID: run)
        #expect(client.state.liveActivities[run]?.isEnded == true)
        try await client.registerLiveActivity(runID: run, token: hexToken(2))
        #expect(client.state.liveActivities[run]?.isEnded == true, "关掉了的同一个令牌不重新打开")
        try await client.registerLiveActivity(runID: run, token: hexToken(3))
        #expect(client.state.liveActivities[run]?.isOpen() == true)
        #expect(client.state.liveActivities[run]?.pushCount == 3)
        // 没登记过的也算成功。
        try await client.endLiveActivity(runID: DemoData.postRunID)
        try await client.endLiveActivity(runID: "never-registered")
    }

    @Test("拒绝：令牌格式、运行不存在、结束 10 分钟以上（App 在本地结束）")
    func rejections() async throws {
        let client = makeClient()
        #expect(
            await failure { try await client.registerLiveActivity(runID: DemoData.publishRunID, token: "xyz") }
                == .api(.invalid))
        #expect(
            await failure { try await client.registerLiveActivity(runID: "missing", token: hexToken(1)) }
                == .api(.notFound))
        // 周报的运行一天前就结束了。
        #expect(
            await failure { try await client.registerLiveActivity(runID: DemoData.weeklyRunID, token: hexToken(1)) }
                == .api(.invalid))
        // 刚结束（10 分钟内）的还可以登记，好让结束的状态推送过去。
        client.update { s in
            if let i = s.runs.firstIndex(where: { $0.id == DemoData.reviewRunID }) {
                s.runs[i].finishedAt = Date().addingTimeInterval(-5 * 60)
            }
        }
        try await client.registerLiveActivity(runID: DemoData.reviewRunID, token: hexToken(1))
        #expect(client.state.liveActivities.count == 1)
    }

    @Test("一台设备同时最多 10 个；已经登记的换令牌不受限")
    func limit() async throws {
        let client = makeClient()
        var runs: [Run] = []
        for i in 0..<LiveActivityLimits.maxOpenPerDevice {
            let run = try await client.createRun(instanceID: writer, prompt: "任务 \(i)")
            runs.append(run)
            try await client.registerLiveActivity(runID: run.id, token: hexToken(UInt8(i + 1)))
        }
        let extra = try await client.createRun(instanceID: writer, prompt: "多出来的")
        #expect(
            await failure { try await client.registerLiveActivity(runID: extra.id, token: hexToken(99)) }
                == .api(.invalid))
        try await client.registerLiveActivity(runID: runs[0].id, token: hexToken(100))
        // 关掉一个就空出名额。
        try await client.endLiveActivity(runID: runs[1].id)
        try await client.registerLiveActivity(runID: extra.id, token: hexToken(99))
    }

    @Test("推送开启令牌：登记、清掉；只有 iPhone、iPad")
    func startToken() async throws {
        let client = makeClient()
        try await client.setLiveActivityStartToken(hexToken(7))
        #expect(client.state.liveActivityStartToken == hexToken(7))
        try await client.setLiveActivityStartToken(Data(repeating: 8, count: 16))
        #expect(client.state.liveActivityStartToken == hexToken(8))
        #expect(await failure { try await client.setLiveActivityStartToken("not-hex") } == .api(.invalid))
        try await client.setLiveActivityStartToken(nil)
        #expect(client.state.liveActivityStartToken == nil)

        // 这台换成 Mac：都不能登记，清掉照样可以。
        client.update { s in
            if let i = s.devices.firstIndex(where: { $0.id == DemoData.deviceID }) { s.devices[i].platform = .macos }
        }
        #expect(await failure { try await client.setLiveActivityStartToken(hexToken(7)) } == .api(.invalid))
        #expect(
            await failure { try await client.registerLiveActivity(runID: DemoData.publishRunID, token: hexToken(7)) }
                == .api(.invalid))
        try await client.setLiveActivityStartToken(nil)
    }
}

// MARK: - 实例、运行、产出物

@Suite("MockClient：实例、运行翻页、产出物（11.7）")
struct MockRunPagingTests {
    @Test("一个实例；不存在的 not_found")
    func instance() async throws {
        let client = makeClient()
        #expect(try await client.instance(writer).name == "写作助手")
        #expect(await failure { _ = try await client.instance("missing") } == .api(.notFound))
    }

    @Test("往前翻页：新的在前，接着 before 之后")
    func olderRuns() async throws {
        let client = makeClient()
        let first = try await client.runs(instanceID: writer, limit: 1)
        #expect(first.map(\.id) == [DemoData.postRunID])
        let next = try await client.olderRuns(instanceID: writer, before: DemoData.postRunID, limit: 1)
        #expect(next.map(\.id) == [DemoData.digestRunID])
        let rest = try await client.olderRuns(instanceID: writer, before: DemoData.digestRunID, limit: 5)
        #expect(rest.map(\.id) == [DemoData.weeklyRunID])
        #expect(try await client.olderRuns(instanceID: writer, before: DemoData.weeklyRunID, limit: 5).isEmpty)
        #expect(
            await failure { _ = try await client.olderRuns(instanceID: writer, before: "missing", limit: 5) }
                == .api(.notFound))
        #expect(
            await failure {
                _ = try await client.olderRuns(instanceID: "missing", before: DemoData.postRunID, limit: 5)
            }
                == .api(.notFound))
    }

    @Test("实例的产出物：新的在前、按 limit；删掉后列表和内容都没了")
    func artifacts() async throws {
        let client = makeClient()
        let list = try await client.instanceArtifacts(writer, limit: 10)
        #expect(list.map(\.id) == [DemoData.weeklyArtifactID])
        #expect(try await client.instanceArtifacts(reviewer, limit: 10).isEmpty)
        #expect(try await client.instanceArtifacts(writer, limit: 0).count == 1, "limit 至少按 1 算")
        #expect(await failure { _ = try await client.instanceArtifacts("missing", limit: 10) } == .api(.notFound))

        try await client.deleteArtifact(DemoData.weeklyArtifactID)
        #expect(try await client.instanceArtifacts(writer, limit: 10).isEmpty)
        #expect(try await client.runArtifacts(DemoData.weeklyRunID).isEmpty)
        #expect(await failure { _ = try await client.artifactContent(DemoData.weeklyArtifactID) } == .api(.notFound))
        #expect(await failure { try await client.deleteArtifact(DemoData.weeklyArtifactID) } == .api(.notFound))
    }
}

// MARK: - 计划

@Suite("MockClient：改计划与触发器（11.7）")
struct MockPlanUpdateTests {
    @Test("只改给了的字段，版本号加一，触发器不动")
    func partialUpdate() async throws {
        let client = makeClient()
        let before = try await client.getPlan(DemoData.digestPlanID)
        let renamed = try await client.updatePlan(before.id, change: PlanChange(title: "  早上的通知汇总  "))
        #expect(renamed.title == "早上的通知汇总")
        #expect(renamed.goal == before.goal)
        #expect(renamed.policy == before.policy)
        #expect(renamed.catchUp == before.catchUp)
        #expect(renamed.triggers == before.triggers)
        #expect(renamed.revision == before.revision + 1)

        var policy = before.policy
        policy.dailyTokenLimit = 200_000
        policy.onApprovalTimeout = .fail
        let changed = try await client.updatePlan(before.id, change: PlanChange(policy: policy, catchUp: .all))
        #expect(changed.title == "早上的通知汇总")
        #expect(changed.policy.dailyTokenLimit == 200_000)
        #expect(changed.policy.onApprovalTimeout == .fail)
        #expect(changed.catchUp == .all)
        #expect(changed.revision == before.revision + 2)
        #expect(try await client.getPlan(before.id) == changed)

        // 换成流水线，再给空数组变回来。
        let steps = [
            PlanStep(key: "collect", instanceID: writer, prompt: "收集通知"),
            PlanStep(key: "review", instanceID: reviewer, prompt: "挑出要处理的", dependsOn: ["collect"]),
        ]
        #expect(try await client.updatePlan(before.id, change: PlanChange(steps: steps)).isPipeline)
        #expect(try await client.updatePlan(before.id, change: PlanChange(steps: [])).isPipeline == false)
    }

    @Test("校验失败时计划不变")
    func validation() async throws {
        let client = makeClient()
        let id = DemoData.digestPlanID
        let before = try await client.getPlan(id)
        func check(_ change: PlanChange, _ expected: Failure) async {
            #expect(await failure { _ = try await client.updatePlan(id, change: change) } == expected)
        }
        await check(PlanChange(title: "   "), .api(.invalid))
        await check(PlanChange(goal: String(repeating: "长", count: Plan.maxGoalLength + 1)), .api(.invalid))
        await check(PlanChange(policy: PlanPolicy(approvalTimeoutSecs: 10)), .api(.invalid))
        await check(PlanChange(policy: PlanPolicy(onApprovalTimeout: .unknown("hibernate"))), .invalidArgument)
        await check(PlanChange(catchUp: .unknown("weekly")), .invalidArgument)
        await check(PlanChange(steps: [PlanStep(key: "Bad Key", instanceID: writer, prompt: "p")]), .api(.invalid))
        await check(
            PlanChange(steps: [
                PlanStep(key: "a", instanceID: writer, prompt: "p", dependsOn: ["b"]),
                PlanStep(key: "b", instanceID: writer, prompt: "p", dependsOn: ["a"]),
            ]), .api(.invalid))
        await check(
            PlanChange(steps: [PlanStep(key: "a", instanceID: writer, prompt: "p", dependsOn: ["z"])]), .api(.invalid))
        await check(PlanChange(steps: [PlanStep(key: "a", instanceID: "missing", prompt: "p")]), .api(.notFound))
        #expect(try await client.getPlan(id) == before)
        #expect(
            await failure { _ = try await client.updatePlan("missing", change: PlanChange(title: "t")) }
                == .api(.notFound))
    }

    @Test("新建时带策略和补跑方式")
    func createWithPolicy() async throws {
        let client = makeClient()
        let policy = PlanPolicy(preauthorizedTools: ["read"], dailyTokenLimit: 10_000)
        let plan = try await client.createPlan(
            NewPlan(
                instanceID: writer, title: "晚报", goal: "汇总", triggers: [.rrule("FREQ=DAILY")], policy: policy,
                catchUp: .skip))
        #expect(plan.policy == policy)
        #expect(plan.catchUp == .skip)
        #expect(
            await failure {
                _ = try await client.createPlan(
                    NewPlan(
                        instanceID: writer, title: "t", goal: "g", triggers: [.rrule("FREQ=DAILY")],
                        catchUp: .unknown("x")))
            } == .invalidArgument)
    }

    @Test("加、删触发器：最多 10 个，一次性的要在将来；版本号不变")
    func triggers() async throws {
        let client = makeClient()
        let id = DemoData.digestPlanID
        let before = try await client.getPlan(id)
        let at = Date().addingTimeInterval(3600)
        let added = try await client.addTrigger(planID: id, schedule: .once(at))
        #expect(added.nextFireAt == at)
        let plan = try await client.getPlan(id)
        #expect(plan.triggers.map(\.id) == before.triggers.map(\.id) + [added.id])
        #expect(plan.revision == before.revision)

        #expect(
            await failure {
                _ = try await client.addTrigger(planID: id, schedule: .once(Date().addingTimeInterval(-60)))
            }
                == .api(.invalid))
        #expect(
            await failure {
                _ = try await client.addTrigger(
                    planID: id, schedule: .cron(expression: "0 9 * *", timeZone: "Asia/Shanghai"))
            } == .api(.invalid))
        #expect(
            await failure { _ = try await client.addTrigger(planID: "missing", schedule: .rrule("FREQ=DAILY")) }
                == .api(.notFound))
        for _ in plan.triggers.count..<Plan.maxTriggers {
            _ = try await client.addTrigger(planID: id, schedule: .rrule("FREQ=WEEKLY"))
        }
        #expect(
            await failure { _ = try await client.addTrigger(planID: id, schedule: .rrule("FREQ=DAILY")) }
                == .api(.invalid))

        try await client.deleteTrigger(added.id)
        #expect(try await client.getPlan(id).triggers.contains { $0.id == added.id } == false)
        #expect(await failure { try await client.deleteTrigger(added.id) } == .api(.notFound))
    }
}

// MARK: - 收件箱

@Suite("MockClient：一条通知、标回未读、删除（11.7）")
struct MockInboxItemTests {
    private let readItem: InboxItemID = "0192f3a0-0000-7000-8000-000000001003"
    private let unreadItem: InboxItemID = "0192f3a0-0000-7000-8000-000000001001"

    @Test("取一条；标回未读，未读数加一")
    func itemAndUnread() async throws {
        let client = makeClient()
        let item = try await client.inboxItem(readItem)
        #expect(item.isRead)
        #expect(item.planID == DemoData.digestPlanID)
        #expect(await failure { _ = try await client.inboxItem("missing") } == .api(.notFound))

        #expect(try client.cachedUnread() == 3)
        #expect(try await client.markInboxUnread(readItem) == 4)
        #expect(try await client.inboxItem(readItem).isRead == false)
        #expect(try client.cachedUnread() == 4)
        #expect(try await client.markInboxUnread(readItem) == 4, "已经未读的不再加")
        #expect(await failure { _ = try await client.markInboxUnread("missing") } == .api(.notFound))
    }

    @Test("删一条：列表和未读数跟着变")
    func delete() async throws {
        let client = makeClient()
        try await client.deleteInboxItem(unreadItem)
        #expect(try client.cachedUnread() == 2)
        #expect(try await client.syncInbox(limit: 10).items.contains { $0.id == unreadItem } == false)
        #expect(await failure { _ = try await client.inboxItem(unreadItem) } == .api(.notFound))
        #expect(await failure { try await client.deleteInboxItem(unreadItem) } == .api(.notFound))
    }
}

// MARK: - 团队与模板

@Suite("MockClient：团队（8.1）")
struct MockTeamTests {
    @Test("列表、详情、新建（成员按顺序排好、名字去掉空白）、改、删")
    func lifecycle() async throws {
        let client = makeClient()
        let demo = try await client.teams()
        #expect(demo.map(\.id) == [DemoData.releaseTeamID])
        #expect(try await client.team(DemoData.releaseTeamID).lead?.instanceID == reviewer)

        let created = try await client.createTeam(
            name: "  写作组 ",
            members: [
                TeamMember(instanceID: reviewer, role: .member, position: 1),
                TeamMember(instanceID: writer, role: .lead, position: 0),
            ])
        #expect(created.name == "写作组")
        #expect(created.members.map(\.instanceID) == [writer, reviewer])
        #expect(try await client.teams().map(\.id) == [DemoData.releaseTeamID, created.id], "先建的在前")

        let renamed = try await client.updateTeam(created.id, name: "新名字", members: nil)
        #expect(renamed.name == "新名字")
        #expect(renamed.members == created.members)
        let reshaped = try await client.updateTeam(created.id, name: nil, members: Team.members([reviewer]))
        #expect(reshaped.name == "新名字")
        #expect(reshaped.members.map(\.instanceID) == [reviewer])
        #expect(reshaped.lead?.instanceID == reviewer)

        try await client.deleteTeam(created.id)
        #expect(try await client.teams().map(\.id) == [DemoData.releaseTeamID])
        #expect(await failure { _ = try await client.team(created.id) } == .api(.notFound))
        #expect(await failure { try await client.deleteTeam(created.id) } == .api(.notFound))
        // 实例不跟着删。
        #expect(try await client.instances().count == 2)
    }

    @Test("校验：名字、成员数、负责人、角色、实例、重复")
    func validation() async {
        let client = makeClient()
        func create(_ name: String, _ members: [TeamMember]) async -> Failure? {
            await failure { _ = try await client.createTeam(name: name, members: members) }
        }
        let one = Team.members([writer])
        #expect(await create(" ", one) == .api(.invalid))
        #expect(await create(String(repeating: "名", count: Team.maxNameLength + 1), one) == .api(.invalid))
        #expect(await create("t", []) == .api(.invalid))
        #expect(await create("t", Array(repeating: one[0], count: Team.maxMembers + 1)) == .api(.invalid))
        #expect(
            await create(
                "t", [TeamMember(instanceID: writer, role: .lead), TeamMember(instanceID: reviewer, role: .lead)])
                == .api(.invalid))
        #expect(await create("t", [TeamMember(instanceID: writer, role: .unknown("boss"))]) == .invalidArgument)
        #expect(await create("t", Team.members(["missing"])) == .api(.notFound))
        #expect(await create("t", Team.members([writer, writer])) == .api(.conflict))
        #expect(
            await failure { _ = try await client.updateTeam(DemoData.releaseTeamID, name: nil, members: []) }
                == .api(.invalid))
        #expect(
            await failure { _ = try await client.updateTeam("missing", name: "x", members: nil) } == .api(.notFound))
        #expect(client.state.teams.count == 1)
    }

    @Test("删掉实例：自动移出团队，团队留着")
    func deleteInstanceLeavesTeam() async throws {
        let client = makeClient()
        try await client.deleteInstance(writer)
        let team = try await client.team(DemoData.releaseTeamID)
        #expect(team.members.map(\.instanceID) == [reviewer])
    }
}

@Suite("MockClient：团队模板（8.1）")
struct MockTeamTemplateTests {
    @Test("新建、从团队生成、列表、删除")
    func lifecycle() async throws {
        let client = makeClient()
        #expect(try await client.teamTemplates().map(\.id) == [DemoData.contentTemplateID])

        let direct = try await client.createTeamTemplate(
            name: "两人组",
            members: [
                TemplateMember(agentID: DemoData.claudeAgentID, name: "写", role: .lead),
                TemplateMember(agentID: DemoData.codexAgentID, harness: "acp", name: "审"),
            ])
        #expect(direct.lead?.name == "写")

        let fromTeam = try await client.createTeamTemplateFromTeam(name: "发版模板", teamID: DemoData.releaseTeamID)
        #expect(
            fromTeam.members == [
                TemplateMember(agentID: DemoData.codexAgentID, harness: "acp", name: "代码审查", role: .lead),
                TemplateMember(agentID: DemoData.claudeAgentID, harness: "acp", name: "写作助手", role: .member),
            ])
        #expect(
            try await client.teamTemplates().map(\.id) == [DemoData.contentTemplateID, direct.id, fromTeam.id])

        try await client.deleteTeamTemplate(direct.id)
        #expect(try await client.teamTemplates().contains { $0.id == direct.id } == false)
        #expect(await failure { try await client.deleteTeamTemplate(direct.id) } == .api(.notFound))
    }

    @Test("校验：成员数、agent 在目录里、成员名、负责人、团队不存在")
    func validation() async {
        let client = makeClient()
        func create(_ members: [TemplateMember]) async -> Failure? {
            await failure { _ = try await client.createTeamTemplate(name: "t", members: members) }
        }
        let claude = TemplateMember(agentID: DemoData.claudeAgentID, name: "a")
        #expect(await create([]) == .api(.invalid))
        #expect(await create(Array(repeating: claude, count: Team.maxMembers + 1)) == .api(.invalid))
        #expect(await create([TemplateMember(agentID: "gemini", name: "a")]) == .api(.invalid))
        #expect(await create([TemplateMember(agentID: DemoData.claudeAgentID, name: "")]) == .api(.invalid))
        #expect(
            await create([
                TemplateMember(agentID: DemoData.claudeAgentID, name: "a", role: .lead),
                TemplateMember(agentID: DemoData.codexAgentID, name: "b", role: .lead),
            ]) == .api(.invalid))
        #expect(
            await create([TemplateMember(agentID: DemoData.claudeAgentID, name: "a", role: .unknown("x"))])
                == .invalidArgument)
        #expect(
            await failure { _ = try await client.createTeamTemplateFromTeam(name: "t", teamID: "missing") }
                == .api(.notFound))
        #expect(
            await failure { _ = try await client.createTeamTemplate(name: " ", members: [claude]) } == .api(.invalid))
    }

    @Test("一键领养：每个成员一个新实例（没有模型路由），编成团队")
    func adopt() async throws {
        let client = makeClient()
        let team = try await client.adoptTeamTemplate(DemoData.contentTemplateID, name: nil)
        #expect(team.name == "内容团队")
        #expect(team.members.map(\.role) == [.lead, .member, .member])
        #expect(team.members.map(\.position) == [0, 1, 2])
        let instances = try await client.instances()
        #expect(instances.count == 5)
        let adopted = team.members.compactMap { m in instances.first { $0.id == m.instanceID } }
        #expect(adopted.map(\.name) == ["主笔", "资料员", "校对"])
        #expect(adopted.map(\.agentID) == [DemoData.claudeAgentID, DemoData.hermesAgentID, DemoData.codexAgentID])
        #expect(adopted.map(\.harness) == ["acp", "acp", "acp"])
        for instance in adopted {
            #expect(try await client.modelRoutes(instanceID: instance.id).isEmpty, "还没有模型路由")
        }
        #expect(try await client.teams().map(\.id) == [DemoData.releaseTeamID, team.id])

        let named = try await client.adoptTeamTemplate(DemoData.contentTemplateID, name: "第二组")
        #expect(named.name == "第二组")
        #expect(Set(named.members.map(\.instanceID)).isDisjoint(with: team.members.map(\.instanceID)))
        #expect(await failure { _ = try await client.adoptTeamTemplate("missing", name: nil) } == .api(.notFound))
    }

    @Test("领养中途会出错的：先校验，一个实例都不建")
    func adoptIsAllOrNothing() async throws {
        let client = makeClient()
        let template = try await client.createTeamTemplate(
            name: "坏模板",
            members: [
                TemplateMember(agentID: DemoData.claudeAgentID, name: "好的"),
                TemplateMember(agentID: DemoData.codexAgentID, harness: "cli", name: "接入方式不对"),
            ])
        #expect(await failure { _ = try await client.adoptTeamTemplate(template.id, name: nil) } == .api(.invalid))
        #expect(try await client.instances().count == 2)
        #expect(try await client.teams().count == 1)
        #expect(await failure { _ = try await client.adoptTeamTemplate(template.id, name: " ") } == .api(.invalid))
    }
}

// MARK: - 模型 key

@Suite("MockClient：改 key、换 key（11.7）")
struct MockCredentialUpdateTests {
    @Test("改备注、停用：给了才改")
    func update() async throws {
        let client = makeClient()
        let id = DemoData.deepseekCredentialID
        let relabeled = try await client.updateCredential(id, label: "DeepSeek 备用", disabled: nil)
        #expect(relabeled.label == "DeepSeek 备用")
        #expect(!relabeled.isDisabled)
        let disabled = try await client.updateCredential(id, label: nil, disabled: true)
        #expect(disabled.label == "DeepSeek 备用")
        #expect(disabled.isDisabled)
        let both = try await client.updateCredential(id, label: "", disabled: false)
        #expect(both.label == "")
        #expect(!both.isDisabled)
        #expect(try await client.credentials().first { $0.id == id } == both)
        let long = String(repeating: "k", count: Credential.maxLabelLength + 1)
        #expect(
            await failure { _ = try await client.updateCredential(id, label: long, disabled: nil) } == .api(.invalid))
        #expect(
            await failure { _ = try await client.updateCredential("missing", label: "x", disabled: nil) }
                == .api(.notFound))
    }

    @Test("换 key：同一条记录，后 4 位变了")
    func replaceSecret() async throws {
        let client = makeClient()
        let id = DemoData.claudeCredentialID
        let replaced = try await client.replaceCredentialSecret(id, apiKey: "sk-ant-new-key-9Zq1")
        #expect(replaced.id == id)
        #expect(replaced.last4 == "9Zq1")
        #expect(replaced.label == "Claude 主力")
        #expect(await failure { _ = try await client.replaceCredentialSecret(id, apiKey: "short") } == .api(.invalid))
        #expect(
            await failure { _ = try await client.replaceCredentialSecret(id, apiKey: "sk-ant with space") }
                == .api(.invalid))
        #expect(
            await failure { _ = try await client.replaceCredentialSecret("missing", apiKey: "sk-ant-new-key") }
                == .api(.notFound))
    }
}

// MARK: - 内容举报

@Suite("MockClient：内容举报（5.5）")
struct MockReportTests {
    /// 周报运行里 agent 的第一条回复。
    private func weeklyReply(_ client: MockClient) throws -> InstanceEvent {
        try #require(
            client.state.events[writer]?.first { $0.runID == DemoData.weeklyRunID && $0.kind == .agentMessage })
    }

    @Test("举报运行、事件、产出物；同一条再举报返回那一条")
    func report() async throws {
        let client = makeClient()
        let run = try await client.reportRun(DemoData.weeklyRunID, reason: .misinformation, note: "  数字不对  ")
        #expect(run.instanceID == writer)
        #expect(run.target == .run)
        #expect(run.state == .open)
        #expect(run.note == "数字不对")
        let again = try await client.reportContent(
            runID: DemoData.weeklyRunID, eventSeq: nil, artifactID: nil, reason: .other, note: nil)
        #expect(again.id == run.id, "还在待处理的同一条内容不重复建")
        #expect(again.reason == .misinformation)

        let reply = try weeklyReply(client)
        let event = try await client.reportEvent(reply, reason: .harmful)
        #expect(event.target == .event(seq: reply.seq))
        #expect(event.id != run.id)
        let artifact = try await client.reportArtifact(
            try #require(client.state.artifacts.first), reason: .infringement, note: "   ")
        #expect(artifact.target == .artifact(DemoData.weeklyArtifactID))
        #expect(artifact.note == nil, "只有空白的说明当作没写")

        let list = try await client.reports()
        #expect(list.map(\.id) == [artifact.id, event.id, run.id], "新的在前")
    }

    @Test("举报的对象要属于这个运行；原因不认识、说明太长的不行")
    func validation() async throws {
        let client = makeClient()
        func report(
            _ runID: RunID, seq: UInt64? = nil, artifact: ArtifactID? = nil, reason: ReportReason = .other,
            note: String? = nil
        ) async -> Failure? {
            await failure {
                _ = try await client.reportContent(
                    runID: runID, eventSeq: seq, artifactID: artifact, reason: reason, note: note)
            }
        }
        #expect(await report("missing") == .api(.notFound))
        // 这条事件属于周报运行，不属于通知汇总。
        let reply = try weeklyReply(client)
        #expect(await report(DemoData.digestRunID, seq: reply.seq) == .api(.notFound))
        #expect(await report(DemoData.weeklyRunID, seq: 9999) == .api(.notFound))
        // 写作助手的产出物不属于代码审查的运行。
        #expect(await report(DemoData.reviewRunID, artifact: DemoData.weeklyArtifactID) == .api(.notFound))
        #expect(await report(DemoData.weeklyRunID, reason: .unknown("spam")) == .invalidArgument)
        let long = String(repeating: "长", count: ContentReport.maxNoteLength + 1)
        #expect(await report(DemoData.weeklyRunID, note: long) == .api(.invalid))
        #expect(try await client.reports().isEmpty)

        // 不属于运行的事件不能举报。
        let event = InstanceEvent(
            instanceID: writer, seq: 1, runID: nil, kind: .agentMessage, payloadJSON: "{}", createdAt: Date())
        #expect(await failure { _ = try await client.reportEvent(event, reason: .other) } == .invalidArgument)
    }

    @Test("处理结果：标成已处理，发到收件箱；之后再举报同一条是新的一条")
    func resolution() async throws {
        let client = makeClient()
        let report = try await client.reportRun(DemoData.weeklyRunID, reason: .privacy)
        let unread = try client.cachedUnread()
        let closed = try #require(client.resolveReport(report.id, resolution: "已删除相关内容"))
        #expect(closed.state == .closed)
        #expect(closed.resolution == "已删除相关内容")
        #expect(closed.handledAt != nil)
        #expect(try client.cachedUnread() == unread + 1)
        #expect(client.state.inbox.first?.title == "举报已处理")
        #expect(try await client.reports().first?.state == .closed)
        #expect(client.resolveReport("missing", resolution: "x") == nil)

        let fresh = try await client.reportRun(DemoData.weeklyRunID, reason: .privacy)
        #expect(fresh.id != report.id)
        #expect(fresh.isOpen)
    }

    @Test("每人每小时 30 次（再举报同一条也算），超了 rate_limited")
    func rateLimit() async throws {
        let client = makeClient()
        for _ in 0..<ContentReport.maxPerHour {
            _ = try await client.reportRun(DemoData.weeklyRunID, reason: .other)
        }
        do {
            _ = try await client.reportRun(DemoData.digestRunID, reason: .other)
            Issue.record("第 31 次应该被限流")
        } catch let e as ClientError {
            #expect(e.isRateLimited)
            #expect((e.retryAfter ?? 0) > 0)
        }
        #expect(try await client.reports().count == 1)
    }
}
