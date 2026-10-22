package cn.thinktin.data.service

import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.ContentReport
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.DeviceInfo
import cn.thinktin.data.model.DeviceMessage
import cn.thinktin.data.model.DeviceMessageKind
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
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.ReportReason
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunFilter
import cn.thinktin.data.model.SavedSecret
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.SignOutOthersResult
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamTemplate
import cn.thinktin.data.model.TemplateMember
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
 * 所有方法失败时抛 [ServiceError]（不会抛别的异常；取消照常抛 CancellationException）。
 * `cached*` 只读本地缓存、不联网，缓存不可用时返回空；它们是挂起函数，真实实现在 IO 线程上读 SQLite，
 * 调用方不必自己切线程。
 * client-core 只给 iOS 用的实时活动（registerLiveActivity 等）不在这里。
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

    /** 改昵称；传 null 清掉。 */
    suspend fun updateProfile(displayName: String?): User

    /**
     * [channel] 是服务端的推送通道：apns、fcm、hms、honor、mi、oppo、vivo、unipush（极光、个推这类统一推送走 unipush）。
     * 不认识的通道 client-core 报参数错误。
     */
    suspend fun setPushToken(channel: String, token: String)

    suspend fun stopAll(): StopAllResult

    suspend fun signOutOtherDevices(stopAgents: Boolean): SignOutOthersResult

    /** 登录着的设备，最近活跃的在前。 */
    suspend fun devices(): List<DeviceInfo>

    /**
     * 吊销一台设备：它的登录会话立即失效。吊销的是当前这台（[DeviceInfo.current]）时等于退出登录：
     * 本地登录状态马上清掉，[authState] 变成未登录，界面回登录页。
     */
    suspend fun revokeDevice(deviceId: String)

    /** 给本人手机号发验证码（注销账号、换手机号前确认）。 */
    suspend fun sendSelfCode(purpose: SelfCodePurpose)

    /**
     * 注销账号（16.4）：用 `sendSelfCode(DeleteAccount)` 发来的验证码确认。内容全部删除、不能恢复；
     * 成功后本地登录状态和缓存一起清掉，[authState] 变成未登录。
     */
    suspend fun deleteAccount(code: String)

    /**
     * App 里切换了语言、或系统语言变了：之后的请求带新的 `Accept-Language`（不联网）。
     * [languageTags] 按偏好排好的 BCP 47 标签（见 [cn.thinktin.data.core.AcceptLanguage.tags]）；空列表表示不带。
     */
    fun setAcceptLanguage(languageTags: List<String>)

    /**
     * 服务端说过这个版本太老（某个请求抛过 [ServiceError.UpgradeRequired]，或事件流握手被拒）。之后事件流以
     * `Stopped` 结束、不再重连；界面进升级页。一直有效（升级就是重装）。
     */
    fun upgradeRequired(): Boolean

    // ---- 手机和电脑之间的消息（14.1，13.9） ----

    /** 发给自己的另一台设备；[bodyJson] 是消息内容的 JSON。电脑不在线时排队，上线后投递。 */
    suspend fun sendDeviceMessage(toDeviceId: String, kind: DeviceMessageKind, bodyJson: String): DeviceMessage

    /** 别的设备发给这台、还没收下的消息，按发出的顺序。 */
    suspend fun deviceMessages(): List<DeviceMessage>

    /** 收下了这些消息（验过签、处理完），之后不再返回。返回确认的条数。 */
    suspend fun ackDeviceMessages(ids: List<String>): Long

    // ---- 目录与实例（13.3） ----

    suspend fun agents(): List<AgentInfo>

    suspend fun instances(): List<Instance>

    /** 一个实例（深链进来、刷新详情时用）。 */
    suspend fun instance(instanceId: String): Instance

    suspend fun cachedInstances(): List<Instance>

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

    /** 更早的一页运行：[beforeRunId] 之前的（列表往下翻），新的在前。 */
    suspend fun olderRuns(instanceId: String, beforeRunId: String, limit: Int = DEFAULT_PAGE): List<Run>

    /**
     * 跨实例的运行（11.8），新的在前：某个计划的运行历史（[RunFilter.planId]）、所有没结束的运行
     * （[RunFilter.activeOnly]，抽屉里的“进行中”）。往下翻时 [beforeRunId] 传上一页最后一个的 id。
     */
    suspend fun listRuns(
        filter: RunFilter = RunFilter(),
        beforeRunId: String? = null,
        limit: Int = DEFAULT_PAGE,
    ): List<Run>

    suspend fun cachedRuns(instanceId: String, limit: Int = DEFAULT_PAGE): List<Run>

    suspend fun getRun(runId: String): Run

    suspend fun cancelRun(runId: String, wholeTree: Boolean = false): Run

    /** 一棵运行树（根在前）。 */
    suspend fun runTree(runId: String): List<Run>

    suspend fun runArtifacts(runId: String): List<Artifact>

    suspend fun artifactContent(artifactId: String): ByteArray

    /** 实例的产出物，新的在前（最多 [limit] 个，服务端上限 500）。 */
    suspend fun instanceArtifacts(instanceId: String, limit: Int = DEFAULT_PAGE): List<Artifact>

    suspend fun deleteArtifact(artifactId: String)

    // ---- 事件（13.5） ----

    /**
     * 订阅实例的事件流。冷流：收集时订阅，取消收集时停止。事件在收集方的协程里交付。
     *
     * 终止语义：收到终止状态（[cn.thinktin.data.model.StreamState.NotFound]、`SignedOut`、`AccountFrozen`、
     * `Stopped`）时先把这个状态发出来，然后流正常结束；`Connecting`、`Live`、`Reconnecting` 之后流继续。
     * 订阅本身失败时抛 [ServiceError]。
     */
    fun events(instanceId: String): Flow<EventStreamItem>

    /** 本地缓存的事件（seq 大于 [afterSeq]，按 seq 升序）。 */
    suspend fun cachedEvents(instanceId: String, afterSeq: Long = 0, limit: Int = DEFAULT_EVENTS): List<InstanceEvent>

    /**
     * 缓存里往前翻：seq 小于 [beforeSeq] 的最后 [limit] 条，按 seq 升序（旧的在前）。
     * 打开对话页时传 null 拿最后一屏先显示，往上翻时传已经显示的最小 seq。
     * 缓存里每个实例最多留 2000 条，更早的、事件流重置（Reset）丢掉的翻不到。
     */
    suspend fun cachedEventsBefore(
        instanceId: String,
        beforeSeq: Long? = null,
        limit: Int = DEFAULT_SCREEN,
    ): List<InstanceEvent>

    // ---- 审批（13.5） ----

    suspend fun approvals(): List<Approval>

    suspend fun decideApproval(approvalId: String, optionId: String): Approval

    // ---- 计划（13.6） ----

    suspend fun plans(instanceId: String? = null): List<Plan>

    suspend fun getPlan(planId: String): Plan

    suspend fun createPlan(plan: NewPlan): Plan

    /** 改计划：标题、目标、策略、补跑方式、流水线步骤，给了才改。返回改完的计划（带触发器和步骤）。 */
    suspend fun updatePlan(planId: String, change: PlanChange): Plan

    suspend fun setPlanPaused(planId: String, paused: Boolean): Plan

    suspend fun confirmPlan(planId: String, revision: Int): Plan

    suspend fun deletePlan(planId: String)

    /** 给计划加一个触发器（一个计划最多 10 个）。 */
    suspend fun addTrigger(planId: String, schedule: Schedule): Trigger

    suspend fun deleteTrigger(triggerId: String)

    // ---- 团队与流水线（13.7） ----

    suspend fun teams(): List<Team>

    suspend fun team(teamId: String): Team

    /** 把几个实例编成团队：一个负责人（[cn.thinktin.data.model.TeamRole.Lead]），其余是成员。 */
    suspend fun createTeam(name: String, members: List<TeamMember>): Team

    /** 改名、换成员（整体替换）；给了才改。 */
    suspend fun updateTeam(teamId: String, name: String? = null, members: List<TeamMember>? = null): Team

    /** 删团队（实例不删）。 */
    suspend fun deleteTeam(teamId: String)

    suspend fun teamTemplates(): List<TeamTemplate>

    /** 新建团队模板，直接给成员。 */
    suspend fun createTeamTemplate(name: String, members: List<TemplateMember>): TeamTemplate

    /** 从现有团队生成模板（每个成员记下它的 agent、接入方式、名字、角色）。 */
    suspend fun createTeamTemplateFromTeam(name: String, teamId: String): TeamTemplate

    suspend fun deleteTeamTemplate(templateId: String)

    /** 一键领养一整个团队：每个成员领养一个新实例，再编成团队。[name] 为 null 用模板的名字。 */
    suspend fun adoptTeamTemplate(templateId: String, name: String? = null): Team

    // ---- 收件箱（13.8） ----

    suspend fun syncInbox(limit: Int = DEFAULT_PAGE): InboxPage

    suspend fun olderInbox(beforeId: String, limit: Int = DEFAULT_PAGE): List<InboxItem>

    suspend fun cachedInbox(beforeId: String? = null, limit: Int = DEFAULT_PAGE): List<InboxItem>

    suspend fun cachedUnread(): Long

    /** 标为已读：[ids] 里的，或 [upToId] 及更早的全部。返回剩余未读数。 */
    suspend fun markInboxRead(ids: List<String>, upToId: String? = null): Long

    /** 一条通知（从推送点进来时用）。 */
    suspend fun inboxItem(itemId: String): InboxItem

    /** 标回未读（要联网）。返回未读数。 */
    suspend fun markInboxUnread(itemId: String): Long

    /** 删除一条（缓存跟着删）。 */
    suspend fun deleteInboxItem(itemId: String)

    // ---- IM 渠道（13.15） ----

    suspend fun imChannels(): List<ImChannel>

    suspend fun addImChannel(channel: NewImChannel): ImChannel

    suspend fun updateImChannel(channelId: String, update: ImChannelUpdate): ImChannel

    suspend fun deleteImChannel(channelId: String)

    /** 发一条测试消息到群里。 */
    suspend fun testImChannel(channelId: String)

    /** 换 webhook 地址（和签名密钥）。 */
    suspend fun replaceImWebhook(channelId: String, webhookUrl: String, secret: String? = null): ImChannel

    // ---- 模型 key 与用量（13.4） ----

    suspend fun usage(group: UsageGroup, fromMs: Long? = null, toMs: Long? = null, tz: String? = null): UsageSummary

    suspend fun vendors(): List<VendorInfo>

    suspend fun credentials(): List<Credential>

    suspend fun addCredential(credential: NewCredential): Credential

    /** 改备注、停用或重新启用一把 key；给了才改。 */
    suspend fun updateCredential(credentialId: String, update: CredentialUpdate): Credential

    /** 换 key（同一个厂商、同一条记录：模型路由不用改）。等 key 的运行会接着跑。 */
    suspend fun replaceCredentialSecret(credentialId: String, apiKey: String): Credential

    suspend fun deleteCredential(credentialId: String)

    // ---- 内容举报（5.5） ----

    /**
     * 举报 agent 的输出（长按回复或产出物）：[eventSeq] 是那条事件，[artifactId] 是产出物，都不给就是整个运行。
     * [note] 最多 1000 字。同一条内容再举报一次返回那一条待处理的举报。处理结果发到收件箱和推送。
     */
    suspend fun reportContent(
        runId: String,
        reason: ReportReason,
        eventSeq: Long? = null,
        artifactId: String? = null,
        note: String? = null,
    ): ContentReport

    /** 自己的举报和处理结果，新的在前。 */
    suspend fun reports(): List<ContentReport>

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

        /** 对话页先显示的“最后一屏”事件数。 */
        const val DEFAULT_SCREEN: Int = 100
    }
}

/** 当前是否已登录（冻结也算登录：登录状态保留）。 */
val ThinktinService.signedIn: Boolean get() = authState.value != AuthState.SignedOut

/**
 * 退出登录，服务端调用失败（断网等）也不抛：两个实现都会先清掉本地会话、把 [ThinktinService.authState] 置为未登录。
 * 取消照常抛出。
 */
suspend fun ThinktinService.logoutQuietly() {
    try {
        logout()
    } catch (_: ServiceError) {
        // 本地已经退出，服务端那边的会话会过期。
    }
}
