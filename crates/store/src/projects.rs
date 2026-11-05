//! 项目（8.13，docs/projects.md 第 3 节）。这一版只有单人项目：创建者是自己、agent 都是自己的实例，在用户自己的租户事务里
//! 读写（领养时和建实例、签授权在同一个事务里，失败全部回滚）。表上的行级安全只放行自己创建、从没共享过的项目
//! （`projects.shared_at IS NULL`）；跨用户的写（8.14 起）只走 worker，按成员关系的读在 8.15。
//!
//! 团队（`teams.rs`）就是单人项目：`TeamId` 和 `ProjectId` 是同一个 id。
//!
//! 8.14 起的跨用户读写都在 `Tx<Worker>` 里，每个方法自己拿锁、自己核对调用的人是不是成员（[`ProjectActor`]）；
//! 加锁顺序见 docs/progress/drafts/projects-8.14-plan.md 第 0 节 D3：用户行 → 项目锁 → 自己的成员行 → 窄的咨询锁 →
//! 邀请行 → 别人的成员行 → 项目 agent 行 → 运行 → 实例。

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use proto::domain::{
    InstanceId, ProjectAgentView, ProjectBudget, ProjectDetail, ProjectId, ProjectLimits,
    ProjectMemberView, ProjectPerson, ProjectRole, ProjectStatus, ProjectSummary, UserId,
    UserStatus,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, parse, unsigned};

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

impl<R> Tx<R> {
    /// 项目锁（事务结束放开）：改项目的成员、agent、状态的都先拿它（docs/progress/drafts/projects-8.14-plan.md 第 0 节 D3 的
    /// 第 2 步）。人数、agent 数的上限在锁里数。
    pub async fn lock_project(&mut self, id: ProjectId) -> Result<()> {
        self.advisory_lock(&format!("project/{id}")).await
    }
}

impl Tx<Worker> {
    /// 按 id 顺序拿几个项目的锁（不在 `SELECT … ORDER BY` 里拿：目标列表里的函数不保证按排序的顺序执行）。
    pub(crate) async fn lock_projects(&mut self, ids: &mut Vec<ProjectId>) -> Result<()> {
        ids.sort_unstable();
        ids.dedup();
        for id in ids.iter() {
            self.lock_project(*id).await?;
        }
        Ok(())
    }
}

/// [`Tx::lock_users`] 锁住的一个用户。
#[derive(Debug, Clone)]
pub(crate) struct LockedUser {
    pub id: UserId,
    pub status: UserStatus,
    pub phone: String,
    pub display_name: Option<String>,
}

/// 核对过的项目成员（只在 store 里、在同一个事务里建出来用）：用户行、项目锁、自己的成员行都锁着。
#[derive(Debug, Clone)]
pub(crate) struct ProjectActor {
    pub user: UserId,
    pub role: ProjectRole,
    pub creator: UserId,
    /// 锁住的用户（调用的人、创建者和 `also` 里的人）；注销了的不在里面。
    pub users: Vec<LockedUser>,
}

impl ProjectActor {
    /// 只有创建者能做的事（邀请、移出、改项目）。
    pub fn require_creator(&self, what: &str) -> Result<()> {
        if self.role == ProjectRole::Creator {
            Ok(())
        } else {
            Err(Error::NotPermitted(format!(
                "only the project creator can {what}"
            )))
        }
    }

    pub fn locked(&self, id: UserId) -> Option<&LockedUser> {
        self.users.iter().find(|u| u.id == id)
    }
}

type SummaryRow = (
    Uuid,
    String,
    String,
    String,
    String,
    bool,
    Uuid,
    Option<String>,
    i64,
    i64,
    i64,
    DateTime<Utc>,
    DateTime<Utc>,
);

type MemberRow = (Uuid, Option<String>, String, DateTime<Utc>, i64);
type AgentRow = (Uuid, Uuid, String, String, bool, i32, DateTime<Utc>);

/// 我是成员（没退出）的项目，带人数、agent 数（实例删了的不算）。`$1` 是我。
const SUMMARY_SQL: &str = "SELECT p.id, p.name, p.goal, p.status, m.role, p.shared_at IS NOT NULL, \
       p.creator_id, cu.display_name, \
       (SELECT count(*) FROM project_members x WHERE x.project_id = p.id AND x.left_at IS NULL), \
       (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
          AND i.state <> 'deleted' WHERE a.project_id = p.id AND a.left_at IS NULL), \
       (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
          AND i.state <> 'deleted' WHERE a.project_id = p.id AND a.left_at IS NULL AND a.user_id = $1), \
       p.created_at, m.joined_at \
  FROM project_members m JOIN projects p ON p.id = m.project_id JOIN users cu ON cu.id = p.creator_id \
 WHERE m.user_id = $1 AND m.left_at IS NULL";

fn count(v: i64, what: &str) -> Result<u32> {
    Ok(u32::try_from(unsigned(v, what)?).unwrap_or(u32::MAX))
}

fn summary(row: SummaryRow) -> Result<ProjectSummary> {
    let (
        id,
        name,
        goal,
        status,
        role,
        shared,
        creator,
        creator_name,
        members,
        agents,
        mine,
        created_at,
        joined_at,
    ) = row;
    Ok(ProjectSummary {
        id: ProjectId(id),
        name,
        goal,
        status: parse(&status)?,
        role: parse(&role)?,
        shared,
        creator: ProjectPerson {
            user_id: UserId(creator),
            display_name: creator_name,
        },
        member_count: count(members, "member count")?,
        agent_count: count(agents, "agent count")?,
        my_agent_count: count(mine, "agent count")?,
        created_at,
        joined_at,
    })
}

impl Tx<Worker> {
    /// 按 id 顺序给用户行加 `FOR KEY SHARE`（D3 第 1 步：写收件箱、成员行、邀请的外键都要拿这把锁，注销拿的是
    /// `FOR UPDATE`）。没有的、注销了的不报错，调用方按结果判断。
    pub(crate) async fn lock_users(&mut self, ids: &[UserId]) -> Result<Vec<LockedUser>> {
        let mut ids: Vec<Uuid> = ids.iter().map(|u| u.0).collect();
        ids.sort_unstable();
        ids.dedup();
        let rows: Vec<(Uuid, String, String, Option<String>)> = sqlx::query_as(
            "SELECT id, status, phone, display_name FROM users WHERE id = ANY($1) \
             ORDER BY id FOR KEY SHARE",
        )
        .bind(&ids)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter()
            .map(|(id, status, phone, display_name)| {
                Ok(LockedUser {
                    id: UserId(id),
                    status: parse(&status)?,
                    phone,
                    display_name,
                })
            })
            .collect()
    }

    /// 核对 `user` 是 `project` 的成员（没退出），项目的状态在 `allow` 里；不是的一律 NotFound（不泄露项目在不在）。
    /// 按 D3 加锁：用户行（`user`、创建者、`also`）→ 项目锁 → 自己的成员行。
    pub(crate) async fn project_actor(
        &mut self,
        user: UserId,
        project: ProjectId,
        also: &[UserId],
        allow: &[ProjectStatus],
    ) -> Result<ProjectActor> {
        let creator: Uuid = sqlx::query_scalar("SELECT creator_id FROM projects WHERE id = $1")
            .bind(project.0)
            .fetch_one(self.conn())
            .await?;
        let creator = UserId(creator);
        let mut ids = vec![user, creator];
        ids.extend_from_slice(also);
        let users: Vec<LockedUser> = self
            .lock_users(&ids)
            .await?
            .into_iter()
            .filter(|u| u.status != UserStatus::Deleted)
            .collect();
        if !users.iter().any(|u| u.id == user) {
            return Err(Error::NotFound);
        }
        self.lock_project(project).await?;
        let status: String = sqlx::query_scalar("SELECT status FROM projects WHERE id = $1")
            .bind(project.0)
            .fetch_one(self.conn())
            .await?;
        if !allow.contains(&parse(&status)?) {
            return Err(Error::NotFound);
        }
        let role: String = sqlx::query_scalar(
            "SELECT role FROM project_members WHERE project_id = $1 AND user_id = $2 \
               AND left_at IS NULL FOR NO KEY UPDATE",
        )
        .bind(project.0)
        .bind(user.0)
        .fetch_one(self.conn())
        .await?;
        Ok(ProjectActor {
            user,
            role: parse(&role)?,
            creator,
            users,
        })
    }

    /// 我是成员（没退出）的、进行中的项目，按创建时间（8.14 的读法：worker 读、同一句 SQL 里核对成员关系；8.15 换成
    /// 成员事务，返回的结构不变）。
    pub async fn my_projects(&mut self, user: UserId) -> Result<Vec<ProjectSummary>> {
        let rows: Vec<SummaryRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{SUMMARY_SQL} AND p.status = 'active' ORDER BY p.created_at, p.id"
        )))
        .bind(user.0)
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(summary).collect()
    }

    /// 项目详情：只有成员（没退出）看得到，不然 NotFound。成员创建者在前；agent 只列还在的（实例没删），按位置；
    /// 预算只给我自己的（每个人管自己的 agent）。
    pub async fn project_detail(
        &mut self,
        user: UserId,
        project: ProjectId,
    ) -> Result<ProjectDetail> {
        let row: SummaryRow = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{SUMMARY_SQL} AND p.status <> 'deleted' AND p.id = $2"
        )))
        .bind(user.0)
        .bind(project.0)
        .fetch_one(self.conn())
        .await?;
        let summary = summary(row)?;
        let members: Vec<MemberRow> = sqlx::query_as(
            "SELECT m.user_id, u.display_name, m.role, m.joined_at, \
                    (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
                       AND i.state <> 'deleted' \
                      WHERE a.project_id = m.project_id AND a.user_id = m.user_id AND a.left_at IS NULL) \
               FROM project_members m JOIN users u ON u.id = m.user_id \
              WHERE m.project_id = $1 AND m.left_at IS NULL \
              ORDER BY m.role = 'creator' DESC, m.joined_at, m.user_id",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?;
        let members = members
            .into_iter()
            .map(|(id, display_name, role, joined_at, agents)| {
                Ok(ProjectMemberView {
                    user_id: UserId(id),
                    display_name,
                    role: parse(&role)?,
                    joined_at,
                    agent_count: count(agents, "agent count")?,
                    is_me: id == user.0,
                })
            })
            .collect::<Result<_>>()?;
        let agents: Vec<AgentRow> = sqlx::query_as(
            "SELECT a.instance_id, a.user_id, i.agent_id, i.name, a.is_lead, a.position, a.added_at \
               FROM project_agents a JOIN instances i ON i.id = a.instance_id AND i.state <> 'deleted' \
              WHERE a.project_id = $1 AND a.left_at IS NULL ORDER BY a.position, a.instance_id",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?;
        let agents = agents
            .into_iter()
            .map(
                |(instance, owner, agent_id, name, is_lead, position, added_at)| ProjectAgentView {
                    instance_id: InstanceId(instance),
                    owner_id: UserId(owner),
                    agent_id,
                    name,
                    is_lead,
                    position: u32::try_from(position).unwrap_or_default(),
                    added_at,
                    mine: owner == user.0,
                },
            )
            .collect();
        let (daily, total): (Option<i64>, Option<i64>) = sqlx::query_as(
            "SELECT daily_token_limit, total_token_limit FROM project_members \
              WHERE project_id = $1 AND user_id = $2",
        )
        .bind(project.0)
        .bind(user.0)
        .fetch_one(self.conn())
        .await?;
        Ok(ProjectDetail {
            summary,
            members,
            agents,
            my_budget: ProjectBudget {
                daily_token_limit: daily.map(|v| unsigned(v, "token limit")).transpose()?,
                total_token_limit: total.map(|v| unsigned(v, "token limit")).transpose()?,
            },
            limits: ProjectLimits::default(),
        })
    }

    /// 改项目的名字、目标（只有创建者；共享了的也能改）。
    pub async fn update_project(
        &mut self,
        user: UserId,
        project: ProjectId,
        name: Option<&str>,
        goal: Option<&str>,
    ) -> Result<()> {
        let actor = self
            .project_actor(user, project, &[], &[ProjectStatus::Active])
            .await?;
        actor.require_creator("change the project")?;
        sqlx::query(
            "UPDATE projects SET name = coalesce($2, name), goal = coalesce($3, goal), \
             updated_at = now() WHERE id = $1",
        )
        .bind(project.0)
        .bind(name)
        .bind(goal)
        .execute(self.conn())
        .await?;
        Ok(())
    }
}

const PROJECT_COLUMNS: &str = "id, name, status, shared_at IS NOT NULL, created_at, updated_at";

impl Tx<Tenant> {
    /// 建单人项目：创建者是自己，agent 都是自己没删的实例，最多一个负责人。
    pub async fn create_solo_project(
        &mut self,
        name: &str,
        goal: &str,
        agents: &[SoloAgent],
    ) -> Result<ProjectId> {
        let id = ProjectId::new();
        sqlx::query(
            "INSERT INTO projects (id, creator_id, name, goal) VALUES ($1, app_user_id(), $2, $3)",
        )
        .bind(id.0)
        .bind(name)
        .bind(goal)
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

    /// 删实例之前拿它所在项目的锁（按 id 顺序；D4：租户改单人项目也先拿项目锁）。删实例先改实例行、再把它在单人项目里的
    /// agent 行标离开，worker 加 agent 是先 agent 行、再实例行，不排队会互相等。看得到的只有自己的 agent 行。
    pub async fn lock_instance_projects(&mut self, instance: InstanceId) -> Result<()> {
        let mut ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT DISTINCT project_id FROM project_agents WHERE instance_id = $1 AND left_at IS NULL",
        )
        .bind(instance.0)
        .fetch_all(self.conn())
        .await?;
        ids.sort_unstable();
        for id in ids {
            self.lock_project(ProjectId(id)).await?;
        }
        Ok(())
    }

    /// 看得到、进行中、没共享过的单人项目才能改：看不到的 NotFound，共享过的 Conflict。先拿项目锁（D4）：不然 worker
    /// 在锁里数 agent、接受邀请的同时，租户还能往里加 agent，超过上限。锁之前先看一眼，别人的项目不去锁它；锁到以后
    /// 再读一遍（这期间可能有人加入、变成共享的了）。
    async fn writable_solo(&mut self, id: ProjectId) -> Result<()> {
        self.own_project(id).await?;
        self.lock_project(id).await?;
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
            // 加共享锁：同时有人在删这个实例时等它提交、再按删掉了算（不然删掉的实例会被改回成负责人）。
            sqlx::query_scalar::<_, Uuid>(
                "SELECT id FROM instances WHERE id = $1 AND state <> 'deleted' FOR SHARE",
            )
            .bind(a.instance_id.0)
            .fetch_one(self.conn())
            .await?;
        }
        Ok(())
    }
}
