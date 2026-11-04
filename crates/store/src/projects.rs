//! 项目（8.13，docs/projects.md 第 3 节）。这一版只有单人项目：创建者是自己、agent 都是自己的实例，在用户自己的租户事务里
//! 读写（领养时和建实例、签授权在同一个事务里，失败全部回滚）。表上的行级安全只放行自己创建、从没共享过的项目
//! （`projects.shared_at IS NULL`）；跨用户的写（8.14 起）只走 worker，按成员关系的读在 8.15。
//!
//! 团队（`teams.rs`）就是单人项目：`TeamId` 和 `ProjectId` 是同一个 id。

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use proto::domain::{InstanceId, ProjectId, ProjectStatus};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, parse};

/// 单人项目里的一个 agent（自己的实例）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SoloAgent {
    pub instance_id: InstanceId,
    pub is_lead: bool,
    pub position: u32,
}

/// 自己创建的项目。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectRecord {
    pub id: ProjectId,
    pub name: String,
    pub status: ProjectStatus,
    /// 有别的用户加入过（之后租户事务不能再改它）。
    pub shared: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

type ProjectRow = (Uuid, String, String, bool, DateTime<Utc>, DateTime<Utc>);

fn record(row: ProjectRow) -> Result<ProjectRecord> {
    let (id, name, status, shared, created_at, updated_at) = row;
    Ok(ProjectRecord {
        id: ProjectId(id),
        name,
        status: parse(&status)?,
        shared,
        created_at,
        updated_at,
    })
}

const PROJECT_COLUMNS: &str = "id, name, status, shared_at IS NOT NULL, created_at, updated_at";

impl Tx<Tenant> {
    /// 建单人项目：创建者是自己，agent 都是自己没删的实例，最多一个负责人。
    pub async fn create_solo_project(
        &mut self,
        name: &str,
        agents: &[SoloAgent],
    ) -> Result<ProjectId> {
        let id = ProjectId::new();
        sqlx::query("INSERT INTO projects (id, creator_id, name) VALUES ($1, app_user_id(), $2)")
            .bind(id.0)
            .bind(name)
            .execute(self.conn())
            .await?;
        sqlx::query(
            "INSERT INTO project_members (project_id, user_id, role) VALUES ($1, app_user_id(), 'creator')",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        self.check_agents(agents).await?;
        for a in agents {
            sqlx::query(
                "INSERT INTO project_agents (project_id, instance_id, user_id, is_lead, position) \
                 VALUES ($1, $2, app_user_id(), $3, $4)",
            )
            .bind(id.0)
            .bind(a.instance_id.0)
            .bind(a.is_lead)
            .bind(i32::try_from(a.position).unwrap_or(i32::MAX))
            .execute(self.conn())
            .await?;
        }
        Ok(id)
    }

    /// 自己创建的一个项目（删掉的看不到）。
    pub async fn own_project(&mut self, id: ProjectId) -> Result<ProjectRecord> {
        let row: ProjectRow = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {PROJECT_COLUMNS} FROM projects WHERE id = $1 AND status <> 'deleted'"
        )))
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        record(row)
    }

    /// 自己创建的、进行中的项目，按创建时间。
    pub async fn own_projects(&mut self) -> Result<Vec<ProjectRecord>> {
        let rows: Vec<ProjectRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {PROJECT_COLUMNS} FROM projects WHERE status = 'active' ORDER BY created_at, id"
        )))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(record).collect()
    }

    /// 项目里自己的、还在的 agent（实例没删），按位置。
    pub async fn my_project_agents(&mut self, id: ProjectId) -> Result<Vec<SoloAgent>> {
        let rows: Vec<(Uuid, bool, i32)> = sqlx::query_as(
            "SELECT a.instance_id, a.is_lead, a.position FROM project_agents a \
             JOIN instances i ON i.id = a.instance_id AND i.state <> 'deleted' \
             WHERE a.project_id = $1 AND a.left_at IS NULL ORDER BY a.position, a.instance_id",
        )
        .bind(id.0)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(instance, is_lead, position)| SoloAgent {
                instance_id: InstanceId(instance),
                is_lead,
                position: u32::try_from(position).unwrap_or_default(),
            })
            .collect())
    }

    /// 改名（单人项目）。
    pub async fn update_solo_project(&mut self, id: ProjectId, name: Option<&str>) -> Result<()> {
        self.writable_solo(id).await?;
        let done = sqlx::query(
            "UPDATE projects SET name = coalesce($2, name), updated_at = now() \
             WHERE id = $1 AND status = 'active'",
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

    /// 整体替换自己在项目里的 agent：原地改，不删了重建（每个 agent 的设置、加入时间留着）；去掉的标成离开。
    pub async fn replace_my_project_agents(
        &mut self,
        id: ProjectId,
        agents: &[SoloAgent],
    ) -> Result<()> {
        self.writable_solo(id).await?;
        self.check_agents(agents).await?;
        // 唯一索引逐行检查：先腾出负责人，再标离开，最后写新的。
        sqlx::query(
            "UPDATE project_agents SET is_lead = false \
             WHERE project_id = $1 AND user_id = app_user_id() AND is_lead",
        )
        .bind(id.0)
        .execute(self.conn())
        .await?;
        let keep: Vec<Uuid> = agents.iter().map(|a| a.instance_id.0).collect();
        sqlx::query(
            "UPDATE project_agents SET left_at = now() \
             WHERE project_id = $1 AND user_id = app_user_id() AND left_at IS NULL \
               AND NOT (instance_id = ANY($2))",
        )
        .bind(id.0)
        .bind(&keep)
        .execute(self.conn())
        .await?;
        for a in agents {
            sqlx::query(
                "INSERT INTO project_agents (project_id, instance_id, user_id, is_lead, position) \
                 VALUES ($1, $2, app_user_id(), $3, $4) \
                 ON CONFLICT (project_id, instance_id) DO UPDATE SET is_lead = EXCLUDED.is_lead, \
                   position = EXCLUDED.position, left_at = NULL, \
                   added_at = CASE WHEN project_agents.left_at IS NULL THEN project_agents.added_at \
                                   ELSE now() END",
            )
            .bind(id.0)
            .bind(a.instance_id.0)
            .bind(a.is_lead)
            .bind(i32::try_from(a.position).unwrap_or(i32::MAX))
            .execute(self.conn())
            .await?;
        }
        Ok(())
    }

    /// 删单人项目（成员、agent、邀请、密钥级联删掉，实例留着）。8.15 有了项目内容以后改成先标删除、后台清理。
    pub async fn delete_solo_project(&mut self, id: ProjectId) -> Result<()> {
        self.writable_solo(id).await?;
        let done = sqlx::query("DELETE FROM projects WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }

    /// 看得到、进行中、没共享过的单人项目才能改：看不到的 NotFound，共享过的 Conflict。
    async fn writable_solo(&mut self, id: ProjectId) -> Result<()> {
        let p = self.own_project(id).await?;
        if p.status != ProjectStatus::Active {
            return Err(Error::NotFound);
        }
        if p.shared {
            return Err(Error::Conflict("project is shared".into()));
        }
        Ok(())
    }

    /// 最多一个负责人、不重复、都是自己没删的实例（别人的、删掉的 NotFound）。
    async fn check_agents(&mut self, agents: &[SoloAgent]) -> Result<()> {
        if agents.iter().filter(|a| a.is_lead).count() > 1 {
            return Err(Error::Invalid("a team has at most one lead".into()));
        }
        let mut seen = HashSet::new();
        for a in agents {
            if !seen.insert(a.instance_id) {
                return Err(Error::Conflict("project_agents_pkey".into()));
            }
            self.instance(a.instance_id).await?;
        }
        Ok(())
    }
}
