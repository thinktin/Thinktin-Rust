import Foundation
import Testing

@testable import ThinktinKit

// 领域模型：开放字符串枚举、强类型 id、时间换算、JSONValue、事件载荷解析和各模型的小计算。

// MARK: - 开放字符串枚举

/// 对一个开放字符串枚举做通用检查：每个认识的取值能按原字符串认回来、编解码是单个字符串；
/// 不认识的取值保留原字符串、编码回去不变。
private func checkOpenEnum<E: OpenStringEnum>(
    _ type: E.Type, unknown raw: String = "brand_new_value", sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(!E.knownCases.isEmpty, "\(E.self) 没有认识的取值", sourceLocation: sourceLocation)
    #expect(
        Set(E.knownCases.map(\.rawValue)).count == E.knownCases.count, "\(E.self) 的原字符串有重复",
        sourceLocation: sourceLocation)
    for c in E.knownCases {
        #expect(E(rawValue: c.rawValue) == c, "\(E.self).\(c) 认不回来", sourceLocation: sourceLocation)
        #expect(c.isKnown, sourceLocation: sourceLocation)
        #expect(c.description == c.rawValue, sourceLocation: sourceLocation)
        let json = try jsonString(c)
        #expect(json == "\"\(c.rawValue)\"", sourceLocation: sourceLocation)
        #expect(try decode(E.self, json) == c, sourceLocation: sourceLocation)
    }
    // 泛型里 `E(rawValue:)` 走的是 RawRepresentable 的可失败版本（实现是不会失败的那个），所以要解包。
    let unknown = try #require(E(rawValue: raw), sourceLocation: sourceLocation)
    #expect(!unknown.isKnown, "\(E.self) 把 \(raw) 当成了认识的取值", sourceLocation: sourceLocation)
    #expect(unknown == E.unknown(raw), sourceLocation: sourceLocation)
    #expect(unknown.rawValue == raw, sourceLocation: sourceLocation)
    #expect(try jsonString(unknown) == "\"\(raw)\"", sourceLocation: sourceLocation)
    let decoded = try decode(E.self, "\"\(raw)\"")
    #expect(decoded == unknown, sourceLocation: sourceLocation)
    #expect(decoded.rawValue == raw, sourceLocation: sourceLocation)
    // 数组里有不认识的取值也不会整体解码失败。
    let list = try decode([E].self, "[\"\(E.knownCases[0].rawValue)\", \"\(raw)\"]")
    #expect(list == [E.knownCases[0], unknown], sourceLocation: sourceLocation)
}

@Suite("开放字符串枚举")
struct OpenStringEnumTests {
    @Test("所有枚举：认识的取值往返、不认识的保留原字符串")
    func allEnums() throws {
        try checkOpenEnum(UserStatus.self)
        try checkOpenEnum(DevicePlatform.self)
        try checkOpenEnum(PushChannel.self)
        try checkOpenEnum(UserLocale.self, unknown: "fr-FR")
        try checkOpenEnum(InstanceState.self)
        try checkOpenEnum(RunSource.self)
        try checkOpenEnum(RunKind.self)
        try checkOpenEnum(RunState.self, unknown: "waiting_moon")
        try checkOpenEnum(ApprovalState.self)
        try checkOpenEnum(ApprovalOptionKind.self)
        try checkOpenEnum(DecisionSource.self)
        try checkOpenEnum(ApprovalTimeoutAction.self)
        try checkOpenEnum(PlanAuthor.self)
        try checkOpenEnum(PlanChange.self)
        try checkOpenEnum(InboxKind.self, unknown: "plan_paused")
        try checkOpenEnum(VaultRequestStatus.self)
        try checkOpenEnum(VaultField.self, unknown: "otp")
        try checkOpenEnum(SecretKind.self)
        try checkOpenEnum(ImVendor.self, unknown: "slack")
        try checkOpenEnum(ImEvent.self)
        try checkOpenEnum(ToolCallStatus.self)
        try checkOpenEnum(StopReason.self)
        try checkOpenEnum(APIErrorCode.self, unknown: "payment_required")
        try checkOpenEnum(InstanceEventKind.self, unknown: "agent.future_thing")
    }

    @Test("服务端的原字符串（snake_case、带点）")
    func wireValues() {
        #expect(RunState(rawValue: "waiting_approval") == .waitingApproval)
        #expect(RunState(rawValue: "waiting_device") == .waitingDevice)
        #expect(RunState(rawValue: "waiting_quota") == .waitingQuota)
        #expect(RunState(rawValue: "waiting_children") == .waitingChildren)
        #expect(InstanceState(rawValue: "archived") == .archived)
        #expect(InboxKind(rawValue: "run_finished") == .runFinished)
        #expect(InboxKind(rawValue: "run_failed") == .runFailed)
        #expect(ApprovalState(rawValue: "expired") == .expired)
        #expect(VaultRequestStatus(rawValue: "declined") == .declined)
        #expect(ApprovalOptionKind(rawValue: "reject_always") == .rejectAlways)
        #expect(ApprovalTimeoutAction(rawValue: "pause_plan") == .pausePlan)
        #expect(UserLocale(rawValue: "zh-CN") == .zhCN)
        #expect(SecretKind(rawValue: "high_entropy") == .highEntropy)
        #expect(ToolCallStatus(rawValue: "in_progress") == .inProgress)
        #expect(StopReason(rawValue: "max_turn_requests") == .maxTurnRequests)
        #expect(APIErrorCode(rawValue: "session_revoked") == .sessionRevoked)
        #expect(APIErrorCode(rawValue: "internal") == .internal)
        #expect(InstanceEventKind(rawValue: "agent.tool_call_update") == .toolCallUpdate)
        #expect(InstanceEventKind(rawValue: "pipeline.step_started") == .pipelineStepStarted)
        #expect(InstanceEventKind(rawValue: "run.log_truncated") == .runLogTruncated)
        // 大小写不同就是不认识的取值（服务端的取值都是小写）。
        #expect(!RunState(rawValue: "RUNNING").isKnown)
    }

    @Test("运行状态的分类")
    func runStateClassification() {
        let terminal: [RunState] = [.succeeded, .failed, .cancelled]
        let waiting: [RunState] = [.waitingApproval, .waitingDevice, .waitingQuota, .waitingChildren]
        for s in RunState.knownCases {
            #expect(s.isTerminal == terminal.contains(s), "\(s)")
            #expect(s.isWaiting == waiting.contains(s), "\(s)")
            #expect(s.isActive == !s.isTerminal, "\(s)")
        }
        // 不认识的状态当作还没结束（可以取消），也不算等待。
        let future = RunState(rawValue: "hibernating")
        #expect(!future.isTerminal)
        #expect(future.isActive)
        #expect(!future.isWaiting)
    }

    @Test("审批选项：批准 / 拒绝，不认识的按前缀")
    func approvalOptionKind() {
        #expect(ApprovalOptionKind.allowOnce.isAllow)
        #expect(ApprovalOptionKind.allowAlways.isAllow)
        #expect(!ApprovalOptionKind.rejectOnce.isAllow)
        #expect(ApprovalOptionKind.rejectAlways.isReject)
        #expect(ApprovalOptionKind(rawValue: "allow_for_session").isAllow)
        #expect(ApprovalOptionKind(rawValue: "reject_forever").isReject)
        let other = ApprovalOptionKind(rawValue: "ask_later")
        #expect(!other.isAllow && !other.isReject)
    }

    @Test("其他枚举上的计算属性")
    func misc() {
        #expect(VaultRequestStatus.pending.isResolved == false)
        #expect(VaultRequestStatus.fulfilled.isResolved)
        #expect(VaultRequestStatus(rawValue: "revoked").isResolved)
        #expect(ToolCallStatus.completed.isFinished)
        #expect(ToolCallStatus.failed.isFinished)
        #expect(!ToolCallStatus.inProgress.isFinished)
        #expect(InstanceEventKind.agentMessage.isAIGenerated)
        #expect(InstanceEventKind.agentThought.isAIGenerated)
        #expect(InstanceEventKind.agentPlan.isAIGenerated)
        #expect(!InstanceEventKind.toolCall.isAIGenerated)
        #expect(!InstanceEventKind.runState.isAIGenerated)
        #expect(UsageGroup.allCases.map(\.rawValue) == ["day", "instance", "model", "credential"])
    }

    @Test("从系统语言标签认出用户语言", arguments: [
        ("zh-Hans-CN", UserLocale.zhCN), ("zh_TW", .zhCN), ("zh", .zhCN), ("en_US", .en), ("EN-gb", .en),
        (" en ", .en),
    ])
    func userLocaleFromTag(tag: String, expected: UserLocale) {
        #expect(UserLocale(languageTag: tag) == expected)
    }

    @Test("认不出的语言标签")
    func userLocaleUnknownTag() {
        #expect(UserLocale(languageTag: "fr-FR") == nil)
        #expect(UserLocale(languageTag: "") == nil)
    }

    @Test("界面语言")
    func displayLanguage() {
        #expect(DisplayLanguage(languageTag: "zh-Hans-CN") == .chinese)
        #expect(DisplayLanguage(languageTag: "ZH_tw") == .chinese)
        #expect(DisplayLanguage(languageTag: "en-US") == .english)
        #expect(DisplayLanguage(languageTag: "ja-JP") == .english)
        #expect(DisplayLanguage.chinese.userLocale == .zhCN)
        #expect(DisplayLanguage.english.userLocale == .en)
        #expect(DisplayLanguage.chinese.aiGeneratedLabel == "AI 生成")
        #expect(DisplayLanguage.english.aiGeneratedLabel == "AI-generated")
        #expect(DisplayLanguage.chinese.locale.identifier == "zh_CN")
    }
}

// MARK: - 强类型 id

@Suite("强类型 id")
struct IdentifierTests {
    @Test("Hashable：按原字符串比较、去重")
    func hashable() {
        let a: RunID = "0192f3a0-0000-7000-8000-000000000201"
        let b = RunID("0192f3a0-0000-7000-8000-000000000201")
        let c = RunID(rawValue: "other")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b, c]).count == 2)
        var dict: [RunID: Int] = [:]
        dict[a] = 1
        dict[b, default: 0] += 1
        #expect(dict[a] == 2)
        #expect(a.description == a.rawValue)
    }

    @Test("Comparable：按原字符串（UUIDv7 也就是按时间）")
    func comparable() {
        let ids: [InboxItemID] = ["0192f3a0-0000-7000-8000-000000001003", "0192f3a0-0000-7000-8000-000000001001"]
        #expect(ids.sorted().map(\.rawValue).first == "0192f3a0-0000-7000-8000-000000001001")
    }

    @Test("Codable：编成单个字符串")
    func codable() throws {
        let id: InstanceID = "inst-42"
        #expect(try jsonString(id) == "\"inst-42\"")
        #expect(try decode(InstanceID.self, "\"inst-42\"") == id)
        #expect(try jsonString([id, "inst-43"]) == "[\"inst-42\",\"inst-43\"]")
        // 做字典的值、在模型里都是字符串。
        let route = RouteFallback(credentialID: "cred-1", upstreamModel: "deepseek-v4-pro")
        let json = try jsonString(route)
        #expect(json.contains("\"credentialID\":\"cred-1\""))
        #expect(try decode(RouteFallback.self, json) == route)
        // 不是字符串时解码失败。
        #expect(throws: DecodingError.self) { try decode(InstanceID.self, "42") }
    }

    @Test("随机 id 是小写 UUID，不重复")
    func random() {
        let a = PlanID.random()
        let b = PlanID.random()
        #expect(a != b)
        #expect(UUID(uuidString: a.rawValue) != nil)
        #expect(a.rawValue == a.rawValue.lowercased())
    }
}

// MARK: - 时间

@Suite("Date 与 Unix 毫秒")
struct DateMillisecondsTests {
    @Test("往返", arguments: [Int64(0), 1, 999, 1_700_000_000_123, 1_792_548_000_000, -1_500, -86_400_000])
    func roundTrip(ms: Int64) {
        let date = Date(unixMilliseconds: ms)
        // Date 内部存的是距 2001 年的秒数（Double），换回 1970 起点会有极小误差，靠四舍五入到整毫秒消掉。
        #expect(date.unixMilliseconds == ms)
        #expect(abs(date.timeIntervalSince1970 - TimeInterval(ms) / 1000) < 1e-6)
    }

    @Test("不足一毫秒的部分四舍五入")
    func rounding() {
        #expect(Date(timeIntervalSince1970: 1.2344).unixMilliseconds == 1_234)
        #expect(Date(timeIntervalSince1970: 1.2346).unixMilliseconds == 1_235)
        #expect(Date(timeIntervalSince1970: 0).unixMilliseconds == 0)
    }
}

// MARK: - JSONValue

@Suite("JSONValue")
struct JSONValueTests {
    @Test("解析各种值")
    func parse() throws {
        let v = try #require(
            JSONValue.parse(
                #"{"s":"文本","n":42,"f":1.5,"t":true,"f2":false,"z":null,"a":[1,"x",[]],"o":{"k":"v"}}"#))
        #expect(v["s"] == .string("文本"))
        #expect(v["n"] == .number(42))
        #expect(v["n"]?.intValue == 42)
        #expect(v["f"]?.doubleValue == 1.5)
        #expect(v["f"]?.intValue == nil)
        #expect(v["t"] == .bool(true))
        #expect(v["f2"]?.boolValue == false)
        #expect(v["z"] == .null)
        #expect(v["z"]?.isNull == true)
        #expect(v["a"]?[0] == 1)
        #expect(v["a"]?[1]?.stringValue == "x")
        #expect(v["a"]?[2] == .array([]))
        #expect(v["a"]?[9] == nil)
        #expect(v["o"]?["k"] == "v")
        #expect(v["missing"] == nil)
        #expect(v.objectValue?.count == 8)
        #expect(v["a"]?.arrayValue?.count == 3)
        // 类型不对的取值器返回 nil。
        #expect(v["s"]?.intValue == nil)
        #expect(v["n"]?.stringValue == nil)
        #expect(v["s"]?["k"] == nil)
        #expect(v[0] == nil)
    }

    @Test("true / false 不会被当成数字，1 / 0 不会被当成布尔")
    func boolVersusNumber() {
        #expect(JSONValue.parse("[true, 1, 0, false]") == .array([.bool(true), .number(1), .number(0), .bool(false)]))
    }

    @Test("顶层是标量也能解析")
    func fragments() {
        #expect(JSONValue.parse("\"x\"") == .string("x"))
        #expect(JSONValue.parse("3") == .number(3))
        #expect(JSONValue.parse("null") == .null)
    }

    @Test("不是合法 JSON 时为 nil")
    func invalid() {
        #expect(JSONValue.parse("") == nil)
        #expect(JSONValue.parse("{") == nil)
        #expect(JSONValue.parse("not json") == nil)
        #expect(JSONValue.parse("{'single': 1}") == nil)
    }

    @Test("字面量")
    func literals() {
        let v: JSONValue = ["a": 1, "b": [true, nil, "s", 2.5]]
        #expect(v == .object(["a": .number(1), "b": .array([.bool(true), .null, .string("s"), .number(2.5)])]))
        let name = "张三"
        let interpolated: JSONValue = "hi \(name)"
        #expect(interpolated == .string("hi 张三"))
    }

    @Test("编码：紧凑、键排序；往返不变")
    func encoding() throws {
        let v: JSONValue = ["b": [1, 2], "a": "x/y", "c": nil]
        #expect(v.compactString() == #"{"a":"x/y","b":[1,2],"c":null}"#)
        #expect(JSONValue.parse(v.compactString()) == v)
        let pretty = v.prettyPrinted()
        #expect(pretty.contains("\n"))
        #expect(JSONValue.parse(pretty) == v)
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == v)
    }

    @Test("整数取值器的边界")
    func intValue() {
        #expect(JSONValue.number(-3).intValue == -3)
        #expect(JSONValue.number(1e16).intValue == nil)
        #expect(JSONValue.number(2.0).intValue == 2)
    }

    @Test("浅合并")
    func merging() {
        let base: JSONValue = ["a": 1, "b": ["x": 1]]
        #expect(base.merging(["b": ["y": 2], "c": 3]) == ["a": 1, "b": ["y": 2], "c": 3])
        #expect(base.merging("replaced") == "replaced")
        #expect(JSONValue.string("s").merging(["a": 1]) == ["a": 1])
    }
}

// MARK: - 事件载荷

@Suite("事件载荷解析")
struct EventPayloadTests {
    @Test("工具调用：snake_case 和 camelCase 都认，缺的字段从 raw 里补")
    func toolCall() throws {
        let p = try #require(
            ToolCallPayload(
                json: #"{"tool_call_id":"tc-1","title":"读文件","kind":"read","status":"in_progress","raw":{"toolCallId":"tc-1","rawInput":{"path":"a.md"}}}"#
            ))
        #expect(p.toolCallID == "tc-1")
        #expect(p.title == "读文件")
        #expect(p.kind == "read")
        #expect(p.status == .inProgress)
        #expect(p.raw?["rawInput"]?["path"] == "a.md")

        // 审批里的 tool_call 是 ACP 原文（camelCase），本身就是 raw。
        let acp = try #require(
            ToolCallPayload(json: #"{"toolCallId":"tc-2","title":"执行","kind":"execute","status":"pending"}"#))
        #expect(acp.toolCallID == "tc-2")
        #expect(acp.title == "执行")
        #expect(acp.status == .pending)
        #expect(acp.raw?["toolCallId"] == "tc-2")

        // tool_call_update 只有 raw：标题、状态从 raw 里补。
        let update = try #require(
            ToolCallPayload(json: #"{"tool_call_id":"tc-1","raw":{"title":"读完了","status":"completed"}}"#))
        #expect(update.title == "读完了")
        #expect(update.status == .completed)
        #expect(update.kind == nil)

        // raw 是 null 时当作没有，不会把 null 当原始内容。
        let nullRaw = try #require(ToolCallPayload(json: #"{"tool_call_id":"tc-3","status":"failed","raw":null}"#))
        #expect(nullRaw.raw == nil)
        #expect(nullRaw.status == .failed)

        #expect(ToolCallPayload(json: "[1,2]") == nil)
        #expect(ToolCallPayload(json: "oops") == nil)
    }

    @Test("审批请求：选项、工具调用")
    func permissionRequested() throws {
        let json =
            #"{"request_id":"r1","title":"运行 rm","options":[{"option_id":"ok","name":"允许","kind":"allow_once"},{"option_id":"no","kind":"reject_once"}],"tool_call":{"toolCallId":"tc-9"}}"#
        guard case .permissionRequested(let p) = EventPayload(kind: .permissionRequested, json: json) else {
            Issue.record("没解析成 permissionRequested")
            return
        }
        #expect(p.requestID == "r1")
        #expect(p.title == "运行 rm")
        #expect(p.options.map(\.id) == ["ok", "no"])
        #expect(p.options[0].kind == .allowOnce)
        // 没有名字时用 option_id。
        #expect(p.options[1].name == "no")
        #expect(p.toolCall?["toolCallId"] == "tc-9")
        // 编码回去还是服务端的字段名。
        let roundTrip = try decode(PermissionRequestedPayload.self, try jsonString(p))
        #expect(roundTrip == p)
    }

    @Test("审批结果：by 缺省、option_id 为空")
    func permissionResolved() throws {
        let p = try decode(PermissionResolvedPayload.self, #"{"request_id":"r1","option_id":null,"by":"timeout"}"#)
        #expect(p.optionID == nil)
        #expect(p.by == .timeout)
        let noBy = try decode(PermissionResolvedPayload.self, #"{"request_id":"r1"}"#)
        #expect(noBy.by == .unknown(""))
    }

    @Test("每种 kind 都解析成对应的载荷", arguments: [
        (InstanceEventKind.agentMessage, #"{"text":"hi"}"#, "message"),
        (.agentThought, #"{"text":"hmm"}"#, "thought"),
        (.toolCall, #"{"tool_call_id":"t"}"#, "toolCall"),
        (.toolCallUpdate, #"{"tool_call_id":"t"}"#, "toolCallUpdate"),
        (.platformToolCall, #"{"call_id":"c","name":"schedule_create","arguments":{}}"#, "platformToolCall"),
        (.agentPlan, #"{"entries":[{"content":"a","status":"pending"}]}"#, "agentPlan"),
        (.permissionRequested, #"{"request_id":"r","options":[]}"#, "permissionRequested"),
        (.permissionResolved, #"{"request_id":"r","by":"user"}"#, "permissionResolved"),
        (.approvalDecided, #"{"approval_id":"a","state":"approved","option_id":"ok"}"#, "approvalDecided"),
        (.vaultRequested, #"{"request_id":"v","name":"npm","purpose":"p","fields":["password"]}"#, "vaultRequested"),
        (.vaultFulfilled, #"{"request_id":"v","name":"npm"}"#, "vaultFulfilled"),
        (.vaultDeclined, #"{"request_id":"v"}"#, "vaultDeclined"),
        (.vaultUsed, #"{"names":["github"]}"#, "vaultUsed"),
        (.runState, #"{"state":"running"}"#, "runState"),
        (.artifactPublished, #"{"artifact_id":"a","name":"x.md","version":2,"size":10}"#, "artifactPublished"),
        (.pipelineStepStarted, #"{"step":"build","run_id":"r","instance_id":"i"}"#, "pipelineStepStarted"),
        (.delegateStarted, #"{"child_run_id":"r","instance_id":"i","to":"审查","title":null}"#, "delegateStarted"),
        (.planNeedsConfirmation, #"{"plan_id":"p","title":"t","change":"created"}"#, "planNeedsConfirmation"),
        (.planCancelled, #"{"plan_id":"p","title":"t"}"#, "planCancelled"),
        (.turnEnded, #"{"stop_reason":"end_turn"}"#, "turnEnded"),
        (.agentError, #"{"message":"boom"}"#, "agentError"),
        (.agentSessionLost, #"{"previous_session_id":"s","reason":"gone"}"#, "sessionLost"),
        (.agentExited, #"{"code":1,"will_restart":true,"restarts":2}"#, "agentExited"),
        (.runLogTruncated, #"{"limit_bytes":1048576}"#, "logTruncated"),
        (.agentUsage, #"{"raw":{"input_tokens":1}}"#, "other"),
        (.agentReady, #"{}"#, "other"),
        (.unknown("x.y"), #"{"a":1}"#, "other"),
    ])
    func kinds(kind: InstanceEventKind, json: String, expected: String) {
        let payload = EventPayload(kind: kind, json: json)
        #expect(payloadTag(payload) == expected)
    }

    @Test("载荷不对时退回 other，并保留原始 JSON")
    func fallback() {
        #expect(EventPayload(kind: .runState, json: #"{"reason":"no state"}"#) == .other(["reason": "no state"]))
        #expect(EventPayload(kind: .agentMessage, json: "not json") == .other(nil))
        #expect(EventPayload(kind: .artifactPublished, json: #"{"name":"x"}"#) == .other(["name": "x"]))
    }

    @Test("缺字段时的缺省值")
    func defaults() throws {
        let text = try decode(TextPayload.self, "{}")
        #expect(text.text == "")
        let vault = try decode(VaultRequestedPayload.self, #"{"request_id":"v"}"#)
        #expect(vault.fields == [.password])
        #expect(vault.name == "")
        let artifact = try decode(ArtifactPublishedPayload.self, #"{"artifact_id":"a"}"#)
        #expect(artifact.version == 1)
        #expect(artifact.size == 0)
        let exited = try decode(AgentExitedPayload.self, "{}")
        #expect(exited.code == nil)
        #expect(!exited.willRestart)
        let plan = try decode(AgentPlanPayload.self, #"{"entries":"oops"}"#)
        #expect(plan.entries.isEmpty)
    }

    @Test("平台工具的类别", arguments: [
        ("schedule_create", PlatformToolCategory.plan), ("plan_update", .plan), ("artifact_publish", .artifact),
        ("delegate", .delegate), ("delegate_status", .delegate), ("vault_request", .vault), ("computer_click", .computer),
        ("desktop_screenshot", .computer), ("web_search", .other),
    ])
    func platformCategory(name: String, expected: PlatformToolCategory) {
        #expect(PlatformToolCategory(toolName: name) == expected)
        #expect(PlatformToolCallPayload(callID: "c", name: name).category == expected)
    }

    @Test("InstanceEvent 的便捷属性")
    func instanceEvent() {
        let e = InstanceEvent(
            instanceID: "i", seq: 7, runID: "r", kind: .runState, payloadJSON: #"{"state":"waiting_device","attempt":2}"#,
            createdAt: Fixture.now)
        #expect(e.id == "i#7")
        #expect(e.runStatePayload?.state == .waitingDevice)
        #expect(e.runStatePayload?.attempt == 2)
        #expect(e.toolCallPayload == nil)
        #expect(e.payloadValue?["state"] == "waiting_device")
        #expect(!e.isAIGenerated)
        // 是否 AI 生成默认按 kind，也可以由服务端显式给。
        let message = InstanceEvent(
            instanceID: "i", seq: 8, runID: "r", kind: .agentMessage, payloadJSON: "{}", createdAt: Fixture.now)
        #expect(message.isAIGenerated)
        let explicit = InstanceEvent(
            instanceID: "i", seq: 9, runID: "r", kind: .agentMessage, payloadJSON: "{}", isAIGenerated: false,
            createdAt: Fixture.now)
        #expect(!explicit.isAIGenerated)
    }

    @Test("事件流状态")
    func streamStatus() {
        #expect(StreamStatus.connecting.isConnecting)
        #expect(StreamStatus.reconnecting(retryIn: 2).isConnecting)
        #expect(!StreamStatus.live.isConnecting)
        for s in [StreamStatus.signedOut, .notFound, .accountFrozen, .stopped] {
            #expect(s.isFinal)
        }
        #expect(!StreamStatus.live.isFinal)
        #expect(!StreamStatus.reconnecting(retryIn: 1).isFinal)
    }
}

private func payloadTag(_ p: EventPayload) -> String {
    switch p {
    case .message: "message"
    case .thought: "thought"
    case .toolCall: "toolCall"
    case .toolCallUpdate: "toolCallUpdate"
    case .platformToolCall: "platformToolCall"
    case .agentPlan: "agentPlan"
    case .permissionRequested: "permissionRequested"
    case .permissionResolved: "permissionResolved"
    case .approvalDecided: "approvalDecided"
    case .vaultRequested: "vaultRequested"
    case .vaultFulfilled: "vaultFulfilled"
    case .vaultDeclined: "vaultDeclined"
    case .vaultUsed: "vaultUsed"
    case .runState: "runState"
    case .artifactPublished: "artifactPublished"
    case .pipelineStepStarted: "pipelineStepStarted"
    case .delegateStarted: "delegateStarted"
    case .planNeedsConfirmation: "planNeedsConfirmation"
    case .planCancelled: "planCancelled"
    case .turnEnded: "turnEnded"
    case .agentError: "agentError"
    case .sessionLost: "sessionLost"
    case .agentExited: "agentExited"
    case .logTruncated: "logTruncated"
    case .other: "other"
    }
}

// MARK: - 模型上的小计算

@Suite("模型")
struct ModelComputationTests {
    @Test("手机号打码、显示名")
    func user() {
        #expect(User.maskedPhone("+8613800138000") == "138****8000")
        #expect(User.maskedPhone("13800138000") == "138****8000")
        #expect(User.maskedPhone("+86123") == "+86123")
        let named = User(id: "u", phone: "+8613800138000", displayName: "张三", createdAt: Fixture.now)
        #expect(named.nameForDisplay == "张三")
        let anonymous = User(id: "u", phone: "+8613800138000", displayName: "", createdAt: Fixture.now)
        #expect(anonymous.nameForDisplay == "138****8000")
    }

    @Test("会话的描述里不打印令牌")
    func sessionDescription() {
        let s = Session(userID: "u1", deviceID: "d1", accessToken: "secret-access", refreshToken: "secret-refresh")
        for text in [s.description, s.debugDescription, String(describing: s), String(reflecting: s)] {
            #expect(!text.contains("secret"))
        }
        let item = NewVaultItem(name: "github", purpose: "p", username: "me", password: "hunter2")
        #expect(!String(describing: item).contains("hunter2"))
        let cred = NewCredential(vendor: "anthropic", label: "主力", apiKey: "sk-ant-xyz")
        #expect(!String(describing: cred).contains("sk-ant"))
        let channel = NewImChannel(webhookURL: "https://open.feishu.cn/hook/abc", secret: "s3", label: "群")
        #expect(!String(describing: channel).contains("abc"))
        let update = VaultItemUpdate(password: "hunter2")
        #expect(!String(describing: update).contains("hunter2"))
        #expect(String(describing: update).contains("passwordChanged: true"))
    }

    @Test("APNs 令牌转十六进制")
    func pushRegistration() {
        let r = PushRegistration.apns(deviceToken: Data([0x00, 0xAB, 0x0F, 0xFF]))
        #expect(r.channel == .apns)
        #expect(r.token == "00ab0fff")
    }

    @Test("运行：根、时长")
    func run() {
        let start = Fixture.now
        var r = Run(id: "r", instanceID: "i", prompt: "p", createdAt: start)
        #expect(r.rootRunID == r.id)
        #expect(r.isRoot)
        #expect(r.duration(now: start) == nil)
        r.startedAt = start
        #expect(r.duration(now: start.addingTimeInterval(30)) == 30)
        r.finishedAt = start.addingTimeInterval(12)
        #expect(r.duration(now: start.addingTimeInterval(99)) == 12)
        let child = Run(id: "c", instanceID: "i", parentRunID: "r", rootRunID: "r", prompt: "p", createdAt: start)
        #expect(!child.isRoot)
        #expect(child.rootRunID == "r")
    }

    @Test("产出物的类型")
    func artifact() {
        func make(_ type: String) -> Artifact {
            Artifact(id: "a", instanceID: "i", runID: "r", name: "x", contentType: type, size: 1, createdAt: Fixture.now)
        }
        #expect(make("text/plain").isText)
        #expect(make("application/json").isText)
        #expect(make("text/markdown; charset=utf-8").isText)
        #expect(!make("application/pdf").isText)
        #expect(make("image/png").isImage)
    }

    @Test("审批：工具调用、过期")
    func approval() {
        let a = DemoData.state(now: Fixture.now).approvals[0]
        #expect(a.isPending)
        #expect(a.toolCall?.toolCallID == "tc-post-1")
        #expect(a.toolCall?.kind == "execute")
        #expect(!a.isExpired(now: a.createdAt))
        #expect(a.isExpired(now: a.expiresAt))
        var expired = a
        expired.state = .expired
        #expect(expired.isExpired(now: a.createdAt))
        var approved = a
        approved.state = .approved
        #expect(!approved.isExpired(now: a.expiresAt.addingTimeInterval(1)))
        let broken = Approval(
            id: "x", runID: "r", instanceID: "i", title: nil, options: [], toolCallJSON: "nope", expiresAt: Fixture.now,
            createdAt: Fixture.now)
        #expect(broken.toolCall == nil)
    }

    @Test("计划：策略解析（缺的字段用默认值）、最近触发时间")
    func plan() throws {
        let demo = DemoData.state(now: Fixture.now)
        let digest = try #require(demo.plans.first { $0.id == DemoData.digestPlanID })
        let policy = try #require(digest.policy)
        #expect(policy.preauthorizedTools == ["read", "search", "fetch"])
        #expect(policy.approvalTimeoutSecs == 3600)
        #expect(policy.onApprovalTimeout == .skip)
        #expect(policy.budget.maxTokens == 50_000)
        #expect(policy.budget.maxDurationSecs == 1800)
        #expect(policy.waitTimeoutSecs == 24 * 3600)
        #expect(policy.dailyTokenLimit == nil)

        var p = digest
        p.policyJSON = "{}"
        #expect(p.policy == PlanPolicy())
        p.policyJSON = #"{"on_approval_timeout":"hibernate"}"#
        #expect(p.policy?.onApprovalTimeout == .unknown("hibernate"))
        p.policyJSON = "not json"
        #expect(p.policy == nil)

        // 策略编码后能原样解回来（服务端的字段名）。
        let encoded = try jsonString(policy)
        #expect(encoded.contains("\"preauthorized_tools\""))
        #expect(try decode(PlanPolicy.self, encoded) == policy)

        let soon = Fixture.now.addingTimeInterval(60)
        let later = Fixture.now.addingTimeInterval(3600)
        p.triggers = [
            Trigger(id: "t1", schedule: .rrule("FREQ=DAILY"), nextFireAt: later),
            Trigger(id: "t2", schedule: .once(soon), isEnabled: false, nextFireAt: soon),
            Trigger(id: "t3", schedule: .cron(expression: "0 9 * * *", timeZone: "Asia/Shanghai")),
        ]
        #expect(p.nextFireAt == later)
        #expect(!p.isPipeline)
        p.steps = [PlanStep(key: "build", instanceID: "i", prompt: "编译")]
        #expect(p.isPipeline)
    }

    @Test("触发规则的编解码")
    func scheduleCodable() throws {
        let schedules: [Schedule] = [
            .cron(expression: "0 9 * * 1-5", timeZone: "Asia/Shanghai"), .rrule("FREQ=WEEKLY;BYDAY=MO"),
            .once(Date(unixMilliseconds: 1_792_548_000_000)),
        ]
        let data = try JSONEncoder().encode(schedules)
        #expect(try JSONDecoder().decode([Schedule].self, from: data) == schedules)
    }

    @Test("agent 目录、模型路由、保险箱、用量")
    func misc() {
        let claude = DemoData.agents[0]
        #expect(!claude.hasUpgrade(from: "0.90.0"))
        #expect(claude.hasUpgrade(from: "0.89.2"))
        let route = ModelRoute(alias: "main", credentialID: "c", upstreamModel: "m")
        #expect(route.isMain)
        #expect(route.id == "main")
        #expect(!ModelRoute(alias: "fast", credentialID: "c", upstreamModel: "m").isMain)

        let item = VaultItem(id: "v", name: "github", purpose: "p", createdAt: Fixture.now)
        #expect(item.reference == "[vault:github]")
        #expect(item.updatedAt == item.createdAt)
        #expect(item.isAvailableToAllInstances)
        #expect(VaultRequest(id: "r", instanceID: "i", name: "n", purpose: "p", createdAt: Fixture.now, expiresAt: Fixture.now).needsUsername)
        #expect(
            !VaultRequest(
                id: "r", instanceID: "i", name: "n", purpose: "p", fields: [.password], createdAt: Fixture.now,
                expiresAt: Fixture.now
            ).needsUsername)

        let bucket = UsageBucket(key: "k", inputTokens: 10, cacheReadTokens: 5, cacheWriteTokens: 2, outputTokens: 3)
        #expect(bucket.totalTokens == 20)
        #expect(Credential(id: "c", vendor: "v", label: "l", last4: "abcd", createdAt: Fixture.now).maskedKey == "••••abcd")
    }

    @Test("认出的密码在原文里的范围（UTF-16 下标）")
    func detectedSecretRange() throws {
        let text = "😀 密码：hunter22 好"
        let ns = text as NSString
        let r = ns.range(of: "hunter22")
        let secret = DetectedSecret(
            kind: .labeled, utf16Range: r.location..<(r.location + r.length), value: "hunter22", suggestedName: "password")
        let range = try #require(secret.range(in: text))
        #expect(String(text[range]) == "hunter22")
        #expect(secret.id == r.location)
        #expect(!secret.description.contains("hunter22"))
        let outOfBounds = DetectedSecret(kind: .labeled, utf16Range: 0..<999, value: "", suggestedName: "x")
        #expect(outOfBounds.range(in: text) == nil)
        // 落在代理对中间的下标认不出来。
        let split = DetectedSecret(kind: .labeled, utf16Range: 1..<3, value: "", suggestedName: "x")
        #expect(split.range(in: text) == nil)
    }
}
