//! 端到端：执行器在本地沙箱里启动真实的 agent-shim，驱动假 ACP agent（agent-shim 的测试替身）。
//! 覆盖对话、审批、取消、平台工具、会话随工作区卷保留。需要 DATABASE_URL（没有时跳过）。
//!
//! 两个二进制属于 agent-shim 包，这里先用 cargo 构建出来（也可以用 THINKTIN_SHIM_BIN、
//! THINKTIN_FAKE_AGENT_BIN 指定）。

use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use async_trait::async_trait;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use orchestrator::exec::{ExecConfig, ExecConnector};
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::shim::{PlatformTools, ToolContext, ToolOutput};
use proto::domain::{DeviceId, GrantScope, Instance, RunId, RunSource, RunState, UserId};
use proto::shim::PlatformTool;
use sandbox::local::LocalProvider;
use serde_json::{Value, json};
use store::NewRun;
use store::testing::TestDb;
use tokio::sync::watch;
use tokio::task::JoinHandle;

fn binaries() -> &'static (PathBuf, PathBuf) {
    static BINS: OnceLock<(PathBuf, PathBuf)> = OnceLock::new();
    BINS.get_or_init(|| {
        if let (Ok(shim), Ok(agent)) = (
            std::env::var("THINKTIN_SHIM_BIN"),
            std::env::var("THINKTIN_FAKE_AGENT_BIN"),
        ) {
            return (shim.into(), agent.into());
        }
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let status = std::process::Command::new(env!("CARGO"))
            .args(["build", "-q", "-p", "agent-shim", "--bins"])
            .current_dir(&root)
            .status()
            .expect("run cargo build");
        assert!(status.success(), "building agent-shim failed");
        let target = std::env::var("CARGO_TARGET_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| root.join("target"));
        let dir = target.join("debug").canonicalize().unwrap();
        (dir.join("agent-shim"), dir.join("fake-acp-agent"))
    })
}

fn write_manifest(dir: &Path, agent: &Path) -> PathBuf {
    let path = dir.join("fake.toml");
    std::fs::write(
        &path,
        format!(
            r#"
            [agent]
            id = "fake"
            name = "Fake"
            upstream = "https://example.com/fake"
            version = "0.0.1"
            license = "MIT"
            sites = ["cn"]

            [runtime]
            template = "agents/fake:0.0.1"
            vcpu = 1
            memory_mb = 256
            state_dirs = [".fake-agent"]

            [[harness]]
            id = "acp"
            kind = "acp"
            command = ["{}"]
            env = {{ FAKE_ACP_CAPS = "load" }}
            session = {{ restore = true, per_session_mcp = true }}

            [llm]
            protocols = ["openai-completions"]
            config = "pi"
            "#,
            agent.display()
        ),
    )
    .unwrap();
    path
}

struct Tools;

#[async_trait]
impl PlatformTools for Tools {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![PlatformTool {
            name: "schedule_list".into(),
            description: "List the user's schedules".into(),
            input_schema: json!({ "type": "object", "properties": { "limit": { "type": "integer" } } }),
        }]
    }
    async fn call(&self, ctx: &ToolContext, name: &str, args: &Value) -> ToolOutput {
        ToolOutput::text(format!("{name}({args}) for run {}", ctx.run))
    }
}

struct Env {
    t: TestDb,
    _dir: tempfile::TempDir,
    lifecycle: Arc<Lifecycle>,
    exec: Arc<Executor>,
    user: UserId,
    instance: Instance,
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let (shim, agent) = binaries();
    let dir = tempfile::tempdir().unwrap();
    let manifest = write_manifest(dir.path(), agent);
    let provider = Arc::new(LocalProvider::new(dir.path().join("sandboxes-root")).unwrap());
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
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let instance = lifecycle
        .adopt(user.id, "user:d", "claude", Some("acp"), "Claude")
        .await
        .unwrap();
    let mut tx = t.db.tenant(user.id).await.unwrap();
    tx.create_run_grant(
        instance.id,
        None,
        &GrantScope {
            platform_tools: vec!["schedule_list".into()],
            ..GrantScope::default()
        },
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let connector = ExecConnector::new(
        provider,
        ExecConfig {
            shim_path: shim.display().to_string(),
            gateway_url: "http://127.0.0.1:9".into(),
            manifest_override: Some(manifest.display().to_string()),
            handshake_timeout: Duration::from_secs(30),
            ..ExecConfig::default()
        },
    );
    let exec = Arc::new(Executor::new(
        t.db.clone(),
        "node-a",
        lifecycle.clone(),
        grants,
        Arc::new(connector),
        Arc::new(Tools),
        ExecutorConfig {
            renew_every: Duration::from_millis(100),
            approval_poll: Duration::from_millis(50),
            stop_timeout: Duration::from_secs(5),
            handshake_timeout: Duration::from_secs(30),
            ..ExecutorConfig::default()
        },
    ));
    Some(Env {
        t,
        _dir: dir,
        lifecycle,
        exec,
        user: user.id,
        instance,
    })
}

impl Env {
    async fn queue(&self, prompt: &str) -> RunId {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let run = tx
            .create_run(&NewRun::new(
                self.instance.id,
                RunSource::User,
                prompt,
                &self.instance.agent_version,
            ))
            .await
            .unwrap();
        tx.commit().await.unwrap();
        run.id
    }

    async fn spawn(&self) -> JoinHandle<()> {
        let rec = self.exec.claim().await.unwrap().expect("a run to claim");
        let (_tx, rx) = watch::channel(false);
        let exec = self.exec.clone();
        tokio::spawn(async move {
            let _keep = _tx;
            exec.execute(rec, rx).await
        })
    }

    async fn run(&self, prompt: &str) -> store::RunRecord {
        let run = self.queue(prompt).await;
        let h = self.spawn().await;
        tokio::time::timeout(Duration::from_secs(60), h)
            .await
            .unwrap()
            .unwrap();
        self.record(run).await
    }

    async fn record(&self, run: RunId) -> store::RunRecord {
        let mut w = self.t.db.worker().await.unwrap();
        let r = w.run_record(run).await.unwrap();
        w.rollback().await.unwrap();
        r
    }

    async fn wait_state(&self, run: RunId, want: RunState) {
        for _ in 0..400 {
            if self.record(run).await.run.state == want {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("run never reached {want}: {:?}", self.record(run).await.run);
    }

    async fn ready_events(&self, run: RunId) -> Vec<Value> {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        tx.events_after(self.instance.id, 0, 1000)
            .await
            .unwrap()
            .into_iter()
            .filter(|e| e.run_id == Some(run) && e.kind == "agent.ready")
            .map(|e| e.payload)
            .collect()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn conversation_approval_and_platform_tools_through_a_real_shim() {
    let Some(e) = env().await else { return };

    let rec = e.run("hello there").await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("echo: hello there"));

    // 审批：shim 按“超出预授权就问用户”转给平台，用户批准后 agent 继续。
    let run = e.queue("tool:edit").await;
    let h = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let pending = tx.pending_approvals().await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].title.as_deref(), Some("Write notes.txt"));
    tx.decide_approval(pending[0].id, "allow", DeviceId::new())
        .await
        .unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(60), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.record(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("tool allowed"));

    // 平台工具：agent 经 MCP 桥调到平台，拿到结果。
    let rec = e.run(r#"mcp schedule_list {"limit":1}"#).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    let summary = rec.run.summary.unwrap();
    assert!(
        summary.contains(r#"schedule_list({"limit":1}) for run"#),
        "{summary}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancellation_and_session_survive_sandbox_rebuild() {
    let Some(e) = env().await else { return };
    let first = e.run("hello").await;
    assert_eq!(first.run.state, RunState::Succeeded);
    let ready = e.ready_events(first.run.id).await;
    assert_eq!(ready[0]["session_restored"], false);

    // 用户取消一个长任务：agent 这一轮被取消，shim 退出。
    let run = e.queue("slow").await;
    let h = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(run, None).await.unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(60), h)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(e.record(run).await.run.state, RunState::Cancelled);

    // 归档（沙箱销毁）后再跑：从模板重建沙箱，agent 的会话状态在工作区卷上，接回原会话。
    assert!(e.lifecycle.archive(e.instance.id).await.unwrap());
    let after = e.run("hello again").await;
    assert_eq!(after.run.state, RunState::Succeeded, "{:?}", after.run);
    let ready = e.ready_events(after.run.id).await;
    assert_eq!(ready[0]["session_restored"], true, "{ready:?}");
}
