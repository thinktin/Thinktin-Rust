//! 产出物索引（8.4）。内容在对象存储里（按用户 DEK 加密），这里只记元数据和存储键。

use chrono::{DateTime, Utc};
use proto::domain::{Artifact, ArtifactId, InstanceId, RunId, UserId};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, signed, unsigned};

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    user_id: Uuid,
    instance_id: Uuid,
    run_id: Uuid,
    root_run_id: Uuid,
    name: String,
    version: i32,
    content_type: String,
    size: i64,
    sha256: Vec<u8>,
    blob_key: String,
    created_at: DateTime<Utc>,
}

/// 产出物和它在对象存储里的位置（只给平台内部用）。
#[derive(Debug, Clone, PartialEq)]
pub struct StoredArtifact {
    pub artifact: Artifact,
    pub user_id: UserId,
    pub blob_key: String,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl Row {
    fn into_stored(self) -> Result<StoredArtifact> {
        Ok(StoredArtifact {
            artifact: Artifact {
                id: self.id.into(),
                instance_id: self.instance_id.into(),
                run_id: self.run_id.into(),
                root_run_id: self.root_run_id.into(),
                name: self.name,
                version: u32::try_from(self.version)
                    .map_err(|_| Error::Corrupt("artifact version".into()))?,
                content_type: self.content_type,
                size: unsigned(self.size, "artifact size")?,
                sha256: hex(&self.sha256),
                created_at: self.created_at,
            },
            user_id: self.user_id.into(),
            blob_key: self.blob_key,
        })
    }
}

macro_rules! columns {
    () => {
        "id, user_id, instance_id, run_id, root_run_id, name, version, content_type, size, sha256, blob_key, created_at"
    };
}

/// 新发布的产出物（内容已经写进对象存储）。
#[derive(Debug, Clone)]
pub struct NewArtifact<'a> {
    pub id: ArtifactId,
    pub user: UserId,
    pub instance: InstanceId,
    pub run: RunId,
    pub root: RunId,
    pub name: &'a str,
    pub content_type: &'a str,
    pub size: u64,
    pub sha256: &'a [u8; 32],
    pub blob_key: &'a str,
}

/// 一棵运行树最多多少个产出物（含历史版本）。
pub const MAX_TREE_ARTIFACTS: i64 = 1000;
/// 列产出物时最多列这么多条。
pub const MAX_LISTED_ARTIFACTS: i64 = 500;
/// 一个范围下面最多看这么多个问题里的产出物。
const MAX_VISIBLE_SCOPES: i64 = 200;

/// 一个运行的产出物范围（8.11）。回答队友问题的运行（和它下面委派的）发布的记在这个问题里，只看得到这个问题
/// 里的；别的运行记在运行树的根上。各自还看得到下面各个问题（含问题里再问的）的回答方发布的：提问方看得到
/// 回答方的，回答方看不到提问方的。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtifactScope {
    /// 发布的记在这里：最近的回答问题的运行（可以是自己），没有就是运行树的根。
    pub own: RunId,
    /// 看得到哪些范围：自己的在前。
    pub visible: Vec<RunId>,
}

impl Tx<Worker> {
    /// 待清理的产出物密文（产出物记录删掉时由触发器排进来）。
    pub async fn blob_purge_batch(&mut self, limit: i64) -> Result<Vec<String>> {
        Ok(sqlx::query_scalar(
            "SELECT blob_key FROM blob_purge ORDER BY queued_at LIMIT $1 FOR UPDATE SKIP LOCKED",
        )
        .bind(limit)
        .fetch_all(self.conn())
        .await?)
    }

    /// 对象存储里已经删掉的，移出队列。
    pub async fn forget_blob_purge(&mut self, keys: &[String]) -> Result<()> {
        sqlx::query("DELETE FROM blob_purge WHERE blob_key = ANY($1)")
            .bind(keys)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 登记产出物，版本号在这棵运行树里同名的基础上加一。
    pub async fn insert_artifact(&mut self, a: &NewArtifact<'_>) -> Result<StoredArtifact> {
        // 同一棵树、同一个名字的发布串行化，版本号不会撞。
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("artifact:{}:{}", a.root, a.name))
            .execute(self.conn())
            .await?;
        // 一棵运行树里的产出物（含历史版本）有上限：agent 不能无限发布，把列表接口撑爆。
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM artifacts WHERE root_run_id = $1")
            .bind(a.root.0)
            .fetch_one(self.conn())
            .await?;
        if n >= MAX_TREE_ARTIFACTS {
            return Err(Error::Invalid(format!(
                "a run tree can hold at most {MAX_TREE_ARTIFACTS} artifacts (versions included)"
            )));
        }
        let row: Row = sqlx::query_as(concat!(
            "INSERT INTO artifacts (id, user_id, instance_id, run_id, root_run_id, name, version, content_type, \
               size, sha256, blob_key) \
             VALUES ($1, $2, $3, $4, $5, $6, \
               (SELECT coalesce(max(version), 0) + 1 FROM artifacts WHERE root_run_id = $5 AND name = $6), \
               $7, $8, $9, $10) RETURNING ",
            columns!()
        ))
        .bind(a.id.0)
        .bind(a.user.0)
        .bind(a.instance.0)
        .bind(a.run.0)
        .bind(a.root.0)
        .bind(a.name)
        .bind(a.content_type)
        .bind(signed(a.size, "size")?)
        .bind(&a.sha256[..])
        .bind(a.blob_key)
        .fetch_one(self.conn())
        .await?;
        row.into_stored()
    }
}

/// 两种角色都能用；业务角色下 RLS 只放行当前用户的产出物。
impl<R> Tx<R> {
    pub async fn artifact(&mut self, id: ArtifactId) -> Result<StoredArtifact> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM artifacts WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_stored()
    }

    /// 一个运行的产出物范围（8.11）：发布的记在哪、看得到哪些范围的。
    pub async fn artifact_scope(&mut self, run: RunId) -> Result<ArtifactScope> {
        let (own, asks): (Uuid, Vec<Uuid>) = sqlx::query_as(
            "WITH RECURSIVE chain AS ( \
               SELECT id, source, parent_run_id, root_run_id, 0 AS depth FROM runs WHERE id = $1 \
               UNION ALL \
               SELECT r.id, r.source, r.parent_run_id, r.root_run_id, c.depth + 1 \
               FROM runs r JOIN chain c ON r.id = c.parent_run_id WHERE c.depth < 64), \
             own AS ( \
               SELECT coalesce((SELECT id FROM chain WHERE source = 'ask' ORDER BY depth LIMIT 1), \
                               (SELECT root_run_id FROM chain WHERE depth = 0)) AS id), \
             below AS ( \
               SELECT r.id, r.source, 1 AS depth FROM runs r, own WHERE r.parent_run_id = own.id \
               UNION ALL \
               SELECT r.id, r.source, b.depth + 1 FROM runs r JOIN below b ON r.parent_run_id = b.id \
               WHERE b.depth < 64) \
             SELECT (SELECT id FROM own), \
                    ARRAY(SELECT id FROM below WHERE source = 'ask' ORDER BY id LIMIT $2)",
        )
        .bind(run.0)
        .bind(MAX_VISIBLE_SCOPES)
        .fetch_one(self.conn())
        .await?;
        let own: RunId = own.into();
        let mut visible = vec![own];
        visible.extend(asks.into_iter().map(RunId::from));
        Ok(ArtifactScope { own, visible })
    }

    /// 范围里看得到的产出物，每个范围里每个名字只取最新版本，按名字排（同名的自己的在前，`root_run_id`
    /// 看得出是哪个问题里的），最多 [`MAX_LISTED_ARTIFACTS`] 条（自己的先列）。
    pub async fn tree_artifacts(&mut self, scope: &ArtifactScope) -> Result<Vec<StoredArtifact>> {
        let ids: Vec<Uuid> = scope.visible.iter().map(|r| r.0).collect();
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT * FROM ( \
               SELECT DISTINCT ON (root_run_id, name) ",
            columns!(),
            "  FROM artifacts WHERE root_run_id = ANY($1) \
               ORDER BY root_run_id, name, version DESC) a \
             ORDER BY root_run_id <> $2, name, root_run_id LIMIT $3"
        ))
        .bind(&ids)
        .bind(scope.own.0)
        .bind(MAX_LISTED_ARTIFACTS)
        .fetch_all(self.conn())
        .await?;
        let mut out: Vec<StoredArtifact> = rows
            .into_iter()
            .map(Row::into_stored)
            .collect::<Result<_>>()?;
        // 稳定排序：同名的自己的还在前面。
        out.sort_by(|a, b| a.artifact.name.cmp(&b.artifact.name));
        Ok(out)
    }

    /// 范围里某个名字的最新版本（或指定版本）。同名的先用自己范围里的；要别的用 [`Tx::scoped_artifact`]。
    pub async fn named_artifact(
        &mut self,
        scope: &ArtifactScope,
        name: &str,
        version: Option<u32>,
    ) -> Result<StoredArtifact> {
        let ids: Vec<Uuid> = scope.visible.iter().map(|r| r.0).collect();
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM artifacts WHERE root_run_id = ANY($1) \
               AND name = $2 AND ($3::int IS NULL OR version = $3) \
             ORDER BY root_run_id = $4 DESC, version DESC LIMIT 1"
        ))
        .bind(&ids)
        .bind(name)
        .bind(version.map(|v| i32::try_from(v).unwrap_or(i32::MAX)))
        .bind(scope.own.0)
        .fetch_one(self.conn())
        .await?;
        row.into_stored()
    }

    /// 范围里看得到的某一个产出物（按 id，同名的里挑一个用）。看不到的当没有。
    pub async fn scoped_artifact(
        &mut self,
        scope: &ArtifactScope,
        id: ArtifactId,
    ) -> Result<StoredArtifact> {
        let a = self.artifact(id).await?;
        if !scope.visible.contains(&a.artifact.root_run_id) {
            return Err(Error::NotFound);
        }
        Ok(a)
    }
}

impl<R> Tx<R> {
    /// 某几个运行发布的产出物（交接时取上游步骤的、查进度时列出来的），每个名字只取最新版本。
    /// 业务角色按行级安全只看得到自己的。
    pub async fn run_artifacts(&mut self, runs: &[RunId]) -> Result<Vec<StoredArtifact>> {
        let ids: Vec<Uuid> = runs.iter().map(|r| r.0).collect();
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT DISTINCT ON (name) ",
            columns!(),
            " FROM artifacts WHERE run_id = ANY($1) ORDER BY name, version DESC"
        ))
        .bind(&ids)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_stored).collect()
    }
}

impl Tx<Tenant> {
    /// 实例上的产出物，新的在前。
    pub async fn instance_artifacts(
        &mut self,
        instance: InstanceId,
        limit: i64,
    ) -> Result<Vec<Artifact>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM artifacts WHERE instance_id = $1 ORDER BY created_at DESC LIMIT $2"
        ))
        .bind(instance.0)
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|r| Ok(r.into_stored()?.artifact))
            .collect()
    }

    /// 删除一个产出物，返回它的存储键（调用方删对象存储里的内容）。
    pub async fn delete_artifact(&mut self, id: ArtifactId) -> Result<String> {
        let key: Option<String> =
            sqlx::query_scalar("DELETE FROM artifacts WHERE id = $1 RETURNING blob_key")
                .bind(id.0)
                .fetch_optional(self.conn())
                .await?;
        key.ok_or(Error::NotFound)
    }
}
