package cn.thinktin.app.ui.approval

import android.content.Context
import android.os.Build
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import cn.thinktin.app.R
import cn.thinktin.data.model.OptionKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/*
 * 批准审批前的身份确认（第 8.5 节）：BiometricPrompt，允许强生物识别或锁屏凭证（PIN / 图案 / 密码），
 * 没有生物识别时退到锁屏密码；设备没有任何锁屏凭证时不许批准，提示先设置。拒绝不用验证。
 *
 * 做成接口是为了注入：JVM / Robolectric 测试里用假的（BiometricPrompt 要真的系统界面）。
 */

/** 能不能做身份确认。 */
enum class GateAvailability {
    Available,

    /** 设备没有设置锁屏凭证（也没有录入生物识别）：提示先去系统设置里设置。 */
    NoCredential,

    /** 设备做不了（硬件不可用、要安全更新、系统不支持）：不能批准，只能拒绝。 */
    Unavailable,
}

/** 身份确认的结果。 */
enum class GateResult {
    Success,

    /** 用户取消了（返回键、点了外面、系统取消）：什么都不发。 */
    Cancelled,

    /** 没有锁屏凭证。 */
    NoCredential,

    /** 失败次数太多被锁定：稍后再试。 */
    Lockout,

    /** 其他错误（硬件不可用、超时……）。 */
    Error,
}

/** 要确认的是什么（提示框里显示：选项和 agent 写的审批标题）。 */
data class GateRequest(val approvalTitle: String?, val optionKind: OptionKind, val optionName: String)

interface ApprovalGate {
    fun availability(): GateAvailability

    /** 弹出确认；在主线程上显示，挂起到有结果。协程被取消时收起提示框。 */
    suspend fun authenticate(request: GateRequest): GateResult
}


/**
 * 真实的实现：androidx.biometric 的 BiometricPrompt。[activity] 给出当前的 Activity（AppContainer 记着
 * MainActivity 的弱引用：旋转屏幕后 ViewModel 还在、Activity 换了，不能把 Activity 存进 ViewModel）；
 * 没有 Activity 时做不了。
 *
 * 允许的认证方式是 `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`；只有 API 28–29 系统不支持这个组合
 * （androidx.biometric 的限制），那两个版本用 `BIOMETRIC_WEAK or DEVICE_CREDENTIAL`（仍然可以用锁屏密码）。
 * 云端审批服务端不验签（第 8.5 节），这里确认的是“本人在场”，不是密钥签名（那是 13.9）。
 */
class BiometricApprovalGate(
    private val activity: () -> FragmentActivity?,
    private val sdkInt: Int = Build.VERSION.SDK_INT,
) : ApprovalGate {
    private val authenticators: Int = authenticatorsFor(sdkInt)

    override fun availability(): GateAvailability {
        val current = activity() ?: return GateAvailability.Unavailable
        return availabilityOf(BiometricManager.from(current).canAuthenticate(authenticators))
    }

    override suspend fun authenticate(request: GateRequest): GateResult = withContext(Dispatchers.Main.immediate) {
        val activity = activity()?.takeUnless { it.isFinishing || it.isDestroyed } ?: return@withContext GateResult.Error
        when (availabilityOf(BiometricManager.from(activity).canAuthenticate(authenticators))) {
            GateAvailability.NoCredential -> return@withContext GateResult.NoCredential
            GateAvailability.Unavailable -> return@withContext GateResult.Error
            GateAvailability.Available -> Unit
        }
        suspendCancellableCoroutine { cont ->
            val callback = object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (cont.isActive) cont.resume(GateResult.Success)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    // errString 是系统写的、可能是另一种语言：只进日志，界面用本地文案。
                    Log.i(TAG, "BiometricPrompt error $errorCode")
                    if (cont.isActive) cont.resume(resultOf(errorCode))
                }

                // onAuthenticationFailed：一次没认出来（指纹不对），提示框还在，等用户再试，不用处理。
            }
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle(activity.getString(R.string.approval_gate_title))
                .setSubtitle(activity.getString(R.string.approval_gate_subtitle, optionText(activity, request)))
                .apply {
                    // agent 写的标题：标 AI 生成（第 8.4 节）。
                    request.approvalTitle?.takeIf { it.isNotBlank() }?.let {
                        setDescription(activity.getString(cn.thinktin.design.R.string.design_ai_generated) + it.take(MAX_DESCRIPTION))
                    }
                }
                .setAllowedAuthenticators(authenticators)
                // 允许锁屏凭证时不能设“取消”按钮（系统提示框自带），也不要求显式确认（人脸识别后直接通过）。
                .setConfirmationRequired(false)
                .build()
            prompt.authenticate(info)
            cont.invokeOnCancellation { activity.runOnUiThread { prompt.cancelAuthentication() } }
        }
    }

    companion object {
        private const val TAG = "ApprovalGate"
        private const val MAX_DESCRIPTION = 200

        /** 允许的认证方式（见类的说明）。 */
        fun authenticatorsFor(sdkInt: Int): Int =
            if (sdkInt == Build.VERSION_CODES.P || sdkInt == Build.VERSION_CODES.Q) {
                BIOMETRIC_WEAK or DEVICE_CREDENTIAL
            } else {
                BIOMETRIC_STRONG or DEVICE_CREDENTIAL
            }

        /** BiometricManager.canAuthenticate 的结果 → 能不能确认。 */
        fun availabilityOf(code: Int): GateAvailability = when (code) {
            BiometricManager.BIOMETRIC_SUCCESS -> GateAvailability.Available
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> GateAvailability.NoCredential
            // 允许锁屏凭证时，没有生物识别硬件也能用密码；这几种是连凭证也用不了。
            else -> GateAvailability.Unavailable
        }

        /** onAuthenticationError 的错误码 → 结果。 */
        fun resultOf(errorCode: Int): GateResult = when (errorCode) {
            BiometricPrompt.ERROR_USER_CANCELED,
            BiometricPrompt.ERROR_NEGATIVE_BUTTON,
            BiometricPrompt.ERROR_CANCELED,
            -> GateResult.Cancelled
            BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL,
            BiometricPrompt.ERROR_NO_BIOMETRICS,
            -> GateResult.NoCredential
            BiometricPrompt.ERROR_LOCKOUT,
            BiometricPrompt.ERROR_LOCKOUT_PERMANENT,
            -> GateResult.Lockout
            else -> GateResult.Error
        }

        private fun optionText(context: Context, request: GateRequest): String = when (request.optionKind) {
            OptionKind.AllowOnce -> context.getString(cn.thinktin.design.R.string.design_approval_allow_once)
            OptionKind.AllowAlways -> context.getString(cn.thinktin.design.R.string.design_approval_allow_always)
            OptionKind.RejectOnce -> context.getString(cn.thinktin.design.R.string.design_approval_reject_once)
            OptionKind.RejectAlways -> context.getString(cn.thinktin.design.R.string.design_approval_reject_always)
            OptionKind.Unknown -> request.optionName
        }
    }
}
