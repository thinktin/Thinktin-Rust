//! 日志（11.8）：client-core 里的 `tracing` 日志交给 App 写进系统日志（iOS 的 `Logger` / os_log、Android 的
//! Logcat），TestFlight 用户的问题才能从 sysdiagnose、bugreport 里查。
//!
//! App 启动时调一次 [`init_logging`]，传一个实现了 [`LogSink`] 的对象。交出去之前在 Rust 这边先抹掉敏感的内容：
//! 叫 token、password 之类的字段只留名字；正文里的 `Bearer …`、像 key 和密码的串（[`crate::secrets::detect`]，
//! 和发消息前识别密码用的是同一套）换成 `[redacted]`；一行最长 4096 字节。所以 iOS 那边可以用 `privacy: .public`
//! 记（不然 sysdiagnose 里只看得到 `<private>`）。
//!
//! client-core 自己的日志按设的级别输出，依赖库（h2、hyper、rustls……）的只输出 warn 和 error。

use std::cell::Cell;
use std::fmt::Write as _;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, OnceLock, RwLock};

use tracing::field::{Field, Visit};
use tracing::{Event, Level, Metadata, Subscriber};
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

/// 一行最长多少字节（超过的截断，末尾加 `…`）。
const MAX_LINE: usize = 4096;

/// 这些字段只留名字。
const SECRET_FIELDS: &[&str] = &[
    "authorization",
    "token",
    "access_token",
    "refresh_token",
    "push_token",
    "password",
    "secret",
    "api_key",
    "webhook",
    "sms_code",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, uniffi::Enum)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl LogLevel {
    fn of(level: &Level) -> Self {
        match *level {
            Level::ERROR => Self::Error,
            Level::WARN => Self::Warn,
            Level::INFO => Self::Info,
            Level::DEBUG => Self::Debug,
            Level::TRACE => Self::Trace,
        }
    }

    fn from_u8(n: u8) -> Self {
        match n {
            0 => Self::Error,
            1 => Self::Warn,
            2 => Self::Info,
            3 => Self::Debug,
            _ => Self::Trace,
        }
    }
}

/// 一条日志。用记录而不是几个参数：以后加字段（时间之类）不用改 App 里的实现。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LogRecord {
    pub level: LogLevel,
    /// 哪个模块（`client_core::events`），iOS 可以当 `Logger` 的 category。
    pub target: String,
    /// 已经抹掉敏感内容的一行。
    pub message: String,
}

/// App 实现：把一条日志写进系统日志。在 client-core 的任意线程上调用，要很快返回，不要再调回 client-core。
#[uniffi::export(foreign)]
pub trait LogSink: Send + Sync {
    fn log(&self, record: LogRecord);
}

/// 进程里的日志设置：交给谁、client-core 自己的日志到哪一级。
struct State {
    sink: RwLock<Option<Arc<dyn LogSink>>>,
    level: AtomicU8,
}

impl State {
    fn new(level: LogLevel) -> Self {
        Self {
            sink: RwLock::new(None),
            level: AtomicU8::new(level as u8),
        }
    }

    fn level(&self) -> LogLevel {
        LogLevel::from_u8(self.level.load(Ordering::Relaxed))
    }

    fn sink(&self) -> Option<Arc<dyn LogSink>> {
        self.sink.read().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

static STATE: OnceLock<Arc<State>> = OnceLock::new();
static INSTALLED: OnceLock<bool> = OnceLock::new();

/// 把 client-core 的日志交给 `sink`，自己的日志输出到 `max_level`（依赖库的只到 warn）。在 App 启动时调；再调一次
/// 是换掉交给谁、改级别。进程里已经有别的 `tracing` 订阅者（桌面端、测试）时返回 false，日志不交出去。
#[uniffi::export]
pub fn init_logging(sink: Arc<dyn LogSink>, max_level: LogLevel) -> bool {
    let state = STATE.get_or_init(|| Arc::new(State::new(max_level)));
    *state.sink.write().unwrap_or_else(|e| e.into_inner()) = Some(sink);
    state.level.store(max_level as u8, Ordering::Relaxed);
    let installed = *INSTALLED.get_or_init(|| {
        let subscriber = tracing_subscriber::registry().with(ForeignLayer {
            state: state.clone(),
        });
        tracing::subscriber::set_global_default(subscriber).is_ok()
    });
    // 级别变了：让各处的日志重新判断要不要输出。
    tracing::callsite::rebuild_interest_cache();
    installed
}

struct ForeignLayer {
    state: Arc<State>,
}

thread_local! {
    /// 正在把日志交给 App：这期间（App 的实现又调回 Rust 打日志）产生的日志丢掉，免得递归。
    static IN_SINK: Cell<bool> = const { Cell::new(false) };
}

impl ForeignLayer {
    fn wanted(&self, meta: &Metadata<'_>) -> bool {
        let level = LogLevel::of(meta.level());
        let ours = meta.target().starts_with("client_core");
        let max = if ours {
            self.state.level()
        } else {
            self.state.level().min(LogLevel::Warn)
        };
        level <= max
    }
}

impl<S: Subscriber> Layer<S> for ForeignLayer {
    fn register_callsite(
        &self,
        _meta: &'static Metadata<'static>,
    ) -> tracing::subscriber::Interest {
        // 级别可以在运行时改，每次都问 `enabled`。
        tracing::subscriber::Interest::sometimes()
    }

    fn enabled(&self, meta: &Metadata<'_>, _ctx: Context<'_, S>) -> bool {
        self.wanted(meta)
    }

    fn max_level_hint(&self) -> Option<tracing::level_filters::LevelFilter> {
        use tracing::level_filters::LevelFilter;
        Some(match self.state.level().max(LogLevel::Warn) {
            LogLevel::Error => LevelFilter::ERROR,
            LogLevel::Warn => LevelFilter::WARN,
            LogLevel::Info => LevelFilter::INFO,
            LogLevel::Debug => LevelFilter::DEBUG,
            LogLevel::Trace => LevelFilter::TRACE,
        })
    }

    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        if IN_SINK.with(Cell::get) || !self.wanted(event.metadata()) {
            return;
        }
        let Some(sink) = self.state.sink() else {
            return;
        };
        let mut line = Line::default();
        event.record(&mut line);
        let record = LogRecord {
            level: LogLevel::of(event.metadata().level()),
            target: event.metadata().target().to_owned(),
            message: scrub(&line.finish()),
        };
        IN_SINK.with(|f| f.set(true));
        // App 那边出错（抛异常）不能弄死 client-core 的线程。
        let _ = catch_unwind(AssertUnwindSafe(|| sink.log(record)));
        IN_SINK.with(|f| f.set(false));
    }
}

/// 拼一行：正文，再接着 ` 字段=值`。敏感字段只留名字。
#[derive(Default)]
struct Line {
    message: String,
    fields: String,
}

impl Line {
    fn finish(self) -> String {
        let mut s = self.message;
        s.push_str(&self.fields);
        s
    }

    fn push(&mut self, field: &Field, value: &dyn std::fmt::Display) {
        if field.name() == "message" {
            let _ = write!(self.message, "{value}");
        } else if SECRET_FIELDS.contains(&field.name()) {
            let _ = write!(self.fields, " {}=[redacted]", field.name());
        } else {
            let _ = write!(self.fields, " {}={value}", field.name());
        }
    }
}

impl Visit for Line {
    fn record_str(&mut self, field: &Field, value: &str) {
        self.push(field, &value);
    }

    fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
        self.push(field, &value);
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.push(field, &format_args!("{value:?}"));
    }
}

/// 抹掉一行里的 `Bearer …` 和像 key、密码的串，截到 [`MAX_LINE`]。
fn scrub(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(i) = rest.find("Bearer ") {
        out.push_str(&rest[..i + "Bearer ".len()]);
        out.push_str("[redacted]");
        let after = &rest[i + "Bearer ".len()..];
        let end = after
            .find(|c: char| c.is_whitespace() || c == '"' || c == '\'')
            .unwrap_or(after.len());
        rest = &after[end..];
    }
    out.push_str(rest);
    let found = crate::secrets::detect(&out);
    let mut clean = String::with_capacity(out.len());
    let mut at = 0;
    for f in found {
        clean.push_str(&out[at..f.start]);
        clean.push_str("[redacted]");
        at = f.end;
    }
    clean.push_str(&out[at..]);
    if clean.len() > MAX_LINE {
        let mut cut = MAX_LINE - "…".len();
        while !clean.is_char_boundary(cut) {
            cut -= 1;
        }
        clean.truncate(cut);
        clean.push('…');
    }
    clean
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use tracing_subscriber::layer::SubscriberExt;

    use super::*;

    #[derive(Default)]
    struct Recorder(Mutex<Vec<LogRecord>>);

    impl LogSink for Recorder {
        fn log(&self, record: LogRecord) {
            self.0.lock().unwrap().push(record);
        }
    }

    /// 在这个线程上用一个单独的设置收日志（不动全局的）。
    fn capture(level: LogLevel, sink: Arc<dyn LogSink>, f: impl FnOnce()) {
        let state = Arc::new(State::new(level));
        *state.sink.write().unwrap() = Some(sink);
        let subscriber = tracing_subscriber::registry().with(ForeignLayer { state });
        tracing::subscriber::with_default(subscriber, f);
    }

    #[test]
    fn levels_and_third_party_targets() {
        let rec = Arc::new(Recorder::default());
        capture(LogLevel::Info, rec.clone(), || {
            tracing::debug!(target: "client_core::events", "too detailed");
            tracing::info!(target: "client_core::events", status = 426, "event stream refused");
            tracing::info!(target: "h2::codec", "frame");
            tracing::warn!(target: "rustls::client", "bad certificate");
        });
        let got = rec.0.lock().unwrap().clone();
        assert_eq!(
            got,
            [
                LogRecord {
                    level: LogLevel::Info,
                    target: "client_core::events".into(),
                    message: "event stream refused status=426".into(),
                },
                LogRecord {
                    level: LogLevel::Warn,
                    target: "rustls::client".into(),
                    message: "bad certificate".into(),
                },
            ]
        );
        let rec = Arc::new(Recorder::default());
        capture(LogLevel::Debug, rec.clone(), || {
            tracing::debug!(target: "client_core::api", "now shown");
            tracing::debug!(target: "hyper::client", "still hidden");
        });
        assert_eq!(rec.0.lock().unwrap().len(), 1);
    }

    #[test]
    fn secrets_never_reach_the_system_log() {
        let rec = Arc::new(Recorder::default());
        let instance = "0199f1a2-3b4c-7d5e-8f60-718293a4b5c6";
        capture(LogLevel::Trace, rec.clone(), || {
            tracing::info!(target: "client_core::api", token = "tta1.abc", password = "hunter2", "login");
            tracing::info!(
                target: "client_core::api",
                "header Authorization: Bearer eyJhbGciOi.abc.def and key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 for {instance}"
            );
        });
        let got = rec.0.lock().unwrap().clone();
        assert_eq!(got[0].message, "login token=[redacted] password=[redacted]");
        let m = &got[1].message;
        assert!(
            !m.contains("eyJhbGciOi") && !m.contains("sk-ant-api03"),
            "{m}"
        );
        assert!(
            m.contains("Bearer [redacted]") && m.contains(instance),
            "{m}"
        );
    }

    #[test]
    fn long_lines_are_cut_on_a_character_boundary() {
        let line = scrub(&"长".repeat(3000));
        assert!(line.len() <= MAX_LINE && line.ends_with('…'));
    }

    /// App 的实现又调回 Rust 打日志：不递归、不死锁；实现里出错不往外传。
    #[test]
    fn a_misbehaving_sink_is_contained() {
        struct Echo(Mutex<u32>);
        impl LogSink for Echo {
            fn log(&self, _record: LogRecord) {
                *self.0.lock().unwrap() += 1;
                tracing::warn!(target: "client_core::echo", "from inside the sink");
            }
        }
        let echo = Arc::new(Echo(Mutex::new(0)));
        capture(LogLevel::Info, echo.clone(), || {
            tracing::info!(target: "client_core::api", "once");
        });
        assert_eq!(*echo.0.lock().unwrap(), 1);

        struct Panics;
        impl LogSink for Panics {
            fn log(&self, _record: LogRecord) {
                panic!("the app's logger threw");
            }
        }
        capture(LogLevel::Info, Arc::new(Panics), || {
            tracing::info!(target: "client_core::api", "survives");
            tracing::info!(target: "client_core::api", "and again");
        });
    }
}
