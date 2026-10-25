package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.app.settings.serverLocale
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.account.DeleteAccountViewModel
import cn.thinktin.app.ui.account.DeleteStep
import cn.thinktin.app.ui.account.EditNameEvent
import cn.thinktin.app.ui.account.EditNameViewModel
import cn.thinktin.app.ui.devices.DevicesAction
import cn.thinktin.app.ui.devices.DevicesDialog
import cn.thinktin.app.ui.devices.DevicesViewModel
import cn.thinktin.app.ui.login.LoginEvent
import cn.thinktin.app.ui.login.LoginViewModel
import cn.thinktin.app.ui.login.PhoneRegion
import cn.thinktin.app.ui.status.FrozenViewModel
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.User
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * 13.2 的 ViewModel：登录（手机号 → 验证码，倒计时、限频、冻结、网络错误、验证码错误）、设备与账号、冻结页。
 * 倒计时跑在 StandardTestDispatcher 的 TestCoroutineScheduler 上，用虚拟时间推进。
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AuthViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun fake(initial: AuthState = AuthState.SignedOut, locale: String = "zh-CN") =
        FakeThinktinService(initial = initial, userLocale = locale)

    private fun rateLimited(secs: Long?) = ServiceError.Api(429, "rate_limited", "too many codes requested", secs)

    // ---- 手机号 ----

    @Test
    fun phoneRegionsValidateAndBuildE164() {
        val cn = PhoneRegion.ChinaMainland
        assertTrue(cn.isValid("138 0013 8000"))
        assertEquals("+8613800138000", cn.e164("138-0013-8000"))
        assertEquals("+86 13800138000", cn.display("138 0013 8000"))
        assertFalse("10 位", cn.isValid("1380013800"))
        assertFalse("不是 1 开头", cn.isValid("23800138000"))
        assertEquals(PhoneRegion.ChinaMainland, PhoneRegion.Default)
        // 别的地区：长途前缀 0 去掉
        assertTrue(PhoneRegion.HongKong.isValid("91234567"))
        assertEquals("+85291234567", PhoneRegion.HongKong.e164("9123 4567"))
        assertTrue(PhoneRegion.Japan.isValid("090-1234-5678"))
        assertEquals("+819012345678", PhoneRegion.Japan.e164("090-1234-5678"))
        assertFalse(PhoneRegion.UnitedStates.isValid("12345"))
        // 都在服务端 E.164 的 8–15 位里
        PhoneRegion.entries.forEach { region ->
            val digits = region.dialCode.length + region.lengths.last
            assertTrue("${region.name} 太长", digits in 8..15)
        }
    }

    @Test
    fun invalidPhoneShowsFieldErrorWithoutSending() = test {
        val service = fake()
        val vm = LoginViewModel(service)
        vm.onPhoneChange("12345")
        vm.requestCode()
        runCurrent()
        assertEquals(UiText(R.string.login_phone_invalid), vm.uiState.value.phoneError)
        assertTrue(service.sentCodes.isEmpty())
        // 改号码清掉提示；非数字字符不收
        vm.onPhoneChange("138abc")
        assertEquals("138", vm.uiState.value.phone)
        assertNull(vm.uiState.value.phoneError)
    }

    @Test
    fun sendCodeStartsSixtySecondCountdown() = test {
        val service = fake()
        val vm = LoginViewModel(service)
        vm.events.test {
            vm.onPhoneChange("13800138000")
            vm.requestCode()
            runCurrent()
            assertEquals(LoginEvent.ShowCodeStep, awaitItem())
            assertEquals(listOf("+8613800138000"), service.sentCodes)
            val state = vm.uiState.value
            assertEquals("+8613800138000", state.sentTo)
            assertEquals("+86 13800138000", state.sentToDisplay)
            assertEquals(60, state.cooldownSecs)
            assertFalse(state.canResend)

            advanceTimeBy(1_000)
            runCurrent()
            assertEquals(59, vm.uiState.value.cooldownSecs)

            // 同一个号码还在重发间隔里：回验证码页，不再发
            vm.requestCode()
            assertEquals(LoginEvent.ShowCodeStep, awaitItem())
            assertEquals(1, service.sentCodes.size)

            advanceTimeBy(59_000)
            runCurrent()
            assertEquals(0, vm.uiState.value.cooldownSecs)
            assertTrue(vm.uiState.value.canResend)
            vm.resend()
            runCurrent()
            assertEquals(LoginEvent.Message(UiText(R.string.login_code_resent)), awaitItem())
            assertEquals(2, service.sentCodes.size)
            assertEquals(60, vm.uiState.value.cooldownSecs)
        }
    }

    @Test
    fun rateLimitedSendCountsDownRemainingSeconds() = test {
        val service = fake()
        service.failNext("sendCode", rateLimited(42))
        val vm = LoginViewModel(service)
        vm.onPhoneChange("13800138000")
        vm.requestCode()
        runCurrent()
        var state = vm.uiState.value
        assertTrue(state.rateLimited)
        assertEquals(42, state.cooldownSecs)
        assertTrue(state.coolingDown)
        assertFalse("限频中同一个号码不能再点", state.canRequestCode)
        assertNull("没有发出去", state.sentTo)

        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(40, vm.uiState.value.cooldownSecs)

        // 限频按号码算：换个号码可以马上发
        vm.onPhoneChange("13900139000")
        assertTrue(vm.uiState.value.canRequestCode)
        vm.onPhoneChange("13800138000")

        advanceTimeBy(40_000)
        runCurrent()
        state = vm.uiState.value
        assertEquals(0, state.cooldownSecs)
        assertFalse(state.rateLimited)
        assertTrue(state.canRequestCode)
    }

    @Test
    fun rateLimitedWithoutSecondsShowsPlainText() = test {
        val service = fake()
        service.failNext("sendCode", rateLimited(null))
        val vm = LoginViewModel(service)
        vm.onPhoneChange("13800138000")
        vm.requestCode()
        runCurrent()
        assertEquals(UiText(R.string.error_rate_limited_plain), vm.uiState.value.phoneError)
    }

    @Test
    fun networkErrorOffersRetry() = test {
        val service = fake()
        service.failNext("sendCode", ServiceError.Network("timeout"))
        val vm = LoginViewModel(service)
        vm.events.test {
            vm.onPhoneChange("13800138000")
            vm.requestCode()
            runCurrent()
            val message = awaitItem() as LoginEvent.Message
            assertEquals(UiText(R.string.error_network), message.text)
            assertFalse(vm.uiState.value.sending)
            // Snackbar 的“重试”：再发一次，成功进验证码页
            message.retry!!.invoke()
            runCurrent()
            assertEquals(LoginEvent.ShowCodeStep, awaitItem())
            assertEquals(2, service.sentCodes.size)
        }
    }

    @Test
    fun invalidPhoneFromServerIsFieldLevel() = test {
        val service = fake()
        service.failNext("sendCode", ServiceError.Api(422, "invalid", "invalid phone number", null))
        val vm = LoginViewModel(service)
        vm.onPhoneChange("13800138000")
        vm.requestCode()
        runCurrent()
        assertEquals(UiText(R.string.login_phone_invalid), vm.uiState.value.phoneError)
    }

    // ---- 验证码 ----

    private suspend fun TestScope.codeStep(service: FakeThinktinService, signedIn: MutableList<User> = mutableListOf()): LoginViewModel {
        val vm = LoginViewModel(service, onSignedIn = { signedIn += it })
        vm.onPhoneChange("13800138000")
        vm.requestCode()
        runCurrent()
        return vm
    }

    @Test
    fun sixDigitsSubmitAutomaticallyAndSignIn() = test {
        val service = fake()
        val signedIn = mutableListOf<User>()
        val vm = codeStep(service, signedIn)
        vm.onCodeChange("12a345")
        assertEquals("只收数字", "12345", vm.uiState.value.code)
        runCurrent()
        assertTrue("不满 6 位不提交", service.logins.isEmpty())
        vm.onCodeChange("1234567")
        assertEquals("最多 6 位", "123456", vm.uiState.value.code)
        runCurrent()
        assertEquals(listOf("+8613800138000" to "123456"), service.logins)
        assertEquals(AuthState.SignedIn, service.authState.value)
        assertEquals("+8613800138000", signedIn.single().phone)
        assertFalse(vm.uiState.value.verifying)
    }

    @Test
    fun wrongCodeClearsAndShowsError() = test {
        val service = fake()
        val vm = codeStep(service)
        vm.onCodeChange("000000")
        runCurrent()
        assertEquals(UiText(R.string.login_code_invalid), vm.uiState.value.codeError)
        assertEquals("", vm.uiState.value.code)
        assertEquals(AuthState.SignedOut, service.authState.value)
        // 再输就清掉提示
        vm.onCodeChange("1")
        assertNull(vm.uiState.value.codeError)
    }

    @Test
    fun frozenAccountGoesToFrozenPage() = test {
        val service = fake()
        val vm = codeStep(service)
        vm.events.test {
            assertEquals(LoginEvent.ShowCodeStep, awaitItem())
            service.failNext("login", ServiceError.AccountFrozen())
            vm.onCodeChange("123456")
            runCurrent()
            assertEquals(LoginEvent.Frozen, awaitItem())
        }
        assertEquals(AuthState.SignedOut, service.authState.value)
    }

    @Test
    fun rateLimitedLoginShowsSecondsOnCode() = test {
        val service = fake()
        val vm = codeStep(service)
        service.failNext("login", rateLimited(3600))
        vm.onCodeChange("123456")
        runCurrent()
        assertEquals(UiText(R.string.error_rate_limited, listOf(3600)), vm.uiState.value.codeError)
        assertEquals("验证码保留，过一会儿再点登录", "123456", vm.uiState.value.code)
    }

    @Test
    fun networkErrorOnLoginRetries() = test {
        val service = fake()
        val vm = codeStep(service)
        vm.events.test {
            assertEquals(LoginEvent.ShowCodeStep, awaitItem())
            service.failNext("login", ServiceError.Network("reset"))
            vm.onCodeChange("123456")
            runCurrent()
            val message = awaitItem() as LoginEvent.Message
            assertEquals(UiText(R.string.error_network), message.text)
            message.retry!!.invoke()
            runCurrent()
            assertEquals(AuthState.SignedIn, service.authState.value)
            assertEquals(2, service.logins.size)
        }
    }

    @Test
    fun resetStartsOver() = test {
        val vm = codeStep(fake())
        vm.reset()
        val state = vm.uiState.value
        assertNull(state.sentTo)
        assertEquals("", state.phone)
        assertEquals(0, state.cooldownSecs)
        advanceUntilIdle()
        assertEquals(0, vm.uiState.value.cooldownSecs)
    }

    @Test
    fun serverLocaleFollowsAppLanguage() {
        assertEquals("zh-CN", AppLanguage.Chinese.serverLocale("en"))
        assertEquals("en", AppLanguage.English.serverLocale("zh"))
        assertEquals("zh-CN", AppLanguage.System.serverLocale("zh"))
        assertEquals("en", AppLanguage.System.serverLocale("ja"))
    }

    // ---- 冻结页 ----

    @Test
    fun frozenCheckAgainAndSignOut() = test {
        val service = fake(initial = AuthState.Frozen)
        val vm = FrozenViewModel(service)
        vm.messages.test {
            service.failNext("me", ServiceError.AccountFrozen())
            vm.checkAgain()
            runCurrent()
            assertEquals(UiText(R.string.frozen_still), awaitItem())
            assertFalse(vm.uiState.value.checking)
            service.failNext("me", ServiceError.Network("timeout"))
            vm.checkAgain()
            runCurrent()
            assertEquals(UiText(R.string.error_network), awaitItem())
            assertEquals(AuthState.Frozen, service.authState.value)
            // 服务端已解冻：取资料成功，服务回到已登录，不提示
            vm.checkAgain()
            runCurrent()
            expectNoEvents()
            assertEquals(AuthState.SignedIn, service.authState.value)
            assertFalse(vm.uiState.value.checking)
        }
        vm.signOut()
        runCurrent()
        assertEquals(1, service.logoutCalls)
        assertEquals(AuthState.SignedOut, service.authState.value)
    }

    // ---- 验证码页重新获取的失败路径 ----

    @Test
    fun resendRateLimitedCountsDownKeepsCode() = test {
        val service = fake()
        val vm = codeStep(service)
        advanceTimeBy(60_000)
        runCurrent()
        vm.onCodeChange("12")
        service.failNext("sendCode", rateLimited(30))
        vm.resend()
        runCurrent()
        var state = vm.uiState.value
        assertTrue(state.rateLimited)
        assertEquals(30, state.cooldownSecs)
        assertFalse(state.canResend)
        assertEquals("+8613800138000", state.sentTo)
        assertEquals("验证码保留", "12", state.code)
        advanceTimeBy(30_000)
        runCurrent()
        state = vm.uiState.value
        assertEquals(0, state.cooldownSecs)
        assertFalse(state.rateLimited)
        assertTrue(state.canResend)
    }

    @Test
    fun resendRateLimitedWithoutSecondsShowsCodeError() = test {
        val service = fake()
        val vm = codeStep(service)
        advanceTimeBy(60_000)
        runCurrent()
        service.failNext("sendCode", rateLimited(null))
        vm.resend()
        runCurrent()
        assertEquals(UiText(R.string.error_rate_limited_plain), vm.uiState.value.codeError)
        assertNull(vm.uiState.value.phoneError)
        assertTrue(vm.uiState.value.canResend)
    }

    @Test
    fun resendNetworkErrorOffersRetry() = test {
        val service = fake()
        val vm = codeStep(service)
        vm.events.test {
            assertEquals(LoginEvent.ShowCodeStep, awaitItem())
            advanceTimeBy(60_000)
            runCurrent()
            service.failNext("sendCode", ServiceError.Network("timeout"))
            vm.resend()
            runCurrent()
            val message = awaitItem() as LoginEvent.Message
            assertEquals(UiText(R.string.error_network), message.text)
            assertEquals(2, service.sentCodes.size)
            message.retry!!.invoke()
            runCurrent()
            assertEquals(LoginEvent.Message(UiText(R.string.login_code_resent)), awaitItem())
            assertEquals(3, service.sentCodes.size)
            assertEquals(60, vm.uiState.value.cooldownSecs)
        }
    }

    // ---- 设备与账号 ----

    private fun devices(service: FakeThinktinService = fake(AuthState.SignedIn), action: DevicesAction? = null) =
        DevicesViewModel(service, action)

    @Test
    fun devicesLoadUserAndList() = test {
        val vm = devices()
        runCurrent()
        val state = vm.uiState.value
        assertFalse(state.loading)
        assertEquals("演示用户", state.user?.displayName)
        assertEquals(listOf("Pixel 8", "MacBook Air", "iPhone 15"), state.devices.map { it.name })
        assertTrue(state.devices.first().current)
    }

    @Test
    fun devicesLoadErrorThenRetry() = test {
        val service = fake(AuthState.SignedIn)
        service.failNext("devices", ServiceError.Network("timeout"))
        val vm = devices(service)
        runCurrent()
        assertEquals(UiText(R.string.error_network), vm.uiState.value.loadError)
        vm.refresh()
        runCurrent()
        assertNull(vm.uiState.value.loadError)
        assertEquals(3, vm.uiState.value.devices.size)
    }

    @Test
    fun revokeDeviceAfterConfirm() = test {
        val vm = devices()
        runCurrent()
        val iphone = vm.uiState.value.devices.first { it.name == "iPhone 15" }
        vm.messages.test {
            vm.askRevoke(iphone)
            assertEquals(DevicesDialog.Revoke(iphone), vm.uiState.value.dialog)
            vm.confirmRevoke()
            runCurrent()
            assertEquals(UiText(R.string.devices_revoked, listOf("iPhone 15")), awaitItem())
        }
        assertNull(vm.uiState.value.dialog)
        assertTrue(vm.uiState.value.devices.none { it.name == "iPhone 15" })
    }

    @Test
    fun signOutOthersNeedsTwoConfirmations() = test {
        val vm = devices()
        runCurrent()
        vm.messages.test {
            vm.askSignOutOthers()
            vm.setStopAgents(true)
            vm.confirmSignOutOthers()
            assertEquals(DevicesDialog.SignOutOthers(stopAgents = true, confirming = true), vm.uiState.value.dialog)
            vm.confirmSignOutOthers()
            runCurrent()
            val message = awaitItem()
            assertEquals(R.string.devices_signed_out_others_and_stopped, message.resId)
            assertEquals(2L, message.args[0])
        }
        assertNull(vm.uiState.value.dialog)
        assertEquals(listOf("Pixel 8"), vm.uiState.value.devices.map { it.name })
    }

    @Test
    fun signOutOthersWithoutStopping() = test {
        val vm = devices()
        runCurrent()
        vm.messages.test {
            vm.askSignOutOthers()
            vm.confirmSignOutOthers()
            vm.confirmSignOutOthers()
            runCurrent()
            assertEquals(UiText(R.string.devices_signed_out_others, listOf(2L)), awaitItem())
        }
    }

    @Test
    fun stopAllShowsCounts() = test {
        val vm = devices()
        runCurrent()
        vm.askStopAll()
        vm.confirmStopAll()
        assertEquals(DevicesDialog.StopAll(confirming = true), vm.uiState.value.dialog)
        vm.confirmStopAll()
        runCurrent()
        val done = vm.uiState.value.dialog as DevicesDialog.StopAllDone
        assertTrue(done.result.runsCancelled > 0)
        assertTrue(done.result.plansPaused > 0)
        vm.dismissDialog()
        assertNull(vm.uiState.value.dialog)
    }

    @Test
    fun stopAllErrorClosesDialogWithMessage() = test {
        val service = fake(AuthState.SignedIn)
        val vm = devices(service)
        runCurrent()
        service.failNext("stopAll", ServiceError.Network("timeout"))
        vm.messages.test {
            vm.askStopAll()
            vm.confirmStopAll()
            vm.confirmStopAll()
            runCurrent()
            assertEquals(UiText(R.string.error_network), awaitItem())
        }
        assertNull(vm.uiState.value.dialog)
        assertFalse(vm.uiState.value.busy)
    }

    @Test
    fun logoutSignsOutThisDeviceOnly() = test {
        val service = fake(AuthState.SignedIn)
        val vm = devices(service)
        runCurrent()
        vm.askLogout()
        vm.confirmLogout()
        runCurrent()
        assertEquals(1, service.logoutCalls)
        assertEquals(AuthState.SignedOut, service.authState.value)
    }

    @Test
    fun editNicknamePrefillsAndSaves() = test {
        val service = fake(AuthState.SignedIn)
        val vm = EditNameViewModel(service)
        runCurrent()
        assertEquals("预填现在的昵称", "演示用户", vm.uiState.value.name)
        assertFalse(vm.uiState.value.loading)
        vm.onNameChange("x".repeat(65))
        vm.save()
        assertEquals(UiText(R.string.profile_name_too_long, listOf(64)), vm.uiState.value.error)
        vm.events.test {
            vm.onNameChange("  小陈  ")
            vm.save()
            runCurrent()
            assertEquals(EditNameEvent.Saved, awaitItem())
            assertEquals("小陈", service.me().displayName)
            // 清空 = 去掉昵称
            vm.onNameChange("")
            vm.save()
            runCurrent()
            assertEquals(EditNameEvent.Saved, awaitItem())
            assertNull(service.me().displayName)
        }
    }

    @Test
    fun editNicknameLoadFailureBlocksSaveUntilRetry() = test {
        val service = fake(AuthState.SignedIn)
        service.failNext("me", ServiceError.Network("timeout"))
        val vm = EditNameViewModel(service)
        runCurrent()
        var state = vm.uiState.value
        assertFalse(state.loading)
        assertEquals(UiText(R.string.error_network), state.loadError)
        assertFalse("加载失败不能编辑", state.editable)
        // 空输入点保存：不能清掉原来的昵称
        vm.save()
        runCurrent()
        assertTrue(service.updatedNames.isEmpty())
        assertEquals("演示用户", service.me().displayName)
        // 重试成功后可以编辑
        vm.load()
        runCurrent()
        state = vm.uiState.value
        assertNull(state.loadError)
        assertTrue(state.editable)
        assertEquals("演示用户", state.name)
    }

    @Test
    fun editNicknameUnchangedSkipsRequest() = test {
        val service = fake(AuthState.SignedIn)
        val vm = EditNameViewModel(service)
        runCurrent()
        vm.events.test {
            vm.onNameChange(" 演示用户 ")
            vm.save()
            runCurrent()
            assertEquals(EditNameEvent.Saved, awaitItem())
        }
        assertTrue(service.updatedNames.isEmpty())
    }

    @Test
    fun editNicknameSaveErrors() = test {
        val service = fake(AuthState.SignedIn)
        val vm = EditNameViewModel(service)
        runCurrent()
        vm.events.test {
            service.failNext("updateProfile", ServiceError.Api(422, "invalid", "display name too long", null))
            vm.onNameChange("小陈")
            vm.save()
            runCurrent()
            assertEquals(UiText(R.string.profile_name_too_long, listOf(64)), vm.uiState.value.error)
            assertFalse(vm.uiState.value.saving)
            service.failNext("updateProfile", ServiceError.Network("timeout"))
            vm.save()
            runCurrent()
            assertEquals(EditNameEvent.Message(UiText(R.string.error_network)), awaitItem())
            assertFalse(vm.uiState.value.saving)
            assertEquals("演示用户", service.me().displayName)
        }
    }

    @Test
    fun revokeDeviceErrorClosesDialogWithMessage() = test {
        val service = fake(AuthState.SignedIn)
        val vm = devices(service)
        runCurrent()
        val iphone = vm.uiState.value.devices.first { it.name == "iPhone 15" }
        service.failNext("revokeDevice", ServiceError.Network("timeout"))
        vm.messages.test {
            vm.askRevoke(iphone)
            vm.confirmRevoke()
            runCurrent()
            assertEquals(UiText(R.string.error_network), awaitItem())
        }
        assertNull(vm.uiState.value.dialog)
        assertFalse(vm.uiState.value.busy)
        assertTrue(vm.uiState.value.devices.any { it.name == "iPhone 15" })
    }

    @Test
    fun signOutOthersErrorClosesDialogWithMessage() = test {
        val service = fake(AuthState.SignedIn)
        val vm = devices(service)
        runCurrent()
        service.failNext("signOutOtherDevices", ServiceError.Network("timeout"))
        vm.messages.test {
            vm.askSignOutOthers()
            vm.confirmSignOutOthers()
            vm.confirmSignOutOthers()
            runCurrent()
            assertEquals(UiText(R.string.error_network), awaitItem())
        }
        assertNull(vm.uiState.value.dialog)
        assertFalse(vm.uiState.value.busy)
        assertEquals(3, vm.uiState.value.devices.size)
    }

    @Test
    fun deleteAccountNetworkErrorKeepsCode() = test {
        val service = fake(AuthState.SignedIn)
        val vm = DeleteAccountViewModel(service)
        vm.sendCode()
        runCurrent()
        vm.onCodeChange("123456")
        vm.next()
        service.failNext("deleteAccount", ServiceError.Network("timeout"))
        vm.confirm()
        runCurrent()
        var state = vm.uiState.value
        assertEquals("非验证码错误：留在最后确认", DeleteStep.Confirm, state.step)
        assertEquals("123456", state.code)
        assertEquals(UiText(R.string.error_network), state.error)
        assertFalse(state.busy)
        assertEquals(AuthState.SignedIn, service.authState.value)
        // 再点一次就成功
        vm.confirm()
        runCurrent()
        state = vm.uiState.value
        assertNull(state.error)
        assertEquals("123456", service.deletedWith)
        assertEquals(AuthState.SignedOut, service.authState.value)
    }

    @Test
    fun initialActionsOpenDialogs() = test {
        assertEquals(DevicesDialog.SignOutOthers(), devices(action = DevicesAction.SignOutOthers).uiState.value.dialog)
        assertEquals(DevicesDialog.StopAll(), devices(action = DevicesAction.StopAll).uiState.value.dialog)
        assertEquals(DevicesAction.StopAll, DevicesAction.fromWire("stop_all"))
        assertNull(DevicesAction.fromWire("nope"))
        assertNull(devices().uiState.value.dialog)
        runCurrent()
    }

    @Test
    fun deleteAccountThreeSteps() = test {
        val service = fake(AuthState.SignedIn)
        val vm = DeleteAccountViewModel(service)
        assertEquals(DeleteStep.Explain, vm.uiState.value.step)
        // 第一步：发验证码
        vm.sendCode()
        runCurrent()
        assertEquals(DeleteStep.Code, vm.uiState.value.step)
        assertEquals(1, service.selfCodes)
        assertEquals(60, vm.uiState.value.resendInSecs)
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(50, vm.uiState.value.resendInSecs)
        vm.sendCode()
        assertEquals("倒计时中不能重发", 1, service.selfCodes)
        // 第二步：不满 6 位不能下一步
        vm.onCodeChange("12a3")
        assertEquals("123", vm.uiState.value.code)
        vm.next()
        assertEquals(DeleteStep.Code, vm.uiState.value.step)
        assertEquals(UiText(R.string.login_code_incomplete), vm.uiState.value.error)
        // 验证码错：第三步确认后回到第二步重填
        vm.onCodeChange("000000")
        vm.next()
        assertEquals(DeleteStep.Confirm, vm.uiState.value.step)
        vm.confirm()
        runCurrent()
        assertEquals(DeleteStep.Code, vm.uiState.value.step)
        assertEquals(UiText(R.string.login_code_invalid), vm.uiState.value.error)
        assertEquals("", vm.uiState.value.code)
        assertEquals(AuthState.SignedIn, service.authState.value)
        // 第三步可以退回第二步
        vm.onCodeChange("123456")
        vm.next()
        vm.back()
        assertEquals(DeleteStep.Code, vm.uiState.value.step)
        vm.next()
        vm.confirm()
        runCurrent()
        assertEquals("123456", service.deletedWith)
        assertEquals(AuthState.SignedOut, service.authState.value)
        assertEquals(0, vm.uiState.value.resendInSecs)
    }

    @Test
    fun deleteAccountRateLimitedCodeAndDemo() = test {
        val service = fake(AuthState.SignedIn)
        val vm = DeleteAccountViewModel(service)
        service.failNext("sendSelfCode", rateLimited(30))
        vm.sendCode()
        runCurrent()
        assertEquals(DeleteStep.Code, vm.uiState.value.step)
        assertEquals(UiText(R.string.error_rate_limited, listOf(30)), vm.uiState.value.error)
        assertEquals(30, vm.uiState.value.resendInSecs)
        // 网络错误：留在原地提示
        val other = DeleteAccountViewModel(service)
        service.failNext("sendSelfCode", ServiceError.Network("timeout"))
        other.sendCode()
        runCurrent()
        assertEquals(DeleteStep.Explain, other.uiState.value.step)
        assertEquals(UiText(R.string.error_network), other.uiState.value.error)
        // 演示模式不能注销
        val demo = DeleteAccountViewModel(MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }))
        assertTrue(demo.uiState.value.isDemo)
        demo.sendCode()
        runCurrent()
        assertEquals(DeleteStep.Explain, demo.uiState.value.step)
    }
}
