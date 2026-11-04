//! 出口代理（2.7）：沙箱 → CONNECT 隧道 → 目标网站。目标用本机的回显服务代替（测试模式放行回环地址和任意端口）。

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use auth::sandbox_token::{SandboxTokenIssuer, SandboxTokenVerifier, TokenRequest};
use base64::Engine;
use keyvault::{KeyVault, LocalKms, MemoryKeyStore};
use llm_gw::egress::{Egress, EgressOptions, MemoryEgressLedger, serve_egress};
use llm_gw::limits::{Limiter, MemoryLedger};
use llm_gw::store::{Instance, Limits, MemoryDirectory};
use llm_gw::usage::MemorySink;
use llm_gw::{Gateway, Options, build_client};
use proto::domain::EgressMode;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn instance(mode: EgressMode, hosts: &[&str]) -> Instance {
    Instance {
        id: "inst-1".into(),
        user_id: "user-1".into(),
        sandbox: Some("sbx-1".into()),
        epoch: 0,
        active: true,
        routes: Default::default(),
        limits: Limits::default(),
        egress_mode: mode,
        egress_hosts: hosts.iter().map(|h| (*h).to_owned()).collect(),
    }
}

struct Env {
    proxy: SocketAddr,
    echo: SocketAddr,
    issuer: SandboxTokenIssuer,
    directory: Arc<MemoryDirectory>,
    ledger: Arc<MemoryEgressLedger>,
    egress: Arc<Egress>,
}

/// 回显服务：读到什么写回什么。
async fn echo_server() -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut s, _)) = l.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let (mut r, mut w) = s.split();
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    addr
}

async fn env(mode: EgressMode, hosts: &[&str], tune: impl FnOnce(&mut EgressOptions)) -> Env {
    let issuer = SandboxTokenIssuer::generate("k1").unwrap();
    let mut verifier = SandboxTokenVerifier::new();
    verifier
        .add_key_b64("k1", &issuer.verifying_key_b64())
        .unwrap();
    let directory = Arc::new(MemoryDirectory::new(
        vec![instance(mode, hosts)],
        vec![],
        vec![],
    ));
    let options = Options::default();
    let gw = Arc::new(Gateway {
        verifier,
        directory: directory.clone(),
        secrets: Arc::new(KeyVault::new(
            LocalKms::new("kms", &[7; 32]),
            MemoryKeyStore::default(),
        )),
        vault: Default::default(),
        usage: Arc::new(MemorySink::default()),
        ledger: Arc::new(MemoryLedger::default()),
        limiter: Limiter::default(),
        cooldowns: Default::default(),
        client: build_client(&options, None).unwrap(),
        options,
    });
    let ledger = Arc::new(MemoryEgressLedger::default());
    let mut opts = EgressOptions {
        insecure: true,
        ..EgressOptions::default()
    };
    tune(&mut opts);
    let egress = Arc::new(Egress::new(gw, ledger.clone(), opts));
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = l.local_addr().unwrap();
    tokio::spawn(serve_egress(l, egress.clone(), std::future::pending()));
    Env {
        proxy,
        echo: echo_server().await,
        issuer,
        directory,
        ledger,
        egress,
    }
}

impl Env {
    fn token_with(&self, f: impl FnOnce(&mut TokenRequest)) -> String {
        let mut req = TokenRequest {
            ep: 0,
            iid: "inst-1".into(),
            uid: "user-1".into(),
            grant: "grant-1".into(),
            sbx: "sbx-1".into(),
            net: Some("127.0.0.1".into()),
        };
        f(&mut req);
        self.issuer.issue(req, 600, now()).unwrap()
    }

    /// 发一个 CONNECT，返回状态行和连接（成功时接着就是隧道）。
    async fn connect(&self, target: &str, token: Option<&str>) -> (String, TcpStream) {
        let mut s = TcpStream::connect(self.proxy).await.unwrap();
        let mut head = format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n");
        if let Some(t) = token {
            let cred = base64::engine::general_purpose::STANDARD.encode(format!("x:{t}"));
            head.push_str(&format!("Proxy-Authorization: Basic {cred}\r\n"));
        }
        head.push_str("\r\n");
        s.write_all(head.as_bytes()).await.unwrap();
        // 读到响应头结束为止（一个字节一个字节读，不吞掉隧道里的数据）。
        let mut resp = Vec::new();
        let mut byte = [0u8; 1];
        while !resp.ends_with(b"\r\n\r\n") {
            match tokio::time::timeout(Duration::from_secs(5), s.read(&mut byte)).await {
                Ok(Ok(1)) => resp.push(byte[0]),
                _ => break,
            }
        }
        let text = String::from_utf8_lossy(&resp).into_owned();
        // 拒绝的响应带正文：读掉（拒绝后连接关闭）。
        if !text.starts_with("HTTP/1.1 200") {
            let mut rest = String::new();
            let _ = tokio::time::timeout(Duration::from_secs(2), s.read_to_string(&mut rest)).await;
            return (format!("{text}{rest}"), s);
        }
        (text, s)
    }

    fn echo_target(&self) -> String {
        format!("localhost:{}", self.echo.port())
    }

    async fn wait_for_records(&self, n: usize) -> Vec<llm_gw::egress::EgressRecord> {
        for _ in 0..100 {
            let r = self.ledger.records();
            if r.len() >= n {
                return r;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        self.ledger.records()
    }
}

fn status(resp: &str) -> u16 {
    resp.split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

#[tokio::test]
async fn an_allowed_host_gets_a_tunnel_and_the_bytes_are_counted() {
    let e = env(EgressMode::Custom, &["localhost"], |_| {}).await;
    let (resp, mut s) = e
        .connect(&e.echo_target(), Some(&e.token_with(|_| {})))
        .await;
    assert_eq!(status(&resp), 200, "{resp}");
    s.write_all(b"hello through the tunnel").await.unwrap();
    let mut buf = [0u8; 24];
    s.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"hello through the tunnel");
    s.shutdown().await.unwrap();
    drop(s);
    let records = e.wait_for_records(1).await;
    let r = &records[0];
    assert!(r.allowed, "{r:?}");
    assert_eq!((r.host.as_str(), r.port), ("localhost", e.echo.port()));
    assert_eq!((r.bytes_up, r.bytes_down), (24, 24));
    assert_eq!(r.address.map(|a| a.port()), Some(e.echo.port()));
    // 没用完的预留退回了：今天只算真用掉的。
    let day = (chrono::Utc::now() + chrono::Duration::hours(8)).date_naive();
    assert_eq!(e.ledger.used("inst-1", day), 48);
}

#[tokio::test]
async fn bad_credentials_methods_and_hosts_are_refused() {
    let e = env(EgressMode::Custom, &["localhost"], |o| {
        o.ask_wait = Duration::ZERO
    })
    .await;
    let target = e.echo_target();
    let (resp, _) = e.connect(&target, None).await;
    assert_eq!(status(&resp), 407, "{resp}");
    assert!(
        resp.to_ascii_lowercase()
            .contains("proxy-authenticate: basic"),
        "{resp}"
    );
    // 令牌绑定的来源地址不是这台：拒绝。
    let elsewhere = e.token_with(|r| r.net = Some("10.0.0.9".into()));
    let (resp, _) = e.connect(&target, Some(&elsewhere)).await;
    assert_eq!(status(&resp), 407, "{resp}");
    let token = e.token_with(|_| {});
    // 上一次运行的令牌：拒绝。
    e.directory.upsert_instance(Instance {
        epoch: 1,
        ..instance(EgressMode::Custom, &["localhost"])
    });
    let (resp, _) = e.connect(&target, Some(&token)).await;
    assert_eq!(status(&resp), 407, "{resp}");
    e.directory
        .upsert_instance(instance(EgressMode::Custom, &["localhost"]));
    // IP 字面量；不在列表里的网站（问用户，用户还没答）。
    let (resp, _) = e
        .connect(&format!("127.0.0.1:{}", e.echo.port()), Some(&token))
        .await;
    assert_eq!(status(&resp), 400, "{resp}");
    let (resp, _) = e.connect("example.com:443", Some(&token)).await;
    assert_eq!(status(&resp), 403, "{resp}");
    assert!(resp.contains("pending_approval"), "{resp}");
    // 不是 CONNECT。
    let mut s = TcpStream::connect(e.proxy).await.unwrap();
    s.write_all(b"GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n")
        .await
        .unwrap();
    let mut out = String::new();
    let _ = tokio::time::timeout(Duration::from_secs(2), s.read_to_string(&mut out)).await;
    assert_eq!(status(&out), 405, "{out}");
    // 拒绝的也记日志（不合规的网站、不放行的网站），认不出是谁的不记。
    let records = e.wait_for_records(2).await;
    let reasons: Vec<_> = records.iter().map(|r| (r.allowed, r.reason)).collect();
    assert_eq!(reasons, [(false, "bad_host"), (false, "pending_approval")]);
}

#[tokio::test]
async fn model_only_agents_get_nothing_and_blocked_ranges_stay_blocked() {
    let e = env(EgressMode::Model, &[], |_| {}).await;
    let token = e.token_with(|_| {});
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 403, "{resp}");
    // 全部公网也连不了禁段里的地址。
    let e = env(EgressMode::All, &[], |o| {
        o.deny = vec!["127.0.0.0/8".parse().unwrap()];
    })
    .await;
    let token = e.token_with(|_| {});
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 403, "{resp}");
    assert!(resp.contains("private_address"), "{resp}");
}

#[tokio::test]
async fn tunnels_are_capped_and_the_daily_allowance_cuts_them_off() {
    let e = env(EgressMode::All, &[], |o| {
        o.max_tunnels = 1;
        o.daily_bytes = 1000;
        o.reserve_chunk = 100;
        o.slot_wait = Duration::from_millis(200);
    })
    .await;
    let token = e.token_with(|_| {});
    let (resp, mut first) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 200, "{resp}");
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 429, "{resp}");
    assert!(resp.contains("too_many_tunnels"), "{resp}");
    // 一直发：双向合计到 1000 字节就断。
    let chunk = [b'x'; 100];
    let mut echoed = 0usize;
    let mut buf = [0u8; 100];
    for _ in 0..20 {
        if first.write_all(&chunk).await.is_err() {
            break;
        }
        match tokio::time::timeout(Duration::from_secs(2), first.read(&mut buf)).await {
            Ok(Ok(0)) | Ok(Err(_)) | Err(_) => break,
            Ok(Ok(n)) => echoed += n,
        }
    }
    assert!(echoed <= 500, "echoed {echoed}");
    let records = e.wait_for_records(2).await;
    let tunnel = records.iter().find(|r| r.allowed).unwrap();
    assert_eq!(tunnel.reason, "quota", "{tunnel:?}");
    assert!(tunnel.bytes_up + tunnel.bytes_down <= 1000, "{tunnel:?}");
    let day = (chrono::Utc::now() + chrono::Duration::hours(8)).date_naive();
    assert!(e.ledger.used("inst-1", day) <= 1000);
    // 用完了：新隧道直接拒绝。
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 429, "{resp}");
    assert!(resp.contains("quota"), "{resp}");
}

#[tokio::test]
async fn revoking_or_narrowing_closes_open_tunnels() {
    let e = env(EgressMode::Custom, &["localhost"], |o| {
        o.recheck_every = Duration::from_millis(100);
    })
    .await;
    let token = e.token_with(|_| {});
    let (resp, mut s) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 200, "{resp}");
    // 用户把档位改回只连模型：开着的隧道很快断开。
    e.directory
        .upsert_instance(instance(EgressMode::Model, &[]));
    let mut buf = [0u8; 8];
    let r = tokio::time::timeout(Duration::from_secs(3), s.read(&mut buf)).await;
    assert!(matches!(r, Ok(Ok(0)) | Ok(Err(_))), "{r:?}");
    let records = e.wait_for_records(1).await;
    assert_eq!(records[0].reason, "revoked");

    // 运行授权吊销了也一样。
    e.directory
        .upsert_instance(instance(EgressMode::Custom, &["localhost"]));
    let (resp, mut s) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 200, "{resp}");
    e.directory.revoke_grant("grant-1");
    let r = tokio::time::timeout(Duration::from_secs(3), s.read(&mut buf)).await;
    assert!(matches!(r, Ok(Ok(0)) | Ok(Err(_))), "{r:?}");
    let records = e.wait_for_records(2).await;
    assert_eq!(records[1].reason, "revoked");
}

#[tokio::test]
async fn idle_tunnels_are_closed() {
    let e = env(EgressMode::All, &[], |o| {
        o.idle_timeout = Duration::from_millis(300);
    })
    .await;
    let token = e.token_with(|_| {});
    let (resp, mut s) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 200, "{resp}");
    let mut buf = [0u8; 8];
    let r = tokio::time::timeout(Duration::from_secs(5), s.read(&mut buf)).await;
    assert!(matches!(r, Ok(Ok(0)) | Ok(Err(_))), "{r:?}");
    let records = e.wait_for_records(1).await;
    assert_eq!(records[0].reason, "idle");
}

/// 一个实例一分钟里的日志超过上限：多出来的按网站和结果合并成一行带次数的（评审 2026-11-04：放行的隧道也算）。
#[tokio::test]
async fn logs_over_the_minute_cap_are_merged() {
    let e = env(EgressMode::Custom, &["localhost"], |o| {
        o.logs_per_minute = 2;
        o.ask_wait = Duration::ZERO;
    })
    .await;
    let token = e.token_with(|_| {});
    for _ in 0..5 {
        let (resp, s) = e.connect(&e.echo_target(), Some(&token)).await;
        assert_eq!(status(&resp), 200, "{resp}");
        drop(s);
        // 等这条隧道结束、记完再开下一条。
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    for _ in 0..3 {
        let (resp, _) = e.connect("example.com:443", Some(&token)).await;
        assert_eq!(status(&resp), 403, "{resp}");
    }
    let single = e.wait_for_records(2).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(e.ledger.records().len(), 2, "{single:?}");
    e.egress.flush_summaries().await;
    let records = e.ledger.records();
    let total: u32 = records.iter().map(|r| r.count).sum();
    assert_eq!(total, 8, "{records:?}");
    let merged = records.iter().find(|r| !r.allowed).unwrap();
    assert_eq!((merged.count, merged.reason), (3, "pending_approval"));
}

/// 同一个来源地址一分钟里 CONNECT 太多：核对令牌之前就拒绝（过期令牌反复来也不会每次都查库）。
#[tokio::test]
async fn one_address_cannot_hammer_the_proxy() {
    let e = env(EgressMode::All, &[], |o| o.attempts_per_ip_per_minute = 3).await;
    for _ in 0..3 {
        let (resp, _) = e.connect(&e.echo_target(), None).await;
        assert_eq!(status(&resp), 407, "{resp}");
    }
    let (resp, _) = e
        .connect(&e.echo_target(), Some(&e.token_with(|_| {})))
        .await;
    assert_eq!(status(&resp), 429, "{resp}");
}

/// 预留了额度、后面没连上（解析不了）：退回，不算今天的用量。
#[tokio::test]
async fn reservations_are_refunded_when_the_tunnel_never_opens() {
    let e = env(EgressMode::All, &[], |_| {}).await;
    let token = e.token_with(|_| {});
    let (resp, _) = e.connect("no-such-host.invalid:443", Some(&token)).await;
    assert_eq!(status(&resp), 502, "{resp}");
    let day = (chrono::Utc::now() + chrono::Duration::hours(8)).date_naive();
    for _ in 0..50 {
        if e.ledger.used("inst-1", day) == 0 {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!(
        "the reservation was not refunded: {}",
        e.ledger.used("inst-1", day)
    );
}

/// 同时开着的隧道满了：新的排队等，有一条结束就轮到它（包管理器同时开很多连接也装得上）。
#[tokio::test]
async fn a_full_tunnel_cap_queues_instead_of_refusing() {
    let e = Arc::new(
        env(EgressMode::All, &[], |o| {
            o.max_tunnels = 1;
            o.slot_wait = Duration::from_secs(5);
        })
        .await,
    );
    let token = e.token_with(|_| {});
    let (resp, first) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 200, "{resp}");
    let waiting = {
        let e = e.clone();
        let token = token.clone();
        tokio::spawn(async move { e.connect(&e.echo_target(), Some(&token)).await.0 })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!waiting.is_finished(), "the second tunnel waits for a slot");
    drop(first);
    let resp = tokio::time::timeout(Duration::from_secs(5), waiting)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(status(&resp), 200, "{resp}");
}

/// 停机：开着的隧道断开、退回没用完的额度、照样记日志。
#[tokio::test]
async fn stopping_closes_tunnels_with_a_log_row_and_a_refund() {
    let e = env(EgressMode::All, &[], |_| {}).await;
    let token = e.token_with(|_| {});
    let (resp, mut s) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 200, "{resp}");
    s.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    s.read_exact(&mut buf).await.unwrap();
    e.egress.stop().await;
    let records = e.wait_for_records(1).await;
    assert_eq!(records[0].reason, "shutdown", "{records:?}");
    let day = (chrono::Utc::now() + chrono::Duration::hours(8)).date_naive();
    assert_eq!(e.ledger.used("inst-1", day), 8);
}

impl Env {
    /// 等到有 `n` 条请求登记上。
    async fn wait_for_asks(&self, n: usize) -> Vec<llm_gw::egress::MemoryAsk> {
        for _ in 0..200 {
            let a = self.ledger.asks();
            if a.len() >= n {
                return a;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        self.ledger.asks()
    }
}

fn asking(o: &mut EgressOptions) {
    o.ask_wait = Duration::from_secs(5);
    o.ask_poll = Duration::from_millis(20);
}

/// 不在名单上的网站问用户：等着的时候用户点了“访问一次”就接着连；这次任务里再访问不用再问，下一个任务重新问。
#[tokio::test]
async fn unlisted_sites_are_asked_and_once_lasts_for_the_task() {
    let e = Arc::new(env(EgressMode::Custom, &[], asking).await);
    e.ledger.set_run("inst-1", Some("run-1"));
    let token = e.token_with(|_| {});
    let waiting = {
        let (e, token) = (e.clone(), token.clone());
        tokio::spawn(async move { e.connect(&e.echo_target(), Some(&token)).await })
    };
    let asks = e.wait_for_asks(1).await;
    assert_eq!(
        (
            asks[0].host.as_str(),
            asks[0].run.as_deref(),
            asks[0].status.as_str()
        ),
        ("localhost", Some("run-1"), "pending")
    );
    assert!(!waiting.is_finished(), "the agent waits for the answer");
    e.ledger.decide(&asks[0].id, "once");
    let (resp, mut s) = tokio::time::timeout(Duration::from_secs(5), waiting)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(status(&resp), 200, "{resp}");
    s.write_all(b"ok").await.unwrap();
    let mut buf = [0u8; 2];
    s.read_exact(&mut buf).await.unwrap();
    drop(s);
    // 同一个任务：直接放行，不再登记。
    let (resp, _s) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 200, "{resp}");
    assert_eq!(e.ledger.asks().len(), 1);

    // 下一个任务：重新问；没人答，过一会儿告诉 agent 先做别的。
    let e = Arc::new(
        env(EgressMode::Custom, &[], |o| {
            o.ask_wait = Duration::from_millis(200);
            o.ask_poll = Duration::from_millis(20);
        })
        .await,
    );
    e.ledger.set_run("inst-1", Some("run-1"));
    let token = e.token_with(|_| {});
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert_eq!(status(&resp), 403, "{resp}");
    assert!(resp.contains("pending_approval"), "{resp}");
    let id = e.ledger.asks()[0].id.clone();
    e.ledger.decide(&id, "once");
    e.ledger.set_run("inst-1", Some("run-2"));
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert!(resp.contains("pending_approval"), "{resp}");
    let asks = e.ledger.asks();
    assert_eq!(asks.len(), 2);
    assert_eq!(asks[1].run.as_deref(), Some("run-2"));
    let records = e.wait_for_records(2).await;
    assert!(
        records
            .iter()
            .all(|r| !r.allowed && r.reason == "pending_approval"),
        "{records:?}"
    );
}

/// “拒绝”：这次任务里不再问，直接告诉 agent 换个办法。
#[tokio::test]
async fn a_denied_site_is_not_asked_again_in_the_task() {
    let e = Arc::new(env(EgressMode::Custom, &[], asking).await);
    e.ledger.set_run("inst-1", Some("run-1"));
    let token = e.token_with(|_| {});
    let waiting = {
        let (e, token) = (e.clone(), token.clone());
        tokio::spawn(async move { e.connect(&e.echo_target(), Some(&token)).await.0 })
    };
    let asks = e.wait_for_asks(1).await;
    e.ledger.decide(&asks[0].id, "denied");
    let resp = waiting.await.unwrap();
    assert_eq!(status(&resp), 403, "{resp}");
    assert!(resp.contains("user_denied"), "{resp}");
    let started = std::time::Instant::now();
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert!(resp.contains("user_denied"), "{resp}");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(e.ledger.asks().len(), 1);
}

/// “一直允许”：接着连，用户答应过的隧道重新核对时不会因为缓存里还没这个网站被断开。只连模型的不问。
#[tokio::test]
async fn always_allowed_tunnels_survive_rechecks_and_model_only_never_asks() {
    let e = Arc::new(
        env(EgressMode::Custom, &[], |o| {
            asking(o);
            o.recheck_every = Duration::from_millis(50);
        })
        .await,
    );
    let token = e.token_with(|_| {});
    let waiting = {
        let (e, token) = (e.clone(), token.clone());
        tokio::spawn(async move { e.connect(&e.echo_target(), Some(&token)).await })
    };
    let asks = e.wait_for_asks(1).await;
    assert_eq!(asks[0].run, None);
    e.ledger.decide(&asks[0].id, "always");
    let (resp, mut s) = waiting.await.unwrap();
    assert_eq!(status(&resp), 200, "{resp}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    s.write_all(b"still").await.unwrap();
    let mut buf = [0u8; 5];
    tokio::time::timeout(Duration::from_secs(2), s.read_exact(&mut buf))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&buf, b"still");
    // 档位改成只连模型：用户答应过的也断。
    e.directory
        .upsert_instance(instance(EgressMode::Model, &[]));
    let r = tokio::time::timeout(Duration::from_secs(3), s.read(&mut buf)).await;
    assert!(matches!(r, Ok(Ok(0)) | Ok(Err(_))), "{r:?}");
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert!(resp.contains("not_allowed"), "{resp}");
    assert_eq!(e.ledger.asks().len(), 1);
}

/// 同时在等的网站有上限：再多的不问；同一个网站多个连接一起等，只登记一条。
#[tokio::test]
async fn pending_asks_are_capped_per_instance() {
    let e = Arc::new(
        env(EgressMode::Custom, &[], |o| {
            o.ask_wait = Duration::from_millis(300);
            o.ask_poll = Duration::from_millis(20);
            o.max_pending_asks = 1;
            o.max_waiting = 1;
        })
        .await,
    );
    let token = e.token_with(|_| {});
    let first = {
        let (e, token) = (e.clone(), token.clone());
        tokio::spawn(async move { e.connect(&e.echo_target(), Some(&token)).await.0 })
    };
    e.wait_for_asks(1).await;
    // 同一个网站的第二个连接：等的名额满了，马上告诉 agent 用户还没答。
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert!(resp.contains("pending_approval"), "{resp}");
    // 别的网站：在等的网站满了，不问。
    let (resp, _) = e.connect("otherhost:443", Some(&token)).await;
    assert!(resp.contains("too_many_asks"), "{resp}");
    assert_eq!(e.ledger.asks().len(), 1);
    let resp = first.await.unwrap();
    assert!(resp.contains("pending_approval"), "{resp}");
}

/// 等用户回答的时候任务结束了（令牌代数变了）：用户随后答应了也不开隧道。
#[tokio::test]
async fn an_approval_after_the_task_ended_does_not_open_a_tunnel() {
    let e = Arc::new(env(EgressMode::Custom, &[], asking).await);
    let token = e.token_with(|_| {});
    let waiting = {
        let (e, token) = (e.clone(), token.clone());
        tokio::spawn(async move { e.connect(&e.echo_target(), Some(&token)).await.0 })
    };
    let asks = e.wait_for_asks(1).await;
    e.directory.upsert_instance(Instance {
        epoch: 1,
        ..instance(EgressMode::Custom, &[])
    });
    e.ledger.decide(&asks[0].id, "once");
    let resp = waiting.await.unwrap();
    assert_eq!(status(&resp), 407, "{resp}");
}

/// 今天的流量用完了：不问用户，直接说用完了。
#[tokio::test]
async fn a_used_up_allowance_is_reported_without_asking() {
    let e = env(EgressMode::Custom, &[], |o| {
        asking(o);
        o.daily_bytes = 100;
    })
    .await;
    let day = (chrono::Utc::now() + chrono::Duration::hours(8)).date_naive();
    use llm_gw::egress::EgressLedger;
    e.ledger
        .reserve("inst-1", "user-1", day, 100, 100)
        .await
        .unwrap();
    let (resp, _) = e
        .connect(&e.echo_target(), Some(&e.token_with(|_| {})))
        .await;
    assert_eq!(status(&resp), 429, "{resp}");
    assert!(resp.contains("quota"), "{resp}");
    assert!(e.ledger.asks().is_empty());
}

/// 等用户回答时客户端等不及断开了：照样记一行日志。
#[tokio::test]
async fn connections_dropped_while_waiting_are_logged() {
    let e = Arc::new(env(EgressMode::Custom, &[], asking).await);
    let token = e.token_with(|_| {});
    let mut s = TcpStream::connect(e.proxy).await.unwrap();
    let cred = base64::engine::general_purpose::STANDARD.encode(format!("x:{token}"));
    let target = e.echo_target();
    s.write_all(
        format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: Basic {cred}\r\n\r\n")
            .as_bytes(),
    )
    .await
    .unwrap();
    e.wait_for_asks(1).await;
    drop(s);
    let records = e.wait_for_records(1).await;
    assert_eq!(
        records.iter().map(|r| r.reason).collect::<Vec<_>>(),
        ["client_gone"]
    );
}
