//! 项目的删除、归档和清理（8.15，docs/projects.md 第 4.6 节，docs/projects-impl.md 第 7 条）。
//!
//! 删除一律软删除：一个短的 worker 事务里标成 `deleted`（成员读、租户读马上都看不到）、删掉项目密钥（项目产出物再也解不
//! 开）、撤回邀请、停掉项目里的运行和授权、把成员的项目提醒标已读；内容由后台清理按批删掉（每批一个事务、不等锁，崩了
//! 从剩下的接着删），最后删项目这一行。归档：只读，停掉运行和授权，agent 留着。都按 8.14 的加锁顺序（D3）。

use std::time::Duration;

use chrono::{DateTime, Utc};
use proto::domain::{ArtifactId, Locale, ProjectId, ProjectStatus, UserId};
use uuid::Uuid;

use crate::{Error, Result, StoredArtifact, Tx, Worker, parse, secs, signed};

/// 删了一个项目：给谁发回执（删之前锁住了的存活成员，不含创建者）和停掉了什么。
#[derive(Debug, Clone)]
pub struct DeletedProject {
    pub project: ProjectId,
    pub name: String,
    pub creator: UserId,
    pub notify: Vec<UserId>,
    pub shared: bool,
    pub invites_revoked: u64,
    pub runs_cancelled: u64,
    pub grants_revoked: u64,
}

impl Tx<Worker> {
    /// 把这些人收件箱里这个项目的提醒（回执除外）标已读：项目删了、人退出了，这些行就看不到了，角标不能留着。
    /// `nowait`：收件人的用户行没锁着的不等锁（D3）。
    pub(crate) async fn read_project_notices(
        &mut self,
        project: ProjectId,
        users: &[UserId],
        nowait: bool,
    ) -> Result<()> {
        if users.is_empty() {
            return Ok(());
        }
        let ids: Vec<Uuid> = users.iter().map(|u| u.0).collect();
        let sql = if nowait {
            "UPDATE inbox_items SET read_at = now() WHERE id IN ( \
               SELECT id FROM inbox_items WHERE project_id = $1 AND user_id = ANY($2) AND read_at IS NULL \
                  AND NOT coalesce(project_receipt(subtype), false) FOR UPDATE SKIP LOCKED)"
        } else {
            "UPDATE inbox_items SET read_at = now() WHERE id IN ( \
               SELECT id FROM inbox_items WHERE project_id = $1 AND user_id = ANY($2) AND read_at IS NULL \
                  AND NOT coalesce(project_receipt(subtype), false))"
        };
        sqlx::query(sql)
            .bind(project.0)
            .bind(&ids)
            .execute(self.conn())
            .await?;
        Ok(())
    }

    /// 停掉项目里的事：锁 agent 行 → 取消运行（等着的审批一起作废）→ 吊销授权；`mark_left` 时 agent 都标离开。
    pub(crate) async fn stop_project(
        &mut self,
        project: ProjectId,
        reason: &str,
        mark_left: bool,
    ) -> Result<(u64, u64)> {
        sqlx::query(
            "SELECT 1 FROM project_agents WHERE project_id = $1 AND left_at IS NULL \
              ORDER BY instance_id FOR NO KEY UPDATE",
        )
        .bind(project.0)
        .execute(self.conn())
        .await?;
        let runs = self.cancel_project_runs(project, reason).await?;
        let grants = self.revoke_project_grants(project, reason).await?;
        if mark_left {
            sqlx::query(
                "UPDATE project_agents SET is_lead = false, left_at = now() \
                  WHERE project_id = $1 AND left_at IS NULL",
            )
            .bind(project.0)
            .execute(self.conn())
            .await?;
        }
        Ok((runs, grants))
    }

    /// 撤回项目里还没处理的邀请，送达的提醒标已读（`locked` 里的收件人直接改，别的不等锁）。返回撤回了几个。
    pub(crate) async fn revoke_pending_invites(
        &mut self,
        project: ProjectId,
        locked: &[UserId],
    ) -> Result<u64> {
        let revoked: Vec<(Uuid, Option<Uuid>)> = sqlx::query_as(
            "UPDATE project_invites SET status = 'revoked', settled_at = now() \
              WHERE project_id = $1 AND status = 'pending' RETURNING id, invitee_id",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?;
        let (mine, other): (Vec<_>, Vec<_>) = revoked
            .iter()
            .copied()
            .partition(|(_, u)| u.is_some_and(|u| locked.contains(&UserId(u))));
        for (id, u) in &mine {
            if let Some(u) = u {
                self.read_invite_items(UserId(*u), &[*id]).await?;
            }
        }
        self.read_invite_items_nowait(&other).await?;
        Ok(revoked.len() as u64)
    }

    /// 还没处理的邀请发给了谁、还有谁是存活成员（不加锁的预读，给 [`Tx::project_actor`] 的 `also` 先锁用户行）。
    async fn project_people(&mut self, project: ProjectId) -> Result<Vec<UserId>> {
        Ok(sqlx::query_scalar::<_, Uuid>(
            "SELECT invitee_id FROM project_invites \
              WHERE project_id = $1 AND status = 'pending' AND invitee_id IS NOT NULL \
             UNION SELECT user_id FROM project_members WHERE project_id = $1 AND left_at IS NULL",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?
        .into_iter()
        .map(UserId)
        .collect())
    }

    /// 删项目（只有创建者；成员 NotPermitted，外人 NotFound）。共享过的只在 `allow_shared` 时删（旧的团队接口不删，回
    /// Conflict）。软删除：马上读不到、密钥删掉，内容由 [`Tx::purge_deleted_projects`] 清理。
    pub async fn delete_project(
        &mut self,
        user: UserId,
        project: ProjectId,
        allow_shared: bool,
    ) -> Result<DeletedProject> {
        let people = self.project_people(project).await?;
        let actor = self
            .project_actor(
                user,
                project,
                &people,
                &[ProjectStatus::Active, ProjectStatus::Archived],
            )
            .await?;
        actor.require_creator("delete the project")?;
        let (name, shared): (String, bool) =
            sqlx::query_as("SELECT name, shared_at IS NOT NULL FROM projects WHERE id = $1")
                .bind(project.0)
                .fetch_one(self.conn())
                .await?;
        if shared && !allow_shared {
            return Err(Error::Conflict("project is shared".into()));
        }
        sqlx::query(
            "UPDATE projects SET status = 'deleted', deleted_at = now(), updated_at = now() WHERE id = $1",
        )
        .bind(project.0)
        .execute(self.conn())
        .await?;
        sqlx::query("DELETE FROM project_keys WHERE project_id = $1")
            .bind(project.0)
            .execute(self.conn())
            .await?;
        let locked: Vec<UserId> = actor.users.iter().map(|u| u.id).collect();
        let invites_revoked = self.revoke_pending_invites(project, &locked).await?;
        let (runs_cancelled, grants_revoked) =
            self.stop_project(project, "project deleted", true).await?;
        // 专属于它的实例换成全新的私人工作区（8.16，锁着的由后台清理兜底）。
        self.retire_project_workspaces(project).await?;
        let members: Vec<UserId> = sqlx::query_scalar::<_, Uuid>(
            "SELECT user_id FROM project_members WHERE project_id = $1 AND left_at IS NULL",
        )
        .bind(project.0)
        .fetch_all(self.conn())
        .await?
        .into_iter()
        .map(UserId)
        .collect();
        let (known, late): (Vec<UserId>, Vec<UserId>) =
            members.into_iter().partition(|m| locked.contains(m));
        self.read_project_notices(project, &known, false).await?;
        self.read_project_notices(project, &late, true).await?;
        Ok(DeletedProject {
            project,
            name,
            creator: actor.creator,
            // 预读之后才加入的人没锁用户行，不给他写收件箱（D3）。
            notify: known.into_iter().filter(|m| *m != actor.creator).collect(),
            shared,
            invites_revoked,
            runs_cancelled,
            grants_revoked,
        })
    }

    /// 归档（只有创建者）：只读，撤回邀请，停掉运行和授权，agent 留着。已经归档的返回 false。
    pub async fn archive_project(&mut self, user: UserId, project: ProjectId) -> Result<bool> {
        let people = self.project_people(project).await?;
        let actor = self
            .project_actor(
                user,
                project,
                &people,
                &[ProjectStatus::Active, ProjectStatus::Archived],
            )
            .await?;
        actor.require_creator("archive the project")?;
        let status: String = sqlx::query_scalar("SELECT status FROM projects WHERE id = $1")
            .bind(project.0)
            .fetch_one(self.conn())
            .await?;
        if parse::<ProjectStatus>(&status)? == ProjectStatus::Archived {
            return Ok(false);
        }
        sqlx::query(
            "UPDATE projects SET status = 'archived', archived_at = now(), updated_at = now() WHERE id = $1",
        )
        .bind(project.0)
        .execute(self.conn())
        .await?;
        let locked: Vec<UserId> = actor.users.iter().map(|u| u.id).collect();
        self.revoke_pending_invites(project, &locked).await?;
        self.stop_project(project, "project archived", false)
            .await?;
        Ok(true)
    }

    /// 取消归档（只有创建者）：又能改了；停掉的运行不恢复。不是归档的返回 false。
    pub async fn unarchive_project(&mut self, user: UserId, project: ProjectId) -> Result<bool> {
        let actor = self
            .project_actor(
                user,
                project,
                &[],
                &[ProjectStatus::Active, ProjectStatus::Archived],
            )
            .await?;
        actor.require_creator("unarchive the project")?;
        let done = sqlx::query(
            "UPDATE projects SET status = 'active', archived_at = NULL, updated_at = now() \
              WHERE id = $1 AND status = 'archived'",
        )
        .bind(project.0)
        .execute(self.conn())
        .await?;
        Ok(done.rows_affected() == 1)
    }

    /// 下载项目产出物之前（8.15 D15）：在同一句 SQL 里核对我还是存活成员（按 `member_projects()`，所以先在这个 worker
    /// 事务里设 app.user_id）、项目没删、密钥还在，一起取出存储位置、包裹的密钥和我的语言。读不到 NotFound。
    pub async fn project_artifact_blob(
        &mut self,
        user: UserId,
        project: ProjectId,
        id: ArtifactId,
    ) -> Result<(StoredArtifact, String, Vec<u8>, Locale)> {
        sqlx::query("SELECT set_config('app.user_id', $1, true)")
            .bind(user.to_string())
            .execute(self.conn())
            .await?;
        let (artifact_id, kid, wrapped, locale): (Uuid, String, Vec<u8>, String) = sqlx::query_as(
            "SELECT a.id, k.kms_key_id, k.wrapped_dek, u.locale FROM artifacts a \
               JOIN project_keys k ON k.project_id = a.project_id \
               JOIN users u ON u.id = $1 \
              WHERE a.id = $3 AND a.project_id = $2 AND a.project_id IN (SELECT member_projects())",
        )
        .bind(user.0)
        .bind(project.0)
        .bind(id.0)
        .fetch_one(self.conn())
        .await?;
        let stored = self.artifact(ArtifactId(artifact_id)).await?;
        Ok((stored, kid, wrapped, parse(&locale)?))
    }

    /// 已经清理掉的项目里、处理完了的举报（8.16：没处理的留给运营，处理完以后在这里删）。不等锁。返回删了几条。
    pub async fn purge_closed_project_reports(&mut self, limit: i64) -> Result<u64> {
        Ok(sqlx::query(
            "DELETE FROM content_reports WHERE id IN (SELECT id FROM content_reports c \
               WHERE c.state = 'closed' AND c.project_id IS NOT NULL \
                 AND NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = c.project_id) \
               LIMIT $1 FOR UPDATE SKIP LOCKED)",
        )
        .bind(limit)
        .execute(self.conn())
        .await?
        .rows_affected())
    }

    /// 后台清理删了的项目（过了 `grace` 才动）：一次调用一个事务、不等锁；按产出物 → 项目提醒 → 事件 → 运行 → 授权的顺序
    /// 删，都删完了再删项目这一行（成员、agent、邀请级联）。一次最多删 `batch` 行，分给这次拿到的几个项目（每个最多分到
    /// 一份），一个大项目占不满所有轮次，小项目一次删完接着删下一个。返回这次删了几行（0：没有能删的了）。
    pub async fn purge_deleted_projects(&mut self, batch: u64, grace: Duration) -> Result<u64> {
        let batch = signed(batch, "batch")?;
        // 外键的级联（运行删了，提醒的 run_id 置空）会等别人锁着的行：等不到就这一轮放弃，下一轮再来。
        sqlx::query("SELECT set_config('lock_timeout', '2s', true)")
            .execute(self.conn())
            .await?;
        let candidates: Vec<(Uuid, DateTime<Utc>)> = sqlx::query_as(
            "SELECT id, deleted_at FROM projects \
              WHERE status = 'deleted' AND deleted_at < now() - make_interval(secs => $1) \
              ORDER BY deleted_at, id LIMIT 20",
        )
        .bind(secs(grace))
        .fetch_all(self.conn())
        .await?;
        if candidates.is_empty() {
            return Ok(0);
        }
        let share = (batch / candidates.len() as i64).max(1);
        let mut remaining = batch;
        let mut total = 0u64;
        for (id, _) in candidates {
            if remaining <= 0 {
                break;
            }
            let got: bool =
                sqlx::query_scalar("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))")
                    .bind(format!("project/{}", ProjectId(id)))
                    .fetch_one(self.conn())
                    .await?;
            if !got {
                continue;
            }
            // 这个项目这次最多删几行。
            let mut quota = share.min(remaining);
            for sql in [
                // 产出物（触发器把对象存储里的内容排进 blob_purge）。
                "DELETE FROM artifacts WHERE id IN (SELECT id FROM artifacts WHERE project_id = $1 \
                   ORDER BY id LIMIT $2)",
                // 项目提醒（回执留着：那是收件人自己的记录）。
                "DELETE FROM inbox_items WHERE id IN (SELECT id FROM inbox_items WHERE project_id = $1 \
                   AND NOT coalesce(project_receipt(subtype), false) LIMIT $2 FOR UPDATE SKIP LOCKED)",
                // 带运行的其余几张表（8.16，迁移 0056）：运行删了外键置空，项目还记着，所以先按项目删。举报只删处理完的
                // （没处理的留给运营，处理完以后由 sweep 删）。
                "DELETE FROM egress_requests WHERE id IN (SELECT id FROM egress_requests WHERE project_id = $1 \
                   LIMIT $2 FOR UPDATE SKIP LOCKED)",
                "DELETE FROM vault_requests WHERE id IN (SELECT id FROM vault_requests WHERE project_id = $1 \
                   LIMIT $2 FOR UPDATE SKIP LOCKED)",
                "DELETE FROM device_calls WHERE id IN (SELECT id FROM device_calls WHERE project_id = $1 \
                   LIMIT $2 FOR UPDATE SKIP LOCKED)",
                "DELETE FROM board_posts WHERE id IN (SELECT id FROM board_posts WHERE project_id = $1 \
                   ORDER BY id LIMIT $2 FOR UPDATE SKIP LOCKED)",
                "DELETE FROM content_reports WHERE id IN (SELECT id FROM content_reports WHERE project_id = $1 \
                   AND state = 'closed' LIMIT $2 FOR UPDATE SKIP LOCKED)",
                "DELETE FROM events WHERE (instance_id, seq, created_at) IN ( \
                   SELECT instance_id, seq, created_at FROM events \
                    WHERE run_id IN (SELECT id FROM runs WHERE project_id = $1) LIMIT $2)",
                // 运行（审批、工具调用、灵动岛级联）。新的先删：子运行在父运行前面。还有提醒指着的（上面跳过的、别人锁着
                // 的）先不删：删了外键要把提醒的 run_id 置空，就得等那一行。
                "DELETE FROM runs WHERE id IN (SELECT r.id FROM runs r WHERE r.project_id = $1 \
                   AND NOT EXISTS (SELECT 1 FROM inbox_items i WHERE i.project_id = $1 AND i.run_id = r.id) \
                   ORDER BY r.id DESC LIMIT $2)",
                "DELETE FROM run_grants WHERE id IN (SELECT id FROM run_grants WHERE project_id = $1 \
                   ORDER BY id DESC LIMIT $2)",
            ] {
                if quota <= 0 {
                    break;
                }
                let n = sqlx::query(sql)
                    .bind(id)
                    .bind(quota)
                    .execute(self.conn())
                    .await?
                    .rows_affected();
                total += n;
                quota -= n as i64;
                remaining -= n as i64;
            }
            if quota <= 0 {
                // 这次的份用完了，还没删完：下一次再来。
                continue;
            }
            // 专属于它的实例（8.16）：删项目时锁着的、还没换工作区的，这里换；实例已经删了的（还等着清理）把项目、归档键
            // 清掉（触发器把项目下的归档对象排进清理）。
            let retired = self.retire_project_workspaces(ProjectId(id)).await?;
            let cleared = sqlx::query(
                "UPDATE instances SET workspace_project_id = NULL, workspace_archive_key = NULL, \
                   workspace_archive_id = NULL, workspace_archive_bytes = NULL, workspace_archive_sha256 = NULL, \
                   workspace_archived_at = NULL, workspace_archive_pending = NULL, \
                   workspace_archive_pending_since = NULL \
                 WHERE id IN (SELECT id FROM instances WHERE workspace_project_id = $1 AND state = 'deleted' \
                              FOR UPDATE SKIP LOCKED)",
            )
            .bind(id)
            .execute(self.conn())
            .await?
            .rows_affected();
            total += retired + cleared;
            remaining -= (retired + cleared) as i64;
            // 都删完了（跳过的提醒还在的，下一轮再来）。
            let left: bool = sqlx::query_scalar(
                "SELECT EXISTS (SELECT 1 FROM runs WHERE project_id = $1) \
                     OR EXISTS (SELECT 1 FROM artifacts WHERE project_id = $1) \
                     OR EXISTS (SELECT 1 FROM run_grants WHERE project_id = $1) \
                     OR EXISTS (SELECT 1 FROM inbox_items WHERE project_id = $1 \
                                  AND NOT coalesce(project_receipt(subtype), false)) \
                     OR EXISTS (SELECT 1 FROM egress_requests WHERE project_id = $1) \
                     OR EXISTS (SELECT 1 FROM vault_requests WHERE project_id = $1) \
                     OR EXISTS (SELECT 1 FROM device_calls WHERE project_id = $1) \
                     OR EXISTS (SELECT 1 FROM board_posts WHERE project_id = $1) \
                     OR EXISTS (SELECT 1 FROM instances WHERE workspace_project_id = $1)",
            )
            .bind(id)
            .fetch_one(self.conn())
            .await?;
            if left {
                continue;
            }
            let n = sqlx::query("DELETE FROM projects WHERE id = $1 AND status = 'deleted'")
                .bind(id)
                .execute(self.conn())
                .await?
                .rows_affected();
            total += n;
            remaining -= n as i64;
        }
        Ok(total)
    }
}
