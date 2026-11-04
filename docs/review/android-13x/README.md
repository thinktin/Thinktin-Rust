# 安卓 13.5–13.15 评审发现（2026-10-29）

由 Android 会话（session_01T2zubC6hDr9ZZR3ihhPP5b）的评审工作流产出：13 个领域评审员对照设计规范、gateway / proto / client-core、iOS 实现找问题，报 76 条、去重 65 条；high / medium 的 25 条各由一个独立反方核实（18 成立、1 驳回、6 没跑成），40 条 low 没核实。驳回的 1 条（RunProgressTracker.kt:63，事件流以 SignedOut 结束时通知残留）已从清单里去掉。

每组的完整内容（描述、证据、建议修法、核实记录）在同目录的 `<组名>.json`，修的时候以 JSON 为准；行号是评审时（`a31080b`）的，核实记录里有纠正过的行号。

状态说明：**已核实成立**直接修；**未核实**先自己核实，成立才修；**low，未核实**先核实，确有其事且改动小才修，否则跳过并写明理由。

## A 对话与运行（13.5）

文件：`docs/review/android-13x/A-chat-run.json`，4 条。

- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/chat/ChatViewModel.kt:298` 对话页打开后新到的审批请求：内嵌审批卡的按钮全部不可点（审批记录从不重新拉取）
  - 建议修法：onEvent 收到 `agent.permission_requested`（以及 `run.state` 进入 waiting_approval）时，用 payload 里的 approval_id 调 `service.getApproval(id)`（没有 id 时拉一次 `service.approvals()` 过滤本实例），结果写进 approvals map 后 scheduleRebuild()；对已经有 approvalId 但 approval 仍为 null 的待处理卡片也在归并后补查一次（照 iOS checkApprovals 的做法，按 id 去重避免反复请求）。…
- **[high·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/chat/ChatViewModel.kt:627` 输入框的停止键对子运行（委派 / 流水线步骤）也用 wholeTree=true：连根停掉其他实例里的整棵树，且本页状态不会更新
  - 建议修法：stop() 按运行决定范围：`run.parentRunId == null`（根）时 wholeTree=true，子运行（委派 / 流水线步骤）只停自己（wholeTree=false，网关会为它单独写 run.state 事件）；若确实要提供“停整棵树”，走和运行页一样的二次确认。网关返回的运行只在 `run.instanceId == instanceId` 时写进 runs，否则对 activeRun 调一次 getRun 刷新本页区块。把 ChatTestSupport 的 cancelRun 改成和网关一致（wholeTree 返回根）以免再被掩盖。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/home/HomeScreen.kt:565` 首页“最近运行”：流水线步骤的 prompt 没有 AI 生成标识（只标了委派）
  - 建议修法：HomeScreen.RunRow 改成 `aiGenerated = run.source == RunSource.Delegate || run.source == RunSource.Pipeline`，最好抽成 :data 里 Run 的扩展属性（和 TimelineItem.Prompt.aiGenerated 共用一处规则）供三个页面调用。
- **[low·low，未核实]** `data/src/main/kotlin/cn/thinktin/data/model/Conversation.kt:423` 流式状态只靠 agent.turn_started 置位：审批通过后、或加载窗口从一轮中间开始时，文字还在流却没有“正在回复”指示
  - 建议修法：照 iOS：runState() 里 state == Running 时 inTurn = true；收到 agent.message / agent.thought / agent.tool_call(_update) / platform_tool_call 且区块未结束时把 inTurn 置 true（turn_ended 仍清掉）。ConversationBuilderTest 补“waiting_approval → running → message”和“窗口从中途开始”的用例。

## B 计划（13.6）

文件：`docs/review/android-13x/B-plans.json`，7 条。

- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/plans/PlanEditViewModel.kt:354` 保存进行中按返回 / 关闭会直接退出编辑页，删旧加新的触发器操作被协程取消，计划留成半截
  - 建议修法：`requestClose()` 在 `s.saving` 时直接 return（或只提示“正在保存”），BackHandler / 关闭按钮在保存中禁用；保存期间 ThinktinTopBar 的关闭图标 `enabled = !state.saving`。
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/plans/PlanEditViewModel.kt:426` 改触发规则时“先删后加”：服务端拒绝新规则（App 本地校验不到的写法）后旧规则已被删掉
  - 建议修法：触发器数量允许时（现有数 + 新增数 ≤ 10）先 addTrigger 再 deleteTrigger，只有会超过 10 条时才退回先删后加；或者先把所有新规则 add 完再删旧的。同时把 `FREQ=MINUTELY` 加进 `rruleProblem` 的本地拦截（服务端最小间隔 5 分钟，MINUTELY 必被拒）。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/plans/PlanTexts.kt:49` 下次 / 上次触发和运行历史用绝对日期时间，运行历史没有时长，与规范 4.6 / 第 5 节及 iOS 不一致
  - 建议修法：给 `RelativeTime` 加将来方向（分钟后 / 小时后 / 明天 HH:mm / N 天后，超过一周显示日期），列表和详情的“下次 / 上次”用它；RunRow 用相对时间 + `run.durationMs(nowMs)` 格式化的时长。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/plans/PlanDetailViewModel.kt:102` 已有内容时刷新失败没有任何提示，编辑保存后回到详情可能静默显示旧内容
  - 建议修法：已有内容时刷新失败改为发 `Message(ErrorText.of(e))` 事件走 Snackbar（可带“重试”），或在页面顶部放一条可关闭的错误横幅；列表页同样处理。
- **[low·low，未核实]** `app/src/main/res/values/strings.xml:814` “只补一次”的中文说明声称暂停期间错过的也会补跑，和服务端恢复语义相反
  - 建议修法：中文改成“平台停机期间错过了几次，回来后只补跑最近的一次（暂停期间错过的不补）”，`plan_catch_up_all_detail` 同样注明只针对停机。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/plans/PlanEditViewModel.kt:225` “用这个团队建流水线”拉不到团队时静默退化成普通新建计划
  - 建议修法：拉团队失败时把错误放进 `loadError`（404 用 team_not_found_* 文案），编辑页像编辑模式一样显示 EmptyState + 重试，重试再调 `prefillFromTeam`；至少也要发一个 snackbar 说明“没拉到团队，按普通计划新建”。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/plans/PlanEditViewModel.kt:211` 编辑时把服务端不认识的 catch_up 静默改写成 once；策略里 onApprovalTimeout 为 Unknown 时任何策略改动都存不上
  - 建议修法：`change.catchUp` 只在用户在表单里实际换过值时发（例如记录 `catchUpTouched`，或 original 为 Unknown 且表单仍是默认值时视为未改）；`PlanPolicyDraft` 遇到 Unknown 的 `onApprovalTimeout` 时在表单上标出“未知取值，需重新选择”并把它列为 PolicyProblem，而不是让 `toCore()` 抛通用错误。

## C 团队与流水线（13.7）

文件：`docs/review/android-13x/C-teams.json`，7 条。

- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/teams/TeamsScreens.kt:317` 团队详情从编辑页返回后不重新加载，显示旧的名字和成员
  - 建议修法：把“是否第一次显示”放进 TeamDetailViewModel（`private var shownOnce = false; fun onShown() { if (!shownOnce) { shownOnce = true; return }; load() }`），Screen 里改成 `LaunchedEffect(viewModel) { viewModel.onShown() }`，和 TeamsScreen / PlanDetailScreen 一致；或者在编辑页保存后通过 SavedStateHandle 通知详情页刷新。
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/teams/TeamsScreens.kt:475` 新建 / 编辑团队页加载失败时不显示错误，呈现成“空表单 / 没有实例”
  - 建议修法：TeamEditScreen 在 `state.loading` 分支之后加 `state.loadError != null -> EmptyState(title=teams_load_failed, message=error, actionLabel=action_retry, onAction=viewModel::retry)`，ViewModel 把 init 里的加载抽成 `fun load()` 供重试；编辑模式下 404 单独显示“找不到这个团队”（复用 team_not_found_*）并禁用保存。
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/plans/PipelineSteps.kt:285` 键名暂时重复时 rename / remove 按键名联动依赖，会把别的步骤的依赖改到错的步骤上
  - 建议修法：依赖改成按本地 step id 记录（StepDraft.dependsOn: List<Long>），`toStep()` 时再换成键名，rename/remove 就不需要联动；或者最小改动：rename / remove 只在旧键名在当前步骤里唯一（`steps.count { it.key.trim() == old } == 1`）时才联动依赖，重名时不动，等 DuplicateKey 提示用户改掉。补一条测试：A=fetch、B 依赖 fetch、C 从 step3 逐字符改到 fetch2，B 的依赖仍是 fetch。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/teams/TeamsViewModels.kt:128` 删除模板 / 删除团队遇到 404 当成失败，和 iOS 及本仓库其他包的约定不一致
  - 建议修法：两个 catch 里判断 `e is ServiceError.Api && (e.status == 404 || e.code == "not_found")`：模板从列表里拿掉并提示“模板已删除”；团队直接发 `TeamDetailEvent.Deleted` 退回。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/teams/TeamsScreens.kt:257` 模板成员列表硬编码中文顿号和全角括号，英文界面也显示中文标点
  - 建议修法：分隔符改用 `stringResource(R.string.list_separator)`，负责人后缀加一条带占位符的字符串（如 `team_template_member_lead`：中文“%1$s（负责人）”、英文“%1$s (Lead)”）。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/teams/TeamsViewModels.kt:249` 本地规则要求团队必须有一个负责人，服务端只限制“最多一个”
  - 建议修法：二选一并记入进度文件：(a) 认定产品上要求必有负责人，则保持现状并在 docs/progress/android-app.md 13.7 段记为有意的严于服务端；(b) 跟服务端一致，去掉 NoLead（负责人单选允许“无”），Pipeline.fromTeam 已能处理 lead == null。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/teams/TeamsScreens.kt:397` 领养后没有“逐个配置模型”清单，配没配好的成员没有标记（规范 8.6）
  - 建议修法：TeamDetailViewModel 加载时对每个成员并发调 `service.modelRoutes(instanceId)`，把“没有 main 别名”的成员记到状态里；详情页在这些成员行上用 error 色标出“未配模型”，并只在存在未配成员时显示那句提示（领养成功后进详情自然就是这个清单）。

## D 推送 / 收件箱 / 电脑配对（13.8、13.9）

文件：`docs/review/android-13x/D-push-computer.json`，11 条。

- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/push/PushMessage.kt:39` 电脑审批（computer_approval）的推送和收件箱条目跳不到能处理它的审批中心
  - 建议修法：`PushMessage.deepLink()` 的 `ComputerApproval` 分支改成 `approvalId?.let { link("approval", it) } ?: Uri.parse(DeepLinks.APPROVALS)`（`thinktin://approvals` 两端都认、清单和 NavHost 已经注册）；`InboxItem.targetRoute()` 的 `ComputerApproval` 改成 `approvalId?.let(Routes::approval) ?: Routes.APPROVALS`；更新 PushTest.deepLink…
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/navigation/InboxTargets.kt:20` 电脑审批的推送和收件箱条目不通向审批中心：点推送只到收件箱，点收件箱条目没有任何跳转
  - 建议修法：`InboxTargets.targetRoute()` 的 `ComputerApproval` 改为 `Routes.APPROVALS`（有 approvalId 时仍可去详情），`PushMessage.deepLink()` 的 `ComputerApproval` 改为 `Uri.parse(DeepLinks.APPROVALS)`（清单已声明 host `approvals`），同步更新 PushTest / InboxTargets 相关测试与注释。
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/MainActivity.kt:78` 点开“账号已解冻”（account_restored）推送后 App 仍停在冻结页，不重查账号
  - 建议修法：在 `PushCoordinator.onOpened()`（或 MainActivity.receive）里记下 `subtype == "account_restored"` 的待处理标记，`AppRoot.PushSync` 在 `auth == Frozen` 且有该标记时调一次 `service.me()`（成功即 CoreThinktinService 把状态切回 SignedIn，MainNavigation 随后处理待处理深链）；顺便让 FrozenAccountScreen 在 ON_RESUME 时也重查一次，和 iOS“回到前台时再问服务端”一致。补一个 PushTest…
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/computer/ComputerLinkViewModel.kt:467` 重新配对同一台电脑 / 生成新密钥时只在本机把令牌标成“已吊销”，电脑那边并没有作废，用户再也无法从手机吊销
  - 建议修法：`paired()` 里只有当这台电脑之前记的 `phoneKey` 与本次 `pending.phoneKey` 不同（或之前没配过）时才把它的令牌标成 revoked，与电脑端 `pair()` 的规则一致；同一把密钥重新配对时令牌保持有效、继续显示可吊销。`resetKey()` 像 `unpair()` 一样先对每台电脑的 `activeGrants` 调 `revokeNow()`（吊销不需要签名，密钥失效也能发），再清空；或者至少不要把它们标成 revoked，而是改文案说明授权要到电脑上清或等过期。
- **[high·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/computer/ComputerLinkViewModel.kt:266` 录入新指纹后密钥失效，但“生成新密钥”按钮永远出不来，用户再也配不了对、批不了审批
  - 建议修法：1) KeystoreSigner 增加不需要生物识别的失效探测：在 publicKey()（或新加 isKeyValid()）里对已有的 entry 做 `Signature.getInstance(ALGORITHM).initSign(entry.privateKey)`，捕获 KeyPermanentlyInvalidatedException 抛 DeviceSignerException.KeyInvalidated（per-op 密钥的 initSign 不弹提示框，失效在 init 阶段就抛）。2) checkKey() 捕获 KeyInvalidated 时设 needsRe…
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/inbox/InboxViewModel.kt:162` 推送 / 深链进来的那一条离线时不回退缓存：只报“网络不可用”，面板不打开
  - 建议修法：`openItem()` 在 `inboxItem()` 抛 `ServiceError.Network` 时回退 `service.cachedInbox(null, 500).firstOrNull { it.id == itemId }`（有就 `opened = it`、`markRead(it)`，client-core 离线标已读会补发；没有再发 Notice）；或者把 `openItem` 放到 `showCached()` 之后的同一个协程里，让 `known` 真能命中。测试里让替身的 `cachedInbox` 用 `yield()` 挂起一次，并加一个“syncInbox…
- **[low·low，未核实]** `data/src/main/kotlin/cn/thinktin/data/model/Computer.kt:255` CapabilityRules.isValidBundleId 比 client-core 的 check_id 宽松：非 ASCII 或超过 128 字符的 bundle id 本地放行、签名时才报错，而且报成“不是 ThinkTin 的配对码”
  - 建议修法：`BUNDLE_PART` 改成 ASCII（`^[A-Za-z0-9_-]+$`）并限制整体长度 ≤ 128（目录同样可以预检不含 `\r`）；把 `Malformed` 的界面文案按场景区分（配对页用“不是配对码”，授权 / 审批页显示 `detail` 或“内容格式不对”）。
- **[low·low，未核实]** `data/src/main/kotlin/cn/thinktin/data/model/Computer.kt:180` CapabilityRules 比 client-core 的规则宽，非 ASCII bundle id 或含 \r 的目录在签名阶段才失败，报的却是“不是 ThinkTin 的配对码”
  - 建议修法：CapabilityRules 和 check_id 对齐：bundle id 整体 1-128 个可见 ASCII 且不含 & = :，各段非空；目录拒绝 \r 和 \n。授权页把 Malformed 映射到 computer_error_invalid_grant 而不是“配对码”文案（toUiText 按场景区分，或 issueGrant 把 Malformed 转成 InvalidGrant）。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/navigation/DeepLinkInbox.kt:21` thinktin-pair: 深链内容不限长，超大 Intent 会在保存状态时 TransactionTooLargeException 崩溃
  - 建议修法：在 DeepLinkInbox.offer（或 MainNavigation 转成路由前）对 PAIR_SCHEME 的 Uri 设上限（比如 2 KB，超过直接丢弃并提示“不是 ThinkTin 的配对码”）；配对码不要经导航参数和 rememberSaveable 传递，改放进内存里的 holder（比如 ComputerLinkStore 或 DeepLinkInbox 自己）由配对页读一次。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/computer/ComputerLinkScreens.kt:474` 扫码深链进来的配对，生物识别提示框只写“和“电脑”配对”，没有说是哪台电脑
  - 建议修法：把 reason 的拼装挪进 ViewModel.pair()：parseOffer 后用 `state.value.name(offer.desktopId)` 取名字再调 signer.sign；界面改传 `(computerName: String) -> String` 或直接传字符串资源 id 让 ViewModel 格式化。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/MainActivity.kt:40` 从“最近任务”重新打开 App 时，上次推送 / 深链的 Intent 会被再处理一遍（重新跳转、重新标已读）
  - 建议修法：receive() 开头加 `if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return`；onNewIntent 里 `setIntent(intent)` 并在处理后清掉 data / tt_* extras（或记录已处理的 intent 标识）。

## E 常驻通知（13.10）

文件：`docs/review/android-13x/E-progress.json`，10 条。

- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/AppRoot.kt:90` Activity 重建（旋转、换深色、换语言）或 Android 8–11 按返回退出时，DisposableEffect 把所有进度通知撤掉、跟踪全停
  - 建议修法：把“换服务就全撤”的逻辑从组合生命周期挪到容器里：AppContainer 记住 `progress` 当前跟的是哪个 `ThinktinService`（`RunProgressTracker` 里记一个 `service` 引用，或者在 `track()` 时记 `service` 身份），只有新的 `track()` 传进来的 service 和正在跟的不是同一个对象、或者 `settings.demoMode` 真正翻转时才 `stopAll()`；或者在 Compose 里用 `remember(service)` + `DisposableEffect` 比较“上一个 servic…
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/progress/RunProgressTracker.kt:27` 进程被杀后重启不对账：过期的常驻通知留在通知栏、Android 13 及以下划不掉、开关显示“关”，直到 8 小时超时
  - 建议修法：通知的 extras 里带上 runId 和 instanceId；服务就绪且已登录时（`PushSync` 进入 SignedIn 分支，或 AppContainer 的 `startCore` 之后）枚举 `NotificationManagerCompat.getActiveNotifications()` 中 tag 为 `run_progress` 的条目：对每条调 `service.run(runId)`，已结束/404 的 cancel，还在进行的重新 `track()`（取不到就 cancel）。演示模式、未登录时直接全撤。最低限度也应在 Application 启动时把 `r…
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/progress/ProgressNotifier.kt:80` Android 14 用户划掉通知后，下一个事件又把它发回来；没有 deleteIntent 让跟踪停下
  - 建议修法：`build()` 里加 `setDeleteIntent(PendingIntent.getBroadcast(..., Intent(context, ProgressDismissedReceiver::class.java).putExtra("run_id", runId), FLAG_IMMUTABLE))`，清单里注册一个不导出的 BroadcastReceiver，收到后 `(application as ThinktinApp).container.progress.stop(runId)`（stop 里的 cancel 对已不存在的通知无害）。ProgressTest 里断…
- **[low·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/progress/RunProgress.kt:57` 起点用的是 Run 快照、缓存里更新的 run.state 被有意忽略、Reset 后也不重拉：通知可能整个过程停在“排队中”且没有计时
  - 建议修法：订阅建立后（收到第一个 `Status(Live)` 时，或者订阅前）调一次 `service.run(run.id)` 用服务端当前的 state / startedAtMs / waitCode 覆盖快照（已结束的直接 cancel 并返回）；收到 `Reset` 时也重拉一次。如果不想多一次请求，至少把缓存里 seq 最大的那条 run.state 应用上（对 `sendMessage` 返回的新运行它一定比快照新）。相应改 ProgressTest 的预期。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/progress/RunProgress.kt:44` 步数和 docs/live-activities.md §3 不一致：不含子运行、平台工具调用也算、缓存只看实例最后 500 条；流水线根运行的计时也起不来
  - 建议修法：只数 `agent.tool_call`；`startedAtMs` 在 Running 或 WaitingChildren 时都记；对 `waiting_children` 的根运行不显示步数（或定期 `run()`/`runTree()` 刷新状态）；在 docs/progress/android-app.md 里明确写出“安卓没有后台推送，子运行的步数算不进来”这个偏差。缓存初始化用 `cachedEvents(instance, afterSeq)` 配合运行的创建时间或直接依赖上一条建议里的 `service.run()`。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/progress/ProgressNotifier.kt:41` tt_progress 渠道被用户关掉时 show() 仍返回 true：开关显示开、事件流一直订着，却什么都不显示；通知被禁时开关也没有任何提示
  - 建议修法：`show()` 里加 `manager.getNotificationChannel(NotificationChannels.PROGRESS)?.importance == NotificationManager.IMPORTANCE_NONE` 时返回 false；`RunProgressTracker.track()` 返回 Boolean（或暴露一个 `lastFailure`），运行页开关在 track 没生效时显示一行“通知已关闭，去系统设置打开”（复用设置页的 `openNotificationSettings`）。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/progress/ProgressNotifier.kt:56` 通知文案用 Application context 取字符串：Android 12 及以下不跟 App 内选的语言
  - 建议修法：在 `build()` 里用 `AppCompatDelegate.getApplicationLocales()` 构造 Configuration（`setLocales`）并 `context.createConfigurationContext(config)` 后再取字符串（空列表时用原 context）；抽成一个 `localizedContext(context)` 工具给 PushNotifier 一起用。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/progress/RunProgressTracker.kt:79` stop() 后马上 track() 同一运行：旧协程的 finally 会把新 job 从表里删掉，新订阅变成停不掉的孤儿
  - 建议修法：finally 里只删自己：`val me = coroutineContext[Job]; synchronized(lock) { if (jobs[run.id] === me) { jobs.remove(run.id); trackedRuns.update { it - run.id } } }`（`track()` 里用 `scope.launch(start = LAZY)` 先放进表再 start，保证 `jobs[run.id]` 就是自己）。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/settings/AppLocales.kt:123` Android 12 及以下：用 Application context 生成的通知渠道名、运行进度通知不跟设置里选的语言
  - 建议修法：在 API < 33 上，给通知相关代码一个按 App 语言包装过的 context：`ContextCompat`/`createConfigurationContext(Configuration().apply { setLocales(LocaleList.forLanguageTags(tag)) })`，由 `AppContainer` 按 `settings.language` 提供（`SystemProgressNotifier`、`NotificationChannels.ensure`、`PushNotifier` 都从它取字符串），语言变化时重新 `ensure` 渠道名…
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/push/NotificationChannels.kt:29` Android 12 及以下：通知渠道名和进度常驻通知的文字不跟 App 内选的语言走
  - 建议修法：构建通知文案时用按 AppSettings.language 包过的 Context（`context.createConfigurationContext(Configuration().apply { setLocales(LocaleList(locale)) })`，System 时用系统的），NotificationChannels.ensure 和 SystemProgressNotifier 都走它；语言切换（SettingsViewModel 调 AppLocales.apply 后）再 ensure 一次让渠道名更新。

## F 隐私 / 设置 / 语言 / 许可（13.11、13.13）

文件：`docs/review/android-13x/F-settings.json`，6 条。

- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/ui/settings/licenses/LicensesViewModel.kt:49` 开源许可页 App 自身依赖的名字写死中文，英文界面里显示中文
  - 建议修法：把每条依赖的说明改成 `@StringRes`（如 `licenses_app_dep_androidx`、`licenses_app_dep_commonmark`），在 values / values-en 各写一份；`AppDependency` 保留纯 ASCII 的 artifact 名（如 `org.commonmark:commonmark`）用于搜索，界面上用 `stringResource` 取说明。
- **[medium·已核实成立]** `app/src/main/kotlin/cn/thinktin/app/AppContainer.kt:215` Android 13+ 在系统设置把"应用语言"改回"系统默认"后，App 不跟随：设置页仍勾着旧语言，Accept-Language 和服务端语言也不改
  - 建议修法：在 Android 13+（`Build.VERSION.SDK_INT >= 33`）系统值是权威的：`followSystemAppLanguage` 不要对 System 提前返回，直接 `if (settings.first().language != language) setLanguage(language)`；只在 API < 33 时保留"系统为空不动存的值"的逻辑（可把 sdkInt 作为构造参数注入便于测试）。
- **[medium·未核实（反方没跑成）]** `app/src/main/kotlin/cn/thinktin/app/settings/AppSettings.kt:28` 系统语言既非中文也非英文时：界面回落到中文（默认 values），服务端语言却被算成 en，和 iOS 也不一致
  - 建议修法：把英文作为默认资源：`values/strings.xml` 改成英文，中文挪到 `values-zh/strings.xml`（或 `values-b+zh`），`locales_config.xml` 不变；同步修改 docs/android-design.md 第 5 节的"values 中文、values-en 英文"。这样非中英文系统的界面、`serverLocale`、iOS 三者一致。若坚持中文做默认，则 `serverLocale` 对非 zh/en 系统要返回 zh-CN 并把 Accept-Language 里补上 zh-CN，但这与 iOS / 后端的约定相悖，不推荐。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/settings/licenses/LicenseInventory.kt:44` 开源许可页没有 NOTICES.md 入口，规范 4.9 和 iOS 都要求能看整份 NOTICES.md
  - 建议修法：在 `LicensesScreen` 的"客户端核心"一节（清单加载成功时）加一行"查看 NOTICES.md"，`onOpenText(LicenseInventory.NOTICES_FILE_NAME, stringResource(R.string.licenses_notices))`，复用 `LicenseTextScreen`（NOTICES.md 约几十 KB，`LicenseFiles.MAX_TEXT_BYTES` 够用）；补中英文文案。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ThinktinApp.kt:40` 任何配置变化（旋转、深色模式、字号）都当成"系统语言变了"：每次都重设 Accept-Language 并请求一次 GET /v1/me
  - 建议修法：在 `ThinktinApp` 记住上一次的 `newConfig.locales`（`LocaleListCompat`），只有 `locales` 变了才调 `onSystemLocalesChanged()` 和重新 `ensure` 通知渠道；或在 `onSystemLocalesChanged` 里比较 `LocaleList.getDefault().toLanguageTags()` 与上次的值。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/privacy/PrivacyInfoScreen.kt:68` 撤回同意只退出登录：下载的产出物文件、配对电脑的密钥和令牌仍留在本机，和对话框承诺的"清掉这台设备上的缓存"不符
  - 建议修法：撤回同意（以及退出登录）时在 `AppContainer` 里加一个 `clearLocalData()`：删除 `cacheDir/artifacts`，清掉 `computer_link` 偏好（或至少当前 userId 的键）、`push` 偏好；`PrivacyInfoViewModel.withdraw()` 在 `logoutQuietly()` 之后、`withdrawPrivacy()` 之前调用它。若有意保留配对数据，就把两处文案改成只说"清掉对话缓存"。

## G 应用内更新（13.12）

文件：`docs/review/android-13x/G-updater.json`，9 条。

- **[medium·未核实（反方没跑成）]** `app/src/main/kotlin/cn/thinktin/app/update/UpdateUi.kt:201` 自动更新提示框在 Activity 重建后消失，下载 / 已下好的状态无处可见
  - 建议修法：把“提示框是否打开”放进 Updater（例如 `promptOpen: StateFlow<Boolean>`，自动检查得到 Available 且未被 dismiss 时置 true，dismiss 时置 false），UpdatePrompt 只收集这个状态；或者至少改成 `rememberSaveable` 并把重开条件扩成 `state is Downloading/Ready/Failed(manifest != null)` 也算打开。
- **[high·未核实（反方没跑成）]** `app/src/main/kotlin/cn/thinktin/app/update/UpdateManifest.kt:43` 清单解析对深层嵌套 JSON 抛 StackOverflowError 未捕获：一份恶意 latest.json 让所有官网包用户每次启动都崩溃
  - 建议修法：(1) `parse` 里把 `catch (e: JSONException)` 改成 `catch (e: Exception)` 外加 `catch (e: StackOverflowError)`（或统一 `catch (e: Throwable) { if (e is VirtualMachineError && e !is StackOverflowError) throw e; throw UpdateException(BadManifest, e) }`），或者解析前先用一次线性扫描限制 `{`/`[` 的嵌套深度（例如 ≤ 32）；(2) `checkNow` / `dow…
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/update/UpdateUi.kt:112` Ready 状态下安装包文件丢失后没有任何恢复路径
  - 建议修法：在 `ApkInstaller.launch` 之前（或 UpdatePanel 的 Ready 分支）检查 `file.exists()`，不存在时把状态改成 `Failed(UpdateError.Storage/Checksum, manifest)`，这样“重试”走 download 重新下载；或给 Updater 加 `ensureReadyFile()`。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/update/ApkTools.kt:20` Android 9（API 28）上 getPackageArchiveInfo 用 GET_SIGNING_CERTIFICATES 读不到签名，签名校验被静默跳过
  - 建议修法：`archive()` 在 `Build.VERSION.SDK_INT == 28` 时传 `GET_SIGNING_CERTIFICATES or GET_SIGNATURES`（collectCertificates 会执行，signingInfo 随之填上）；并考虑在 archive 读不到签名而 installed 读得到时按 Signature 失败而不是放行。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/status/UpgradeScreen.kt:83` 官网包的升级页在清单说“已是最新”时没有出口，用户卡在页面上
  - 建议修法：UpgradeRequiredScreen 对 direct 也始终显示“去官网下载”（放在 UpdatePanel 下面），或 UpdatePanel 加一个 `showWebsiteAlways` 参数在升级页打开。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/update/Updater.kt:127` 自动检查的节流只在成功时记时间，失败时每次冷启动都请求；时钟回拨后长期不再检查
  - 建议修法：在 `checkIfDue` 决定要查时就写 `lastCheckMs = now`（或失败也写），并把 `lastCheckMs > now` 视为到期：`val last = prefs.lastCheckMs; if (last in (now - DAY_MS)..now) return`。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/update/UpdateUi.kt:214` 自动提示框下载期间不能关也不能取消，慢网络下整个 App 被挡住
  - 建议修法：Updater 加 `cancelDownload()`（`job?.cancel()`、删 .part、状态回到 Available），对话框在下载中把“以后再说”换成“取消下载”或允许关闭对话框而下载继续、进入设置页可见。
- **[low·low，未核实]** `scripts/update-manifest.py:43` update-manifest.py 不检查安装包是 direct 渠道，用商店包生成清单会让官网用户永久失去应用内更新
  - 建议修法：脚本在 badging 输出里要求出现 `uses-permission: name='android.permission.REQUEST_INSTALL_PACKAGES'`（direct 独有），否则 sys.exit("不是 direct 渠道的包")；可顺带检查文件名是否是 thinktin-<版本>.apk。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/update/Updater.kt:46` HttpURLConnection 默认跟随跨域名 302：清单和安装包的“只认 thinktin.cn”限制只对第一跳有效
  - 建议修法：在 `SystemHttpFetcher.open` 里设 `connection.instanceFollowRedirects = false`，自己处理 3xx：取 `Location`、用 `URL(url).toURI().resolve(location)` 解析后再过一次 `UpdateManifest.isAllowedUrl`，不合格抛 `UpdateException(BadManifest)`，并限制跳转次数（≤ 5）；`manifestUrl` 也在构造 `Updater` 时（或 `readText` 前）过 `isAllowedUrl`。如果决定允许跳转到第三方 C…

## H 保险箱 / IM / Mock / README（13.14、13.15、横切）

文件：`docs/review/android-13x/H-vault-im-misc.json`，10 条。

- **[medium·未核实（反方没跑成）]** `app/src/main/kotlin/cn/thinktin/app/ui/vault/VaultViewModels.kt:329` 修改条目时把已删除实例的 id 留在 selected 里，一动实例就被服务端 404 拒掉，且用户无法去掉它
  - 建议修法：加载详情后把 `selected` 过滤成当前可选实例的 id（`detail.item.instanceIds.filter { id -> instances.any { it.id == id } }.toSet()`），或者在 `instanceIds` 取值时只保留 `instances` 里存在的 id；这样已删除的实例在保存时自动被清掉，`hasChanges` 也会因此变成 true 让用户能顺手保存。可选：在修改页对被过滤掉的 id 提示一句“已删除的实例会被移除”。
- **[medium·未核实（反方没跑成）]** `app/src/main/kotlin/cn/thinktin/app/ui/imchannels/ImChannelViewModels.kt:165` “换地址”允许换成别家的平台，服务端会 422 拒绝；Mock 和测试还把这当成正确行为
  - 建议修法：在 `ImChannelRules.Problem` 加 `DifferentVendor`，`ImChannelEditorUiState.webhookProblem` 在 `editing && replacingWebhook && original != null` 且 `vendorOf(url) != null && vendorOf(url) != original.vendor` 时返回它，文案中英文各加一条（“换的地址要是同一家（%1$s）的，别家的另外绑一个” / “The new address must be a %1$s bot. Add other platfor…
- **[medium·未核实（反方没跑成）]** `app/src/main/kotlin/cn/thinktin/app/ui/imchannels/ImChannelViewModels.kt:268` 同一个群机器人绑两次（409）显示成“内容已被修改，请刷新后重试”
  - 建议修法：编辑页 `save()` 的 catch 里先判 `e is ServiceError.Api && (e.code == "conflict" || e.status == 409)` → `Notice(UiText(R.string.im_already_bound))`，中英文各加一条（“这个群机器人已经绑过了，去改那个渠道就行。” / “This group bot is already added. Edit that channel instead.”）；Mock `addImChannel`/`replaceImWebhook` 按 vendor+token 查重抛 `Serv…
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/vault/VaultScreens.kt:589` 编辑页把账号里的控制字符错误标在“用途”输入框上，账号框本身不报错
  - 建议修法：把 ControlCharacters 拆成 PurposeControlCharacters / UsernameControlCharacters（或带字段参数），编辑页各自绑到对应输入框；或在渲染时按 `VaultRules.hasControlCharacters(state.username)` 决定把问题标到账号框。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/ui/vault/VaultScreens.kt:484` 新建/修改条目页有未保存输入（含已输入的密码）时按返回直接丢弃，没有确认，和本仓库其他编辑页及 iOS 不一致
  - 建议修法：在 VaultEditorScreen 加 `BackHandler(enabled = state.hasChanges && !state.saving)` 和顶栏返回统一走一个 `requestClose`：有改动时弹 ConfirmDialog（复用 plan_discard_* 文案或加 vault_discard_*），确认后再 `onBack()`。
- **[low·low，未核实]** `data/src/main/kotlin/cn/thinktin/data/model/ImChannelRules.kt:84` 备注里有控制字符时提示“备注最多 64 个字”，用户不知道该改什么
  - 建议修法：`Problem` 拆成 `LabelTooLong` 和 `LabelControlChars`，后者文案中英文各加一条（“备注里不能有换行、制表符这类控制字符。” / “The note can't contain line breaks or other control characters.”）；ImChannelRulesTest 的 `labelsAndEvents` 改成分别断言。
- **[low·low，未核实]** `data/src/main/kotlin/cn/thinktin/data/mock/MockThinktinService.kt:804` Mock 的 confirmPlan 对“不在等确认”的计划不报 409，比服务端宽松
  - 建议修法：在 Mock 的 confirmPlan 里先判断 `!plan.awaitingConfirmation` → `ServiceError.Api(409, "conflict", "the plan is not waiting for confirmation", null)`，再比 revision；PlansViewModelTest 用它覆盖“别处已确认”。
- **[low·low，未核实]** `data/src/main/kotlin/cn/thinktin/data/mock/MockThinktinService.kt:1071` Mock 的 IM 渠道换地址允许换厂商、绑定允许重复绑同一个机器人，服务端分别报 422 / 409
  - 建议修法：Mock：replaceImWebhook 里 `parsed.vendor != old.vendor` 时抛 422 invalid（同服务端文案），addImChannel / replaceImWebhook 里按 (vendor, token) 查重抛 409 conflict；编辑页在换地址时本地就提示“要同一家的，换平台请新建渠道”，并给 409 一条专门文案。
- **[low·low，未核实]** `app/src/main/kotlin/cn/thinktin/app/push/PushNotifier.kt:35` 审批通知没有规范要求的“拒绝”快捷按钮
  - 建议修法：给 kind == Approval 且有 approvalId 的通知加一个“拒绝”action（PendingIntent 指向一个 exported=false 的 BroadcastReceiver 或 MainActivity 的特定 action），处理时先 getApproval 确认仍是待处理再 decideApproval(reject)，成功后 cancel 通知并标已读；或者在进度文件 / README 明确记为有意延后到接推送 SDK 时。
- **[low·low，未核实]** `README.md:142` README 对渠道和已知问题的描述已经过时（缺 direct 渠道；已做完的事仍列为未做）
  - 建议修法：更新 README：渠道一节加 `direct`（并说明共用 cn 的 FlavorPush、仅它申请 REQUEST_INSTALL_PACKAGES）、目录树补 app/src/direct；已知问题里删掉已完成的三条（或改写成现存的真实限制）。
