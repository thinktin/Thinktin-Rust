//! 工作区归档放进对象存储：按用户 DEK 分块加密，只有密文落盘；挪到别的用户、别的归档 id 下，
//! 或者对象被改过，都放不回来（真实 Postgres，没有 DATABASE_URL 时跳过）。

use std::sync::Arc;
use std::time::Duration;

use control::WorkspaceStore;
use keyvault::LocalKms;
use orchestrator::artifacts::LocalBlobStore;
use orchestrator::workspaces::ObjectWorkspaceStore;
use proto::domain::UserId;
use store::WorkspaceArchive;
use store::testing::TestDb;

struct Env {
    _t: TestDb,
    blobs: tempfile::TempDir,
    temp: tempfile::TempDir,
    store: ObjectWorkspaceStore,
    alice: UserId,
    bob: UserId,
}

async fn env() -> Option<Env> {
    let t = TestDb::new().await?;
    let blobs = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let store = ObjectWorkspaceStore::new(
        t.db.clone(),
        Arc::new(LocalBlobStore::new(blobs.path()).unwrap()),
        Arc::new(LocalKms::new("kms", &[9; 32])),
        temp.path(),
        Duration::from_secs(30),
    );
    let mut w = t.db.worker().await.unwrap();
    let (alice, _) = w.upsert_user_by_phone("+8613800000011").await.unwrap();
    let (bob, _) = w.upsert_user_by_phone("+8613800000012").await.unwrap();
    w.commit().await.unwrap();
    Some(Env {
        _t: t,
        blobs,
        temp,
        store,
        alice: alice.id,
        bob: bob.id,
    })
}

impl Env {
    async fn put(&self, user: UserId, data: &[u8]) -> Result<WorkspaceArchive, String> {
        let id = uuid::Uuid::now_v7();
        let key = self.store.key(user, "ws-1", id);
        let mut reader = data;
        let meta = self.store.put(user, &key, id, &mut reader, 8 << 20).await?;
        Ok(WorkspaceArchive {
            key,
            id: meta.id,
            bytes: meta.bytes,
            sha256: meta.sha256,
            archived_at: chrono::Utc::now(),
        })
    }

    async fn restore(&self, user: UserId, a: &WorkspaceArchive) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        self.store.restore(user, a, &mut out).await?;
        Ok(out)
    }

    fn object(&self, a: &WorkspaceArchive) -> std::path::PathBuf {
        self.blobs.path().join(&a.key)
    }

    fn temp_files(&self) -> usize {
        std::fs::read_dir(self.temp.path()).unwrap().count()
    }
}

#[tokio::test]
async fn archives_round_trip_encrypted() {
    let Some(e) = env().await else { return };
    let big: Vec<u8> = (0..(5 << 20) / 2).map(|i: u32| (i % 251) as u8).collect();
    for len in [0, 1, 1 << 20, big.len()] {
        let plain = &big[..len];
        let a = e.put(e.alice, plain).await.unwrap();
        assert_eq!(a.bytes, len as u64);
        assert!(a.key.starts_with("workspaces/"), "{}", a.key);
        assert_eq!(e.restore(e.alice, &a).await.unwrap(), plain, "{len}");
        // 对象存储里是密文。
        let stored = std::fs::read(e.object(&a)).unwrap();
        if len > 64 {
            assert!(!stored.windows(64).any(|w| w == &plain[..64]));
        }
    }
    assert_eq!(e.temp_files(), 0, "temp files are removed");
}

#[tokio::test]
async fn tampered_or_moved_archives_do_not_restore() {
    let Some(e) = env().await else { return };
    let data: Vec<u8> = (0..300_000u32).map(|i| (i % 7) as u8).collect();
    let a = e.put(e.alice, &data).await.unwrap();

    // 别的用户、别的归档 id、记录的大小或摘要不对。
    assert!(e.restore(e.bob, &a).await.is_err());
    let other_id = WorkspaceArchive {
        id: uuid::Uuid::now_v7(),
        ..a.clone()
    };
    assert!(e.restore(e.alice, &other_id).await.is_err());
    let wrong_sha = WorkspaceArchive {
        sha256: [0; 32],
        ..a.clone()
    };
    assert!(e.restore(e.alice, &wrong_sha).await.is_err());

    // 对象被改了一个字节、被截断。
    let path = e.object(&a);
    let good = std::fs::read(&path).unwrap();
    let mut bad = good.clone();
    bad[100] ^= 1;
    std::fs::write(&path, &bad).unwrap();
    assert!(e.restore(e.alice, &a).await.is_err());
    std::fs::write(&path, &good[..good.len() - 3]).unwrap();
    assert!(e.restore(e.alice, &a).await.is_err());
    std::fs::write(&path, &good).unwrap();
    assert_eq!(e.restore(e.alice, &a).await.unwrap(), data);
    assert_eq!(e.temp_files(), 0);
}

#[tokio::test]
async fn oversized_archives_are_refused() {
    let Some(e) = env().await else { return };
    let id = uuid::Uuid::now_v7();
    let key = e.store.key(e.alice, "ws-1", id);
    let data = vec![1u8; 3 << 20];
    let mut reader = &data[..];
    let err = e
        .store
        .put(e.alice, &key, id, &mut reader, 2 << 20)
        .await
        .unwrap_err();
    assert!(err.contains("larger than"), "{err}");
    assert!(!e.blobs.path().join(&key).exists(), "nothing is uploaded");
    assert_eq!(e.temp_files(), 0);
}
