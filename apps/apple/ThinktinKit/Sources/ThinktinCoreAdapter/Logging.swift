import Foundation
import ThinktinKit

#if canImport(os)
    import os
#endif

/// client-core 的日志（Rust 的 `tracing`，11.8）接到系统日志：Apple 平台写进 `os.Logger`（subsystem
/// `cn.thinktin.core`，category 是 Rust 的模块名，比如 `client_core::events`），TestFlight 用户的问题才能从
/// sysdiagnose、Console.app 里查（`log stream --predicate 'subsystem == "cn.thinktin.core"'`）。
///
/// App 启动时调一次 `CoreLogging.install(maxLevel:)`（建 `CoreClient` 之前、之后都行）。正文在 Rust 那边已经抹掉了
/// 令牌、密码、像 key 的串，所以按 `.public` 记（不然 sysdiagnose 里只看得到 `<private>`）。依赖库（h2、hyper、
/// rustls）的日志只到 warn。
public enum CoreLogging {
    /// 日志级别，从严重到啰嗦（和 client-core 的 `LogLevel` 一一对应）。
    public enum Level: Int, Sendable, Hashable, CaseIterable, Comparable {
        case error, warn, info, debug, trace

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 系统日志里的子系统名。
    public static let subsystem = "cn.thinktin.core"

    private struct State {
        var sink: OSLogSink?
        var level: Level?
        var connected = false
    }

    private static let state = Locked(State())

    /// 把 client-core 的日志接到系统日志，client-core 自己的日志输出到 `maxLevel`（发布版用 `.info`，调试用 `.debug`）。
    /// 只装一次：之后再调只改级别（同一个级别什么都不做），可以从任何线程调。
    ///
    /// - Returns: 接上了没有。进程里已经有别的 Rust 日志订阅者时是 false（桌面端、Rust 的测试；App 里不会）。
    @discardableResult
    public static func install(maxLevel: Level = .info) -> Bool {
        state.withLock { s in
            if s.sink != nil, s.level == maxLevel { return s.connected }
            let sink = s.sink ?? OSLogSink()
            // 第一次是装上；再调一次是同一个 sink 改级别（client-core 的 init_logging 两种都管）。
            s.connected = Core.initLogging(sink: sink, maxLevel: maxLevel.core)
            s.sink = sink
            s.level = maxLevel
            return s.connected
        }
    }

    /// 现在的级别；还没装为 nil。
    public static var currentLevel: Level? { state.withLock { $0.level } }
}

extension CoreLogging.Level {
    init(core level: Core.LogLevel) {
        switch level {
        case .error: self = .error
        case .warn: self = .warn
        case .info: self = .info
        case .debug: self = .debug
        case .trace: self = .trace
        }
    }

    var core: Core.LogLevel {
        switch self {
        case .error: .error
        case .warn: .warn
        case .info: .info
        case .debug: .debug
        case .trace: .trace
        }
    }

    /// 写进标准错误时的级别名。
    var label: String {
        switch self {
        case .error: "ERROR"
        case .warn: "WARN"
        case .info: "INFO"
        case .debug: "DEBUG"
        case .trace: "TRACE"
        }
    }
}

/// 把 client-core 的一条日志写进系统日志（`CoreLogging` 用）。client-core 在自己的任意线程上调，要很快返回，
/// 不调回 client-core。
///
/// - Apple 平台：`os.Logger`，每个 category（Rust 模块）建一个、缓存起来。级别照 `Logger` 的习惯：warn 和 error
///   都记成 `.error`（`Logger.warning` 也是），info 是 `.info`，debug、trace 是 `.debug`。
/// - 没有 os 的平台（Linux 上的测试和 CI）：一行一条写到标准错误。
final class OSLogSink: Core.LogSink {
    #if canImport(os)
        private let loggers = Locked<[String: Logger]>([:])
    #endif

    func log(record: Core.LogRecord) {
        let level = CoreLogging.Level(core: record.level)
        #if canImport(os)
            let logger = loggers.withLock { cache in
                if let logger = cache[record.target] { return logger }
                let logger = Logger(subsystem: CoreLogging.subsystem, category: record.target)
                cache[record.target] = logger
                return logger
            }
            logger.log(level: level.osLogType, "\(record.message, privacy: .public)")
        #else
            let line = Self.line(level: level, target: record.target, message: record.message) + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        #endif
    }

    /// 标准错误里的一行：`[WARN] client_core::events: …`。
    static func line(level: CoreLogging.Level, target: String, message: String) -> String {
        "[\(level.label)] \(target): \(message)"
    }
}

#if canImport(os)
    extension CoreLogging.Level {
        /// 系统日志的类型。`.info` 平时只在内存里，出错时才落盘；`.error` 一直落盘。
        var osLogType: OSLogType {
            switch self {
            case .error, .warn: .error
            case .info: .info
            case .debug, .trace: .debug
            }
        }
    }
#endif
