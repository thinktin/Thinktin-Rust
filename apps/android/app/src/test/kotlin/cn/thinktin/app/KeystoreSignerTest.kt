package cn.thinktin.app

import androidx.biometric.BiometricPrompt
import cn.thinktin.app.computer.KeystoreSigner
import cn.thinktin.data.model.DeviceSignerException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/**
 * 13.9：Keystore 签名的纯逻辑（Robolectric 没有 AndroidKeyStore，生成密钥、BiometricPrompt 只能真机验证）：
 * 公钥转 SEC1、BiometricPrompt 的错误码。
 */
class KeystoreSignerTest {
    private fun keyPair() = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    @Test
    fun publicKeysBecomeUncompressedSec1() {
        repeat(20) {
            val pair = keyPair()
            val public = pair.public as ECPublicKey
            val sec1 = KeystoreSigner.sec1(public)
            assertEquals(65, sec1.size)
            assertEquals(0x04.toByte(), sec1[0])
            // 坐标原样读回来是同一个点（BigInteger 的符号字节、短坐标都补齐了）。
            val x = BigInteger(1, sec1.copyOfRange(1, 33))
            val y = BigInteger(1, sec1.copyOfRange(33, 65))
            val back = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), public.params))
            assertEquals(public, back)

            // 签名是 DER（SHA256withECDSA），用这个公钥验得过。
            val message = "thinktin".toByteArray()
            val signature = Signature.getInstance("SHA256withECDSA").apply {
                initSign(pair.private)
                update(message)
            }.sign()
            assertEquals(0x30.toByte(), signature[0])
            assertTrue(Signature.getInstance("SHA256withECDSA").apply { initVerify(back); update(message) }.verify(signature))
        }
    }

    @Test
    fun biometricErrorsMapToSignerErrors() {
        for (code in listOf(BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_CANCELED)) {
            assertTrue(KeystoreSigner.errorFor(code) is DeviceSignerException.Cancelled)
        }
        for (code in listOf(BiometricPrompt.ERROR_NO_BIOMETRICS, BiometricPrompt.ERROR_HW_NOT_PRESENT, BiometricPrompt.ERROR_HW_UNAVAILABLE)) {
            assertTrue(KeystoreSigner.errorFor(code) is DeviceSignerException.Unavailable)
        }
        for (code in listOf(BiometricPrompt.ERROR_LOCKOUT, BiometricPrompt.ERROR_LOCKOUT_PERMANENT)) {
            assertTrue(KeystoreSigner.errorFor(code) is DeviceSignerException.Lockout)
        }
        assertTrue(KeystoreSigner.errorFor(BiometricPrompt.ERROR_TIMEOUT) is DeviceSignerException.Failed)
    }
}
