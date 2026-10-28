//! 流水线端到端：调度循环到点生成流水线运行 → 流水线驱动按依赖开始各步 → 执行器（shim 替身）执行 →
//! 上游用平台工具发布产出物 → 下游拿到交接说明和工作区里的文件。还有失败传播和整树停止。
//! 需要 DATABASE_URL（没有时跳过）。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use chrono::Utc;
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use keyvault::LocalKms;
use orchestrator::artifacts::{ArtifactStore, LocalBlobStore, Origin};
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::pipeline::{HandoffCopier, PipelineConfig, PipelineDriver};
use orchestrator::scheduler::{Scheduler, SchedulerConfig};
use orchestrator::shim::{
    ConnectError, PlatformTools, ShimConnector, ShimLaunch, ShimProcess, ShimSession, ToolContext,
    ToolOutput,
};
use orchestrator::tools::{ARTIFACT_TOOLS, ArtifactTools, ToolSet};
use proto::domain::{
    CatchUp, GrantId, GrantScope, Instance, PlanAuthor, PlanId, PlanPolicy, PlanStep, RunId,
    RunKind, RunSource, RunState, ScheduleSpec, UserId,
};
use proto::shim::{ShimCommand, ShimEvent, StopReason};
use sandbox::local::LocalProvider;
use sandbox::{SandboxId, SandboxProvider};
use serde_json::json;
use store::NewPlan;
use store::testing::TestDb;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

// ---------- shim 替身：publish:<名字>:<内容> 发布产出物；fail 拒绝；其他回显 ----------

#[derive(Clone, Default)]
struct Fake {
    prompts: Arc<Mutex<Vec<String>>>,
}

struct Proc(Option<JoinHandle<()>>);

#[async_trait]
impl ShimProcess for Proc {
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
impl ShimConnector for Fake {
    async fn start(&self, _launch: &ShimLaunch) -> Result<ShimSession, ConnectError> {
        let (cmd_tx, mut cmds) = mpsc::channel::<ShimCommand>(16);
        let (ev, ev_rx) = mpsc::channel::<ShimEvent>(64);
        let prompts = self.prompts.clone();
        let task = tokio::spawn(async move {
            let _ = ev
                .send(ShimEvent::Ready {
                    protocol_version: 1,
                    agent_id: "fake".into(),
                    harness: "acp".into(),
                    agent_info: None,
                    session_id: "s".into(),
                    session_restored: false,
                })
                .await;
            while let Some(cmd) = cmds.recv().await {
                match cmd {
                    ShimCommand::Prompt { run_id, text } => {
                        prompts.lock().unwrap().push(text.clone());
                        let _ = ev
                            .send(ShimEvent::TurnStarted {
                                run_id: run_id.clone(),
                            })
                            .await;
                        let first = text.lines().next().unwrap_or_default().to_owned();
                        let say = |t: String| ShimEvent::MessageChunk {
                            run_id: Some(run_id.clone()),
                            text: t,
                        };
                        let end = |r| ShimEvent::TurnEnded {
                            run_id: run_id.clone(),
                            stop_reason: r,
                        };
                        if let Some(rest) = first.strip_prefix("publish:") {
                            let (name, content) = rest.split_once(':').unwrap();
                            let _ = ev
                                .send(ShimEvent::PlatformToolCall {
                                    run_id: run_id.clone(),
                                    call_id: "c1".into(),
                                    name: "artifact_publish".into(),
                                    arguments: json!({ "name": name, "content": content }),
                                })
                                .await;
                            while let Some(c) = cmds.recv().await {
                                if let ShimCommand::PlatformToolResult {
                                    is_error, content, ..
                                } = c
                                {
                                    assert!(!is_error, "publish failed: {content:?}");
                                    break;
                                }
                            }
                            let _ = ev.send(say(format!("published {name}"))).await;
                            let _ = ev.send(end(StopReason::EndTurn)).await;
                        } else if first == "fail" {
                            let _ = ev.send(end(StopReason::Refusal)).await;
                        } else {
                            let _ = ev.send(say(format!("done: {first}"))).await;
                            let _ = ev.send(end(StopReason::EndTurn)).await;
                        }
                    }
                    ShimCommand::Cancel { run_id } => {
                        let _ = ev
                            .send(ShimEvent::TurnEnded {
                                run_id,
                                stop_reason: StopReason::Cancelled,
                            })
                            .await;
                    }
                    ShimCommand::Shutdown => return,
                    _ => {}
                }
            }
        });
        Ok(ShimSession {
            commands: cmd_tx,
            events: ev_rx,
            process: Box::new(Proc(Some(task))),
        })
    }
}

// ---------- 环境 ----------

struct Env {
    t: TestDb,
    _dir: tempfile::TempDir,
    provider: Arc<LocalProvider>,
    exec: Arc<Executor>,
    driver: PipelineDriver,
    fake: Fake,
    user: UserId,
    a: Instance,
    b: Instance,
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let dir = tempfile::tempdir().unwrap();
    let provider = Arc::new(LocalProvider::new(dir.path().join("sbx")).unwrap());
    let lifecycle = Arc::new(Lifecycle::new(
        t.db.clone(),
        provider.clone(),
        Arc::new(BuiltinTemplates),
        LifecycleConfig::default(),
    ));
    let grants = Arc::new(GrantService::new(
        t.db.clone(),
        GrantConfig::default(),
        SandboxTokenIssuer::generate("s1").unwrap(),
    ));
    let store = Arc::new(ArtifactStore::new(
        t.db.clone(),
        Arc::new(LocalBlobStore::new(dir.path().join("blobs")).unwrap()),
        Arc::new(LocalKms::new("kms", &[5; 32])),
    ));
    let tools: Arc<dyn PlatformTools> = Arc::new(ToolSet::new(vec![Arc::new(ArtifactTools::new(
        t.db.clone(),
        store.clone(),
        provider.clone(),
        "workspace",
    ))]));
    let fake = Fake::default();
    let exec = Arc::new(
        Executor::new(
            t.db.clone(),
            "node-a",
            lifecycle.clone(),
            grants,
            Arc::new(fake.clone()),
            tools,
            ExecutorConfig {
                renew_every: Duration::from_millis(200),
                stop_timeout: Duration::from_secs(2),
                ..ExecutorConfig::default()
            },
        )
        .with_handoff(Arc::new(HandoffCopier::new(
            t.db.clone(),
            store,
            provider.clone(),
            "workspace",
        ))),
    );
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let a = control::adopt(
        &t.db,
        &BuiltinTemplates,
        user.id,
        "user:d",
        "claude",
        None,
        "researcher",
    )
    .await
    .unwrap();
    let b = control::adopt(
        &t.db,
        &BuiltinTemplates,
        user.id,
        "user:d",
        "codex",
        None,
        "writer",
    )
    .await
    .unwrap();
    Some(Env {
        driver: PipelineDriver::new(t.db.clone(), PipelineConfig::default()),
        t,
        _dir: dir,
        provider,
        exec,
        fake,
        user: user.id,
        a,
        b,
    })
}

impl Env {
    /// 建一个带步骤的计划（计划授权里有产出物工具），到点。
    async fn plan(&self, steps: Vec<PlanStep>) -> PlanId {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let plan = tx
            .create_plan(&NewPlan {
                instance_id: self.a.id,
                title: "周报".into(),
                goal: "write the weekly report".into(),
                policy: PlanPolicy::default(),
                catch_up: CatchUp::Once,
                created_by: PlanAuthor::User,
                run_grant_id: None,
            })
            .await
            .unwrap();
        let grant = tx
            .create_run_grant(
                self.a.id,
                Some(plan.id),
                &GrantScope {
                    platform_tools: ARTIFACT_TOOLS.iter().map(|s| s.to_string()).collect(),
                    ..GrantScope::default()
                },
                Duration::from_secs(3600),
            )
            .await
            .unwrap();
        tx.set_plan_grant(plan.id, grant.id).await.unwrap();
        tx.set_plan_steps(plan.id, &steps).await.unwrap();
        tx.add_trigger(
            plan.id,
            &ScheduleSpec::Cron {
                expr: "0 9 * * 1".into(),
                tz: "Asia/Shanghai".into(),
            },
            Some(Utc::now() - chrono::Duration::minutes(5)),
        )
        .await
        .unwrap();
        tx.commit().await.unwrap();
        plan.id
    }

    /// 驱动流水线和执行器，直到根运行结束。
    async fn drive(&self, root: RunId) -> store::RunRecord {
        for _ in 0..100 {
            self.driver.tick().await.unwrap();
            while let Some(rec) = self.exec.claim().await.unwrap() {
                let (_tx, rx) = watch::channel(false);
                self.exec.execute(rec, rx).await;
            }
            let r = self.record(root).await;
            if r.run.state.is_terminal() {
                return r;
            }
        }
        panic!("pipeline did not finish: {:?}", self.record(root).await.run);
    }

    async fn record(&self, id: RunId) -> store::RunRecord {
        let mut w = self.t.db.worker().await.unwrap();
        let r = w.run_record(id).await.unwrap();
        w.rollback().await.unwrap();
        r
    }

    async fn root_of(&self, plan: PlanId) -> RunId {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let runs = tx.runs(self.a.id, None, 50).await.unwrap();
        runs.into_iter()
            .find(|r| r.plan_id == Some(plan) && r.kind == RunKind::Pipeline)
            .expect("a pipeline run")
            .id
    }
}

fn step(key: &str, inst: &Instance, prompt: &str, deps: &[&str]) -> PlanStep {
    PlanStep {
        key: key.into(),
        instance_id: inst.id,
        prompt: prompt.into(),
        depends_on: deps.iter().map(|d| d.to_string()).collect(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn steps_run_in_dependency_order_and_hand_over_artifacts() {
    let Some(e) = env().await else { return };
    let plan = e
        .plan(vec![
            step("report", &e.b, "write the report", &["research", "data"]),
            step("research", &e.a, "publish:notes.md:three facts", &[]),
            step("data", &e.b, "collect numbers", &[]),
        ])
        .await;
    let report = Scheduler::new(e.t.db.clone(), SchedulerConfig::default())
        .tick(Utc::now())
        .await
        .unwrap();
    assert_eq!(report.runs_created, 1);
    let root = e.root_of(plan).await;
    let done = e.drive(root).await;
    assert_eq!(done.run.state, RunState::Succeeded, "{:?}", done.run);
    assert_eq!(
        done.run.summary.as_deref(),
        Some("report：done: write the report")
    );

    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let tree = tx.run_tree(root).await.unwrap();
    tx.rollback().await.unwrap();
    assert_eq!(tree.len(), 4);
    let child = |k: &str| {
        tree.iter()
            .find(|r| r.step_key.as_deref() == Some(k))
            .unwrap()
            .clone()
    };
    assert!(tree.iter().all(|r| r.state == RunState::Succeeded));
    assert_eq!(child("research").instance_id, e.a.id);
    assert_eq!(child("report").instance_id, e.b.id);
    // report 在两个上游都成功之后才开始。
    assert!(child("report").started_at > child("research").finished_at);
    assert!(child("report").started_at > child("data").finished_at);

    // 交接说明：上游摘要和产出物清单。
    let prompts = e.fake.prompts.lock().unwrap().clone();
    let report_prompt = prompts
        .iter()
        .find(|p| p.starts_with("write the report"))
        .unwrap();
    assert!(report_prompt.contains("交接说明"), "{report_prompt}");
    assert!(report_prompt.contains("research：published notes.md"));
    assert!(report_prompt.contains("data：done: collect numbers"));
    assert!(report_prompt.contains("handoff/notes.md"));
    // 上游产出物已经复制到下游的工作区。
    let mut w = e.t.db.worker().await.unwrap();
    let rt_b = w.instance_runtime(e.b.id).await.unwrap();
    let artifacts = w.tree_artifacts(root).await.unwrap();
    // 每一步都有自己实例上的子授权，从计划授权收窄而来。
    let report_rec = w.run_record(child("report").id).await.unwrap();
    let (_, g) = w.run_grant(report_rec.run_grant_id.unwrap()).await.unwrap();
    w.rollback().await.unwrap();
    assert_eq!(g.instance_id, e.b.id);
    assert!(g.parent_id.is_some());
    assert_eq!(artifacts.len(), 1);
    assert_eq!(artifacts[0].artifact.name, "notes.md");
    let copied = e
        .provider
        .read_file(
            &SandboxId(rt_b.sandbox_id.unwrap()),
            "workspace/handoff/notes.md",
            u64::MAX,
        )
        .await
        .unwrap();
    assert_eq!(copied, b"three facts");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failed_step_stops_the_pipeline() {
    let Some(e) = env().await else { return };
    let plan = e
        .plan(vec![
            step("first", &e.a, "fail", &[]),
            step("second", &e.b, "never runs", &["first"]),
        ])
        .await;
    Scheduler::new(e.t.db.clone(), SchedulerConfig::default())
        .tick(Utc::now())
        .await
        .unwrap();
    let root = e.root_of(plan).await;
    let done = e.drive(root).await;
    assert_eq!(done.run.state, RunState::Failed);
    assert!(done.run.error.unwrap().contains("step first failed"));
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let tree = tx.run_tree(root).await.unwrap();
    assert_eq!(tree.len(), 2, "second never started");
    tx.rollback().await.unwrap();
    assert!(
        !e.fake
            .prompts
            .lock()
            .unwrap()
            .iter()
            .any(|p| p.starts_with("never runs"))
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_whole_tree_can_be_stopped() {
    let Some(e) = env().await else { return };
    let plan = e
        .plan(vec![
            step("one", &e.a, "step one", &[]),
            step("two", &e.b, "step two", &[]),
        ])
        .await;
    Scheduler::new(e.t.db.clone(), SchedulerConfig::default())
        .tick(Utc::now())
        .await
        .unwrap();
    let root = e.root_of(plan).await;
    e.driver.tick().await.unwrap(); // 两步都开始（排队）
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert_eq!(
        tx.cancel_run_tree(root, "stopped by user").await.unwrap(),
        3
    );
    tx.commit().await.unwrap();
    assert!(
        e.exec.claim().await.unwrap().is_none(),
        "nothing left to run"
    );
    assert_eq!(e.record(root).await.run.state, RunState::Cancelled);
    e.driver.tick().await.unwrap();
    assert_eq!(e.record(root).await.run.state, RunState::Cancelled);
}

// ---------- 多 agent 协同（17.4） ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn independent_steps_run_side_by_side() {
    let Some(e) = env().await else { return };
    let plan = e
        .plan(vec![
            step("summary", &e.a, "sum up", &["left", "right"]),
            step("left", &e.a, "collect facts", &[]),
            step("right", &e.b, "collect numbers", &[]),
        ])
        .await;
    Scheduler::new(e.t.db.clone(), SchedulerConfig::default())
        .tick(Utc::now())
        .await
        .unwrap();
    let root = e.root_of(plan).await;
    // 第一次推进：没有依赖的两步一起排上队，下游的还没建。
    e.driver.tick().await.unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let tree = tx.run_tree(root).await.unwrap();
    tx.rollback().await.unwrap();
    let mut queued: Vec<&str> = tree
        .iter()
        .filter(|r| r.state == RunState::Queued)
        .filter_map(|r| r.step_key.as_deref())
        .collect();
    queued.sort_unstable();
    assert_eq!(queued, ["left", "right"]);
    assert!(
        tree.iter()
            .all(|r| r.step_key.as_deref() != Some("summary"))
    );
    // 两步各在自己的实例上，同时领起来、同时执行。
    let first = e.exec.claim().await.unwrap().expect("a step to run");
    let second = e.exec.claim().await.unwrap().expect("the other step");
    assert_ne!(first.run.instance_id, second.run.instance_id);
    let run = |rec: store::RunRecord| {
        let exec = e.exec.clone();
        tokio::spawn(async move {
            let (_stop, rx) = watch::channel(false);
            exec.execute(rec, rx).await;
        })
    };
    let (one, two) = (run(first), run(second));
    one.await.unwrap();
    two.await.unwrap();
    // 两个上游都完成后，下游接着跑，整条流水线完成。
    let done = e.drive(root).await;
    assert_eq!(done.run.state, RunState::Succeeded, "{:?}", done.run);
    assert_eq!(done.run.summary.as_deref(), Some("summary：done: sum up"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn scheduled_pipelines_start_one_live_activity() {
    let Some(e) = env().await else { return };
    // 用户的 iPhone 开了“计划运行时显示实时活动”。
    let mut w = e.t.db.worker().await.unwrap();
    let phone = w
        .create_device(e.user, proto::domain::DevicePlatform::Ios, "iPhone", None)
        .await
        .unwrap();
    w.create_session(
        proto::domain::SessionId::new(),
        e.user,
        phone,
        b"r",
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.set_activity_start_token(phone, Some("5747a77e"))
        .await
        .unwrap();
    tx.commit().await.unwrap();

    let plan = e
        .plan(vec![
            step("research", &e.a, "find three facts", &[]),
            step("report", &e.b, "write the report", &["research"]),
        ])
        .await;
    Scheduler::new(e.t.db.clone(), SchedulerConfig::default())
        .tick(Utc::now())
        .await
        .unwrap();
    let root = e.root_of(plan).await;
    let done = e.drive(root).await;
    assert_eq!(done.run.state, RunState::Succeeded, "{:?}", done.run);
    // 流水线开始时给根运行开一个；步骤不单独开。
    let rows: Vec<(uuid::Uuid, String)> =
        sqlx::query_as("SELECT run_id, origin FROM live_activities WHERE device_id = $1")
            .bind(phone.0)
            .fetch_all(e.t.db.pool())
            .await
            .unwrap();
    assert_eq!(rows, vec![(root.0, "push".to_owned())]);
}

/// 第一步就起不来（步骤用的实例被删了）：这个流水线失败，别的流水线照常推进（之前每一轮都在这里出错回滚）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_pipeline_whose_first_step_cannot_start_fails_alone() {
    let Some(e) = env().await else { return };
    let broken = e.plan(vec![step("only", &e.b, "write", &[])]).await;
    let fine = e
        .plan(vec![step("only", &e.a, "find three facts", &[])])
        .await;
    Scheduler::new(e.t.db.clone(), SchedulerConfig::default())
        .tick(Utc::now())
        .await
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_instance_runs(e.b.id, "instance deleted")
        .await
        .unwrap();
    tx.revoke_instance_grants(e.b.id, "instance deleted")
        .await
        .unwrap();
    tx.delete_instance(e.b.id).await.unwrap();
    tx.commit().await.unwrap();
    let broken_root = e.root_of(broken).await;
    let fine_root = e.root_of(fine).await;
    e.driver.tick().await.unwrap();
    assert_eq!(e.record(broken_root).await.run.state, RunState::Failed);
    let done = e.drive(fine_root).await;
    assert_eq!(done.run.state, RunState::Succeeded, "{:?}", done.run);
}

/// 回答队友的问题（8.11）时只看得到、只写得进这个问题下面的产出物：问的是信息，不是权限。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn answering_a_question_sees_only_its_own_artifacts() {
    let Some(e) = env().await else { return };
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(ArtifactStore::new(
        e.t.db.clone(),
        Arc::new(LocalBlobStore::new(dir.path()).unwrap()),
        Arc::new(LocalKms::new("kms", &[5; 32])),
    ));
    let tools = ArtifactTools::new(
        e.t.db.clone(),
        store.clone(),
        e.provider.clone(),
        "workspace",
    );
    // a 在做任务 r，问了 b 一个问题 q。
    let mut w = e.t.db.worker().await.unwrap();
    let r = w
        .create_run(
            e.user,
            &store::NewRun::new(e.a.id, RunSource::User, "report", &e.a.agent_version),
        )
        .await
        .unwrap()
        .unwrap();
    let mut q = store::NewRun::new(e.b.id, RunSource::Ask, "q", &e.b.agent_version);
    q.parent_run_id = Some(r.id);
    let q = w.create_run(e.user, &q).await.unwrap().unwrap();
    w.commit().await.unwrap();
    store
        .publish(
            Origin {
                user: e.user,
                instance: e.a.id,
                run: r.id,
                root: r.id,
            },
            "inbox.md",
            "text/markdown",
            b"private",
        )
        .await
        .unwrap();
    let ctx = |instance, run| ToolContext {
        user: e.user,
        instance,
        run,
        plan: None,
        grant: GrantId::new(),
    };
    let text = |o: &ToolOutput| o.content[0]["text"].as_str().unwrap_or_default().to_owned();
    let mine = tools
        .call(&ctx(e.a.id, r.id), "artifact_list", &json!({}))
        .await;
    assert!(text(&mine).contains("inbox.md"), "{}", text(&mine));
    let theirs = tools
        .call(&ctx(e.b.id, q.id), "artifact_list", &json!({}))
        .await;
    assert!(!text(&theirs).contains("inbox.md"), "{}", text(&theirs));
    let read = tools
        .call(
            &ctx(e.b.id, q.id),
            "artifact_read",
            &json!({ "name": "inbox.md" }),
        )
        .await;
    assert!(read.is_error, "{}", text(&read));
}
