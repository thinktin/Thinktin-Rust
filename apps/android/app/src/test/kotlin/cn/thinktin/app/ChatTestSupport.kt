package cn.thinktin.app

import cn.thinktin.app.ui.chat.ArtifactFiles
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.SavedSecret
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.nio.file.Files

/**
 * 对话页的服务替身：数据来自 Mock，事件流由测试往 [stream] 里放（Mock 自己的事件流会按节奏一直吐演示事件，
 * 虚拟时间里跑不完）；记下发出的消息、停止的运行、按 id 取过的审批；[failNext] 让某个方法下一次抛错。
 * [syntheticRuns] 不为空时运行列表用它（翻页测试要 50 个以上的运行）；[extraApprovals] 是 Mock 之外的审批记录
 * （打开页面之后才来的请求）。
 */
class ChatService(
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    val stream = Channel<EventStreamItem>(Channel.UNLIMITED)
    var subscriptions = 0
        private set
    val sent = mutableListOf<Pair<String, Boolean>>()
    val cancelled = mutableListOf<Pair<String, Boolean>>()
    var runsCalls = 0
        private set
    var olderRunsCalls = 0
        private set
    var syntheticRuns: List<Run> = emptyList()
    var cachedEventsOverride: List<InstanceEvent>? = null
    val extraApprovals = mutableListOf<Approval>()
    var approvalsCalls = 0
        private set
    val approvalFetches = mutableListOf<String>()

    /** 本地识别不出来（让 sendMessage 自己抛 ContainsSecrets）。 */
    var detectNothing = false
    private val failures = mutableMapOf<String, ServiceError>()

    fun failNext(method: String, error: ServiceError) {
        synchronized(failures) { failures[method] = error }
    }

    private fun maybeFail(method: String) {
        synchronized(failures) { failures.remove(method) }?.let { throw it }
    }

    override fun events(instanceId: String): Flow<EventStreamItem> {
        subscriptions++
        maybeFail("events")
        return stream.receiveAsFlow()
    }

    override suspend fun sendMessage(instanceId: String, text: String, allowSecrets: Boolean): Run {
        sent += text to allowSecrets
        maybeFail("sendMessage")
        return mock.sendMessage(instanceId, text, allowSecrets)
    }

    override fun detectSecrets(text: String): List<DetectedSecret> = if (detectNothing) emptyList() else mock.detectSecrets(text)

    override suspend fun saveSecretFromMessage(message: String, value: String, item: NewVaultItem): SavedSecret {
        maybeFail("saveSecretFromMessage")
        return mock.saveSecretFromMessage(message, value, item)
    }

    override suspend fun cancelRun(runId: String, wholeTree: Boolean): Run {
        cancelled += runId to wholeTree
        maybeFail("cancelRun")
        if (syntheticRuns.isNotEmpty()) return syntheticRuns.first { it.id == runId }.copy(state = RunState.Cancelled)
        // 和网关一致：停整棵树时返回的是根运行（可能属于别的实例）。
        val run = mock.cancelRun(runId, wholeTree)
        return if (wholeTree && run.rootRunId != run.id) mock.getRun(run.rootRunId) else run
    }

    override suspend fun approvals(): List<Approval> {
        approvalsCalls++
        maybeFail("approvals")
        return mock.approvals() + extraApprovals.filter { it.state == ApprovalState.Pending }
    }

    override suspend fun getApproval(approvalId: String): Approval {
        approvalFetches += approvalId
        maybeFail("getApproval")
        return extraApprovals.firstOrNull { it.id == approvalId } ?: mock.getApproval(approvalId)
    }

    override suspend fun runs(instanceId: String, limit: Int): List<Run> {
        runsCalls++
        maybeFail("runs")
        if (syntheticRuns.isNotEmpty()) return syntheticRuns.take(limit)
        return mock.runs(instanceId, limit)
    }

    override suspend fun cachedRuns(instanceId: String, limit: Int): List<Run> =
        if (syntheticRuns.isNotEmpty()) syntheticRuns.take(limit) else mock.cachedRuns(instanceId, limit)

    override suspend fun olderRuns(instanceId: String, beforeRunId: String, limit: Int): List<Run> {
        olderRunsCalls++
        maybeFail("olderRuns")
        if (syntheticRuns.isEmpty()) return mock.olderRuns(instanceId, beforeRunId, limit)
        val i = syntheticRuns.indexOfFirst { it.id == beforeRunId }
        return if (i < 0) emptyList() else syntheticRuns.drop(i + 1).take(limit)
    }

    override suspend fun cachedEventsBefore(instanceId: String, beforeSeq: Long?, limit: Int): List<InstanceEvent> =
        cachedEventsOverride?.filter { beforeSeq == null || it.seq < beforeSeq }?.takeLast(limit)
            ?: mock.cachedEventsBefore(instanceId, beforeSeq, limit)

    override suspend fun instance(instanceId: String): cn.thinktin.data.model.Instance {
        maybeFail("instance")
        return mock.instance(instanceId)
    }

    override suspend fun artifactContent(artifactId: String): ByteArray {
        maybeFail("artifactContent")
        return mock.artifactContent(artifactId)
    }

    /** 一个新事件（seq 接着 Mock 里这个实例最大的往下编）。 */
    suspend fun event(instanceId: String, runId: String?, kind: String, payload: JsonObject, seq: Long): EventStreamItem.Event =
        EventStreamItem.Event(
            InstanceEvent(
                instanceId = instanceId, seq = seq, runId = runId, kind = kind, payload = payload,
                aiGenerated = kind == "agent.message", createdAtMs = DemoTestApp.FIXED_CLOCK.millis(),
            ),
        )

    companion object {
        /** [count] 个已结束的运行，新的在前（翻页测试）。 */
        fun manyRuns(instanceId: String, count: Int): List<Run> {
            val now = DemoTestApp.FIXED_CLOCK.millis()
            return List(count) { i ->
                Run(
                    id = "many-$i", kind = RunKind.Agent, instanceId = instanceId, planId = null, parentRunId = null,
                    rootRunId = "many-$i", stepKey = null, source = RunSource.User, prompt = "第 $i 个", state = RunState.Succeeded,
                    stateReason = null, attempt = 1, tokensUsed = 1, summary = null, error = null,
                    createdAtMs = now - i * 60_000L, startedAtMs = now - i * 60_000L, finishedAtMs = now - i * 60_000L + 1000,
                )
            }
        }
    }
}

/** 产出物存到临时目录（测试里不碰 App 的缓存目录）。 */
class TempArtifactFiles : ArtifactFiles {
    val dir: File = Files.createTempDirectory("artifacts").toFile()

    override suspend fun save(artifactId: String, name: String, bytes: ByteArray): File =
        File(dir, "$artifactId-$name").apply { writeBytes(bytes) }
}
