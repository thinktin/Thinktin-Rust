package cn.thinktin.data.core

import android.util.Log
import cn.thinktin.core.LogLevel
import cn.thinktin.core.LogRecord
import cn.thinktin.core.LogSink
import cn.thinktin.core.initLogging

/**
 * 把 client-core 的日志（已经抹掉敏感内容）接到 `android.util.Log`（11.8）。Application.onCreate 里调一次 [install]：
 * debug 包到 Debug 级别，release 只要 Warn 以上。
 */
object CoreLogging {
    /** logcat 的 tag（不超过 23 个字符）。 */
    const val TAG: String = "ThinktinCore"

    /**
     * 安装日志出口（会加载 .so）。返回 client-core 是否接受（进程里已经有别的 tracing 订阅者时返回 false）。
     * 加载失败等异常照常抛出，调用方兜住。
     */
    fun install(verbose: Boolean): Boolean =
        initLogging(AndroidLogSink, if (verbose) LogLevel.DEBUG else LogLevel.WARN)

    /** client-core 的级别 → logcat 的优先级。 */
    internal fun priority(level: LogLevel): Int = when (level) {
        LogLevel.ERROR -> Log.ERROR
        LogLevel.WARN -> Log.WARN
        LogLevel.INFO -> Log.INFO
        LogLevel.DEBUG -> Log.DEBUG
        LogLevel.TRACE -> Log.VERBOSE
    }

    /** 一行日志：`模块: 内容`。 */
    internal fun line(record: LogRecord): String = "${record.target}: ${record.message}"
}

/** 在 client-core 的任意线程上被调用：只写 logcat，很快返回，不回调 client-core。 */
internal object AndroidLogSink : LogSink {
    override fun log(record: LogRecord) {
        Log.println(CoreLogging.priority(record.level), CoreLogging.TAG, CoreLogging.line(record))
    }
}
