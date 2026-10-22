package cn.thinktin.data.core

import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.ImChannel
import cn.thinktin.data.model.NewImChannel
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.InboxPage
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.LoginResult
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.model.RouteFallback
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.SavedSecret
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.SignOutOthersResult
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.Trigger
import cn.thinktin.data.model.UsageBucket
import cn.thinktin.data.model.UsageSummary
import cn.thinktin.data.model.User
import cn.thinktin.data.model.VaultItem
import cn.thinktin.data.model.VaultItemDetail
import cn.thinktin.data.model.VaultItemUpdate
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.data.model.parseJsonObject
import cn.thinktin.core.AgentInfo as CoreAgentInfo
import cn.thinktin.core.Approval as CoreApproval
import cn.thinktin.core.ApprovalOption as CoreApprovalOption
import cn.thinktin.core.Artifact as CoreArtifact
import cn.thinktin.core.Credential as CoreCredential
import cn.thinktin.core.DetectedSecret as CoreDetectedSecret
import cn.thinktin.core.ImChannel as CoreImChannel
import cn.thinktin.core.NewImChannel as CoreNewImChannel
import cn.thinktin.core.InboxItem as CoreInboxItem
import cn.thinktin.core.InboxPage as CoreInboxPage
import cn.thinktin.core.Instance as CoreInstance
import cn.thinktin.core.InstanceEvent as CoreInstanceEvent
import cn.thinktin.core.LoginResult as CoreLoginResult
import cn.thinktin.core.ModelRoute as CoreModelRoute
import cn.thinktin.core.NewCredential as CoreNewCredential
import cn.thinktin.core.NewPlan as CoreNewPlan
import cn.thinktin.core.NewVaultItem as CoreNewVaultItem
import cn.thinktin.core.Plan as CorePlan
import cn.thinktin.core.PlanStep as CorePlanStep
import cn.thinktin.core.RouteFallback as CoreRouteFallback
import cn.thinktin.core.Run as CoreRun
import cn.thinktin.core.SavedSecret as CoreSavedSecret
import cn.thinktin.core.Schedule as CoreSchedule
import cn.thinktin.core.SignOutOthersResult as CoreSignOutOthersResult
import cn.thinktin.core.StopAllResult as CoreStopAllResult
import cn.thinktin.core.StreamStatus as CoreStreamStatus
import cn.thinktin.core.Trigger as CoreTrigger
import cn.thinktin.core.UsageBucket as CoreUsageBucket
import cn.thinktin.core.UsageSummary as CoreUsageSummary
import cn.thinktin.core.User as CoreUser
import cn.thinktin.core.VaultItem as CoreVaultItem
import cn.thinktin.core.VaultItemDetail as CoreVaultItemDetail
import cn.thinktin.core.VaultItemUpdate as CoreVaultItemUpdate
import cn.thinktin.core.VaultRequest as CoreVaultRequest
import cn.thinktin.core.VendorInfo as CoreVendorInfo

/*
 * cn.thinktin.core（UniFFI）→ App 模型。无符号数转有符号（服务端的计数和大小远小于 Long.MAX_VALUE），
 * 状态字符串转枚举（未知 → Unknown），JSON 字符串解析成对象（失败 → 空对象）。
 */

/** ULong → Long；超出范围（不会发生）时取 Long.MAX_VALUE，不溢出成负数。 */
internal fun ULong.toLongClamped(): Long = if (this > Long.MAX_VALUE.toULong()) Long.MAX_VALUE else toLong()

internal fun UInt.toIntClamped(): Int = if (this > Int.MAX_VALUE.toUInt()) Int.MAX_VALUE else toInt()

/** Long → ULong；负数按 0。 */
internal fun Long.toULongNonNegative(): ULong = coerceAtLeast(0).toULong()

internal fun Int.toUIntNonNegative(): UInt = coerceAtLeast(0).toUInt()

internal fun CoreUser.toModel(): User = User(
    id = id,
    phone = phone,
    displayName = displayName,
    status = status,
    locale = locale,
    createdAtMs = createdAtMs,
)

internal fun CoreLoginResult.toModel(): LoginResult = LoginResult(user = user.toModel(), newUser = newUser)

internal fun CoreAgentInfo.toModel(): AgentInfo = AgentInfo(
    id = id,
    name = name,
    version = version,
    license = license,
    sites = sites,
    harnesses = harnesses,
    defaultHarness = defaultHarness,
    versions = versions,
)

internal fun CoreInstance.toModel(): Instance = Instance(
    id = id,
    agentId = agentId,
    agentVersion = agentVersion,
    harness = harness,
    name = name,
    state = InstanceState.fromWire(state),
    createdAtMs = createdAtMs,
    lastActiveAtMs = lastActiveAtMs,
)

internal fun CoreRouteFallback.toModel(): RouteFallback = RouteFallback(credentialId, upstreamModel)

internal fun RouteFallback.toCore(): CoreRouteFallback = CoreRouteFallback(credentialId, upstreamModel)

internal fun CoreModelRoute.toModel(): ModelRoute = ModelRoute(
    alias = alias,
    credentialId = credentialId,
    upstreamModel = upstreamModel,
    fallbacks = fallbacks.map { it.toModel() },
)

internal fun ModelRoute.toCore(): CoreModelRoute = CoreModelRoute(
    alias = alias,
    credentialId = credentialId,
    upstreamModel = upstreamModel,
    fallbacks = fallbacks.map { it.toCore() },
)

internal fun CoreRun.toModel(): Run = Run(
    id = id,
    kind = RunKind.fromWire(kind),
    instanceId = instanceId,
    planId = planId,
    parentRunId = parentRunId,
    rootRunId = rootRunId,
    stepKey = stepKey,
    source = RunSource.fromWire(source),
    prompt = prompt,
    state = RunState.fromWire(state),
    stateReason = stateReason,
    attempt = attempt.toIntClamped(),
    tokensUsed = tokensUsed.toLongClamped(),
    summary = summary,
    error = error,
    createdAtMs = createdAtMs,
    startedAtMs = startedAtMs,
    finishedAtMs = finishedAtMs,
)

internal fun CoreArtifact.toModel(): Artifact = Artifact(
    id = id,
    instanceId = instanceId,
    runId = runId,
    name = name,
    version = version.toIntClamped(),
    contentType = contentType,
    size = size.toLongClamped(),
    sha256 = sha256,
    createdAtMs = createdAtMs,
)

internal fun CoreInstanceEvent.toModel(): InstanceEvent = InstanceEvent(
    instanceId = instanceId,
    seq = seq.toLongClamped(),
    runId = runId,
    kind = kind,
    payload = parseJsonObject(payloadJson),
    aiGenerated = aiGenerated,
    createdAtMs = createdAtMs,
)

internal fun CoreStreamStatus.toModel(): StreamState = when (this) {
    CoreStreamStatus.Connecting -> StreamState.Connecting
    CoreStreamStatus.Live -> StreamState.Live
    is CoreStreamStatus.Reconnecting -> StreamState.Reconnecting(retryInMs.toLongClamped())
    CoreStreamStatus.SignedOut -> StreamState.SignedOut
    CoreStreamStatus.NotFound -> StreamState.NotFound
    CoreStreamStatus.AccountFrozen -> StreamState.AccountFrozen
    CoreStreamStatus.Stopped -> StreamState.Stopped
}

internal fun CoreApprovalOption.toModel(): ApprovalOption =
    ApprovalOption(optionId = optionId, name = name, kind = OptionKind.fromWire(kind))

internal fun CoreApproval.toModel(): Approval = Approval(
    id = id,
    runId = runId,
    instanceId = instanceId,
    title = title,
    options = options.map { it.toModel() },
    toolCallJson = toolCallJson,
    toolCall = parseJsonObject(toolCallJson),
    state = ApprovalState.fromWire(state),
    expiresAtMs = expiresAtMs,
    createdAtMs = createdAtMs,
)

internal fun CoreSchedule.toModel(): Schedule = when (this) {
    is CoreSchedule.Cron -> Schedule.Cron(expr = expr, tz = tz)
    is CoreSchedule.Rrule -> Schedule.Rrule(rule = rule)
    is CoreSchedule.Once -> Schedule.Once(atMs = atMs)
}

internal fun Schedule.toCore(): CoreSchedule = when (this) {
    is Schedule.Cron -> CoreSchedule.Cron(expr = expr, tz = tz)
    is Schedule.Rrule -> CoreSchedule.Rrule(rule = rule)
    is Schedule.Once -> CoreSchedule.Once(atMs = atMs)
}

internal fun CoreTrigger.toModel(): Trigger = Trigger(
    id = id,
    schedule = schedule.toModel(),
    enabled = enabled,
    nextFireAtMs = nextFireAtMs,
    lastFireAtMs = lastFireAtMs,
)

internal fun CorePlanStep.toModel(): PlanStep =
    PlanStep(key = key, instanceId = instanceId, prompt = prompt, dependsOn = dependsOn)

internal fun PlanStep.toCore(): CorePlanStep =
    CorePlanStep(key = key, instanceId = instanceId, prompt = prompt, dependsOn = dependsOn)

internal fun CorePlan.toModel(): Plan = Plan(
    id = id,
    instanceId = instanceId,
    title = title,
    goal = goal,
    paused = paused,
    createdBy = createdBy,
    awaitingConfirmation = awaitingConfirmation,
    revision = revision.toIntClamped(),
    policyJson = policyJson,
    policy = parseJsonObject(policyJson),
    createdAtMs = createdAtMs,
    triggers = triggers.map { it.toModel() },
    steps = steps.map { it.toModel() },
)

internal fun NewPlan.toCore(): CoreNewPlan = CoreNewPlan(
    instanceId = instanceId,
    title = title,
    goal = goal,
    triggers = triggers.map { it.toCore() },
    steps = steps.map { it.toCore() },
)

internal fun CoreInboxItem.toModel(): InboxItem = InboxItem(
    id = id,
    instanceId = instanceId,
    runId = runId,
    planId = planId,
    approvalId = approvalId,
    kind = InboxKind.fromWire(kind),
    title = title,
    body = body,
    aiGenerated = aiGenerated,
    read = read,
    createdAtMs = createdAtMs,
)

internal fun CoreInboxPage.toModel(): InboxPage = InboxPage(items = items.map { it.toModel() }, unread = unread)

internal fun CoreCredential.toModel(): Credential = Credential(
    id = id,
    vendor = vendor,
    label = label,
    last4 = last4,
    dailyTokenLimit = dailyTokenLimit?.toLongClamped(),
    disabled = disabled,
    createdAtMs = createdAtMs,
)

internal fun NewCredential.toCore(): CoreNewCredential = CoreNewCredential(
    vendor = vendor,
    label = label,
    apiKey = apiKey,
    anthropicBase = anthropicBase,
    openaiBase = openaiBase,
    responsesBase = responsesBase,
    dailyTokenLimit = dailyTokenLimit?.toULongNonNegative(),
)

internal fun CoreVendorInfo.toModel(): VendorInfo =
    VendorInfo(id = id, name = name, protocols = protocols, models = models, notes = notes)

internal fun CoreUsageBucket.toModel(): UsageBucket = UsageBucket(
    key = key,
    requests = requests.toLongClamped(),
    inputTokens = inputTokens.toLongClamped(),
    cacheReadTokens = cacheReadTokens.toLongClamped(),
    cacheWriteTokens = cacheWriteTokens.toLongClamped(),
    outputTokens = outputTokens.toLongClamped(),
    chargedTokens = chargedTokens.toLongClamped(),
    estimatedRequests = estimatedRequests.toLongClamped(),
    failedRequests = failedRequests.toLongClamped(),
)

internal fun CoreUsageSummary.toModel(): UsageSummary =
    UsageSummary(buckets = buckets.map { it.toModel() }, total = total.toModel())

internal fun CoreStopAllResult.toModel(): StopAllResult = StopAllResult(
    runsCancelled = runsCancelled.toLongClamped(),
    grantsRevoked = grantsRevoked.toLongClamped(),
    plansPaused = plansPaused.toLongClamped(),
)

internal fun CoreSignOutOthersResult.toModel(): SignOutOthersResult =
    SignOutOthersResult(devicesSignedOut = devicesSignedOut.toLongClamped(), stopped = stopped?.toModel())

internal fun CoreDetectedSecret.toModel(): DetectedSecret = DetectedSecret(
    kind = kind,
    start = start.toIntClamped(),
    end = end.toIntClamped(),
    value = value,
    suggestedName = suggestedName,
    service = service,
    storable = storable,
)

internal fun CoreVaultItem.toModel(): VaultItem = VaultItem(
    id = id,
    name = name,
    purpose = purpose,
    hasUsername = hasUsername,
    instanceIds = instanceIds,
    createdAtMs = createdAtMs,
    updatedAtMs = updatedAtMs,
    lastUsedAtMs = lastUsedAtMs,
)

internal fun CoreVaultItemDetail.toModel(): VaultItemDetail = VaultItemDetail(item = item.toModel(), username = username)

internal fun NewVaultItem.toCore(): CoreNewVaultItem = CoreNewVaultItem(
    name = name,
    purpose = purpose,
    username = username,
    password = password,
    instanceIds = instanceIds,
)

internal fun VaultItemUpdate.toCore(): CoreVaultItemUpdate = CoreVaultItemUpdate(
    purpose = purpose,
    username = username,
    password = password,
    instanceIds = instanceIds,
)

internal fun CoreSavedSecret.toModel(): SavedSecret = SavedSecret(item = item.toModel(), message = message)

internal fun CoreVaultRequest.toModel(): VaultRequest = VaultRequest(
    id = id,
    instanceId = instanceId,
    runId = runId,
    name = name,
    purpose = purpose,
    fields = fields,
    status = VaultRequestStatus.fromWire(status),
    itemId = itemId,
    createdAtMs = createdAtMs,
    expiresAtMs = expiresAtMs,
    resolvedAtMs = resolvedAtMs,
)

internal fun CoreImChannel.toModel(): ImChannel = ImChannel(
    id = id,
    vendor = vendor,
    label = label,
    hint = hint,
    hasSecret = hasSecret,
    events = events,
    enabled = enabled,
    lastSentAtMs = lastSentAtMs,
    lastError = lastError,
    createdAtMs = createdAtMs,
)

internal fun NewImChannel.toCore(): CoreNewImChannel =
    CoreNewImChannel(webhookUrl = webhookUrl, secret = secret, label = label, events = events)
