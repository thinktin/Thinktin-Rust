package cn.thinktin.data.mock

import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.Device
import cn.thinktin.data.model.DevicePlatform
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.ImChannel
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.model.RouteFallback
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.model.TeamTemplate
import cn.thinktin.data.model.TemplateMember
import cn.thinktin.data.model.Trigger
import cn.thinktin.data.model.UsageBucket
import cn.thinktin.data.model.User
import cn.thinktin.data.model.VaultItem
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.VendorInfo
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * 演示数据（确定性：结构固定，时间相对于 [baseMs]）。
 * 3 个目录 agent；2 个实例（一个运行中、一个已暂停）；每个实例若干运行，事件覆盖第 8.2 节的每一种 kind
 * （含等待审批、失败、流水线子运行、委派）；5 种收件箱条目；2 个计划（一个待确认）；key、厂商、保险箱。
 */
internal class MockData(private val baseMs: Long) {

    private fun ago(minutes: Long): Long = baseMs - minutes * MINUTE

    val user = User(
        id = "user-demo",
        phone = "+86 138****0000",
        displayName = "演示用户",
        status = "active",
        locale = "zh-CN",
        createdAtMs = ago(60L * 24 * 90),
    )

    val agents = listOf(
        AgentInfo(
            id = AGENT_CODER, name = "代码助手", version = "1.4.0", license = "Apache-2.0",
            sites = listOf("github.com"), harnesses = listOf("claude-code", "codex"), defaultHarness = "claude-code",
            versions = listOf("1.4.0", "1.3.2"),
        ),
        AgentInfo(
            id = AGENT_RESEARCH, name = "调研助手", version = "0.9.2", license = "MIT",
            sites = emptyList(), harnesses = listOf("codex"), defaultHarness = "codex",
            versions = listOf("0.9.2"),
        ),
        AgentInfo(
            id = AGENT_WRITER, name = "写作助手", version = "2.0.1", license = null,
            sites = emptyList(), harnesses = listOf("claude-code"), defaultHarness = "claude-code",
            versions = listOf("2.0.1", "2.0.0", "1.9.0"),
        ),
    )

    val instances = listOf(
        Instance(
            id = INSTANCE_CODER, agentId = AGENT_CODER, agentVersion = "1.4.0", harness = "claude-code",
            name = "小码", state = InstanceState.Running, createdAtMs = ago(60L * 24 * 30), lastActiveAtMs = ago(2),
        ),
        Instance(
            id = INSTANCE_RESEARCH, agentId = AGENT_RESEARCH, agentVersion = "0.9.2", harness = "codex",
            name = "研究员", state = InstanceState.Paused, createdAtMs = ago(60L * 24 * 20), lastActiveAtMs = ago(60L * 24),
        ),
    )

    private fun run(
        id: String,
        instanceId: String,
        prompt: String,
        state: RunState,
        createdMinutesAgo: Long,
        durationMinutes: Long?,
        source: RunSource = RunSource.User,
        kind: RunKind = RunKind.Agent,
        planId: String? = null,
        parent: String? = null,
        root: String = id,
        stepKey: String? = null,
        tokens: Long = 0,
        summary: String? = null,
        error: String? = null,
        reason: String? = null,
        attempt: Int = 1,
    ): Run {
        val created = ago(createdMinutesAgo)
        val started = if (state == RunState.Queued) null else created + 2_000
        return Run(
            id = id, kind = kind, instanceId = instanceId, planId = planId, parentRunId = parent, rootRunId = root,
            stepKey = stepKey, source = source, prompt = prompt, state = state, stateReason = reason,
            attempt = attempt, tokensUsed = tokens, summary = summary, error = error, createdAtMs = created,
            startedAtMs = started,
            finishedAtMs = if (state.isTerminal && started != null) started + (durationMinutes ?: 1) * MINUTE else null,
        )
    }

    val runs: List<Run> = listOf(
        run(
            RUN_LIVE, INSTANCE_CODER, "给登录页加单元测试", RunState.Running, 2, null, tokens = 3_420,
        ),
        run(
            RUN_WAITING, INSTANCE_CODER, "清理 build 目录里的旧产物", RunState.WaitingApproval, 20, null,
            tokens = 1_830, reason = "等待你批准删除文件",
        ),
        run(
            RUN_DONE, INSTANCE_CODER, "把 README 翻译成英文", RunState.Succeeded, 180, 4, tokens = 12_840,
            summary = "已翻译并提交 README.en.md",
        ),
        run(
            RUN_FAILED, INSTANCE_CODER, "每日依赖检查", RunState.Failed, 60L * 24, 3, source = RunSource.Plan,
            planId = PLAN_DAILY, tokens = 2_210, error = "上游仓库连接超时（重试 3 次后放弃）", attempt = 3,
        ),
        run(
            RUN_PIPELINE, INSTANCE_CODER, "调研竞品并写周报", RunState.Succeeded, 60L * 48, 25, kind = RunKind.Pipeline,
            tokens = 0, summary = "2 个步骤全部完成",
        ),
        run(
            RUN_PIPELINE_WRITE, INSTANCE_CODER, "根据调研结果写周报", RunState.Succeeded, 60L * 48 - 15, 9,
            source = RunSource.Pipeline, parent = RUN_PIPELINE, root = RUN_PIPELINE, stepKey = "write", tokens = 8_120,
            summary = "周报已生成：weekly-report.md",
        ),
        run(
            RUN_PIPELINE_RESEARCH, INSTANCE_RESEARCH, "调研三家竞品的定价", RunState.Succeeded, 60L * 48 - 1, 13,
            source = RunSource.Pipeline, parent = RUN_PIPELINE, root = RUN_PIPELINE, stepKey = "research",
            tokens = 15_600, summary = "整理了三家竞品的定价表",
        ),
        run(
            RUN_DELEGATE, INSTANCE_RESEARCH, "查一下登录页用到的测试框架的最新版本", RunState.Succeeded, 1, 1,
            source = RunSource.Delegate, parent = RUN_LIVE, root = RUN_LIVE, tokens = 940, summary = "JUnit 4.13.2",
        ),
        run(
            RUN_CANCELLED, INSTANCE_RESEARCH, "整理上周的阅读清单", RunState.Cancelled, 60L * 26, 2, tokens = 410,
            reason = "用户取消",
        ),
    )

    val artifacts = listOf(
        Artifact(
            id = "art-readme", instanceId = INSTANCE_CODER, runId = RUN_DONE, name = "README.en.md", version = 1,
            contentType = "text/markdown", size = 4_812, sha256 = "9f2c".padEnd(64, '0'), createdAtMs = ago(176),
        ),
        Artifact(
            id = "art-weekly", instanceId = INSTANCE_CODER, runId = RUN_PIPELINE_WRITE, name = "weekly-report.md",
            version = 2, contentType = "text/markdown", size = 9_336, sha256 = "41ab".padEnd(64, '0'),
            createdAtMs = ago(60L * 48 - 24),
        ),
    )

    val artifactContents: Map<String, String> = mapOf(
        "art-readme" to "# ThinkTin\n\nAn agent platform. (demo)\n",
        "art-weekly" to "# 周报（演示）\n\n- 竞品 A：按量计费\n- 竞品 B：订阅制\n",
    )

    // ---- 事件 ----

    private val seqByInstance = mutableMapOf<String, Long>()

    private fun MutableList<InstanceEvent>.ev(
        instanceId: String,
        runId: String?,
        kind: String,
        minutesAgo: Long,
        ai: Boolean = kind.startsWith("agent."),
        payload: JsonObjectBuilder.() -> Unit = {},
    ) {
        val seq = (seqByInstance[instanceId] ?: 0L) + 1
        seqByInstance[instanceId] = seq
        add(
            InstanceEvent(
                instanceId = instanceId, seq = seq, runId = runId, kind = kind,
                payload = buildJsonObject(payload), aiGenerated = ai, createdAtMs = ago(minutesAgo),
            ),
        )
    }

    private fun JsonObjectBuilder.rawToolCall(title: String, kind: String, input: JsonObject) {
        putJsonObject("raw") {
            put("title", title)
            put("kind", kind)
            put("rawInput", input)
        }
    }

    private fun stateEvent(state: RunState, reason: String? = null, attempt: Int = 1): JsonObjectBuilder.() -> Unit = {
        put("state", state.wire)
        if (reason != null) put("reason", reason)
        put("attempt", attempt)
    }

    val events: List<InstanceEvent> = buildList {
        val c = INSTANCE_CODER
        // 小码：流水线根运行（两天前）
        ev(c, RUN_PIPELINE, EventKinds.RUN_STATE, 60L * 48, payload = stateEvent(RunState.Running))
        ev(c, RUN_PIPELINE, EventKinds.PIPELINE_STEP_STARTED, 60L * 48 - 1, ai = false) {
            put("step", "research"); put("run_id", RUN_PIPELINE_RESEARCH); put("instance_id", INSTANCE_RESEARCH)
        }
        ev(c, RUN_PIPELINE, EventKinds.PIPELINE_STEP_STARTED, 60L * 48 - 15, ai = false) {
            put("step", "write"); put("run_id", RUN_PIPELINE_WRITE); put("instance_id", INSTANCE_CODER)
        }
        ev(c, RUN_PIPELINE_WRITE, EventKinds.AGENT_MESSAGE, 60L * 48 - 20) { put("text", "周报已写好，见产出物。") }
        ev(c, RUN_PIPELINE_WRITE, EventKinds.ARTIFACT_PUBLISHED, 60L * 48 - 24, ai = false) {
            put("artifact_id", "art-weekly"); put("name", "weekly-report.md"); put("version", 2); put("size", 9_336)
        }
        ev(c, RUN_PIPELINE, EventKinds.RUN_STATE, 60L * 48 - 25, payload = stateEvent(RunState.Succeeded))

        // 小码：失败的计划运行（一天前）
        ev(c, RUN_FAILED, EventKinds.RUN_STATE, 60L * 24, payload = stateEvent(RunState.Starting))
        ev(c, RUN_FAILED, EventKinds.AGENT_READY, 60L * 24) { put("harness", "claude-code") }
        ev(c, RUN_FAILED, EventKinds.AGENT_TURN_STARTED, 60L * 24)
        ev(c, RUN_FAILED, EventKinds.AGENT_ERROR, 60L * 24 - 1) { put("message", "fetch https://registry.example.com 超时") }
        ev(c, RUN_FAILED, EventKinds.AGENT_SESSION_LOST, 60L * 24 - 1) { put("reason", "sandbox_restarted") }
        ev(c, RUN_FAILED, EventKinds.RUN_STATE, 60L * 24 - 1, payload = stateEvent(RunState.Backoff, "upstream_timeout", 2))
        ev(c, RUN_FAILED, EventKinds.RUN_LOG_TRUNCATED, 60L * 24 - 2) { put("limit_bytes", 1_048_576) }
        ev(c, RUN_FAILED, EventKinds.AGENT_EXITED, 60L * 24 - 2) { put("code", 1) }
        ev(c, RUN_FAILED, EventKinds.RUN_STATE, 60L * 24 - 3, payload = stateEvent(RunState.Failed, "upstream_timeout", 3))

        // 小码：成功的运行（三小时前）
        ev(c, RUN_DONE, EventKinds.RUN_STATE, 180, payload = stateEvent(RunState.Running))
        ev(c, RUN_DONE, EventKinds.AGENT_TURN_STARTED, 180)
        ev(c, RUN_DONE, EventKinds.AGENT_THOUGHT, 180) { put("text", "先读 README，再逐段翻译，保留代码块。") }
        ev(c, RUN_DONE, EventKinds.AGENT_PLAN, 180) {
            putJsonArray("entries") {
                addJsonObject { put("content", "读取 README.md"); put("status", "completed"); put("priority", "high") }
                addJsonObject { put("content", "翻译并写入 README.en.md"); put("status", "completed"); put("priority", "high") }
                addJsonObject { put("content", "提交改动"); put("status", "completed"); put("priority", "medium") }
            }
        }
        ev(c, RUN_DONE, EventKinds.AGENT_TOOL_CALL, 179) {
            put("tool_call_id", "tc-read"); put("title", "读取 README.md"); put("kind", "read"); put("status", "in_progress")
            rawToolCall("Read", "read", buildJsonObject { put("path", "README.md") })
        }
        ev(c, RUN_DONE, EventKinds.AGENT_TOOL_CALL_UPDATE, 179) {
            put("tool_call_id", "tc-read"); put("status", "completed")
            putJsonObject("raw") { put("lines", 128) }
        }
        ev(c, RUN_DONE, EventKinds.AGENT_TOOL_CALL, 178) {
            put("tool_call_id", "tc-write"); put("title", "写入 README.en.md"); put("kind", "edit"); put("status", "pending")
            rawToolCall("Write", "edit", buildJsonObject { put("path", "README.en.md") })
        }
        ev(c, RUN_DONE, EventKinds.AGENT_PERMISSION_REQUESTED, 178) {
            put("request_id", APPROVAL_DONE); put("title", "写入 README.en.md")
            putJsonArray("options") {
                addJsonObject { put("option_id", "allow"); put("name", "批准"); put("kind", OptionKind.AllowOnce.wire) }
                addJsonObject { put("option_id", "reject"); put("name", "拒绝"); put("kind", OptionKind.RejectOnce.wire) }
            }
            putJsonObject("tool_call") { put("tool_call_id", "tc-write") }
        }
        ev(c, RUN_DONE, EventKinds.APPROVAL_DECIDED, 177, ai = false) {
            put("approval_id", APPROVAL_DONE); put("state", ApprovalState.Approved.wire); put("option_id", "allow")
        }
        ev(c, RUN_DONE, EventKinds.AGENT_PERMISSION_RESOLVED, 177) {
            put("request_id", APPROVAL_DONE); put("option_id", "allow"); put("by", "user")
        }
        ev(c, RUN_DONE, EventKinds.AGENT_TOOL_CALL_UPDATE, 177) { put("tool_call_id", "tc-write"); put("status", "completed") }
        ev(c, RUN_DONE, EventKinds.AGENT_MESSAGE, 177) { put("text", "README 已翻译成英文，") }
        ev(c, RUN_DONE, EventKinds.AGENT_MESSAGE, 177) { put("text", "写在 `README.en.md`，代码块保持原样。") }
        ev(c, RUN_DONE, EventKinds.ARTIFACT_PUBLISHED, 176, ai = false) {
            put("artifact_id", "art-readme"); put("name", "README.en.md"); put("version", 1); put("size", 4_812)
        }
        ev(c, RUN_DONE, EventKinds.AGENT_USAGE, 176) {
            putJsonObject("raw") { put("input_tokens", 10_200); put("output_tokens", 2_640) }
        }
        ev(c, RUN_DONE, EventKinds.AGENT_TURN_ENDED, 176) { put("stop_reason", "end_turn") }
        ev(c, RUN_DONE, EventKinds.RUN_STATE, 176, payload = stateEvent(RunState.Succeeded))

        // 小码：等待审批（二十分钟前）
        ev(c, RUN_WAITING, EventKinds.RUN_STATE, 20, payload = stateEvent(RunState.Running))
        ev(c, RUN_WAITING, EventKinds.AGENT_TURN_STARTED, 20)
        ev(c, RUN_WAITING, EventKinds.AGENT_TOOL_CALL, 19) {
            put("tool_call_id", "tc-rm"); put("title", "删除 build/ 下 30 天前的文件"); put("kind", "execute")
            put("status", "pending")
            rawToolCall("Bash", "execute", buildJsonObject { put("command", "find build -mtime +30 -delete") })
        }
        ev(c, RUN_WAITING, EventKinds.AGENT_PERMISSION_REQUESTED, 19) {
            put("request_id", APPROVAL_PENDING); put("title", "删除 build/ 下 30 天前的文件")
            putJsonArray("options") {
                addJsonObject { put("option_id", "allow"); put("name", "批准"); put("kind", OptionKind.AllowOnce.wire) }
                addJsonObject { put("option_id", "always"); put("name", "一直允许"); put("kind", OptionKind.AllowAlways.wire) }
                addJsonObject { put("option_id", "reject"); put("name", "拒绝"); put("kind", OptionKind.RejectOnce.wire) }
            }
            putJsonObject("tool_call") { put("tool_call_id", "tc-rm") }
        }
        ev(c, RUN_WAITING, EventKinds.RUN_STATE, 19, payload = stateEvent(RunState.WaitingApproval, "等待你批准删除文件"))

        // 小码：正在运行（两分钟前开始）
        ev(c, RUN_LIVE, EventKinds.RUN_STATE, 2, payload = stateEvent(RunState.Running))
        ev(c, RUN_LIVE, EventKinds.AGENT_UPDATE, 2) { put("message", "已加载项目上下文") }
        ev(c, RUN_LIVE, EventKinds.AGENT_TURN_STARTED, 2)
        ev(c, RUN_LIVE, EventKinds.AGENT_VAULT_REVEAL, 2) {
            put("call_id", "vr-1")
            putJsonArray("refs") { add("github") }
        }
        ev(c, RUN_LIVE, EventKinds.VAULT_USED, 2, ai = false) {
            put("request_id", "vr-1"); putJsonArray("names") { add("github") }
        }
        ev(c, RUN_LIVE, EventKinds.AGENT_PLATFORM_TOOL_CALL, 2) {
            put("call_id", "ptc-1"); put("name", "delegate")
            putJsonObject("arguments") { put("to", INSTANCE_RESEARCH); put("title", "查测试框架的最新版本") }
        }
        ev(c, RUN_LIVE, EventKinds.DELEGATE_STARTED, 1, ai = false) {
            put("child_run_id", RUN_DELEGATE); put("instance_id", INSTANCE_RESEARCH); put("to", "研究员")
            put("title", "查测试框架的最新版本")
        }
        ev(c, RUN_LIVE, EventKinds.AGENT_MESSAGE, 1) { put("text", "我先看看登录页现有的结构，") }

        // 研究员
        val r = INSTANCE_RESEARCH
        ev(r, RUN_PIPELINE_RESEARCH, EventKinds.RUN_STATE, 60L * 48 - 1, payload = stateEvent(RunState.Running))
        ev(r, RUN_PIPELINE_RESEARCH, EventKinds.AGENT_MESSAGE, 60L * 48 - 10) { put("text", "三家竞品的定价已整理成表格。") }
        ev(r, RUN_PIPELINE_RESEARCH, EventKinds.RUN_STATE, 60L * 48 - 14, payload = stateEvent(RunState.Succeeded))
        ev(r, RUN_CANCELLED, EventKinds.RUN_STATE, 60L * 26, payload = stateEvent(RunState.Running))
        ev(r, RUN_CANCELLED, EventKinds.AGENT_TURN_STARTED, 60L * 26)
        ev(r, RUN_CANCELLED, EventKinds.VAULT_REQUESTED, 60L * 26, ai = false) {
            put("request_id", "vreq-old"); put("name", "pocket"); put("purpose", "读取稍后阅读列表")
            putJsonArray("fields") { add("username"); add("password") }
        }
        ev(r, RUN_CANCELLED, EventKinds.VAULT_DECLINED, 60L * 26 - 1, ai = false) { put("request_id", "vreq-old") }
        ev(r, RUN_CANCELLED, EventKinds.AGENT_TURN_ENDED, 60L * 26 - 2) { put("stop_reason", "cancelled") }
        ev(r, RUN_CANCELLED, EventKinds.RUN_STATE, 60L * 26 - 2, payload = stateEvent(RunState.Cancelled, "用户取消"))
        ev(r, null, EventKinds.PLAN_NEEDS_CONFIRMATION, 60L * 25, ai = false) {
            put("plan_id", PLAN_WEEKLY); put("title", "每周一整理行业新闻"); put("change", "created")
        }
        ev(r, null, EventKinds.PLAN_CANCELLED, 60L * 25 - 1, ai = false) {
            put("plan_id", "plan-old"); put("title", "每小时检查价格"); put("change", "cancelled")
        }
        ev(r, null, EventKinds.VAULT_REQUESTED, 60L * 3, ai = false) {
            put("request_id", VAULT_REQUEST_PENDING); put("name", "aliyun_oss"); put("purpose", "上传调研报告")
            putJsonArray("fields") { add("username"); add("password") }
        }
        ev(r, null, EventKinds.VAULT_REQUESTED, 60L * 2, ai = false) {
            put("request_id", "vreq-done"); put("name", "zotero"); put("purpose", "同步文献库")
            putJsonArray("fields") { add("password") }
        }
        ev(r, null, EventKinds.VAULT_FULFILLED, 60L * 2 - 5, ai = false) { put("request_id", "vreq-done"); put("name", "zotero") }
        ev(r, RUN_DELEGATE, EventKinds.AGENT_MESSAGE, 1) { put("text", "JUnit 最新的 4.x 是 4.13.2。") }
        ev(r, RUN_DELEGATE, EventKinds.RUN_STATE, 1, payload = stateEvent(RunState.Succeeded))
    }.sortedWith(compareBy({ it.instanceId }, { it.seq }))

    /** 各实例当前最大的 seq（演示事件流从这里接着往下编号）。 */
    val lastSeq: Map<String, Long> get() = seqByInstance.toMap()

    val approvals = listOf(
        Approval(
            id = APPROVAL_PENDING, runId = RUN_WAITING, instanceId = INSTANCE_CODER,
            title = "删除 build/ 下 30 天前的文件",
            options = listOf(
                ApprovalOption("allow", "批准", OptionKind.AllowOnce),
                ApprovalOption("always", "一直允许", OptionKind.AllowAlways),
                ApprovalOption("reject", "拒绝", OptionKind.RejectOnce),
                ApprovalOption("never", "一直拒绝", OptionKind.RejectAlways),
            ),
            toolCallJson = """{"title":"Bash","kind":"execute","rawInput":{"command":"find build -mtime +30 -delete"}}""",
            toolCall = buildJsonObject {
                put("title", "Bash"); put("kind", "execute")
                putJsonObject("rawInput") { put("command", "find build -mtime +30 -delete") }
            },
            state = ApprovalState.Pending, expiresAtMs = ago(19) + 24 * 60 * MINUTE, createdAtMs = ago(19),
        ),
        Approval(
            id = APPROVAL_DONE, runId = RUN_DONE, instanceId = INSTANCE_CODER, title = "写入 README.en.md",
            options = listOf(
                ApprovalOption("allow", "批准", OptionKind.AllowOnce),
                ApprovalOption("reject", "拒绝", OptionKind.RejectOnce),
            ),
            toolCallJson = """{"title":"Write","kind":"edit","rawInput":{"path":"README.en.md"}}""",
            toolCall = buildJsonObject {
                put("title", "Write"); put("kind", "edit")
                putJsonObject("rawInput") { put("path", "README.en.md") }
            },
            state = ApprovalState.Approved, expiresAtMs = ago(178) + 24 * 60 * MINUTE, createdAtMs = ago(178),
        ),
    )

    val plans = listOf(
        Plan(
            id = PLAN_DAILY, instanceId = INSTANCE_CODER, title = "每日依赖检查", goal = "每天早上检查依赖有没有安全更新，有就开 PR。",
            paused = false, createdBy = "user", awaitingConfirmation = false, revision = 3,
            policyJson = """{"budget_tokens":50000,"timeout_secs":1800,"on_approval_timeout":"reject"}""",
            policy = buildJsonObject {
                put("budget_tokens", 50_000); put("timeout_secs", 1_800); put("on_approval_timeout", "reject")
            },
            createdAtMs = ago(60L * 24 * 14),
            triggers = listOf(
                Trigger(
                    id = "trg-daily", schedule = Schedule.Cron("0 9 * * *", "Asia/Shanghai"), enabled = true,
                    nextFireAtMs = baseMs + 9 * 60 * MINUTE, lastFireAtMs = ago(60L * 24),
                ),
            ),
            steps = emptyList(),
        ),
        Plan(
            id = PLAN_WEEKLY, instanceId = INSTANCE_RESEARCH, title = "每周一整理行业新闻",
            goal = "每周一上午汇总上周的行业新闻，写成一页摘要。", paused = false, createdBy = "agent",
            awaitingConfirmation = true, revision = 1, policyJson = "{}", policy = JsonObject(emptyMap()),
            createdAtMs = ago(60L * 25),
            triggers = listOf(
                Trigger(
                    id = "trg-weekly",
                    schedule = Schedule.Rrule("DTSTART;TZID=Asia/Shanghai:20260105T100000\nRRULE:FREQ=WEEKLY;BYDAY=MO"),
                    enabled = true, nextFireAtMs = baseMs + 3 * 24 * 60 * MINUTE, lastFireAtMs = null,
                ),
            ),
            steps = listOf(PlanStep("collect", INSTANCE_RESEARCH, "收集上周的行业新闻", emptyList())),
        ),
    )

    val inbox = listOf(
        InboxItem(
            id = "inbox-5", instanceId = INSTANCE_CODER, runId = RUN_WAITING, planId = null, approvalId = APPROVAL_PENDING,
            kind = InboxKind.Approval, title = "小码请求删除文件", body = "删除 build/ 下 30 天前的文件，需要你批准。",
            aiGenerated = false, read = false, createdAtMs = ago(19),
        ),
        InboxItem(
            id = "inbox-4", instanceId = INSTANCE_RESEARCH, runId = null, planId = null, approvalId = null,
            kind = InboxKind.ComputerApproval, title = "研究员请求操作你的电脑", body = "打开“下载”文件夹里的 report.pdf。",
            aiGenerated = false, read = false, createdAtMs = ago(60),
        ),
        InboxItem(
            id = "inbox-3", instanceId = INSTANCE_CODER, runId = RUN_DONE, planId = null, approvalId = null,
            kind = InboxKind.RunFinished, title = "README 翻译完成", body = "已翻译并提交 README.en.md。",
            aiGenerated = true, read = true, createdAtMs = ago(176),
        ),
        InboxItem(
            id = "inbox-2", instanceId = INSTANCE_CODER, runId = RUN_FAILED, planId = PLAN_DAILY, approvalId = null,
            kind = InboxKind.RunFailed, title = "每日依赖检查失败", body = "上游仓库连接超时（重试 3 次后放弃）。",
            aiGenerated = false, read = true, createdAtMs = ago(60L * 24 - 3),
        ),
        InboxItem(
            id = "inbox-1", instanceId = INSTANCE_RESEARCH, runId = null, planId = PLAN_WEEKLY, approvalId = null,
            kind = InboxKind.Info, title = "研究员建议了一个新计划", body = "“每周一整理行业新闻”等你确认。",
            aiGenerated = true, read = false, createdAtMs = ago(60L * 25),
        ),
    )

    val vendors = listOf(
        VendorInfo("anthropic", "Anthropic", listOf("anthropic"), listOf("claude-sonnet-4", "claude-opus-4"), ""),
        VendorInfo("openai", "OpenAI", listOf("openai", "responses"), listOf("gpt-4.1", "o3"), ""),
        VendorInfo("deepseek", "DeepSeek", listOf("openai", "anthropic"), listOf("deepseek-chat", "deepseek-reasoner"), "国内直连"),
    )

    val credentials = listOf(
        Credential("cred-work", "anthropic", "工作 key", "a1b2", 2_000_000, false, ago(60L * 24 * 30)),
        Credential("cred-home", "deepseek", "个人", "9z8y", null, false, ago(60L * 24 * 10)),
    )

    val modelRoutes: Map<String, List<ModelRoute>> = mapOf(
        INSTANCE_CODER to listOf(
            ModelRoute("default", "cred-work", "claude-sonnet-4", listOf(RouteFallback("cred-home", "deepseek-chat"))),
        ),
        INSTANCE_RESEARCH to listOf(ModelRoute("default", "cred-home", "deepseek-reasoner", emptyList())),
    )

    val usageDays: List<UsageBucket> = (6 downTo 0).map { daysAgo ->
        val factor = (7 - daysAgo).toLong()
        UsageBucket(
            key = "D-$daysAgo", requests = 12 * factor, inputTokens = 8_000 * factor, cacheReadTokens = 2_000 * factor,
            cacheWriteTokens = 500 * factor, outputTokens = 1_500 * factor, chargedTokens = 10_000 * factor,
            estimatedRequests = 0, failedRequests = if (daysAgo == 1) 3 else 0,
        )
    }

    val vaultItems = listOf(
        VaultItem("vault-github", "github", "推送代码到 GitHub", true, listOf(INSTANCE_CODER), ago(60L * 24 * 7), ago(60L * 24 * 7), ago(2)),
        VaultItem("vault-npm", "npm_token", "发布 npm 包", false, emptyList(), ago(60L * 24 * 3), ago(60L * 24), null),
    )

    val vaultUsernames: Map<String, String> = mapOf("vault-github" to "demo-user", "vault-npm" to "")

    val vaultRequests = listOf(
        VaultRequest(
            id = VAULT_REQUEST_PENDING, instanceId = INSTANCE_RESEARCH, runId = null, name = "aliyun_oss",
            purpose = "上传调研报告", fields = listOf("username", "password"), status = VaultRequestStatus.Pending,
            itemId = null, createdAtMs = ago(180), expiresAtMs = ago(180) + 24 * 60 * MINUTE, resolvedAtMs = null,
        ),
        VaultRequest(
            id = "vreq-done", instanceId = INSTANCE_RESEARCH, runId = null, name = "zotero", purpose = "同步文献库",
            fields = listOf("password"), status = VaultRequestStatus.Fulfilled, itemId = "vault-zotero",
            createdAtMs = ago(120), expiresAtMs = ago(120) + 24 * 60 * MINUTE, resolvedAtMs = ago(115),
        ),
    )

    val devices = listOf(
        Device("dev-this", DevicePlatform.Android, "Pixel 8", true, ago(60L * 24 * 30), baseMs, null),
        Device("dev-iphone", DevicePlatform.Ios, "iPhone 15", false, ago(60L * 24 * 60), ago(60L * 5), null),
        Device("dev-mac", DevicePlatform.Macos, "MacBook Air", false, ago(60L * 24 * 90), ago(60L * 24 * 8), ago(60L * 24 * 8)),
    )

    val teams = listOf(
        Team(
            id = "team-research", name = "调研小组",
            members = listOf(
                TeamMember(INSTANCE_RESEARCH, TeamRole.Lead, 0),
                TeamMember(INSTANCE_CODER, TeamRole.Member, 1),
            ),
            createdAtMs = ago(60L * 24 * 5),
        ),
    )

    val imChannels = listOf(
        ImChannel(
            id = "im-feishu", vendor = "feishu", label = "研发群", hint = "a1b2", hasSecret = true,
            events = listOf("run_finished", "run_failed", "approval"), enabled = true, lastSentAtMs = ago(30),
            lastError = null, createdAtMs = ago(60L * 24 * 10),
        ),
        ImChannel(
            id = "im-wecom", vendor = "wecom", label = "周报群", hint = "9z8y", hasSecret = false,
            events = listOf("run_failed"), enabled = false, lastSentAtMs = ago(60L * 24 * 2),
            lastError = "webhook returned 404", createdAtMs = ago(60L * 24 * 20),
        ),
    )

    val teamTemplates = listOf(
        TeamTemplate(
            id = "tpl-research", name = "调研 + 写作",
            members = listOf(
                TemplateMember(AGENT_RESEARCH, null, "研究员", TeamRole.Lead),
                TemplateMember(AGENT_WRITER, "claude-code", "笔杆子", TeamRole.Member),
            ),
            createdAtMs = ago(60L * 24 * 4),
        ),
    )

    companion object {
        const val MINUTE: Long = 60_000

        const val AGENT_CODER = "agent-coder"
        const val AGENT_RESEARCH = "agent-research"
        const val AGENT_WRITER = "agent-writer"

        const val INSTANCE_CODER = "inst-coder"
        const val INSTANCE_RESEARCH = "inst-research"

        const val RUN_LIVE = "run-live"
        const val RUN_WAITING = "run-waiting"
        const val RUN_DONE = "run-done"
        const val RUN_FAILED = "run-failed"
        const val RUN_PIPELINE = "run-pipeline"
        const val RUN_PIPELINE_RESEARCH = "run-pipeline-research"
        const val RUN_PIPELINE_WRITE = "run-pipeline-write"
        const val RUN_DELEGATE = "run-delegate"
        const val RUN_CANCELLED = "run-cancelled"

        const val APPROVAL_PENDING = "approval-pending"
        const val APPROVAL_DONE = "approval-done"

        const val PLAN_DAILY = "plan-daily"
        const val PLAN_WEEKLY = "plan-weekly"

        const val VAULT_REQUEST_PENDING = "vreq-pending"
    }
}
