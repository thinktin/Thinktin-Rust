//! 主程序的运维接口、版本协商和停机流程。需要 DATABASE_URL（没有时跳过）。

use std::time::{Duration, Instant};

use proto::api::{ErrorBody, ErrorCode, ServerInfo, VERSION_HEADER};
use server::Config;
use store::testing::TestDb;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn health_version_and_graceful_shutdown() {
    let Some(t) = TestDb::new().await else { return };
    let cfg = Config::parse(
        r#"
        [shutdown]
        drain_secs = 1
        grace_secs = 5
        "#,
    )
    .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let db = t.db.clone();
    let server = tokio::spawn(async move {
        server::serve(&cfg, db, listener, async {
            stop_rx.await.ok();
        })
        .await
    });
    let http = reqwest::Client::new();

    let r = http.get(format!("{base}/healthz")).send().await.unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(r.headers()[VERSION_HEADER], "1");
    assert_eq!(r.headers()["cache-control"], "no-store");
    let r = http.get(format!("{base}/readyz")).send().await.unwrap();
    assert_eq!(r.status(), 200);
    let info: ServerInfo = http
        .get(format!("{base}/version"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(info.api_version, proto::api::API_VERSION);
    assert_eq!(
        info.shim_protocol_version,
        proto::shim::SHIM_PROTOCOL_VERSION
    );

    // 未知接口、太老的客户端、写错的版本头都返回统一的错误结构。
    let r = http.get(format!("{base}/nope")).send().await.unwrap();
    assert_eq!(r.status(), 404);
    assert_eq!(
        r.json::<ErrorBody>().await.unwrap().code,
        ErrorCode::NotFound
    );
    let r = http
        .get(format!("{base}/version"))
        .header(VERSION_HEADER, "0")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 426);
    assert_eq!(
        r.json::<ErrorBody>().await.unwrap().code,
        ErrorCode::UpgradeRequired
    );
    let r = http
        .get(format!("{base}/version"))
        .header(VERSION_HEADER, "99")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200, "newer clients are served at our version");
    assert_eq!(r.headers()[VERSION_HEADER], "1");
    let r = http
        .get(format!("{base}/version"))
        .header(VERSION_HEADER, "abc")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 422);

    // 停机：先报未就绪（存活检查照常），排空期过后停止服务，serve 正常返回。
    let started = Instant::now();
    stop_tx.send(()).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let r = http.get(format!("{base}/readyz")).send().await.unwrap();
    assert_eq!(r.status(), 503);
    assert_eq!(
        r.json::<ErrorBody>().await.unwrap().code,
        ErrorCode::Unavailable
    );
    let r = http.get(format!("{base}/healthz")).send().await.unwrap();
    assert_eq!(r.status(), 200);
    server.await.unwrap().unwrap();
    let took = started.elapsed();
    assert!(
        took >= Duration::from_millis(900) && took < Duration::from_secs(5),
        "{took:?}"
    );
    assert!(
        reqwest::Client::new()
            .get(format!("{base}/healthz"))
            .send()
            .await
            .is_err(),
        "no longer listening"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn client_api_is_mounted_when_enabled() {
    let Some(t) = TestDb::new().await else { return };
    let mut cfg = Config::parse(
        r#"
        [shutdown]
        drain_secs = 0
        [api]
        enabled = true
        dev_sms = true
        "#,
    )
    .unwrap();
    cfg.api_secrets = server::config::ApiSecrets {
        access_token_seed: Some(
            auth::signed::Signer25519::generate("a1")
                .unwrap()
                .seed_b64()
                .to_string(),
        ),
        code_pepper: Some("ab".repeat(32)),
        kms_key: Some("cd".repeat(32)),
    };
    let blobs = tempfile::tempdir().unwrap();
    cfg.storage.local_root = blobs.path().to_path_buf();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let db = t.db.clone();
    let server = tokio::spawn(async move {
        server::serve(&cfg, db, listener, async {
            stop_rx.await.ok();
        })
        .await
    });
    let http = reqwest::Client::new();
    let r = http.get(format!("{base}/v1/agents")).send().await.unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(r.headers()[VERSION_HEADER], "1");
    let r = http
        .post(format!("{base}/v1/auth/code"))
        .json(&serde_json::json!({ "phone": "13800138000" }))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 204);
    let r = http.get(format!("{base}/v1/me")).send().await.unwrap();
    assert_eq!(r.status(), 401);
    assert_eq!(
        r.json::<ErrorBody>().await.unwrap().code,
        ErrorCode::Unauthenticated
    );
    let r = http
        .get(format!("{base}/v1/agents"))
        .header(VERSION_HEADER, "0")
        .send()
        .await
        .unwrap();
    assert_eq!(
        r.status(),
        426,
        "old clients are turned away from the API too"
    );
    stop_tx.send(()).unwrap();
    server.await.unwrap().unwrap();
}
