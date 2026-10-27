package cn.thinktin.data

import cn.thinktin.data.core.CorePairingCodec
import cn.thinktin.data.model.CapabilityGrant
import cn.thinktin.data.model.ComputerApprovalRequest
import cn.thinktin.data.model.PairingCodecException
import cn.thinktin.data.model.PairingEncoding
import cn.thinktin.data.model.PairingOffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * 配对与验签（13.9）经真实的 client-core：和 `crates/client-core/src/pairing/tests.rs`、iOS 的 PairingCodecTests
 * 同一批测试向量（OpenSSL 独立生成）。需要 THINKTIN_CORE_LIB_DIR；没有时跳过，THINKTIN_REQUIRE_CORE=1 时失败。
 */
class CorePairingCodecTest {
    private val codec = CorePairingCodec()

    @Before
    fun requireNativeLibrary() {
        if (System.getProperty("jna.library.path").isNullOrBlank()) {
            if (System.getProperty("thinktin.requireCore") == "true") fail("THINKTIN_REQUIRE_CORE=1，但没有设置 THINKTIN_CORE_LIB_DIR")
            assumeTrue("未设置 THINKTIN_CORE_LIB_DIR，跳过", false)
        }
    }

    private fun offer(expiresIn: Long = 300) = PairingOffer(
        desktopId = "mac-1", desktopKey = DESKTOP_KEY, nonce = NONCE, expiresAt = System.currentTimeMillis() / 1000 + expiresIn,
    )

    @Test
    fun approvalBytesMatchTheIndependentImplementation() {
        val request = ComputerApprovalRequest(
            desktopId = "mac-1", requestId = "req-42", tool = "delete_files",
            argumentsJson = """{"recursive":1,"paths":["/Users/me/old.log","/Users/me/tmp"],"note":"清理\n旧文件"}""",
            summary = "删除 2 个文件", issuedAt = 1_760_000_000, expiresAt = 1_760_000_600,
        )
        val message = codec.approvalMessage(request, approve = true)
        assertEquals(APPROVAL_MESSAGE, String(message, Charsets.UTF_8))
        assertNotEquals(String(message, Charsets.UTF_8), String(codec.approvalMessage(request, approve = false), Charsets.UTF_8))
    }

    @Test
    fun pairingCodesRoundTripAndConfirmationsVerify() {
        val parsed = codec.parseOffer(CorePairingCodec.offerUriForTesting(offer()))
        assertEquals(offer().copy(expiresAt = parsed.expiresAt), parsed)
        codec.verifyConfirmation(parsed, "iphone-7", PHONE_KEY, CONFIRM_DER)
        try {
            codec.verifyConfirmation(parsed, "iphone-8", PHONE_KEY, CONFIRM_DER)
            fail("别的手机 id 应该验不过")
        } catch (_: PairingCodecException.BadSignature) {
        }
        assertTrue(String(codec.responseMessage(parsed, "iphone-7", PHONE_KEY), Charsets.UTF_8).startsWith("thinktin-pair-response-v1\n"))
        try {
            codec.parseOffer(CorePairingCodec.offerUriForTesting(offer(expiresIn = -3600)))
            fail("过期的邀请应该拒绝")
        } catch (_: PairingCodecException.Expired) {
        }
        try {
            codec.parseOffer("https://example.com")
            fail("不是配对码")
        } catch (_: PairingCodecException.Malformed) {
        }
    }

    @Test
    fun capabilityBytesAndPublicKeys() {
        val grant = CapabilityGrant("mac-1", "tok-1", listOf("/Users/me/Documents"), listOf("com.apple.Safari"), 1_760_003_600)
        val message = String(codec.capabilityMessage(grant), Charsets.UTF_8)
        assertTrue(message.startsWith("thinktin-capability-v1\n"))
        assertTrue("tok-1" in message)
        val compressed = PairingEncoding.fromBase64url(PHONE_KEY)!!
        assertEquals(PHONE_KEY, codec.encodePublicKey(compressed))
        assertArrayEquals(compressed, PairingEncoding.fromBase64url(PairingEncoding.base64url(compressed)))
        try {
            codec.encodePublicKey(ByteArray(33) { 1 })
            fail("不是合法的公钥")
        } catch (_: PairingCodecException) {
        }
    }

    companion object {
        const val PHONE_KEY = "A3ZBMie_HDnUDgWOHXgN_KgD1WVDY2JGkisQVOaV2ztZ"
        const val DESKTOP_KEY = "BHGPuO3emZZPoXZt1QKaW_v0vTGoCGWqM-dmhYZVc_9ziHw6tD4C6tX9UofXGOOguvAbH7jebXfPeeYP8l568Ps"
        const val NONCE = "AAECAwQFBgcICQoLDA0ODw"
        const val APPROVAL_MESSAGE = "thinktin-approval-v1\ndesktop:mac-1\nrequest:req-42\ntool:delete_files\n" +
            "args-sha256:812063d33eea6eecb5b080fe8cf105b13725d48b04a57d198dd25781b9d48ce2\n" +
            "summary-sha256:4c33c19418c5481ea2fc3897035d3d724c56fbd6fdca1624d8e9132ab5100463\n" +
            "issued:1760000000\nexpires:1760000600\ndecision:approve\n"
        val CONFIRM_DER = byteArrayOf(
            0x30, 0x44, 0x02, 0x20, 0x0f, 0x92.toByte(), 0x5e, 0x83.toByte(), 0xfd.toByte(), 0x16, 0xcc.toByte(), 0xa4.toByte(),
            0x0f, 0x39, 0xae.toByte(), 0x0b, 0xb6.toByte(), 0x70, 0x2c, 0x0d, 0x6b, 0x5c, 0x32, 0xbe.toByte(), 0x6a, 0x3b,
            0xc0.toByte(), 0x08, 0xcb.toByte(), 0x3f, 0xc8.toByte(), 0x72, 0x81.toByte(), 0x91.toByte(), 0x1d, 0xbc.toByte(),
            0x02, 0x20, 0x21, 0x3f, 0x97.toByte(), 0x6a, 0xce.toByte(), 0xfc.toByte(), 0xdb.toByte(), 0xef.toByte(),
            0xd7.toByte(), 0x76, 0xf1.toByte(), 0x55, 0xa1.toByte(), 0x63, 0x00, 0x41, 0x3e, 0x45, 0x27, 0xd0.toByte(),
            0x8a.toByte(), 0x5d, 0x30, 0x3d, 0x93.toByte(), 0x8c.toByte(), 0x7e, 0xa1.toByte(), 0x27, 0x93.toByte(),
            0x43, 0x5a,
        )
    }
}
