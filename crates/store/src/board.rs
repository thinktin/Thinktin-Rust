//! 共享看板（WBS 8.10）：每个用户一块，他的所有 agent（和他自己在 App 里）都能读写。
//!
//! - 写了的内容不改，只能归档、删除。没归档的最多 [`MAX_BOARD_LIVE_POSTS`] 条：写新的时按用户加锁再数，
//!   满了先把最早的归档（并发写也不会超；用户取消归档的按取消归档的时间算）；归档的过
//!   [`BOARD_ARCHIVE_RETENTION`] 由维护任务删掉。
//! - 内容是 agent 写的，这里原样存取；交给 agent 时由调用方注明是不可信输入。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{
    BoardPost, BoardPostId, InstanceId, MAX_BOARD_BODY_CHARS, MAX_BOARD_LIVE_POSTS, MAX_BOARD_TAGS,
    RunId, valid_board_tag,
};
use uuid::Uuid;

use crate::{Error, Result, Tenant, Tx, Worker, secs, unsigned};

/// 归档的条目留这么久，之后维护任务删掉。
pub const BOARD_ARCHIVE_RETENTION: Duration = Duration::from_secs(30 * 24 * 3600);

/// 写一条。
#[derive(Debug, Clone, Default)]
pub struct NewBoardPost {
    /// agent 写的：它的实例和运行。用户在 App 里写的都是空。
    pub author_instance_id: Option<InstanceId>,
    pub run_id: Option<RunId>,
    pub body: String,
    pub tags: Vec<String>,
}

/// 读看板：按标签、看没归档的还是归档了的，`before` 往下翻。
#[derive(Debug, Clone, Default)]
pub struct BoardFilter {
    pub tag: Option<String>,
    pub archived: bool,
    pub before: Option<BoardPostId>,
    pub limit: i64,
}

/// 标签转成小写、去重、排序，格式不对报 Invalid。
pub fn normalize_board_tags(tags: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for t in tags {
        let t = t.trim().to_lowercase();
        if !valid_board_tag(&t) {
            return Err(Error::Invalid(format!(
                "tag {t:?} must be 1-32 letters, digits, '-' or '_'"
            )));
        }
        if !out.contains(&t) {
            out.push(t);
        }
    }
    if out.len() > MAX_BOARD_TAGS {
        return Err(Error::Invalid(format!(
            "at most {MAX_BOARD_TAGS} tags per post"
        )));
    }
    out.sort();
    Ok(out)
}

/// 正文：去掉首尾空白，1–2000 个字，除了换行和制表符不能有控制字符。
pub fn check_board_body(body: &str) -> Result<String> {
    let body = body.trim();
    let n = body.chars().count();
    if n == 0 || n > MAX_BOARD_BODY_CHARS {
        return Err(Error::Invalid(format!(
            "a post must be 1-{MAX_BOARD_BODY_CHARS} characters"
        )));
    }
    if body
        .chars()
        .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return Err(Error::Invalid(
            "a post must not contain control characters".into(),
        ));
    }
    Ok(body.to_owned())
}

#[derive(sqlx::FromRow)]
struct Row {
    id: Uuid,
    author_instance_id: Option<Uuid>,
    author_name: Option<String>,
    run_id: Option<Uuid>,
    body: String,
    tags: Vec<String>,
    by_agent: bool,
    created_at: DateTime<Utc>,
    archived_at: Option<DateTime<Utc>>,
}

impl Row {
    fn into_post(self) -> BoardPost {
        BoardPost {
            id: self.id.into(),
            author_instance_id: self.author_instance_id.map(Into::into),
            author_name: self.author_name,
            run_id: self.run_id.map(Into::into),
            body: self.body,
            tags: self.tags,
            ai_generated: self.by_agent,
            created_at: self.created_at,
            archived_at: self.archived_at,
        }
    }
}

/// 带上作者名字（实例删了的没有）。
macro_rules! select {
    () => {
        "SELECT p.id, p.author_instance_id, i.name AS author_name, p.run_id, p.body, p.tags, p.by_agent, \
           p.created_at, p.archived_at \
         FROM board_posts p LEFT JOIN instances i ON i.id = p.author_instance_id AND i.state <> 'deleted' "
    };
}

impl Tx<Tenant> {
    /// 写一条（正文、标签先用 [`check_board_body`]、[`normalize_board_tags`] 查过）。按用户加锁：没归档的
    /// 满了先把最早的归档。返回写好的一条和这次自动归档了几条。
    pub async fn post_to_board(&mut self, new: &NewBoardPost) -> Result<(BoardPost, u64)> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("board/{}", self.user()))
            .execute(self.conn())
            .await?;
        // 用户取消归档的算新的（按取消归档的时间排），不然看板满着时它又第一个被归档。
        let archived = sqlx::query(
            "UPDATE board_posts SET archived_at = now() WHERE id IN ( \
               SELECT id FROM board_posts WHERE user_id = app_user_id() AND archived_at IS NULL \
               ORDER BY coalesce(revived_at, created_at) DESC, id DESC OFFSET $1)",
        )
        .bind(i64::try_from(MAX_BOARD_LIVE_POSTS - 1).unwrap_or(i64::MAX))
        .execute(self.conn())
        .await?
        .rows_affected();
        let id = BoardPostId::new();
        sqlx::query(
            "INSERT INTO board_posts (id, user_id, author_instance_id, run_id, body, tags, by_agent) \
             VALUES ($1, app_user_id(), $2, $3, $4, $5, $6)",
        )
        .bind(id.0)
        .bind(new.author_instance_id.map(|i| i.0))
        .bind(new.run_id.map(|r| r.0))
        .bind(&new.body)
        .bind(&new.tags)
        .bind(new.run_id.is_some())
        .execute(self.conn())
        .await?;
        Ok((self.board_post(id).await?, archived))
    }

    pub async fn board_post(&mut self, id: BoardPostId) -> Result<BoardPost> {
        let row: Row = sqlx::query_as(concat!(select!(), "WHERE p.id = $1"))
            .bind(id.0)
            .fetch_one(self.conn())
            .await?;
        Ok(row.into_post())
    }

    /// 看板上的条目，新的在前。没归档的、归档了的两条语句，各用得上自己的索引。
    pub async fn board_posts(&mut self, f: &BoardFilter) -> Result<Vec<BoardPost>> {
        let sql = if f.archived {
            concat!(
                select!(),
                "WHERE p.user_id = app_user_id() AND p.archived_at IS NOT NULL \
                 AND ($1::text IS NULL OR $1 = ANY(p.tags)) AND ($2::uuid IS NULL OR p.id < $2) \
                 ORDER BY p.id DESC LIMIT $3"
            )
        } else {
            concat!(
                select!(),
                "WHERE p.user_id = app_user_id() AND p.archived_at IS NULL \
                 AND ($1::text IS NULL OR $1 = ANY(p.tags)) AND ($2::uuid IS NULL OR p.id < $2) \
                 ORDER BY p.id DESC LIMIT $3"
            )
        };
        let rows: Vec<Row> = sqlx::query_as(sql)
            .bind(f.tag.as_deref().map(str::to_lowercase))
            .bind(f.before.map(|b| b.0))
            .bind(f.limit)
            .fetch_all(self.conn())
            .await?;
        Ok(rows.into_iter().map(Row::into_post).collect())
    }

    /// 归档、取消归档。已经是那样的不动（重试不出错）；取消归档时没归档的已经满了就拒绝（先归档别的）。
    pub async fn set_board_post_archived(
        &mut self,
        id: BoardPostId,
        archived: bool,
    ) -> Result<BoardPost> {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(format!("board/{}", self.user()))
            .execute(self.conn())
            .await?;
        let was_archived: bool =
            sqlx::query_scalar("SELECT archived_at IS NOT NULL FROM board_posts WHERE id = $1")
                .bind(id.0)
                .fetch_optional(self.conn())
                .await?
                .ok_or(Error::NotFound)?;
        if was_archived == archived {
            return self.board_post(id).await;
        }
        if !archived {
            let live: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM board_posts WHERE user_id = app_user_id() AND archived_at IS NULL",
            )
            .fetch_one(self.conn())
            .await?;
            if unsigned(live, "board posts")? >= MAX_BOARD_LIVE_POSTS {
                return Err(Error::Invalid(format!(
                    "the board already has {MAX_BOARD_LIVE_POSTS} posts; archive some first"
                )));
            }
        }
        sqlx::query(
            "UPDATE board_posts SET archived_at = CASE WHEN $2 THEN now() END, \
               revived_at = CASE WHEN $2 THEN revived_at ELSE now() END \
             WHERE id = $1",
        )
        .bind(id.0)
        .bind(archived)
        .execute(self.conn())
        .await?;
        self.board_post(id).await
    }

    pub async fn delete_board_post(&mut self, id: BoardPostId) -> Result<()> {
        let done = sqlx::query("DELETE FROM board_posts WHERE id = $1")
            .bind(id.0)
            .execute(self.conn())
            .await?;
        if done.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        Ok(())
    }
}

impl Tx<Worker> {
    /// 删掉归档超过 `older_than` 的看板条目（维护任务），返回删了几条。
    pub async fn purge_archived_board_posts(&mut self, older_than: Duration) -> Result<u64> {
        Ok(sqlx::query(
            "DELETE FROM board_posts WHERE archived_at IS NOT NULL \
               AND archived_at < now() - make_interval(secs => $1)",
        )
        .bind(secs(older_than))
        .execute(self.conn())
        .await?
        .rows_affected())
    }
}
