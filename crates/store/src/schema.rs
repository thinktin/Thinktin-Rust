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
pub(crate) fn migrator() -> Migrator {
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
    /// 执行迁移。要用表的属主账号（迁移账号）连接。只能由一个迁移进程执行（迁移 Job）：带 `-- no-transaction` 的迁移
    /// （CREATE INDEX CONCURRENTLY）会和等 sqlx 咨询锁的另一个迁移进程死锁（docs/release.md 第 3 节）。
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

/// 服务角色（迁移 0049 里同一张表）：不管直接还是间接，都不能是成员角色、定义者的成员。
pub(crate) const SERVICE_ROLES: [&str; 4] = [
    "thinktin_app",
    "thinktin_worker",
    "thinktin_llmgw",
    "thinktin_relay",
];

impl Db {
    /// 启动时核对数据库角色（8.15）：服务登录账号要能 SET ROLE 到业务、后台、项目成员三个角色，而且不能是定义者函数
    /// 属主的成员（不然它就能改这些函数）；两个 8.15 角色的配置没被改坏（见 [`Self::role_graph_problems`]）。登录账号的
    /// 核对超级用户（开发库）跳过。有问题的写在 [`Error::Schema`] 里。
    pub async fn check_roles(&self) -> Result<()> {
        let mut problems = self.role_graph_problems(&SERVICE_ROLES).await?;
        let superuser: bool =
            sqlx::query_scalar("SELECT rolsuper FROM pg_roles WHERE rolname = session_user")
                .fetch_one(self.pool())
                .await?;
        if !superuser {
            let missing: Vec<String> = sqlx::query_scalar(
                "SELECT w.name FROM unnest($1::text[]) AS w(name) LEFT JOIN pg_roles r ON r.rolname = w.name \
                  WHERE NOT coalesce(pg_has_role(session_user, r.oid, 'SET'), false) ORDER BY 1",
            )
            .bind(["thinktin_app", "thinktin_member", "thinktin_worker"])
            .fetch_all(self.pool())
            .await?;
            let definer: bool = sqlx::query_scalar(
                "SELECT coalesce(pg_has_role(session_user, r.oid, 'MEMBER'), false) FROM pg_roles r \
                  WHERE r.rolname = 'thinktin_project_definer' \
                 UNION ALL SELECT false LIMIT 1",
            )
            .fetch_one(self.pool())
            .await?;
            if !missing.is_empty() {
                problems.push(format!(
                    "the login cannot SET ROLE to {}",
                    missing.join(", ")
                ));
            }
            if definer {
                problems
                    .push("the login must not be a member of thinktin_project_definer".to_string());
            }
        }
        if problems.is_empty() {
            Ok(())
        } else {
            Err(Error::Schema(format!(
                "{} (docs/deploy-checklist.md section 3)",
                problems.join("; ")
            )))
        }
    }

    /// 两个 8.15 角色后来有没有被改坏（迁移 0049 只在迁移时核对一次，而且只看直接的成员关系）：不能登录、不绕过行级安全、
    /// 不是超级用户、不能建角色和库，定义者不继承权限；它们不是任何角色的成员；`services` 里的角色不管直接还是经过别的角色间接，都不是
    /// 它们的成员（行级安全的策略按继承的成员关系生效，服务角色继承了成员角色，白名单就没了）。
    pub(crate) async fn role_graph_problems(&self, services: &[&str]) -> Result<Vec<String>> {
        let attributes: Vec<String> = sqlx::query_scalar(
            "SELECT rolname::text FROM pg_roles \
              WHERE rolname IN ('thinktin_member', 'thinktin_project_definer') \
                AND (rolsuper OR rolbypassrls OR rolcanlogin OR rolcreaterole OR rolcreatedb \
                     OR (rolname = 'thinktin_project_definer' AND rolinherit)) ORDER BY 1",
        )
        .fetch_all(self.pool())
        .await?;
        let parents: Vec<String> = sqlx::query_scalar(
            "SELECT DISTINCT r.rolname::text FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.member \
              WHERE r.rolname IN ('thinktin_member', 'thinktin_project_definer') ORDER BY 1",
        )
        .fetch_all(self.pool())
        .await?;
        let inherited: Vec<String> = sqlx::query_scalar(
            "SELECT s.rolname::text || ' -> ' || g.rolname::text FROM pg_roles s, pg_roles g \
              WHERE s.rolname::text = ANY($1) \
                AND g.rolname IN ('thinktin_member', 'thinktin_project_definer') \
                AND pg_has_role(s.oid, g.oid, 'MEMBER') ORDER BY 1",
        )
        .bind(services)
        .fetch_all(self.pool())
        .await?;
        let mut problems = vec![];
        if !attributes.is_empty() {
            problems.push(format!(
                "{} must be NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB (thinktin_project_definer also NOINHERIT)",
                attributes.join(", ")
            ));
        }
        if !parents.is_empty() {
            problems.push(format!(
                "{} must not be a member of any role",
                parents.join(", ")
            ));
        }
        if !inherited.is_empty() {
            problems.push(format!(
                "service roles must not be members of the project roles, directly or through another role: {}",
                inherited.join(", ")
            ));
        }
        Ok(problems)
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
