package cn.thinktin.app.ui.account

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.isInvalid
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

data class EditNameUiState(
    val loading: Boolean = true,
    val name: String = "",
    val error: UiText? = null,
    val saving: Boolean = false,
)

sealed interface EditNameEvent {
    data object Saved : EditNameEvent

    data class Message(val text: UiText) : EditNameEvent
}

/** 改昵称（updateProfile）：清空 = 去掉昵称；服务端限 1–64 个字。 */
class EditNameViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(EditNameUiState())
    val uiState: StateFlow<EditNameUiState> = state.asStateFlow()

    private val eventChannel = Channel<EditNameEvent>(Channel.BUFFERED)
    val events: Flow<EditNameEvent> = eventChannel.receiveAsFlow()

    init {
        viewModelScope.launch {
            val current = try {
                service.me().displayName.orEmpty()
            } catch (e: ServiceError) {
                eventChannel.send(EditNameEvent.Message(ErrorText.of(e)))
                ""
            }
            // 用户已经开始输入就不覆盖。
            state.update { if (it.loading && it.name.isEmpty()) it.copy(loading = false, name = current) else it.copy(loading = false) }
        }
    }

    fun onNameChange(name: String) {
        state.update { it.copy(name = name, error = null) }
    }

    fun save() {
        val current = state.value
        if (current.saving) return
        val name = current.name.trim()
        if (name.codePointCount(0, name.length) > MAX_NAME_LENGTH) {
            state.update { it.copy(error = UiText(R.string.profile_name_too_long, listOf(MAX_NAME_LENGTH))) }
            return
        }
        state.update { it.copy(saving = true, error = null) }
        viewModelScope.launch {
            try {
                service.updateProfile(name.ifEmpty { null })
                state.update { it.copy(saving = false) }
                eventChannel.send(EditNameEvent.Saved)
            } catch (e: ServiceError) {
                state.update { it.copy(saving = false) }
                if (e is ServiceError.Api && e.isInvalid) {
                    state.update { it.copy(error = UiText(R.string.profile_name_too_long, listOf(MAX_NAME_LENGTH))) }
                } else {
                    eventChannel.send(EditNameEvent.Message(ErrorText.of(e)))
                }
            }
        }
    }

    companion object {
        /** 昵称上限（服务端 1–64 个字符）。 */
        const val MAX_NAME_LENGTH: Int = 64
    }
}

/** 改昵称页（路由 account/name）。保存成功后返回，上一页在显示时重新取资料。 */
@Composable
fun EditNameScreen(onBack: () -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: EditNameViewModel = viewModel(factory = viewModelFactory { initializer { EditNameViewModel(service) } })
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                // 返回后上一页重新取资料，显示新昵称。
                EditNameEvent.Saved -> onBack()
                is EditNameEvent.Message ->
                    snackbar.showSnackbar(context.getString(event.text.resId, *event.text.args.toTypedArray()))
            }
        }
    }
    val focus = remember { FocusRequester() }
    LaunchedEffect(state.loading) { if (!state.loading) focus.requestFocus() }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.profile_name_edit),
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
                .imePadding()
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
        ) {
            val label = stringResource(R.string.profile_name)
            OutlinedTextField(
                value = state.name,
                onValueChange = viewModel::onNameChange,
                label = { Text(label) },
                singleLine = true,
                enabled = !state.loading && !state.saving,
                isError = state.error != null,
                supportingText = { Text(state.error?.asString() ?: stringResource(R.string.profile_name_hint)) },
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
                enabled = !state.loading,
                loading = state.saving,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
