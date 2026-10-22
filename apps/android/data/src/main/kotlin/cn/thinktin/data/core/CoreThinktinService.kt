package cn.thinktin.data.core

import cn.thinktin.core.ClientException
import cn.thinktin.core.EventListener
import cn.thinktin.core.StreamStatus
import cn.thinktin.core.ThinktinClientInterface
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.Device
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.ImChannel
import cn.thinktin.data.model.ImChannelUpdate
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxPage
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.LoginResult
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.NewImChannel
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanUpdate
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.SavedSecret
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.SignOutOthersResult
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamTemplate
import cn.thinktin.data.model.Trigger
import cn.thinktin.data.model.UsageGroup
import cn.thinktin.data.model.UsageSummary
import cn.thinktin.data.model.User
import cn.thinktin.data.model.VaultItem
import cn.thinktin.data.model.VaultItemDetail
import cn.thinktin.data.model.VaultItemUpdate
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.data.model.isTerminal
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.data.service.toServiceError
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.withContext
import cn.thinktin.core.InstanceEvent as CoreInstanceEvent
import cn.thinktin.core.detectSecrets as coreDetectSecrets

/**
 * ThinktinService 的真实实现：把 client-core（UniFFI 生成的 [ThinktinClientInterface]）适配成 App 模型。
 * 只在本模块里构造（[ClientFactory.createService]）；参数用接口类型，测试可以传假对象。
 *
 * - ClientException → [ServiceError]；SignedOut / AccountFrozen 同时更新 [authState]。
 * - 其他异常（Rust panic 变成的 InternalException、JNA 的错误……）也包成 [ServiceError.Other]，不冲出 ViewModel。
 * - `cached*` 是同步的 JNA + SQLite 调用，切到 [io] 上执行，不占主线程。
 * - client-core 还没有的操作抛 [ServiceError.Unsupported]。
 */
internal class CoreThinktinService(
    private val client: ThinktinClientInterface,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ThinktinService {

    override val isDemo: Boolean = false

    // 惰性：第一次用到时才问 client-core（测试里的假对象不必实现 signedIn）。读不出来按未登录。
    private val auth: MutableStateFlow<AuthState> by lazy {
        val signedIn = try {
            client.signedIn()
        } catch (_: Exception) {
            false
        }
        MutableStateFlow(if (signedIn) AuthState.SignedIn else AuthState.SignedOut)
    }

    override val authState: StateFlow<AuthState> get() = auth.asStateFlow()

    /** 调 client-core，把异常换成 ServiceError，并据此更新登录状态。取消照常抛出。 */
    private inline fun <T> call(block: () -> T): T =
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: ServiceError) {
            throw e
        } catch (e: ClientException) {
            throw onError(e.toServiceError())
        } catch (e: Exception) {
            // InternalException（Rust 里 panic、回调抛异常）、JNA 的 RuntimeException 等。
            throw ServiceError.Other(e::class.java.simpleName, e.message.orEmpty(), e)
        }

    private fun onError(error: ServiceError): ServiceError {
        when (error) {
            is ServiceError.SignedOut -> auth.value = AuthState.SignedOut
            is ServiceError.AccountFrozen -> auth.value = AuthState.Frozen
            else -> Unit
        }
        return error
    }

    /** 缓存读（同步 JNA + SQLite）放到 IO 线程；失败不打断界面：返回 [fallback]。 */
    private suspend fun <T> cached(fallback: T, block: () -> T): T =
        try {
            withContext(io) { block() }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            fallback
        }

    private fun unsupported(operation: String): Nothing = throw ServiceError.Unsupported(operation)

    // ---- 登录与账号 ----

    override suspend fun sendCode(phone: String) = call { client.sendCode(phone) }

    override suspend fun login(phone: String, code: String, pushChannel: String?, pushToken: String?): LoginResult =
        call { client.login(phone, code, pushChannel, pushToken).toModel() }.also { auth.value = AuthState.SignedIn }

    override suspend fun logout() {
        try {
            call { client.logout() }
        } finally {
            auth.value = AuthState.SignedOut
        }
    }

    override suspend fun me(): User = call { client.me().toModel() }

    override suspend fun setLocale(locale: String): User = call { client.setLocale(locale).toModel() }

    override suspend fun setPushToken(channel: String, token: String) = call { client.setPushToken(channel, token) }

    override suspend fun stopAll(): StopAllResult = call { client.stopAll().toModel() }

    override suspend fun signOutOtherDevices(stopAgents: Boolean): SignOutOthersResult =
        call { client.signOutOtherDevices(stopAgents).toModel() }

    override suspend fun devices(): List<Device> = unsupported("devices")

    override suspend fun signOutDevice(deviceId: String) = unsupported("signOutDevice")

    override suspend fun sendAccountCode() = unsupported("sendAccountCode")

    override suspend fun deleteAccount(code: String) = unsupported("deleteAccount")

    // ---- 目录与实例 ----

    override suspend fun agents(): List<AgentInfo> = call { client.agents().map { it.toModel() } }

    override suspend fun instances(): List<Instance> = call { client.instances().map { it.toModel() } }

    override suspend fun cachedInstances(): List<Instance> = cached(emptyList()) { client.cachedInstances().map { it.toModel() } }

    override suspend fun adopt(agentId: String, name: String, harness: String?): Instance =
        call { client.adopt(agentId, name, harness).toModel() }

    override suspend fun renameInstance(instanceId: String, name: String): Instance =
        call { client.renameInstance(instanceId, name).toModel() }

    override suspend fun setInstanceVersion(instanceId: String, version: String?): Instance =
        call { client.setInstanceVersion(instanceId, version).toModel() }

    override suspend fun deleteInstance(instanceId: String) = call { client.deleteInstance(instanceId) }

    override suspend fun modelRoutes(instanceId: String): List<ModelRoute> =
        call { client.modelRoutes(instanceId).map { it.toModel() } }

    override suspend fun setModelRoutes(instanceId: String, routes: List<ModelRoute>) =
        call { client.setModelRoutes(instanceId, routes.map { it.toCore() }) }

    // ---- 运行 ----

    override suspend fun createRun(instanceId: String, prompt: String): Run =
        call { client.createRun(instanceId, prompt).toModel() }

    override suspend fun sendMessage(instanceId: String, text: String, allowSecrets: Boolean): Run =
        call { client.sendMessage(instanceId, text, allowSecrets).toModel() }

    override suspend fun runs(instanceId: String, limit: Int): List<Run> =
        call { client.runs(instanceId, limit.toUIntNonNegative()).map { it.toModel() } }

    override suspend fun olderRuns(instanceId: String, beforeRunId: String, limit: Int): List<Run> =
        unsupported("olderRuns")

    override suspend fun cachedRuns(instanceId: String, limit: Int): List<Run> =
        cached(emptyList()) { client.cachedRuns(instanceId, limit.toUIntNonNegative()).map { it.toModel() } }

    override suspend fun getRun(runId: String): Run = call { client.getRun(runId).toModel() }

    override suspend fun cancelRun(runId: String, wholeTree: Boolean): Run =
        call { client.cancelRun(runId, wholeTree).toModel() }

    override suspend fun runTree(runId: String): List<Run> = call { client.runTree(runId).map { it.toModel() } }

    override suspend fun runArtifacts(runId: String): List<Artifact> =
        call { client.runArtifacts(runId).map { it.toModel() } }

    override suspend fun artifactContent(artifactId: String): ByteArray = call { client.artifactContent(artifactId) }

    override suspend fun instanceArtifacts(instanceId: String): List<Artifact> = unsupported("instanceArtifacts")

    override suspend fun deleteArtifact(artifactId: String) = unsupported("deleteArtifact")

    // ---- 事件 ----

    override fun events(instanceId: String): Flow<EventStreamItem> = callbackFlow {
        // 回调在 client-core 的后台线程上：只往通道里放，收集方在自己的协程（通常是主线程）里处理。
        val listener = object : EventListener {
            override fun onEvent(event: CoreInstanceEvent) {
                trySend(EventStreamItem.Event(event.toModel()))
            }

            override fun onReset(oldestSeq: ULong, latestSeq: ULong?) {
                trySend(EventStreamItem.Reset(oldestSeq.toLongClamped(), latestSeq?.toLongClamped()))
            }

            override fun onStatus(status: StreamStatus) {
                val state = status.toModel()
                when (state) {
                    StreamState.SignedOut -> auth.value = AuthState.SignedOut
                    StreamState.AccountFrozen -> auth.value = AuthState.Frozen
                    else -> Unit
                }
                trySend(EventStreamItem.Status(state))
                // 终止状态之后不会再有事件：结束流（和 Mock 一致，见 ThinktinService.events 的说明）。
                if (state.isTerminal) channel.close()
            }
        }
        val subscription = call { client.subscribe(instanceId, listener) }
        awaitClose {
            // stop 让 client-core 停掉后台任务；close 立即释放原生句柄（不等 Cleaner）。
            try {
                subscription.stop()
            } finally {
                subscription.close()
            }
        }
    }.buffer(Channel.UNLIMITED)

    override suspend fun cachedEvents(instanceId: String, afterSeq: Long, limit: Int): List<InstanceEvent> =
        cached(emptyList()) {
            client.cachedEvents(instanceId, afterSeq.toULongNonNegative(), limit.toUIntNonNegative()).map { it.toModel() }
        }

    // ---- 审批 ----

    override suspend fun approvals(): List<Approval> = call { client.approvals().map { it.toModel() } }

    override suspend fun decideApproval(approvalId: String, optionId: String): Approval =
        call { client.decideApproval(approvalId, optionId).toModel() }

    // ---- 计划 ----

    override suspend fun plans(instanceId: String?): List<Plan> = call { client.plans(instanceId).map { it.toModel() } }

    override suspend fun getPlan(planId: String): Plan = call { client.getPlan(planId).toModel() }

    override suspend fun createPlan(plan: NewPlan): Plan = call { client.createPlan(plan.toCore()).toModel() }

    override suspend fun updatePlan(planId: String, update: PlanUpdate): Plan = unsupported("updatePlan")

    override suspend fun setPlanPaused(planId: String, paused: Boolean): Plan =
        call { client.setPlanPaused(planId, paused).toModel() }

    override suspend fun confirmPlan(planId: String, revision: Int): Plan =
        call { client.confirmPlan(planId, revision.toUIntNonNegative()).toModel() }

    override suspend fun deletePlan(planId: String) = call { client.deletePlan(planId) }

    override suspend fun addTrigger(planId: String, schedule: Schedule): Trigger = unsupported("addTrigger")

    override suspend fun deleteTrigger(triggerId: String) = unsupported("deleteTrigger")

    // ---- 团队 ----

    override suspend fun teams(): List<Team> = unsupported("teams")

    override suspend fun createTeam(name: String, members: List<TeamMember>): Team = unsupported("createTeam")

    override suspend fun updateTeam(teamId: String, name: String?, members: List<TeamMember>?): Team =
        unsupported("updateTeam")

    override suspend fun deleteTeam(teamId: String) = unsupported("deleteTeam")

    override suspend fun teamTemplates(): List<TeamTemplate> = unsupported("teamTemplates")

    override suspend fun saveTeamAsTemplate(teamId: String, name: String): TeamTemplate =
        unsupported("saveTeamAsTemplate")

    override suspend fun deleteTeamTemplate(templateId: String) = unsupported("deleteTeamTemplate")

    override suspend fun adoptTeamTemplate(templateId: String): Team = unsupported("adoptTeamTemplate")

    // ---- 收件箱 ----

    override suspend fun syncInbox(limit: Int): InboxPage = call { client.syncInbox(limit.toUIntNonNegative()).toModel() }

    override suspend fun olderInbox(beforeId: String, limit: Int): List<InboxItem> =
        call { client.olderInbox(beforeId, limit.toUIntNonNegative()).map { it.toModel() } }

    override suspend fun cachedInbox(beforeId: String?, limit: Int): List<InboxItem> =
        cached(emptyList()) { client.cachedInbox(beforeId, limit.toUIntNonNegative()).map { it.toModel() } }

    override suspend fun cachedUnread(): Long = cached(0L) { client.cachedUnread() }

    override suspend fun markInboxRead(ids: List<String>, upToId: String?): Long =
        call { client.markInboxRead(ids, upToId) }

    override suspend fun markInboxUnread(itemId: String) = unsupported("markInboxUnread")

    override suspend fun deleteInboxItem(itemId: String) = unsupported("deleteInboxItem")

    // ---- IM 渠道 ----

    override suspend fun imChannels(): List<ImChannel> = call { client.imChannels().map { it.toModel() } }

    override suspend fun addImChannel(channel: NewImChannel): ImChannel =
        call { client.addImChannel(channel.toCore()).toModel() }

    override suspend fun updateImChannel(channelId: String, update: ImChannelUpdate): ImChannel =
        call { client.updateImChannel(channelId, update.label, update.events, update.enabled).toModel() }

    override suspend fun deleteImChannel(channelId: String) = call { client.deleteImChannel(channelId) }

    override suspend fun testImChannel(channelId: String) = call { client.testImChannel(channelId) }

    override suspend fun replaceImWebhook(channelId: String, webhookUrl: String, secret: String?): ImChannel =
        call { client.replaceImWebhook(channelId, webhookUrl, secret).toModel() }

    // ---- key 与用量 ----

    override suspend fun usage(group: UsageGroup, fromMs: Long?, toMs: Long?, tz: String?): UsageSummary =
        call { client.usage(group.wire, fromMs, toMs, tz).toModel() }

    override suspend fun vendors(): List<VendorInfo> = call { client.vendors().map { it.toModel() } }

    override suspend fun credentials(): List<Credential> = call { client.credentials().map { it.toModel() } }

    override suspend fun addCredential(credential: NewCredential): Credential =
        call { client.addCredential(credential.toCore()).toModel() }

    override suspend fun updateCredential(credentialId: String, update: CredentialUpdate): Credential =
        unsupported("updateCredential")

    override suspend fun deleteCredential(credentialId: String) = call { client.deleteCredential(credentialId) }

    // ---- 保险箱 ----

    override fun detectSecrets(text: String): List<DetectedSecret> = call { coreDetectSecrets(text).map { it.toModel() } }

    override suspend fun saveSecretFromMessage(message: String, value: String, item: NewVaultItem): SavedSecret =
        call { client.saveSecretFromMessage(message, value, item.toCore()).toModel() }

    override suspend fun vaultItems(): List<VaultItem> = call { client.vaultItems().map { it.toModel() } }

    override suspend fun vaultItem(itemId: String): VaultItemDetail = call { client.vaultItem(itemId).toModel() }

    override suspend fun createVaultItem(item: NewVaultItem): VaultItem =
        call { client.createVaultItem(item.toCore()).toModel() }

    override suspend fun updateVaultItem(itemId: String, change: VaultItemUpdate): VaultItem =
        call { client.updateVaultItem(itemId, change.toCore()).toModel() }

    override suspend fun deleteVaultItem(itemId: String) = call { client.deleteVaultItem(itemId) }

    override suspend fun vaultRequests(all: Boolean): List<VaultRequest> =
        call { client.vaultRequests(all).map { it.toModel() } }

    override suspend fun fulfillVaultRequest(
        requestId: String,
        username: String,
        password: String,
        purpose: String?,
    ): VaultRequest = call { client.fulfillVaultRequest(requestId, username, password, purpose).toModel() }

    override suspend fun declineVaultRequest(requestId: String): VaultRequest =
        call { client.declineVaultRequest(requestId).toModel() }
}
