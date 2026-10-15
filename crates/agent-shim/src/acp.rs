//! 用 ACP（Agent Client Protocol v1）驱动 agent：握手、建立或接回会话、转发任务、
//! 把会话更新翻译成平台事件、按预授权策略处理权限请求（架构方案 3.3、3.4）。
//!
//! 这里只用到 ACP 的一小部分，所以直接手写 JSON：发出去的请求按规范构造，收到的消息宽松解析。
//! 各家 agent 会带自己的扩展（`_meta`、未标准化的 `sessionUpdate` 种类），认不出的原样透传，
//! 不能因为一个新字段就断开。shim 不声明文件系统和终端能力，agent 用自己的工具在沙箱里干活。

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, anyhow};
use proto::shim::{
    DecisionSource, PermissionKind, PermissionOption, ShimCommand, ShimEvent, StopReason,
};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::events::EventSink;
use crate::jsonrpc::{Incoming, Peer, RpcError};
use crate::policy::{Decision, PermissionPolicy};
use crate::process::ProcessHandle;

pub const PROTOCOL_VERSION: u64 = 1;

pub struct ConnectOptions<'a> {
    pub cwd: &'a Path,
    pub mcp_servers: &'a [Value],
    /// 清单里验证过的会话能力。
    pub restore_supported: bool,
    pub per_session_mcp: bool,
    /// 上次的会话 id，有的话尝试接回。
    pub previous_session: Option<&'a str>,
    pub handshake_timeout: Duration,
}

pub struct Connected {
    pub session_id: String,
    pub agent_info: Option<Value>,
    pub restored: bool,
    /// 想接回但没接回来的原因。
    pub restore_error: Option<String>,
    /// 握手期间收到、还没处理的消息。
    pub backlog: Vec<Incoming>,
}

/// 握手并准备好会话。
pub async fn connect(
    peer: &Peer,
    incoming: &mut mpsc::UnboundedReceiver<Incoming>,
    opts: &ConnectOptions<'_>,
) -> anyhow::Result<Connected> {
    let timeout = opts.handshake_timeout;
    let init = with_timeout(
        timeout,
        "initialize",
        peer.request(
            "initialize",
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "clientCapabilities": {
                    "fs": {"readTextFile": false, "writeTextFile": false},
                    "terminal": false,
                },
                "clientInfo": {
                    "name": "thinktin-agent-shim",
                    "title": "ThinkTin",
                    "version": env!("CARGO_PKG_VERSION"),
                },
            }),
        ),
    )
    .await?;
    let version = init.get("protocolVersion").and_then(Value::as_u64);
    if version != Some(PROTOCOL_VERSION) {
        return Err(anyhow!(
            "agent negotiated ACP protocol version {version:?}, shim only speaks {PROTOCOL_VERSION}"
        ));
    }
    let caps = init
        .get("agentCapabilities")
        .cloned()
        .unwrap_or(Value::Null);
    let agent_info = init.get("agentInfo").cloned();
    let cwd = opts.cwd.display().to_string();
    let mcp_servers = if opts.per_session_mcp {
        Value::from(opts.mcp_servers.to_vec())
    } else {
        json!([])
    };

    let mut restore_error = None;
    let mut backlog = Vec::new();
    if let Some(previous) = opts.previous_session.filter(|_| opts.restore_supported) {
        let params = json!({"sessionId": previous, "cwd": cwd, "mcpServers": mcp_servers});
        let method = if caps.pointer("/sessionCapabilities/resume").is_some() {
            Some("session/resume")
        } else if caps.get("loadSession").and_then(Value::as_bool) == Some(true) {
            Some("session/load")
        } else {
            None
        };
        match method {
            Some(method) => {
                match with_timeout(timeout, method, peer.request(method, params)).await {
                    Ok(_) => {
                        // `session/load` 会先把历史以 session/update 重放一遍再回复，有的 agent
                        // （如 Hermes）在 `session/resume` 时也会重放。此时还没有任何一轮在跑，
                        // 这些内容平台的运行日志里已经有了，丢掉；其余消息留给驱动循环处理。
                        while let Ok(msg) = incoming.try_recv() {
                            if !is_history_replay(&msg) {
                                backlog.push(msg);
                            }
                        }
                        return Ok(Connected {
                            session_id: previous.to_owned(),
                            agent_info,
                            restored: true,
                            restore_error: None,
                            backlog,
                        });
                    }
                    Err(err) => restore_error = Some(format!("{method} failed: {err:#}")),
                }
            }
            None => {
                restore_error =
                    Some("agent supports neither session/resume nor session/load".into())
            }
        }
    }

    let created = with_timeout(
        timeout,
        "session/new",
        peer.request(
            "session/new",
            json!({"cwd": cwd, "mcpServers": mcp_servers}),
        ),
    )
    .await?;
    let session_id = created
        .get("sessionId")
        .and_then(Value::as_str)
        .context("session/new returned no sessionId")?
        .to_owned();
    Ok(Connected {
        session_id,
        agent_info,
        restored: false,
        restore_error,
        backlog,
    })
}

/// 接回会话时 agent 重放的历史内容。
fn is_history_replay(msg: &Incoming) -> bool {
    let Incoming::Notification { method, params } = msg else {
        return false;
    };
    let kind = params
        .pointer("/update/sessionUpdate")
        .and_then(Value::as_str);
    method == "session/update"
        && matches!(
            kind,
            Some(
                "user_message_chunk"
                    | "agent_message_chunk"
                    | "agent_thought_chunk"
                    | "tool_call"
                    | "tool_call_update"
                    | "plan"
            )
        )
}

async fn with_timeout(
    timeout: Duration,
    what: &str,
    fut: impl Future<Output = Result<Value, RpcError>>,
) -> anyhow::Result<Value> {
    match tokio::time::timeout(timeout, fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(err)) => Err(anyhow!("{what} failed: {err}")),
        Err(_) => Err(anyhow!("{what} timed out after {timeout:?}")),
    }
}

/// 一次连接结束的原因。
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// 平台要求停止。
    Shutdown,
    /// agent 进程退出或断开。
    AgentGone { code: Option<i32> },
}

struct PendingPermission {
    rpc_id: Value,
    run_id: Option<String>,
    options: Vec<PermissionOption>,
}

pub struct Driver<'a> {
    pub peer: Arc<Peer>,
    pub incoming: mpsc::UnboundedReceiver<Incoming>,
    pub session_id: String,
    pub sink: &'a EventSink,
    pub policy: &'a PermissionPolicy,
}

impl Driver<'_> {
    /// 处理平台指令和 agent 消息，直到平台要求停止或 agent 退出。
    pub async fn run(
        mut self,
        backlog: Vec<Incoming>,
        cmds: &mut mpsc::UnboundedReceiver<ShimCommand>,
        process: &mut ProcessHandle,
    ) -> Outcome {
        let mut turn: Option<String> = None;
        let mut pending: HashMap<String, PendingPermission> = HashMap::new();
        let mut next_permission = 1u64;
        let (done_tx, mut done_rx) = mpsc::unbounded_channel::<(String, Result<Value, RpcError>)>();
        let (expired_tx, mut expired_rx) = mpsc::unbounded_channel::<String>();

        {
            let mut state = State {
                turn: &mut turn,
                pending: &mut pending,
                next_permission: &mut next_permission,
                expired_tx: &expired_tx,
            };
            for msg in backlog {
                self.on_incoming(msg, &mut state);
            }
        }

        loop {
            // biased：agent 的消息先于“这一轮已结束”处理。agent 总是先发完 session/update
            // 再回复 session/prompt，读线程也按这个顺序投递，所以事件不会乱序。
            tokio::select! {
                biased;
                cmd = cmds.recv() => {
                    let Some(cmd) = cmd else { return Outcome::Shutdown };
                    match cmd {
                        ShimCommand::Shutdown => return Outcome::Shutdown,
                        ShimCommand::Prompt { run_id, text } => {
                            if let Some(active) = &turn {
                                self.sink.emit(ShimEvent::Error {
                                    run_id: Some(run_id),
                                    message: format!("agent is busy with run {active}"),
                                });
                                continue;
                            }
                            turn = Some(run_id.clone());
                            self.sink.emit(ShimEvent::TurnStarted { run_id: run_id.clone() });
                            let peer = self.peer.clone();
                            let done = done_tx.clone();
                            let params = json!({
                                "sessionId": self.session_id,
                                "prompt": [{"type": "text", "text": text}],
                            });
                            tokio::spawn(async move {
                                let result = peer.request("session/prompt", params).await;
                                let _ = done.send((run_id, result));
                            });
                        }
                        ShimCommand::Cancel { run_id } => {
                            if turn.as_deref() != Some(run_id.as_str()) {
                                self.sink.emit(ShimEvent::Error {
                                    run_id: Some(run_id),
                                    message: "no such active run".into(),
                                });
                                continue;
                            }
                            let _ = self
                                .peer
                                .notify("session/cancel", json!({"sessionId": self.session_id}));
                            // ACP 规定取消后客户端要以 cancelled 回复所有未决的权限请求。
                            for (request_id, p) in pending.drain() {
                                self.peer.respond(p.rpc_id, Ok(cancelled_outcome()));
                                self.sink.emit(ShimEvent::PermissionResolved {
                                    run_id: p.run_id,
                                    request_id,
                                    option_id: None,
                                    by: DecisionSource::Cancelled,
                                });
                            }
                        }
                        // 平台工具的指令由 main 交给工具桥，不会到这里。
                        ShimCommand::SetPlatformTools { .. } | ShimCommand::PlatformToolResult { .. } => {}
                        ShimCommand::PermissionDecision { request_id, option_id } => {
                            self.on_decision(&mut pending, request_id, option_id);
                        }
                    }
                }
                msg = self.incoming.recv() => {
                    let Some(msg) = msg else {
                        let code = crate::process::exit_code(&mut process.child).await;
                        return self.gone(turn, code);
                    };
                    let mut state = State {
                        turn: &mut turn,
                        pending: &mut pending,
                        next_permission: &mut next_permission,
                        expired_tx: &expired_tx,
                    };
                    self.on_incoming(msg, &mut state);
                }
                Some((run_id, result)) = done_rx.recv() => {
                    turn = None;
                    match result {
                        Ok(resp) => {
                            if let Some(usage) = resp.get("usage").filter(|u| !u.is_null()) {
                                self.sink.emit(ShimEvent::Usage {
                                    run_id: Some(run_id.clone()),
                                    raw: usage.clone(),
                                });
                            }
                            let stop_reason = resp
                                .get("stopReason")
                                .cloned()
                                .and_then(|v| serde_json::from_value(v).ok())
                                .unwrap_or(StopReason::Unknown);
                            self.sink.emit(ShimEvent::TurnEnded { run_id, stop_reason });
                        }
                        // 连接断了：下一次循环会从 incoming 收到 None，按 agent 退出处理。
                        Err(err) if err.code == RpcError::CLOSED => turn = Some(run_id),
                        Err(err) => self.sink.emit(ShimEvent::Error {
                            run_id: Some(run_id),
                            message: format!("session/prompt failed: {err}"),
                        }),
                    }
                }
                Some(request_id) = expired_rx.recv() => {
                    if let Some(p) = pending.remove(&request_id) {
                        self.peer.respond(p.rpc_id, Ok(cancelled_outcome()));
                        self.sink.emit(ShimEvent::PermissionResolved {
                            run_id: p.run_id,
                            request_id,
                            option_id: None,
                            by: DecisionSource::Timeout,
                        });
                    }
                }
                status = process.child.wait() => {
                    return self.gone(turn, status.ok().and_then(|s| s.code()));
                }
            }
        }
    }

    fn gone(&self, turn: Option<String>, code: Option<i32>) -> Outcome {
        if let Some(run_id) = turn {
            self.sink.emit(ShimEvent::Error {
                run_id: Some(run_id),
                message: "agent exited during the run".into(),
            });
        }
        Outcome::AgentGone { code }
    }

    fn on_incoming(&self, msg: Incoming, state: &mut State<'_>) {
        match msg {
            Incoming::Notification { method, params } if method == "session/update" => {
                if params.get("sessionId").and_then(Value::as_str) != Some(&self.session_id) {
                    tracing::debug!("ignoring update for another session: {params}");
                    return;
                }
                let update = params.get("update").cloned().unwrap_or(Value::Null);
                if let Some(event) = translate_update(update, state.turn.clone()) {
                    self.sink.emit(event);
                }
            }
            Incoming::Notification { method, .. } => {
                tracing::debug!("ignoring agent notification {method}");
            }
            Incoming::Request { id, method, params } if method == "session/request_permission" => {
                self.on_permission_request(id, params, state);
            }
            Incoming::Request { id, method, .. } => {
                tracing::warn!("agent called unsupported client method {method}");
                self.peer
                    .respond(id, Err(RpcError::method_not_found(&method)));
            }
        }
    }

    fn on_permission_request(&self, rpc_id: Value, params: Value, state: &mut State<'_>) {
        let tool_call = params.get("toolCall").cloned().unwrap_or(Value::Null);
        let options = parse_options(params.get("options"));
        let request_id = format!("perm-{}", *state.next_permission);
        *state.next_permission += 1;
        let run_id = state.turn.clone();
        let kind = tool_call.get("kind").and_then(Value::as_str);
        let decided = match self.policy.decide(kind, &options) {
            Decision::Select(option_id) => Some(Some(option_id)),
            Decision::Cancel => Some(None),
            Decision::Ask => None,
        };
        // 预授权策略直接决定的不发 PermissionRequested（平台会当成要用户批准、推送提醒），只发结果。
        if let Some(option_id) = decided {
            self.peer.respond(rpc_id, Ok(outcome(option_id.as_deref())));
            self.sink.emit(ShimEvent::PermissionResolved {
                run_id,
                request_id,
                option_id,
                by: DecisionSource::Policy,
            });
            return;
        }
        self.sink.emit(ShimEvent::PermissionRequested {
            run_id: run_id.clone(),
            request_id: request_id.clone(),
            title: str_field(&tool_call, "title"),
            options: options.clone(),
            tool_call: tool_call.clone(),
        });
        let expired = state.expired_tx.clone();
        let wait = self.policy.ask_timeout;
        let id = request_id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(wait).await;
            let _ = expired.send(id);
        });
        state.pending.insert(
            request_id,
            PendingPermission {
                rpc_id,
                run_id,
                options,
            },
        );
    }

    fn on_decision(
        &self,
        pending: &mut HashMap<String, PendingPermission>,
        request_id: String,
        option_id: Option<String>,
    ) {
        let Some(p) = pending.get(&request_id) else {
            self.sink.emit(ShimEvent::Error {
                run_id: None,
                message: format!("no pending permission request {request_id}"),
            });
            return;
        };
        if let Some(opt) = &option_id
            && !p.options.iter().any(|o| &o.option_id == opt)
        {
            self.sink.emit(ShimEvent::Error {
                run_id: p.run_id.clone(),
                message: format!("permission request {request_id} has no option {opt}"),
            });
            return;
        }
        let p = pending.remove(&request_id).expect("checked above");
        self.peer
            .respond(p.rpc_id, Ok(outcome(option_id.as_deref())));
        self.sink.emit(ShimEvent::PermissionResolved {
            run_id: p.run_id,
            request_id,
            option_id,
            by: DecisionSource::User,
        });
    }
}

struct State<'s> {
    turn: &'s mut Option<String>,
    pending: &'s mut HashMap<String, PendingPermission>,
    next_permission: &'s mut u64,
    expired_tx: &'s mpsc::UnboundedSender<String>,
}

fn outcome(option_id: Option<&str>) -> Value {
    match option_id {
        Some(id) => json!({"outcome": {"outcome": "selected", "optionId": id}}),
        None => cancelled_outcome(),
    }
}

fn cancelled_outcome() -> Value {
    json!({"outcome": {"outcome": "cancelled"}})
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn parse_options(v: Option<&Value>) -> Vec<PermissionOption> {
    v.and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|o| {
                    Some(PermissionOption {
                        option_id: str_field(o, "optionId")?,
                        name: str_field(o, "name").unwrap_or_default(),
                        kind: o
                            .get("kind")
                            .cloned()
                            .and_then(|k| serde_json::from_value(k).ok())
                            .unwrap_or(PermissionKind::Unknown),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 把 ACP 的 `session/update` 翻译成平台事件。用户消息的回显不上报。
pub fn translate_update(update: Value, run_id: Option<String>) -> Option<ShimEvent> {
    let kind = update
        .get("sessionUpdate")
        .and_then(Value::as_str)?
        .to_owned();
    let text = || {
        let content = update.get("content")?;
        (content.get("type").and_then(Value::as_str) == Some("text"))
            .then(|| str_field(content, "text"))
            .flatten()
    };
    let event = match kind.as_str() {
        "user_message_chunk" => return None,
        "agent_message_chunk" => match text() {
            Some(text) => ShimEvent::MessageChunk { run_id, text },
            None => ShimEvent::AgentUpdate {
                run_id,
                kind,
                raw: update,
            },
        },
        "agent_thought_chunk" => match text() {
            Some(text) => ShimEvent::ThoughtChunk { run_id, text },
            None => ShimEvent::AgentUpdate {
                run_id,
                kind,
                raw: update,
            },
        },
        "tool_call" => ShimEvent::ToolCall {
            run_id,
            tool_call_id: str_field(&update, "toolCallId").unwrap_or_default(),
            title: str_field(&update, "title"),
            kind: str_field(&update, "kind"),
            status: str_field(&update, "status"),
            raw: update,
        },
        "tool_call_update" => ShimEvent::ToolCallUpdate {
            run_id,
            tool_call_id: str_field(&update, "toolCallId").unwrap_or_default(),
            status: str_field(&update, "status"),
            raw: update,
        },
        "plan" => ShimEvent::Plan {
            run_id,
            entries: update.get("entries").cloned().unwrap_or(Value::Null),
        },
        "usage_update" => ShimEvent::Usage {
            run_id,
            raw: update,
        },
        _ => ShimEvent::AgentUpdate {
            run_id,
            kind,
            raw: update,
        },
    };
    Some(event)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r() -> Option<String> {
        Some("r1".into())
    }

    #[test]
    fn text_chunks() {
        let ev = translate_update(
            json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}),
            r(),
        );
        assert_eq!(
            ev,
            Some(ShimEvent::MessageChunk {
                run_id: r(),
                text: "hi".into()
            })
        );
        let ev = translate_update(
            json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hm"}}),
            None,
        );
        assert_eq!(
            ev,
            Some(ShimEvent::ThoughtChunk {
                run_id: None,
                text: "hm".into()
            })
        );
        let image = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "image", "data": "..."}});
        assert!(matches!(
            translate_update(image, r()),
            Some(ShimEvent::AgentUpdate { kind, .. }) if kind == "agent_message_chunk"
        ));
        assert_eq!(
            translate_update(
                json!({"sessionUpdate": "user_message_chunk", "content": {}}),
                r()
            ),
            None
        );
    }

    #[test]
    fn tool_calls_and_unknown_kinds() {
        let ev = translate_update(
            json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read a", "kind": "read", "status": "pending"}),
            r(),
        )
        .unwrap();
        let ShimEvent::ToolCall {
            tool_call_id,
            kind,
            status,
            ..
        } = ev
        else {
            panic!("{ev:?}")
        };
        assert_eq!(
            (tool_call_id.as_str(), kind.as_deref(), status.as_deref()),
            ("t1", Some("read"), Some("pending"))
        );

        let ev =
            translate_update(json!({"sessionUpdate": "subagent_update", "x": 1}), r()).unwrap();
        assert!(matches!(ev, ShimEvent::AgentUpdate { kind, .. } if kind == "subagent_update"));
        assert_eq!(translate_update(json!({"nothing": 1}), r()), None);
    }

    #[test]
    fn permission_options_parse_leniently() {
        let opts = parse_options(Some(&json!([
            {"optionId": "a", "name": "Allow", "kind": "allow_once"},
            {"optionId": "b", "kind": "weird"},
            {"name": "no id"},
        ])));
        assert_eq!(opts.len(), 2);
        assert_eq!(opts[0].kind, PermissionKind::AllowOnce);
        assert_eq!(opts[1].kind, PermissionKind::Unknown);
    }
}
