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
        dedicated: false,
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

/// 一小时里问用户问得太多了：不再问，告诉 agent 的是这个原因（不是“在等别的网站”）。
#[tokio::test]
async fn too_many_asks_in_an_hour_have_their_own_reason() {
    let e = env(EgressMode::Custom, &[], |o| {
        o.ask_wait = Duration::from_millis(100);
        o.ask_poll = Duration::from_millis(20);
        o.max_asks_per_hour = 1;
    })
    .await;
    let token = e.token_with(|_| {});
    let (resp, _) = e.connect(&e.echo_target(), Some(&token)).await;
    assert!(resp.contains("pending_approval"), "{resp}");
    let (resp, _) = e.connect("otherhost:443", Some(&token)).await;
    assert!(resp.contains("ask_rate"), "{resp}");
    // 用户答应了的不算：答应以后又能问新网站。
    let id = e.ledger.asks()[0].id.clone();
    e.ledger.decide(&id, "always");
    let (resp, _) = e.connect("otherhost:443", Some(&token)).await;
    assert!(resp.contains("pending_approval"), "{resp}");
}

/// 浏览器通行证（docs/browser.md 第 4.1 节）只给浏览器通道用：拿它走普通通道被拒。
#[tokio::test]
async fn the_browser_pass_does_not_work_on_the_direct_lane() {
    let e = env(EgressMode::All, &[], |_| {}).await;
    let pass = e
        .issuer
        .issue_for(
            TokenRequest {
                ep: 0,
                iid: "inst-1".into(),
                uid: "user-1".into(),
                grant: "grant-1".into(),
                sbx: "sbx-1".into(),
                net: Some("127.0.0.1".into()),
            },
            Some(auth::sandbox_token::AUD_BROWSER),
            600,
            now(),
        )
        .unwrap();
    let (resp, _) = e.connect(&e.echo_target(), Some(&pass)).await;
    assert_eq!(status(&resp), 407, "{resp}");
    // 普通令牌照常。
    let (resp, _) = e
        .connect(&e.echo_target(), Some(&e.token_with(|_| {})))
        .await;
    assert_eq!(status(&resp), 200, "{resp}");
}

// ---- 浏览器通道（docs/browser.md 第 3.3、4.3 节）----

impl Env {
    fn browser_pass(&self) -> String {
        self.browser_pass_at(0)
    }

    /// 令牌代数是 `ep` 的浏览器通行证（下一次任务尝试）。
    fn browser_pass_at(&self, ep: u64) -> String {
        self.issuer
            .issue_for(
                TokenRequest {
                    ep,
                    iid: "inst-1".into(),
                    uid: "user-1".into(),
                    grant: "grant-1".into(),
                    sbx: "sbx-1".into(),
                    net: Some("127.0.0.1".into()),
                },
                Some(auth::sandbox_token::AUD_BROWSER),
                600,
                now(),
            )
            .unwrap()
    }

    /// 用户名是 `browser` 的 CONNECT（转发口发的）。
    async fn browser_connect(&self, target: &str, pass: &str, page: &str) -> (String, TcpStream) {
        let mut s = TcpStream::connect(self.proxy).await.unwrap();
        let cred = base64::engine::general_purpose::STANDARD.encode(format!("browser:{pass}"));
        let head = format!(
            "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: Basic {cred}\r\n\
             X-Thinktin-Browser: kind=res; page={page}\r\n\r\n"
        );
        s.write_all(head.as_bytes()).await.unwrap();
        let mut resp = Vec::new();
        let mut byte = [0u8; 1];
        while !resp.ends_with(b"\r\n\r\n") {
            match tokio::time::timeout(Duration::from_secs(5), s.read(&mut byte)).await {
                Ok(Ok(1)) => resp.push(byte[0]),
                _ => break,
            }
        }
        let text = String::from_utf8_lossy(&resp).into_owned();
        if !text.starts_with("HTTP/1.1 200") {
            let mut rest = String::new();
            let _ = tokio::time::timeout(Duration::from_secs(2), s.read_to_string(&mut rest)).await;
            return (format!("{text}{rest}"), s);
        }
        (text, s)
    }

    /// `POST /v1/browser/ask`，返回状态码和回答。
    async fn ask(&self, pass: Option<&str>, body: serde_json::Value) -> (u16, serde_json::Value) {
        let mut s = TcpStream::connect(self.proxy).await.unwrap();
        let body = body.to_string();
        let mut head = format!(
            "POST /v1/browser/ask HTTP/1.1\r\nHost: egress\r\nContent-Type: application/json\r\n\
             Content-Length: {}\r\n",
            body.len()
        );
        if let Some(p) = pass {
            head.push_str(&format!("Authorization: Bearer {p}\r\n"));
        }
        head.push_str("\r\n");
        s.write_all(head.as_bytes()).await.unwrap();
        s.write_all(body.as_bytes()).await.unwrap();
        let mut out = String::new();
        tokio::time::timeout(Duration::from_secs(10), s.read_to_string(&mut out))
            .await
            .unwrap()
            .unwrap();
        let (head, body) = out.split_once("\r\n\r\n").unwrap_or((&out, ""));
        (
            status(head),
            serde_json::from_str(body).unwrap_or(serde_json::Value::Null),
        )
    }
}

fn ask_body(host: &str, wait: u64) -> serde_json::Value {
    serde_json::json!({"host": host, "url": format!("https://{host}/a"), "from": "news.example.com",
        "cause": "link", "wait_secs": wait})
}

fn browser_env_opts(o: &mut EgressOptions) {
    o.browser_lanes = true;
    o.ask_poll = Duration::from_millis(20);
}

#[tokio::test]
async fn browser_page_resources_are_not_asked_but_keep_the_other_checks() {
    let e = env(EgressMode::Dev, &[], browser_env_opts).await;
    let pass = e.browser_pass();
    // 直接上网会问用户的网站，浏览器通道不问、直接连。
    let (resp, mut s) = e
        .browser_connect(&e.echo_target(), &pass, "news.example.com")
        .await;
    assert_eq!(status(&resp), 200, "{resp}");
    s.write_all(b"page bytes").await.unwrap();
    let mut buf = [0u8; 10];
    s.read_exact(&mut buf).await.unwrap();
    drop(s);
    assert!(e.ledger.asks().is_empty());
    let records = e.wait_for_records(1).await;
    let r = &records[0];
    assert!(r.allowed, "{r:?}");
    assert_eq!(r.via, proto::egress::Via::Browser);
    assert_eq!(r.kind, Some("res"));
    assert_eq!(r.page_site.as_deref(), Some("news.example.com"));
    assert_eq!((r.bytes_up, r.bytes_down), (10, 10));
    // 沙箱令牌冒充浏览器：不行。
    let (resp, _) = e
        .browser_connect(&e.echo_target(), &e.token_with(|_| {}), "x")
        .await;
    assert_eq!(status(&resp), 407, "{resp}");

    // 没开浏览器通道：用户名 browser 一律 407。
    let off = env(EgressMode::All, &[], |_| {}).await;
    let (resp, _) = off
        .browser_connect(&off.echo_target(), &off.browser_pass(), "x")
        .await;
    assert_eq!(status(&resp), 407, "{resp}");
    // 只连模型：整条通道不能用。
    let model = env(EgressMode::Model, &[], browser_env_opts).await;
    let (resp, _) = model
        .browser_connect(&model.echo_target(), &model.browser_pass(), "x")
        .await;
    assert_eq!(status(&resp), 403, "{resp}");
    assert!(resp.contains("not_allowed"), "{resp}");
    // 禁段照样拒绝。
    let blocked = env(EgressMode::Dev, &[], |o| {
        browser_env_opts(o);
        o.deny = vec!["127.0.0.0/8".parse().unwrap()];
    })
    .await;
    let (resp, _) = blocked
        .browser_connect(&blocked.echo_target(), &blocked.browser_pass(), "x")
        .await;
    assert_eq!(status(&resp), 403, "{resp}");
    assert!(resp.contains("private_address"), "{resp}");
    // 每天的额度和直接上网共用：用完了浏览器也不行。
    let spent = env(EgressMode::Dev, &[], |o| {
        browser_env_opts(o);
        o.daily_bytes = 0;
    })
    .await;
    let (resp, _) = spent
        .browser_connect(&spent.echo_target(), &spent.browser_pass(), "x")
        .await;
    assert_eq!(status(&resp), 429, "{resp}");
    assert!(resp.contains("quota"), "{resp}");
}

#[tokio::test]
async fn browser_tunnels_have_their_own_cap() {
    let e = env(EgressMode::All, &[], |o| {
        browser_env_opts(o);
        o.max_tunnels = 1;
        o.browser_max_tunnels = 2;
        o.browser_slot_wait = Duration::from_millis(200);
    })
    .await;
    let pass = e.browser_pass();
    let (resp, _direct) = e
        .connect(&e.echo_target(), Some(&e.token_with(|_| {})))
        .await;
    assert_eq!(status(&resp), 200, "{resp}");
    // 直接上网的名额满了，浏览器的照样能开两条。
    let (resp, _b1) = e.browser_connect(&e.echo_target(), &pass, "a.com").await;
    assert_eq!(status(&resp), 200, "{resp}");
    let (resp, _b2) = e.browser_connect(&e.echo_target(), &pass, "a.com").await;
    assert_eq!(status(&resp), 200, "{resp}");
    let (resp, _) = e.browser_connect(&e.echo_target(), &pass, "a.com").await;
    assert_eq!(status(&resp), 429, "{resp}");
    assert!(resp.contains("too_many_tunnels"), "{resp}");
}

#[tokio::test]
async fn the_browser_asks_about_a_site_once_per_task() {
    let e = env(EgressMode::Dev, &[], browser_env_opts).await;
    e.ledger.set_run("inst-1", Some("run-1"));
    let pass = e.browser_pass();
    // 没开、没通行证、沙箱令牌：都不行。
    let off = env(EgressMode::Dev, &[], |_| {}).await;
    assert_eq!(
        off.ask(Some(&off.browser_pass()), ask_body("localhost", 0))
            .await
            .0,
        404
    );
    assert_eq!(e.ask(None, ask_body("localhost", 0)).await.0, 401);
    assert_eq!(
        e.ask(Some(&e.token_with(|_| {})), ask_body("localhost", 0))
            .await
            .0,
        401
    );
    // 第一次：登记一条浏览器提问，没人答就是 pending。
    let (code, reply) = e.ask(Some(&pass), ask_body("localhost", 0)).await;
    assert_eq!(code, 200);
    assert_eq!(reply["result"], "pending", "{reply}");
    let asks = e.ledger.asks();
    assert_eq!(asks.len(), 1);
    assert_eq!(reply["request_id"], asks[0].id.as_str());
    assert_eq!(asks[0].via, proto::egress::Via::Browser);
    assert_eq!(asks[0].site.as_deref(), Some("localhost"));
    // 再问一次还是那一条（用户只看到一张卡片）。
    let (_, reply) = e.ask(Some(&pass), ask_body("localhost", 0)).await;
    assert_eq!(reply["result"], "pending");
    assert_eq!(e.ledger.asks().len(), 1);
    // 等的时候用户点了“访问一次”。
    let ledger = e.ledger.clone();
    let id = asks[0].id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        ledger.decide(&id, "once");
    });
    let (_, reply) = e.ask(Some(&pass), ask_body("localhost", 5)).await;
    assert_eq!(reply["result"], "allowed", "{reply}");
    assert_eq!(reply["scope"], "once");
    // 真的问了用户：带着那条请求（守门据此说“用户允许了”）。
    assert_eq!(reply["request_id"], asks[0].id.as_str());
    // 这次任务里再打开同一个网站：不用再问，也不说用户刚允许。
    let (_, reply) = e.ask(Some(&pass), ask_body("localhost", 0)).await;
    assert_eq!(reply["result"], "allowed");
    assert!(reply.get("request_id").is_none(), "{reply}");
    assert_eq!(e.ledger.asks().len(), 1);
    // 换了任务要重新问；这次拒绝了，这次任务里不再问、浏览器通道也不放这个网站。
    e.ledger.set_run("inst-1", Some("run-2"));
    let (_, reply) = e.ask(Some(&pass), ask_body("localhost", 0)).await;
    assert_eq!(reply["result"], "pending");
    let id = reply["request_id"].as_str().unwrap().to_owned();
    e.ledger.decide(&id, "denied");
    let (_, reply) = e.ask(Some(&pass), ask_body("localhost", 0)).await;
    assert_eq!(reply["result"], "denied", "{reply}");
    let (resp, _) = e.browser_connect(&e.echo_target(), &pass, "x").await;
    assert_eq!(status(&resp), 403, "{resp}");
    assert!(resp.contains("user_denied"), "{resp}");
    // 问询记日志：via=browser, kind=ask，来源网站按主域名。
    let records = e.wait_for_records(5).await;
    let ask = records
        .iter()
        .find(|r| r.kind == Some("ask") && r.allowed)
        .expect("an allowed ask row");
    assert_eq!(ask.via, proto::egress::Via::Browser);
    assert_eq!(ask.page_site.as_deref(), Some("example.com"));
}

#[tokio::test]
async fn the_browser_ask_checks_the_address_mode_and_allowance_first() {
    // 内网地址：不问用户、不登记。
    let e = env(EgressMode::Dev, &[], |o| {
        browser_env_opts(o);
        o.deny = vec!["127.0.0.0/8".parse().unwrap()];
    })
    .await;
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    assert_eq!(reply["result"], "private_address", "{reply}");
    assert!(e.ledger.asks().is_empty());
    // 解析不到。
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("nx.invalid", 0))
        .await;
    assert_eq!(reply["result"], "resolve", "{reply}");
    // 只连模型：不问，名字也不解析（解析本身会把名字带出去）。
    let e = env(EgressMode::Model, &[], browser_env_opts).await;
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    assert_eq!(reply["result"], "not_allowed", "{reply}");
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("nx.invalid", 0))
        .await;
    assert_eq!(reply["result"], "not_allowed", "{reply}");
    // 今天的流量用完了：不问。
    let e = env(EgressMode::Dev, &[], |o| {
        browser_env_opts(o);
        o.daily_bytes = 0;
    })
    .await;
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    assert_eq!(reply["result"], "quota", "{reply}");
    assert!(e.ledger.asks().is_empty());
    // 全部公网的档位：直接允许（没问用户，不带请求）。问询和页面资源的次数分开算。
    let e = env(EgressMode::All, &[], |o| {
        browser_env_opts(o);
        o.browser_attempts_per_minute = 1;
    })
    .await;
    for _ in 0..3 {
        let (_, reply) = e
            .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
            .await;
        assert_eq!(reply["result"], "allowed");
        assert_eq!(reply["scope"], "default");
        assert!(reply.get("request_id").is_none(), "{reply}");
    }
    let (resp, _) = e
        .browser_connect(&e.echo_target(), &e.browser_pass(), "x")
        .await;
    assert_eq!(status(&resp), 200, "{resp}");
    // 一直允许的网站：同一个网站都算。
    let e = env(EgressMode::Dev, &["localhost"], browser_env_opts).await;
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    assert_eq!(reply["result"], "allowed");
    assert_eq!(reply["scope"], "always");
    // 这次任务已经有太多网站在等。
    let e = env(EgressMode::Dev, &[], |o| {
        browser_env_opts(o);
        o.max_pending_asks = 0;
    })
    .await;
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    assert_eq!(reply["result"], "too_many_asks", "{reply}");
    // 坏的请求。
    let (code, _) = e
        .ask(Some(&e.browser_pass()), serde_json::json!({"nope": 1}))
        .await;
    assert_eq!(code, 400);
}

/// 直接上网的回答只算它那个网址；浏览器里的按网站（docs/browser.md 第 1.2 节）。
#[tokio::test]
async fn direct_answers_count_for_their_own_host_only_in_the_browser() {
    use llm_gw::egress::{Answer, Asked, EgressLedger};
    use proto::egress::Via;
    let l = MemoryEgressLedger::default();
    l.set_run("i", Some("r"));
    let ask = |host: &'static str, via| {
        let l = &l;
        async move {
            match l
                .ask("u", "i", host, Some("r"), 5, 20, via, Some("zhihu.com"))
                .await
                .unwrap()
            {
                Asked::Request(id) => id,
                other => panic!("{other:?}"),
            }
        }
    };
    let direct = ask("gist.zhihu.com", Via::Direct).await;
    l.decide(&direct, "denied");
    let (_, a) = l
        .site_decision("i", "zhihu.com", "www.zhihu.com")
        .await
        .unwrap();
    assert_eq!(a, None, "a curl denial does not block the whole site");
    let (_, a) = l
        .site_decision("i", "zhihu.com", "gist.zhihu.com")
        .await
        .unwrap();
    assert_eq!(a, Some((Answer::Denied, Via::Direct)));
    let browser = ask("www.zhihu.com", Via::Browser).await;
    l.decide(&browser, "once");
    let (_, a) = l
        .site_decision("i", "zhihu.com", "zhuanlan.zhihu.com")
        .await
        .unwrap();
    assert_eq!(
        a,
        Some((Answer::Allowed, Via::Browser)),
        "a browser answer covers the site"
    );
}

/// 直接上网时答的只算那个网址：浏览器问到同一个网址，回答带上这个范围（守门只记这个网址）。
#[tokio::test]
async fn direct_answers_reach_the_browser_as_host_only() {
    use llm_gw::egress::{Asked, EgressLedger};
    use proto::egress::Via;
    let e = env(EgressMode::Dev, &[], browser_env_opts).await;
    e.ledger.set_run("inst-1", Some("run-1"));
    let direct = |status: &'static str| {
        let ledger = e.ledger.clone();
        async move {
            let Asked::Request(id) = ledger
                .ask(
                    "user-1",
                    "inst-1",
                    "localhost",
                    Some("run-1"),
                    5,
                    20,
                    Via::Direct,
                    Some("localhost"),
                )
                .await
                .unwrap()
            else {
                panic!("not asked")
            };
            ledger.decide(&id, status);
        }
    };
    direct("denied").await;
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    assert_eq!(reply["result"], "denied", "{reply}");
    assert_eq!(reply["scope"], "host");
    e.ledger.set_run("inst-1", Some("run-2"));
    let ledger = e.ledger.clone();
    let Asked::Request(id) = ledger
        .ask(
            "user-1",
            "inst-1",
            "localhost",
            Some("run-2"),
            5,
            20,
            Via::Direct,
            Some("localhost"),
        )
        .await
        .unwrap()
    else {
        panic!("not asked")
    };
    ledger.decide(&id, "once");
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    assert_eq!(reply["result"], "allowed", "{reply}");
    assert_eq!(reply["scope"], "default");
}

/// 浏览器通道“这次任务拒绝过”的缓存不带到下一次任务尝试（令牌代数变了）。
#[tokio::test]
async fn the_site_denial_cache_does_not_cross_task_attempts() {
    let e = env(EgressMode::Dev, &[], browser_env_opts).await;
    e.ledger.set_run("inst-1", Some("run-1"));
    let (_, reply) = e
        .ask(Some(&e.browser_pass()), ask_body("localhost", 0))
        .await;
    let id = reply["request_id"].as_str().unwrap().to_owned();
    e.ledger.decide(&id, "denied");
    let (resp, _) = e
        .browser_connect(&e.echo_target(), &e.browser_pass(), "x")
        .await;
    assert_eq!(status(&resp), 403, "{resp}");
    // 下一次任务尝试：代数加一、换了任务。15 秒的缓存里还是“拒绝过”，但不算这次的。
    let mut next = instance(EgressMode::Dev, &[]);
    next.epoch = 1;
    e.directory.upsert_instance(next);
    e.ledger.set_run("inst-1", Some("run-2"));
    let (resp, _) = e
        .browser_connect(&e.echo_target(), &e.browser_pass_at(1), "x")
        .await;
    assert_eq!(status(&resp), 200, "{resp}");
}
