package cn.thinktin.data.mock

import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.Device
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxPage
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.LoginResult
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanUpdate
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.SavedSecret
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.SignOutOthersResult
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamTemplate
import cn.thinktin.data.model.Trigger
import cn.thinktin.data.model.UsageBucket
import cn.thinktin.data.model.UsageGroup
import cn.thinktin.data.model.UsageSummary
import cn.thinktin.data.model.User
import cn.thinktin.data.model.VaultItem
import cn.thinktin.data.model.VaultItemDetail
import cn.thinktin.data.model.VaultItemUpdate
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.data.model.parseJsonObject
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * 演示模式的 ThinktinService：确定性的假数据（[MockData]），全部在内存里，可以增删改。
 *
 * @param delayMs 每次“联网”调用前等待的毫秒数（默认 0；演示时可以设成 300 看加载态）。
 * @param eventIntervalMs 运行中的实例吐演示事件的间隔。
 * @param clock 当前时间（毫秒）；假数据的时间都相对于构造时的 clock()。
 */
class MockThinktinService(
    private val delayMs: Long = 0,
    private val eventIntervalMs: Long = DEFAULT_EVENT_INTERVAL_MS,
    private val clock: () -> Long = System::currentTimeMillis,
) : ThinktinService {

    private val data = MockData(clock())
    private val lock = Any()

    private var user: User = data.user
    private val agentList: List<AgentInfo> = data.agents
    private val instanceList = data.instances.toMutableList()
    private val runList = data.runs.toMutableList()
    private val artifactList = data.artifacts.toMutableList()
    private val eventList = data.events.toMutableList()
    private val nextSeq = data.lastSeq.toMutableMap()
    private val approvalList = data.approvals.toMutableList()
    private val planList = data.plans.toMutableList()
    private val inboxList = data.inbox.toMutableList()
    private val credentialList = data.credentials.toMutableList()
    private val routes = data.modelRoutes.toMutableMap()
    private val vaultList = data.vaultItems.toMutableList()
    private val vaultUsernames = data.vaultUsernames.toMutableMap()
    private val vaultRequestList = data.vaultRequests.toMutableList()
    private val deviceList = data.devices.toMutableList()
    private val teamList = data.teams.toMutableList()
    private val templateList = data.teamTemplates.toMutableList()
    private var idCounter = 0
    private var scriptStep = 0

    /** 新追加的事件（发消息、演示脚本），推给正在收集 events() 的页面。 */
    private val appended = MutableSharedFlow<InstanceEvent>(extraBufferCapacity = 64)

    override val isDemo: Boolean = true

    private val auth = MutableStateFlow(AuthState.SignedIn)
    override val authState: StateFlow<AuthState> = auth.asStateFlow()

    private suspend fun lag() {
        if (delayMs > 0) delay(delayMs)
    }

    private fun newId(prefix: String): String = synchronized(lock) { "$prefix-demo-${++idCounter}" }

    private fun notFound(what: String, id: String): Nothing =
        throw ServiceError.Api(status = 404, code = "not_found", detail = "$what $id not found", retryAfterSecs = null)

    private fun requireSignedIn() {
        if (auth.value == AuthState.SignedOut) throw ServiceError.SignedOut()
    }

    // ---- 登录与账号 ----

    override suspend fun sendCode(phone: String) {
        lag()
        if (phone.isBlank()) throw ServiceError.Api(400, "invalid", "phone is empty", null)
    }

    override suspend fun login(phone: String, code: String, pushChannel: String?, pushToken: String?): LoginResult {
        lag()
        if (code.length != 6) throw ServiceError.Api(400, "invalid_code", "code must have 6 digits", null)
        auth.value = AuthState.SignedIn
        return LoginResult(user = user, newUser = false)
    }

    override suspend fun logout() {
        lag()
        auth.value = AuthState.SignedOut
    }

    override suspend fun me(): User {
        lag(); requireSignedIn()
        return user
    }

    override suspend fun setLocale(locale: String): User {
        lag()
        return synchronized(lock) { user.copy(locale = locale).also { user = it } }
    }

    override suspend fun setPushToken(channel: String, token: String) = lag()

    override suspend fun stopAll(): StopAllResult {
        lag()
        return synchronized(lock) {
            var cancelled = 0L
            runList.replaceAll { run ->
                if (run.state.isActive) {
                    cancelled++
                    run.copy(state = RunState.Cancelled, finishedAtMs = clock(), stateReason = "stop_all")
                } else {
                    run
                }
            }
            var paused = 0L
            planList.replaceAll { plan -> if (!plan.paused) plan.copy(paused = true).also { paused++ } else plan }
            StopAllResult(runsCancelled = cancelled, grantsRevoked = cancelled, plansPaused = paused)
        }
    }

    override suspend fun signOutOtherDevices(stopAgents: Boolean): SignOutOthersResult {
        val stopped = if (stopAgents) stopAll() else null
        lag()
        val count = synchronized(lock) {
            val others = deviceList.count { !it.current && it.revokedAtMs == null }
            deviceList.replaceAll { if (!it.current && it.revokedAtMs == null) it.copy(revokedAtMs = clock()) else it }
            others.toLong()
        }
        return SignOutOthersResult(devicesSignedOut = count, stopped = stopped)
    }

    override suspend fun devices(): List<Device> {
        lag()
        return synchronized(lock) { deviceList.toList() }
    }

    override suspend fun signOutDevice(deviceId: String) {
        lag()
        synchronized(lock) {
            val i = deviceList.indexOfFirst { it.id == deviceId }
            if (i < 0) notFound("device", deviceId)
            deviceList[i] = deviceList[i].copy(revokedAtMs = clock())
        }
    }

    override suspend fun sendAccountCode() = lag()

    override suspend fun deleteAccount(code: String) {
        lag()
        if (code.length != 6) throw ServiceError.Api(400, "invalid_code", "code must have 6 digits", null)
        auth.value = AuthState.SignedOut
    }

    // ---- 目录与实例 ----

    override suspend fun agents(): List<AgentInfo> {
        lag()
        return agentList
    }

    override suspend fun instances(): List<Instance> {
        lag(); requireSignedIn()
        return cachedInstances()
    }

    override fun cachedInstances(): List<Instance> =
        synchronized(lock) { instanceList.filter { it.state != InstanceState.Deleted } }

    override suspend fun adopt(agentId: String, name: String, harness: String?): Instance {
        lag()
        val agent = agentList.firstOrNull { it.id == agentId } ?: notFound("agent", agentId)
        val now = clock()
        val instance = Instance(
            id = newId("inst"), agentId = agent.id, agentVersion = agent.version,
            harness = harness ?: agent.defaultHarness, name = name, state = InstanceState.Running,
            createdAtMs = now, lastActiveAtMs = now,
        )
        synchronized(lock) { instanceList.add(instance) }
        return instance
    }

    private fun updateInstance(instanceId: String, change: (Instance) -> Instance): Instance = synchronized(lock) {
        val i = instanceList.indexOfFirst { it.id == instanceId }
        if (i < 0) notFound("instance", instanceId)
        change(instanceList[i]).also { instanceList[i] = it }
    }

    override suspend fun renameInstance(instanceId: String, name: String): Instance {
        lag()
        return updateInstance(instanceId) { it.copy(name = name) }
    }

    override suspend fun setInstanceVersion(instanceId: String, version: String?): Instance {
        lag()
        return updateInstance(instanceId) { inst ->
            val agent = agentList.first { it.id == inst.agentId }
            inst.copy(agentVersion = version ?: agent.version)
        }
    }

    override suspend fun deleteInstance(instanceId: String) {
        lag()
        updateInstance(instanceId) { it.copy(state = InstanceState.Deleted) }
    }

    override suspend fun modelRoutes(instanceId: String): List<ModelRoute> {
        lag()
        return synchronized(lock) { routes[instanceId].orEmpty() }
    }

    override suspend fun setModelRoutes(instanceId: String, routes: List<ModelRoute>) {
        lag()
        synchronized(lock) { this.routes[instanceId] = routes }
    }

    // ---- 运行 ----

    override suspend fun createRun(instanceId: String, prompt: String): Run {
        lag()
        val now = clock()
        val id = newId("run")
        val run = Run(
            id = id, kind = RunKind.Agent, instanceId = instanceId, planId = null, parentRunId = null, rootRunId = id,
            stepKey = null, source = RunSource.User, prompt = prompt, state = RunState.Queued, stateReason = null,
            attempt = 1, tokensUsed = 0, summary = null, error = null, createdAtMs = now, startedAtMs = null,
            finishedAtMs = null,
        )
        synchronized(lock) {
            if (instanceList.none { it.id == instanceId }) notFound("instance", instanceId)
            runList.add(0, run)
        }
        append(instanceId, id, EventKinds.RUN_STATE, buildJsonObject { put("state", RunState.Queued.wire); put("attempt", 1) })
        return run
    }

    override suspend fun sendMessage(instanceId: String, text: String, allowSecrets: Boolean): Run {
        if (!allowSecrets) {
            val found = detectSecrets(text)
            if (found.isNotEmpty()) throw ServiceError.ContainsSecrets(found.size)
        }
        return createRun(instanceId, text)
    }

    override suspend fun runs(instanceId: String, limit: Int): List<Run> {
        lag(); requireSignedIn()
        return cachedRuns(instanceId, limit)
    }

    override suspend fun olderRuns(instanceId: String, beforeRunId: String, limit: Int): List<Run> {
        lag()
        return synchronized(lock) {
            val all = sortedRuns(instanceId)
            val i = all.indexOfFirst { it.id == beforeRunId }
            if (i < 0) emptyList() else all.drop(i + 1).take(limit)
        }
    }

    private fun sortedRuns(instanceId: String): List<Run> =
        runList.filter { it.instanceId == instanceId }.sortedByDescending { it.createdAtMs }

    override fun cachedRuns(instanceId: String, limit: Int): List<Run> =
        synchronized(lock) { sortedRuns(instanceId).take(limit) }

    override suspend fun getRun(runId: String): Run {
        lag()
        return synchronized(lock) { runList.firstOrNull { it.id == runId } } ?: notFound("run", runId)
    }

    override suspend fun cancelRun(runId: String, wholeTree: Boolean): Run {
        lag()
        return synchronized(lock) {
            val target = runList.firstOrNull { it.id == runId } ?: notFound("run", runId)
            runList.replaceAll { run ->
                val inScope = run.id == runId || (wholeTree && run.rootRunId == target.rootRunId)
                if (inScope && run.state.isActive) {
                    run.copy(state = RunState.Cancelled, finishedAtMs = clock(), stateReason = "用户取消")
                } else {
                    run
                }
            }
            runList.first { it.id == runId }
        }
    }

    override suspend fun runTree(runId: String): List<Run> {
        lag()
        return synchronized(lock) {
            val run = runList.firstOrNull { it.id == runId } ?: notFound("run", runId)
            runList.filter { it.rootRunId == run.rootRunId }
                .sortedWith(compareBy<Run> { it.parentRunId != null }.thenBy { it.createdAtMs })
        }
    }

    override suspend fun runArtifacts(runId: String): List<Artifact> {
        lag()
        return synchronized(lock) { artifactList.filter { it.runId == runId } }
    }

    override suspend fun artifactContent(artifactId: String): ByteArray {
        lag()
        val text = data.artifactContents[artifactId] ?: notFound("artifact", artifactId)
        return text.toByteArray(Charsets.UTF_8)
    }

    override suspend fun instanceArtifacts(instanceId: String): List<Artifact> {
        lag()
        return synchronized(lock) { artifactList.filter { it.instanceId == instanceId } }
    }

    override suspend fun deleteArtifact(artifactId: String) {
        lag()
        synchronized(lock) { artifactList.removeAll { it.id == artifactId } }
    }

    // ---- 事件 ----

    private fun append(instanceId: String, runId: String?, kind: String, payload: JsonObject): InstanceEvent {
        val event = synchronized(lock) {
            val seq = (nextSeq[instanceId] ?: 0L) + 1
            nextSeq[instanceId] = seq
            InstanceEvent(
                instanceId = instanceId, seq = seq, runId = runId, kind = kind, payload = payload,
                aiGenerated = kind.startsWith("agent."), createdAtMs = clock(),
            ).also { eventList.add(it) }
        }
        appended.tryEmit(event)
        return event
    }

    /** 演示脚本：运行中的实例按固定节奏吐的事件（循环）。 */
    private fun nextScripted(instanceId: String): InstanceEvent {
        val runId = synchronized(lock) {
            runList.filter { it.instanceId == instanceId && it.state.isActive }.maxByOrNull { it.createdAtMs }?.id
        }
        val step = synchronized(lock) { scriptStep++ }
        val (kind, payload) = when (step % SCRIPT_LENGTH) {
            0 -> EventKinds.AGENT_MESSAGE to buildJsonObject { put("text", "正在读取登录页的代码……") }
            1 -> EventKinds.AGENT_TOOL_CALL to buildJsonObject {
                put("tool_call_id", "tc-live-$step"); put("title", "搜索 LoginScreen"); put("kind", "search")
                put("status", "in_progress")
                putJsonObject("raw") { put("query", "LoginScreen") }
            }
            2 -> EventKinds.AGENT_TOOL_CALL_UPDATE to buildJsonObject {
                put("tool_call_id", "tc-live-${step - 1}"); put("status", "completed")
            }
            3 -> EventKinds.AGENT_MESSAGE to buildJsonObject { put("text", "找到了 3 个需要覆盖的分支，开始写测试。") }
            else -> EventKinds.AGENT_USAGE to buildJsonObject {
                putJsonObject("raw") { put("input_tokens", 1_200 + step); put("output_tokens", 300) }
            }
        }
        return append(instanceId, runId, kind, payload)
    }

    override fun events(instanceId: String): Flow<EventStreamItem> = channelFlow {
        send(EventStreamItem.Status(StreamState.Connecting))
        lag()
        val instance = synchronized(lock) { instanceList.firstOrNull { it.id == instanceId } }
        if (instance == null || instance.state == InstanceState.Deleted) {
            send(EventStreamItem.Status(StreamState.NotFound))
            return@channelFlow
        }
        send(EventStreamItem.Status(StreamState.Live))
        launch {
            appended.filter { it.instanceId == instanceId }.collect { send(EventStreamItem.Event(it)) }
        }
        if (instance.state == InstanceState.Running) {
            while (true) {
                delay(eventIntervalMs)
                // 通过 appended 推送（上面的 launch 会转发），这里不重复发送。
                nextScripted(instanceId)
            }
        } else {
            awaitCancellation()
        }
    }

    override fun cachedEvents(instanceId: String, afterSeq: Long, limit: Int): List<InstanceEvent> =
        synchronized(lock) {
            eventList.filter { it.instanceId == instanceId && it.seq > afterSeq }.sortedBy { it.seq }.take(limit)
        }

    // ---- 审批 ----

    override suspend fun approvals(): List<Approval> {
        lag()
        return synchronized(lock) { approvalList.sortedByDescending { it.createdAtMs } }
    }

    override suspend fun decideApproval(approvalId: String, optionId: String): Approval {
        lag()
        val decided = synchronized(lock) {
            val i = approvalList.indexOfFirst { it.id == approvalId }
            if (i < 0) notFound("approval", approvalId)
            val approval = approvalList[i]
            val option = approval.options.firstOrNull { it.optionId == optionId } ?: notFound("option", optionId)
            val state = if (option.kind.isAllow) ApprovalState.Approved else ApprovalState.Rejected
            approval.copy(state = state).also {
                approvalList[i] = it
                val r = runList.indexOfFirst { run -> run.id == approval.runId }
                if (r >= 0 && runList[r].state == RunState.WaitingApproval) {
                    runList[r] = runList[r].copy(
                        state = if (state == ApprovalState.Approved) RunState.Running else RunState.Failed,
                        stateReason = null,
                    )
                }
            }
        }
        append(
            decided.instanceId, decided.runId, EventKinds.APPROVAL_DECIDED,
            buildJsonObject { put("approval_id", approvalId); put("state", decided.state.wire); put("option_id", optionId) },
        )
        return decided
    }

    // ---- 计划 ----

    override suspend fun plans(instanceId: String?): List<Plan> {
        lag()
        return synchronized(lock) {
            planList.filter { instanceId == null || it.instanceId == instanceId }
                .sortedWith(compareByDescending<Plan> { it.awaitingConfirmation }.thenByDescending { it.createdAtMs })
        }
    }

    override suspend fun getPlan(planId: String): Plan {
        lag()
        return synchronized(lock) { planList.firstOrNull { it.id == planId } } ?: notFound("plan", planId)
    }

    override suspend fun createPlan(plan: NewPlan): Plan {
        lag()
        val now = clock()
        val created = Plan(
            id = newId("plan"), instanceId = plan.instanceId, title = plan.title, goal = plan.goal, paused = false,
            createdBy = "user", awaitingConfirmation = false, revision = 1, policyJson = "{}",
            policy = JsonObject(emptyMap()), createdAtMs = now,
            triggers = plan.triggers.map { Trigger(newId("trg"), it, true, null, null) }, steps = plan.steps,
        )
        synchronized(lock) { planList.add(created) }
        return created
    }

    private fun updatePlanLocked(planId: String, change: (Plan) -> Plan): Plan = synchronized(lock) {
        val i = planList.indexOfFirst { it.id == planId }
        if (i < 0) notFound("plan", planId)
        change(planList[i]).also { planList[i] = it }
    }

    override suspend fun updatePlan(planId: String, update: PlanUpdate): Plan {
        lag()
        return updatePlanLocked(planId) { plan ->
            plan.copy(
                title = update.title ?: plan.title,
                goal = update.goal ?: plan.goal,
                policyJson = update.policyJson ?: plan.policyJson,
                policy = update.policyJson?.let { parseJsonObject(it) } ?: plan.policy,
                steps = update.steps ?: plan.steps,
                revision = plan.revision + 1,
            )
        }
    }

    override suspend fun setPlanPaused(planId: String, paused: Boolean): Plan {
        lag()
        return updatePlanLocked(planId) { it.copy(paused = paused) }
    }

    override suspend fun confirmPlan(planId: String, revision: Int): Plan {
        lag()
        return updatePlanLocked(planId) { plan ->
            if (plan.revision != revision) {
                throw ServiceError.Api(409, "conflict", "plan revision changed", null)
            }
            plan.copy(awaitingConfirmation = false)
        }
    }

    override suspend fun deletePlan(planId: String) {
        lag()
        synchronized(lock) { planList.removeAll { it.id == planId } }
    }

    override suspend fun addTrigger(planId: String, schedule: Schedule): Trigger {
        lag()
        val trigger = Trigger(newId("trg"), schedule, true, null, null)
        updatePlanLocked(planId) { it.copy(triggers = it.triggers + trigger) }
        return trigger
    }

    override suspend fun deleteTrigger(triggerId: String) {
        lag()
        synchronized(lock) {
            planList.replaceAll { plan -> plan.copy(triggers = plan.triggers.filterNot { it.id == triggerId }) }
        }
    }

    // ---- 团队 ----

    override suspend fun teams(): List<Team> {
        lag()
        return synchronized(lock) { teamList.toList() }
    }

    override suspend fun createTeam(name: String, members: List<TeamMember>): Team {
        lag()
        val team = Team(newId("team"), name, members, clock())
        synchronized(lock) { teamList.add(team) }
        return team
    }

    override suspend fun updateTeam(teamId: String, name: String?, members: List<TeamMember>?): Team {
        lag()
        return synchronized(lock) {
            val i = teamList.indexOfFirst { it.id == teamId }
            if (i < 0) notFound("team", teamId)
            teamList[i].copy(name = name ?: teamList[i].name, members = members ?: teamList[i].members)
                .also { teamList[i] = it }
        }
    }

    override suspend fun deleteTeam(teamId: String) {
        lag()
        synchronized(lock) { teamList.removeAll { it.id == teamId } }
    }

    override suspend fun teamTemplates(): List<TeamTemplate> {
        lag()
        return synchronized(lock) { templateList.toList() }
    }

    override suspend fun saveTeamAsTemplate(teamId: String, name: String): TeamTemplate {
        lag()
        return synchronized(lock) {
            val team = teamList.firstOrNull { it.id == teamId } ?: notFound("team", teamId)
            val members = team.members.mapNotNull { m ->
                instanceList.firstOrNull { it.id == m.instanceId }?.let {
                    cn.thinktin.data.model.TemplateMember(it.agentId, it.harness, it.name, m.role)
                }
            }
            TeamTemplate("tpl-demo-${++idCounter}", name, members, clock()).also { templateList.add(it) }
        }
    }

    override suspend fun deleteTeamTemplate(templateId: String) {
        lag()
        synchronized(lock) { templateList.removeAll { it.id == templateId } }
    }

    override suspend fun adoptTeamTemplate(templateId: String): Team {
        val template = synchronized(lock) { templateList.firstOrNull { it.id == templateId } }
            ?: notFound("template", templateId)
        val members = template.members.mapIndexed { index, m ->
            val instance = adopt(m.agentId, m.name, m.harness)
            TeamMember(instance.id, m.role, index)
        }
        return createTeam(template.name, members)
    }

    // ---- 收件箱 ----

    private fun unreadLocked(): Long = inboxList.count { !it.read }.toLong()

    override suspend fun syncInbox(limit: Int): InboxPage {
        lag(); requireSignedIn()
        return synchronized(lock) {
            InboxPage(items = inboxList.sortedByDescending { it.createdAtMs }.take(limit), unread = unreadLocked())
        }
    }

    override suspend fun olderInbox(beforeId: String, limit: Int): List<InboxItem> {
        lag()
        return cachedInbox(beforeId, limit)
    }

    override fun cachedInbox(beforeId: String?, limit: Int): List<InboxItem> = synchronized(lock) {
        val sorted = inboxList.sortedByDescending { it.createdAtMs }
        val from = if (beforeId == null) 0 else sorted.indexOfFirst { it.id == beforeId }.let { if (it < 0) sorted.size else it + 1 }
        sorted.drop(from).take(limit)
    }

    override fun cachedUnread(): Long = synchronized(lock) { unreadLocked() }

    override suspend fun markInboxRead(ids: List<String>, upToId: String?): Long {
        lag()
        return synchronized(lock) {
            val upTo = upToId?.let { id -> inboxList.firstOrNull { it.id == id }?.createdAtMs }
            inboxList.replaceAll { item ->
                if (item.id in ids || (upTo != null && item.createdAtMs <= upTo)) item.copy(read = true) else item
            }
            unreadLocked()
        }
    }

    override suspend fun markInboxUnread(itemId: String) {
        lag()
        synchronized(lock) { inboxList.replaceAll { if (it.id == itemId) it.copy(read = false) else it } }
    }

    override suspend fun deleteInboxItem(itemId: String) {
        lag()
        synchronized(lock) { inboxList.removeAll { it.id == itemId } }
    }

    // ---- key 与用量 ----

    override suspend fun usage(group: UsageGroup, fromMs: Long?, toMs: Long?, tz: String?): UsageSummary {
        lag()
        val days = data.usageDays
        val buckets = when (group) {
            UsageGroup.Day -> days
            UsageGroup.Instance -> splitTotal(days, listOf("inst-coder" to 7, "inst-research" to 3))
            UsageGroup.Model -> splitTotal(days, listOf("claude-sonnet-4" to 6, "deepseek-chat" to 3, "deepseek-reasoner" to 1))
            UsageGroup.Credential -> splitTotal(days, listOf("cred-work" to 6, "cred-home" to 4))
        }
        return UsageSummary(buckets = buckets, total = sum("total", days))
    }

    private fun sum(key: String, buckets: List<UsageBucket>): UsageBucket = UsageBucket(
        key = key,
        requests = buckets.sumOf { it.requests },
        inputTokens = buckets.sumOf { it.inputTokens },
        cacheReadTokens = buckets.sumOf { it.cacheReadTokens },
        cacheWriteTokens = buckets.sumOf { it.cacheWriteTokens },
        outputTokens = buckets.sumOf { it.outputTokens },
        chargedTokens = buckets.sumOf { it.chargedTokens },
        estimatedRequests = buckets.sumOf { it.estimatedRequests },
        failedRequests = buckets.sumOf { it.failedRequests },
    )

    private fun splitTotal(days: List<UsageBucket>, shares: List<Pair<String, Int>>): List<UsageBucket> {
        val total = sum("total", days)
        val parts = shares.sumOf { it.second }
        return shares.map { (key, share) ->
            fun part(v: Long) = v * share / parts
            UsageBucket(
                key = key, requests = part(total.requests), inputTokens = part(total.inputTokens),
                cacheReadTokens = part(total.cacheReadTokens), cacheWriteTokens = part(total.cacheWriteTokens),
                outputTokens = part(total.outputTokens), chargedTokens = part(total.chargedTokens),
                estimatedRequests = part(total.estimatedRequests), failedRequests = part(total.failedRequests),
            )
        }
    }

    override suspend fun vendors(): List<VendorInfo> {
        lag()
        return data.vendors
    }

    override suspend fun credentials(): List<Credential> {
        lag()
        return synchronized(lock) { credentialList.toList() }
    }

    override suspend fun addCredential(credential: NewCredential): Credential {
        lag()
        if (credential.apiKey.length < 8) throw ServiceError.Api(422, "invalid", "api key too short", null)
        val created = Credential(
            id = newId("cred"), vendor = credential.vendor, label = credential.label,
            last4 = credential.apiKey.takeLast(4), dailyTokenLimit = credential.dailyTokenLimit, disabled = false,
            createdAtMs = clock(),
        )
        synchronized(lock) { credentialList.add(created) }
        return created
    }

    override suspend fun updateCredential(credentialId: String, update: CredentialUpdate): Credential {
        lag()
        return synchronized(lock) {
            val i = credentialList.indexOfFirst { it.id == credentialId }
            if (i < 0) notFound("credential", credentialId)
            val old = credentialList[i]
            old.copy(
                label = update.label ?: old.label,
                dailyTokenLimit = update.dailyTokenLimit ?: old.dailyTokenLimit,
                disabled = update.disabled ?: old.disabled,
            ).also { credentialList[i] = it }
        }
    }

    override suspend fun deleteCredential(credentialId: String) {
        lag()
        synchronized(lock) { credentialList.removeAll { it.id == credentialId } }
    }

    // ---- 保险箱 ----

    override fun detectSecrets(text: String): List<DetectedSecret> {
        val found = mutableListOf<DetectedSecret>()
        LABELED.findAll(text).forEach { m ->
            val value = m.groups[2] ?: return@forEach
            found += DetectedSecret(
                kind = "labeled", start = value.range.first, end = value.range.last + 1, value = value.value,
                suggestedName = "password", service = "", storable = true,
            )
        }
        API_KEY.findAll(text).forEach { m ->
            if (found.none { m.range.first >= it.start && m.range.first < it.end }) {
                found += DetectedSecret(
                    kind = "api_key", start = m.range.first, end = m.range.last + 1, value = m.value,
                    suggestedName = "api_key", service = "", storable = true,
                )
            }
        }
        return found.sortedBy { it.start }
    }

    override suspend fun saveSecretFromMessage(message: String, value: String, item: NewVaultItem): SavedSecret {
        val saved = createVaultItem(item)
        return SavedSecret(item = saved, message = message.replace(value, "[vault:${saved.name}]"))
    }

    override suspend fun vaultItems(): List<VaultItem> {
        lag()
        return synchronized(lock) { vaultList.toList() }
    }

    override suspend fun vaultItem(itemId: String): VaultItemDetail {
        lag()
        return synchronized(lock) {
            val item = vaultList.firstOrNull { it.id == itemId } ?: notFound("vault item", itemId)
            VaultItemDetail(item = item, username = vaultUsernames[itemId].orEmpty())
        }
    }

    override suspend fun createVaultItem(item: NewVaultItem): VaultItem {
        lag()
        val now = clock()
        return synchronized(lock) {
            if (vaultList.any { it.name == item.name }) throw ServiceError.Api(409, "conflict", "name taken", null)
            val created = VaultItem(
                id = "vault-demo-${++idCounter}", name = item.name, purpose = item.purpose,
                hasUsername = item.username.isNotEmpty(), instanceIds = item.instanceIds, createdAtMs = now,
                updatedAtMs = now, lastUsedAtMs = null,
            )
            vaultList.add(created)
            vaultUsernames[created.id] = item.username
            created
        }
    }

    override suspend fun updateVaultItem(itemId: String, change: VaultItemUpdate): VaultItem {
        lag()
        return synchronized(lock) {
            val i = vaultList.indexOfFirst { it.id == itemId }
            if (i < 0) notFound("vault item", itemId)
            change.username?.let { vaultUsernames[itemId] = it }
            val old = vaultList[i]
            old.copy(
                purpose = change.purpose ?: old.purpose,
                hasUsername = vaultUsernames[itemId].orEmpty().isNotEmpty(),
                instanceIds = change.instanceIds ?: old.instanceIds,
                updatedAtMs = clock(),
            ).also { vaultList[i] = it }
        }
    }

    override suspend fun deleteVaultItem(itemId: String) {
        lag()
        synchronized(lock) { vaultList.removeAll { it.id == itemId } }
    }

    override suspend fun vaultRequests(all: Boolean): List<VaultRequest> {
        lag()
        return synchronized(lock) { vaultRequestList.filter { all || it.status == VaultRequestStatus.Pending } }
    }

    private fun resolveRequest(requestId: String, status: VaultRequestStatus, itemId: String?): VaultRequest =
        synchronized(lock) {
            val i = vaultRequestList.indexOfFirst { it.id == requestId }
            if (i < 0) notFound("vault request", requestId)
            vaultRequestList[i].copy(status = status, itemId = itemId, resolvedAtMs = clock())
                .also { vaultRequestList[i] = it }
        }

    override suspend fun fulfillVaultRequest(
        requestId: String,
        username: String,
        password: String,
        purpose: String?,
    ): VaultRequest {
        val request = synchronized(lock) { vaultRequestList.firstOrNull { it.id == requestId } }
            ?: notFound("vault request", requestId)
        val item = createVaultItem(
            NewVaultItem(request.name, purpose ?: request.purpose, username, password, listOf(request.instanceId)),
        )
        val resolved = resolveRequest(requestId, VaultRequestStatus.Fulfilled, item.id)
        append(request.instanceId, request.runId, EventKinds.VAULT_FULFILLED, buildJsonObject {
            put("request_id", requestId); put("name", request.name)
        })
        return resolved
    }

    override suspend fun declineVaultRequest(requestId: String): VaultRequest {
        lag()
        val resolved = resolveRequest(requestId, VaultRequestStatus.Declined, null)
        append(resolved.instanceId, resolved.runId, EventKinds.VAULT_DECLINED, buildJsonObject { put("request_id", requestId) })
        return resolved
    }

    companion object {
        const val DEFAULT_EVENT_INTERVAL_MS: Long = 2_000
        private const val SCRIPT_LENGTH = 5

        private val LABELED = Regex("""(?i)(password|passwd|pwd|密码|口令|token|secret)\s*[:：=]\s*(\S{6,})""")
        private val API_KEY = Regex("""\b(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,})""")
    }
}
