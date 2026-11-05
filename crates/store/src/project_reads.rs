//! 项目成员的读（8.15，docs/projects.md 第 5 节，docs/projects-impl.md 第 2 条）：`thinktin_member` 角色的只读事务。
//!
//! 读得到哪些行由库里的策略按 `member_projects()` 算：只看 `app.user_id`，我是存活成员、项目进行中或归档、我没注销。
//! 没有“当前项目”这种设置，传别的项目 id 也读不到；退出、被移出、项目删了，下一个请求就读不到了。
//! [`ProjectTx`] 不是 `Tx<R>`：那些通用的方法（写事件、写收件箱、拿锁……）在这里一个都没有，能做什么在编译时就定了。

use chrono::{DateTime, Utc};
use proto::domain::{
    InstanceId, ProjectAgentView, ProjectBudget, ProjectDetail, ProjectId, ProjectLimits,
    ProjectMemberView, ProjectPerson, ProjectStatus, ProjectSummary, UserId,
};
use sqlx::{PgConnection, Postgres, Transaction};
use uuid::Uuid;

use crate::{Error, Result, parse, unsigned};

/// 项目成员的只读事务（[`crate::Db::member`] 开）。
pub struct ProjectTx {
    tx: Transaction<'static, Postgres>,
    user: UserId,
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

/// 我是存活成员的项目，带人数、agent 数。删了的实例、撤下的 agent 不算（实例的行策略只放行项目里还在、没删的实例）；
/// 创建者注销了的，名字是空的（用户行只放行存活的成员）。
const SUMMARY_SQL: &str = "SELECT p.id, p.name, p.goal, p.status, m.role, p.shared_at IS NOT NULL, \
       p.creator_id, cu.display_name, \
       (SELECT count(*) FROM project_members x WHERE x.project_id = p.id AND x.left_at IS NULL), \
       (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
          WHERE a.project_id = p.id AND a.left_at IS NULL), \
       (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
          WHERE a.project_id = p.id AND a.left_at IS NULL AND a.user_id = app_user_id()), \
       p.created_at, m.joined_at \
  FROM project_members m JOIN projects p ON p.id = m.project_id LEFT JOIN users cu ON cu.id = p.creator_id \
 WHERE m.user_id = app_user_id() AND m.left_at IS NULL";

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

impl ProjectTx {
    pub(crate) fn new(tx: Transaction<'static, Postgres>, user: UserId) -> Self {
        Self { tx, user }
    }

    pub fn user(&self) -> UserId {
        self.user
    }

    /// 结束（只读，回滚）。
    pub async fn finish(self) -> Result<()> {
        self.tx.rollback().await?;
        Ok(())
    }

    pub(crate) fn conn(&mut self) -> &mut PgConnection {
        &mut self.tx
    }

    /// 我读得到这个项目（存活成员、没删）：它的状态；读不到 NotFound。
    pub async fn require_project(&mut self, project: ProjectId) -> Result<ProjectStatus> {
        let status: String = sqlx::query_scalar("SELECT status FROM projects WHERE id = $1")
            .bind(project.0)
            .fetch_one(self.conn())
            .await?;
        parse(&status)
    }

    /// 我是存活成员的项目（进行中、归档的），按创建时间。
    pub async fn my_projects(&mut self) -> Result<Vec<ProjectSummary>> {
        let rows: Vec<SummaryRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{SUMMARY_SQL} ORDER BY p.created_at, p.id"
        )))
        .fetch_all(self.conn())
        .await?;
        rows.into_iter().map(summary).collect()
    }

    /// 项目详情（和 8.14 的结构一样）：成员创建者在前；agent 只列还在的（实例没删），按位置；预算只给我自己的。
    pub async fn project_detail(&mut self, project: ProjectId) -> Result<ProjectDetail> {
        let row: SummaryRow =
            sqlx::query_as(sqlx::AssertSqlSafe(format!("{SUMMARY_SQL} AND p.id = $1")))
                .bind(project.0)
                .fetch_one(self.conn())
                .await?;
        let summary = summary(row)?;
        let user = self.user;
        let members: Vec<MemberRow> = sqlx::query_as(
            "SELECT m.user_id, u.display_name, m.role, m.joined_at, \
                    (SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
                      WHERE a.project_id = m.project_id AND a.user_id = m.user_id AND a.left_at IS NULL) \
               FROM project_members m LEFT JOIN users u ON u.id = m.user_id \
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
               FROM project_agents a JOIN instances i ON i.id = a.instance_id \
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
        let budget: Option<(Option<i64>, Option<i64>)> = sqlx::query_as(
            "SELECT daily_token_limit, total_token_limit FROM my_project_budget($1)",
        )
        .bind(project.0)
        .fetch_optional(self.conn())
        .await?;
        let (daily, total) = budget.ok_or(Error::NotFound)?;
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
}
