//! 项目里的协作（8.17）的执行器端到端测试：两个用户的专属 botin 在一个共享项目里查队友、看板、提问、委派（shim 替身 +
//! 本地沙箱 + 真实 Postgres）。创建者派的任务经库里的派单建出来，工具是真的（查队友、看板、提问、委派、产出物）。
//! 没有 DATABASE_URL 时跳过。
//!
//! 角色：alice 建了项目「Launch」，她的 botin「Alice-A」专属于项目、是负责人；她还有一个私人的「Diary」和一个混用的
//! 「Mixed」。bob 带着专属的「Bob-B」加入（bob 用英文）。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use orchestrator::artifacts::{ArtifactStore, LocalBlobStore};
use orchestrator::ask::AskTools;
use orchestrator::board::BoardTools;
use orchestrator::delegate::DelegateTools;
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::peers::PeerTools;
use orchestrator::pipeline::{HandoffCopier, PipelineConfig, PipelineDriver};
use orchestrator::projects;
use orchestrator::shim::{
    ConnectError, PlatformTools, ShimConnector, ShimLaunch, ShimProcess, ShimSession, ToolContext,
    ToolOutput,
};
use orchestrator::tools::{ArtifactTools, PROJECT_RUN_TOOLS, ToolSet};
use proto::domain::{
    GrantId, Instance, PROJECT_CONSENT_VERSION, ProjectId, ProjectPipelineStep, RunId, RunSource,
    RunState, UserId,
};
use proto::shim::{PlatformTool, ShimCommand, ShimEvent, StopReason};
use sandbox::local::LocalProvider;
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{Consent, Db, InviteCaps, InviteKey, JoinAgent, JoinTerms, NewRun, SoloAgent};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

const ACTOR: &str = "user:test-device";
const KMS_KEY: [u8; 32] = [7; 32];
const STOP_HERE: &str = "this run is over or the agent's workspace changed; stop here";

fn kms() -> Arc<dyn keyvault::Kms> {
    Arc::new(keyvault::LocalKms::new("kms1", &KMS_KEY))
}

// ---------- shim 替身：按提示词一行行表演 ----------

#[derive(Debug, Clone)]
struct Call {
    run: String,
    name: String,
    error: bool,
    text: String,
}

#[derive(Default)]
struct Recorded {
    /// 每次启动：运行、交给 shim 的平台工具（名字）。
    launches: Vec<(RunId, Vec<String>)>,
    /// 每一轮：运行 id、交给 agent 的消息。
    prompts: Vec<(String, String)>,
    calls: Vec<Call>,
}

#[derive(Default, Clone)]
struct Fake {
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
impl ShimConnector for Fake {
    async fn start(&self, launch: &ShimLaunch) -> Result<ShimSession, ConnectError> {
        self.rec.lock().unwrap().launches.push((
            launch.run,
            launch
                .platform_tools
                .iter()
                .map(|t| t.name.clone())
                .collect(),
        ));
        let (cmd_tx, cmd_rx) = mpsc::channel(16);
        let (ev_tx, ev_rx) = mpsc::channel(64);
        let task = tokio::spawn(fake_shim(cmd_rx, ev_tx, self.rec.clone()));
        Ok(ShimSession {
            commands: cmd_tx,
            events: ev_rx,
            process: Box::new(FakeProcess(Some(task))),
        })
    }
}

/// 交还结果的消息后面附着原来的任务（供参考）：替身不再照着它表演一遍。
fn script(text: &str) -> &str {
    ["原来的任务（供参考）", "The original task, for reference"]
        .iter()
        .filter_map(|m| text.find(m))
        .min()
        .map_or(text, |i| &text[..i])
}

/// 提示词的每一行：`call 工具 [JSON 参数]` 调平台工具；`say 文字` 照说；`refuse` 这一轮以模型拒绝结束；`crash once`
/// 第一次尝试时崩溃（续跑时不崩）。一轮结束时把说的话一行一行回复出去。
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
    while let Some(cmd) = cmds.recv().await {
        let (run_id, text) = match cmd {
            ShimCommand::Prompt { run_id, text } => (run_id, text),
            ShimCommand::Cancel { run_id } => {
                let _ = ev
                    .send(ShimEvent::TurnEnded {
                        run_id,
                        stop_reason: StopReason::Cancelled,
                    })
                    .await;
                continue;
            }
            ShimCommand::Shutdown => return,
            _ => continue,
        };
        rec.lock()
            .unwrap()
            .prompts
            .push((run_id.clone(), text.clone()));
        let _ = ev
            .send(ShimEvent::TurnStarted {
                run_id: run_id.clone(),
            })
            .await;
        let retry = text.contains("续跑说明") || text.contains("Resume note");
        let mut said: Vec<String> = Vec::new();
        let mut stop = StopReason::EndTurn;
        for (i, line) in script(&text).lines().enumerate() {
            if let Some(rest) = line.strip_prefix("call ") {
                let (name, args) = rest.split_once(' ').unwrap_or((rest, "{}"));
                let arguments: Value = serde_json::from_str(args).unwrap_or_else(|_| json!({}));
                let _ = ev
                    .send(ShimEvent::PlatformToolCall {
                        run_id: run_id.clone(),
                        call_id: format!("c{i}"),
                        name: name.into(),
                        arguments,
                    })
                    .await;
                let call = loop {
                    match cmds.recv().await {
                        Some(ShimCommand::PlatformToolResult {
                            content, is_error, ..
                        }) => {
                            break Call {
                                run: run_id.clone(),
                                name: name.into(),
                                error: is_error,
                                text: content[0]["text"].as_str().unwrap_or_default().to_owned(),
                            };
                        }
                        Some(ShimCommand::Shutdown) | None => return,
                        Some(_) => {}
                    }
                };
                rec.lock().unwrap().calls.push(call);
            } else if let Some(t) = line.strip_prefix("say ") {
                said.push(t.into());
            } else if line == "refuse" {
                stop = StopReason::Refusal;
            } else if line == "crash once" && !retry {
                return;
            }
        }
        let _ = ev
            .send(ShimEvent::MessageChunk {
                run_id: Some(run_id.clone()),
                text: said.join("\n"),
            })
            .await;
        let _ = ev
            .send(ShimEvent::TurnEnded {
                run_id,
                stop_reason: stop,
            })
            .await;
    }
}

// ---------- 平台工具 ----------

/// 联网搜索和项目里用不了的日程、保险箱工具的替身。
struct Stub;

const STUB_TOOLS: [&str; 3] = ["web_search", "schedule_list", "vault_list"];

#[async_trait]
impl PlatformTools for Stub {
    fn tools(&self) -> Vec<PlatformTool> {
        STUB_TOOLS
            .iter()
            .map(|name| PlatformTool {
                read_only: false,
                name: (*name).into(),
                description: (*name).into(),
                input_schema: json!({ "type": "object" }),
            })
            .collect()
    }
    async fn call(&self, _ctx: &ToolContext, name: &str, _args: &Value) -> ToolOutput {
        ToolOutput::text(format!("{name} done"))
    }
}

fn sorted(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v
}

// ---------- 环境 ----------

struct Env {
    t: TestDb,
    _dir: tempfile::TempDir,
    exec: Arc<Executor>,
    provider: Arc<LocalProvider>,
    tools: Arc<ToolSet>,
    fake: Fake,
    alice: UserId,
    bob: UserId,
    p: ProjectId,
    /// alice 的专属 botin，负责人。
    a: Instance,
    /// bob 的专属 botin。
    b: Instance,
    /// alice 的私人 botin（不在项目里）。
    x: Instance,
    /// alice 在项目里的混用 botin（单人项目时加的）。
    m: Instance,
}

async fn display_name(db: &Db, user: UserId, name: &str, locale: &str) {
    sqlx::query("UPDATE users SET display_name = $2, locale = $3 WHERE id = $1")
        .bind(user.0)
        .bind(name)
        .bind(locale)
        .execute(db.pool())
        .await
        .unwrap();
}

/// 绕过触发器直接改库（模拟运行走到某个状态、老数据）：只有超级用户能这样写。
async fn raw_sql(db: &Db, sql: &str, binds: &[uuid::Uuid]) {
    let mut tx = db.pool().begin().await.unwrap();
    sqlx::query("SET LOCAL session_replication_role = replica")
        .execute(&mut *tx)
        .await
        .unwrap();
    let mut q = sqlx::query(sqlx::AssertSqlSafe(sql.to_owned()));
    for b in binds {
        q = q.bind(*b);
    }
    q.execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
}

async fn env(phone: u64) -> Option<Env> {
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
        kms(),
    ));
    let providers: Vec<Arc<dyn PlatformTools>> = vec![
        Arc::new(ArtifactTools::new(
            t.db.clone(),
            store.clone(),
            provider.clone(),
            "workspace",
        )),
        Arc::new(PeerTools::new(t.db.clone())),
        Arc::new(BoardTools::new(t.db.clone(), kms())),
        Arc::new(AskTools::new(t.db.clone(), kms())),
        Arc::new(DelegateTools::new(t.db.clone())),
        Arc::new(Stub),
    ];
    let tools = Arc::new(ToolSet::new(providers));
    let fake = Fake::default();
    let exec = Arc::new(
        Executor::new(
            t.db.clone(),
            "node-a",
            lifecycle.clone(),
            grants,
            Arc::new(fake.clone()),
            tools.clone(),
            ExecutorConfig {
                renew_every: Duration::from_millis(100),
                approval_poll: Duration::from_millis(50),
                stop_timeout: Duration::from_secs(2),
                backoff_base: Duration::ZERO,
                ..ExecutorConfig::default()
            },
        )
        .with_vault(kms())
        .with_handoff(Arc::new(HandoffCopier::new(
            t.db.clone(),
            store,
            provider.clone(),
            "workspace",
        ))),
    );
    let mut w = t.db.worker().await.unwrap();
    let (alice, _) = w
        .upsert_user_by_phone(&format!("+86{phone}"))
        .await
        .unwrap();
    let (bob, _) = w
        .upsert_user_by_phone(&format!("+86{}", phone + 1))
        .await
        .unwrap();
    w.commit().await.unwrap();
    let (alice, bob) = (alice.id, bob.id);
    display_name(&t.db, alice, "Alice", "zh-CN").await;
    display_name(&t.db, bob, "Bob", "en").await;
    let a = lifecycle
        .adopt(alice, "user:d", "claude", None, "Alice-A")
        .await
        .unwrap();
    let x = lifecycle
        .adopt(alice, "user:d", "claude", None, "Diary")
        .await
        .unwrap();
    let m = lifecycle
        .adopt(alice, "user:d", "claude", None, "Mixed")
        .await
        .unwrap();
    let b = lifecycle
        .adopt(bob, "user:d", "claude", None, "Bob-B")
        .await
        .unwrap();
    // bob 私人时干过一件事：运行日志还在 B 的事件里，项目里谁也看不到。
    let mut tx = t.db.tenant(bob).await.unwrap();
    let old = tx
        .create_run(&NewRun::new(
            b.id,
            RunSource::User,
            "bob private diary",
            &b.agent_version,
        ))
        .await
        .unwrap();
    tx.cancel_run(old.id, None).await.unwrap();
    tx.commit().await.unwrap();
    let mut w = t.db.worker().await.unwrap();
    w.append_event(
        b.id,
        Some(old.id),
        "agent.message",
        &json!({ "text": "bob-private-note-5521" }),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    let mut tx = t.db.tenant(alice).await.unwrap();
    let p = tx
        .create_solo_project(
            "Launch",
            "Ship the launch plan",
            &[
                SoloAgent {
                    instance_id: a.id,
                    is_lead: true,
                    position: 0,
                },
                SoloAgent {
                    instance_id: m.id,
                    is_lead: false,
                    position: 1,
                },
            ],
        )
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert!(
        projects::dedicate_agent(&t.db, kms(), alice, ACTOR, p, a.id)
            .await
            .unwrap()
    );
    let hash = [phone as u8; 32];
    projects::invite_link(&t.db, alice, ACTOR, p, &hash, InviteCaps::default())
        .await
        .unwrap();
    projects::accept(
        &t.db,
        kms(),
        bob,
        ACTOR,
        InviteKey::Link(&hash),
        &JoinTerms {
            agents: vec![JoinAgent::Existing {
                id: b.id,
                dedicate: true,
                ack_shared_memory: false,
            }],
            daily_token_limit: 1_000_000,
            total_token_limit: 5_000_000,
            consent: Consent {
                version: PROJECT_CONSENT_VERSION,
            },
            mixed_allowed: false,
            max_instances: 0,
        },
    )
    .await
    .unwrap();
    Some(Env {
        t,
        _dir: dir,
        exec,
        provider,
        tools,
        fake,
        alice,
        bob,
        p,
        a,
        b,
        x,
        m,
    })
}

impl Env {
    fn db(&self) -> &Db {
        &self.t.db
    }

    /// alice（创建者）给 `to` 派一个任务。返回运行和它的授权。
    async fn task(&self, to: &Instance, prompt: &str) -> (RunId, GrantId) {
        let mut w = self.db().worker().await.unwrap();
        let d = w
            .create_project_task(
                self.alice,
                self.p,
                Some(to.id),
                prompt,
                Duration::from_secs(3600),
            )
            .await
            .unwrap();
        w.commit().await.unwrap();
        let grant = self.state(d.run.id).await.run_grant_id.expect("a grant");
        (d.run.id, grant)
    }

    /// `to` 上一个排着的任务的工具上下文（直接调工具用：排着的运行还没结束）。
    async fn ctx(&self, to: &Instance, owner: UserId) -> ToolContext {
        let (run, grant) = self.task(to, "hold").await;
        ToolContext {
            user: owner,
            instance: to.id,
            run,
            plan: None,
            grant,
            project: Some(self.p),
        }
    }

    async fn tool(&self, ctx: &ToolContext, name: &str, args: Value) -> (bool, String) {
        let out = self.tools.call(ctx, name, &args).await;
        (
            out.is_error,
            out.content[0]["text"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
        )
    }

    async fn tool_json(&self, ctx: &ToolContext, name: &str, args: Value) -> Value {
        let (error, text) = self.tool(ctx, name, args).await;
        assert!(!error, "{name}: {text}");
        serde_json::from_str(&text).unwrap()
    }

    /// 领一个运行（必须有），在后台执行到结束。返回它。
    async fn run_next(&self) -> RunId {
        let rec = self.exec.claim().await.unwrap().expect("a run to claim");
        let id = rec.run.id;
        let (_stop, rx) = watch::channel(false);
        let exec = self.exec.clone();
        let h = tokio::spawn(async move { exec.execute(rec, rx).await });
        tokio::time::timeout(Duration::from_secs(20), h)
            .await
            .unwrap()
            .unwrap();
        id
    }

    async fn state(&self, run: RunId) -> store::RunRecord {
        let mut w = self.db().worker().await.unwrap();
        let r = w.run_record(run).await.unwrap();
        w.rollback().await.unwrap();
        r
    }

    /// 这个运行收到的消息（每一轮一条）。
    fn prompts(&self, run: RunId) -> Vec<String> {
        let id = run.to_string();
        self.fake
            .rec
            .lock()
            .unwrap()
            .prompts
            .iter()
            .filter(|(r, _)| *r == id)
            .map(|(_, t)| t.clone())
            .collect()
    }

    fn launch(&self, run: RunId) -> Vec<String> {
        self.fake
            .rec
            .lock()
            .unwrap()
            .launches
            .iter()
            .find(|(r, _)| *r == run)
            .map(|(_, t)| t.clone())
            .expect("a launch")
    }

    fn calls(&self, run: RunId) -> Vec<Call> {
        let id = run.to_string();
        self.fake
            .rec
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|c| c.run == id)
            .cloned()
            .collect()
    }

    /// 这个运行唯一的子运行。
    async fn only_child(&self, parent: RunId) -> store::RunRecord {
        let ids: Vec<uuid::Uuid> =
            sqlx::query_scalar("SELECT id FROM runs WHERE parent_run_id = $1")
                .bind(parent.0)
                .fetch_all(self.db().pool())
                .await
                .unwrap();
        assert_eq!(ids.len(), 1, "{ids:?}");
        self.state(RunId(ids[0])).await
    }
}

// ---------- 用例 ----------

/// 项目里的运行（O1、O11）：负责人 A 拿到全部 12 个项目工具，B 拿到除了委派以外的 10 个；日程、保险箱这些从来没有。
/// 负责人换成 B 以后，A 还在跑的运行再委派得到“只有负责人能委派”。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn project_run_tools_follow_the_project_lead() {
    let Some(e) = env(13800017001).await else {
        return;
    };
    let (ta, _) = e.task(&e.a, "say hi").await;
    assert_eq!(e.run_next().await, ta);
    let (tb, _) = e.task(&e.b, "say hi").await;
    assert_eq!(e.run_next().await, tb);
    assert_eq!(
        sorted(e.launch(ta)),
        sorted(PROJECT_RUN_TOOLS.map(String::from).to_vec())
    );
    let want: Vec<String> = PROJECT_RUN_TOOLS
        .iter()
        .filter(|t| !t.starts_with("delegate"))
        .map(|t| t.to_string())
        .collect();
    assert_eq!(sorted(e.launch(tb)), sorted(want));
    for launch in [e.launch(ta), e.launch(tb)] {
        assert!(
            !launch
                .iter()
                .any(|t| t.starts_with("schedule") || t.starts_with("vault")),
            "{launch:?}"
        );
    }

    let ctx = e.ctx(&e.a, e.alice).await;
    let mut w = e.db().worker().await.unwrap();
    w.set_project_lead(e.alice, e.p, Some(e.b.id))
        .await
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(
        e.tool(
            &ctx,
            "delegate",
            json!({ "to": "Bob-B", "task": "write it" })
        )
        .await,
        (
            true,
            "only the project's lead can delegate; ask instead".to_owned()
        )
    );
}

/// 查队友（O2）：A 只看到项目里专属的 B（是 Bob 的、不是负责人），看不到 alice 私人的、混用的 botin；名字里的控制字符、
/// 括号去掉；bob 撤下 B 以后列表里没有了。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn agents_list_sees_only_the_project() {
    let Some(e) = env(13800017011).await else {
        return;
    };
    let ctx = e.ctx(&e.a, e.alice).await;
    let (error, text) = e.tool(&ctx, "agents_list", json!({})).await;
    assert!(!error, "{text}");
    assert!(
        !text.contains(&e.x.name) && !text.contains(&e.m.name),
        "{text}"
    );
    let list: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        list["agents"],
        json!([{
            "instance_id": e.b.id,
            "name": "Bob-B",
            "agent": "claude",
            "owner": "Bob",
            "lead": false,
            "status": "idle",
        }])
    );
    assert_eq!(list["project"]["name"], "Launch");
    assert_eq!(list["project"]["goal"], "Ship the launch plan");
    assert_eq!(list["project"]["you_are_lead"], true);

    raw_sql(
        e.db(),
        "UPDATE instances SET name = E'Bob\\n「B」（x）' WHERE id = $1",
        &[e.b.id.0],
    )
    .await;
    let list = e.tool_json(&ctx, "agents_list", json!({})).await;
    assert_eq!(list["agents"][0]["name"], "Bob Bx");

    projects::withdraw_agent(e.db(), e.bob, ACTOR, e.p, e.b.id)
        .await
        .unwrap();
    let list = e.tool_json(&ctx, "agents_list", json!({})).await;
    assert_eq!(list["agents"], json!([]));
}

/// 查进度（O3）：只给成员能看的。B 私人时的运行看不到；在等审批的项目运行说成等主人；任务是第一行；没有工具标题、
/// 失败原因、用途。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn agent_status_shows_only_the_member_view() {
    let Some(e) = env(13800017021).await else {
        return;
    };
    let (failed, _) = e.task(&e.b, "an earlier task").await;
    raw_sql(
        e.db(),
        "UPDATE runs SET state = 'failed', error = 'sk-test-err-991', summary = 'earlier summary', \
                started_at = now(), finished_at = now() WHERE id = $1",
        &[failed.0],
    )
    .await;
    let (waiting, _) = e.task(&e.b, "first line of task\nsecond line").await;
    raw_sql(
        e.db(),
        "UPDATE runs SET state = 'waiting_approval', started_at = now() WHERE id = $1",
        &[waiting.0],
    )
    .await;
    let mut w = e.db().worker().await.unwrap();
    for (kind, payload) in [
        (
            "agent.plan",
            json!({ "entries": [{ "content": "collect", "status": "in_progress" }] }),
        ),
        ("agent.tool_call", json!({ "title": "SECRET-TOOL-TITLE" })),
        ("agent.message", json!({ "text": "working on it" })),
    ] {
        w.append_event(e.b.id, Some(waiting), kind, &payload)
            .await
            .unwrap();
    }
    w.commit().await.unwrap();
    raw_sql(
        e.db(),
        "UPDATE instances SET purpose = 'PRIVATE-PURPOSE' WHERE id = $1",
        &[e.b.id.0],
    )
    .await;

    let grant_b = e.state(waiting).await.run_grant_id.unwrap();
    let ctx_b = ToolContext {
        user: e.bob,
        instance: e.b.id,
        run: waiting,
        plan: None,
        grant: grant_b,
        project: Some(e.p),
    };
    let published = e
        .tool_json(
            &ctx_b,
            "artifact_publish",
            json!({ "name": "notes.md", "content": "draft" }),
        )
        .await;
    assert_eq!(published["name"], "notes.md");

    let ctx = e.ctx(&e.a, e.alice).await;
    let (error, text) = e
        .tool(&ctx, "agent_status", json!({ "agent": "Bob-B" }))
        .await;
    assert!(!error, "{text}");
    for secret in [
        "SECRET-TOOL-TITLE",
        "sk-test-err",
        "bob private diary",
        "bob-private-note",
        "PRIVATE-PURPOSE",
        "second line",
    ] {
        assert!(!text.contains(secret), "{secret}: {text}");
    }
    let s: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(s["owner"], "Bob");
    assert_eq!(s["status"], "busy");
    assert_eq!(s["current"]["run_id"], json!(waiting));
    assert_eq!(s["current"]["state"], "waiting_owner");
    assert_eq!(s["current"]["task"], "first line of task");
    assert_eq!(
        s["current"]["todo"],
        json!([{ "content": "collect", "status": "in_progress" }])
    );
    assert_eq!(s["current"]["last_said"], "working on it");
    assert_eq!(s["current"]["artifacts"], json!(["notes.md"]));
    assert_eq!(s["last_finished"]["run_id"], json!(failed));
    assert_eq!(s["last_finished"]["state"], "failed");
    assert_eq!(s["last_finished"]["summary"], "earlier summary");
    // 不在项目里的：和查不到一样。
    let (error, text) = e
        .tool(&ctx, "agent_status", json!({ "agent": "Diary" }))
        .await;
    assert!(error && text.starts_with("no agent called \"Diary\" in this project"));
}

/// 项目看板（O4）：A 写的进项目看板，不进 alice 的私人看板；正文和 alice 保险箱里的值一样也原样写（不抹值，免得成员
/// 从抹掉的位置猜出密码）；B 读得到，作者是“Alice-A (Alice's botin)”；bob 撤下 B 以后它的工具一律停下。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn board_tools_use_the_project_board() {
    let Some(e) = env(13800017031).await else {
        return;
    };
    let vault = orchestrator::artifacts::user_vault(e.db(), kms(), e.alice, true)
        .await
        .unwrap();
    let id = proto::domain::VaultItemId::new();
    let sealed = vault
        .seal_vault(
            &e.alice.to_string(),
            &id.to_string(),
            &keyvault::VaultSecret {
                username: "octocat".into(),
                password: "hunter2-secret-value".into(),
            },
        )
        .await
        .unwrap();
    let mut tx = e.db().tenant(e.alice).await.unwrap();
    tx.create_vault_item(&store::NewVaultItem {
        id,
        name: "github".into(),
        purpose: "push code".into(),
        sealed,
        has_username: true,
        instance_ids: vec![e.x.id],
    })
    .await
    .unwrap();
    tx.commit().await.unwrap();

    let ctx_a = e.ctx(&e.a, e.alice).await;
    let body = "the code is hunter2-secret-value";
    let posted = e
        .tool_json(
            &ctx_a,
            "board_post",
            json!({ "body": body, "tags": ["launch"] }),
        )
        .await;
    assert_eq!(posted["status"], "posted");
    let rows: Vec<(String, uuid::Uuid)> =
        sqlx::query_as("SELECT body, project_id FROM project_board_posts WHERE run_id = $1")
            .bind(ctx_a.run.0)
            .fetch_all(e.db().pool())
            .await
            .unwrap();
    assert_eq!(rows, vec![(body.to_owned(), e.p.0)]);
    let private: i64 = sqlx::query_scalar("SELECT count(*) FROM board_posts WHERE user_id = $1")
        .bind(e.alice.0)
        .fetch_one(e.db().pool())
        .await
        .unwrap();
    assert_eq!(private, 0);

    let ctx_b = e.ctx(&e.b, e.bob).await;
    let read = e.tool_json(&ctx_b, "board_read", json!({})).await;
    assert_eq!(read["posts"].as_array().unwrap().len(), 1, "{read}");
    assert_eq!(read["posts"][0]["body"], body);
    assert_eq!(read["posts"][0]["author"], "Alice-A (Alice's botin)");
    assert_eq!(read["posts"][0]["tags"], json!(["launch"]));
    assert!(read["note"].as_str().unwrap().contains("project members"));

    projects::withdraw_agent(e.db(), e.bob, ACTOR, e.p, e.b.id)
        .await
        .unwrap();
    for (name, args) in [
        ("board_read", json!({})),
        ("board_post", json!({ "body": "late" })),
        ("ask", json!({ "to": "Alice-A", "question": "late?" })),
        ("agents_list", json!({})),
        ("agent_status", json!({ "agent": "Alice-A" })),
        ("delegate_list", json!({})),
        ("delegate", json!({ "to": "Alice-A", "task": "late" })),
        ("artifact_list", json!({})),
        (
            "artifact_publish",
            json!({ "name": "late.md", "content": "late" }),
        ),
    ] {
        assert_eq!(
            e.tool(&ctx_b, name, args).await,
            (true, STOP_HERE.to_owned()),
            "{name}"
        );
    }
}

/// 跨主人提问（O5）：A 问 B；B 收到的说明用 bob 的语言、说是 Alice 的 botin，库里存的是原文；B 用 bob 自己的常设授权
/// 回答；A 接着跑时拿到回答，注明是别的 agent 写的。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ask_across_owners_end_to_end() {
    let Some(e) = env(13800017041).await else {
        return;
    };
    let (ta, _) = e
        .task(
            &e.a,
            r#"call ask {"to":"Bob-B","question":"say the budget is 42"}"#,
        )
        .await;
    assert_eq!(e.run_next().await, ta);
    let call = &e.calls(ta)[0];
    assert!(call.name == "ask" && !call.error, "{call:?}");
    assert!(call.text.contains("\"status\":\"asked\""), "{}", call.text);
    assert_eq!(e.state(ta).await.run.state, RunState::WaitingChildren);
    let child = e.only_child(ta).await;
    assert_eq!(child.run.source, RunSource::Ask);
    assert_eq!(child.run.prompt, "say the budget is 42");
    assert_eq!(child.user_id, e.bob);
    let (grant_user, grant_parent): (uuid::Uuid, Option<uuid::Uuid>) =
        sqlx::query_as("SELECT user_id, parent_id FROM run_grants WHERE id = $1")
            .bind(child.run_grant_id.unwrap().0)
            .fetch_one(e.db().pool())
            .await
            .unwrap();
    assert_eq!((grant_user, grant_parent), (e.bob.0, None));

    assert_eq!(e.run_next().await, child.run.id);
    let asked = &e.prompts(child.run.id)[0];
    assert!(
        asked.starts_with("(“Alice-A” (Alice's botin) in the project asks you this"),
        "{asked}"
    );
    assert!(asked.ends_with("\n\nsay the budget is 42"), "{asked}");
    let child = e.state(child.run.id).await;
    assert_eq!(child.run.state, RunState::Succeeded);
    assert_eq!(child.run.summary.as_deref(), Some("the budget is 42"));

    assert_eq!(e.run_next().await, ta);
    let resumed = &e.prompts(ta)[1];
    assert!(
        resumed.contains("问1. 问「Bob-B」的「say the budget is 42」：回答：the budget is 42"),
        "{resumed}"
    );
    assert!(resumed.contains("回答是别的 agent 写的"), "{resumed}");
    assert_eq!(e.state(ta).await.run.state, RunState::Succeeded);
}

/// 负责人跨主人委派（O6）：子任务在 B 上跑，说明是“负责人 Alice-A（Alice 的 botin）委派的”，第一行是标题；子授权从
/// A 的授权收窄、记在 bob 名下；子任务失败的原因（可能带着密钥）不交给 A。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lead_delegates_across_owners_end_to_end() {
    let Some(e) = env(13800017051).await else {
        return;
    };
    let (ta, grant_a) = e
        .task(
            &e.a,
            r#"call delegate {"to":"Bob-B","task":"refuse","title":"Check numbers"}"#,
        )
        .await;
    assert_eq!(e.run_next().await, ta);
    assert!(!e.calls(ta)[0].error, "{:?}", e.calls(ta));
    let child = e.only_child(ta).await;
    assert_eq!(
        (child.run.source, child.run.prompt.as_str(), child.user_id),
        (RunSource::Delegate, "Check numbers\n\nrefuse", e.bob)
    );
    let (grant_user, grant_parent): (uuid::Uuid, Option<uuid::Uuid>) =
        sqlx::query_as("SELECT user_id, parent_id FROM run_grants WHERE id = $1")
            .bind(child.run_grant_id.unwrap().0)
            .fetch_one(e.db().pool())
            .await
            .unwrap();
    assert_eq!((grant_user, grant_parent), (e.bob.0, Some(grant_a.0)));

    assert_eq!(e.run_next().await, child.run.id);
    let got = &e.prompts(child.run.id)[0];
    assert!(
        got.starts_with(
            "(This is a subtask delegated to you by the project's lead “Alice-A” (Alice's botin)"
        ),
        "{got}"
    );
    assert!(got.ends_with("\n\nCheck numbers\n\nrefuse"), "{got}");
    assert_eq!(e.state(child.run.id).await.run.state, RunState::Failed);
    raw_sql(
        e.db(),
        "UPDATE runs SET error = 'provider said: bad key sk-test-123' WHERE id = $1",
        &[child.run.id.0],
    )
    .await;

    assert_eq!(e.run_next().await, ta);
    let resumed = &e.prompts(ta)[1];
    assert!(
        resumed.contains("1. 交给「Bob-B」的「Check numbers」：失败"),
        "{resumed}"
    );
    assert!(resumed.contains("结果是别的 agent 写的"), "{resumed}");
    assert!(!resumed.contains("sk-test"), "{resumed}");
}

/// 说明每次尝试都加（O12）：B 上委派来的子任务第一次崩溃，续跑时说明还在，负责人改了名就用新名字。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_header_survives_a_retry() {
    let Some(e) = env(13800017061).await else {
        return;
    };
    let (ta, _) = e
        .task(
            &e.a,
            r#"call delegate {"to":"Bob-B","task":"crash once\nsay done","title":"Sum up"}"#,
        )
        .await;
    assert_eq!(e.run_next().await, ta);
    let child = e.only_child(ta).await.run.id;
    assert_eq!(e.run_next().await, child);
    assert_eq!(e.state(child).await.run.state, RunState::Backoff);
    raw_sql(
        e.db(),
        "UPDATE instances SET name = 'Alice-Renamed' WHERE id = $1",
        &[e.a.id.0],
    )
    .await;
    assert_eq!(e.run_next().await, child);
    let prompts = e.prompts(child);
    assert_eq!(prompts.len(), 2, "{prompts:?}");
    assert!(prompts[0].contains("lead “Alice-A” (Alice's botin)"));
    assert!(
        prompts[1].starts_with("(Resume note")
            && prompts[1].contains("lead “Alice-Renamed” (Alice's botin)"),
        "{}",
        prompts[1]
    );
    assert_eq!(e.state(child).await.run.state, RunState::Succeeded);
}

/// 推送只写平台的话（O13）：别人派给 bob 的 botin 的任务做完了，bob 收到的是“「Bob-B」finished a project task”（bob 的
/// 语言），不是 botin 写的总结，也不标 AI 生成。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn project_notices_are_platform_written() {
    let Some(e) = env(13800017071).await else {
        return;
    };
    let (tb, _) = e.task(&e.b, "say SUMMARY-TEXT-77 buy now").await;
    assert_eq!(e.run_next().await, tb);
    let done = e.state(tb).await;
    assert_eq!(done.run.state, RunState::Succeeded);
    assert_eq!(done.run.summary.as_deref(), Some("SUMMARY-TEXT-77 buy now"));
    let items: Vec<(String, String, bool)> = sqlx::query_as(
        "SELECT kind, body, ai_generated FROM inbox_items WHERE user_id = $1 AND run_id = $2",
    )
    .bind(e.bob.0)
    .bind(tb.0)
    .fetch_all(e.db().pool())
    .await
    .unwrap();
    assert_eq!(
        items,
        vec![(
            "run_finished".to_owned(),
            "“Bob-B” finished a project task".to_owned(),
            false
        )]
    );
    let pushes: Vec<Value> = sqlx::query_scalar("SELECT payload FROM outbox WHERE user_id = $1")
        .bind(e.bob.0)
        .fetch_all(e.db().pool())
        .await
        .unwrap();
    let text = serde_json::to_string(&pushes).unwrap();
    assert!(
        text.contains("finished a project task") && !text.contains("SUMMARY-TEXT-77"),
        "{text}"
    );
    // 失败的也只写平台的话（不放失败原因）。
    let (failed, _) = e.task(&e.b, "say FAILED-TEXT-88\nrefuse").await;
    assert_eq!(e.run_next().await, failed);
    assert_eq!(e.state(failed).await.run.state, RunState::Failed);
    let items: Vec<(String, String, bool)> = sqlx::query_as(
        "SELECT kind, body, ai_generated FROM inbox_items WHERE user_id = $1 AND run_id = $2",
    )
    .bind(e.bob.0)
    .bind(failed.0)
    .fetch_all(e.db().pool())
    .await
    .unwrap();
    assert_eq!(
        items,
        vec![(
            "run_failed".to_owned(),
            "“Bob-B” did not finish a project task".to_owned(),
            false
        )]
    );
}

/// 没人要了的子任务（O14）：负责人的运行结束了（比如在私人那边被取消），它委派给 B 的子任务由执行器的定时清理取消，
/// 记一条状态事件。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn orphans_are_swept_by_the_executor() {
    let Some(e) = env(13800017081).await else {
        return;
    };
    let (ta, _) = e
        .task(
            &e.a,
            r#"call delegate {"to":"Bob-B","task":"say ok","title":"Later"}"#,
        )
        .await;
    assert_eq!(e.run_next().await, ta);
    let child = e.only_child(ta).await.run.id;
    raw_sql(
        e.db(),
        "UPDATE runs SET state = 'cancelled', finished_at = now() WHERE id = $1",
        &[ta.0],
    )
    .await;
    assert_eq!(e.exec.sweep_project_runs().await.unwrap(), 1);
    let rec = e.state(child).await;
    assert_eq!(rec.run.state, RunState::Cancelled);
    assert_eq!(
        rec.run.state_reason.as_deref(),
        Some("the task it was working for ended")
    );
    let events: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM events WHERE run_id = $1 AND kind = 'run.state' \
            AND payload->>'state' = 'cancelled'",
    )
    .bind(child.0)
    .fetch_one(e.db().pool())
    .await
    .unwrap();
    assert_eq!(events, 1);
    assert_eq!(e.exec.sweep_project_runs().await.unwrap(), 0);
}

/// 全部停止以后（用户的决定 1）：bob 按了全部停止，A 照样能问 B，但问题等 bob 确认；bob 收件箱里有一条等确认的提醒，
/// 指着这个问题。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stopped_owner_is_asked_first() {
    let Some(e) = env(13800017091).await else {
        return;
    };
    let ctx = e.ctx(&e.a, e.alice).await;
    orchestrator::account::stop_all(e.db(), e.bob, ACTOR)
        .await
        .unwrap();
    let asked = e
        .tool_json(&ctx, "ask", json!({ "to": "Bob-B", "question": "say hi" }))
        .await;
    assert_eq!(asked["status"], "waiting_owner");
    assert_eq!(asked["owner"], "Bob");
    let child = e.only_child(ctx.run).await;
    assert_eq!(child.run.state, RunState::Queued);
    assert_eq!(
        child.run.wait_code.as_deref(),
        Some(store::OWNER_CONFIRM_WAIT)
    );
    let items: Vec<(String, String, Option<uuid::Uuid>, Option<uuid::Uuid>)> = sqlx::query_as(
        "SELECT subtype, title, run_id, project_id FROM inbox_items WHERE user_id = $1 AND subtype = $2",
    )
    .bind(e.bob.0)
    .bind(store::OWNER_CONFIRM_WAIT)
    .fetch_all(e.db().pool())
    .await
    .unwrap();
    assert_eq!(
        items,
        vec![(
            store::OWNER_CONFIRM_WAIT.to_owned(),
            "Confirm a project task".to_owned(),
            Some(child.run.id.0),
            Some(e.p.0)
        )]
    );
    // 一个不在项目里的名字：和查不到一样。
    let (error, text) = e
        .tool(&ctx, "ask", json!({ "to": "Diary", "question": "hi" }))
        .await;
    assert!(error && text.starts_with("no agent called \"Diary\" in this project"));

    // 负责人委派的也等确认；每个等着的任务一条提醒（C6 评审）。
    let delegated = e
        .tool_json(
            &ctx,
            "delegate",
            json!({ "to": "Bob-B", "task": "say done", "title": "Sum up" }),
        )
        .await;
    assert_eq!(delegated["status"], "waiting_owner");
    let held: RunId = delegated["run_id"].as_str().unwrap().parse().unwrap();
    assert_eq!(
        e.state(held).await.run.wait_code.as_deref(),
        Some(store::OWNER_CONFIRM_WAIT)
    );
    // 能领的只有 A 上排着的那个（直接调工具用的），等确认的领不到。
    let claimed = e.exec.claim().await.unwrap().map(|r| r.run.id);
    assert_eq!(claimed, Some(ctx.run));
    assert!(
        e.exec.claim().await.unwrap().is_none(),
        "held tasks are not claimed"
    );
    let unread = || async {
        let ids: Vec<uuid::Uuid> = sqlx::query_scalar(
            "SELECT run_id FROM inbox_items WHERE user_id = $1 AND subtype = $2 AND read_at IS NULL \
              ORDER BY created_at, id",
        )
        .bind(e.bob.0)
        .bind(store::OWNER_CONFIRM_WAIT)
        .fetch_all(e.db().pool())
        .await
        .unwrap();
        ids
    };
    assert_eq!(unread().await, vec![child.run.id.0, held.0]);
    // 不做第一个：它的提醒算已读，第二个的还在；做第二个：都读了，子任务能领了。
    orchestrator::project_tasks::confirm_task(e.db(), e.bob, ACTOR, e.p, child.run.id, false)
        .await
        .unwrap();
    assert_eq!(e.state(child.run.id).await.run.state, RunState::Cancelled);
    assert_eq!(unread().await, vec![held.0]);
    orchestrator::project_tasks::confirm_task(e.db(), e.bob, ACTOR, e.p, held, true)
        .await
        .unwrap();
    assert!(unread().await.is_empty());
    assert_eq!(e.run_next().await, held);
    assert_eq!(e.state(held).await.run.state, RunState::Succeeded);
}

/// 别的成员的 botin 发布的产出物（8.17）：负责人列出来时标着 `from_another_member`、带说明；读的时候内容在猜不到的边界
/// 里面。自己的不标。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn artifacts_from_other_members_are_fenced() {
    let Some(e) = env(13800017101).await else {
        return;
    };
    let (ta, grant_a) = e
        .task(
            &e.a,
            r#"call delegate {"to":"Bob-B","task":"call artifact_publish {\"name\":\"notes.md\",\"content\":\"draft by bob\"}","title":"Notes"}"#,
        )
        .await;
    assert_eq!(e.run_next().await, ta);
    let child = e.only_child(ta).await.run.id;
    assert_eq!(e.run_next().await, child);
    assert!(!e.calls(child)[0].error, "{:?}", e.calls(child));
    let ctx = ToolContext {
        user: e.alice,
        instance: e.a.id,
        run: ta,
        plan: None,
        grant: grant_a,
        project: Some(e.p),
    };
    let mine = e
        .tool_json(
            &ctx,
            "artifact_publish",
            json!({ "name": "plan.md", "content": "alice's plan" }),
        )
        .await;
    assert_eq!(mine["name"], "plan.md");
    let list = e.tool_json(&ctx, "artifact_list", json!({})).await;
    let items = list["artifacts"].as_array().unwrap();
    let by_name = |n: &str| items.iter().find(|a| a["name"] == n).unwrap().clone();
    assert_eq!(by_name("notes.md")["from_another_member"], true);
    assert!(by_name("plan.md").get("from_another_member").is_none());
    assert!(
        list["note"]
            .as_str()
            .unwrap()
            .contains("another project member")
    );
    let read = e
        .tool_json(&ctx, "artifact_read", json!({ "name": "notes.md" }))
        .await;
    let content = read["content"].as_str().unwrap();
    let boundary = content
        .strip_prefix("<<<")
        .and_then(|c| c.split_once('\n'))
        .map(|(b, _)| b.to_owned())
        .unwrap();
    assert!(
        boundary.starts_with("ARTIFACT-") && boundary.len() > 20,
        "{content}"
    );
    assert_eq!(
        content,
        format!("<<<{boundary}\ndraft by bob\n{boundary}>>>")
    );
    assert!(read["note"].as_str().unwrap().contains(&boundary));
    let own = e
        .tool_json(&ctx, "artifact_read", json!({ "name": "plan.md" }))
        .await;
    assert_eq!(own["content"], "alice's plan");
}

// ---------- 项目流水线（8.17） ----------

fn pstep(key: &str, instance: &Instance, prompt: &str, deps: &[&str]) -> ProjectPipelineStep {
    ProjectPipelineStep {
        key: key.into(),
        instance_id: instance.id,
        prompt: prompt.into(),
        depends_on: deps.iter().map(|d| d.to_string()).collect(),
    }
}

impl Env {
    async fn pipeline(&self, steps: &[ProjectPipelineStep]) -> RunId {
        orchestrator::project_tasks::start_pipeline(
            self.db(),
            kms(),
            self.alice,
            ACTOR,
            self.p,
            "Launch report",
            "Ship the report",
            steps,
        )
        .await
        .unwrap()
    }

    async fn step_run(&self, root: RunId, key: &str) -> store::RunRecord {
        let mut w = self.db().worker().await.unwrap();
        let children = w.child_runs(root).await.unwrap();
        w.rollback().await.unwrap();
        children
            .into_iter()
            .find(|c| c.run.step_key.as_deref() == Some(key))
            .unwrap_or_else(|| panic!("no step {key}"))
    }
}

/// 跨主人的项目流水线（O8）：根运行挂在 alice 的 A 上；B 那一步记在 bob 名下、用 bob 自己的常设授权；交接说明用 bob 的
/// 语言、上游的结果在边界里、注明是别的 botin 写的；上游的产出物复制进 B 的工作区；做完以后根运行成功。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn project_pipeline_across_owners() {
    let Some(e) = env(13800017111).await else {
        return;
    };
    let driver = PipelineDriver::new(e.db().clone(), PipelineConfig::default());
    let root = e
        .pipeline(&[
            pstep(
                "fetch",
                &e.a,
                "call artifact_publish {\"name\":\"facts.md\",\"content\":\"fact one\"}\nsay facts gathered",
                &[],
            ),
            pstep("write", &e.b, "say report written", &["fetch"]),
        ])
        .await;
    let rec = e.state(root).await;
    assert_eq!((rec.run.instance_id, rec.user_id), (e.a.id, e.alice));
    driver.tick().await.unwrap();
    assert_eq!(e.state(root).await.run.state, RunState::WaitingChildren);
    let fetch = e.step_run(root, "fetch").await;
    assert_eq!(e.run_next().await, fetch.run.id);
    assert_eq!(e.state(fetch.run.id).await.run.state, RunState::Succeeded);
    driver.tick().await.unwrap();
    let write = e.step_run(root, "write").await;
    assert_eq!(write.user_id, e.bob);
    let (grant_user, grant_parent): (uuid::Uuid, Option<uuid::Uuid>) =
        sqlx::query_as("SELECT user_id, parent_id FROM run_grants WHERE id = $1")
            .bind(write.run_grant_id.unwrap().0)
            .fetch_one(e.db().pool())
            .await
            .unwrap();
    assert_eq!((grant_user, grant_parent), (e.bob.0, None));
    let prompt = &write.run.prompt;
    assert!(prompt.starts_with("say report written"), "{prompt}");
    assert!(
        prompt.contains("written by other botins in the project"),
        "{prompt}"
    );
    let open = prompt.find("\n<<<UPSTREAM-").expect("an opening boundary");
    let boundary = &prompt[open + 4..][..prompt[open + 4..].find('\n').unwrap()];
    let close = prompt
        .rfind(&format!("{boundary}>>>"))
        .expect("a closing boundary");
    let fenced = &prompt[open..close];
    assert!(
        fenced.contains("facts gathered") && fenced.contains("handoff/facts.md"),
        "{prompt}"
    );
    assert_eq!(e.run_next().await, write.run.id);
    assert_eq!(e.state(write.run.id).await.run.state, RunState::Succeeded);
    let mut w = e.db().worker().await.unwrap();
    let sandbox = w
        .instance_runtime(e.b.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    w.rollback().await.unwrap();
    use sandbox::SandboxProvider;
    let copied = e
        .provider
        .read_file(
            &sandbox::SandboxId(sandbox),
            "workspace/handoff/facts.md",
            1 << 20,
        )
        .await
        .unwrap();
    assert_eq!(copied, b"fact one");
    driver.tick().await.unwrap();
    let done = e.state(root).await;
    assert_eq!(done.run.state, RunState::Succeeded, "{:?}", done.run);
    assert_eq!(done.run.summary.as_deref(), Some("write：report written"));
}

/// 一步失败（O8b）：根运行只记“第几步失败了”，不抄那一步的失败原因（是 bob 的，可能带着密钥），事件里也没有。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failed_project_step_does_not_leak_its_error() {
    let Some(e) = env(13800017121).await else {
        return;
    };
    let driver = PipelineDriver::new(e.db().clone(), PipelineConfig::default());
    let root = e
        .pipeline(&[
            pstep("fetch", &e.b, "refuse", &[]),
            pstep("write", &e.a, "say never", &["fetch"]),
        ])
        .await;
    driver.tick().await.unwrap();
    let fetch = e.step_run(root, "fetch").await;
    assert_eq!(e.run_next().await, fetch.run.id);
    raw_sql(
        e.db(),
        "UPDATE runs SET error = 'provider said: bad key sk-test-456' WHERE id = $1",
        &[fetch.run.id.0],
    )
    .await;
    driver.tick().await.unwrap();
    let done = e.state(root).await;
    assert_eq!(done.run.state, RunState::Failed);
    assert_eq!(done.run.error.as_deref(), Some("step fetch failed"));
    let leaked: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM events WHERE run_id = $1 AND payload::text LIKE '%sk-test%'",
    )
    .bind(root.0)
    .fetch_one(e.db().pool())
    .await
    .unwrap();
    assert_eq!(leaked, 0);
    let row: String = sqlx::query_scalar("SELECT row_to_json(r)::text FROM runs r WHERE id = $1")
        .bind(root.0)
        .fetch_one(e.db().pool())
        .await
        .unwrap();
    assert!(!row.contains("sk-test"), "{row}");
}

/// 两步之间关了派单开关（O8）：下一步开不了，只有这条流水线失败（平台的说明）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn switching_dispatch_off_fails_the_pipeline() {
    let Some(e) = env(13800017131).await else {
        return;
    };
    let driver = PipelineDriver::new(e.db().clone(), PipelineConfig::default());
    let root = e
        .pipeline(&[
            pstep("fetch", &e.a, "say ok", &[]),
            pstep("write", &e.b, "say never", &["fetch"]),
        ])
        .await;
    driver.tick().await.unwrap();
    let fetch = e.step_run(root, "fetch").await;
    assert_eq!(e.run_next().await, fetch.run.id);
    let mut w = e.db().worker().await.unwrap();
    w.set_project_dispatch(false, "test", None).await.unwrap();
    w.commit().await.unwrap();
    driver.tick().await.unwrap();
    let done = e.state(root).await;
    assert_eq!(done.run.state, RunState::Failed, "{:?}", done.run);
    assert_eq!(
        done.run.error.as_deref(),
        Some("the agent for step write cannot take project work now")
    );
}
