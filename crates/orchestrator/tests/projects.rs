//! 跨用户项目的回执和审计（8.14）。需要 DATABASE_URL（没有时跳过）。

use orchestrator::projects;
use proto::domain::{
    Instance, InstanceLimits, PROJECT_CONSENT_VERSION, ProjectId, TeamMember, TeamRole, UserId,
    notice_subtype,
};
use store::testing::TestDb;
use store::{Consent, Db, InviteCaps, InviteKey, JoinTerms, NewInstance};

const ACTOR: &str = "user:test-device";

async fn user(db: &Db, phone: &str, name: Option<&str>) -> UserId {
    let mut w = db.worker().await.unwrap();
    let (u, _) = w.upsert_user_by_phone(phone).await.unwrap();
    w.commit().await.unwrap();
    if let Some(name) = name {
        sqlx::query("UPDATE users SET display_name = $2 WHERE id = $1")
            .bind(u.id.0)
            .bind(name)
            .execute(db.pool())
            .await
            .unwrap();
    }
    u.id
}

async fn instance(db: &Db, user: UserId, name: &str) -> Instance {
    let mut t = db.tenant(user).await.unwrap();
    let i = t
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: name.into(),
            workspace_id: "vol-1".into(),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    t.commit().await.unwrap();
    i
}

async fn project(db: &Db, owner: UserId, lead: &Instance, name: &str) -> ProjectId {
    let mut t = db.tenant(owner).await.unwrap();
    let team = t
        .create_team(
            name,
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

/// (subtype, title, body, project_id, project_invite_id) of a user's inbox, oldest first.
async fn inbox(
    db: &Db,
    user: UserId,
) -> Vec<(
    String,
    String,
    String,
    Option<uuid::Uuid>,
    Option<uuid::Uuid>,
)> {
    sqlx::query_as(
        "SELECT subtype, title, body, project_id, project_invite_id FROM inbox_items \
          WHERE user_id = $1 ORDER BY created_at, id",
    )
    .bind(user.0)
    .fetch_all(db.pool())
    .await
    .unwrap()
}

async fn audit(db: &Db, user: UserId) -> Vec<(String, serde_json::Value)> {
    sqlx::query_as("SELECT action, detail FROM audit_log WHERE user_id = $1 ORDER BY id")
        .bind(user.0)
        .fetch_all(db.pool())
        .await
        .unwrap()
}

async fn pushes(db: &Db, user: UserId) -> Vec<serde_json::Value> {
    sqlx::query_scalar("SELECT payload FROM outbox WHERE user_id = $1 ORDER BY id")
        .bind(user.0)
        .fetch_all(db.pool())
        .await
        .unwrap()
}

fn terms(agents: &[&Instance]) -> JoinTerms {
    JoinTerms {
        agents: agents.iter().map(|a| a.id).collect(),
        daily_token_limit: 1000,
        total_token_limit: 5000,
        consent: Consent {
            version: PROJECT_CONSENT_VERSION,
        },
    }
}

/// 邀请、加入、撤回、退出、移出：每一步给该知道的人发回执、给每个相关的人记审计。邀请通知不带邀请人能写的字；
/// 审计里没有手机号。
#[tokio::test]
async fn project_flows_send_receipts_and_audit() {
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800002101", Some("Alice")).await;
    let bob = user(db, "+8613800002102", Some("Bob")).await;
    let carol = user(db, "+8613800002103", None).await;
    let a1 = instance(db, alice, "lead").await;
    let b1 = instance(db, bob, "helper").await;
    let c1 = instance(db, carol, "writer").await;
    let p = project(db, alice, &a1, "Secret plan").await;

    // 邀请 bob：bob 收到一条不带名字的通知（推送也是），alice 记一条审计。
    let invite =
        projects::invite_phone(db, alice, ACTOR, p, "+8613800002102", InviteCaps::default())
            .await
            .unwrap();
    let items = inbox(db, bob).await;
    assert_eq!(items.len(), 1);
    let (subtype, title, body, project_id, invite_id) = &items[0];
    assert_eq!(subtype, notice_subtype::PROJECT_INVITE);
    assert_eq!((*project_id, *invite_id), (Some(p.0), Some(invite.id.0)));
    for text in [title, body] {
        assert!(
            !text.contains("Alice") && !text.contains("Secret"),
            "{text}"
        );
    }
    let push = &pushes(db, bob).await[0];
    let push_text = push.to_string();
    assert!(!push_text.contains("Alice") && !push_text.contains("Secret"));
    assert!(push_text.contains(&invite.id.to_string()));
    // 再邀请一次：同一条，不再通知、不再记审计。
    let again =
        projects::invite_phone(db, alice, ACTOR, p, "+8613800002102", InviteCaps::default())
            .await
            .unwrap();
    assert_eq!(again.id, invite.id);
    assert_eq!(inbox(db, bob).await.len(), 1);
    let created: Vec<_> = audit(db, alice)
        .await
        .into_iter()
        .filter(|(a, _)| a == "project.invite.create")
        .collect();
    assert_eq!(created.len(), 1);
    assert!(
        !created[0].1.to_string().contains("+86"),
        "no phone numbers"
    );

    // bob 接受：alice 收到“加入了”，两边各一条审计；bob 的那条记实例和预算，alice 的只记是谁。
    let a = projects::accept(db, bob, ACTOR, InviteKey::Phone(invite.id), &terms(&[&b1]))
        .await
        .unwrap();
    assert!(a.created);
    let items = inbox(db, alice).await;
    let joined = items.last().unwrap();
    assert_eq!(joined.0, notice_subtype::PROJECT_JOINED);
    assert!(joined.2.contains("Bob") && joined.2.contains("Secret plan"));
    let bob_audit = audit(db, bob).await;
    let (action, detail) = bob_audit.last().unwrap();
    assert_eq!(action, "project.join");
    assert_eq!(detail["instances"][0], b1.id.to_string());
    assert_eq!(detail["consent_version"], PROJECT_CONSENT_VERSION);
    let (action, detail) = audit(db, alice).await.pop().unwrap();
    assert_eq!(action, "project.member_joined");
    assert!(detail.get("instances").is_none());
    assert_eq!(detail["member"], bob.to_string());
    // bob 的邀请通知标成已读。
    let read: bool = sqlx::query_scalar(
        "SELECT read_at IS NOT NULL FROM inbox_items WHERE user_id = $1 AND project_invite_id = $2",
    )
    .bind(bob.0)
    .bind(invite.id.0)
    .fetch_one(db.pool())
    .await
    .unwrap();
    assert!(read);
    // 列表、详情。
    let mine = projects::my_projects(db, bob).await.unwrap();
    assert_eq!(mine.len(), 1);
    let d = projects::detail(db, bob, p).await.unwrap();
    assert_eq!(d.members.len(), 2);

    // carol 用链接加入（没昵称：回执里叫“一位成员”）。
    let hash = [7u8; 32];
    projects::invite_link(db, alice, ACTOR, p, &hash, InviteCaps::default())
        .await
        .unwrap();
    projects::accept(db, carol, ACTOR, InviteKey::Link(&hash), &terms(&[&c1]))
        .await
        .unwrap();
    let joined = inbox(db, alice).await.pop().unwrap();
    assert!(
        joined.2.contains("一位成员") || joined.2.contains("A member"),
        "{}",
        joined.2
    );

    // 创建者撤了 bob 的 agent：告诉 bob；bob 撤自己的：告诉创建者。
    projects::withdraw_agent(db, alice, ACTOR, p, b1.id)
        .await
        .unwrap();
    let removed = inbox(db, bob).await.pop().unwrap();
    assert_eq!(removed.0, notice_subtype::PROJECT_AGENT_REMOVED);
    assert!(removed.2.contains("helper"));
    let (action, detail) = audit(db, alice).await.pop().unwrap();
    assert_eq!(action, "project.agent.withdraw");
    assert!(detail.get("instance").is_none(), "{detail}");
    projects::withdraw_agent(db, carol, ACTOR, p, c1.id)
        .await
        .unwrap();
    let left = inbox(db, alice).await.pop().unwrap();
    assert_eq!(left.0, notice_subtype::PROJECT_AGENT_LEFT);
    assert!(left.2.contains("writer"));
    // 再撤一次：不再通知。
    let n = inbox(db, alice).await.len();
    projects::withdraw_agent(db, carol, ACTOR, p, c1.id)
        .await
        .unwrap();
    assert_eq!(inbox(db, alice).await.len(), n);

    // bob 退出：告诉创建者。移出 carol：告诉 carol；再移一次不再通知。
    projects::leave(db, bob, ACTOR, p).await.unwrap();
    let left = inbox(db, alice).await.pop().unwrap();
    assert_eq!(left.0, notice_subtype::PROJECT_LEFT);
    assert!(left.2.contains("Bob"));
    projects::remove_member(db, alice, ACTOR, p, carol)
        .await
        .unwrap();
    let removed = inbox(db, carol).await.pop().unwrap();
    assert_eq!(removed.0, notice_subtype::PROJECT_REMOVED);
    let n = inbox(db, carol).await.len();
    projects::remove_member(db, alice, ACTOR, p, carol)
        .await
        .unwrap();
    assert_eq!(inbox(db, carol).await.len(), n);
    let (action, _) = audit(db, carol).await.pop().unwrap();
    assert_eq!(action, "project.removed");

    // 拉黑以后的邀请：不通知。
    projects::block(db, carol, ACTOR, alice).await.unwrap();
    assert_eq!(projects::blocks(db, carol).await.unwrap().len(), 1);
    let p2 = project(db, alice, &instance(db, alice, "x").await, "Second").await;
    projects::invite_phone(
        db,
        alice,
        ACTOR,
        p2,
        "+8613800002103",
        InviteCaps::default(),
    )
    .await
    .unwrap();
    assert_eq!(inbox(db, carol).await.len(), n);
    projects::unblock(db, carol, ACTOR, alice).await.unwrap();
    assert!(projects::blocks(db, carol).await.unwrap().is_empty());

    // 后台：到期的标过期。
    sqlx::query("UPDATE project_invites SET expires_at = now() - interval '1 second' WHERE status = 'pending'")
        .execute(db.pool())
        .await
        .unwrap();
    assert!(projects::sweep(db).await.unwrap() >= 1);
    let pending: i64 =
        sqlx::query_scalar("SELECT count(*) FROM project_invites WHERE status = 'pending'")
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(pending, 0);
}
