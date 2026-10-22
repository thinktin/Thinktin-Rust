package cn.thinktin.app

import cn.thinktin.data.core.FixedTlsState
import cn.thinktin.data.core.TlsState
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/**
 * 测试用 Application：强制演示模式，时间固定在北京时间 2026-10-22 09:00（问候语是“早上好”）。
 * 不经 JNI 初始化证书校验（本机的 Linux .so 没有那个 JNI 函数）：用假的 [TlsState]。
 */
class DemoTestApp : ThinktinApp() {
    override fun initializeTls(): TlsState = FixedTlsState(ready = true)

    /** 不接 client-core 的日志：测试里不加载 .so。 */
    override fun initializeLogging() = Unit

    override fun createContainer(): AppContainer = AppContainer.create(
        this,
        tls = tlsState,
        forceDemo = true,
        clock = FIXED_CLOCK,
        settingsName = "settings-${UUID.randomUUID()}",
    )

    companion object {
        val FIXED_CLOCK: Clock = Clock.fixed(Instant.parse("2026-10-22T01:00:00Z"), ZoneId.of("Asia/Shanghai"))
    }
}
