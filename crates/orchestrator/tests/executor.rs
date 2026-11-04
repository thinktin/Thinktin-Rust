//! 执行器：用进程内的 shim 替身（按提示词决定行为）+ 本地沙箱后端 + 真实 Postgres。
//! 没有 DATABASE_URL 时跳过。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use auth::grants::{GrantConfig, GrantService};
use auth::sandbox_token::SandboxTokenIssuer;
use control::{BuiltinTemplates, Lifecycle, LifecycleConfig};
use orchestrator::ask::{ASK_TOOLS, AskTools, MAX_ASKS_PER_RUN};
use orchestrator::computer::DeviceCalls;
use orchestrator::delegate::{DELEGATE_TOOLS, DelegateTools, MAX_CHILDREN_PER_RUN};
use orchestrator::executor::{Executor, ExecutorConfig};
use orchestrator::shim::{
    ConnectError, NoPlatformTools, PlatformTools, ShimConnector, ShimLaunch, ShimProcess,
    ShimSession, ToolContext, ToolOutput,
};
use proto::domain::{
    CatchUp, DevicePlatform, GrantScope, Instance, PlanAuthor, PlanPolicy, RunBudget, RunId,
    RunSource, RunState, TeamMember, TeamRole, UserId,
};
use proto::shim::{
    DecisionSource, PermissionKind, PermissionOption, PlatformTool, ShimCommand, ShimEvent,
    StopReason,
};
use sandbox::local::LocalProvider;
use serde_json::{Value, json};
use store::testing::TestDb;
use store::{NewPlan, NewRun, NewUsage};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;

// ---------- shim 替身 ----------

#[derive(Default)]
struct Recorded {
    launches: Vec<(String, Vec<String>, Vec<String>)>,
    prompts: Vec<String>,
    /// 就绪时说接回了之前的会话。
    restore_sessions: bool,
    /// 收到子任务结果、队友回答的这么多次里，这一轮一开始就崩溃。
    crash_on_results: u32,
    /// “slowly” 的提示词等它放行（测试在这一轮中间做完要做的事再放行），最多等 5 秒。
    gate: Option<Arc<tokio::sync::Notify>>,
}

#[derive(Default, Clone)]
struct FakeConnector {
    rec: Arc<Mutex<Recorded>>,
}

struct FakeProcess(Option<JoinHandle<()>>);

#[async_trait]
impl ShimProcess for FakeProcess {
    async fn wait(&mut self) {
        if let Some(h) = self.0.as_mut() {
            let _ = h.await;
            self.0 = None;
        }
    }
    async fn kill(&mut self) {
        if let Some(h) = self.0.take() {
            h.abort();
        }
    }
}

#[async_trait]
impl ShimConnector for FakeConnector {
    async fn start(&self, launch: &ShimLaunch) -> Result<ShimSession, ConnectError> {
        self.rec.lock().unwrap().launches.push((
            launch.token.clone(),
            launch.allow_tools.clone(),
            launch
                .platform_tools
                .iter()
                .map(|t| t.name.clone())
                .collect(),
        ));
        let (cmd_tx, cmd_rx) = mpsc::channel(16);
        let (ev_tx, ev_rx) = mpsc::channel(64);
        let rec = self.rec.clone();
        let task = tokio::spawn(fake_shim(cmd_rx, ev_tx, rec));
        Ok(ShimSession {
            commands: cmd_tx,
            events: ev_rx,
            process: Box::new(FakeProcess(Some(task))),
        })
    }
}

fn chunk(run: &str, text: &str) -> ShimEvent {
    ShimEvent::MessageChunk {
        run_id: Some(run.into()),
        text: text.into(),
    }
}

fn tool_call(run: &str, i: u32) -> ShimEvent {
    ShimEvent::ToolCall {
        run_id: Some(run.into()),
        tool_call_id: format!("t{i}"),
        title: Some("Read file".into()),
        kind: Some("read".into()),
        status: Some("completed".into()),
        raw: Value::Null,
    }
}

fn ended(run: &str, stop_reason: StopReason) -> ShimEvent {
    ShimEvent::TurnEnded {
        run_id: run.into(),
        stop_reason,
    }
}

/// 调平台工具 delegate，把结果当作回复，结束这一轮。
async fn delegate_call(
    ev: &mpsc::Sender<ShimEvent>,
    cmds: &mut mpsc::Receiver<ShimCommand>,
    run_id: &str,
    to: &str,
    task: &str,
) {
    let _ = ev
        .send(ShimEvent::PlatformToolCall {
            run_id: run_id.into(),
            call_id: "d1".into(),
            name: "delegate".into(),
            arguments: json!({ "to": to, "task": task, "title": "subtask" }),
        })
        .await;
    while let Some(c) = cmds.recv().await {
        if let ShimCommand::PlatformToolResult { content, .. } = c {
            let text = content[0]["text"].as_str().unwrap_or_default().to_owned();
            let _ = ev.send(chunk(run_id, &text)).await;
            let _ = ev.send(ended(run_id, StopReason::EndTurn)).await;
            break;
        }
    }
}

/// 调平台工具 ask 问队友（8.11），把结果当作回复，结束这一轮。
async fn ask_call(
    ev: &mpsc::Sender<ShimEvent>,
    cmds: &mut mpsc::Receiver<ShimCommand>,
    run_id: &str,
    to: &str,
    question: &str,
) {
    let _ = ev
        .send(ShimEvent::PlatformToolCall {
            run_id: run_id.into(),
            call_id: "q1".into(),
            name: "ask".into(),
            arguments: json!({ "to": to, "question": question }),
        })
        .await;
    while let Some(c) = cmds.recv().await {
        if let ShimCommand::PlatformToolResult { content, .. } = c {
            let text = content[0]["text"].as_str().unwrap_or_default().to_owned();
            let _ = ev.send(chunk(run_id, &text)).await;
            let _ = ev.send(ended(run_id, StopReason::EndTurn)).await;
            break;
        }
    }
}

/// 一轮里调 `n` 次 delegate（任务各不相同，不会被当成重复调用），把最后一次的结果当作回复，结束这一轮。
async fn fan_out(
    ev: &mpsc::Sender<ShimEvent>,
    cmds: &mut mpsc::Receiver<ShimCommand>,
    run_id: &str,
    n: usize,
) {
    let mut last = String::new();
    for i in 0..n {
        let _ = ev
            .send(ShimEvent::PlatformToolCall {
                run_id: run_id.into(),
                call_id: format!("f{i}"),
                name: "delegate".into(),
                arguments: json!({ "to": "helper", "task": format!("say hello, part {i}") }),
            })
            .await;
        while let Some(c) = cmds.recv().await {
            if let ShimCommand::PlatformToolResult { content, .. } = c {
                last = content[0]["text"].as_str().unwrap_or_default().to_owned();
                break;
            }
        }
    }
    let _ = ev.send(chunk(run_id, &last)).await;
    let _ = ev.send(ended(run_id, StopReason::EndTurn)).await;
}

/// 按提示词里的关键字表演：say hello / need approval / loop forever / crash / use tool。
async fn fake_shim(
    mut cmds: mpsc::Receiver<ShimCommand>,
    ev: mpsc::Sender<ShimEvent>,
    rec: Arc<Mutex<Recorded>>,
) {
    let restored = rec.lock().unwrap().restore_sessions;
    let _ = ev
        .send(ShimEvent::Ready {
            protocol_version: 1,
            agent_id: "claude".into(),
            harness: "acp".into(),
            agent_info: None,
            session_id: "s1".into(),
            session_restored: restored,
        })
        .await;
    let mut looping: Option<String> = None;
    let mut ticks = 0;
    loop {
        let cmd = if let Some(run) = &looping {
            match tokio::time::timeout(Duration::from_millis(30), cmds.recv()).await {
                Ok(c) => c,
                Err(_) => {
                    ticks += 1;
                    let _ = ev.send(tool_call(run, ticks)).await;
                    continue;
                }
            }
        } else {
            cmds.recv().await
        };
        let Some(cmd) = cmd else { return };
        match cmd {
            ShimCommand::Prompt { run_id, text } => {
                rec.lock().unwrap().prompts.push(text.clone());
                // 打断说明里引用了被打断的任务（8.12）：只按新消息表演。
                let text = match text.split_once("\n\n") {
                    Some((note, message)) if note.starts_with("（打断说明") => {
                        message.to_owned()
                    }
                    _ => text,
                };
                let _ = ev
                    .send(ShimEvent::TurnStarted {
                        run_id: run_id.clone(),
                    })
                    .await;
                let results = text.contains("子任务都结束了") || text.contains("问题有结果了");
                if results && {
                    let mut r = rec.lock().unwrap();
                    let crash = r.crash_on_results > 0;
                    r.crash_on_results = r.crash_on_results.saturating_sub(1);
                    crash
                } {
                    return;
                }
                // 慢一点再开始（给测试留出在这一轮中间做点什么的时间）。
                if text.contains("slowly") {
                    let gate = rec.lock().unwrap().gate.clone();
                    match gate {
                        Some(g) => {
                            let _ =
                                tokio::time::timeout(Duration::from_secs(5), g.notified()).await;
                        }
                        None => tokio::time::sleep(Duration::from_millis(400)).await,
                    }
                }
                if text.contains("子任务都结束了") {
                    // 委派的子任务的结果交回来了（8.7）。
                    let _ = ev.send(chunk(&run_id, "got the results")).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("问题有结果了") {
                    // 问队友的回答交回来了（8.11）。原来的任务说了“没答上就再问”：同一个问题再问一次。
                    let again = text
                        .split_once("ask teammate ")
                        .filter(|_| text.contains("re-ask") && text.contains("对方没有在"))
                        .map(|(_, rest)| rest.split_once(": ").unwrap_or((rest, "say hello")));
                    match again {
                        Some((to, question)) => {
                            let question = question.lines().next().unwrap_or_default().to_owned();
                            ask_call(&ev, &mut cmds, &run_id, to.trim(), &question).await;
                        }
                        None => {
                            let _ = ev.send(chunk(&run_id, "got the answers")).await;
                            let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                        }
                    }
                } else if text.contains("check news") {
                    // 一遍遍调平台工具，直到结果后面捎带了新消息（8.12），把捎带的那段当作回复。
                    let mut said = "no news".to_owned();
                    for i in 0..200 {
                        let _ = ev
                            .send(ShimEvent::PlatformToolCall {
                                run_id: run_id.clone(),
                                call_id: format!("n{i}"),
                                name: "schedule_list".into(),
                                arguments: json!({ "page": i }),
                            })
                            .await;
                        let mut extra = None;
                        while let Some(c) = cmds.recv().await {
                            if let ShimCommand::PlatformToolResult { content, .. } = c {
                                extra = content
                                    .get(1)
                                    .and_then(|b| b["text"].as_str())
                                    .map(str::to_owned);
                                break;
                            }
                        }
                        if let Some(news) = extra {
                            said = news;
                            break;
                        }
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                    let _ = ev.send(chunk(&run_id, &said)).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if let Some((_, rest)) = text.split_once("ask teammate ") {
                    // 问队友（8.11）："ask teammate 名字: 问题"。
                    let (to, question) = rest.split_once(": ").unwrap_or((rest, "say hello"));
                    ask_call(&ev, &mut cmds, &run_id, to.trim(), question).await;
                } else if let Some((_, task)) = text.split_once("lead the team: ") {
                    delegate_call(&ev, &mut cmds, &run_id, "helper", task).await;
                } else if let Some((_, rest)) = text.split_once("relay to ") {
                    // 一层层往下委派（8.8 的深度上限）："relay to 成员: 剩下的任务"。
                    let (to, task) = rest.split_once(": ").unwrap_or((rest, "say hello"));
                    delegate_call(&ev, &mut cmds, &run_id, to.trim(), task).await;
                } else if let Some((_, n)) = text.split_once("fan out ") {
                    // 一轮里委派很多个子任务（8.8 每次运行的上限）。
                    let n = n
                        .split_whitespace()
                        .next()
                        .and_then(|n| n.parse().ok())
                        .unwrap_or(1);
                    fan_out(&ev, &mut cmds, &run_id, n).await;
                } else if text.contains("delegate back") {
                    delegate_call(&ev, &mut cmds, &run_id, "Claude", "anything").await;
                } else if text.contains("say hello") {
                    let _ = ev.send(chunk(&run_id, "Hello")).await;
                    let _ = ev.send(chunk(&run_id, " world")).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("need approval") {
                    let _ = ev.send(tool_call(&run_id, 0)).await;
                    let _ = ev
                        .send(ShimEvent::PermissionRequested {
                            run_id: Some(run_id.clone()),
                            request_id: "p1".into(),
                            title: Some("Delete old reports".into()),
                            options: vec![
                                PermissionOption {
                                    option_id: "allow".into(),
                                    name: "Allow".into(),
                                    kind: PermissionKind::AllowOnce,
                                },
                                PermissionOption {
                                    option_id: "reject".into(),
                                    name: "Reject".into(),
                                    kind: PermissionKind::RejectOnce,
                                },
                            ],
                            tool_call: json!({ "title": "rm reports/*.old" }),
                        })
                        .await;
                    // 等决定。
                    while let Some(c) = cmds.recv().await {
                        if let ShimCommand::PermissionDecision {
                            request_id,
                            option_id,
                        } = c
                        {
                            let _ = ev
                                .send(ShimEvent::PermissionResolved {
                                    run_id: Some(run_id.clone()),
                                    request_id,
                                    option_id: option_id.clone(),
                                    by: DecisionSource::User,
                                })
                                .await;
                            let word = if option_id.as_deref() == Some("allow") {
                                "approved"
                            } else {
                                "rejected"
                            };
                            let _ = ev.send(chunk(&run_id, word)).await;
                            let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                            break;
                        }
                    }
                } else if text.contains("nul") {
                    // agent 回复里夹着 NUL（比如转述的网页标题）：存不进 Postgres，不能让收尾失败。
                    let _ = ev.send(chunk(&run_id, "done\u{0}here")).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("flood") {
                    // 失控的 agent：一大段回复，再夹着工具调用不停输出。
                    let big = "z".repeat(200 << 10);
                    for i in 0..20 {
                        let _ = ev.send(chunk(&run_id, &big)).await;
                        let _ = ev.send(tool_call(&run_id, i)).await;
                    }
                    let _ = ev.send(chunk(&run_id, &big)).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("loop forever") {
                    looping = Some(run_id);
                } else if text.contains("use vault") {
                    // 沙箱里的助手要保险箱里的值，命令把它打印了出来。
                    let _ = ev
                        .send(ShimEvent::VaultReveal {
                            run_id: run_id.clone(),
                            call_id: "v1".into(),
                            refs: vec!["github".into(), "github.username".into()],
                        })
                        .await;
                    while let Some(c) = cmds.recv().await {
                        if let ShimCommand::VaultValues { values, error, .. } = c {
                            let text = match error {
                                Some(e) => format!("error: {e}"),
                                None => format!("got {} for {}", values.0[0], values.0[1]),
                            };
                            let _ = ev
                                .send(ShimEvent::ToolCallUpdate {
                                    run_id: Some(run_id.clone()),
                                    tool_call_id: "t1".into(),
                                    status: Some("completed".into()),
                                    raw: json!({ "content": [{ "type": "text", "text": text }] }),
                                })
                                .await;
                            let _ = ev.send(chunk(&run_id, &text)).await;
                            let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                            break;
                        }
                    }
                } else if text.contains("broken key") && !text.contains("续跑说明") {
                    // 模型调用一直失败（测试往用量表里写失败记录），agent 卡着重试，直到被取消。
                    while let Some(c) = cmds.recv().await {
                        match c {
                            ShimCommand::Cancel { run_id } => {
                                let _ = ev.send(ended(&run_id, StopReason::Cancelled)).await;
                                break;
                            }
                            ShimCommand::Shutdown => return,
                            _ => {}
                        }
                    }
                } else if text.contains("gives up") {
                    // 模型调用失败几次以后 agent 自己放弃这一轮（测试在这期间写失败记录）。
                    tokio::time::sleep(Duration::from_millis(1500)).await;
                    let _ = ev.send(chunk(&run_id, "API Error: 429")).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("broken key") {
                    // 补上 key 以后接着跑。
                    let _ = ev.send(chunk(&run_id, "back to work")).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if text.contains("publish twice") {
                    // 同样的参数调两次有副作用的工具，再换个参数调一次（7.13）。
                    let mut got = Vec::new();
                    for name in ["a", "a", "b"] {
                        let _ = ev
                            .send(ShimEvent::PlatformToolCall {
                                run_id: run_id.clone(),
                                call_id: format!("c{}", got.len()),
                                name: "artifact_publish".into(),
                                arguments: json!({ "name": name }),
                            })
                            .await;
                        while let Some(c) = cmds.recv().await {
                            if let ShimCommand::PlatformToolResult { content, .. } = c {
                                got.push(
                                    content[0]["text"].as_str().unwrap_or_default().to_owned(),
                                );
                                break;
                            }
                        }
                    }
                    let _ = ev.send(chunk(&run_id, &got.join("|"))).await;
                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                } else if let Some((_, tool)) = text.split_once("use computer: ") {
                    // 用电脑上的工具（14.2），把结果（或错误）当作回复。电脑不在线时执行器还会取消这一轮。
                    let tool = tool
                        .split_whitespace()
                        .next()
                        .unwrap_or_default()
                        .to_owned();
                    let _ = ev
                        .send(ShimEvent::PlatformToolCall {
                            run_id: run_id.clone(),
                            call_id: "pc1".into(),
                            name: tool,
                            arguments: json!({ "path": "/Users/a/notes.md" }),
                        })
                        .await;
                    while let Some(c) = cmds.recv().await {
                        match c {
                            ShimCommand::PlatformToolResult {
                                content, is_error, ..
                            } => {
                                let text = content[0]["text"].as_str().unwrap_or_default();
                                let reply = if is_error {
                                    format!("error: {text}")
                                } else {
                                    text.to_owned()
                                };
                                let _ = ev.send(chunk(&run_id, &reply)).await;
                                if !reply.contains("offline") {
                                    let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                                    break;
                                }
                            }
                            ShimCommand::Cancel { run_id } => {
                                let _ = ev.send(ended(&run_id, StopReason::Cancelled)).await;
                                break;
                            }
                            ShimCommand::Shutdown => return,
                            _ => {}
                        }
                    }
                } else if text.contains("crash") {
                    return;
                } else if text.contains("use tool") {
                    // 被攻破的 shim 可以调没告诉它的工具。
                    let name = if text.contains("forged") {
                        "delegate"
                    } else {
                        "schedule_list"
                    };
                    let _ = ev
                        .send(ShimEvent::PlatformToolCall {
                            run_id: run_id.clone(),
                            call_id: "c1".into(),
                            name: name.into(),
                            arguments: json!({ "limit": 1 }),
                        })
                        .await;
                    while let Some(c) = cmds.recv().await {
                        if let ShimCommand::PlatformToolResult { content, .. } = c {
                            let text = content[0]["text"].as_str().unwrap_or_default().to_owned();
                            let _ = ev.send(chunk(&run_id, &text)).await;
                            let _ = ev.send(ended(&run_id, StopReason::EndTurn)).await;
                            break;
                        }
                    }
                }
            }
            ShimCommand::Cancel { run_id } => {
                looping = None;
                let _ = ev.send(ended(&run_id, StopReason::Cancelled)).await;
            }
            ShimCommand::Shutdown => return,
            _ => {}
        }
    }
}

const KMS_KEY: [u8; 32] = [9; 32];

fn kms() -> Arc<dyn keyvault::Kms> {
    Arc::new(keyvault::LocalKms::new("kms1", &KMS_KEY))
}

/// 只声明 vault_list：授权里有它，沙箱里的助手才能要值。
struct VaultStub;

#[async_trait]
impl PlatformTools for VaultStub {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![PlatformTool {
            name: "vault_list".into(),
            description: "List vault items".into(),
            input_schema: json!({ "type": "object" }),
        }]
    }
    async fn call(&self, _ctx: &ToolContext, name: &str, _args: &Value) -> ToolOutput {
        ToolOutput::text(name)
    }
}

struct Tools;

#[async_trait]
impl PlatformTools for Tools {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![
            PlatformTool {
                name: "schedule_list".into(),
                description: "List schedules".into(),
                input_schema: json!({ "type": "object" }),
            },
            PlatformTool {
                name: "delegate".into(),
                description: "Delegate".into(),
                input_schema: json!({ "type": "object" }),
            },
        ]
    }
    async fn call(&self, ctx: &ToolContext, name: &str, _args: &Value) -> ToolOutput {
        ToolOutput::text(format!("{name} for run {}", ctx.run))
    }
}

// ---------- 环境 ----------

struct Env {
    t: TestDb,
    _dir: tempfile::TempDir,
    lifecycle: Arc<Lifecycle>,
    exec: Arc<Executor>,
    fake: FakeConnector,
    user: UserId,
    instance: Instance,
}

async fn env_with(
    cfg: ExecutorConfig,
    scope: Option<GrantScope>,
    tools: Arc<dyn PlatformTools>,
) -> Option<Env> {
    env_full(cfg, scope, tools, false).await
}

/// 带电脑工具（14.2）的执行器：调用写进库里，由测试扮演的电脑（[`fake_computer`]）领走、回结果。
async fn env_computer() -> Option<Env> {
    let scope = GrantScope {
        platform_tools: proto::computer::names().map(String::from).collect(),
        ..GrantScope::default()
    };
    env_full(fast(), Some(scope), Arc::new(NoPlatformTools), true).await
}

async fn env_full(
    cfg: ExecutorConfig,
    scope: Option<GrantScope>,
    tools: Arc<dyn PlatformTools>,
    computer: bool,
) -> Option<Env> {
    let t = TestDb::new().await?;
    let dir = tempfile::tempdir().unwrap();
    let provider = Arc::new(LocalProvider::new(dir.path()).unwrap());
    let lifecycle = Arc::new(Lifecycle::new(
        t.db.clone(),
        provider,
        Arc::new(BuiltinTemplates),
        LifecycleConfig::default(),
    ));
    let grants = Arc::new(GrantService::new(
        t.db.clone(),
        GrantConfig::default(),
        SandboxTokenIssuer::generate("s1").unwrap(),
    ));
    let mut w = t.db.worker().await.unwrap();
    let (user, _) = w.upsert_user_by_phone("+8613800000001").await.unwrap();
    w.commit().await.unwrap();
    let instance = lifecycle
        .adopt(user.id, "user:d", "claude", None, "Claude")
        .await
        .unwrap();
    if let Some(scope) = scope {
        let mut tx = t.db.tenant(user.id).await.unwrap();
        tx.create_run_grant(instance.id, None, &scope, Duration::from_secs(3600))
            .await
            .unwrap();
        tx.commit().await.unwrap();
    }
    let fake = FakeConnector::default();
    let mut exec = Executor::new(
        t.db.clone(),
        "node-a",
        lifecycle.clone(),
        grants,
        Arc::new(fake.clone()),
        tools,
        cfg,
    )
    .with_vault(kms());
    if computer {
        let calls = Arc::new(DeviceCalls::new(t.db.clone()));
        let listening = calls.clone();
        tokio::spawn(async move { listening.listen(std::future::pending()).await });
        exec = exec.with_computer(calls);
    }
    let exec = Arc::new(exec);
    Some(Env {
        t,
        _dir: dir,
        lifecycle,
        exec,
        fake,
        user: user.id,
        instance,
    })
}

fn fast() -> ExecutorConfig {
    ExecutorConfig {
        renew_every: Duration::from_millis(100),
        approval_poll: Duration::from_millis(50),
        stop_timeout: Duration::from_secs(2),
        ..ExecutorConfig::default()
    }
}

async fn env() -> Option<Env> {
    env_with(
        fast(),
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
}

impl Env {
    async fn queue(&self, prompt: &str, budget: Option<RunBudget>, max_attempts: u32) -> RunId {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let mut new = NewRun::new(
            self.instance.id,
            RunSource::User,
            prompt,
            &self.instance.agent_version,
        );
        if let Some(b) = budget {
            new.budget = b;
        }
        new.max_attempts = max_attempts;
        let run = tx.create_run(&new).await.unwrap();
        tx.commit().await.unwrap();
        run.id
    }

    /// 领取并在后台执行，返回停机信号和任务句柄。
    async fn spawn(&self) -> (watch::Sender<bool>, JoinHandle<()>) {
        let rec = self.exec.claim().await.unwrap().expect("a run to claim");
        let (tx, rx) = watch::channel(false);
        let exec = self.exec.clone();
        (tx, tokio::spawn(async move { exec.execute(rec, rx).await }))
    }

    async fn run_to_end(&self) {
        let (_stop, h) = self.spawn().await;
        tokio::time::timeout(Duration::from_secs(20), h)
            .await
            .unwrap()
            .unwrap();
    }

    async fn state(&self, run: RunId) -> store::RunRecord {
        let mut w = self.t.db.worker().await.unwrap();
        let r = w.run_record(run).await.unwrap();
        w.rollback().await.unwrap();
        r
    }

    async fn wait_state(&self, run: RunId, want: RunState) {
        for _ in 0..200 {
            if self.state(run).await.run.state == want {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("run never reached {want}: {:?}", self.state(run).await.run);
    }

    async fn events(&self, run: RunId) -> Vec<(String, Value)> {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        tx.events_after(self.instance.id, 0, 1000)
            .await
            .unwrap()
            .into_iter()
            .filter(|e| e.run_id == Some(run))
            .map(|e| (e.kind, e.payload))
            .collect()
    }

    async fn inbox(&self) -> Vec<proto::domain::InboxItem> {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let items = tx.inbox(None, 100, false).await.unwrap();
        tx.rollback().await.unwrap();
        items
    }

    async fn outbox_kinds(&self) -> Vec<String> {
        let mut w = self.t.db.worker().await.unwrap();
        let items = w
            .claim_outbox("test", Duration::from_secs(60), 100)
            .await
            .unwrap();
        w.rollback().await.unwrap();
        items
            .into_iter()
            .map(|i| i.payload["kind"].as_str().unwrap_or_default().to_owned())
            .collect()
    }
}

// ---------- 用例 ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_goes_from_queue_to_success_with_a_log_and_a_notification() {
    let Some(e) = env().await else { return };
    let run = e.queue("please say hello", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("Hello world"));
    assert!(rec.run.started_at.is_some() && rec.run.finished_at.is_some());
    assert_eq!(rec.lease_owner, None);

    let events = e.events(run).await;
    let kinds: Vec<&str> = events.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        kinds,
        [
            "agent.ready",
            "agent.turn_started",
            "run.state",
            "agent.message",
            "agent.turn_ended",
            "run.state"
        ]
    );
    let message = events.iter().find(|(k, _)| k == "agent.message").unwrap();
    assert_eq!(message.1["text"], "Hello world", "chunks are coalesced");
    assert_eq!(events.last().unwrap().1["state"], "succeeded");
    // 不在等的时候没有等待原因（事件内容和以前一样）。
    assert!(events.last().unwrap().1.get("wait_code").is_none());
    assert_eq!(e.outbox_kinds().await, ["run_finished"]);
    // 收件箱留一条，推送里带着它的 id。
    let inbox = e.inbox().await;
    assert_eq!(inbox.len(), 1);
    assert_eq!(inbox[0].kind, "run_finished");
    assert_eq!(inbox[0].run_id, Some(run));
    assert_eq!(inbox[0].body, "Hello world");
    assert!(!inbox[0].read);
    let mut w = e.t.db.worker().await.unwrap();
    let pushed = w
        .claim_outbox("test", Duration::from_secs(60), 10)
        .await
        .unwrap();
    w.rollback().await.unwrap();
    assert_eq!(
        pushed[0].payload["target"]["inbox_id"],
        inbox[0].id.to_string()
    );

    // 沙箱令牌经 launch 交给 shim；没有预授权的工具。
    let launch = e.fake.rec.lock().unwrap().launches[0].clone();
    assert!(launch.0.starts_with("tts1."));
    assert!(launch.1.is_empty());
    // 实例被唤醒了。
    let mut w = e.t.db.worker().await.unwrap();
    assert_eq!(
        w.instance_runtime(e.instance.id).await.unwrap().state,
        proto::domain::InstanceState::Running
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn approvals_wait_for_the_user() {
    let Some(e) = env().await else { return };
    let run = e.queue("need approval to clean up", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let pending = tx.pending_approvals().await.unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].title.as_deref(), Some("Delete old reports"));
    assert!(matches!(
        tx.decide_approval(pending[0].id, "bogus", proto::domain::DeviceId::new())
            .await,
        Err(store::Error::Invalid(_))
    ));
    tx.decide_approval(pending[0].id, "allow", proto::domain::DeviceId::new())
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let approval_id = pending[0].id;
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded);
    assert_eq!(rec.run.summary.as_deref(), Some("approved"));
    // 审批事件带上对得上审批记录的键。
    let events = e.events(run).await;
    let payload = |kind: &str| {
        events
            .iter()
            .find(|(k, _)| k == kind)
            .unwrap_or_else(|| panic!("no {kind}"))
            .1
            .clone()
    };
    let asked = payload("agent.permission_requested");
    assert_eq!(
        (
            &asked["attempt"],
            &asked["approval_id"],
            &asked["request_id"]
        ),
        (
            &json!(1),
            &json!(approval_id),
            &json!(pending[0].request_id)
        )
    );
    let resolved = payload("agent.permission_resolved");
    assert_eq!(
        (
            &resolved["attempt"],
            &resolved["approval_id"],
            &resolved["approval_state"]
        ),
        (&json!(1), &json!(approval_id), &json!("approved"))
    );
    // 先有审批请求，再进入等审批。
    let at = |want: &dyn Fn(&(String, Value)) -> bool| events.iter().position(want).unwrap();
    assert!(
        at(&|(k, _)| k == "agent.permission_requested")
            < at(&|(k, p)| k == "run.state" && p["state"] == "waiting_approval")
    );
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(tx.pending_approvals().await.unwrap().is_empty());
    tx.rollback().await.unwrap();
    let kinds = e.outbox_kinds().await;
    assert!(kinds.contains(&"approval".to_string()) && kinds.contains(&"run_finished".to_string()));
    // 审批提醒处理完就算已读；运行结果还没读。
    let inbox = e.inbox().await;
    let approval = inbox.iter().find(|i| i.kind == "approval").unwrap();
    assert!(approval.read && approval.approval_id.is_some());
    let done = inbox.iter().find(|i| i.kind == "run_finished").unwrap();
    assert!(!done.read);
    let states: Vec<String> = e
        .events(run)
        .await
        .into_iter()
        .filter(|(k, _)| k == "run.state")
        .map(|(_, p)| p["state"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        states,
        ["running", "waiting_approval", "running", "succeeded"]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn user_cancellation_stops_the_agent() {
    let Some(e) = env().await else { return };
    let run = e.queue("loop forever", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(run, None).await.unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Cancelled);
    let events = e.events(run).await;
    assert!(
        events
            .iter()
            .any(|(k, p)| k == "agent.turn_ended" && p["stop_reason"] == "cancelled"),
        "the agent's turn was cancelled"
    );
    assert!(
        e.outbox_kinds().await.is_empty(),
        "no push for a user cancel"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn budgets_stop_runaway_runs() {
    let Some(e) = env().await else { return };
    // 步数。
    let steps = e
        .queue(
            "loop forever",
            Some(RunBudget {
                max_steps: Some(3),
                ..RunBudget::default()
            }),
            3,
        )
        .await;
    e.run_to_end().await;
    let rec = e.state(steps).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("step budget"));
    // 时长。
    let time = e
        .queue(
            "loop forever",
            Some(RunBudget {
                max_duration_secs: 1,
                ..RunBudget::default()
            }),
            3,
        )
        .await;
    e.run_to_end().await;
    let rec = e.state(time).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("time budget"));
    // token：以模型网关的计费记录为准。
    let tokens = e
        .queue(
            "loop forever",
            Some(RunBudget {
                max_tokens: Some(1000),
                ..RunBudget::default()
            }),
            3,
        )
        .await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(tokens, RunState::Running).await;
    let mut w = e.t.db.worker().await.unwrap();
    w.insert_usage(&NewUsage {
        user: e.user,
        instance: e.instance.id,
        alias: "main".into(),
        vendor: "anthropic".into(),
        upstream_model: "m".into(),
        endpoint: "messages".into(),
        status: 200,
        outcome: "ok".into(),
        charged_tokens: 5000,
        ..NewUsage::default()
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(tokens).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("token budget"));
    assert_eq!(rec.run.tokens_used, 5000);
    assert_eq!(
        e.outbox_kinds().await,
        ["run_failed", "run_failed", "run_failed"]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn crashes_back_off() {
    let Some(e) = env().await else { return };
    let run = e.queue("crash please", None, 2).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Backoff);
    assert_eq!(rec.lease_owner, None);
    assert!(rec.not_before > chrono::Utc::now() + chrono::Duration::seconds(20));
    assert!(e.exec.claim().await.unwrap().is_none(), "backing off");
    assert!(e.outbox_kinds().await.is_empty(), "no push while retrying");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn shutdown_hands_the_run_to_another_replica_with_a_resume_note() {
    let Some(e) = env().await else { return };
    let run = e.queue("loop forever", None, 3).await;
    let (stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    // 让 agent 先干一会儿（调几次工具），续跑简报里要有这些。
    tokio::time::sleep(Duration::from_millis(300)).await;
    stop.send(true).unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Backoff);
    assert_eq!(rec.lease_owner, None);
    // 马上能被（另一个副本）领走，算第二次尝试，提示词带续跑说明。
    let next = e.exec.claim().await.unwrap().unwrap();
    assert_eq!(next.run.id, run);
    assert_eq!(next.run.attempt, 2);
    let (tx, rx) = watch::channel(false);
    let exec = e.exec.clone();
    let h = tokio::spawn(async move { exec.execute(next, rx).await });
    e.wait_state(run, RunState::Running).await;
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(prompts[1].contains("续跑说明") && prompts[1].contains("第 2 次"));
    // 替身接不回会话：附上平台记录的上次进展（7.12）。
    assert!(
        prompts[1].contains("没能接回")
            && prompts[1].contains("Read file")
            && prompts[1].contains("中断原因"),
        "{}",
        prompts[1]
    );
    let mut t = e.t.db.tenant(e.user).await.unwrap();
    t.cancel_run(run, None).await.unwrap();
    t.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    drop(tx);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn expired_leases_are_taken_over_and_give_up_after_max_attempts() {
    let Some(e) = env().await else { return };
    let run = e.queue("say hello", None, 1).await;
    // 另一个副本领了之后崩溃（租约立即过期）。
    let mut w = e.t.db.worker().await.unwrap();
    w.claim_next_run("dead-node", Duration::ZERO)
        .await
        .unwrap()
        .unwrap();
    w.commit().await.unwrap();
    assert_eq!(e.exec.take_over_expired().await.unwrap(), 1);
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed, "max_attempts = 1");
    assert!(rec.run.state_reason.unwrap().contains("gave up"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_second_crash_gives_up() {
    let Some(e) = env_with(
        ExecutorConfig {
            backoff_base: Duration::ZERO,
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("crash please", None, 2).await;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Backoff);
    // 第二次也崩溃：超过最多尝试次数，失败并通知。
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert_eq!(rec.run.attempt, 2);
    assert_eq!(e.outbox_kinds().await, ["run_failed"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn platform_tools_follow_the_grant_scope() {
    let Some(e) = env_with(
        fast(),
        Some(GrantScope {
            platform_tools: vec!["schedule_list".into()],
            ..GrantScope::default()
        }),
        Arc::new(Tools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("use tool", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded);
    assert_eq!(
        rec.run.summary,
        Some(format!("schedule_list for run {run}"))
    );
    let launches = e.fake.rec.lock().unwrap().launches.clone();
    assert_eq!(
        launches[0].2,
        ["schedule_list"],
        "delegate is outside the grant"
    );
    // 授权范围外的工具，就算 shim 发来调用也不执行。
    let run = e.queue("use tool, forged", None, 3).await;
    e.run_to_end().await;
    assert_eq!(
        e.state(run).await.run.summary.as_deref(),
        Some("unknown platform tool delegate")
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn runs_without_a_grant_fail() {
    let Some(e) = env_with(fast(), None, Arc::new(NoPlatformTools)).await else {
        return;
    };
    let run = e.queue("say hello", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(rec.run.error.unwrap().contains("no active run grant"));
}

/// agent 输出不受控：单条日志截断，整次运行的日志有总量上限，摘要只取开头。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn agent_output_is_bounded_in_memory_and_in_the_log() {
    let Some(e) = env_with(
        ExecutorConfig {
            max_run_log_bytes: 256 << 10,
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(Tools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("please flood", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert!(rec.run.summary.as_deref().unwrap().chars().count() <= 401);
    let events = e.events(run).await;
    let logged: usize = events
        .iter()
        .filter(|(k, _)| k.starts_with("agent."))
        .map(|(_, p)| serde_json::to_vec(p).unwrap().len())
        .sum();
    assert!(logged <= 256 << 10, "agent events took {logged} bytes");
    for (_, p) in &events {
        assert!(serde_json::to_vec(p).unwrap().len() <= 256 << 10);
    }
    let marks = events
        .iter()
        .filter(|(k, _)| k == "run.log_truncated")
        .count();
    assert_eq!(marks, 1);
    // 状态变化照常记。
    assert_eq!(events.last().unwrap().0, "run.state");
    assert_eq!(events.last().unwrap().1["state"], "succeeded");
}

impl Env {
    async fn approve_pending(&self) {
        let mut tx = self.t.db.tenant(self.user).await.unwrap();
        let pending = tx.pending_approvals().await.unwrap();
        assert_eq!(pending.len(), 1, "{pending:?}");
        tx.decide_approval(pending[0].id, "allow", proto::domain::DeviceId::new())
            .await
            .unwrap();
        tx.commit().await.unwrap();
    }

    async fn instance_state(&self) -> proto::domain::InstanceState {
        let mut w = self.t.db.worker().await.unwrap();
        let s = w.instance_runtime(self.instance.id).await.unwrap().state;
        w.rollback().await.unwrap();
        s
    }
}

/// 等审批期间沙箱被空闲回收暂停：用户批准后先唤醒沙箱，再把决定交给 agent。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn approving_wakes_a_paused_sandbox() {
    let Some(e) = env().await else { return };
    let run = e.queue("need approval to clean up", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    assert!(e.lifecycle.pause(e.instance.id).await.unwrap());
    assert_eq!(
        e.instance_state().await,
        proto::domain::InstanceState::Paused
    );
    e.approve_pending().await;
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(e.state(run).await.run.state, RunState::Succeeded);
    assert_eq!(
        e.instance_state().await,
        proto::domain::InstanceState::Running
    );
}

/// 等审批时被打断（发版、副本挂了）：没处理的审批作废，下次尝试 agent 从 perm-1 重新请求也不会撞上。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn interrupted_approvals_are_asked_again_on_the_next_attempt() {
    let Some(e) = env().await else { return };
    let run = e.queue("need approval to clean up", None, 3).await;
    let (stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    stop.send(true).unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(e.state(run).await.run.state, RunState::Backoff);
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(
        tx.pending_approvals().await.unwrap().is_empty(),
        "the old request is void"
    );
    tx.rollback().await.unwrap();
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::WaitingApproval).await;
    e.approve_pending().await;
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!((rec.run.state, rec.run.attempt), (RunState::Succeeded, 2));
    // 两次尝试的请求 id 一样（shim 每次从 perm-1 编号），靠 attempt 和审批 id 分开。
    let asked: Vec<Value> = e
        .events(run)
        .await
        .into_iter()
        .filter(|(k, _)| k == "agent.permission_requested")
        .map(|(_, p)| p)
        .collect();
    assert_eq!(asked.len(), 2);
    assert_eq!(asked[0]["request_id"], asked[1]["request_id"]);
    assert_eq!(
        (&asked[0]["attempt"], &asked[1]["attempt"]),
        (&json!(1), &json!(2))
    );
    assert!(
        asked[0]["approval_id"].is_string() && asked[0]["approval_id"] != asked[1]["approval_id"]
    );
}

/// 等审批的运行让出执行名额：只有一个名额时，别的运行照样能跑；批准后它拿回名额接着跑完。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn runs_waiting_for_approval_do_not_hold_an_execution_slot() {
    let Some(e) = env_with(
        ExecutorConfig {
            max_concurrent: 1,
            claim_poll: Duration::from_millis(50),
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
    else {
        return;
    };
    let waiting = e.queue("need approval to clean up", None, 3).await;
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let exec = e.exec.clone();
    let loop_handle = tokio::spawn(async move {
        exec.run(async {
            let _ = stop_rx.await;
        })
        .await
    });
    e.wait_state(waiting, RunState::WaitingApproval).await;
    // 另一个实例上的运行（同一个实例同时只跑一个运行）。
    let second = e
        .lifecycle
        .adopt(e.user, "user:d", "claude", None, "Claude 2")
        .await
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_run_grant(
        second.id,
        None,
        &GrantScope::default(),
        Duration::from_secs(3600),
    )
    .await
    .unwrap();
    let other = tx
        .create_run(&NewRun::new(
            second.id,
            RunSource::User,
            "please say hello",
            &second.agent_version,
        ))
        .await
        .unwrap()
        .id;
    tx.commit().await.unwrap();
    e.wait_state(other, RunState::Succeeded).await;
    e.approve_pending().await;
    e.wait_state(waiting, RunState::Succeeded).await;
    let _ = stop_tx.send(());
    tokio::time::timeout(Duration::from_secs(20), loop_handle)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn nul_characters_in_agent_output_do_not_break_finishing() {
    let Some(e) = env().await else { return };
    let run = e.queue("reply with a nul", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("donehere"));
    assert_eq!(rec.lease_owner, None);
}

/// 续租赶不上、租约被别的副本接手：原来的执行停下 agent，接手的副本的运行原样不动（不取消、不改状态）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_taken_over_run_is_left_to_the_new_holder() {
    let Some(e) = env_with(
        ExecutorConfig {
            lease: Duration::from_millis(300),
            renew_every: Duration::from_secs(1),
            ..fast()
        },
        Some(GrantScope::default()),
        Arc::new(NoPlatformTools),
    )
    .await
    else {
        return;
    };
    let run = e.queue("loop forever", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    // 续租间隔比租约长：两次续租之间租约会过期，等到那时接手（机器忙时时间点不固定，轮询）。
    // 每次新开事务：now() 是事务开始的时间。
    let mut taken = Vec::new();
    let mut w = e.t.db.worker().await.unwrap();
    for _ in 0..100 {
        taken = w
            .take_over_expired("node-b", Duration::from_secs(60), 10)
            .await
            .unwrap();
        if !taken.is_empty() {
            break;
        }
        w.rollback().await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        w = e.t.db.worker().await.unwrap();
    }
    assert_eq!(taken.len(), 1);
    // 接手的副本已经让 agent 请求了一次审批。
    w.create_approval(&store::NewApproval {
        user: e.user,
        instance: e.instance.id,
        run,
        request_id: "2:p1",
        title: Some("Delete old reports"),
        options: &json!([{ "option_id": "allow", "name": "Allow", "kind": "allow_once" }]),
        tool_call: &json!({}),
        expires_in: Duration::from_secs(600),
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), h)
        .await
        .expect("the old holder stops")
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Running);
    assert_eq!(rec.lease_owner.as_deref(), Some("node-b"));
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert_eq!(
        tx.pending_approvals().await.unwrap().len(),
        1,
        "the new holder's approval is untouched"
    );
}

/// 运行的一次尝试结束、运行被取消时，签给它的沙箱令牌作废（实例的令牌代数加一），
/// agent 留在沙箱里的后台进程不能接着用模型网关。排队中的运行被取消不动代数（它没有令牌）。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sandbox_tokens_die_with_the_run() {
    let Some(e) = env().await else { return };
    let epoch = || async {
        let mut w = e.t.db.worker().await.unwrap();
        let rt = w.instance_runtime(e.instance.id).await.unwrap();
        w.rollback().await.unwrap();
        rt.token_epoch
    };
    assert_eq!(epoch().await, 0);
    e.queue("say hello", None, 3).await;
    e.run_to_end().await;
    assert_eq!(epoch().await, 1, "the finished attempt's token is dead");

    let queued = e.queue("say hello", None, 3).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(queued, None).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(epoch().await, 1, "a queued run had no token");

    let run = e.queue("loop forever", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(run, None).await.unwrap();
    tx.commit().await.unwrap();
    assert_eq!(epoch().await, 2, "cancelling kills the token at once");
    tokio::time::timeout(Duration::from_secs(10), h)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        epoch().await,
        2,
        "the executor does not bump again (the next run may already hold a token)"
    );
}

/// 密码保险箱（9.11）：沙箱里的助手按名字拿到值（授权里有保险箱工具、条目允许这个实例），
/// 记审计和运行日志（只记名字）；运行日志、摘要里看不到值。没有授权时拿不到。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_vault_helper_gets_values_and_logs_never_show_them() {
    let scope = GrantScope {
        platform_tools: vec!["vault_list".into()],
        ..GrantScope::default()
    };
    let Some(e) = env_with(fast(), Some(scope), Arc::new(VaultStub)).await else {
        return;
    };
    let vault = orchestrator::artifacts::user_vault(&e.t.db, kms(), e.user, true)
        .await
        .unwrap();
    let id = proto::domain::VaultItemId::new();
    let sealed = vault
        .seal_vault(
            &e.user.to_string(),
            &id.to_string(),
            &keyvault::VaultSecret {
                username: "octocat".into(),
                password: "gh-secret-123".into(),
            },
        )
        .await
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_vault_item(&store::NewVaultItem {
        id,
        name: "github".into(),
        purpose: "push code".into(),
        sealed,
        has_username: true,
        instance_ids: vec![e.instance.id],
    })
    .await
    .unwrap();
    tx.commit().await.unwrap();

    let run = e.queue("please use vault", None, 1).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(
        rec.run.summary.as_deref(),
        Some("got [vault:github] for octocat")
    );
    let events = e.events(run).await;
    let all = serde_json::to_string(&events).unwrap();
    assert!(!all.contains("gh-secret-123"), "{all}");
    assert!(all.contains("[vault:github]"), "{all}");
    let used: Vec<&Value> = events
        .iter()
        .filter(|(k, _)| k == "vault.used")
        .map(|(_, p)| p)
        .collect();
    assert_eq!(used, [&json!({ "names": ["github"] })]);
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(tx.vault_items().await.unwrap()[0].last_used_at.is_some());
    tx.rollback().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_vault_needs_the_grant() {
    let Some(e) = env().await else { return };
    let run = e.queue("please use vault", None, 1).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert!(
        rec.run
            .summary
            .as_deref()
            .is_some_and(|s| s.contains("not allowed to use the password vault")),
        "{:?}",
        rec.run.summary
    );
}

/// 模型网关记下的一次失败的模型调用。
async fn model_call_failed(e: &Env, status: u16) {
    let mut w = e.t.db.worker().await.unwrap();
    w.insert_usage(&NewUsage {
        user: e.user,
        instance: e.instance.id,
        alias: "main".into(),
        vendor: "anthropic".into(),
        upstream_model: "m".into(),
        endpoint: "messages".into(),
        status,
        outcome: "upstream_status".into(),
        ..NewUsage::default()
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_stuck_on_its_model_key_waits_until_a_key_is_added() {
    let Some(e) = env().await else { return };
    let run = e.queue("broken key", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    // 主 key、备用 key 都 401：降级链试完了，agent 还在重试。
    model_call_failed(&e, 401).await;
    model_call_failed(&e, 401).await;
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::WaitingQuota, "{:?}", rec.run);
    assert_eq!(rec.lease_owner, None, "waiting gives the lease back");
    assert!(
        rec.run
            .state_reason
            .as_deref()
            .unwrap_or_default()
            .contains("key"),
        "{:?}",
        rec.run.state_reason
    );
    // 要用户处理：通知用户换 key；提醒带上等的是什么，App 直接跳到换 key。
    assert!(
        e.inbox()
            .await
            .iter()
            .any(|i| i.body.contains("更换 key") && i.subtype.as_deref() == Some("invalid")),
        "{:?}",
        e.inbox().await
    );
    // 结构化的原因：key 无效，要用户换（接口和事件里都有）。
    assert_eq!(rec.run.wait_code.as_deref(), Some("invalid"));
    assert!(e.events(run).await.iter().any(|(k, p)| k == "run.state"
        && p["state"] == "waiting_quota"
        && p["wait_code"] == "invalid"));
    // 还没补上 key：领不到。
    assert!(e.exec.claim().await.unwrap().is_none());

    // 补上 key：接着跑（带续跑说明），这次成功了；从等待里接着跑不占重试次数。
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert_eq!(
        tx.wake_waiting_runs(RunState::WaitingQuota).await.unwrap(),
        1
    );
    tx.commit().await.unwrap();
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!((rec.run.attempt, rec.max_attempts), (2, 4));
    assert_eq!(rec.run.wait_code, None);
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(prompts[1].contains("续跑说明"), "{prompts:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rate_limits_wait_a_few_minutes_without_a_push() {
    let Some(e) = env().await else { return };
    let run = e.queue("gives up", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(run, RunState::Running).await;
    model_call_failed(&e, 429).await;
    model_call_failed(&e, 429).await;
    // 短暂的限流：续租时不判卡住，agent 自己会退避重试。
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(e.state(run).await.run.state, RunState::Running);
    // agent 重试几次后放弃了这一轮：转入等 key，几分钟后自己再试，不用打扰用户。
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::WaitingQuota, "{:?}", rec.run);
    assert_eq!(rec.run.wait_code.as_deref(), Some("rate_limited"));
    assert!(rec.not_before > chrono::Utc::now() + chrono::Duration::minutes(4));
    assert!(e.inbox().await.iter().all(|i| i.kind != "run_failed"));
    assert!(e.exec.claim().await.unwrap().is_none());
}

/// 先是 key 无效、换了 key 又欠费（10.7）：两次等待各提醒一次，子类型不同；同一个原因不重复提醒。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn each_new_wait_reason_is_announced() {
    let Some(e) = env().await else { return };
    let run = e.queue("loop forever", None, 3).await;
    for (status, code) in [(401, "invalid"), (402, "no_balance")] {
        let (_stop, h) = e.spawn().await;
        e.wait_state(run, RunState::Running).await;
        model_call_failed(&e, status).await;
        model_call_failed(&e, status).await;
        tokio::time::timeout(Duration::from_secs(20), h)
            .await
            .unwrap()
            .unwrap();
        let rec = e.state(run).await;
        assert_eq!(
            (rec.run.state, rec.run.wait_code.as_deref()),
            (RunState::WaitingQuota, Some(code)),
            "{:?}",
            rec.run
        );
        // 用户补上 key：接着跑。
        let mut tx = e.t.db.tenant(e.user).await.unwrap();
        tx.wake_waiting_runs(RunState::WaitingQuota).await.unwrap();
        tx.commit().await.unwrap();
    }
    let waits: Vec<String> = e
        .inbox()
        .await
        .into_iter()
        .filter(|i| i.kind == "run_failed")
        .map(|i| i.subtype.unwrap_or_default())
        .collect();
    assert_eq!(waits, ["no_balance", "invalid"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn waits_time_out_by_the_plan_policy() {
    let Some(e) = env().await else { return };
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let plan = tx
        .create_plan(&NewPlan {
            instance_id: e.instance.id,
            title: "早报".into(),
            goal: "汇总新闻".into(),
            policy: PlanPolicy::default(),
            catch_up: CatchUp::default(),
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    let mut new = NewRun::new(
        e.instance.id,
        RunSource::Plan,
        "broken key",
        &e.instance.agent_version,
    );
    new.plan_id = Some(plan.id);
    let run = tx.create_run(&new).await.unwrap().id;
    tx.commit().await.unwrap();
    // 进入等 key，最晚的时间已经过了。
    let mut w = e.t.db.worker().await.unwrap();
    w.claim_next_run("x", Duration::from_secs(60))
        .await
        .unwrap()
        .unwrap();
    w.transition_run(run, "x", RunState::Running, &store::RunChange::default())
        .await
        .unwrap();
    let past = chrono::Utc::now() - chrono::Duration::seconds(1);
    w.transition_run(
        run,
        "x",
        RunState::WaitingQuota,
        &store::RunChange {
            release_lease: true,
            not_before: Some(past),
            wait_deadline: Some(past),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    w.commit().await.unwrap();
    assert!(
        e.exec.claim().await.unwrap().is_none(),
        "expired waits do not resume"
    );

    assert_eq!(e.exec.expire_waits().await.unwrap(), 1);
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(
        rec.run
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("model key"),
        "{:?}",
        rec.run.error
    );
    // 计划策略默认是“暂停计划”。
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(tx.plan(plan.id).await.unwrap().paused);
    tx.rollback().await.unwrap();
    assert!(e.inbox().await.iter().any(|i| i.kind == "run_failed"));
    assert_eq!(e.exec.expire_waits().await.unwrap(), 0);
}

/// 计划里的运行：用给定的策略。
async fn queue_plan_run(
    e: &Env,
    prompt: &str,
    policy: PlanPolicy,
) -> (proto::domain::PlanId, RunId) {
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let plan = tx
        .create_plan(&NewPlan {
            instance_id: e.instance.id,
            title: "整理报表".into(),
            goal: prompt.into(),
            policy,
            catch_up: CatchUp::default(),
            created_by: PlanAuthor::User,
            run_grant_id: None,
        })
        .await
        .unwrap();
    let mut new = NewRun::new(
        e.instance.id,
        RunSource::Plan,
        prompt,
        &e.instance.agent_version,
    );
    new.plan_id = Some(plan.id);
    let run = tx.create_run(&new).await.unwrap().id;
    tx.commit().await.unwrap();
    (plan.id, run)
}

/// 审批过了时限用户没处理（7.10）：平台这边判超时（shim 的计时器在沙箱暂停时不走，替身里也没有），
/// 策略是“跳过”时告诉 agent 不做这一步、接着跑，并告诉用户跳过了什么。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn expired_approvals_are_skipped_by_policy() {
    let Some(e) = env().await else { return };
    let policy = PlanPolicy {
        approval_timeout_secs: 1,
        on_approval_timeout: proto::domain::ApprovalTimeoutAction::Skip,
        ..PlanPolicy::default()
    };
    let (_, run) = queue_plan_run(&e, "need approval", policy).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("rejected"));
    let mut w = e.t.db.worker().await.unwrap();
    let approval = w.approval_for_request(run, "1:p1").await.unwrap().unwrap();
    w.rollback().await.unwrap();
    assert_eq!(
        approval.approval.state,
        proto::domain::ApprovalState::Expired
    );
    // 平台判的超时，shim 回的是 by=user：事件里带上平台交过去的结果，时间线才不会显示成用户拒绝。
    let resolved = e
        .events(run)
        .await
        .into_iter()
        .find(|(k, _)| k == "agent.permission_resolved")
        .unwrap()
        .1;
    assert_eq!(
        (&resolved["attempt"], &resolved["approval_id"]),
        (&json!(1), &json!(approval.approval.id))
    );
    assert!(
        resolved["by"] == "timeout" || resolved["approval_state"] == "expired",
        "{resolved}"
    );
    let inbox = e.inbox().await;
    assert!(
        inbox.iter().any(|i| i.title == "审批超时，已跳过这一步"
                && i.body == "Delete old reports"
                // 运行结束时只有审批本身那条算已读，这条留给之后回来的用户。
                && !i.read
                && i.subtype.as_deref() == Some("approval_skipped")),
        "{inbox:?}"
    );
}

/// 策略是“暂停计划”：计划暂停，运行判失败。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn expired_approvals_pause_the_plan() {
    let Some(e) = env().await else { return };
    let policy = PlanPolicy {
        approval_timeout_secs: 1,
        ..PlanPolicy::default()
    };
    let (plan, run) = queue_plan_run(&e, "need approval", policy).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Failed, "{:?}", rec.run);
    assert!(
        rec.run
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("plan was paused"),
        "{:?}",
        rec.run.error
    );
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    assert!(tx.plan(plan).await.unwrap().paused);
    tx.rollback().await.unwrap();
}

// ---------- 委派（8.6–8.8） ----------

/// 平台工具晚一点再装上（委派工具要用测试库，库在环境里才建）。
#[derive(Default, Clone)]
struct Late(Arc<std::sync::OnceLock<Arc<dyn PlatformTools>>>);

#[async_trait]
impl PlatformTools for Late {
    fn tools(&self) -> Vec<PlatformTool> {
        self.0.get().map(|t| t.tools()).unwrap_or_default()
    }
    async fn call(&self, ctx: &ToolContext, name: &str, args: &Value) -> ToolOutput {
        match self.0.get() {
            Some(t) => t.call(ctx, name, args).await,
            None => ToolOutput::error("tools are not ready"),
        }
    }
}

/// 负责人（e.instance，名字 Claude）和成员 helper 编成团队，负责人的授权里有委派工具。
async fn delegation_env() -> Option<(Env, Instance)> {
    delegation_env_with(fast()).await
}

async fn delegation_env_with(cfg: ExecutorConfig) -> Option<(Env, Instance)> {
    let late = Late::default();
    let scope = GrantScope {
        platform_tools: DELEGATE_TOOLS.iter().map(|t| t.to_string()).collect(),
        ..GrantScope::default()
    };
    let e = env_with(cfg, Some(scope), Arc::new(late.clone())).await?;
    let _ = late.0.set(Arc::new(DelegateTools::new(e.t.db.clone())));
    let helper = e
        .lifecycle
        .adopt(e.user, "user:d", "claude", None, "helper")
        .await
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_team(
        "crew",
        &[
            TeamMember {
                instance_id: e.instance.id,
                role: TeamRole::Lead,
                position: 0,
            },
            TeamMember {
                instance_id: helper.id,
                role: TeamRole::Member,
                position: 1,
            },
        ],
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    Some((e, helper))
}

async fn children(e: &Env, parent: RunId) -> Vec<proto::domain::Run> {
    let mut w = e.t.db.worker().await.unwrap();
    let runs = w.delegated_runs(parent).await.unwrap();
    w.rollback().await.unwrap();
    runs
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_lead_delegates_waits_and_gets_the_results_back() {
    let Some((e, helper)) = delegation_env().await else {
        return;
    };
    let run = e.queue("lead the team: say hello please", None, 3).await;
    // 负责人委派以后结束这一轮：转入等子任务，放掉租约。
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::WaitingChildren, "{:?}", rec.run);
    assert_eq!(rec.lease_owner, None);
    let kids = children(&e, run).await;
    assert_eq!(kids.len(), 1);
    let child = &kids[0];
    assert_eq!(
        (
            child.instance_id,
            child.source,
            child.parent_run_id,
            child.root_run_id
        ),
        (helper.id, RunSource::Delegate, Some(run), run)
    );
    assert!(child.prompt.contains("say hello please") && child.prompt.contains("委派"));
    // 子运行用从负责人授权收窄出来的子授权。
    let mut w = e.t.db.worker().await.unwrap();
    let child_rec = w.run_record(child.id).await.unwrap();
    let (_, grant) = w.run_grant(child_rec.run_grant_id.unwrap()).await.unwrap();
    w.rollback().await.unwrap();
    assert_eq!(grant.instance_id, helper.id);
    assert!(grant.parent_id.is_some());
    assert!(
        e.events(run)
            .await
            .iter()
            .any(|(k, p)| k == "delegate.started" && p["to"] == "helper")
    );

    // 成员做子任务。
    e.run_to_end().await;
    assert_eq!(e.state(child.id).await.run.state, RunState::Succeeded);
    // 子任务的完成不单独推送。
    assert!(e.inbox().await.iter().all(|i| i.run_id != Some(child.id)));

    // 负责人接着跑：结果作为新消息交回去，不占重试次数。
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("got the results"));
    assert_eq!((rec.run.attempt, rec.max_attempts), (2, 4));
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 3, "{prompts:?}");
    assert!(
        prompts[2].contains("交给「helper」") && prompts[2].contains("Hello world"),
        "{}",
        prompts[2]
    );
    // 交过的结果不再交。
    let mut w = e.t.db.worker().await.unwrap();
    assert!(w.unreported_children(run).await.unwrap().is_empty());
    w.rollback().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn delegating_back_up_the_chain_is_refused() {
    let Some((e, helper)) = delegation_env().await else {
        return;
    };
    // helper 也领一个团队，成员是负责人：helper 再委派给负责人就成了互相等。
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_team(
        "reverse",
        &[
            TeamMember {
                instance_id: helper.id,
                role: TeamRole::Lead,
                position: 0,
            },
            TeamMember {
                instance_id: e.instance.id,
                role: TeamRole::Member,
                position: 1,
            },
        ],
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let run = e.queue("lead the team: delegate back", None, 3).await;
    e.run_to_end().await;
    let child = children(&e, run).await[0].id;
    e.run_to_end().await;
    let rec = e.state(child).await;
    assert_eq!(rec.run.state, RunState::Succeeded);
    assert!(
        rec.run
            .summary
            .as_deref()
            .unwrap_or_default()
            .contains("deadlock"),
        "{:?}",
        rec.run.summary
    );
    assert!(children(&e, child).await.is_empty());
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Succeeded);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_run_tree_shares_one_token_budget() {
    let Some((e, _helper)) = delegation_env().await else {
        return;
    };
    let budget = RunBudget {
        max_tokens: Some(1000),
        ..RunBudget::default()
    };
    let run = e
        .queue("lead the team: loop forever please", Some(budget), 3)
        .await;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::WaitingChildren);
    // 负责人自己已经用掉了 800。
    let mut w = e.t.db.worker().await.unwrap();
    w.set_run_usage(run, 800, 0).await.unwrap();
    w.commit().await.unwrap();
    let child = children(&e, run).await[0].clone();
    let (_stop, h) = e.spawn().await;
    e.wait_state(child.id, RunState::Running).await;
    // 子任务用了 300：自己没超，加上整棵树就超了。
    let mut w = e.t.db.worker().await.unwrap();
    w.insert_usage(&NewUsage {
        user: e.user,
        instance: child.instance_id,
        alias: "main".into(),
        vendor: "anthropic".into(),
        upstream_model: "m".into(),
        endpoint: "messages".into(),
        status: 200,
        outcome: "complete".into(),
        charged_tokens: 300,
        ..NewUsage::default()
    })
    .await
    .unwrap();
    w.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(child.id).await;
    assert_eq!(rec.run.state, RunState::Failed);
    assert!(
        rec.run
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("shared by the run tree"),
        "{:?}",
        rec.run.error
    );
    // 负责人拿到失败的结果接着跑。
    e.run_to_end().await;
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(prompts.last().unwrap().contains("失败"), "{prompts:?}");
}

/// `lead` 领一个两人团队，成员是 `member`。
async fn team(e: &Env, name: &str, lead: &Instance, member: &Instance) {
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_team(
        name,
        &[
            TeamMember {
                instance_id: lead.id,
                role: TeamRole::Lead,
                position: 0,
            },
            TeamMember {
                instance_id: member.id,
                role: TeamRole::Member,
                position: 1,
            },
        ],
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
}

// ---------- 多 agent 协同（17.4） ----------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn delegation_stops_at_three_levels() {
    let Some((e, helper)) = delegation_env().await else {
        return;
    };
    // 一条委派链：负责人 → helper → carol → dave → xena，每一层领一个两人团队。
    let mut chain = vec![helper];
    for name in ["carol", "dave", "xena"] {
        let next = e
            .lifecycle
            .adopt(e.user, "user:d", "claude", None, name)
            .await
            .unwrap();
        team(&e, &format!("team {name}"), chain.last().unwrap(), &next).await;
        chain.push(next);
    }
    let root = e
        .queue(
            "relay to helper: relay to carol: relay to dave: relay to xena: say hello",
            None,
            3,
        )
        .await;
    // 前三层各自委派下一层，转入等子任务。
    let mut runs = vec![root];
    for (level, member) in chain.iter().take(3).enumerate() {
        e.run_to_end().await;
        let parent = *runs.last().unwrap();
        let rec = e.state(parent).await;
        assert_eq!(
            rec.run.state,
            RunState::WaitingChildren,
            "level {level}: {:?}",
            rec.run
        );
        let kids = children(&e, parent).await;
        assert_eq!(kids.len(), 1, "level {level}");
        assert_eq!(kids[0].instance_id, member.id, "level {level}");
        assert_eq!(kids[0].root_run_id, root);
        runs.push(kids[0].id);
    }
    // 第三层（dave）再委派就超过 3 层：被拒，自己做完。
    e.run_to_end().await;
    let deepest = e.state(*runs.last().unwrap()).await;
    assert_eq!(deepest.run.state, RunState::Succeeded, "{:?}", deepest.run);
    assert!(
        deepest
            .run
            .summary
            .as_deref()
            .unwrap_or_default()
            .contains("limited to 3 levels"),
        "{:?}",
        deepest.run.summary
    );
    assert!(children(&e, deepest.run.id).await.is_empty());
    // 结果一层层交回去，整条链都完成，只有根运行推送。
    for _ in 0..3 {
        e.run_to_end().await;
    }
    for run in &runs {
        assert_eq!(e.state(*run).await.run.state, RunState::Succeeded, "{run}");
    }
    let inbox = e.inbox().await;
    assert!(inbox.iter().all(|i| i.run_id == Some(root)), "{inbox:?}");
    assert!(e.exec.claim().await.unwrap().is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_delegates_at_most_ten_subtasks() {
    let Some((e, helper)) = delegation_env().await else {
        return;
    };
    let run = e.queue("fan out 11", None, 3).await;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::WaitingChildren);
    let kids = children(&e, run).await;
    assert_eq!(kids.len(), MAX_CHILDREN_PER_RUN);
    assert!(
        kids.iter()
            .all(|k| k.instance_id == helper.id && k.source == RunSource::Delegate)
    );
    // 第 11 个被拒：agent 拿到的是错误，没有多建子运行。
    let said: Vec<String> = e
        .events(run)
        .await
        .into_iter()
        .filter(|(k, _)| k == "agent.message")
        .map(|(_, p)| p["text"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert!(
        said.iter().any(|t| t.contains("at most 10 subtasks")),
        "{said:?}"
    );
}

// ---------- 副作用幂等（7.13） ----------

/// 数调用次数的、有副作用的工具。
#[derive(Default)]
struct Publish(std::sync::atomic::AtomicUsize);

#[async_trait]
impl PlatformTools for Publish {
    fn tools(&self) -> Vec<PlatformTool> {
        vec![PlatformTool {
            name: "artifact_publish".into(),
            description: "Publish".into(),
            input_schema: json!({ "type": "object" }),
        }]
    }
    async fn call(&self, _ctx: &ToolContext, _name: &str, _args: &Value) -> ToolOutput {
        let n = self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        ToolOutput::text(format!("published #{n}"))
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn side_effecting_tools_run_once_per_identical_call() {
    let tools = Arc::new(Publish::default());
    let scope = GrantScope {
        platform_tools: vec!["artifact_publish".into()],
        ..GrantScope::default()
    };
    let Some(e) = env_with(fast(), Some(scope), tools.clone()).await else {
        return;
    };
    let run = e.queue("publish twice", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    // 第二次同样的调用直接拿到第一次的结果；换了参数的照常执行。
    assert_eq!(
        rec.run.summary.as_deref(),
        Some("published #1|published #1|published #2")
    );
    assert_eq!(tools.0.load(std::sync::atomic::Ordering::SeqCst), 2);
}

// ---------- 电脑工具（14.2） ----------

async fn add_mac(e: &Env) -> proto::domain::DeviceId {
    let mut w = e.t.db.worker().await.unwrap();
    let mac = w
        .create_device(e.user, DevicePlatform::Macos, "MacBook", None)
        .await
        .unwrap();
    w.commit().await.unwrap();
    mac
}

/// 测试扮演的电脑：连上中继（在线、唤醒等它的运行；返回时已经连上），把发给它的调用领走，
/// `delay` 之后回“<工具> read <路径>”。停掉返回的任务就是电脑不再回（在线状态还新鲜）。
async fn fake_computer(e: &Env, mac: proto::domain::DeviceId, delay: Duration) -> JoinHandle<()> {
    let db = e.t.db.clone();
    let user = e.user;
    let conn = uuid::Uuid::now_v7();
    let mut r = db.relay().await.unwrap();
    r.link_device(&store::NewLink {
        device: mac,
        user,
        node: "relay-test".into(),
        connection: conn,
    })
    .await
    .unwrap();
    r.wake_device_waiters(user).await.unwrap();
    r.commit().await.unwrap();
    tokio::spawn(async move {
        loop {
            let mut r = db.relay().await.unwrap();
            r.touch_link(mac, conn).await.unwrap();
            let calls = r.claim_device_calls(mac, conn, 10).await.unwrap();
            r.commit().await.unwrap();
            for c in calls {
                tokio::time::sleep(delay).await;
                let text = format!(
                    "{} read {}",
                    c.tool,
                    c.arguments["path"].as_str().unwrap_or_default()
                );
                let mut r = db.relay().await.unwrap();
                r.finish_device_call(
                    c.id,
                    mac,
                    conn,
                    &json!({ "content": [{ "type": "text", "text": text }], "is_error": false }),
                )
                .await
                .unwrap();
                r.commit().await.unwrap();
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
}

async fn device_call_states(e: &Env) -> Vec<String> {
    sqlx::query_scalar("SELECT state FROM device_calls ORDER BY created_at")
        .fetch_all(e.t.db.pool())
        .await
        .unwrap()
}

/// 有电脑的用户：agent 拿到电脑工具，调用转到用户自己的电脑上，结果交回 agent。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn computer_tools_reach_the_users_own_computer() {
    let Some(e) = env_computer().await else {
        return;
    };
    let mac = add_mac(&e).await;
    let computer = fake_computer(&e, mac, Duration::from_millis(300)).await;
    let run = e.queue("use computer: computer_read_file", None, 3).await;
    e.run_to_end().await;
    computer.abort();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(
        rec.run.summary.as_deref(),
        Some("computer_read_file read /Users/a/notes.md")
    );
    let launches = e.fake.rec.lock().unwrap().launches.clone();
    assert!(
        launches[0].2.iter().any(|t| t == "computer_screenshot"),
        "{launches:?}"
    );
    let (device, run_id, state): (uuid::Uuid, Option<uuid::Uuid>, String) =
        sqlx::query_as("SELECT device_id, run_id, state FROM device_calls")
            .fetch_one(e.t.db.pool())
            .await
            .unwrap();
    assert_eq!(
        (device, run_id, state.as_str()),
        (mac.0, Some(run.0), "done")
    );
}

/// 电脑迟迟不回（比如在等用户在手机上批准）时执行器照常续租：用户取消马上生效，不用等电脑。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn waiting_for_the_computer_does_not_block_the_run() {
    let Some(e) = env_computer().await else {
        return;
    };
    let mac = add_mac(&e).await;
    let computer = fake_computer(&e, mac, Duration::from_secs(3600)).await;
    let run = e.queue("use computer: computer_run", None, 3).await;
    let (_stop, h) = e.spawn().await;
    for _ in 0..400 {
        if device_call_states(&e).await == ["sent"] {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(device_call_states(&e).await, ["sent"]);
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(run, None).await.unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), h)
        .await
        .expect("cancelling does not wait for the computer")
        .unwrap();
    computer.abort();
    assert_eq!(e.state(run).await.run.state, RunState::Cancelled);
}

/// 电脑不在线：运行停下这一轮、转入等电脑上线（放掉租约、通知用户）；电脑连上中继时唤醒，
/// 带着续跑说明接着跑，这次调成了。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_waits_for_the_computer_to_come_online() {
    let Some(e) = env_computer().await else {
        return;
    };
    let mac = add_mac(&e).await;
    let run = e.queue("use computer: computer_screenshot", None, 3).await;
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::WaitingDevice, "{:?}", rec.run);
    assert_eq!(rec.run.wait_code.as_deref(), Some("device_offline"));
    assert_eq!(rec.lease_owner, None);
    assert!(
        e.inbox()
            .await
            .iter()
            .any(|i| i.body.contains("电脑不在线")),
        "{:?}",
        e.inbox().await
    );
    assert!(e.exec.claim().await.unwrap().is_none());

    let computer = fake_computer(&e, mac, Duration::ZERO).await;
    let mut claimed = None;
    for _ in 0..200 {
        if let Some(r) = e.exec.claim().await.unwrap() {
            claimed = Some(r);
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let rec = claimed.expect("the run wakes up when the computer connects");
    let (_tx, rx) = watch::channel(false);
    tokio::time::timeout(Duration::from_secs(20), e.exec.execute(rec, rx))
        .await
        .unwrap();
    computer.abort();
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(
        rec.run.summary.as_deref(),
        Some("computer_screenshot read /Users/a/notes.md")
    );
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(prompts[1].contains("续跑说明"), "{prompts:?}");
}

/// 没登录电脑的用户：agent 看不到电脑工具，硬调也不行。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn without_a_computer_there_are_no_computer_tools() {
    let Some(e) = env_computer().await else {
        return;
    };
    let run = e.queue("use computer: computer_list_dir", None, 3).await;
    e.run_to_end().await;
    let launches = e.fake.rec.lock().unwrap().launches.clone();
    assert!(
        launches[0].2.iter().all(|t| !t.starts_with("computer_")),
        "{launches:?}"
    );
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert!(
        rec.run
            .summary
            .as_deref()
            .unwrap_or_default()
            .contains("unknown platform tool"),
        "{:?}",
        rec.run.summary
    );
    assert!(device_call_states(&e).await.is_empty());
}

// ---------- 问队友（8.11） ----------

/// e.instance（名字 Claude）和 helper 是同一用户的两个实例，不在一个团队里；两个都有自己的授权，里面有提问工具。
async fn ask_env() -> Option<(Env, Instance)> {
    let late = Late::default();
    let scope = GrantScope {
        platform_tools: ASK_TOOLS.iter().map(|t| t.to_string()).collect(),
        ..GrantScope::default()
    };
    let e = env_with(fast(), Some(scope.clone()), Arc::new(late.clone())).await?;
    let _ = late.0.set(Arc::new(AskTools::new(e.t.db.clone(), kms())));
    let helper = e
        .lifecycle
        .adopt(e.user, "user:d", "claude", None, "helper")
        .await
        .unwrap();
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.create_run_grant(helper.id, None, &scope, Duration::from_secs(3600))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    Some((e, helper))
}

async fn asks(e: &Env, parent: RunId) -> Vec<proto::domain::Run> {
    let mut w = e.t.db.worker().await.unwrap();
    let runs = w.ask_runs(parent).await.unwrap();
    w.rollback().await.unwrap();
    runs
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_teammate_answers_and_the_answer_comes_back() {
    let Some((e, helper)) = ask_env().await else {
        return;
    };
    let run = e.queue("ask teammate helper: say hello", None, 3).await;
    // 问完结束这一轮：转入等回答，放掉租约。
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::WaitingChildren, "{:?}", rec.run);
    assert_eq!(
        rec.run.wait_code.as_deref(),
        Some(proto::domain::wait_code::ANSWER)
    );
    assert_eq!(rec.lease_owner, None);
    let qs = asks(&e, run).await;
    assert_eq!(qs.len(), 1);
    let q = &qs[0];
    assert_eq!(
        (
            q.instance_id,
            q.source,
            q.parent_run_id,
            q.root_run_id,
            q.plan_id
        ),
        (helper.id, RunSource::Ask, Some(run), run, None)
    );
    assert!(q.prompt.contains("「Claude」") && q.prompt.ends_with("\n\nsay hello"));
    // 回答方用它自己的授权，不从提问方收窄。
    assert_eq!(e.state(q.id).await.run_grant_id, None);
    assert!(
        e.events(run)
            .await
            .iter()
            .any(|(k, p)| k == "ask.sent" && p["to"] == "helper" && p["question"] == "say hello")
    );

    // 对方回答：不单独推送。
    e.run_to_end().await;
    let answered = e.state(q.id).await.run;
    assert_eq!(answered.state, RunState::Succeeded);
    assert_eq!(answered.summary.as_deref(), Some("Hello world"));
    assert!(e.inbox().await.iter().all(|i| i.run_id != Some(q.id)));

    // 提问方接着跑：回答作为新消息交回去，不占重试次数。
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("got the answers"));
    assert_eq!((rec.run.attempt, rec.max_attempts), (2, 4));
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(
        prompts[2].contains("问「helper」的「say hello」：回答：Hello world"),
        "{}",
        prompts[2]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn asking_back_someone_who_waits_for_you_is_refused() {
    let Some((e, _helper)) = ask_env().await else {
        return;
    };
    let run = e
        .queue(
            "ask teammate helper: ask teammate Claude: say hello",
            None,
            3,
        )
        .await;
    e.run_to_end().await;
    let q = asks(&e, run).await[0].id;
    // helper 回答时反过来问 Claude：Claude 正等着它，会互相等死，拒绝。
    e.run_to_end().await;
    let rec = e.state(q).await;
    assert_eq!(rec.run.state, RunState::Succeeded);
    assert!(
        rec.run
            .summary
            .as_deref()
            .unwrap_or_default()
            .contains("deadlock"),
        "{:?}",
        rec.run.summary
    );
    assert!(asks(&e, q).await.is_empty());
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Succeeded);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unanswered_questions_time_out() {
    let Some((e, helper)) = ask_env().await else {
        return;
    };
    // helper 正忙：问题排在它这一轮后面。
    let busy = {
        let mut tx = e.t.db.tenant(e.user).await.unwrap();
        let r = tx
            .create_run(&NewRun::new(
                helper.id,
                RunSource::User,
                "loop forever",
                &helper.agent_version,
            ))
            .await
            .unwrap();
        tx.commit().await.unwrap();
        r.id
    };
    let (_stop, h) = e.spawn().await;
    e.wait_state(busy, RunState::Running).await;
    let run = e.queue("ask teammate helper: say hello", None, 3).await;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::WaitingChildren);
    let q = asks(&e, run).await[0].id;
    assert_eq!(e.state(q).await.run.state, RunState::Queued);
    // 过了回答期限：后台取消它，提问方拿到“对方没回答”。
    sqlx::query("UPDATE runs SET answer_deadline = now() - interval '1 second' WHERE id = $1")
        .bind(q.0)
        .execute(e.t.db.pool())
        .await
        .unwrap();
    assert_eq!(e.exec.expire_asks().await.unwrap(), 1);
    let rec = e.state(q).await;
    assert_eq!(rec.run.state, RunState::Cancelled);
    assert_eq!(
        rec.run.state_reason.as_deref(),
        Some(store::ANSWER_TIMEOUT_REASON)
    );
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Succeeded);
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(
        prompts.last().unwrap().contains("对方没有在 30 分钟内回答"),
        "{prompts:?}"
    );
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(busy, None).await.unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
}

/// 直接调提问工具（不经 agent）：看拒绝的情况。
async fn ask_directly(e: &Env, run: RunId, to: &str, question: &str) -> ToolOutput {
    let tools = AskTools::new(e.t.db.clone(), kms());
    let mut w = e.t.db.worker().await.unwrap();
    let grant = w
        .active_grant_for_instance(e.instance.id)
        .await
        .unwrap()
        .unwrap();
    w.rollback().await.unwrap();
    let ctx = ToolContext {
        user: e.user,
        instance: e.instance.id,
        run,
        plan: None,
        grant,
    };
    tools
        .call(&ctx, "ask", &json!({ "to": to, "question": question }))
        .await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn questions_respect_the_switch_and_the_cap() {
    let Some((e, helper)) = ask_env().await else {
        return;
    };
    let run = e.queue("anything", None, 3).await;
    let text = |o: &ToolOutput| o.content[0]["text"].as_str().unwrap_or_default().to_owned();
    // 问自己、问不存在的：看不到。
    for to in ["Claude", "nobody"] {
        let out = ask_directly(&e, run, to, "hi").await;
        assert!(
            out.is_error && text(&out).contains("no agent called"),
            "{}",
            text(&out)
        );
    }
    // 一次运行最多问几次。
    for i in 0..MAX_ASKS_PER_RUN {
        let out = ask_directly(&e, run, "helper", &format!("question {i}")).await;
        assert!(!out.is_error, "{}", text(&out));
    }
    let out = ask_directly(&e, run, "helper", "one more").await;
    assert!(
        out.is_error && text(&out).contains("at most"),
        "{}",
        text(&out)
    );
    // 关了“允许其他 agent 问我”：和不存在一样。
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.update_instance(
        helper.id,
        &store::InstanceChange {
            peer_access: Some(false),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    let out = ask_directly(&e, run, "helper", "hi again").await;
    assert!(
        out.is_error && text(&out).contains("no agent called"),
        "{}",
        text(&out)
    );
}

// ---------- 运行中收消息（8.12） ----------

async fn queue_urgent(e: &Env, prompt: &str) -> (RunId, store::Urgent) {
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    let (run, urgent) = tx
        .queue_urgent_run(&NewRun::new(
            e.instance.id,
            RunSource::User,
            prompt,
            &e.instance.agent_version,
        ))
        .await
        .unwrap();
    tx.commit().await.unwrap();
    (run.id, urgent)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_urgent_message_interrupts_the_running_task() {
    let Some(e) = env().await else { return };
    let busy = e.queue("loop forever on the report", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(busy, RunState::Running).await;
    // 先排着一条普通消息：紧急消息排在它前面。
    let normal = e.queue("say hello later", None, 3).await;
    let (urgent, how) = queue_urgent(&e, "say hello now").await;
    assert_eq!(how, store::Urgent::Interrupting(busy));
    // 执行器续租时看到，停下这一轮、结束运行：不推送（用户自己打断的）。
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(busy).await;
    assert_eq!(rec.run.state, RunState::Cancelled, "{:?}", rec.run);
    assert_eq!(
        rec.run.state_reason.as_deref(),
        Some(store::INTERRUPTED_REASON)
    );
    assert!(e.inbox().await.iter().all(|i| i.run_id != Some(busy)));
    // 紧急消息接着跑，开头说明打断了什么。
    e.run_to_end().await;
    assert_eq!(e.state(urgent).await.run.state, RunState::Succeeded);
    assert_eq!(e.state(normal).await.run.state, RunState::Queued);
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    let last = prompts.last().unwrap();
    assert!(
        last.contains("「loop forever on the report」") && last.ends_with("\n\nsay hello now"),
        "{last}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_urgent_message_stops_a_waiting_run_at_once() {
    let Some((e, _helper)) = delegation_env().await else {
        return;
    };
    let lead = e.queue("lead the team: loop forever please", None, 3).await;
    e.run_to_end().await;
    assert_eq!(e.state(lead).await.run.state, RunState::WaitingChildren);
    let child = children(&e, lead).await[0].id;
    // 负责人停在等子任务里、没人在执行它：直接取消，连同子任务。
    let (urgent, how) = queue_urgent(&e, "say hello instead").await;
    assert_eq!(how, store::Urgent::Stopped(lead));
    assert_eq!(e.state(lead).await.run.state, RunState::Cancelled);
    assert_eq!(e.state(child).await.run.state, RunState::Cancelled);
    // 再来一条紧急消息：排在上一条后面，不再去打断谁。
    let (second, how) = queue_urgent(&e, "say hello again").await;
    assert_eq!(how, store::Urgent::Behind(urgent));
    e.run_to_end().await;
    assert_eq!(e.state(urgent).await.run.state, RunState::Succeeded);
    assert_eq!(e.state(second).await.run.state, RunState::Queued);
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    assert!(prompts.last().unwrap().contains("打断说明"), "{prompts:?}");
}

/// 正忙的 agent 调平台工具时捎带排队的消息；返回它这一轮的总结和轮到那条消息时发给 agent 的提示词。
async fn ride_along(restore_sessions: bool) -> Option<(String, String)> {
    let e = env_with(
        fast(),
        Some(GrantScope {
            platform_tools: vec!["schedule_list".into()],
            ..GrantScope::default()
        }),
        Arc::new(Tools),
    )
    .await?;
    e.fake.rec.lock().unwrap().restore_sessions = restore_sessions;
    let busy = e.queue("check news", None, 3).await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(busy, RunState::Running).await;
    let message = e.queue("say hello when you can", None, 3).await;
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    let rec = e.state(busy).await;
    assert_eq!(rec.run.state, RunState::Succeeded);
    assert!(e.state(message).await.announced_at.is_some());
    e.run_to_end().await;
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    Some((
        rec.run.summary.unwrap_or_default(),
        prompts.last().unwrap().clone(),
    ))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn queued_messages_ride_along_with_platform_tool_results() {
    let Some((said, next)) = ride_along(true).await else {
        return;
    };
    // 正忙的 agent 在工具结果后面看到了排队的消息。
    assert!(
        said.contains("平台捎带") && said.contains("1. say hello when you can"),
        "{said}"
    );
    // 轮到这条消息时提醒 agent 可能已经看过（会话接回了才这么说）。
    assert!(next.starts_with("（平台在你做上一个任务时"), "{next}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_seen_in_a_lost_session_comes_as_new() {
    let Some((said, next)) = ride_along(false).await else {
        return;
    };
    assert!(said.contains("平台捎带"), "{said}");
    // 会话没接回：agent 不记得看过，按新消息发。
    assert_eq!(next, "say hello when you can");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_urgent_message_is_not_lost_when_the_turn_ends_in_a_wait() {
    // 续租很久才一次：紧急消息到的时候这一轮已经在收尾，靠的是结束时的检查。
    let cfg = ExecutorConfig {
        renew_every: Duration::from_secs(30),
        ..fast()
    };
    let Some((e, _helper)) = delegation_env_with(cfg).await else {
        return;
    };
    let gate = Arc::new(tokio::sync::Notify::new());
    e.fake.rec.lock().unwrap().gate = Some(gate.clone());
    let lead = e
        .queue("slowly lead the team: loop forever please", None, 3)
        .await;
    let (_stop, h) = e.spawn().await;
    e.wait_state(lead, RunState::Running).await;
    let (urgent, how) = queue_urgent(&e, "say hello now").await;
    assert_eq!(how, store::Urgent::Interrupting(lead));
    // 紧急消息建好了，agent 再委派、结束这一轮。
    gate.notify_one();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
    // 这一轮委派完要转入等子任务：改成按打断结束，子任务一起停掉。
    let rec = e.state(lead).await;
    assert_eq!(rec.run.state, RunState::Cancelled, "{:?}", rec.run);
    assert_eq!(
        rec.run.state_reason.as_deref(),
        Some(store::INTERRUPTED_REASON)
    );
    let kids = children(&e, lead).await;
    assert_eq!(kids.len(), 1);
    assert_eq!(kids[0].state, RunState::Cancelled);
    e.run_to_end().await;
    assert_eq!(e.state(urgent).await.run.state, RunState::Succeeded);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn answers_are_handed_over_again_if_the_turn_with_them_breaks() {
    let Some((e, _helper)) = ask_env().await else {
        return;
    };
    let run = e.queue("ask teammate helper: say hello", None, 3).await;
    e.run_to_end().await;
    e.run_to_end().await;
    // 交还回答的这一轮刚开始就崩溃：回答还没记成已交还，下次再交。
    e.fake.rec.lock().unwrap().crash_on_results = 1;
    e.run_to_end().await;
    assert_eq!(e.state(run).await.run.state, RunState::Backoff);
    sqlx::query("UPDATE runs SET not_before = now() WHERE id = $1")
        .bind(run.0)
        .execute(e.t.db.pool())
        .await
        .unwrap();
    e.run_to_end().await;
    let rec = e.state(run).await;
    assert_eq!(rec.run.state, RunState::Succeeded, "{:?}", rec.run);
    assert_eq!(rec.run.summary.as_deref(), Some("got the answers"));
    let prompts = e.fake.rec.lock().unwrap().prompts.clone();
    let last = prompts.last().unwrap();
    assert!(last.contains("回答：Hello world"), "{last}");
    // 重交的：说明是续跑。
    assert!(last.starts_with("（续跑说明"), "{last}");
    let mut w = e.t.db.worker().await.unwrap();
    assert!(w.unreported_children(run).await.unwrap().is_empty());
    w.rollback().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_question_can_be_asked_again_once_its_outcome_was_handed_over() {
    let Some((e, _helper)) = ask_env().await else {
        return;
    };
    let run = e.queue("anything", None, 3).await;
    let id = |o: &ToolOutput| {
        let v: Value = serde_json::from_str(o.content[0]["text"].as_str().unwrap()).unwrap();
        v["run_id"].as_str().unwrap().to_owned()
    };
    // 还没答完时再问同一个问题：就是那一个（agent 重试）。
    let first = ask_directly(&e, run, "helper", "where is the data?").await;
    let again = ask_directly(&e, run, "helper", "where is the data?").await;
    assert_eq!(id(&first), id(&again));
    assert_eq!(asks(&e, run).await.len(), 1);
    // 超时没答上、结果交还了以后再问：真的再问一次。
    let q = asks(&e, run).await[0].id;
    sqlx::query("UPDATE runs SET answer_deadline = now() - interval '1 second' WHERE id = $1")
        .bind(q.0)
        .execute(e.t.db.pool())
        .await
        .unwrap();
    assert_eq!(e.exec.expire_asks().await.unwrap(), 1);
    // 超时了、结果还没交给 agent：还是那一个（结果会交过去）。
    let pending = ask_directly(&e, run, "helper", "where is the data?").await;
    assert_eq!(id(&pending), id(&first));
    let mut w = e.t.db.worker().await.unwrap();
    w.mark_handed(&[q]).await.unwrap();
    w.commit().await.unwrap();
    let third = ask_directly(&e, run, "helper", "where is the data?").await;
    assert!(!third.is_error);
    assert_ne!(id(&third), id(&first));
    assert_eq!(asks(&e, run).await.len(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_agent_can_ask_again_in_the_turn_that_brings_no_answer() {
    let Some((e, helper)) = ask_env().await else {
        return;
    };
    // helper 正忙，问题等到超时。
    let busy = {
        let mut tx = e.t.db.tenant(e.user).await.unwrap();
        let r = tx
            .create_run(&NewRun::new(
                helper.id,
                RunSource::User,
                "loop forever",
                &helper.agent_version,
            ))
            .await
            .unwrap();
        tx.commit().await.unwrap();
        r.id
    };
    let (_stop, h) = e.spawn().await;
    e.wait_state(busy, RunState::Running).await;
    let run = e
        .queue("re-ask if needed; ask teammate helper: say hello", None, 3)
        .await;
    e.run_to_end().await;
    let q = asks(&e, run).await[0].id;
    sqlx::query("UPDATE runs SET answer_deadline = now() - interval '1 second' WHERE id = $1")
        .bind(q.0)
        .execute(e.t.db.pool())
        .await
        .unwrap();
    assert_eq!(e.exec.expire_asks().await.unwrap(), 1);
    // 拿到“对方没回答”的这一轮里再问同一个问题：真的再问了一次，接着等它。
    e.run_to_end().await;
    let qs = asks(&e, run).await;
    assert_eq!(qs.len(), 2, "{qs:?}");
    assert_eq!(qs[1].state, RunState::Queued);
    assert_eq!(e.state(run).await.run.state, RunState::WaitingChildren);
    let mut tx = e.t.db.tenant(e.user).await.unwrap();
    tx.cancel_run(busy, None).await.unwrap();
    tx.commit().await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), h)
        .await
        .unwrap()
        .unwrap();
}

/// 计划设了成功时不通知（7.1，事件触发的计划常这么设）：成功的不推送、不进收件箱；失败的照样通知。
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn quiet_plans_only_notify_when_something_needs_the_user() {
    let Some(e) = env().await else { return };
    let quiet = PlanPolicy {
        notify_success: false,
        ..PlanPolicy::default()
    };
    let (_, ok) = queue_plan_run(&e, "say hello", quiet.clone()).await;
    e.run_to_end().await;
    assert_eq!(e.state(ok).await.run.state, RunState::Succeeded);
    assert!(e.inbox().await.iter().all(|i| i.run_id != Some(ok)));
    assert!(e.outbox_kinds().await.is_empty());
    // 失败了（只许试一次就崩溃）：照样通知。
    let (_, bad) = queue_plan_run(&e, "crash please", quiet).await;
    sqlx::query("UPDATE runs SET max_attempts = 1 WHERE id = $1")
        .bind(bad.0)
        .execute(e.t.db.pool())
        .await
        .unwrap();
    e.run_to_end().await;
    assert_eq!(e.state(bad).await.run.state, RunState::Failed);
    assert!(e.inbox().await.iter().any(|i| i.run_id == Some(bad)));
}
