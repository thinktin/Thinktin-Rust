package cn.thinktin.data.core

import cn.thinktin.core.PairingException
import cn.thinktin.data.model.CapabilityGrant
import cn.thinktin.data.model.ComputerApprovalRequest
import cn.thinktin.data.model.PairingCodec
import cn.thinktin.data.model.PairingCodecException
import cn.thinktin.data.model.PairingOffer
import cn.thinktin.core.ApprovalRequest as CoreApprovalRequest
import cn.thinktin.core.CapabilityGrant as CoreCapabilityGrant
import cn.thinktin.core.PairingOffer as CorePairingOffer

/**
 * [PairingCodec] 的真实现（13.9）：client-core 的配对与验签（`crates/client-core/src/pairing.rs`，docs/pairing.md）。
 * 手机和电脑用同一份实现，签的字节一定一致；签名在 Keystore 里做。
 */
class CorePairingCodec : PairingCodec {
    override fun parseOffer(uri: String): PairingOffer = run {
        val offer = cn.thinktin.core.parsePairingOffer(uri)
        PairingOffer(
            desktopId = offer.desktopId, desktopKey = offer.desktopKey, nonce = offer.nonce,
            expiresAt = offer.expiresAt.toLong(),
        )
    }

    override fun responseMessage(offer: PairingOffer, phoneId: String, phoneKey: String): ByteArray = run {
        cn.thinktin.core.pairingResponseMessage(offer.toCore(), phoneId, phoneKey)
    }

    override fun verifyConfirmation(offer: PairingOffer, phoneId: String, phoneKey: String, signature: ByteArray) = run {
        cn.thinktin.core.verifyPairingConfirmation(offer.toCore(), phoneId, phoneKey, signature)
    }

    override fun approvalMessage(request: ComputerApprovalRequest, approve: Boolean): ByteArray = run {
        val core = CoreApprovalRequest(
            desktopId = request.desktopId, requestId = request.requestId, tool = request.tool,
            argumentsJson = request.argumentsJson, summary = request.summary,
            issuedAt = request.issuedAt.toULong(), expiresAt = request.expiresAt.toULong(),
        )
        cn.thinktin.core.approvalMessage(core, approve)
    }

    override fun capabilityMessage(grant: CapabilityGrant): ByteArray = run {
        val core = CoreCapabilityGrant(
            desktopId = grant.desktopId, tokenId = grant.tokenId, dirs = grant.dirs, apps = grant.apps,
            expiresAt = grant.expiresAt.toULong(),
        )
        cn.thinktin.core.capabilityMessage(core)
    }

    override fun encodePublicKey(sec1: ByteArray): String = run { cn.thinktin.core.encodePublicKey(sec1) }

    private fun <T> run(body: () -> T): T = try {
        body()
    } catch (e: PairingException.Malformed) {
        throw PairingCodecException.Malformed(e.detail)
    } catch (_: PairingException.Expired) {
        throw PairingCodecException.Expired()
    } catch (_: PairingException.BadSignature) {
        throw PairingCodecException.BadSignature()
    }

    companion object {
        internal fun PairingOffer.toCore(): CorePairingOffer =
            CorePairingOffer(desktopId = desktopId, desktopKey = desktopKey, nonce = nonce, expiresAt = expiresAt.toULong())

        /** 测试用：电脑那边生成的二维码内容（手机不需要生成）。 */
        internal fun offerUriForTesting(offer: PairingOffer): String = cn.thinktin.core.pairingOfferUri(offer.toCore())
    }
}
