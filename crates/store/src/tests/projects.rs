//! 项目与跨用户协作（8.14 起）的库测试。需要真实 Postgres，没设置 DATABASE_URL 时跳过。

use proto::domain::{
    Instance, ProjectBudget, ProjectId, ProjectInviteId, ProjectInviteStatus, ProjectRole,
    TeamMember, TeamRole, UserId,
};

use super::{instance, queue_run, user};
use crate::testing::TestDb;
use crate::{Consent, CreatedInvite, Db, Error, InviteCaps, InviteKey, JoinTerms, NewInboxItem};

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

const DAY: std::time::Duration = std::time::Duration::from_secs(7 * 24 * 3600);

/// 设了昵称的用户（邀请人要有昵称）。
async fn named(db: &Db, phone: &str, name: &str) -> UserId {
    let u = user(db, phone).await;
    sqlx::query("UPDATE users SET display_name = $2 WHERE id = $1")
        .bind(u.0)
        .bind(name)
        .execute(db.pool())
        .await
        .unwrap();
    u
}

/// 和编排层一样：加锁前按号码查到收件人，再发邀请。
async fn invite_phone(
    db: &Db,
    inviter: UserId,
    project: ProjectId,
    phone: &str,
    caps: InviteCaps,
) -> crate::Result<CreatedInvite> {
    let mut w = db.worker().await.unwrap();
    let recipient = w.user_by_phone(phone).await.unwrap().map(|u| u.id);
    let r = w
        .create_phone_invite(inviter, project, phone, recipient, caps, DAY)
        .await;
    match &r {
        Ok(_) => w.commit().await.unwrap(),
        Err(_) => w.rollback().await.unwrap(),
    }
    r
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

/// 邀请的一行库里的状态：(status, invitee_id, suppressed_at 有没有)。
async fn invite_state(db: &Db, id: ProjectInviteId) -> (String, Option<uuid::Uuid>, bool) {
    sqlx::query_as(
        "SELECT status, invitee_id, suppressed_at IS NOT NULL FROM project_invites WHERE id = $1",
    )
    .bind(id.0)
    .fetch_one(db.pool())
    .await
    .unwrap()
}

/// 给 `user` 的收件箱放一条这个邀请的提醒（store 测试里没有编排层发通知）。
async fn invite_item(db: &Db, user: UserId, project: ProjectId, invite: ProjectInviteId) {
    let mut w = db.worker().await.unwrap();
    w.insert_inbox(
        user,
        &NewInboxItem {
            kind: "info".into(),
            title: "t".into(),
            body: "b".into(),
            project_id: Some(project),
            project_invite_id: Some(invite),
            ..NewInboxItem::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
}

async fn invite_item_read(db: &Db, user: UserId, invite: ProjectInviteId) -> bool {
    sqlx::query_scalar(
        "SELECT read_at IS NOT NULL FROM inbox_items WHERE user_id = $1 AND project_invite_id = $2",
    )
    .bind(user.0)
    .bind(invite.0)
    .fetch_one(db.pool())
    .await
    .unwrap()
}

/// 按手机号邀请（8.14 测试 1）：号码注册没有、拉黑没有、通知到了上限、已经是成员，邀请人拿到的结果都一样；只有
/// 该通知的人有 `deliver_to`；拉黑的只标不送达；到了上限的照样看得到。
#[tokio::test]
async fn phone_invites_look_the_same_whoever_owns_the_number() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001031", "Alice").await;
    let bob = user(db, "+8613800001032").await;
    let carol = user(db, "+8613800001033").await;
    let dave = user(db, "+8613800001034").await;
    let erin = named(db, "+8613800001035", "Erin").await;
    let frank = user(db, "+8613800001036").await;
    let unregistered = "+8613800001039";
    let a1 = instance(db, alice).await;
    let e1 = instance(db, erin).await;
    let f1 = instance(db, frank).await;
    let project = solo(db, alice, &a1).await;
    let erins = solo(db, erin, &e1).await;
    join_raw(db, project, frank, &[&f1]).await;
    worker_do(db, async |w| w.block_user(carol, alice).await)
        .await
        .unwrap();
    let caps = InviteCaps {
        per_inviter_per_day: 6,
        per_phone_per_day: 1,
    };
    // erin 先给 dave 发了一条（送达了），dave 今天的通知到了上限。
    let first = invite_phone(db, erin, erins, "+8613800001034", caps)
        .await
        .unwrap();
    assert_eq!(first.deliver_to, Some(dave));

    let mut got = vec![];
    for phone in [
        "+8613800001032",
        unregistered,
        "+8613800001033",
        "+8613800001034",
        "+8613800001036",
    ] {
        let c = invite_phone(db, alice, project, phone, caps).await.unwrap();
        assert!(c.created);
        assert_eq!(c.project_name, "p");
        got.push(c);
    }
    let deliver: Vec<_> = got.iter().map(|c| c.deliver_to).collect();
    assert_eq!(deliver, vec![Some(bob), None, None, None, None]);
    // 去掉 id、时间、打码的号码以后一模一样。
    let norm = |c: &CreatedInvite| {
        let mut i = c.invite.clone();
        i.id = ProjectInviteId(uuid::Uuid::nil());
        i.created_at = chrono::DateTime::UNIX_EPOCH;
        i.expires_at = chrono::DateTime::UNIX_EPOCH;
        assert!(i.phone_masked.take().unwrap().contains("****"));
        i
    };
    for c in &got[1..] {
        assert_eq!(norm(c), norm(&got[0]));
    }
    assert_eq!(got[0].invite.status, ProjectInviteStatus::Pending);
    assert_eq!(
        got[0].invite.phone_masked.as_deref(),
        Some("+86138****1032")
    );
    // 库里：只有 carol 那条不送达；dave 那条没送达也没标不送达。
    let mut states = vec![];
    for c in &got {
        states.push(invite_state(db, c.invite.id).await);
    }
    assert_eq!(states[0], ("pending".into(), Some(bob.0), false));
    assert_eq!(states[1], ("pending".into(), None, false));
    assert_eq!(states[2], ("pending".into(), None, true));
    assert_eq!(states[3], ("pending".into(), None, false));
    assert_eq!(states[4], ("pending".into(), None, false));
    // 被邀请的人那边：carol 看不到；dave 看得到（只是没推送）；frank 已经在项目里，看不到。
    let mut w = db.worker().await.unwrap();
    assert!(w.invites_for(carol).await.unwrap().is_empty());
    assert!(w.invites_for(frank).await.unwrap().is_empty());
    let daves = w.invites_for(dave).await.unwrap();
    assert_eq!(daves.len(), 2);
    assert!(daves.iter().any(|p| p.invite_id == got[3].invite.id));
    let bobs = w.invites_for(bob).await.unwrap();
    assert_eq!(bobs.len(), 1);
    let p = &bobs[0];
    assert_eq!((p.project.id, p.creator.user_id), (project, alice));
    assert_eq!(p.creator.display_name.as_deref(), Some("Alice"));
    assert_eq!((p.users, p.agents), (2, 2));
    assert_eq!(p.members.len(), 2);
    assert_eq!(p.members[0].role, ProjectRole::Creator);
    assert_eq!(p.shared_with_project.len(), 5);
    assert_eq!(p.kept_private.len(), 8);
    // 按 id 预览：bob 看得到，别人 NotFound。
    let one = w
        .invite_preview(bob, InviteKey::Phone(got[0].invite.id))
        .await
        .unwrap();
    assert_eq!(one, bobs[0]);
    assert!(matches!(
        w.invite_preview(carol, InviteKey::Phone(got[0].invite.id))
            .await,
        Err(Error::NotFound)
    ));
    w.rollback().await.unwrap();
    // 没注册的号码注册以后看得到。
    let newcomer = user(db, unregistered).await;
    let mut w = db.worker().await.unwrap();
    let theirs = w.invites_for(newcomer).await.unwrap();
    assert_eq!(theirs.len(), 1);
    assert_eq!(theirs[0].invite_id, got[1].invite.id);
    w.rollback().await.unwrap();
    // 再邀请 bob：还是那一条，不再数一次（邀请人到了每天的上限也照样成功）；新号码 429。
    let caps = InviteCaps {
        per_inviter_per_day: 5,
        per_phone_per_day: 1,
    };
    let again = invite_phone(db, alice, project, "+8613800001032", caps)
        .await
        .unwrap();
    assert!(!again.created && again.deliver_to.is_none());
    assert_eq!(again.invite, got[0].invite);
    let err = invite_phone(db, alice, project, "+8613800001037", caps)
        .await
        .unwrap_err();
    assert!(
        matches!(err, Error::RetryAfter(s) if (1..=86_400).contains(&s)),
        "{err:?}"
    );
    // 上限是 0 就不限。
    let c = invite_phone(db, alice, project, "+8613800001037", InviteCaps::default())
        .await
        .unwrap();
    assert!(c.created);
    // 邀请自己、成员邀请、没昵称的创建者：都不行。
    let err = invite_phone(db, alice, project, "+8613800001031", InviteCaps::default())
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    let err = invite_phone(db, frank, project, "+8613800001040", InviteCaps::default())
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    let f2 = instance(db, frank).await;
    let franks = solo(db, frank, &f2).await;
    let err = invite_phone(db, frank, franks, "+8613800001040", InviteCaps::default())
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    // 不是成员的：NotFound。
    let err = invite_phone(db, erin, project, "+8613800001040", InviteCaps::default())
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
}

/// 邀请列表、撤回、链接邀请、上限、过期和清理。
#[tokio::test]
async fn invite_lists_revoke_links_and_sweeps() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001041", "Alice").await;
    let bob = user(db, "+8613800001042").await;
    let carol = user(db, "+8613800001043").await;
    let a1 = instance(db, alice).await;
    let c1 = instance(db, carol).await;
    let project = solo(db, alice, &a1).await;
    join_raw(db, project, carol, &[&c1]).await;
    let caps = InviteCaps::default();
    let to_bob = invite_phone(db, alice, project, "+8613800001042", caps)
        .await
        .unwrap();
    invite_item(db, bob, project, to_bob.invite.id).await;
    // 链接邀请：凭令牌的哈希预览；按 id 找不到。
    let hash = [9u8; 32];
    let link = worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash, caps, DAY).await
    })
    .await
    .unwrap();
    assert_eq!(link.kind, proto::domain::ProjectInviteKind::Link);
    assert!(link.phone_masked.is_none());
    let mut w = db.worker().await.unwrap();
    let p = w.invite_preview(bob, InviteKey::Link(&hash)).await.unwrap();
    assert_eq!((p.invite_id, p.project.id), (link.id, project));
    assert!(matches!(
        w.invite_preview(bob, InviteKey::Phone(link.id)).await,
        Err(Error::NotFound)
    ));
    assert!(matches!(
        w.invite_preview(bob, InviteKey::Link(&[7; 32])).await,
        Err(Error::NotFound)
    ));
    // 列表：只有创建者；成员 NotPermitted；外人 NotFound。
    let list = w.project_invites(alice, project).await.unwrap();
    assert_eq!(
        list.iter().map(|i| i.id).collect::<Vec<_>>(),
        vec![link.id, to_bob.invite.id]
    );
    assert!(matches!(
        w.project_invites(carol, project).await,
        Err(Error::NotPermitted(_))
    ));
    assert!(matches!(
        w.project_invites(bob, project).await,
        Err(Error::NotFound)
    ));
    w.rollback().await.unwrap();
    // 撤回：只有创建者；撤回后 bob 看不到、提醒标已读；再撤一次照样成功（没改）。
    let err = worker_do(db, async |w| {
        w.revoke_invite(carol, project, to_bob.invite.id).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    let other = solo(db, alice, &instance(db, alice).await).await;
    let err = worker_do(db, async |w| {
        w.revoke_invite(alice, other, to_bob.invite.id).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    assert!(
        worker_do(db, async |w| w
            .revoke_invite(alice, project, to_bob.invite.id)
            .await)
        .await
        .unwrap()
    );
    assert!(
        !worker_do(db, async |w| w
            .revoke_invite(alice, project, to_bob.invite.id)
            .await)
        .await
        .unwrap()
    );
    assert!(invite_item_read(db, bob, to_bob.invite.id).await);
    let mut w = db.worker().await.unwrap();
    assert!(w.invites_for(bob).await.unwrap().is_empty());
    w.rollback().await.unwrap();
    // 撤回以后可以再邀请（新的一条）。
    let again = invite_phone(db, alice, project, "+8613800001042", caps)
        .await
        .unwrap();
    assert!(again.created && again.invite.id != to_bob.invite.id);
    invite_item(db, bob, project, again.invite.id).await;

    // 过期：列表里马上按过期算；后台把它标上、提醒标已读；过期的号码再邀请是新的一条。
    sqlx::query(
        "UPDATE project_invites SET expires_at = now() - interval '1 second' WHERE id = $1",
    )
    .bind(again.invite.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    let list = w.project_invites(alice, project).await.unwrap();
    let e = list.iter().find(|i| i.id == again.invite.id).unwrap();
    assert_eq!(e.status, ProjectInviteStatus::Expired);
    assert!(e.settled_at.is_some());
    assert!(w.invites_for(bob).await.unwrap().is_empty());
    w.rollback().await.unwrap();
    assert_eq!(
        worker_do(db, async |w| w.expire_project_invites(100).await)
            .await
            .unwrap(),
        1
    );
    assert_eq!(invite_state(db, again.invite.id).await.0, "expired");
    assert!(invite_item_read(db, bob, again.invite.id).await);
    // 清理：结束 30 天以上的删掉，别的留着。
    sqlx::query("UPDATE project_invites SET settled_at = now() - interval '31 days' WHERE id = $1")
        .bind(to_bob.invite.id.0)
        .execute(db.pool())
        .await
        .unwrap();
    let purged = worker_do(db, async |w| {
        w.purge_project_invites(std::time::Duration::from_secs(30 * 86_400), 100)
            .await
    })
    .await
    .unwrap();
    assert_eq!(purged, 1);
    let left: i64 =
        sqlx::query_scalar("SELECT count(*) FROM project_invites WHERE project_id = $1")
            .bind(project.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(left, 2);

    // 待处理的上限：20 条（链接、号码都算）。
    // 已经有一条链接邀请待处理，再发 19 条就满了。
    for n in 0..19 {
        invite_phone(db, alice, project, &format!("+86138000020{n:02}"), caps)
            .await
            .unwrap();
    }
    let err = invite_phone(db, alice, project, "+8613800002099", caps)
        .await
        .unwrap_err();
    assert!(
        matches!(err, Error::ProjectLimit(crate::ProjectCap::PendingInvites)),
        "{err:?}"
    );
    // 人数上限：10 个人（含创建者）满了就不能再邀请。
    let other = solo(db, alice, &instance(db, alice).await).await;
    for n in 0..9 {
        let u = user(db, &format!("+86138000030{n:02}")).await;
        join_raw(db, other, u, &[]).await;
    }
    let err = invite_phone(db, alice, other, "+8613800003099", caps)
        .await
        .unwrap_err();
    assert!(
        matches!(err, Error::ProjectLimit(crate::ProjectCap::Members)),
        "{err:?}"
    );
}

/// 拉黑（8.14 测试 9）：拒绝并拉黑以后邀请人那边照样“待接受”，被拉黑的人再发来的不送达；取消拉黑不恢复；拉黑和
/// 发邀请同时进行时，不会漏下一条送达的；拒绝并拉黑和拉黑同时进行不死锁。
#[tokio::test]
async fn blocks_hide_invites_silently() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001051", "Alice").await;
    let carol = user(db, "+8613800001053").await;
    let dave = user(db, "+8613800001054").await;
    let a1 = instance(db, alice).await;
    let project = solo(db, alice, &a1).await;
    let caps = InviteCaps::default();
    let first = invite_phone(db, alice, project, "+8613800001053", caps)
        .await
        .unwrap();
    assert_eq!(first.deliver_to, Some(carol));
    invite_item(db, carol, project, first.invite.id).await;
    worker_do(db, async |w| {
        w.decline_invite(carol, first.invite.id, true).await
    })
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    let seen = w.project_invites(alice, project).await.unwrap();
    assert_eq!(
        seen[0].status,
        ProjectInviteStatus::Pending,
        "looks pending"
    );
    assert!(w.invites_for(carol).await.unwrap().is_empty());
    let blocks = w.blocks(carol).await.unwrap();
    assert_eq!(blocks.len(), 1);
    assert_eq!(
        (blocks[0].user_id, blocks[0].display_name.as_deref()),
        (alice, Some("Alice"))
    );
    w.rollback().await.unwrap();
    assert!(invite_item_read(db, carol, first.invite.id).await);
    assert_eq!(
        invite_state(db, first.invite.id).await,
        ("pending".into(), Some(carol.0), true)
    );
    // 拉黑以后的新邀请（另一个项目）：不送达、标不送达。
    let second_project = solo(db, alice, &instance(db, alice).await).await;
    let second = invite_phone(db, alice, second_project, "+8613800001053", caps)
        .await
        .unwrap();
    assert!(second.created && second.deliver_to.is_none());
    assert!(invite_state(db, second.invite.id).await.2);
    // 拒绝已经不送达的：NotFound（看不到）。
    let err = worker_do(db, async |w| {
        w.decline_invite(carol, second.invite.id, false).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    // 取消拉黑：之前标的不恢复；拉黑没有的人 NotFound；拉黑自己 Invalid；取消两次照样成功。
    for _ in 0..2 {
        worker_do(db, async |w| w.unblock_user(carol, alice).await)
            .await
            .unwrap();
    }
    let mut w = db.worker().await.unwrap();
    assert!(w.invites_for(carol).await.unwrap().is_empty());
    assert!(w.blocks(carol).await.unwrap().is_empty());
    w.rollback().await.unwrap();
    let err = worker_do(db, async |w| w.block_user(carol, UserId::new()).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    let err = worker_do(db, async |w| w.block_user(carol, carol).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    // 只拒绝（不拉黑）：标“已拒绝”，提醒标已读。
    let third_project = solo(db, alice, &instance(db, alice).await).await;
    let third = invite_phone(db, alice, third_project, "+8613800001053", caps)
        .await
        .unwrap();
    assert_eq!(third.deliver_to, Some(carol));
    invite_item(db, carol, third_project, third.invite.id).await;
    worker_do(db, async |w| {
        w.decline_invite(carol, third.invite.id, false).await
    })
    .await
    .unwrap();
    assert_eq!(invite_state(db, third.invite.id).await.0, "declined");
    assert!(invite_item_read(db, carol, third.invite.id).await);
    // 别人拒绝不了不是发给他的邀请。
    let fourth = invite_phone(db, alice, third_project, "+8613800001054", caps)
        .await
        .unwrap();
    let err = worker_do(db, async |w| {
        w.decline_invite(carol, fourth.invite.id, false).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");

    // 拉黑和发邀请同时进行：结束后没有 alice 发给 dave 的、送达了的或可见的待处理邀请。
    for round in 0..5 {
        let p = solo(db, alice, &instance(db, alice).await).await;
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, b1) = (db.clone(), barrier.clone());
        let block = tokio::spawn(async move {
            b1.wait().await;
            worker_do(&d1, async |w| w.block_user(dave, alice).await).await
        });
        let (d2, b2) = (db.clone(), barrier.clone());
        let send = tokio::spawn(async move {
            b2.wait().await;
            invite_phone(&d2, alice, p, "+8613800001054", InviteCaps::default()).await
        });
        block.await.unwrap().unwrap();
        send.await.unwrap().unwrap();
        let visible: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM project_invites WHERE inviter_id = $1 AND invitee_phone = $2 \
               AND status = 'pending' AND suppressed_at IS NULL",
        )
        .bind(alice.0)
        .bind("+8613800001054")
        .fetch_one(db.pool())
        .await
        .unwrap();
        assert_eq!(visible, 0, "round {round}");
        worker_do(db, async |w| w.unblock_user(dave, alice).await)
            .await
            .unwrap();
    }

    // 拒绝并拉黑和拉黑同时进行：不死锁（谁先都行，后一个可能 NotFound）。
    for _ in 0..2 {
        let p = solo(db, alice, &instance(db, alice).await).await;
        let inv = invite_phone(db, alice, p, "+8613800001053", caps)
            .await
            .unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, b1) = (db.clone(), barrier.clone());
        let decline = tokio::spawn(async move {
            b1.wait().await;
            worker_do(&d1, async |w| {
                w.decline_invite(carol, inv.invite.id, true).await
            })
            .await
        });
        let (d2, b2) = (db.clone(), barrier.clone());
        let block = tokio::spawn(async move {
            b2.wait().await;
            worker_do(&d2, async |w| w.block_user(carol, alice).await).await
        });
        let r = decline.await.unwrap();
        assert!(matches!(r, Ok(_) | Err(Error::NotFound)), "{r:?}");
        block.await.unwrap().unwrap();
        assert!(invite_state(db, inv.invite.id).await.2);
        worker_do(db, async |w| w.unblock_user(carol, alice).await)
            .await
            .unwrap();
    }
}

fn terms(agents: &[&Instance]) -> JoinTerms {
    JoinTerms {
        agents: agents.iter().map(|a| a.id).collect(),
        daily_token_limit: 1_000_000,
        total_token_limit: 10_000_000,
        consent: Consent {
            version: proto::domain::PROJECT_CONSENT_VERSION,
        },
    }
}

async fn accept(
    db: &Db,
    user: UserId,
    key: InviteKey<'_>,
    terms: &JoinTerms,
) -> crate::Result<crate::Accepted> {
    worker_do(db, async |w| w.accept_invite(user, key, terms).await).await
}

async fn live_member(db: &Db, project: ProjectId, user: UserId) -> bool {
    sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM project_members WHERE project_id = $1 AND user_id = $2 \
           AND left_at IS NULL)",
    )
    .bind(project.0)
    .bind(user.0)
    .fetch_one(db.pool())
    .await
    .unwrap()
}

async fn live_agent_count(db: &Db, project: ProjectId) -> i64 {
    sqlx::query_scalar(
        "SELECT count(*) FROM project_agents a JOIN instances i ON i.id = a.instance_id \
           AND i.state <> 'deleted' WHERE a.project_id = $1 AND a.left_at IS NULL",
    )
    .bind(project.0)
    .fetch_one(db.pool())
    .await
    .unwrap()
}

/// 用原始 SQL 让成员退出（退出流程在后面的提交）。
async fn leave_raw(db: &Db, project: ProjectId, user: UserId) {
    sqlx::query(
        "UPDATE project_agents SET left_at = now(), is_lead = false \
          WHERE project_id = $1 AND user_id = $2 AND left_at IS NULL",
    )
    .bind(project.0)
    .bind(user.0)
    .execute(db.pool())
    .await
    .unwrap();
    sqlx::query(
        "UPDATE project_members SET left_at = now(), left_reason = 'left' \
          WHERE project_id = $1 AND user_id = $2 AND left_at IS NULL",
    )
    .bind(project.0)
    .bind(user.0)
    .execute(db.pool())
    .await
    .unwrap();
}

/// 有 `n` 个 agent 的单人项目（第一个是负责人）。
async fn solo_with(db: &Db, owner: UserId, n: usize) -> (ProjectId, Vec<Instance>) {
    let mut agents = vec![];
    for _ in 0..n {
        agents.push(instance(db, owner).await);
    }
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
    let mut t = db.tenant(owner).await.unwrap();
    let team = t.create_team("big", &members).await.unwrap();
    t.commit().await.unwrap();
    (team.id.into(), agents)
}

/// 链接邀请（8.14 测试 2）：一次有效；同一个人再接受一次不改什么；别人拿同一个令牌 NotFound；不能按 id 当手机号邀请
/// 接受；过期了接受不了，后台标过期、提醒标已读。手机号邀请也能接受，加入后共享、带着确认时间和预算。
#[tokio::test]
async fn link_invites_are_single_use_and_idempotent() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001061", "Alice").await;
    let bob = named(db, "+8613800001062", "Bob").await;
    let carol = user(db, "+8613800001063").await;
    let a1 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let c1 = instance(db, carol).await;
    let project = solo(db, alice, &a1).await;
    let hash = [3u8; 32];
    let link = worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    // 按 id 当手机号邀请：预览、接受都 NotFound。
    let err = accept(db, bob, InviteKey::Phone(link.id), &terms(&[&b1]))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    // 别人的实例、删掉的实例：Invalid（和邀请找不到分开），邀请不作废。
    let err = accept(db, bob, InviteKey::Link(&hash), &terms(&[&c1]))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    assert_eq!(invite_state(db, link.id).await.0, "pending");
    // 确认版本不对、预算不对、agent 为空或重复：Invalid。
    let mut bad = terms(&[&b1]);
    bad.consent.version = 0;
    let mut over = terms(&[&b1]);
    over.daily_token_limit = over.total_token_limit + 1;
    let mut zero = terms(&[&b1]);
    zero.total_token_limit = 0;
    for t in [bad, over, zero, terms(&[]), terms(&[&b1, &b1])] {
        let err = accept(db, bob, InviteKey::Link(&hash), &t)
            .await
            .unwrap_err();
        assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    }
    let got = accept(db, bob, InviteKey::Link(&hash), &terms(&[&b1]))
        .await
        .unwrap();
    assert!(got.created);
    assert_eq!(
        (got.project, got.creator, got.invite),
        (project, alice, link.id)
    );
    assert_eq!(got.member_name.as_deref(), Some("Bob"));
    assert_eq!(got.agents, vec![b1.id]);
    assert!(got.vendors.is_empty());
    assert!(live_member(db, project, bob).await);
    let (consented, daily): (bool, Option<i64>) = sqlx::query_as(
        "SELECT consented_at IS NOT NULL, daily_token_limit FROM project_members \
          WHERE project_id = $1 AND user_id = $2",
    )
    .bind(project.0)
    .bind(bob.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert!(consented && daily == Some(1_000_000));
    let agent_consented: bool = sqlx::query_scalar(
        "SELECT consented_at IS NOT NULL FROM project_agents WHERE project_id = $1 AND instance_id = $2",
    )
    .bind(project.0)
    .bind(b1.id.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert!(agent_consented);
    // 再接受一次：不改，created = false。
    let again = accept(db, bob, InviteKey::Link(&hash), &terms(&[&b1]))
        .await
        .unwrap();
    assert!(!again.created);
    assert_eq!(again.agents, vec![b1.id]);
    // 别人拿同一个令牌：NotFound。
    let err = accept(db, carol, InviteKey::Link(&hash), &terms(&[&c1]))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    let mut w = db.worker().await.unwrap();
    let list = w.project_invites(alice, project).await.unwrap();
    assert_eq!(list[0].status, ProjectInviteStatus::Accepted);
    assert_eq!(list[0].accepted_by.as_ref().unwrap().user_id, bob);
    assert!(w.project_detail(bob, project).await.unwrap().summary.shared);
    w.rollback().await.unwrap();

    // 手机号邀请：过期了接受不了；后台标过期、提醒标已读。
    let to_carol = invite_phone(db, alice, project, "+8613800001063", InviteCaps::default())
        .await
        .unwrap();
    assert_eq!(to_carol.deliver_to, Some(carol));
    invite_item(db, carol, project, to_carol.invite.id).await;
    sqlx::query(
        "UPDATE project_invites SET expires_at = now() - interval '1 second' WHERE id = $1",
    )
    .bind(to_carol.invite.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    let err = accept(
        db,
        carol,
        InviteKey::Phone(to_carol.invite.id),
        &terms(&[&c1]),
    )
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    worker_do(db, async |w| w.expire_project_invites(10).await)
        .await
        .unwrap();
    assert_eq!(invite_state(db, to_carol.invite.id).await.0, "expired");
    assert!(invite_item_read(db, carol, to_carol.invite.id).await);
    // 新的手机号邀请：只有被邀请的号码接受得了；接受后提醒标已读。
    let fresh = invite_phone(db, alice, project, "+8613800001063", InviteCaps::default())
        .await
        .unwrap();
    invite_item(db, carol, project, fresh.invite.id).await;
    let err = accept(db, bob, InviteKey::Phone(fresh.invite.id), &terms(&[&b1]))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    let got = accept(db, carol, InviteKey::Phone(fresh.invite.id), &terms(&[&c1]))
        .await
        .unwrap();
    assert!(got.created);
    assert!(invite_item_read(db, carol, fresh.invite.id).await);
    // 已经是成员：再用别的邀请 Conflict，邀请不作废。
    let hash2 = [4u8; 32];
    let link2 = worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash2, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    let err = accept(db, carol, InviteKey::Link(&hash2), &terms(&[&c1]))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Conflict(_)), "{err:?}");
    assert_eq!(invite_state(db, link2.id).await.0, "pending");
    // 拉黑了邀请人的：手机号邀请接受不了（链接照样能用）。
    let dave = user(db, "+8613800001064").await;
    let d1 = instance(db, dave).await;
    let to_dave = invite_phone(db, alice, project, "+8613800001064", InviteCaps::default())
        .await
        .unwrap();
    sqlx::query("INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1, $2)")
        .bind(dave.0)
        .bind(alice.0)
        .execute(db.pool())
        .await
        .unwrap();
    let err = accept(
        db,
        dave,
        InviteKey::Phone(to_dave.invite.id),
        &terms(&[&d1]),
    )
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    let got = accept(db, dave, InviteKey::Link(&hash2), &terms(&[&d1]))
        .await
        .unwrap();
    assert!(got.created);
}

/// 接受和撤回、和过期同时发生（8.14 测试 3）：每一轮只有一方成；接受了 ⇔ 是成员。
#[tokio::test]
async fn accept_races_revoke_and_expiry() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001071", "Alice").await;
    let bob = user(db, "+8613800001072").await;
    let a1 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let project = solo(db, alice, &a1).await;
    let mut wins = (0, 0);
    for round in 0..20 {
        let inv = invite_phone(db, alice, project, "+8613800001072", InviteCaps::default())
            .await
            .unwrap();
        let id = inv.invite.id;
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, b_1, t1) = (db.clone(), barrier.clone(), terms(&[&b1]));
        let acc = tokio::spawn(async move {
            b_1.wait().await;
            accept(&d1, bob, InviteKey::Phone(id), &t1).await
        });
        let (d2, b_2) = (db.clone(), barrier.clone());
        let rev = tokio::spawn(async move {
            b_2.wait().await;
            worker_do(&d2, async |w| w.revoke_invite(alice, project, id).await).await
        });
        let (a, r) = (acc.await.unwrap(), rev.await.unwrap());
        match (&a, &r) {
            (Ok(x), Err(Error::Conflict(_))) if x.created => wins.0 += 1,
            (Err(Error::NotFound), Ok(true)) => wins.1 += 1,
            other => panic!("round {round}: {other:?}"),
        }
        let state = invite_state(db, id).await.0;
        assert_eq!(state == "accepted", live_member(db, project, bob).await);
        if a.is_ok() {
            leave_raw(db, project, bob).await;
        }
    }
    eprintln!("accept vs revoke: {wins:?}");
    // 和过期：邀请在两边开始后不久到期；最后再扫一次，邀请要么接受了、要么过期了。
    for round in 0..20u64 {
        let inv = invite_phone(db, alice, project, "+8613800001072", InviteCaps::default())
            .await
            .unwrap();
        let id = inv.invite.id;
        sqlx::query(
            "UPDATE project_invites SET expires_at = now() + interval '40 milliseconds' WHERE id = $1",
        )
        .bind(id.0)
        .execute(db.pool())
        .await
        .unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, b_1, t1) = (db.clone(), barrier.clone(), terms(&[&b1]));
        let acc = tokio::spawn(async move {
            b_1.wait().await;
            tokio::time::sleep(std::time::Duration::from_millis(round * 4)).await;
            accept(&d1, bob, InviteKey::Phone(id), &t1).await
        });
        let (d2, b_2) = (db.clone(), barrier.clone());
        let exp = tokio::spawn(async move {
            b_2.wait().await;
            tokio::time::sleep(std::time::Duration::from_millis(45)).await;
            worker_do(&d2, async |w| w.expire_project_invites(100).await).await
        });
        let a = acc.await.unwrap();
        exp.await.unwrap().unwrap();
        worker_do(db, async |w| w.expire_project_invites(100).await)
            .await
            .unwrap();
        let state = invite_state(db, id).await.0;
        match &a {
            Ok(x) => assert!(x.created && state == "accepted", "round {round}"),
            Err(Error::NotFound) => assert_eq!(state, "expired", "round {round}"),
            Err(e) => panic!("round {round}: {e:?}"),
        }
        assert_eq!(state == "accepted", live_member(db, project, bob).await);
        if a.is_ok() {
            leave_raw(db, project, bob).await;
        }
    }
}

/// 两个人同时接受、只剩一个名额（8.14 测试 4）：一个成，另一个 `ProjectLimit(Members)`、邀请还是待接受。
#[tokio::test]
async fn concurrent_accepts_respect_ten_users() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001081", "Alice").await;
    let a1 = instance(db, alice).await;
    let project = solo(db, alice, &a1).await;
    for n in 0..8 {
        let u = user(db, &format!("+86138000040{n:02}")).await;
        join_raw(db, project, u, &[]).await;
    }
    let x = user(db, "+8613800004090").await;
    let y = user(db, "+8613800004091").await;
    let (xi, yi) = (instance(db, x).await, instance(db, y).await);
    let ix = invite_phone(db, alice, project, "+8613800004090", InviteCaps::default())
        .await
        .unwrap()
        .invite
        .id;
    let iy = invite_phone(db, alice, project, "+8613800004091", InviteCaps::default())
        .await
        .unwrap()
        .invite
        .id;
    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
    let (d1, b1, t1) = (db.clone(), barrier.clone(), terms(&[&xi]));
    let first = tokio::spawn(async move {
        b1.wait().await;
        accept(&d1, x, InviteKey::Phone(ix), &t1).await
    });
    let (d2, b2, t2) = (db.clone(), barrier.clone(), terms(&[&yi]));
    let second = tokio::spawn(async move {
        b2.wait().await;
        accept(&d2, y, InviteKey::Phone(iy), &t2).await
    });
    let (rx, ry) = (first.await.unwrap(), second.await.unwrap());
    let (ok, lost) = match (&rx, &ry) {
        (Ok(_), Err(e)) => (ix, (iy, e)),
        (Err(e), Ok(_)) => (iy, (ix, e)),
        other => panic!("{other:?}"),
    };
    assert!(
        matches!(lost.1, Error::ProjectLimit(crate::ProjectCap::Members)),
        "{:?}",
        lost.1
    );
    assert_eq!(invite_state(db, ok).await.0, "accepted");
    assert_eq!(invite_state(db, lost.0).await.0, "pending");
    let n: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM project_members WHERE project_id = $1 AND left_at IS NULL",
    )
    .bind(project.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!(n, 10);
}

/// agent 数上限 30（8.14 测试 5）：加入、加 agent 都在锁里数；已经在项目里的不算新的；实例删了的不算；成员加 agent
/// 要带确认。
#[tokio::test]
async fn thirty_agents_per_project() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001091", "Alice").await;
    let bob = user(db, "+8613800001092").await;
    let (project, alices) = solo_with(db, alice, 28).await;
    let mut bobs = vec![];
    for _ in 0..4 {
        bobs.push(instance(db, bob).await);
    }
    let hash = [5u8; 32];
    worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    let err = accept(
        db,
        bob,
        InviteKey::Link(&hash),
        &terms(&[&bobs[0], &bobs[1], &bobs[2]]),
    )
    .await
    .unwrap_err();
    assert!(
        matches!(err, Error::ProjectLimit(crate::ProjectCap::Agents)),
        "{err:?}"
    );
    accept(
        db,
        bob,
        InviteKey::Link(&hash),
        &terms(&[&bobs[0], &bobs[1]]),
    )
    .await
    .unwrap();
    assert_eq!(live_agent_count(db, project).await, 30);
    let consent = Some(Consent {
        version: proto::domain::PROJECT_CONSENT_VERSION,
    });
    let add = |user: UserId, ids: Vec<proto::domain::InstanceId>, consent: Option<Consent>| async move {
        worker_do(db, async |w| {
            w.add_project_agents(user, project, &ids, consent).await
        })
        .await
    };
    // 满了：加新的不行；重发已经在里面的照样成功（什么也没加）。
    let err = add(bob, vec![bobs[2].id], consent).await.unwrap_err();
    assert!(
        matches!(err, Error::ProjectLimit(crate::ProjectCap::Agents)),
        "{err:?}"
    );
    assert_eq!(add(bob, vec![bobs[0].id], consent).await.unwrap(), vec![]);
    // 成员不带确认、确认版本不对：Invalid；加别人的实例：NotFound。
    let err = add(bob, vec![bobs[2].id], None).await.unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    let err = add(bob, vec![bobs[2].id], Some(Consent { version: 99 }))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    let err = add(bob, vec![alices[1].id], consent).await.unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    // 实例删了的不算：删掉一个就又能加一个。
    sqlx::query("UPDATE instances SET state = 'deleted', deleted_at = now() WHERE id = $1")
        .bind(alices[27].id.0)
        .execute(db.pool())
        .await
        .unwrap();
    assert_eq!(
        add(bob, vec![bobs[2].id], consent).await.unwrap(),
        vec![bobs[2].id]
    );
    // 29 个时同时加两个：只有一个成。
    sqlx::query(
        "UPDATE project_agents SET left_at = now() WHERE project_id = $1 AND instance_id = $2",
    )
    .bind(project.0)
    .bind(bobs[2].id.0)
    .execute(db.pool())
    .await
    .unwrap();
    assert_eq!(live_agent_count(db, project).await, 29);
    let a_new = instance(db, alice).await;
    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
    let (d1, b1, i1) = (db.clone(), barrier.clone(), bobs[3].id);
    let one = tokio::spawn(async move {
        b1.wait().await;
        worker_do(&d1, async |w| {
            w.add_project_agents(bob, project, &[i1], consent).await
        })
        .await
    });
    let (d2, b2, i2) = (db.clone(), barrier.clone(), a_new.id);
    let two = tokio::spawn(async move {
        b2.wait().await;
        // 创建者不用确认。
        worker_do(&d2, async |w| {
            w.add_project_agents(alice, project, &[i2], None).await
        })
        .await
    });
    let (r1, r2) = (one.await.unwrap(), two.await.unwrap());
    assert_eq!(
        [&r1, &r2].iter().filter(|r| r.is_ok()).count(),
        1,
        "{r1:?} {r2:?}"
    );
    let lost = if r1.is_ok() { &r2 } else { &r1 };
    assert!(
        matches!(lost, Err(Error::ProjectLimit(crate::ProjectCap::Agents))),
        "{lost:?}"
    );
    assert_eq!(live_agent_count(db, project).await, 30);
    // 创建者加的 agent 没有确认时间，成员加的有。
    if r2.is_ok() {
        let c: bool = sqlx::query_scalar(
            "SELECT consented_at IS NULL FROM project_agents WHERE project_id = $1 AND instance_id = $2",
        )
        .bind(project.0)
        .bind(a_new.id.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
        assert!(c);
    }
}

/// 租户改团队和加入同时进行（8.14 测试 12）：都在项目锁里，agent 数不超过 30；团队先改完，或者回 409（项目已经共享）。
#[tokio::test]
async fn team_edits_and_joins_serialize() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001101", "Alice").await;
    let bob = user(db, "+8613800001102").await;
    let b1 = instance(db, bob).await;
    for round in 0..4 {
        let (project, alices) = solo_with(db, alice, 29).await;
        let extra = instance(db, alice).await;
        let hash = [10 + round as u8; 32];
        worker_do(db, async |w| {
            w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
                .await
        })
        .await
        .unwrap();
        let mut members: Vec<TeamMember> = alices
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
        members.push(TeamMember {
            instance_id: extra.id,
            role: TeamRole::Member,
            position: 29,
        });
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, bar1) = (db.clone(), barrier.clone());
        let edit = tokio::spawn(async move {
            bar1.wait().await;
            let mut ta = d1.tenant(alice).await.unwrap();
            let r = ta.update_team(project.into(), None, Some(&members)).await;
            match r {
                Ok(_) => ta.commit().await.map(|_| ()),
                Err(e) => {
                    ta.rollback().await.unwrap();
                    Err(e)
                }
            }
        });
        let (d2, bar2, t2) = (db.clone(), barrier.clone(), terms(&[&b1]));
        let join = tokio::spawn(async move {
            bar2.wait().await;
            accept(&d2, bob, InviteKey::Link(&hash), &t2).await
        });
        let (e, j) = (edit.await.unwrap(), join.await.unwrap());
        match (&e, &j) {
            // 团队先改完：30 个了，加入回上限。
            (Ok(()), Err(Error::ProjectLimit(crate::ProjectCap::Agents))) => {}
            // 先加入了：项目共享了，团队改不了。
            (Err(Error::Conflict(_)), Ok(_)) => {}
            other => panic!("round {round}: {other:?}"),
        }
        assert!(live_agent_count(db, project).await <= 30);
    }
}

/// 退出、移出、撤回、再加入（8.14 测试 6）。
#[tokio::test]
async fn withdraw_leave_remove_and_rejoin() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001111", "Alice").await;
    let bob = named(db, "+8613800001112", "Bob").await;
    let carol = user(db, "+8613800001113").await;
    let a1 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let b2 = instance(db, bob).await;
    let project = solo(db, alice, &a1).await;
    let hash = [21u8; 32];
    worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    accept(db, bob, InviteKey::Link(&hash), &terms(&[&b1, &b2]))
        .await
        .unwrap();
    let withdraw = |user: UserId, i: proto::domain::InstanceId| async move {
        worker_do(db, async |w| {
            w.withdraw_project_agent(user, project, i).await
        })
        .await
    };
    // 主人撤自己的；再撤一次 already_left。
    let w1 = withdraw(bob, b1.id).await.unwrap();
    assert!(!w1.already_left);
    assert_eq!((w1.owner, w1.creator), (bob, alice));
    assert_eq!(w1.owner_name.as_deref(), Some("Bob"));
    assert_eq!(w1.name, "main");
    assert!(withdraw(bob, b1.id).await.unwrap().already_left);
    // 创建者撤成员的；外人 NotFound；成员撤创建者的 NotPermitted。
    let err = withdraw(carol, b2.id).await.unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    let err = withdraw(bob, a1.id).await.unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    assert!(!withdraw(alice, b2.id).await.unwrap().already_left);
    assert_eq!(live_agent_count(db, project).await, 1);
    // 成员移不了人；创建者退不了。
    let err = worker_do(db, async |w| {
        w.remove_project_member(bob, project, alice).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    let err = worker_do(db, async |w| w.leave_project(alice, project).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::Conflict(_)), "{err:?}");
    // 移出创建者 Invalid；移出从没加入过的人 NotFound。
    let err = worker_do(db, async |w| {
        w.remove_project_member(alice, project, alice).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    let err = worker_do(db, async |w| {
        w.remove_project_member(alice, project, carol).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    // bob 退出：看不到了；再退一次 NotFound。
    let exit = worker_do(db, async |w| w.leave_project(bob, project).await)
        .await
        .unwrap();
    assert!(exit.changed);
    assert_eq!((exit.creator, exit.member), (alice, bob));
    assert_eq!(exit.member_name.as_deref(), Some("Bob"));
    let reason: Option<String> = sqlx::query_scalar(
        "SELECT left_reason FROM project_members WHERE project_id = $1 AND user_id = $2",
    )
    .bind(project.0)
    .bind(bob.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!(reason.as_deref(), Some("left"));
    let mut w = db.worker().await.unwrap();
    assert!(matches!(
        w.project_detail(bob, project).await,
        Err(Error::NotFound)
    ));
    assert!(w.my_projects(bob).await.unwrap().is_empty());
    w.rollback().await.unwrap();
    let err = worker_do(db, async |w| w.leave_project(bob, project).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    // 新的邀请让他回来：同一行成员和 agent 原地恢复，加入时间往后挪。
    let joined_before: chrono::DateTime<chrono::Utc> = sqlx::query_scalar(
        "SELECT joined_at FROM project_members WHERE project_id = $1 AND user_id = $2",
    )
    .bind(project.0)
    .bind(bob.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    let hash2 = [22u8; 32];
    worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash2, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    accept(db, bob, InviteKey::Link(&hash2), &terms(&[&b1]))
        .await
        .unwrap();
    let (rows, joined): (i64, chrono::DateTime<chrono::Utc>) = sqlx::query_as(
        "SELECT (SELECT count(*) FROM project_agents WHERE project_id = $1 AND user_id = $2), \
                (SELECT joined_at FROM project_members WHERE project_id = $1 AND user_id = $2)",
    )
    .bind(project.0)
    .bind(bob.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!(rows, 2, "rows are reused, not duplicated");
    assert!(joined > joined_before);
    assert_eq!(live_agent_count(db, project).await, 2);
    // 移出：标 removed；再移一次照样成功（不改）；项目还是共享的。
    let exit = worker_do(db, async |w| {
        w.remove_project_member(alice, project, bob).await
    })
    .await
    .unwrap();
    assert!(exit.changed);
    let again = worker_do(db, async |w| {
        w.remove_project_member(alice, project, bob).await
    })
    .await
    .unwrap();
    assert!(!again.changed);
    let (reason, shared): (Option<String>, bool) = sqlx::query_as(
        "SELECT m.left_reason, p.shared_at IS NOT NULL FROM project_members m \
           JOIN projects p ON p.id = m.project_id WHERE m.project_id = $1 AND m.user_id = $2",
    )
    .bind(project.0)
    .bind(bob.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert_eq!((reason.as_deref(), shared), (Some("removed"), true));
    assert_eq!(live_agent_count(db, project).await, 1);
    // 预算：成员两个都要；创建者可以不限。
    let budget = |d: Option<u64>, t: Option<u64>| ProjectBudget {
        daily_token_limit: d,
        total_token_limit: t,
    };
    worker_do(db, async |w| {
        w.set_project_budget(alice, project, &budget(None, Some(5)))
            .await
    })
    .await
    .unwrap();
    let hash3 = [23u8; 32];
    worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash3, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    accept(db, bob, InviteKey::Link(&hash3), &terms(&[&b1]))
        .await
        .unwrap();
    let err = worker_do(db, async |w| {
        w.set_project_budget(bob, project, &budget(Some(5), None))
            .await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    let err = worker_do(db, async |w| {
        w.set_project_budget(bob, project, &budget(Some(6), Some(5)))
            .await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err:?}");
    worker_do(db, async |w| {
        w.set_project_budget(bob, project, &budget(Some(5), Some(6)))
            .await
    })
    .await
    .unwrap();
    let mut w = db.worker().await.unwrap();
    let d = w.project_detail(bob, project).await.unwrap();
    assert_eq!(d.my_budget, budget(Some(5), Some(6)));
    let d = w.project_detail(alice, project).await.unwrap();
    assert_eq!(d.my_budget, budget(None, Some(5)));
    w.rollback().await.unwrap();
}

/// 把 `from` 这一行复制成项目 `project` 的（列表现查）；`parent` 给授权设父授权。
async fn copy_into_project(
    db: &Db,
    table: &str,
    from: uuid::Uuid,
    project: ProjectId,
    parent: Option<uuid::Uuid>,
) -> uuid::Uuid {
    let cols: Vec<String> = sqlx::query_scalar(
        "SELECT column_name::text FROM information_schema.columns WHERE table_name = $1 \
           AND column_name NOT IN ('id', 'project_id', 'space_kind', 'space_id') \
         ORDER BY ordinal_position",
    )
    .bind(table)
    .fetch_all(db.pool())
    .await
    .unwrap();
    let list = cols.join(", ");
    let id = uuid::Uuid::now_v7();
    let mut w = db.worker().await.unwrap();
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "INSERT INTO {table} (id, project_id, {list}) SELECT $1, $2, {list} FROM {table} WHERE id = $3"
    )))
    .bind(id)
    .bind(project.0)
    .bind(from)
    .execute(w.conn())
    .await
    .unwrap();
    if let Some(p) = parent {
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "UPDATE {table} SET parent_id = $2 WHERE id = $1"
        )))
        .bind(id)
        .bind(p)
        .execute(w.conn())
        .await
        .unwrap();
    }
    if table == "runs" {
        sqlx::query(
            "UPDATE runs SET state = 'running', lease_owner = 'w-test', \
               lease_expires_at = now() + interval '1 hour' WHERE id = $1",
        )
        .bind(id)
        .execute(w.conn())
        .await
        .unwrap();
    }
    w.commit().await.unwrap();
    id
}

async fn epoch(db: &Db, i: &Instance) -> i64 {
    sqlx::query_scalar("SELECT token_epoch FROM instances WHERE id = $1")
        .bind(i.id.0)
        .fetch_one(db.pool())
        .await
        .unwrap()
}

async fn run_state(db: &Db, id: uuid::Uuid) -> String {
    sqlx::query_scalar("SELECT state FROM runs WHERE id = $1")
        .bind(id)
        .fetch_one(db.pool())
        .await
        .unwrap()
}

async fn grant_revoked(db: &Db, id: uuid::Uuid) -> bool {
    sqlx::query_scalar("SELECT revoked_at IS NOT NULL FROM run_grants WHERE id = $1")
        .bind(id)
        .fetch_one(db.pool())
        .await
        .unwrap()
}

/// 撤回、退出停掉项目里的运行和授权（8.14 测试 7）：令牌代数加一；同一个实例上的私人运行、授权不动。
#[tokio::test]
async fn exits_stop_project_runs_and_grants() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001121", "Alice").await;
    let bob = user(db, "+8613800001122").await;
    let a1 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let b2 = instance(db, bob).await;
    let project = solo(db, alice, &a1).await;
    let hash = [31u8; 32];
    worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    accept(db, bob, InviteKey::Link(&hash), &terms(&[&b1, &b2]))
        .await
        .unwrap();
    // 每个实例：一个私人运行（排队）、一个私人授权；复制出一个跑着的项目运行、一个项目授权和它的子授权。
    let mut seeded = vec![];
    for i in [&b1, &b2] {
        let private_run = queue_run(db, bob, i, "private").await.id.0;
        let mut tb = db.tenant(bob).await.unwrap();
        let private_grant = tb
            .create_run_grant(
                i.id,
                None,
                &proto::domain::GrantScope::default(),
                std::time::Duration::from_secs(3600),
            )
            .await
            .unwrap()
            .id
            .0;
        tb.commit().await.unwrap();
        let run = copy_into_project(db, "runs", private_run, project, None).await;
        let grant = copy_into_project(db, "run_grants", private_grant, project, None).await;
        let child = copy_into_project(db, "run_grants", private_grant, project, Some(grant)).await;
        seeded.push((private_run, private_grant, run, grant, child));
    }
    let check = async |i: &Instance,
                       s: &(uuid::Uuid, uuid::Uuid, uuid::Uuid, uuid::Uuid, uuid::Uuid),
                       before: i64| {
        let (private_run, private_grant, run, grant, child) = *s;
        assert_eq!(run_state(db, run).await, "cancelled");
        assert_eq!(epoch(db, i).await, before + 1);
        assert!(grant_revoked(db, grant).await && grant_revoked(db, child).await);
        assert_eq!(run_state(db, private_run).await, "queued");
        assert!(!grant_revoked(db, private_grant).await);
    };
    let before = epoch(db, &b1).await;
    let w = worker_do(db, async |w| {
        w.withdraw_project_agent(bob, project, b1.id).await
    })
    .await
    .unwrap();
    assert_eq!((w.runs_cancelled, w.grants_revoked), (1, 2));
    check(&b1, &seeded[0], before).await;
    // b2 的还在跑。
    assert_eq!(run_state(db, seeded[1].2).await, "running");
    let before = epoch(db, &b2).await;
    let exit = worker_do(db, async |w| w.leave_project(bob, project).await)
        .await
        .unwrap();
    assert_eq!((exit.runs_cancelled, exit.grants_revoked), (1, 2));
    check(&b2, &seeded[1], before).await;
}

/// 注销和项目流程同时进行不死锁（8.14 测试 10b）。
#[tokio::test]
async fn erase_and_project_flows_do_not_deadlock() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let no_deadlock = |r: &crate::Result<()>| {
        if let Err(Error::Db(e)) = r {
            panic!("database error (deadlock?): {e}");
        }
    };
    for round in 0..3u32 {
        let alice = named(db, &format!("+861380000{round}201"), "Alice").await;
        let bob = named(db, &format!("+861380000{round}202"), "Bob").await;
        let a1 = instance(db, alice).await;
        let b1 = instance(db, bob).await;
        let project = solo(db, alice, &a1).await;
        let hash = [40 + round as u8; 32];
        worker_do(db, async |w| {
            w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
                .await
        })
        .await
        .unwrap();
        // 注销 bob 的同时 bob 接受邀请。
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, br1) = (db.clone(), barrier.clone());
        let erase = tokio::spawn(async move {
            br1.wait().await;
            worker_do(&d1, async |w| w.erase_account(bob).await).await
        });
        let (d2, br2, t2) = (db.clone(), barrier.clone(), terms(&[&b1]));
        let join = tokio::spawn(async move {
            br2.wait().await;
            accept(&d2, bob, InviteKey::Link(&hash), &t2)
                .await
                .map(|_| ())
        });
        let (e, j) = (erase.await.unwrap(), join.await.unwrap());
        no_deadlock(&e);
        no_deadlock(&j);
        e.unwrap();
        assert!(!live_member(db, project, bob).await, "round {round}");

        // 注销 alice 的同时 carol 退出 alice 的项目。
        let carol = named(db, &format!("+861380000{round}203"), "Carol").await;
        let c1 = instance(db, carol).await;
        let hash = [50 + round as u8; 32];
        worker_do(db, async |w| {
            w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
                .await
        })
        .await
        .unwrap();
        accept(db, carol, InviteKey::Link(&hash), &terms(&[&c1]))
            .await
            .unwrap();
        // alice 的另一个单人项目：注销时她自己的租户事务正在改它。
        let (solo_project, alices) = solo_with(db, alice, 2).await;
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(3));
        let (d1, br1) = (db.clone(), barrier.clone());
        let erase = tokio::spawn(async move {
            br1.wait().await;
            worker_do(&d1, async |w| w.erase_account(alice).await).await
        });
        let (d2, br2) = (db.clone(), barrier.clone());
        let leave = tokio::spawn(async move {
            br2.wait().await;
            worker_do(&d2, async |w| {
                w.leave_project(carol, project).await.map(|_| ())
            })
            .await
        });
        let (d3, br3, keep) = (db.clone(), barrier.clone(), alices[1].id);
        let edit = tokio::spawn(async move {
            br3.wait().await;
            let mut ta = d3.tenant(alice).await?;
            let r = ta
                .update_team(
                    solo_project.into(),
                    Some("renamed"),
                    Some(&[TeamMember {
                        instance_id: keep,
                        role: TeamRole::Lead,
                        position: 0,
                    }]),
                )
                .await;
            match r {
                Ok(_) => ta.commit().await,
                Err(e) => {
                    ta.rollback().await.ok();
                    Err(e)
                }
            }
        });
        let (e, l, u) = (
            erase.await.unwrap(),
            leave.await.unwrap(),
            edit.await.unwrap(),
        );
        no_deadlock(&e);
        no_deadlock(&l);
        no_deadlock(&u);
        e.unwrap();
        let left: i64 = sqlx::query_scalar("SELECT count(*) FROM projects WHERE creator_id = $1")
            .bind(alice.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(left, 0, "round {round}: alice's projects are gone");
    }
}

/// 删了的实例离开共享项目（8.14 测试 11）：删完调 `retire_deleted_instance`；没调的由后台兜底；项目锁被占着时后台跳过。
#[tokio::test]
async fn deleted_instances_leave_shared_projects() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001131", "Alice").await;
    let bob = user(db, "+8613800001132").await;
    let a1 = instance(db, alice).await;
    let a2 = instance(db, alice).await;
    let a3 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let project = solo(db, alice, &a1).await;
    worker_do(db, async |w| {
        w.add_project_agents(alice, project, &[a2.id, a3.id], None)
            .await
    })
    .await
    .unwrap();
    let hash = [61u8; 32];
    worker_do(db, async |w| {
        w.create_link_invite(alice, project, &hash, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    accept(db, bob, InviteKey::Link(&hash), &terms(&[&b1]))
        .await
        .unwrap();
    let left = async |i: &Instance| -> bool {
        sqlx::query_scalar(
            "SELECT left_at IS NOT NULL FROM project_agents WHERE project_id = $1 AND instance_id = $2",
        )
        .bind(project.0)
        .bind(i.id.0)
        .fetch_one(db.pool())
        .await
        .unwrap()
    };
    // 删 a2，接着撤下：标离开。没删的实例调了也不变。
    super::delete_instance_like_the_api(db.clone(), alice, a2.id)
        .await
        .unwrap();
    assert!(!left(&a2).await, "the tenant cannot touch a shared project");
    assert_eq!(
        worker_do(db, async |w| w.retire_deleted_instance(alice, a2.id).await)
            .await
            .unwrap(),
        1
    );
    assert!(left(&a2).await);
    assert_eq!(
        worker_do(db, async |w| w.retire_deleted_instance(alice, a3.id).await)
            .await
            .unwrap(),
        0
    );
    // 删 a3 不撤：后台兜底；项目锁被占着时跳过，放开后撤下。
    super::delete_instance_like_the_api(db.clone(), alice, a3.id)
        .await
        .unwrap();
    let mut holder = db.worker().await.unwrap();
    holder.lock_project(project).await.unwrap();
    assert_eq!(
        worker_do(db, async |w| w.retire_deleted_project_agents(100).await)
            .await
            .unwrap(),
        0
    );
    holder.rollback().await.unwrap();
    assert!(!left(&a3).await);
    assert_eq!(
        worker_do(db, async |w| w.retire_deleted_project_agents(100).await)
            .await
            .unwrap(),
        1
    );
    assert!(left(&a3).await);
    let mut w = db.worker().await.unwrap();
    let d = w.project_detail(bob, project).await.unwrap();
    assert_eq!(
        d.agents.iter().map(|a| a.instance_id).collect::<Vec<_>>(),
        vec![a1.id, b1.id]
    );
    w.rollback().await.unwrap();
}

/// 评审修复（8.14）：删掉没人加入过的单人项目，邀请跟着删了，但每天的上限照样算（发送记录不跟着项目删）；删之前撤回
/// 还没处理的邀请，对方的提醒标已读；成员调删除 NotPermitted，共享过的 Conflict。
#[tokio::test]
async fn deleting_a_solo_project_keeps_invite_caps() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001141", "Alice").await;
    let bob = user(db, "+8613800001142").await;
    let carol = user(db, "+8613800001143").await;
    let a1 = instance(db, alice).await;
    let c1 = instance(db, carol).await;
    let caps = InviteCaps {
        per_inviter_per_day: 2,
        per_phone_per_day: 1,
    };
    let p = solo(db, alice, &a1).await;
    let first = invite_phone(db, alice, p, "+8613800001142", caps)
        .await
        .unwrap();
    assert_eq!(first.deliver_to, Some(bob));
    invite_item(db, bob, p, first.invite.id).await;
    assert_eq!(
        worker_do(db, async |w| w.release_solo_project_invites(alice, p).await)
            .await
            .unwrap(),
        1
    );
    assert!(invite_item_read(db, bob, first.invite.id).await);
    let mut ta = db.tenant(alice).await.unwrap();
    ta.delete_solo_project(p).await.unwrap();
    ta.commit().await.unwrap();
    let gone: i64 =
        sqlx::query_scalar("SELECT count(*) FROM project_invites WHERE project_id = $1")
            .bind(p.0)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(gone, 0);
    // 新项目：发给 bob 的号码今天已经通知过一次了（上限 1），这次不通知；alice 今天第二个邀请，再发就 429。
    let p2 = solo(db, alice, &instance(db, alice).await).await;
    let second = invite_phone(db, alice, p2, "+8613800001142", caps)
        .await
        .unwrap();
    assert!(second.created && second.deliver_to.is_none());
    let err = invite_phone(db, alice, p2, "+8613800001144", caps)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::RetryAfter(_)), "{err:?}");
    // 成员删不了（NotPermitted），外人 NotFound，共享过的 Conflict。
    let hash = [71u8; 32];
    worker_do(db, async |w| {
        w.create_link_invite(alice, p2, &hash, InviteCaps::default(), DAY)
            .await
    })
    .await
    .unwrap();
    accept(db, carol, InviteKey::Link(&hash), &terms(&[&c1]))
        .await
        .unwrap();
    let err = worker_do(db, async |w| {
        w.release_solo_project_invites(carol, p2).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::NotPermitted(_)), "{err:?}");
    let err = worker_do(db, async |w| w.release_solo_project_invites(bob, p2).await)
        .await
        .unwrap_err();
    assert!(matches!(err, Error::NotFound), "{err:?}");
    let err = worker_do(db, async |w| {
        w.release_solo_project_invites(alice, p2).await
    })
    .await
    .unwrap_err();
    assert!(matches!(err, Error::Conflict(_)), "{err:?}");
    // 后台删掉两天前的发送记录。
    sqlx::query("UPDATE project_invite_sends SET created_at = now() - interval '3 days'")
        .execute(db.pool())
        .await
        .unwrap();
    worker_do(db, async |w| {
        w.purge_project_invites(std::time::Duration::from_secs(30 * 86_400), 100)
            .await
    })
    .await
    .unwrap();
    let left: i64 = sqlx::query_scalar("SELECT count(*) FROM project_invite_sends")
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(left, 0);
    // 租户碰不到发送记录。
    let mut tb = db.tenant(bob).await.unwrap();
    let err = sqlx::query("SELECT count(*) FROM project_invite_sends")
        .execute(tb.conn())
        .await
        .map_err(Error::from)
        .unwrap_err();
    assert!(matches!(err, Error::Forbidden(_)), "{err:?}");
}

/// 评审修复（8.14）：成员还在的时候发给他号码的邀请，在他被移出、退出时撤回，他不能拿着旧邀请自己回来；号码的旧邀请过期
/// 以后再邀请，旧的提醒标已读；撤回一个已经过期（后台还没标）的邀请什么也不改。
#[tokio::test]
async fn stale_invites_do_not_outlive_their_purpose() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = named(db, "+8613800001151", "Alice").await;
    let bob = user(db, "+8613800001152").await;
    let carol = user(db, "+8613800001153").await;
    let a1 = instance(db, alice).await;
    let b1 = instance(db, bob).await;
    let c1 = instance(db, carol).await;
    let p = solo(db, alice, &a1).await;
    for (who, inst, phone, n) in [
        (bob, &b1, "+8613800001152", 81u8),
        (carol, &c1, "+8613800001153", 82u8),
    ] {
        let hash = [n; 32];
        worker_do(db, async |w| {
            w.create_link_invite(alice, p, &hash, InviteCaps::default(), DAY)
                .await
        })
        .await
        .unwrap();
        accept(db, who, InviteKey::Link(&hash), &terms(&[inst]))
            .await
            .unwrap();
        // 已经是成员，照样给他的号码发一个（邀请人看不出来）。
        invite_phone(db, alice, p, phone, InviteCaps::default())
            .await
            .unwrap();
    }
    let stale = |phone: &'static str| async move {
        let id: uuid::Uuid = sqlx::query_scalar(
            "SELECT id FROM project_invites WHERE invitee_phone = $1 ORDER BY created_at DESC LIMIT 1",
        )
        .bind(phone)
        .fetch_one(db.pool())
        .await
        .unwrap();
        ProjectInviteId(id)
    };
    let to_bob = stale("+8613800001152").await;
    let to_carol = stale("+8613800001153").await;
    worker_do(db, async |w| w.remove_project_member(alice, p, bob).await)
        .await
        .unwrap();
    worker_do(db, async |w| w.leave_project(carol, p).await)
        .await
        .unwrap();
    for (who, inst, id) in [(bob, &b1, to_bob), (carol, &c1, to_carol)] {
        assert_eq!(invite_state(db, id).await.0, "revoked");
        let mut w = db.worker().await.unwrap();
        assert!(w.invites_for(who).await.unwrap().is_empty());
        w.rollback().await.unwrap();
        let err = accept(db, who, InviteKey::Phone(id), &terms(&[inst]))
            .await
            .unwrap_err();
        assert!(matches!(err, Error::NotFound), "{err:?}");
        assert!(!live_member(db, p, who).await);
    }
    // 过期以后再邀请：旧的提醒标已读。
    let dave = user(db, "+8613800001154").await;
    let old = invite_phone(db, alice, p, "+8613800001154", InviteCaps::default())
        .await
        .unwrap();
    assert_eq!(old.deliver_to, Some(dave));
    invite_item(db, dave, p, old.invite.id).await;
    sqlx::query(
        "UPDATE project_invites SET expires_at = now() - interval '1 second' WHERE id = $1",
    )
    .bind(old.invite.id.0)
    .execute(db.pool())
    .await
    .unwrap();
    // 撤回已经过期的：不改（返回 false），留给后台标过期。
    assert!(
        !worker_do(db, async |w| w.revoke_invite(alice, p, old.invite.id).await)
            .await
            .unwrap()
    );
    assert_eq!(invite_state(db, old.invite.id).await.0, "pending");
    let new = invite_phone(db, alice, p, "+8613800001154", InviteCaps::default())
        .await
        .unwrap();
    assert!(new.created && new.invite.id != old.invite.id);
    assert_eq!(invite_state(db, old.invite.id).await.0, "expired");
    assert!(invite_item_read(db, dave, old.invite.id).await);
}

/// 评审修复（8.14）：两个人同时注销（一个是项目的创建者，另一个加入过又退出、还有一个发给他的邀请）不死锁；往单人项目里
/// 加 agent 和删这个实例同时进行不死锁。
#[tokio::test]
async fn erasures_and_instance_deletes_do_not_deadlock() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let no_deadlock = |r: &crate::Result<()>| {
        if let Err(Error::Db(e)) = r {
            panic!("database error (deadlock?): {e}");
        }
    };
    for round in 0..3u32 {
        let alice = named(db, &format!("+861380000{round}301"), "Alice").await;
        let erin = user(db, &format!("+861380000{round}302")).await;
        let a1 = instance(db, alice).await;
        let e1 = instance(db, erin).await;
        let q = solo(db, alice, &a1).await;
        let hash = [90 + round as u8; 32];
        worker_do(db, async |w| {
            w.create_link_invite(alice, q, &hash, InviteCaps::default(), DAY)
                .await
        })
        .await
        .unwrap();
        accept(db, erin, InviteKey::Link(&hash), &terms(&[&e1]))
            .await
            .unwrap();
        worker_do(db, async |w| w.leave_project(erin, q).await)
            .await
            .unwrap();
        invite_phone(
            db,
            alice,
            q,
            &format!("+861380000{round}302"),
            InviteCaps::default(),
        )
        .await
        .unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, b1) = (db.clone(), barrier.clone());
        let one = tokio::spawn(async move {
            b1.wait().await;
            worker_do(&d1, async |w| w.erase_account(alice).await).await
        });
        let (d2, b2) = (db.clone(), barrier.clone());
        let two = tokio::spawn(async move {
            b2.wait().await;
            worker_do(&d2, async |w| w.erase_account(erin).await).await
        });
        let (r1, r2) = (one.await.unwrap(), two.await.unwrap());
        no_deadlock(&r1);
        no_deadlock(&r2);
        r1.unwrap();
        r2.unwrap();

        // 加 agent（重发已经在里面的那个）和删它同时进行。
        let frank = named(db, &format!("+861380000{round}303"), "Frank").await;
        let (s, fs) = solo_with(db, frank, 2).await;
        let extra = instance(db, frank).await;
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let (d1, b1, ids) = (db.clone(), barrier.clone(), vec![fs[1].id, extra.id]);
        let add = tokio::spawn(async move {
            b1.wait().await;
            worker_do(&d1, async |w| {
                w.add_project_agents(frank, s, &ids, None).await
            })
            .await
            .map(|_| ())
        });
        let (d2, b2, gone) = (db.clone(), barrier.clone(), fs[1].id);
        let del = tokio::spawn(async move {
            b2.wait().await;
            super::delete_instance_like_the_api(d2, frank, gone)
                .await
                .map(|_| ())
        });
        let (ra, rd) = (add.await.unwrap(), del.await.unwrap());
        no_deadlock(&ra);
        no_deadlock(&rd);
        rd.unwrap();
        assert!(matches!(ra, Ok(()) | Err(Error::Invalid(_))), "{ra:?}");
    }
}
