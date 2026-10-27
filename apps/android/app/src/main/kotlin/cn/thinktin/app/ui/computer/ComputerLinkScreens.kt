package cn.thinktin.app.ui.computer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.approval.rememberNowMs
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.RelativeTime
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.data.model.CapabilityGrant
import cn.thinktin.data.model.ComputerAction
import cn.thinktin.data.model.CapabilityRules
import cn.thinktin.data.model.ComputerApprovalRequest
import cn.thinktin.data.model.DeviceInfo
import cn.thinktin.data.model.DeviceSignerException
import cn.thinktin.data.model.IssuedGrant
import cn.thinktin.data.model.PairingCodecException
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTheme
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

// 手机控制电脑（13.9，docs/pairing.md）：“电脑”页（配对、授权、解除配对），审批中心里电脑发来的高危操作。
// 和 iOS 12.9 的 ComputerLinkViews 一样。签名密钥、client-core 的编码、存储都在 AppContainer 里。

const val COMPUTER_ROW_TEST_TAG = "computer-row-"
const val COMPUTER_PAIR_CODE_TEST_TAG = "computer-pair-code"

/** 建 [ComputerLinkViewModel]：依赖都在 AppContainer 里。换了服务（演示 / 真实）就是另一个。 */
@Composable
fun computerLinkViewModel(): ComputerLinkViewModel {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    return viewModel(
        key = "computer-link-${System.identityHashCode(service)}",
        factory = viewModelFactory {
            initializer {
                ComputerLinkViewModel(
                    service = service,
                    codec = container.pairingCodec,
                    signer = container.deviceSigner,
                    store = container.computerLinks,
                    clock = container.clock::millis,
                )
            }
        },
    )
}

/** 出的错 → 界面文案（服务端的错按 [ErrorText]）。 */
fun ComputerLinkError.toUiText(): UiText = when (this) {
    is ComputerLinkError.Service -> ErrorText.of(error)
    is ComputerLinkError.Pairing -> when (error) {
        is PairingCodecException.Expired -> UiText(R.string.computer_error_expired)
        is PairingCodecException.BadSignature -> UiText(R.string.computer_error_bad_signature)
        is PairingCodecException.Malformed -> UiText(R.string.computer_error_malformed)
    }
    is ComputerLinkError.Signer -> when (val e = error) {
        is DeviceSignerException.Cancelled -> UiText(R.string.computer_error_cancelled)
        is DeviceSignerException.Unavailable -> UiText(R.string.computer_cannot_sign)
        is DeviceSignerException.KeyInvalidated -> UiText(R.string.computer_needs_repair)
        is DeviceSignerException.Lockout -> UiText(R.string.computer_error_lockout)
        is DeviceSignerException.Failed -> UiText(R.string.computer_error_sign_failed, listOf(e.detail))
    }
    ComputerLinkError.NotYourComputer -> UiText(R.string.computer_error_not_yours)
    ComputerLinkError.NotPaired -> UiText(R.string.computer_error_not_paired)
    ComputerLinkError.PairingTimedOut -> UiText(R.string.computer_error_timed_out)
    ComputerLinkError.InvalidGrant -> UiText(R.string.computer_error_invalid_grant)
}

/**
 * “电脑”页（路由 computers，从设备与账号页进）：这个账号登录着的每台电脑的配对状态、在线状态；授权、吊销、解除配对。
 * 配对、授权各是单独的页面（[ComputerPairScreen]、[ComputerGrantScreen]：有输入框，不做成对话框）。
 */
@Composable
fun ComputersScreen(onBack: () -> Unit, onPair: (computerId: String) -> Unit, onGrant: (computerId: String) -> Unit) {
    val container = LocalAppContainer.current
    val viewModel = computerLinkViewModel()
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val now by rememberNowMs(container.clock)
    LaunchedEffect(viewModel) { viewModel.onShown() }
    var unpairing by remember { mutableStateOf<DeviceInfo?>(null) }
    var confirmReset by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_computers),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            item {
                Text(
                    stringResource(R.string.computer_intro),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                )
            }
            state.error?.let { error ->
                item { Notice(error.toUiText().asString(), MaterialTheme.colorScheme.error) }
            }
            if (!state.canSign) {
                item { Notice(stringResource(R.string.computer_cannot_sign), MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            if (state.needsRepair) {
                item {
                    Column(Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp)) {
                        Text(
                            stringResource(R.string.computer_needs_repair),
                            style = MaterialTheme.typography.bodySmall,
                            color = ThinktinTheme.extendedColors.warning,
                        )
                        SecondaryButton(
                            text = stringResource(R.string.computer_reset_key),
                            onClick = { confirmReset = true },
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }
                }
            }
            item { SectionHeader(stringResource(R.string.page_computers), Modifier.padding(horizontal = ThinktinSpacing.Page)) }
            when {
                state.loading && !state.hasLoaded -> item {
                    val label = stringResource(R.string.loading)
                    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.semantics { contentDescription = label })
                    }
                }
                state.hasLoaded && state.computers.isEmpty() -> item {
                    Notice(stringResource(R.string.computer_none), MaterialTheme.colorScheme.onSurfaceVariant)
                }
                else -> items(state.computers, key = { it.id }) { computer ->
                    ComputerRow(
                        computer = computer,
                        state = state,
                        nowMs = now,
                        onPair = { onPair(computer.id) },
                        onGrant = { onGrant(computer.id) },
                        onUnpair = { unpairing = computer },
                        onRevoke = viewModel::revoke,
                    )
                }
            }
            item { Box(Modifier.padding(bottom = 24.dp)) }
        }
    }

    unpairing?.let { computer ->
        ConfirmDialog(
            title = stringResource(R.string.computer_unpair_title, computer.name),
            text = stringResource(R.string.computer_unpair_message),
            confirm = stringResource(R.string.computer_unpair),
            danger = true,
            onConfirm = {
                viewModel.unpair(computer.id)
                unpairing = null
            },
            onDismiss = { unpairing = null },
        )
    }
    if (confirmReset) {
        ConfirmDialog(
            title = stringResource(R.string.computer_reset_key_title),
            text = stringResource(R.string.computer_reset_key_message),
            confirm = stringResource(R.string.computer_reset_key_confirm),
            danger = true,
            onConfirm = {
                viewModel.resetKey()
                confirmReset = false
            },
            onDismiss = { confirmReset = false },
        )
    }
}

@Composable
private fun Notice(text: String, color: androidx.compose.ui.graphics.Color) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = color,
        modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp),
    )
}

/** 一台电脑：名字、在线、配对状态；没配对时右边是“配对”，配好了是更多操作（授权、重新配对、解除配对），下面列着有效的授权。 */
@Composable
private fun ComputerRow(
    computer: DeviceInfo,
    state: ComputerLinkUiState,
    nowMs: Long,
    onPair: () -> Unit,
    onGrant: () -> Unit,
    onUnpair: () -> Unit,
    onRevoke: (IssuedGrant) -> Unit,
) {
    val zone = LocalAppContainer.current.clock.zone
    val paired = state.paired(computer.id)
    val online = stringResource(if (computer.online) R.string.devices_online else R.string.devices_offline)
    val pairing = paired?.let {
        stringResource(R.string.computer_paired, RelativeTime.of(it.pairedAtMs, nowMs, zone).asString())
    } ?: stringResource(R.string.computer_not_paired)
    var menuOpen by remember { mutableStateOf(false) }
    Column(Modifier.testTag(COMPUTER_ROW_TEST_TAG + computer.id)) {
        ListItem(
            headlineContent = { Text(computer.name) },
            supportingContent = { Text(stringResource(R.string.computer_status, online, pairing)) },
            leadingContent = { Icon(Icons.Outlined.Laptop, contentDescription = null) },
            trailingContent = {
                if (paired == null) {
                    TextButton(onClick = onPair, enabled = state.canSign && !state.working) {
                        Text(stringResource(R.string.computer_pair))
                    }
                } else {
                    Box {
                        IconButton(onClick = { menuOpen = true }) {
                            Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.computer_more, computer.name))
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.computer_grant)) },
                                enabled = state.canSign,
                                onClick = {
                                    menuOpen = false
                                    onGrant()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.computer_pair_again)) },
                                enabled = state.canSign,
                                onClick = {
                                    menuOpen = false
                                    onPair()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.computer_unpair), color = MaterialTheme.colorScheme.error) },
                                onClick = {
                                    menuOpen = false
                                    onUnpair()
                                },
                            )
                        }
                    }
                }
            },
            colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
        )
        if (paired != null) {
            for (issued in state.activeGrants(computer.id, nowMs)) {
                GrantRow(issued, nowMs, onRevoke = { onRevoke(issued) })
            }
        }
    }
}

@Composable
private fun GrantRow(issued: IssuedGrant, nowMs: Long, onRevoke: () -> Unit) {
    val summary = grantSummary(issued.grant)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 72.dp, end = 8.dp, bottom = 8.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(summary, style = MaterialTheme.typography.bodySmall)
            Text(
                expiresText(issued.grant.expiresAt, nowMs),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val description = stringResource(R.string.computer_revoke_description, summary)
        TextButton(onClick = onRevoke, modifier = Modifier.semantics { contentDescription = description }) {
            Text(stringResource(R.string.computer_revoke), color = MaterialTheme.colorScheme.error)
        }
    }
}

/** 授权的内容：目录、应用。 */
@Composable
private fun grantSummary(grant: CapabilityGrant): String {
    val separator = stringResource(R.string.computer_list_separator)
    val parts = buildList {
        if (grant.dirs.isNotEmpty()) add(stringResource(R.string.computer_grant_dirs_summary, grant.dirs.joinToString(separator)))
        if (grant.apps.isNotEmpty()) add(stringResource(R.string.computer_grant_apps_summary, grant.apps.joinToString(separator)))
    }
    return parts.joinToString(stringResource(R.string.computer_summary_separator))
}

/** 还有多久到期（[expiresAtSecs] 是 Unix 秒）。 */
@Composable
private fun expiresText(expiresAtSecs: Long, nowMs: Long): String {
    val minutes = ((expiresAtSecs * 1000 - nowMs) / 60_000).coerceAtLeast(1)
    return when {
        minutes < 60 -> stringResource(R.string.computer_expires_minutes, minutes.toInt())
        minutes < 48 * 60 -> stringResource(R.string.computer_expires_hours, (minutes / 60).toInt())
        else -> stringResource(R.string.computer_expires_days, (minutes / (24 * 60)).toInt())
    }
}

@Composable
private fun durationText(seconds: Long): String {
    val hours = (seconds / 3600).toInt()
    return if (hours >= 24) {
        stringResource(R.string.computer_duration_days, hours / 24)
    } else {
        stringResource(R.string.computer_duration_hours, hours)
    }
}

/**
 * 配对一台电脑（路由 computers/pair）：粘贴配对码（或者从二维码深链带进来）→ 生物识别签名 → 等电脑确认。等的时候每隔几秒
 * 收一次消息，离开这页就不等了（配对邀请留着，下次打开电脑页时还会收确认，过期了自己清掉）。[computerId] 为 null 是从二维码
 * 进来的：还不知道是哪台。
 */
@Composable
fun ComputerPairScreen(computerId: String?, pairingCode: String?, onBack: () -> Unit) {
    val context = LocalContext.current
    val clock = LocalAppContainer.current.clock
    val viewModel = computerLinkViewModel()
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    var code by rememberSaveable { mutableStateOf(pairingCode.orEmpty()) }
    // 这页打开之后配好的才算“这次配好了”。
    val openedAtMs by rememberSaveable { mutableLongStateOf(clock.millis()) }
    val computer = computerId?.let { id -> state.computers.firstOrNull { it.id == id } }
    val done = !state.isPairing && state.link.computers.any {
        it.pairedAtMs >= openedAtMs && (computerId == null || it.desktopId == computerId)
    }
    LaunchedEffect(state.isPairing) {
        if (state.isPairing) viewModel.awaitConfirmation()
    }
    val name = computer?.name ?: stringResource(R.string.computer_approval_unknown)
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = computer?.let { stringResource(R.string.computer_pair_title, it.name) }
                    ?: stringResource(R.string.computer_pair_title_any),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
        ) {
            Text(
                stringResource(R.string.computer_pair_instructions),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            when {
                done -> {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Outlined.CheckCircle, contentDescription = null, tint = ThinktinTheme.extendedColors.success)
                        Text(stringResource(R.string.computer_pair_done), style = MaterialTheme.typography.titleMedium)
                    }
                    PrimaryButton(text = stringResource(R.string.action_close), onClick = onBack, modifier = Modifier.fillMaxWidth())
                }
                // 等的时间可能很长（电脑不在线）：用静态的沙漏，不放一直转的圈。
                state.isPairing -> {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(Icons.Outlined.HourglassEmpty, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Text(stringResource(R.string.computer_pair_waiting), style = MaterialTheme.typography.bodyMedium)
                    }
                    SecondaryButton(
                        text = stringResource(R.string.computer_pair_stop_waiting),
                        onClick = viewModel::cancelPairing,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                else -> {
                    OutlinedTextField(
                        value = code,
                        onValueChange = { code = it },
                        label = { Text(stringResource(R.string.computer_pair_code)) },
                        placeholder = { Text("thinktin-pair:v1?…") },
                        textStyle = TextStyle(fontFamily = FontFamily.Monospace),
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                        maxLines = 4,
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(COMPUTER_PAIR_CODE_TEST_TAG),
                    )
                    PrimaryButton(
                        text = stringResource(R.string.computer_pair),
                        onClick = { viewModel.pair(code, context.getString(R.string.computer_sign_pair, name)) },
                        enabled = code.isNotBlank() && state.hasLoaded && state.canSign,
                        loading = state.working,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            state.error?.let {
                Text(it.toUiText().asString(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            if (!state.canSign) {
                Text(
                    stringResource(R.string.computer_cannot_sign),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** 给配好的电脑授权（路由 computers/{id}/grant）：能碰的目录、应用（一行一个）和有效期，签名发过去，发出去就回电脑页。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ComputerGrantScreen(computerId: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val viewModel = computerLinkViewModel()
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    var dirs by rememberSaveable { mutableStateOf("") }
    var apps by rememberSaveable { mutableStateOf("") }
    var duration by rememberSaveable { mutableLongStateOf(CapabilityRules.DURATIONS[1]) }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { if (it is ComputerLinkEvent.GrantIssued) onBack() }
    }
    val name = state.name(computerId) ?: stringResource(R.string.computer_approval_unknown)
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.computer_grant_title, name),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
        ) {
            Text(
                stringResource(R.string.computer_grant_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            LinesField(dirs, { dirs = it }, stringResource(R.string.computer_grant_dirs), "/Users/me/Documents")
            LinesField(apps, { apps = it }, stringResource(R.string.computer_grant_apps), "com.apple.Safari")
            Text(stringResource(R.string.computer_grant_duration), style = MaterialTheme.typography.labelLarge)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (option in CapabilityRules.DURATIONS) {
                    FilterChip(selected = option == duration, onClick = { duration = option }, label = { Text(durationText(option)) })
                }
            }
            state.error?.let {
                Text(it.toUiText().asString(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            PrimaryButton(
                text = stringResource(R.string.computer_grant_sign),
                loading = state.working,
                enabled = state.hasLoaded && state.canSign,
                onClick = {
                    viewModel.issueGrant(
                        desktopId = computerId,
                        dirs = dirs.lines(),
                        apps = apps.lines(),
                        durationSecs = duration,
                        reason = context.getString(R.string.computer_sign_grant, name),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun LinesField(value: String, onValueChange: (String) -> Unit, label: String, placeholder: String) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        textStyle = TextStyle(fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
        minLines = 3,
        modifier = Modifier.fillMaxWidth(),
    )
}

// ---- 审批中心里的电脑操作 ----

/** 审批中心列表里的一组：电脑发来的高危操作（说明是 AI 生成的、工具、参数），批准 / 拒绝都要生物识别签名。 */
fun LazyListScope.computerApprovalItems(
    requests: List<ComputerApprovalRequest>,
    state: ComputerLinkUiState,
    nowMs: Long,
    onDecide: (ComputerApprovalRequest, Boolean) -> Unit,
) {
    if (requests.isEmpty()) return
    item(key = "computer-approvals") {
        Column {
            SectionHeader(stringResource(R.string.computer_approvals_title), Modifier.fillMaxWidth())
            state.error?.let {
                Text(it.toUiText().asString(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
        }
    }
    items(requests, key = { "computer-${it.requestId}" }) { request ->
        ComputerApprovalCard(request, state, nowMs, onDecide)
    }
}

const val COMPUTER_APPROVAL_CARD_TEST_TAG = "computer-approval-"

@Composable
private fun ComputerApprovalCard(
    request: ComputerApprovalRequest,
    state: ComputerLinkUiState,
    nowMs: Long,
    onDecide: (ComputerApprovalRequest, Boolean) -> Unit,
) {
    val computer = state.name(request.desktopId) ?: stringResource(R.string.computer_approval_unknown)
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(COMPUTER_APPROVAL_CARD_TEST_TAG + request.requestId),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.Laptop, contentDescription = null, modifier = Modifier.size(16.dp))
                Text(
                    computer,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    expiresText(request.expiresAt, nowMs),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(approvalDescription(request), style = MaterialTheme.typography.bodyLarge)
            AiGeneratedLabel()
            Text(request.tool, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace))
            Text(
                prettyArguments(request.argumentsJson),
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 8,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 4.dp)) {
                val enabled = !state.working && state.canSign
                SecondaryButton(
                    text = stringResource(R.string.computer_reject),
                    onClick = { onDecide(request, false) },
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                )
                PrimaryButton(
                    text = stringResource(R.string.computer_approve),
                    onClick = { onDecide(request, true) },
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** 审批卡片的说明：执行命令、删除按手机的界面语言说，理由照原话附上；别的工具用电脑给的说明。和 iOS 一样。 */
@Composable
private fun approvalDescription(request: ComputerApprovalRequest): String {
    val what = when (val action = request.action()) {
        is ComputerAction.Run ->
            action.cwd?.let { cwd -> stringResource(R.string.computer_approval_run_in, cwd, action.command) }
                ?: stringResource(R.string.computer_approval_run, action.command)
        is ComputerAction.Delete -> stringResource(R.string.computer_approval_delete, action.path)
        null -> return request.summary
    }
    val reason = request.reason() ?: return what
    return what + "\n" + stringResource(R.string.computer_approval_reason, reason)
}

private val prettyJson = Json { prettyPrint = true }

/** 参数 JSON 排好版；不是 JSON 就原样显示。 */
internal fun prettyArguments(text: String): String = try {
    prettyJson.encodeToString(JsonElement.serializer(), Json.parseToJsonElement(text))
} catch (_: SerializationException) {
    text
} catch (_: IllegalArgumentException) {
    text
}
