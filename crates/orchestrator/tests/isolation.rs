//! 项目会话和工作区隔离（8.16）的执行器端到端测试：专属实例上的项目运行经执行器领取、执行（shim 替身 + 本地沙箱 +
//! 真实 Postgres）。项目运行只拿到项目的平台工具、不按主人的保险箱抹值、没有项目授权或空间对不上就不启动；产出物工具
//! 在运行结束、空间变了以后不读不写；捎带的消息、续跑简报不出这个空间、这个运行。没有 DATABASE_URL 时跳过。
//!
//! 8.16 里还没有派项目任务的接口（8.17）：项目运行、项目授权都用 worker 角色直接写进库里（库里只有 worker 写得出）。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use orchestrator::artifacts::{ArtifactStore, LocalBlobStore};
use orchestrator::computer::DeviceCalls;
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::projects;
use orchestrator::shim::{
    ConnectError, PlatformTools, ShimConnector, ShimLaunch, ShimProcess, ShimSession, ToolContext,
    ToolOutput,
};
use orchestrator::tools::{ARTIFACT_TOOLS, ArtifactTools, PROJECT_RUN_TOOLS, ToolSet};
use proto::domain::{
    DevicePlatform, GrantId, GrantScope, Instance, InstanceId, ProjectId, RunId, RunSource,
    RunState, UserId,
};
use proto::shim::{PlatformTool, ShimCommand, ShimEvent, StopReason};
use sandbox::local::LocalProvider;
use sandbox::{SandboxId, SandboxProvider};
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{Db, NewRun, SoloAgent};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

const ACTOR: &str = "user:test-device";
const KMS_KEY: [u8; 32] = [9; 32];

fn kms() -> Arc<dyn keyvault::Kms> {
    Arc::new(keyvault::LocalKms::new("kms1", &KMS_KEY))
}

// ---------- shim 替身：按提示词一行行表演 ----------

/// 一次平台工具调用（或要保险箱的值）的结果：调的什么、是不是错误、结果里的每段文字（第二段起是捎带的消息）。
#[derive(Debug, Clone)]
struct Call {
    name: String,
    error: bool,
    texts: Vec<String>,
}

#[derive(Default)]
struct Recorded {
    /// 每次启动交给 shim 的平台工具（名字）。
    launches: Vec<Vec<String>>,
    prompts: Vec<String>,
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
        self.rec.lock().unwrap().launches.push(
            launch
                .platform_tools
                .iter()
                .map(|t| t.name.clone())
                .collect(),
        );
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

/// 提示词的每一行（续跑说明里引用的原提示词也算）：
/// - `call 工具 [JSON 参数]`：调平台工具，等结果；
/// - `reveal 名字`：要保险箱里的值；
/// - `say 文字`：照说；`shout 文字`：说大写的（和提示词里的原文区分开，用来认出续跑简报里的内容）；
/// - `note 标题`：报一个工具调用，标题是大写的；
/// - `crash once`：第一次尝试时说完前面的就崩溃（续跑时不崩）。
///
/// 一轮结束时把说的话、工具结果（`工具: 结果`）一行一行回复出去。
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
        rec.lock().unwrap().prompts.push(text.clone());
        let _ = ev
            .send(ShimEvent::TurnStarted {
                run_id: run_id.clone(),
            })
            .await;
        let retry = text.contains("续跑说明");
        let mut said: Vec<String> = Vec::new();
        for (i, line) in text.lines().enumerate() {
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
                                name: name.into(),
                                error: is_error,
                                texts: content
                                    .iter()
                                    .map(|b| b["text"].as_str().unwrap_or_default().to_owned())
                                    .collect(),
                            };
                        }
                        Some(ShimCommand::Shutdown) | None => return,
                        Some(_) => {}
                    }
                };
                said.push(format!("{name}: {}", call.texts[0]));
                rec.lock().unwrap().calls.push(call);
            } else if let Some(r) = line.strip_prefix("reveal ") {
                let _ = ev
                    .send(ShimEvent::VaultReveal {
                        run_id: run_id.clone(),
                        call_id: format!("v{i}"),
                        refs: vec![r.into()],
                    })
                    .await;
                let call = loop {
                    match cmds.recv().await {
                        Some(ShimCommand::VaultValues { values, error, .. }) => {
                            break Call {
                                name: line.into(),
                                error: error.is_some(),
                                texts: vec![
                                    error.unwrap_or_else(|| format!("{} values", values.0.len())),
                                ],
                            };
                        }
                        Some(ShimCommand::Shutdown) | None => return,
                        Some(_) => {}
                    }
                };
                said.push(format!("{line}: {}", call.texts[0]));
                rec.lock().unwrap().calls.push(call);
            } else if let Some(t) = line.strip_prefix("say ") {
                said.push(t.into());
            } else if let Some(t) = line.strip_prefix("shout ") {
                said.push(t.to_uppercase());
            } else if let Some(t) = line.strip_prefix("note ") {
                let _ = ev
                    .send(ShimEvent::ToolCall {
                        run_id: Some(run_id.clone()),
                        tool_call_id: format!("t{i}"),
                        title: Some(t.to_uppercase()),
                        kind: Some("read".into()),
                        status: Some("completed".into()),
                        raw: Value::Null,
                    })
                    .await;
            } else if line == "crash once" && !retry {
                let _ = ev
                    .send(ShimEvent::MessageChunk {
                        run_id: Some(run_id.clone()),
                        text: said.join("\n"),
                    })
                    .await;
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
                stop_reason: StopReason::EndTurn,
            })
            .await;
    }
}

// ---------- 平台工具 ----------

/// 不是项目工具的平台工具（日程、保险箱、看板、提问、查队友、委派），和项目运行能用的 web_search。替身只回工具名和
/// 在哪个空间里调的（工具上下文里的项目）。
const STUB_TOOLS: [&str; 7] = [
    "web_search",
    "schedule_list",
    "vault_list",
    "board_post",
    "ask",
    "agents_list",
    "delegate",
];

fn space(project: Option<ProjectId>) -> String {
    project.map_or_else(|| "private".to_owned(), |p| format!("project {p}"))
}

struct Stub;

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
    async fn call(&self, ctx: &ToolContext, name: &str, _args: &Value) -> ToolOutput {
        ToolOutput::text(format!("{name} in {}", space(ctx.project)))
    }
}

/// 执行器提供的全部平台工具：产出物、替身的那些、电脑工具。授权里全列上。
fn every_tool() -> Vec<String> {
    ARTIFACT_TOOLS
        .iter()
        .chain(STUB_TOOLS.iter())
        .copied()
        .chain(proto::computer::names())
        .map(String::from)
        .collect()
}

fn sorted(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v
}

// ---------- 环境 ----------

struct Env {
    t: TestDb,
    _dir: tempfile::TempDir,
    provider: Arc<LocalProvider>,
    lifecycle: Arc<Lifecycle>,
    exec: Arc<Executor>,
    artifacts: Arc<ArtifactTools>,
    fake: Fake,
    user: UserId,
    p: ProjectId,
    /// 专属于 p 的 agent（单人项目的负责人）。
    d: Instance,
    /// p 里混用的 agent：照常接私人任务，有私人授权。
    c: Instance,
    /// d 还是私人的时候的授权（标专属时吊销了）。
    d_private_grant: GrantId,
    /// d 在 p 里的项目授权。
    grant: GrantId,
}

/// 用原始连接切到 worker 角色（隔离 1 级，同 `Db::worker`）：库里只有 worker 写得出项目运行、项目授权。
async fn as_worker(db: &Db) -> sqlx::Transaction<'static, sqlx::Postgres> {
    let mut tx = db.pool().begin().await.unwrap();
    sqlx::query(
        "SELECT set_config('role', 'thinktin_worker', true), \
                set_config('thinktin.isolation', '1', true)",
    )
    .execute(&mut *tx)
    .await
    .unwrap();
    tx
}

/// 以 worker 身份执行一句只绑一个 id 的 SQL，返回改了几行。
async fn worker_sql(db: &Db, sql: &'static str, id: uuid::Uuid) -> u64 {
    let mut tx = as_worker(db).await;
    let n = sqlx::query(sql)
        .bind(id)
        .execute(&mut *tx)
        .await
        .unwrap()
        .rows_affected();
    tx.commit().await.unwrap();
    n
}

/// 项目授权（8.17 派单时才会签发）。
async fn project_grant(
    db: &Db,
    user: UserId,
    instance: InstanceId,
    p: ProjectId,
    scope: &GrantScope,
) -> GrantId {
    let id = GrantId::new();
    let mut tx = as_worker(db).await;
    sqlx::query(
        "INSERT INTO run_grants (id, user_id, instance_id, project_id, scope, expires_at) \
         VALUES ($1, $2, $3, $4, $5::jsonb, now() + interval '1 hour')",
    )
    .bind(id.0)
    .bind(user.0)
    .bind(instance.0)
    .bind(p.0)
    .bind(serde_json::to_string(scope).unwrap())
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    id
}

/// alice（`phone`）登录着一台电脑；她的单人项目 p 里两个 agent：d 是负责人，标成专属（换了全新的工作区、私人授权吊销），
/// c 是混用的。d 私人的时候干过一件事（取消了），运行日志还在 d 的事件里。两个 agent 的授权都列了全部平台工具。
async fn env(phone: &str) -> Option<Env> {
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
    let artifacts = Arc::new(ArtifactTools::new(
        t.db.clone(),
        store,
        provider.clone(),
        "workspace",
    ));
    let providers: Vec<Arc<dyn PlatformTools>> = vec![artifacts.clone(), Arc::new(Stub)];
    let fake = Fake::default();
    let calls = Arc::new(DeviceCalls::new(t.db.clone()));
    let listening = calls.clone();
    tokio::spawn(async move { listening.listen(std::future::pending()).await });
    let exec = Arc::new(
        Executor::new(
            t.db.clone(),
            "node-a",
            lifecycle.clone(),
            grants,
            Arc::new(fake.clone()),
            Arc::new(ToolSet::new(providers)),
            ExecutorConfig {
                renew_every: Duration::from_millis(100),
                approval_poll: Duration::from_millis(50),
                stop_timeout: Duration::from_secs(2),
                backoff_base: Duration::ZERO,
                ..ExecutorConfig::default()
            },
        )
        .with_vault(kms())
        .with_computer(calls),
    );
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone(phone).await.unwrap();
    w.create_device(user.id, DevicePlatform::Macos, "MacBook", None)
        .await
        .unwrap();
    w.commit().await.unwrap();
    let user = user.id;
    let d = lifecycle
        .adopt(user, "user:d", "claude", None, "Lead")
        .await
        .unwrap();
    let c = lifecycle
        .adopt(user, "user:d", "claude", None, "Helper")
        .await
        .unwrap();
    let scope = GrantScope {
        platform_tools: every_tool(),
        ..GrantScope::default()
    };
    let ttl = Duration::from_secs(3600);
    let mut tx = t.db.tenant(user).await.unwrap();
    let d_private_grant = tx
        .create_run_grant(d.id, None, &scope, ttl)
        .await
        .unwrap()
        .id;
    tx.create_run_grant(c.id, None, &scope, ttl).await.unwrap();
    let old = tx
        .create_run(&NewRun::new(
            d.id,
            RunSource::User,
            "keep my diary",
            &d.agent_version,
        ))
        .await
        .unwrap();
    tx.cancel_run(old.id, None).await.unwrap();
    let p = tx
        .create_solo_project(
            "Launch",
            "",
            &[
                SoloAgent {
                    instance_id: d.id,
                    is_lead: true,
                    position: 0,
                },
                SoloAgent {
                    instance_id: c.id,
                    is_lead: false,
                    position: 1,
                },
            ],
        )
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut w = t.db.worker().await.unwrap();
    w.append_event(
        d.id,
        Some(old.id),
        "agent.tool_call",
        &json!({ "title": "PRIVATE-TOOL" }),
    )
    .await
    .unwrap();
    w.append_event(
        d.id,
        Some(old.id),
        "agent.message",
        &json!({ "text": "private-diary-7731" }),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    assert!(
        projects::dedicate_agent(&t.db, kms(), user, ACTOR, p, d.id)
            .await
            .unwrap()
    );
    let grant = project_grant(&t.db, user, d.id, p, &scope).await;
    Some(Env {
        t,
        _dir: dir,
        provider,
        lifecycle,
        exec,
        artifacts,
        fake,
        user,
        p,
        d,
        c,
        d_private_grant,
        grant,
    })
}

impl Env {
    /// p 里 `instance` 上排队的一条用户消息（项目运行）。`delay` 秒以后才能领：捎带用的消息设一小时，领不走，只等着被捎带。
    async fn project_run(
        &self,
        instance: &Instance,
        prompt: &str,
        grant: Option<GrantId>,
        delay: f64,
    ) -> RunId {
        let id = RunId::new();
        let mut tx = as_worker(&self.t.db).await;
        let n = sqlx::query(
            "INSERT INTO runs (id, user_id, instance_id, project_id, root_run_id, source, prompt, agent_version, \
                               run_grant_id, not_before) \
             SELECT $1, user_id, id, $2, $1, 'user', $3, agent_version, $4, now() + make_interval(secs => $5) \
               FROM instances WHERE id = $6",
        )
        .bind(id.0)
        .bind(self.p.0)
        .bind(prompt)
        .bind(grant.map(|g| g.0))
        .bind(delay)
        .bind(instance.id.0)
        .execute(&mut *tx)
        .await
        .unwrap()
        .rows_affected();
        assert_eq!(n, 1);
        tx.commit().await.unwrap();
        id
    }

    /// c 上的私人消息（主人自己发的），`delay` 秒以后才能领。
    async fn private_run(&self, prompt: &str, delay: i64) -> RunId {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let mut new = NewRun::new(self.c.id, RunSource::User, prompt, &self.c.agent_version);
        if delay > 0 {
            new.not_before = Some(chrono::Utc::now() + chrono::Duration::seconds(delay));
        }
        let run = tx.create_run(&new).await.unwrap();
        tx.commit().await.unwrap();
        run.id
    }

    /// 在后台执行（执行器的 future 很大，放进任务里，不压在测试线程的栈上），等它结束。
    async fn execute(&self, rec: store::RunRecord) {
        let (_stop, rx) = watch::channel(false);
        let exec = self.exec.clone();
        let h = tokio::spawn(async move { exec.execute(rec, rx).await });
        tokio::time::timeout(Duration::from_secs(20), h)
            .await
            .unwrap()
            .unwrap();
    }

    /// 领一个运行，执行到结束。
    async fn run_to_end(&self) {
        let rec = self.exec.claim().await.unwrap().expect("a run to claim");
        self.execute(rec).await;
    }

    async fn state(&self, run: RunId) -> store::RunRecord {
        let mut w = self.t.db.worker().await.unwrap();
        let r = w.run_record(run).await.unwrap();
        w.rollback().await.unwrap();
        r
    }

    /// 运行日志里这个运行的回复。
    async fn messages(&self, run: RunId) -> Vec<String> {
        let mut w = self.t.db.worker().await.unwrap();
        let events = w
            .recent_run_events(run, &["agent.message"], 50)
            .await
            .unwrap();
        w.rollback().await.unwrap();
        events
            .into_iter()
            .map(|e| e.payload["text"].as_str().unwrap_or_default().to_owned())
            .collect()
    }

    fn launches(&self) -> Vec<Vec<String>> {
        self.fake.rec.lock().unwrap().launches.clone()
    }

    fn calls(&self) -> Vec<Call> {
        self.fake.rec.lock().unwrap().calls.clone()
    }

    async fn grant_last_used(&self, grant: GrantId) -> Option<chrono::DateTime<chrono::Utc>> {
        let mut tx = as_worker(&self.t.db).await;
        let at = sqlx::query_scalar("SELECT last_used_at FROM run_grants WHERE id = $1")
            .bind(grant.0)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        tx.rollback().await.unwrap();
        at
    }

    /// 直接调产出物工具（像 shim 发来的调用那样），返回（是不是错误，文字）。
    async fn artifact_tool(&self, ctx: &ToolContext, name: &str, args: Value) -> (bool, String) {
        let out = self.artifacts.call(ctx, name, &args).await;
        (
            out.is_error,
            out.content[0]["text"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
        )
    }

    async fn artifact_count(&self, run: RunId) -> i64 {
        let mut tx = as_worker(&self.t.db).await;
        let n = sqlx::query_scalar("SELECT count(*) FROM artifacts WHERE run_id = $1")
            .bind(run.0)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        tx.rollback().await.unwrap();
        n
    }
}

// ---------- 用例 ----------

/// 授权里列了全部平台工具（日程、保险箱、看板、提问、查队友、委派、电脑），d 又是项目的负责人（委派工具不会因为
/// “不是负责人”被拿掉）、主人登录着电脑：项目运行启动时只拿到 PROJECT_RUN_TOOLS；shim 硬调别的工具一律
/// “unknown platform tool”，要保险箱的值被拒；工具上下文带着项目。对照：同一个主人、同样的授权，混用实例 c 上的
/// 私人运行照授权拿到它们（拿掉它们的是空间规则，不是授权）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn project_run_gets_only_project_tools() {
    let Some(e) = env("+8613800016301").await else {
        return;
    };
    let refused = [
        "schedule_list",
        "vault_list",
        "board_post",
        "ask",
        "agents_list",
        "delegate",
        "computer_list_dir",
    ];
    let mut script = vec![
        r#"call web_search {"query":"launch plan"}"#.to_owned(),
        "call artifact_list".to_owned(),
    ];
    script.extend(refused.iter().map(|t| format!("call {t}")));
    script.push("reveal github".into());
    let run = e
        .project_run(&e.d, &script.join("\n"), Some(e.grant), 0.0)
        .await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(
        sorted(e.launches()[0].clone()),
        sorted(PROJECT_RUN_TOOLS.map(String::from).to_vec())
    );
    let calls = e.calls();
    assert_eq!(calls.len(), refused.len() + 3, "{calls:?}");
    assert_eq!(
        (
            calls[0].name.as_str(),
            calls[0].error,
            calls[0].texts[0].as_str()
        ),
        (
            "web_search",
            false,
            format!("web_search in project {}", e.p).as_str()
        )
    );
    assert_eq!(calls[1].name, "artifact_list");
    assert!(
        !calls[1].error && calls[1].texts[0].contains("artifacts"),
        "{:?}",
        calls[1]
    );
    for (call, name) in calls[2..].iter().zip(refused) {
        assert_eq!(
            (call.name.as_str(), call.error, call.texts[0].clone()),
            (name, true, format!("unknown platform tool {name}"))
        );
    }
    let reveal = calls.last().unwrap();
    assert_eq!(
        (reveal.name.as_str(), reveal.error, reveal.texts[0].as_str()),
        (
            "reveal github",
            true,
            "this agent is not allowed to use the password vault"
        )
    );

    // 对照：私人运行。c 不是负责人，委派工具本来就没有。
    let run = e
        .private_run(
            "call web_search {\"query\":\"launch plan\"}\ncall schedule_list\nreveal github",
            0,
        )
        .await;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Succeeded);
    let want: Vec<String> = every_tool()
        .into_iter()
        .filter(|t| t != "delegate")
        .collect();
    assert_eq!(sorted(e.launches()[1].clone()), sorted(want));
    let calls: Vec<(String, bool, String)> = e.calls()[refused.len() + 3..]
        .iter()
        .map(|c| (c.name.clone(), c.error, c.texts[0].clone()))
        .collect();
    assert_eq!(
        calls,
        [
            ("web_search".into(), false, "web_search in private".into()),
            (
                "schedule_list".into(),
                false,
                "schedule_list in private".into()
            ),
            (
                "reveal github".into(),
                true,
                "no vault item named github for this agent; ask the user with vault_request".into()
            ),
        ]
    );
}

/// 主人的保险箱里有一个密码（D14）：项目运行不按主人的保险箱抹值（抹掉的位置会让成员猜出主人的密码），agent 说出来的
/// 原样记进运行日志和摘要。对照：同一个主人的私人运行照样抹掉。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn project_run_scrubber_is_empty() {
    let Some(e) = env("+8613800016311").await else {
        return;
    };
    const SECRET: &str = "pin-4821-secret";
    let vault = orchestrator::artifacts::user_vault(&e.t.db, kms(), e.user, true)
        .await
        .unwrap();
    let id = proto::domain::VaultItemId::new();
    let sealed = vault
        .seal_vault(
            &e.user.to_string(),
            &id.to_string(),
            &keyvault::VaultSecret {
                username: "alice".into(),
                password: SECRET.into(),
            },
        )
        .await
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_vault_item(&store::NewVaultItem {
        id,
        name: "bank".into(),
        purpose: "pay invoices".into(),
        sealed,
        has_username: true,
        instance_ids: vec![e.c.id],
    })
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let said = format!("my guess is {SECRET}");

    let run = e
        .project_run(&e.d, &format!("say {said}"), Some(e.grant), 0.0)
        .await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(e.messages(run).await, std::slice::from_ref(&said));
    assert_eq!(rec.run.summary.as_deref(), Some(said.as_str()));

    let run = e.private_run(&format!("say {said}"), 0).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(e.messages(run).await, ["my guess is [vault:bank]"]);
    assert_eq!(rec.run.summary.as_deref(), Some("my guess is [vault:bank]"));
}

/// 项目运行不借私人的授权：d 上还留着一个能用的私人授权（这里把标专属时吊销的那个恢复了，模拟漏吊销的），没带项目授权的
/// 项目运行也在启动 agent 之前失败，私人授权没被用过。对照：带上项目授权的照常跑。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn project_run_without_grant_fails() {
    let Some(e) = env("+8613800016321").await else {
        return;
    };
    assert_eq!(
        worker_sql(
            &e.t.db,
            "UPDATE run_grants SET revoked_at = NULL, revoke_reason = NULL WHERE id = $1",
            e.d_private_grant.0,
        )
        .await,
        1
    );
    let run = e.project_run(&e.d, "say hello", None, 0.0).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed, "{:?}", rec.run);
    assert!(
        rec.run
            .error
            .as_deref()
            .is_some_and(|m| m.contains("a project run needs its project grant")),
        "{:?}",
        rec.run.error
    );
    assert!(e.launches().is_empty(), "never launched");
    assert_eq!(e.grant_last_used(e.d_private_grant).await, None);

    let run = e.project_run(&e.d, "say hello", Some(e.grant), 0.0).await;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Succeeded);
    assert_eq!(e.launches().len(), 1);
    assert_eq!(e.grant_last_used(e.d_private_grant).await, None);
    assert!(e.grant_last_used(e.grant).await.is_some());
}

/// 项目运行领取以后、启动之前实例的空间变了：d 被改回混用（workspace_project_id 为空）。库里的规则不让实例在有没结束的
/// 运行时换成另一个项目（instances_dedicated_alone），走正常接口也撤不下、放不回私人，所以领取之后用 worker 直接改这一列
/// 来模拟（领取的查询和栅栏只能这样绕过）。执行器在换沙箱令牌、启动 agent 之前失败。对照：空间对得上的照常跑。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn space_mismatch_is_refused() {
    let Some(e) = env("+8613800016331").await else {
        return;
    };
    let first = e.project_run(&e.d, "say first", Some(e.grant), 0.0).await;
    e.run_to_end().await;
    assert_eq!(e.state(first).await.run.state, RunState::Succeeded);
    assert_eq!(e.launches().len(), 1);
    let used = e.grant_last_used(e.grant).await;
    assert!(used.is_some());

    let run = e.project_run(&e.d, "say second", Some(e.grant), 0.0).await;
    let rec = e.exec.claim().await.unwrap().expect("the project run");
    assert_eq!(rec.run.id, run);
    assert_eq!(
        worker_sql(
            &e.t.db,
            "UPDATE instances SET workspace_project_id = NULL WHERE id = $1",
            e.d.id.0,
        )
        .await,
        1
    );
    e.execute(rec).await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed, "{:?}", rec.run);
    assert!(
        rec.run
            .error
            .as_deref()
            .is_some_and(|m| m.contains("the instance is not isolated for this run's space")),
        "{:?}",
        rec.run.error
    );
    assert_eq!(e.launches().len(), 1, "never launched");
    assert_eq!(e.fake.rec.lock().unwrap().prompts.len(), 1);
    assert_eq!(e.grant_last_used(e.grant).await, used, "no sandbox token");
}

/// 产出物工具（评审第 5 条）：运行还在、空间对得上时读写这个空间的工作区；运行已经结束（被取消了、执行器还没发现），
/// 或者调用的空间和实例现在的空间对不上时，publish、fetch 都不读不写。最后走一遍真实的顺序：撤下 d、放回私人、
/// 唤醒出新的私人沙箱，旧运行迟到的调用读不到私人工作区里的文件，也写不进去。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn artifact_tools_refuse_ended_runs_and_changed_spaces() {
    let Some(e) = env("+8613800016341").await else {
        return;
    };
    const REFUSED: &str = "this run is over or the agent's workspace changed; stop here";
    let run = e.project_run(&e.d, "draft", Some(e.grant), 3600.0).await;
    let rt = e.lifecycle.ensure_running(e.d.id).await.unwrap();
    let sandbox = SandboxId(rt.sandbox_id.clone().unwrap());
    e.provider
        .write_file(&sandbox, "workspace/notes.txt", b"project notes")
        .await
        .unwrap();
    let ctx = ToolContext {
        user: e.user,
        instance: e.d.id,
        run,
        plan: None,
        grant: e.grant,
        project: Some(e.p),
    };
    let publish = json!({ "name": "brief.md", "content": "# brief" });
    let from_file = json!({ "name": "notes.txt", "path": "notes.txt" });
    let fetch = json!({ "name": "brief.md", "path": "handoff/brief.md" });
    for (name, args) in [
        ("artifact_publish", &publish),
        ("artifact_publish", &from_file),
        ("artifact_fetch", &fetch),
    ] {
        let (error, text) = e.artifact_tool(&ctx, name, args.clone()).await;
        assert!(!error, "{name}: {text}");
    }
    assert_eq!(e.artifact_count(run).await, 2);
    assert_eq!(
        e.provider
            .read_file(&sandbox, "workspace/handoff/brief.md", 1 << 20)
            .await
            .unwrap(),
        b"# brief"
    );

    // 调用的空间和实例现在的空间对不上（私人的、别的项目的）。
    for project in [None, Some(ProjectId::new())] {
        let other = ToolContext { project, ..ctx };
        for (name, args) in [
            ("artifact_publish", &publish),
            ("artifact_publish", &from_file),
            (
                "artifact_fetch",
                &json!({ "name": "brief.md", "path": "handoff/again.md" }),
            ),
            ("artifact_list", &json!({})),
        ] {
            assert_eq!(
                e.artifact_tool(&other, name, args.clone()).await,
                (true, REFUSED.to_owned()),
                "{name} in {project:?}"
            );
        }
    }
    assert_eq!(e.artifact_count(run).await, 2);
    assert!(
        e.provider
            .read_file(&sandbox, "workspace/handoff/again.md", 1 << 20)
            .await
            .is_err()
    );

    // 运行已经结束，空间还对得上。
    assert_eq!(
        worker_sql(
            &e.t.db,
            "UPDATE runs SET state = 'cancelled', state_reason = 'withdrawn', finished_at = now() \
             WHERE id = $1",
            run.0,
        )
        .await,
        1
    );
    for (name, args) in [
        ("artifact_publish", &publish),
        (
            "artifact_fetch",
            &json!({ "name": "brief.md", "path": "handoff/late.md" }),
        ),
    ] {
        assert_eq!(
            e.artifact_tool(&ctx, name, args.clone()).await,
            (true, REFUSED.to_owned()),
            "{name} after the run ended"
        );
    }
    assert_eq!(e.artifact_count(run).await, 2);
    assert!(
        e.provider
            .read_file(&sandbox, "workspace/handoff/late.md", 1 << 20)
            .await
            .is_err()
    );

    // 撤下、放回私人、新的私人沙箱里有主人的文件：旧运行迟到的调用读不到、写不进。
    projects::withdraw_agent(&e.t.db, e.user, ACTOR, e.p, e.d.id)
        .await
        .unwrap();
    projects::release_instance(&e.t.db, e.user, ACTOR, e.d.id)
        .await
        .unwrap();
    let rt = e.lifecycle.ensure_running(e.d.id).await.unwrap();
    assert_eq!(rt.workspace_project_id, None);
    let private = SandboxId(rt.sandbox_id.clone().unwrap());
    assert_ne!(private, sandbox);
    e.provider
        .write_file(&private, "workspace/notes.txt", b"private diary")
        .await
        .unwrap();
    for (name, args) in [("artifact_publish", &from_file), ("artifact_fetch", &fetch)] {
        assert_eq!(
            e.artifact_tool(&ctx, name, args.clone()).await,
            (true, REFUSED.to_owned()),
            "{name} after release"
        );
    }
    assert_eq!(e.artifact_count(run).await, 2);
    assert!(
        e.provider
            .read_file(&private, "workspace/handoff/brief.md", 1 << 20)
            .await
            .is_err()
    );
}

/// 捎带消息（8.12）只捎带同一个空间的：d 上的项目运行调工具时看到 d 上排队的项目消息；混用实例 c 上的私人运行看到
/// 主人排队的私人消息，看不到同一个实例上排队的项目消息（它留着没被标成看过）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn piggyback_stays_in_space() {
    let Some(e) = env("+8613800016351").await else {
        return;
    };
    let busy = e
        .project_run(&e.d, "call artifact_list", Some(e.grant), 0.0)
        .await;
    let project_message = e
        .project_run(&e.d, "please also check the budget", None, 3600.0)
        .await;
    e.run_to_end().await;
    assert_eq!(e.state(busy).await.run.state, RunState::Succeeded);
    let calls = e.calls();
    assert_eq!(calls[0].name, "artifact_list");
    assert!(!calls[0].error, "{:?}", calls[0]);
    assert_eq!(calls[0].texts.len(), 2, "{:?}", calls[0]);
    assert!(
        calls[0].texts[1].contains("please also check the budget"),
        "{:?}",
        calls[0].texts
    );
    assert!(e.state(project_message).await.announced_at.is_some());

    let busy = e.private_run("call artifact_list", 0).await;
    let private_message = e.private_run("buy a birthday present", 3600).await;
    let foreign = e
        .project_run(&e.c, "project chore on the mixed agent", None, 3600.0)
        .await;
    e.run_to_end().await;
    assert_eq!(e.state(busy).await.run.state, RunState::Succeeded);
    let calls = e.calls();
    assert_eq!(calls[1].name, "artifact_list");
    assert_eq!(calls[1].texts.len(), 2, "{:?}", calls[1]);
    assert!(
        calls[1].texts[1].contains("buy a birthday present")
            && !calls[1].texts[1].contains("project chore"),
        "{:?}",
        calls[1].texts
    );
    assert!(e.state(private_message).await.announced_at.is_some());
    assert_eq!(e.state(foreign).await.announced_at, None);
}

/// 续跑简报（7.12）只读这个运行的日志：d 的事件里还有它私人时干的活、p 里另一个运行的记录，项目运行第一次尝试崩溃后
/// 续跑，简报里只有它自己上次的工具调用和回复。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resume_brief_reads_only_its_run() {
    let Some(e) = env("+8613800016361").await else {
        return;
    };
    let other = e.project_run(&e.d, "other", Some(e.grant), 0.0).await;
    assert_eq!(
        worker_sql(
            &e.t.db,
            "UPDATE runs SET state = 'succeeded', finished_at = now() WHERE id = $1",
            other.0,
        )
        .await,
        1
    );
    let mut w = e.t.db.worker().await.unwrap();
    w.append_event(
        e.d.id,
        Some(other),
        "agent.tool_call",
        &json!({ "title": "OTHER-TOOL" }),
    )
    .await
    .unwrap();
    w.append_event(
        e.d.id,
        Some(other),
        "agent.message",
        &json!({ "text": "other-run-note" }),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();

    let run = e
        .project_run(
            &e.d,
            "note progress tool\nshout progress-on-launch\ncrash once",
            Some(e.grant),
            0.0,
        )
        .await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Backoff, "{:?}", rec.run);
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.attempt, 2);
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 2);
    let brief = &prompts[1];
    // 上次的工具调用和回复（大写的，提示词原文里没有）。
    assert!(
        brief.contains("续跑说明")
            && brief.contains("PROGRESS TOOL")
            && brief.contains("PROGRESS-ON-LAUNCH"),
        "{brief}"
    );
    for foreign in [
        "PRIVATE-TOOL",
        "private-diary-7731",
        "OTHER-TOOL",
        "other-run-note",
    ] {
        assert!(!brief.contains(foreign), "{foreign} in {brief}");
    }
}
