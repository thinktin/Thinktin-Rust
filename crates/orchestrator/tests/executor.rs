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
                } else if text.contains("nul") {
                    // agent 回复里夹着 NUL（比如转述的网页标题）：存不进 Postgres，不能让收尾失败。
                    let _ = ev.send(chunk(&run_id, "done\u{0}here")).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("flood") {
                    // 失控的 agent：一大段回复，再夹着工具调用不停输出。
                    let big = "z".repeat(200 << 10);
                    for i in 0..20 {
                        let _ = ev.send(chunk(&run_id, &big)).await;
                        let _ = ev.send(tool_call(&run_id, i)).await;
                    }
                    let _ = ev.send(chunk(&run_id, &big)).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("loop forever") {
                    looping = Some(run_id);
                } else if text.contains("use vault") {
                    // 沙箱里的助手要保险箱里的值，命令把它打印了出来。
                    let _ = ev
                        .send(ShimEvent::VaultReveal {
                            run_id: run_id.clone(),
                            call_id: "v1".into(),
                            refs: vec!["github".into(), "github.username".into()],
                        })
                        .await;
                    while let Some(c) = cmds.recv().await {
                        if let ShimCommand::VaultValues { values, error, .. } = c {
                            let text = match error {
                                Some(e) => format!("error: {e}"),
                                None => format!("got {} for {}", values.0[0], values.0[1]),
                            };
                            let _ = ev
                                .send(ShimEvent::ToolCallUpdate {
                                    run_id: Some(run_id.clone()),
                                    tool_call_id: "t1".into(),
                                    status: Some("completed".into()),
                                    raw: json!({ "content": [{ "type": "text", "text": text }] }),
                                })
                                .await;
                            let _ = ev.send(chunk(&run_id, &text)).await;
                            let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                            break;
                        }
                    }
                } else if text.contains("crash") {
                    return;
                } else if text.contains("use tool") {
                    // 被攻破的 shim 可以调没告诉它的工具。
                    let name = if text.contains("forged") {
                        "delegate"
                    } else {
                        "schedule_list"
                    };
                    let _ = ev
                        .send(ShimEvent::PlatformToolCall {
                            run_id: run_id.clone(),
                            call_id: "c1".into(),
                            name: name.into(),
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

const KMS_KEY: [u8; 32] = [9; 32];

fn kms() -> Arc<dyn keyvault::Kms> {
    Arc::new(keyvault::LocalKms::new("kms1", &KMS_KEY))
}

/// 只声明 vault_list：授权里有它，沙箱里的助手才能要值。
struct VaultStub;

#[async_trait]
impl PlatformTools for VaultStub {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![PlatformTool {
            name: "vault_list".into(),
            description: "List vault items".into(),
            input_schema: json!({ "type": "object" }),
        }]
    }
    async fn call(&self, _ctx: &ToolContext, name: &str, _args: &Value) -> ToolOutput {
        ToolOutput::text(name)
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
    lifecycle: Arc<Lifecycle>,
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
    let exec = Arc::new(
        Executor::new(
            t.db.clone(),
            "node-a",
            lifecycle.clone(),
            grants,
            Arc::new(fake.clone()),
            tools,
            cfg,
        )
        .with_vault(kms()),
    );
    Some(Env {
        t,
        _dir: dir,
        lifecycle,
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

    async fn inbox(&self) -> Vec<proto::domain::InboxItem> {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let items = tx.inbox(None, 100, false).await.unwrap();
        tx.rollback().await.unwrap();
        items
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
    // 收件箱留一条，推送里带着它的 id。
    let inbox = e.inbox().await;
    assert_eq!(inbox.len(), 1);
    assert_eq!(inbox[0].kind, "run_finished");
    assert_eq!(inbox[0].run_id, Some(run));
    assert_eq!(inbox[0].body, "Hello world");
    assert!(!inbox[0].read);
    let mut w = e.t.db.worker().await.unwrap();
    let pushed = w
        .claim_outbox("test", Duration::from_secs(60), 10)
        .await
        .unwrap();
    w.rollback().await.unwrap();
    assert_eq!(
        pushed[0].payload["target"]["inbox_id"],
        inbox[0].id.to_string()
    );

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
    // 审批提醒处理完就算已读；运行结果还没读。
    let inbox = e.inbox().await;
    let approval = inbox.iter().find(|i| i.kind == "approval").unwrap();
    assert!(approval.read && approval.approval_id.is_some());
    let done = inbox.iter().find(|i| i.kind == "run_finished").unwrap();
    assert!(!done.read);
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
    let launches = e.fake.rec.lock().unwrap().launches.clone();
    assert_eq!(
        launches[0].2,
        ["schedule_list"],
        "delegate is outside the grant"
    );
    // 授权范围外的工具，就算 shim 发来调用也不执行。
    let run = e.queue("use tool, forged", None, 3).await;
    e.run_to_end().await;
    assert_eq!(
        e.state(run).await.run.summary.as_deref(),
        Some("unknown platform tool delegate")
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

/// agent 输出不受控：单条日志截断，整次运行的日志有总量上限，摘要只取开头。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn agent_output_is_bounded_in_memory_and_in_the_log() {
    let Some(e) = env_with(
        ExecutorConfig {
            max_run_log_bytes: 256 << 10,
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(Tools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("please flood", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert!(rec.run.summary.as_deref().unwrap().chars().count() <= 401);
    let events = e.events(run).await;
    let logged: usize = events
        .iter()
        .filter(|(k, _)| k.starts_with("agent."))
        .map(|(_, p)| serde_json::to_vec(p).unwrap().len())
        .sum();
    assert!(logged <= 256 << 10, "agent events took {logged} bytes");
    for (_, p) in &events {
        assert!(serde_json::to_vec(p).unwrap().len() <= 256 << 10);
    }
    let marks = events
        .iter()
        .filter(|(k, _)| k == "run.log_truncated")
        .count();
    assert_eq!(marks, 1);
    // 状态变化照常记。
    assert_eq!(events.last().unwrap().0, "run.state");
    assert_eq!(events.last().unwrap().1["state"], "succeeded");
}

impl Env {
    async fn approve_pending(&self) {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let pending = tx.pending_approvals().await.unwrap();
        assert_eq!(pending.len(), 1, "{pending:?}");
        tx.decide_approval(pending[0].id, "allow", proto::domain::DeviceId::new())
            .await
            .unwrap();
        tx.commit().await.unwrap();
    }

    async fn instance_state(&self) -> proto::domain::InstanceState {
        let mut w = self.t.db.worker().await.unwrap();
        let s = w.instance_runtime(self.instance.id).await.unwrap().state;
        w.rollback().await.unwrap();
        s
    }
}

/// 等审批期间沙箱被空闲回收暂停：用户批准后先唤醒沙箱，再把决定交给 agent。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn approving_wakes_a_paused_sandbox() {
    let Some(e) = env().await else { return };
    let run = e.queue("need approval to clean up", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    assert!(e.lifecycle.pause(e.instance.id).await.unwrap());
    assert_eq!(
        e.instance_state().await,
        proto::domain::InstanceState::Paused
    );
    e.approve_pending().await;
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(e.state(run).await.run.state, RunState::Succeeded);
    assert_eq!(
        e.instance_state().await,
        proto::domain::InstanceState::Running
    );
}

/// 等审批时被打断（发版、副本挂了）：没处理的审批作废，下次尝试 agent 从 perm-1 重新请求也不会撞上。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn interrupted_approvals_are_asked_again_on_the_next_attempt() {
    let Some(e) = env().await else { return };
    let run = e.queue("need approval to clean up", None, 3).await;
    let (stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    stop.send(true).unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(e.state(run).await.run.state, RunState::Backoff);
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(
        tx.pending_approvals().await.unwrap().is_empty(),
        "the old request is void"
    );
    tx.rollback().await.unwrap();
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    e.approve_pending().await;
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!((rec.run.state, rec.run.attempt), (RunState::Succeeded, 2));
}

/// 等审批的运行让出执行名额：只有一个名额时，别的运行照样能跑；批准后它拿回名额接着跑完。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn runs_waiting_for_approval_do_not_hold_an_execution_slot() {
    let Some(e) = env_with(
        ExecutorConfig {
            max_concurrent: 1,
            claim_poll: Duration::from_millis(50),
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
    else {
        return;
    };
    let waiting = e.queue("need approval to clean up", None, 3).await;
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let exec = e.exec.clone();
    let loop_handle = tokio::spawn(async move {
        exec.run(async {
            let _ = stop_rx.await;
        })
        .await
    });
    e.wait_state(waiting, RunState::WaitingApproval).await;
    // 另一个实例上的运行（同一个实例同时只跑一个运行）。
    let second = e
        .lifecycle
        .adopt(e.user, "user:d", "claude", None, "Claude 2")
        .await
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_run_grant(
        second.id,
        None,
        &GrantScope::default(),
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    let other = tx
        .create_run(&NewRun::new(
            second.id,
            RunSource::User,
            "please say hello",
            &second.agent_version,
        ))
        .await
        .unwrap()
        .id;
    tx.commit().await.unwrap();
    e.wait_state(other, RunState::Succeeded).await;
    e.approve_pending().await;
    e.wait_state(waiting, RunState::Succeeded).await;
    let _ = stop_tx.send(());
    tokio::time::timeout(Duration::from_secs(20), loop_handle)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn nul_characters_in_agent_output_do_not_break_finishing() {
    let Some(e) = env().await else { return };
    let run = e.queue("reply with a nul", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("donehere"));
    assert_eq!(rec.lease_owner, None);
}

/// 续租赶不上、租约被别的副本接手：原来的执行停下 agent，接手的副本的运行原样不动（不取消、不改状态）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_taken_over_run_is_left_to_the_new_holder() {
    let Some(e) = env_with(
        ExecutorConfig {
            lease: Duration::from_millis(300),
            renew_every: Duration::from_secs(1),
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("loop forever", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    // 续租间隔比租约长：两次续租之间租约会过期，等到那时接手（机器忙时时间点不固定，轮询）。
    // 每次新开事务：now() 是事务开始的时间。
    let mut taken = Vec::new();
    let mut w = e.t.db.worker().await.unwrap();
    for _ in 0..100 {
        taken = w
            .take_over_expired("node-b", Duration::from_secs(60), 10)
            .await
            .unwrap();
        if !taken.is_empty() {
            break;
        }
        w.rollback().await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        w = e.t.db.worker().await.unwrap();
    }
    assert_eq!(taken.len(), 1);
    // 接手的副本已经让 agent 请求了一次审批。
    w.create_approval(&store::NewApproval {
        user: e.user,
        instance: e.instance.id,
        run,
        request_id: "2:p1",
        title: Some("Delete old reports"),
        options: &json!([{ "option_id": "allow", "name": "Allow", "kind": "allow_once" }]),
        tool_call: &json!({}),
        expires_in: Duration::from_secs(600),
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), h)
        .await
        .expect("the old holder stops")
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Running);
    assert_eq!(rec.lease_owner.as_deref(), Some("node-b"));
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert_eq!(
        tx.pending_approvals().await.unwrap().len(),
        1,
        "the new holder's approval is untouched"
    );
}

/// 运行的一次尝试结束、运行被取消时，签给它的沙箱令牌作废（实例的令牌代数加一），
/// agent 留在沙箱里的后台进程不能接着用模型网关。排队中的运行被取消不动代数（它没有令牌）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sandbox_tokens_die_with_the_run() {
    let Some(e) = env().await else { return };
    let epoch = || async {
        let mut w = e.t.db.worker().await.unwrap();
        let rt = w.instance_runtime(e.instance.id).await.unwrap();
        w.rollback().await.unwrap();
        rt.token_epoch
    };
    assert_eq!(epoch().await, 0);
    e.queue("say hello", None, 3).await;
    e.run_to_end().await;
    assert_eq!(epoch().await, 1, "the finished attempt's token is dead");

    let queued = e.queue("say hello", None, 3).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(queued, None).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(epoch().await, 1, "a queued run had no token");

    let run = e.queue("loop forever", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(run, None).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(epoch().await, 2, "cancelling kills the token at once");
    tokio::time::timeout(Duration::from_secs(10), h)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        epoch().await,
        2,
        "the executor does not bump again (the next run may already hold a token)"
    );
}

/// 密码保险箱（9.11）：沙箱里的助手按名字拿到值（授权里有保险箱工具、条目允许这个实例），
/// 记审计和运行日志（只记名字）；运行日志、摘要里看不到值。没有授权时拿不到。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_vault_helper_gets_values_and_logs_never_show_them() {
    let scope = GrantScope {
        platform_tools: vec!["vault_list".into()],
        ..GrantScope::default()
    };
    let Some(e) = env_with(fast(), Some(scope), Arc::new(VaultStub)).await else {
        return;
    };
    let vault = orchestrator::artifacts::user_vault(&e.t.db, kms(), e.user, true)
        .await
        .unwrap();
    let id = proto::domain::VaultItemId::new();
    let sealed = vault
        .seal_vault(
            &e.user.to_string(),
            &id.to_string(),
            &keyvault::VaultSecret {
                username: "octocat".into(),
                password: "gh-secret-123".into(),
            },
        )
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_vault_item(&store::NewVaultItem {
        id,
        name: "github".into(),
        purpose: "push code".into(),
        sealed,
        has_username: true,
        instance_ids: vec![e.instance.id],
    })
    .await
    .unwrap();
    tx.commit().await.unwrap();

    let run = e.queue("please use vault", None, 1).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(
        rec.run.summary.as_deref(),
        Some("got [vault:github] for octocat")
    );
    let events = e.events(run).await;
    let all = serde_json::to_string(&events).unwrap();
    assert!(!all.contains("gh-secret-123"), "{all}");
    assert!(all.contains("[vault:github]"), "{all}");
    let used: Vec<&Value> = events
        .iter()
        .filter(|(k, _)| k == "vault.used")
        .map(|(_, p)| p)
        .collect();
    assert_eq!(used, [&json!({ "names": ["github"] })]);
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(tx.vault_items().await.unwrap()[0].last_used_at.is_some());
    tx.rollback().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_vault_needs_the_grant() {
    let Some(e) = env().await else { return };
    let run = e.queue("please use vault", None, 1).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert!(
        rec.run
            .summary
            .as_deref()
            .is_some_and(|s| s.contains("not allowed to use the password vault")),
        "{:?}",
        rec.run.summary
    );
}
