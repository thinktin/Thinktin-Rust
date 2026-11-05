//! 跨用户数据边界（8.15）的库测试：成员角色、定义者函数、成员读、退出即不可见。需要真实 Postgres，没设置 DATABASE_URL
//! 时跳过。

use crate::testing::TestDb;

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
    assert_eq!(open, ["blob_purge", "im_bot_slots"], "tables without FORCE RLS");
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
