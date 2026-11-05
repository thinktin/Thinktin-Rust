//! 项目与跨用户协作（8.14 起）的库测试。需要真实 Postgres，没设置 DATABASE_URL 时跳过。

use proto::domain::{
    Instance, ProjectId, ProjectInviteId, ProjectRole, TeamMember, TeamRole, UserId,
};

use super::{instance, queue_run, user};
use crate::testing::TestDb;
use crate::{Db, Error, NewInboxItem};

/// alice 的单人项目（经旧的团队接口建），负责人是 `lead`。
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

/// 用 worker 的原始 SQL 把 `member` 和他的 agent 加进项目（8.14 的加入流程写好以前，测试这样共享项目）。
async fn join_raw(db: &Db, project: ProjectId, member: UserId, agents: &[&Instance]) {
    let mut w = db.worker().await.unwrap();
    sqlx::query(
        "INSERT INTO project_members (project_id, user_id, role, consented_at) \
         VALUES ($1, $2, 'member', now())",
    )
    .bind(project.0)
    .bind(member.0)
    .execute(w.conn())
    .await
    .unwrap();
    for (n, a) in agents.iter().enumerate() {
        sqlx::query(
            "INSERT INTO project_agents (project_id, instance_id, user_id, position) \
             VALUES ($1, $2, $3, $4)",
        )
        .bind(project.0)
        .bind(a.id.0)
        .bind(member.0)
        .bind(n as i32 + 10)
        .execute(w.conn())
        .await
        .unwrap();
    }
    w.commit().await.unwrap();
}

/// 跨用户的行只有 worker 写得出（8.14 测试 8）：租户碰不到邀请、拉黑表，写不出“成员”行，改不了共享项目里自己的
/// agent；加入了别人的项目也读不到那个项目的行；旧的团队接口改共享项目回 Conflict。
#[tokio::test]
async fn cross_user_rows_are_worker_only() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800001011").await;
    let bob = user(db, "+8613800001012").await;
    let a1 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let project = solo(db, alice, &a1).await;
    let forbidden = |sql: String| async move {
        let mut tb = db.tenant(bob).await.unwrap();
        let err = sqlx::query(sqlx::AssertSqlSafe(sql.clone()))
            .execute(tb.conn())
            .await
            .map_err(Error::from)
            .unwrap_err();
        assert!(matches!(err, Error::Forbidden(_)), "{sql}: {err:?}");
    };
    let (p, a, b) = (project.0, alice.0, bob.0);
    forbidden("SELECT count(*) FROM project_invites".into()).await;
    forbidden("SELECT count(*) FROM user_blocks".into()).await;
    forbidden(format!(
        "INSERT INTO project_invites (id, project_id, inviter_id, kind, invitee_phone, expires_at) \
         VALUES (gen_random_uuid(), '{p}', '{a}', 'phone', '+8613800001012', now() + interval '1 day')"
    ))
    .await;
    forbidden(format!(
        "INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ('{b}', '{a}')"
    ))
    .await;
    // 自己把自己写成别人项目的成员：没有 consented_at 的列权限；只写有权限的列，策略也只放行创建者行。
    forbidden(format!(
        "INSERT INTO project_members (project_id, user_id, role, consented_at) \
         VALUES ('{p}', '{b}', 'member', now())"
    ))
    .await;
    {
        let mut tb = db.tenant(bob).await.unwrap();
        let err = sqlx::query(sqlx::AssertSqlSafe(format!(
            "INSERT INTO project_members (project_id, user_id, role) VALUES ('{p}', '{b}', 'member')"
        )))
        .execute(tb.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
        assert!(
            matches!(err, Error::Forbidden(_) | Error::Invalid(_)),
            "{err:?}"
        );
    }
    // worker 共享项目以后：bob 还是读不到 alice 的项目行；他改不了自己在共享项目里的 agent 行（0 行）。
    join_raw(db, project, bob, &[&b1]).await;
    let mut tb = db.tenant(bob).await.unwrap();
    let seen: i64 = sqlx::query_scalar("SELECT count(*) FROM projects WHERE id = $1")
        .bind(project.0)
        .fetch_one(tb.conn())
        .await
        .unwrap();
    assert_eq!(seen, 0);
    let done = sqlx::query(
        "UPDATE project_agents SET position = 99 WHERE project_id = $1 AND instance_id = $2",
    )
    .bind(project.0)
    .bind(b1.id.0)
    .execute(tb.conn())
    .await
    .unwrap();
    assert_eq!(done.rows_affected(), 0);
    tb.rollback().await.unwrap();
    // alice 自己的租户事务也改不了共享了的项目：旧的团队接口回 Conflict，项目还在。
    let mut ta = db.tenant(alice).await.unwrap();
    let err = ta
        .update_team(project.into(), Some("renamed"), None)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Conflict(_)), "{err:?}");
    ta.rollback().await.unwrap();
    let mut ta = db.tenant(alice).await.unwrap();
    let err = ta.delete_team(project.into()).await.unwrap_err();
    assert!(matches!(err, Error::Conflict(_)), "{err:?}");
    ta.rollback().await.unwrap();
}

/// 项目列表和详情（8.14 的 worker 读法）：只给成员看；人数、agent 数不算删了的实例；预算只给自己的；只有创建者改得了
/// 名字和目标。
#[tokio::test]
async fn project_reads_follow_membership() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800001021").await;
    let bob = user(db, "+8613800001022").await;
    let carol = user(db, "+8613800001023").await;
    let a1 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let b2 = instance(db, bob).await;
    let project = solo(db, alice, &a1).await;
    sqlx::query("UPDATE users SET display_name = 'Alice' WHERE id = $1")
        .bind(alice.0)
        .execute(db.pool())
        .await
        .unwrap();
    // 只有创建者的时候：alice 看得到，bob、carol 看不到。
    let mut w = db.worker().await.unwrap();
    let mine = w.my_projects(alice).await.unwrap();
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0].role, ProjectRole::Creator);
    assert!(!mine[0].shared);
    assert!(w.my_projects(bob).await.unwrap().is_empty());
    assert!(matches!(
        w.project_detail(carol, project).await,
        Err(Error::NotFound)
    ));
    w.rollback().await.unwrap();

    join_raw(db, project, bob, &[&b1, &b2]).await;
    sqlx::query(
        "UPDATE project_members SET daily_token_limit = 1000, total_token_limit = 5000 \
         WHERE project_id = $1 AND user_id = $2",
    )
    .bind(project.0)
    .bind(bob.0)
    .execute(db.pool())
    .await
    .unwrap();
    // b2 删掉了：不算、不列。
    sqlx::query("UPDATE instances SET state = 'deleted', deleted_at = now() WHERE id = $1")
        .bind(b2.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let mut w = db.worker().await.unwrap();
    let bobs = w.my_projects(bob).await.unwrap();
    assert_eq!(bobs.len(), 1);
    let s = &bobs[0];
    assert_eq!(
        (s.id, s.role, s.shared),
        (project, ProjectRole::Member, true)
    );
    assert_eq!(s.creator.user_id, alice);
    assert_eq!(s.creator.display_name.as_deref(), Some("Alice"));
    assert_eq!((s.member_count, s.agent_count, s.my_agent_count), (2, 2, 1));
    let d = w.project_detail(bob, project).await.unwrap();
    assert_eq!(d.members.len(), 2);
    assert_eq!(d.members[0].user_id, alice);
    assert_eq!(d.members[0].role, ProjectRole::Creator);
    assert!(d.members[1].is_me && d.members[1].agent_count == 1);
    let ids: Vec<_> = d.agents.iter().map(|a| (a.instance_id, a.mine)).collect();
    assert_eq!(ids, vec![(a1.id, false), (b1.id, true)]);
    assert_eq!(d.my_budget.daily_token_limit, Some(1000));
    assert_eq!(d.my_budget.total_token_limit, Some(5000));
    let da = w.project_detail(alice, project).await.unwrap();
    assert_eq!(da.my_budget.daily_token_limit, None);
    assert!(matches!(
        w.project_detail(carol, project).await,
        Err(Error::NotFound)
    ));
    w.rollback().await.unwrap();

    // 改名字、目标：只有创建者；不是成员的 NotFound。
    let mut w = db.worker().await.unwrap();
    let err = w
        .update_project(bob, project, Some("x"), None)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let err = w
        .update_project(carol, project, Some("x"), None)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    w.rollback().await.unwrap();
    let mut w = db.worker().await.unwrap();
    w.update_project(alice, project, None, Some("ship it"))
        .await
        .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let d = w.project_detail(bob, project).await.unwrap();
    assert_eq!(
        (d.summary.name.as_str(), d.summary.goal.as_str()),
        ("p", "ship it")
    );
    // 太长的目标：库里的 CHECK 拦住。
    let err = w
        .update_project(alice, project, None, Some(&"x".repeat(4001)))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
    // bob 退出（原始 SQL）以后就看不到了。
    sqlx::query(
        "UPDATE project_members SET left_at = now(), left_reason = 'left' \
         WHERE project_id = $1 AND user_id = $2",
    )
    .bind(project.0)
    .bind(bob.0)
    .execute(db.pool())
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    assert!(w.my_projects(bob).await.unwrap().is_empty());
    assert!(matches!(
        w.project_detail(bob, project).await,
        Err(Error::NotFound)
    ));
    let d = w.project_detail(alice, project).await.unwrap();
    assert_eq!((d.summary.member_count, d.summary.shared), (1, true));
    w.rollback().await.unwrap();
}

/// 收件箱里项目回执的字段（8.14，0047 的 inbox_project_guard）：只有 worker 写得出；写了以后谁都不能改它们和子类型；
/// 租户照样能标已读；运行删掉以后 run_id 置空、project_id 留着。
#[tokio::test]
async fn inbox_project_fields_are_server_only() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800001001").await;
    let i = instance(db, alice).await;
    let mut ta = db.tenant(alice).await.unwrap();
    let team = ta
        .create_team(
            "p",
            &[TeamMember {
                instance_id: i.id,
                role: TeamRole::Lead,
                position: 0,
            }],
        )
        .await
        .unwrap();
    ta.commit().await.unwrap();
    let project: ProjectId = team.id.into();
    let run = queue_run(db, alice, &i, "x").await;
    let item = |project_id: Option<ProjectId>| NewInboxItem {
        kind: "info".into(),
        title: "t".into(),
        body: "b".into(),
        run_id: Some(run.id),
        project_id,
        project_invite_id: project_id.map(|_| ProjectInviteId::new()),
        ..NewInboxItem::default()
    };
    // 租户写不出带项目字段的行。
    let mut ta = db.tenant(alice).await.unwrap();
    let err = ta
        .insert_inbox(alice, &item(Some(project)))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
    ta.rollback().await.unwrap();
    // worker 写得出；之后谁都改不了。
    let mut w = db.worker().await.unwrap();
    let id = w
        .insert_inbox(alice, &item(Some(project)))
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    let mut w = db.worker().await.unwrap();
    let err = sqlx::query("UPDATE inbox_items SET project_id = NULL WHERE id = $1")
        .bind(id.0)
        .execute(w.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    w.rollback().await.unwrap();
    let mut ta = db.tenant(alice).await.unwrap();
    let err = sqlx::query("UPDATE inbox_items SET subtype = 'report_handled' WHERE id = $1")
        .bind(id.0)
        .execute(ta.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    ta.rollback().await.unwrap();
    // 租户标已读不受影响；读出来带着项目和邀请。
    let mut ta = db.tenant(alice).await.unwrap();
    assert_eq!(ta.mark_inbox_read(Some(&[id]), None).await.unwrap(), 1);
    ta.commit().await.unwrap();
    let mut ta = db.tenant(alice).await.unwrap();
    let got = ta
        .inbox(None, 10, false)
        .await
        .unwrap()
        .into_iter()
        .find(|x| x.id == id)
        .unwrap();
    assert_eq!(got.project_id, Some(project));
    assert!(got.project_invite_id.is_some() && got.read);
    ta.rollback().await.unwrap();
    // 运行删掉：run_id 置空（外键 ON DELETE SET NULL 不触发守卫），项目还在。
    sqlx::query("DELETE FROM runs WHERE id = $1")
        .bind(run.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let (run_id, project_id): (Option<uuid::Uuid>, Option<uuid::Uuid>) =
        sqlx::query_as("SELECT run_id, project_id FROM inbox_items WHERE id = $1")
            .bind(id.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!((run_id, project_id), (None, Some(project.0)));
}
