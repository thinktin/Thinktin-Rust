//! 工作区归档：没有卷的后端（本地后端的无卷模式，和 ACS 一样）+ 内存里的归档存储 + 真实 Postgres
//! （没有 DATABASE_URL 时跳过）。打包、解包用宿主机上的 GNU tar。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use catalog::Manifest;
use control::{
    ArchiveMeta, BuiltinTemplates, Error, Lifecycle, LifecycleConfig, Templates, WorkspaceStore,
};
use proto::domain::{
    CatchUp, InstanceId, InstanceState, PlanAuthor, PlanPolicy, ScheduleSpec, UserId,
};
use sandbox::local::LocalProvider;
use sandbox::{CreateSpec, SandboxId, SandboxProvider, SandboxState};
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
    ) -> Result<ArchiveMeta, String> {
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

/// 放回工作区时不锁实例，先记下新沙箱：别处的唤醒等着；放了太久（进程中途被杀）就当没人管了，删掉那个沙箱。
#[tokio::test]
async fn unfinished_restores_are_waited_for_then_cleaned_up() {
    let Some(e) = env().await else { return };
    // 放回最多 2 × 1 + 3 × 1 秒，过了就算没人管。
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
        started.elapsed() >= Duration::from_secs(4),
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

    // 巡检也会清：记下的时间早于放回的上限。
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
