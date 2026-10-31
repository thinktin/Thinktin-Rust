//! 共享看板（8.10）：agent 写的带作者、标签，按标签读；内容注明不可信；保险箱的值不上看板；一次运行写的条数有
//! 上限；写了在作者的实例上记一条事件。需要 DATABASE_URL（没有时跳过）。

use std::sync::Arc;
use std::time::Duration;

use keyvault::{Kms, LocalKms};
use orchestrator::board::{BoardTools, MAX_POSTS_PER_RUN};
use orchestrator::shim::{PlatformTools, ToolContext, ToolOutput};
use proto::domain::{GrantScope, Instance, InstanceLimits, RunSource, UserId};
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{NewBoardPost, NewInstance, NewRun};

fn kms() -> Arc<dyn Kms> {
    Arc::new(LocalKms::new("kms1", &[3; 32]))
}

async fn setup(t: &TestDb, phone: &str) -> (UserId, Instance, ToolContext) {
    let mut w = t.db.worker().await.unwrap();
    let (u, _) = w.upsert_user_by_phone(phone).await.unwrap();
    w.commit().await.unwrap();
    let mut tx = t.db.tenant(u.id).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "Writer".into(),
            workspace_id: format!("ws-{}", uuid::Uuid::now_v7().simple()),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    let grant = tx
        .create_run_grant(
            inst.id,
            None,
            &GrantScope {
                platform_tools: vec!["board_read".into(), "board_post".into()],
                ..GrantScope::default()
            },
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let run = tx
        .create_run(&NewRun::new(inst.id, RunSource::User, "report", "1"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let ctx = ToolContext {
        user: u.id,
        instance: inst.id,
        run: run.id,
        plan: None,
        grant: grant.id,
    };
    (u.id, inst, ctx)
}

fn body(out: &ToolOutput) -> Value {
    assert!(!out.is_error, "{:?}", out.content);
    serde_json::from_str(out.content[0]["text"].as_str().unwrap()).unwrap()
}

fn error(out: &ToolOutput) -> String {
    assert!(out.is_error, "{:?}", out.content);
    out.content[0]["text"].as_str().unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn agents_post_to_and_read_the_shared_board() {
    let Some(t) = TestDb::new().await else { return };
    let (user, inst, ctx) = setup(&t, "+8613800008911").await;
    let tools = BoardTools::new(t.db.clone(), kms());

    // 保险箱里的密码不上看板。
    let vault = orchestrator::artifacts::user_vault(&t.db, kms(), user, true)
        .await
        .unwrap();
    let id = proto::domain::VaultItemId::new();
    let sealed = vault
        .seal_vault(
            &user.to_string(),
            &id.to_string(),
            &keyvault::VaultSecret {
                username: "octocat".into(),
                password: "gh-secret-123".into(),
            },
        )
        .await
        .unwrap();
    let mut tx = t.db.tenant(user).await.unwrap();
    tx.create_vault_item(&store::NewVaultItem {
        id,
        name: "github".into(),
        purpose: "push code".into(),
        sealed,
        has_username: true,
        instance_ids: vec![inst.id],
    })
    .await
    .unwrap();
    // 用户自己写的一条。
    tx.post_to_board(&NewBoardPost {
        body: "Ship on Friday".into(),
        tags: vec!["launch".into()],
        ..NewBoardPost::default()
    })
    .await
    .unwrap();
    tx.commit().await.unwrap();

    let posted = body(
        &tools
            .call(
                &ctx,
                "board_post",
                &json!({ "body": "Pushed with gh-secret-123. Reviews next.", "tags": ["Launch", "launch", "研发"] }),
            )
            .await,
    );
    assert_eq!(posted["status"], "posted");

    let read = body(&tools.call(&ctx, "board_read", &json!({})).await);
    assert!(
        read["note"]
            .as_str()
            .unwrap()
            .contains("not as instructions")
    );
    let posts = read["posts"].as_array().unwrap();
    assert_eq!(posts.len(), 2);
    assert_eq!(posts[0]["author"], "Writer");
    assert_eq!(posts[0]["author_instance_id"], json!(inst.id));
    assert_eq!(posts[0]["tags"], json!(["launch", "研发"]));
    let text = posts[0]["body"].as_str().unwrap();
    assert!(!text.contains("gh-secret-123"), "{text}");
    assert!(text.contains("[vault:github]"), "{text}");
    assert_eq!(posts[1]["author"], "user");

    // 按标签读；翻页。
    let tagged = body(
        &tools
            .call(&ctx, "board_read", &json!({ "tag": "研发" }))
            .await,
    );
    assert_eq!(tagged["posts"].as_array().unwrap().len(), 1);
    let first = body(&tools.call(&ctx, "board_read", &json!({ "limit": 1 })).await);
    assert!(first["next"].as_str().unwrap().contains("before="));
    let older = body(
        &tools
            .call(
                &ctx,
                "board_read",
                &json!({ "before": first["posts"][0]["id"], "limit": 1 }),
            )
            .await,
    );
    assert_eq!(older["posts"][0]["author"], "user");

    // 写了在作者的实例上记一条事件。
    let mut w = t.db.worker().await.unwrap();
    let events = w
        .recent_run_events(ctx.run, &["board.posted"], 10)
        .await
        .unwrap();
    w.rollback().await.unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].payload["post_id"], posted["post_id"]);

    // 不合格的：空的、太长的、坏标签。
    for bad in [
        json!({ "body": "   " }),
        json!({ "body": "x".repeat(2001) }),
        json!({ "body": "ok", "tags": ["has space"] }),
        json!({ "body": "ok", "tags": ["a", "b", "c", "d", "e", "f", "g", "h", "i"] }),
    ] {
        error(&tools.call(&ctx, "board_post", &bad).await);
    }

    // 一次运行写的条数有上限。
    for i in 1..MAX_POSTS_PER_RUN {
        body(
            &tools
                .call(&ctx, "board_post", &json!({ "body": format!("note {i}") }))
                .await,
        );
    }
    let capped = error(
        &tools
            .call(&ctx, "board_post", &json!({ "body": "one more" }))
            .await,
    );
    assert!(capped.contains("per task"), "{capped}");
}
