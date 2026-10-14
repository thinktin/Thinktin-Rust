//! 实例和它的模型别名（5.5、6.4）。

use std::net::IpAddr;
use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{Instance, InstanceId, InstanceLimits, InstanceState, ModelRoute, UserId};
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
        })
    }
}

macro_rules! runtime_columns {
    () => {
        "id, user_id, agent_id, agent_version, harness, state, sandbox_id, \
         host(sandbox_address) AS sandbox_address, workspace_id, snapshot_id, limits, last_active_at"
    };
}

#[derive(sqlx::FromRow)]
struct RouteRow {
    alias: String,
    credential_id: Uuid,
    upstream_model: String,
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

    /// 标记删除。沙箱和工作区由后台的生命周期管理回收。
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
        Ok(())
    }

    /// 整体替换实例的模型别名。凭证必须是自己的、没删除、没停用。
    pub async fn set_model_routes(
        &mut self,
        instance: InstanceId,
        routes: &[ModelRoute],
    ) -> Result<()> {
        // 锁住实例行：并发替换时后到的等前一个提交，不会交错成两份的并集。
        self.instance_for_update(instance).await?;
        sqlx::query("DELETE FROM model_routes WHERE instance_id = $1")
            .bind(instance.0)
            .execute(self.conn())
            .await?;
        for route in routes {
            let usable: Option<bool> = sqlx::query_scalar(
                "SELECT deleted_at IS NULL AND NOT disabled FROM credentials WHERE id = $1 FOR SHARE",
            )
            .bind(route.credential_id.0)
            .fetch_optional(self.conn())
            .await?;
            if usable != Some(true) {
                return Err(Error::Invalid(format!(
                    "credential {} is not usable",
                    route.credential_id
                )));
            }
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
        Ok(rows
            .into_iter()
            .map(|r| ModelRoute {
                alias: r.alias,
                credential_id: r.credential_id.into(),
                upstream_model: r.upstream_model,
            })
            .collect())
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

impl Tx<Worker> {
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
