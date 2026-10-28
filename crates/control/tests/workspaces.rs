//! 工作区归档：没有卷的后端（本地后端的无卷模式，和 ACS 一样）+ 内存里的归档存储 + 真实 Postgres
//! （没有 DATABASE_URL 时跳过）。打包、解包用宿主机上的 GNU tar。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use catalog::Manifest;
use control::{
    ArchiveMeta, BuiltinTemplates, Error, Lifecycle, LifecycleConfig, PutTicket, Templates,
    WorkspaceStore,
};
use proto::domain::{
    CatchUp, InstanceId, InstanceState, PlanAuthor, PlanPolicy, ScheduleSpec, UserId,
};
use sandbox::local::LocalProvider;
use sandbox::{
    CreateSpec, ExecSpec, Process, SandboxId, SandboxInfo, SandboxProvider, SandboxState,
    SnapshotId,
};
use sha2::{Digest, Sha256};
use store::WorkspaceArchive;
use store::testing::TestDb;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use uuid::Uuid;

/// 明文放在内存里的归档存储（生产上是加密后放对象存储）。
#[derive(Default)]
struct MemStore {
    objects: Mutex<HashMap<String, Vec<u8>>>,
    fail_put: AtomicBool,
    corrupt: AtomicBool,
    /// 存、放在这里停住，直到放行（模拟要传很久）。
    hold: AtomicBool,
    held: tokio::sync::Notify,
    release: tokio::sync::Notify,
    /// 开始过几次上传、删过哪些对象。
    puts: AtomicUsize,
    deleted: Mutex<Vec<String>>,
}

impl MemStore {
    async fn maybe_hold(&self) {
        if self.hold.load(Ordering::SeqCst) {
            self.held.notify_one();
            self.release.notified().await;
        }
    }
}

#[async_trait]
impl WorkspaceStore for MemStore {
    async fn put(
        &self,
        _user: UserId,
        key: &str,
        id: Uuid,
        data: &mut (dyn AsyncRead + Send + Unpin),
        max: u64,
        _ticket: PutTicket,
    ) -> Result<ArchiveMeta, String> {
        self.puts.fetch_add(1, Ordering::SeqCst);
        if self.fail_put.load(Ordering::SeqCst) {
            return Err("object storage is down".into());
        }
        self.maybe_hold().await;
        let mut buf = Vec::new();
        data.take(max + 1)
            .read_to_end(&mut buf)
            .await
            .map_err(|e| e.to_string())?;
        if buf.len() as u64 > max {
            return Err("too large".into());
        }
        let meta = ArchiveMeta {
            id,
            bytes: buf.len() as u64,
            sha256: Sha256::digest(&buf).into(),
        };
        self.objects.lock().unwrap().insert(key.to_owned(), buf);
        Ok(meta)
    }

    async fn restore(
        &self,
        _user: UserId,
        archive: &WorkspaceArchive,
        sink: &mut (dyn AsyncWrite + Send + Unpin),
    ) -> Result<(), String> {
        let mut data = self
            .objects
            .lock()
            .unwrap()
            .get(&archive.key)
            .cloned()
            .ok_or("no such archive")?;
        if self.corrupt.load(Ordering::SeqCst) {
            data[10] ^= 0xff;
        }
        self.maybe_hold().await;
        sink.write_all(&data).await.map_err(|e| e.to_string())?;
        let sha: [u8; 32] = Sha256::digest(&data).into();
        if sha != archive.sha256 || data.len() as u64 != archive.bytes {
            return Err("archive does not match its record".into());
        }
        Ok(())
    }

    async fn delete(&self, _user: UserId, key: &str) -> Result<(), String> {
        self.objects.lock().unwrap().remove(key);
        self.deleted.lock().unwrap().push(key.to_owned());
        Ok(())
    }
}

struct Env {
    t: TestDb,
    dir: tempfile::TempDir,
    provider: Arc<LocalProvider>,
    store: Arc<MemStore>,
    user: UserId,
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let dir = tempfile::tempdir().unwrap();
    let provider = Arc::new(LocalProvider::new(dir.path()).unwrap().without_volumes());
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000002").await.unwrap();
    w.commit().await.unwrap();
    Some(Env {
        t,
        dir,
        provider,
        store: Arc::default(),
        user: user.id,
    })
}

fn lifecycle(e: &Env, cfg: LifecycleConfig) -> Lifecycle {
    Lifecycle::new(
        e.t.db.clone(),
        e.provider.clone(),
        Arc::new(BuiltinTemplates),
        cfg,
    )
    .with_workspace_store(e.store.clone())
}

fn eager() -> LifecycleConfig {
    LifecycleConfig {
        idle_pause: Duration::ZERO,
        archive_after: Duration::ZERO,
        ..LifecycleConfig::default()
    }
}

impl Env {
    async fn runtime(&self, id: InstanceId) -> store::InstanceRuntime {
        let mut w = self.t.db.worker().await.unwrap();
        w.instance_runtime(id).await.unwrap()
    }

    async fn purge_queue(&self) -> Vec<String> {
        let mut w = self.t.db.worker().await.unwrap();
        let mut keys = w.blob_purge_batch(100).await.unwrap();
        w.forget_blob_purge(&keys).await.unwrap();
        w.commit().await.unwrap();
        keys.sort();
        keys
    }

    async fn write(&self, sandbox: &str, path: &str, data: &[u8]) {
        self.provider
            .write_file(&SandboxId(sandbox.into()), path, data)
            .await
            .unwrap();
    }

    async fn read(&self, sandbox: &str, path: &str) -> Option<Vec<u8>> {
        self.provider
            .read_file(&SandboxId(sandbox.into()), path, u64::MAX)
            .await
            .ok()
    }

    fn sandboxes(&self) -> usize {
        std::fs::read_dir(self.dir.path().join("sandboxes"))
            .unwrap()
            .count()
    }
}

#[tokio::test]
async fn idle_instances_are_archived_to_the_store_and_restored() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, eager());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    e.write(&sid, "workspace/.thinktin/home/state.json", b"{}")
        .await;

    // 一轮巡检：先暂停，再归档（工作区打包存走，沙箱销毁）。
    let report = lc.sweep().await.unwrap();
    assert_eq!((report.paused, report.archived, report.failed), (1, 1, 0));
    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Archived);
    assert_eq!(rt.sandbox_id, None);
    assert_eq!(e.provider.get(&SandboxId(sid.clone())).await.unwrap(), None);
    let first = rt.archive.clone().unwrap();
    assert!(e.store.objects.lock().unwrap().contains_key(&first.key));
    assert!(first.key.starts_with("workspaces/"), "{}", first.key);
    assert!(e.purge_queue().await.is_empty());

    // 唤醒：从模板建新沙箱，把工作区放回去，临时文件删掉。
    let woke = lc.ensure_running(inst.id).await.unwrap();
    let new_sid = woke.sandbox_id.unwrap();
    assert_ne!(new_sid, sid);
    assert_eq!(
        e.read(&new_sid, "workspace/notes.txt").await.unwrap(),
        b"keep me"
    );
    assert_eq!(
        e.read(&new_sid, "workspace/.thinktin/home/state.json")
            .await
            .unwrap(),
        b"{}"
    );
    assert_eq!(
        e.read(&new_sid, "workspace/.thinktin/restore.tgz").await,
        None
    );

    // 手动归档运行中的实例：新归档换掉旧的，旧对象排进清理队列。
    e.write(&new_sid, "workspace/notes.txt", b"v2").await;
    assert!(lc.archive(inst.id).await.unwrap());
    let second = e.runtime(inst.id).await.archive.unwrap();
    assert_ne!(second.key, first.key);
    assert_eq!(e.purge_queue().await, std::slice::from_ref(&first.key));
    let again = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    assert_eq!(e.read(&again, "workspace/notes.txt").await.unwrap(), b"v2");

    // 删除实例：回收时归档也排进清理队列。
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.delete_instance(inst.id).await.unwrap();
    t.commit().await.unwrap();
    assert_eq!(lc.sweep().await.unwrap().purged, 1);
    assert_eq!(e.purge_queue().await, std::slice::from_ref(&second.key));
    assert!(e.runtime(inst.id).await.archive.is_none());
}

#[tokio::test]
async fn failed_saves_and_restores_lose_nothing() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, eager());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;

    // 存不进去：不归档，沙箱暂停着留下（为打包恢复过的又暂停回去），没用上的对象排进清理队列。
    e.store.fail_put.store(true, Ordering::SeqCst);
    let report = lc.sweep().await.unwrap();
    assert_eq!((report.paused, report.archived, report.failed), (1, 0, 1));
    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Paused);
    assert_eq!(rt.sandbox_id.as_deref(), Some(sid.as_str()));
    assert!(rt.archive.is_none());
    assert_eq!(
        e.provider
            .get(&SandboxId(sid.clone()))
            .await
            .unwrap()
            .unwrap()
            .state,
        SandboxState::Paused
    );
    let queued = e.purge_queue().await;
    assert_eq!(queued.len(), 1);
    assert!(e.store.objects.lock().unwrap().is_empty());
    assert!(e.runtime(inst.id).await.archive_failed_at.is_some());

    // 失败过的一段时间内不再试（不然每轮巡检都恢复、打包一遍）。
    e.store.fail_put.store(false, Ordering::SeqCst);
    let report = lc.sweep().await.unwrap();
    assert_eq!((report.archived, report.failed), (0, 0));
    assert!(e.read_paused(&sid).await);

    // 过了重试的时间再试：存好了。放回时归档对不上：唤醒失败，新沙箱删掉，实例还是已归档、归档还在。
    let lc = lifecycle(
        &e,
        LifecycleConfig {
            archive_retry_after: Duration::ZERO,
            ..eager()
        },
    );
    assert_eq!(lc.sweep().await.unwrap().archived, 1);
    assert!(e.runtime(inst.id).await.archive_failed_at.is_none());
    e.store.corrupt.store(true, Ordering::SeqCst);
    assert!(matches!(
        lc.ensure_running(inst.id).await,
        Err(Error::Workspace(_))
    ));
    assert_eq!(e.sandboxes(), 0, "no sandbox is left behind");
    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Archived);
    assert!(rt.archive.is_some());

    // 修好了再唤醒：文件都在。
    e.store.corrupt.store(false, Ordering::SeqCst);
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    assert_eq!(
        e.read(&sid, "workspace/notes.txt").await.unwrap(),
        b"keep me"
    );
}

#[tokio::test]
async fn too_large_workspaces_stay_paused() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(
        &e,
        LifecycleConfig {
            max_archive_bytes: 64,
            ..eager()
        },
    );
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    let noise: Vec<u8> = (0..4096u32)
        .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
        .collect();
    e.write(&sid, "workspace/noise.bin", &noise).await;
    let report = lc.sweep().await.unwrap();
    assert_eq!((report.archived, report.failed), (0, 1));
    assert_eq!(e.runtime(inst.id).await.state, InstanceState::Paused);
    assert!(e.read_paused(&sid).await);
    // 下一轮不再恢复、打包一遍。
    let report = lc.sweep().await.unwrap();
    assert_eq!((report.archived, report.failed), (0, 0));
    assert!(e.read_paused(&sid).await);
}

impl Env {
    /// 在后端建一个沙箱、记成“正在放回”，然后不管了（模拟唤醒到一半进程没了）。
    async fn orphan(&self, inst: InstanceId, name: &str) -> SandboxId {
        let info = self
            .provider
            .create(CreateSpec {
                template: name.into(),
                workspace: Some("w".into()),
                ..CreateSpec::default()
            })
            .await
            .unwrap();
        let mut w = self.t.db.worker().await.unwrap();
        w.begin_restore(inst, &info.id.0).await.unwrap();
        w.commit().await.unwrap();
        info.id
    }

    /// 沙箱还在（暂停着）。
    async fn read_paused(&self, sid: &str) -> bool {
        matches!(
            self.provider.get(&SandboxId(sid.into())).await.unwrap(),
            Some(i) if i.state == SandboxState::Paused
        )
    }
}

/// 换版本：先把工作区存起来、销毁旧沙箱，再按新版本建、放回去。
#[tokio::test]
async fn version_changes_keep_the_workspace() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, LifecycleConfig::default());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let old = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&old, "workspace/notes.md", b"keep me").await;

    let current = catalog::builtin("pi").unwrap().agent.version;
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.request_instance_version(inst.id, &current).await.unwrap();
    t.commit().await.unwrap();
    let rt = lc.ensure_running(inst.id).await.unwrap();
    let new = rt.sandbox_id.clone().unwrap();
    assert_ne!(new, old);
    assert!(!rt.rebuild_pending);
    assert_eq!(e.provider.get(&SandboxId(old)).await.unwrap(), None);
    assert_eq!(
        e.read(&new, "workspace/notes.md").await.unwrap(),
        b"keep me"
    );
    assert!(e.runtime(inst.id).await.archive.is_some());

    // 运维的重建也一样。
    e.write(&new, "workspace/notes.md", b"v2").await;
    let rebuilt = lc.rebuild(inst.id, None).await.unwrap();
    let third = rebuilt.sandbox_id.unwrap();
    assert_ne!(third, new);
    assert_eq!(e.read(&third, "workspace/notes.md").await.unwrap(), b"v2");
}

/// 归档了的实例，计划快到点时也提前建好沙箱、放回工作区（6.5 预热）。
#[tokio::test]
async fn archived_instances_are_prewarmed_before_their_plans() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(
        &e,
        LifecycleConfig {
            keep_if_trigger_within: Duration::ZERO,
            prewarm_lead: Duration::from_secs(300),
            ..eager()
        },
    );
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    assert_eq!(lc.sweep().await.unwrap().archived, 1);

    let mut t = e.t.db.tenant(e.user).await.unwrap();
    let plan = t
        .create_plan(&store::NewPlan {
            instance_id: inst.id,
            title: "soon".into(),
            goal: "check".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::Once,
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    t.add_trigger(
        plan.id,
        &ScheduleSpec::Cron {
            expr: "0 * * * *".into(),
            tz: "UTC".into(),
        },
        Some(chrono::Utc::now() + chrono::Duration::seconds(60)),
    )
    .await
    .unwrap();
    t.commit().await.unwrap();

    // 换成平常的计时，免得同一轮巡检里预热完又被暂停、归档。
    let lc = lifecycle(
        &e,
        LifecycleConfig {
            keep_if_trigger_within: Duration::ZERO,
            prewarm_lead: Duration::from_secs(300),
            ..LifecycleConfig::default()
        },
    );
    let report = lc.sweep().await.unwrap();
    assert_eq!((report.prewarmed, report.failed), (1, 0));
    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Running);
    let sid = rt.sandbox_id.unwrap();
    assert_eq!(
        e.read(&sid, "workspace/notes.txt").await.unwrap(),
        b"keep me"
    );
}

/// 放回工作区时不锁实例，先记下新沙箱、定时刷新：别处的唤醒等着；不再刷新了（进程中途被杀）就当没人管了，
/// 删掉那个沙箱。
#[tokio::test]
async fn unfinished_restores_are_waited_for_then_cleaned_up() {
    let Some(e) = env().await else { return };
    // 标记 2 × 1 秒没刷新就算没人管。
    let lc = lifecycle(
        &e,
        LifecycleConfig {
            archive_timeout: Duration::from_secs(1),
            op_timeout: Duration::from_secs(1),
            ..LifecycleConfig::default()
        },
    );
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    assert!(lc.archive(inst.id).await.unwrap());

    // 一次唤醒建好了沙箱、记下了，还没放完就没了下文。
    let first = e.orphan(inst.id, "a").await;
    // 唤醒等着，等到算没人管了，删掉它、自己建一个放回去。
    let started = std::time::Instant::now();
    let rt = lc.ensure_running(inst.id).await.unwrap();
    assert!(
        started.elapsed() >= Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );
    let sid = rt.sandbox_id.clone().unwrap();
    assert_ne!(sid, first.0);
    assert_eq!(e.provider.get(&first).await.unwrap(), None);
    assert_eq!(
        e.read(&sid, "workspace/notes.txt").await.unwrap(),
        b"keep me"
    );
    assert!(e.runtime(inst.id).await.restoring.is_none());

    // 巡检也会清：标记太久没刷新。
    assert!(lc.archive(inst.id).await.unwrap());
    let second = e.orphan(inst.id, "b").await;
    sqlx::query("UPDATE instances SET restoring_since = now() - interval '1 hour' WHERE id = $1")
        .bind(inst.id.0)
        .execute(e.t.db.pool())
        .await
        .unwrap();
    lc.sweep().await.unwrap();
    assert_eq!(e.provider.get(&second).await.unwrap(), None);
    assert!(e.runtime(inst.id).await.restoring.is_none());
}

/// 只有当前版本，再假装有一个旧版本 `0.0.1-old`（同一份清单）。
struct TwoVersions;

const OLD: &str = "0.0.1-old";

impl Templates for TwoVersions {
    fn current(&self, agent_id: &str) -> Option<Manifest> {
        catalog::builtin(agent_id)
    }

    fn manifest(&self, agent_id: &str, version: &str) -> Option<Manifest> {
        let mut m = catalog::builtin(agent_id)?;
        if version == OLD {
            m.agent.version = OLD.into();
        }
        (m.agent.version == version).then_some(m)
    }
}

/// 换版本前存不下工作区：先不换，版本改回当前沙箱的版本，旧沙箱照常用（用户过后再试）。
#[tokio::test]
async fn version_changes_keep_the_old_version_when_the_workspace_cannot_be_saved() {
    let Some(e) = env().await else { return };
    let lc = Lifecycle::new(
        e.t.db.clone(),
        e.provider.clone(),
        Arc::new(TwoVersions),
        LifecycleConfig::default(),
    )
    .with_workspace_store(e.store.clone());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    lc.ensure_running(inst.id).await.unwrap();
    let old = lc.rebuild(inst.id, Some(OLD)).await.unwrap();
    assert_eq!(old.sandbox_version.as_deref(), Some(OLD));
    let sid = old.sandbox_id.unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;

    e.store.fail_put.store(true, Ordering::SeqCst);
    let current = catalog::builtin("pi").unwrap().agent.version;
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.request_instance_version(inst.id, &current).await.unwrap();
    t.commit().await.unwrap();
    let rt = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(
        rt.sandbox_id.as_deref(),
        Some(sid.as_str()),
        "the old sandbox keeps running"
    );
    assert_eq!(rt.agent_version, OLD);
    assert!(!rt.rebuild_pending);
    assert_eq!(
        e.read(&sid, "workspace/notes.txt").await.unwrap(),
        b"keep me"
    );
    let kept: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_log WHERE action = 'instance.version.kept' AND target = $1",
    )
    .bind(inst.id.to_string())
    .fetch_one(e.t.db.pool())
    .await
    .unwrap();
    assert_eq!(kept, 1);
}

/// 存、放要传很久时不锁着实例：这期间用户发消息、记事件这些写实例行的事务照常做（不然 15 秒就超时报错）。
#[tokio::test]
async fn long_transfers_do_not_lock_the_instance() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let lc = Arc::new(lifecycle(&e, LifecycleConfig::default()));
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    let write_event = || {
        let e = e.clone();
        async move {
            tokio::time::timeout(Duration::from_secs(3), async {
                let mut t = e.t.db.tenant(e.user).await.unwrap();
                t.append_event(inst.id, None, "test.ping", &serde_json::json!({}))
                    .await
                    .unwrap();
                t.commit().await.unwrap();
            })
            .await
        }
    };

    for step in ["archive", "restore"] {
        e.store.hold.store(true, Ordering::SeqCst);
        let held = e.store.held.notified();
        let task = {
            let lc = lc.clone();
            tokio::spawn(async move {
                if step == "archive" {
                    lc.archive(inst.id).await.map(|_| ())
                } else {
                    lc.ensure_running(inst.id).await.map(|_| ())
                }
            })
        };
        held.await;
        assert!(
            write_event().await.is_ok(),
            "{step}: the instance row is not locked"
        );
        e.store.hold.store(false, Ordering::SeqCst);
        e.store.release.notify_one();
        task.await.unwrap().unwrap();
    }
    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Running);
    assert_eq!(
        e.read(rt.sandbox_id.as_deref().unwrap(), "workspace/notes.txt")
            .await
            .unwrap(),
        b"keep me"
    );
}

/// 删沙箱可以设成失败一次、或者删完卡住一次的本地后端（没有卷）。
struct Flaky {
    inner: Arc<LocalProvider>,
    fail_destroy: AtomicBool,
    stall_destroy: AtomicBool,
    stalled: tokio::sync::Notify,
    /// 删完沙箱后断开这个库里其它开着事务的连接一次（模拟删沙箱期间库连接断了）。
    drop_connections: Mutex<Option<sqlx::PgPool>>,
}

impl Flaky {
    fn new(inner: Arc<LocalProvider>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            fail_destroy: AtomicBool::new(false),
            stall_destroy: AtomicBool::new(false),
            stalled: tokio::sync::Notify::new(),
            drop_connections: Mutex::new(None),
        })
    }
}

#[async_trait]
impl SandboxProvider for Flaky {
    fn name(&self) -> &'static str {
        "flaky"
    }

    fn workspace_persists(&self) -> bool {
        false
    }

    async fn create(&self, spec: CreateSpec) -> sandbox::Result<SandboxInfo> {
        self.inner.create(spec).await
    }

    async fn get(&self, id: &SandboxId) -> sandbox::Result<Option<SandboxInfo>> {
        self.inner.get(id).await
    }

    async fn exec(&self, id: &SandboxId, spec: ExecSpec) -> sandbox::Result<Process> {
        self.inner.exec(id, spec).await
    }

    async fn pause(&self, id: &SandboxId) -> sandbox::Result<()> {
        self.inner.pause(id).await
    }

    async fn resume(&self, id: &SandboxId) -> sandbox::Result<SandboxInfo> {
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
        if self.fail_destroy.swap(false, Ordering::SeqCst) {
            return Err(sandbox::Error::Provider(
                "sandbox-manager is unreachable".into(),
            ));
        }
        self.inner.destroy(id).await?;
        let pool = self.drop_connections.lock().unwrap().take();
        if let Some(pool) = pool {
            sqlx::query(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
                 WHERE datname = current_database() AND state = 'idle in transaction' \
                   AND pid <> pg_backend_pid()",
            )
            .execute(&pool)
            .await
            .unwrap();
        }
        if self.stall_destroy.swap(false, Ordering::SeqCst) {
            self.stalled.notify_one();
            std::future::pending::<()>().await;
        }
        Ok(())
    }

    async fn delete_workspace(&self, workspace: &str) -> sandbox::Result<()> {
        self.inner.delete_workspace(workspace).await
    }

    async fn write_file(&self, id: &SandboxId, path: &str, data: &[u8]) -> sandbox::Result<()> {
        self.inner.write_file(id, path, data).await
    }

    async fn write_file_stream(
        &self,
        id: &SandboxId,
        path: &str,
        data: Box<dyn AsyncRead + Send + Unpin>,
        len: u64,
    ) -> sandbox::Result<()> {
        self.inner.write_file_stream(id, path, data, len).await
    }

    async fn read_file(&self, id: &SandboxId, path: &str, max: u64) -> sandbox::Result<Vec<u8>> {
        self.inner.read_file(id, path, max).await
    }
}

impl Env {
    /// 等 `store` 停在存、放里（[`MemStore::hold`]）。
    async fn hold(&self) -> impl std::future::Future<Output = ()> + '_ {
        self.store.hold.store(true, Ordering::SeqCst);
        self.store.held.notified()
    }

    fn release(&self) {
        self.store.hold.store(false, Ordering::SeqCst);
        self.store.release.notify_one();
    }

    async fn request_current_version(&self, id: InstanceId) {
        let current = catalog::builtin("pi").unwrap().agent.version;
        let mut t = self.t.db.tenant(self.user).await.unwrap();
        t.request_instance_version(id, &current).await.unwrap();
        t.commit().await.unwrap();
    }
}

/// 一个实例同时只存一份：另一个副本的归档（巡检、手动）看到别处正在存就不做，不去恢复、暂停那个沙箱。
#[tokio::test]
async fn one_archive_at_a_time() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let lc = Arc::new(lifecycle(&e, LifecycleConfig::default()));
    let other = lifecycle(&e, eager());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    assert!(lc.pause(inst.id).await.unwrap());

    let held = e.hold().await;
    let first = {
        let lc = lc.clone();
        tokio::spawn(async move { lc.archive(inst.id).await })
    };
    held.await;
    // 另一个副本：手动归档、巡检都跳过，不另起上传。
    assert!(!other.archive(inst.id).await.unwrap());
    let report = other.sweep().await.unwrap();
    assert_eq!((report.archived, report.failed), (0, 0));
    assert_eq!(e.store.puts.load(Ordering::SeqCst), 1);

    e.release();
    assert!(first.await.unwrap().unwrap());
    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Archived);
    assert!(rt.archive_failed_at.is_none());
    assert!(rt.archive_pending.is_none());
    assert!(e.purge_queue().await.is_empty());
    let woke = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(
        e.read(woke.sandbox_id.as_deref().unwrap(), "workspace/notes.txt")
            .await
            .unwrap(),
        b"keep me"
    );
}

/// 手动归档时（打包上传不锁实例）实例被用了：这次归档作废，沙箱和期间的改动都留着，传上去的对象排进清理队列。
#[tokio::test]
async fn use_during_an_archive_cancels_it() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let lc = Arc::new(lifecycle(&e, LifecycleConfig::default()));
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"before").await;

    let held = e.hold().await;
    let task = {
        let lc = lc.clone();
        tokio::spawn(async move { lc.archive(inst.id).await })
    };
    held.await;
    let rt = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(rt.sandbox_id.as_deref(), Some(sid.as_str()));
    e.write(&sid, "workspace/notes.txt", b"after").await;
    e.release();
    assert!(!task.await.unwrap().unwrap(), "the archive is dropped");

    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Running);
    assert_eq!(rt.sandbox_id.as_deref(), Some(sid.as_str()));
    assert!(rt.archive.is_none());
    assert!(
        rt.archive_failed_at.is_none(),
        "a dropped archive is no failure"
    );
    assert_eq!(e.read(&sid, "workspace/notes.txt").await.unwrap(), b"after");
    assert_eq!(e.purge_queue().await.len(), 1);
}

/// 换版本时两个唤醒一起来（运行、预热）：只有一个去存工作区，另一个等着，最后拿到同一个新沙箱，
/// 不会拿到要删掉的旧沙箱。
#[tokio::test]
async fn concurrent_wakes_share_one_rebuild() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let lc = Arc::new(lifecycle(&e, LifecycleConfig::default()));
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let old = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&old, "workspace/notes.txt", b"keep me").await;
    e.request_current_version(inst.id).await;

    let held = e.hold().await;
    let wake = || {
        let lc = lc.clone();
        tokio::spawn(async move { lc.ensure_running(inst.id).await })
    };
    let first = wake();
    held.await;
    let second = wake();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!second.is_finished(), "the second wake waits for the save");
    e.release();
    let a = first.await.unwrap().unwrap();
    let b = second.await.unwrap().unwrap();
    assert_eq!(a.sandbox_id, b.sandbox_id);
    let new = a.sandbox_id.unwrap();
    assert_ne!(new, old);
    assert!(!b.rebuild_pending);
    assert_eq!(e.store.puts.load(Ordering::SeqCst), 1);
    assert_eq!(e.provider.get(&SandboxId(old)).await.unwrap(), None);
    assert_eq!(
        e.read(&new, "workspace/notes.txt").await.unwrap(),
        b"keep me"
    );
}

/// 放回到一半被取消（运行取消了）：新沙箱删掉、标记清掉，下次唤醒不用等。
#[tokio::test]
async fn cancelled_restores_clean_up_after_themselves() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let lc = Arc::new(lifecycle(&e, LifecycleConfig::default()));
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    assert!(lc.archive(inst.id).await.unwrap());

    let held = e.hold().await;
    let task = {
        let lc = lc.clone();
        tokio::spawn(async move { lc.ensure_running(inst.id).await })
    };
    held.await;
    assert!(e.runtime(inst.id).await.restoring.is_some());
    task.abort();
    let _ = task.await;
    e.store.hold.store(false, Ordering::SeqCst);
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while e.runtime(inst.id).await.restoring.is_some() || e.sandboxes() > 0 {
        assert!(
            std::time::Instant::now() < deadline,
            "the restore is cleaned up"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    let rt = tokio::time::timeout(Duration::from_secs(10), lc.ensure_running(inst.id))
        .await
        .expect("the next wake does not wait")
        .unwrap();
    assert_eq!(
        e.read(rt.sandbox_id.as_deref().unwrap(), "workspace/notes.txt")
            .await
            .unwrap(),
        b"keep me"
    );
    assert_eq!(e.sandboxes(), 1);
}

/// 要的就是沙箱现在的版本（重建修故障、换过去又换回来），工作区又存不下：不重建了，接着用现在的沙箱，
/// 不会每次运行都失败。
#[tokio::test]
async fn same_version_requests_keep_the_sandbox_when_the_workspace_cannot_be_saved() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, LifecycleConfig::default());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    e.store.fail_put.store(true, Ordering::SeqCst);
    e.request_current_version(inst.id).await;
    for _ in 0..2 {
        let rt = lc.ensure_running(inst.id).await.unwrap();
        assert_eq!(rt.sandbox_id.as_deref(), Some(sid.as_str()));
        assert!(!rt.rebuild_pending);
    }
    assert_eq!(
        e.read(&sid, "workspace/notes.txt").await.unwrap(),
        b"keep me"
    );
    let skipped: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_log WHERE action = 'instance.rebuild.skipped' AND target = $1",
    )
    .bind(inst.id.to_string())
    .fetch_one(e.t.db.pool())
    .await
    .unwrap();
    assert_eq!(skipped, 1);
}

/// 上传时实例被删除、回收了（待定的对象排进清理队列时还没传上去）：传完发现没人要，自己删掉对象。
#[tokio::test]
async fn uploads_finished_after_a_purge_are_deleted() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let lc = Arc::new(lifecycle(&e, LifecycleConfig::default()));
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"secret").await;

    let held = e.hold().await;
    let task = {
        let lc = lc.clone();
        tokio::spawn(async move { lc.archive(inst.id).await })
    };
    held.await;
    let key = e.runtime(inst.id).await.archive_pending.unwrap();
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.delete_instance(inst.id).await.unwrap();
    t.commit().await.unwrap();
    assert_eq!(
        lifecycle(&e, LifecycleConfig::default())
            .sweep()
            .await
            .unwrap()
            .purged,
        1
    );
    // 后台的清理先跑了一遍（对象还没传上去，什么都没删到）。
    assert_eq!(e.purge_queue().await, std::slice::from_ref(&key));
    e.release();
    let _ = task.await.unwrap();
    assert!(!e.store.objects.lock().unwrap().contains_key(&key));
    assert!(e.store.deleted.lock().unwrap().contains(&key));
}

/// 存好了、删沙箱失败：不算归档失败（下一轮巡检直接删，不用再存），换版本也不会因此退回旧版本。
#[tokio::test]
async fn failed_deletes_after_a_save_are_retried_without_saving_again() {
    let Some(e) = env().await else { return };
    let flaky = Flaky::new(e.provider.clone());
    let lc = Lifecycle::new(
        e.t.db.clone(),
        flaky.clone(),
        Arc::new(BuiltinTemplates),
        eager(),
    )
    .with_workspace_store(e.store.clone());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;

    flaky.fail_destroy.store(true, Ordering::SeqCst);
    let report = lc.sweep().await.unwrap();
    assert_eq!((report.paused, report.archived, report.failed), (1, 0, 1));
    let rt = e.runtime(inst.id).await;
    assert_eq!(rt.state, InstanceState::Paused);
    assert!(rt.archive.is_some(), "the workspace is saved");
    assert!(
        rt.archive_failed_at.is_none(),
        "a failed delete is no failed save"
    );
    assert!(e.read_paused(&sid).await);

    let report = lc.sweep().await.unwrap();
    assert_eq!((report.archived, report.failed), (1, 0));
    assert_eq!(e.store.puts.load(Ordering::SeqCst), 1, "not saved again");
    assert_eq!(e.runtime(inst.id).await.state, InstanceState::Archived);
}

/// 存好、删沙箱删到一半被打断（运行取消、进程被杀）：归档已经记下了，下次唤醒从新的归档放回，期间的改动不丢。
#[tokio::test]
async fn interrupted_deletes_after_a_save_keep_the_new_archive() {
    let Some(e) = env().await else { return };
    let flaky = Flaky::new(e.provider.clone());
    let lc = Arc::new(
        Lifecycle::new(
            e.t.db.clone(),
            flaky.clone(),
            Arc::new(BuiltinTemplates),
            LifecycleConfig::default(),
        )
        .with_workspace_store(e.store.clone()),
    );
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"v1").await;
    assert!(lc.archive(inst.id).await.unwrap());
    let first = e.runtime(inst.id).await.archive.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"v2").await;

    flaky.stall_destroy.store(true, Ordering::SeqCst);
    let stalled = flaky.stalled.notified();
    let task = {
        let lc = lc.clone();
        tokio::spawn(async move { lc.archive(inst.id).await })
    };
    stalled.await;
    task.abort();
    let _ = task.await;
    let rt = e.runtime(inst.id).await;
    assert_ne!(
        rt.archive.unwrap().key,
        first.key,
        "the new archive is recorded"
    );

    let woke = lc.ensure_running(inst.id).await.unwrap();
    assert_eq!(
        e.read(woke.sandbox_id.as_deref().unwrap(), "workspace/notes.txt")
            .await
            .unwrap(),
        b"v2"
    );
}

/// 归档打包到一半被打断：为打包恢复的沙箱暂停回去、待定的上传清掉，下一次归档马上能做。停机时等得到这个收拾
/// 任务（多线程运行时下，被中止的任务派出的收拾任务和关连接池抢时间）。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn interrupted_saves_clean_up_after_themselves() {
    let Some(e) = env().await else { return };
    let e = Arc::new(e);
    let lc = Arc::new(lifecycle(&e, LifecycleConfig::default()));
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"keep me").await;
    assert!(lc.pause(inst.id).await.unwrap());

    let held = e.hold().await;
    let task = {
        let lc = lc.clone();
        tokio::spawn(async move { lc.archive(inst.id).await })
    };
    held.await;
    assert!(!e.read_paused(&sid).await, "resumed for the export");
    // 守着的归档还在做：停机时等得到它（等到上限）。
    let started = std::time::Instant::now();
    lc.pending_cleanups().wait(Duration::from_millis(300)).await;
    assert!(started.elapsed() >= Duration::from_millis(300));
    task.abort();
    let _ = task.await;
    e.store.hold.store(false, Ordering::SeqCst);
    lc.pending_cleanups().wait(Duration::from_secs(10)).await;
    assert!(e.runtime(inst.id).await.archive_pending.is_none());
    assert!(e.read_paused(&sid).await);
    assert_eq!(e.purge_queue().await.len(), 1);

    let archived = tokio::time::timeout(Duration::from_secs(10), lc.archive(inst.id))
        .await
        .expect("the next archive does not wait for the old mark to expire")
        .unwrap();
    assert!(archived);
}

/// 库里暂停着、沙箱其实在跑（上次归档被打断留下的）：这次归档没成也暂停回去，不一直按运行收费。
#[tokio::test]
async fn failed_saves_pause_a_sandbox_left_running() {
    let Some(e) = env().await else { return };
    let lc = lifecycle(&e, LifecycleConfig::default());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    let sid = lc
        .ensure_running(inst.id)
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    assert!(lc.pause(inst.id).await.unwrap());
    e.provider.resume(&SandboxId(sid.clone())).await.unwrap();
    assert!(!e.read_paused(&sid).await);
    e.store.fail_put.store(true, Ordering::SeqCst);
    assert!(lc.archive(inst.id).await.is_err());
    assert!(e.read_paused(&sid).await);
    assert_eq!(e.runtime(inst.id).await.state, InstanceState::Paused);
}

/// 存好了、删沙箱时库连接断了（换版本的唤醒）：归档已经记下，不算存失败，不退回旧版本；下次唤醒照常换过去，
/// 期间的改动都在。
#[tokio::test]
async fn database_errors_after_a_save_do_not_undo_a_version_change() {
    let Some(e) = env().await else { return };
    let flaky = Flaky::new(e.provider.clone());
    let lc = Lifecycle::new(
        e.t.db.clone(),
        flaky.clone(),
        Arc::new(TwoVersions),
        LifecycleConfig::default(),
    )
    .with_workspace_store(e.store.clone());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    lc.ensure_running(inst.id).await.unwrap();
    let old = lc.rebuild(inst.id, Some(OLD)).await.unwrap();
    let sid = old.sandbox_id.unwrap();
    e.write(&sid, "workspace/notes.txt", b"v2").await;

    e.request_current_version(inst.id).await;
    *flaky.drop_connections.lock().unwrap() = Some(e.t.db.pool().clone());
    assert!(lc.ensure_running(inst.id).await.is_err());
    let rt = e.runtime(inst.id).await;
    assert!(rt.archive_failed_at.is_none(), "the save did not fail");
    assert!(rt.rebuild_pending, "the version change is still wanted");

    let rt = lc.ensure_running(inst.id).await.unwrap();
    let current = catalog::builtin("pi").unwrap().agent.version;
    assert_eq!(rt.agent_version, current);
    assert_eq!(rt.sandbox_version.as_deref(), Some(current.as_str()));
    assert!(!rt.rebuild_pending);
    assert_eq!(
        e.read(rt.sandbox_id.as_deref().unwrap(), "workspace/notes.txt")
            .await
            .unwrap(),
        b"v2"
    );
    let kept: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_log WHERE action = 'instance.version.kept' AND target = $1",
    )
    .bind(inst.id.to_string())
    .fetch_one(e.t.db.pool())
    .await
    .unwrap();
    assert_eq!(kept, 0);
}

/// 换版本时上次已经存好、只差删沙箱（暂停着，走直接删）：删完库连接断了，也不退回旧版本，下次唤醒照常换过去。
#[tokio::test]
async fn database_errors_in_the_delete_only_path_do_not_undo_a_version_change() {
    let Some(e) = env().await else { return };
    let flaky = Flaky::new(e.provider.clone());
    let lc = Lifecycle::new(
        e.t.db.clone(),
        flaky.clone(),
        Arc::new(TwoVersions),
        LifecycleConfig::default(),
    )
    .with_workspace_store(e.store.clone());
    let inst = lc.adopt(e.user, "user:d", "pi", None, "Pi").await.unwrap();
    lc.ensure_running(inst.id).await.unwrap();
    let sid = lc
        .rebuild(inst.id, Some(OLD))
        .await
        .unwrap()
        .sandbox_id
        .unwrap();
    e.write(&sid, "workspace/notes.txt", b"v2").await;
    assert!(lc.pause(inst.id).await.unwrap());
    // 存好了、删沙箱失败：暂停着，归档是最新的。
    flaky.fail_destroy.store(true, Ordering::SeqCst);
    assert!(lc.archive(inst.id).await.is_err());
    let puts = e.store.puts.load(Ordering::SeqCst);

    e.request_current_version(inst.id).await;
    *flaky.drop_connections.lock().unwrap() = Some(e.t.db.pool().clone());
    assert!(lc.ensure_running(inst.id).await.is_err());
    assert!(e.runtime(inst.id).await.rebuild_pending);

    let rt = lc.ensure_running(inst.id).await.unwrap();
    let current = catalog::builtin("pi").unwrap().agent.version;
    assert_eq!(rt.agent_version, current);
    assert!(!rt.rebuild_pending);
    assert_eq!(e.store.puts.load(Ordering::SeqCst), puts, "not saved again");
    assert_eq!(
        e.read(rt.sandbox_id.as_deref().unwrap(), "workspace/notes.txt")
            .await
            .unwrap(),
        b"v2"
    );
    let kept: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM audit_log WHERE action = 'instance.version.kept' AND target = $1",
    )
    .bind(inst.id.to_string())
    .fetch_one(e.t.db.pool())
    .await
    .unwrap();
    assert_eq!(kept, 0);
}
