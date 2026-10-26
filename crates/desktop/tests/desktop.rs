//! 电脑端工具服务（14.2）的端到端测试：真实数据库、进程里的设备中继、平台一侧的 `DeviceCalls`，
//! 电脑端用 `Desktop` + 文件工具，手机由测试扮演（用固定的 P-256 私钥签名）。没有 DATABASE_URL 时跳过。

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use auth::access_token::{AccessTokenIssuer, AccessTokenVerifier};
use auth::signed::{Signer25519, Verifier25519};
use client_core::pairing::{
    ApprovalDecisionBody, ApprovalRequestBody, CapabilityBody, CapabilityGrant, PairConfirmBody,
    PairResponseBody, PairingOffer, RevocationBody, approval_message, capability_message,
    decode_signature, encode_public_key, encode_signature, pairing_response_message,
    parse_pairing_offer, verify_pairing_confirmation,
};
use desktop::files::FileTools;
use desktop::{
    Activity, Desktop, DesktopConfig, PairedPhone, PairingStatus, SoftwareKey, Status, TokenSource,
};
use orchestrator::computer::{CallOutput, DeviceCalls};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use proto::domain::{DeviceId, DeviceMessageKind, DevicePlatform, SessionId, UserId};
use relay::{Relay, RelayConfig};
use serde_json::{Value, json};
use store::testing::TestDb;

/// `[7; 32]` 这把私钥的公钥（client-core 的配对测试里同一把）。
const PHONE_KEY: &str = "Ax4YUy_UdUwC8wQdnHXOszuD_9gax85P6ILMscmLxYlu";
const WAIT: Duration = Duration::from_secs(15);

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn phone_sign(message: &[u8]) -> String {
    let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
    let sig: Signature = key.sign(message);
    encode_signature(&sig.to_bytes())
}

fn stranger_sign(message: &[u8]) -> String {
    let key = SigningKey::from_slice(&[9u8; 32]).unwrap();
    let sig: Signature = key.sign(message);
    encode_signature(&sig.to_bytes())
}

struct Tokens {
    issuer: AccessTokenIssuer,
    user: UserId,
    device: DeviceId,
    session: SessionId,
}

#[async_trait]
impl TokenSource for Tokens {
    async fn access_token(&self, _refresh: bool) -> Result<String, String> {
        self.issuer
            .issue(
                &self.user.to_string(),
                &self.device.to_string(),
                &self.session.to_string(),
                now(),
            )
            .map_err(|e| e.to_string())
    }
}

struct Env {
    t: TestDb,
    calls: DeviceCalls,
    desktop: Desktop,
    user: UserId,
    mac: DeviceId,
    phone: DeviceId,
    home: PathBuf,
    data: tempfile::TempDir,
    _home_dir: tempfile::TempDir,
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let signer = Signer25519::generate("a1").unwrap();
    let mut keys = Verifier25519::new();
    keys.add_key_b64("a1", &signer.verifying_key_b64()).unwrap();
    let relay = Relay::new(
        t.db.clone(),
        AccessTokenVerifier(keys),
        RelayConfig {
            heartbeat: Duration::from_secs(5),
            ..RelayConfig::default()
        },
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(relay.serve(listener, std::future::pending()));
    let calls = DeviceCalls::new(t.db.clone());
    let listening = calls.clone();
    tokio::spawn(async move { listening.listen(std::future::pending()).await });

    let mut w = t.db.worker().await.unwrap();
    let (u, _) = w.upsert_user_by_phone("+8613600000001").await.unwrap();
    let mac = w
        .create_device(u.id, DevicePlatform::Macos, "MacBook", None)
        .await
        .unwrap();
    let session = SessionId::new();
    w.create_session(
        session,
        u.id,
        mac,
        session.0.as_bytes(),
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    let phone = w
        .create_device(u.id, DevicePlatform::Ios, "iPhone", None)
        .await
        .unwrap();
    w.commit().await.unwrap();

    let home_dir = tempfile::tempdir().unwrap();
    let home = std::fs::canonicalize(home_dir.path()).unwrap();
    std::fs::create_dir(home.join("Documents")).unwrap();
    std::fs::write(home.join("Documents/plan.md"), "ship it").unwrap();
    std::fs::write(home.join("secret.txt"), "do not read").unwrap();
    let data = tempfile::tempdir().unwrap();
    let mut cfg = DesktopConfig::new(
        format!("ws://{addr}/v1/connect"),
        mac.to_string(),
        data.path(),
    );
    cfg.approval_ttl = Duration::from_secs(20);
    let desktop = Desktop::new(
        cfg,
        Arc::new(Tokens {
            issuer: AccessTokenIssuer(signer),
            user: u.id,
            device: mac,
            session,
        }),
        Arc::new(FileTools::for_home(&home)),
    )
    .unwrap();
    desktop
        .pair(PairedPhone {
            device_id: phone.to_string(),
            public_key: PHONE_KEY.into(),
        })
        .unwrap();
    let running = desktop.clone();
    tokio::spawn(async move { running.run().await });
    let env = Env {
        t,
        calls,
        desktop,
        user: u.id,
        mac,
        phone,
        home,
        data,
        _home_dir: home_dir,
    };
    // 等电脑连上中继、报上工具。
    tokio::time::timeout(WAIT, async {
        loop {
            let mut w = env.t.db.worker().await.unwrap();
            let online = w.online_computer(env.user).await.unwrap();
            w.rollback().await.unwrap();
            if online.is_some_and(|(_, tools)| tools.iter().any(|t| t == "computer_run")) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the computer comes online");
    assert_eq!(env.desktop.status(), Status::Connected);
    Some(env)
}

impl Env {
    async fn call(&self, tool: &str, args: Value) -> CallOutput {
        self.calls
            .call(self.user, None, tool, args, Duration::from_secs(30))
            .await
            .unwrap()
    }

    /// 手机经平台发一条消息给电脑。
    async fn phone_sends(&self, kind: DeviceMessageKind, body: Value) {
        let mut t = self.t.db.tenant(self.user).await.unwrap();
        t.send_device_message(self.phone, self.mac, kind, &body)
            .await
            .unwrap();
        t.commit().await.unwrap();
    }

    /// 手机收到的审批请求（等它到）。
    async fn approval_request(&self) -> client_core::pairing::ApprovalRequest {
        tokio::time::timeout(WAIT, async {
            loop {
                let mut t = self.t.db.tenant(self.user).await.unwrap();
                let inbox = t.pending_device_messages(self.phone, 10).await.unwrap();
                if let Some(m) = inbox.first() {
                    t.ack_device_messages(self.phone, &[m.id]).await.unwrap();
                    t.commit().await.unwrap();
                    assert_eq!(m.kind, DeviceMessageKind::ApprovalRequest);
                    let body: ApprovalRequestBody = serde_json::from_value(m.body.clone()).unwrap();
                    return body.request;
                }
                t.rollback().await.unwrap();
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("an approval request reaches the phone")
    }

    async fn wait_grants(&self, n: usize) {
        tokio::time::timeout(WAIT, async {
            while self.desktop.grants().len() != n {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("the computer takes the capability change");
    }

    fn audit(&self) -> Vec<Value> {
        std::fs::read_to_string(self.data.path().join("audit.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }
}

fn text(out: &CallOutput) -> &str {
    out.content[0]["text"].as_str().unwrap_or_default()
}

/// 普通操作要手机签发的能力令牌：没有令牌不做；令牌只覆盖授权的目录；签名不对的令牌不收；吊销后又不做了。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ordinary_tools_need_a_capability_from_the_phone() {
    let Some(e) = env().await else { return };
    let plan = e.home.join("Documents/plan.md");
    let read = json!({ "path": plan.to_str().unwrap() });
    let mut activity = e.desktop.watch_activity();

    let out = e.call("computer_read_file", read.clone()).await;
    assert!(
        out.is_error && text(&out).contains("has not allowed"),
        "{out:?}"
    );
    assert_eq!(out.device, e.mac);
    assert!(!activity.has_changed().unwrap(), "拒绝的调用不算正在执行");

    let grant = CapabilityGrant {
        desktop_id: e.mac.to_string(),
        token_id: "g1".into(),
        dirs: vec![e.home.join("Documents").to_str().unwrap().to_owned()],
        apps: vec![],
        expires_at: now() + 3600,
    };
    // 签名不对的令牌不收。
    let forged = CapabilityBody {
        grant: grant.clone(),
        signature: stranger_sign(&capability_message(grant.clone()).unwrap()),
    };
    e.phone_sends(
        DeviceMessageKind::Capability,
        serde_json::to_value(forged).unwrap(),
    )
    .await;
    let signed = CapabilityBody {
        grant: grant.clone(),
        signature: phone_sign(&capability_message(grant.clone()).unwrap()),
    };
    e.phone_sends(
        DeviceMessageKind::Capability,
        serde_json::to_value(signed).unwrap(),
    )
    .await;
    e.wait_grants(1).await;
    assert_eq!(e.desktop.grants(), vec![grant]);

    let out = e.call("computer_read_file", read.clone()).await;
    assert_eq!((text(&out), out.is_error), ("ship it", false));
    // 执行时报过“正在执行”，结束后回到空闲（菜单栏的“正在被控制”）。
    assert!(activity.has_changed().unwrap());
    assert_eq!(*activity.borrow_and_update(), Activity::default());
    let out = e
        .call(
            "computer_write_file",
            json!({ "path": e.home.join("Documents/notes.md").to_str().unwrap(), "content": "hi" }),
        )
        .await;
    assert!(!out.is_error, "{out:?}");
    // 授权目录外面的不行。
    let out = e
        .call(
            "computer_read_file",
            json!({ "path": e.home.join("secret.txt").to_str().unwrap() }),
        )
        .await;
    assert!(out.is_error, "{out:?}");
    // 截图之类电脑上没有的工具：平台按 hello 报的工具拦下。
    assert!(
        e.calls
            .call(
                e.user,
                None,
                "computer_screenshot",
                json!({}),
                Duration::from_secs(5)
            )
            .await
            .is_err()
    );

    // 吊销后又不做了。
    e.phone_sends(
        DeviceMessageKind::Revocation,
        serde_json::to_value(RevocationBody {
            token_id: "g1".into(),
        })
        .unwrap(),
    )
    .await;
    e.wait_grants(0).await;
    let out = e.call("computer_read_file", read).await;
    assert!(out.is_error, "{out:?}");

    // 每个调用都记进本地审计日志：参数只记摘要，不记读到、写进的内容。
    let audit = e.audit();
    let decisions: Vec<&str> = audit
        .iter()
        .map(|l| l["decision"].as_str().unwrap())
        .collect();
    assert_eq!(
        decisions,
        ["denied", "allowed", "allowed", "denied", "denied"]
    );
    assert!(
        audit.iter().all(|l| !l.to_string().contains("ship it")
            && l["arguments_digest"]
                .as_str()
                .is_some_and(|d| d.len() == 64)),
        "{audit:?}"
    );
    // 令牌存在本地，重启后还在（吊销也在）。
    let state: Value =
        serde_json::from_slice(&std::fs::read(e.data.path().join("desktop-state.json")).unwrap())
            .unwrap();
    assert_eq!(state["revoked"], json!(["g1"]));
}

/// 高危操作每次都要手机签名批准：批准了才做；拒绝、签名不对都不做。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn risky_tools_wait_for_the_phone_to_approve() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let run = |command: &'static str| {
        let e = e.clone();
        tokio::spawn(async move {
            e.call(
                "computer_run",
                json!({ "command": command, "reason": "check the toolchain" }),
            )
            .await
        })
    };
    let decide = |request: &client_core::pairing::ApprovalRequest,
                  approve: bool,
                  sign: fn(&[u8]) -> String| {
        let message = approval_message(request.clone(), approve).unwrap();
        ApprovalDecisionBody {
            request_id: request.request_id.clone(),
            approve,
            signature: sign(&message),
        }
    };

    // 批准：做了。
    let waiting = run("echo approved");
    let request = e.approval_request().await;
    assert_eq!(request.tool, "computer_run");
    assert_eq!(request.desktop_id, e.mac.to_string());
    assert!(
        request.summary.contains("echo approved")
            && request.summary.contains("check the toolchain"),
        "{}",
        request.summary
    );
    e.phone_sends(
        DeviceMessageKind::ApprovalDecision,
        serde_json::to_value(decide(&request, true, phone_sign)).unwrap(),
    )
    .await;
    let out = waiting.await.unwrap();
    assert!(!out.is_error, "{out:?}");
    assert!(text(&out).contains("approved"), "{out:?}");

    // 拒绝：不做。
    let waiting = run("echo declined");
    let request = e.approval_request().await;
    e.phone_sends(
        DeviceMessageKind::ApprovalDecision,
        serde_json::to_value(decide(&request, false, phone_sign)).unwrap(),
    )
    .await;
    let out = waiting.await.unwrap();
    assert!(out.is_error && text(&out).contains("declined"), "{out:?}");

    // 不是配对的手机签的：不做。
    let waiting = run("echo forged");
    let request = e.approval_request().await;
    e.phone_sends(
        DeviceMessageKind::ApprovalDecision,
        serde_json::to_value(decide(&request, true, stranger_sign)).unwrap(),
    )
    .await;
    let out = waiting.await.unwrap();
    assert!(
        out.is_error && text(&out).contains("could not be verified"),
        "{out:?}"
    );

    let decisions: Vec<String> = e
        .audit()
        .iter()
        .map(|l| l["decision"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(decisions, ["approved", "declined", "declined"]);
}

/// 配对（14.8）：电脑出二维码，手机扫码签名回复，电脑验签、签确认发回、记下手机（之前的令牌作废）。
/// 签名不对的回复让这个二维码作废；不是当前二维码的回复不理。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pairs_with_a_phone_that_scanned_the_code() {
    let Some(e) = env().await else { return };
    // 先有一张旧手机给的令牌：换了手机就作废。
    let grant = CapabilityGrant {
        desktop_id: e.mac.to_string(),
        token_id: "old-token".into(),
        dirs: vec![e.home.join("Documents").display().to_string()],
        apps: vec![],
        expires_at: now() + 3600,
    };
    e.phone_sends(
        DeviceMessageKind::Capability,
        serde_json::to_value(CapabilityBody {
            signature: phone_sign(&capability_message(grant.clone()).unwrap()),
            grant,
        })
        .unwrap(),
    )
    .await;
    e.wait_grants(1).await;

    let new_phone = SigningKey::from_slice(&[8u8; 32]).unwrap();
    let new_phone_key = encode_public_key(
        new_phone
            .verifying_key()
            .to_sec1_point(false)
            .as_bytes()
            .to_vec(),
    )
    .unwrap();
    let respond = |offer: &PairingOffer, key: &SigningKey, nonce: &str| {
        let message =
            pairing_response_message(offer.clone(), e.phone.to_string(), new_phone_key.clone())
                .unwrap();
        let sig: Signature = key.sign(&message);
        serde_json::to_value(PairResponseBody {
            nonce: nonce.to_owned(),
            phone_key: new_phone_key.clone(),
            signature: encode_signature(&sig.to_bytes()),
        })
        .unwrap()
    };
    let mut pairing = e.desktop.watch_pairing();

    // 签名不对：这个二维码作废，手机没换。
    let uri = e
        .desktop
        .start_pairing(Arc::new(SoftwareKey::generate()), Duration::from_secs(300))
        .unwrap();
    let offer = parse_pairing_offer(uri).unwrap();
    assert_eq!(offer.desktop_id, e.mac.to_string());
    let stranger = SigningKey::from_slice(&[9u8; 32]).unwrap();
    e.phone_sends(
        DeviceMessageKind::PairResponse,
        respond(&offer, &stranger, &offer.nonce),
    )
    .await;
    tokio::time::timeout(
        WAIT,
        pairing.wait_for(|s| matches!(s, PairingStatus::Failed { .. })),
    )
    .await
    .expect("the bad response is refused")
    .unwrap();
    assert_eq!(e.desktop.paired_phone().unwrap().public_key, PHONE_KEY);

    // 重新出二维码，手机签对了：记下新手机，签确认发回。旧二维码的回复不理。
    let desktop_key = Arc::new(SoftwareKey::generate());
    let uri = e
        .desktop
        .start_pairing(desktop_key, Duration::from_secs(300))
        .unwrap();
    let fresh = parse_pairing_offer(uri).unwrap();
    assert_ne!(fresh.nonce, offer.nonce);
    e.phone_sends(
        DeviceMessageKind::PairResponse,
        respond(&offer, &new_phone, &offer.nonce),
    )
    .await;
    e.phone_sends(
        DeviceMessageKind::PairResponse,
        respond(&fresh, &new_phone, &fresh.nonce),
    )
    .await;
    let status = tokio::time::timeout(
        WAIT,
        pairing.wait_for(|s| matches!(s, PairingStatus::Paired { .. })),
    )
    .await
    .expect("the phone is paired")
    .unwrap()
    .clone();
    assert_eq!(
        status,
        PairingStatus::Paired {
            phone_id: e.phone.to_string()
        }
    );
    assert_eq!(
        e.desktop.paired_phone(),
        Some(PairedPhone {
            device_id: e.phone.to_string(),
            public_key: new_phone_key.clone(),
        })
    );
    assert!(
        e.desktop.grants().is_empty(),
        "the old phone's grants are gone"
    );

    // 手机收到电脑签的确认，用二维码里的电脑公钥验得过。
    let confirm = tokio::time::timeout(WAIT, async {
        loop {
            let mut t = e.t.db.tenant(e.user).await.unwrap();
            let inbox = t.pending_device_messages(e.phone, 10).await.unwrap();
            if let Some(m) = inbox
                .iter()
                .find(|m| m.kind == DeviceMessageKind::PairConfirm)
            {
                t.ack_device_messages(e.phone, &[m.id]).await.unwrap();
                t.commit().await.unwrap();
                return serde_json::from_value::<PairConfirmBody>(m.body.clone()).unwrap();
            }
            t.rollback().await.unwrap();
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the confirmation reaches the phone");
    assert_eq!(confirm.nonce, fresh.nonce);
    verify_pairing_confirmation(
        fresh,
        e.phone.to_string(),
        new_phone_key,
        decode_signature(&confirm.signature).unwrap(),
    )
    .unwrap();

    // 关掉二维码：回到没在配对。
    e.desktop.cancel_pairing();
    assert_eq!(*e.desktop.watch_pairing().borrow(), PairingStatus::Idle);
}
