//! 事件流的 TLS 用系统证书校验（11.8）：和接口请求一样认系统信任的证书。Linux 上系统证书来自 `SSL_CERT_FILE`，
//! 所以这里换着设它：不认识的签发者连不上，信任了测试 CA 就连上、收到事件。
//!
//! 改环境变量，所以这个文件里只有一个测试（单独一个进程）。
#![cfg(target_os = "linux")]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use client_core::api::{Api, ApiConfig, MemorySessionStore, Session, SessionStore};
use client_core::events::{self, EventSink, StreamConfig, StreamStatus};
use futures_util::SinkExt;
use proto::domain::{DevicePlatform, InstanceEvent, InstanceId};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::json;
use tokio_tungstenite::tungstenite::Message;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/tls")
        .join(name)
}

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<InstanceEvent>>,
    statuses: Mutex<Vec<StreamStatus>>,
}

impl EventSink for Sink {
    fn on_event(&self, e: &InstanceEvent) {
        self.events.lock().unwrap().push(e.clone());
    }
    fn on_reset(&self, _: u64, _: Option<u64>) {}
    fn on_status(&self, s: StreamStatus) {
        self.statuses.lock().unwrap().push(s);
    }
}

/// 一个 wss 服务端：握手后发一条事件，然后一直开着。
async fn serve(instance: InstanceId) -> u16 {
    let certs = CertificateDer::pem_file_iter(fixture("localhost.pem"))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let key = PrivateKeyDer::from_pem_file(fixture("localhost.key")).unwrap();
    let cfg = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(certs, key)
    .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(cfg));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else {
                return;
            };
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                // 不认识证书的客户端在这里就断了。
                let Ok(tls) = acceptor.accept(tcp).await else {
                    return;
                };
                let Ok(mut ws) = tokio_tungstenite::accept_async(tls).await else {
                    return;
                };
                let frame = json!({
                    "type": "event", "instance_id": instance, "seq": 1, "run_id": null,
                    "kind": "agent.message", "payload": {"text": "hello over tls"},
                    "created_at": "2026-10-22T00:00:00Z",
                });
                let _ = ws.send(Message::Text(frame.to_string().into())).await;
                tokio::time::sleep(Duration::from_secs(30)).await;
            });
        }
    });
    port
}

fn api(port: u16) -> Arc<Api> {
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
                base_url: format!("https://localhost:{port}"),
                platform: DevicePlatform::Ios,
                device_name: "test".into(),
                timeout: Duration::from_secs(5),
            },
            store,
        )
        .unwrap(),
    )
}

fn fast() -> StreamConfig {
    StreamConfig {
        min_backoff: Duration::from_millis(50),
        max_backoff: Duration::from_millis(200),
        idle_timeout: Duration::from_secs(5),
        connect_timeout: Duration::from_secs(5),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_event_stream_trusts_the_system_certificate_store() {
    let instance = InstanceId::new();
    let port = serve(instance).await;
    let rt = tokio::runtime::Handle::current();

    // 系统里没有签发它的 CA：连不上，一直在重连。
    // SAFETY: 这个测试文件里只有这一个测试，改环境变量时没有别的线程在读它（流还没开始）。
    unsafe { std::env::set_var("SSL_CERT_FILE", fixture("other-ca.pem")) };
    let sink = Arc::new(Sink::default());
    let h = events::spawn(
        &rt,
        api(port),
        None,
        instance,
        Some(0),
        sink.clone(),
        fast(),
    );
    tokio::time::sleep(Duration::from_millis(1500)).await;
    h.stop();
    {
        let statuses = sink.statuses.lock().unwrap();
        assert!(!statuses.contains(&StreamStatus::Live), "{statuses:?}");
        assert!(
            statuses
                .iter()
                .any(|s| matches!(s, StreamStatus::Reconnecting { .. })),
            "{statuses:?}"
        );
    }
    assert!(sink.events.lock().unwrap().is_empty());

    // 系统信任了测试 CA：连上，收到事件。
    // SAFETY: 同上；上一个流已经停了。
    unsafe { std::env::set_var("SSL_CERT_FILE", fixture("ca.pem")) };
    let sink = Arc::new(Sink::default());
    let _h = events::spawn(
        &rt,
        api(port),
        None,
        instance,
        Some(0),
        sink.clone(),
        fast(),
    );
    for _ in 0..100 {
        if !sink.events.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let events = sink.events.lock().unwrap().clone();
    assert_eq!(events.len(), 1, "{:?}", sink.statuses.lock().unwrap());
    assert_eq!(events[0].payload["text"], "hello over tls");
    assert!(sink.statuses.lock().unwrap().contains(&StreamStatus::Live));
}
