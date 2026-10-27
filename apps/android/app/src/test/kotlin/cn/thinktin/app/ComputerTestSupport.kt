package cn.thinktin.app

import cn.thinktin.data.model.CapabilityGrant
import cn.thinktin.data.model.ComputerApprovalRequest
import cn.thinktin.data.model.DeviceSigner
import cn.thinktin.data.model.DeviceSignerException
import cn.thinktin.data.model.PairingCodec
import cn.thinktin.data.model.PairingCodecException
import cn.thinktin.data.model.PairingEncoding
import cn.thinktin.data.model.PairingOffer

// 13.9 的替身：视图模型测试和界面测试共用。

/** 假的 client-core 编码：消息是可读的文本，电脑的签名是 `desktop:` 加消息。真的编码在 :data 的 CorePairingCodecTest 里测。 */
internal class FakeCodec(private val nowSecs: () -> Long) : PairingCodec {
    override fun parseOffer(uri: String): PairingOffer {
        val parts = uri.split(':')
        val expires = parts.getOrNull(3)?.toLongOrNull()
        // 测试里的配对码：pair:<电脑>:<随机数>:<过期秒>，或者 thinktin-pair: 开头（深链）。
        if (parts.size != 4 || parts[0] !in setOf("pair", "thinktin-pair") || expires == null) {
            throw PairingCodecException.Malformed("pairing code")
        }
        if (expires <= nowSecs()) throw PairingCodecException.Expired()
        return PairingOffer(desktopId = parts[1], desktopKey = "dk-${parts[1]}", nonce = parts[2], expiresAt = expires)
    }

    override fun responseMessage(offer: PairingOffer, phoneId: String, phoneKey: String): ByteArray =
        "response|${offer.desktopId}|${offer.nonce}|$phoneId|$phoneKey".toByteArray()

    override fun verifyConfirmation(offer: PairingOffer, phoneId: String, phoneKey: String, signature: ByteArray) {
        if (!signature.contentEquals(confirmation(offer, phoneId, phoneKey).toByteArray())) throw PairingCodecException.BadSignature()
    }

    override fun approvalMessage(request: ComputerApprovalRequest, approve: Boolean): ByteArray =
        "approval|${request.requestId}|$approve".toByteArray()

    override fun capabilityMessage(grant: CapabilityGrant): ByteArray =
        "capability|${grant.tokenId}|${grant.dirs.joinToString(",")}".toByteArray()

    override fun encodePublicKey(sec1: ByteArray): String = PairingEncoding.base64url(sec1)

    companion object {
        fun confirmation(offer: PairingOffer, phoneId: String, phoneKey: String) =
            "desktop:confirm|${offer.desktopKey}|${offer.nonce}|$phoneId|$phoneKey"
    }
}

/** 假的 Keystore：签名是 `signed:` 加消息。 */
internal class FakeSigner : DeviceSigner {
    var available = true
    var key = "phone-key-1".toByteArray()
    var failNext: DeviceSignerException? = null
    val reasons = mutableListOf<String>()

    override fun isAvailable(): Boolean = available

    override suspend fun publicKey(): ByteArray = key

    override suspend fun sign(message: ByteArray, reason: String): ByteArray {
        reasons += reason
        failNext?.let {
            failNext = null
            throw it
        }
        return "signed:".toByteArray() + message
    }

    override suspend fun resetKey() {
        key = "phone-key-2".toByteArray()
    }
}
