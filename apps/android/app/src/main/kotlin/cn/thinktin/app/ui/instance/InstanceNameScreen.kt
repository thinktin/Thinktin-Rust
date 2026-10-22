package cn.thinktin.app.ui.instance

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.agent.InstanceNames
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class InstanceNameUiState(
    val loading: Boolean = true,
    val name: String = "",
    /** 现在的名字；还没取到是 null（不能保存）。 */
    val original: String? = null,
    val loadError: UiText? = null,
    /** 名字下的提示。 */
    val error: UiText? = null,
    val saving: Boolean = false,
    /** 已经发出 Saved（等页面退出）：不再保存，免得退出动画期间再点一次多弹一层返回栈。 */
    val finished: Boolean = false,
) {
    val editable: Boolean get() = !loading && original != null && !finished
}

sealed interface InstanceNameEvent {
    data class Saved(val instance: Instance?) : InstanceNameEvent

    data class Message(val text: UiText) : InstanceNameEvent
}

/** 改实例名（renameInstance）：1–64 个字，用户起的名字，不标 AI 生成。 */
class InstanceNameViewModel(
    private val service: ThinktinService,
    private val instanceId: String,
) : ViewModel() {
    private val state = MutableStateFlow(InstanceNameUiState())
    val uiState: StateFlow<InstanceNameUiState> = state.asStateFlow()

    private val eventChannel = Channel<InstanceNameEvent>(Channel.BUFFERED)
    val events: Flow<InstanceNameEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    /** 先用缓存预填，再联网取最新的名字。 */
    fun load() {
        state.update { it.copy(loading = it.original == null, loadError = null) }
        viewModelScope.launch {
            if (state.value.original == null) {
                service.cachedInstances().firstOrNull { it.id == instanceId && it.state != InstanceState.Deleted }
                    ?.let { cached -> prefill(cached.name) }
            }
            try {
                val instance = service.instance(instanceId)
                // 用户已经改过输入框就不覆盖。
                val s = state.value
                if (s.original == null || s.name == s.original) {
                    state.update { it.copy(name = instance.name) }
                }
                state.update { it.copy(loading = false, original = instance.name) }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    private fun prefill(name: String) {
        state.update { it.copy(loading = false, original = name, name = name) }
    }

    fun onNameChange(name: String) {
        state.update { it.copy(name = name, error = null) }
    }

    fun save() {
        val current = state.value
        if (current.saving || !current.editable) return
        val name = current.name.trim()
        if (name == current.original) {
            state.update { it.copy(finished = true) }
            eventChannel.trySend(InstanceNameEvent.Saved(null))
            return
        }
        InstanceNames.validate(name)?.let { error ->
            state.update { it.copy(error = error) }
            return
        }
        state.update { it.copy(saving = true, error = null) }
        viewModelScope.launch {
            try {
                val updated = service.renameInstance(instanceId, name)
                state.update { it.copy(saving = false, finished = true, original = updated.name, name = updated.name) }
                eventChannel.send(InstanceNameEvent.Saved(updated))
            } catch (e: ServiceError) {
                state.update { it.copy(saving = false) }
                when {
                    e is ServiceError.Api && e.isInvalid ->
                        state.update { it.copy(error = UiText(R.string.instance_name_too_long, listOf(InstanceNames.MAX_LENGTH))) }
                    // 服务端改名目前不返回 409（实例名没有唯一约束），留着防将来加约束。
                    e is ServiceError.Api && (e.code == "conflict" || e.status == 409) ->
                        state.update { it.copy(error = UiText(R.string.adopt_conflict)) }
                    else -> eventChannel.send(InstanceNameEvent.Message(ErrorText.of(e)))
                }
            }
        }
    }
}

/** 改实例名（路由 instance/{instanceId}/name）：独立页面，不用对话框（README“对话框里不放输入框”）。 */
@Composable
fun InstanceNameScreen(instanceId: String, onBack: () -> Unit, onSaved: () -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: InstanceNameViewModel = viewModel(
        key = "instance-name-$instanceId",
        factory = viewModelFactory { initializer { InstanceNameViewModel(service, instanceId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is InstanceNameEvent.Saved -> onSaved()
                is InstanceNameEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    val focus = remember { FocusRequester() }
    LaunchedEffect(state.editable) { if (state.editable) focus.requestFocus() }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.instance_rename),
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
                .consumeWindowInsets(padding)
                .imePadding()
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
        ) {
            val label = stringResource(R.string.instance_name)
            OutlinedTextField(
                value = state.name,
                onValueChange = viewModel::onNameChange,
                label = { Text(label) },
                singleLine = true,
                enabled = state.editable && !state.saving,
                isError = state.error != null,
                supportingText = {
                    Text(state.error?.asString() ?: stringResource(R.string.adopt_name_hint, InstanceNames.MAX_LENGTH))
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { viewModel.save() }),
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focus)
                    .semantics { contentDescription = label },
            )
            PrimaryButton(
                text = stringResource(R.string.action_save),
                onClick = viewModel::save,
                enabled = state.editable,
                loading = state.saving,
                modifier = Modifier.fillMaxWidth(),
            )
            state.loadError?.let { error ->
                Text(
                    text = error.asString(),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
                TextButton(onClick = viewModel::load) { Text(stringResource(R.string.action_retry)) }
            }
        }
    }
}
