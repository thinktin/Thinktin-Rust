//! 平台工具（WBS 7.8）：`thinktin.schedule`，让 agent 在平台上登记、查看、修改、取消计划，
//! 代替 agent 自带的定时功能（架构方案 4.9）。agent 看到的名字是 `mcp__thinktin__schedule_*` 之类。
//!
//! agent 不可信（可能被网页、邮件里的内容诱导），而计划会在没人看着的时候用用户的 key 反复运行，所以：
//! - agent 新建或修改的计划先处于暂停状态，推送提醒用户，用户在 App 里确认（恢复）后才生效；
//! - agent 只能动自己实例上的计划；取消（删除）不需要确认；
//! - 触发频率受和接口一样的下限约束。

use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use notify::{PushKind, PushMessage, PushTarget};
use proto::domain::{CatchUp, Plan, PlanAuthor, PlanId, PlanPolicy, ScheduleSpec};
use proto::shim::PlatformTool;
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Db, NewPlan, Tenant, Tx};

use crate::outbox::push_item;
use crate::schedule::Schedule;
use crate::shim::{PlatformTools, ToolContext, ToolOutput};

pub const SCHEDULE_TOOLS: [&str; 4] = [
    "schedule_list",
    "schedule_create",
    "schedule_update",
    "schedule_cancel",
];

pub struct ScheduleTools {
    db: Db,
    min_interval: Duration,
    grant_ttl: Duration,
}

impl ScheduleTools {
    pub fn new(db: Db) -> Self {
        Self {
            db,
            min_interval: Duration::from_secs(5 * 60),
            grant_ttl: Duration::from_secs(90 * 24 * 3600),
        }
    }

    pub fn with_min_interval(mut self, min: Duration) -> Self {
        self.min_interval = min;
        self
    }
}

fn spec_schema() -> Value {
    json!({
        "type": "object",
        "description": "When to run. cron: five fields in the user's time zone, e.g. {\"kind\":\"cron\",\"expr\":\"0 8 * * *\",\"tz\":\"Asia/Shanghai\"}; rrule: iCalendar DTSTART;TZID=...+RRULE; once: {\"kind\":\"once\",\"at\":\"2026-10-20T09:00:00+08:00\"}.",
        "properties": {
            "kind": { "type": "string", "enum": ["cron", "rrule", "once"] },
            "expr": { "type": "string" },
            "tz": { "type": "string" },
            "rule": { "type": "string" },
            "at": { "type": "string" }
        },
        "required": ["kind"]
    })
}

#[derive(Deserialize)]
struct CreateArgs {
    title: String,
    goal: String,
    schedule: ScheduleSpec,
    #[serde(default)]
    catch_up: CatchUp,
}

#[derive(Deserialize)]
struct UpdateArgs {
    plan_id: PlanId,
    title: Option<String>,
    goal: Option<String>,
    schedule: Option<ScheduleSpec>,
}

#[derive(Deserialize)]
struct CancelArgs {
    plan_id: PlanId,
}

/// 工具调用失败：错误信息原样交给 agent（它可以据此改正参数）。
struct Fail(String);

impl From<store::Error> for Fail {
    fn from(e: store::Error) -> Self {
        match e {
            store::Error::NotFound => Fail("plan not found".into()),
            store::Error::Invalid(m) | store::Error::Conflict(m) => Fail(m),
            other => {
                tracing::error!(error = %other, "schedule tool failed");
                Fail("internal error, try again later".into())
            }
        }
    }
}

fn parse<T: for<'de> Deserialize<'de>>(args: &Value) -> Result<T, Fail> {
    serde_json::from_value(args.clone()).map_err(|e| Fail(format!("invalid arguments: {e}")))
}

fn check_text(field: &str, v: &str, max: usize) -> Result<(), Fail> {
    let n = v.trim().chars().count();
    if n == 0 || n > max {
        return Err(Fail(format!("{field} must be 1-{max} characters")));
    }
    Ok(())
}

impl ScheduleTools {
    fn next_fire(&self, spec: &ScheduleSpec) -> Result<chrono::DateTime<Utc>, Fail> {
        let now = Utc::now();
        let s = Schedule::parse(spec).map_err(|e| Fail(e.to_string()))?;
        if !matches!(spec, ScheduleSpec::Once { .. }) {
            s.check_min_interval(now, self.min_interval)
                .map_err(|e| Fail(e.to_string()))?;
        }
        s.next_after(now)
            .ok_or_else(|| Fail("the schedule never fires after now".into()))
    }

    /// 这个实例上没删除的计划（别的实例的计划当作不存在）。
    async fn own_plan(t: &mut Tx<Tenant>, ctx: &ToolContext, id: PlanId) -> Result<Plan, Fail> {
        let plan = t.plan(id).await?;
        if plan.instance_id != ctx.instance {
            return Err(Fail("plan not found".into()));
        }
        Ok(plan)
    }

    /// 计划改动后等用户确认：暂停，并推送提醒。
    async fn ask_to_confirm(
        t: &mut Tx<Tenant>,
        ctx: &ToolContext,
        plan: &Plan,
        what: &str,
    ) -> Result<(), Fail> {
        t.set_plan_paused(plan.id, true).await?;
        let message = PushMessage {
            kind: PushKind::Info,
            title: "agent 想安排一个计划".into(),
            body: format!(
                "{what}「{}」，确认后才会按时运行",
                plan.title.chars().take(40).collect::<String>()
            ),
            thread_id: Some(plan.id.to_string()),
            collapse_id: Some(format!("plan-confirm:{}", plan.id)),
            target: PushTarget {
                instance_id: Some(ctx.instance.to_string()),
                ..Default::default()
            },
            ttl: None,
        };
        t.enqueue_outbox(&push_item(&message, None)).await?;
        t.append_event(
            ctx.instance,
            Some(ctx.run),
            "plan.needs_confirmation",
            &json!({ "plan_id": plan.id, "title": plan.title, "change": what }),
        )
        .await?;
        Ok(())
    }

    async fn list(&self, ctx: &ToolContext) -> Result<Value, Fail> {
        let mut t = self.db.tenant(ctx.user).await?;
        let mut out = Vec::new();
        for plan in t.plans(Some(ctx.instance)).await? {
            let triggers: Vec<Value> = t
                .triggers(plan.id)
                .await?
                .into_iter()
                .map(|tr| json!({ "schedule": tr.spec, "enabled": tr.enabled, "next_fire_at": tr.next_fire_at }))
                .collect();
            out.push(json!({
                "plan_id": plan.id,
                "title": plan.title,
                "goal": plan.goal,
                "paused": plan.paused,
                "created_by": plan.created_by,
                "triggers": triggers,
            }));
        }
        t.rollback().await?;
        Ok(json!({ "plans": out }))
    }

    async fn create(&self, ctx: &ToolContext, args: CreateArgs) -> Result<Value, Fail> {
        check_text("title", &args.title, 100)?;
        check_text("goal", &args.goal, 8000)?;
        let next = self.next_fire(&args.schedule)?;
        let scope = {
            let mut w = self.db.worker().await?;
            let (_, g) = w.run_grant(ctx.grant).await?;
            w.rollback().await?;
            g.scope
        };
        let mut t = self.db.tenant(ctx.user).await?;
        let plan = t
            .create_plan(&NewPlan {
                instance_id: ctx.instance,
                title: args.title.trim().into(),
                goal: args.goal.trim().into(),
                policy: PlanPolicy::default(),
                catch_up: args.catch_up,
                created_by: PlanAuthor::Agent,
                run_grant_id: None,
            })
            .await?;
        // 计划的授权不超过发起这次调用的运行的授权。
        let grant = t
            .create_run_grant(ctx.instance, Some(plan.id), &scope, self.grant_ttl)
            .await?;
        t.set_plan_grant(plan.id, grant.id).await?;
        t.add_trigger(plan.id, &args.schedule, Some(next)).await?;
        Self::ask_to_confirm(&mut t, ctx, &plan, "新建了计划").await?;
        t.audit(
            &format!("agent:{}", ctx.instance),
            "plan.create",
            Some(&plan.id.to_string()),
            &json!({ "run": ctx.run }),
        )
        .await?;
        t.commit().await?;
        Ok(json!({
            "plan_id": plan.id,
            "status": "awaiting_user_confirmation",
            "next_fire_at": next,
            "note": "The plan is registered but paused until the user confirms it in the ThinkTin app.",
        }))
    }

    async fn update(&self, ctx: &ToolContext, args: UpdateArgs) -> Result<Value, Fail> {
        let next = args
            .schedule
            .as_ref()
            .map(|s| self.next_fire(s))
            .transpose()?;
        let mut t = self.db.tenant(ctx.user).await?;
        let plan = Self::own_plan(&mut t, ctx, args.plan_id).await?;
        let title = args.title.unwrap_or(plan.title.clone());
        let goal = args.goal.unwrap_or(plan.goal.clone());
        check_text("title", &title, 100)?;
        check_text("goal", &goal, 8000)?;
        let plan = t
            .update_plan(
                plan.id,
                title.trim(),
                goal.trim(),
                &plan.policy,
                plan.catch_up,
            )
            .await?;
        if let (Some(spec), Some(next)) = (&args.schedule, next) {
            for tr in t.triggers(plan.id).await? {
                t.delete_trigger(tr.id).await?;
            }
            t.add_trigger(plan.id, spec, Some(next)).await?;
        }
        Self::ask_to_confirm(&mut t, ctx, &plan, "修改了计划").await?;
        t.audit(
            &format!("agent:{}", ctx.instance),
            "plan.update",
            Some(&plan.id.to_string()),
            &json!({ "run": ctx.run }),
        )
        .await?;
        t.commit().await?;
        Ok(json!({ "plan_id": plan.id, "status": "awaiting_user_confirmation" }))
    }

    async fn cancel(&self, ctx: &ToolContext, args: CancelArgs) -> Result<Value, Fail> {
        let mut t = self.db.tenant(ctx.user).await?;
        let plan = Self::own_plan(&mut t, ctx, args.plan_id).await?;
        t.delete_plan(plan.id).await?;
        t.revoke_plan_grants(plan.id, "cancelled by agent").await?;
        t.append_event(
            ctx.instance,
            Some(ctx.run),
            "plan.cancelled",
            &json!({ "plan_id": plan.id, "title": plan.title }),
        )
        .await?;
        t.audit(
            &format!("agent:{}", ctx.instance),
            "plan.delete",
            Some(&plan.id.to_string()),
            &json!({ "run": ctx.run }),
        )
        .await?;
        t.commit().await?;
        Ok(json!({ "plan_id": plan.id, "status": "cancelled" }))
    }
}

#[async_trait]
impl PlatformTools for ScheduleTools {
    fn tools(&self) -> Vec<PlatformTool> {
        let plan_id = json!({ "type": "string", "description": "plan_id from schedule_list" });
        vec![
            PlatformTool {
                name: "schedule_list".into(),
                description: "List the plans (recurring or one-time tasks) registered on the ThinkTin platform for this agent.".into(),
                input_schema: json!({ "type": "object", "properties": {} }),
            },
            PlatformTool {
                name: "schedule_create".into(),
                description: "Register a plan on the ThinkTin platform: the platform runs `goal` as a new task for this agent at the scheduled times, even when the user is offline. Use this instead of any built-in cron or heartbeat. New plans wait for the user's confirmation in the app.".into(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "title": { "type": "string", "description": "Short name shown to the user" },
                        "goal": { "type": "string", "description": "The instruction to run each time" },
                        "schedule": spec_schema(),
                        "catch_up": { "type": "string", "enum": ["once", "all", "skip"], "description": "What to do with fires missed while the platform was down (default once)" }
                    },
                    "required": ["title", "goal", "schedule"]
                }),
            },
            PlatformTool {
                name: "schedule_update".into(),
                description: "Change a plan's title, goal or schedule. Changes wait for the user's confirmation in the app.".into(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "plan_id": plan_id,
                        "title": { "type": "string" },
                        "goal": { "type": "string" },
                        "schedule": spec_schema()
                    },
                    "required": ["plan_id"]
                }),
            },
            PlatformTool {
                name: "schedule_cancel".into(),
                description: "Cancel (delete) a plan.".into(),
                input_schema: json!({
                    "type": "object",
                    "properties": { "plan_id": plan_id },
                    "required": ["plan_id"]
                }),
            },
        ]
    }

    async fn call(&self, ctx: &ToolContext, name: &str, arguments: &Value) -> ToolOutput {
        let result = match name {
            "schedule_list" => self.list(ctx).await,
            "schedule_create" => match parse(arguments) {
                Ok(a) => self.create(ctx, a).await,
                Err(e) => Err(e),
            },
            "schedule_update" => match parse(arguments) {
                Ok(a) => self.update(ctx, a).await,
                Err(e) => Err(e),
            },
            "schedule_cancel" => match parse(arguments) {
                Ok(a) => self.cancel(ctx, a).await,
                Err(e) => Err(e),
            },
            other => Err(Fail(format!("unknown platform tool {other}"))),
        };
        match result {
            Ok(v) => ToolOutput::text(v.to_string()),
            Err(Fail(m)) => ToolOutput::error(m),
        }
    }
}
