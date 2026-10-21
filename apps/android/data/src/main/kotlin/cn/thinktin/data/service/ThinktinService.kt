package cn.thinktin.data.service

import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.Device
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxPage
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.LoginResult
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanUpdate
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.SavedSecret
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.SignOutOthersResult
import cn.thinktin.data.model.StopAllResult
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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** 登录状态。 */
enum class AuthState {
    SignedIn,
    SignedOut,

    /** 账号被冻结：登录状态保留，界面显示冻结说明页。 */
    Frozen,
}

/**
 * App 访问 ThinkTin 平台的唯一入口（13.1–13.8 用到的全部操作）。
 *
 * - 真实实现 [cn.thinktin.data.core.CoreThinktinService] 经 client-core（UniFFI）调服务端；
 * - 演示实现 [cn.thinktin.data.mock.MockThinktinService] 用确定性的假数据。
 *
 * 所有方法失败时抛 [ServiceError]。`cached*` 只读本地缓存，不联网、不挂起（缓存不可用时返回空）。
 * 标注“client-core 还没有”的方法：服务端已有接口，真实实现暂时抛 [ServiceError.Unsupported]。
 */
interface ThinktinService {
    /** 是演示数据（不联网）。 */
    val isDemo: Boolean

    /** 登录状态；登录、退出、收到 SignedOut / AccountFrozen 时更新。 */
    val authState: StateFlow<AuthState>

    // ---- 登录与账号（13.2、13.13） ----

    suspend fun sendCode(phone: String)

    suspend fun login(phone: String, code: String, pushChannel: String? = null, pushToken: String? = null): LoginResult

    suspend fun logout()

    suspend fun me(): User

    /** zh-CN / en */
    suspend fun setLocale(locale: String): User

    /** [channel]：jpush / fcm。 */
    suspend fun setPushToken(channel: String, token: String)

    suspend fun stopAll(): StopAllResult

    suspend fun signOutOtherDevices(stopAgents: Boolean): SignOutOthersResult

    /** 设备列表（client-core 还没有）。 */
    suspend fun devices(): List<Device>

    /** 远程下线一台设备（client-core 还没有）。 */
    suspend fun signOutDevice(deviceId: String)

    /** 给本人手机号发注销验证码（client-core 还没有）。 */
    suspend fun sendAccountCode()

    /** 注销账号（client-core 还没有）。 */
    suspend fun deleteAccount(code: String)

    // ---- 目录与实例（13.3） ----

    suspend fun agents(): List<AgentInfo>

    suspend fun instances(): List<Instance>

    fun cachedInstances(): List<Instance>

    suspend fun adopt(agentId: String, name: String, harness: String? = null): Instance

    suspend fun renameInstance(instanceId: String, name: String): Instance

    /** [version] 为 null 表示跟随最新版。 */
    suspend fun setInstanceVersion(instanceId: String, version: String?): Instance

    suspend fun deleteInstance(instanceId: String)

    suspend fun modelRoutes(instanceId: String): List<ModelRoute>

    suspend fun setModelRoutes(instanceId: String, routes: List<ModelRoute>)

    // ---- 运行（13.5、13.7） ----

    suspend fun createRun(instanceId: String, prompt: String): Run

    /** [allowSecrets] 为假且消息里有像密码的内容时抛 [ServiceError.ContainsSecrets]。 */
    suspend fun sendMessage(instanceId: String, text: String, allowSecrets: Boolean = false): Run

    /** 最近的运行，新的在前。 */
    suspend fun runs(instanceId: String, limit: Int = DEFAULT_PAGE): List<Run>

    /** 更早的运行（分页，client-core 还没有）。 */
    suspend fun olderRuns(instanceId: String, beforeRunId: String, limit: Int = DEFAULT_PAGE): List<Run>

    fun cachedRuns(instanceId: String, limit: Int = DEFAULT_PAGE): List<Run>

    suspend fun getRun(runId: String): Run

    suspend fun cancelRun(runId: String, wholeTree: Boolean = false): Run

    /** 一棵运行树（根在前）。 */
    suspend fun runTree(runId: String): List<Run>

    suspend fun runArtifacts(runId: String): List<Artifact>

    suspend fun artifactContent(artifactId: String): ByteArray

    /** 实例的全部产出物（client-core 还没有）。 */
    suspend fun instanceArtifacts(instanceId: String): List<Artifact>

    /** 删除产出物（client-core 还没有）。 */
    suspend fun deleteArtifact(artifactId: String)

    // ---- 事件（13.5） ----

    /**
     * 订阅实例的事件流。冷流：收集时订阅，取消收集时停止。事件在收集方的协程里交付。
     */
    fun events(instanceId: String): Flow<EventStreamItem>

    /** 本地缓存的事件（seq 大于 [afterSeq]，按 seq 升序）。 */
    fun cachedEvents(instanceId: String, afterSeq: Long = 0, limit: Int = DEFAULT_EVENTS): List<InstanceEvent>

    // ---- 审批（13.5） ----

    suspend fun approvals(): List<Approval>

    suspend fun decideApproval(approvalId: String, optionId: String): Approval

    // ---- 计划（13.6） ----

    suspend fun plans(instanceId: String? = null): List<Plan>

    suspend fun getPlan(planId: String): Plan

    suspend fun createPlan(plan: NewPlan): Plan

    /** 修改计划（client-core 还没有）。 */
    suspend fun updatePlan(planId: String, update: PlanUpdate): Plan

    suspend fun setPlanPaused(planId: String, paused: Boolean): Plan

    suspend fun confirmPlan(planId: String, revision: Int): Plan

    suspend fun deletePlan(planId: String)

    /** 给计划加触发器（client-core 还没有）。 */
    suspend fun addTrigger(planId: String, schedule: Schedule): Trigger

    /** 删除触发器（client-core 还没有）。 */
    suspend fun deleteTrigger(triggerId: String)

    // ---- 团队与流水线（13.7，client-core 还没有） ----

    suspend fun teams(): List<Team>

    suspend fun createTeam(name: String, members: List<TeamMember>): Team

    suspend fun updateTeam(teamId: String, name: String? = null, members: List<TeamMember>? = null): Team

    suspend fun deleteTeam(teamId: String)

    suspend fun teamTemplates(): List<TeamTemplate>

    suspend fun saveTeamAsTemplate(teamId: String, name: String): TeamTemplate

    suspend fun deleteTeamTemplate(templateId: String)

    suspend fun adoptTeamTemplate(templateId: String): Team

    // ---- 收件箱（13.8） ----

    suspend fun syncInbox(limit: Int = DEFAULT_PAGE): InboxPage

    suspend fun olderInbox(beforeId: String, limit: Int = DEFAULT_PAGE): List<InboxItem>

    fun cachedInbox(beforeId: String? = null, limit: Int = DEFAULT_PAGE): List<InboxItem>

    fun cachedUnread(): Long

    /** 标为已读：[ids] 里的，或 [upToId] 及更早的全部。返回剩余未读数。 */
    suspend fun markInboxRead(ids: List<String>, upToId: String? = null): Long

    /** 标为未读（client-core 还没有）。 */
    suspend fun markInboxUnread(itemId: String)

    /** 删除一条（client-core 还没有）。 */
    suspend fun deleteInboxItem(itemId: String)

    // ---- 模型 key 与用量（13.4） ----

    suspend fun usage(group: UsageGroup, fromMs: Long? = null, toMs: Long? = null, tz: String? = null): UsageSummary

    suspend fun vendors(): List<VendorInfo>

    suspend fun credentials(): List<Credential>

    suspend fun addCredential(credential: NewCredential): Credential

    /** 修改标签、限额、启用状态（client-core 还没有）。 */
    suspend fun updateCredential(credentialId: String, update: CredentialUpdate): Credential

    suspend fun deleteCredential(credentialId: String)

    // ---- 密码保险箱（13.5、13.14） ----

    /** 发送前检查消息里有没有像密码的内容（不联网）。 */
    fun detectSecrets(text: String): List<DetectedSecret>

    suspend fun saveSecretFromMessage(message: String, value: String, item: NewVaultItem): SavedSecret

    suspend fun vaultItems(): List<VaultItem>

    suspend fun vaultItem(itemId: String): VaultItemDetail

    suspend fun createVaultItem(item: NewVaultItem): VaultItem

    suspend fun updateVaultItem(itemId: String, change: VaultItemUpdate): VaultItem

    suspend fun deleteVaultItem(itemId: String)

    /** [all] 为假时只返回待处理的。 */
    suspend fun vaultRequests(all: Boolean = false): List<VaultRequest>

    suspend fun fulfillVaultRequest(requestId: String, username: String, password: String, purpose: String? = null): VaultRequest

    suspend fun declineVaultRequest(requestId: String): VaultRequest

    companion object {
        const val DEFAULT_PAGE: Int = 50
        const val DEFAULT_EVENTS: Int = 500
    }
}

/** 当前是否已登录（冻结也算登录：登录状态保留）。 */
val ThinktinService.signedIn: Boolean get() = authState.value != AuthState.SignedOut
