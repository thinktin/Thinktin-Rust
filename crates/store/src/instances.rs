//! 实例和它的模型别名（5.5、6.4）。

use std::net::IpAddr;
use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    CredentialId, Instance, InstanceId, InstanceLimits, InstanceState, MAX_ROUTE_FALLBACKS,
    ModelRoute, RouteFallback, UserId,
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
        })
    }
}

macro_rules! columns {
    () => {
        "id, agent_id, agent_version, harness, name, state, created_at, last_active_at"
    };
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
}

impl RuntimeRow {
    fn into_runtime(self) -> Result<InstanceRuntime> {
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
        })
    }
}

macro_rules! runtime_columns {
    () => {
        "id, user_id, agent_id, agent_version, harness, state, sandbox_id, \
         host(sandbox_address) AS sandbox_address, workspace_id, snapshot_id, limits, last_active_at, \
         rebuild_pending, token_epoch"
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
        // 降级链随主路由级联删除。
        sqlx::query("DELETE FROM model_routes WHERE instance_id = $1")
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
    /// 委派（8.7）：`lead` 当负责人的团队里的其他成员（没删除的实例），按名字排。
    pub async fn delegation_targets(&mut self, lead: InstanceId) -> Result<Vec<Instance>> {
        let rows: Vec<Row> = sqlx::query_as(concat!(
            "SELECT ",
            columns!(),
            " FROM instances WHERE state <> 'deleted' AND id <> $1 AND id IN ( \
               SELECT m.instance_id FROM team_members m WHERE m.team_id IN ( \
                 SELECT team_id FROM team_members WHERE instance_id = $1 AND role = 'lead')) \
             ORDER BY name, id"
        ))
        .bind(lead.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(Row::into_instance).collect()
    }
}

impl Tx<Worker> {
    /// 实例是不是哪个团队的负责人（只有负责人能委派，8.7）。
    pub async fn is_team_lead(&mut self, instance: InstanceId) -> Result<bool> {
        Ok(sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM team_members WHERE instance_id = $1 AND role = 'lead')",
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
               snapshot_id = $5, updated_at = now() \
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
    /// 预热（6.5）：`within` 之内有计划要触发、现在暂停着的实例。包括计划自己的实例，
    /// 和流水线里第一批（没有依赖、到点就开跑的）步骤的实例。账号冻结的不算。
    pub async fn instances_to_prewarm(
        &mut self,
        within: Duration,
        limit: i64,
    ) -> Result<Vec<InstanceId>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT i.id FROM instances i JOIN users u ON u.id = i.user_id AND u.status = 'active' \
             WHERE i.state = 'paused' AND i.id IN ( \
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
        sqlx::query(
            "UPDATE instances SET purged_at = now(), sandbox_id = NULL, sandbox_address = NULL, snapshot_id = NULL \
             WHERE id = $1",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 记一次活动（运行开始、用户发消息），空闲暂停按它计时。
    pub async fn touch_instance(&mut self, id: InstanceId) -> Result<()> {
        sqlx::query("UPDATE instances SET last_active_at = now() WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 某个状态下空闲超过 `idle` 的实例（空闲暂停、归档扫描），跳过别的副本正在处理的。
    /// 有运行正在执行的不算空闲；等审批、等设备的运行不挡暂停（事情来了再唤醒）。
    pub async fn idle_instances(
        &mut self,
        state: InstanceState,
        idle: Duration,
        limit: i64,
    ) -> Result<Vec<InstanceRuntime>> {
        let rows: Vec<RuntimeRow> = sqlx::query_as(concat!(
            "SELECT ",
            runtime_columns!(),
            " FROM instances \
             WHERE state = $1 AND last_active_at < now() - make_interval(secs => $2) \
               AND NOT EXISTS (SELECT 1 FROM runs WHERE runs.instance_id = instances.id \
                               AND runs.state IN ('starting', 'running')) \
             ORDER BY last_active_at LIMIT $3 FOR UPDATE SKIP LOCKED"
        ))
        .bind(state.as_str())
        .bind(secs(idle))
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(RuntimeRow::into_runtime).collect()
    }
}
