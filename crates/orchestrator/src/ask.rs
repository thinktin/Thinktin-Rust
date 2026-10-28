//! 问队友（WBS 8.11）：agent 用平台工具 `ask` 问同一用户的另一个 agent 一个问题。
//!
//! - 问题是提问方运行下的一个子运行（来源 `ask`），在对方的实例上跑、接着对方的会话：对方暂停着就先唤醒，
//!   正忙就排在它这一轮后面。对方用它自己实例的授权、模型 key、预授权范围和审批规则（问的是信息，不是权限）；
//!   花的 token 计入提问方那棵运行树的共享预算（8.6）。
//! - 和委派一样，工具立刻返回。提问方这一轮结束时还有没回的问题，就转入“等待子任务”（等待原因是等回答）、
//!   放掉租约；回答都到了（或者超时了）作为一条新消息交还给它。
//! - 护栏：只能问 `agents_list` 看得到的（同一用户、没关“允许其他 agent 查我、问我”）；对方（直接或间接地）
//!   在等自己时不许问（“谁在等谁”和委派共用，按用户加锁检查）；一次运行最多问 [`MAX_ASKS_PER_RUN`] 次，
//!   回答时再问别人最多 [`MAX_DEPTH`] 层；[`ANSWER_TIMEOUT`] 内没答完的由后台取消，交还“对方没回答”。
//! - 问题送进对方会话之前抹掉用户保险箱里的值，免得密码经提问到了别的 agent 手里。

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use keyvault::Kms;
use proto::domain::RunSource;
use proto::shim::PlatformTool;
use serde::Deserialize;
use serde_json::{Value, json};
use store::{Db, NewRun};

use crate::shim::{PlatformTools, ToolContext, ToolOutput};

pub const ASK_TOOLS: [&str; 1] = ["ask"];

/// 一次运行最多问这么多次。
pub const MAX_ASKS_PER_RUN: usize = 5;
/// 回答问题时还能再问别人，最多这么多层（A 问 B，B 回答时问 C，C 就不能再问了）。
pub const MAX_DEPTH: usize = 2;
/// 过了这么久还没答完（排队等对方的时间也算），按“对方没回答”交还。
pub const ANSWER_TIMEOUT: Duration = Duration::from_secs(30 * 60);
/// 问题最长这么多字。
const MAX_QUESTION_CHARS: usize = 4000;
/// 回答方出错时重试一次。
const ANSWER_ATTEMPTS: u32 = 2;

pub struct AskTools {
    db: Db,
    kms: Arc<dyn Kms>,
}

impl AskTools {
    pub fn new(db: Db, kms: Arc<dyn Kms>) -> Self {
        Self { db, kms }
    }

    async fn ask(&self, ctx: &ToolContext, args: AskArgs) -> Result<Value, String> {
        let question: String = args
            .question
            .trim()
            .chars()
            .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
            .collect();
        if question.is_empty() || question.chars().count() > MAX_QUESTION_CHARS {
            return Err(format!(
                "question must be 1-{MAX_QUESTION_CHARS} characters"
            ));
        }
        let to = args.to.trim();
        let mut t = self.db.tenant(ctx.user).await.map_err(internal)?;
        let peers = t.peers(ctx.instance).await.map_err(internal)?;
        let me = t.instance(ctx.instance).await.map_err(internal)?;
        t.rollback().await.map_err(internal)?;
        // 关了开关的和不存在的回答一样：看不出它在不在（8.9）。
        let Some(peer) = peers
            .into_iter()
            .find(|p| p.instance.id.to_string() == to || p.instance.name == to)
        else {
            return Err(format!(
                "no agent called {to:?} that you can see; agents_list shows the ones you can"
            ));
        };
        let target = peer.instance;
        let scrubber = crate::vault::user_scrubber(&self.db, self.kms.clone(), ctx.user).await;
        let question = scrubber.scrub(&question).unwrap_or(question);

        let mut w = self.db.worker().await.map_err(internal)?;
        w.lock_run_waits(ctx.user).await.map_err(internal)?;
        let chain = w.run_chain(ctx.run).await.map_err(internal)?;
        let depth = chain
            .iter()
            .filter(|(_, _, source)| *source == RunSource::Ask)
            .count();
        if depth >= MAX_DEPTH {
            return Err(
                "you are answering a question that was itself asked while answering one; \
                 answer with what you know instead of asking further"
                    .into(),
            );
        }
        if w.instance_waits_for(target.id, ctx.run)
            .await
            .map_err(internal)?
        {
            return Err(format!(
                "{} is waiting (directly or through other agents) for you to finish, so it cannot \
                 answer now; asking it would deadlock. Go on without it",
                target.name
            ));
        }
        // 对方得有自己的授权（用户“全部停止”以后要等用户再给它发消息才重新签发）：没有的话问了也答不了。
        if w.active_grant_for_instance(target.id)
            .await
            .map_err(internal)?
            .is_none()
        {
            return Err(format!(
                "{} cannot take questions right now (the user stopped it)",
                target.name
            ));
        }
        if w.ask_runs(ctx.run).await.map_err(internal)?.len() >= MAX_ASKS_PER_RUN {
            return Err(format!(
                "at most {MAX_ASKS_PER_RUN} questions per task; put what you still need into one question"
            ));
        }
        let parent = w.run_record(ctx.run).await.map_err(internal)?;
        let locale = w.user_locale(ctx.user).await.map_err(internal)?;
        let prompt = crate::texts::ask_question(locale, &me.name, &question);
        let mut new = NewRun::new(
            target.id,
            RunSource::Ask,
            prompt,
            target.agent_version.clone(),
        );
        new.parent_run_id = Some(ctx.run);
        // 计划、授权不带过去：对方按它自己的预授权和审批规则回答（问的是信息，不是权限）。
        new.plan_id = None;
        new.run_grant_id = None;
        // 预算整棵树共用（8.6）。
        new.budget = parent.budget;
        new.max_attempts = ANSWER_ATTEMPTS;
        new.answer_deadline = Some(Utc::now() + ANSWER_TIMEOUT);
        let child = w
            .create_run(ctx.user, &new)
            .await
            .map_err(internal)?
            .ok_or_else(|| "could not send the question".to_owned())?;
        w.append_event(
            ctx.instance,
            Some(ctx.run),
            "ask.sent",
            &json!({
                "child_run_id": child.id,
                "instance_id": target.id,
                "to": target.name,
                "question": first_line(&question, 80),
            }),
        )
        .await
        .map_err(internal)?;
        w.commit().await.map_err(internal)?;
        let minutes = ANSWER_TIMEOUT.as_secs() / 60;
        let mut next = format!(
            "Keep working on other parts if you like. When you end your turn, the platform waits for the \
             answer (at most {minutes} minutes) and sends it to you as a new message. Asking the same \
             question again in this task only returns this result."
        );
        if peer.holder.is_some() {
            next.insert_str(
                0,
                &format!(
                    "{} is busy, so the question waits until it finishes its current task. ",
                    target.name
                ),
            );
        }
        Ok(json!({
            "run_id": child.id,
            "to": target.name,
            "status": "asked",
            "next": next,
        }))
    }
}

#[derive(Deserialize)]
struct AskArgs {
    /// 名字或实例 id。
    to: String,
    question: String,
}

/// 第一行，最多 `max` 个字。
fn first_line(s: &str, max: usize) -> String {
    let line = s.lines().next().unwrap_or_default().trim();
    let mut out: String = line.chars().take(max).collect();
    if line.chars().count() > max {
        out.push('…');
    }
    out
}

fn internal(e: impl std::fmt::Display) -> String {
    tracing::warn!(error = %e, "ask tool failed");
    "internal error, try again later".into()
}

#[async_trait]
impl PlatformTools for AskTools {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![PlatformTool {
            name: "ask".into(),
            description: "Ask another of the user's agents a question (see agents_list). It returns at once; when you end your turn the platform waits for the answer and sends it to you as a new message. The other agent is woken if paused and answers after its current task if busy. Use it for information you cannot find yourself; it cannot approve or do anything for you.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "to": { "type": "string", "description": "Name or instance_id from agents_list" },
                    "question": { "type": "string", "description": "The question, with the context the other agent needs to answer it" }
                },
                "required": ["to", "question"]
            }),
        }]
    }

    async fn call(&self, ctx: &ToolContext, name: &str, arguments: &Value) -> ToolOutput {
        let result = match name {
            "ask" => match serde_json::from_value::<AskArgs>(arguments.clone()) {
                Ok(a) => self.ask(ctx, a).await,
                Err(e) => Err(format!("bad arguments: {e}")),
            },
            other => Err(format!("unknown platform tool {other}")),
        };
        match result {
            Ok(v) => ToolOutput::text(v.to_string()),
            Err(m) => ToolOutput::error(m),
        }
    }
}
