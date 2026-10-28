//! 并发唤醒：`instances` 个暂停着的实例，每个被同时唤醒 `wakes_per_instance` 次（比如整点时同一个实例上
//! 有好几个计划到点），总并发 `concurrency`。
//!
//! 沙箱后端是本地后端外面包一层固定延迟（[`Delayed`]），模拟 Cube 建沙箱、恢复、暂停的耗时；测的是控制面这一侧：
//! 实例行锁、连接池、状态核对。核对：每个实例只恢复了一次沙箱（重复唤醒排在行锁后面，看到已经在跑就直接返回），
//! 沙箱 id 不变，最后全部是运行中。
//!
//! 注意 `ensure_running` 在调用沙箱后端期间一直占着一个数据库连接和实例的行锁，所以单副本的唤醒吞吐
//! 上限大约是 连接池大小 / 恢复耗时。报告里的 `pool_bound_per_sec` 就是这个数。

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, ensure};
use async_trait::async_trait;
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use futures_util::StreamExt;
use proto::domain::{InstanceId, UserId};
use sandbox::local::LocalProvider;
use sandbox::{CreateSpec, ExecSpec, Process, SandboxId, SandboxInfo, SandboxProvider, SnapshotId};
use serde::Serialize;
use store::Db;

use crate::stats::{Summary, rate};

/// 给另一个后端的建、恢复、暂停加上固定延迟，并计数。
pub struct Delayed<P> {
    inner: P,
    pub create_latency: Duration,
    pub resume_latency: Duration,
    pub pause_latency: Duration,
    pub creates: AtomicUsize,
    pub resumes: AtomicUsize,
    pub pauses: AtomicUsize,
}

impl<P> Delayed<P> {
    pub fn new(inner: P, create: Duration, resume: Duration, pause: Duration) -> Self {
        Self {
            inner,
            create_latency: create,
            resume_latency: resume,
            pause_latency: pause,
            creates: AtomicUsize::new(0),
            resumes: AtomicUsize::new(0),
            pauses: AtomicUsize::new(0),
        }
    }
}

async fn delay(d: Duration) {
    if !d.is_zero() {
        tokio::time::sleep(d).await;
    }
}

#[async_trait]
impl<P: SandboxProvider> SandboxProvider for Delayed<P> {
    fn name(&self) -> &'static str {
        self.inner.name()
    }

    fn workspace_persists(&self) -> bool {
        self.inner.workspace_persists()
    }

    async fn create(&self, spec: CreateSpec) -> sandbox::Result<SandboxInfo> {
        delay(self.create_latency).await;
        self.creates.fetch_add(1, Ordering::Relaxed);
        self.inner.create(spec).await
    }

    async fn get(&self, id: &SandboxId) -> sandbox::Result<Option<SandboxInfo>> {
        self.inner.get(id).await
    }

    async fn exec(&self, id: &SandboxId, spec: ExecSpec) -> sandbox::Result<Process> {
        self.inner.exec(id, spec).await
    }

    async fn pause(&self, id: &SandboxId) -> sandbox::Result<()> {
        delay(self.pause_latency).await;
        self.pauses.fetch_add(1, Ordering::Relaxed);
        self.inner.pause(id).await
    }

    async fn resume(&self, id: &SandboxId) -> sandbox::Result<SandboxInfo> {
        delay(self.resume_latency).await;
        self.resumes.fetch_add(1, Ordering::Relaxed);
        self.inner.resume(id).await
    }

    async fn snapshot(&self, id: &SandboxId) -> sandbox::Result<SnapshotId> {
        self.inner.snapshot(id).await
    }

    async fn restore(
        &self,
        snapshot: &SnapshotId,
        spec: CreateSpec,
    ) -> sandbox::Result<SandboxInfo> {
        self.inner.restore(snapshot, spec).await
    }

    async fn destroy(&self, id: &SandboxId) -> sandbox::Result<()> {
        self.inner.destroy(id).await
    }

    async fn delete_workspace(&self, workspace: &str) -> sandbox::Result<()> {
        self.inner.delete_workspace(workspace).await
    }

    async fn write_file(&self, id: &SandboxId, path: &str, data: &[u8]) -> sandbox::Result<()> {
        self.inner.write_file(id, path, data).await
    }

    async fn read_file(&self, id: &SandboxId, path: &str, max: u64) -> sandbox::Result<Vec<u8>> {
        self.inner.read_file(id, path, max).await
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub instances: usize,
    pub users: usize,
    /// 每个实例同时被唤醒几次。
    pub wakes_per_instance: usize,
    /// 同时进行的唤醒数。
    pub concurrency: usize,
    pub create_latency: Duration,
    pub resume_latency: Duration,
    pub pause_latency: Duration,
    /// 准备阶段（建沙箱、暂停）的并发数。
    pub setup_concurrency: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            instances: 500,
            users: 100,
            wakes_per_instance: 2,
            concurrency: 256,
            create_latency: Duration::from_millis(500),
            resume_latency: Duration::from_millis(200),
            pause_latency: Duration::from_millis(100),
            setup_concurrency: 32,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Report {
    pub instances: usize,
    pub wakes: usize,
    pub concurrency: usize,
    pub pool_size: u32,
    pub resume_latency_ms: f64,
    pub setup_secs: f64,
    pub wall_ms: f64,
    pub wakes_per_sec: f64,
    /// 单副本的理论上限：连接池大小 / 恢复耗时。
    pub pool_bound_per_sec: f64,
    pub latency: Summary,
    pub errors: usize,
    pub first_error: Option<String>,
    /// 唤醒阶段沙箱后端被调用恢复的次数（应等于实例数）。
    pub resumes: usize,
    /// 唤醒后沙箱 id 变了的实例数（应为 0）。
    pub sandbox_changed: usize,
    /// 最后处于运行中的实例数（应等于实例数）。
    pub running: i64,
}

/// 领养一个实例、第一次唤醒建沙箱、再暂停。返回实例和沙箱 id。
async fn prepare(lc: &Lifecycle, user: UserId, i: usize) -> anyhow::Result<(InstanceId, String)> {
    let inst = lc
        .adopt(user, "loadtest", "claude", None, &format!("wake-{i}"))
        .await?;
    let rt = lc.ensure_running(inst.id).await?;
    let sid = rt.sandbox_id.context("no sandbox after the first wake")?;
    ensure!(
        lc.pause(inst.id).await?,
        "instance {} did not pause",
        inst.id
    );
    Ok((inst.id, sid))
}

/// `pool_size` 是 `db` 连接池的大小，只用来算报告里的理论上限。
pub async fn run(db: &Db, pool_size: u32, cfg: &Config) -> anyhow::Result<Report> {
    ensure!(
        cfg.instances > 0 && cfg.users > 0,
        "need at least one instance and one user"
    );
    let dir = tempfile::tempdir().context("sandbox root")?;
    let provider = Arc::new(Delayed::new(
        LocalProvider::new(dir.path()).context("local sandbox provider")?,
        cfg.create_latency,
        cfg.resume_latency,
        cfg.pause_latency,
    ));
    let lc = Lifecycle::new(
        db.clone(),
        provider.clone(),
        Arc::new(BuiltinTemplates),
        LifecycleConfig::default(),
    );

    // 准备：领养、第一次唤醒建沙箱、暂停。
    let setup_start = Instant::now();
    let mut users = Vec::with_capacity(cfg.users);
    let mut w = db.worker().await?;
    for u in 0..cfg.users {
        let (user, _) = w.upsert_user_by_phone(&format!("+86137{u:08}")).await?;
        users.push(user.id);
    }
    w.commit().await?;
    let lc = &lc;
    let users = &users;
    let prepared: Vec<anyhow::Result<(InstanceId, String)>> =
        futures_util::stream::iter(0..cfg.instances)
            .map(|i| prepare(lc, users[i % users.len()], i))
            .buffer_unordered(cfg.setup_concurrency.max(1))
            .collect()
            .await;
    let sandboxes: HashMap<InstanceId, String> = prepared
        .into_iter()
        .collect::<anyhow::Result<_>>()
        .context("prepare paused instances")?;
    let setup_secs = setup_start.elapsed().as_secs_f64();

    // 唤醒洪峰：同一个实例的几次唤醒错开排进队列，让它们真的撞在一起。
    let ids: Vec<InstanceId> = sandboxes.keys().copied().collect();
    let wakes: Vec<InstanceId> = (0..cfg.wakes_per_instance.max(1))
        .flat_map(|_| ids.iter().copied())
        .collect();
    let resumes_before = provider.resumes.load(Ordering::Relaxed);
    let start = Instant::now();
    let results: Vec<(InstanceId, Duration, Result<Option<String>, String>)> =
        futures_util::stream::iter(wakes.iter().copied())
            .map(|id| async move {
                let t = Instant::now();
                let r = lc
                    .ensure_running(id)
                    .await
                    .map(|rt| rt.sandbox_id)
                    .map_err(|e| e.to_string());
                (id, t.elapsed(), r)
            })
            .buffer_unordered(cfg.concurrency.max(1))
            .collect()
            .await;
    let wall = start.elapsed();
    let resumes = provider.resumes.load(Ordering::Relaxed) - resumes_before;

    let mut latencies = Vec::with_capacity(results.len());
    let mut errors = 0;
    let mut first_error = None;
    let mut changed = std::collections::HashSet::new();
    for (id, elapsed, r) in results {
        match r {
            Ok(sid) => {
                latencies.push(elapsed);
                if sid.as_deref() != sandboxes.get(&id).map(String::as_str) {
                    changed.insert(id);
                }
            }
            Err(e) => {
                errors += 1;
                first_error.get_or_insert(e);
            }
        }
    }
    let running: i64 = sqlx::query_scalar("SELECT count(*) FROM instances WHERE state = 'running'")
        .fetch_one(db.pool())
        .await?;
    let resume_secs = cfg.resume_latency.as_secs_f64().max(0.001);

    Ok(Report {
        instances: ids.len(),
        wakes: wakes.len(),
        concurrency: cfg.concurrency,
        pool_size,
        resume_latency_ms: cfg.resume_latency.as_secs_f64() * 1000.0,
        setup_secs,
        wall_ms: wall.as_secs_f64() * 1000.0,
        wakes_per_sec: rate(wakes.len(), wall),
        pool_bound_per_sec: f64::from(pool_size) / resume_secs,
        latency: Summary::of(&latencies),
        errors,
        first_error,
        resumes,
        sandbox_changed: changed.len(),
        running,
    })
}
