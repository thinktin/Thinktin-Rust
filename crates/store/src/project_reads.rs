//! 项目成员的读（8.15，docs/projects.md 第 5 节，docs/projects-impl.md 第 2 条）：`thinktin_member` 角色的只读事务。
//!
//! 读得到哪些行由库里的策略按 `member_projects()` 算：只看 `app.user_id`，我是存活成员、项目进行中或归档、我没注销。
//! 没有“当前项目”这种设置，传别的项目 id 也读不到；退出、被移出、项目删了，下一个请求就读不到了。
//! [`ProjectTx`] 不是 `Tx<R>`：那些通用的方法（写事件、写收件箱、拿锁……）在这里一个都没有，能做什么在编译时就定了。

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use proto::domain::{
    ArtifactId, InstanceId, ProjectAgentView, ProjectArtifact, ProjectAuthor, ProjectAuthorStatus,
    ProjectBudget, ProjectDetail, ProjectId, ProjectLimits, ProjectMemberView, ProjectPerson,
    ProjectRun, ProjectRunEvent, ProjectRunEvents, ProjectStatus, ProjectSummary, RunId, UserId,
};
use serde_json::Value;
use sqlx::{PgConnection, Postgres, Transaction};
use uuid::Uuid;

use crate::{Error, Result, parse, unsigned};

/// 列项目运行：只看一个 agent 的（`instance`）、往下翻（`before`）、一页多少（1 到 200）。
#[derive(Debug, Clone, Copy, Default)]
pub struct ProjectRunFilter {
    pub instance: Option<InstanceId>,
    pub before: Option<RunId>,
    pub limit: u32,
}

/// 库里的 project_run* 函数返回的一行（成员能看的字段）。
#[derive(sqlx::FromRow)]
struct RunRow {
    id: Uuid,
    kind: String,
    user_id: Uuid,
    instance_id: Uuid,
    parent_run_id: Option<Uuid>,
    root_run_id: Uuid,
    step_key: Option<String>,
    source: String,
    prompt: String,
    state: String,
    summary: Option<String>,
    created_at: DateTime<Utc>,
    started_at: Option<DateTime<Utc>>,
    finished_at: Option<DateTime<Utc>>,
}

const RUN_COLUMNS: &str = "id, kind, user_id, instance_id, parent_run_id, root_run_id, step_key, source, prompt, \
     state, summary, created_at, started_at, finished_at";

type ArtifactRow = (
    Uuid,
    Uuid,
    Uuid,
    Uuid,
    Uuid,
    String,
    i32,
    String,
    i64,
    Vec<u8>,
    DateTime<Utc>,
);

const ARTIFACT_COLUMNS: &str = "id, user_id, instance_id, run_id, root_run_id, name, version, content_type, size, \
     sha256, created_at";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// 内容的主人在不在：存活成员带 id 和昵称；退出的、注销的不带（没有成员行的按退出算）。
pub(crate) fn author(authors: &HashMap<Uuid, ProjectAuthor>, user: Uuid) -> ProjectAuthor {
    authors.get(&user).cloned().unwrap_or(ProjectAuthor {
        user_id: None,
        display_name: None,
        status: ProjectAuthorStatus::Left,
    })
}

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
type AgentRow = (Uuid, Uuid, String, String, bool, i32, DateTime<Utc>, bool);

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

    /// 项目里每个（曾经的）成员现在的样子。
    pub(crate) async fn authors(
        &mut self,
        project: ProjectId,
    ) -> Result<HashMap<Uuid, ProjectAuthor>> {
        let rows: Vec<(Uuid, Option<String>, bool, bool)> = sqlx::query_as(
            "SELECT m.user_id, CASE WHEN m.left_at IS NULL THEN u.display_name END, m.left_at IS NULL, \
                    coalesce(m.left_reason = 'erased', false) \
               FROM project_members m LEFT JOIN users u ON u.id = m.user_id WHERE m.project_id = $1",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?;
        Ok(rows
            .into_iter()
            .map(|(id, name, live, erased)| {
                let a = if live {
                    ProjectAuthor {
                        user_id: Some(UserId(id)),
                        display_name: name,
                        status: ProjectAuthorStatus::Member,
                    }
                } else {
                    ProjectAuthor {
                        user_id: None,
                        display_name: None,
                        status: if erased {
                            ProjectAuthorStatus::Erased
                        } else {
                            ProjectAuthorStatus::Left
                        },
                    }
                };
                (id, a)
            })
            .collect())
    }

    fn run(
        &self,
        project: ProjectId,
        row: RunRow,
        authors: &HashMap<Uuid, ProjectAuthor>,
    ) -> Result<ProjectRun> {
        Ok(ProjectRun {
            id: RunId(row.id),
            project_id: project,
            instance_id: InstanceId(row.instance_id),
            owner: author(authors, row.user_id),
            mine: row.user_id == self.user.0,
            kind: parse(&row.kind)?,
            source: parse(&row.source)?,
            parent_run_id: row.parent_run_id.map(RunId),
            root_run_id: RunId(row.root_run_id),
            step_key: row.step_key,
            prompt: row.prompt,
            state: parse(&row.state)?,
            summary: row.summary,
            created_at: row.created_at,
            started_at: row.started_at,
            finished_at: row.finished_at,
        })
    }

    /// 项目的运行，新的在前（只有成员能看的字段，库里的 project_runs() 挑好）。
    pub async fn project_runs(
        &mut self,
        project: ProjectId,
        f: &ProjectRunFilter,
    ) -> Result<Vec<ProjectRun>> {
        self.require_project(project).await?;
        let rows: Vec<RunRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {RUN_COLUMNS} FROM project_runs($1, $2, $3, $4)"
        )))
        .bind(project.0)
        .bind(f.instance.map(|i| i.0))
        .bind(f.before.map(|r| r.0))
        .bind(f.limit.clamp(1, 200) as i32)
        .fetch_all(self.conn())
        .await?;
        let authors = self.authors(project).await?;
        rows.into_iter()
            .map(|r| self.run(project, r, &authors))
            .collect()
    }

    /// 项目里的一个运行；不在这个项目里、我读不到的 NotFound。
    pub async fn project_run(&mut self, project: ProjectId, run: RunId) -> Result<ProjectRun> {
        let row: RunRow = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {RUN_COLUMNS} FROM project_run($1, $2)"
        )))
        .bind(project.0)
        .bind(run.0)
        .fetch_one(self.conn())
        .await?;
        let authors = self.authors(project).await?;
        self.run(project, row, &authors)
    }

    /// 一个项目运行所在的整棵树（先建的在前，最多 500 个）。
    pub async fn project_run_tree(
        &mut self,
        project: ProjectId,
        run: RunId,
    ) -> Result<Vec<ProjectRun>> {
        let root = self.project_run(project, run).await?.root_run_id;
        let rows: Vec<RunRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {RUN_COLUMNS} FROM project_run_tree($1, $2)"
        )))
        .bind(project.0)
        .bind(root.0)
        .fetch_all(self.conn())
        .await?;
        let authors = self.authors(project).await?;
        rows.into_iter()
            .map(|r| self.run(project, r, &authors))
            .collect()
    }

    /// 一个项目运行最近的事件（白名单里的种类和字段，旧的在前，最多 `limit` 条，1 到 500）；更早的没给时 `truncated`。
    pub async fn project_run_events(
        &mut self,
        project: ProjectId,
        run: RunId,
        limit: u32,
    ) -> Result<ProjectRunEvents> {
        self.project_run(project, run).await?;
        let limit = limit.clamp(1, 500) as usize;
        let mut rows: Vec<(String, Value, DateTime<Utc>)> =
            sqlx::query_as("SELECT kind, data, created_at FROM project_run_events($1, $2, $3)")
                .bind(project.0)
                .bind(run.0)
                .bind((limit + 1) as i32)
                .fetch_all(self.conn())
                .await?;
        let truncated = rows.len() > limit;
        if truncated {
            rows.drain(..rows.len() - limit);
        }
        Ok(ProjectRunEvents {
            events: rows
                .into_iter()
                .map(|(kind, data, created_at)| ProjectRunEvent {
                    run_id: run,
                    kind,
                    data,
                    created_at,
                })
                .collect(),
            truncated,
        })
    }

    fn artifact(
        &self,
        project: ProjectId,
        row: ArtifactRow,
        authors: &HashMap<Uuid, ProjectAuthor>,
    ) -> Result<ProjectArtifact> {
        let (id, owner, instance, run, root, name, version, content_type, size, sha256, created_at) =
            row;
        Ok(ProjectArtifact {
            id: ArtifactId(id),
            project_id: project,
            instance_id: InstanceId(instance),
            run_id: RunId(run),
            root_run_id: RunId(root),
            author: author(authors, owner),
            mine: owner == self.user.0,
            name,
            version: u32::try_from(version)
                .map_err(|_| Error::Corrupt("artifact version".into()))?,
            content_type,
            size: unsigned(size, "artifact size")?,
            sha256: hex(&sha256),
            created_at,
        })
    }

    /// 项目的产出物，新的在前（1 到 200 条）。
    pub async fn project_artifacts(
        &mut self,
        project: ProjectId,
        before: Option<ArtifactId>,
        limit: u32,
    ) -> Result<Vec<ProjectArtifact>> {
        self.require_project(project).await?;
        let rows: Vec<ArtifactRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {ARTIFACT_COLUMNS} FROM artifacts \
              WHERE project_id = $1 AND ($2::uuid IS NULL OR id < $2) ORDER BY id DESC LIMIT $3"
        )))
        .bind(project.0)
        .bind(before.map(|a| a.0))
        .bind(i64::from(limit.clamp(1, 200)))
        .fetch_all(self.conn())
        .await?;
        let authors = self.authors(project).await?;
        rows.into_iter()
            .map(|r| self.artifact(project, r, &authors))
            .collect()
    }

    /// 项目的一个产出物（不在这个项目里的 NotFound）。
    pub async fn project_artifact(
        &mut self,
        project: ProjectId,
        id: ArtifactId,
    ) -> Result<ProjectArtifact> {
        let row: ArtifactRow = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {ARTIFACT_COLUMNS} FROM artifacts WHERE project_id = $1 AND id = $2"
        )))
        .bind(project.0)
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        let authors = self.authors(project).await?;
        self.artifact(project, row, &authors)
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
            "SELECT a.instance_id, a.user_id, i.agent_id, i.name, a.is_lead, a.position, a.added_at, \
                    a.dedicated \
               FROM project_agents a JOIN instances i ON i.id = a.instance_id \
              WHERE a.project_id = $1 AND a.left_at IS NULL ORDER BY a.position, a.instance_id",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?;
        let agents = agents
            .into_iter()
            .map(
                |(instance, owner, agent_id, name, is_lead, position, added_at, dedicated)| {
                    ProjectAgentView {
                        instance_id: InstanceId(instance),
                        owner_id: UserId(owner),
                        agent_id,
                        name,
                        is_lead,
                        position: u32::try_from(position).unwrap_or_default(),
                        added_at,
                        mine: owner == user.0,
                        dedicated,
                    }
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
