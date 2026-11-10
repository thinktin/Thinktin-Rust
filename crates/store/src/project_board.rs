//! 项目看板（8.17，迁移 0062）：归项目所有，成员（在 App 里）和成员派进项目的 agent 都能写、都能读；租户没有任何权限，
//! 私人看板的老读法碰不到它。写走 worker（核对成员关系、agent 还在），读走成员的只读事务。
//!
//! - 和私人看板一样：写了不改，只能归档、删；没归档的最多 [`MAX_BOARD_LIVE_POSTS`] 条，满了最早的自动归档；归档的过
//!   [`crate::BOARD_ARCHIVE_RETENTION`] 由维护任务删掉。
//! - 成员自己写的每人每天最多 [`MAX_PROJECT_BOARD_POSTS_PER_DAY`] 条（agent 写的按运行的上限，编排层管）。
//! - 内容原样存取；交给 agent 时由调用方注明是不可信输入。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    BoardPostId, InstanceId, MAX_BOARD_LIVE_POSTS, MAX_PROJECT_BOARD_POSTS_PER_DAY,
    ProjectBoardPost, ProjectId, ProjectStatus, RunId, UserId,
};
use uuid::Uuid;

use crate::board::BoardFilter;
use crate::project_reads::author;
use crate::{Error, ProjectTx, Result, Tx, Worker, secs, unsigned};

/// 谁写的：成员自己（App 里），或者项目里的一个运行（agent 用看板工具）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoardWriter {
    Member(UserId),
    Agent(RunId),
}

/// 写一条（正文、标签先用 [`crate::check_board_body`]、[`crate::normalize_board_tags`] 查过）。
#[derive(Debug, Clone, Default)]
pub struct NewProjectBoardPost {
    pub body: String,
    pub tags: Vec<String>,
}

type PostRow = (
    Uuid,
    Uuid,
    Option<Uuid>,
    Option<String>,
    Option<Uuid>,
    bool,
    String,
    Vec<String>,
    DateTime<Utc>,
    Option<DateTime<Utc>>,
);

const POST_SELECT: &str = "SELECT b.id, b.author_user_id, b.author_instance_id, i.name, b.run_id, b.by_agent, \
       b.body, b.tags, b.created_at, b.archived_at \
  FROM project_board_posts b LEFT JOIN instances i ON i.id = b.author_instance_id ";

impl Tx<Worker> {
    /// 往项目看板上写一条（8.17）。成员：要是存活成员、项目开着、今天手动写的没到上限；agent：它这个运行在项目里、
    /// agent 还在、运行没结束。在项目锁里把超出上限的最早的条目归档。返回新条目的 id 和这次自动归档了几条。
    pub async fn post_to_project_board(
        &mut self,
        by: BoardWriter,
        p: ProjectId,
        new: &NewProjectBoardPost,
    ) -> Result<(BoardPostId, u64)> {
        let (author, instance, run) = match by {
            BoardWriter::Member(user) => {
                self.project_actor(user, p, &[], &[ProjectStatus::Active])
                    .await?;
                // 等多久：24 小时窗口里最早的一条过了窗口为止（按库里的时钟算，和邀请一样）。
                let (today, wait): (i64, Option<i64>) = sqlx::query_as(
                    "SELECT count(*), \
                            ceil(extract(epoch FROM min(created_at) + interval '1 day' - now()))::bigint \
                       FROM project_board_posts WHERE project_id = $1 AND author_user_id = $2 \
                        AND NOT by_agent AND created_at > now() - interval '1 day'",
                )
                .bind(p.0)
                .bind(user.0)
                .fetch_one(self.conn())
                .await?;
                if unsigned(today, "board posts")? >= MAX_PROJECT_BOARD_POSTS_PER_DAY {
                    let wait = wait.and_then(|w| u64::try_from(w).ok()).unwrap_or(1);
                    return Err(Error::RetryAfter(wait.max(1)));
                }
                (user, None, None)
            }
            BoardWriter::Agent(run) => {
                let actor = self.project_agent_actor(run, p, &[]).await?;
                (actor.owner, Some(actor.instance), Some(run))
            }
        };
        let archived = sqlx::query(
            "UPDATE project_board_posts SET archived_at = now() WHERE id IN ( \
               SELECT id FROM project_board_posts WHERE project_id = $1 AND archived_at IS NULL \
                ORDER BY coalesce(revived_at, created_at) DESC, id DESC OFFSET $2)",
        )
        .bind(p.0)
        .bind(i64::try_from(MAX_BOARD_LIVE_POSTS - 1).unwrap_or(i64::MAX))
        .execute(self.conn())
        .await?
        .rows_affected();
        let id = BoardPostId::new();
        sqlx::query(
            "INSERT INTO project_board_posts (id, project_id, author_user_id, author_instance_id, run_id, by_agent, \
                                              body, tags) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        )
        .bind(id.0)
        .bind(p.0)
        .bind(author.0)
        .bind(instance.map(|i: InstanceId| i.0))
        .bind(run.map(|r: RunId| r.0))
        .bind(run.is_some())
        .bind(&new.body)
        .bind(&new.tags)
        .execute(self.conn())
        .await?;
        Ok((id, archived))
    }

    /// 能管这一条的（创建者，或者是自己写的、自己的 agent 写的）：锁着这一条，返回它归不归档。别人的 NotPermitted；
    /// 不在这个项目里的 NotFound。
    async fn manage_project_board_post(
        &mut self,
        user: UserId,
        p: ProjectId,
        post: BoardPostId,
    ) -> Result<bool> {
        let actor = self
            .project_actor(user, p, &[], &[ProjectStatus::Active])
            .await?;
        let row: Option<(Uuid, bool)> = sqlx::query_as(
            "SELECT author_user_id, archived_at IS NOT NULL FROM project_board_posts \
              WHERE id = $1 AND project_id = $2 FOR UPDATE",
        )
        .bind(post.0)
        .bind(p.0)
        .fetch_optional(self.conn())
        .await?;
        let Some((author, archived)) = row else {
            return Err(Error::NotFound);
        };
        if author != user.0 && actor.creator != user {
            return Err(Error::NotPermitted(
                "only the author or the project creator can change this post".into(),
            ));
        }
        Ok(archived)
    }

    /// 归档、取消归档（已经是那样的不动）；取消归档时没归档的满了拒绝（先归档别的）。
    pub async fn set_project_board_post_archived(
        &mut self,
        user: UserId,
        p: ProjectId,
        post: BoardPostId,
        archived: bool,
    ) -> Result<()> {
        let was = self.manage_project_board_post(user, p, post).await?;
        if was == archived {
            return Ok(());
        }
        if !archived {
            let live: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM project_board_posts WHERE project_id = $1 AND archived_at IS NULL",
            )
            .bind(p.0)
            .fetch_one(self.conn())
            .await?;
            if unsigned(live, "board posts")? >= MAX_BOARD_LIVE_POSTS {
                return Err(Error::Invalid(format!(
                    "the board already has {MAX_BOARD_LIVE_POSTS} posts; archive some first"
                )));
            }
        }
        sqlx::query(
            "UPDATE project_board_posts SET archived_at = CASE WHEN $2 THEN now() END, \
               revived_at = CASE WHEN $2 THEN revived_at ELSE now() END WHERE id = $1",
        )
        .bind(post.0)
        .bind(archived)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    pub async fn delete_project_board_post(
        &mut self,
        user: UserId,
        p: ProjectId,
        post: BoardPostId,
    ) -> Result<()> {
        self.manage_project_board_post(user, p, post).await?;
        sqlx::query("DELETE FROM project_board_posts WHERE id = $1")
            .bind(post.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 删掉归档超过 `older_than` 的项目看板条目（维护任务），返回删了几条。
    pub async fn purge_archived_project_board_posts(
        &mut self,
        older_than: Duration,
    ) -> Result<u64> {
        Ok(sqlx::query(
            "DELETE FROM project_board_posts WHERE archived_at IS NOT NULL \
               AND archived_at < now() - make_interval(secs => $1)",
        )
        .bind(secs(older_than))
        .execute(self.conn())
        .await?
        .rows_affected())
    }

    /// 删项目里的一个产出物（8.17，8.15 留下的）：创建者，或者产出物的主人；别人 NotPermitted，不在项目里的 NotFound。
    /// 对象存储里的内容由触发器排进清理。
    pub async fn delete_project_artifact(
        &mut self,
        user: UserId,
        p: ProjectId,
        artifact: proto::domain::ArtifactId,
    ) -> Result<()> {
        let actor = self
            .project_actor(user, p, &[], &[ProjectStatus::Active])
            .await?;
        let owner: Option<Uuid> = sqlx::query_scalar(
            "SELECT user_id FROM artifacts WHERE id = $1 AND project_id = $2 FOR UPDATE",
        )
        .bind(artifact.0)
        .bind(p.0)
        .fetch_optional(self.conn())
        .await?;
        let Some(owner) = owner else {
            return Err(Error::NotFound);
        };
        if owner != user.0 && actor.creator != user {
            return Err(Error::NotPermitted(
                "only the creator or the artifact's owner can delete it".into(),
            ));
        }
        sqlx::query("DELETE FROM artifacts WHERE id = $1")
            .bind(artifact.0)
            .execute(self.conn())
            .await?;
        Ok(())
    }
}

impl ProjectTx {
    fn board_post_view(
        &self,
        p: ProjectId,
        creator: Uuid,
        row: PostRow,
        authors: &std::collections::HashMap<Uuid, proto::domain::ProjectAuthor>,
    ) -> ProjectBoardPost {
        let (id, by, instance, name, run, by_agent, body, tags, created_at, archived_at) = row;
        let mine = by == self.user().0;
        ProjectBoardPost {
            id: BoardPostId(id),
            project_id: p,
            author: author(authors, by),
            author_instance_id: instance.map(InstanceId),
            author_name: if by_agent { name } else { None },
            run_id: run.map(RunId),
            mine,
            can_manage: mine || creator == self.user().0,
            body,
            tags,
            ai_generated: by_agent,
            created_at,
            archived_at,
        }
    }

    async fn creator_of(&mut self, p: ProjectId) -> Result<Uuid> {
        Ok(
            sqlx::query_scalar("SELECT creator_id FROM projects WHERE id = $1")
                .bind(p.0)
                .fetch_one(self.conn())
                .await?,
        )
    }

    /// 项目看板（8.17），新的在前；按标签、看没归档的还是归档了的，`before` 往下翻（1 到 50 条）。撤下、删了的 agent
    /// 写的看不到名字。
    pub async fn project_board(
        &mut self,
        p: ProjectId,
        f: &BoardFilter,
    ) -> Result<Vec<ProjectBoardPost>> {
        self.require_project(p).await?;
        let archived = if f.archived {
            "b.archived_at IS NOT NULL"
        } else {
            "b.archived_at IS NULL"
        };
        let rows: Vec<PostRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{POST_SELECT} WHERE b.project_id = $1 AND {archived} \
               AND ($2::text IS NULL OR $2 = ANY(b.tags)) AND ($3::uuid IS NULL OR b.id < $3) \
             ORDER BY b.id DESC LIMIT $4"
        )))
        .bind(p.0)
        .bind(f.tag.as_deref().map(str::to_lowercase))
        .bind(f.before.map(|b| b.0))
        .bind(f.limit.clamp(1, 50))
        .fetch_all(self.conn())
        .await?;
        let creator = self.creator_of(p).await?;
        let authors = self.authors(p).await?;
        Ok(rows
            .into_iter()
            .map(|r| self.board_post_view(p, creator, r, &authors))
            .collect())
    }

    /// 项目看板上的一条（不在这个项目里的 NotFound）。
    pub async fn project_board_post(
        &mut self,
        p: ProjectId,
        id: BoardPostId,
    ) -> Result<ProjectBoardPost> {
        self.require_project(p).await?;
        let row: PostRow = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{POST_SELECT} WHERE b.project_id = $1 AND b.id = $2"
        )))
        .bind(p.0)
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        let creator = self.creator_of(p).await?;
        let authors = self.authors(p).await?;
        Ok(self.board_post_view(p, creator, row, &authors))
    }
}
