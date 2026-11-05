//! 跨用户数据边界（8.15）的库测试：成员角色、定义者函数、成员读、退出即不可见。需要真实 Postgres，没设置 DATABASE_URL
//! 时跳过。

use proto::domain::{Instance, ProjectId, ProjectStatus, TeamMember, TeamRole, UserId};

use super::{instance, user};
use crate::testing::TestDb;
use crate::{Db, Error};

/// 迁移 0049 的角色和定义者函数（D1、D2、D18）：两个新角色不能登录、不绕过行级安全、不是任何角色的成员，服务角色也不是
/// 它们的成员；定义者函数归 thinktin_project_definer、固定 search_path、PUBLIC 不能执行；每张表都开了行级安全且 FORCE；
/// 成员角色对私人表一点权限都没有。
#[tokio::test]
async fn member_roles_and_definers_are_locked_down() {
    let Some(t) = TestDb::new().await else { return };
    let pool = t.db.pool();
    for role in ["thinktin_member", "thinktin_project_definer"] {
        let (login, bypass, superuser, inherit): (bool, bool, bool, bool) = sqlx::query_as(
            "SELECT rolcanlogin, rolbypassrls, rolsuper, rolinherit FROM pg_roles WHERE rolname = $1",
        )
        .bind(role)
        .fetch_one(pool)
        .await
        .unwrap();
        assert!(!login && !bypass && !superuser, "{role}");
        if role == "thinktin_project_definer" {
            assert!(!inherit, "the definer must not inherit");
        }
        let member_of: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.member WHERE r.rolname = $1",
        )
        .bind(role)
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(member_of, 0, "{role} is a member of nothing");
        for service in [
            "thinktin_app",
            "thinktin_worker",
            "thinktin_llmgw",
            "thinktin_relay",
        ] {
            let inherits: bool = sqlx::query_scalar("SELECT pg_has_role($1, $2, 'USAGE')")
                .bind(service)
                .bind(role)
                .fetch_one(pool)
                .await
                .unwrap();
            assert!(!inherits, "{service} must not get {role}'s rights");
        }
    }
    // 定义者函数：归定义者，search_path 固定，PUBLIC 不能执行。
    let defs: Vec<(String, String, Option<Vec<String>>, bool)> = sqlx::query_as(
        "SELECT p.proname::text, pg_get_userbyid(p.proowner)::text, p.proconfig::text[], \
                has_function_privilege('public', p.oid, 'EXECUTE') \
           FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace \
          WHERE n.nspname = 'public' AND p.prosecdef",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    for name in ["member_projects", "my_project_budget"] {
        let (_, owner, config, public) = defs
            .iter()
            .find(|d| d.0 == name)
            .unwrap_or_else(|| panic!("{name} is security definer"));
        assert_eq!(owner, "thinktin_project_definer", "{name}");
        assert!(!public, "{name}: PUBLIC must not execute it");
        assert!(
            config
                .iter()
                .flatten()
                .any(|c| c == "search_path=pg_catalog, public, pg_temp"),
            "{name}: {config:?}"
        );
    }
    // 所有定义者函数（包括 0001、0007、0023 的旧函数）都固定了 search_path，pg_temp 排在最后。
    for (name, _, config, _) in &defs {
        assert!(
            config
                .iter()
                .flatten()
                .any(|c| c.starts_with("search_path=") && c.ends_with("pg_temp")),
            "{name}: {config:?}"
        );
    }
    // 每张表都开了行级安全，而且对属主也生效（FORCE）。
    let open: Vec<String> = sqlx::query_scalar(
        "SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
          WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relname <> '_sqlx_migrations' \
            AND c.relname NOT LIKE 'events\\_%' \
            AND NOT (c.relrowsecurity AND c.relforcerowsecurity) ORDER BY 1",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    // 没开的只有两张后台用的表：服务角色以外谁都没有权限。
    assert_eq!(
        open,
        ["blob_purge", "im_bot_slots"],
        "tables without FORCE RLS"
    );
    for table in &open {
        for role in ["thinktin_app", "thinktin_member"] {
            let any: bool = sqlx::query_scalar(
                "SELECT has_table_privilege($1, $2, 'SELECT, INSERT, UPDATE, DELETE') \
                     OR has_any_column_privilege($1, $2, 'SELECT')",
            )
            .bind(role)
            .bind(table)
            .fetch_one(pool)
            .await
            .unwrap();
            assert!(!any, "{role} must not touch {table}");
        }
    }
    // 成员角色：私人表一点权限都没有；项目目录只有列出来的列。
    for table in [
        "runs",
        "events",
        "approvals",
        "tool_calls",
        "usage_records",
        "credentials",
        "model_routes",
        "vault_items",
        "vault_requests",
        "devices",
        "user_keys",
        "project_keys",
        "project_invites",
        "project_invite_sends",
        "user_blocks",
        "inbox_items",
        "board_posts",
        "plans",
        "outbox",
        "audit_log",
        "artifacts",
    ] {
        let any: bool = sqlx::query_scalar(
            "SELECT has_table_privilege('thinktin_member', $1, 'SELECT') \
                 OR has_any_column_privilege('thinktin_member', $1, 'SELECT') \
                 OR has_table_privilege('thinktin_member', $1, 'INSERT, UPDATE, DELETE')",
        )
        .bind(table)
        .fetch_one(pool)
        .await
        .unwrap();
        assert!(!any, "thinktin_member must not touch {table}");
    }
    for (table, column, granted) in [
        ("projects", "name", true),
        ("project_members", "left_reason", true),
        ("project_members", "daily_token_limit", false),
        ("project_agents", "allow_computer", false),
        ("project_agents", "consented_at", false),
        ("users", "display_name", true),
        ("users", "phone", false),
        ("instances", "name", true),
        ("instances", "state", false),
        ("instances", "limits", false),
    ] {
        let has: bool =
            sqlx::query_scalar("SELECT has_column_privilege('thinktin_member', $1, $2, 'SELECT')")
                .bind(table)
                .bind(column)
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(has, granted, "{table}.{column}");
    }
}

/// alice 的单人项目，负责人是 `lead`。
async fn solo(db: &Db, owner: UserId, lead: &Instance) -> ProjectId {
    let mut t = db.tenant(owner).await.unwrap();
    let team = t
        .create_team(
            "p",
            &[TeamMember {
                instance_id: lead.id,
                role: TeamRole::Lead,
                position: 0,
            }],
        )
        .await
        .unwrap();
    t.commit().await.unwrap();
    team.id.into()
}

/// 用 worker 的原始 SQL 把 `member` 加进项目，带一个 agent。
async fn join_raw(db: &Db, project: ProjectId, member: UserId, agent: &Instance) {
    let mut w = db.worker().await.unwrap();
    sqlx::query(
        "INSERT INTO project_members (project_id, user_id, role, consented_at, daily_token_limit, \
           total_token_limit) VALUES ($1, $2, 'member', now(), 100, 1000)",
    )
    .bind(project.0)
    .bind(member.0)
    .execute(w.conn())
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO project_agents (project_id, instance_id, user_id, position) VALUES ($1, $2, $3, 5)",
    )
    .bind(project.0)
    .bind(agent.id.0)
    .bind(member.0)
    .execute(w.conn())
    .await
    .unwrap();
    w.commit().await.unwrap();
}

/// 作为 `who` 的成员事务跑一句 SQL，返回错误（每句一个事务：出错以后事务就废了）。
async fn member_err(db: &Db, who: UserId, sql: &str) -> Error {
    let mut m = db.member(who).await.unwrap();
    let err = sqlx::query(sqlx::AssertSqlSafe(sql.to_string()))
        .execute(m.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    m.finish().await.ok();
    err
}

/// 成员只读得到自己是存活成员的项目（8.15 测试 1）：别的项目按 id 读不到，伪造设置也没用；私人表一律没有权限；写不了。
#[tokio::test]
async fn member_reads_only_live_projects() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800005001").await;
    let bob = user(db, "+8613800005002").await;
    let carol = user(db, "+8613800005003").await;
    let (a1, a2, b1) = (
        instance(db, alice).await,
        instance(db, alice).await,
        instance(db, bob).await,
    );
    let p1 = solo(db, alice, &a1).await;
    let p2 = solo(db, alice, &a2).await;
    join_raw(db, p1, bob, &b1).await;

    let mut m = db.member(bob).await.unwrap();
    let listed: Vec<ProjectId> = m
        .my_projects()
        .await
        .unwrap()
        .iter()
        .map(|p| p.id)
        .collect();
    assert_eq!(listed, vec![p1]);
    assert!(matches!(m.project_detail(p2).await, Err(Error::NotFound)));
    m.finish().await.unwrap();
    let mut m = db.member(bob).await.unwrap();
    assert_eq!(m.require_project(p1).await.unwrap(), ProjectStatus::Active);
    // 伪造“当前项目”的设置：照样读不到 P2；member_projects() 只按 app.user_id 算。
    sqlx::query("SELECT set_config('app.project_id', $1, true)")
        .bind(p2.0.to_string())
        .execute(m.conn())
        .await
        .unwrap();
    let seen: i64 = sqlx::query_scalar("SELECT count(*) FROM projects WHERE id = $1")
        .bind(p2.0)
        .fetch_one(m.conn())
        .await
        .unwrap();
    assert_eq!(seen, 0);
    let mine: Vec<uuid::Uuid> = sqlx::query_scalar("SELECT member_projects()")
        .fetch_all(m.conn())
        .await
        .unwrap();
    assert_eq!(mine, vec![p1.0]);
    // 预算只有自己的；别人的成员行读得到但没有预算列。
    let budget: Vec<(Option<i64>, Option<i64>)> =
        sqlx::query_as("SELECT daily_token_limit, total_token_limit FROM my_project_budget($1)")
            .bind(p1.0)
            .fetch_all(m.conn())
            .await
            .unwrap();
    assert_eq!(budget, vec![(Some(100), Some(1000))]);
    let other: Vec<(Option<i64>, Option<i64>)> =
        sqlx::query_as("SELECT daily_token_limit, total_token_limit FROM my_project_budget($1)")
            .bind(p2.0)
            .fetch_all(m.conn())
            .await
            .unwrap();
    assert!(other.is_empty());
    m.finish().await.unwrap();
    // 外人什么都没有。
    let mut m = db.member(carol).await.unwrap();
    assert!(m.my_projects().await.unwrap().is_empty());
    assert!(matches!(m.require_project(p1).await, Err(Error::NotFound)));
    m.finish().await.unwrap();
    // 私人表、敏感列：一律 42501。
    for sql in [
        "SELECT 1 FROM approvals LIMIT 1",
        "SELECT 1 FROM tool_calls LIMIT 1",
        "SELECT 1 FROM usage_records LIMIT 1",
        "SELECT 1 FROM credentials LIMIT 1",
        "SELECT 1 FROM model_routes LIMIT 1",
        "SELECT 1 FROM vault_items LIMIT 1",
        "SELECT 1 FROM vault_requests LIMIT 1",
        "SELECT 1 FROM devices LIMIT 1",
        "SELECT 1 FROM user_keys LIMIT 1",
        "SELECT 1 FROM project_keys LIMIT 1",
        "SELECT 1 FROM project_invites LIMIT 1",
        "SELECT 1 FROM user_blocks LIMIT 1",
        "SELECT 1 FROM events LIMIT 1",
        "SELECT 1 FROM runs LIMIT 1",
        "SELECT 1 FROM inbox_items LIMIT 1",
        "SELECT 1 FROM board_posts LIMIT 1",
        "SELECT 1 FROM plans LIMIT 1",
        "SELECT 1 FROM outbox LIMIT 1",
        "SELECT 1 FROM audit_log LIMIT 1",
        "SELECT daily_token_limit FROM project_members LIMIT 1",
        "SELECT state FROM instances LIMIT 1",
        "SELECT phone FROM users LIMIT 1",
    ] {
        let err = member_err(db, bob, sql).await;
        assert!(matches!(err, Error::Forbidden(_)), "{sql}: {err:?}");
    }
    // 只读事务：写一律不行（25006 也算 Forbidden）。
    let err = member_err(
        db,
        bob,
        "INSERT INTO audit_log (actor, action) VALUES ('x', 'y')",
    )
    .await;
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    let err = member_err(db, bob, "UPDATE projects SET name = 'x'").await;
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    // 退出以后：马上读不到。
    sqlx::query("UPDATE project_agents SET left_at = now() WHERE project_id = $1 AND user_id = $2")
        .bind(p1.0)
        .bind(bob.0)
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query(
        "UPDATE project_members SET left_at = now(), left_reason = 'left' \
          WHERE project_id = $1 AND user_id = $2",
    )
    .bind(p1.0)
    .bind(bob.0)
    .execute(db.pool())
    .await
    .unwrap();
    let mut m = db.member(bob).await.unwrap();
    assert!(m.my_projects().await.unwrap().is_empty());
    assert!(matches!(m.project_detail(p1).await, Err(Error::NotFound)));
    m.finish().await.unwrap();
}

/// 详情的结构和 8.14 一样（8.15 测试 2 的补充：8.14 的项目测试已经全部改成成员读）：归档的项目照样列出来、状态是
/// archived；删了的项目、注销的成员看不到；删了的项目里的成员读不到。
#[tokio::test]
async fn archived_projects_are_listed_and_deleted_ones_vanish() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800005011").await;
    let bob = user(db, "+8613800005012").await;
    let (a1, b1) = (instance(db, alice).await, instance(db, bob).await);
    let p = solo(db, alice, &a1).await;
    join_raw(db, p, bob, &b1).await;
    sqlx::query("UPDATE projects SET status = 'archived', archived_at = now() WHERE id = $1")
        .bind(p.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut m = db.member(bob).await.unwrap();
    let listed = m.my_projects().await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].status, ProjectStatus::Archived);
    let d = m.project_detail(p).await.unwrap();
    assert_eq!(d.summary.status, ProjectStatus::Archived);
    assert_eq!(d.members.len(), 2);
    m.finish().await.unwrap();
    sqlx::query("UPDATE projects SET status = 'deleted', deleted_at = now() WHERE id = $1")
        .bind(p.0)
        .execute(db.pool())
        .await
        .unwrap();
    for who in [alice, bob] {
        let mut m = db.member(who).await.unwrap();
        assert!(m.my_projects().await.unwrap().is_empty());
        assert!(matches!(m.require_project(p).await, Err(Error::NotFound)));
        m.finish().await.unwrap();
    }
    // 租户那边：删了的项目连创建者也看不到。
    let mut ta = db.tenant(alice).await.unwrap();
    let seen: i64 = sqlx::query_scalar("SELECT count(*) FROM projects WHERE id = $1")
        .bind(p.0)
        .fetch_one(ta.conn())
        .await
        .unwrap();
    assert_eq!(seen, 0);
    ta.rollback().await.unwrap();
}

/// 启动核对（D19）：超级用户（开发、测试库）跳过；不是任何服务角色成员的登录账号（这里用迁移账号）报缺了哪些角色。
#[tokio::test]
async fn startup_checks_the_login_roles() {
    let Some(t) = TestDb::new().await else { return };
    t.db.check_roles().await.unwrap();
    let owner = t.owner_db().await;
    let err = owner.check_roles().await.unwrap_err();
    let Error::Schema(msg) = err else {
        panic!("{err:?}")
    };
    assert!(
        msg.contains("thinktin_app, thinktin_member, thinktin_worker"),
        "{msg}"
    );
    assert!(msg.contains("deploy-checklist"), "{msg}");
}
