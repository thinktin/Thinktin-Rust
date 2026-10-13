//! 测试用的假 ACP agent：按提示词里的关键字表演各种行为，供 agent-shim 的集成测试驱动。
//!
//! - `tool[:kind]`：发起一次工具调用并请求权限，按结果回复 allowed / rejected，被放弃则以 cancelled 结束
//! - `slow`：慢慢输出，直到收到 session/cancel
//! - `crash`：直接退出（模拟 agent 崩溃）
//! - `env`：把关心的环境变量回报出来，检查 shim 的环境隔离
//! - `usage`：上报用量
//! - 其他：回显
//!
//! 环境变量 `FAKE_ACP_CAPS` 控制声明的会话能力：`resume`（默认）、`load` 或 `none`。

use std::collections::BTreeSet;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Value, json};

fn main() {
    // 有的 agent 会往 stdout 打非 JSON 的东西，shim 要能跳过。
    println!("fake agent booting");
    let (tx, rx) = mpsc::channel::<Value>();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if let Ok(v) = serde_json::from_str(&line)
                && tx.send(v).is_err()
            {
                break;
            }
        }
    });
    let mut agent = Agent {
        rx,
        next_id: 1000,
        sessions: load_sessions(),
        cancelled: false,
    };
    while let Ok(msg) = agent.rx.recv() {
        agent.handle(msg);
    }
}

struct Agent {
    rx: mpsc::Receiver<Value>,
    next_id: u64,
    sessions: BTreeSet<String>,
    cancelled: bool,
}

fn send(v: Value) {
    let mut out = std::io::stdout().lock();
    writeln!(out, "{v}").unwrap();
    out.flush().unwrap();
}

fn sessions_path() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap()).join(".fake-agent/sessions.json")
}

fn load_sessions() -> BTreeSet<String> {
    std::fs::read_to_string(sessions_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

impl Agent {
    fn save_sessions(&self) {
        let path = sessions_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, serde_json::to_string(&self.sessions).unwrap()).unwrap();
    }

    fn handle(&mut self, msg: Value) {
        let method = msg["method"].as_str().unwrap_or_default().to_owned();
        let id = msg.get("id").cloned();
        let params = msg["params"].clone();
        match (method.as_str(), id) {
            ("session/cancel", None) => self.cancelled = true,
            ("initialize", Some(id)) => {
                let caps = match std::env::var("FAKE_ACP_CAPS").as_deref() {
                    Ok("load") => json!({"loadSession": true}),
                    Ok("none") => json!({}),
                    _ => json!({"sessionCapabilities": {"resume": {}}}),
                };
                reply(
                    id,
                    json!({
                        "protocolVersion": 1,
                        "agentCapabilities": caps,
                        "agentInfo": {"name": "fake-acp-agent", "version": "0.0.1"},
                        "authMethods": [],
                    }),
                );
            }
            ("session/new", Some(id)) => {
                let sid = format!("fake-{}", self.sessions.len() + 1);
                self.sessions.insert(sid.clone());
                self.save_sessions();
                reply(id, json!({"sessionId": sid}));
            }
            ("session/resume", Some(id)) => {
                let sid = params["sessionId"].as_str().unwrap_or_default();
                if self.sessions.contains(sid) {
                    reply(id, json!({}));
                } else {
                    reply_err(id, -32002, "session not found");
                }
            }
            ("session/load", Some(id)) => {
                let sid = params["sessionId"].as_str().unwrap_or_default().to_owned();
                if !self.sessions.contains(&sid) {
                    return reply_err(id, -32002, "session not found");
                }
                update(
                    &sid,
                    json!({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "old question"}}),
                );
                update(
                    &sid,
                    json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "REPLAYED"}}),
                );
                reply(id, Value::Null);
            }
            ("session/prompt", Some(id)) => self.prompt(id, params),
            (_, Some(id)) => reply_err(id, -32601, "method not found"),
            (_, None) => {}
        }
    }

    fn prompt(&mut self, id: Value, params: Value) {
        self.cancelled = false;
        let sid = params["sessionId"].as_str().unwrap_or_default().to_owned();
        let text = params["prompt"][0]["text"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let say = |t: &str| {
            update(
                &sid,
                json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}}),
            );
        };
        if text == "crash" {
            say("about to crash");
            std::process::exit(3);
        }
        if text == "slow" {
            for i in 0..200 {
                say(&format!("{i} "));
                std::thread::sleep(Duration::from_millis(50));
                while let Ok(msg) = self.rx.try_recv() {
                    self.handle(msg);
                }
                if self.cancelled {
                    return reply(id, json!({"stopReason": "cancelled"}));
                }
            }
            return reply(id, json!({"stopReason": "end_turn"}));
        }
        if let Some(kind) = text.strip_prefix("tool") {
            let kind = kind
                .strip_prefix(':')
                .filter(|k| !k.is_empty())
                .unwrap_or("edit");
            let tool = json!({"toolCallId": "call-1", "title": "Write notes.txt", "kind": kind, "status": "pending"});
            let mut call = tool.clone();
            call["sessionUpdate"] = "tool_call".into();
            update(&sid, call);
            let outcome = self.request(
                "session/request_permission",
                json!({
                    "sessionId": sid,
                    "toolCall": tool,
                    "options": [
                        {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                        {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
                        {"optionId": "deny", "name": "Reject", "kind": "reject_once"},
                    ],
                }),
            );
            let outcome = &outcome["outcome"];
            if outcome["outcome"] == "cancelled" {
                return reply(id, json!({"stopReason": "cancelled"}));
            }
            let allowed = outcome["optionId"] == "allow" || outcome["optionId"] == "always";
            update(
                &sid,
                json!({
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call-1",
                    "status": if allowed { "completed" } else { "failed" },
                }),
            );
            say(if allowed {
                "tool allowed"
            } else {
                "tool rejected"
            });
            return reply(id, json!({"stopReason": "end_turn"}));
        }
        if text == "env" {
            let var = |k: &str| std::env::var(k).ok();
            say(&json!({
                "HOME": var("HOME"),
                "token": var("THINKTIN_SANDBOX_TOKEN"),
                "secret": var("SHIM_TEST_SECRET"),
                "harness_env": var("FAKE_HARNESS_ENV"),
                "pi_dir": var("PI_CODING_AGENT_DIR"),
            })
            .to_string());
            return reply(id, json!({"stopReason": "end_turn"}));
        }
        if text == "usage" {
            update(
                &sid,
                json!({"sessionUpdate": "usage_update", "used": 1200, "size": 200000}),
            );
            say("counted");
            return reply(
                id,
                json!({"stopReason": "end_turn", "usage": {"inputTokens": 10, "outputTokens": 5, "totalTokens": 15}}),
            );
        }
        update(
            &sid,
            json!({"sessionUpdate": "plan", "entries": [{"content": "answer", "priority": "high", "status": "in_progress"}]}),
        );
        update(
            &sid,
            json!({"sessionUpdate": "available_commands_update", "availableCommands": []}),
        );
        say(&format!("echo: {text}"));
        reply(id, json!({"stopReason": "end_turn"}));
    }

    /// 发请求并等回复；等待期间照常处理别的消息（比如 session/cancel）。
    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        loop {
            let Ok(msg) = self.rx.recv() else {
                std::process::exit(0);
            };
            if msg.get("method").is_none() && msg["id"] == id {
                return msg["result"].clone();
            }
            self.handle(msg);
        }
    }
}

fn reply(id: Value, result: Value) {
    send(json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

fn reply_err(id: Value, code: i64, message: &str) {
    send(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

fn update(sid: &str, update: Value) {
    send(
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": update}}),
    );
}
