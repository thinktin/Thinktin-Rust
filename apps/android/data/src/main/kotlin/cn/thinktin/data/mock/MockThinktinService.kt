package cn.thinktin.data.mock

import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.ContentReport
import cn.thinktin.data.model.ConversationBuilder
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.DeviceInfo
import cn.thinktin.data.model.DeviceMessage
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.ImChannel
import cn.thinktin.data.model.ImChannelRules
import cn.thinktin.data.model.ImChannelUpdate
import cn.thinktin.data.model.ImEvents
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxPage
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.LoginResult
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.NewImChannel
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.ReportReason
import cn.thinktin.data.model.ReportState
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunFilter
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.SavedSecret
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.SignOutOthersResult
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamTemplate
import cn.thinktin.data.model.TemplateMember
import cn.thinktin.data.model.Trigger
import cn.thinktin.data.model.TriggerDisabledReason
import cn.thinktin.data.model.UsageBucket
import cn.thinktin.data.model.UsageGroup
import cn.thinktin.data.model.UsageSummary
import cn.thinktin.data.model.User
import cn.thinktin.data.model.VaultItem
import cn.thinktin.data.model.VaultItemDetail
import cn.thinktin.data.model.VaultItemUpdate
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.VaultRules
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
    /**
     * 账号的实例数上限（服务端的 `[api.limits] instances_per_user`，11.9）：0 不限（服务端的默认值）。
     * 到了上限领养报 409 `instance_limit`。
     */
    private val instanceLimit: Int = 0,
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
    private val deviceMessageList = data.deviceMessages.toMutableList()
    private val sentDeviceMessageList = mutableListOf<DeviceMessage>()
    private val reportList = data.reports.toMutableList()
    private val teamList = data.teams.toMutableList()
    private val templateList = data.teamTemplates.toMutableList()
    private val imChannelList = data.imChannels.toMutableList()

    /** 最近一小时发过的 IM 测试消息（毫秒时间）。 */
    private val imTests = mutableListOf<Long>()
    private var idCounter = 0
    private var scriptStep = 0

    /** 新追加的事件（发消息、演示脚本），推给正在收集 events() 的页面。 */
    private val appended = MutableSharedFlow<InstanceEvent>(extraBufferCapacity = 64)

    override val isDemo: Boolean = true

    private val auth = MutableStateFlow(AuthState.SignedIn)
    override val authState: StateFlow<AuthState> = auth.asStateFlow()

    /** 最近一次 [setAcceptLanguage] 给的语言列表（演示模式不联网，只记下来；测试用）。 */
    @Volatile
    var acceptLanguageTags: List<String> = emptyList()
        private set

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

    override suspend fun updateProfile(displayName: String?): User {
        lag()
        return synchronized(lock) { user.copy(displayName = displayName?.takeIf { it.isNotBlank() }).also { user = it } }
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
        // 和服务端一样：吊销的设备不再出现在列表里。
        val count = synchronized(lock) {
            val others = deviceList.count { !it.current }
            deviceList.removeAll { !it.current }
            others.toLong()
        }
        return SignOutOthersResult(devicesSignedOut = count, stopped = stopped)
    }

    override suspend fun devices(): List<DeviceInfo> {
        lag(); requireSignedIn()
        return synchronized(lock) { deviceList.sortedByDescending { it.lastSeenAtMs } }
    }

    override suspend fun revokeDevice(deviceId: String) {
        lag()
        val current = synchronized(lock) {
            val device = deviceList.firstOrNull { it.id == deviceId } ?: notFound("device", deviceId)
            deviceList.remove(device)
            device.current
        }
        // 吊销当前这台等于退出登录（和真实服务一样，本地马上退出）。
        if (current) auth.value = AuthState.SignedOut
    }

    override fun setAcceptLanguage(languageTags: List<String>) {
        acceptLanguageTags = languageTags.toList()
    }

    /** 演示模式不联网，版本永远够新；测试可以调 [simulateUpgradeRequired] 看升级页。 */
    private val upgrade = MutableStateFlow(false)
    override val upgradeState: StateFlow<Boolean> = upgrade.asStateFlow()

    override fun upgradeRequired(): Boolean = upgrade.value

    /** 模拟服务端说版本太老（测试用；和真实服务一样，置上之后不再变回）。 */
    fun simulateUpgradeRequired() {
        upgrade.value = true
    }

    override suspend fun sendSelfCode(purpose: SelfCodePurpose) {
        lag(); requireSignedIn()
    }

    override suspend fun deleteAccount(code: String) {
        lag()
        if (code.length != 6) throw ServiceError.Api(400, "invalid_code", "code must have 6 digits", null)
        auth.value = AuthState.SignedOut
    }

    // ---- 手机和电脑之间的消息 ----

    override suspend fun sendDeviceMessage(toDeviceId: String, kind: DeviceMessageKind, bodyJson: String): DeviceMessage {
        lag()
        if (kind == DeviceMessageKind.Unknown) throw ServiceError.Api(422, "invalid", "unknown device message kind", null)
        val body = parseJsonObject(bodyJson)
        val from = synchronized(lock) {
            if (deviceList.none { it.id == toDeviceId }) notFound("device", toDeviceId)
            deviceList.first { it.current }.id
        }
        val now = clock()
        val message = DeviceMessage(
            id = newId("dmsg"), fromDeviceId = from, toDeviceId = toDeviceId, kind = kind, bodyJson = bodyJson,
            body = body, createdAtMs = now, expiresAtMs = now + DEVICE_MESSAGE_TTL_MS,
        )
        synchronized(lock) { sentDeviceMessageList += message }
        return message
    }

    /** 本机发出去的消息（测试看发了什么；演示模式里没有电脑收）。 */
    fun sentDeviceMessages(): List<DeviceMessage> = synchronized(lock) { sentDeviceMessageList.toList() }

    /** 模拟另一台设备（比如在线的 Mac）发来一条消息，之后 [deviceMessages] 能收到（不校验方向和签名）。 */
    fun deliverDeviceMessage(fromDeviceId: String, kind: DeviceMessageKind, bodyJson: String): DeviceMessage {
        val now = clock()
        return synchronized(lock) {
            val message = DeviceMessage(
                id = "dmsg-demo-${++idCounter}", fromDeviceId = fromDeviceId, toDeviceId = deviceList.first { it.current }.id,
                kind = kind, bodyJson = bodyJson, body = parseJsonObject(bodyJson), createdAtMs = now,
                expiresAtMs = now + DEVICE_MESSAGE_TTL_MS,
            )
            deviceMessageList += message
            message
        }
    }

    override suspend fun deviceMessages(): List<DeviceMessage> {
        lag()
        return synchronized(lock) { deviceMessageList.sortedBy { it.createdAtMs } }
    }

    override suspend fun ackDeviceMessages(ids: List<String>): Long {
        lag()
        return synchronized(lock) {
            val before = deviceMessageList.size
            deviceMessageList.removeAll { it.id in ids }
            (before - deviceMessageList.size).toLong()
        }
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

    override suspend fun instance(instanceId: String): Instance {
        lag(); requireSignedIn()
        return synchronized(lock) { instanceList.firstOrNull { it.id == instanceId && it.state != InstanceState.Deleted } }
            ?: notFound("instance", instanceId)
    }

    override suspend fun cachedInstances(): List<Instance> =
        synchronized(lock) { instanceList.filter { it.state != InstanceState.Deleted } }

    /** 名字 1–64 个字（去掉首尾空白后），和服务端一样。 */
    private fun checkInstanceName(name: String): String {
        val trimmed = name.trim()
        val length = trimmed.codePointCount(0, trimmed.length)
        if (length !in 1..64) {
            throw ServiceError.Api(status = 422, code = "invalid", detail = "name must be 1-64 characters", retryAfterSecs = null)
        }
        return trimmed
    }

    override suspend fun adopt(agentId: String, name: String, harness: String?): Instance {
        lag(); requireSignedIn()
        return synchronized(lock) {
            checkInstanceLimit(1)
            newInstanceLocked(checkAdopt(agentId, name, harness))
        }
    }

    /** 领养前的检查（control 的 adopt）：agent 在目录里、名字 1–64 字、接入方式是它有的。返回要建的实例（还没加进列表）。 */
    private fun checkAdopt(agentId: String, name: String, harness: String?): Instance {
        val agent = agentList.firstOrNull { it.id == agentId } ?: notFound("agent", agentId)
        val checked = checkInstanceName(name)
        if (harness != null && harness !in agent.harnesses) {
            throw ServiceError.Api(status = 422, code = "invalid", detail = "$agentId has no harness $harness", retryAfterSecs = null)
        }
        val now = clock()
        return Instance(
            id = "", agentId = agent.id, agentVersion = agent.version,
            harness = harness ?: agent.defaultHarness, name = checked, state = InstanceState.Running,
            createdAtMs = now, lastActiveAtMs = now,
        )
    }

    private fun newInstanceLocked(spec: Instance): Instance =
        spec.copy(id = newId("inst")).also { instanceList.add(it) }

    /** 再领养 [adding] 个就超过实例数上限（没删除的才算）时报 409 `instance_limit`（和服务端一样）。 */
    private fun checkInstanceLimit(adding: Int) {
        if (instanceLimit <= 0) return
        val count = instanceList.count { it.state != InstanceState.Deleted }
        if (count + adding > instanceLimit) {
            throw ServiceError.Api(409, INSTANCE_LIMIT, "at most $instanceLimit instances per account", null)
        }
    }

    private fun updateInstance(instanceId: String, change: (Instance) -> Instance): Instance = synchronized(lock) {
        val i = instanceList.indexOfFirst { it.id == instanceId }
        if (i < 0) notFound("instance", instanceId)
        change(instanceList[i]).also { instanceList[i] = it }
    }

    override suspend fun renameInstance(instanceId: String, name: String): Instance {
        lag(); requireSignedIn()
        val checked = checkInstanceName(name)
        return updateInstance(instanceId) { it.copy(name = checked) }
    }

    override suspend fun setInstanceVersion(instanceId: String, version: String?): Instance {
        lag()
        requireSignedIn()
        return updateInstance(instanceId) { inst ->
            val agent = agentList.first { it.id == inst.agentId }
            if (version != null && version !in agent.versions) {
                throw ServiceError.Api(status = 422, code = "invalid", detail = "version $version is not available", retryAfterSecs = null)
            }
            inst.copy(agentVersion = version ?: agent.version)
        }
    }

    /**
     * 和服务端一样（11.9，接入网关的 instances::delete）：实例标记删除（state = deleted）；它自己的计划标记删除（这里直接
     * 从列表里拿掉，plans() 和 getPlan 都看不到）；别的实例的流水线有一步在它上面、还在跑的暂停（恢复、确认报 409，
     * 改了步骤才行，见 [refuseDeletedSteps]）；它的模型别名和降级链一起删掉；团队成员在读取时过滤（[teams]、[team]，
     * 对应 store/teams.rs）。
     */
    override suspend fun deleteInstance(instanceId: String) {
        lag(); requireSignedIn()
        synchronized(lock) {
            if (instanceList.none { it.id == instanceId && it.state != InstanceState.Deleted }) notFound("instance", instanceId)
            planList.removeAll { it.instanceId == instanceId }
            planList.replaceAll { plan ->
                if (!plan.paused && plan.steps.any { it.instanceId == instanceId }) plan.copy(paused = true).withSchedule() else plan
            }
            routes.remove(instanceId)
            updateInstance(instanceId) { it.copy(state = InstanceState.Deleted) }
        }
    }

    override suspend fun modelRoutes(instanceId: String): List<ModelRoute> {
        lag()
        return synchronized(lock) { routes[instanceId].orEmpty() }
    }

    /**
     * 和服务端一样：最多 16 个别名、每个最多 3 个备用，别名格式按库里的约束，key 必须存在；新引用的 key 不能是停用的，
     * 实例原来就用着（主 key 或降级链）的停用 key 可以留着（11.9）。
     */
    override suspend fun setModelRoutes(instanceId: String, routes: List<ModelRoute>) {
        lag()
        synchronized(lock) {
            if (instanceList.none { it.id == instanceId && it.state != InstanceState.Deleted }) notFound("instance", instanceId)
            val kept = this.routes[instanceId].orEmpty()
                .flatMap { route -> listOf(route.credentialId) + route.fallbacks.map { it.credentialId } }
                .toSet()
            if (routes.size > 16) invalid("at most 16 model aliases")
            if (routes.map { it.alias }.toSet().size != routes.size) invalid("duplicate model alias")
            for (route in routes) {
                if (!ALIAS.matches(route.alias)) invalid("bad alias ${route.alias}")
                if (route.fallbacks.size > 3) invalid("at most 3 fallbacks per model alias")
                val used = listOf(route.credentialId to route.upstreamModel) +
                    route.fallbacks.map { it.credentialId to it.upstreamModel }
                for ((credentialId, model) in used) {
                    if (model.isEmpty() || model.codePointCount(0, model.length) > 128) invalid("upstream_model must be 1-128 characters")
                    val credential = credentialList.firstOrNull { it.id == credentialId } ?: notFound("credential", credentialId)
                    if (credential.disabled && credentialId !in kept) invalid("credential $credentialId is disabled")
                }
            }
            this.routes[instanceId] = routes
        }
        // 换了 key 或者加了备用 key：等额度的运行接着跑。
        wakeRunsWaitingForQuota()
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

    override suspend fun listRuns(filter: RunFilter, beforeRunId: String?, limit: Int): List<Run> {
        lag(); requireSignedIn()
        return synchronized(lock) {
            val all = runList
                .filter { filter.planId == null || it.planId == filter.planId || it.rootPlanId() == filter.planId }
                .filter { !filter.activeOnly || it.state.isActive }
                .filter { !filter.rootsOnly || it.parentRunId == null }
                .sortedByDescending { it.createdAtMs }
            val start = if (beforeRunId == null) 0 else all.indexOfFirst { it.id == beforeRunId }.let { if (it < 0) all.size else it + 1 }
            all.drop(start).take(limit.coerceAtLeast(0))
        }
    }

    /** 流水线步骤、委派的子任务记在根运行的计划下（真实服务的 plan_id 过滤也包括它们）。调用方持有 [lock]。 */
    private fun Run.rootPlanId(): String? =
        if (parentRunId == null) planId else runList.firstOrNull { it.id == rootRunId }?.planId

    private fun sortedRuns(instanceId: String): List<Run> =
        runList.filter { it.instanceId == instanceId }.sortedByDescending { it.createdAtMs }

    override suspend fun cachedRuns(instanceId: String, limit: Int): List<Run> =
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

    override suspend fun instanceArtifacts(instanceId: String, limit: Int): List<Artifact> {
        lag()
        return synchronized(lock) {
            artifactList.filter { it.instanceId == instanceId }.sortedByDescending { it.createdAtMs }
                .take(limit.coerceIn(0, MAX_ARTIFACTS))
        }
    }

    override suspend fun deleteArtifact(artifactId: String) {
        lag()
        synchronized(lock) { if (!artifactList.removeAll { it.id == artifactId }) notFound("artifact", artifactId) }
    }

    // ---- 事件 ----

    /**
     * 等额度的运行马上接着跑（服务端的 `wake_waiting_runs(waiting_quota)`，7.11）：加了 key、启用、放宽或取消每日上限、
     * 换 key、改模型路由之后。演示里改成“开始”，记一条运行状态事件。
     */
    private fun wakeRunsWaitingForQuota() {
        val woken = synchronized(lock) {
            runList.indices.filter { runList[it].state == RunState.WaitingQuota }.map { i ->
                runList[i].copy(state = RunState.Starting, stateReason = null, waitCode = null).also { runList[i] = it }
            }
        }
        for (run in woken) {
            append(run.instanceId, run.id, EventKinds.RUN_STATE, buildJsonObject { put("state", RunState.Starting.wire) })
        }
    }

    private fun append(instanceId: String, runId: String?, kind: String, payload: JsonObject): InstanceEvent {
        val event = synchronized(lock) {
            val seq = (nextSeq[instanceId] ?: 0L) + 1
            nextSeq[instanceId] = seq
            InstanceEvent(
                instanceId = instanceId, seq = seq, runId = runId, kind = kind, payload = payload,
                aiGenerated = kind in ConversationBuilder.AI_GENERATED_KINDS, createdAtMs = clock(),
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
        if (auth.value == AuthState.SignedOut) {
            send(EventStreamItem.Status(StreamState.SignedOut))
            return@channelFlow
        }
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

    override suspend fun cachedEvents(instanceId: String, afterSeq: Long, limit: Int): List<InstanceEvent> =
        synchronized(lock) {
            eventList.filter { it.instanceId == instanceId && it.seq > afterSeq }.sortedBy { it.seq }.take(limit)
        }

    override suspend fun cachedEventsBefore(instanceId: String, beforeSeq: Long?, limit: Int): List<InstanceEvent> =
        synchronized(lock) {
            eventList.filter { it.instanceId == instanceId && (beforeSeq == null || it.seq < beforeSeq) }
                .sortedBy { it.seq }.takeLast(limit.coerceAtLeast(0))
        }

    // ---- 审批 ----

    override suspend fun approvals(): List<Approval> {
        lag()
        // 和服务端一样只列待处理的。
        return synchronized(lock) {
            approvalList.filter { it.state == ApprovalState.Pending }.sortedByDescending { it.createdAtMs }
        }
    }

    override suspend fun getApproval(approvalId: String): Approval {
        lag()
        return synchronized(lock) { approvalList.firstOrNull { it.id == approvalId } } ?: notFound("approval", approvalId)
    }

    override suspend fun decideApproval(approvalId: String, optionId: String): Approval {
        lag()
        val decided = synchronized(lock) {
            val i = approvalList.indexOfFirst { it.id == approvalId }
            if (i < 0) notFound("approval", approvalId)
            val approval = approvalList[i]
            if (approval.state != ApprovalState.Pending) {
                throw ServiceError.Api(409, "conflict", "approval is already ${approval.state.wire}", null)
            }
            val option = approval.options.firstOrNull { it.optionId == optionId }
                ?: throw ServiceError.Api(422, "invalid", "unknown option $optionId", null)
            val state = if (option.kind.isAllow) ApprovalState.Approved else ApprovalState.Rejected
            approval.copy(state = state, decidedOption = optionId, decidedAtMs = clock()).also {
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
            buildJsonObject {
                put("approval_id", approvalId); put("state", decided.state.wire); put("option_id", optionId)
                put("request_id", decided.requestId); put("attempt", decided.attempt)
            },
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
        val policy = plan.policy ?: PlanPolicy()
        val created = Plan(
            id = newId("plan"), instanceId = plan.instanceId, title = plan.title, goal = plan.goal, paused = false,
            createdBy = "user", awaitingConfirmation = false, revision = 1, policyJson = policy.toServerJson(),
            policy = policy, catchUp = plan.catchUp ?: CatchUp.Once, createdAtMs = now,
            triggers = plan.triggers.map { Trigger(newId("trg"), it, true, firstFire(it), null) }, steps = plan.steps,
        ).withSchedule()
        synchronized(lock) { planList.add(created) }
        return created
    }

    private fun updatePlanLocked(planId: String, change: (Plan) -> Plan): Plan = synchronized(lock) {
        val i = planList.indexOfFirst { it.id == planId }
        if (i < 0) notFound("plan", planId)
        change(planList[i]).withSchedule().also { planList[i] = it }
    }

    /** 像服务端那样重算下一次运行时间和失效触发器个数：暂停、等确认时没有下一次。 */
    private fun Plan.withSchedule(): Plan = copy(
        nextFireAtMs = if (paused || awaitingConfirmation) {
            null
        } else {
            triggers.filter { it.enabled }.mapNotNull { it.nextFireAtMs }.minOrNull()
        },
        invalidTriggers = triggers.count { it.disabledReason == TriggerDisabledReason.InvalidRule },
    )

    /** 新触发器的下一次时间：只算一次性的（cron、rrule 演示模式不展开）。 */
    private fun firstFire(schedule: Schedule): Long? =
        (schedule as? Schedule.Once)?.atMs?.takeIf { it > clock() }

    override suspend fun updatePlan(planId: String, change: PlanChange): Plan {
        lag()
        if (change.catchUp == CatchUp.Unknown) throw ServiceError.Api(422, "invalid", "unknown catch_up", null)
        return updatePlanLocked(planId) { plan ->
            val policy = change.policy ?: plan.policy
            plan.copy(
                title = change.title ?: plan.title,
                goal = change.goal ?: plan.goal,
                policy = policy,
                policyJson = policy.toServerJson(),
                catchUp = change.catchUp ?: plan.catchUp,
                steps = change.steps ?: plan.steps,
                revision = plan.revision + 1,
            )
        }
    }

    override suspend fun setPlanPaused(planId: String, paused: Boolean): Plan {
        lag()
        return updatePlanLocked(planId) { plan ->
            if (!paused) refuseDeletedSteps(plan)
            plan.copy(paused = paused)
        }
    }

    /**
     * 流水线有一步在已删除的实例上（删除实例时暂停了它，11.9）：恢复、确认都报 409 conflict，先改步骤（updatePlan）才行。
     */
    private fun refuseDeletedSteps(plan: Plan) {
        val deleted = instanceList.filter { it.state == InstanceState.Deleted }.map { it.id }.toSet()
        plan.steps.firstOrNull { it.instanceId in deleted }?.let { step ->
            throw ServiceError.Api(409, "conflict", "step ${step.key} runs on a deleted instance; change the steps first", null)
        }
    }

    override suspend fun confirmPlan(planId: String, revision: Int): Plan {
        lag()
        return updatePlanLocked(planId) { plan ->
            refuseDeletedSteps(plan)
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
        val trigger = Trigger(newId("trg"), schedule, true, firstFire(schedule), null)
        updatePlanLocked(planId) { plan ->
            if (plan.triggers.size >= MAX_TRIGGERS) {
                throw ServiceError.Api(422, "invalid", "a plan has at most $MAX_TRIGGERS triggers", null)
            }
            plan.copy(triggers = plan.triggers + trigger)
        }
        return trigger
    }

    override suspend fun deleteTrigger(triggerId: String) {
        lag()
        synchronized(lock) {
            if (planList.none { plan -> plan.triggers.any { it.id == triggerId } }) notFound("trigger", triggerId)
            planList.replaceAll { plan -> plan.copy(triggers = plan.triggers.filterNot { it.id == triggerId }).withSchedule() }
        }
    }

    // ---- 团队 ----

    override suspend fun teams(): List<Team> {
        lag()
        return synchronized(lock) { teamList.map(::withoutDeletedMembers) }
    }

    override suspend fun team(teamId: String): Team {
        lag()
        return synchronized(lock) { teamList.firstOrNull { it.id == teamId }?.let(::withoutDeletedMembers) } ?: notFound("team", teamId)
    }

    /** 和服务端一样：读取时不列出已删除的实例（store/teams.rs 的 team 查询 JOIN instances 过滤 deleted）。 */
    private fun withoutDeletedMembers(team: Team): Team {
        val deleted = instanceList.filter { it.state == InstanceState.Deleted }.map { it.id }.toSet()
        if (team.members.none { it.instanceId in deleted }) return team
        return team.copy(members = team.members.filterNot { it.instanceId in deleted })
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

    override suspend fun createTeamTemplate(name: String, members: List<TemplateMember>): TeamTemplate {
        lag()
        val template = TeamTemplate(newId("tpl"), name, members, clock())
        synchronized(lock) { templateList.add(template) }
        return template
    }

    override suspend fun createTeamTemplateFromTeam(name: String, teamId: String): TeamTemplate {
        lag()
        return synchronized(lock) {
            val team = teamList.firstOrNull { it.id == teamId } ?: notFound("team", teamId)
            val members = team.members.sortedBy { it.position }.mapNotNull { m ->
                instanceList.firstOrNull { it.id == m.instanceId }?.let {
                    TemplateMember(it.agentId, it.harness, it.name, m.role)
                }
            }
            TeamTemplate("tpl-demo-${++idCounter}", name, members, clock()).also { templateList.add(it) }
        }
    }

    override suspend fun deleteTeamTemplate(templateId: String) {
        lag()
        synchronized(lock) { templateList.removeAll { it.id == templateId } }
    }

    /**
     * 和服务端一样（11.9）全成或全不成：团队名不合法（1–64 字）报 422；放不下整个团队报 409 `instance_limit`；
     * 有成员领养不了（agent 下架、接入方式不对）也一个都不建。
     */
    override suspend fun adoptTeamTemplate(templateId: String, name: String?): Team {
        lag(); requireSignedIn()
        return synchronized(lock) {
            val template = templateList.firstOrNull { it.id == templateId } ?: notFound("template", templateId)
            val teamName = (name ?: template.name).trim()
            if (teamName.codePointCount(0, teamName.length) !in 1..64) invalid("name must be 1-64 characters")
            checkInstanceLimit(template.members.size)
            val specs = template.members.map { checkAdopt(it.agentId, it.name, it.harness) }
            val members = specs.mapIndexed { index, spec ->
                TeamMember(newInstanceLocked(spec).id, template.members[index].role, index)
            }
            Team(newId("team"), teamName, members, clock()).also { teamList.add(it) }
        }
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

    override suspend fun cachedInbox(beforeId: String?, limit: Int): List<InboxItem> = synchronized(lock) {
        val sorted = inboxList.sortedByDescending { it.createdAtMs }
        val from = if (beforeId == null) 0 else sorted.indexOfFirst { it.id == beforeId }.let { if (it < 0) sorted.size else it + 1 }
        sorted.drop(from).take(limit)
    }

    override suspend fun cachedUnread(): Long = synchronized(lock) { unreadLocked() }

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

    override suspend fun inboxItem(itemId: String): InboxItem {
        lag()
        return synchronized(lock) { inboxList.firstOrNull { it.id == itemId } } ?: notFound("inbox item", itemId)
    }

    override suspend fun markInboxUnread(itemId: String): Long {
        lag()
        return synchronized(lock) {
            if (inboxList.none { it.id == itemId }) notFound("inbox item", itemId)
            inboxList.replaceAll { if (it.id == itemId) it.copy(read = false) else it }
            unreadLocked()
        }
    }

    override suspend fun deleteInboxItem(itemId: String) {
        lag()
        synchronized(lock) { if (!inboxList.removeAll { it.id == itemId }) notFound("inbox item", itemId) }
    }

    // ---- IM 渠道 ----

    override suspend fun imChannels(): List<ImChannel> {
        lag()
        return synchronized(lock) { imChannelList.toList() }
    }

    /** webhook 地址和签名密钥，按服务端的规则（[ImChannelRules]）查。 */
    private fun checkImWebhook(url: String, secret: String?): ImChannelRules.ParsedWebhook {
        if (url.length > ImChannelRules.MAX_WEBHOOK) invalid("webhook_url must be 1-512 characters")
        val parsed = ImChannelRules.parseWebhook(url) ?: when (ImChannelRules.webhookProblem(url)) {
            ImChannelRules.Problem.BadToken -> invalid("webhook_url: the token after the address is missing or malformed")
            else -> invalid("webhook_url must be a Feishu, Lark, WeCom or DingTalk group bot webhook address, copied as is")
        }
        when (ImChannelRules.secretProblem(secret.orEmpty(), parsed.vendor)) {
            ImChannelRules.Problem.SecretNotSupported -> invalid("secret: WeCom bots have no signing secret")
            null -> {}
            else -> invalid("secret must be 8-128 visible characters (DingTalk secrets start with SEC)")
        }
        return parsed
    }

    private fun checkImLabelAndEvents(label: String?, events: List<String>?) {
        if (label != null && ImChannelRules.labelProblem(label) != null) invalid("label must be 0-64 characters")
        if (events != null) {
            if (events.isEmpty()) invalid("events must name at least one of run_finished, run_failed, approval")
            events.firstOrNull { it !in ImEvents.ALL }?.let { invalid("unknown event \"$it\"") }
        }
    }

    override suspend fun addImChannel(channel: NewImChannel): ImChannel {
        lag()
        return synchronized(lock) {
            val parsed = checkImWebhook(channel.webhookUrl, channel.secret)
            checkImLabelAndEvents(channel.label, channel.events)
            if (imChannelList.size >= ImChannelRules.MAX_CHANNELS) {
                invalid("at most ${ImChannelRules.MAX_CHANNELS} IM channels per account")
            }
            ImChannel(
                id = newId("im"), vendor = parsed.vendor, label = channel.label,
                hint = ImChannelRules.hint(parsed.token), hasSecret = !channel.secret.isNullOrBlank(),
                events = channel.events ?: ImEvents.ALL, enabled = true, lastSentAtMs = null, lastError = null,
                createdAtMs = clock(),
            ).also { imChannelList.add(it) }
        }
    }

    override suspend fun updateImChannel(channelId: String, update: ImChannelUpdate): ImChannel {
        lag()
        return synchronized(lock) {
            checkImLabelAndEvents(update.label, update.events)
            val i = imChannelList.indexOfFirst { it.id == channelId }
            if (i < 0) notFound("im channel", channelId)
            val old = imChannelList[i]
            old.copy(
                label = update.label ?: old.label,
                events = update.events ?: old.events,
                enabled = update.enabled ?: old.enabled,
            ).also { imChannelList[i] = it }
        }
    }

    override suspend fun deleteImChannel(channelId: String) {
        lag()
        synchronized(lock) {
            if (!imChannelList.removeAll { it.id == channelId }) notFound("im channel", channelId)
        }
    }

    /** 测试消息：关着的不发；每小时最多 10 条（多了 429）。 */
    override suspend fun testImChannel(channelId: String) {
        lag()
        synchronized(lock) {
            val i = imChannelList.indexOfFirst { it.id == channelId }
            if (i < 0) notFound("im channel", channelId)
            if (!imChannelList[i].enabled) invalid("the channel is turned off; turn it on first")
            val now = clock()
            imTests.removeAll { now - it >= HOUR_MS }
            if (imTests.size >= ImChannelRules.TESTS_PER_HOUR) {
                throw ServiceError.Api(429, "rate_limited", "too many IM test messages", 3600)
            }
            imTests.add(now)
            imChannelList[i] = imChannelList[i].copy(lastSentAtMs = now)
        }
    }

    /** 换地址：清掉之前的错误；机器人失效被后台停掉的（Mock 里按“关着、有错误”算）重新打开，用户自己关的还关着。 */
    override suspend fun replaceImWebhook(channelId: String, webhookUrl: String, secret: String?): ImChannel {
        lag()
        return synchronized(lock) {
            val parsed = checkImWebhook(webhookUrl, secret)
            val i = imChannelList.indexOfFirst { it.id == channelId }
            if (i < 0) notFound("im channel", channelId)
            val old = imChannelList[i]
            old.copy(
                vendor = parsed.vendor,
                hint = ImChannelRules.hint(parsed.token),
                hasSecret = !secret.isNullOrBlank(),
                lastError = null,
                enabled = old.enabled || old.lastError != null,
            ).also { imChannelList[i] = it }
        }
    }

    // ---- key 与用量 ----

    override suspend fun usage(group: UsageGroup, fromMs: Long?, toMs: Long?, tz: String?): UsageSummary {
        lag()
        // 和服务端一样：不给时间就是最近 30 天；按天切分的时区默认 Asia/Shanghai（演示数据固定按它切）。
        val to = toMs ?: clock()
        val from = fromMs ?: (to - 30L * 24 * 60 * 60 * 1000)
        if (from >= to || to - from > 366L * 24 * 60 * 60 * 1000) invalid("from must be before to, at most 366 days apart")
        val zone = MockData.USAGE_ZONE
        val days = data.usageDays.filter { bucket ->
            val start = java.time.LocalDate.parse(bucket.key).atStartOfDay(zone).toInstant().toEpochMilli()
            start < to && start + 24L * 60 * 60 * 1000 > from
        }
        val buckets = when (group) {
            UsageGroup.Day -> days
            UsageGroup.Instance -> splitTotal(days, listOf("inst-coder" to 7, "inst-research" to 3))
            UsageGroup.Model -> splitTotal(
                days,
                listOf("anthropic/claude-sonnet-4" to 6, "deepseek/deepseek-chat" to 3, "deepseek/deepseek-reasoner" to 1),
            )
            UsageGroup.Credential -> splitTotal(days, listOf("cred-work" to 6, "cred-home" to 4))
        }.filter { it.requests > 0 }
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
        val vendor = data.vendors.firstOrNull { it.id == credential.vendor }
        if (vendor == null && credential.vendor != CUSTOM_VENDOR) invalid("unknown vendor: use an id from GET /v1/vendors, or custom with your own base URLs")
        // 服务端 check_len 按字符（码点）数。
        if (credential.label.codePointCount(0, credential.label.length) > 64) invalid("label must be 0-64 characters")
        checkKey(credential.vendor, credential.apiKey)
        val bases = listOf(
            "anthropic_base" to credential.anthropicBase,
            "openai_base" to credential.openaiBase,
            "responses_base" to credential.responsesBase,
        )
        for ((field, base) in bases) {
            if (base != null && !base.startsWith("https://")) invalid("$field must be an https URL")
            base?.let(::planOnlyBase)?.let { plan ->
                invalid(
                    "$field: $plan is a coding or subscription plan address, which only works in the vendor's own tools; " +
                        "use the pay-as-you-go address",
                )
            }
        }
        val hasBase = bases.any { it.second != null }
        if ((credential.vendor == CUSTOM_VENDOR) != hasBase) {
            invalid("base URLs are required for, and only allowed with, vendor custom")
        }
        if (credential.dailyTokenLimit == 0L) invalid("daily_token_limit must be positive")
        val protocols = vendor?.protocols ?: listOfNotNull(
            "anthropic".takeIf { credential.anthropicBase != null },
            "chat".takeIf { credential.openaiBase != null },
            "responses".takeIf { credential.responsesBase != null },
        )
        val created = Credential(
            id = newId("cred"), vendor = credential.vendor, label = credential.label,
            last4 = credential.apiKey.takeLast(4), dailyTokenLimit = credential.dailyTokenLimit, disabled = false,
            createdAtMs = clock(),
            protocols = protocols,
        )
        synchronized(lock) { credentialList.add(created) }
        wakeRunsWaitingForQuota()
        return created
    }

    /** 服务端保存 key 前的检查（gateway 的 check_key + proto::vendors::check_key）。 */
    private fun checkKey(vendor: String, apiKey: String) {
        if (apiKey.length < 8 || apiKey.length > 4096) invalid("api_key must be 8-4096 bytes")
        if (apiKey.any { it.isWhitespace() || it.isISOControl() }) invalid("api_key must not contain spaces or control characters")
        data.vendors.firstOrNull { it.id == vendor }?.subscriptionKeyPrefixes?.firstOrNull { apiKey.startsWith(it) }?.let { prefix ->
            invalid("subscription keys ($prefix...) can only be used in the vendor's own tools; use a pay-as-you-go API key")
        }
    }

    private fun invalid(detail: String): Nothing = throw ServiceError.Api(422, "invalid", detail, null)

    override suspend fun updateCredential(credentialId: String, update: CredentialUpdate): Credential {
        lag()
        val updated = synchronized(lock) {
            val i = credentialList.indexOfFirst { it.id == credentialId }
            if (i < 0) notFound("credential", credentialId)
            val old = credentialList[i]
            old.copy(
                label = update.label ?: old.label,
                disabled = update.disabled ?: old.disabled,
            ).also { credentialList[i] = it }
        }
        // 重新启用了：等额度的运行接着跑。
        if (update.disabled == false) wakeRunsWaitingForQuota()
        return updated
    }

    /** 套餐专用地址（任何一家的 planOnlyBases）：去掉首尾空白、转小写后等于它或接着是 `/`（proto::vendors::plan_only_base）。 */
    private fun planOnlyBase(base: String): String? {
        val url = base.trim().lowercase()
        return data.vendors.flatMap { it.planOnlyBases }.firstOrNull { prefix ->
            url.startsWith(prefix) && (url.length == prefix.length || url[prefix.length] == '/')
        }
    }

    override suspend fun setCredentialDailyLimit(credentialId: String, dailyTokenLimit: Long?): Credential {
        lag()
        if (dailyTokenLimit != null && dailyTokenLimit <= 0) invalid("daily_token_limit must be positive")
        val (changed, raised) = synchronized(lock) {
            val i = credentialList.indexOfFirst { it.id == credentialId }
            if (i < 0) notFound("credential", credentialId)
            val old = credentialList[i].dailyTokenLimit
            // 放宽或取消上限才唤醒；原来就不限的、收紧的不唤醒（和服务端一样）。
            val raised = old != null && (dailyTokenLimit == null || dailyTokenLimit > old)
            credentialList[i].copy(dailyTokenLimit = dailyTokenLimit).also { credentialList[i] = it } to raised
        }
        if (raised) wakeRunsWaitingForQuota()
        return changed
    }

    override suspend fun replaceCredentialSecret(credentialId: String, apiKey: String): Credential {
        lag()
        val vendor = synchronized(lock) { credentialList.firstOrNull { it.id == credentialId }?.vendor }
            ?: notFound("credential", credentialId)
        checkKey(vendor, apiKey)
        val replaced = synchronized(lock) {
            val i = credentialList.indexOfFirst { it.id == credentialId }
            if (i < 0) notFound("credential", credentialId)
            credentialList[i].copy(last4 = apiKey.takeLast(4)).also { credentialList[i] = it }
        }
        wakeRunsWaitingForQuota()
        return replaced
    }

    /** 和服务端一样：还有没删除的实例的别名（主 key 或降级链）在用就拒绝（409），先改路由。 */
    override suspend fun deleteCredential(credentialId: String) {
        lag()
        synchronized(lock) {
            if (credentialList.none { it.id == credentialId }) notFound("credential", credentialId)
            val deleted = instanceList.filter { it.state == InstanceState.Deleted }.map { it.id }.toSet()
            val used = routes.filterKeys { it !in deleted }.values.sumOf { list ->
                list.count { it.credentialId == credentialId } +
                    list.sumOf { route -> route.fallbacks.count { it.credentialId == credentialId } }
            }
            if (used > 0) throw ServiceError.Api(409, "conflict", "credential is used by $used model route(s)", null)
            credentialList.removeAll { it.id == credentialId }
        }
    }

    // ---- 内容举报 ----

    override suspend fun reportContent(
        runId: String,
        reason: ReportReason,
        eventSeq: Long?,
        artifactId: String?,
        note: String?,
    ): ContentReport {
        lag()
        if (reason == ReportReason.Unknown) throw ServiceError.Api(422, "invalid", "unknown report reason", null)
        if ((note?.length ?: 0) > MAX_REPORT_NOTE) throw ServiceError.Api(422, "invalid", "note is too long", null)
        return synchronized(lock) {
            val run = runList.firstOrNull { it.id == runId } ?: notFound("run", runId)
            // 同一条内容再举报一次：返回那一条待处理的。
            reportList.firstOrNull {
                it.runId == runId && it.eventSeq == eventSeq && it.artifactId == artifactId && it.state == ReportState.Open
            } ?: ContentReport(
                id = newId("report"), runId = runId, instanceId = run.instanceId, eventSeq = eventSeq,
                artifactId = artifactId, reason = reason, note = note, state = ReportState.Open, resolution = null,
                createdAtMs = clock(), handledAtMs = null,
            ).also { reportList.add(it) }
        }
    }

    override suspend fun reports(): List<ContentReport> {
        lag()
        return synchronized(lock) { reportList.sortedByDescending { it.createdAtMs } }
    }

    // ---- 保险箱 ----

    override fun detectSecrets(text: String): List<DetectedSecret> {
        val found = mutableListOf<DetectedSecret>()
        PRIVATE_KEY.findAll(text).forEach { m ->
            found += DetectedSecret(
                kind = "private_key", start = m.range.first, end = m.range.last + 1, value = m.value,
                suggestedName = "private_key", service = "", storable = false,
            )
        }
        LABELED.findAll(text).forEach { m ->
            val value = m.groups[2] ?: return@forEach
            if (found.any { value.range.first >= it.start && value.range.first < it.end }) return@forEach
            // 已经换成保险箱引用的不算（和 client-core 一样）。
            if (value.value.startsWith("[vault:")) return@forEach
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

    override fun uniqueVaultName(base: String, taken: List<String>): String {
        // 和 client-core 的规则一样（简化版）：小写、只留字母数字和下划线，重名加 _2、_3……
        val clean = base.lowercase().replace(Regex("[^a-z0-9_]+"), "_").trim('_').take(MAX_VAULT_NAME).ifEmpty { "secret" }
        if (clean !in taken) return clean
        return generateSequence(2) { it + 1 }
            .map { n -> val suffix = "_$n"; clean.take(MAX_VAULT_NAME - suffix.length) + suffix }
            .first { it !in taken }
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

    /** 用途、账号：长度和控制字符（服务端的 `check_text`）。 */
    private fun checkVaultText(text: String, max: Int) {
        if (VaultRules.length(text) > max) invalid("at most $max characters")
        if (VaultRules.hasControlCharacters(text)) invalid("must not contain control characters")
    }

    private fun checkVaultPassword(password: String) {
        if (VaultRules.passwordProblem(password) != null) {
            invalid("password must be ${VaultRules.MIN_PASSWORD} characters to ${VaultRules.MAX_PASSWORD_BYTES} bytes")
        }
    }

    /** 和服务端一样的顺序：名字、用途、账号、密码、实例数，再看条数上限，最后才是重名。调用方持有 [lock]。 */
    private fun createVaultItemLocked(item: NewVaultItem): VaultItem {
        if (!VaultRules.isValidName(item.name)) invalid("bad vault name ${item.name}")
        checkVaultText(item.purpose, VaultRules.MAX_PURPOSE)
        checkVaultText(item.username, VaultRules.MAX_USERNAME)
        checkVaultPassword(item.password)
        if (item.instanceIds.size > VaultRules.MAX_INSTANCES) invalid("at most ${VaultRules.MAX_INSTANCES} instance_ids")
        if (vaultList.size >= VaultRules.MAX_ITEMS) invalid("the vault holds at most ${VaultRules.MAX_ITEMS} items")
        if (vaultList.any { it.name == item.name }) throw ServiceError.Api(409, "conflict", "name taken", null)
        val now = clock()
        val created = VaultItem(
            id = "vault-demo-${++idCounter}", name = item.name, purpose = item.purpose.trim(),
            hasUsername = item.username.isNotEmpty(), instanceIds = item.instanceIds.distinct().sorted(), createdAtMs = now,
            updatedAtMs = now, lastUsedAtMs = null,
        )
        vaultList.add(created)
        vaultUsernames[created.id] = item.username
        return created
    }

    override suspend fun createVaultItem(item: NewVaultItem): VaultItem {
        lag()
        return synchronized(lock) { createVaultItemLocked(item) }
    }

    override suspend fun updateVaultItem(itemId: String, change: VaultItemUpdate): VaultItem {
        lag()
        return synchronized(lock) {
            val i = vaultList.indexOfFirst { it.id == itemId }
            if (i < 0) notFound("vault item", itemId)
            // 先校验再改：出错时什么都不动。
            change.purpose?.let { checkVaultText(it, VaultRules.MAX_PURPOSE) }
            change.username?.let { checkVaultText(it, VaultRules.MAX_USERNAME) }
            change.password?.let { checkVaultPassword(it) }
            if ((change.instanceIds?.size ?: 0) > VaultRules.MAX_INSTANCES) invalid("at most ${VaultRules.MAX_INSTANCES} instance_ids")
            change.username?.let { vaultUsernames[itemId] = it }
            val old = vaultList[i]
            old.copy(
                purpose = change.purpose?.trim() ?: old.purpose,
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

    /** 把请求标成处理过了；已经不是等待中的报 409（服务端一样）。调用方持有 [lock]。 */
    private fun resolveRequestLocked(requestId: String, status: VaultRequestStatus, itemId: String?): VaultRequest {
        val i = vaultRequestList.indexOfFirst { it.id == requestId }
        if (i < 0) notFound("vault request", requestId)
        return vaultRequestList[i].copy(status = status, itemId = itemId, resolvedAtMs = clock())
            .also { vaultRequestList[i] = it }
    }

    private fun pendingRequestLocked(requestId: String): VaultRequest {
        val request = vaultRequestList.firstOrNull { it.id == requestId } ?: notFound("vault request", requestId)
        if (request.status != VaultRequestStatus.Pending) {
            throw ServiceError.Api(409, "conflict", "the request is already ${request.status.wire}", null)
        }
        return request
    }

    /**
     * 和服务端一样：先校验账号密码，再看请求还在等；已经有同名条目就更新它（换账号密码和用途，限定了实例的把这个实例加上），
     * 没有才新建。
     */
    override suspend fun fulfillVaultRequest(
        requestId: String,
        username: String,
        password: String,
        purpose: String?,
    ): VaultRequest {
        lag()
        val (request, resolved) = synchronized(lock) {
            checkVaultText(username, VaultRules.MAX_USERNAME)
            checkVaultPassword(password)
            purpose?.let { checkVaultText(it, VaultRules.MAX_PURPOSE) }
            val request = pendingRequestLocked(requestId)
            val j = vaultList.indexOfFirst { it.name == request.name }
            val item = if (j >= 0) {
                val old = vaultList[j]
                vaultUsernames[old.id] = username
                old.copy(
                    purpose = (purpose ?: request.purpose).trim(),
                    hasUsername = username.isNotEmpty(),
                    instanceIds = if (old.instanceIds.isEmpty() || request.instanceId in old.instanceIds) {
                        old.instanceIds
                    } else {
                        old.instanceIds + request.instanceId
                    },
                    updatedAtMs = clock(),
                ).also { vaultList[j] = it }
            } else {
                createVaultItemLocked(
                    NewVaultItem(request.name, purpose ?: request.purpose, username, password, listOf(request.instanceId)),
                )
            }
            request to resolveRequestLocked(requestId, VaultRequestStatus.Fulfilled, item.id)
        }
        append(request.instanceId, request.runId, EventKinds.VAULT_FULFILLED, buildJsonObject {
            put("request_id", requestId); put("name", request.name)
        })
        return resolved
    }

    override suspend fun declineVaultRequest(requestId: String): VaultRequest {
        lag()
        val resolved = synchronized(lock) {
            pendingRequestLocked(requestId)
            resolveRequestLocked(requestId, VaultRequestStatus.Declined, null)
        }
        append(resolved.instanceId, resolved.runId, EventKinds.VAULT_DECLINED, buildJsonObject { put("request_id", requestId) })
        return resolved
    }

    companion object {
        const val DEFAULT_EVENT_INTERVAL_MS: Long = 2_000

        /** 自定义接口的厂商 id（地址由 key 自己带）。 */
        private const val CUSTOM_VENDOR = "custom"

        /** 模型别名的格式（库里的 CHECK 约束）。 */
        private val ALIAS = Regex("^[a-z0-9][a-z0-9._-]{0,63}$")

        /** 实例数到了上限的错误码（409；数量上限的码都以 `_limit` 结尾）。 */
        const val INSTANCE_LIMIT = "instance_limit"
        private const val SCRIPT_LENGTH = 5
        private const val HOUR_MS = 60L * 60 * 1000

        private val LABELED = Regex("""(?i)(password|passwd|pwd|密码|口令|token|secret)\s*[:：=]\s*(\S{6,})""")
        private val PRIVATE_KEY = Regex("""-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----""")

        /** 保险箱条目名的最大长度（和 client-core 一样）。 */
        private const val MAX_VAULT_NAME = VaultRules.MAX_NAME
        private val API_KEY = Regex("""\b(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,})""")

        private const val DEVICE_MESSAGE_TTL_MS: Long = 10 * 60_000
        private const val MAX_ARTIFACTS = 500
        private const val MAX_TRIGGERS = 10
        private const val MAX_REPORT_NOTE = 1000
    }
}
