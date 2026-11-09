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
        // 项目产出物的索引（8.15，迁移 0054）：没有对象存储里的位置（下载由 worker 再核对）。
        ("artifacts", "name", true),
        ("artifacts", "project_id", true),
        ("artifacts", "blob_key", false),
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

async fn space(db: &Db, table: &str, run: uuid::Uuid) -> Vec<(String, Option<uuid::Uuid>)> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT space_kind, project_id FROM {table} WHERE run_id = $1 ORDER BY 1"
    )))
    .bind(run)
    .fetch_all(db.pool())
    .await
    .unwrap()
}

/// 事件、审批、产出物的空间跟着运行走（8.15 测试 5 的 C4 部分）：worker、租户写的都由触发器按运行填上项目；建了不能改；
/// 和运行对不上的被外键拒绝；项目产出物要项目有密钥，登记时给的项目和运行的对不上报错。
#[tokio::test]
async fn scope_follows_the_run() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800005021").await;
    let bob = user(db, "+8613800005022").await;
    let (a1, b1) = (instance(db, alice).await, instance(db, bob).await);
    let p = solo(db, alice, &a1).await;
    join_raw(db, p, bob, &b1).await;
    let private = super::queue_run(db, bob, &b1, "private").await;
    let r = super::projects::copy_into_project(db, "runs", private.id.0, p, None).await;
    let r_id = proto::domain::RunId(r);
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.run_project(r_id).await.unwrap(), Some(p));
    assert_eq!(w.run_project(private.id).await.unwrap(), None);
    w.append_event(
        b1.id,
        Some(r_id),
        "agent.message",
        &serde_json::json!({ "text": "hi" }),
    )
    .await
    .unwrap();
    w.create_approval(&crate::NewApproval {
        user: bob,
        instance: b1.id,
        run: r_id,
        request_id: "perm-1",
        title: None,
        options: &serde_json::json!([]),
        tool_call: &serde_json::json!({}),
        expires_in: std::time::Duration::from_secs(60),
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    // 租户（bob 自己）在项目运行上写事件：照样带上项目。
    let mut tb = db.tenant(bob).await.unwrap();
    tb.append_event(
        b1.id,
        Some(r_id),
        "agent.plan",
        &serde_json::json!({ "entries": [] }),
    )
    .await
    .unwrap();
    tb.commit().await.unwrap();
    assert_eq!(
        space(db, "events", r).await,
        vec![("project".into(), Some(p.0)), ("project".into(), Some(p.0))]
    );
    assert_eq!(
        space(db, "approvals", r).await,
        vec![("project".into(), Some(p.0))]
    );
    // 私人运行上的照样是私人的。
    let mut w = db.worker().await.unwrap();
    w.append_event(
        b1.id,
        Some(private.id),
        "agent.message",
        &serde_json::json!({ "text": "mine" }),
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    assert_eq!(
        space(db, "events", private.id.0).await,
        vec![("private".into(), None)]
    );
    // 产出物：没有密钥登记不进项目；不说是项目的也不行（库里按运行算出来的对不上）。
    let artifact = |project: Option<ProjectId>, name: &'static str| crate::NewArtifact {
        id: proto::domain::ArtifactId::new(),
        user: bob,
        instance: b1.id,
        run: r_id,
        root: r_id,
        name,
        content_type: "text/plain",
        size: 1,
        sha256: &[0; 32],
        blob_key: "k",
        project,
    };
    let mut w = db.worker().await.unwrap();
    assert!(matches!(
        w.insert_artifact(&artifact(Some(p), "a.txt")).await,
        Err(Error::NotFound)
    ));
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let (kid, wrapped) = w
        .insert_project_key(p, "kms-1", b"wrapped-1")
        .await
        .unwrap();
    assert_eq!(
        (kid.as_str(), wrapped.as_slice()),
        ("kms-1", &b"wrapped-1"[..])
    );
    // 同时有人存了：用先存的那个。
    let (kid, _) = w
        .insert_project_key(p, "kms-2", b"wrapped-2")
        .await
        .unwrap();
    assert_eq!(kid, "kms-1");
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let err = w
        .insert_artifact(&artifact(None, "b.txt"))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let a = w
        .insert_artifact(&artifact(Some(p), "a.txt"))
        .await
        .unwrap();
    assert_eq!(a.project_id, Some(p));
    assert_eq!(w.project_key(p).await.unwrap().unwrap().0, "kms-1");
    w.commit().await.unwrap();
    assert_eq!(
        space(db, "artifacts", r).await,
        vec![("project".into(), Some(p.0))]
    );
    // 建了不能改空间。
    let err = sqlx::query("UPDATE events SET project_id = NULL WHERE run_id = $1")
        .bind(r)
        .execute(db.pool())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    // 和运行的空间对不上：去掉触发器硬写一条私人的，外键拒绝。
    sqlx::query("ALTER TABLE approvals DISABLE TRIGGER approvals_space")
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(
        "INSERT INTO approvals (id, user_id, instance_id, run_id, request_id, options, tool_call, expires_at, \
           space_kind, space_id) \
         VALUES (gen_random_uuid(), $1, $2, $3, 'perm-2', '[]', '{}', now() + interval '1 minute', 'private', $1)",
    )
    .bind(bob.0)
    .bind(b1.id.0)
    .bind(r)
    .execute(w.conn())
    .await
    .map_err(Error::from)
    .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
    sqlx::query("ALTER TABLE approvals ENABLE TRIGGER approvals_space")
        .execute(db.pool())
        .await
        .unwrap();
    // 项目删了（软删除）：密钥读不到，也存不进去。
    sqlx::query("UPDATE projects SET status = 'deleted', deleted_at = now() WHERE id = $1")
        .bind(p.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.project_key(p).await.unwrap(), None);
    assert!(matches!(
        w.insert_project_key(p, "kms-3", b"x").await,
        Err(Error::NotFound)
    ));
    w.rollback().await.unwrap();
}

/// 迁移 0050 的回填（8.15 测试 12）：迁移之前就有的项目运行的事件、审批、产出物，迁移后都带上项目，三个外键都核对过。
#[tokio::test]
async fn scope_backfill_covers_existing_rows() {
    let Some(t) = TestDb::up_to(49).await else {
        return;
    };
    let db = &t.db;
    let alice = user(db, "+8613800005031").await;
    let bob = user(db, "+8613800005032").await;
    let (a1, b1) = (
        super::old_instance(db, alice).await,
        super::old_instance(db, bob).await,
    );
    let p = solo(db, alice, &a1).await;
    join_raw(db, p, bob, &b1).await;
    let private = super::old_run(db, bob, &b1).await;
    let r = super::projects::copy_into_project(db, "runs", private.id.0, p, None).await;
    // 0050 之前：事件、审批、产出物没有空间列（直接写，超级用户）。
    for sql in [
        "INSERT INTO events (instance_id, seq, run_id, user_id, kind, payload) \
         VALUES ($2, 1001, $1, $3, 'agent.message', '{}')",
        "INSERT INTO approvals (id, user_id, instance_id, run_id, request_id, options, tool_call, expires_at) \
         VALUES (gen_random_uuid(), $3, $2, $1, 'perm-1', '[]', '{}', now() + interval '1 minute')",
        "INSERT INTO artifacts (id, user_id, instance_id, run_id, root_run_id, name, version, content_type, \
           size, sha256, blob_key) \
         VALUES (gen_random_uuid(), $3, $2, $1, $1, 'a.txt', 1, 'text/plain', 1, '\\x00', 'k')",
    ] {
        sqlx::query(sqlx::AssertSqlSafe(sql.to_string()))
            .bind(r)
            .bind(b1.id.0)
            .bind(bob.0)
            .execute(db.pool())
            .await
            .unwrap();
    }
    t.migrate_rest().await;
    for table in ["events", "approvals", "artifacts"] {
        assert_eq!(
            space(db, table, r).await,
            vec![("project".into(), Some(p.0))],
            "{table}"
        );
    }
    let unvalidated: Vec<String> = sqlx::query_scalar(
        "SELECT conname::text FROM pg_constraint \
          WHERE conname IN ('events_run_space', 'approvals_run_space', 'artifacts_run_space') \
            AND NOT convalidated",
    )
    .fetch_all(db.pool())
    .await
    .unwrap();
    assert!(unvalidated.is_empty(), "{unvalidated:?}");
    let n: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM pg_constraint \
          WHERE conname IN ('events_run_space', 'approvals_run_space', 'artifacts_run_space')",
    )
    .fetch_one(db.pool())
    .await
    .unwrap();
    // events 是分区表：每个分区一份外键约束，父表一份。
    assert!(n >= 3, "{n}");
}

/// bob 在 alice 的项目里的一个项目运行（复制出来、跑着），和一个私人运行。
async fn project_run_fixture(
    db: &Db,
) -> (
    UserId,
    UserId,
    ProjectId,
    Instance,
    proto::domain::RunId,
    proto::domain::RunId,
) {
    let alice = user(db, "+8613800005101").await;
    let bob = user(db, "+8613800005102").await;
    let (a1, b1) = (instance(db, alice).await, instance(db, bob).await);
    let p = solo(db, alice, &a1).await;
    join_raw(db, p, bob, &b1).await;
    let private = super::queue_run(db, bob, &b1, "private task").await;
    let r = super::projects::copy_into_project(db, "runs", private.id.0, p, None).await;
    (alice, bob, p, b1, proto::domain::RunId(r), private.id)
}

/// 退出即不可见（8.15 测试 3 的 C6 部分）：成员时，自己的私人列表不混进项目运行，按 id 读得到；退出以后自己的项目运行、
/// 事件、产出物都读不到，成员读也读不到；alice 看得到 bob 留下的运行，主人显示“已退出”；bob 的私人运行 alice 永远看不到。
#[tokio::test]
async fn leaving_hides_project_rows_everywhere() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, private) = project_run_fixture(db).await;
    let mut w = db.worker().await.unwrap();
    w.append_event(
        b1.id,
        Some(r),
        "agent.message",
        &serde_json::json!({ "text": "done" }),
    )
    .await
    .unwrap();
    w.append_event(
        b1.id,
        Some(private),
        "agent.message",
        &serde_json::json!({ "text": "mine" }),
    )
    .await
    .unwrap();
    w.insert_project_key(p, "kms-1", b"wrapped").await.unwrap();
    let art = w
        .insert_artifact(&crate::NewArtifact {
            id: proto::domain::ArtifactId::new(),
            user: bob,
            instance: b1.id,
            run: r,
            root: r,
            name: "report.md",
            content_type: "text/markdown",
            size: 1,
            sha256: &[1; 32],
            blob_key: "k",
            project: Some(p),
        })
        .await
        .unwrap();
    w.commit().await.unwrap();
    // 成员时：按 id 读得到；私人的列表、事件流、产出物不混进项目的。
    let mut tb = db.tenant(bob).await.unwrap();
    assert_eq!(tb.run(r).await.unwrap().project_id, Some(p));
    let runs: Vec<_> = tb
        .runs(b1.id, None, 50)
        .await
        .unwrap()
        .iter()
        .map(|r| r.id)
        .collect();
    assert_eq!(runs, vec![private]);
    let listed: Vec<_> = tb
        .list_runs(crate::RunFilter::default(), None, 50)
        .await
        .unwrap()
        .iter()
        .map(|r| r.id)
        .collect();
    assert_eq!(listed, vec![private]);
    let events = tb.events_after(b1.id, 0, 100).await.unwrap();
    assert!(events.iter().all(|e| e.run_id != Some(r)), "{events:?}");
    assert!(events.iter().any(|e| e.run_id == Some(private)));
    assert!(tb.instance_artifacts(b1.id, 50).await.unwrap().is_empty());
    tb.rollback().await.unwrap();
    // 成员读：bob、alice 都看得到这个运行和产出物。
    for who in [alice, bob] {
        let mut m = db.member(who).await.unwrap();
        let runs = m
            .project_runs(
                p,
                &crate::ProjectRunFilter {
                    limit: 50,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(runs.iter().map(|x| x.id).collect::<Vec<_>>(), vec![r]);
        assert_eq!(runs[0].mine, who == bob);
        assert_eq!(runs[0].owner.user_id, Some(bob));
        let arts = m.project_artifacts(p, None, 50).await.unwrap();
        assert_eq!(
            arts.iter().map(|a| a.id).collect::<Vec<_>>(),
            vec![art.artifact.id]
        );
        // 私人运行：成员读按 id 也读不到。
        assert!(matches!(
            m.project_run(p, private).await,
            Err(Error::NotFound)
        ));
        m.finish().await.unwrap();
    }
    // bob 退出。
    sqlx::query("UPDATE project_agents SET left_at = now() WHERE project_id = $1 AND user_id = $2")
        .bind(p.0)
        .bind(bob.0)
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query(
        "UPDATE project_members SET left_at = now(), left_reason = 'left' \
          WHERE project_id = $1 AND user_id = $2",
    )
    .bind(p.0)
    .bind(bob.0)
    .execute(db.pool())
    .await
    .unwrap();
    let mut tb = db.tenant(bob).await.unwrap();
    assert!(matches!(tb.run(r).await, Err(Error::NotFound)));
    assert!(matches!(
        tb.delete_artifact(art.artifact.id).await,
        Err(Error::NotFound)
    ));
    assert_eq!(tb.run(private).await.unwrap().id, private);
    tb.rollback().await.unwrap();
    let mut m = db.member(bob).await.unwrap();
    assert!(matches!(
        m.project_runs(
            p,
            &crate::ProjectRunFilter {
                limit: 50,
                ..Default::default()
            }
        )
        .await,
        Err(Error::NotFound)
    ));
    m.finish().await.unwrap();
    // alice 照样看得到，主人显示“已退出”（没有 id 和昵称）。
    let mut m = db.member(alice).await.unwrap();
    let run = m.project_run(p, r).await.unwrap();
    assert_eq!(run.owner.status, proto::domain::ProjectAuthorStatus::Left);
    assert_eq!(run.owner.user_id, None);
    let a = m.project_artifact(p, art.artifact.id).await.unwrap();
    assert_eq!(a.author.status, proto::domain::ProjectAuthorStatus::Left);
    m.finish().await.unwrap();
}

/// 成员看到的事件按白名单（8.15 测试 4）：只有那 10 种，每种只有列出来的字段，私人的东西（原始参数、思考、用量、审批）
/// 一个字都不出来；状态粗化；传别的项目、别的运行 id 读不到。
#[tokio::test]
async fn project_view_is_whitelisted() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, _) = project_run_fixture(db).await;
    let marker = "SECRET-MARKER";
    let raw = serde_json::json!({ "secret": marker });
    let kinds: Vec<(&str, serde_json::Value)> = vec![
        (
            "agent.tool_call",
            serde_json::json!({ "tool_call_id": "t1", "kind": "edit", "status": "pending",
            "title": marker, "raw": raw }),
        ),
        (
            "agent.tool_call_update",
            serde_json::json!({ "tool_call_id": "t1", "status": "completed",
            "raw": raw, "content": marker }),
        ),
        ("agent.message", serde_json::json!({ "text": "hello" })),
        (
            "agent.plan",
            serde_json::json!({ "entries": [{ "content": "step one", "status": "pending",
            "priority": marker }] }),
        ),
        (
            "agent.turn_started",
            serde_json::json!({ "secret": marker }),
        ),
        (
            "agent.turn_ended",
            serde_json::json!({ "stop_reason": "end_turn", "usage": marker }),
        ),
        (
            "run.state",
            serde_json::json!({ "state": "waiting_quota", "reason": marker, "attempt": 3 }),
        ),
        (
            "run.log_truncated",
            serde_json::json!({ "dropped": marker }),
        ),
        (
            "artifact.published",
            serde_json::json!({ "artifact_id": "a1", "name": "x.md", "version": 2,
            "blob_key": marker }),
        ),
        (
            "pipeline.step_started",
            serde_json::json!({ "step": "draft", "prompt": marker }),
        ),
        ("agent.thought", serde_json::json!({ "text": marker })),
        ("agent.usage", serde_json::json!({ "tokens": marker })),
        (
            "agent.permission_requested",
            serde_json::json!({ "title": marker }),
        ),
        ("agent.vault_reveal", serde_json::json!({ "name": marker })),
        ("approval.decided", serde_json::json!({ "option": marker })),
        (
            "agent.platform_tool_call",
            serde_json::json!({ "args": marker }),
        ),
        ("run.state", serde_json::json!({ "state": "backoff" })),
    ];
    let mut w = db.worker().await.unwrap();
    for (k, v) in &kinds {
        w.append_event(b1.id, Some(r), k, v).await.unwrap();
    }
    w.commit().await.unwrap();
    let mut m = db.member(alice).await.unwrap();
    let got = m.project_run_events(p, r, 100).await.unwrap();
    assert!(!got.truncated);
    let text = serde_json::to_string(&got).unwrap();
    assert!(!text.contains(marker), "{text}");
    let seen: Vec<(String, serde_json::Value)> = got
        .events
        .iter()
        .map(|e| (e.kind.clone(), e.data.clone()))
        .collect();
    assert_eq!(
        seen,
        vec![
            (
                "tool_call".into(),
                serde_json::json!({ "tool_call_id": "t1", "tool_kind": "edit", "status": "pending" })
            ),
            (
                "tool_call_update".into(),
                serde_json::json!({ "tool_call_id": "t1", "status": "completed" })
            ),
            ("message".into(), serde_json::json!({ "text": "hello" })),
            (
                "plan".into(),
                serde_json::json!({ "entries": [{ "content": "step one", "status": "pending" }] })
            ),
            ("turn_started".into(), serde_json::json!({})),
            (
                "turn_ended".into(),
                serde_json::json!({ "stop_reason": "end_turn" })
            ),
            (
                "state".into(),
                serde_json::json!({ "state": "waiting_owner" })
            ),
            ("log_truncated".into(), serde_json::json!({})),
            (
                "artifact".into(),
                serde_json::json!({ "artifact_id": "a1", "name": "x.md", "version": 2 })
            ),
            (
                "step_started".into(),
                serde_json::json!({ "step": "draft" })
            ),
            ("state".into(), serde_json::json!({ "state": "running" })),
        ]
    );
    // 只要最近的 3 条：截断。
    let last = m.project_run_events(p, r, 3).await.unwrap();
    assert!(last.truncated);
    assert_eq!(last.events.len(), 3);
    assert_eq!(last.events[2].kind, "state");
    // 运行本身：状态粗化，没有失败原因、花费这些字段。
    let run = m.project_run(p, r).await.unwrap();
    assert_eq!(run.state, proto::domain::ProjectRunState::Running);
    assert_eq!(run.prompt, "private task");
    let tree = m.project_run_tree(p, r).await.unwrap();
    assert_eq!(tree.iter().map(|x| x.id).collect::<Vec<_>>(), vec![r]);
    m.finish().await.unwrap();
    // 别的项目、编出来的 id：读不到。
    let other = solo(db, alice, &instance(db, alice).await).await;
    let mut m = db.member(bob).await.unwrap();
    for f in [
        m.project_run(other, r).await.err(),
        m.project_run_tree(other, r).await.err(),
        m.project_run_events(other, r, 10).await.err(),
    ] {
        assert!(matches!(f, Some(Error::NotFound)), "{f:?}");
    }
    m.finish().await.unwrap();
    let mut m = db.member(bob).await.unwrap();
    assert!(matches!(
        m.project_runs(
            other,
            &crate::ProjectRunFilter {
                limit: 5,
                ..Default::default()
            }
        )
        .await,
        Err(Error::NotFound)
    ));
    m.finish().await.unwrap();
    // 库里的白名单和代码里的一样；回执子类型也一样。
    let sql = include_str!("../../migrations/0054_project_scoped_reads.sql");
    for k in proto::domain::PROJECT_RUN_EVENT_KINDS {
        assert!(sql.contains(&format!("'{k}'")), "{k}");
    }
    for s in proto::domain::notice_subtype::PROJECT_RECEIPTS {
        let yes: bool = sqlx::query_scalar("SELECT project_receipt($1)")
            .bind(s)
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert!(yes, "{s}");
    }
    for s in [Some("approval"), Some("info"), None] {
        let yes: Option<bool> = sqlx::query_scalar("SELECT project_receipt($1)")
            .bind(s)
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert!(!yes.unwrap_or(false), "{s:?}");
    }
}

/// 收件箱的项目从运行算（8.15 测试 6）：worker 写运行提醒不用给项目；给错了、回执带运行都不行；租户在项目运行上写不了
/// 提醒（成员时 42501，退出以后运行看不到，23503）；退出以后运行提醒看不到，回执照样看得到。外加测试 5 的 C6 部分：退出
/// 以后租户往自己的项目运行上追加事件被拒绝。
#[tokio::test]
async fn inbox_project_is_derived() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (_alice, bob, p, b1, r, private) = project_run_fixture(db).await;
    let note =
        |run: Option<proto::domain::RunId>, project: Option<ProjectId>, subtype: Option<&str>| {
            crate::NewInboxItem {
                kind: "info".into(),
                title: "t".into(),
                body: "b".into(),
                run_id: run,
                project_id: project,
                subtype: subtype.map(String::from),
                ..crate::NewInboxItem::default()
            }
        };
    let mut w = db.worker().await.unwrap();
    let id = w
        .insert_inbox(bob, &note(Some(r), None, None))
        .await
        .unwrap()
        .unwrap();
    let receipt = w
        .insert_inbox(
            bob,
            &note(
                None,
                Some(p),
                Some(proto::domain::notice_subtype::PROJECT_LEFT),
            ),
        )
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    let stored: Option<uuid::Uuid> =
        sqlx::query_scalar("SELECT project_id FROM inbox_items WHERE id = $1")
            .bind(id.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(stored, Some(p.0));
    // 给错项目、回执带运行：都不行。
    let other = solo(db, bob, &instance(db, bob).await).await;
    for (n, what) in [
        (note(Some(r), Some(other), None), "mismatch"),
        (
            note(
                Some(r),
                Some(p),
                Some(proto::domain::notice_subtype::PROJECT_JOINED),
            ),
            "receipt with a run",
        ),
    ] {
        let mut w = db.worker().await.unwrap();
        let err = w.insert_inbox(bob, &n).await.unwrap_err();
        assert!(matches!(err, Error::Invalid(_)), "{what}: {err:?}");
        w.rollback().await.unwrap();
    }
    // 租户在项目运行上写提醒：成员时 Forbidden。
    let mut tb = db.tenant(bob).await.unwrap();
    let err = tb
        .insert_inbox(bob, &note(Some(r), None, None))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    tb.rollback().await.unwrap();
    // 私人运行的提醒照常。
    let mut tb = db.tenant(bob).await.unwrap();
    tb.insert_inbox(bob, &note(Some(private), None, None))
        .await
        .unwrap()
        .unwrap();
    tb.commit().await.unwrap();
    // 退出以后：运行提醒看不到，回执看得到；在项目运行上写提醒、追加事件都被拒绝。
    sqlx::query("UPDATE project_agents SET left_at = now() WHERE project_id = $1 AND user_id = $2")
        .bind(p.0)
        .bind(bob.0)
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query(
        "UPDATE project_members SET left_at = now(), left_reason = 'left' \
          WHERE project_id = $1 AND user_id = $2",
    )
    .bind(p.0)
    .bind(bob.0)
    .execute(db.pool())
    .await
    .unwrap();
    let mut tb = db.tenant(bob).await.unwrap();
    let ids: Vec<_> = tb
        .inbox(None, 50, false)
        .await
        .unwrap()
        .iter()
        .map(|i| i.id)
        .collect();
    assert!(!ids.contains(&id), "the run notice is hidden");
    assert!(ids.contains(&receipt), "the receipt stays");
    tb.rollback().await.unwrap();
    let mut tb = db.tenant(bob).await.unwrap();
    let err = tb
        .insert_inbox(bob, &note(Some(r), None, None))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    tb.rollback().await.unwrap();
    let mut tb = db.tenant(bob).await.unwrap();
    let err = tb
        .append_event(
            b1.id,
            Some(r),
            "run.cancel_requested",
            &serde_json::json!({}),
        )
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    tb.rollback().await.unwrap();
}

async fn worker_do<T>(
    db: &Db,
    f: impl AsyncFnOnce(&mut crate::Tx<crate::Worker>) -> crate::Result<T>,
) -> crate::Result<T> {
    let mut w = db.worker().await.unwrap();
    let r = f(&mut w).await;
    match &r {
        Ok(_) => w.commit().await.unwrap(),
        Err(_) => w.rollback().await.unwrap(),
    }
    r
}

async fn scalar(db: &Db, sql: &str, id: uuid::Uuid) -> i64 {
    sqlx::query_scalar(sqlx::AssertSqlSafe(sql.to_string()))
        .bind(id)
        .fetch_one(db.pool())
        .await
        .unwrap()
}

/// R 上放一条事件、一个产出物（项目有了密钥）、一条 bob 的运行提醒、一条回执。
async fn fill_project(
    db: &Db,
    bob: UserId,
    p: ProjectId,
    b1: &Instance,
    r: proto::domain::RunId,
) -> (proto::domain::InboxItemId, proto::domain::InboxItemId) {
    let mut w = db.worker().await.unwrap();
    w.append_event(
        b1.id,
        Some(r),
        "agent.message",
        &serde_json::json!({ "text": "x" }),
    )
    .await
    .unwrap();
    w.insert_project_key(p, "kms-1", b"wrapped").await.unwrap();
    w.insert_artifact(&crate::NewArtifact {
        id: proto::domain::ArtifactId::new(),
        user: bob,
        instance: b1.id,
        run: r,
        root: r,
        name: "out.md",
        content_type: "text/markdown",
        size: 1,
        sha256: &[2; 32],
        blob_key: "project-blob",
        project: Some(p),
    })
    .await
    .unwrap();
    let base = crate::NewInboxItem {
        kind: "info".into(),
        title: "t".into(),
        body: "b".into(),
        ..crate::NewInboxItem::default()
    };
    let notice = w
        .insert_inbox(
            bob,
            &crate::NewInboxItem {
                run_id: Some(r),
                ..base.clone()
            },
        )
        .await
        .unwrap()
        .unwrap();
    let receipt = w
        .insert_inbox(
            bob,
            &crate::NewInboxItem {
                project_id: Some(p),
                subtype: Some(proto::domain::notice_subtype::PROJECT_JOINED.into()),
                ..base
            },
        )
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    (notice, receipt)
}

/// 删除即不可读、后台清理（8.15 测试 7）。
#[tokio::test]
async fn deleting_makes_unreadable_then_purges() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, _) = project_run_fixture(db).await;
    let (notice, receipt) = fill_project(db, bob, p, &b1, r).await;
    let epoch = || async {
        scalar(
            db,
            "SELECT token_epoch FROM instances WHERE id = $1",
            b1.id.0,
        )
        .await
    };
    let before = epoch().await;
    // 成员删不了；旧接口的删法删不了共享过的。
    let err = worker_do(db, async |w| w.delete_project(bob, p, true).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    let err = worker_do(db, async |w| w.delete_project(alice, p, false).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Conflict(_)), "{err:?}");
    let d = worker_do(db, async |w| w.delete_project(alice, p, true).await)
        .await
        .unwrap();
    assert_eq!(
        (d.creator, d.notify.clone(), d.shared),
        (alice, vec![bob], true)
    );
    assert_eq!(d.runs_cancelled, 1);
    // 马上读不到；密钥没了；运行取消、令牌代数加一；agent 离开；bob 的运行提醒已读，回执不动。
    let mut m = db.member(bob).await.unwrap();
    assert!(matches!(m.require_project(p).await, Err(Error::NotFound)));
    m.finish().await.unwrap();
    let mut tb = db.tenant(bob).await.unwrap();
    assert!(matches!(tb.run(r).await, Err(Error::NotFound)));
    tb.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.project_key(p).await.unwrap(), None);
    w.rollback().await.unwrap();
    let state: String = sqlx::query_scalar("SELECT state FROM runs WHERE id = $1")
        .bind(r.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(state, "cancelled");
    assert_eq!(epoch().await, before + 1);
    assert_eq!(
        scalar(
            db,
            "SELECT count(*) FROM project_agents WHERE project_id = $1 AND left_at IS NULL",
            p.0
        )
        .await,
        0
    );
    let read = |id: proto::domain::InboxItemId| async move {
        sqlx::query_scalar::<_, bool>("SELECT read_at IS NOT NULL FROM inbox_items WHERE id = $1")
            .bind(id.0)
            .fetch_one(db.pool())
            .await
            .unwrap()
    };
    assert!(read(notice).await);
    assert!(!read(receipt).await);
    // 再删一次：已经删了，NotFound。
    let err = worker_do(db, async |w| w.delete_project(alice, p, true).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    // 后台清理：别人锁着一条项目提醒时，项目这一行留到下一轮。
    let mut holder = db.worker().await.unwrap();
    sqlx::query("SELECT 1 FROM inbox_items WHERE id = $1 FOR UPDATE")
        .bind(notice.0)
        .execute(holder.conn())
        .await
        .unwrap();
    loop {
        let n = worker_do(db, async |w| {
            w.purge_deleted_projects(2, std::time::Duration::ZERO).await
        })
        .await
        .unwrap();
        if n == 0 {
            break;
        }
    }
    assert_eq!(
        scalar(db, "SELECT count(*) FROM projects WHERE id = $1", p.0).await,
        1
    );
    holder.rollback().await.unwrap();
    loop {
        let n = worker_do(db, async |w| {
            w.purge_deleted_projects(2, std::time::Duration::ZERO).await
        })
        .await
        .unwrap();
        if n == 0 {
            break;
        }
    }
    for (sql, what) in [
        ("SELECT count(*) FROM projects WHERE id = $1", "project"),
        ("SELECT count(*) FROM runs WHERE project_id = $1", "runs"),
        (
            "SELECT count(*) FROM events WHERE project_id = $1",
            "events",
        ),
        (
            "SELECT count(*) FROM artifacts WHERE project_id = $1",
            "artifacts",
        ),
        (
            "SELECT count(*) FROM run_grants WHERE project_id = $1",
            "grants",
        ),
        (
            "SELECT count(*) FROM project_members WHERE project_id = $1",
            "members",
        ),
        (
            "SELECT count(*) FROM inbox_items WHERE project_id = $1 AND NOT coalesce(project_receipt(subtype), false)",
            "notices",
        ),
    ] {
        assert_eq!(scalar(db, sql, p.0).await, 0, "{what}");
    }
    assert_eq!(
        scalar(
            db,
            "SELECT count(*) FROM inbox_items WHERE project_id = $1",
            p.0
        )
        .await,
        1,
        "the receipt stays"
    );
    let mut w = db.worker().await.unwrap();
    assert!(
        w.blob_purge_batch(10)
            .await
            .unwrap()
            .contains(&"project-blob".to_string())
    );
    w.rollback().await.unwrap();
}

/// 归档只读（8.15 测试 8）：运行取消、邀请撤回；成员照样读；存密钥、登记产出物、加 agent、改项目都不行；照样能退出；
/// 取消归档恢复。
#[tokio::test]
async fn archive_is_read_only() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, _) = project_run_fixture(db).await;
    fill_project(db, bob, p, &b1, r).await;
    assert!(
        !worker_do(db, async |w| w.unarchive_project(alice, p).await)
            .await
            .unwrap()
    );
    let err = worker_do(db, async |w| w.archive_project(bob, p).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    assert!(
        worker_do(db, async |w| w.archive_project(alice, p).await)
            .await
            .unwrap()
    );
    assert!(
        !worker_do(db, async |w| w.archive_project(alice, p).await)
            .await
            .unwrap()
    );
    let state: String = sqlx::query_scalar("SELECT state FROM runs WHERE id = $1")
        .bind(r.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(state, "cancelled");
    let mut m = db.member(bob).await.unwrap();
    assert_eq!(
        m.project_detail(p).await.unwrap().summary.status,
        ProjectStatus::Archived
    );
    assert_eq!(
        m.project_runs(
            p,
            &crate::ProjectRunFilter {
                limit: 10,
                ..Default::default()
            }
        )
        .await
        .unwrap()
        .len(),
        1
    );
    assert_eq!(m.project_artifacts(p, None, 10).await.unwrap().len(), 1);
    m.finish().await.unwrap();
    let b2 = instance(db, bob).await;
    let consent = Some(crate::Consent {
        version: proto::domain::PROJECT_CONSENT_VERSION,
    });
    for err in [
        worker_do(db, async |w| {
            w.insert_project_key(p, "k2", b"x").await.map(|_| ())
        })
        .await
        .unwrap_err(),
        worker_do(db, async |w| {
            w.add_project_agents(bob, p, &super::mixed(&[b2.id]), consent, true, 0)
                .await
                .map(|_| ())
        })
        .await
        .unwrap_err(),
        worker_do(db, async |w| {
            w.update_project(alice, p, Some("x"), None).await
        })
        .await
        .unwrap_err(),
    ] {
        assert!(matches!(err, Error::NotFound), "{err:?}");
    }
    let err = worker_do(db, async |w| {
        w.insert_artifact(&crate::NewArtifact {
            id: proto::domain::ArtifactId::new(),
            user: bob,
            instance: b1.id,
            run: r,
            root: r,
            name: "late.md",
            content_type: "text/markdown",
            size: 1,
            sha256: &[3; 32],
            blob_key: "late",
            project: Some(p),
        })
        .await
        .map(|_| ())
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    // 归档着也能退出（8.15 评审：以前是取消归档以后才退的）。
    worker_do(db, async |w| w.leave_project(bob, p).await.map(|_| ()))
        .await
        .unwrap();
    let mut m = db.member(bob).await.unwrap();
    assert!(matches!(m.project_detail(p).await, Err(Error::NotFound)));
    m.finish().await.unwrap();
    assert!(
        worker_do(db, async |w| w.unarchive_project(alice, p).await)
            .await
            .unwrap()
    );
    let mut m = db.member(alice).await.unwrap();
    assert_eq!(
        m.project_detail(p).await.unwrap().summary.status,
        ProjectStatus::Active
    );
    m.finish().await.unwrap();
}

/// 注销留下别人项目里的记录（8.15 测试 9）。
#[tokio::test]
async fn erase_keeps_others_records() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, private) = project_run_fixture(db).await;
    let mut w = db.worker().await.unwrap();
    w.append_event(
        b1.id,
        Some(r),
        "agent.tool_call",
        &serde_json::json!({ "tool_call_id": "t1", "kind": "edit", "status": "pending", "title": "secret", "raw": 1 }),
    )
    .await
    .unwrap();
    w.append_event(
        b1.id,
        Some(r),
        "agent.thought",
        &serde_json::json!({ "text": "secret" }),
    )
    .await
    .unwrap();
    w.append_event(
        b1.id,
        Some(r),
        "run.state",
        &serde_json::json!({ "state": "failed", "reason": "secret", "attempt": 2 }),
    )
    .await
    .unwrap();
    w.create_approval(&crate::NewApproval {
        user: bob,
        instance: b1.id,
        run: r,
        request_id: "perm-1",
        title: None,
        options: &serde_json::json!([]),
        tool_call: &serde_json::json!({}),
        expires_in: std::time::Duration::from_secs(60),
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    sqlx::query("UPDATE runs SET error = 'secret error', state_reason = 'secret' WHERE id = $1")
        .bind(r.0)
        .execute(db.pool())
        .await
        .unwrap();
    worker_do(db, async |w| w.erase_account(bob).await)
        .await
        .unwrap();
    // alice 还看得到 bob 的运行，主人“已注销”；留下的事件只有白名单里的字段。
    let mut m = db.member(alice).await.unwrap();
    let run = m.project_run(p, r).await.unwrap();
    assert_eq!(run.owner.status, proto::domain::ProjectAuthorStatus::Erased);
    m.finish().await.unwrap();
    let payloads: Vec<(String, serde_json::Value)> =
        sqlx::query_as("SELECT kind, payload FROM events WHERE run_id = $1 ORDER BY seq")
            .bind(r.0)
            .fetch_all(db.pool())
            .await
            .unwrap();
    assert_eq!(
        payloads,
        vec![
            (
                "agent.tool_call".into(),
                serde_json::json!({ "tool_call_id": "t1", "kind": "edit", "status": "pending" })
            ),
            ("run.state".into(), serde_json::json!({ "state": "failed" })),
        ]
    );
    let (error, reason): (Option<String>, Option<String>) =
        sqlx::query_as("SELECT error, state_reason FROM runs WHERE id = $1")
            .bind(r.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!((error, reason), (None, None));
    assert_eq!(
        scalar(db, "SELECT count(*) FROM approvals WHERE run_id = $1", r.0).await,
        0
    );
    assert_eq!(
        scalar(db, "SELECT count(*) FROM runs WHERE id = $1", private.0).await,
        0
    );
    // 创建者注销：项目软删除、密钥没了；清理以后什么都不剩。
    worker_do(db, async |w| w.erase_account(alice).await)
        .await
        .unwrap();
    let status: String = sqlx::query_scalar("SELECT status FROM projects WHERE id = $1")
        .bind(p.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(status, "deleted");
    loop {
        let n = worker_do(db, async |w| {
            w.purge_deleted_projects(50, std::time::Duration::ZERO)
                .await
        })
        .await
        .unwrap();
        if n == 0 {
            break;
        }
    }
    assert_eq!(
        scalar(db, "SELECT count(*) FROM projects WHERE id = $1", p.0).await,
        0
    );
    assert_eq!(
        scalar(db, "SELECT count(*) FROM runs WHERE id = $1", r.0).await,
        0
    );
}

/// 删项目和别的事同时进行（8.15 测试 10）：存密钥、接受邀请、退出、成员注销；都不死锁，删完以后没有密钥。
#[tokio::test]
async fn delete_races() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let no_deadlock = |r: &crate::Result<()>| {
        if let Err(Error::Db(e)) = r {
            panic!("database error (deadlock?): {e}");
        }
    };
    for round in 0..3u32 {
        let alice = user(db, &format!("+861380000{round}501")).await;
        let bob = user(db, &format!("+861380000{round}502")).await;
        let carol = user(db, &format!("+861380000{round}503")).await;
        sqlx::query("UPDATE users SET display_name = 'A' WHERE id = $1")
            .bind(alice.0)
            .execute(db.pool())
            .await
            .unwrap();
        let (a1, b1, c1) = (
            instance(db, alice).await,
            instance(db, bob).await,
            instance(db, carol).await,
        );
        let p = solo(db, alice, &a1).await;
        join_raw(db, p, bob, &b1).await;
        let hash = [100 + round as u8; 32];
        worker_do(db, async |w| {
            w.create_link_invite(
                alice,
                p,
                &hash,
                crate::InviteCaps::default(),
                std::time::Duration::from_secs(3600),
            )
            .await
            .map(|_| ())
        })
        .await
        .unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(5));
        let spawn =
            |f: std::pin::Pin<Box<dyn std::future::Future<Output = crate::Result<()>> + Send>>| {
                let b = barrier.clone();
                tokio::spawn(async move {
                    b.wait().await;
                    f.await
                })
            };
        let (d1, d2, d3, d4, d5) = (db.clone(), db.clone(), db.clone(), db.clone(), db.clone());
        let tasks = vec![
            spawn(Box::pin(async move {
                worker_do(&d1, async |w| {
                    w.delete_project(alice, p, true).await.map(|_| ())
                })
                .await
            })),
            spawn(Box::pin(async move {
                worker_do(&d2, async |w| {
                    w.insert_project_key(p, "kms", b"x").await.map(|_| ())
                })
                .await
            })),
            spawn(Box::pin(async move {
                let terms = crate::JoinTerms {
                    agents: vec![crate::JoinAgent::mixed(c1.id)],
                    daily_token_limit: 10,
                    total_token_limit: 100,
                    consent: crate::Consent {
                        version: proto::domain::PROJECT_CONSENT_VERSION,
                    },
                    mixed_allowed: true,
                    max_instances: 0,
                };
                worker_do(&d3, async |w| {
                    w.accept_invite(carol, crate::InviteKey::Link(&hash), &terms)
                        .await
                        .map(|_| ())
                })
                .await
            })),
            spawn(Box::pin(async move {
                worker_do(&d4, async |w| w.leave_project(bob, p).await.map(|_| ())).await
            })),
            spawn(Box::pin(async move {
                worker_do(&d5, async |w| w.erase_account(bob).await).await
            })),
        ];
        let mut results = vec![];
        for t in tasks {
            let r = t.await.unwrap();
            no_deadlock(&r);
            results.push(r);
        }
        assert!(results[0].is_ok(), "{:?}", results[0]);
        results[4].as_ref().unwrap();
        // 删完：没有密钥；接受邀请要么在删之前（然后被一起删掉）要么 NotFound。
        assert_eq!(
            scalar(
                db,
                "SELECT count(*) FROM project_keys WHERE project_id = $1",
                p.0
            )
            .await,
            0,
            "round {round}"
        );
        assert!(
            matches!(results[2], Ok(()) | Err(Error::NotFound)),
            "{:?}",
            results[2]
        );
    }
}

/// 后台清理分配每次的行数（8.15 评审）：一个内容多的项目不会占满每一次，排在后面的小项目一次就删掉。
#[tokio::test]
async fn purge_shares_each_batch_between_projects() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800005301").await;
    // 每个实例同时只能有一个进行中的运行：大项目里放六个 agent，各复制一个运行进去。
    let mut agents = Vec::new();
    for _ in 0..6 {
        agents.push(instance(db, alice).await);
    }
    let mut t = db.tenant(alice).await.unwrap();
    let members: Vec<TeamMember> = agents
        .iter()
        .enumerate()
        .map(|(i, a)| TeamMember {
            instance_id: a.id,
            role: if i == 0 {
                TeamRole::Lead
            } else {
                TeamRole::Member
            },
            position: i as u32,
        })
        .collect();
    let big: ProjectId = t.create_team("big", &members).await.unwrap().id.into();
    t.commit().await.unwrap();
    let small = solo(db, alice, &instance(db, alice).await).await;
    for a in &agents {
        let private = super::queue_run(db, alice, a, "task").await;
        super::projects::copy_into_project(db, "runs", private.id.0, big, None).await;
    }
    for p in [big, small] {
        worker_do(db, async |w| w.delete_project(alice, p, false).await)
            .await
            .unwrap();
    }
    // 先删的大项目排在前面；一次 4 行，各分 2 行：小项目这一次就删完了。
    let n = worker_do(db, async |w| {
        w.purge_deleted_projects(4, std::time::Duration::ZERO).await
    })
    .await
    .unwrap();
    assert!(n >= 3, "{n}");
    assert_eq!(
        scalar(db, "SELECT count(*) FROM projects WHERE id = $1", small.0).await,
        0
    );
    assert_eq!(
        scalar(db, "SELECT count(*) FROM projects WHERE id = $1", big.0).await,
        1
    );
    loop {
        let n = worker_do(db, async |w| {
            w.purge_deleted_projects(4, std::time::Duration::ZERO).await
        })
        .await
        .unwrap();
        if n == 0 {
            break;
        }
    }
    assert_eq!(
        scalar(db, "SELECT count(*) FROM projects WHERE id = $1", big.0).await,
        0
    );
    assert_eq!(
        scalar(db, "SELECT count(*) FROM runs WHERE project_id = $1", big.0).await,
        0
    );
}

/// 启动核对看得到间接的成员关系（8.15 评审）：一个服务角色经过别的角色继承了成员角色，`check_roles` 报错；正常配置下
/// 什么都不报。用临时角色代替服务角色，不碰别的测试在用的角色。
#[tokio::test]
async fn startup_catches_roles_that_inherit_the_member_role() {
    let Some(t) = TestDb::new().await else { return };
    let pool = t.db.pool();
    assert!(
        t.db.role_graph_problems(&crate::schema::SERVICE_ROLES)
            .await
            .unwrap()
            .is_empty()
    );
    let suffix = uuid::Uuid::now_v7().simple().to_string();
    let svc = format!("thinktin_test_svc_{}", &suffix[24..]);
    let mid = format!("thinktin_test_mid_{}", &suffix[24..]);
    for sql in [
        format!("CREATE ROLE {svc} NOLOGIN"),
        format!("CREATE ROLE {mid} NOLOGIN"),
        format!("GRANT thinktin_member TO {mid}"),
        format!("GRANT {mid} TO {svc}"),
    ] {
        sqlx::query(sqlx::AssertSqlSafe(sql))
            .execute(pool)
            .await
            .unwrap();
    }
    let problems = t.db.role_graph_problems(&[svc.as_str()]).await.unwrap();
    for sql in [format!("DROP ROLE {svc}"), format!("DROP ROLE {mid}")] {
        sqlx::query(sqlx::AssertSqlSafe(sql))
            .execute(pool)
            .await
            .unwrap();
    }
    assert_eq!(problems.len(), 1, "{problems:?}");
    assert!(
        problems[0].contains(&format!("{svc} -> thinktin_member")),
        "{problems:?}"
    );
}

/// 先退出、后注销的人（8.15 评审）：留在项目里的内容显示“已注销”，不是“已退出”。
#[tokio::test]
async fn left_then_erased_shows_as_erased() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, _, r, _) = project_run_fixture(db).await;
    worker_do(db, async |w| w.leave_project(bob, p).await)
        .await
        .unwrap();
    let mut m = db.member(alice).await.unwrap();
    assert_eq!(
        m.project_run(p, r).await.unwrap().owner.status,
        proto::domain::ProjectAuthorStatus::Left
    );
    m.finish().await.unwrap();
    worker_do(db, async |w| w.erase_account(bob).await)
        .await
        .unwrap();
    let mut m = db.member(alice).await.unwrap();
    let owner = m.project_run(p, r).await.unwrap().owner;
    assert_eq!(owner.status, proto::domain::ProjectAuthorStatus::Erased);
    assert_eq!((owner.user_id, owner.display_name), (None, None));
    m.finish().await.unwrap();
}

/// bob 的项目运行上一个待审批的审批、它的提醒、一条运行提醒（8.15 评审：退出时这些都要结掉）。
async fn pending_approval_and_notices(
    db: &Db,
    bob: UserId,
    b1: &Instance,
    r: proto::domain::RunId,
) -> (uuid::Uuid, Vec<proto::domain::InboxItemId>) {
    let mut w = db.worker().await.unwrap();
    let a = w
        .create_approval(&crate::NewApproval {
            user: bob,
            instance: b1.id,
            run: r,
            request_id: "perm-1",
            title: None,
            options: &serde_json::json!([]),
            tool_call: &serde_json::json!({}),
            expires_in: std::time::Duration::from_secs(600),
        })
        .await
        .unwrap();
    let mut notices = Vec::new();
    for (kind, approval) in [("approval", Some(a.approval.id)), ("run_finished", None)] {
        let id = w
            .insert_inbox(
                bob,
                &crate::NewInboxItem {
                    kind: kind.into(),
                    title: kind.into(),
                    instance_id: Some(b1.id),
                    run_id: Some(r),
                    approval_id: approval,
                    ..crate::NewInboxItem::default()
                },
            )
            .await
            .unwrap()
            .unwrap();
        notices.push(id);
    }
    assert_eq!(w.unread_inbox_count(bob).await.unwrap(), 2);
    w.commit().await.unwrap();
    (a.approval.id.0, notices)
}

async fn assert_settled(
    db: &Db,
    bob: UserId,
    approval: uuid::Uuid,
    notices: &[proto::domain::InboxItemId],
) {
    let state: String = sqlx::query_scalar("SELECT state FROM approvals WHERE id = $1")
        .bind(approval)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(state, "cancelled");
    for n in notices {
        let read: bool =
            sqlx::query_scalar("SELECT read_at IS NOT NULL FROM inbox_items WHERE id = $1")
                .bind(n.0)
                .fetch_one(db.pool())
                .await
                .unwrap();
        assert!(read, "{n}");
    }
    let mut w = db.worker().await.unwrap();
    assert_eq!(w.unread_inbox_count(bob).await.unwrap(), 0, "the badge");
    w.rollback().await.unwrap();
}

/// 退出（D23，8.15 评审）：项目里待审批的审批取消，它的提醒和运行提醒标已读，角标不再算它们。
#[tokio::test]
async fn leaving_settles_approvals_and_notices() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (_, bob, p, b1, r, _) = project_run_fixture(db).await;
    let (approval, notices) = pending_approval_and_notices(db, bob, &b1, r).await;
    worker_do(db, async |w| w.leave_project(bob, p).await)
        .await
        .unwrap();
    assert_settled(db, bob, approval, &notices).await;
}

/// 删项目（8.15 评审）：和退出一样结掉还在的成员的审批和提醒。
#[tokio::test]
async fn deleting_settles_approvals_and_notices() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, _) = project_run_fixture(db).await;
    let (approval, notices) = pending_approval_and_notices(db, bob, &b1, r).await;
    worker_do(db, async |w| w.delete_project(alice, p, true).await)
        .await
        .unwrap();
    assert_settled(db, bob, approval, &notices).await;
}

/// 成员角色的权限一项不多（8.15 评审）：表、列权限和下面的单子完全一样；定义者不拥有任何表；库里的回执子类型和
/// `PROJECT_RECEIPTS` 完全一样（多认一种，退出的人就还看得到那种提醒）。
#[tokio::test]
async fn member_privileges_are_exactly_the_allow_list() {
    let Some(t) = TestDb::new().await else { return };
    let pool = t.db.pool();
    let mut columns: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT table_name::text, column_name::text, privilege_type::text \
           FROM information_schema.column_privileges \
          WHERE grantee = 'thinktin_member' AND table_schema = 'public' ORDER BY 1, 2, 3",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    columns.dedup();
    let expected: Vec<(String, String, String)> = [
        ("instances", "agent_id"),
        ("instances", "id"),
        ("instances", "name"),
        ("instances", "user_id"),
        ("project_agents", "added_at"),
        ("project_agents", "dedicated"),
        ("project_agents", "instance_id"),
        ("project_agents", "is_lead"),
        ("project_agents", "left_at"),
        ("project_agents", "position"),
        ("project_agents", "project_id"),
        ("project_agents", "user_id"),
        // 8.17 的项目看板：读的列，没有 revived_at（只用来排自动归档的顺序）。
        ("project_board_posts", "archived_at"),
        ("project_board_posts", "author_instance_id"),
        ("project_board_posts", "author_user_id"),
        ("project_board_posts", "body"),
        ("project_board_posts", "by_agent"),
        ("project_board_posts", "created_at"),
        ("project_board_posts", "id"),
        ("project_board_posts", "project_id"),
        ("project_board_posts", "run_id"),
        ("project_board_posts", "tags"),
        ("project_members", "joined_at"),
        ("project_members", "left_at"),
        ("project_members", "left_reason"),
        ("project_members", "project_id"),
        ("project_members", "role"),
        ("project_members", "user_id"),
        ("projects", "archived_at"),
        ("projects", "created_at"),
        ("projects", "creator_id"),
        ("projects", "goal"),
        ("projects", "id"),
        ("projects", "name"),
        ("projects", "shared_at"),
        ("projects", "status"),
        ("projects", "updated_at"),
        ("users", "display_name"),
        ("users", "id"),
    ]
    .iter()
    .map(|(t, c)| (t.to_string(), c.to_string(), "SELECT".to_string()))
    .collect();
    let artifacts: Vec<(String, String, String)> = columns
        .iter()
        .filter(|(t, _, _)| t == "artifacts")
        .cloned()
        .collect();
    let others: Vec<(String, String, String)> = columns
        .into_iter()
        .filter(|(t, _, _)| t != "artifacts")
        .collect();
    assert_eq!(others, expected);
    // 产出物：只有读的列，没有内容所在的键和主人以外的东西。
    let artifact_cols: Vec<&str> = artifacts.iter().map(|(_, c, _)| c.as_str()).collect();
    assert!(
        artifacts.iter().all(|(_, _, p)| p == "SELECT"),
        "{artifacts:?}"
    );
    for private in ["blob_key", "space_id", "space_kind"] {
        assert!(!artifact_cols.contains(&private), "{artifact_cols:?}");
    }
    let tables: Vec<(String, String)> = sqlx::query_as(
        "SELECT table_name::text, privilege_type::text FROM information_schema.role_table_grants \
          WHERE grantee = 'thinktin_member' AND table_schema = 'public' ORDER BY 1, 2",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    assert!(tables.is_empty(), "table-wide grants: {tables:?}");
    let owned: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM pg_class WHERE relowner = 'thinktin_project_definer'::regrole",
    )
    .fetch_one(pool)
    .await
    .unwrap();
    assert_eq!(owned, 0);
    // 库里的回执列表：每个已知的提醒子类型，是不是回执两边一致。
    for s in proto::domain::notice_subtype::ALL {
        let receipt: Option<bool> = sqlx::query_scalar("SELECT project_receipt($1)")
            .bind(s)
            .fetch_one(pool)
            .await
            .unwrap();
        assert_eq!(
            receipt.unwrap_or(false),
            proto::domain::notice_subtype::PROJECT_RECEIPTS.contains(&s),
            "{s}"
        );
    }
}

async fn project_of(db: &Db, table: &str, id: uuid::Uuid) -> Option<uuid::Uuid> {
    sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
        "SELECT project_id FROM {table} WHERE id = $1"
    )))
    .bind(id)
    .fetch_one(db.pool())
    .await
    .unwrap()
}

const BOARD_SQL: &str = "INSERT INTO board_posts (id, user_id, author_instance_id, run_id, by_agent, body) \
                         VALUES ($1, $2, $3, $4, true, 'hi')";
const VAULT_SQL: &str = "INSERT INTO vault_requests (id, user_id, instance_id, run_id, name, expires_at) \
                         VALUES ($1, $2, $3, $4, 'github', now() + interval '1 hour')";
const REPORT_SQL: &str = "INSERT INTO content_reports (id, user_id, instance_id, run_id, reason, snapshot, state, \
                            handled_at) \
                          VALUES ($1, $2, $3, $4, 'other', '{}', $5, CASE WHEN $5 = 'closed' THEN now() END)";

/// 带运行的其余几张表也记项目（8.16 测试 10，迁移 0056）：项目按运行算，租户自己填不了，填了和运行对不上的不行；建了
/// 不能改、不能挪到别的运行；运行删了（外键置空）项目还在；退出以后租户看不到、也写不进；删了的项目 worker 也写不进。
#[tokio::test]
async fn run_linked_rows_carry_the_project() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, private) = project_run_fixture(db).await;
    let vault = uuid::Uuid::now_v7();
    let mut tb = db.tenant(bob).await.unwrap();
    sqlx::query(VAULT_SQL)
        .bind(vault)
        .bind(bob.0)
        .bind(b1.id.0)
        .bind(r.0)
        .execute(tb.conn())
        .await
        .unwrap();
    tb.commit().await.unwrap();
    assert_eq!(project_of(db, "vault_requests", vault).await, Some(p.0));
    // 私人看板不收项目运行写的（8.17：项目看板是单独的表，迁移 0060 的 board_posts_private）。
    let mut tb = db.tenant(bob).await.unwrap();
    let err = sqlx::query(BOARD_SQL)
        .bind(uuid::Uuid::now_v7())
        .bind(bob.0)
        .bind(b1.id.0)
        .bind(r.0)
        .execute(tb.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(
        matches!(&err, Error::Invalid(m) if m == "board_posts_private"),
        "{err:?}"
    );
    tb.rollback().await.unwrap();
    // 租户自己填项目：不行。
    let mut tb = db.tenant(bob).await.unwrap();
    let err = sqlx::query(
        "INSERT INTO board_posts (id, user_id, run_id, by_agent, body, project_id) \
         VALUES ($1, $2, $3, false, 'x', $4)",
    )
    .bind(uuid::Uuid::now_v7())
    .bind(bob.0)
    .bind(private.0)
    .bind(p.0)
    .execute(tb.conn())
    .await
    .map_err(Error::from)
    .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    tb.rollback().await.unwrap();
    // worker 也不往私人看板写项目条目（8.17 的项目看板是 project_board_posts），带了运行的要和运行一致。
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(
        "INSERT INTO board_posts (id, user_id, by_agent, body, project_id) VALUES ($1, $2, false, 'x', $3)",
    )
    .bind(uuid::Uuid::now_v7())
    .bind(bob.0)
    .bind(p.0)
    .execute(w.conn())
    .await
    .map_err(Error::from)
    .unwrap_err();
    assert!(
        matches!(&err, Error::Invalid(m) if m == "board_posts_private"),
        "{err:?}"
    );
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(
        "INSERT INTO board_posts (id, user_id, run_id, by_agent, body, project_id) \
         VALUES ($1, $2, $3, false, 'x', $4)",
    )
    .bind(uuid::Uuid::now_v7())
    .bind(bob.0)
    .bind(private.0)
    .bind(p.0)
    .execute(w.conn())
    .await
    .map_err(Error::from)
    .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
    // 举报（没有外键）也带上项目。
    let report = uuid::Uuid::now_v7();
    let mut tb = db.tenant(bob).await.unwrap();
    sqlx::query(REPORT_SQL)
        .bind(report)
        .bind(bob.0)
        .bind(b1.id.0)
        .bind(r.0)
        .bind("open")
        .execute(tb.conn())
        .await
        .unwrap();
    tb.commit().await.unwrap();
    assert_eq!(project_of(db, "content_reports", report).await, Some(p.0));
    // 建了不能改项目、不能挪运行。
    for sql in [
        "UPDATE vault_requests SET project_id = NULL WHERE id = $1",
        "UPDATE vault_requests SET run_id = $2 WHERE id = $1",
    ] {
        let mut w = db.worker().await.unwrap();
        let err = sqlx::query(sqlx::AssertSqlSafe(sql.to_string()))
            .bind(vault)
            .bind(private.0)
            .execute(w.conn())
            .await
            .map_err(Error::from)
            .unwrap_err();
        assert!(matches!(err, Error::Invalid(_)), "{sql}: {err:?}");
        w.rollback().await.unwrap();
    }
    // 租户只改保险箱请求的处理结果。
    let mut tb = db.tenant(bob).await.unwrap();
    let err = sqlx::query("UPDATE vault_requests SET run_id = $2 WHERE id = $1")
        .bind(vault)
        .bind(private.0)
        .execute(tb.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    tb.rollback().await.unwrap();
    let mut tb = db.tenant(bob).await.unwrap();
    sqlx::query("UPDATE vault_requests SET status = 'declined', resolved_at = now() WHERE id = $1")
        .bind(vault)
        .execute(tb.conn())
        .await
        .unwrap();
    tb.commit().await.unwrap();
    // bob 退出：看不到这些行，也写不进（运行看不到：23503）。
    worker_do(db, async |w| w.leave_project(bob, p).await.map(|_| ()))
        .await
        .unwrap();
    let mut tb = db.tenant(bob).await.unwrap();
    for (table, id) in [("vault_requests", vault), ("content_reports", report)] {
        let n: i64 = sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT count(*) FROM {table} WHERE id = $1"
        )))
        .bind(id)
        .fetch_one(tb.conn())
        .await
        .unwrap();
        assert_eq!(n, 0, "{table}");
    }
    let err = sqlx::query(VAULT_SQL)
        .bind(uuid::Uuid::now_v7())
        .bind(bob.0)
        .bind(b1.id.0)
        .bind(r.0)
        .execute(tb.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    tb.rollback().await.unwrap();
    // 删了的项目：worker 也写不进。
    worker_do(db, async |w| {
        w.delete_project(alice, p, true).await.map(|_| ())
    })
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query(VAULT_SQL)
        .bind(uuid::Uuid::now_v7())
        .bind(bob.0)
        .bind(b1.id.0)
        .bind(r.0)
        .execute(w.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(
        matches!(&err, Error::Invalid(m) if m == "project_deleted"),
        "{err:?}"
    );
    w.rollback().await.unwrap();
    // 运行删了（外键置空 run_id）：项目还记着，后台清理按项目找得到。
    sqlx::query("DELETE FROM runs WHERE id = $1")
        .bind(r.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert_eq!(project_of(db, "vault_requests", vault).await, Some(p.0));
    let run: Option<uuid::Uuid> =
        sqlx::query_scalar("SELECT run_id FROM vault_requests WHERE id = $1")
            .bind(vault)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(run, None);
}

/// 后台清理删掉带运行的其余几张表里项目的行（8.16 测试 11 的表这一半）；没处理的举报留着，处理完的删掉。
#[tokio::test]
async fn purge_clears_run_linked_project_rows() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, bob, p, b1, r, _) = project_run_fixture(db).await;
    // 私人看板不收项目条目（8.17，项目看板的清理在 project_board 的测试里）。
    let (vault, open, closed) = (
        uuid::Uuid::now_v7(),
        uuid::Uuid::now_v7(),
        uuid::Uuid::now_v7(),
    );
    let mut w = db.worker().await.unwrap();
    sqlx::query(VAULT_SQL)
        .bind(vault)
        .bind(bob.0)
        .bind(b1.id.0)
        .bind(r.0)
        .execute(w.conn())
        .await
        .unwrap();
    for (id, state) in [(open, "open"), (closed, "closed")] {
        sqlx::query(REPORT_SQL)
            .bind(id)
            .bind(bob.0)
            .bind(b1.id.0)
            .bind(r.0)
            .bind(state)
            .execute(w.conn())
            .await
            .unwrap();
    }
    w.commit().await.unwrap();
    worker_do(db, async |w| {
        w.delete_project(alice, p, true).await.map(|_| ())
    })
    .await
    .unwrap();
    loop {
        let n = worker_do(db, async |w| {
            w.purge_deleted_projects(50, std::time::Duration::ZERO)
                .await
        })
        .await
        .unwrap();
        if n == 0 {
            break;
        }
    }
    for (table, id, left) in [
        ("vault_requests", vault, 0),
        ("content_reports", closed, 0),
        ("content_reports", open, 1),
        ("projects", p.0, 0),
    ] {
        assert_eq!(
            scalar(
                db,
                &format!("SELECT count(*) FROM {table} WHERE id = $1"),
                id
            )
            .await,
            left,
            "{table}"
        );
    }
}

/// 用户审批和取消项目运行同时进行（8.16 测试 12）：审批先锁审批、再改实例（追加事件）；取消现在也是先审批后实例，不会
/// 互相等死（以前取消先给实例加代数再改审批，两边各拿一半）。四个取消函数各来几轮，审批在拿着审批锁时停一下，让取消
/// 在中间插进来。
#[tokio::test]
async fn cancel_and_decide_do_not_deadlock() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (_, bob, p, b1, r, private) = project_run_fixture(db).await;
    let mut run = r;
    for round in 0..8 {
        if round > 0 {
            run = proto::domain::RunId(
                super::projects::copy_into_project(db, "runs", private.0, p, None).await,
            );
        }
        let mut w = db.worker().await.unwrap();
        let a = w
            .create_approval(&crate::NewApproval {
                user: bob,
                instance: b1.id,
                run,
                request_id: "perm-1",
                title: None,
                options: &serde_json::json!([{ "option_id": "allow", "name": "Allow", "kind": "allow_once" }]),
                tool_call: &serde_json::json!({}),
                expires_in: std::time::Duration::from_secs(600),
            })
            .await
            .unwrap();
        w.commit().await.unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (db1, db2, b1c, bar1, bar2) =
            (db.clone(), db.clone(), b1.clone(), barrier.clone(), barrier);
        let decide = tokio::spawn(async move {
            let mut t = db1.tenant(bob).await.unwrap();
            let got = t
                .decide_approval(a.approval.id, "allow", proto::domain::DeviceId::new())
                .await;
            bar1.wait().await;
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            let appended = t
                .append_event(
                    b1c.id,
                    Some(run),
                    "approval.decided",
                    &serde_json::json!({}),
                )
                .await;
            match (got, appended) {
                (Ok(_), Ok(_)) => t.commit().await,
                (Err(e), _) | (_, Err(e)) => Err(e),
            }
        });
        let cancel = tokio::spawn(async move {
            bar2.wait().await;
            tokio::time::sleep(std::time::Duration::from_millis(30)).await;
            let mut w = db2.worker().await.unwrap();
            let n = match round % 4 {
                0 => w.cancel_project_agent_runs(p, b1.id, "withdrawn").await,
                1 => w.cancel_project_member_runs(p, bob, "left").await,
                2 => w.cancel_project_runs(p, "archived").await,
                _ => w.cancel_user_runs(bob, "account frozen").await,
            };
            match n {
                Ok(_) => w.commit().await,
                Err(e) => Err(e),
            }
        });
        for (what, r) in [
            ("decide", decide.await.unwrap()),
            ("cancel", cancel.await.unwrap()),
        ] {
            if let Err(e) = r {
                panic!("round {round} {what}: {e:?}");
            }
        }
        let state: String = sqlx::query_scalar("SELECT state FROM runs WHERE id = $1")
            .bind(run.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(state, "cancelled", "round {round}");
    }
}

/// 用原始 SQL 把运行放进某个状态：在声明了 1 级隔离的事务里（拿着租约的项目运行要过 0055 的 runs_isolation 栅栏）。
async fn seed_run(db: &Db, run: proto::domain::RunId, sql: &str) {
    let mut conn = db.pool().begin().await.unwrap();
    sqlx::query("SELECT set_config('thinktin.isolation', '1', true), set_config('thinktin.project_protocol', '2', true)")
        .execute(&mut *conn)
        .await
        .unwrap();
    sqlx::query(sqlx::AssertSqlSafe(sql.to_string()))
        .bind(run.0)
        .execute(&mut *conn)
        .await
        .unwrap();
    conn.commit().await.unwrap();
}

/// agent 行标成离开（没走取消的路径，比如以前的程序）或者放回来（放回来时触发器按实例重新算 dedicated）。
async fn set_agent_left(db: &Db, p: ProjectId, instance: proto::domain::InstanceId, left: bool) {
    sqlx::query(
        "UPDATE project_agents SET left_at = CASE WHEN $3 THEN now() END, is_lead = false \
          WHERE project_id = $1 AND instance_id = $2",
    )
    .bind(p.0)
    .bind(instance.0)
    .bind(left)
    .execute(db.pool())
    .await
    .unwrap();
}

/// 后台兜底取消项目运行（8.16 测试 13）：专属实例上的项目运行，agent 行还在时，租约过期的被接管领到、等 key 过了期限的
/// 被等待超时领到；agent 行被标成离开以后两个都不碰它。兜底把它取消，审批作废、等着的出网请求过期、令牌代数加一；
/// 别的实例上的私人运行不动。
#[tokio::test]
async fn orphan_sweeper_frees_the_instance() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (_, bob, p, b1, r, private) = project_run_fixture(db).await;
    // b1 标成专属（这一版只领专属实例上的项目运行，混用实例上的 isolated! 本来就不领）：标专属要实例空闲，上面的两个
    // 运行先结束，标完再把项目运行放回去。
    sqlx::query(
        "UPDATE runs SET state = 'cancelled', lease_owner = NULL, lease_expires_at = NULL, finished_at = now() \
          WHERE id = ANY($1)",
    )
    .bind(vec![r.0, private.0])
    .execute(db.pool())
    .await
    .unwrap();
    sqlx::query(
        "UPDATE instances SET workspace_project_id = $2, peer_access = false WHERE id = $1",
    )
    .bind(b1.id.0)
    .bind(p.0)
    .execute(db.pool())
    .await
    .unwrap();
    set_agent_left(db, p, b1.id, false).await;
    let dedicated: bool = sqlx::query_scalar(
        "SELECT dedicated FROM project_agents WHERE project_id = $1 AND instance_id = $2",
    )
    .bind(p.0)
    .bind(b1.id.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert!(dedicated, "the derived flag follows the instance");
    let other = instance(db, bob).await;
    let elsewhere = super::queue_run(db, bob, &other, "private task").await.id;
    let egress = uuid::Uuid::now_v7();
    let mut w = db.worker().await.unwrap();
    let a = w
        .create_approval(&crate::NewApproval {
            user: bob,
            instance: b1.id,
            run: r,
            request_id: "perm-1",
            title: None,
            options: &serde_json::json!([]),
            tool_call: &serde_json::json!({}),
            expires_in: std::time::Duration::from_secs(600),
        })
        .await
        .unwrap();
    w.commit().await.unwrap();
    // 出网请求只有出口代理写（这里直接写）。
    sqlx::query(
        "INSERT INTO egress_requests (id, user_id, instance_id, host, run_id) VALUES ($1, $2, $3, 'example.com', $4)",
    )
    .bind(egress)
    .bind(bob.0)
    .bind(b1.id.0)
    .bind(r.0)
    .execute(db.pool())
    .await
    .unwrap();
    // 两种接管的状态：跑着、租约过期（接管）；等 key、过了期限（等待超时）。agent 行在时领得到，离开以后领不到。
    let lease = std::time::Duration::from_secs(60);
    for (seed, takeover) in [
        (
            "UPDATE runs SET state = 'running', lease_owner = 'gone', \
               lease_expires_at = now() - interval '1 minute', finished_at = NULL WHERE id = $1",
            true,
        ),
        (
            "UPDATE runs SET state = 'waiting_quota', lease_owner = NULL, lease_expires_at = NULL, \
               wait_deadline = now() - interval '1 minute', finished_at = NULL WHERE id = $1",
            false,
        ),
    ] {
        seed_run(db, r, seed).await;
        for left in [false, true] {
            set_agent_left(db, p, b1.id, left).await;
            let mut w = db.worker().await.unwrap();
            let got = if takeover {
                w.take_over_expired("w1", lease, 10).await
            } else {
                w.claim_expired_waits("w1", lease, 10).await
            }
            .unwrap();
            w.rollback().await.unwrap();
            let got: Vec<_> = got.iter().map(|g| g.run.id).collect();
            let want = if left { vec![] } else { vec![r] };
            assert_eq!(got, want, "{seed} (agent left: {left})");
        }
    }
    let epoch: i64 = sqlx::query_scalar("SELECT token_epoch FROM instances WHERE id = $1")
        .bind(b1.id.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    let got = w.cancel_orphaned_project_runs(10).await.unwrap();
    w.commit().await.unwrap();
    assert_eq!(got, vec![(r, b1.id, false)]);
    for (sql, id, want) in [
        ("SELECT state FROM runs WHERE id = $1", r.0, "cancelled"),
        (
            "SELECT state FROM approvals WHERE id = $1",
            a.approval.id.0,
            "cancelled",
        ),
        (
            "SELECT status FROM egress_requests WHERE id = $1",
            egress,
            "expired",
        ),
        (
            "SELECT state FROM runs WHERE id = $1",
            elsewhere.0,
            "queued",
        ),
    ] {
        let got: String = sqlx::query_scalar(sqlx::AssertSqlSafe(sql.to_string()))
            .bind(id)
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(got, want, "{sql}");
    }
    let after: i64 = sqlx::query_scalar("SELECT token_epoch FROM instances WHERE id = $1")
        .bind(b1.id.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(after, epoch + 1);
    // 再来一次：没有了。
    let mut w = db.worker().await.unwrap();
    assert!(w.cancel_orphaned_project_runs(10).await.unwrap().is_empty());
    w.rollback().await.unwrap();
}

/// 创建者注销（8.16 测试 20）：他建的项目软删除，别的成员专属于它的实例在同一个事务里换回全新的私人工作区。
#[tokio::test]
async fn creator_erase_retires_members_dedicated_instances() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let (alice, _bob, p, b1, _, _) = project_run_fixture(db).await;
    // b1 上的运行先结束（标专属要实例空闲），再标成专属。
    sqlx::query(
        "UPDATE runs SET state = 'cancelled', lease_owner = NULL, lease_expires_at = NULL, finished_at = now() \
          WHERE instance_id = $1",
    )
    .bind(b1.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    sqlx::query(
        "UPDATE instances SET workspace_project_id = $2, peer_access = false WHERE id = $1",
    )
    .bind(b1.id.0)
    .bind(p.0)
    .execute(db.pool())
    .await
    .unwrap();
    worker_do(db, async |w| w.erase_account(alice).await)
        .await
        .unwrap();
    let (space, state, peers): (Option<uuid::Uuid>, String, bool) = sqlx::query_as(
        "SELECT workspace_project_id, state, peer_access FROM instances WHERE id = $1",
    )
    .bind(b1.id.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!((space, state.as_str(), peers), (None, "provisioning", true));
}
