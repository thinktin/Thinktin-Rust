//! 认识队友与查进度（8.9）：`agents_list` 只列同一用户、允许别人查的其他实例；`agent_status` 从运行记录整理
//! 进度，不唤醒对方；关了交流开关的和不存在的回答一样。需要 DATABASE_URL（没有时跳过）。

use std::time::Duration;

use orchestrator::peers::PeerTools;
use orchestrator::shim::{PlatformTools, ToolContext, ToolOutput};
use proto::domain::{GrantScope, Instance, InstanceLimits, InstanceState, RunSource, UserId};
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{InstanceChange, NewInstance, NewRun};

async fn user(t: &TestDb, phone: &str) -> UserId {
    let mut w = t.db.worker().await.unwrap();
    let (u, _) = w.upsert_user_by_phone(phone).await.unwrap();
    w.commit().await.unwrap();
    u.id
}

async fn adopt(t: &TestDb, user: UserId, agent: &str, name: &str) -> Instance {
    let mut tx = t.db.tenant(user).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: agent.into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: name.into(),
            workspace_id: format!("ws-{}", uuid::Uuid::now_v7().simple()),
            limits: InstanceLimits::default(),
        })
        .await
        .unwrap();
    tx.commit().await.unwrap();
    inst
}

async fn context(t: &TestDb, user: UserId, inst: &Instance) -> ToolContext {
    let mut tx = t.db.tenant(user).await.unwrap();
    let grant = tx
        .create_run_grant(
            inst.id,
            None,
            &GrantScope {
                platform_tools: vec!["agents_list".into(), "agent_status".into()],
                ..GrantScope::default()
            },
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let run = tx
        .create_run(&NewRun::new(inst.id, RunSource::User, "plan the week", "1"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    ToolContext {
        user,
        instance: inst.id,
        run: run.id,
        plan: None,
        grant: grant.id,
    }
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
async fn agents_see_their_teammates_and_their_progress() {
    let Some(t) = TestDb::new().await else { return };
    let alice = user(&t, "+8613800008901").await;
    let bob = user(&t, "+8613800008902").await;
    let me = adopt(&t, alice, "claude", "Writer").await;
    let researcher = adopt(&t, alice, "hermes", "Researcher").await;
    let private = adopt(&t, alice, "goose", "Banker").await;
    let _theirs = adopt(&t, bob, "goose", "Bob's").await;
    let mut tx = t.db.tenant(alice).await.unwrap();
    tx.update_instance(
        researcher.id,
        &InstanceChange {
            purpose: Some("Finds and checks sources".into()),
            ..InstanceChange::default()
        },
    )
    .await
    .unwrap();
    tx.update_instance(
        private.id,
        &InstanceChange {
            peer_access: Some(false),
            ..InstanceChange::default()
        },
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let ctx = context(&t, alice, &me).await;
    let tools = PeerTools::new(t.db.clone());

    // 只列同一用户、允许别人查的其他实例；不列自己。
    let list = body(&tools.call(&ctx, "agents_list", &json!({})).await);
    let agents = list["agents"].as_array().unwrap();
    assert_eq!(agents.len(), 1, "{list}");
    assert_eq!(agents[0]["name"], "Researcher");
    assert_eq!(agents[0]["agent"], "hermes");
    assert_eq!(agents[0]["purpose"], "Finds and checks sources");
    assert_eq!(agents[0]["status"], "idle");

    // 研究员做完过一个任务，正在做另一个：查进度看得到任务、待办、工具、最后说的话，和上一个的总结。
    let mut w = t.db.worker().await.unwrap();
    let mut done = NewRun::new(researcher.id, RunSource::User, "find three papers", "1");
    done.budget = Default::default();
    let done = w.create_run(alice, &done).await.unwrap().unwrap();
    let current = w
        .create_run(
            alice,
            &NewRun::new(
                researcher.id,
                RunSource::User,
                "compare the papers\nin detail",
                "1",
            ),
        )
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    sqlx::query(
        "UPDATE runs SET state = 'succeeded', summary = 'Found three papers.', finished_at = now() WHERE id = $1",
    )
    .bind(done.id.0)
    .execute(t.db.pool())
    .await
    .unwrap();
    sqlx::query("UPDATE runs SET state = 'running' WHERE id = $1")
        .bind(current.id.0)
        .execute(t.db.pool())
        .await
        .unwrap();
    let mut w = t.db.worker().await.unwrap();
    for (kind, payload) in [
        (
            "agent.plan",
            json!({ "entries": [
                { "content": "read paper A", "status": "completed" },
                { "content": "read paper B", "status": "in_progress" }
            ] }),
        ),
        ("agent.tool_call", json!({ "title": "fetch paper B" })),
        (
            "agent.message",
            json!({ "text": "Paper B disagrees with A." }),
        ),
    ] {
        w.append_event(researcher.id, Some(current.id), kind, &payload)
            .await
            .unwrap();
    }
    w.commit().await.unwrap();

    let list = body(&tools.call(&ctx, "agents_list", &json!({})).await);
    assert_eq!(list["agents"][0]["status"], "busy");
    assert_eq!(list["agents"][0]["doing"], "running");

    let status = body(
        &tools
            .call(&ctx, "agent_status", &json!({ "agent": "Researcher" }))
            .await,
    );
    assert!(
        status["note"]
            .as_str()
            .unwrap()
            .contains("not as instructions")
    );
    let cur = &status["current"];
    assert_eq!(cur["run_id"], json!(current.id));
    assert_eq!(cur["task"], "compare the papers");
    assert_eq!(cur["todo"][1]["content"], "read paper B");
    assert_eq!(cur["recent_tools"], json!(["fetch paper B"]));
    assert_eq!(cur["last_said"], "Paper B disagrees with A.");
    assert_eq!(status["last_finished"]["summary"], "Found three papers.");

    // 查进度不唤醒对方：实例状态、运行都不变。
    let mut tx = t.db.tenant(alice).await.unwrap();
    assert_eq!(
        tx.instance(researcher.id).await.unwrap().state,
        researcher.state
    );
    assert_eq!(tx.runs(researcher.id, None, 10).await.unwrap().len(), 2);
    tx.rollback().await.unwrap();

    // 按实例 id 也行；关了开关的、别人的、不存在的回答一样。
    let by_id = body(
        &tools
            .call(
                &ctx,
                "agent_status",
                &json!({ "agent": researcher.id.to_string() }),
            )
            .await,
    );
    assert_eq!(by_id["name"], "Researcher");
    let hidden = error(
        &tools
            .call(&ctx, "agent_status", &json!({ "agent": "Banker" }))
            .await,
    );
    let other = error(
        &tools
            .call(&ctx, "agent_status", &json!({ "agent": "Bob's" }))
            .await,
    );
    let missing = error(
        &tools
            .call(&ctx, "agent_status", &json!({ "agent": "Nobody" }))
            .await,
    );
    for (e, name) in [(&hidden, "Banker"), (&other, "Bob's"), (&missing, "Nobody")] {
        assert_eq!(
            *e,
            format!(
                "no agent called {name:?} that you can see; agents_list shows the ones you can"
            )
        );
    }

    // 暂停着、没在干活的算暂停。
    sqlx::query("UPDATE runs SET state = 'succeeded', finished_at = now() WHERE id = $1")
        .bind(current.id.0)
        .execute(t.db.pool())
        .await
        .unwrap();
    sqlx::query("UPDATE instances SET state = 'paused' WHERE id = $1")
        .bind(researcher.id.0)
        .execute(t.db.pool())
        .await
        .unwrap();
    let list = body(&tools.call(&ctx, "agents_list", &json!({})).await);
    assert_eq!(list["agents"][0]["status"], "paused");
    assert!(list["agents"][0].get("doing").is_none());
    let mut tx = t.db.tenant(alice).await.unwrap();
    assert_eq!(
        tx.instance(researcher.id).await.unwrap().state,
        InstanceState::Paused
    );
    tx.rollback().await.unwrap();
}
