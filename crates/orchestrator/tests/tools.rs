//! thinktin.schedule 平台工具：agent 登记的计划等用户确认、只能动自己实例的计划、规则校验。
//! 需要 DATABASE_URL（没有时跳过）。

use std::time::Duration;

use orchestrator::shim::{PlatformTools, ToolContext};
use orchestrator::tools::ScheduleTools;
use proto::domain::{GrantScope, InstanceId, InstanceLimits, PlanAuthor, RunSource, UserId};
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{NewInstance, NewRun};

async fn context(t: &TestDb, user: UserId) -> (ToolContext, InstanceId) {
    let mut tx = t.db.tenant(user).await.unwrap();
    let inst = tx
        .create_instance(&NewInstance {
            agent_id: "claude".into(),
            agent_version: "1".into(),
            harness: "acp".into(),
            name: "c".into(),
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
                platform_tools: vec!["schedule_create".into()],
                max_tokens: Some(1000),
                ..GrantScope::default()
            },
            Duration::from_secs(3600),
        )
        .await
        .unwrap();
    let run = tx
        .create_run(&NewRun::new(inst.id, RunSource::User, "x", "1"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    (
        ToolContext {
            user,
            instance: inst.id,
            run: run.id,
            plan: None,
            grant: grant.id,
        },
        inst.id,
    )
}

fn body(out: &orchestrator::shim::ToolOutput) -> Value {
    let text = out.content[0]["text"].as_str().unwrap();
    serde_json::from_str(text).unwrap_or(Value::String(text.into()))
}

#[tokio::test]
async fn agents_register_plans_that_wait_for_the_user() {
    let Some(t) = TestDb::new().await else { return };
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let (ctx, inst) = context(&t, user.id).await;
    let tools = ScheduleTools::new(t.db.clone());
    assert_eq!(tools.tools().len(), 4);

    let out = tools
        .call(
            &ctx,
            "schedule_create",
            &json!({
                "title": "早报",
                "goal": "Summarize today's news",
                "schedule": { "kind": "cron", "expr": "0 8 * * *", "tz": "Asia/Shanghai" }
            }),
        )
        .await;
    assert!(!out.is_error, "{out:?}");
    let created = body(&out);
    assert_eq!(created["status"], "awaiting_user_confirmation");
    let plan_id: proto::domain::PlanId = created["plan_id"].as_str().unwrap().parse().unwrap();

    let mut tx = t.db.tenant(user.id).await.unwrap();
    let plan = tx.plan(plan_id).await.unwrap();
    assert!(plan.paused, "waits for the user");
    assert_eq!(plan.created_by, PlanAuthor::Agent);
    assert_eq!(plan.instance_id, inst);
    // 计划的授权不超过发起调用的运行的授权。
    let grants = tx.run_grants(inst).await.unwrap();
    let plan_grant = grants.iter().find(|g| g.plan_id == Some(plan_id)).unwrap();
    assert_eq!(plan_grant.scope.max_tokens, Some(1000));
    tx.rollback().await.unwrap();
    let mut w = t.db.worker().await.unwrap();
    let pushes = w
        .claim_outbox("probe", Duration::from_secs(1), 10)
        .await
        .unwrap();
    w.rollback().await.unwrap();
    assert_eq!(pushes.len(), 1);
    assert_eq!(pushes[0].payload["kind"], "info");

    let listed = body(&tools.call(&ctx, "schedule_list", &json!({})).await);
    assert_eq!(listed["plans"][0]["plan_id"], created["plan_id"]);
    assert_eq!(listed["plans"][0]["paused"], true);

    // 用户确认（恢复）后，agent 再改又要重新确认。
    let mut tx = t.db.tenant(user.id).await.unwrap();
    tx.set_plan_paused(plan_id, false).await.unwrap();
    tx.commit().await.unwrap();
    let out = tools
        .call(
            &ctx,
            "schedule_update",
            &json!({ "plan_id": plan_id, "goal": "Summarize tech news", "schedule": { "kind": "cron", "expr": "30 7 * * 1-5", "tz": "Asia/Shanghai" } }),
        )
        .await;
    assert!(!out.is_error, "{out:?}");
    let mut tx = t.db.tenant(user.id).await.unwrap();
    let plan = tx.plan(plan_id).await.unwrap();
    assert!(plan.paused);
    assert_eq!(plan.goal, "Summarize tech news");
    let triggers = tx.triggers(plan_id).await.unwrap();
    assert_eq!(triggers.len(), 1);
    assert!(
        matches!(&triggers[0].spec, proto::domain::ScheduleSpec::Cron { expr, .. } if expr == "30 7 * * 1-5")
    );
    tx.rollback().await.unwrap();

    // 别的实例上的 agent 动不了这个计划。
    let (other, _) = context(&t, user.id).await;
    let out = tools
        .call(&other, "schedule_cancel", &json!({ "plan_id": plan_id }))
        .await;
    assert!(out.is_error);
    assert!(body(&out).as_str().unwrap().contains("not found"));

    // 规则校验：太频繁、时区不对、已经过去的一次性时间、参数缺失。
    for bad in [
        json!({ "title": "x", "goal": "y", "schedule": { "kind": "cron", "expr": "* * * * *", "tz": "UTC" } }),
        json!({ "title": "x", "goal": "y", "schedule": { "kind": "cron", "expr": "0 8 * * *", "tz": "Nowhere/City" } }),
        json!({ "title": "x", "goal": "y", "schedule": { "kind": "once", "at": "2020-01-01T00:00:00Z" } }),
        json!({ "title": "x" }),
    ] {
        let out = tools.call(&ctx, "schedule_create", &bad).await;
        assert!(out.is_error, "{bad} should be rejected");
    }
    assert!(tools.call(&ctx, "schedule_nope", &json!({})).await.is_error);

    let out = tools
        .call(&ctx, "schedule_cancel", &json!({ "plan_id": plan_id }))
        .await;
    assert!(!out.is_error, "{out:?}");
    let mut tx = t.db.tenant(user.id).await.unwrap();
    assert!(tx.plan(plan_id).await.is_err(), "deleted");
    assert!(
        tx.run_grants(inst)
            .await
            .unwrap()
            .iter()
            .all(|g| g.plan_id != Some(plan_id)),
        "its grant is revoked"
    );
}
