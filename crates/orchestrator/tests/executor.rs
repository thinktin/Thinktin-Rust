//! 执行器：用进程内的 shim 替身（按提示词决定行为）+ 本地沙箱后端 + 真实 Postgres。
//! 没有 DATABASE_URL 时跳过。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::shim::{
    ConnectError, NoPlatformTools, PlatformTools, ShimConnector, ShimLaunch, ShimProcess,
    ShimSession, ToolContext, ToolOutput,
};
use proto::domain::{GrantScope, Instance, RunBudget, RunId, RunSource, RunState, UserId};
use proto::shim::{
    DecisionSource, PermissionKind, PermissionOption, PlatformTool, ShimCommand, ShimEvent,
    StopReason,
};
use sandbox::local::LocalProvider;
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{NewRun, NewUsage};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

// ---------- shim 替身 ----------

#[derive(Default)]
struct Recorded {
    launches: Vec<(String, Vec<String>, Vec<String>)>,
    prompts: Vec<String>,
}

#[derive(Default, Clone)]
struct FakeConnector {
    rec: Arc<Mutex<Recorded>>,
}

struct FakeProcess(Option<JoinHandle<()>>);

#[async_trait]
impl ShimProcess for FakeProcess {
    async fn wait(&mut self) {
        if let Some(h) = self.0.as_mut() {
            let _ = h.await;
            self.0 = None;
        }
    }
    async fn kill(&mut self) {
        if let Some(h) = self.0.take() {
            h.abort();
        }
    }
}

#[async_trait]
impl ShimConnector for FakeConnector {
    async fn start(&self, launch: &ShimLaunch) -> Result<ShimSession, ConnectError> {
        self.rec.lock().unwrap().launches.push((
            launch.token.clone(),
            launch.allow_tools.clone(),
            launch
                .platform_tools
                .iter()
                .map(|t| t.name.clone())
                .collect(),
        ));
        let (cmd_tx, cmd_rx) = mpsc::channel(16);
        let (ev_tx, ev_rx) = mpsc::channel(64);
        let rec = self.rec.clone();
        let task = tokio::spawn(fake_shim(cmd_rx, ev_tx, rec));
        Ok(ShimSession {
            commands: cmd_tx,
            events: ev_rx,
            process: Box::new(FakeProcess(Some(task))),
        })
    }
}

fn chunk(run: &str, text: &str) -> ShimEvent {
    ShimEvent::MessageChunk {
        run_id: Some(run.into()),
        text: text.into(),
    }
}

fn tool_call(run: &str, i: u32) -> ShimEvent {
    ShimEvent::ToolCall {
        run_id: Some(run.into()),
        tool_call_id: format!("t{i}"),
        title: Some("Read file".into()),
        kind: Some("read".into()),
        status: Some("completed".into()),
        raw: Value::Null,
    }
}

fn ended(run: &str, stop_reason: StopReason) -> ShimEvent {
    ShimEvent::TurnEnded {
        run_id: run.into(),
        stop_reason,
    }
}

/// 按提示词里的关键字表演：say hello / need approval / loop forever / crash / use tool。
async fn fake_shim(
    mut cmds: mpsc::Receiver<ShimCommand>,
    ev: mpsc::Sender<ShimEvent>,
    rec: Arc<Mutex<Recorded>>,
) {
    let _ = ev
        .send(ShimEvent::Ready {
            protocol_version: 1,
            agent_id: "claude".into(),
            harness: "acp".into(),
            agent_info: None,
            session_id: "s1".into(),
            session_restored: false,
        })
        .await;
    let mut looping: Option<String> = None;
    let mut ticks = 0;
    loop {
        let cmd = if let Some(run) = &looping {
            match tokio::time::timeout(Duration::from_millis(30), cmds.recv()).await {
                Ok(c) => c,
                Err(_) => {
                    ticks += 1;
                    let _ = ev.send(tool_call(run, ticks)).await;
                    continue;
                }
            }
        } else {
            cmds.recv().await
        };
        let Some(cmd) = cmd else { return };
        match cmd {
            ShimCommand::Prompt { run_id, text } => {
                rec.lock().unwrap().prompts.push(text.clone());
                let _ = ev
                    .send(ShimEvent::TurnStarted {
                        run_id: run_id.clone(),
                    })
                    .await;
                if text.contains("say hello") {
                    let _ = ev.send(chunk(&run_id, "Hello")).await;
                    let _ = ev.send(chunk(&run_id, " world")).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("need approval") {
                    let _ = ev.send(tool_call(&run_id, 0)).await;
                    let _ = ev
                        .send(ShimEvent::PermissionRequested {
                            run_id: Some(run_id.clone()),
                            request_id: "p1".into(),
                            title: Some("Delete old reports".into()),
                            options: vec![
                                PermissionOption {
                                    option_id: "allow".into(),
                                    name: "Allow".into(),
                                    kind: PermissionKind::AllowOnce,
                                },
                                PermissionOption {
                                    option_id: "reject".into(),
                                    name: "Reject".into(),
                                    kind: PermissionKind::RejectOnce,
                                },
                            ],
                            tool_call: json!({ "title": "rm reports/*.old" }),
                        })
                        .await;
                    // 等决定。
                    while let Some(c) = cmds.recv().await {
                        if let ShimCommand::PermissionDecision {
                            request_id,
                            option_id,
                        } = c
                        {
                            let _ = ev
                                .send(ShimEvent::PermissionResolved {
                                    run_id: Some(run_id.clone()),
                                    request_id,
                                    option_id: option_id.clone(),
                                    by: DecisionSource::User,
                                })
                                .await;
                            let word = if option_id.as_deref() == Some("allow") {
                                "approved"
                            } else {
                                "rejected"
                            };
                            let _ = ev.send(chunk(&run_id, word)).await;
                            let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                            break;
                        }
                    }
                } else if text.contains("loop forever") {
                    looping = Some(run_id);
                } else if text.contains("crash") {
                    return;
                } else if text.contains("use tool") {
                    let _ = ev
                        .send(ShimEvent::PlatformToolCall {
                            run_id: run_id.clone(),
                            call_id: "c1".into(),
                            name: "schedule_list".into(),
                            arguments: json!({ "limit": 1 }),
                        })
                        .await;
                    while let Some(c) = cmds.recv().await {
                        if let ShimCommand::PlatformToolResult { content, .. } = c {
                            let text = content[0]["text"].as_str().unwrap_or_default().to_owned();
                            let _ = ev.send(chunk(&run_id, &text)).await;
                            let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                            break;
                        }
                    }
                }
            }
            ShimCommand::Cancel { run_id } => {
                looping = None;
                let _ = ev.send(ended(&run_id, StopReason::Cancelled)).await;
            }
            ShimCommand::Shutdown => return,
            _ => {}
        }
    }
}

struct Tools;

#[async_trait]
impl PlatformTools for Tools {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![
            PlatformTool {
                name: "schedule_list".into(),
                description: "List schedules".into(),
                input_schema: json!({ "type": "object" }),
            },
            PlatformTool {
                name: "delegate".into(),
                description: "Delegate".into(),
                input_schema: json!({ "type": "object" }),
            },
        ]
    }
    async fn call(&self, ctx: &ToolContext, name: &str, _args: &Value) -> ToolOutput {
        ToolOutput::text(format!("{name} for run {}", ctx.run))
    }
}

// ---------- 环境 ----------

struct Env {
    t: TestDb,
    _dir: tempfile::TempDir,
    exec: Arc<Executor>,
    fake: FakeConnector,
    user: UserId,
    instance: Instance,
}

async fn env_with(
    cfg: ExecutorConfig,
    scope: Option<GrantScope>,
    tools: Arc<dyn PlatformTools>,
) -> Option<Env> {
    let t = TestDb::new().await?;
    let dir = tempfile::tempdir().unwrap();
    let provider = Arc::new(LocalProvider::new(dir.path()).unwrap());
    let lifecycle = Arc::new(Lifecycle::new(
        t.db.clone(),
        provider,
        Arc::new(BuiltinTemplates),
        LifecycleConfig::default(),
    ));
    let grants = Arc::new(GrantService::new(
        t.db.clone(),
        GrantConfig::default(),
        SandboxTokenIssuer::generate("s1").unwrap(),
    ));
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let instance = lifecycle
        .adopt(user.id, "user:d", "claude", None, "Claude")
        .await
        .unwrap();
    if let Some(scope) = scope {
        let mut tx = t.db.tenant(user.id).await.unwrap();
        tx.create_run_grant(instance.id, None, &scope, Duration::from_secs(3600))
            .await
            .unwrap();
        tx.commit().await.unwrap();
    }
    let fake = FakeConnector::default();
    let exec = Arc::new(Executor::new(
        t.db.clone(),
        "node-a",
        lifecycle,
        grants,
        Arc::new(fake.clone()),
        tools,
        cfg,
    ));
    Some(Env {
        t,
        _dir: dir,
        exec,
        fake,
        user: user.id,
        instance,
    })
}

fn fast() -> ExecutorConfig {
    ExecutorConfig {
        renew_every: Duration::from_millis(100),
        approval_poll: Duration::from_millis(50),
        stop_timeout: Duration::from_secs(2),
        ..ExecutorConfig::default()
    }
}

async fn env() -> Option<Env> {
    env_with(
        fast(),
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
}

impl Env {
    async fn queue(&self, prompt: &str, budget: Option<RunBudget>, max_attempts: u32) -> RunId {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let mut new = NewRun::new(
            self.instance.id,
            RunSource::User,
            prompt,
            &self.instance.agent_version,
        );
        if let Some(b) = budget {
            new.budget = b;
        }
        new.max_attempts = max_attempts;
        let run = tx.create_run(&new).await.unwrap();
        tx.commit().await.unwrap();
        run.id
    }

    /// 领取并在后台执行，返回停机信号和任务句柄。
    async fn spawn(&self) -> (watch::Sender<bool>, JoinHandle<()>) {
        let rec = self.exec.claim().await.unwrap().expect("a run to claim");
        let (tx, rx) = watch::channel(false);
        let exec = self.exec.clone();
        (tx, tokio::spawn(async move { exec.execute(rec, rx).await }))
    }

    async fn run_to_end(&self) {
        let (_stop, h) = self.spawn().await;
        tokio::time::timeout(Duration::from_secs(20), h)
            .await
            .unwrap()
            .unwrap();
    }

    async fn state(&self, run: RunId) -> store::RunRecord {
        let mut w = self.t.db.worker().await.unwrap();
        let r = w.run_record(run).await.unwrap();
        w.rollback().await.unwrap();
        r
    }

    async fn wait_state(&self, run: RunId, want: RunState) {
        for _ in 0..200 {
            if self.state(run).await.run.state == want {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("run never reached {want}: {:?}", self.state(run).await.run);
    }

    async fn events(&self, run: RunId) -> Vec<(String, Value)> {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        tx.events_after(self.instance.id, 0, 1000)
            .await
            .unwrap()
            .into_iter()
            .filter(|e| e.run_id == Some(run))
            .map(|e| (e.kind, e.payload))
            .collect()
    }

    async fn outbox_kinds(&self) -> Vec<String> {
        let mut w = self.t.db.worker().await.unwrap();
        let items = w
            .claim_outbox("test", Duration::from_secs(60), 100)
            .await
            .unwrap();
        w.rollback().await.unwrap();
        items
            .into_iter()
            .map(|i| i.payload["kind"].as_str().unwrap_or_default().to_owned())
            .collect()
    }
}

// ---------- 用例 ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_goes_from_queue_to_success_with_a_log_and_a_notification() {
    let Some(e) = env().await else { return };
    let run = e.queue("please say hello", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("Hello world"));
    assert!(rec.run.started_at.is_some() && rec.run.finished_at.is_some());
    assert_eq!(rec.lease_owner, None);

    let events = e.events(run).await;
    let kinds: Vec<&str> = events.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        kinds,
        [
            "agent.ready",
            "agent.turn_started",
            "run.state",
            "agent.message",
            "agent.turn_ended",
            "run.state"
        ]
    );
    let message = events.iter().find(|(k, _)| k == "agent.message").unwrap();
    assert_eq!(message.1["text"], "Hello world", "chunks are coalesced");
    assert_eq!(events.last().unwrap().1["state"], "succeeded");
    assert_eq!(e.outbox_kinds().await, ["run_finished"]);

    // 沙箱令牌经 launch 交给 shim；没有预授权的工具。
    let launch = e.fake.rec.lock().unwrap().launches[0].clone();
    assert!(launch.0.starts_with("tts1."));
    assert!(launch.1.is_empty());
    // 实例被唤醒了。
    let mut w = e.t.db.worker().await.unwrap();
    assert_eq!(
        w.instance_runtime(e.instance.id).await.unwrap().state,
        proto::domain::InstanceState::Running
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn approvals_wait_for_the_user() {
    let Some(e) = env().await else { return };
    let run = e.queue("need approval to clean up", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let pending = tx.pending_approvals().await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].title.as_deref(), Some("Delete old reports"));
    assert!(matches!(
        tx.decide_approval(pending[0].id, "bogus", proto::domain::DeviceId::new())
            .await,
        Err(store::Error::Invalid(_))
    ));
    tx.decide_approval(pending[0].id, "allow", proto::domain::DeviceId::new())
        .await
        .unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded);
    assert_eq!(rec.run.summary.as_deref(), Some("approved"));
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(tx.pending_approvals().await.unwrap().is_empty());
    tx.rollback().await.unwrap();
    let kinds = e.outbox_kinds().await;
    assert!(kinds.contains(&"approval".to_string()) && kinds.contains(&"run_finished".to_string()));
    let states: Vec<String> = e
        .events(run)
        .await
        .into_iter()
        .filter(|(k, _)| k == "run.state")
        .map(|(_, p)| p["state"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        states,
        ["running", "waiting_approval", "running", "succeeded"]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn user_cancellation_stops_the_agent() {
    let Some(e) = env().await else { return };
    let run = e.queue("loop forever", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(run, None).await.unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Cancelled);
    let events = e.events(run).await;
    assert!(
        events
            .iter()
            .any(|(k, p)| k == "agent.turn_ended" && p["stop_reason"] == "cancelled"),
        "the agent's turn was cancelled"
    );
    assert!(
        e.outbox_kinds().await.is_empty(),
        "no push for a user cancel"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn budgets_stop_runaway_runs() {
    let Some(e) = env().await else { return };
    // 步数。
    let steps = e
        .queue(
            "loop forever",
            Some(RunBudget {
                max_steps: Some(3),
                ..RunBudget::default()
            }),
            3,
        )
        .await;
    e.run_to_end().await;
    let rec = e.state(steps).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("step budget"));
    // 时长。
    let time = e
        .queue(
            "loop forever",
            Some(RunBudget {
                max_duration_secs: 1,
                ..RunBudget::default()
            }),
            3,
        )
        .await;
    e.run_to_end().await;
    let rec = e.state(time).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("time budget"));
    // token：以模型网关的计费记录为准。
    let tokens = e
        .queue(
            "loop forever",
            Some(RunBudget {
                max_tokens: Some(1000),
                ..RunBudget::default()
            }),
            3,
        )
        .await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(tokens, RunState::Running).await;
    let mut w = e.t.db.worker().await.unwrap();
    w.insert_usage(&NewUsage {
        user: e.user,
        instance: e.instance.id,
        alias: "main".into(),
        vendor: "anthropic".into(),
        upstream_model: "m".into(),
        endpoint: "messages".into(),
        status: 200,
        outcome: "ok".into(),
        charged_tokens: 5000,
        ..NewUsage::default()
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(tokens).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("token budget"));
    assert_eq!(rec.run.tokens_used, 5000);
    assert_eq!(
        e.outbox_kinds().await,
        ["run_failed", "run_failed", "run_failed"]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn crashes_back_off() {
    let Some(e) = env().await else { return };
    let run = e.queue("crash please", None, 2).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Backoff);
    assert_eq!(rec.lease_owner, None);
    assert!(rec.not_before > chrono::Utc::now() + chrono::Duration::seconds(20));
    assert!(e.exec.claim().await.unwrap().is_none(), "backing off");
    assert!(e.outbox_kinds().await.is_empty(), "no push while retrying");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn shutdown_hands_the_run_to_another_replica_with_a_resume_note() {
    let Some(e) = env().await else { return };
    let run = e.queue("loop forever", None, 3).await;
    let (stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    stop.send(true).unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Backoff);
    assert_eq!(rec.lease_owner, None);
    // 马上能被（另一个副本）领走，算第二次尝试，提示词带续跑说明。
    let next = e.exec.claim().await.unwrap().unwrap();
    assert_eq!(next.run.id, run);
    assert_eq!(next.run.attempt, 2);
    let (tx, rx) = watch::channel(false);
    let exec = e.exec.clone();
    let h = tokio::spawn(async move { exec.execute(next, rx).await });
    e.wait_state(run, RunState::Running).await;
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(prompts[1].contains("续跑说明") && prompts[1].contains("第 2 次"));
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.cancel_run(run, None).await.unwrap();
    t.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    drop(tx);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn expired_leases_are_taken_over_and_give_up_after_max_attempts() {
    let Some(e) = env().await else { return };
    let run = e.queue("say hello", None, 1).await;
    // 另一个副本领了之后崩溃（租约立即过期）。
    let mut w = e.t.db.worker().await.unwrap();
    w.claim_next_run("dead-node", Duration::ZERO)
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(e.exec.take_over_expired().await.unwrap(), 1);
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed, "max_attempts = 1");
    assert!(rec.run.state_reason.unwrap().contains("gave up"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_second_crash_gives_up() {
    let Some(e) = env_with(
        ExecutorConfig {
            backoff_base: Duration::ZERO,
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("crash please", None, 2).await;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Backoff);
    // 第二次也崩溃：超过最多尝试次数，失败并通知。
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert_eq!(rec.run.attempt, 2);
    assert_eq!(e.outbox_kinds().await, ["run_failed"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn platform_tools_follow_the_grant_scope() {
    let Some(e) = env_with(
        fast(),
        Some(GrantScope {
            platform_tools: vec!["schedule_list".into()],
            ..GrantScope::default()
        }),
        Arc::new(Tools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("use tool", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded);
    assert_eq!(
        rec.run.summary,
        Some(format!("schedule_list for run {run}"))
    );
    let launches = &e.fake.rec.lock().unwrap().launches;
    assert_eq!(
        launches[0].2,
        ["schedule_list"],
        "delegate is outside the grant"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn runs_without_a_grant_fail() {
    let Some(e) = env_with(fast(), None, Arc::new(NoPlatformTools)).await else {
        return;
    };
    let run = e.queue("say hello", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("no active run grant"));
}
