package cn.thinktin.app.computer

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import cn.thinktin.app.R
import cn.thinktin.data.model.DeviceSigner
import cn.thinktin.data.model.DeviceSignerException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.ProviderException
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Keystore 里的签名密钥（13.9，docs/pairing.md 第 1 节），和 iOS 的 SecureEnclaveSigner 一样：
 *
 * - AndroidKeyStore 里的 P-256 私钥，不出安全硬件；有 StrongBox（独立安全芯片）就放进去，没有退到 TEE。
 * - 每次签名都要强生物识别（`BIOMETRIC_STRONG`，不接受锁屏密码）：密钥设成每次使用都要验证，签名对象经
 *   BiometricPrompt 的 CryptoObject 交给系统，验过才能签。签的是 SHA256withECDSA，输出 DER。
 * - `setInvalidatedByBiometricEnrollment`：录入了新的指纹、人脸，系统让密钥永久失效（[DeviceSignerException.KeyInvalidated]，
 *   要重新生成、重新配对），别人加了自己的指纹也签不了。
 * - 没录生物识别、没有强生物识别硬件时不可用。
 *
 * BiometricPrompt 要当前的 Activity：[activity] 每次签名时去找（AppContainer 记着 MainActivity 的弱引用）。
 */
class KeystoreSigner(
    context: Context,
    private val activity: () -> FragmentActivity?,
    private val alias: String = DEFAULT_ALIAS,
) : DeviceSigner {
    private val context = context.applicationContext

    override fun isAvailable(): Boolean =
        BiometricManager.from(context).canAuthenticate(BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

    override suspend fun publicKey(): ByteArray = withContext(Dispatchers.IO) {
        val entry = loadOrCreate()
        prepareSignature(entry)
        val key = entry.certificate.publicKey as? ECPublicKey ?: throw DeviceSignerException.KeyInvalidated()
        sec1(key)
    }

    override suspend fun sign(message: ByteArray, reason: String): ByteArray {
        if (!isAvailable()) throw DeviceSignerException.Unavailable()
        val signature = withContext(Dispatchers.IO) { prepareSignature(loadOrCreate()) }
        val unlocked = authenticate(signature, reason)
        return withContext(Dispatchers.IO) {
            try {
                unlocked.update(message)
                unlocked.sign()
            } catch (e: GeneralSecurityException) {
                Log.e(TAG, "signing failed", e)
                throw DeviceSignerException.Failed(e.javaClass.simpleName)
            }
        }
    }

    override suspend fun resetKey() {
        withContext(Dispatchers.IO) {
            try {
                keyStore().deleteEntry(alias)
            } catch (e: GeneralSecurityException) {
                Log.e(TAG, "cannot delete the signing key", e)
                throw DeviceSignerException.Failed(e.javaClass.simpleName)
            }
        }
    }

    // ---- 内部 ----

    // 证书在生物识别重新录入后仍可读；只有初始化签名才能识别已永久失效的私钥。
    private fun prepareSignature(entry: KeyStore.PrivateKeyEntry): Signature = try {
        Signature.getInstance(ALGORITHM).apply { initSign(entry.privateKey) }
    } catch (e: KeyPermanentlyInvalidatedException) {
        throw DeviceSignerException.KeyInvalidated()
    } catch (e: GeneralSecurityException) {
        Log.e(TAG, "initSign failed", e)
        throw DeviceSignerException.Failed(e.javaClass.simpleName)
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    private fun loadOrCreate(): KeyStore.PrivateKeyEntry {
        try {
            val store = keyStore()
            (store.getEntry(alias, null) as? KeyStore.PrivateKeyEntry)?.let { return it }
            val strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
            try {
                generate(strongBox)
            } catch (e: ProviderException) {
                // StrongBoxUnavailableException 是 ProviderException：说有 StrongBox 但用不了时退到 TEE。
                if (!strongBox) throw e
                Log.w(TAG, "StrongBox unavailable, using the TEE", e)
                generate(strongBox = false)
            }
            return store.getEntry(alias, null) as? KeyStore.PrivateKeyEntry ?: throw DeviceSignerException.Unavailable()
        } catch (e: GeneralSecurityException) {
            // 没录生物识别时生成会失败（InvalidAlgorithmParameterException）；Keystore 坏了也是这里。
            Log.e(TAG, "cannot create the signing key", e)
            throw DeviceSignerException.Unavailable()
        } catch (e: ProviderException) {
            Log.e(TAG, "cannot create the signing key", e)
            throw DeviceSignerException.Unavailable()
        }
    }

    private fun generate(strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                // 每次使用都要验证、只认强生物识别。Android 11 以前默认就是这样（有效期 -1：每次都验，只认生物识别）。
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                }
                if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) setIsStrongBoxBacked(true)
            }
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).apply { initialize(spec) }.generateKeyPair()
    }

    /** 弹 BiometricPrompt，验过后返回能用的签名对象。协程被取消时收起提示框。 */
    private suspend fun authenticate(signature: Signature, reason: String): Signature =
        withContext(Dispatchers.Main.immediate) {
            val activity = activity()?.takeUnless { it.isFinishing || it.isDestroyed }
                ?: throw DeviceSignerException.Failed("no activity")
            suspendCancellableCoroutine { cont ->
                val callback = object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        val unlocked = result.cryptoObject?.signature
                        if (!cont.isActive) return
                        if (unlocked != null) {
                            cont.resume(unlocked)
                        } else {
                            cont.resumeWithException(DeviceSignerException.Failed("no crypto object"))
                        }
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        // errString 是系统写的、可能是另一种语言：只进日志，界面用本地文案。
                        Log.i(TAG, "BiometricPrompt error $errorCode")
                        if (cont.isActive) cont.resumeWithException(errorFor(errorCode))
                    }

                    // onAuthenticationFailed：一次没认出来，提示框还在，等用户再试。
                }
                val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
                val info = BiometricPrompt.PromptInfo.Builder()
                    .setTitle(reason)
                    .setSubtitle(activity.getString(R.string.computer_sign_prompt_subtitle))
                    .setNegativeButtonText(activity.getString(R.string.action_cancel))
                    .setAllowedAuthenticators(BIOMETRIC_STRONG)
                    .build()
                prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
                cont.invokeOnCancellation { activity.runOnUiThread { prompt.cancelAuthentication() } }
            }
        }

    companion object {
        private const val TAG = "KeystoreSigner"
        private const val PROVIDER = "AndroidKeyStore"
        private const val ALGORITHM = "SHA256withECDSA"
        const val DEFAULT_ALIAS = "cn.thinktin.signing-key.p256"

        /** P-256 公钥 → SEC1 不压缩格式（`04 ‖ X ‖ Y`，65 字节）。 */
        fun sec1(key: ECPublicKey): ByteArray =
            byteArrayOf(0x04) + fixed32(key.w.affineX) + fixed32(key.w.affineY)

        /** 坐标补齐到 32 字节（BigInteger 可能多一个符号字节，也可能短）。 */
        private fun fixed32(value: BigInteger): ByteArray {
            val bytes = value.toByteArray()
            return when {
                bytes.size == 32 -> bytes
                bytes.size > 32 -> bytes.copyOfRange(bytes.size - 32, bytes.size)
                else -> ByteArray(32 - bytes.size) + bytes
            }
        }

        /** BiometricPrompt 的错误码 → 签名的错。 */
        fun errorFor(errorCode: Int): DeviceSignerException = when (errorCode) {
            BiometricPrompt.ERROR_USER_CANCELED,
            BiometricPrompt.ERROR_NEGATIVE_BUTTON,
            BiometricPrompt.ERROR_CANCELED,
            -> DeviceSignerException.Cancelled()
            BiometricPrompt.ERROR_NO_BIOMETRICS,
            BiometricPrompt.ERROR_HW_NOT_PRESENT,
            BiometricPrompt.ERROR_HW_UNAVAILABLE,
            BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL,
            -> DeviceSignerException.Unavailable()
            BiometricPrompt.ERROR_LOCKOUT,
            BiometricPrompt.ERROR_LOCKOUT_PERMANENT,
            -> DeviceSignerException.Lockout()
            else -> DeviceSignerException.Failed("biometric error $errorCode")
        }
    }
}

/** 签不了名的设备（没有注入签名密钥时，比如测试）：电脑页显示“这台手机签不了名”。 */
object UnavailableSigner : DeviceSigner {
    override fun isAvailable(): Boolean = false

    override suspend fun publicKey(): ByteArray = throw DeviceSignerException.Unavailable()

    override suspend fun sign(message: ByteArray, reason: String): ByteArray = throw DeviceSignerException.Unavailable()

    override suspend fun resetKey() = Unit
}
