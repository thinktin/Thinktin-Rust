//! 平台工具：`thinktin.schedule`（WBS 7.8）和 `thinktin.artifacts`（8.4）。
//!
//! `thinktin.schedule`，让 agent 在平台上登记、查看、修改、取消计划，
//! 代替 agent 自带的定时功能（架构方案 4.9）。agent 看到的名字是 `mcp__thinktin__schedule_*` 之类。
//!
//! agent 不可信（可能被网页、邮件里的内容诱导），而计划会在没人看着的时候用用户的 key 反复运行，所以：
//! - agent 新建或修改的计划先处于暂停状态，推送提醒用户，用户在 App 里确认（恢复）后才生效；
//! - agent 只能动自己实例上的计划；取消（删除）不需要确认；
//! - 触发频率受和接口一样的下限约束。

use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use notify::PushKind;
use proto::domain::{CatchUp, Plan, PlanAuthor, PlanId, PlanPolicy, ScheduleSpec};
use proto::shim::PlatformTool;
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Db, NewPlan, Tenant, Tx};

use crate::outbox::{Notice, notify_tenant};
use crate::schedule::Schedule;
use crate::shim::{PlatformTools, ToolContext, ToolOutput};

pub const SCHEDULE_TOOLS: [&str; 4] = [
    "schedule_list",
    "schedule_create",
    "schedule_update",
    "schedule_cancel",
];

/// 一个实例上 agent 建的计划（没删除的）最多这么多。
const MAX_AGENT_PLANS: u64 = 20;
/// 一次运行里 agent 最多新建、修改这么多次计划（每次都会给用户发确认提醒）。
const MAX_PLAN_CHANGES_PER_RUN: u64 = 10;

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
    // NUL 存不进 Postgres 的文本列，其他控制字符会污染推送和界面（换行、制表符除外）。
    if v.chars().any(|c| c.is_control() && c != '\n' && c != '\t') {
        return Err(Fail(format!("{field} contains control characters")));
    }
    Ok(())
}

impl ScheduleTools {
    fn next_fire(&self, spec: &ScheduleSpec) -> Result<chrono::DateTime<Utc>, Fail> {
        let now = Utc::now();
        let s = Schedule::parse_new(spec, now).map_err(|e| Fail(e.to_string()))?;
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

    /// 一次运行里改计划的次数有上限：每次改动都会给用户发确认提醒。
    async fn check_change_quota(t: &mut Tx<Tenant>, ctx: &ToolContext) -> Result<(), Fail> {
        if t.run_event_count(ctx.run, "plan.needs_confirmation")
            .await?
            >= MAX_PLAN_CHANGES_PER_RUN
        {
            return Err(Fail(format!(
                "this run already created or changed {MAX_PLAN_CHANGES_PER_RUN} plans; wait for the user"
            )));
        }
        Ok(())
    }

    /// 计划改动后等用户确认：暂停、版本号加一，并推送提醒。用户确认时要带上看到的版本。
    async fn ask_to_confirm(
        t: &mut Tx<Tenant>,
        ctx: &ToolContext,
        plan: &Plan,
        what: &str,
    ) -> Result<(), Fail> {
        t.request_plan_confirmation(plan.id).await?;
        let notice = Notice {
            instance: Some(ctx.instance),
            run: Some(ctx.run),
            plan: Some(plan.id),
            thread_id: Some(plan.id.to_string()),
            collapse_id: Some(format!("plan-confirm:{}", plan.id)),
            // 计划标题是 agent 起的。
            ai_generated: true,
            ..Notice::new(
                PushKind::Info,
                "agent 想安排一个计划",
                format!(
                    "{what}「{}」，确认后才会按时运行",
                    plan.title.chars().take(40).collect::<String>()
                ),
            )
        };
        notify_tenant(t, &notice).await?;
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
        let mut t = self.db.tenant(ctx.user).await?;
        Self::check_change_quota(&mut t, ctx).await?;
        if t.agent_plan_count(ctx.instance).await? >= MAX_AGENT_PLANS {
            return Err(Fail(format!(
                "this agent already has {MAX_AGENT_PLANS} plans; ask the user to remove some first"
            )));
        }
        // 预算沿用发起调用的这次运行，不比它宽。
        let policy = PlanPolicy {
            budget: t.run_budget(ctx.run).await?,
            ..PlanPolicy::default()
        };
        let plan = t
            .create_plan(&NewPlan {
                instance_id: ctx.instance,
                title: args.title.trim().into(),
                goal: args.goal.trim().into(),
                policy,
                catch_up: args.catch_up,
                created_by: PlanAuthor::Agent,
                run_grant_id: None,
            })
            .await?;
        // 计划的授权从发起调用的运行的授权收窄出来：范围相同、有效期不超过它，吊销它时一起失效。
        // 用户确认计划时换成正式的授权。
        let grant = t
            .create_plan_child_grant(ctx.grant, ctx.instance, plan.id, self.grant_ttl)
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
        Self::check_change_quota(&mut t, ctx).await?;
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

// ---------- 组合 ----------

/// 把几组平台工具合在一起，按工具名分派。
pub struct ToolSet {
    providers: Vec<std::sync::Arc<dyn PlatformTools>>,
}

impl ToolSet {
    pub fn new(providers: Vec<std::sync::Arc<dyn PlatformTools>>) -> Self {
        Self { providers }
    }
}

#[async_trait]
impl PlatformTools for ToolSet {
    fn tools(&self) -> Vec<PlatformTool> {
        self.providers.iter().flat_map(|p| p.tools()).collect()
    }

    async fn call(&self, ctx: &ToolContext, name: &str, arguments: &Value) -> ToolOutput {
        for p in &self.providers {
            if p.tools().iter().any(|t| t.name == name) {
                return p.call(ctx, name, arguments).await;
            }
        }
        ToolOutput::error(format!("unknown platform tool {name}"))
    }
}

// ---------- thinktin.artifacts（8.4） ----------

pub const ARTIFACT_TOOLS: [&str; 4] = [
    "artifact_publish",
    "artifact_list",
    "artifact_read",
    "artifact_fetch",
];

/// 读给 agent 的文本内容上限（更大的用 artifact_fetch 放进工作区）。
const MAX_INLINE_BYTES: usize = 64 << 10;

pub struct ArtifactTools {
    db: Db,
    store: std::sync::Arc<crate::artifacts::ArtifactStore>,
    provider: std::sync::Arc<dyn sandbox::SandboxProvider>,
    /// agent 工作区在沙箱里的目录（相对沙箱根）。
    workdir: String,
}

impl ArtifactTools {
    pub fn new(
        db: Db,
        store: std::sync::Arc<crate::artifacts::ArtifactStore>,
        provider: std::sync::Arc<dyn sandbox::SandboxProvider>,
        workdir: impl Into<String>,
    ) -> Self {
        Self {
            db,
            store,
            provider,
            workdir: workdir.into(),
        }
    }

    async fn origin(
        &self,
        ctx: &ToolContext,
    ) -> Result<(crate::artifacts::Origin, Option<String>), Fail> {
        let mut w = self.db.worker().await?;
        let rec = w.run_record(ctx.run).await?;
        let rt = w.instance_runtime(ctx.instance).await?;
        w.rollback().await?;
        Ok((
            crate::artifacts::Origin {
                user: ctx.user,
                instance: ctx.instance,
                run: ctx.run,
                root: rec.run.root_run_id,
            },
            rt.sandbox_id,
        ))
    }

    fn workspace_path(&self, rel: &str) -> Result<String, Fail> {
        sandbox::check_relative_path(rel).map_err(|e| Fail(e.to_string()))?;
        Ok(format!("{}/{rel}", self.workdir))
    }

    async fn publish(&self, ctx: &ToolContext, args: &Value) -> Result<Value, Fail> {
        #[derive(Deserialize)]
        struct A {
            name: String,
            path: Option<String>,
            content: Option<String>,
            content_type: Option<String>,
        }
        let a: A = parse(args)?;
        let (origin, sandbox) = self.origin(ctx).await?;
        let (bytes, default_type) = match (&a.path, &a.content) {
            (Some(path), None) => {
                let sid = sandbox.ok_or_else(|| Fail("the sandbox is not running".into()))?;
                let bytes = self
                    .provider
                    .read_file(
                        &sandbox::SandboxId(sid),
                        &self.workspace_path(path)?,
                        crate::artifacts::MAX_ARTIFACT_BYTES as u64,
                    )
                    .await
                    .map_err(|e| Fail(format!("reading {path}: {e}")))?;
                (bytes, "application/octet-stream")
            }
            (None, Some(text)) => (text.clone().into_bytes(), "text/plain; charset=utf-8"),
            _ => return Err(Fail("give exactly one of path or content".into())),
        };
        let content_type = a.content_type.as_deref().unwrap_or(default_type);
        let stored = self
            .store
            .publish(origin, a.name.trim(), content_type, &bytes)
            .await
            .map_err(|e| match e {
                crate::artifacts::ArtifactError::Invalid(m)
                | crate::artifacts::ArtifactError::Store(store::Error::Invalid(m)) => Fail(m),
                other => {
                    tracing::error!(error = %other, "publishing an artifact failed");
                    Fail("could not store the artifact, try again later".into())
                }
            })?;
        Ok(json!({
            "artifact_id": stored.artifact.id,
            "name": stored.artifact.name,
            "version": stored.artifact.version,
            "size": stored.artifact.size,
        }))
    }

    async fn list(&self, ctx: &ToolContext) -> Result<Value, Fail> {
        let (origin, _) = self.origin(ctx).await?;
        let mut w = self.db.worker().await?;
        let items = w.tree_artifacts(origin.root).await?;
        w.rollback().await?;
        let list: Vec<Value> = items
            .into_iter()
            .map(|a| {
                json!({
                    "name": a.artifact.name,
                    "version": a.artifact.version,
                    "size": a.artifact.size,
                    "content_type": a.artifact.content_type,
                    "from_run": a.artifact.run_id,
                })
            })
            .collect();
        Ok(json!({ "artifacts": list }))
    }

    async fn find(
        &self,
        ctx: &ToolContext,
        args: &Value,
    ) -> Result<(store::StoredArtifact, Value), Fail> {
        let (origin, _) = self.origin(ctx).await?;
        let name = args
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| Fail("name is required".into()))?;
        let version = args
            .get("version")
            .and_then(Value::as_u64)
            .map(|v| u32::try_from(v).unwrap_or(u32::MAX));
        let mut w = self.db.worker().await?;
        let a = w
            .named_artifact(origin.root, name, version)
            .await
            .map_err(|e| match e {
                store::Error::NotFound => Fail(format!("no artifact named {name:?} in this task")),
                other => other.into(),
            })?;
        w.rollback().await?;
        Ok((a, args.clone()))
    }

    async fn read(&self, ctx: &ToolContext, args: &Value) -> Result<Value, Fail> {
        let (a, _) = self.find(ctx, args).await?;
        if a.artifact.size as usize > MAX_INLINE_BYTES {
            return Err(Fail(format!(
                "{} is {} bytes; use artifact_fetch to copy it into the workspace",
                a.artifact.name, a.artifact.size
            )));
        }
        let bytes = self
            .store
            .read(&a)
            .await
            .map_err(|_| Fail("could not read the artifact, try again later".into()))?;
        let text = String::from_utf8(bytes)
            .map_err(|_| Fail("the artifact is binary; use artifact_fetch".into()))?;
        Ok(json!({ "name": a.artifact.name, "version": a.artifact.version, "content": text }))
    }

    async fn fetch(&self, ctx: &ToolContext, args: &Value) -> Result<Value, Fail> {
        let (a, args) = self.find(ctx, args).await?;
        let rel = args
            .get("path")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| format!("handoff/{}", a.artifact.name));
        let target = self.workspace_path(&rel)?;
        let (_, sandbox) = self.origin(ctx).await?;
        let sid = sandbox.ok_or_else(|| Fail("the sandbox is not running".into()))?;
        let bytes = self
            .store
            .read(&a)
            .await
            .map_err(|_| Fail("could not read the artifact, try again later".into()))?;
        self.provider
            .write_file(&sandbox::SandboxId(sid), &target, &bytes)
            .await
            .map_err(|e| Fail(format!("writing {rel}: {e}")))?;
        Ok(json!({ "name": a.artifact.name, "version": a.artifact.version, "path": rel }))
    }
}

#[async_trait]
impl PlatformTools for ArtifactTools {
    fn tools(&self) -> Vec<PlatformTool> {
        let name = json!({ "type": "string", "description": "Artifact name, like report.md" });
        let version = json!({ "type": "integer", "description": "Version (default latest)" });
        vec![
            PlatformTool {
                name: "artifact_publish".into(),
                description: "Publish a result of this task as an artifact so later steps and other agents can use it. Give either `content` (text) or `path` (a file in your workspace). Publishing the same name again creates a new version.".into(),
                input_schema: json!({
                    "type": "object",
                    "properties": {
                        "name": name,
                        "content": { "type": "string" },
                        "path": { "type": "string", "description": "File path relative to your workspace" },
                        "content_type": { "type": "string" }
                    },
                    "required": ["name"]
                }),
            },
            PlatformTool {
                name: "artifact_list".into(),
                description: "List the artifacts published in this task (including by upstream steps and other agents).".into(),
                input_schema: json!({ "type": "object", "properties": {} }),
            },
            PlatformTool {
                name: "artifact_read".into(),
                description: "Read a small text artifact (up to 64 KB).".into(),
                input_schema: json!({ "type": "object", "properties": { "name": name, "version": version }, "required": ["name"] }),
            },
            PlatformTool {
                name: "artifact_fetch".into(),
                description: "Copy an artifact into your workspace (default handoff/<name>).".into(),
                input_schema: json!({
                    "type": "object",
                    "properties": { "name": name, "version": version, "path": { "type": "string" } },
                    "required": ["name"]
                }),
            },
        ]
    }

    async fn call(&self, ctx: &ToolContext, name: &str, arguments: &Value) -> ToolOutput {
        let result = match name {
            "artifact_publish" => self.publish(ctx, arguments).await,
            "artifact_list" => self.list(ctx).await,
            "artifact_read" => self.read(ctx, arguments).await,
            "artifact_fetch" => self.fetch(ctx, arguments).await,
            other => Err(Fail(format!("unknown platform tool {other}"))),
        };
        match result {
            Ok(v) => ToolOutput::text(v.to_string()),
            Err(Fail(m)) => ToolOutput::error(m),
        }
    }
}
