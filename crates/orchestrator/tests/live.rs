//! 实时活动（10.6）：App 登记的按运行的状态更新、合并、结束；计划运行远程开启；令牌失效、重试和放弃。
//! 需要 DATABASE_URL（没有时跳过）。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use notify::filter::KeywordFilter;
use notify::{LiveActivityChannel, LiveEvent, LivePush, PushOutcome};
use orchestrator::live::{ATTRIBUTES_TYPE, LiveConfig, LiveDispatcher, MAX_OPEN, queue_starts};
use proto::domain::{DeviceId, DevicePlatform, InstanceLimits, Run, RunSource, SessionId, UserId};
use serde_json::json;
use store::testing::TestDb;
use store::{NewInstance, NewRun};

const PHONE: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
/// App 换了的令牌（同一个实时活动重新开了一个）。
const PHONE2: &str = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";
const START: &str = "5747a77ec0de5747a77ec0de5747a77ec0de5747a77ec0de5747a77ec0de5747";

#[derive(Default)]
struct Recording {
    outcomes: Mutex<HashMap<String, PushOutcome>>,
    sent: Mutex<Vec<(String, LivePush)>>,
    /// 每次发要多久（APNs 很慢的时候）。
    delay: Mutex<Duration>,
}

impl Recording {
    fn set(&self, token: &str, outcome: PushOutcome) {
        self.outcomes.lock().unwrap().insert(token.into(), outcome);
    }
    fn sent(&self) -> Vec<(String, LivePush)> {
        std::mem::take(&mut self.sent.lock().unwrap())
    }
}

#[async_trait]
impl LiveActivityChannel for Recording {
    async fn send_live(&self, token: &str, push: &LivePush) -> PushOutcome {
        let delay = *self.delay.lock().unwrap();
        tokio::time::sleep(delay).await;
        self.sent
            .lock()
            .unwrap()
            .push((token.to_owned(), push.clone()));
        self.outcomes
            .lock()
            .unwrap()
            .get(token)
            .cloned()
            .unwrap_or(PushOutcome::Delivered { id: None })
    }
}

struct Setup {
    t: TestDb,
    user: UserId,
    phone: DeviceId,
    instance: proto::domain::Instance,
}

async fn setup(phone_number: &str, name: &str) -> Option<Setup> {
    let t = TestDb::new().await?;
    let mut w = t.db.worker().await.unwrap();
    let (u, _) = w.upsert_user_by_phone(phone_number).await.unwrap();
    let phone = w
        .create_device(u.id, DevicePlatform::Ios, "iPhone", None)
        .await
        .unwrap();
    w.create_session(
        SessionId::new(),
        u.id,
        phone,
        b"r",
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let mut tx = t.db.tenant(u.id).await.unwrap();
    let instance = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: name.into(),
            workspace_id: "vol-1".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    tx.commit().await.unwrap();
    Some(Setup {
        t,
        user: u.id,
        phone,
        instance,
    })
}

impl Setup {
    async fn run(&self, source: RunSource) -> Run {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let r = tx
            .create_run(&NewRun::new(self.instance.id, source, "整理邮件", "1"))
            .await
            .unwrap();
        tx.commit().await.unwrap();
        r
    }

    async fn set(&self, run: &Run, state: &str, steps: i32) {
        sqlx::query(
            "UPDATE runs SET state = $2, steps = $3, \
               started_at = coalesce(started_at, now()), \
               finished_at = CASE WHEN $2 IN ('succeeded', 'failed', 'cancelled') THEN now() END \
             WHERE id = $1",
        )
        .bind(run.id.0)
        .bind(state)
        .bind(steps)
        .execute(self.t.db.pool())
        .await
        .unwrap();
    }

    async fn register(&self, run: &Run, token: &str) {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        tx.register_live_activity(self.phone, run.id, token, MAX_OPEN)
            .await
            .unwrap();
        tx.commit().await.unwrap();
    }

    async fn start_token(&self, token: Option<&str>) {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        tx.set_activity_start_token(self.phone, token)
            .await
            .unwrap();
        tx.commit().await.unwrap();
    }

    async fn stored_start_token(&self) -> Option<String> {
        sqlx::query_scalar("SELECT activity_start_token FROM devices WHERE id = $1")
            .bind(self.phone.0)
            .fetch_one(self.t.db.pool())
            .await
            .unwrap()
    }

    async fn row(&self, run: &Run) -> (Option<String>, bool, i32) {
        sqlx::query_as(
            "SELECT last_error, ended_at IS NOT NULL, attempts FROM live_activities \
             WHERE device_id = $1 AND run_id = $2",
        )
        .bind(self.phone.0)
        .bind(run.id.0)
        .fetch_one(self.t.db.pool())
        .await
        .unwrap()
    }

    fn dispatcher(&self, rec: Arc<Recording>, cfg: LiveConfig) -> LiveDispatcher {
        LiveDispatcher::new(self.t.db.clone(), "node-a", rec, cfg)
    }
}

/// 不等间隔，测试里马上能发下一次。
fn eager() -> LiveConfig {
    LiveConfig {
        state_gap: Duration::ZERO,
        step_gap: Duration::from_secs(3600),
        backoff_base: Duration::ZERO,
        ..Default::default()
    }
}

#[tokio::test]
async fn app_activities_follow_the_run_and_end_with_it() {
    let Some(s) = setup("+8613800000061", "调研助手").await else {
        return;
    };
    let run = s.run(RunSource::User).await;
    s.set(&run, "running", 1).await;
    s.register(&run, PHONE).await;
    let rec = Arc::new(Recording::default());
    let d = s.dispatcher(rec.clone(), eager());

    // 刚登记：现在的状态马上发一次。
    assert_eq!(d.tick().await.unwrap(), 1);
    let sent = rec.sent();
    assert_eq!(sent.len(), 1);
    let (token, push) = &sent[0];
    assert_eq!(token, PHONE);
    assert_eq!(push.event, LiveEvent::Update);
    assert!(push.urgent && push.attributes.is_none() && push.alert.is_none());
    assert_eq!(push.content_state["state"], "running");
    assert_eq!(push.content_state["steps"], 1);
    assert!(push.content_state["startedAt"].as_i64().unwrap() > 1_700_000_000);
    assert!(push.content_state.get("endedAt").is_none());
    // 没变化不发；只是步数变了，间隔没到也不发。
    assert_eq!(d.tick().await.unwrap(), 0);
    s.set(&run, "running", 5).await;
    assert_eq!(d.tick().await.unwrap(), 0);
    // 状态变了：马上发，带着最新的步数（几次变化合成一次）。
    s.set(&run, "waiting_approval", 6).await;
    assert_eq!(d.tick().await.unwrap(), 1);
    let sent = rec.sent();
    assert_eq!(
        sent[0].1.content_state["state"], "waiting_approval",
        "{:?}",
        sent[0].1
    );
    assert_eq!(sent[0].1.content_state["steps"], 6);
    assert!(sent[0].1.urgent);
    // 只是步数变了、间隔到了：低优先级。
    let lazy = s.dispatcher(
        rec.clone(),
        LiveConfig {
            step_gap: Duration::ZERO,
            ..eager()
        },
    );
    s.set(&run, "waiting_approval", 7).await;
    assert_eq!(lazy.tick().await.unwrap(), 1);
    assert!(!rec.sent()[0].1.urgent);

    // 结束：发 end，带结束时间；之后不再发。
    s.set(&run, "succeeded", 9).await;
    assert_eq!(d.tick().await.unwrap(), 1);
    let sent = rec.sent();
    assert_eq!(sent[0].1.event, LiveEvent::End);
    assert!(sent[0].1.urgent);
    assert_eq!(sent[0].1.content_state["state"], "succeeded");
    assert!(sent[0].1.content_state["endedAt"].is_i64());
    assert_eq!(d.tick().await.unwrap(), 0);
    assert_eq!(s.row(&run).await, (None, true, 0));
}

#[tokio::test]
async fn scheduled_runs_start_activities_remotely() {
    let Some(s) = setup("+8613800000062", "坏词 助手").await else {
        return;
    };
    s.start_token(Some(START)).await;
    // 用户自己发起的：App 自己开，不远程开启。
    let _own = s.run(RunSource::User).await;
    let planned = s.run(RunSource::Plan).await;
    // 第一次领取时记下待开启的：只有计划的根运行（用户自己发起的由 App 自己开）。
    for _ in 0..2 {
        let mut w = s.t.db.worker().await.unwrap();
        let rec = w
            .claim_next_run("node-a", Duration::from_secs(60))
            .await
            .unwrap()
            .unwrap();
        queue_starts(&mut w, &rec).await.unwrap();
        w.commit().await.unwrap();
        // 同一个实例一次一个运行：放回去（往后推），好领下一个。
        sqlx::query(
            "UPDATE runs SET state = 'queued', lease_owner = NULL, \
               not_before = now() + interval '1 hour' WHERE id = $1",
        )
        .bind(rec.run.id.0)
        .execute(s.t.db.pool())
        .await
        .unwrap();
    }
    let rows: Vec<(uuid::Uuid, String)> =
        sqlx::query_as("SELECT run_id, origin FROM live_activities")
            .fetch_all(s.t.db.pool())
            .await
            .unwrap();
    assert_eq!(rows, vec![(planned.id.0, "push".to_owned())]);

    let rec = Arc::new(Recording::default());
    let d = s
        .dispatcher(rec.clone(), eager())
        .with_filter(Arc::new(KeywordFilter::new(["坏词"])));
    assert_eq!(d.tick().await.unwrap(), 1);
    let sent = rec.sent();
    let (token, push) = &sent[0];
    assert_eq!(token, START);
    assert_eq!(push.event, LiveEvent::Start);
    assert!(push.urgent);
    let (kind, attributes) = push.attributes.clone().unwrap();
    assert_eq!(kind, ATTRIBUTES_TYPE);
    // 实例名命中过滤：锁屏上换成 App 名。
    assert_eq!(
        attributes,
        json!({
            "runId": planned.id.to_string(),
            "instanceId": s.instance.id.to_string(),
            "title": "ThinkTin",
        })
    );
    assert_eq!(
        push.alert,
        Some(("ThinkTin".into(), "计划开始运行了".into()))
    );
    assert_eq!(push.content_state["state"], "queued");
    // 开启了，等 App 报上新实时活动的令牌；报上来之后照常更新。
    assert_eq!(d.tick().await.unwrap(), 0);
    s.set(&planned, "running", 2).await;
    assert_eq!(d.tick().await.unwrap(), 0);
    s.register(&planned, PHONE).await;
    assert_eq!(d.tick().await.unwrap(), 1);
    let sent = rec.sent();
    assert_eq!(
        (sent[0].0.as_str(), sent[0].1.event),
        (PHONE, LiveEvent::Update)
    );
    assert_eq!(sent[0].1.content_state["state"], "running");
}

#[tokio::test]
async fn dead_tokens_retries_and_giving_up() {
    let Some(s) = setup("+8613800000063", "调研助手").await else {
        return;
    };
    let rec = Arc::new(Recording::default());
    let d = s.dispatcher(
        rec.clone(),
        LiveConfig {
            max_attempts: 2,
            ..eager()
        },
    );

    // 推送开启令牌失效：清掉，这个运行不再开启。
    s.start_token(Some(START)).await;
    let planned = s.run(RunSource::Plan).await;
    let mut w = s.t.db.worker().await.unwrap();
    w.queue_live_starts(s.user, planned.id, 2).await.unwrap();
    w.commit().await.unwrap();
    rec.set(
        START,
        PushOutcome::InvalidToken {
            reason: "Unregistered".into(),
        },
    );
    assert_eq!(d.tick().await.unwrap(), 1);
    assert_eq!(s.stored_start_token().await, None);
    assert_eq!(
        s.row(&planned).await,
        (Some("Unregistered".into()), true, 0)
    );

    // 实时活动的令牌失效（用户划掉了）：不再发。
    let run = s.run(RunSource::User).await;
    s.register(&run, PHONE).await;
    rec.set(
        PHONE,
        PushOutcome::InvalidToken {
            reason: "ExpiredToken".into(),
        },
    );
    assert_eq!(d.tick().await.unwrap(), 1);
    assert_eq!(s.row(&run).await, (Some("ExpiredToken".into()), true, 0));
    // 失效的令牌再报一次：不重新打开。
    s.register(&run, PHONE).await;
    assert_eq!(d.tick().await.unwrap(), 0);

    // 暂时失败：退避重试，次数到了就不再发。App 再报一次同一个令牌就从头来。
    s.register(&run, PHONE2).await;
    rec.set(
        PHONE2,
        PushOutcome::Retry {
            after: None,
            reason: "ServiceUnavailable".into(),
        },
    );
    assert_eq!(d.tick().await.unwrap(), 1);
    assert_eq!(
        s.row(&run).await,
        (Some("ServiceUnavailable".into()), false, 1)
    );
    assert_eq!(d.tick().await.unwrap(), 1);
    assert_eq!(
        s.row(&run).await,
        (
            Some("gave up after 2 attempts: ServiceUnavailable".into()),
            true,
            1
        )
    );
    assert_eq!(d.tick().await.unwrap(), 0);
    rec.set(PHONE2, PushOutcome::Delivered { id: None });
    s.register(&run, PHONE2).await;
    assert_eq!(d.tick().await.unwrap(), 1);
    assert_eq!(s.row(&run).await, (None, false, 0));
    assert_eq!(
        rec.sent().len(),
        5,
        "start, dead token, two retries, the fresh one"
    );
}

#[tokio::test]
async fn slow_sends_do_not_outlive_their_lock() {
    let Some(s) = setup("+8613800000064", "调研助手").await else {
        return;
    };
    let first = s.run(RunSource::User).await;
    s.register(&first, PHONE).await;
    let second = s.run(RunSource::User).await;
    s.register(&second, PHONE2).await;
    let rec = Arc::new(Recording::default());
    *rec.delay.lock().unwrap() = Duration::from_millis(1500);
    // 一次只发一个、锁一秒：第一个发完时第二个的锁已经过期（别的副本可能领去发了），不发。
    let d = s.dispatcher(
        rec.clone(),
        LiveConfig {
            concurrency: 1,
            lock_for: Duration::from_secs(1),
            ..eager()
        },
    );
    assert_eq!(d.tick().await.unwrap(), 2);
    assert_eq!(rec.sent().len(), 1);
    // 下一轮再领、再发。
    *rec.delay.lock().unwrap() = Duration::ZERO;
    assert_eq!(d.tick().await.unwrap(), 1);
    assert_eq!(rec.sent().len(), 1);
}
