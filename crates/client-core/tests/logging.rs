//! 日志交给 App（11.8）：装上全局的订阅者以后，client-core 的日志到了 App 的实现里；再调一次换掉实现、改级别。
//! 装的是进程全局的订阅者，所以这个文件里只有一个测试。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use client_core::api::{Api, ApiConfig, MemorySessionStore, Session, SessionStore};
use client_core::events::{self, EventSink, StreamConfig, StreamStatus};
use client_core::logging::{LogLevel, LogRecord, LogSink, init_logging};
use proto::domain::{DevicePlatform, InstanceEvent, InstanceId};

#[derive(Default)]
struct Recorder(Mutex<Vec<LogRecord>>);

impl LogSink for Recorder {
    fn log(&self, record: LogRecord) {
        self.0.lock().unwrap().push(record);
    }
}

struct Quiet;

impl EventSink for Quiet {
    fn on_event(&self, _: &InstanceEvent) {}
    fn on_reset(&self, _: u64, _: Option<u64>) {}
    fn on_status(&self, _: StreamStatus) {}
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn client_core_logs_reach_the_app() {
    let first = Arc::new(Recorder::default());
    assert!(init_logging(first.clone(), LogLevel::Debug));

    // 连不上的事件流：debug 级别的“连不上”到了 App 那边。
    let store = Arc::new(MemorySessionStore::default());
    store.save(Some(Session {
        user_id: "u".into(),
        device_id: "d".into(),
        access_token: "tta1.secret-token-value".into(),
        refresh_token: "r".into(),
    }));
    let api = Arc::new(
        Api::new(
            ApiConfig {
                base_url: "http://127.0.0.1:9".into(),
                platform: DevicePlatform::Ios,
                device_name: "t".into(),
                timeout: Duration::from_secs(2),
                accept_language: None,
            },
            store,
        )
        .unwrap(),
    );
    let cfg = StreamConfig {
        min_backoff: Duration::from_millis(20),
        max_backoff: Duration::from_millis(50),
        idle_timeout: Duration::from_secs(5),
        connect_timeout: Duration::from_secs(2),
    };
    let rt = tokio::runtime::Handle::current();
    let h = events::spawn(
        &rt,
        api.clone(),
        None,
        InstanceId::new(),
        Some(0),
        Arc::new(Quiet),
        cfg.clone(),
    );
    let seen = || {
        first.0.lock().unwrap().iter().any(|r| {
            r.level == LogLevel::Debug
                && r.target == "client_core::events"
                && r.message.contains("connect failed")
        })
    };
    for _ in 0..100 {
        if seen() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    h.stop();
    assert!(seen(), "{:?}", first.0.lock().unwrap());
    assert!(
        first
            .0
            .lock()
            .unwrap()
            .iter()
            .all(|r| !r.message.contains("secret-token-value")),
        "the access token never reaches the log"
    );

    // 再调一次：换成新的实现、只要 warn 以上。之后 debug 的哪边都不到，warn 的只到新的。
    tokio::time::sleep(Duration::from_millis(100)).await;
    let second = Arc::new(Recorder::default());
    assert!(init_logging(second.clone(), LogLevel::Warn));
    let before = first.0.lock().unwrap().len();
    tracing::debug!(target: "client_core::test", "hidden now");
    tracing::warn!(target: "client_core::test", "shown");
    assert_eq!(first.0.lock().unwrap().len(), before);
    let got = second.0.lock().unwrap().clone();
    assert!(got.iter().all(|r| r.level <= LogLevel::Warn), "{got:?}");
    assert!(got.iter().any(|r| r.message == "shown"), "{got:?}");

    // 用 `log` 打日志的依赖库（系统不信任证书时 rustls-platform-verifier 说的原因）：warn 以上的也交给 App，
    // 模块名是原来的，转换时带的出处字段不拼进正文。
    log::warn!(target: "rustls_platform_verifier::android", "certificate was not trusted: expired");
    log::info!(target: "reqwest::connect", "dependency chatter");
    let got = second.0.lock().unwrap().clone();
    let from_log: Vec<_> = got
        .iter()
        .filter(|r| {
            r.target.starts_with("rustls_platform_verifier") || r.target.starts_with("reqwest")
        })
        .collect();
    assert_eq!(from_log.len(), 1, "{got:?}");
    assert_eq!(
        (
            from_log[0].level,
            from_log[0].target.as_str(),
            from_log[0].message.as_str()
        ),
        (
            LogLevel::Warn,
            "rustls_platform_verifier::android",
            "certificate was not trusted: expired"
        )
    );
}
