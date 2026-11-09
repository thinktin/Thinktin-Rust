//! 实例和它的模型别名（5.5、6.4）。

use std::net::IpAddr;
use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    CredentialId, EgressMode, Instance, InstanceId, InstanceLimits, InstanceState,
    MAX_ROUTE_FALLBACKS, ModelRoute, ProjectId, RouteFallback, RunState, UserId,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, from_json, parse, secs, to_json};

/// 新建实例。沙箱由实例生命周期管理（6.4）随后创建。
#[derive(Debug, Clone)]
pub struct NewInstance {
    pub agent_id: String,
    pub agent_version: String,
    pub harness: String,
    pub name: String,
    pub workspace_id: String,
    pub limits: InstanceLimits,
}

/// 后台看到的实例：带沙箱绑定，给生命周期管理、模型网关核对沙箱令牌用。
#[derive(Debug, Clone, PartialEq)]
pub struct InstanceRuntime {
    pub id: InstanceId,
    pub user_id: UserId,
    pub agent_id: String,
    pub agent_version: String,
    pub harness: String,
    pub state: InstanceState,
    pub sandbox_id: Option<String>,
    pub sandbox_address: Option<IpAddr>,
    pub workspace_id: String,
    pub snapshot_id: Option<String>,
    pub limits: InstanceLimits,
    pub last_active_at: DateTime<Utc>,
    /// 换了模板版本，下次唤醒时要按新版本重建沙箱。
    pub rebuild_pending: bool,
    /// 沙箱令牌的代数，签进令牌；运行的一次尝试结束时加一，旧令牌随之失效。
    pub token_epoch: u64,
    /// 最新的工作区归档（没有工作区卷的后端用，见 docs/sandbox-acs.md）。
    pub archive: Option<WorkspaceArchive>,
    /// 上一次归档失败的时间（之后成功归档会清掉）。
    pub archive_failed_at: Option<DateTime<Utc>>,
    /// 正在上传（或上传到一半没了下文）的归档对象。
    pub archive_pending: Option<String>,
    /// 当前沙箱是按哪个版本建的；以前建的沙箱没记，是 None。
    pub sandbox_version: Option<String>,
    /// 正在往这个沙箱里放回归档（还没绑定到实例）。
    pub restoring: Option<RestoringSandbox>,
    /// 专属于这个项目（8.16）：沙箱、工作区、归档（按项目 DEK）、agent 的 HOME 和会话都只属于这个项目。
    pub workspace_project_id: Option<ProjectId>,
}

/// 正在放回归档的新沙箱。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoringSandbox {
    pub sandbox_id: String,
    pub since: DateTime<Utc>,
}

/// 存在对象存储里的一份工作区归档（tar.gz，按用户 DEK 分块加密）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceArchive {
    pub key: String,
    /// 加密时进 AAD 的归档 id。
    pub id: Uuid,
    /// 明文（tar.gz）的大小和 SHA-256。
    pub bytes: u64,
    pub sha256: [u8; 32],
    pub archived_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    agent_id: String,
    agent_version: String,
    harness: String,
    name: String,
    state: String,
    created_at: DateTime<Utc>,
    last_active_at: DateTime<Utc>,
    purpose: String,
    peer_access: bool,
    egress_mode: String,
    egress_hosts: Vec<String>,
    workspace_project_id: Option<Uuid>,
}

impl Row {
    fn into_instance(self) -> Result<Instance> {
        Ok(Instance {
            id: self.id.into(),
            agent_id: self.agent_id,
            agent_version: self.agent_version,
            harness: self.harness,
            name: self.name,
            state: parse(&self.state)?,
            created_at: self.created_at,
            last_active_at: self.last_active_at,
            purpose: self.purpose,
            peer_access: self.peer_access,
            egress_mode: parse(&self.egress_mode)?,
            egress_hosts: self.egress_hosts,
            dedicated_project_id: self.workspace_project_id.map(ProjectId),
        })
    }
}

macro_rules! columns {
    () => {
        "id, agent_id, agent_version, harness, name, state, created_at, last_active_at, purpose, peer_access, \
         egress_mode, egress_hosts, workspace_project_id"
    };
}

/// 改实例（App 的实例设置）：给了才改。
#[derive(Debug, Clone, Default)]
pub struct InstanceChange {
    pub name: Option<String>,
    /// 用途说明（8.9）。
    pub purpose: Option<String>,
    /// “允许其他 agent 查我、问我”（8.9）。
    pub peer_access: Option<bool>,
    /// 能上哪些网站和用户加的网站（2.7）：两个一起改，网站已经按 `proto::egress::normalize_host` 整理过。
    pub egress: Option<(EgressMode, Vec<String>)>,
}

/// 同一用户的另一个实例，`agents_list` 用（8.9）。
#[derive(Debug, Clone, PartialEq)]
pub struct Peer {
    pub instance: Instance,
    /// 占着实例的运行（在跑、等审批、等子任务……）的状态；没有就是空闲。
    pub holder: Option<RunState>,
}

#[derive(sqlx::FromRow)]
struct RuntimeRow {
    id: Uuid,
    user_id: Uuid,
    agent_id: String,
    agent_version: String,
    harness: String,
    state: String,
    sandbox_id: Option<String>,
    sandbox_address: Option<String>,
    workspace_id: String,
    snapshot_id: Option<String>,
    limits: serde_json::Value,
    last_active_at: DateTime<Utc>,
    rebuild_pending: bool,
    token_epoch: i64,
    workspace_archive_key: Option<String>,
    workspace_archive_id: Option<Uuid>,
    workspace_archive_bytes: Option<i64>,
    workspace_archive_sha256: Option<Vec<u8>>,
    workspace_archived_at: Option<DateTime<Utc>>,
    workspace_archive_failed_at: Option<DateTime<Utc>>,
    workspace_archive_pending: Option<String>,
    sandbox_version: Option<String>,
    restoring_sandbox_id: Option<String>,
    restoring_since: Option<DateTime<Utc>>,
    workspace_project_id: Option<Uuid>,
}

impl RuntimeRow {
    fn into_runtime(self) -> Result<InstanceRuntime> {
        let archive = match (
            self.workspace_archive_key,
            self.workspace_archive_id,
            self.workspace_archive_bytes,
            self.workspace_archive_sha256,
            self.workspace_archived_at,
        ) {
            (Some(key), Some(id), Some(bytes), Some(sha), Some(archived_at)) => {
                Some(WorkspaceArchive {
                    key,
                    id,
                    bytes: u64::try_from(bytes)
                        .map_err(|_| Error::Invalid("negative archive size".into()))?,
                    sha256: sha
                        .try_into()
                        .map_err(|_| Error::Invalid("bad archive digest".into()))?,
                    archived_at,
                })
            }
            _ => None,
        };
        Ok(InstanceRuntime {
            id: self.id.into(),
            user_id: self.user_id.into(),
            agent_id: self.agent_id,
            agent_version: self.agent_version,
            harness: self.harness,
            state: parse(&self.state)?,
            sandbox_id: self.sandbox_id,
            sandbox_address: self.sandbox_address.as_deref().map(parse).transpose()?,
            workspace_id: self.workspace_id,
            snapshot_id: self.snapshot_id,
            limits: from_json(self.limits, "instance limits")?,
            last_active_at: self.last_active_at,
            rebuild_pending: self.rebuild_pending,
            token_epoch: u64::try_from(self.token_epoch).unwrap_or_default(),
            archive,
            archive_failed_at: self.workspace_archive_failed_at,
            archive_pending: self.workspace_archive_pending,
            sandbox_version: self.sandbox_version,
            restoring: match (self.restoring_sandbox_id, self.restoring_since) {
                (Some(sandbox_id), Some(since)) => Some(RestoringSandbox { sandbox_id, since }),
                _ => None,
            },
            workspace_project_id: self.workspace_project_id.map(ProjectId),
        })
    }
}

macro_rules! runtime_columns {
    () => {
        "id, user_id, agent_id, agent_version, harness, state, sandbox_id, \
         host(sandbox_address) AS sandbox_address, workspace_id, snapshot_id, limits, last_active_at, \
         rebuild_pending, token_epoch, workspace_archive_key, workspace_archive_id, \
         workspace_archive_bytes, workspace_archive_sha256, workspace_archived_at, \
         workspace_archive_failed_at, workspace_archive_pending, sandbox_version, \
         restoring_sandbox_id, restoring_since, workspace_project_id"
    };
}

#[derive(sqlx::FromRow)]
struct RouteRow {
    alias: String,
    credential_id: Uuid,
    upstream_model: String,
}

/// 实例各别名的降级链（按顺序）。租户和模型网关两边共用。
pub(crate) async fn route_fallbacks(
    conn: &mut sqlx::PgConnection,
    instance: InstanceId,
) -> Result<std::collections::HashMap<String, Vec<RouteFallback>>> {
    let rows: Vec<RouteRow> = sqlx::query_as(
        "SELECT alias, credential_id, upstream_model FROM model_route_fallbacks \
         WHERE instance_id = $1 ORDER BY alias, position",
    )
    .bind(instance.0)
    .fetch_all(conn)
    .await?;
    let mut map: std::collections::HashMap<String, Vec<RouteFallback>> = Default::default();
    for r in rows {
        map.entry(r.alias).or_default().push(RouteFallback {
            credential_id: r.credential_id.into(),
            upstream_model: r.upstream_model,
        });
    }
    Ok(map)
}

impl Tx<Tenant> {
    /// 按用户加锁（到事务结束），再数没删除的实例（归档的也算）。领养前查上限用：并发领养的排着队数，
    /// 不会一起超过上限（11.9）。
    pub async fn lock_instance_count(&mut self) -> Result<u64> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("instances/{}", self.user()))
            .execute(self.conn())
            .await?;
        let n: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM instances WHERE user_id = app_user_id() AND state <> 'deleted'",
        )
        .fetch_one(self.conn())
        .await?;
        crate::unsigned(n, "instance count")
    }

    pub async fn create_instance(&mut self, new: &NewInstance) -> Result<Instance> {
        let row: Row = sqlx::query_as(concat!(
            "INSERT INTO instances (id, user_id, agent_id, agent_version, harness, name, workspace_id, limits) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6, $7) RETURNING ",
            columns!()
        ))
        .bind(InstanceId::new().0)
        .bind(&new.agent_id)
        .bind(&new.agent_version)
        .bind(&new.harness)
        .bind(&new.name)
        .bind(&new.workspace_id)
        .bind(to_json(&new.limits)?)
        .fetch_one(self.conn())
        .await?;
        row.into_instance()
    }

    /// 没删除的实例。
    pub async fn instance(&mut self, id: InstanceId) -> Result<Instance> {
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM instances WHERE id = $1 AND state <> 'deleted'"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_instance()
    }

    pub async fn instances(&mut self) -> Result<Vec<Instance>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM instances WHERE state <> 'deleted' ORDER BY created_at"
        ))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_instance).collect()
    }

    /// 改名字、用途说明、交流开关（给了才改）。实例删了是 NotFound。
    pub async fn update_instance(&mut self, id: InstanceId, change: &InstanceChange) -> Result<()> {
        let done = sqlx::query(
            "UPDATE instances SET name = coalesce($2, name), purpose = coalesce($3, purpose), \
               peer_access = coalesce($4, peer_access), egress_mode = coalesce($5, egress_mode), \
               egress_hosts = coalesce($6, egress_hosts), updated_at = now() \
             WHERE id = $1 AND state <> 'deleted'",
        )
        .bind(id.0)
        .bind(change.name.as_deref())
        .bind(change.purpose.as_deref())
        .bind(change.peer_access)
        .bind(change.egress.as_ref().map(|(m, _)| m.as_str()))
        .bind(change.egress.as_ref().map(|(_, h)| h.clone()))
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 从“一直允许”的网站里删掉一个（2.7；没有这个网站也算成功）。只删这一个，不会冲掉同时点的“一直允许”。
    pub async fn remove_egress_host(&mut self, id: InstanceId, host: &str) -> Result<Instance> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE instances SET egress_hosts = array_remove(egress_hosts, $2), updated_at = now() \
             WHERE id = $1 AND state <> 'deleted' RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(host)
        .fetch_optional(self.conn())
        .await?;
        row.ok_or(Error::NotFound)?.into_instance()
    }

    pub async fn rename_instance(&mut self, id: InstanceId, name: &str) -> Result<()> {
        let done = sqlx::query(
            "UPDATE instances SET name = $2, updated_at = now() WHERE id = $1 AND state <> 'deleted'",
        )
        .bind(id.0)
        .bind(name)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 换模板版本（升级或回滚）：记下新版本，下次唤醒时重建沙箱。版本是否存在由调用方核对。
    pub async fn request_instance_version(
        &mut self,
        id: InstanceId,
        version: &str,
    ) -> Result<Instance> {
        let row: Option<Row> = sqlx::query_as(concat!(
            "UPDATE instances SET agent_version = $2, rebuild_pending = true, updated_at = now() \
             WHERE id = $1 AND state <> 'deleted' RETURNING ",
            columns!()
        ))
        .bind(id.0)
        .bind(version)
        .fetch_optional(self.conn())
        .await?;
        row.ok_or(Error::NotFound)?.into_instance()
    }

    /// 用户删实例（接入网关的删除接口）：按固定的加锁顺序一步步来，改实例行之前先锁它所在的项目（D4）、再锁它的出网
    /// 请求（8.16：放回私人、标专属、用户回答出网请求都是先请求后实例），然后处理计划、停运行、吊销授权、标记删除。
    /// 共享项目里的 agent 行租户改不了，提交以后由 worker 撤下。找不到的 NotFound。
    pub async fn remove_instance(&mut self, id: InstanceId) -> Result<crate::RetiredPlans> {
        self.instance(id).await?;
        self.lock_instance_projects(id).await?;
        self.lock_instance_egress_requests(id).await?;
        let retired = self.retire_instance_plans(id).await?;
        self.cancel_instance_runs(id, "instance deleted").await?;
        self.revoke_instance_grants(id, "instance deleted").await?;
        self.delete_instance(id).await?;
        Ok(retired)
    }

    /// 标记删除。沙箱和工作区由后台的生命周期管理回收；模型别名和降级链一起删掉（已删除的实例的别名看不到也改不了，
    /// 留着会让它们指着的 key 删不掉）。实例的计划、运行、授权由调用方处理（接入网关的删除接口）。
    pub async fn delete_instance(&mut self, id: InstanceId) -> Result<()> {
        let done = sqlx::query(
            "UPDATE instances SET state = 'deleted', deleted_at = now(), updated_at = now() \
             WHERE id = $1 AND state <> 'deleted'",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        // 从项目里离开（运行记录还要引用这一行，只标记）；负责人位置空出来。
        sqlx::query(
            "UPDATE project_agents SET is_lead = false, left_at = now() \
             WHERE instance_id = $1 AND left_at IS NULL",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        // 降级链随主路由级联删除。
        sqlx::query("DELETE FROM model_routes WHERE instance_id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        // 还在等用户回答的出网请求（2.7）不用答了：标成过期，提醒的收件箱条目算已读（角标不留着）。
        sqlx::query(
            "WITH gone AS (UPDATE egress_requests SET status = 'expired' \
                           WHERE instance_id = $1 AND status = 'pending' RETURNING id) \
             UPDATE inbox_items SET read_at = now() \
             WHERE egress_request_id IN (SELECT id FROM gone) AND read_at IS NULL",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 整体替换实例的模型别名（连同各自的降级链）。凭证必须是自己的、没删除；新引用的不能是停用的，实例原来就用着的
    /// 停用 key 可以留着（网关照样跳过它），所以从别名里去掉别的 key 不会因为它保存不了。
    pub async fn set_model_routes(
        &mut self,
        instance: InstanceId,
        routes: &[ModelRoute],
    ) -> Result<()> {
        for route in routes {
            if route.fallbacks.len() > MAX_ROUTE_FALLBACKS {
                return Err(Error::Invalid(format!(
                    "at most {MAX_ROUTE_FALLBACKS} fallbacks per model alias"
                )));
            }
        }
        // 锁住实例行：并发替换时后到的等前一个提交，不会交错成两份的并集。
        self.instance_for_update(instance).await?;
        // 实例原来就用着的 key（主路由或降级链）：停用了也可以留着。
        let kept: std::collections::HashSet<Uuid> = sqlx::query_scalar::<_, Uuid>(
            "SELECT credential_id FROM model_routes WHERE instance_id = $1 \
             UNION SELECT credential_id FROM model_route_fallbacks WHERE instance_id = $1",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?
        .into_iter()
        .collect();
        // 备用项随主路由级联删除。
        sqlx::query("DELETE FROM model_routes WHERE instance_id = $1")
            .bind(instance.0)
            .execute(self.conn())
            .await?;
        for route in routes {
            self.lock_usable_credential(route.credential_id, kept.contains(&route.credential_id.0))
                .await?;
            sqlx::query(
                "INSERT INTO model_routes (instance_id, alias, user_id, credential_id, upstream_model) \
                 VALUES ($1, $2, app_user_id(), $3, $4)",
            )
            .bind(instance.0)
            .bind(&route.alias)
            .bind(route.credential_id.0)
            .bind(&route.upstream_model)
            .execute(self.conn())
            .await?;
            for (i, fb) in route.fallbacks.iter().enumerate() {
                self.lock_usable_credential(fb.credential_id, kept.contains(&fb.credential_id.0))
                    .await?;
                sqlx::query(
                    "INSERT INTO model_route_fallbacks \
                       (instance_id, alias, position, user_id, credential_id, upstream_model) \
                     VALUES ($1, $2, $3, app_user_id(), $4, $5)",
                )
                .bind(instance.0)
                .bind(&route.alias)
                .bind(i as i16 + 1)
                .bind(fb.credential_id.0)
                .bind(&fb.upstream_model)
                .execute(self.conn())
                .await?;
            }
        }
        sqlx::query("UPDATE instances SET updated_at = now() WHERE id = $1")
            .bind(instance.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    pub async fn model_routes(&mut self, instance: InstanceId) -> Result<Vec<ModelRoute>> {
        self.instance(instance).await?;
        let rows: Vec<RouteRow> = sqlx::query_as(
            "SELECT alias, credential_id, upstream_model FROM model_routes WHERE instance_id = $1 ORDER BY alias",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?;
        let mut fallbacks = route_fallbacks(self.conn(), instance).await?;
        Ok(rows
            .into_iter()
            .map(|r| ModelRoute {
                fallbacks: fallbacks.remove(&r.alias).unwrap_or_default(),
                alias: r.alias,
                credential_id: r.credential_id.into(),
                upstream_model: r.upstream_model,
            })
            .collect())
    }

    /// 路由要用的 key：自己的、没删除；`keep_disabled` 时（实例原来就用着）停用的也行。`FOR SHARE` 和删除 key 互斥，
    /// 检查之后不会被删掉。
    async fn lock_usable_credential(
        &mut self,
        id: CredentialId,
        keep_disabled: bool,
    ) -> Result<()> {
        let state: Option<(bool, bool)> = sqlx::query_as(
            "SELECT deleted_at IS NULL, disabled FROM credentials WHERE id = $1 FOR SHARE",
        )
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        match state {
            Some((true, false)) => Ok(()),
            Some((true, true)) if keep_disabled => Ok(()),
            Some((true, true)) => Err(Error::Invalid(format!("credential {id} is disabled"))),
            _ => Err(Error::Invalid(format!("credential {id} is not usable"))),
        }
    }

    async fn instance_for_update(&mut self, id: InstanceId) -> Result<()> {
        sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM instances WHERE id = $1 AND state <> 'deleted' FOR UPDATE",
        )
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        Ok(())
    }
}

impl Tx<Tenant> {
    /// 认识队友（8.9）：同一用户的其他实例里允许别人查、问的（没删除的），按名字排，带上占着它的运行的状态。
    pub async fn peers(&mut self, me: InstanceId) -> Result<Vec<Peer>> {
        #[derive(sqlx::FromRow)]
        struct PeerRow {
            #[sqlx(flatten)]
            row: Row,
            holder: Option<String>,
        }
        let rows: Vec<PeerRow> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            ", (SELECT r.state FROM runs r WHERE r.instance_id = instances.id AND r.kind = 'agent' \
                 AND r.project_id IS NULL \
                 AND r.state IN ('starting', 'running', 'waiting_approval', 'waiting_device', 'waiting_quota', \
                                 'waiting_children', 'backoff') LIMIT 1) AS holder \
             FROM instances WHERE state <> 'deleted' AND id <> $1 AND peer_access \
               AND workspace_project_id IS NULL ORDER BY name, id"
        ))
        .bind(me.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|r| {
                Ok(Peer {
                    instance: r.row.into_instance()?,
                    holder: r.holder.as_deref().map(parse).transpose()?,
                })
            })
            .collect()
    }

    /// 委派（8.7）：`lead` 当负责人的团队里的其他成员（没删除的实例），按名字排。
    pub async fn delegation_targets(&mut self, lead: InstanceId) -> Result<Vec<Instance>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM instances WHERE state <> 'deleted' AND id <> $1 AND user_id = app_user_id() \
               AND workspace_project_id IS NULL AND id IN ( \
               SELECT a.instance_id FROM project_agents a \
                WHERE a.left_at IS NULL AND a.user_id = app_user_id() AND a.project_id IN ( \
                  SELECT l.project_id FROM project_agents l JOIN projects p ON p.id = l.project_id \
                   WHERE l.instance_id = $1 AND l.is_lead AND l.left_at IS NULL \
                     AND p.creator_id = app_user_id() AND p.status = 'active')) \
             ORDER BY name, id"
        ))
        .bind(lead.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_instance).collect()
    }
}

impl Tx<Worker> {
    /// 实例是不是它主人自己的哪个团队（单人项目）的负责人（只有负责人能委派，8.7）。别人的项目里当负责人不算：私人运行
    /// 不能因此拿到委派工具。
    pub async fn is_team_lead(&mut self, instance: InstanceId) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM project_agents a JOIN projects p ON p.id = a.project_id \
               WHERE a.instance_id = $1 AND a.is_lead AND a.left_at IS NULL \
                 AND p.creator_id = a.user_id AND p.status = 'active')",
        )
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?)
    }
}

impl Tx<Worker> {
    /// 实例配置的模型别名（交给 agent 的模型列表）。
    pub async fn route_aliases(&mut self, id: InstanceId) -> Result<Vec<String>> {
        Ok(sqlx::query_scalar(
            "SELECT alias FROM model_routes WHERE instance_id = $1 ORDER BY alias",
        )
        .bind(id.0)
        .fetch_all(self.conn())
        .await?)
    }

    pub async fn instance_runtime(&mut self, id: InstanceId) -> Result<InstanceRuntime> {
        let row: RuntimeRow = sqlx::query_as(concat!(
            "SELECT ",
            runtime_columns!(),
            " FROM instances WHERE id = $1"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_runtime()
    }

    /// 生命周期管理更新实例的状态和沙箱绑定（6.4）。
    pub async fn set_instance_runtime(
        &mut self,
        id: InstanceId,
        state: InstanceState,
        sandbox_id: Option<&str>,
        sandbox_address: Option<IpAddr>,
        snapshot_id: Option<&str>,
    ) -> Result<()> {
        let done = sqlx::query(
            "UPDATE instances SET state = $2, sandbox_id = $3, sandbox_address = $4::inet, \
               snapshot_id = $5, updated_at = now(), \
               sandbox_version = CASE WHEN $3::text IS NULL THEN NULL ELSE sandbox_version END \
             WHERE id = $1",
        )
        .bind(id.0)
        .bind(state.as_str())
        .bind(sandbox_id)
        .bind(sandbox_address.map(|a| a.to_string()))
        .bind(snapshot_id)
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 让实例之前签出的沙箱令牌全部失效（运行的一次尝试结束时调用，和状态变更放在同一个事务里）。
    pub async fn bump_token_epoch(&mut self, id: InstanceId) -> Result<()> {
        sqlx::query("UPDATE instances SET token_epoch = token_epoch + 1 WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 锁住实例行再读（唤醒、暂停、重建这些操作串行化，多个副本不会同时给一个实例建沙箱）。
    pub async fn lock_instance(&mut self, id: InstanceId) -> Result<InstanceRuntime> {
        let row: RuntimeRow = sqlx::query_as(concat!(
            "SELECT ",
            runtime_columns!(),
            " FROM instances WHERE id = $1 FOR UPDATE"
        ))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        row.into_runtime()
    }

    /// 和 [`Self::lock_instance`] 一样，但别的事务锁着时不等，返回 None（巡检跳过正在被处理的实例）。
    pub async fn try_lock_instance(&mut self, id: InstanceId) -> Result<Option<InstanceRuntime>> {
        let row: Option<RuntimeRow> = sqlx::query_as(concat!(
            "SELECT ",
            runtime_columns!(),
            " FROM instances WHERE id = $1 FOR UPDATE SKIP LOCKED"
        ))
        .bind(id.0)
        .fetch_optional(self.conn())
        .await?;
        row.map(RuntimeRow::into_runtime).transpose()
    }

    /// 有正在执行的运行（启动中、运行中）：这时不能暂停或归档。
    pub async fn instance_busy(&mut self, id: InstanceId) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM runs WHERE instance_id = $1 AND state IN ('starting', 'running'))",
        )
        .bind(id.0)
        .fetch_one(self.conn())
        .await?)
    }

    /// 这段时间内有没有计划要触发（有就不归档，免得到点还要从模板重建）。
    /// 预热（6.5）：`within` 之内有计划要触发、现在暂停或归档着的实例（归档的要从模板重建、放回工作区，
    /// 更要提前）。包括计划自己的实例，和流水线里第一批（没有依赖、到点就开跑的）步骤的实例。账号冻结的不算。
    pub async fn instances_to_prewarm(
        &mut self,
        within: Duration,
        limit: i64,
    ) -> Result<Vec<InstanceId>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT i.id FROM instances i JOIN users u ON u.id = i.user_id AND u.status = 'active' \
             WHERE i.state IN ('paused', 'archived') AND i.id IN ( \
               SELECT p.instance_id FROM plans p JOIN triggers t ON t.plan_id = p.id \
                 WHERE p.status = 'active' AND t.enabled \
                   AND t.next_fire_at < now() + make_interval(secs => $1) \
               UNION \
               SELECT s.instance_id FROM plan_steps s JOIN plans p ON p.id = s.plan_id \
                 JOIN triggers t ON t.plan_id = p.id \
                 WHERE p.status = 'active' AND t.enabled AND cardinality(s.depends_on) = 0 \
                   AND t.next_fire_at < now() + make_interval(secs => $1)) \
             ORDER BY i.last_active_at LIMIT $2",
        )
        .bind(secs(within))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(ids.into_iter().map(Into::into).collect())
    }

    pub async fn trigger_due_within(&mut self, id: InstanceId, within: Duration) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM triggers t JOIN plans p ON p.id = t.plan_id \
               WHERE p.instance_id = $1 AND p.status = 'active' AND t.enabled \
                 AND t.next_fire_at < now() + make_interval(secs => $2))",
        )
        .bind(id.0)
        .bind(secs(within))
        .fetch_one(self.conn())
        .await?)
    }

    /// 升级、回滚模板版本（重建时生效）。
    /// 按新版本重建完成。
    pub async fn clear_rebuild_pending(&mut self, id: InstanceId) -> Result<()> {
        sqlx::query("UPDATE instances SET rebuild_pending = false WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 每个 agent 版本上有多少个没删除的实例（15.5：下架一个版本后看还有多少实例没换过去）。
    pub async fn instance_versions(&mut self) -> Result<Vec<(String, String, i64)>> {
        Ok(sqlx::query_as(
            "SELECT agent_id, agent_version, count(*) FROM instances WHERE state <> 'deleted' \
             GROUP BY agent_id, agent_version ORDER BY agent_id, agent_version",
        )
        .fetch_all(self.conn())
        .await?)
    }

    pub async fn set_instance_version(
        &mut self,
        id: InstanceId,
        agent_version: &str,
    ) -> Result<()> {
        sqlx::query("UPDATE instances SET agent_version = $2, updated_at = now() WHERE id = $1")
            .bind(id.0)
            .bind(agent_version)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 已删除、资源还没回收的实例，锁住返回（SKIP LOCKED）。
    pub async fn instances_to_purge(&mut self, limit: i64) -> Result<Vec<InstanceRuntime>> {
        let rows: Vec<RuntimeRow> = sqlx::query_as(concat!(
            "SELECT ",
            runtime_columns!(),
            " FROM instances WHERE state = 'deleted' AND purged_at IS NULL \
             ORDER BY deleted_at LIMIT $1 FOR UPDATE SKIP LOCKED"
        ))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(RuntimeRow::into_runtime).collect()
    }

    pub async fn mark_instance_purged(&mut self, id: InstanceId) -> Result<()> {
        // 工作区归档的对象由触发器排进 blob_purge。
        sqlx::query(
            "UPDATE instances SET purged_at = now(), sandbox_id = NULL, sandbox_address = NULL, snapshot_id = NULL, \
               workspace_archive_key = NULL, workspace_archive_id = NULL, workspace_archive_bytes = NULL, \
               workspace_archive_sha256 = NULL, workspace_archived_at = NULL, workspace_archive_pending = NULL, \
               workspace_archive_pending_since = NULL, sandbox_version = NULL, restoring_sandbox_id = NULL, \
               restoring_since = NULL, workspace_project_id = NULL \
             WHERE id = $1",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 要上传一份新的工作区归档：先记下对象键（单独提交），上传中途进程被杀时下次能找到、删掉它。
    /// 一个实例同时只存一份：别处的上传在 `stale_after` 之内刷新过（[`Self::refresh_workspace_archive`]）
    /// 时什么都不改，返回 false；更早的算没人管了，换掉（由触发器排进 blob_purge）。实例删了也返回 false。
    pub async fn begin_workspace_archive(
        &mut self,
        id: InstanceId,
        key: &str,
        stale_after: Duration,
    ) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE instances SET workspace_archive_pending = $2, \
               workspace_archive_pending_since = clock_timestamp() \
             WHERE id = $1 AND state <> 'deleted' \
               AND (workspace_archive_pending IS NULL OR workspace_archive_pending_since IS NULL \
                    OR workspace_archive_pending_since < clock_timestamp() - make_interval(secs => $3))",
        )
        .bind(id.0)
        .bind(key)
        .bind(secs(stale_after))
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 上传还在进行：刷新时间（单独提交）。待定的已经不是 `key` 时返回 false。
    pub async fn refresh_workspace_archive(&mut self, id: InstanceId, key: &str) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE instances SET workspace_archive_pending_since = clock_timestamp() \
             WHERE id = $1 AND workspace_archive_pending = $2",
        )
        .bind(id.0)
        .bind(key)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 上传完成：换成新的归档（旧的由触发器排进 blob_purge）。待定的对象已经不是 `key`
    /// （别的副本开始了新的上传）时什么都不改，返回 false。
    pub async fn finish_workspace_archive(
        &mut self,
        id: InstanceId,
        key: &str,
        archive_id: Uuid,
        bytes: u64,
        sha256: &[u8; 32],
    ) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE instances SET workspace_archive_key = $2, workspace_archive_id = $3, \
               workspace_archive_bytes = $4, workspace_archive_sha256 = $5, \
               workspace_archived_at = now(), workspace_archive_pending = NULL, \
               workspace_archive_pending_since = NULL, workspace_archive_failed_at = NULL, \
               workspace_archive_error = NULL \
             WHERE id = $1 AND workspace_archive_pending = $2",
        )
        .bind(id.0)
        .bind(key)
        .bind(archive_id)
        .bind(i64::try_from(bytes).map_err(|_| Error::Invalid("archive too large".into()))?)
        .bind(sha256.as_slice())
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 归档失败了（单独提交）：一段时间内巡检不再试，除非实例又被用过。错误信息只留前 500 个字符，
    /// 控制字符换成空格（报错里可能带着沙箱里打印的东西，Postgres 的 text 存不了 NUL）。
    pub async fn record_workspace_archive_failure(
        &mut self,
        id: InstanceId,
        error: &str,
    ) -> Result<()> {
        let error: String = error
            .chars()
            .take(500)
            .map(|c| if c.is_control() { ' ' } else { c })
            .collect();
        sqlx::query(
            "UPDATE instances SET workspace_archive_failed_at = now(), workspace_archive_error = $2 \
             WHERE id = $1",
        )
        .bind(id.0)
        .bind(error)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 当前沙箱是按这个版本建的。
    pub async fn set_sandbox_version(&mut self, id: InstanceId, version: &str) -> Result<()> {
        sqlx::query("UPDATE instances SET sandbox_version = $2 WHERE id = $1")
            .bind(id.0)
            .bind(version)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 要往新建的沙箱里放回归档（单独提交，放回时不锁实例）：记下沙箱，进程中途被杀时巡检能找到、删掉它。
    /// 时间用当下的（不是事务开始时的）：之前锁实例、建沙箱花的时间不算。
    pub async fn begin_restore(&mut self, id: InstanceId, sandbox_id: &str) -> Result<()> {
        sqlx::query(
            "UPDATE instances SET restoring_sandbox_id = $2, restoring_since = clock_timestamp() \
             WHERE id = $1",
        )
        .bind(id.0)
        .bind(sandbox_id)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 还在放回：刷新时间（单独提交）。记的已经不是这个沙箱时返回 false。
    pub async fn refresh_restore(&mut self, id: InstanceId, sandbox_id: &str) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE instances SET restoring_since = clock_timestamp() \
             WHERE id = $1 AND restoring_sandbox_id = $2",
        )
        .bind(id.0)
        .bind(sandbox_id)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 记着的放回 `older_than` 没刷新了（按数据库的时钟）。没有在放回的返回 false。
    pub async fn restore_is_stale(&mut self, id: InstanceId, older_than: Duration) -> Result<bool> {
        let stale: Option<bool> = sqlx::query_scalar(
            "SELECT restoring_since < clock_timestamp() - make_interval(secs => $2) \
             FROM instances WHERE id = $1",
        )
        .bind(id.0)
        .bind(secs(older_than))
        .fetch_one(self.conn())
        .await?;
        Ok(stale.unwrap_or(false))
    }

    /// 放回结束（成功或放弃）。记的已经不是这个沙箱时什么都不改，返回 false。
    pub async fn end_restore(&mut self, id: InstanceId, sandbox_id: &str) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE instances SET restoring_sandbox_id = NULL, restoring_since = NULL \
             WHERE id = $1 AND restoring_sandbox_id = $2",
        )
        .bind(id.0)
        .bind(sandbox_id)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 太久没刷新的放回（进程中途被杀）：巡检删掉那些沙箱。
    pub async fn stale_restores(
        &mut self,
        older_than: Duration,
        limit: i64,
    ) -> Result<Vec<InstanceId>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT id FROM instances WHERE restoring_sandbox_id IS NOT NULL \
               AND restoring_since < clock_timestamp() - make_interval(secs => $1) \
             ORDER BY restoring_since LIMIT $2",
        )
        .bind(secs(older_than))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(ids.into_iter().map(Into::into).collect())
    }

    /// 上传失败或不用了：对象由触发器排进 blob_purge。待定的已经不是 `key`（被当成没人管换掉了、实例回收了）
    /// 时什么都不改，返回 false：这时排进队列的可能早就删过了，调用方自己删掉传上去的对象。
    pub async fn abort_workspace_archive(&mut self, id: InstanceId, key: &str) -> Result<bool> {
        let done = sqlx::query(
            "UPDATE instances SET workspace_archive_pending = NULL, workspace_archive_pending_since = NULL \
             WHERE id = $1 AND workspace_archive_pending = $2",
        )
        .bind(id.0)
        .bind(key)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 记一次活动（运行开始、用户发消息），空闲暂停按它计时。用当下的时间（不是事务开始时的）：调用方锁着实例，
    /// 这样总比之前提交的归档时间晚，归档不会被误当成比这次活动新。
    pub async fn touch_instance(&mut self, id: InstanceId) -> Result<()> {
        sqlx::query("UPDATE instances SET last_active_at = clock_timestamp() WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 某个状态下空闲超过 `idle` 的实例（空闲暂停、归档扫描）和它们的最后活动时间，最久没动的在前。
    /// 不加锁：调用方逐个锁住、核对状态和活动时间没变再处理。
    /// 有运行正在执行的不算空闲；`also_busy` 里状态的运行也挡着（比如等审批时不暂停）。
    /// 别的等待（等设备、等额度）不挡暂停，事情来了再唤醒。
    /// `failed_retry`：上次归档失败、之后没被用过的，这么久之内不列出来（归档阶段用，免得每轮都白做一遍）。
    pub async fn idle_instance_ids(
        &mut self,
        state: InstanceState,
        idle: Duration,
        limit: i64,
        also_busy: &[RunState],
        failed_retry: Duration,
    ) -> Result<Vec<(InstanceId, DateTime<Utc>)>> {
        let busy = busy_states(also_busy);
        let rows: Vec<(Uuid, DateTime<Utc>)> = sqlx::query_as(
            "SELECT id, last_active_at FROM instances \
             WHERE state = $1 AND last_active_at < now() - make_interval(secs => $2) \
               AND NOT EXISTS (SELECT 1 FROM runs WHERE runs.instance_id = instances.id \
                               AND runs.state = ANY($4)) \
               AND (workspace_archive_failed_at IS NULL \
                    OR workspace_archive_failed_at < last_active_at \
                    OR workspace_archive_failed_at < now() - make_interval(secs => $5)) \
             ORDER BY last_active_at LIMIT $3",
        )
        .bind(state.as_str())
        .bind(secs(idle))
        .bind(limit)
        .bind(&busy)
        .bind(secs(failed_retry))
        .fetch_all(self.conn())
        .await?;
        Ok(rows.into_iter().map(|(id, at)| (id.into(), at)).collect())
    }

    /// 有正在执行的运行，或者有 `also_busy` 里状态的运行。
    pub async fn instance_busy_with(
        &mut self,
        id: InstanceId,
        also_busy: &[RunState],
    ) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM runs WHERE instance_id = $1 AND state = ANY($2))",
        )
        .bind(id.0)
        .bind(busy_states(also_busy))
        .fetch_one(self.conn())
        .await?)
    }

    /// 下次唤醒时重建沙箱（换了版本）。
    pub async fn mark_rebuild_pending(&mut self, id: InstanceId) -> Result<()> {
        sqlx::query("UPDATE instances SET rebuild_pending = true WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }
}

/// 启动中、运行中，加上调用方给的状态。
fn busy_states(also: &[RunState]) -> Vec<&'static str> {
    [RunState::Starting, RunState::Running]
        .iter()
        .chain(also)
        .map(|s| s.as_str())
        .collect()
}

/// 没结束的运行（实例在做的事）。
const ACTIVE_RUN: &str = "state NOT IN ('succeeded', 'failed', 'cancelled')";

impl Tx<Worker> {
    /// 换工作区之前先锁这个实例的出网请求（8.16）：用户决定出网请求时先锁请求、再改实例，这里同样先请求后实例。
    pub(crate) async fn prelock_egress(&mut self, instance: InstanceId) -> Result<()> {
        sqlx::query("SELECT id FROM egress_requests WHERE instance_id = $1 ORDER BY id FOR UPDATE")
            .bind(instance.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 实例上没有别的事（8.16，标专属之前；调用方已经 `FOR UPDATE` 锁着实例）：没结束的运行、生效中的计划（自己的或者
    /// 步骤用到它）、`project` 以外的项目里还在的 agent 行都没有。有的回 `Conflict("instance_not_free: …")`（库里的
    /// 触发器兜底）。
    pub(crate) async fn free_instance_check(
        &mut self,
        instance: InstanceId,
        project: Option<ProjectId>,
    ) -> Result<()> {
        let (runs, plans, pipelines, elsewhere): (bool, bool, bool, bool) =
            sqlx::query_as(sqlx::AssertSqlSafe(format!(
                "SELECT EXISTS (SELECT 1 FROM runs WHERE instance_id = $1 AND {ACTIVE_RUN}), \
                        EXISTS (SELECT 1 FROM plans p WHERE p.status = 'active' AND (p.instance_id = $1 \
                                  OR p.id IN (SELECT s.plan_id FROM plan_steps s WHERE s.instance_id = $1))), \
                        EXISTS (SELECT 1 FROM runs r JOIN plan_steps s ON s.plan_id = r.plan_id \
                                 WHERE r.kind = 'pipeline' AND r.{ACTIVE_RUN} AND s.instance_id = $1), \
                        EXISTS (SELECT 1 FROM project_agents a WHERE a.instance_id = $1 AND a.left_at IS NULL \
                                  AND a.project_id IS DISTINCT FROM $2)"
            )))
        .bind(instance.0)
        .bind(project.map(|p| p.0))
        .fetch_one(self.conn())
        .await?;
        let why = if runs {
            "it is still working on something; stop it first"
        } else if plans {
            "an active plan uses it; pause the plan first"
        } else if pipelines {
            "a running pipeline still has a step on it; wait for it to finish or stop it"
        } else if elsewhere {
            "it is in another project; withdraw it there first"
        } else {
            return Ok(());
        };
        Err(Error::Conflict(format!("instance_not_free: {why}")))
    }

    /// 换一个全新的工作区（8.16：标专属、释放、项目删了）：旧的沙箱、放回中的沙箱、工作区卷记进 `retired_workspaces`
    /// 由巡检销毁，旧的归档对象由触发器排进清理；实例回到“准备中”，令牌代数加一，记下新的空间（`space`）。等着用户处理的
    /// 出网请求删掉、保险箱请求过期，它们的提醒标已读（别人锁着的跳过）。调用方已经锁着实例、核对过它是空闲的。
    /// 实例删了的 NotFound。
    pub(crate) async fn retire_workspace(
        &mut self,
        instance: InstanceId,
        space: Option<ProjectId>,
        reason: &str,
    ) -> Result<()> {
        sqlx::query(
            "INSERT INTO retired_workspaces (id, instance_id, user_id, workspace_id, sandbox_ids, reason) \
             SELECT $2, id, user_id, workspace_id, array_remove(ARRAY[sandbox_id, restoring_sandbox_id], NULL), $3 \
               FROM instances WHERE id = $1 AND state <> 'deleted'",
        )
        .bind(instance.0)
        .bind(Uuid::now_v7())
        .bind(reason)
        .execute(self.conn())
        .await?;
        let done = sqlx::query(
            "UPDATE instances SET workspace_project_id = $2, workspace_id = $3, state = 'provisioning', \
               sandbox_id = NULL, sandbox_address = NULL, snapshot_id = NULL, sandbox_version = NULL, \
               rebuild_pending = false, workspace_archive_key = NULL, workspace_archive_id = NULL, \
               workspace_archive_bytes = NULL, workspace_archive_sha256 = NULL, workspace_archived_at = NULL, \
               workspace_archive_pending = NULL, workspace_archive_pending_since = NULL, \
               workspace_archive_failed_at = NULL, workspace_archive_error = NULL, \
               restoring_sandbox_id = NULL, restoring_since = NULL, egress_hosts = '{}', \
               peer_access = ($2::uuid IS NULL), token_epoch = token_epoch + 1, updated_at = now() \
             WHERE id = $1 AND state <> 'deleted'",
        )
        .bind(instance.0)
        .bind(space.map(|p| p.0))
        .bind(crate::new_workspace_id())
        .execute(self.conn())
        .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        sqlx::query(
            "WITH gone AS (DELETE FROM egress_requests WHERE id IN ( \
                             SELECT id FROM egress_requests WHERE instance_id = $1 FOR UPDATE SKIP LOCKED) \
                           RETURNING id, status) \
             UPDATE inbox_items SET read_at = now() WHERE id IN ( \
                 SELECT id FROM inbox_items WHERE egress_request_id IN \
                   (SELECT id FROM gone WHERE status = 'pending') AND read_at IS NULL FOR UPDATE SKIP LOCKED)",
        )
        .bind(instance.0)
        .execute(self.conn())
        .await?;
        sqlx::query(
            "WITH gone AS (UPDATE vault_requests SET status = 'expired', resolved_at = now() WHERE id IN ( \
                             SELECT id FROM vault_requests WHERE instance_id = $1 AND status = 'pending' \
                             FOR UPDATE SKIP LOCKED) RETURNING id) \
             UPDATE inbox_items SET read_at = now() WHERE id IN ( \
                 SELECT id FROM inbox_items WHERE vault_request_id IN (SELECT id FROM gone) \
                    AND read_at IS NULL FOR UPDATE SKIP LOCKED)",
        )
        .bind(instance.0)
        .execute(self.conn())
        .await?;
        self.append_event(
            instance,
            None,
            "instance.state",
            &serde_json::json!({ "state": "provisioning", "reset": reason }),
        )
        .await?;
        Ok(())
    }

    /// 项目删了（8.16）：专属于它的实例换成全新的私人工作区（记忆、文件清空，名字留着）。别人锁着的跳过（不等锁），后台清理
    /// 兜底。返回换了几个。
    pub(crate) async fn retire_project_workspaces(&mut self, project: ProjectId) -> Result<u64> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT id FROM instances WHERE workspace_project_id = $1 AND state <> 'deleted' \
              ORDER BY id FOR UPDATE SKIP LOCKED",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?;
        for id in &ids {
            self.retire_workspace(InstanceId(*id), None, "project_deleted")
                .await?;
        }
        Ok(ids.len() as u64)
    }

    /// 把专属实例放回私人（8.16，主人在项目里撤下它以后）：换一个全新的私人工作区（项目的记忆、文件清空）。不是专属的
    /// Invalid；还在项目里、还有没结束的运行 Conflict；不是自己的、删了的 NotFound。
    pub async fn release_instance(
        &mut self,
        user: UserId,
        instance: InstanceId,
    ) -> Result<Instance> {
        self.lock_users(&[user]).await?;
        let found: Option<(Option<Uuid>, Uuid)> = sqlx::query_as(
            "SELECT workspace_project_id, user_id FROM instances WHERE id = $1 AND state <> 'deleted'",
        )
        .bind(instance.0)
        .fetch_optional(self.conn())
        .await?;
        let Some((space, owner)) = found else {
            return Err(Error::NotFound);
        };
        if owner != user.0 {
            return Err(Error::NotFound);
        }
        let Some(project) = space.map(ProjectId) else {
            return Err(Error::Invalid(
                "the agent is not dedicated to a project".into(),
            ));
        };
        self.lock_project(project).await?;
        self.prelock_egress(instance).await?;
        let rt = self.lock_instance(instance).await?;
        if rt.state == proto::domain::InstanceState::Deleted {
            return Err(Error::NotFound);
        }
        if rt.workspace_project_id != Some(project) {
            return Err(Error::Conflict("the agent changed, try again".into()));
        }
        let (live, busy): (bool, bool) = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT EXISTS (SELECT 1 FROM project_agents WHERE instance_id = $1 AND left_at IS NULL), \
                    EXISTS (SELECT 1 FROM runs WHERE instance_id = $1 AND {ACTIVE_RUN})"
        )))
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?;
        if live {
            return Err(Error::Conflict(
                "withdraw the agent from the project first".into(),
            ));
        }
        if busy {
            return Err(Error::Conflict(
                "the agent is still working; try again later".into(),
            ));
        }
        self.retire_workspace(instance, None, "release").await?;
        let row: Row = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM instances WHERE id = $1"
        ))
        .bind(instance.0)
        .fetch_one(self.conn())
        .await?;
        row.into_instance()
    }
}

/// 换下来、等着销毁的工作区（8.16，[`Tx::retire_workspace`] 记的）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetiredWorkspace {
    pub id: Uuid,
    pub instance: InstanceId,
    pub workspace_id: String,
    pub sandbox_ids: Vec<String>,
    pub attempts: u32,
}

impl Tx<Worker> {
    /// 到了时候、没人在处理的换下来的工作区（锁到事务结束，别的副本跳过）。
    pub async fn retired_workspaces_due(&mut self, limit: i64) -> Result<Vec<RetiredWorkspace>> {
        let rows: Vec<(Uuid, Uuid, String, Vec<String>, i32)> = sqlx::query_as(
            "SELECT id, instance_id, workspace_id, sandbox_ids, attempts FROM retired_workspaces \
              WHERE retry_at <= now() ORDER BY retry_at, id LIMIT $1 FOR UPDATE SKIP LOCKED",
        )
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(
                |(id, instance, workspace_id, sandbox_ids, attempts)| RetiredWorkspace {
                    id,
                    instance: InstanceId(instance),
                    workspace_id,
                    sandbox_ids,
                    attempts: u32::try_from(attempts).unwrap_or_default(),
                },
            )
            .collect())
    }

    /// 销毁完了。
    pub async fn forget_retired_workspace(&mut self, id: Uuid) -> Result<()> {
        sqlx::query("DELETE FROM retired_workspaces WHERE id = $1")
            .bind(id)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 没销毁成：过一会儿再试（1、2、4……分钟，最多一小时一次），记下原因。
    pub async fn retry_retired_workspace(&mut self, id: Uuid, error: &str) -> Result<()> {
        let error: String = error.chars().take(500).collect();
        sqlx::query(
            "UPDATE retired_workspaces SET attempts = attempts + 1, last_error = $2, \
               retry_at = now() + make_interval(mins => least(power(2, least(attempts, 6))::int, 60)) \
             WHERE id = $1",
        )
        .bind(id)
        .bind(error)
        .execute(self.conn())
        .await?;
        Ok(())
    }
}

impl<R> Tx<R> {
    /// 实例的名字（删了的也给；8.17 项目任务的推送里用）。
    pub async fn instance_name(&mut self, id: InstanceId) -> Result<String> {
        sqlx::query_scalar("SELECT name FROM instances WHERE id = $1")
            .bind(id.0)
            .fetch_optional(self.conn())
            .await?
            .ok_or(Error::NotFound)
    }
}
