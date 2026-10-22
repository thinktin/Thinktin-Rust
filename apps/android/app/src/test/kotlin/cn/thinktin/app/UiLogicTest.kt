package cn.thinktin.app

import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.RelativeTime
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isLimitReached
import cn.thinktin.app.ui.common.isRetryable
import cn.thinktin.app.ui.common.WaitText
import cn.thinktin.app.ui.home.Greeting
import cn.thinktin.data.model.WaitCode
import cn.thinktin.data.service.ServiceError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Clock
import java.time.Instant
import java.time.ZoneId

class UiLogicTest {
    @Test
    fun waitTextCoversEveryKnownCode() {
        assertEquals(UiText(R.string.wait_invalid_key), WaitText.of(WaitCode.Invalid))
        assertEquals(UiText(R.string.wait_no_balance), WaitText.of(WaitCode.NoBalance))
        assertEquals(UiText(R.string.wait_key_unavailable), WaitText.of(WaitCode.Unavailable))
        assertEquals(UiText(R.string.wait_rate_limited), WaitText.of(WaitCode.RateLimited))
        assertEquals(UiText(R.string.wait_overloaded), WaitText.of(WaitCode.Overloaded))
        assertEquals(UiText(R.string.wait_device_offline), WaitText.of(WaitCode.DeviceOffline))
        // 不认识的码、没有码：按运行状态显示。
        assertEquals(null, WaitText.of(WaitCode.Unknown))
        assertEquals(null, WaitText.of(null as WaitCode?))
    }

    @Test
    fun errorTextMapsServiceErrors() {
        assertEquals(UiText(R.string.error_network), ErrorText.of(ServiceError.Network("timeout")))
        assertEquals(UiText(R.string.error_signed_out), ErrorText.of(ServiceError.SignedOut()))
        assertEquals(UiText(R.string.error_account_frozen), ErrorText.of(ServiceError.AccountFrozen()))
        assertEquals(UiText(R.string.error_upgrade_required), ErrorText.of(ServiceError.UpgradeRequired()))
        assertEquals(UiText(R.string.error_contains_secrets, listOf(2)), ErrorText.of(ServiceError.ContainsSecrets(2)))
        assertEquals(UiText(R.string.error_unsupported), ErrorText.of(ServiceError.Unsupported("teams")))
        assertEquals(UiText(R.string.error_tls_unavailable), ErrorText.of(ServiceError.TlsUnavailable()))
        assertEquals(UiText(R.string.error_other), ErrorText.of(ServiceError.Other("decode", "x")))
        assertEquals(
            UiText(R.string.error_rate_limited, listOf(30)),
            ErrorText.of(ServiceError.Api(429, "rate_limited", "slow", 30)),
        )
        assertEquals(UiText(R.string.error_rate_limited_plain), ErrorText.of(ServiceError.Api(429, "rate_limited", "", null)))
        assertEquals(UiText(R.string.error_not_found), ErrorText.of(ServiceError.Api(404, "not_found", "", null)))
        assertEquals(UiText(R.string.error_conflict), ErrorText.of(ServiceError.Api(409, "conflict", "", null)))
        assertEquals(UiText(R.string.error_invalid), ErrorText.of(ServiceError.Api(422, "invalid_base_url", "", null)))
        assertEquals(UiText(R.string.error_server, listOf("internal")), ErrorText.of(ServiceError.Api(500, "internal", "", null)))
        assertEquals(UiText(R.string.error_forbidden), ErrorText.of(ServiceError.Api(403, "forbidden", "", null)))
        assertEquals(UiText(R.string.error_forbidden), ErrorText.of(ServiceError.Api(403, "", "", null)))
        assertEquals(UiText(R.string.error_quota), ErrorText.of(ServiceError.Api(402, "quota_exceeded", "", null)))
        assertEquals(UiText(R.string.error_quota), ErrorText.of(ServiceError.Api(402, "budget_exceeded", "", null)))
        assertEquals(UiText(R.string.error_rate_limited_plain), ErrorText.of(ServiceError.Api(429, "", "", null)))
        assertEquals(UiText(R.string.error_invalid), ErrorText.of(ServiceError.Api(400, "", "", null)))
        // code 为空时显示状态码
        assertEquals(UiText(R.string.error_server, listOf("500")), ErrorText.of(ServiceError.Api(500, "", "", null)))
    }

    @Test
    fun limitCodesAndUnknownCodes() {
        // 11.9：数量上限的码以 _limit 结尾、409；先于 conflict 认出来
        val instanceLimit = ServiceError.Api(409, "instance_limit", "at most 5 instances", null)
        assertTrue(instanceLimit.isLimitReached)
        assertEquals(UiText(R.string.error_limit_reached), ErrorText.of(instanceLimit))
        assertEquals(UiText(R.string.error_limit_reached), ErrorText.of(ServiceError.Api(409, "vault_item_limit", "", null)))
        assertFalse("限频不是数量上限", ServiceError.Api(429, "rate_limited", "", null).isLimitReached)
        assertFalse(ServiceError.Api(409, "conflict", "", null).isLimitReached)
        assertFalse(ServiceError.Api(422, "limit", "", null).isLimitReached)
        // 不认识的码（client-core 原样放进 code）按状态给通用文案，状态也不认识的显示码，不崩
        assertEquals(UiText(R.string.error_conflict), ErrorText.of(ServiceError.Api(409, "brand_new_code", "", null)))
        assertEquals(UiText(R.string.error_not_found), ErrorText.of(ServiceError.Api(404, "gone_forever", "", null)))
        assertEquals(UiText(R.string.error_invalid), ErrorText.of(ServiceError.Api(422, "brand_new_code", "", null)))
        assertEquals(
            UiText(R.string.error_server, listOf("teapot")),
            ErrorText.of(ServiceError.Api(418, "teapot", "", null)),
        )
        assertFalse(ServiceError.Api(418, "teapot", "", null).isRetryable)
    }

    @Test
    fun greetingFollowsLocalHour() {
        fun at(iso: String) = Greeting.at(Clock.fixed(Instant.parse(iso), ZoneId.of("Asia/Shanghai")))
        assertEquals(Greeting.Morning, at("2026-10-22T01:00:00Z")) // 09:00
        assertEquals(Greeting.Afternoon, at("2026-10-22T06:30:00Z")) // 14:30
        assertEquals(Greeting.Evening, at("2026-10-22T13:00:00Z")) // 21:00
        assertEquals(Greeting.Evening, at("2026-10-21T19:00:00Z")) // 03:00
    }

    @Test
    fun relativeTime() {
        val zone = ZoneId.of("Asia/Shanghai")
        val now = Instant.parse("2026-10-22T06:00:00Z").toEpochMilli() // 14:00
        val minute = 60_000L
        assertEquals(RelativeTime.JustNow, RelativeTime.of(now - 30_000, now, zone))
        assertEquals(RelativeTime.MinutesAgo(5), RelativeTime.of(now - 5 * minute, now, zone))
        assertEquals(RelativeTime.HoursAgo(3), RelativeTime.of(now - 180 * minute, now, zone))
        // 昨天 20:30
        assertEquals(
            RelativeTime.Yesterday("20:30"),
            RelativeTime.of(Instant.parse("2026-10-21T12:30:00Z").toEpochMilli(), now, zone),
        )
        assertEquals(
            RelativeTime.DaysAgo(3),
            RelativeTime.of(Instant.parse("2026-10-19T02:00:00Z").toEpochMilli(), now, zone),
        )
        assert(RelativeTime.of(Instant.parse("2026-09-01T02:00:00Z").toEpochMilli(), now, zone) is RelativeTime.Date)
        // 将来的时间按“刚刚”
        assertEquals(RelativeTime.JustNow, RelativeTime.of(now + 10 * minute, now, zone))
    }
}
