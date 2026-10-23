//! 常驻可靠性演练（WBS 7.15）：计划运行跑到一半时出事，平台自己把它跑完。
//!
//! 每个副本是一个完整的 `thinktin-server`（调度、执行、投递、巡检），各自在单独的线程和 tokio 运行时里，
//! 自己的连接池；“杀进程”是直接丢掉整个运行时（不走优雅停机，和 `kill -9` 一样什么都来不及做）。
//! agent 是真实的 agent-shim 加假 agent，任务 `slow` 要跑 10 秒左右。
//!
//! - 杀 agent 进程：沙箱里的进程全被杀掉，同一个副本按崩溃重试，在同一个沙箱里接着跑。
//! - 杀副本（宿主机宕机）：副本连同它的本地沙箱一起没了，另一个副本等租约过期后接手，从模板重建沙箱接着跑。
//! - 发版重启：新副本先起来，老副本优雅停机，运行马上交回，新副本接着跑，不用等租约过期。
//! - 退出登录、关 App：见 `main_chain.rs` 的常驻场景（17.3）。
//!
//! 每个场景都核对：运行最后成功、是第 2 次尝试、第 2 次的任务带续跑说明，以及恢复用了多久。
//! 需要 DATABASE_URL（没有时跳过）。

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use auth::sandbox_token::SandboxTokenIssuer;
use chrono::Utc;
use proto::domain::{
    CatchUp, GrantScope, InstanceId, PlanAuthor, PlanPolicy, Run, RunState, ScheduleSpec, UserId,
};
use server::Config;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use store::testing::TestDb;
use store::{NewInstance, NewPlan};
use tokio::sync::oneshot;

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

/// 演练环境：一个库、一个用户、一个实例、一个已经到点的计划（任务 `slow`）。
struct Drill {
    t: TestDb,
    db_options: PgConnectOptions,
    dir: tempfile::TempDir,
    shim: PathBuf,
    manifest: PathBuf,
    seed: String,
    user: UserId,
    instance: InstanceId,
}

impl Drill {
    async fn new() -> Option<Drill> {
        let t = TestDb::new().await?;
        let (shim, agent) = binaries();
        let dir = tempfile::tempdir().unwrap();
        let manifest = manifest(dir.path(), &agent);
        let name: String = sqlx::query_scalar("SELECT current_database()")
            .fetch_one(t.db.pool())
            .await
            .unwrap();
        let db_options = std::env::var("DATABASE_URL")
            .unwrap()
            .parse::<PgConnectOptions>()
            .unwrap()
            .database(&name);

        let mut w = t.db.worker().await.unwrap();
        let (user, _) = w.upsert_user_by_phone("+8613800000715").await.unwrap();
        w.commit().await.unwrap();
        let claude = catalog::builtin("claude").unwrap();
        let mut tx = t.db.tenant(user.id).await.unwrap();
        let inst = tx
            .create_instance(&NewInstance {
                agent_id: "claude".into(),
                agent_version: claude.agent.version.clone(),
                harness: "acp".into(),
                name: "Claude".into(),
                workspace_id: "ws-drill".into(),
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
                title: "长任务".into(),
                goal: "slow".into(),
                policy: PlanPolicy::default(),
                catch_up: CatchUp::Once,
                created_by: PlanAuthor::User,
                run_grant_id: Some(grant.id),
            })
            .await
            .unwrap();
        // 40 秒前到点：削峰抖动（最多 30 秒）已经过去，副本一起来就领。
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
        let seed = SandboxTokenIssuer::generate("k1")
            .unwrap()
            .seed_b64()
            .to_string();
        Some(Drill {
            t,
            db_options,
            dir,
            shim,
            manifest,
            seed,
            user: user.id,
            instance: inst.id,
        })
    }

    fn sandbox_root(&self) -> PathBuf {
        self.dir.path().join("sandboxes")
    }

    /// 一个副本的配置。两个副本共用沙箱数据目录（工作区卷在里面），沙箱本身各管各的。
    fn config(&self, node: &str, lease_secs: u64) -> Config {
        let mut cfg = Config::parse(&format!(
            r#"
            node_id = "{node}"
            [shutdown]
            drain_secs = 0
            grace_secs = 10
            [worker]
            enabled = true
            sweep_every_secs = 3600
            lease_secs = {lease_secs}
            takeover_every_secs = 1
            retry_backoff_secs = 1
            [sandbox]
            local_root = "{}"
            shim_path = "{}"
            gateway_url = "http://127.0.0.1:9"
            manifest_override = "{}"
            token_kid = "k1"
            "#,
            self.sandbox_root().display(),
            self.shim.display(),
            self.manifest.display(),
        ))
        .unwrap();
        cfg.storage.local_root = self.dir.path().join("blobs");
        cfg.api_secrets.kms_key = Some("cd".repeat(32));
        cfg.sandbox_token_seed = Some(self.seed.clone());
        cfg
    }

    fn start(&self, node: &str, lease_secs: u64) -> Replica {
        Replica::start(self.config(node, lease_secs), self.db_options.clone())
    }

    async fn run(&self) -> Option<Run> {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let runs = tx.runs(self.instance, None, 10).await.unwrap();
        tx.rollback().await.unwrap();
        assert!(runs.len() <= 1, "one fire, one run: {runs:#?}");
        runs.into_iter().next()
    }

    async fn sandbox_id(&self) -> Option<String> {
        let mut w = self.t.db.worker().await.unwrap();
        let rt = w.instance_runtime(self.instance).await.unwrap();
        w.rollback().await.unwrap();
        rt.sandbox_id
    }

    /// 等运行进入运行中，再让 agent 干一会儿。
    async fn wait_running(&self) -> Run {
        for _ in 0..240 {
            if let Some(r) = self.run().await
                && r.state == RunState::Running
            {
                tokio::time::sleep(Duration::from_millis(1500)).await;
                return r;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        panic!("the run never started: {:#?}", self.run().await);
    }

    async fn wait_done(&self, within: Duration) -> Run {
        let deadline = Instant::now() + within;
        while Instant::now() < deadline {
            if let Some(r) = self.run().await
                && r.state.is_terminal()
            {
                return r;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        panic!(
            "the run did not finish within {within:?}: {:#?}",
            self.run().await
        );
    }
}

/// 第 2 次尝试成功，任务前面加了续跑说明（假 agent 把收到的任务原样回显成总结）。
fn assert_resumed(run: &Run) {
    assert_eq!(run.state, RunState::Succeeded, "{run:#?}");
    assert_eq!(run.attempt, 2, "{run:#?}");
    let summary = run.summary.as_deref().unwrap_or_default();
    assert!(
        summary.starts_with("echo: （续跑说明：这是第 2 次尝试"),
        "{summary}"
    );
}

/// 一个副本：单独的线程、单独的 tokio 运行时、单独的连接池。
struct Replica {
    stop: Option<oneshot::Sender<()>>,
    kill: Option<oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Replica {
    fn start(cfg: Config, db: PgConnectOptions) -> Replica {
        let (stop_tx, stop_rx) = oneshot::channel::<()>();
        let (kill_tx, kill_rx) = oneshot::channel::<()>();
        let thread = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async move {
                let pool = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(db)
                    .await
                    .unwrap();
                let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                let serve = server::serve(&cfg, store::Db::from_pool(pool), listener, async {
                    stop_rx.await.ok();
                });
                tokio::select! {
                    r = serve => r.unwrap(),
                    _ = kill_rx => {}
                }
            });
            // 不等任何任务收尾：和进程被杀一样。
            rt.shutdown_background();
        });
        Replica {
            stop: Some(stop_tx),
            kill: Some(kill_tx),
            thread: Some(thread),
        }
    }

    async fn join(&mut self) {
        let thread = self.thread.take().unwrap();
        tokio::task::spawn_blocking(move || thread.join())
            .await
            .unwrap()
            .expect("replica thread panicked");
    }

    /// 杀掉：运行时直接丢弃，租约、连接、沙箱进程都没人收拾。
    async fn kill(mut self) {
        self.kill.take().unwrap().send(()).ok();
        self.join().await;
    }

    /// 优雅停机（发版）。
    async fn stop(mut self) {
        self.stop.take().unwrap().send(()).ok();
        tokio::time::timeout(Duration::from_secs(30), self.join())
            .await
            .expect("the replica stops within its grace period");
    }
}

/// 杀掉工作目录在 `root` 下面的所有进程（沙箱里的 agent-shim 和 agent）。返回杀了几个。
fn kill_sandbox_processes(root: &Path) -> usize {
    let root = root.canonicalize().unwrap();
    let mut killed = 0;
    for entry in std::fs::read_dir("/proc").unwrap().flatten() {
        let name = entry.file_name();
        let Some(pid) = name
            .to_str()
            .filter(|s| s.chars().all(|c| c.is_ascii_digit()))
        else {
            continue;
        };
        let Ok(cwd) = std::fs::read_link(entry.path().join("cwd")) else {
            continue;
        };
        if cwd.starts_with(&root) {
            let ok = std::process::Command::new("kill")
                .args(["-9", pid])
                .status()
                .is_ok_and(|s| s.success());
            if ok {
                killed += 1;
            }
        }
    }
    killed
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn killed_agent_processes_are_retried_in_the_same_sandbox() {
    let Some(d) = Drill::new().await else { return };
    let a = d.start("drill-a", 30);
    let first = d.wait_running().await;
    assert_eq!(first.attempt, 1);
    let sandbox = d.sandbox_id().await;

    let t = Instant::now();
    assert!(
        kill_sandbox_processes(&d.sandbox_root()) > 0,
        "found the agent's processes"
    );
    let run = d.wait_done(Duration::from_secs(60)).await;
    let recovery = t.elapsed();
    assert_resumed(&run);
    assert_eq!(d.sandbox_id().await, sandbox, "same sandbox");
    eprintln!("agent killed: finished {recovery:?} after the kill");
    a.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_killed_replica_is_taken_over_after_its_lease() {
    let Some(d) = Drill::new().await else { return };
    let lease = 4;
    let a = d.start("drill-a", lease);
    let first = d.wait_running().await;
    assert_eq!(first.attempt, 1);
    let sandbox = d.sandbox_id().await;

    let t = Instant::now();
    a.kill().await;
    // 宿主机连同沙箱一起没了，另一个副本接手。
    let b = d.start("drill-b", lease);
    let run = d.wait_done(Duration::from_secs(90)).await;
    let recovery = t.elapsed();
    assert_resumed(&run);
    assert_ne!(d.sandbox_id().await, sandbox, "rebuilt from the template");
    // 至少等到租约过期（续租间隔是租约的四分之一，最后一次续租后最多再过 3/4 个租约）。
    assert!(
        recovery >= Duration::from_secs(lease) / 2,
        "taken over before the lease could expire: {recovery:?}"
    );
    eprintln!("replica killed: finished {recovery:?} after the kill (lease {lease}s)");
    b.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_rolling_restart_hands_the_run_over_without_waiting_for_the_lease() {
    let Some(d) = Drill::new().await else { return };
    // 租约很长：如果要等它过期，这个测试会超时。
    let lease = 120;
    let old = d.start("drill-old", lease);
    let first = d.wait_running().await;
    assert_eq!(first.attempt, 1);

    // 新版本先起来，再停老的。
    let new = d.start("drill-new", lease);
    let t = Instant::now();
    old.stop().await;
    let run = d.wait_done(Duration::from_secs(45)).await;
    let recovery = t.elapsed();
    assert_resumed(&run);
    assert!(
        recovery < Duration::from_secs(lease),
        "handed over without waiting for the lease: {recovery:?}"
    );
    eprintln!("rolling restart: finished {recovery:?} after the old replica was told to stop");
    new.stop().await;
}
