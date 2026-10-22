package cn.thinktin.data

import cn.thinktin.core.ClientException
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.asServiceError
import cn.thinktin.data.service.toServiceError
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ServiceErrorTest {
    @Test
    fun mapsEveryClientException() {
        assertTrue(ClientException.Network("timeout").toServiceError() is ServiceError.Network)
        assertTrue(ClientException.SignedOut().toServiceError() is ServiceError.SignedOut)
        assertTrue(ClientException.UpgradeRequired().toServiceError() is ServiceError.UpgradeRequired)
        assertTrue(ClientException.AccountFrozen().toServiceError() is ServiceError.AccountFrozen)

        val api = ClientException.Api(429u, "rate_limited", "slow down", 30uL).toServiceError() as ServiceError.Api
        assertEquals(429, api.status)
        assertEquals("rate_limited", api.code)
        assertEquals("slow down", api.detail)
        assertEquals(30L, api.retryAfterSecs)
        assertNull((ClientException.Api(404u, "not_found", "", null).toServiceError() as ServiceError.Api).retryAfterSecs)

        assertEquals(2, (ClientException.ContainsSecrets(2u).toServiceError() as ServiceError.ContainsSecrets).count)

        val others = listOf(
            ClientException.Decode("bad json") to "decode",
            ClientException.Cache("disk full") to "cache",
            ClientException.InvalidArgument("id") to "invalid_argument",
            ClientException.Internal("panic") to "internal",
        )
        for ((exception, kind) in others) {
            val mapped = exception.toServiceError() as ServiceError.Other
            assertEquals(kind, mapped.kind)
            assertSame(exception, mapped.cause)
        }
    }

    @Test
    fun networkKeepsDetail() {
        val error = ClientException.Network("dns failed").toServiceError() as ServiceError.Network
        assertEquals("dns failed", error.detail)
    }

    @Test
    fun asServiceErrorPassesThroughAndWraps() {
        val original = ServiceError.Unsupported("teams")
        assertSame(original, original.asServiceError())
        assertTrue(ClientException.SignedOut().asServiceError() is ServiceError.SignedOut)
        val wrapped = IllegalStateException("boom").asServiceError() as ServiceError.Other
        assertEquals("IllegalStateException", wrapped.kind)
    }
}
