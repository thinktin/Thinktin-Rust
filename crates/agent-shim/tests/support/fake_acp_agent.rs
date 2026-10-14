//! 测试用的假 ACP agent：按提示词里的关键字表演各种行为，供 agent-shim 的集成测试驱动。
//!
//! - `tool[:kind]`：发起一次工具调用并请求权限，按结果回复 allowed / rejected，被放弃则以 cancelled 结束
//! - `slow`：慢慢输出，直到收到 session/cancel
//! - `crash`：直接退出（模拟 agent 崩溃）
//! - `env`：把关心的环境变量回报出来，检查 shim 的环境隔离
//! - `usage`：上报用量
//! - `mcp <工具> <JSON 参数>`：启动会话配置里的第一个 MCP 服务器，列出工具并调用一次，把结果说出来
//! - `llm <问题>`：按 shim 写的 Pi 配置（models.json）调模型网关，把回答说出来
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
        mcp_servers: Vec::new(),
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
    mcp_servers: Vec<Value>,
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
                self.mcp_servers = params["mcpServers"].as_array().cloned().unwrap_or_default();
                let sid = format!("fake-{}", self.sessions.len() + 1);
                self.sessions.insert(sid.clone());
                self.save_sessions();
                reply(id, json!({"sessionId": sid}));
            }
            ("session/resume", Some(id)) => {
                let sid = params["sessionId"].as_str().unwrap_or_default();
                if self.sessions.contains(sid) {
                    // 和真实 agent 一样，接回会话时用这次给的 MCP 服务器。
                    self.mcp_servers = params["mcpServers"].as_array().cloned().unwrap_or_default();
                    // 像 Hermes 一样在 resume 时也重放历史，外加一条非历史的更新。
                    update(
                        sid,
                        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "REPLAYED"}}),
                    );
                    update(
                        sid,
                        json!({"sessionUpdate": "available_commands_update", "availableCommands": [{"name": "after-resume"}]}),
                    );
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
                self.mcp_servers = params["mcpServers"].as_array().cloned().unwrap_or_default();
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
        if let Some(rest) = text.strip_prefix("mcp ") {
            let (tool, args) = rest.split_once(' ').unwrap_or((rest, "{}"));
            say(&mcp_call(self.mcp_servers.first(), tool, args));
            return reply(id, json!({"stopReason": "end_turn"}));
        }
        // 像 Pi 一样按 shim 写的 models.json 调模型网关（端到端测试用）。
        if let Some(question) = text.strip_prefix("llm ") {
            match ask_llm(question) {
                Ok(answer) => say(&format!("llm: {answer}")),
                Err(e) => say(&format!("llm error: {e}")),
            }
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

/// 当一个最简单的 MCP 客户端：启动服务器、握手、列工具、调一次工具。
fn mcp_call(server: Option<&Value>, tool: &str, args: &str) -> String {
    let Some(server) = server else {
        return "no mcp server".into();
    };
    let mut child = std::process::Command::new(server["command"].as_str().unwrap())
        .args(
            server["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|a| a.as_str().unwrap()),
        )
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = std::io::BufReader::new(child.stdout.take().unwrap());
    let mut rpc = |id: u64, method: &str, params: Value| -> Value {
        writeln!(
            stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        )
        .unwrap();
        loop {
            let mut line = String::new();
            stdout.read_line(&mut line).unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["id"] == json!(id) {
                return v;
            }
        }
    };
    let init = rpc(
        1,
        "initialize",
        json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake"}}),
    );
    let tools = rpc(2, "tools/list", json!({}));
    let args: Value = serde_json::from_str(args).unwrap_or(json!({}));
    let result = rpc(3, "tools/call", json!({"name": tool, "arguments": args}));
    let _ = child.kill();
    let _ = child.wait();
    format!(
        "server={} tools={} error={} text={}",
        init["result"]["serverInfo"]["name"].as_str().unwrap_or("?"),
        tools["result"]["tools"].as_array().map_or(0, Vec::len),
        result["result"]["isError"],
        result["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or(""),
    )
}

/// 读 shim 生成的 Pi 配置，向模型网关发一次非流式的 Chat Completions 请求，返回回答。
/// 只支持 http（本地网关）。
fn ask_llm(question: &str) -> Result<String, String> {
    use std::io::Read;
    let dir = std::env::var("PI_CODING_AGENT_DIR").map_err(|_| "no PI_CODING_AGENT_DIR")?;
    let models: Value = serde_json::from_str(
        &std::fs::read_to_string(format!("{dir}/models.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let p = &models["providers"]["thinktin"];
    let base = p["baseUrl"].as_str().ok_or("no baseUrl")?;
    let key = p["apiKey"].as_str().ok_or("no apiKey")?;
    let key = match key.strip_prefix('$') {
        Some(var) => std::env::var(var).map_err(|_| format!("{var} is not set"))?,
        None => key.to_owned(),
    };
    let model = p["models"][0]["id"].as_str().ok_or("no model")?;
    let rest = base
        .strip_prefix("http://")
        .ok_or("only http is supported")?;
    let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
    let body =
        json!({"model": model, "messages": [{"role": "user", "content": question}]}).to_string();
    let mut conn = std::net::TcpStream::connect(host).map_err(|e| e.to_string())?;
    write!(
        conn,
        "POST /{path}/chat/completions HTTP/1.0\r\nHost: {host}\r\nAuthorization: Bearer {key}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .map_err(|e| e.to_string())?;
    let mut resp = String::new();
    conn.read_to_string(&mut resp).map_err(|e| e.to_string())?;
    let (head, payload) = resp.split_once("\r\n\r\n").ok_or("bad response")?;
    if !head.starts_with("HTTP/1.0 200") && !head.starts_with("HTTP/1.1 200") {
        return Err(head.lines().next().unwrap_or_default().to_owned());
    }
    let v: Value = serde_json::from_str(payload).map_err(|e| format!("{e}: {payload}"))?;
    Ok(v["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or_default()
        .to_owned())
}
