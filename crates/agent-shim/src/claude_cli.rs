//! Claude 的第二种接入方式：直接驱动 Claude Code 命令行的 stream-json 模式，
//! 不经过 ACP 适配器（和 Claude Agent SDK 用的是同一套协议）。
//!
//! - 启动：`claude -p --input-format stream-json --output-format stream-json --verbose
//!   --include-partial-messages --permission-prompt-tool=stdio --permission-mode default`，
//!   新会话用 `--session-id` 指定 id，接回用 `--resume`。
//! - 握手：发 `initialize` 控制请求，收到回复才算就绪。要接回的会话不存在时，
//!   命令行会在回复前直接退出，这时改开新会话并上报 `session_lost`。
//! - 权限：命令行通过 `can_use_tool` 控制请求征求许可，按预授权策略决定或交给用户。
//!   必须显式传 `--permission-mode default`，否则新版本的默认模式不会来问。
//! - 取消：发 `interrupt` 控制请求。

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{Context, anyhow};
use catalog::Harness;
use proto::shim::{
    DecisionSource, PermissionKind, PermissionOption, SHIM_PROTOCOL_VERSION, ShimCommand,
    ShimEvent, StopReason,
};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::acp::Outcome;
use crate::config::random_bytes;
use crate::events::EventSink;
use crate::policy::{Decision, PermissionPolicy};
use crate::process::{self, Launch, ProcessHandle, StderrTail};
use crate::shim::{self, ShimConfig};

const STOP_GRACE: Duration = Duration::from_secs(3);
const INIT_REQUEST_ID: &str = "thinktin-init";

pub async fn run(
    cfg: &ShimConfig,
    harness: &Harness,
    launch: &Launch,
    cmds: &mut mpsc::UnboundedReceiver<ShimCommand>,
    sink: &EventSink,
) -> anyhow::Result<Outcome> {
    let saved = shim::previous_session(cfg, harness).filter(|_| harness.session.restore);
    let mut lost = None;
    if let Some(prev) = &saved {
        match start(cfg, launch, SessionArg::Resume(&prev.session_id)).await {
            Ok(conn) => return drive(cfg, harness, conn, true, cmds, sink).await,
            Err(err) => lost = Some(format!("--resume failed: {err:#}")),
        }
    }
    let session_id = uuid_v4()?;
    let conn = start(cfg, launch, SessionArg::New(&session_id)).await?;
    if let (Some(reason), Some(prev)) = (lost, &saved) {
        sink.emit(ShimEvent::SessionLost {
            previous_session_id: prev.session_id.clone(),
            reason,
        });
    }
    drive(cfg, harness, conn, false, cmds, sink).await
}

enum SessionArg<'a> {
    New(&'a str),
    Resume(&'a str),
}

struct Conn {
    proc: ProcessHandle,
    out: mpsc::UnboundedSender<String>,
    rx: mpsc::UnboundedReceiver<Value>,
    stderr_tail: StderrTail,
    session_id: String,
    init: Value,
    backlog: Vec<Value>,
}

impl Conn {
    fn send(&self, msg: Value) {
        let _ = self.out.send(msg.to_string());
    }
}

/// 启动命令行并完成 `initialize` 握手。
async fn start(cfg: &ShimConfig, launch: &Launch, session: SessionArg<'_>) -> anyhow::Result<Conn> {
    let mut launch = launch.clone();
    launch.command.extend(
        [
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--input-format",
            "stream-json",
            "--include-partial-messages",
            "--permission-prompt-tool=stdio",
            "--permission-mode",
            "default",
        ]
        .map(String::from),
    );
    let session_id = match session {
        SessionArg::New(id) => {
            launch.command.extend(["--session-id".into(), id.into()]);
            id
        }
        SessionArg::Resume(id) => {
            launch.command.extend(["--resume".into(), id.into()]);
            id
        }
    };
    if let Some(mcp) = mcp_config(&cfg.mcp_servers) {
        launch.command.extend(["--mcp-config".into(), mcp]);
    }

    let mut spawned = process::spawn(&launch, true)?;
    let stdout = spawned.stdout.take().context("stdout not captured")?;
    let mut stdin = spawned.stdin.take().context("stdin not captured")?;
    let (msg_tx, mut rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            match serde_json::from_str::<Value>(&line) {
                Ok(v) => {
                    if msg_tx.send(v).is_err() {
                        break;
                    }
                }
                Err(_) => tracing::warn!("ignoring non-JSON line from claude: {line}"),
            }
        }
    });
    let (out, mut out_rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        while let Some(mut line) = out_rx.recv().await {
            line.push('\n');
            if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
                break;
            }
        }
    });

    let _ = out.send(
        json!({
            "type": "control_request",
            "request_id": INIT_REQUEST_ID,
            "request": {"subtype": "initialize", "hooks": {}},
        })
        .to_string(),
    );
    let mut backlog = Vec::new();
    let handshake = async {
        loop {
            let Some(msg) = rx.recv().await else {
                return Err(anyhow!("claude exited before answering initialize"));
            };
            let is_init_reply = msg["type"] == "control_response"
                && msg["response"]["request_id"] == INIT_REQUEST_ID;
            if is_init_reply {
                return match msg["response"]["subtype"].as_str() {
                    Some("success") => Ok(msg["response"]["response"].clone()),
                    _ => Err(anyhow!("initialize failed: {}", msg["response"])),
                };
            }
            if msg["type"] == "result" && msg["is_error"] == true {
                return Err(anyhow!("claude reported {}", msg["subtype"]));
            }
            backlog.push(msg);
        }
    };
    let init = match tokio::time::timeout(cfg.handshake_timeout, handshake).await {
        Ok(Ok(init)) => init,
        Ok(Err(err)) => {
            drop(out);
            spawned.proc.terminate(STOP_GRACE).await;
            return Err(err.context(format!(
                "recent stderr:\n{}",
                spawned.stderr_tail.snapshot()
            )));
        }
        Err(_) => {
            drop(out);
            spawned.proc.terminate(STOP_GRACE).await;
            return Err(anyhow!(
                "initialize timed out after {:?}",
                cfg.handshake_timeout
            ));
        }
    };
    Ok(Conn {
        proc: spawned.proc,
        out,
        rx,
        stderr_tail: spawned.stderr_tail,
        session_id: session_id.to_owned(),
        init,
        backlog,
    })
}

struct PendingPermission {
    control_id: String,
    run_id: Option<String>,
    input: Value,
    suggestions: Value,
}

struct Turn {
    run_id: String,
    cancel_requested: bool,
}

async fn drive(
    cfg: &ShimConfig,
    harness: &Harness,
    mut conn: Conn,
    restored: bool,
    cmds: &mut mpsc::UnboundedReceiver<ShimCommand>,
    sink: &EventSink,
) -> anyhow::Result<Outcome> {
    shim::remember_session(cfg, harness, &conn.session_id);
    sink.emit(ShimEvent::Ready {
        protocol_version: SHIM_PROTOCOL_VERSION,
        agent_id: cfg.manifest.agent.id.clone(),
        harness: harness.id.clone(),
        agent_info: Some(json!({
            "name": "claude-code",
            "version": conn.init["claude_code_version"],
        })),
        session_id: conn.session_id.clone(),
        session_restored: restored,
    });

    let mut d = Driver {
        sink,
        policy: &cfg.policy,
        turn: None,
        pending: HashMap::new(),
        next_permission: 1,
        next_control: 1,
        expired_tx: mpsc::unbounded_channel().0,
    };
    let (expired_tx, mut expired_rx) = mpsc::unbounded_channel::<String>();
    d.expired_tx = expired_tx;
    for msg in std::mem::take(&mut conn.backlog) {
        d.on_message(&conn, msg);
    }

    let outcome = loop {
        tokio::select! {
            biased;
            cmd = cmds.recv() => match cmd {
                None | Some(ShimCommand::Shutdown) => break Outcome::Shutdown,
                Some(cmd) => d.on_command(&conn, cmd),
            },
            msg = conn.rx.recv() => match msg {
                Some(msg) => d.on_message(&conn, msg),
                None => {
                    let code = conn.proc.child.wait().await.ok().and_then(|s| s.code());
                    break d.gone(code);
                }
            },
            Some(request_id) = expired_rx.recv() => d.expire(&conn, request_id),
            status = conn.proc.child.wait() => {
                break d.gone(status.ok().and_then(|s| s.code()));
            }
        }
    };
    if let Outcome::AgentGone { code } = &outcome {
        tracing::warn!(
            "claude exited (code {code:?}); recent stderr:\n{}",
            conn.stderr_tail.snapshot()
        );
    }
    // 关闭 stdin，命令行读到 EOF 后自行退出。
    drop(conn.out);
    conn.proc.terminate(STOP_GRACE).await;
    Ok(outcome)
}

struct Driver<'a> {
    sink: &'a EventSink,
    policy: &'a PermissionPolicy,
    turn: Option<Turn>,
    pending: HashMap<String, PendingPermission>,
    next_permission: u64,
    next_control: u64,
    expired_tx: mpsc::UnboundedSender<String>,
}

impl Driver<'_> {
    fn run_id(&self) -> Option<String> {
        self.turn.as_ref().map(|t| t.run_id.clone())
    }

    fn gone(&mut self, code: Option<i32>) -> Outcome {
        if let Some(turn) = self.turn.take() {
            self.sink.emit(ShimEvent::Error {
                run_id: Some(turn.run_id),
                message: "agent exited during the run".into(),
            });
        }
        Outcome::AgentGone { code }
    }

    fn on_command(&mut self, conn: &Conn, cmd: ShimCommand) {
        match cmd {
            ShimCommand::Shutdown => unreachable!("handled by the caller"),
            ShimCommand::Prompt { run_id, text } => {
                if let Some(turn) = &self.turn {
                    self.sink.emit(ShimEvent::Error {
                        run_id: Some(run_id),
                        message: format!("agent is busy with run {}", turn.run_id),
                    });
                    return;
                }
                conn.send(json!({
                    "type": "user",
                    "message": {"role": "user", "content": [{"type": "text", "text": text}]},
                    "parent_tool_use_id": null,
                    "session_id": conn.session_id,
                }));
                self.turn = Some(Turn {
                    run_id,
                    cancel_requested: false,
                });
            }
            ShimCommand::Cancel { run_id } => {
                let Some(turn) = self.turn.as_mut().filter(|t| t.run_id == run_id) else {
                    self.sink.emit(ShimEvent::Error {
                        run_id: Some(run_id),
                        message: "no such active run".into(),
                    });
                    return;
                };
                turn.cancel_requested = true;
                let id = format!("thinktin-ctl-{}", self.next_control);
                self.next_control += 1;
                conn.send(json!({
                    "type": "control_request",
                    "request_id": id,
                    "request": {"subtype": "interrupt"},
                }));
                for (request_id, p) in std::mem::take(&mut self.pending) {
                    respond_permission(conn, &p, None, "The run was cancelled.");
                    self.sink.emit(ShimEvent::PermissionResolved {
                        run_id: p.run_id,
                        request_id,
                        option_id: None,
                        by: DecisionSource::Cancelled,
                    });
                }
            }
            ShimCommand::PermissionDecision {
                request_id,
                option_id,
            } => {
                if !self.pending.contains_key(&request_id) {
                    self.sink.emit(ShimEvent::Error {
                        run_id: None,
                        message: format!("no pending permission request {request_id}"),
                    });
                    return;
                }
                if let Some(opt) = &option_id
                    && !permission_options().iter().any(|o| &o.option_id == opt)
                {
                    self.sink.emit(ShimEvent::Error {
                        run_id: self.run_id(),
                        message: format!("permission request {request_id} has no option {opt}"),
                    });
                    return;
                }
                let p = self.pending.remove(&request_id).expect("checked above");
                respond_permission(conn, &p, option_id.as_deref(), "Rejected by the user.");
                self.sink.emit(ShimEvent::PermissionResolved {
                    run_id: p.run_id,
                    request_id,
                    option_id,
                    by: DecisionSource::User,
                });
            }
        }
    }

    fn expire(&mut self, conn: &Conn, request_id: String) {
        if let Some(p) = self.pending.remove(&request_id) {
            respond_permission(conn, &p, None, "No decision was made in time.");
            self.sink.emit(ShimEvent::PermissionResolved {
                run_id: p.run_id,
                request_id,
                option_id: None,
                by: DecisionSource::Timeout,
            });
        }
    }

    fn on_message(&mut self, conn: &Conn, msg: Value) {
        let run_id = self.run_id();
        match msg["type"].as_str().unwrap_or_default() {
            "stream_event" => {
                if let Some(ev) = translate_stream_event(&msg["event"], run_id) {
                    self.sink.emit(ev);
                }
            }
            "assistant" => {
                for ev in tool_calls(&msg["message"], run_id) {
                    self.sink.emit(ev);
                }
            }
            "user" => {
                for ev in tool_results(&msg["message"], run_id) {
                    self.sink.emit(ev);
                }
            }
            "result" => self.on_result(msg),
            "control_request" => self.on_control_request(conn, msg),
            "control_response" | "keep_alive" => {}
            "system" => match msg["subtype"].as_str() {
                Some("init" | "status") => {}
                other => self.sink.emit(ShimEvent::AgentUpdate {
                    run_id,
                    kind: format!("system/{}", other.unwrap_or("unknown")),
                    raw: msg,
                }),
            },
            other => self.sink.emit(ShimEvent::AgentUpdate {
                run_id,
                kind: other.to_owned(),
                raw: msg,
            }),
        }
    }

    fn on_result(&mut self, msg: Value) {
        let Some(turn) = self.turn.take() else {
            tracing::debug!("result outside of a run: {msg}");
            return;
        };
        let usage = json!({
            "usage": msg["usage"],
            "total_cost_usd": msg["total_cost_usd"],
            "num_turns": msg["num_turns"],
            "duration_ms": msg["duration_ms"],
        });
        self.sink.emit(ShimEvent::Usage {
            run_id: Some(turn.run_id.clone()),
            raw: usage,
        });
        let stop_reason = stop_reason(&msg, turn.cancel_requested);
        if msg["is_error"] == true && !turn.cancel_requested {
            let detail = msg["result"]
                .as_str()
                .or(msg["subtype"].as_str())
                .unwrap_or("unknown error");
            self.sink.emit(ShimEvent::Error {
                run_id: Some(turn.run_id.clone()),
                message: format!("claude: {detail}"),
            });
        }
        self.sink.emit(ShimEvent::TurnEnded {
            run_id: turn.run_id,
            stop_reason,
        });
    }

    fn on_control_request(&mut self, conn: &Conn, msg: Value) {
        let control_id = msg["request_id"].as_str().unwrap_or_default().to_owned();
        let req = &msg["request"];
        if req["subtype"] != "can_use_tool" {
            conn.send(json!({
                "type": "control_response",
                "response": {
                    "subtype": "error",
                    "request_id": control_id,
                    "error": format!("{} is not supported by the ThinkTin agent-shim", req["subtype"]),
                },
            }));
            return;
        }
        let tool_name = req["tool_name"].as_str().unwrap_or_default();
        let kind = tool_kind(tool_name);
        let title = req["title"]
            .as_str()
            .or(req["display_name"].as_str())
            .map(str::to_owned)
            .unwrap_or_else(|| tool_title(tool_name, &req["input"]));
        let request_id = format!("perm-{}", self.next_permission);
        self.next_permission += 1;
        let run_id = self.run_id();
        let options = permission_options();
        self.sink.emit(ShimEvent::PermissionRequested {
            run_id: run_id.clone(),
            request_id: request_id.clone(),
            title: Some(title.clone()),
            options: options.clone(),
            tool_call: json!({
                "toolCallId": req["tool_use_id"],
                "title": title,
                "kind": kind,
                "rawInput": req["input"],
            }),
        });
        let pending = PendingPermission {
            control_id,
            run_id: run_id.clone(),
            input: req["input"].clone(),
            suggestions: req["permission_suggestions"].clone(),
        };
        let option_id = match self.policy.decide(Some(kind), &options) {
            Decision::Select(id) => Some(id),
            Decision::Cancel => None,
            Decision::Ask => {
                let expired = self.expired_tx.clone();
                let wait = self.policy.ask_timeout;
                let id = request_id.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(wait).await;
                    let _ = expired.send(id);
                });
                self.pending.insert(request_id, pending);
                return;
            }
        };
        respond_permission(
            conn,
            &pending,
            option_id.as_deref(),
            "Not within the run's pre-authorized scope.",
        );
        self.sink.emit(ShimEvent::PermissionResolved {
            run_id,
            request_id,
            option_id,
            by: DecisionSource::Policy,
        });
    }
}

/// 命令行的权限请求没有选项列表，统一给出这三个，语义同 ACP。
fn permission_options() -> Vec<PermissionOption> {
    [
        ("allow", "Allow", PermissionKind::AllowOnce),
        ("allow_always", "Always allow", PermissionKind::AllowAlways),
        ("deny", "Reject", PermissionKind::RejectOnce),
    ]
    .into_iter()
    .map(|(id, name, kind)| PermissionOption {
        option_id: id.into(),
        name: name.into(),
        kind,
    })
    .collect()
}

fn respond_permission(
    conn: &Conn,
    p: &PendingPermission,
    option_id: Option<&str>,
    deny_message: &str,
) {
    let decision = match option_id {
        Some("allow") => json!({"behavior": "allow", "updatedInput": p.input}),
        Some("allow_always") => {
            let mut d = json!({"behavior": "allow", "updatedInput": p.input});
            if p.suggestions.is_array() {
                d["updatedPermissions"] = p.suggestions.clone();
            }
            d
        }
        _ => json!({"behavior": "deny", "message": deny_message}),
    };
    conn.send(json!({
        "type": "control_response",
        "response": {"subtype": "success", "request_id": p.control_id, "response": decision},
    }));
}

/// 和 claude-agent-acp 的分类一致，供预授权策略使用。
fn tool_kind(name: &str) -> &'static str {
    match name {
        "Read" | "NotebookRead" => "read",
        "Glob" | "Grep" | "LS" | "ToolSearch" => "search",
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => "edit",
        "Bash" | "BashOutput" | "KillShell" | "KillBash" => "execute",
        "WebFetch" | "WebSearch" => "fetch",
        "TodoWrite" | "Task" | "Agent" => "think",
        "ExitPlanMode" | "EnterPlanMode" => "switch_mode",
        _ => "other",
    }
}

fn tool_title(name: &str, input: &Value) -> String {
    [
        "description",
        "command",
        "file_path",
        "pattern",
        "url",
        "query",
    ]
    .iter()
    .find_map(|k| input[*k].as_str())
    .map_or_else(|| name.to_owned(), |detail| format!("{name}: {detail}"))
}

fn translate_stream_event(ev: &Value, run_id: Option<String>) -> Option<ShimEvent> {
    if ev["type"] != "content_block_delta" {
        return None;
    }
    let delta = &ev["delta"];
    match delta["type"].as_str()? {
        "text_delta" => Some(ShimEvent::MessageChunk {
            run_id,
            text: delta["text"].as_str()?.to_owned(),
        }),
        "thinking_delta" => Some(ShimEvent::ThoughtChunk {
            run_id,
            text: delta["thinking"].as_str()?.to_owned(),
        }),
        _ => None,
    }
}

fn blocks(message: &Value) -> impl Iterator<Item = &Value> {
    message["content"].as_array().into_iter().flatten()
}

fn tool_calls(message: &Value, run_id: Option<String>) -> Vec<ShimEvent> {
    blocks(message)
        .filter(|b| b["type"] == "tool_use")
        .map(|b| {
            let name = b["name"].as_str().unwrap_or_default();
            ShimEvent::ToolCall {
                run_id: run_id.clone(),
                tool_call_id: b["id"].as_str().unwrap_or_default().to_owned(),
                title: Some(tool_title(name, &b["input"])),
                kind: Some(tool_kind(name).to_owned()),
                status: Some("pending".into()),
                raw: b.clone(),
            }
        })
        .collect()
}

fn tool_results(message: &Value, run_id: Option<String>) -> Vec<ShimEvent> {
    blocks(message)
        .filter(|b| b["type"] == "tool_result")
        .map(|b| ShimEvent::ToolCallUpdate {
            run_id: run_id.clone(),
            tool_call_id: b["tool_use_id"].as_str().unwrap_or_default().to_owned(),
            status: Some(
                if b["is_error"] == true {
                    "failed"
                } else {
                    "completed"
                }
                .into(),
            ),
            raw: b.clone(),
        })
        .collect()
}

fn stop_reason(result: &Value, cancel_requested: bool) -> StopReason {
    if cancel_requested {
        return StopReason::Cancelled;
    }
    match (result["subtype"].as_str(), result["stop_reason"].as_str()) {
        (Some("error_max_turns"), _) => StopReason::MaxTurnRequests,
        (_, Some("max_tokens")) => StopReason::MaxTokens,
        (_, Some("refusal")) => StopReason::Refusal,
        (Some("success"), Some("end_turn") | None) => StopReason::EndTurn,
        _ => StopReason::Unknown,
    }
}

/// ACP 格式的 MCP 服务器列表转成 `--mcp-config` 的 JSON。
fn mcp_config(servers: &[Value]) -> Option<String> {
    let pairs = |v: &Value| -> serde_json::Map<String, Value> {
        v.as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| Some((p["name"].as_str()?.to_owned(), p["value"].clone())))
            .collect()
    };
    let mut out = serde_json::Map::new();
    for s in servers {
        let Some(name) = s["name"].as_str() else {
            continue;
        };
        let entry = match s["type"].as_str() {
            Some(t @ ("http" | "sse")) => {
                json!({"type": t, "url": s["url"], "headers": pairs(&s["headers"])})
            }
            _ => json!({"command": s["command"], "args": s["args"], "env": pairs(&s["env"])}),
        };
        out.insert(name.to_owned(), entry);
    }
    (!out.is_empty()).then(|| json!({"mcpServers": out}).to_string())
}

fn uuid_v4() -> anyhow::Result<String> {
    let mut b = random_bytes(16)?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_deltas_become_chunks() {
        let ev = json!({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "hi"}});
        assert_eq!(
            translate_stream_event(&ev, Some("r".into())),
            Some(ShimEvent::MessageChunk {
                run_id: Some("r".into()),
                text: "hi".into()
            })
        );
        let ev = json!({"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "hm"}});
        assert!(matches!(
            translate_stream_event(&ev, None),
            Some(ShimEvent::ThoughtChunk { .. })
        ));
        assert_eq!(
            translate_stream_event(&json!({"type": "message_start"}), None),
            None
        );
    }

    #[test]
    fn tool_use_and_results() {
        let msg = json!({"content": [
            {"type": "text", "text": "x"},
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls", "description": "List files"}},
        ]});
        let evs = tool_calls(&msg, None);
        assert_eq!(evs.len(), 1);
        let ShimEvent::ToolCall {
            tool_call_id,
            title,
            kind,
            ..
        } = &evs[0]
        else {
            panic!()
        };
        assert_eq!(
            (tool_call_id.as_str(), kind.as_deref()),
            ("t1", Some("execute"))
        );
        assert_eq!(title.as_deref(), Some("Bash: List files"));

        let msg = json!({"content": [{"type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "no"}]});
        let evs = tool_results(&msg, None);
        assert!(
            matches!(&evs[0], ShimEvent::ToolCallUpdate { status: Some(s), .. } if s == "failed")
        );
    }

    #[test]
    fn stop_reasons() {
        let r = |v: Value| stop_reason(&v, false);
        assert_eq!(
            r(json!({"subtype": "success", "stop_reason": "end_turn"})),
            StopReason::EndTurn
        );
        assert_eq!(
            r(json!({"subtype": "success", "stop_reason": null})),
            StopReason::EndTurn
        );
        assert_eq!(
            r(json!({"subtype": "error_max_turns"})),
            StopReason::MaxTurnRequests
        );
        assert_eq!(
            r(json!({"subtype": "success", "stop_reason": "max_tokens"})),
            StopReason::MaxTokens
        );
        assert_eq!(
            r(json!({"subtype": "error_during_execution"})),
            StopReason::Unknown
        );
        assert_eq!(
            stop_reason(&json!({"subtype": "success"}), true),
            StopReason::Cancelled
        );
    }

    #[test]
    fn mcp_servers_convert_from_acp_format() {
        assert_eq!(mcp_config(&[]), None);
        let cfg = mcp_config(&[
            json!({"name": "files", "command": "mcp-files", "args": ["--root", "/w"], "env": [{"name": "A", "value": "1"}]}),
            json!({"type": "http", "name": "platform", "url": "http://127.0.0.1:9/mcp", "headers": [{"name": "X", "value": "y"}]}),
        ])
        .unwrap();
        let v: Value = serde_json::from_str(&cfg).unwrap();
        assert_eq!(v["mcpServers"]["files"]["env"]["A"], "1");
        assert_eq!(v["mcpServers"]["files"]["args"][1], "/w");
        assert_eq!(v["mcpServers"]["platform"]["headers"]["X"], "y");
    }

    #[test]
    fn uuid_format() {
        let id = uuid_v4().unwrap();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert!(matches!(&id[19..20], "8" | "9" | "a" | "b"));
    }
}
