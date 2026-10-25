package cn.thinktin.app

import java.time.Clock
import java.time.Instant
import java.time.ZoneId

/**
 * 跟着系统时区走的时钟。`Clock.systemDefaultZone()` 在创建时就把时区定死了，App 进程活着时用户换了时区
 * （出差、手动改），按天切分（用量页）和相对时间还会按旧时区算；这个每次取时区都读系统当前的。
 */
object SystemZoneClock : Clock() {
    override fun getZone(): ZoneId = ZoneId.systemDefault()

    override fun withZone(zone: ZoneId): Clock = Clock.system(zone)

    override fun instant(): Instant = Instant.now()

    override fun millis(): Long = System.currentTimeMillis()
}
