//! thinktin.schedule 平台工具：agent 登记的计划等用户确认、只能动自己实例的计划、规则校验。
//! 需要 DATABASE_URL（没有时跳过）。

use std::time::Duration;

use orchestrator::shim::{PlatformTools, ToolContext};
use orchestrator::tools::ScheduleTools;
use proto::domain::{
    GrantScope, InstanceId, InstanceLimits, PlanAuthor, RunBudget, RunSource, UserId,
};
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
    let mut new = NewRun::new(inst.id, RunSource::User, "x", "1");
    new.budget = RunBudget {
        max_tokens: Some(5000),
        max_duration_secs: 600,
        max_steps: Some(7),
    };
    let run = tx.create_run(&new).await.unwrap();
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
    assert!(
        plan.paused && plan.awaiting_confirmation,
        "waits for the user"
    );
    assert_eq!(plan.created_by, PlanAuthor::Agent);
    assert_eq!(plan.instance_id, inst);
    // 预算沿用发起调用的运行，不比它宽。
    assert_eq!(plan.policy.budget.max_steps, Some(7));
    assert_eq!(plan.policy.budget.max_tokens, Some(5000));
    // 计划的授权从发起调用的运行的授权收窄出来，不是新签的顶层授权。
    let plan_grant = tx.plan_grant(plan_id).await.unwrap().unwrap();
    assert_eq!(plan_grant.parent_id, Some(ctx.grant));
    assert_eq!(plan_grant.scope.max_tokens, Some(1000));
    // 等确认的计划不能直接恢复。
    assert!(
        tx.set_plan_paused(plan_id, false)
            .await
            .unwrap_err()
            .is_conflict()
    );
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

    // 用户确认看到的版本后开始运行；agent 再改又要重新确认。
    let mut tx = t.db.tenant(user.id).await.unwrap();
    let confirmed = tx.confirm_plan(plan_id, plan.revision).await.unwrap();
    assert!(!confirmed.paused && !confirmed.awaiting_confirmation);
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
    let updated = tx.plan(plan_id).await.unwrap();
    assert!(updated.paused && updated.awaiting_confirmation);
    assert_eq!(updated.goal, "Summarize tech news");
    // 用户手里还是改之前的版本：确认被拒，要先看新内容。
    assert!(
        tx.confirm_plan(plan_id, plan.revision)
            .await
            .unwrap_err()
            .is_conflict()
    );
    assert!(updated.revision > plan.revision);
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

/// agent 建计划有上限：每个实例最多 20 个，一次运行最多改 10 次（每次都给用户发提醒）。
/// 计划的授权跟着发起调用的运行的授权：那边吊销，这边一起失效。
#[tokio::test]
async fn agent_plans_are_capped_and_tied_to_the_calling_grant() {
    let Some(t) = TestDb::new().await else { return };
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let (ctx, _) = context(&t, user.id).await;
    let tools = ScheduleTools::new(t.db.clone());
    let create = |i: usize| {
        json!({
            "title": format!("plan {i}"),
            "goal": "g",
            "schedule": { "kind": "cron", "expr": "0 8 * * *", "tz": "Asia/Shanghai" }
        })
    };
    let mut first = None;
    for i in 0..10 {
        let out = tools.call(&ctx, "schedule_create", &create(i)).await;
        assert!(!out.is_error, "{out:?}");
        first.get_or_insert(body(&out)["plan_id"].as_str().unwrap().to_owned());
    }
    let out = tools.call(&ctx, "schedule_create", &create(10)).await;
    assert!(out.is_error && body(&out).as_str().unwrap().contains("wait for the user"));

    // 吊销发起调用的运行的授权：agent 建的计划的授权跟着失效。
    let plan_id: proto::domain::PlanId = first.unwrap().parse().unwrap();
    let mut tx = t.db.tenant(user.id).await.unwrap();
    tx.revoke_run_grant(ctx.grant, "test").await.unwrap();
    assert!(
        tx.plan_grant(plan_id)
            .await
            .unwrap()
            .unwrap()
            .revoked_at
            .is_some()
    );
    tx.commit().await.unwrap();
    // 调用方的授权失效后，agent 不能再建计划。
    let mut tx = t.db.tenant(user.id).await.unwrap();
    let fresh = tx
        .create_run(&NewRun::new(ctx.instance, RunSource::User, "y", "1"))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let ctx2 = proto_ctx(&ctx, fresh.id);
    let out = tools.call(&ctx2, "schedule_create", &create(11)).await;
    assert!(out.is_error && body(&out).as_str().unwrap().contains("not active"));

    // 每个实例最多 20 个 agent 建的计划（换几次运行、换新授权也一样）。
    let mut made = 10;
    let mut last_err = String::new();
    for round in 0..3 {
        let mut tx = t.db.tenant(user.id).await.unwrap();
        let grant = tx
            .create_run_grant(
                ctx.instance,
                None,
                &GrantScope::default(),
                Duration::from_secs(3600),
            )
            .await
            .unwrap();
        let run = tx
            .create_run(&NewRun::new(ctx.instance, RunSource::User, "z", "1"))
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let c = orchestrator::shim::ToolContext {
            grant: grant.id,
            ..proto_ctx(&ctx, run.id)
        };
        for i in 0..10 {
            let out = tools
                .call(&c, "schedule_create", &create(100 * round + i))
                .await;
            if out.is_error {
                last_err = body(&out).as_str().unwrap().to_owned();
                break;
            }
            made += 1;
        }
    }
    assert_eq!(made, 20);
    assert!(last_err.contains("already has 20 plans"), "{last_err}");
}

fn proto_ctx(ctx: &ToolContext, run: proto::domain::RunId) -> ToolContext {
    ToolContext {
        user: ctx.user,
        instance: ctx.instance,
        run,
        plan: None,
        grant: ctx.grant,
    }
}

/// 密码保险箱的平台工具（9.11）：agent 只看到名字和用途；请求推送给用户、同名的复用、有上限；
/// 已经有可用的条目就直接告诉它怎么用。
#[tokio::test]
async fn vault_tools_list_names_and_ask_the_user() {
    use orchestrator::vault::VaultTools;
    use proto::domain::VaultItemId;

    let Some(t) = TestDb::new().await else { return };
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let (ctx, inst) = context(&t, user.id).await;
    let (other_ctx, other) = context(&t, user.id).await;
    let mut tx = t.db.tenant(user.id).await.unwrap();
    for (name, instances) in [("github", vec![]), ("bank", vec![other])] {
        tx.create_vault_item(&store::NewVaultItem {
            id: VaultItemId::new(),
            name: name.into(),
            purpose: format!("{name} account"),
            sealed: vec![1; 40],
            has_username: true,
            instance_ids: instances,
        })
        .await
        .unwrap();
    }
    tx.commit().await.unwrap();
    let tools = VaultTools::new(t.db.clone());
    assert_eq!(tools.tools().len(), 2);

    // 只列这个实例能用的，从不带值。
    let listed = body(&tools.call(&ctx, "vault_list", &json!({})).await);
    let names: Vec<&str> = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["github"]);
    assert!(listed["usage"].as_str().unwrap().contains("thinktin-vault"));
    let listed = body(&tools.call(&other_ctx, "vault_list", &json!({})).await);
    assert_eq!(listed["items"].as_array().unwrap().len(), 2);

    // 已经有了：直接用。
    let out = tools
        .call(
            &ctx,
            "vault_request",
            &json!({ "name": "github", "purpose": "push code" }),
        )
        .await;
    assert!(!out.is_error);
    assert_eq!(body(&out)["status"], "available");

    // 请用户填：推送、记事件；同名的复用，不重复推送。
    for _ in 0..2 {
        let out = tools
            .call(
                &ctx,
                "vault_request",
                &json!({ "name": "work-mail", "purpose": "read the weekly report", "fields": ["username"] }),
            )
            .await;
        assert!(!out.is_error, "{out:?}");
        assert_eq!(body(&out)["status"], "requested");
    }
    let mut tx = t.db.tenant(user.id).await.unwrap();
    let pending = tx.vault_requests(true).await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].fields, ["username", "password"]);
    assert_eq!(pending[0].run_id, Some(ctx.run));
    let inbox = tx.inbox(None, 10, false).await.unwrap();
    assert_eq!(inbox.len(), 1);
    assert!(inbox[0].ai_generated && inbox[0].body.contains("read the weekly report"));
    assert_eq!(
        tx.run_event_count(ctx.run, "vault.requested")
            .await
            .unwrap(),
        1
    );
    tx.rollback().await.unwrap();
    // 别的实例上的同名条目这个 agent 用不了：照样请用户处理。
    let out = tools
        .call(
            &ctx,
            "vault_request",
            &json!({ "name": "bank", "purpose": "pay the bill" }),
        )
        .await;
    assert_eq!(body(&out)["status"], "requested");
    let listed = body(&tools.call(&ctx, "vault_list", &json!({})).await);
    assert_eq!(listed["pending_requests"].as_array().unwrap().len(), 2);

    // 参数校验和每次运行的上限。
    for bad in [
        json!({ "name": "Bad Name", "purpose": "x" }),
        json!({ "name": "ok", "purpose": "" }),
        json!({ "name": "ok", "purpose": "x", "fields": ["token"] }),
    ] {
        assert!(tools.call(&ctx, "vault_request", &bad).await.is_error);
    }
    for i in 0..3 {
        let out = tools
            .call(
                &ctx,
                "vault_request",
                &json!({ "name": format!("site-{i}"), "purpose": "login" }),
            )
            .await;
        assert!(!out.is_error);
    }
    let out = tools
        .call(
            &ctx,
            "vault_request",
            &json!({ "name": "one-more", "purpose": "login" }),
        )
        .await;
    assert!(out.is_error, "the sixth request in one run is refused");
}
