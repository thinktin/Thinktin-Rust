//! 请求的公共部分（11.8）：每个请求都带 `Accept-Language`；服务端说版本太老（426）时，接口报 `UpgradeRequired`、
//! 事件流以 `UpgradeRequired` 结束、不再重连。用一个只会按路径回固定响应的 HTTP 桩，不需要数据库。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use client_core::ClientError;
use client_core::api::{Api, ApiConfig, MemorySessionStore, Session, SessionStore};
use client_core::events::{self, EventSink, StreamConfig, StreamStatus};
use proto::domain::{DevicePlatform, InstanceEvent, InstanceId};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// 收到的请求头（第一行加各个头，原样）。
type Seen = Arc<Mutex<Vec<String>>>;

/// 按“方法 路径前缀”回 `(状态码, 响应体)`；没配的回 404。
async fn stub(routes: Vec<(&'static str, u16, &'static str)>) -> (String, Seen) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen: Seen = Arc::default();
    let log = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut tcp, _)) = listener.accept().await else {
                return;
            };
            let log = log.clone();
            let routes = routes.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    match tcp.read(&mut chunk).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => buf.extend_from_slice(&chunk[..n]),
                    }
                }
                let head = String::from_utf8_lossy(&buf).to_string();
                let line = head.lines().next().unwrap_or_default().to_owned();
                log.lock().unwrap().push(head.clone());
                let (status, body) = routes
                    .iter()
                    .find(|(prefix, _, _)| line.starts_with(prefix))
                    .map(|(_, s, b)| (*s, *b))
                    .unwrap_or((404, r#"{"code":"not_found","message":"no"}"#));
                let resp = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\
                     connection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = tcp.write_all(resp.as_bytes()).await;
                let _ = tcp.shutdown().await;
            });
        }
    });
    (base, seen)
}

fn api(base: &str, lang: Option<&str>) -> Arc<Api> {
    let store = Arc::new(MemorySessionStore::default());
    store.save(Some(Session {
        user_id: "u".into(),
        device_id: "d".into(),
        access_token: "tta1.test".into(),
        refresh_token: "r".into(),
    }));
    Arc::new(
        Api::new(
            ApiConfig {
                base_url: base.into(),
                platform: DevicePlatform::Ios,
                device_name: "test".into(),
                timeout: Duration::from_secs(5),
                accept_language: lang.map(Into::into),
            },
            store,
        )
        .unwrap(),
    )
}

fn header(head: &str, name: &str) -> Option<String> {
    head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim()
            .eq_ignore_ascii_case(name)
            .then(|| v.trim().to_owned())
    })
}

#[derive(Default)]
struct Sink(Mutex<Vec<StreamStatus>>);

impl EventSink for Sink {
    fn on_event(&self, _: &InstanceEvent) {}
    fn on_reset(&self, _: u64, _: Option<u64>) {}
    fn on_status(&self, s: StreamStatus) {
        self.0.lock().unwrap().push(s);
    }
}

fn fast() -> StreamConfig {
    StreamConfig {
        min_backoff: Duration::from_millis(50),
        max_backoff: Duration::from_millis(100),
        idle_timeout: Duration::from_secs(5),
        connect_timeout: Duration::from_secs(5),
    }
}

/// 等事件流结束，返回它报过的状态。
async fn finished(sink: &Sink) -> Vec<StreamStatus> {
    for _ in 0..100 {
        let s = sink.0.lock().unwrap().clone();
        if s.last().is_some_and(|l| {
            !matches!(
                l,
                StreamStatus::Connecting | StreamStatus::Live | StreamStatus::Reconnecting { .. }
            )
        }) {
            return s;
        }
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    panic!("the stream did not end: {:?}", sink.0.lock().unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_request_carries_the_device_language() {
    let (base, seen) = stub(vec![
        ("POST /v1/auth/code", 204, ""),
        (
            "GET /v1/me",
            401,
            r#"{"code":"unauthenticated","message":"expired"}"#,
        ),
        (
            "POST /v1/auth/refresh",
            401,
            r#"{"code":"session_revoked","message":"gone"}"#,
        ),
    ])
    .await;
    let lang = "zh-Hans-CN, en-US;q=0.9";
    let a = api(&base, Some(lang));
    a.send_code("13800138000").await.unwrap();
    // 令牌过期时的刷新请求也带上。
    assert!(matches!(a.me().await, Err(ClientError::SignedOut)));
    // 事件流的握手也带上（桩回 404：实例不存在）。
    let sink = Arc::new(Sink::default());
    let a2 = api(&base, Some(lang));
    let _h = events::spawn(
        &tokio::runtime::Handle::current(),
        a2.clone(),
        None,
        InstanceId::new(),
        Some(0),
        sink.clone(),
        fast(),
    );
    assert_eq!(finished(&sink).await.last(), Some(&StreamStatus::NotFound));
    {
        let heads = seen.lock().unwrap();
        assert_eq!(heads.len(), 4, "{heads:?}");
        for h in heads.iter() {
            assert_eq!(header(h, "accept-language").as_deref(), Some(lang), "{h}");
            assert_eq!(
                header(h, "x-thinktin-api-version").as_deref(),
                Some("1"),
                "{h}"
            );
        }
        assert!(
            heads[1].starts_with("GET /v1/me") && heads[2].starts_with("POST /v1/auth/refresh")
        );
        assert!(heads[3].contains("/events/ws"));
    }
    // 换语言、不带；带不了的值报参数错误。
    a.set_accept_language(Some("en")).unwrap();
    a.send_code("13800138000").await.unwrap();
    a.set_accept_language(None).unwrap();
    a.send_code("13800138000").await.unwrap();
    {
        let heads = seen.lock().unwrap();
        assert_eq!(header(&heads[4], "accept-language").as_deref(), Some("en"));
        assert_eq!(header(&heads[5], "accept-language"), None);
    }
    assert!(matches!(
        a.set_accept_language(Some("en\r\nx-evil: 1")),
        Err(ClientError::InvalidArgument { .. })
    ));
    assert!(matches!(
        Api::new(
            ApiConfig {
                base_url: base.clone(),
                platform: DevicePlatform::Ios,
                device_name: "t".into(),
                timeout: Duration::from_secs(5),
                accept_language: Some("x".repeat(300)),
            },
            Arc::new(MemorySessionStore::default()),
        ),
        Err(ClientError::InvalidArgument { .. })
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_old_app_stops_instead_of_reconnecting() {
    let rt = tokio::runtime::Handle::current();
    // 握手 426：结束（UpgradeRequired），只连了一次；之后再开的事件流不再连。
    let (base, seen) = stub(vec![(
        "GET /v1/instances/",
        426,
        r#"{"code":"upgrade_required","message":"too old"}"#,
    )])
    .await;
    let a = api(&base, None);
    let sink = Arc::new(Sink::default());
    let _h = events::spawn(
        &rt,
        a.clone(),
        None,
        InstanceId::new(),
        Some(0),
        sink.clone(),
        fast(),
    );
    assert_eq!(
        finished(&sink).await,
        vec![StreamStatus::Connecting, StreamStatus::UpgradeRequired]
    );
    assert!(a.upgrade_required());
    let sink = Arc::new(Sink::default());
    let _h = events::spawn(
        &rt,
        a.clone(),
        None,
        InstanceId::new(),
        Some(0),
        sink.clone(),
        fast(),
    );
    assert_eq!(finished(&sink).await, vec![StreamStatus::UpgradeRequired]);
    assert_eq!(seen.lock().unwrap().len(), 1);

    // 令牌过期、刷新时才说太老（不带错误体）：一样结束。
    let (base, _) = stub(vec![
        ("GET /v1/instances/", 401, ""),
        ("POST /v1/auth/refresh", 426, ""),
    ])
    .await;
    let a = api(&base, None);
    let sink = Arc::new(Sink::default());
    let _h = events::spawn(
        &rt,
        a.clone(),
        None,
        InstanceId::new(),
        Some(0),
        sink.clone(),
        fast(),
    );
    let statuses = finished(&sink).await;
    assert_eq!(
        statuses.last(),
        Some(&StreamStatus::UpgradeRequired),
        "{statuses:?}"
    );
    assert!(
        !statuses
            .iter()
            .any(|s| matches!(s, StreamStatus::Reconnecting { .. })),
        "{statuses:?}"
    );
    assert!(a.upgrade_required());

    // 接口请求：带错误体、不带错误体的 426 都报 UpgradeRequired。
    let (base, _) = stub(vec![
        (
            "GET /v1/me",
            426,
            r#"{"code":"upgrade_required","message":"too old"}"#,
        ),
        ("POST /v1/auth/code", 426, ""),
    ])
    .await;
    let a = api(&base, None);
    assert!(!a.upgrade_required());
    assert!(matches!(a.me().await, Err(ClientError::UpgradeRequired)));
    assert!(a.upgrade_required());
    let a = api(&base, None);
    assert!(matches!(
        a.send_code("13800138000").await,
        Err(ClientError::UpgradeRequired)
    ));
    assert!(a.upgrade_required());
}

#[test]
fn accept_language_from_the_system_list() {
    use client_core::ffi::accept_language_header;
    assert_eq!(
        accept_language_header(vec!["zh-Hans-CN".into(), "en_US".into(), "en".into()]),
        "zh-Hans-CN, en-US;q=0.9, en;q=0.8"
    );
    assert_eq!(
        accept_language_header(vec![" ".into(), "x;q=1".into(), "fr".into()]),
        "fr"
    );
    assert_eq!(accept_language_header(vec![]), "");
    let many: Vec<String> = (0..15).map(|i| format!("l{i}")).collect();
    assert_eq!(accept_language_header(many).split(", ").count(), 10);
    // 长的语言标签（带地区偏好的扩展）：只留放得下 256 字节的前几个，结果总能直接用。
    let long: Vec<String> = (0..10)
        .map(|i| format!("en-US-u-fw-mon-mu-celsius-x-ab{i:02}"))
        .collect();
    let header = accept_language_header(long);
    assert!(
        header.len() <= 256 && header.split(", ").count() == 6,
        "{header}"
    );
    assert!(header.ends_with(";q=0.5"), "{header}");
    let cfg = ApiConfig {
        base_url: "https://api.example.com".into(),
        platform: DevicePlatform::Ios,
        device_name: "test".into(),
        timeout: Duration::from_secs(5),
        accept_language: Some(header),
    };
    assert!(Api::new(cfg, Arc::new(MemorySessionStore::default())).is_ok());
    assert_eq!(
        proto::domain::Locale::from_accept_language("zh-Hans-CN, en-US;q=0.9"),
        Some(proto::domain::Locale::ZhCn)
    );
}
