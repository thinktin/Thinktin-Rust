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
        agents: agents
            .iter()
            .map(|a| store::JoinAgent::mixed(a.id))
            .collect(),
        daily_token_limit: 1000,
        total_token_limit: 5000,
        consent: Consent {
            version: PROJECT_CONSENT_VERSION,
        },
        mixed_allowed: true,
        max_instances: 0,
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
    // 再撤一次：不再通知；加回来再撤（一小时内）：也不再多一条，推送互相替换。
    let n = inbox(db, alice).await.len();
    projects::withdraw_agent(db, carol, ACTOR, p, c1.id)
        .await
        .unwrap();
    assert_eq!(inbox(db, alice).await.len(), n);
    let consent = Some(Consent {
        version: PROJECT_CONSENT_VERSION,
    });
    projects::add_agents(
        db,
        carol,
        ACTOR,
        p,
        &[store::JoinAgent::mixed(c1.id)],
        consent,
        true,
        0,
    )
    .await
    .unwrap();
    projects::withdraw_agent(db, carol, ACTOR, p, c1.id)
        .await
        .unwrap();
    assert_eq!(inbox(db, alice).await.len(), n);
    // 换一个新领养的实例也一样（按主人算，不按实例）。
    let c2 = instance(db, carol, "spam spam").await;
    projects::add_agents(
        db,
        carol,
        ACTOR,
        p,
        &[store::JoinAgent::mixed(c2.id)],
        consent,
        true,
        0,
    )
    .await
    .unwrap();
    projects::withdraw_agent(db, carol, ACTOR, p, c2.id)
        .await
        .unwrap();
    assert_eq!(inbox(db, alice).await.len(), n);
    let collapse: Vec<String> = pushes(db, alice)
        .await
        .iter()
        .filter_map(|p| p["collapse_id"].as_str().map(String::from))
        .filter(|c| c.starts_with("project_agent:"))
        .collect();
    assert!(collapse.iter().all(|c| c == &collapse[0]) && !collapse.is_empty());

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

    // 拒绝并拉黑：审计里记着拉黑了谁（和直接拉黑一样）。
    let p3 = project(db, alice, &instance(db, alice, "y").await, "Third").await;
    let to_carol = projects::invite_phone(
        db,
        alice,
        ACTOR,
        p3,
        "+8613800002103",
        InviteCaps::default(),
    )
    .await
    .unwrap();
    projects::decline(db, carol, ACTOR, to_carol.id, true)
        .await
        .unwrap();
    let (action, detail) = audit(db, carol).await.pop().unwrap();
    assert_eq!(action, "user.block");
    assert_eq!(detail["blocked"], alice.to_string());
    projects::unblock(db, carol, ACTOR, alice).await.unwrap();
    let n = inbox(db, carol).await.len();
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

/// 项目产出物（8.15）：项目运行发布的用项目的密钥加密、存在项目下面（同时发布只建一把密钥，主人的个人密钥解不开）；
/// 成员凭成员关系下载，外人下载不了（退出以后的见网关的 `project_runs_and_artifacts_over_http`）；项目删了密钥没了，
/// 谁都解不开；删项目时还在的成员收到“项目已删除”。
#[tokio::test]
async fn project_artifacts_use_the_project_key_and_die_with_it() {
    use orchestrator::artifacts::{ArtifactError, ArtifactStore, LocalBlobStore, Origin};
    use std::sync::Arc;
    let Some(t) = TestDb::new().await else { return };
    let db = &t.db;
    let alice = user(db, "+8613800002201", Some("Alice")).await;
    let bob = user(db, "+8613800002202", Some("Bob")).await;
    let a1 = instance(db, alice, "lead").await;
    let b1 = instance(db, bob, "helper").await;
    let p = project(db, alice, &a1, "Shared").await;
    let hash = [9u8; 32];
    projects::invite_link(db, alice, ACTOR, p, &hash, InviteCaps::default())
        .await
        .unwrap();
    projects::accept(db, bob, ACTOR, InviteKey::Link(&hash), &terms(&[&b1]))
        .await
        .unwrap();
    // bob 在项目里的一个运行（worker 复制出来：8.15 里项目运行还不会被领去执行）。
    let mut tb = db.tenant(bob).await.unwrap();
    let private = tb
        .create_run(&store::NewRun::new(
            b1.id,
            proto::domain::RunSource::User,
            "task",
            "1",
        ))
        .await
        .unwrap();
    tb.commit().await.unwrap();
    let cols: Vec<String> = sqlx::query_scalar(
        "SELECT column_name::text FROM information_schema.columns WHERE table_name = 'runs' \
           AND column_name NOT IN ('id', 'project_id', 'space_kind', 'space_id') ORDER BY ordinal_position",
    )
    .fetch_all(db.pool())
    .await
    .unwrap();
    let list = cols.join(", ");
    let run = proto::domain::RunId::new();
    // 只有 worker 写得出项目运行（fill_space 触发器）：用原始连接切到 worker 角色。
    let mut tx = db.pool().begin().await.unwrap();
    sqlx::query("SELECT set_config('role', 'thinktin_worker', true)")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "INSERT INTO runs (id, project_id, {list}) SELECT $1, $2, {list} FROM runs WHERE id = $3"
    )))
    .bind(run.0)
    .bind(p.0)
    .bind(private.id.0)
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let dir = tempfile::tempdir().unwrap();
    let kms: Arc<dyn keyvault::Kms> = Arc::new(keyvault::LocalKms::new("kms1", &[5; 32]));
    let blobs = Arc::new(LocalBlobStore::new(dir.path().join("blobs")).unwrap());
    let store = ArtifactStore::new(db.clone(), blobs.clone(), kms.clone());
    let origin = Origin {
        user: bob,
        instance: b1.id,
        run,
        root: run,
    };
    // 项目还没有密钥时同时发布两个（8.15 评审）：只建出一把，两个都解得开。
    let (a, b) = tokio::join!(
        store.publish(origin, "report.md", "text/markdown", b"# done"),
        store.publish(origin, "notes.md", "text/markdown", b"# notes"),
    );
    let (a, b) = (a.unwrap(), b.unwrap());
    let keys: i64 = sqlx::query_scalar("SELECT count(*) FROM project_keys WHERE project_id = $1")
        .bind(p.0)
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert_eq!(keys, 1);
    assert_eq!(store.read(&b).await.unwrap(), b"# notes");
    // 主人的个人密钥解不开项目产出物。
    let sealed = orchestrator::artifacts::BlobStore::get(blobs.as_ref(), &a.blob_key)
        .await
        .unwrap();
    let mine = orchestrator::artifacts::user_vault(db, kms.clone(), bob, true)
        .await
        .unwrap();
    assert!(
        mine.open_bytes(&bob.to_string(), &a.artifact.id.to_string(), &sealed)
            .await
            .is_err()
    );
    assert_eq!(a.project_id, Some(p));
    assert!(a.blob_key.starts_with("projects/"), "{}", a.blob_key);
    assert_eq!(store.read(&a).await.unwrap(), b"# done");
    // alice（成员）下载得到；外人 carol 不行。
    let (got, bytes, _) = store
        .read_for_member(alice, p, a.artifact.id)
        .await
        .unwrap();
    assert_eq!(
        (got.artifact.id, bytes.as_slice()),
        (a.artifact.id, &b"# done"[..])
    );
    let carol = user(db, "+8613800002203", None).await;
    assert!(matches!(
        store.read_for_member(carol, p, a.artifact.id).await,
        Err(ArtifactError::Store(store::Error::NotFound))
    ));
    // 删项目：bob 收到“项目已删除”；密钥没了，谁都解不开。
    projects::delete(db, alice, ACTOR, p, true).await.unwrap();
    let deleted = inbox(db, bob).await.pop().unwrap();
    assert_eq!(deleted.0, notice_subtype::PROJECT_DELETED);
    assert!(deleted.2.contains("Shared"), "{}", deleted.2);
    assert!(matches!(store.read(&a).await, Err(ArtifactError::Gone)));
    assert!(matches!(
        store.read_for_member(alice, p, a.artifact.id).await,
        Err(ArtifactError::Store(store::Error::NotFound))
    ));
    let (action, detail) = audit(db, alice).await.pop().unwrap();
    assert_eq!(action, "project.delete");
    assert_eq!(detail["shared"], true);
}
