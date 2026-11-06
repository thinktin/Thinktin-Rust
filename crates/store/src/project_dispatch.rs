//! 派单（8.17，迁移 0060）：可执行的项目运行、项目授权只从这里写。库里的开关（一行，默认关）在老副本都退出以后由运维
//! 打开（`thinktin-server admin project-dispatch on`）；写入时的栅栏核对开关、协议、agent 还在。

use proto::domain::ProjectId;
use uuid::Uuid;

use crate::{Result, Tx, Worker};

impl Tx<Worker> {
    /// 派单开关开着没有。
    pub async fn project_dispatch_enabled(&mut self) -> Result<bool> {
        Ok(
            sqlx::query_scalar("SELECT enabled FROM project_dispatch WHERE id")
                .fetch_optional(self.conn())
                .await?
                .unwrap_or(false),
        )
    }

    /// 开、关派单开关，记下谁、为什么。关的时候等已经过了栅栏、还没提交的派单（栅栏 `FOR SHARE` 读这一行），之后
    /// 再取消没结束的项目运行（[`Tx::projects_with_unfinished_runs`]），不会漏掉在途的。
    pub async fn set_project_dispatch(
        &mut self,
        enabled: bool,
        by: &str,
        reason: Option<&str>,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE project_dispatch SET enabled = $1, changed_at = now(), changed_by = $2, reason = $3 WHERE id",
        )
        .bind(enabled)
        .bind(by)
        .bind(reason)
        .execute(self.conn())
        .await?;
        Ok(())
    }

    /// 还有没结束的运行的项目（关开关以后逐个取消用）。
    pub async fn projects_with_unfinished_runs(&mut self, limit: i64) -> Result<Vec<ProjectId>> {
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "SELECT DISTINCT project_id FROM runs WHERE project_id IS NOT NULL \
               AND state NOT IN ('succeeded', 'failed', 'cancelled') LIMIT $1",
        )
        .bind(limit)
        .fetch_all(self.conn())
        .await?;
        Ok(ids.into_iter().map(ProjectId).collect())
    }
}
