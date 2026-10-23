//! 程序和数据库的迁移对得上（WBS 2.9）。
//!
//! 生产上迁移由发布流程单独执行（`thinktin-server migrate`，用表的属主账号），之后才上新版本的程序。
//! 程序启动时核对它带的迁移都执行过，缺了就拒绝启动：滚动发布时新副本起不来，老副本照常服务，
//! 不会出现新代码查不存在的列。
//!
//! 迁移只加不删（先加新的；旧版本不再用了，下一次发布再删旧的，见 docs/release.md），所以数据库比程序新时
//! （回滚到上一版）照常启动，上一版的 `migrate` 也不报错。

use sqlx::migrate::Migrator;
use tracing::warn;

use crate::{Db, Error, Result};

/// 程序里带的迁移。
fn migrator() -> Migrator {
    sqlx::migrate!("./migrations")
}

/// 程序里带的迁移和数据库里执行过的对比（按版本号）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MigrationStatus {
    /// 程序带的、数据库还没执行的：先执行 `thinktin-server migrate`。
    pub pending: Vec<i64>,
    /// 数据库执行过、程序不认识的：数据库比程序新（比如回滚到了上一版）。不影响启动。
    pub newer: Vec<i64>,
    /// 执行过、但内容和程序里的不一样：发布过的迁移被改了。
    pub modified: Vec<i64>,
    /// 执行到一半失败、留在半截状态的。
    pub failed: Vec<i64>,
}

impl MigrationStatus {
    /// 这个程序不能在这个数据库上跑的原因；能跑时为 None。
    pub fn problem(&self) -> Option<String> {
        let mut out = Vec::new();
        if !self.failed.is_empty() {
            out.push(format!(
                "migrations {} failed halfway: repair the database by hand, then run \
                 `thinktin-server migrate` again",
                list(&self.failed)
            ));
        }
        if !self.modified.is_empty() {
            out.push(format!(
                "migrations {} were edited after they ran: a released migration must never change, \
                 add a new one instead",
                list(&self.modified)
            ));
        }
        if !self.pending.is_empty() {
            out.push(format!(
                "the database is missing migrations {} that this build needs: run \
                 `thinktin-server migrate` with the migration account first",
                list(&self.pending)
            ));
        }
        (!out.is_empty()).then(|| out.join("; "))
    }
}

fn list(versions: &[i64]) -> String {
    versions
        .iter()
        .map(i64::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

/// `embedded`：程序带的（版本、校验和）；`applied`：数据库里的（版本、校验和、是否成功）。
fn compare(embedded: &[(i64, Vec<u8>)], applied: &[(i64, Vec<u8>, bool)]) -> MigrationStatus {
    let mut status = MigrationStatus::default();
    for (version, checksum) in embedded {
        match applied.iter().find(|(v, _, _)| v == version) {
            None => status.pending.push(*version),
            Some((_, _, false)) => status.failed.push(*version),
            Some((_, done, true)) if done != checksum => status.modified.push(*version),
            Some(_) => {}
        }
    }
    for (version, _, success) in applied {
        if embedded.iter().any(|(v, _)| v == version) {
            continue;
        }
        if *success {
            status.newer.push(*version);
        } else {
            status.failed.push(*version);
        }
    }
    status.failed.sort_unstable();
    status
}

impl Db {
    /// 执行迁移。要用表的属主账号（迁移账号）连接；多个副本同时执行时由 sqlx 的咨询锁串行化。
    /// 数据库里有程序不认识的迁移（回滚到上一版时）不报错：迁移只加不删，上一版的程序在新表结构上照常能跑。
    pub async fn migrate(&self) -> Result<()> {
        let mut migrator = migrator();
        migrator.set_ignore_missing(true);
        migrator.run(&self.pool).await?;
        Ok(())
    }

    /// 程序带的迁移和数据库里执行过的对比。服务的登录账号要能读 `_sqlx_migrations`
    /// （迁移 0016 授权给了各个服务角色）。
    pub async fn migration_status(&self) -> Result<MigrationStatus> {
        let applied: Vec<(i64, Vec<u8>, bool)> = match sqlx::query_as(
            "SELECT version, checksum, success FROM _sqlx_migrations ORDER BY version",
        )
        .fetch_all(&self.pool)
        .await
        {
            Ok(rows) => rows,
            // 一次都没迁移过：表还不存在。
            Err(e) if e.as_database_error().and_then(|d| d.code()).as_deref() == Some("42P01") => {
                Vec::new()
            }
            Err(e) => return Err(e.into()),
        };
        let embedded: Vec<(i64, Vec<u8>)> = migrator()
            .iter()
            .filter(|m| !m.migration_type.is_down_migration())
            .map(|m| (m.version, m.checksum.to_vec()))
            .collect();
        Ok(compare(&embedded, &applied))
    }

    /// 启动时核对迁移：这一版要的迁移都执行过、发布过的迁移没被改过，否则返回 [`Error::Schema`] 说明原因。
    /// 数据库比程序新（回滚到了上一版）时记一条日志，照常返回。
    pub async fn check_migrations(&self) -> Result<MigrationStatus> {
        let status = self.migration_status().await?;
        if let Some(problem) = status.problem() {
            return Err(Error::Schema(problem));
        }
        if !status.newer.is_empty() {
            warn!(
                migrations = ?status.newer,
                "the database has migrations this build does not know (an older build after a rollback?)"
            );
        }
        Ok(status)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn embedded() -> Vec<(i64, Vec<u8>)> {
        vec![(1, vec![1]), (2, vec![2]), (3, vec![3])]
    }

    #[test]
    fn a_fully_migrated_database_is_fine() {
        let applied = vec![(1, vec![1], true), (2, vec![2], true), (3, vec![3], true)];
        let status = compare(&embedded(), &applied);
        assert_eq!(status, MigrationStatus::default());
        assert_eq!(status.problem(), None);
    }

    #[test]
    fn missing_migrations_stop_the_new_build() {
        let status = compare(&embedded(), &[(1, vec![1], true)]);
        assert_eq!(status.pending, [2, 3]);
        let problem = status.problem().unwrap();
        assert!(problem.contains("missing migrations 2, 3"), "{problem}");
        assert!(problem.contains("thinktin-server migrate"), "{problem}");
        assert_eq!(compare(&embedded(), &[]).pending, [1, 2, 3]);
    }

    #[test]
    fn an_older_build_runs_on_a_newer_database() {
        let applied = vec![
            (1, vec![1], true),
            (2, vec![2], true),
            (3, vec![3], true),
            (4, vec![4], true),
        ];
        let status = compare(&embedded(), &applied);
        assert_eq!(status.newer, [4]);
        assert_eq!(status.problem(), None);
    }

    #[test]
    fn edited_or_half_applied_migrations_are_problems() {
        let applied = vec![
            (1, vec![1], true),
            (2, vec![9], true),
            (3, vec![3], false),
            (4, vec![4], false),
        ];
        let status = compare(&embedded(), &applied);
        assert_eq!(status.modified, [2]);
        assert_eq!(status.failed, [3, 4]);
        assert!(status.pending.is_empty() && status.newer.is_empty());
        let problem = status.problem().unwrap();
        assert!(
            problem.contains("migrations 3, 4 failed halfway"),
            "{problem}"
        );
        assert!(problem.contains("migrations 2 were edited"), "{problem}");
    }
}
