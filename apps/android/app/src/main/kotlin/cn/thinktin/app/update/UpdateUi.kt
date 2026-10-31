package cn.thinktin.app.update

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.thinktin.app.BuildConfig
import cn.thinktin.app.R
import cn.thinktin.app.ui.chat.formatSize
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing

/** 失败原因的文案。 */
private fun UpdateError.message(): Int = when (this) {
    UpdateError.Network -> R.string.update_error_network
    UpdateError.BadManifest -> R.string.update_error_manifest
    UpdateError.DeviceTooOld -> R.string.update_error_device
    UpdateError.Checksum -> R.string.update_error_checksum
    UpdateError.BadApk -> R.string.update_error_apk
    UpdateError.Signature -> R.string.update_error_signature
    UpdateError.Storage -> R.string.update_error_storage
}

/**
 * 检查、下载、安装的面板（设置 → 检查更新、升级页、自动检查的提示共用）：状态一句话、更新内容、进度、按钮；
 * 出错时可以重试，也可以去官网下载。
 */
@Composable
fun UpdatePanel(updater: Updater, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val chinese = LocalConfiguration.current.locales[0].language == "zh"
    val state by updater.updateState.collectAsStateWithLifecycle()
    var installNote by remember { mutableStateOf<Int?>(null) }
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val status = when (val current = state) {
            UpdateState.Idle -> null
            UpdateState.Checking -> stringResource(R.string.update_checking)
            UpdateState.UpToDate -> stringResource(R.string.update_up_to_date)
            is UpdateState.Available -> stringResource(R.string.update_available, current.manifest.versionName)
            is UpdateState.Downloading -> stringResource(
                R.string.update_downloading,
                formatSize(current.read),
                formatSize(current.manifest.size),
            )
            is UpdateState.Ready -> stringResource(R.string.update_ready)
            is UpdateState.Failed -> stringResource(current.error.message())
        }
        if (status != null) {
            Text(
                text = status,
                style = MaterialTheme.typography.bodyLarge,
                color = if (state is UpdateState.Failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        val manifest = when (val current = state) {
            is UpdateState.Available -> current.manifest
            is UpdateState.Downloading -> current.manifest
            is UpdateState.Ready -> current.manifest
            else -> null
        }
        if (manifest != null) {
            Text(
                text = stringResource(R.string.update_size, formatSize(manifest.size)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            val notes = manifest.notes(chinese)
            if (notes.isNotBlank()) {
                Text(stringResource(R.string.update_notes_title), style = MaterialTheme.typography.titleSmall)
                Text(notes, style = MaterialTheme.typography.bodyMedium)
            }
        }
        when (val current = state) {
            UpdateState.Checking -> LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            is UpdateState.Downloading -> LinearProgressIndicator(
                progress = { (current.read.toFloat() / current.manifest.size).coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
            )
            is UpdateState.Available -> PrimaryButton(
                text = stringResource(R.string.update_download),
                onClick = updater::download,
                modifier = Modifier.fillMaxWidth(),
            )
            is UpdateState.Ready -> PrimaryButton(
                text = stringResource(R.string.update_install),
                onClick = {
                    val file = updater.readyFile() ?: return@PrimaryButton
                    installNote = when (ApkInstaller.launch(context, file)) {
                        InstallLaunch.Started -> null
                        InstallLaunch.NeedsPermission -> R.string.update_needs_permission
                        InstallLaunch.Unavailable -> R.string.update_install_unavailable
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
            is UpdateState.Failed -> {
                val retry = if (current.manifest != null && current.error != UpdateError.DeviceTooOld) {
                    updater::download
                } else {
                    updater::check
                }
                PrimaryButton(
                    text = stringResource(R.string.action_retry),
                    onClick = retry,
                    modifier = Modifier.fillMaxWidth(),
                )
                SecondaryButton(
                    text = stringResource(R.string.update_open_website),
                    onClick = { StoreLinks.openDownloadPage(context) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            UpdateState.Idle, UpdateState.UpToDate -> SecondaryButton(
                text = stringResource(if (state == UpdateState.Idle) R.string.settings_check_update else R.string.update_check_again),
                onClick = updater::check,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        installNote?.let { note ->
            Text(
                text = stringResource(note),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** 设置 → 检查更新（只有官网安装包有）：进来就查一次。 */
@Composable
fun UpdateScreen(updater: Updater, onBack: () -> Unit) {
    LaunchedEffect(updater) {
        if (updater.updateState.value.let { it == UpdateState.Idle || it is UpdateState.Failed || it == UpdateState.UpToDate }) {
            updater.check()
        }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.settings_check_update),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = stringResource(R.string.update_current_version, BuildConfig.VERSION_NAME),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            UpdatePanel(updater)
        }
    }
}

/**
 * 自动检查（一天最多一次）发现新版本时弹一次：可以直接下载安装，也可以“以后再说”（这个版本不再自动弹）。
 * 下载中、下好了也在这个框里，直到装上或关掉。
 */
@Composable
fun UpdatePrompt(updater: Updater) {
    LaunchedEffect(updater) { updater.checkIfDue() }
    val state by updater.updateState.collectAsStateWithLifecycle()
    var open by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state) {
        if (state is UpdateState.Available && updater.shouldPrompt) open = true
    }
    if (!open) return
    val version = when (val current = state) {
        is UpdateState.Available -> current.manifest.versionName
        is UpdateState.Downloading -> current.manifest.versionName
        is UpdateState.Ready -> current.manifest.versionName
        is UpdateState.Failed -> current.manifest?.versionName
        else -> null
    }
    AlertDialog(
        onDismissRequest = {},
        title = { Text(stringResource(R.string.update_prompt_title, version.orEmpty())) },
        text = { UpdatePanel(updater) },
        confirmButton = {},
        dismissButton = {
            TextButton(
                onClick = {
                    updater.dismiss()
                    open = false
                },
            ) { Text(stringResource(R.string.update_later)) }
        },
    )
}
