//! 主程序带后台任务跑起来：计划到点 → 调度循环生成运行 → 执行器在本地沙箱里用真实 agent-shim
//! 驱动假 agent → 结果写库、通知进出箱、投递器处理。需要 DATABASE_URL（没有时跳过）。

use std::path::{Path, PathBuf};
use std::time::Duration;

use auth::sandbox_token::SandboxTokenIssuer;
use chrono::Utc;
use proto::domain::{CatchUp, GrantScope, PlanAuthor, PlanPolicy, RunState, ScheduleSpec};
use server::Config;
use store::testing::TestDb;
use store::{NewInstance, NewPlan};

fn binaries() -> (PathBuf, PathBuf) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let status = std::process::Command::new(env!("CARGO"))
        .args(["build", "-q", "-p", "agent-shim", "--bins"])
        .current_dir(&root)
        .status()
        .expect("run cargo build");
    assert!(status.success());
    let target = std::env::var("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join("target"));
    let dir = target.join("debug").canonicalize().unwrap();
    (dir.join("agent-shim"), dir.join("fake-acp-agent"))
}

fn manifest(dir: &Path, agent: &Path) -> PathBuf {
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_due_plan_runs_to_completion_inside_the_server() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("warn,agent_shim=debug")
        .with_test_writer()
        .try_init();
    let Some(t) = TestDb::new().await else { return };
    let (shim, agent) = binaries();
    let dir = tempfile::tempdir().unwrap();
    let manifest = manifest(dir.path(), &agent);
    let mut cfg = Config::parse(&format!(
        r#"
        [shutdown]
        drain_secs = 0
        grace_secs = 10
        [worker]
        enabled = true
        sweep_every_secs = 3600
        [sandbox]
        local_root = "{}"
        shim_path = "{}"
        gateway_url = "http://127.0.0.1:9"
        manifest_override = "{}"
        token_kid = "k1"
        "#,
        dir.path().join("sandboxes").display(),
        shim.display(),
        manifest.display(),
    ))
    .unwrap();
    cfg.sandbox_token_seed = Some(
        SandboxTokenIssuer::generate("k1")
            .unwrap()
            .seed_b64()
            .to_string(),
    );

    // 一个用户、一个实例（领养的是内置 claude 清单，跑起来用假 agent 的清单）、一个到点的计划。
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let claude = catalog::builtin("claude").unwrap();
    let mut tx = t.db.tenant(user.id).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: claude.agent.version.clone(),
            harness: "acp".into(),
            name: "Claude".into(),
            workspace_id: "ws-e2e".into(),
            limits: Default::default(),
        })
        .await
        .unwrap();
    let grant = tx
        .create_run_grant(
            inst.id,
            None,
            &GrantScope::default(),
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let plan = tx
        .create_plan(&NewPlan {
            instance_id: inst.id,
            title: "早报".into(),
            goal: "daily briefing".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::User,
            run_grant_id: Some(grant.id),
        })
        .await
        .unwrap();
    tx.add_trigger(
        plan.id,
        &ScheduleSpec::Cron {
            expr: "0 8 * * *".into(),
            tz: "Asia/Shanghai".into(),
        },
        Some(Utc::now() - chrono::Duration::seconds(40)),
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let db = t.db.clone();
    let server = tokio::spawn(async move {
        server::serve(&cfg, db, listener, async {
            stop_rx.await.ok();
        })
        .await
    });

    // 等运行跑完。
    let mut done = None;
    for _ in 0..240 {
        let mut tx = t.db.tenant(user.id).await.unwrap();
        let runs = tx.runs(inst.id, None, 10).await.unwrap();
        tx.rollback().await.unwrap();
        if let Some(r) = runs.into_iter().find(|r| r.state.is_terminal()) {
            done = Some(r);
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let Some(run) = done else {
        let mut tx = t.db.tenant(user.id).await.unwrap();
        panic!(
            "the plan run did not finish: {:#?}",
            tx.runs(inst.id, None, 10).await.unwrap()
        );
    };
    assert_eq!(run.state, RunState::Succeeded, "{run:?}");
    assert_eq!(run.plan_id, Some(plan.id));
    assert_eq!(run.summary.as_deref(), Some("echo: daily briefing"));

    // 结果通知进了出箱，投递器处理掉了（这个用户没有设备，记为放弃）。
    let mut drained = false;
    for _ in 0..40 {
        let mut w = t.db.worker().await.unwrap();
        let left = w
            .claim_outbox("probe", Duration::from_secs(1), 10)
            .await
            .unwrap();
        w.rollback().await.unwrap();
        if left.is_empty() {
            drained = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(drained, "the dispatcher handled the notification");

    stop_tx.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(30), server)
        .await
        .expect("server stops within the grace period")
        .unwrap()
        .unwrap();
}
