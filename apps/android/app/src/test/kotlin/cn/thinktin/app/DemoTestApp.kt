package cn.thinktin.app

import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/** 测试用 Application：强制演示模式，时间固定在北京时间 2026-10-22 09:00（问候语是“早上好”）。 */
class DemoTestApp : ThinktinApp() {
    override fun createContainer(): AppContainer =
        AppContainer.create(this, forceDemo = true, clock = FIXED_CLOCK, settingsName = "settings-${UUID.randomUUID()}")

    companion object {
        val FIXED_CLOCK: Clock = Clock.fixed(Instant.parse("2026-10-22T01:00:00Z"), ZoneId.of("Asia/Shanghai"))
    }
}
