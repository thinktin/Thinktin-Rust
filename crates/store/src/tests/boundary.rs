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
    let (a1, b1) = (instance(db, alice).await, instance(db, bob).await);
    let p = solo(db, alice, &a1).await;
    join_raw(db, p, bob, &b1).await;
    let private = super::queue_run(db, bob, &b1, "private").await;
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
