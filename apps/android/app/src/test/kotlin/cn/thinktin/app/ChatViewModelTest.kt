package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.chat.ChatDialog
import cn.thinktin.app.ui.chat.ChatEvent
import cn.thinktin.app.ui.chat.ChatViewModel
import cn.thinktin.app.ui.chat.DraftHandoff
import cn.thinktin.app.ui.home.HomeEvent
import cn.thinktin.app.ui.home.HomeViewModel
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalCardStatus
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.Conversation
import cn.thinktin.data.model.ConversationSection
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.HistoryGap
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.TimelineItem
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 13.5 对话页的 ViewModel：先缓存后联网、实时事件按批归并、未知运行去取、on_reset、事件流状态、翻页、
 * 发送（乐观加入、失败回填）、密码拦截（保险箱表单、重名、仍然发送、私钥、服务端拦下）、停止、等待横幅、
 * 审批、agent 的填写请求、产出物下载、定位到运行、首页转交。事件流由测试控制（[ChatService.stream]）。
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val service = ChatService()
    private val gate = FakeApprovalGate()
    private val files = TempArtifactFiles()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun chat(
        instanceId: String = "inst-coder",
        focus: String? = null,
        draft: String? = null,
    ) = ChatViewModel(service, gate, DemoTestApp.FIXED_CLOCK, instanceId, focus, files, draft)

    private val ChatViewModel.conversation: Conversation get() = uiState.value.conversation

    private fun Conversation.items(runId: String): List<TimelineItem> = block(runId)!!.items

    /** 一条待处理的审批记录（和 agent.permission_requested 事件按 runId、attempt、requestId 对上）。 */
    private fun pendingApproval(id: String, runId: String, requestId: String): Approval {
        val now = DemoTestApp.FIXED_CLOCK.millis()
        return Approval(
            id = id, runId = runId, instanceId = "inst-coder", title = "删除 build 目录",
            options = listOf(ApprovalOption("allow", "批准", OptionKind.AllowOnce), ApprovalOption("reject", "拒绝", OptionKind.RejectOnce)),
            toolCallJson = "{}", toolCall = JsonObject(emptyMap()), state = ApprovalState.Pending,
            expiresAtMs = now + 24 * 60 * 60_000L, createdAtMs = now, requestId = requestId, attempt = 1,
        )
    }

    private fun permissionRequested(requestId: String, approvalId: String?) = buildJsonObject {
        put("request_id", requestId); put("attempt", 1); put("title", "删除 build 目录")
        if (approvalId != null) put("approval_id", approvalId)
    }

    private val waitingApproval = buildJsonObject { put("state", "waiting_approval"); put("attempt", 1) }

    @Test
    fun opensFromCacheThenRefreshesAndSubscribes() = test {
        val vm = chat()
        advanceUntilIdle()
        val state = vm.uiState.value
        assertFalse(state.loading)
        assertEquals("小码", state.instance?.name)
        assertEquals(1, service.subscriptions)
        // 运行按时间排好，旧的在前；成功的运行里有拼好的回复和产出物。
        val ids = state.conversation.blocks.map { it.runId }
        assertEquals("run-live", ids.last())
        val done = state.conversation.items("run-done")
        assertTrue(done.filterIsInstance<TimelineItem.AgentText>().single().text.startsWith("README 已翻译成英文，写在"))
        assertEquals("art-readme", done.filterIsInstance<TimelineItem.Artifact>().single().artifactId)
        // 正在运行：停止按钮停它；等审批的运行出横幅。
        assertEquals("run-live", state.activeRun)
        assertEquals("run-waiting", state.conversation.attentionBlock?.runId)
        // 缓存翻到头、运行也不满一页：没有更早的了。
        assertFalse(state.hasOlder)
    }

    @Test
    fun liveEventsAreMergedInBatches() = test {
        val vm = chat()
        advanceUntilIdle()
        val seen = mutableListOf<Conversation>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { vm.uiState.collect { seen += it.conversation } }
        val before = seen.size
        repeat(20) { i ->
            service.stream.trySend(
                service.event("inst-coder", "run-live", EventKinds.AGENT_MESSAGE, buildJsonObject { put("text", "$i,") }, 1000L + i),
            )
        }
        advanceUntilIdle()
        // 20 条一次归并（不是每条一次）。
        assertTrue("rebuilt ${seen.size - before} times", seen.size - before <= 2)
        val text = vm.conversation.items("run-live").filterIsInstance<TimelineItem.AgentText>().single().text
        assertTrue(text.startsWith("我先看看登录页现有的结构，0,1,2,"))
        assertTrue(text.endsWith("19,"))
    }

    @Test
    fun eventForUnknownRunFetchesIt() = test {
        val vm = chat()
        advanceUntilIdle()
        val run = service.mock.createRun("inst-coder", "别的设备发的")
        service.stream.trySend(
            service.event("inst-coder", run.id, EventKinds.AGENT_MESSAGE, buildJsonObject { put("text", "收到") }, 2000),
        )
        advanceUntilIdle()
        val block = vm.conversation.block(run.id)!!
        assertEquals("别的设备发的", block.prompt?.text)
    }

    @Test
    fun resetClearsEventsKeepsRunsAndMarksRetention() = test {
        val vm = chat()
        advanceUntilIdle()
        val runsBefore = service.runsCalls
        service.stream.trySend(EventStreamItem.Reset(oldestSeq = 500, latestSeq = 600))
        advanceUntilIdle()
        assertEquals(runsBefore + 1, service.runsCalls)
        val done = vm.conversation.block("run-done")!!
        assertEquals(HistoryGap.Expired, done.history)
        assertEquals(listOf(TimelineItem.Prompt::class), done.items.map { it::class })
        // 补发的事件进来：有事件的运行恢复显示过程。
        service.stream.trySend(
            service.event("inst-coder", "run-live", EventKinds.AGENT_MESSAGE, buildJsonObject { put("text", "补发") }, 500),
        )
        advanceUntilIdle()
        assertEquals(HistoryGap.None, vm.conversation.block("run-live")!!.history)
        assertEquals("补发", vm.conversation.items("run-live").filterIsInstance<TimelineItem.AgentText>().single().text)
    }

    @Test
    fun streamStatusDrivesBannerAndNotFoundLeaves() = test {
        val vm = chat()
        advanceUntilIdle()
        service.stream.trySend(EventStreamItem.Status(StreamState.Reconnecting(3000)))
        advanceUntilIdle()
        assertEquals(StreamState.Reconnecting(3000), vm.uiState.value.stream)
        service.stream.trySend(EventStreamItem.Status(StreamState.Live))
        advanceUntilIdle()
        assertEquals(StreamState.Live, vm.uiState.value.stream)
        vm.events.test {
            service.stream.trySend(EventStreamItem.Status(StreamState.NotFound))
            advanceUntilIdle()
            assertEquals(ChatEvent.InstanceGone, awaitItem())
        }
        assertTrue(vm.uiState.value.notFound)
    }

    @Test
    fun subscribeFailureCanReconnect() = test {
        service.failNext("events", ServiceError.Network("down"))
        val vm = chat()
        advanceUntilIdle()
        assertTrue(vm.uiState.value.streamFailed)
        vm.subscribe()
        advanceUntilIdle()
        assertFalse(vm.uiState.value.streamFailed)
        assertEquals(2, service.subscriptions)
    }

    @Test
    fun offlineShowsCacheAndMissingInstanceLeaves() = test {
        service.failNext("instance", ServiceError.Network("down"))
        val vm = chat()
        advanceUntilIdle()
        assertTrue(vm.uiState.value.offline)
        assertTrue(vm.conversation.blocks.isNotEmpty())

        service.failNext("instance", ServiceError.Api(404, "not_found", "gone", null))
        val gone = chat()
        gone.events.test {
            advanceUntilIdle()
            assertEquals(ChatEvent.InstanceGone, awaitItem())
        }
    }

    @Test
    fun pagingLoadsOlderRuns() = test {
        service.syntheticRuns = ChatService.manyRuns("inst-coder", 60)
        service.cachedEventsOverride = emptyList()
        val vm = chat()
        advanceUntilIdle()
        assertEquals(50, vm.conversation.blocks.size)
        assertTrue(vm.uiState.value.hasOlder)
        vm.loadOlder()
        advanceUntilIdle()
        assertEquals(1, service.olderRunsCalls)
        assertEquals(60, vm.conversation.blocks.size)
        assertEquals("many-59", vm.conversation.blocks.first().runId)
        assertFalse(vm.uiState.value.hasOlder)
        // 翻完了不再联网。
        vm.loadOlder()
        advanceUntilIdle()
        assertEquals(1, service.olderRunsCalls)
    }

    @Test
    fun pagingFailureStillShowsCacheAndStops() = test {
        service.syntheticRuns = ChatService.manyRuns("inst-coder", 60)
        service.cachedEventsOverride = emptyList()
        val vm = chat()
        advanceUntilIdle()
        vm.events.test {
            service.failNext("olderRuns", ServiceError.Network("down"))
            vm.loadOlder()
            advanceUntilIdle()
            assertTrue(awaitItem() is ChatEvent.Message)
        }
        assertFalse(vm.uiState.value.loadingOlder)
        assertFalse(vm.uiState.value.hasOlder)
    }

    @Test
    fun focusRunScrollsAfterLoading() = test {
        val vm = chat(focus = "run-done")
        vm.events.test {
            advanceUntilIdle()
            assertEquals(ChatEvent.ScrollToRun("run-done"), awaitItem())
        }
    }

    @Test
    fun focusRunPagesBackUntilFound() = test {
        service.syntheticRuns = ChatService.manyRuns("inst-coder", 60)
        service.cachedEventsOverride = emptyList()
        val vm = chat(focus = "many-55")
        vm.events.test {
            advanceUntilIdle()
            assertEquals(ChatEvent.ScrollToRun("many-55"), awaitItem())
        }
        assertEquals(1, service.olderRunsCalls)
    }

    @Test
    fun sendAddsRunOptimisticallyAndClearsDraft() = test {
        val vm = chat()
        advanceUntilIdle()
        vm.events.test {
            vm.onDraftChange("  再加一个边界情况  ")
            vm.send()
            advanceUntilIdle()
            assertEquals(ChatEvent.ScrollToBottom, awaitItem())
        }
        assertEquals(listOf("再加一个边界情况" to false), service.sent)
        assertEquals("", vm.uiState.value.draft)
        val newest = vm.conversation.blocks.last { it.prompt?.text == "再加一个边界情况" }
        assertTrue(newest.prompt!!.fromUser)
        assertFalse(vm.uiState.value.sending)
    }

    @Test
    fun sendFailureRestoresDraftWithRetry() = test {
        val vm = chat()
        advanceUntilIdle()
        vm.events.test {
            service.failNext("sendMessage", ServiceError.Network("timeout"))
            vm.onDraftChange("帮我看看 CI")
            vm.send()
            advanceUntilIdle()
            val message = awaitItem() as ChatEvent.Message
            assertNotNull(message.retry)
            assertEquals("帮我看看 CI", vm.uiState.value.draft)
            message.retry!!.invoke()
            advanceUntilIdle()
            assertEquals(ChatEvent.ScrollToBottom, awaitItem())
        }
        assertEquals(2, service.sent.size)
        assertEquals("", vm.uiState.value.draft)
    }

    @Test
    fun secretOpensVaultFormAndReplacesWithReference() = test {
        val vm = chat()
        advanceUntilIdle()
        vm.onDraftChange("数据库 password: hunter2hunter2 请用它连")
        vm.send()
        advanceUntilIdle()
        val form = vm.uiState.value.secretForm!!
        assertEquals("hunter2hunter2", form.password)
        assertEquals("password", form.name)
        assertTrue(service.sent.isEmpty())
        vm.onSecretFormChange { it.copy(purpose = "连测试库", username = "app") }
        vm.events.test {
            vm.saveSecret()
            advanceUntilIdle()
            assertTrue(awaitItem() is ChatEvent.Message)
        }
        assertNull(vm.uiState.value.secretForm)
        assertEquals("数据库 password: [vault:password] 请用它连", vm.uiState.value.draft)
        val saved = service.mock.vaultItems().single { it.name == "password" }
        assertEquals(listOf("inst-coder"), saved.instanceIds)
        assertEquals("连测试库", saved.purpose)
        assertTrue(service.sent.isEmpty())
        // 换成引用后再发就不拦了。
        vm.send()
        advanceUntilIdle()
        assertEquals(listOf("数据库 password: [vault:password] 请用它连" to false), service.sent)
    }

    @Test
    fun suggestedNameAvoidsExistingItemsAndConflictPicksAnother() = test {
        val vm = chat()
        advanceUntilIdle()
        vm.onDraftChange("token: ghp_abcdefghijklmnopqrstuvwxyz")
        vm.send()
        advanceUntilIdle()
        // 用户改成已有的名字：服务端 409，提示并换一个。
        vm.onSecretFormChange { it.copy(name = "github") }
        vm.saveSecret()
        advanceUntilIdle()
        val form = vm.uiState.value.secretForm!!
        assertNotNull(form.nameError)
        assertEquals("github_2", form.name)
        assertFalse(form.saving)
    }

    @Test
    fun sendAnywayNeedsSecondConfirmation() = test {
        val vm = chat()
        advanceUntilIdle()
        vm.onDraftChange("password: hunter2hunter2")
        vm.send()
        advanceUntilIdle()
        vm.askSendAnyway()
        assertNull(vm.uiState.value.secretForm)
        assertEquals(ChatDialog.SendAnyway("password: hunter2hunter2", 1), vm.uiState.value.dialog)
        assertTrue(service.sent.isEmpty())
        vm.confirmSendAnyway()
        advanceUntilIdle()
        assertEquals(listOf("password: hunter2hunter2" to true), service.sent)
        assertNull(vm.uiState.value.dialog)
    }

    @Test
    fun privateKeyIsOnlyWarned() = test {
        val vm = chat()
        advanceUntilIdle()
        vm.onDraftChange("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----")
        vm.send()
        advanceUntilIdle()
        assertEquals(ChatDialog.PrivateKey, vm.uiState.value.dialog)
        assertNull(vm.uiState.value.secretForm)
        assertTrue(service.sent.isEmpty())
        vm.dismissDialog()
        assertNull(vm.uiState.value.dialog)
    }

    @Test
    fun serverSideContainsSecretsAsksToSendAnyway() = test {
        service.detectNothing = true
        val vm = chat()
        advanceUntilIdle()
        service.failNext("sendMessage", ServiceError.ContainsSecrets(2))
        vm.onDraftChange("看起来正常的消息")
        vm.send()
        advanceUntilIdle()
        assertEquals(ChatDialog.SendAnyway("看起来正常的消息", 2), vm.uiState.value.dialog)
        assertEquals("看起来正常的消息", vm.uiState.value.draft)
    }

    /** 根运行：连同它委派出去的子任务一起停。 */
    @Test
    fun stopCancelsActiveRunTree() = test {
        val vm = chat()
        advanceUntilIdle()
        vm.events.test {
            vm.stop()
            advanceUntilIdle()
            assertTrue(awaitItem() is ChatEvent.Message)
        }
        assertEquals(listOf("run-live" to true), service.cancelled)
        assertEquals(RunState.Cancelled, vm.conversation.block("run-live")!!.state)
        assertFalse(vm.uiState.value.stopping)
    }

    /** 委派 / 流水线步骤的子运行：停止键只停它自己，不连根停掉负责人那边（别的实例）的整棵树。 */
    @Test
    fun stopOnChildRunOnlyCancelsItself() = test {
        val child = service.mock.getRun("run-delegate").copy(state = RunState.Running, finishedAtMs = null)
        service.syntheticRuns = listOf(child)
        service.cachedEventsOverride = emptyList()
        val vm = chat(instanceId = "inst-research")
        advanceUntilIdle()
        assertEquals("run-delegate", vm.uiState.value.activeRun)
        vm.events.test {
            vm.stop()
            advanceUntilIdle()
            assertTrue(awaitItem() is ChatEvent.Message)
        }
        assertEquals(listOf("run-delegate" to false), service.cancelled)
        assertEquals(RunState.Cancelled, vm.conversation.block("run-delegate")!!.state)
        assertNull(vm.uiState.value.activeRun)
    }

    /** 打开页面之后才来的审批请求：按 approval_id 取记录（只取一次、不重拉列表），内嵌卡片才能批准 / 拒绝、有倒计时。 */
    @Test
    fun permissionRequestedAfterOpeningFetchesItsApprovalRecord() = test {
        val vm = chat()
        advanceUntilIdle()
        val listCalls = service.approvalsCalls
        val approval = pendingApproval("ap-new", "run-live", "perm-9")
        service.extraApprovals += approval
        service.stream.trySend(
            service.event("inst-coder", "run-live", EventKinds.AGENT_PERMISSION_REQUESTED, permissionRequested("perm-9", "ap-new"), 2000),
        )
        service.stream.trySend(service.event("inst-coder", "run-live", EventKinds.RUN_STATE, waitingApproval, 2001))
        advanceUntilIdle()
        val card = vm.conversation.block("run-live")!!.approvalCards.single()
        assertEquals(ApprovalCardStatus.Pending, card.status)
        assertTrue(card.canDecide)
        assertEquals(approval.expiresAtMs, card.expiresAtMs)
        assertEquals(listOf("ap-new"), service.approvalFetches)
        assertEquals(listCalls, service.approvalsCalls)
        // 横幅的“去审批”能滚到卡片，不用去审批中心。
        assertEquals(RunState.WaitingApproval, vm.conversation.attentionBlock?.state)
        vm.events.test {
            assertTrue(vm.scrollToPendingApproval())
            assertTrue(awaitItem() is ChatEvent.ScrollToItem)
        }
        // 卡片上决定走的就是这条记录。
        vm.actions.onOption(card.approval!!, card.approval!!.options.first { it.kind == OptionKind.AllowOnce })
        vm.actions.confirm()
        advanceUntilIdle()
        assertEquals(1, gate.requests.size)
    }

    /** 事件里没有 approval_id（老数据）：运行进入等审批时拉一次待处理列表，按关联键对上。 */
    @Test
    fun waitingApprovalWithoutApprovalIdFallsBackToApprovalList() = test {
        val vm = chat()
        advanceUntilIdle()
        val listCalls = service.approvalsCalls
        service.extraApprovals += pendingApproval("ap-old", "run-live", "perm-9")
        service.stream.trySend(
            service.event("inst-coder", "run-live", EventKinds.AGENT_PERMISSION_REQUESTED, permissionRequested("perm-9", null), 2000),
        )
        advanceUntilIdle()
        assertFalse(vm.conversation.block("run-live")!!.approvalCards.single().canDecide)
        assertEquals(listCalls, service.approvalsCalls)
        service.stream.trySend(service.event("inst-coder", "run-live", EventKinds.RUN_STATE, waitingApproval, 2001))
        advanceUntilIdle()
        assertEquals(listCalls + 1, service.approvalsCalls)
        assertTrue(service.approvalFetches.isEmpty())
        val card = vm.conversation.block("run-live")!!.approvalCards.single()
        assertEquals("ap-old", card.approvalId)
        assertTrue(card.canDecide)
    }

    @Test
    fun waitingBannerScrollsToPendingApprovalAndApprovingGoesThroughGate() = test {
        val vm = chat()
        advanceUntilIdle()
        val cards = vm.conversation.block("run-waiting")!!.approvalCards
        assertEquals(listOf(ApprovalCardStatus.Superseded, ApprovalCardStatus.Pending), cards.map { it.status })
        vm.events.test {
            assertTrue(vm.scrollToPendingApproval())
            assertTrue(awaitItem() is ChatEvent.ScrollToItem)
        }
        val pending = cards[1]
        val approval = pending.approval!!
        vm.actions.onOption(approval, approval.options.first { it.kind == OptionKind.AllowOnce })
        vm.actions.confirm()
        advanceUntilIdle()
        assertEquals(1, gate.requests.size)
        assertEquals(ApprovalCardStatus.Approved, vm.conversation.block("run-waiting")!!.approvalCards[1].status)
    }

    @Test
    fun vaultRequestCanBeFulfilledOrDeclined() = test {
        val vm = chat(instanceId = "inst-research")
        advanceUntilIdle()
        val cards = vm.conversation.sections.mapNotNull { (it as? ConversationSection.Loose)?.item as? TimelineItem.VaultRequestCard }
        val pending = cards.single { it.requestId == "vreq-pending" }
        assertEquals(VaultRequestStatus.Pending, pending.status)
        assertEquals("上传调研报告", pending.purpose)
        vm.openVaultForm(pending)
        assertTrue(vm.uiState.value.vaultForm!!.wantsPassword)
        // 没填密码：本地提示，不发。
        vm.submitVaultForm()
        assertNotNull(vm.uiState.value.vaultForm!!.error)
        vm.onVaultFormChange { it.copy(username = "me", password = "s3cret") }
        vm.submitVaultForm()
        advanceUntilIdle()
        assertNull(vm.uiState.value.vaultForm)
        val after = vm.conversation.sections.mapNotNull { (it as? ConversationSection.Loose)?.item as? TimelineItem.VaultRequestCard }
        assertEquals(VaultRequestStatus.Fulfilled, after.single { it.requestId == "vreq-pending" }.status)
        assertEquals(VaultRequestStatus.Fulfilled, service.mock.vaultRequests(all = true).single { it.id == "vreq-pending" }.status)
    }

    @Test
    fun artifactDownloadsToFileAndRejectsHugeOnes() = test {
        val vm = chat()
        advanceUntilIdle()
        val artifact = vm.conversation.items("run-done").filterIsInstance<TimelineItem.Artifact>().single()
        vm.events.test {
            vm.openArtifact(artifact, share = true)
            assertEquals("art-readme", vm.uiState.value.downloadingArtifactId)
            advanceUntilIdle()
            val open = awaitItem() as ChatEvent.OpenFile
            assertTrue(open.share)
            assertEquals("README.en.md", open.name)
            assertTrue(open.file.readText().startsWith("# ThinkTin"))
            assertNull(vm.uiState.value.downloadingArtifactId)

            vm.openArtifact(artifact.copy(size = ChatViewModel.MAX_ARTIFACT_BYTES + 1))
            assertTrue(awaitItem() is ChatEvent.Message)
        }
    }

    @Test
    fun homeHandsOffSecretsToChat() = test {
        val handoff = DraftHandoff()
        val home = HomeViewModel(service, DemoTestApp.FIXED_CLOCK, handoff)
        advanceUntilIdle()
        home.uiEvents.test {
            home.onDraftChange("password: hunter2hunter2")
            home.send()
            advanceUntilIdle()
            assertEquals(HomeEvent.OpenChat("inst-coder"), awaitItem())
        }
        assertTrue(service.sent.isEmpty())
        val vm = chat(draft = handoff.take("inst-coder"))
        advanceUntilIdle()
        assertEquals("hunter2hunter2", vm.uiState.value.secretForm?.password)
        assertNull(handoff.take("inst-coder"))
    }
}
